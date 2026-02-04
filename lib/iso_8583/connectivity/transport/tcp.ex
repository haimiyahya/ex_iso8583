defmodule Iso8583.Transport.TCP do
  @moduledoc """
  TCP transport implementations for ISO 8583.

  Includes both server (accepts connections) and client (connects out)
  implementations.
  """
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

      defmodule MyApp.PaymentHandler do
        use Iso8583.Handler,
          processor: MyApp.PaymentProcessor,
          transport: Iso8583.Transport.TCP.Server,
          transport_opts: [
            port: 8080,
            acceptors: 10,
            packet_handler: :raw
          ]
      end

  ## Options

  | Option | Type | Default | Description |
  |--------|------|---------|-------------|
  | `:port` | `integer()` | Required | Port to listen on |
  | `:acceptors` | `integer()` | `10` | Number of acceptor processes |
  | `:name` | `atom()` | `nil` | Name for registration |
  | `:packet_handler` | `atom() \| module()` | `:raw` | How to parse messages |
  | `:timeout` | `integer()` | `60000` | Connection idle timeout (ms) |

  ## Packet Handlers

  ### `:raw` (default)
  Reads entire socket buffer. Best for:
  - Clients that send complete messages at once
  - Messages with known length prefixes

  ### `:line`
  Reads until newline. Best for:
  - Testing/debugging
  - Line-delimited protocols

  ### `{:size, bytes}`
  Reads fixed-size messages. Best for:
  - Fixed-length ISO messages

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
  - `transport_metadata` - `%{connection_time, bytes_received, messages_received}`

  ## Supervisor Tree

      Iso8583.Transport.TCP.Server (GenServer)
          │
          ├── AcceptorSupervisor (DynamicSupervisor)
          │    ├── Acceptor 1 (GenServer) ──► Connection 1
          │    ├── Acceptor 2 (GenServer) ──► Connection 2
          │    └── ...
          │
          └── ClientRegistry (ETS)
  """

  use GenServer

  alias Iso8583.Context

  defstruct [
    :listen_socket,
    :acceptor_sup,
    :client_registry,
    :receive_callback,
    :port,
    :acceptors,
    :packet_handler,
    :timeout,
    :name
  ]

  # Client API

  @doc """
  Starts the TCP server transport.
  """
  def start_link(opts) do
    port = Keyword.fetch!(opts, :port)
    acceptors = Keyword.get(opts, :acceptors, 10)
    name = Keyword.get(opts, :name)
    packet_handler = Keyword.get(opts, :packet_handler, :raw)
    timeout = Keyword.get(opts, :timeout, 60_000)

    GenServer.start_link(
      __MODULE__,
      [port: port, acceptors: acceptors, packet_handler: packet_handler, timeout: timeout],
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
      type: :worker
    }
  end

  @doc """
  Sends data to a connected client.
  """
  def send(socket, data) when is_port(socket) do
    :gen_tcp.send(socket, data)
  end

  @doc """
  Registers the callback for receiving messages.
  """
  def set_receive_callback(server_pid, callback) when is_pid(server_pid) do
    GenServer.call(server_pid, {:set_callback, callback})
  end

  def set_receive_callback(name, callback) when is_atom(name) do
    GenServer.call(name, {:set_callback, callback})
  end

  @doc """
  Stops the server.
  """
  def stop(server_pid) when is_pid(server_pid) do
    GenServer.stop(server_pid, :normal)
  end

  def stop(name) when is_atom(name) do
    GenServer.stop(name, :normal)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    port = Keyword.fetch!(opts, :port)
    acceptors = Keyword.get(opts, :acceptors, 10)
    packet_handler = Keyword.get(opts, :packet_handler, :raw)
    timeout = Keyword.get(opts, :timeout, 60_000)

    # Create client registry
    client_registry = :ets.new(:tcp_clients, [:set, :private, :named_table])

    # Start acceptor supervisor
    case start_acceptor_supervisor() do
      {:ok, acceptor_sup} ->
        # Start listening
        case listen(port) do
          {:ok, listen_socket} ->
            # Start acceptors
            start_acceptors(acceptor_sup, listen_socket, self(), acceptors, opts)

            {:ok,
             %__MODULE__{
               listen_socket: listen_socket,
               acceptor_sup: acceptor_sup,
               client_registry: client_registry,
               port: port,
               acceptors: acceptors,
               packet_handler: packet_handler,
               timeout: timeout
             }}

          {:error, reason} ->
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
  def handle_info({:incoming_message, client_id, data, peer_address}, state) do
    if state.receive_callback do
      socket = :ets.lookup_element(state.client_registry, client_id, 2)

      context =
        Context.new(
          transport_ref: socket,
          client_id: client_id,
          peer_address: peer_address,
          transport_metadata: %{
            connection_time: get_connection_time(client_id),
            bytes_received: get_bytes_received(client_id),
            messages_received: get_messages_received(client_id)
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
    :ets.insert(state.client_registry, {client_id, socket})
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
    :ok
  end

  # Private functions

  defp start_acceptor_supervisor do
    Supervisor.start_link(
      [{DynamicSupervisor, strategy: :one_for_one, name: Iso8583.TCP.AcceptorSupervisor}],
      strategy: :one_for_one
    )
  end

  defp listen(port) do
    :gen_tcp.listen(
      port,
      [:binary, packet: 0, active: false, reuseaddr: true, send_timeout: 5000]
    )
  end

  defp start_acceptors(supervisor, listen_socket, server_pid, count, opts) do
    Enum.each(1..count, fn _ ->
      {:ok, _pid} =
        DynamicSupervisor.start_child(
          supervisor,
          {Iso8583.Transport.TCP.Acceptor,
           {listen_socket, server_pid, Keyword.get(opts, :packet_handler, :raw),
            Keyword.get(opts, :timeout, 60_000)}}
        )
    end)
  end

  # Connection tracking (simplified - in production would use separate table)
  defp get_connection_time(_client_id), do: System.system_time(:millisecond)
  defp get_bytes_received(_client_id), do: 0
  defp get_messages_received(_client_id), do: 0
end

defmodule Iso8583.Transport.TCP.Acceptor do
  @moduledoc """
  Acceptor process that accepts a single TCP connection and hands it off
  to a connection handler.
  """

  use GenServer
  require Logger

  def start_link({listen_socket, server_pid, packet_handler, timeout}) do
    GenServer.start_link(
      __MODULE__,
      {listen_socket, server_pid, packet_handler, timeout}
    )
  end

  def init({listen_socket, server_pid, packet_handler, timeout}) do
    # Send async accept request
    :gen_tcp.controlling_process(listen_socket, self())
    send(self(), :accept)

    {:ok,
     %{
       listen_socket: listen_socket,
       server_pid: server_pid,
       packet_handler: packet_handler,
       timeout: timeout,
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
            timeout: state.timeout
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
  """

  use GenServer
  require Logger

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
       buffer: <<>>
     }}
  end

  def handle_info(:receive, state) do
    case recv_packet(state) do
      {:ok, data, new_buffer} ->
        if byte_size(data) > 0 do
          send(state.server_pid, {:incoming_message, state.client_id, data, state.peer_address})
        end

        send(self(), :receive)
        {:noreply, %{state | buffer: new_buffer}}

      {:error, :closed} ->
        Logger.debug("Client #{state.client_id} disconnected")
        {:stop, :normal, state}

      {:error, reason} ->
        Logger.warning("Receive error for client #{state.client_id}: #{inspect(reason)}")
        {:stop, reason, state}
    end
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
end

