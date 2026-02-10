defmodule Iso8583.Transport.WebSocket do
  @moduledoc """
  WebSocket transport implementations for ISO 8583.

  Provides WebSocket server implementation for real-time ISO 8583 messaging.
  """

  require Logger

  @type frame_type :: :text | :binary

  @doc """
  Encodes a message with length prefix framing.

  ## Parameters

  - `data` - The binary data to encode
  - `prefix_bytes` - Number of bytes for length prefix (1, 2, or 4)

  ## Examples

      iex> Iso8583.Transport.WebSocket.encode_framed(<<1, 2, 3>>, 2)
      <<0, 3, 1, 2, 3>>

  """
  @spec encode_framed(binary(), pos_integer()) :: binary()
  def encode_framed(data, prefix_bytes \\ 2) do
    length = byte_size(data)
    <<length::big-integer-size(prefix_bytes * 8), data::binary>>
  end

  @doc """
  Decodes a length-prefixed message from a buffer.

  Returns `{:ok, message, remaining_buffer}` or `:incomplete` if more data is needed.

  ## Examples

      iex> Iso8583.Transport.WebSocket.decode_framed(<<0, 3, 1, 2, 3>>, 2)
      {:ok, <<1, 2, 3>>, <<>>}

      iex> Iso8583.Transport.WebSocket.decode_framed(<<0, 3, 1>>, 2)
      :incomplete

  """
  @spec decode_framed(binary(), pos_integer()) :: {:ok, binary(), binary()} | :incomplete
  def decode_framed(buffer, prefix_bytes) do
    prefix_size = prefix_bytes

    if byte_size(buffer) < prefix_size do
      :incomplete
    else
      <<msg_length::big-integer-size(prefix_bytes * 8), rest::binary>> = buffer

      if byte_size(rest) >= msg_length do
        <<message::binary-size(msg_length), remaining::binary>> = rest
        {:ok, message, remaining}
      else
        :incomplete
      end
    end
  end

  @doc """
  Extracts the raw TCP socket port from a Plug.Conn or WebSocket connection.

  This is needed to take control of the socket after WebSocket upgrade.
  """
  def extract_socket_port(conn) do
    case conn do
      # Bandit.Adapter with HTTP1.Socket
      %{adapter: {Bandit.Adapter, %{transport: %{socket: %{socket: port}}}}} when is_port(port) ->
        elem(conn.adapter, 1).transport.socket.socket

      # Bandit with nested socket (alternate structure)
      %{adapter: {Bandit.Adapter, _, %{socket: %{socket: port}}}} when is_port(port) ->
        elem(conn.adapter, 1).socket.socket

      # Bandit with adapter as map
      %{adapter: %{transport: %{socket: %{socket: port}}}} when is_port(port) ->
        conn.adapter.transport.socket.socket

      %{adapter: %{socket: %{socket: port}}} when is_port(port) ->
        conn.adapter.socket.socket

      # Direct ThousandIsland socket reference
      %{socket: %{socket: port}} when is_port(port) ->
        conn.socket.socket

      # Raw port (Cowboy/ranch)
      %{adapter: port} when is_port(port) ->
        conn.adapter

      # Check for deeply nested socket in adapter (tuple case)
      %{adapter: {_module, adapter_struct}} ->
        find_port_in_struct(adapter_struct)

      # Check for deeply nested socket in adapter (map case)
      %{adapter: adapter} when is_map(adapter) ->
        find_port_in_struct(adapter)

      # Fallback
      _ ->
        nil
    end
  end

  defp find_port_in_struct(struct) when is_map(struct) do
    Enum.reduce_while(struct, nil, fn
      {_key, value}, nil when is_port(value) ->
        {:halt, value}

      {_key, value}, nil when is_map(value) ->
        case find_port_in_struct(value) do
          port when is_port(port) -> {:halt, port}
          _ -> {:cont, nil}
        end

      {_key, value}, nil when is_list(value) ->
        case find_port_in_struct(value) do
          port when is_port(port) -> {:halt, port}
          _ -> {:cont, nil}
        end

      {_key, _value}, nil ->
        {:cont, nil}

      {_key, _}, port ->
        {:halt, port}
    end)
  end

  defp find_port_in_struct(struct) when is_list(struct) do
    Enum.find_value(struct, fn
      value when is_port(value) -> value
      value when is_map(value) -> find_port_in_struct(value)
      value when is_list(value) -> find_port_in_struct(value)
      _ -> nil
    end)
  end

  defp find_port_in_struct(_), do: nil
end

