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

    case Bandit.start_link(bandit_opts) do
      {:ok, pid} ->
        send(state_name, :register)

        {:ok, %__MODULE__{state_name: state_name, path: path, port: port, scheme: scheme, ref: pid}}

      {:error, reason} ->
        {:stop, reason}
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
  """

  import Plug.Conn
  require Logger

  def init(opts) do
    state_name = Keyword.fetch!(opts, :state_name)
    path = Keyword.fetch!(opts, :path)
    {:ok, %{state_name: state_name, path: path}}
  end

  def call(conn, %{state_name: state_name, path: path}) do
    if conn.method == "GET" and conn.request_path == path do
      # Check for WebSocket upgrade request
      case get_req_header(conn, "upgrade") do
        ["websocket"] ->
          handle_websocket_upgrade(conn, state_name)

        _ ->
          send_resp(conn, 426, "Upgrade Required")
          |> put_resp_header("upgrade", "websocket")
      end
    else
      send_resp(conn, 404, "Not found")
    end
  end

  defp handle_websocket_upgrade(conn, state_name) do
    # Get configuration from state
    prefix_bytes = GenServer.call(state_name, :get_prefix_bytes, 5000)

    # Create WebSocket upgrade response
    conn =
      conn
      |> put_resp_header("connection", "upgrade")
      |> put_resp_header("upgrade", "websocket")
      |> put_resp_header("sec-websocket-accept", websocket_accept(conn))
      |> send_resp(101, "")
      |> send_chunked(200)

    # Get peer address from conn
    peer_address = get_peer_address(conn)

    # Get headers
    headers = Enum.into(conn.req_headers, %{})

    # Spawn WebSocket handler process
    {:ok, ws_pid} =
      Iso8583.Transport.WebSocket.Socket.start_link(
        socket: conn,
        state_name: state_name,
        prefix_bytes: prefix_bytes,
        peer_address: peer_address,
        headers: headers
      )

    # Take control of the connection
    Process.flag(:trap_exit, true)

    # Monitor the WebSocket process
    Process.monitor(ws_pid)

    # Wait for WebSocket to terminate
    receive do
      {:DOWN, _ref, :process, ^ws_pid, _reason} ->
        :ok
    end

    conn
  end

  defp websocket_accept(conn) do
    key =
      conn
      |> get_req_header("sec-websocket-key")
      |> List.first()

    if key do
      :base64.encode(key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
      |> :crypto.hash(:sha)
      |> :base64.encode()
    else
      ""
    end
  end

  defp get_peer_address(conn) do
    # Try to get real IP from headers (for proxied requests)
    case get_req_header(conn, "x-forwarded-for") do
      [ip | _] ->
        parse_ip(ip)

      [] ->
        case get_req_header(conn, "x-real-ip") do
          [ip] -> parse_ip(ip)
          [] -> conn.remote_ip
        end
    end
  end

  defp parse_ip(ip_str) when is_binary(ip_str) do
    ip_str
    |> String.to_charlist()
    |> :inet.parse_address()
    |> case do
      {:ok, addr} -> addr
      _ -> {127, 0, 0, 1}
    end
  end

  defp parse_ip(_), do: {127, 0, 0, 1}
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
    :buffer
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def init(opts) do
    conn = Keyword.fetch!(opts, :socket)
    state_name = Keyword.fetch!(opts, :state_name)
    prefix_bytes = Keyword.fetch!(opts, :prefix_bytes)
    peer_address = Keyword.get(opts, :peer_address, {127, 0, 0, 1})
    headers = Keyword.get(opts, :headers, %{})

    # Generate client ID
    client_id = generate_client_id()

    # Take control of the connection
    :gen_tcp.controlling_process(conn.adapter, self())

    # Start receiving
    :erlang.send(self(), :receive)

    {:ok,
     %__MODULE__{
       conn: conn,
       state_name: state_name,
       client_id: client_id,
       peer_address: peer_address,
       prefix_bytes: prefix_bytes,
       headers: headers,
       buffer: <<>>
     }}
  end

  def handle_info(:receive, state) do
    case recv_frame(state) do
      {:ok, data, new_buffer} ->
        if byte_size(data) > 0 do
          # Get callback and process message
          case GenServer.call(state.state_name, :get_callback, 5000) do
            nil ->
              Logger.warning("No callback set for WebSocket message")

            callback ->
              context = build_context(state)
              callback.(data, context)
          end
        end

        :erlang.send(self(), :receive)
        {:noreply, %{state | buffer: new_buffer}}

      {:error, :closed} ->
        Logger.debug("WebSocket client #{state.client_id} disconnected")
        {:stop, :normal, state}

      {:error, reason} ->
        Logger.warning("WebSocket receive error: #{inspect(reason)}")
        {:stop, reason, state}
    end
  end

  def handle_info({:tcp, _port, data}, state) do
    # Append data to buffer
    new_buffer = state.buffer <> data

    # Try to extract complete messages
    case extract_messages(new_buffer, state.prefix_bytes, []) do
      {:ok, messages, remaining_buffer} ->
        # Process each message
        Enum.each(messages, fn data ->
          case GenServer.call(state.state_name, :get_callback, 5000) do
            nil ->
              Logger.warning("No callback set for WebSocket message")

            callback ->
              context = build_context(state)
              callback.(data, context)
          end
        end)

        :erlang.send(self(), :receive)
        {:noreply, %{state | buffer: remaining_buffer}}

      :incomplete ->
        # Need more data
        {:noreply, %{state | buffer: new_buffer}}
    end
  end

  def handle_info({:tcp_closed, _port}, state) do
    {:stop, :normal, state}
  end

  def handle_info({:tcp_error, _port, reason}, state) do
    {:stop, reason, state}
  end

  def terminate(_reason, state) do
    if state.conn do
      # Close the underlying socket
      :gen_tcp.close(state.conn.adapter)
    end

    :ok
  end

  @doc """
  Sends framed data to the WebSocket client.
  """
  def send(%__MODULE__{} = socket, data) do
    framed = Iso8583.Transport.WebSocket.encode_framed(data, socket.prefix_bytes)

    case Plug.Conn.chunk(socket.conn, framed) do
      {:ok, _conn} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Private functions

  defp recv_frame(state) do
    case :gen_tcp.recv(state.conn.adapter, 0, 60_000) do
      {:ok, data} ->
        new_buffer = state.buffer <> data
        extract_single_message(new_buffer, state.prefix_bytes)

      {:error, :closed} ->
        {:error, :closed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_single_message(buffer, prefix_bytes) do
    case Iso8583.Transport.WebSocket.decode_framed(buffer, prefix_bytes) do
      {:ok, message, remaining} ->
        {:ok, message, remaining}

      :incomplete ->
        {:ok, <<>>, buffer}
    end
  end

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

defmodule Iso8583.WebSocket.Registry do
  @moduledoc """
  Registry for WebSocket transport processes.
  """
end