defmodule Iso8583.Transport.TCP.Client do
  @moduledoc """
  TCP Client transport for ISO 8583 messages.

  Connects to a remote TCP server and sends/receives ISO 8583 messages.

  ## Usage

      defmodule MyApp.UpstreamHandler do
        use Iso8583.Handler,
          processor: MyApp.UpstreamProcessor,
          transport: Iso8583.Transport.TCP.Client,
          transport_opts: [
            host: "acquirer.example.com",
            port: 9000,
            reconnect_interval: 5000
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

  ## Context Metadata

  The client populates `Iso8583.Context` with:
  - `transport_ref` - `:client` (atom identifier)
  - `client_id` - `"tcp_client"`
  - `peer_address` - Remote server address
  - `transport_metadata` - `%{connection_time, bytes_sent, bytes_received}`

  """

  use GenServer
  import Kernel, except: [send: 2]
  require Logger

  alias Iso8583.Context

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
    :pending_requests
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

    # Try to connect immediately
    send(self(), :connect)

    {:ok,
     %__MODULE__{
       host: host,
       port: port,
       reconnect_interval: reconnect_interval,
       timeout: timeout,
       socket: nil,
       connection_time: nil,
       bytes_sent: 0,
       bytes_received: 0,
       pending_requests: %{}
     }}
  end

  @impl true
  def handle_info(:connect, state) do
    case connect(state.host, state.port, state.timeout) do
      {:ok, socket} ->
        Logger.info("Connected to #{state.host}:#{state.port}")

        # Start receiving
        send(self(), :receive)

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
    case :gen_tcp.recv(state.socket, 0, state.timeout) do
      {:ok, data} ->
        if state.receive_callback do
          context =
            Context.new(
              transport_ref: :client,
              client_id: "tcp_client",
              peer_address: state.host,
              transport_metadata: %{
                connection_time: state.connection_time,
                bytes_sent: state.bytes_sent,
                bytes_received: state.bytes_received
              }
            )

          state.receive_callback.(data, context)
        end

        send(self(), :receive)
        {:noreply, %{state | bytes_received: state.bytes_received + byte_size(data)}}

      {:error, :timeout} ->
        send(self(), :receive)
        {:noreply, state}

      {:error, :closed} ->
        Logger.warning("Connection closed to #{state.host}:#{state.port}")
        send(self(), :connect)
        {:noreply, %{state | socket: nil, connection_time: nil}}

      {:error, reason} ->
        Logger.error("Receive error: #{inspect(reason)}")
        send(self(), :connect)
        {:noreply, %{state | socket: nil, connection_time: nil}}
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
      case :gen_tcp.send(state.socket, data) do
        :ok ->
          {:reply, :ok, %{state | bytes_sent: state.bytes_sent + byte_size(data)}}

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
end