defmodule Iso8583.Transport.WebSocket.Server do
  @moduledoc """
  WebSocket Server transport for ISO 8583 messages.

  Provides a WebSocket endpoint for real-time ISO 8583 messaging over WebSocket.
  Messages use 2-byte length prefix framing (big-endian/network order).

  ## Architecture

      ┌─────────────────────────────────────────────────────────┐
      │           Iso8583.Transport.WebSocket.Server             │
      │  - Serves WebSocket upgrade endpoint                     │
      │  - Handles WebSocket connections                        │
      │  - Manages connection lifecycle                         │
      │  - Messages use 2-byte length prefix framing             │
      └─────────────────────────────────────────────────────────┘
                          │
          ┌───────────────┼───────────────┐
          │               │               │
      ┌───────┐       ┌───────┐       ┌───────┐
      │WS Conn1│       │WS Conn2│       │WS Conn3│
      └───────┘       └───────┘       └───────┘

  ## Usage

      defmodule MyApp.WSHandler do
        use Iso8583.Handler,
          processor: MyApp.PaymentProcessor,
          transport: Iso8583.Transport.WebSocket.Server,
          transport_opts: [
            port: 4000,
            path: "/iso8583/ws"
          ]
      end

  ## Options

  | Option | Type | Default | Description |
  |--------|------|---------|-------------|
  | `:port` | `integer()` | Required | Port to listen on |
  | `:path` | `String.t()` | `"/iso8583/ws"` | WebSocket endpoint path |
  | `:name` | `atom()` | `nil` | Name for registration |
  | `:timeout` | `integer()` | `60000` | Connection idle timeout (ms) |
  | `:prefix_bytes` | `1 \\| 2 \\| 4` | `2` | Length prefix bytes |
  | `:scheme` | `:http \\| :https` | `:http` | HTTP or HTTPS |
  | `:certfile` | `String.t()` | `nil` | SSL certificate file |
  | `:keyfile` | `String.t()` | `nil` | SSL key file |

  ## Message Framing

  All messages use length-prefix framing with configurable prefix size (default: 2 bytes).

  ### Client to Server (Request)
  ```
  +--------+--------+--------------------------+
  | Len Hi | Len Lo |     ISO 8583 Message     |
  +--------+--------+--------------------------+
  |<---- 2 bytes --->|<-- Length bytes ------->|
  ```

  ### Server to Client (Response)
  ```
  +--------+--------+--------------------------+
  | Len Hi | Len Lo |     ISO 8583 Response    |
  +--------+--------+--------------------------+
  |<---- 2 bytes --->|<-- Length bytes ------->|
  ```

  ## WebSocket Client Example

  JavaScript:
  ```javascript
  const ws = new WebSocket('ws://localhost:4000/iso8583/ws');

  // Send ISO message with 2-byte length prefix
  function sendMessage(isoMessage) {
    const length = isoMessage.length;
    const framed = new Uint8Array(2 + length);
    framed[0] = (length >> 8) & 0xFF;  // Length high byte
    framed[1] = length & 0xFF;         // Length low byte
    framed.set(isoMessage, 2);
    ws.send(framed);
  }

  ws.onmessage = (event) => {
    const data = new Uint8Array(event.data);
    const length = (data[0] << 8) | data[1];
    const isoMessage = data.slice(2, 2 + length);
    // Process ISO 8583 response
  };
  ```

  Python (using websocket-client):
  ```python
  import websocket
  import struct

  def on_message(ws, message):
      # message is bytes with 2-byte length prefix
      length = struct.unpack('>H', message[:2])[0]
      iso_message = message[2:2+length]
      # Process ISO 8583 response
      print(f"Received: {iso_message.hex()}")

  def send_iso_message(ws, iso_data):
      framed = struct.pack('>H', len(iso_data)) + iso_data
      ws.send(framed, websocket.ABNF.OPCODE_BINARY)

  ws = websocket.WebSocketApp("ws://localhost:4000/iso8583/ws",
                              on_message=on_message)
  ws.run_forever()
  ```

  ## Context Metadata

  The server populates `Iso8583.Context` with:
  - `transport_ref` - The `WebSocket` struct
  - `client_id` - Unique connection identifier (UUID)
  - `peer_address` - Client's IP address from headers
  - `transport_metadata` - `%{headers, path, request_uri, user_agent}`

  ## Comparison with TCP Transport

  | Feature | TCP | WebSocket |
  |---------|-----|-----------|
  | Protocol | Raw TCP | HTTP/WebSocket |
  | Firewall | May be blocked | Works through most firewalls |
  | Browser | No native support | Full support |
  | Overhead | Minimal | HTTP handshake + framing |
  | TLS | Separate port | Same port (wss://) |
  | Framing | Configurable | 2-byte length prefix |

  ## Supervisor Tree

      Iso8583.Transport.WebSocket.Server (Supervisor)
          │
          ├── WebSocketRegistry (ETS)
          │
          └── Bandit HTTP Server
                │
                └── WebSocket Connections (Lightweight processes)
  """

  use Supervisor

  defstruct [
    :port,
    :path,
    :scheme,
    :timeout,
    :name,
    :certfile,
    :keyfile,
    :prefix_bytes,
    :receive_callback
  ]

  # Client API

  @doc """
  Starts the WebSocket server transport.
  """
  def start_link(opts) do
    port = Keyword.fetch!(opts, :port)
    path = Keyword.get(opts, :path, "/iso8583/ws")
    scheme = Keyword.get(opts, :scheme, :http)
    timeout = Keyword.get(opts, :timeout, 60_000)
    name = Keyword.get(opts, :name)
    certfile = Keyword.get(opts, :certfile)
    keyfile = Keyword.get(opts, :keyfile)
    prefix_bytes = Keyword.get(opts, :prefix_bytes, 2)

    Supervisor.start_link(
      __MODULE__,
      [
        port: port,
        path: path,
        scheme: scheme,
        timeout: timeout,
        name: name,
        certfile: certfile,
        keyfile: keyfile,
        prefix_bytes: prefix_bytes
      ],
      name: name
    )
  end

  @doc """
  Returns the child spec for supervision.
  """
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      type: :supervisor
    }
  end

  @doc """
  Sends data (response) to a WebSocket client.

  For WebSocket server, responses are sent directly through the WebSocket connection.
  """
  def send(ws_handle, data) do
    Iso8583.Transport.WebSocket.Socket.send(ws_handle, data)
  end

  @doc """
  Registers the callback for receiving messages.
  """
  def set_receive_callback(server_pid, callback) when is_pid(server_pid) do
    GenServer.call(server_pid, {:set_callback, callback})
  end

  def set_receive_callback(name, callback) when is_atom(name) do
    case Registry.lookup(Iso8583.WebSocket.Registry, name) do
      [{pid, _}] -> GenServer.call(pid, {:set_callback, callback})
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Stops the server.
  """
  def stop(server_pid) when is_pid(server_pid) do
    Supervisor.stop(server_pid, :normal)
  end

  def stop(name) when is_atom(name) do
    case Process.whereis(name) do
      nil -> {:error, :not_found}
      pid -> Supervisor.stop(pid, :normal)
    end
  end

  # Supervisor Callbacks

  @impl true
  def init(opts) do
    port = Keyword.fetch!(opts, :port)
    path = Keyword.get(opts, :path, "/iso8583/ws")
    scheme = Keyword.get(opts, :scheme, :http)
    timeout = Keyword.get(opts, :timeout, 60_000)
    name = Keyword.get(opts, :name)
    certfile = Keyword.get(opts, :certfile)
    keyfile = Keyword.get(opts, :keyfile)
    prefix_bytes = Keyword.get(opts, :prefix_bytes, 2)

    # Start state process to hold callback
    state_name = Module.concat(__MODULE__, State)

    children = [
      # Start WebSocket Registry first
      {Registry, [keys: :unique, name: Iso8583.WebSocket.Registry]},
      # State process for callback storage
      {Iso8583.Transport.WebSocket.Server.State,
       [
         port: port,
         path: path,
         timeout: timeout,
         registry_name: name,
         prefix_bytes: prefix_bytes,
         name: state_name
       ]},
      # Plug-based WebSocket endpoint
      {Iso8583.Transport.WebSocket.Server.Endpoint,
       [
         state_name: state_name,
         path: path,
         port: port,
         scheme: scheme,
         certfile: certfile,
         keyfile: keyfile
       ]}
    ]

    opts = [strategy: :one_for_one]
    Supervisor.init(children, opts)
  end
end

defmodule Iso8583.Transport.WebSocket.Server.State do
  @moduledoc """
  GenServer that holds the receive callback for the WebSocket server.
  """

  use GenServer

  defstruct [:callback, :port, :path, :timeout, :registry_name, :prefix_bytes]

  def start_link(opts) do
    name = Keyword.get(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def init(opts) do
    port = Keyword.fetch!(opts, :port)
    path = Keyword.get(opts, :path, "/iso8583/ws")
    timeout = Keyword.get(opts, :timeout, 60_000)
    registry_name = Keyword.get(opts, :registry_name)
    prefix_bytes = Keyword.get(opts, :prefix_bytes, 2)

    # Register in registry so we can be found
    if registry_name do
      try do
        Registry.register(Iso8583.WebSocket.Registry, registry_name, self())
      rescue
        _ -> :ok
      end
    end

    {:ok,
     %__MODULE__{
       callback: nil,
       port: port,
       path: path,
       timeout: timeout,
       registry_name: registry_name,
       prefix_bytes: prefix_bytes
     }}
  end

  def handle_call({:set_callback, callback}, _from, state) do
    {:reply, :ok, %{state | callback: callback}}
  end

  def handle_call(:get_callback, _from, state) do
    {:reply, state.callback, state}
  end

  def handle_call(:get_prefix_bytes, _from, state) do
    {:reply, state.prefix_bytes, state}
  end

  def handle_info({:get_callback, from}, state) do
    # Send callback back to the requesting process (non-blocking)
    send(from, {:callback, state.callback})
    {:noreply, state}
  end

  def handle_info(:register, state) do
    if state.registry_name do
      try do
        Registry.register(Iso8583.WebSocket.Registry, state.registry_name, self())
      rescue
        _ -> :ok
      end
    end

    {:noreply, state}
  end
end

defmodule Iso8583.Transport.WebSocket.Server.Endpoint do
  @moduledoc """
  Bandit-powered WebSocket endpoint for ISO 8583 messages.
  """

  use GenServer

  defstruct [:state_name, :path, :port, :scheme, :ref]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def init(opts) do
    state_name = Keyword.get(opts, :state_name)
    path = Keyword.get(opts, :path, "/iso8583/ws")
    port = Keyword.get(opts, :port)
    scheme = Keyword.get(opts, :scheme, :http)
    certfile = Keyword.get(opts, :certfile)
    keyfile = Keyword.get(opts, :keyfile)

    # Start the listener with WebSocket plug
    bandit_opts = [
      plug: {Iso8583.Transport.WebSocket.Server.Plug, state_name: state_name, path: path},
      port: port,
      scheme: scheme
    ]

    bandit_opts =
      if certfile && keyfile do
        bandit_opts ++ [certfile: certfile, keyfile: keyfile]
      else
        bandit_opts
      end

    # Bandit is an optional dependency - check if it's available
    if Code.ensure_loaded?(Bandit) do
      case apply(Bandit, :start_link, [bandit_opts]) do
        {:ok, pid} ->
          send(state_name, :register)

          {:ok, %__MODULE__{state_name: state_name, path: path, port: port, scheme: scheme, ref: pid}}

        {:error, reason} ->
          {:stop, reason}
      end
    else
      {:stop, {:error, :bandit_not_available}}
    end
  end

  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    {:stop, reason, state}
  end

  def terminate(_reason, state) do
    if state.ref, do: Process.exit(state.ref, :normal)
    :ok
  end
end

defmodule Iso8583.Transport.WebSocket.Server.Plug do
  @moduledoc """
  Plug that handles WebSocket upgrade requests for ISO 8583 messages.

  Uses Bandit WebSocket via WebSockAdapter.upgrade/4.
  """

  import Plug.Conn
  require Logger

  def init(opts) do
    state_name = Keyword.fetch!(opts, :state_name)
    path = Keyword.fetch!(opts, :path)
    %{state_name: state_name, path: path}
  end

  def call(conn, %{state_name: state_name, path: path}) do
    if conn.method == "GET" and conn.request_path == path do
      # Check for WebSocket upgrade request
      case get_req_header(conn, "upgrade") do
        ["websocket"] ->
          Logger.debug("WebSocket upgrade request received for #{path}")
          # Upgrade to WebSocket using WebSockAdapter (Bandit)
          WebSockAdapter.upgrade(
            conn,
            Iso8583.Transport.WebSocket.Server.Handler,
            %{state_name: state_name},
            timeout: 60_000
          )

        _ ->
          send_resp(conn, 426, "Upgrade Required")
          |> put_resp_header("upgrade", "websocket")
      end
    else
      send_resp(conn, 404, "Not found")
    end
  end
end

defmodule Iso8583.Transport.WebSocket.Server.Handler do
  @moduledoc """
  WebSocket handler using the WebSock behaviour for Bandit.

  Receives WebSocket messages and forwards them to the ISO 8583 processor.
  """

  @behaviour WebSock
  require Logger

  @impl true
  def init(state) do
    Logger.info("WebSocket connection established")
    {:ok, state}
  end

  @impl true
  def handle_in({data, [{:opcode, :binary}]}, state) do
    Logger.info("WebSocket received binary message: #{byte_size(data)} bytes")
    process_message(data, state)
  end

  @impl true
  def handle_in({data, [{:opcode, :text}]}, state) do
    Logger.info("WebSocket received text message: #{byte_size(data)} bytes")
    process_message(data, state)
  end

  @impl true
  def handle_control(_ping_or_pong, state) do
    # Pongs are automatically sent by the server before this callback
    {:ok, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:ok, state}
  end

  @impl true
  def terminate(_reason, _state) do
    Logger.info("WebSocket connection terminated")
    :ok
  end

  # Process the received message through the callback
  defp process_message(data, state) do
    # Try to get the callback from the state process without blocking
    case GenServer.whereis(state.state_name) do
      nil ->
        Logger.warning("State process not found!")
        {:ok, state}

      pid ->
        # Use a non-blocking approach - send request and handle response asynchronously
        send(pid, {:get_callback, self()})
        # Wait for response with a timeout
        receive do
          {:callback, callback} when is_function(callback, 2) ->
            # Create context
            context = %{
              peer_address: {127, 0, 0, 1},
              transport_metadata: %{
                websocket: true
              }
            }

            # Call the callback
            result = callback.(data, context)
            Logger.info("Callback returned: #{inspect(result)}")

            # Send response back if callback returns {:reply, response}
            case result do
              {:reply, response} when is_binary(response) and byte_size(response) > 0 ->
                # Frame the response with 2-byte length prefix (big-endian)
                response_len = byte_size(response)
                framed_response = <<response_len::16-big, response::binary>>
                Logger.info("Sending framed response: #{byte_size(framed_response)} bytes (response_size: #{response_len}) (hex: #{Base.encode16(framed_response)})")
                {:push, [{:binary, framed_response}], state}

              {:reply, response} when is_binary(response) ->
                Logger.warning("Response is empty (size: #{byte_size(response)}), not sending")
                {:ok, state}

              other ->
                Logger.warning("Unexpected result format: #{inspect(other)}")
                {:ok, state}
            end

          {:callback, nil} ->
            Logger.warning("No callback registered!")
            {:ok, state}

          _ ->
            Logger.warning("Invalid callback response")
            {:ok, state}
        after
          5000 ->
            Logger.error("Timeout waiting for callback")
            {:ok, state}
        end
    end
  end
end

defmodule Iso8583.Transport.WebSocket.Socket do
  @moduledoc """
  Handles WebSocket connection for ISO 8583 messages.

  Manages the WebSocket connection, handles incoming framed messages,
  and sends framed responses.
  """

  use GenServer
  require Logger
  import Kernel, except: [send: 2]

  defstruct [
    :conn,
    :state_name,
    :client_id,
    :peer_address,
    :prefix_bytes,
    :headers,
    :buffer,
    :socket_port
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def init(opts) do
    conn = Keyword.get(opts, :conn)
    state_name = Keyword.fetch!(opts, :state_name)
    prefix_bytes = Keyword.fetch!(opts, :prefix_bytes)
    peer_address = Keyword.get(opts, :peer_address, {127, 0, 0, 1})
    headers = Keyword.get(opts, :headers, %{})

    # Generate client ID
    client_id = generate_client_id()

    # Get socket port - either passed directly or extracted from conn
    socket_port = case Keyword.fetch(opts, :socket_port) do
      {:ok, port} when is_port(port) ->
        Logger.info("Using provided socket port: #{inspect(port)}")
        port

      :error ->
        # Fallback: extract from conn (old behavior)
        conn = Keyword.fetch!(opts, :socket)
        Iso8583.Transport.WebSocket.extract_socket_port(conn)
    end

    # Defer socket ownership transfer and active mode setup
    # This will be handled in handle_continue after init completes
    # and after parent transfers ownership to us
    {:ok, %__MODULE__{
      conn: conn,
      state_name: state_name,
      client_id: client_id,
      peer_address: peer_address,
      prefix_bytes: prefix_bytes,
      headers: headers,
      buffer: <<>>,
      socket_port: socket_port
    }, {:continue, :setup_socket}}
  end

  def handle_continue(:setup_socket, state) do
    # Now we can set up the socket (ownership should have been transferred by parent)
    Logger.info("Setting up socket in handle_continue")

    # Set socket to active mode to receive {:tcp, port, data} messages
    case :inet.setopts(state.socket_port, active: true) do
      :ok -> Logger.info("setopts active: true succeeded in handle_continue")
      {:error, reason} -> Logger.error("setopts failed: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  # Extract the actual TCP port from various connection structures
  defp extract_socket_port(conn) do
    require Logger
    Logger.info("Extracting socket port from conn, adapter: #{inspect(conn.adapter)}")
    # Try multiple patterns to extract the socket port
    case conn do
      # Bandit.Adapter with HTTP1.Socket: {Bandit.Adapter, %Bandit.Adapter{transport: %Bandit.HTTP1.Socket{socket: %ThousandIsland.Socket{socket: port}}}}}
      %{adapter: {Bandit.Adapter, %{transport: %{socket: %{socket: port}}}}} when is_port(port) ->
        elem(conn.adapter, 1).transport.socket.socket

      # Bandit with nested socket (alternate structure)
      %{adapter: {Bandit.Adapter, _, %{socket: %{socket: port}}}} when is_port(port) ->
        elem(conn.adapter, 1).socket.socket

      # Bandit with adapter as map
      %{adapter: %{transport: %{socket: %{socket: port}}}} when is_port(port) ->
        conn.adapter.transport.socket.socket

      %{adapter: %{socket: %{socket: port}}} when is_port(port) ->
        conn.adapter.socket.socket

      # Direct ThousandIsland socket reference
      %{socket: %{socket: port}} when is_port(port) ->
        conn.socket.socket

      # Raw port (Cowboy/ranch)
      %{adapter: port} when is_port(port) ->
        conn.adapter

      # Check for deeply nested socket in adapter (tuple case)
      %{adapter: {_module, adapter_struct}} ->
        try do
          find_port_in_struct(adapter_struct)
        rescue
          _ ->
            find_port_in_conn_safe(conn)
        end

      # Check for deeply nested socket in adapter (map case)
      %{adapter: adapter} when is_map(adapter) ->
        try do
          find_port_in_struct(adapter)
        rescue
          _ ->
            find_port_in_conn_safe(conn)
        end

      # Fallback: try to find any port in the entire conn struct
      _ ->
        find_port_in_conn_safe(conn)
    end
  end

  # Safe search that handles Plug.Conn and other non-enumerable structures
  defp find_port_in_conn_safe(conn) do
    # Only search specific fields that might contain the socket
    potential_fields = [:adapter, :transport, :socket]

    Enum.find_value(potential_fields, fn field ->
      case Map.get(conn, field) do
        nil -> nil
        value when is_port(value) -> value
        value when is_map(value) -> find_port_in_struct_safe(value)
        value when is_list(value) -> find_port_in_struct_safe(value)
        {_mod, _tag, struct, _, _, _} -> find_port_in_struct_safe(struct)
        _ -> nil
      end
    end) || throw(:cannot_extract_socket_port)
  end

  # Recursively search for a port in nested structures
  defp find_port_in_struct(struct) when is_map(struct) do
    Enum.reduce_while(struct, nil, fn
      {_key, value}, nil when is_port(value) ->
        {:halt, value}

      {_key, value}, nil when is_map(value) ->
        case find_port_in_struct(value) do
          port when is_port(port) -> {:halt, port}
          _ -> {:cont, nil}
        end

      {_key, value}, nil when is_list(value) ->
        case find_port_in_struct(value) do
          port when is_port(port) -> {:halt, port}
          _ -> {:cont, nil}
        end

      {_key, _value}, nil ->
        {:cont, nil}

      {_key, _}, port ->
        {:halt, port}
    end) || throw(:cannot_extract_socket_port)
  end

  defp find_port_in_struct(struct) when is_list(struct) do
    Enum.find_value(struct, fn
      value when is_port(value) -> value
      value when is_map(value) -> find_port_in_struct_safe(value)
      value when is_list(value) -> find_port_in_struct(value)
      _ -> nil
    end) || throw(:cannot_extract_socket_port)
  end

  defp find_port_in_struct(_), do: throw(:cannot_extract_socket_port)

  # Safe version that returns nil instead of throwing
  defp find_port_in_struct_safe(struct) when is_map(struct) do
    try do
      find_port_in_struct(struct)
    rescue
      :cannot_extract_socket_port -> nil
      _ -> nil
    end
  end

  defp find_port_in_struct_safe(struct) when is_list(struct) do
    try do
      find_port_in_struct(struct)
    rescue
      :cannot_extract_socket_port -> nil
      _ -> nil
    end
  end

  defp find_port_in_struct_safe(_), do: nil

  # WebSocket frame decoding for server-side (client sends masked frames)
  defp decode_websocket_frames(data, acc) do
    decode_frames(data, acc)
  end

  defp decode_frames(<<>>, acc), do: {:ok, Enum.reverse(acc), <<>>}

  defp decode_frames(data, acc) do
    case decode_single_frame(data) do
      {:ok, frame_payload, remaining} ->
        decode_frames(remaining, [frame_payload | acc])

      {:error, :incomplete} ->
        {:ok, Enum.reverse(acc), data}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_single_frame(<<_fin::1, _rsv1::1, _rsv2::1, _rsv3::1, _opcode::4, mask::1, _::7, rest::binary>>) do
    case rest do
      # Unmasked frame with short payload (< 126) - server-to-client
      <<payload_len::7, payload::binary-size(payload_len), remaining::binary>>
          when mask == 0 and payload_len < 126 ->
        {:ok, payload, remaining}

      # Unmasked frame with 16-bit extended length - marker is 126
      <<126::7, ext_len::16, payload::binary-size(ext_len), remaining::binary>>
          when mask == 0 ->
        {:ok, payload, remaining}

      # Unmasked frame with 64-bit extended length - marker is 127
      <<127::7, ext_len::64, payload::binary-size(ext_len), remaining::binary>>
          when mask == 0 and ext_len <= 4_294_967_295 ->
        {:ok, payload, remaining}

      # Masked frame with short payload (< 126) - client-to-server
      <<payload_len::7, mask_key::32, payload::binary-size(payload_len), remaining::binary>>
          when mask == 1 and payload_len < 126 ->
        unmasked = unmask_payload(payload, mask_key, <<>>)
        {:ok, unmasked, remaining}

      # Masked frame with 16-bit extended length - marker is 126
      <<126::7, ext_len::16, mask_key::32, payload::binary-size(ext_len), remaining::binary>>
          when mask == 1 ->
        unmasked = unmask_payload(payload, mask_key, <<>>)
        {:ok, unmasked, remaining}

      # Masked frame with 64-bit extended length - marker is 127
      <<127::7, ext_len::64, mask_key::32, payload::binary-size(ext_len), remaining::binary>>
          when mask == 1 ->
        if ext_len <= 4_294_967_295 do
          unmasked = unmask_payload(payload, mask_key, <<>>)
          {:ok, unmasked, remaining}
        else
          {:error, :payload_too_large}
        end

      _ ->
        {:error, :incomplete}
    end
  end

  defp decode_single_frame(_), do: {:error, :incomplete}

  defp unmask_payload(<<>>, _mask_key, acc), do: acc

  defp unmask_payload(<<byte::8, rest::binary>>, <<mask_key::32, remaining_mask::binary>>, acc) do
    unmasked = Bitwise.bxor(byte, mask_key)
    unmask_payload(rest, <<remaining_mask::binary, mask_key::8>>, acc <> <<unmasked::8>>)
  end

  def handle_info({:tcp, _port, data}, state) do
    # Append data to buffer
    new_buffer = state.buffer <> data
    Logger.info("WebSocket received #{byte_size(data)} bytes, buffer now #{byte_size(new_buffer)} bytes")

    # First decode WebSocket frames (client sends masked frames)
    case decode_websocket_frames(new_buffer, []) do
      {:ok, frame_payloads, remaining_buffer} ->
        Logger.info("Decoded #{length(frame_payloads)} WebSocket frames")

        # Extract ISO messages from each frame payload (length-prefixed)
        Enum.each(frame_payloads, fn frame_payload ->
          case extract_messages(frame_payload, state.prefix_bytes, []) do
            {:ok, messages, _} ->
              Logger.info("Extracted #{length(messages)} ISO messages from frame")
              # Process each message
              Enum.each(messages, fn data ->
                Logger.info("Calling get_callback from state_name: #{inspect(state.state_name)}")
                case GenServer.call(state.state_name, :get_callback, 5000) do
                  nil ->
                    Logger.warning("No callback registered!")
                    :ok

                  callback ->
                    context = build_context(state)
                    Logger.info("Calling callback with #{byte_size(data)} bytes")
                    result = callback.(data, context)
                    Logger.info("Callback returned: #{inspect(result)}")

                    # Send response back if callback returns {:reply, response}
                    case result do
                      {:reply, response} when is_binary(response) and byte_size(response) > 0 ->
                        Logger.info("Sending response: #{byte_size(response)} bytes")
                        send(%__MODULE__{socket_port: state.socket_port, prefix_bytes: state.prefix_bytes}, response)

                      _ ->
                        Logger.info("No response to send")
                        :ok
                    end
                end
              end)

            :incomplete ->
              Logger.warning("Incomplete ISO message in frame")
          end
        end)

        :erlang.send(self(), :receive)
        {:noreply, %{state | buffer: remaining_buffer}}

      {:error, :incomplete} ->
        # Need more data for complete WebSocket frame
        {:noreply, %{state | buffer: new_buffer}}
    end
  end

  def handle_info({:tcp_closed, _port}, state) do
    {:stop, :normal, state}
  end

  def handle_info({:tcp_error, _port, reason}, state) do
    Logger.info("WebSocket TCP error: #{inspect(reason)}")
    {:stop, reason, state}
  end

  def handle_info(msg, state) do
    Logger.info("WebSocket received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  def terminate(_reason, state) do
    if state.socket_port do
      # Close the underlying socket
      :gen_tcp.close(state.socket_port)
    end

    :ok
  end

  @doc """
  Sends framed data to the WebSocket client.
  """
  def send(%__MODULE__{} = socket, data) do
    framed = Iso8583.Transport.WebSocket.encode_framed(data, socket.prefix_bytes)

    # Use raw TCP send instead of Plug.Conn.chunk for Bandit compatibility
    :gen_tcp.send(socket.socket_port, framed)
  end

  # Private functions

  defp extract_messages(buffer, prefix_bytes, acc) do
    case Iso8583.Transport.WebSocket.decode_framed(buffer, prefix_bytes) do
      {:ok, message, remaining} ->
        extract_messages(remaining, prefix_bytes, [message | acc])

      :incomplete ->
        if acc == [] do
          :incomplete
        else
          {:ok, Enum.reverse(acc), buffer}
        end
    end
  end

  defp build_context(state) do
    Iso8583.Context.new(
      transport_ref: self(),
      client_id: state.client_id,
      peer_address: state.peer_address,
      transport_metadata: %{
        headers: state.headers,
        path: state.conn.request_path,
        user_agent: Map.get(state.headers, "user-agent")
      }
    )
  end

  defp generate_client_id do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)
    :erlang.list_to_binary(:io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e]))
  end
end

defmodule Iso8583.Transport.WebSocket.Client do
  @moduledoc """
  WebSocket Client transport for ISO 8583 messages.

  Connects to a WebSocket server and sends/receives ISO 8583 messages with
  2-byte length-prefix framing.

  ## Usage

      defmodule MyApp.WSClientHandler do
        use Iso8583.Handler,
          processor: MyApp.PaymentProcessor,
          transport: Iso8583.Transport.WebSocket.Client,
          transport_opts: [
            url: "ws://localhost:4000/iso8583/ws"
          ]
      end

  ## Options

  | Option | Type | Default | Description |
  |--------|------|---------|-------------|
  | `:url` | `String.t()` | Required | WebSocket URL (ws:// or wss://) |
  | `:name` | `atom()` | `nil` | Name for registration |
  | `:reconnect_interval` | `integer()` | `5000` | Reconnect delay on disconnect (ms) |
  | `:timeout` | `integer()` | `60000` | Connection timeout (ms) |
  | `:prefix_bytes` | `1 \\| 2 \\| 4` | `2` | Length prefix bytes for framing |
  | `:headers` | `map()` | `%{}` | Additional headers for handshake |

  ## Message Framing

  All messages use length-prefix framing (default: 2 bytes).

  **Client to Server:**
  ```
  +--------+--------+--------------------------+
  | Len Hi | Len Lo |     ISO 8583 Message     |
  +--------+--------+--------------------------+
  ```

  **Server to Client:**
  ```
  +--------+--------+--------------------------+
  | Len Hi | Len Lo |     ISO 8583 Response    |
  +--------+--------+--------------------------+
  ```

  ## Context Metadata

  The client populates `Iso8583.Context` with:
  - `transport_ref` - `:client` (atom identifier)
  - `client_id` - `"ws_client"`
  - `peer_address` - Server's host and port
  - `transport_metadata` - `%{url, connection_time, bytes_sent, bytes_received}`

  ## Example

      # Connect to WebSocket server
      {:ok, client} = Iso8583.Transport.WebSocket.Client.start_link(
        url: "ws://localhost:4000/iso8583/ws"
      )

      # Set callback for incoming messages
      Iso8583.Transport.WebSocket.Client.set_receive_callback(client, fn
        data, _context ->
          # Process ISO 8583 response
          IO.inspect("Received: \#{Base.encode16(data)}")
      end)

      # Send ISO message (automatically framed with length prefix)
      iso_message = <<0x02, 0x00, 0xB2, 0x20, ...>>
      Iso8583.Transport.WebSocket.Client.send(:client, iso_message)
  """

  use GenServer
  require Logger
  import Kernel, except: [send: 2]
  import Bitwise

  alias Iso8583.Context

  defstruct [
    :socket,
    :url,
    :host,
    :port,
    :path,
    :scheme,
    :receive_callback,
    :reconnect_interval,
    :timeout,
    :prefix_bytes,
    :headers,
    :connection_time,
    :bytes_sent,
    :bytes_received,
    :buffer
  ]

  @doc """
  Starts the WebSocket client transport.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Returns the child spec for supervision.
  """
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      type: :worker
    }
  end

  @doc """
  Sends data to the WebSocket server.
  """
  def send(:client, data) do
    GenServer.call(__MODULE__, {:send, data})
  end

  def send(pid, data) when is_pid(pid) do
    GenServer.call(pid, {:send, data})
  end

  @doc """
  Registers the callback for receiving messages.
  """
  def set_receive_callback(client_pid, callback) when is_pid(client_pid) do
    GenServer.call(client_pid, {:set_callback, callback})
  end

  @doc """
  Stops the client.
  """
  def stop(client_pid) when is_pid(client_pid) do
    GenServer.stop(client_pid, :normal)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    url = Keyword.fetch!(opts, :url)
    reconnect_interval = Keyword.get(opts, :reconnect_interval, 5000)
    timeout = Keyword.get(opts, :timeout, 60_000)
    prefix_bytes = Keyword.get(opts, :prefix_bytes, 2)
    headers = Keyword.get(opts, :headers, %{})

    # Parse URL
    {scheme, host, port, path} = parse_url(url)

    # Try to connect immediately
    :erlang.send(self(), :connect)

    {:ok,
     %__MODULE__{
       url: url,
       scheme: scheme,
       host: host,
       port: port,
       path: path,
       reconnect_interval: reconnect_interval,
       timeout: timeout,
       prefix_bytes: prefix_bytes,
       headers: headers,
       socket: nil,
       connection_time: nil,
       bytes_sent: 0,
       bytes_received: 0,
       buffer: <<>>
     }}
  end

  @impl true
  def handle_info(:connect, state) do
    case websocket_connect(state) do
      {:ok, socket} ->
        Logger.info("WebSocket connected to #{state.url}")

        # Set socket to active mode to receive data as messages
        :inet.setopts(socket, active: :once)

        {:noreply,
         %{state | socket: socket, connection_time: System.system_time(:millisecond),
           buffer: <<>>}}

      {:error, reason} ->
        Logger.warning("Failed to connect to #{state.url}: #{inspect(reason)}")
        Process.send_after(self(), :connect, state.reconnect_interval)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:tcp, socket, data}, state) when socket == state.socket do
    Logger.info("Received #{byte_size(data)} bytes from server (hex: #{Base.encode16(data)})")

    # Decode WebSocket frames
    case decode_websocket_frames(data, state.buffer) do
      {:ok, frame_payloads, new_buffer} ->
        Logger.info("Decoded #{length(frame_payloads)} WebSocket frames")

        # Extract ISO messages from each frame
        {iso_messages, total_bytes} = extract_iso_messages(frame_payloads, state.prefix_bytes, [], 0)

        Logger.info("Extracted #{length(iso_messages)} ISO messages (#{total_bytes} bytes)")

        # Process each received message
        Enum.each(iso_messages, fn data ->
          if state.receive_callback do
            context = build_context(state)
            state.receive_callback.(data, context)
          end
        end)

        # Re-enable active mode to receive next message
        :inet.setopts(socket, active: :once)

        {:noreply, %{state | buffer: new_buffer, bytes_received: state.bytes_received + total_bytes}}

      {:error, reason} ->
        Logger.error("WebSocket decode error: #{inspect(reason)}")
        # Re-enable active mode
        :inet.setopts(socket, active: :once)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:tcp_closed, socket}, state) when socket == state.socket do
    Logger.warning("WebSocket connection closed to #{state.url}")
    :erlang.send(self(), :connect)
    {:noreply, %{state | socket: nil, connection_time: nil, buffer: <<>>}}
  end

  @impl true
  def handle_info({:tcp_error, socket, reason}, state) when socket == state.socket do
    Logger.error("WebSocket TCP error: #{inspect(reason)}")
    :erlang.send(self(), :connect)
    {:noreply, %{state | socket: nil, connection_time: nil, buffer: <<>>}}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("Received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def handle_call({:send, data}, _from, state) do
    if state.socket do
      # Frame the data with length prefix
      framed_data = frame_data(data, state.prefix_bytes)

      # Wrap in WebSocket binary frame
      ws_frame = encode_websocket_frame(framed_data)

      Logger.info("Sending WebSocket frame: #{byte_size(ws_frame)} bytes (data: #{byte_size(framed_data)} bytes)")
      Logger.debug("Frame hex: #{Base.encode16(ws_frame)}")
      Logger.debug("Framed data hex: #{Base.encode16(framed_data)}")

      case :gen_tcp.send(state.socket, ws_frame) do
        :ok ->
          Logger.debug("Sent successfully via :gen_tcp.send")
          {:reply, :ok, %{state | bytes_sent: state.bytes_sent + byte_size(ws_frame)}}

        {:error, reason} ->
          Logger.error("Failed to send: #{inspect(reason)}")
          {:reply, {:error, reason}, state}
      end
    else
      Logger.warning("Cannot send - socket is nil")
      {:reply, {:error, :not_connected}, state}
    end
  end

  @impl true
  def handle_call({:set_callback, callback}, _from, state) do
    {:reply, :ok, %{state | receive_callback: callback}}
  end

  @impl true
  def terminate(_reason, state) do
    if state.socket do
      # Send close frame
      close_frame = <<0x88, 0>>
      :gen_tcp.send(state.socket, close_frame)
      :gen_tcp.close(state.socket)
    end

    :ok
  end

  # Private functions

  defp parse_url(url) do
    # Parse ws:// or wss:// URL
    uri = URI.parse(url)

    scheme = case uri.scheme do
      "ws" -> :ws
      "wss" -> :wss
      _ -> :ws
    end

    port = case {scheme, uri.port} do
      {:ws, nil} -> 80
      {:wss, nil} -> 443
      {_, port} -> port
    end

    path = uri.path || "/"

    {scheme, uri.host, port, path}
  end

  defp websocket_connect(state) do
    # Generate WebSocket key
    key = :base64.encode(:crypto.strong_rand_bytes(16))

    # Build Host header
    host_header = if state.port == 80 do
      state.host
    else
      "#{state.host}:#{state.port}"
    end

    # Build handshake request
    headers = [
      {"Host", host_header},
      {"Upgrade", "websocket"},
      {"Connection", "Upgrade"},
      {"Sec-WebSocket-Key", key},
      {"Sec-WebSocket-Version", "13"}
    ] ++ Map.to_list(state.headers)

    request = [
      "GET #{state.path} HTTP/1.1\r\n",
      Enum.map(headers, fn {k, v} -> "#{k}: #{v}\r\n" end),
      "\r\n"
    ]

    # Connect to server
    host_charlist = to_charlist(state.host)
    connect_opts = [:binary, packet: :raw, active: false]

    case :gen_tcp.connect(host_charlist, state.port, connect_opts, state.timeout) do
      {:ok, socket} ->
        # Send handshake
        request_str = :erlang.iolist_to_binary(request)
        case :gen_tcp.send(socket, request_str) do
          :ok ->
            # Receive handshake response (may be split across multiple packets)
            case recv_handshake_response(socket, <<>>, state.timeout) do
              {:ok, response} ->
                case parse_handshake_response(response, key) do
                  :ok ->
                    {:ok, socket}

                  {:error, reason} ->
                    :gen_tcp.close(socket)
                    {:error, reason}
                end

              {:error, reason} ->
                :gen_tcp.close(socket)
                {:error, reason}
            end

          {:error, reason} ->
            :gen_tcp.close(socket)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Receive HTTP handshake response, handling split packets
  defp recv_handshake_response(socket, acc, timeout) do
    case :gen_tcp.recv(socket, 0, timeout) do
      {:ok, data} ->
        new_acc = acc <> data
        # Check if we have received the full headers (ending with \r\n\r\n)
        case :binary.match(new_acc, "\r\n\r\n") do
          {_, _} ->
            {:ok, new_acc}
          :nomatch ->
            # Continue receiving
            recv_handshake_response(socket, new_acc, timeout)
        end

      {:error, reason} ->
        if acc == <<>> do
          {:error, reason}
        else
          # Return what we have so far
          {:ok, acc}
        end
    end
  end

  defp parse_handshake_response(response, key) do
    # Debug logging
    require Logger
    Logger.debug("WebSocket handshake response: #{inspect(response)}")

    # Parse HTTP response manually
    case parse_http_response(response) do
      {:ok, status_code, headers} ->
        Logger.debug("WebSocket handshake status: #{status_code}, headers: #{inspect(headers)}")

        if status_code == 101 do
          # Verify Sec-WebSocket-Accept
          expected_accept =
            :crypto.hash(:sha, key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
            |> :base64.encode()

          accept_header = get_header_value(headers, "sec-websocket-accept", "")

          Logger.debug("WebSocket accept - received: #{accept_header}, expected: #{expected_accept}")

          if accept_header == expected_accept do
            :ok
          else
            {:error, :invalid_accept}
          end
        else
          {:error, {:unexpected_status, status_code}}
        end

      {:error, reason} ->
        Logger.debug("WebSocket handshake parse error: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp parse_http_response(response) do
    # Parse HTTP response line and headers
    # Use String.split to split on ALL \r\n occurrences
    parts = String.split(response, "\r\n", trim: false)

    case parts do
      [status_line | header_lines] ->
        # Parse status line: "HTTP/1.1 101 Switching Protocols"
        # The reason phrase may contain spaces, so we need to handle that
        case String.split(status_line, " ", parts: 3) do
          [_, status_code, _] ->
            {status_int, _} = Integer.parse(status_code)

            # Parse headers
            headers = parse_headers(header_lines, %{})
            {:ok, status_int, headers}

          _ ->
            {:error, :invalid_status_line}
        end

      _ ->
        {:error, :invalid_response}
    end
  end

  defp parse_headers([], acc), do: acc

  defp parse_headers(["" | _], acc), do: acc

  defp parse_headers([line | rest], acc) do
    case String.split(line, ":", parts: 2) do
      [key, value] ->
        key_lower = String.downcase(String.trim(key))
        parse_headers(rest, Map.put(acc, key_lower, String.trim(value)))

      _ ->
        parse_headers(rest, acc)
    end
  end

  defp get_header_value(headers, key, default) do
    Map.get(headers, String.downcase(key), default)
  end

  defp decode_websocket_frames(data, buffer) do
    combined = buffer <> data
    decode_frames(combined, [])
  end

  defp decode_frames(<<>>, acc), do: {:ok, Enum.reverse(acc), <<>>}

  defp decode_frames(data, acc) do
    case decode_single_frame(data) do
      {:ok, frame_payload, remaining} ->
        decode_frames(remaining, [frame_payload | acc])

      {:error, :incomplete} ->
        {:ok, Enum.reverse(acc), data}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_single_frame(<<_fin::1, _rsv1::1, _rsv2::1, _rsv3::1, _opcode::4, mask::1, payload_len::7, rest::binary>>) do
    # Decode payload length - handle both masked (client) and unmasked (server) frames
    # Capture the payload_len from the header instead of discarding it
    Logger.debug("Decoding frame: mask=#{mask}, payload_len=#{payload_len}, rest_size=#{byte_size(rest)}")

    case {mask, payload_len, rest} do
      # Unmasked frame with short payload (< 126) - server-to-client
      {0, pl, data} when pl < 126 and byte_size(data) >= pl ->
        <<payload::binary-size(pl), remaining::binary>> = data
        {:ok, payload, remaining}

      # Unmasked frame with 16-bit extended length - marker is 126
      {0, 126, data} when byte_size(data) >= 2 ->
        <<ext_len::16, rest::binary>> = data
        if byte_size(rest) >= ext_len do
          <<payload::binary-size(ext_len), remaining::binary>> = rest
          {:ok, payload, remaining}
        else
          {:error, :incomplete}
        end

      # Unmasked frame with 64-bit extended length - marker is 127
      {0, 127, data} when byte_size(data) >= 8 ->
        <<ext_len::64, rest::binary>> = data
        if ext_len <= 4_294_967_295 and byte_size(rest) >= ext_len do
          <<payload::binary-size(ext_len), remaining::binary>> = rest
          {:ok, payload, remaining}
        else
          {:error, :incomplete}
        end

      # Masked frame with short payload (< 126) - client-to-server
      {1, pl, data} when pl < 126 and byte_size(data) >= pl + 4 ->
        <<mask_key::32, payload::binary-size(pl), remaining::binary>> = data
        unmasked = unmask_payload(payload, mask_key, <<>>)
        {:ok, unmasked, remaining}

      # Masked frame with 16-bit extended length - marker is 126
      {1, 126, data} when byte_size(data) >= 6 ->
        <<ext_len::16, rest::binary>> = data
        if byte_size(rest) >= ext_len + 4 do
          <<mask_key::32, payload::binary-size(ext_len), remaining::binary>> = rest
          unmasked = unmask_payload(payload, mask_key, <<>>)
          {:ok, unmasked, remaining}
        else
          {:error, :incomplete}
        end

      # Masked frame with 64-bit extended length - marker is 127
      {1, 127, data} when byte_size(data) >= 12 ->
        <<ext_len::64, rest::binary>> = data
        if ext_len <= 4_294_967_295 and byte_size(rest) >= ext_len + 4 do
          <<mask_key::32, payload::binary-size(ext_len), remaining::binary>> = rest
          unmasked = unmask_payload(payload, mask_key, <<>>)
          {:ok, unmasked, remaining}
        else
          {:error, :payload_too_large}
        end

      _ ->
        Logger.debug("Frame incomplete or doesn't match any pattern")
        {:error, :incomplete}
    end
  end

  defp decode_single_frame(_), do: {:error, :incomplete}

  defp unmask_payload(<<>>, _mask_key, acc), do: acc

  defp unmask_payload(<<byte::8, rest::binary>>, <<mask_key::32, remaining_mask::binary>>, acc) do
    unmasked = Bitwise.bxor(byte, mask_key)
    unmask_payload(rest, <<remaining_mask::binary, mask_key::8>>, <<acc::binary, unmasked::8>>)
  end

  defp unmask_payload(<<byte::8, rest::binary>>, <<mask_key::32>>, acc) do
    unmasked = Bitwise.bxor(byte, mask_key)
    <<remaining_mask::24>> = <<mask_key::32>>
    unmask_payload(rest, <<remaining_mask::24>>, <<acc::binary, unmasked::8>>)
  end

  defp extract_iso_messages(frames, prefix_bytes, acc, total_bytes) do
    # Combine all frames into a single buffer and extract ISO messages
    combined_buffer = Enum.join(frames, <<>>)
    extract_from_buffer(combined_buffer, prefix_bytes, acc, total_bytes)
  end

  defp extract_from_buffer(buffer, prefix_bytes, acc, total_bytes) do
    if byte_size(buffer) < prefix_bytes do
      {Enum.reverse(acc), total_bytes}
    else
      <<msg_length::big-integer-size(prefix_bytes * 8), rest::binary>> = buffer

      if byte_size(rest) >= msg_length do
        <<message::binary-size(msg_length), remaining::binary>> = rest
        extract_from_buffer(remaining, prefix_bytes, [message | acc], total_bytes + prefix_bytes + msg_length)
      else
        {Enum.reverse(acc), total_bytes}
      end
    end
  end

  defp encode_websocket_frame(payload) do
    payload_len = byte_size(payload)

    # Generate masking key
    mask_key = :crypto.strong_rand_bytes(4)

    # Mask the payload
    masked_payload = mask_payload(payload, mask_key, <<>>)

    # Binary frame (opcode 2), WITH masking (required for client-to-server)
    # First byte: FIN=1, RSV=0, opcode=2 (binary) -> 0x82
    # Second byte: MASK=1 (0x80) | payload length
    case payload_len do
      len when len < 126 ->
        # MASK bit (0x80) ORed with 7-bit length
        second_byte = 0x80 ||| len
        <<0x82, second_byte, mask_key::binary, masked_payload::binary>>

      len when len <= 65_535 ->
        <<0x82, 0xFE, len::16, mask_key::binary, masked_payload::binary>>

      len ->
        <<0x82, 0xFF, len::64, mask_key::binary, masked_payload::binary>>
    end
  end

  defp mask_payload(<<>>, _mask_key, acc), do: acc

  defp mask_payload(<<byte::8, rest::binary>>, <<mk1, mk2, mk3, mk4>> = mask_key, acc) do
    masked = Bitwise.bxor(byte, mk1)
    # Rotate mask key
    mask_key = <<mk2, mk3, mk4, mk1>>
    mask_payload(rest, mask_key, <<acc::binary, masked>>)
  end

  defp frame_data(data, prefix_bytes) do
    length = byte_size(data)
    <<length::big-integer-size(prefix_bytes * 8), data::binary>>
  end

  defp build_context(state) do
    Context.new(
      transport_ref: :client,
      client_id: "ws_client",
      peer_address: {state.host, state.port},
      transport_metadata: %{
        url: state.url,
        connection_time: state.connection_time,
        bytes_sent: state.bytes_sent,
        bytes_received: state.bytes_received
      }
    )
  end
end

defmodule Iso8583.WebSocket.Registry do
  @moduledoc """
  Registry for WebSocket transport processes.
  """
end
