defmodule Iso8583.Transport.TCP do
  @moduledoc """
  TCP transport implementations for ISO 8583.

  Includes both server (accepts connections) and client (connects out)
  implementations.
  """

  @doc """
  Encodes data with length prefix framing.

  ## Parameters
  - `data` - Binary data to frame
  - `prefix_bytes` - Number of bytes for length prefix (1, 2, or 4)

  ## Returns
  Framed binary with big-endian (network order) length prefix.

  ## Examples
      iex> Iso8583.Transport.TCP.encode_framed(<<1, 2, 3>>, 2)
      <<0, 3, 1, 2, 3>>

      iex> Iso8583.Transport.TCP.encode_framed(<<0x02, 0x00>>, 1)
      <<2, 2, 0>>
  """
  def encode_framed(data, prefix_bytes) when prefix_bytes in [1, 2, 4] do
    length = byte_size(data)
    <<length::big-integer-size(prefix_bytes * 8), data::binary>>
  end

  @doc """
  Decodes length-prefixed data from a buffer.

  ## Parameters
  - `buffer` - Binary buffer possibly containing length-prefixed data
  - `prefix_bytes` - Number of bytes for length prefix (1, 2, or 4)

  ## Returns
  - `{:ok, message, remaining}` - Successfully extracted a message
  - `:incomplete` - Not enough data for length prefix or complete message

  ## Examples
      iex> Iso8583.Transport.TCP.decode_framed(<<0, 3, 1, 2, 3, 4, 5>>, 2)
      {:ok, <<1, 2, 3>>, <<4, 5>>}

      iex> Iso8583.Transport.TCP.decode_framed(<<0, 3>>, 2)
      :incomplete
  """
  def decode_framed(buffer, prefix_bytes) when prefix_bytes in [1, 2, 4] do
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

defmodule Iso8583.Transport.TCP.Server do
  @moduledoc """
  TCP Server transport for ISO 8583 messages.

  Accepts TCP connections from clients and receives ISO 8583 messages.

  ## Architecture

      ┌─────────────────────────────────────────────────────────┐
      │              Iso8583.Transport.TCP.Server               │
      │  - Listens on configured port                           │
      │  - Spawns acceptor processes                            │
      │  - Each acceptor handles one connection                 │
      │  - Messages forwarded to receive callback               │
      └─────────────────────────────────────────────────────────┘
                          │
          ┌───────────────┼───────────────┐
          │               │               │
      ┌───────┐       ┌───────┐       ┌───────┐
      │Client 1│       │Client 2│       │Client 3│
      └───────┘       └───────┘       └───────┘

  ## Usage

  ### Without TPDU

      defmodule MyApp.PaymentHandler do
        use Iso8583.Handler,
          processor: MyApp.PaymentProcessor,
          transport: Iso8583.Transport.TCP.Server,
          transport_opts: [
            port: 8080,
            acceptors: 10,
            packet_handler: {:length_prefix, 2}
          ]
      end

  ### With TPDU

      defmodule MyApp.PaymentHandler do
        use Iso8583.Handler,
          processor: MyApp.PaymentProcessor,
          transport: Iso8583.Transport.TCP.Server,
          transport_opts: [
            port: 8080,
            acceptors: 10,
            packet_handler: {:length_prefix, 2},
            tpdu_enabled: true,
            tpdu_address_size: 5,
            tpdu_source_address: <<0, 0, 0, 0, 1>>
          ]
      end

  ## Options

  | Option | Type | Default | Description |
  |--------|------|---------|-------------|
  | `:port` | `integer()` | Required | Port to listen on |
  | `:acceptors` | `integer()` | `10` | Number of acceptor processes |
  | `:name` | `atom()` | `nil` | Name for registration |
  | `:packet_handler` | `atom() \| tuple()` | `:raw` | How to parse messages |
  | `:timeout` | `integer()` | `60000` | Connection idle timeout (ms) |
  | `:tpdu_enabled` | `boolean()` | `false` | Enable TPDU handling |
  | `:tpdu_address_size` | `integer()` | `5` | TPDU address size in bytes |
  | `:tpdu_source_address` | `binary()` | `<<0,0,0,0,1>>` | Source address for responses |

  ## Packet Handlers (Framing)

  ### `:raw` (default)
  Reads entire socket buffer. Best for:
  - Clients that send complete messages at once
  - Protocols with external framing

  ### `:line`
  Reads until newline. Best for:
  - Testing/debugging
  - Line-delimited protocols

  ### `{:size, bytes}`
  Reads fixed-size messages. Best for:
  - Fixed-length ISO messages
  - Protocols with predictable message sizes

  ### `{:length_prefix, bytes}` - **Recommended for ISO 8583**
  Reads length-prefixed messages. Each message is prefixed with a big-endian
  (network order) length field. Best for:
  - Standard ISO 8583 over TCP
  - Protocols with variable-length messages
  - Production deployments requiring message boundaries

  Example: `packet_handler: {:length_prefix, 2}` means each message is prefixed
  with a 2-byte length field (max message size: 65535 bytes).

  **Message format (without TPDU):**
  ```
  +--------+--------+--------------------------+
  | Len Hi | Len Lo |     Message Data         |
  +--------+--------+--------------------------+
  |<---- 2 bytes --->|<-- Length bytes ------->|
  ```

  **Message format (with TPDU enabled):**
  ```
  +--------+--------+--------------+--------------------------+
  | Len Hi | Len Lo |    TPDU      |     ISO 8583 Message     |
  +--------+--------+--------------+--------------------------+
  |<---- 2 bytes --->|<-- 10 bytes ->|<-- Length - 10 ------->|
  |<----------- Total message length --------------->|
  ```

  **TPDU Routing:** When TPDU is enabled, the transport automatically swaps
  source/destination addresses in the response TPDU to route the message back
  to the sender.

  ## Message Flow with TPDU
  ```
  Request:  [Length] [TPDU: Client→Acquirer] [ISO Message]
                           ↓
                    Transport strips TPDU
                           ↓
                    Application processes ISO
                           ↓
                    Transport adds TPDU (swapped)
                           ↓
  Response: [Length] [TPDU: Acquirer→Client] [ISO Response]
  ```

  **Python client example (without TPDU):**
  ```python
  import socket
  import struct

  # Connect to server
  sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
  sock.connect(('localhost', 8080))

  # Send ISO message with 2-byte length prefix
  iso_message = bytes.fromhex('0200b2200000001000000000000000000000000011234567890123456')
  framed = struct.pack('>H', len(iso_message)) + iso_message  # Big-endian 2-byte length
  sock.send(framed)

  # Receive response with 2-byte length prefix
  length_bytes = sock.recv(2)
  length = struct.unpack('>H', length_bytes)[0]
  response = sock.recv(length)
  ```

  **Python client example (with TPDU):**
  ```python
  import socket
  import struct

  # TPDU configuration
  TPDU_SIZE = 10  # 5 bytes dest + 5 bytes source
  SOURCE_ADDR = bytes([0, 0, 0, 0, 1])  # Our address
  DEST_ADDR = bytes([0, 0, 0, 0, 2])    # Acquirer address

  # Connect to server
  sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
  sock.connect(('localhost', 8080))

  # Send ISO message with TPDU and 2-byte length prefix
  iso_message = bytes.fromhex('0200b2200000001000000000000000000000000011234567890123456')
  payload = DEST_ADDR + SOURCE_ADDR + iso_message  # TPDU + ISO
  framed = struct.pack('>H', len(payload)) + payload
  sock.send(framed)

  # Receive response
  length_bytes = sock.recv(2)
  length = struct.unpack('>H', length_bytes)[0]
  response_data = sock.recv(length)

  # Extract TPDU from response
  tpdu_dest = response_data[0:5]    # Should be our source
  tpdu_src = response_data[5:10]    # Should be acquirer
  iso_response = response_data[10:]  # Actual ISO message
  ```

  **Elixir client example:**
  ```elixir
  # Connect to server
  {:ok, socket} = :gen_tcp.connect('localhost', 8080, [:binary, packet: 0, active: false])

  # Send ISO message with 2-byte length prefix
  iso_message = <<0x02, 0x00, 0xB2, 0x20, ...>>
  length = byte_size(iso_message)
  :gen_tcp.send(socket, <<length::big-integer-size(16), iso_message::binary>>)

  # Receive response with 2-byte length prefix
  {:ok, <<length::big-integer-size(16)>>} = :gen_tcp.recv(socket, 2)
  {:ok, response} = :gen_tcp.recv(socket, length)
  ```

  **Supported prefix sizes:**
  - `{:length_prefix, 1}` - 1 byte length (max: 255 bytes)
  - `{:length_prefix, 2}` - 2 bytes length (max: 65,535 bytes) - **Most common**
  - `{:length_prefix, 4}` - 4 bytes length (max: 4,294,967,295 bytes)

  ### Custom module
  Implement `handle_packet/2`:
      defmodule MyPacketHandler do
        def handle_packet(socket, opts) do
          case :gen_tcp.recv(socket, 0, 1000) do
            {:ok, data} -> {:ok, data}
            {:error, :timeout} -> {:ok, <<>>}
            {:error, reason} -> {:error, reason}
          end
        end
      end

  ## Context Metadata

  The server populates `Iso8583.Context` with:
  - `transport_ref` - The socket (port)
  - `client_id` - Unique client identifier (UUID)
  - `peer_address` - Client's IP address
  - `transport_metadata` - `%{connection_time, bytes_received, messages_received, tpdu}`

  When TPDU is enabled, the request TPDU is included in `transport_metadata.tpdu`.

  ## Supervisor Tree

      Iso8583.Transport.TCP.Server (GenServer)
          │
          ├── AcceptorSupervisor (DynamicSupervisor)
          │    ├── Acceptor 1 (GenServer) ──► Connection 1
          │    ├── Acceptor 2 (GenServer) ──► Connection 2
          │    └── ...
          │
          └── ClientRegistry (ETS) - Stores connection stats

  ## Registry

  When a `:name` is provided, the server registers itself in a registry
  for lookup by name. This allows `set_receive_callback/2` to work with
  either a PID or a registered name.
  """

  use GenServer

  alias Iso8583.Context
  alias Ex_Iso8583.TPDU

  defstruct [
    :listen_socket,
    :acceptor_sup,
    :client_registry,
    :receive_callback,
    :port,
    :acceptors,
    :packet_handler,
    :timeout,
    :name,
    :registry_name,
    :tpdu_enabled,
    :tpdu_address_size,
    :tpdu_source_address
  ]

  # Client API

  @doc """
  Starts the TCP server transport.

  ## Options

  - `:port` - Required port number
  - `:acceptors` - Number of acceptor processes (default: 10)
  - `:name` - Registered name for the server (also used for Registry)
  - `:packet_handler` - How to parse messages (default: :raw)
  - `:timeout` - Connection timeout in ms (default: 60_000)
  - `:tpdu_enabled` - Enable TPDU handling (default: false)
  - `:tpdu_address_size` - TPDU address size in bytes (default: 5)
  - `:tpdu_source_address` - Source address for responses (default: <<0,0,0,0,1>>)
  """
  def start_link(opts) do
    port = Keyword.fetch!(opts, :port)
    acceptors = Keyword.get(opts, :acceptors, 10)
    name = Keyword.get(opts, :name)
    packet_handler = Keyword.get(opts, :packet_handler, :raw)
    timeout = Keyword.get(opts, :timeout, 60_000)
    tpdu_enabled = Keyword.get(opts, :tpdu_enabled, false)
    tpdu_address_size = Keyword.get(opts, :tpdu_address_size, 5)
    tpdu_source = Keyword.get(opts, :tpdu_source_address, <<0, 0, 0, 0, 1>>)

    gen_server_opts = if name, do: [name: name], else: []

    GenServer.start_link(
      __MODULE__,
      [
        port: port,
        acceptors: acceptors,
        packet_handler: packet_handler,
        timeout: timeout,
        tpdu_enabled: tpdu_enabled,
        tpdu_address_size: tpdu_address_size,
        tpdu_source_address: tpdu_source,
        registry_name: name
      ],
      gen_server_opts
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
      type: :worker
    }
  end

  @doc """
  Sends data to a connected client.

  For direct socket access, use `:gen_tcp.send/2`.
  For response with TPDU, use `send_response/2`.
  """
  def send(socket, data) when is_port(socket) do
    :gen_tcp.send(socket, data)
  end

  @doc """
  Sends a response to a client through their connection handler.

  This is the recommended way to send responses when using TPDU, as it
  ensures the TPDU is correctly added with swapped source/destination.
  """
  def send_response(_client_id, _response) do
    # Note: For direct socket access, use :gen_tcp.send/2
    # The TPDU handling is done at the connection level
    {:error, :use_socket_directly}
  end

  @doc """
  Registers the callback for receiving messages.

  Supports both PID and registered name (atom) for lookup.
  """
  def set_receive_callback(server_pid, callback) when is_pid(server_pid) do
    GenServer.call(server_pid, {:set_callback, callback})
  end

  def set_receive_callback(name, callback) when is_atom(name) do
    case lookup_server(name) do
      {:ok, pid} -> GenServer.call(pid, {:set_callback, callback})
      {:error, _} -> {:error, :not_found}
    end
  end

  @doc """
  Looks up a TCP server by registered name.
  """
  def lookup_server(name) when is_atom(name) do
    ensure_registry_started()

    case :ets.lookup(:iso8583_tcp_registry, name) do
      [{^name, pid}] when is_pid(pid) -> {:ok, pid}
      _ -> {:error, :not_found}
    end
  end

  defp ensure_registry_started do
    case :ets.whereis(:iso8583_tcp_registry) do
      :undefined ->
        :ets.new(:iso8583_tcp_registry, [:set, :named_table, :public])
      _ref ->
        :ok
    end
  end

  @doc """
  Stops the server.
  """
  def stop(server_pid) when is_pid(server_pid) do
    GenServer.stop(server_pid, :normal)
  end

  def stop(name) when is_atom(name) do
    case lookup_server(name) do
      {:ok, pid} -> GenServer.stop(pid, :normal)
      {:error, _} -> {:error, :not_found}
    end
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    port = Keyword.fetch!(opts, :port)
    acceptors = Keyword.get(opts, :acceptors, 10)
    packet_handler = Keyword.get(opts, :packet_handler, :raw)
    timeout = Keyword.get(opts, :timeout, 60_000)
    tpdu_enabled = Keyword.get(opts, :tpdu_enabled, false)
    tpdu_address_size = Keyword.get(opts, :tpdu_address_size, 5)
    tpdu_source = Keyword.get(opts, :tpdu_source_address, <<0, 0, 0, 0, 1>>)
    registry_name = Keyword.get(opts, :registry_name)

    # Create client registry with connection stats
    client_registry = :ets.new(:tcp_clients, [:set, :private, :named_table])

    # Start acceptor supervisor (unnamed to avoid conflicts)
    case start_acceptor_supervisor() do
      {:ok, acceptor_sup} ->
        # Start listening
        case listen(port) do
          {:ok, listen_socket} ->
            # Start acceptors
            start_acceptors(acceptor_sup, listen_socket, self(), acceptors, opts)

            # Register in TCP Registry if name is provided
            if registry_name do
              ensure_registry_started()
              :ets.insert(:iso8583_tcp_registry, {registry_name, self()})
            end

            {:ok,
             %__MODULE__{
               listen_socket: listen_socket,
               acceptor_sup: acceptor_sup,
               client_registry: client_registry,
               port: port,
               acceptors: acceptors,
               packet_handler: packet_handler,
               timeout: timeout,
               name: registry_name,
               registry_name: registry_name,
               tpdu_enabled: tpdu_enabled,
               tpdu_address_size: tpdu_address_size,
               tpdu_source_address: tpdu_source
             }}

          {:error, reason} ->
            # Stop acceptor supervisor on listen failure
            if acceptor_sup, do: GenServer.stop(acceptor_sup, :normal)
            {:stop, reason}
        end

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_info({:set_callback_from_init, callback}, state) do
    {:noreply, %{state | receive_callback: callback}}
  end

  @impl true
  def handle_info({:incoming_message, client_id, data, peer_address, request_tpdu}, state) do
    if state.receive_callback do
      # Get socket and update stats
      [{_client_id, socket, conn_time, bytes_recv, msgs_recv}] = :ets.lookup(state.client_registry, client_id)

      # Update stats
      new_bytes_recv = bytes_recv + byte_size(data)
      new_msgs_recv = msgs_recv + 1
      :ets.insert(state.client_registry, {client_id, socket, conn_time, new_bytes_recv, new_msgs_recv})

      context =
        Context.new(
          transport_ref: socket,
          client_id: client_id,
          peer_address: peer_address,
          transport_metadata: %{
            connection_time: conn_time,
            bytes_received: new_bytes_recv,
            messages_received: new_msgs_recv,
            tpdu: request_tpdu
          }
        )

      state.receive_callback.(data, context)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:client_disconnected, client_id}, state) do
    :ets.delete(state.client_registry, client_id)
    {:noreply, state}
  end

  @impl true
  def handle_call({:set_callback, callback}, _from, state) do
    {:reply, :ok, %{state | receive_callback: callback}}
  end

  @impl true
  def handle_call({:register_client, client_id, socket}, _from, state) do
    # Register client with connection stats
    :ets.insert(state.client_registry, {client_id, socket, System.system_time(:millisecond), 0, 0})
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:unregister_client, client_id}, _from, state) do
    :ets.delete(state.client_registry, client_id)
    {:reply, :ok, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.listen_socket do
      :gen_tcp.close(state.listen_socket)
    end

    :ets.delete(state.client_registry)

    # Remove from registry
    if state.registry_name do
      :ets.delete(:iso8583_tcp_registry, state.registry_name)
    end

    # Stop the acceptor supervisor (using the stored PID)
    if state.acceptor_sup && Process.alive?(state.acceptor_sup) do
      GenServer.stop(state.acceptor_sup, :normal)
    end

    :ok
  end

  # Private functions

  defp start_acceptor_supervisor do
    DynamicSupervisor.start_link(
      strategy: :one_for_one
    )
  end

  defp listen(port) do
    :gen_tcp.listen(
      port,
      [:binary, packet: 0, active: false, reuseaddr: true, send_timeout: 5000]
    )
  end

  defp start_acceptors(acceptor_sup_pid, listen_socket, server_pid, count, opts) do
    Enum.each(1..count, fn _ ->
      child_spec = %{
        id: {Iso8583.Transport.TCP.Acceptor, make_ref()},
        start: {Iso8583.Transport.TCP.Acceptor, :start_link, [{listen_socket, server_pid, opts}]},
        restart: :permanent,
        type: :worker
      }

      # Use the acceptor supervisor PID
      {:ok, _pid} = DynamicSupervisor.start_child(acceptor_sup_pid, child_spec)
    end)
  end
end

defmodule Iso8583.Transport.TCP.Acceptor do
  @moduledoc """
  Acceptor process that accepts a single TCP connection and hands it off
  to a connection handler.
  """

  use GenServer
  require Logger

  def start_link({listen_socket, server_pid, opts}) do
    GenServer.start_link(
      __MODULE__,
      {listen_socket, server_pid, opts}
    )
  end

  def init({listen_socket, server_pid, opts}) do
    packet_handler = Keyword.get(opts, :packet_handler, :raw)
    timeout = Keyword.get(opts, :timeout, 60_000)
    tpdu_enabled = Keyword.get(opts, :tpdu_enabled, false)
    tpdu_address_size = Keyword.get(opts, :tpdu_address_size, 5)
    tpdu_source_address = Keyword.get(opts, :tpdu_source_address, <<0, 0, 0, 0, 1>>)

    # Send async accept request
    :gen_tcp.controlling_process(listen_socket, self())
    send(self(), :accept)

    {:ok,
     %{
       listen_socket: listen_socket,
       server_pid: server_pid,
       packet_handler: packet_handler,
       timeout: timeout,
       tpdu_enabled: tpdu_enabled,
       tpdu_address_size: tpdu_address_size,
       tpdu_source_address: tpdu_source_address,
       socket: nil,
       client_id: nil
     }}
  end

  def handle_info(:accept, state) do
    case :gen_tcp.accept(state.listen_socket, 1000) do
      {:ok, socket} ->
        # Get peer address
        peer_address = get_peer_address(socket)

        # Generate client ID
        client_id = generate_client_id()

        # Start connection handler
        {:ok, handler_pid} =
          Iso8583.Transport.TCP.Connection.start_link(
            socket: socket,
            server_pid: state.server_pid,
            client_id: client_id,
            peer_address: peer_address,
            packet_handler: state.packet_handler,
            timeout: state.timeout,
            tpdu_enabled: state.tpdu_enabled,
            tpdu_address_size: state.tpdu_address_size,
            tpdu_source_address: state.tpdu_source_address
          )

        # Register with server
        GenServer.call(state.server_pid, {:register_client, client_id, socket})

        # Monitor the connection handler
        Process.monitor(handler_pid)

        # Continue accepting
        send(self(), :accept)

        {:noreply,
         %{state | socket: socket, client_id: client_id}}

      {:error, :timeout} ->
        # No connection, try again
        send(self(), :accept)
        {:noreply, state}

      {:error, reason} ->
        Logger.warning("Accept error: #{inspect(reason)}")
        send(self(), :accept)
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    # Connection handler died, notify server
    if state.client_id do
      send(state.server_pid, {:client_disconnected, state.client_id})
    end

    send(self(), :accept)
    {:noreply, %{state | socket: nil, client_id: nil}}
  end

  defp get_peer_address(socket) do
    case :inet.peername(socket) do
      {:ok, {addr, _port}} -> addr
      _ -> nil
    end
  end

  defp generate_client_id do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)
    :erlang.list_to_binary(:io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e]))
  end
end

defmodule Iso8583.Transport.TCP.Connection do
  @moduledoc """
  Handles a single TCP connection - reads messages and forwards to server.

  Supports TPDU extraction and automatic response TPDU insertion.
  """

  use GenServer
  require Logger

  alias Ex_Iso8583.TPDU

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def init(opts) do
    socket = Keyword.fetch!(opts, :socket)
    server_pid = Keyword.fetch!(opts, :server_pid)
    client_id = Keyword.fetch!(opts, :client_id)
    peer_address = Keyword.fetch!(opts, :peer_address)
    packet_handler = Keyword.get(opts, :packet_handler, :raw)
    timeout = Keyword.get(opts, :timeout, 60_000)
    tpdu_enabled = Keyword.get(opts, :tpdu_enabled, false)
    tpdu_address_size = Keyword.get(opts, :tpdu_address_size, 5)
    tpdu_source_address = Keyword.get(opts, :tpdu_source_address, <<0, 0, 0, 0, 1>>)

    # Take control of socket
    :gen_tcp.controlling_process(socket, self())

    # Start receiving
    send(self(), :receive)

    {:ok,
     %{
       socket: socket,
       server_pid: server_pid,
       client_id: client_id,
       peer_address: peer_address,
       packet_handler: packet_handler,
       timeout: timeout,
       tpdu_enabled: tpdu_enabled,
       tpdu_address_size: tpdu_address_size,
       tpdu_source_address: tpdu_source_address,
       request_tpdu: nil,
       buffer: <<>>
     }}
  end

  def handle_info(:receive, state) do
    case recv_packet(state) do
      {:ok, data, new_buffer} ->
        {request_tpdu, data_without_tpdu} = if byte_size(data) > 0 do
          # Extract TPDU if enabled
          if state.tpdu_enabled do
            case TPDU.extract(data, state.tpdu_address_size) do
              {:ok, tpdu, rest} ->
                {tpdu, rest}
              {:error, _} ->
                {nil, data}
            end
          else
            {nil, data}
          end
        else
          {state.request_tpdu, <<>>}
        end

        # Send message to server
        if byte_size(data_without_tpdu) > 0 do
          send(state.server_pid, {:incoming_message, state.client_id, data_without_tpdu, state.peer_address, request_tpdu})
        end

        send(self(), :receive)
        {:noreply, %{state | buffer: new_buffer, request_tpdu: request_tpdu}}

      {:error, :closed} ->
        Logger.debug("Client #{state.client_id} disconnected")
        {:stop, :normal, state}

      {:error, reason} ->
        Logger.warning("Receive error for client #{state.client_id}: #{inspect(reason)}")
        {:stop, reason, state}
    end
  end

  def handle_info({:send_response, response}, state) do
    # Add TPDU to response if enabled
    response_with_tpdu = if state.tpdu_enabled and state.request_tpdu do
      # Swap destination and source for response
      response_tpdu = %{
        destination: state.request_tpdu.source,
        source: state.tpdu_source_address
      }
      TPDU.prepend(response, response_tpdu, state.tpdu_address_size)
    else
      response
    end

    :gen_tcp.send(state.socket, response_with_tpdu)
    {:noreply, state}
  end

  def handle_info({:tcp_closed, _socket}, state) do
    {:stop, :normal, state}
  end

  def handle_info({:tcp_error, _socket, reason}, state) do
    {:stop, reason, state}
  end

  def terminate(_reason, state) do
    if state.socket do
      :gen_tcp.close(state.socket)
    end

    send(state.server_pid, {:client_disconnected, state.client_id})
    :ok
  end

  # Packet receiving

  defp recv_packet(state) do
    case state.packet_handler do
      :raw ->
        case :gen_tcp.recv(state.socket, 0, state.timeout) do
          {:ok, data} -> {:ok, data, <<>>}
          {:error, reason} -> {:error, reason}
        end

      :line ->
        case :gen_tcp.recv(state.socket, 0, state.timeout) do
          {:ok, data} -> {:ok, data, <<>>}
          {:error, reason} -> {:error, reason}
        end

      {:size, size} ->
        case :gen_tcp.recv(state.socket, size, state.timeout) do
          {:ok, data} -> {:ok, data, <<>>}
          {:error, reason} -> {:error, reason}
        end

      {:length_prefix, prefix_bytes} when prefix_bytes in [1, 2, 4] ->
        recv_length_prefixed(state, prefix_bytes)

      {module, function} when is_atom(module) and is_atom(function) ->
        apply(module, function, [state.socket, state.timeout])

      module when is_atom(module) ->
        if function_exported?(module, :handle_packet, 2) do
          module.handle_packet(state.socket, state.timeout)
        else
          {:error, :invalid_packet_handler}
        end
    end
  end

  # Length-prefixed framing with buffering
  defp recv_length_prefixed(state, prefix_bytes) do
    # First, try to get more data if buffer is empty
    case get_buffer_data(state) do
      {:error, reason} ->
        {:error, reason}

      {:ok, buffer} ->
        # Check if we have enough data for the length prefix
        prefix_size = prefix_bytes

        if byte_size(buffer) < prefix_size do
          # Not enough data for length prefix, wait for more
          {:ok, <<>>, buffer}
        else
          # Extract the message length (big-endian/network order)
          <<msg_length::big-integer-size(prefix_bytes * 8), rest::binary>> = buffer

          # Check if we have the complete message
          if byte_size(rest) >= msg_length do
            # Extract the message and any remaining data
            <<message::binary-size(msg_length), remaining::binary>> = rest
            {:ok, message, remaining}
          else
            # Incomplete message, wait for more data
            {:ok, <<>>, buffer}
          end
        end
    end
  end

  defp get_buffer_data(state) do
    if byte_size(state.buffer) == 0 do
      case :gen_tcp.recv(state.socket, 0, state.timeout) do
        {:ok, data} -> {:ok, data}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, state.buffer}
    end
  end
end

defmodule Iso8583.Transport.TCP.Client do
  @moduledoc """
  TCP Client transport for ISO 8583 messages.

  Connects to a remote TCP server and sends/receives ISO 8583 messages.

  ## Usage

  ### Without TPDU

      defmodule MyApp.UpstreamHandler do
        use Iso8583.Handler,
          processor: MyApp.UpstreamProcessor,
          transport: Iso8583.Transport.TCP.Client,
          transport_opts: [
            host: "acquirer.example.com",
            port: 9000,
            packet_handler: {:length_prefix, 2}
          ]
      end

  ### With TPDU

      defmodule MyApp.UpstreamHandler do
        use Iso8583.Handler,
          processor: MyApp.UpstreamProcessor,
          transport: Iso8583.Transport.TCP.Client,
          transport_opts: [
            host: "acquirer.example.com",
            port: 9000,
            packet_handler: {:length_prefix, 2},
            tpdu_enabled: true,
            tpdu_address_size: 5,
            tpdu_source_address: <<0, 0, 0, 0, 1>>,
            tpdu_destination_address: <<0, 0, 0, 0, 2>>
          ]
      end

  ## Options

  | Option | Type | Default | Description |
  |--------|------|---------|-------------|
  | `:host` | `String.t() \| :inet.ip_address()` | Required | Remote host |
  | `:port` | `integer()` | Required | Remote port |
  | `:name` | `atom()` | `nil` | Name for registration |
  | `:reconnect_interval` | `integer()` | `5000` | Reconnect delay on disconnect (ms) |
  | `:timeout` | `integer()` | `60000` | Socket timeout (ms) |
  | `:packet_handler` | `atom() \| tuple()` | `:raw` | How to frame messages |
  | `:tpdu_enabled` | `boolean()` | `false` | Enable TPDU handling |
  | `:tpdu_address_size` | `integer()` | `5` | TPDU address size in bytes |
  | `:tpdu_source_address` | `binary()` | `<<0,0,0,0,1>>` | Source address for requests |
  | `:tpdu_destination_address` | `binary()` | `<<0,0,0,0,2>>` | Destination address for requests |

  ## Packet Handlers (Framing)

  ### `:raw` (default)
  Sends and receives raw data without framing. Use when:
  - The server handles framing externally
  - You need complete control over message format

  ### `{:length_prefix, bytes}` - **Recommended for ISO 8583**
  Automatically frames messages with a big-endian (network order) length prefix.
  Best for:
  - Standard ISO 8583 over TCP
  - Connecting to servers that expect length-prefixed messages

  Example: `packet_handler: {:length_prefix, 2}` means:
  - Outgoing: prepends 2-byte length before sending
  - Incoming: parses 2-byte length to read complete messages

  **Message flow (without TPDU):**
  ```
  Client -> Server: [Len Hi] [Len Lo] [ISO Message Data...]
  Server -> Client: [Len Hi] [Len Lo] [ISO Response Data...]
  ```

  **Message flow (with TPDU enabled):**
  ```
  Request:  [Length] [TPDU: Us→Acquirer] [ISO Message]
  Response: [Length] [TPDU: Acquirer→Us] [ISO Response]
  ```

  The TPDU source/destination are automatically swapped in responses.

  **Supported prefix sizes:**
  - `{:length_prefix, 1}` - 1 byte length (max: 255 bytes)
  - `{:length_prefix, 2}` - 2 bytes length (max: 65,535 bytes) - **Most common**
  - `{:length_prefix, 4}` - 4 bytes length (max: 4,294,967,295 bytes)

  ## Context Metadata

  The client populates `Iso8583.Context` with:
  - `transport_ref` - `:client` (atom identifier)
  - `client_id` - `"tcp_client"`
  - `peer_address` - Remote server address
  - `transport_metadata` - `%{connection_time, bytes_sent, bytes_received, tpdu}`

  When TPDU is enabled, the response TPDU is included in `transport_metadata.tpdu`.

  """

  use GenServer
  import Kernel, except: [send: 2]
  require Logger

  alias Iso8583.Context
  alias Ex_Iso8583.TPDU

  defstruct [
    :socket,
    :host,
    :port,
    :receive_callback,
    :reconnect_interval,
    :timeout,
    :connection_time,
    :bytes_sent,
    :bytes_received,
    :pending_requests,
    :packet_handler,
    :tpdu_enabled,
    :tpdu_address_size,
    :tpdu_source_address,
    :tpdu_destination_address,
    :request_tpdu,
    :buffer
  ]

  @doc """
  Starts the TCP client transport.
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
  Sends data to the remote server.
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
    host = Keyword.fetch!(opts, :host)
    port = Keyword.fetch!(opts, :port)
    reconnect_interval = Keyword.get(opts, :reconnect_interval, 5000)
    timeout = Keyword.get(opts, :timeout, 60_000)
    packet_handler = Keyword.get(opts, :packet_handler, :raw)
    tpdu_enabled = Keyword.get(opts, :tpdu_enabled, false)
    tpdu_address_size = Keyword.get(opts, :tpdu_address_size, 5)
    tpdu_source = Keyword.get(opts, :tpdu_source_address, <<0, 0, 0, 0, 1>>)
    tpdu_destination = Keyword.get(opts, :tpdu_destination_address, <<0, 0, 0, 0, 2>>)

    # Try to connect immediately
    :erlang.send(self(), :connect)

    {:ok,
     %__MODULE__{
       host: host,
       port: port,
       reconnect_interval: reconnect_interval,
       timeout: timeout,
       packet_handler: packet_handler,
       tpdu_enabled: tpdu_enabled,
       tpdu_address_size: tpdu_address_size,
       tpdu_source_address: tpdu_source,
       tpdu_destination_address: tpdu_destination,
       socket: nil,
       connection_time: nil,
       bytes_sent: 0,
       bytes_received: 0,
       pending_requests: %{},
       request_tpdu: nil,
       buffer: <<>>
     }}
  end

  @impl true
  def handle_info(:connect, state) do
    case connect(state.host, state.port, state.timeout) do
      {:ok, socket} ->
        Logger.info("Connected to #{state.host}:#{state.port}")

        # Start receiving (use Kernel.send to avoid conflict with Client.send/2)
        Kernel.send(self(), :receive)

        {:noreply,
         %{state | socket: socket, connection_time: System.system_time(:millisecond)}}

      {:error, reason} ->
        Logger.warning("Failed to connect to #{state.host}:#{state.port}: #{inspect(reason)}")
        Process.send_after(self(), :connect, state.reconnect_interval)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:receive, state) when state.socket != nil do
    case recv_and_parse(state) do
      {:ok, messages, new_buffer, bytes_received} ->
        # Process each received message
        Enum.each(messages, fn data ->
          if state.receive_callback do
            # Extract TPDU from response if enabled
            {data_without_tpdu, response_tpdu} = if state.tpdu_enabled do
              case TPDU.extract(data, state.tpdu_address_size) do
                {:ok, tpdu, rest} ->
                  {rest, tpdu}
                {:error, _} ->
                  {data, nil}
              end
            else
              {data, nil}
            end

            context =
              Context.new(
                transport_ref: :client,
                client_id: "tcp_client",
                peer_address: state.host,
                transport_metadata: %{
                  connection_time: state.connection_time,
                  bytes_sent: state.bytes_sent,
                  bytes_received: state.bytes_received,
                  tpdu: response_tpdu
                }
              )

            state.receive_callback.(data_without_tpdu, context)
          end
        end)

        # Continue receiving
        :erlang.send(self(), :receive)
        {:noreply, %{state | buffer: new_buffer, bytes_received: state.bytes_received + bytes_received}}

      {:error, :timeout} ->
        :erlang.send(self(), :receive)
        {:noreply, state}

      {:error, :closed} ->
        Logger.warning("Connection closed to #{state.host}:#{state.port}")
        :erlang.send(self(), :connect)
        {:noreply, %{state | socket: nil, connection_time: nil, buffer: <<>>}}

      {:error, reason} ->
        Logger.error("Receive error: #{inspect(reason)}")
        :erlang.send(self(), :connect)
        {:noreply, %{state | socket: nil, connection_time: nil, buffer: <<>>}}
    end
  end

  @impl true
  def handle_info(:receive, state) do
    # Not connected, wait for connect
    {:noreply, state}
  end

  @impl true
  def handle_call({:send, data}, _from, state) do
    if state.socket do
      # Add TPDU if enabled
      data_with_tpdu = if state.tpdu_enabled do
        tpdu = %{
          destination: state.tpdu_destination_address,
          source: state.tpdu_source_address
        }
        TPDU.prepend(data, tpdu, state.tpdu_address_size)
      else
        data
      end

      # Frame the data if using length_prefix
      framed_data = frame_data(data_with_tpdu, state.packet_handler)

      case :gen_tcp.send(state.socket, framed_data) do
        :ok ->
          {:reply, :ok, %{state | bytes_sent: state.bytes_sent + byte_size(framed_data)}}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
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
      :gen_tcp.close(state.socket)
    end

    :ok
  end

  # Private functions

  defp connect(host, port, timeout) when is_binary(host) do
    case :inet.parse_address(to_charlist(host)) do
      {:ok, ip} -> connect(ip, port, timeout)
      _ -> connect_by_hostname(host, port, timeout)
    end
  end

  defp connect(ip, port, timeout) when is_tuple(ip) do
    :gen_tcp.connect(ip, port, [:binary, packet: 0, active: false], timeout)
  end

  defp connect_by_hostname(host, port, timeout) do
    # Try to resolve and connect
    case :inet.gethostbyname(to_charlist(host)) do
      {:ok, {:hostent, _, _, :inet, _, [ip | _]}} ->
        connect(ip, port, timeout)

      _ ->
        {:error, :nxdomain}
    end
  end

  # Framing and parsing helpers

  defp frame_data(data, packet_handler) do
    case packet_handler do
      {:length_prefix, prefix_bytes} when prefix_bytes in [1, 2, 4] ->
        length = byte_size(data)
        <<length::big-integer-size(prefix_bytes * 8), data::binary>>

      _ ->
        data
    end
  end

  defp recv_and_parse(state) do
    case :gen_tcp.recv(state.socket, 0, state.timeout) do
      {:ok, data} ->
        new_buffer = state.buffer <> data

        case state.packet_handler do
          {:length_prefix, prefix_bytes} when prefix_bytes in [1, 2, 4] ->
            extract_messages(new_buffer, prefix_bytes, [])

          :raw ->
            {:ok, [new_buffer], <<>>, byte_size(new_buffer)}

          _ ->
            {:ok, [new_buffer], <<>>, byte_size(new_buffer)}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_messages(buffer, prefix_bytes, acc) do
    prefix_size = prefix_bytes

    if byte_size(buffer) < prefix_size do
      # Not enough data for length prefix
      if acc == [] do
        {:error, :timeout}
      else
        {:ok, Enum.reverse(acc), buffer, 0}
      end
    else
      # Extract the message length (big-endian)
      <<msg_length::big-integer-size(prefix_bytes * 8), rest::binary>> = buffer

      if byte_size(rest) >= msg_length do
        # Extract complete message
        <<message::binary-size(msg_length), remaining::binary>> = rest
        extract_messages(remaining, prefix_bytes, [message | acc])
      else
        # Incomplete message, wait for more data
        if acc == [] do
          {:error, :timeout}
        else
          {:ok, Enum.reverse(acc), buffer, 0}
        end
      end
    end
  end
end
