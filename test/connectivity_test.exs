defmodule Iso8583.ContextTest do
  use ExUnit.Case

  alias Iso8583.Context

  describe "new/1" do
    test "creates empty context" do
      context = Context.new([])

      assert context.transport_ref == nil
      assert context.client_id == nil
      assert context.peer_address == nil
      assert context.request_id == nil
      assert context.transport_metadata == nil
    end

    test "creates context with keyword options" do
      context = Context.new(transport_ref: self(), client_id: "client_123")

      assert context.transport_ref == self()
      assert context.client_id == "client_123"
    end

    test "creates context with map" do
      context = Context.new(%{transport_ref: self(), client_id: "client_123"})

      assert context.transport_ref == self()
      assert context.client_id == "client_123"
    end

    test "creates context with all fields" do
      socket = :erlang.open_port({:spawn, "echo"}, [])
      context =
        Context.new(
          transport_ref: socket,
          client_id: "client_001",
          peer_address: {192, 168, 1, 100},
          request_id: "req-123",
          transport_metadata: %{connection_time: System.system_time()}
        )

      assert context.transport_ref == socket
      assert context.client_id == "client_001"
      assert context.peer_address == {192, 168, 1, 100}
      assert context.request_id == "req-123"
      assert context.transport_metadata.connection_time

      :erlang.port_close(socket)
    end
  end

  describe "put_metadata/3" do
    test "adds metadata to empty context" do
      context = Context.new([])
      context = Context.put_metadata(context, :key, :value)

      assert context.transport_metadata == %{key: :value}
    end

    test "adds metadata to existing metadata" do
      context = Context.new(transport_metadata: %{existing: :value})
      context = Context.put_metadata(context, :new_key, :new_value)

      assert context.transport_metadata == %{existing: :value, new_key: :new_value}
    end

    test "updates existing metadata key" do
      context = Context.new(transport_metadata: %{key: :old_value})
      context = Context.put_metadata(context, :key, :new_value)

      assert context.transport_metadata == %{key: :new_value}
    end
  end

  describe "get_metadata/3" do
    test "returns nil for non-existent key" do
      context = Context.new([])

      assert Context.get_metadata(context, :non_existent) == nil
    end

    test "returns default for non-existent key" do
      context = Context.new([])

      assert Context.get_metadata(context, :non_existent, :default) == :default
    end

    test "returns value for existing key" do
      context = Context.put_metadata(Context.new([]), :my_key, :my_value)

      assert Context.get_metadata(context, :my_key) == :my_value
    end
  end

  describe "peer_address_string/1" do
    test "returns nil when peer_address is nil" do
      context = Context.new([])

      assert Context.peer_address_string(context) == nil
    end

    test "returns IPv4 address as string" do
      context = Context.new(peer_address: {192, 168, 1, 100})

      assert Context.peer_address_string(context) == "192.168.1.100"
    end

    test "returns IPv6 address as string" do
      context = Context.new(peer_address: {0, 0, 0, 0, 0, 65535, 32322, 60101})

      # IPv4-mapped IPv6 - :inet.ntoa returns the full IPv6 representation
      assert Context.peer_address_string(context) == "::ffff:126.66.234.197"
    end

    test "returns localhost as string" do
      context = Context.new(peer_address: {127, 0, 0, 1})

      assert Context.peer_address_string(context) == "127.0.0.1"
    end
  end

  describe "merge_metadata/2" do
    test "merges map into context metadata" do
      context = Context.new([])
      context = Context.merge_metadata(context, %{key1: :value1, key2: :value2})

      assert context.transport_metadata == %{key1: :value1, key2: :value2}
    end

    test "merges with existing metadata" do
      context = Context.new(transport_metadata: %{existing: :old})
      context = Context.merge_metadata(context, %{existing: :new, new_key: :new_value})

      assert context.transport_metadata == %{existing: :new, new_key: :new_value}
    end
  end

  describe "new_with_request_id/1" do
    test "creates context with generated request ID" do
      context = Context.new_with_request_id()

      assert context.request_id != nil
      assert is_binary(context.request_id)
      # UUID v4 format: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
      assert Regex.match?(~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i,
        context.request_id)
    end

    test "creates context with request ID and other options" do
      context = Context.new_with_request_id(transport_ref: self(), client_id: "client_123")

      assert context.request_id != nil
      assert context.transport_ref == self()
      assert context.client_id == "client_123"
    end

    test "generates unique request IDs" do
      context1 = Context.new_with_request_id()
      context2 = Context.new_with_request_id()

      assert context1.request_id != context2.request_id
    end
  end
end

defmodule Iso8583.HandlerTest do
  use ExUnit.Case

  # Mock processor for testing
  defmodule MockProcessor do
    use TransactionProcessor

    config error_response_code_field: 39,
          error_message_field: 60

    defmodule TestRequest do
      defstruct [:data]
    end

    defmodule TestResponse do
      defstruct [:response_code, :data]
    end

    defhandler :test, TestRequest, TestResponse do
      def handle(%TestRequest{data: data}) do
        %TestResponse{response_code: "00", data: data}
      end
    end
  end

  # Mock transport for testing
  defmodule MockTransport do
    @behaviour Iso8583.Transport

    def start_link(opts) do
      Agent.start_link(fn -> %{callback: nil, opts: opts} end, name: Keyword.get(opts, :name))
    end

    def child_spec(opts) do
      %{
        id: __MODULE__,
        start: {__MODULE__, :start_link, [opts]},
        restart: :permanent,
        type: :worker
      }
    end

    def send(_transport_ref, data) do
      # Just return ok
      :ok
    end

    def set_receive_callback(pid, callback) do
      Agent.update(pid, fn state -> %{state | callback: callback} end)
      :ok
    end

    def stop(pid), do: Agent.stop(pid)

    # Helper for testing - trigger receive callback
    def trigger_receive(pid, raw_message, context) do
      callback = Agent.get(pid, fn state -> state.callback end)

      if callback do
        callback.(raw_message, context)
      else
        {:error, :no_callback}
      end
    end
  end

  describe "Handler macro" do
    defmodule TestHandler do
      use Iso8583.Handler,
        processor: MockProcessor,
        transport: MockTransport,
        transport_opts: [name: :test_transport],
        log_level: :debug
    end

    test "has processor reference" do
      assert TestHandler.__processor__() == MockProcessor
    end

    test "has transport reference" do
      assert TestHandler.__transport__() == MockTransport
    end

    test "has child spec" do
      spec = TestHandler.child_spec([])

      assert spec.id == TestHandler
      assert spec.restart == :permanent
      assert spec.type == :worker
    end
  end

  describe "Handler with mocked transport" do
    setup do
      {:ok, transport_pid} = MockTransport.start_link(name: :test_mock_transport)

      handler_opts = [
        transport: transport_pid,
        transport_opts: [name: :test_mock_transport]
      ]

      on_exit(fn -> Process.exit(transport_pid, :normal) end)

      {:ok, transport_pid: transport_pid, handler_opts: handler_opts}
    end

    test "can start handler", %{transport_pid: transport_pid} do
      start_opts = [
        transport: transport_pid,
        transport_opts: [name: :test_mock_transport]
      ]

      assert {:ok, _pid} = Iso8583.HandlerTest.TestHandler.start_link(start_opts)
    end
  end
end

defmodule Iso8583.Transport.TCP.FramingTest do
  use ExUnit.Case
  alias Iso8583.Transport.TCP

  describe "encode_framed/2" do
    test "encodes message with 2-byte length prefix" do
      message = <<1, 2, 3>>
      encoded = TCP.encode_framed(message, 2)

      assert encoded == <<0, 3, 1, 2, 3>>
    end

    test "encodes message with 1-byte length prefix" do
      message = <<1, 2, 3>>
      encoded = TCP.encode_framed(message, 1)

      assert encoded == <<3, 1, 2, 3>>
    end

    test "encodes message with 4-byte length prefix" do
      message = <<1, 2, 3>>
      encoded = TCP.encode_framed(message, 4)

      assert encoded == <<0, 0, 0, 3, 1, 2, 3>>
    end

    test "encodes empty message" do
      encoded = TCP.encode_framed(<<>>, 2)

      assert encoded == <<0, 0>>
    end

    test "encodes large message with 2-byte prefix" do
      message = :binary.copy(<<42>>, 1000)
      encoded = TCP.encode_framed(message, 2)

      assert byte_size(encoded) == 1002
      assert binary_part(encoded, 0, 2) == <<3, 232>>  # 1000 in big-endian
    end

    test "encodes max 2-byte length (65535)" do
      message = :binary.copy(<<255>>, 65535)
      encoded = TCP.encode_framed(message, 2)

      assert byte_size(encoded) == 65537
      assert binary_part(encoded, 0, 2) == <<255, 255>>
    end
  end

  describe "decode_framed/2" do
    test "decodes complete message with 2-byte prefix" do
      buffer = <<0, 3, 1, 2, 3>>
      assert TCP.decode_framed(buffer, 2) == {:ok, <<1, 2, 3>>, <<>>}
    end

    test "decodes complete message with 1-byte prefix" do
      buffer = <<3, 1, 2, 3>>
      assert TCP.decode_framed(buffer, 1) == {:ok, <<1, 2, 3>>, <<>>}
    end

    test "decodes complete message with 4-byte prefix" do
      buffer = <<0, 0, 0, 3, 1, 2, 3>>
      assert TCP.decode_framed(buffer, 4) == {:ok, <<1, 2, 3>>, <<>>}
    end

    test "returns incomplete when buffer has only length prefix" do
      buffer = <<0, 10>>
      assert TCP.decode_framed(buffer, 2) == :incomplete
    end

    test "returns incomplete when buffer has partial message" do
      buffer = <<0, 10, 1, 2, 3>>
      assert TCP.decode_framed(buffer, 2) == :incomplete
    end

    test "returns incomplete when buffer is empty" do
      buffer = <<>>
      assert TCP.decode_framed(buffer, 2) == :incomplete
    end

    test "decodes message and returns remaining buffer" do
      buffer = <<0, 3, 1, 2, 3, 0, 5, 4, 5, 6, 7>>
      assert TCP.decode_framed(buffer, 2) == {:ok, <<1, 2, 3>>, <<0, 5, 4, 5, 6, 7>>}
    end

    test "decodes empty message" do
      buffer = <<0, 0, 1, 2, 3>>
      assert TCP.decode_framed(buffer, 2) == {:ok, <<>>, <<1, 2, 3>>}
    end

    test "handles max 2-byte length (65535)" do
      data = :binary.copy(<<42>>, 65535)
      buffer = <<255, 255, data::binary>>
      assert TCP.decode_framed(buffer, 2) == {:ok, data, <<>>}
    end
  end

  describe "encode/decode roundtrip" do
    test "roundtrip with 2-byte prefix" do
      original = <<0x02, 0x00, 0xB2, 0x20, 0x00, 0x00, 0x00, 0x10>>
      encoded = TCP.encode_framed(original, 2)
      assert {:ok, decoded, <<>>} = TCP.decode_framed(encoded, 2)
      assert decoded == original
    end

    test "roundtrip with 1-byte prefix" do
      original = <<1, 2, 3, 4, 5>>
      encoded = TCP.encode_framed(original, 1)
      assert {:ok, decoded, <<>>} = TCP.decode_framed(encoded, 1)
      assert decoded == original
    end

    test "roundtrip with 4-byte prefix" do
      original = :binary.copy(<<42>>, 1000)
      encoded = TCP.encode_framed(original, 4)
      assert {:ok, decoded, <<>>} = TCP.decode_framed(encoded, 4)
      assert decoded == original
    end
  end
end

defmodule Iso8583.Transport.TCP.ServerTest do
  use ExUnit.Case, async: false

  alias Iso8583.Transport.TCP.Server

  describe "server configuration" do
    test "has child spec" do
      spec = Server.child_spec(port: 0)  # Use port 0 for testing

      assert spec.id == Iso8583.Transport.TCP.Server
      assert spec.restart == :permanent
      assert spec.type == :worker
    end
  end

  describe "start_link/1" do
    test "starts server with port option" do
      port = get_available_port()

      assert {:ok, pid} = Server.start_link(port: port)
      assert Process.alive?(pid)

      :ok = Server.stop(pid)
    end

    test "starts server with name registration" do
      port = get_available_port()

      assert {:ok, _pid} = Server.start_link(port: port, name: :test_tcp_server)

      # Verify server is registered
      assert {:ok, pid} = Server.lookup_server(:test_tcp_server)
      assert Process.alive?(pid)

      :ok = Server.stop(:test_tcp_server)
    end

    test "starts server with TPDU enabled" do
      port = get_available_port()

      assert {:ok, pid} = Server.start_link(
        port: port,
        tpdu_enabled: true,
        tpdu_address_size: 5,
        tpdu_source_address: <<0, 0, 0, 0, 1>>
      )
      assert Process.alive?(pid)

      :ok = Server.stop(pid)
    end

    test "returns error when port is missing" do
      assert_raise KeyError, fn ->
        Server.start_link([])
      end
    end
  end

  describe "lookup_server/1" do
    test "looks up server by registered name" do
      port = get_available_port()

      {:ok, _pid} = Server.start_link(port: port, name: :test_lookup_server)

      assert {:ok, pid} = Server.lookup_server(:test_lookup_server)
      assert is_pid(pid)

      Server.stop(:test_lookup_server)
    end

    test "returns error for non-existent server" do
      assert {:error, :not_found} = Server.lookup_server(:non_existent_server)
    end
  end

  describe "set_receive_callback/2" do
    test "sets callback by PID" do
      port = get_available_port()
      {:ok, pid} = Server.start_link(port: port)

      test_pid = self()
      callback = fn data, _context -> send(test_pid, {:received, data}) end

      assert :ok = Server.set_receive_callback(pid, callback)

      Server.stop(pid)
    end

    test "sets callback by registered name" do
      port = get_available_port()
      {:ok, _pid} = Server.start_link(port: port, name: :test_callback_server)

      test_pid = self()
      callback = fn data, _context -> send(test_pid, {:received, data}) end

      assert :ok = Server.set_receive_callback(:test_callback_server, callback)

      Server.stop(:test_callback_server)
    end

    test "returns error for non-existent server when setting callback by name" do
      callback = fn data, _context -> :ok end

      assert {:error, :not_found} = Server.set_receive_callback(:non_existent_server, callback)
    end
  end

  describe "stop/1" do
    test "stops server by PID" do
      port = get_available_port()
      {:ok, pid} = Server.start_link(port: port)

      assert :ok = Server.stop(pid)
      refute Process.alive?(pid)
    end

    test "stops server by name" do
      port = get_available_port()
      {:ok, _pid} = Server.start_link(port: port, name: :test_stop_server)

      assert :ok = Server.stop(:test_stop_server)

      # Give it time to stop
      Process.sleep(50)
      assert {:error, :not_found} = Server.lookup_server(:test_stop_server)
    end

    test "returns error for non-existent server" do
      assert {:error, :not_found} = Server.stop(:non_existent_server)
    end
  end

  describe "client connection handling" do
    test "accepts TCP client connections" do
      port = get_available_port()

      {:ok, server_pid} = Server.start_link(
        port: port,
        acceptors: 2,
        timeout: 5000
      )

      # Set callback to track connections
      parent = self()
      Server.set_receive_callback(server_pid, fn data, context ->
        send(parent, {:message_received, data, context})
      end)

      # Connect a client
      {:ok, client_socket} = :gen_tcp.connect(:localhost, port, [:binary, packet: 0, active: false])

      # Send a message with 2-byte length prefix
      iso_message = <<0x02, 0x00, 0xB2, 0x20>>
      framed = <<byte_size(iso_message)::big-integer-size(16), iso_message::binary>>
      :gen_tcp.send(client_socket, framed)

      # Give time for server to process
      Process.sleep(100)

      # Clean up
      :gen_tcp.close(client_socket)
      Server.stop(server_pid)
    end

    test "handles length-prefixed messages with TPDU" do
      port = get_available_port()

      {:ok, server_pid} = Server.start_link(
        port: port,
        packet_handler: {:length_prefix, 2},
        tpdu_enabled: true,
        tpdu_address_size: 5,
        tpdu_source_address: <<0, 0, 0, 0, 2>>
      )

      parent = self()
      Server.set_receive_callback(server_pid, fn data, context ->
        send(parent, {:message_received, data, context})
      end)

      {:ok, client_socket} = :gen_tcp.connect(:localhost, port, [:binary, packet: 0, active: false])

      # Create message with TPDU: dest (acquirer) + source (client) + ISO message
      tpdu = <<0, 0, 0, 0, 2, 0, 0, 0, 0, 1>>  # 5 bytes dest + 5 bytes source
      iso_message = <<0x02, 0x00, 0xB2, 0x20>>
      payload = tpdu <> iso_message
      framed = <<byte_size(payload)::big-integer-size(16), payload::binary>>

      :gen_tcp.send(client_socket, framed)
      Process.sleep(100)

      :gen_tcp.close(client_socket)
      Server.stop(server_pid)
    end
  end

  # Helper function to get an available port
  defp get_available_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end
end

defmodule Iso8583.Transport.TCP.ClientTest do
  use ExUnit.Case, async: false

  alias Iso8583.Transport.TCP.Client

  describe "client configuration" do
    test "has child spec" do
      spec = Client.child_spec(host: "localhost", port: 8080)

      assert spec.id == Iso8583.Transport.TCP.Client
      assert spec.restart == :permanent
      assert spec.type == :worker
    end
  end

  describe "start_link/1" do
    test "starts client with required options" do
      port = start_echo_server()

      assert {:ok, pid} = Client.start_link(
        host: "localhost",
        port: port
      )
      assert Process.alive?(pid)

      Client.stop(pid)
      stop_echo_server(port)
    end

    test "starts client with TPDU enabled" do
      port = start_echo_server()

      assert {:ok, pid} = Client.start_link(
        host: "localhost",
        port: port,
        tpdu_enabled: true,
        tpdu_address_size: 5,
        tpdu_source_address: <<0, 0, 0, 0, 1>>,
        tpdu_destination_address: <<0, 0, 0, 0, 2>>
      )
      assert Process.alive?(pid)

      Client.stop(pid)
      stop_echo_server(port)
    end
  end

  describe "set_receive_callback/2" do
    test "sets callback by PID" do
      port = start_echo_server()
      {:ok, pid} = Client.start_link(host: "localhost", port: port)

      test_pid = self()
      callback = fn _data, _context -> send(test_pid, {:received, :ok}) end

      assert :ok = Client.set_receive_callback(pid, callback)

      Client.stop(pid)
      stop_echo_server(port)
    end

    test "sets callback by registered name" do
      port = start_echo_server()
      {:ok, _pid} = Client.start_link(host: "localhost", port: port, name: :test_tcp_callback_client)

      test_pid = self()
      callback = fn _data, _context -> send(test_pid, {:received, :ok}) end

      assert :ok = Client.set_receive_callback(:test_tcp_callback_client, callback)

      Client.stop(:test_tcp_callback_client)
      stop_echo_server(port)
    end

    test "returns error for non-existent client when setting callback by name" do
      callback = fn _data, _context -> :ok end

      assert {:error, :not_found} = Client.set_receive_callback(:non_existent_tcp_client, callback)
    end
  end

  describe "lookup_client/1" do
    test "looks up client by registered name" do
      port = start_echo_server()
      {:ok, pid} = Client.start_link(host: "localhost", port: port, name: :test_lookup_tcp_client)

      assert {:ok, lookup_pid} = Client.lookup_client(:test_lookup_tcp_client)
      assert lookup_pid == pid

      Client.stop(:test_lookup_tcp_client)
      stop_echo_server(port)
    end

    test "returns error for non-existent client" do
      assert {:error, :not_found} = Client.lookup_client(:non_existent_tcp_client)
    end
  end

  describe "send/2" do
    test "sends data by PID" do
      port = start_echo_server()
      {:ok, pid} = Client.start_link(host: "localhost", port: port)

      assert :ok = Client.send(pid, <<0x02, 0x00, 0xB2, 0x20>>)

      Client.stop(pid)
      stop_echo_server(port)
    end

    test "sends data by registered name" do
      port = start_echo_server()
      {:ok, _pid} = Client.start_link(host: "localhost", port: port, name: :test_tcp_send_client)

      assert :ok = Client.send(:test_tcp_send_client, <<0x02, 0x00, 0xB2, 0x20>>)

      Client.stop(:test_tcp_send_client)
      stop_echo_server(port)
    end

    test "returns error when sending to non-existent client by name" do
      assert {:error, :not_found} = Client.send(:non_existent_tcp_client, <<0x02, 0x00>>)
    end
  end

  describe "stop/1" do
    test "stops client by PID" do
      port = start_echo_server()
      {:ok, pid} = Client.start_link(host: "localhost", port: port)

      assert :ok = Client.stop(pid)
      refute Process.alive?(pid)

      stop_echo_server(port)
    end

    test "stops client by name" do
      port = start_echo_server()
      {:ok, _pid} = Client.start_link(host: "localhost", port: port, name: :test_tcp_stop_client)

      assert :ok = Client.stop(:test_tcp_stop_client)

      # Give it time to stop
      Process.sleep(50)
      assert {:error, :not_found} = Client.lookup_client(:test_tcp_stop_client)

      stop_echo_server(port)
    end

    test "returns error for non-existent client" do
      assert {:error, :not_found} = Client.stop(:non_existent_tcp_client)
    end
  end

  describe "connection stats tracking" do
    test "initializes connection stats to zero" do
      port = start_echo_server()
      {:ok, pid} = Client.start_link(host: "localhost", port: port)

      state = :sys.get_state(pid)
      assert state.bytes_sent == 0
      assert state.bytes_received == 0
      assert state.messages_received == 0

      Client.stop(pid)
      stop_echo_server(port)
    end
  end

  # Simple echo server for testing
  defp start_echo_server do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)

    # Start acceptor in a separate process
    spawn(fn ->
      accept_loop(socket)
    end)

    port
  end

  defp accept_loop(listen_socket) do
    case :gen_tcp.accept(listen_socket, 1000) do
      {:ok, socket} ->
        # Echo data back
        spawn(fn -> echo_loop(socket) end)
        accept_loop(listen_socket)
      {:error, :timeout} ->
        accept_loop(listen_socket)
      {:error, _} ->
        :gen_tcp.close(listen_socket)
    end
  end

  defp echo_loop(socket) do
    case :gen_tcp.recv(socket, 0, 1000) do
      {:ok, data} ->
        :gen_tcp.send(socket, data)
        echo_loop(socket)
      {:error, _} ->
        :gen_tcp.close(socket)
    end
  end

  defp stop_echo_server(port) do
    # The echo server process will exit when the socket is closed
    :ok
  end
end

defmodule Iso8583.Transport.HTTP.ServerTest do
  use ExUnit.Case

  alias Iso8583.Context

  describe "context creation for HTTP" do
    test "creates context with HTTP metadata" do
      context =
        Context.new(
          transport_ref: :mock_conn,
          client_id: "http_client",
          peer_address: {127, 0, 0, 1},
          request_id: "req-123",
          transport_metadata: %{
            method: "POST",
            path: "/iso8583",
            headers: %{"content-type" => "application/json"},
            user_agent: "TestClient/1.0"
          }
        )

      assert context.transport_ref == :mock_conn
      assert context.client_id == "http_client"
      assert context.peer_address == {127, 0, 0, 1}
      assert context.request_id == "req-123"
      assert context.transport_metadata.method == "POST"
      assert context.transport_metadata.path == "/iso8583"
    end
  end

  describe "request/response encoding" do
    test "encodes ISO message to base64" do
      iso_message = <<0x02, 0x00, 0x00, 0x01, 0x23, 0x45>>
      encoded = Base.encode64(iso_message)

      assert is_binary(encoded)
      assert String.length(encoded) > 0
    end

    test "decodes base64 to ISO message" do
      iso_message = <<0x02, 0x00, 0x00, 0x01, 0x23, 0x45>>
      encoded = Base.encode64(iso_message)

      assert {:ok, ^iso_message} = Base.decode64(encoded)
    end
  end

  describe "JSON request format" do
    test "encodes request to JSON" do
      iso_message = <<0x02, 0x00, 0x00, 0x01, 0x23, 0x45>>
      encoded = Base.encode64(iso_message)

      json = Jason.encode!(%{iso_message: encoded, request_id: "req-123"})

      assert is_binary(json)
      assert String.contains?(json, "iso_message")
    end

    test "decodes JSON request" do
      iso_message = <<0x02, 0x00, 0x00, 0x01, 0x23, 0x45>>
      encoded = Base.encode64(iso_message)

      json = Jason.encode!(%{iso_message: encoded, request_id: "req-123"})

      assert {:ok, %{"iso_message" => ^encoded, "request_id" => "req-123"}} = Jason.decode(json)
    end

    test "extracts ISO message from JSON" do
      iso_message = <<0x02, 0x00, 0x00, 0x01, 0x23, 0x45>>
      encoded = Base.encode64(iso_message)

      json = Jason.encode!(%{iso_message: encoded})

      assert {:ok, decoded} = Jason.decode(json)
      assert {:ok, ^iso_message} = Base.decode64(decoded["iso_message"])
    end
  end

  describe "JSON response format" do
    test "encodes success response to JSON" do
      response = <<0x02, 0x10, 0x00, 0x01, 0x00>>
      encoded = Base.encode64(response)

      json = Jason.encode!(%{iso_message: encoded, request_id: "req-123"})

      assert {:ok, decoded} = Jason.decode(json)
      assert decoded["request_id"] == "req-123"
    end

    test "encodes error response to JSON" do
      json = Jason.encode!(%{error: "Invalid message", request_id: "req-123"})

      assert {:ok, decoded} = Jason.decode(json)
      assert decoded["error"] == "Invalid message"
      assert decoded["request_id"] == "req-123"
    end
  end

  describe "server configuration" do
    test "has child spec" do
      spec = Iso8583.Transport.HTTP.Server.child_spec(port: 4000)

      assert spec.id == Iso8583.Transport.HTTP.Server
      assert spec.restart == :permanent
      assert spec.type == :supervisor
    end
  end

  describe "lookup_server/1" do
    test "looks up server by registered name" do
      port = get_available_port()

      {:ok, _pid} = Iso8583.Transport.HTTP.Server.start_link(
        port: port,
        name: :test_http_lookup_server
      )

      assert {:ok, server_pid} = Iso8583.Transport.HTTP.Server.lookup_server(:test_http_lookup_server)
      assert is_pid(server_pid)

      Iso8583.Transport.HTTP.Server.stop(:test_http_lookup_server)
      Process.sleep(100)
    end

    test "returns error for non-existent server" do
      assert {:error, :not_found} = Iso8583.Transport.HTTP.Server.lookup_server(:non_existent_http_server)
    end
  end

  describe "set_receive_callback/2" do
    test "sets callback by registered name" do
      port = get_available_port()

      {:ok, _pid} = Iso8583.Transport.HTTP.Server.start_link(
        port: port,
        name: :test_http_callback_server
      )

      test_pid = self()
      callback = fn _data, _context -> send(test_pid, {:http_received, :ok}) end

      assert :ok = Iso8583.Transport.HTTP.Server.set_receive_callback(:test_http_callback_server, callback)

      Iso8583.Transport.HTTP.Server.stop(:test_http_callback_server)
      Process.sleep(100)
    end

    test "returns error for non-existent server when setting callback by name" do
      callback = fn _data, _context -> :ok end

      assert {:error, :not_found} = Iso8583.Transport.HTTP.Server.set_receive_callback(:non_existent_http_server, callback)
    end
  end

  describe "stop/2" do
    test "stops server by name" do
      port = get_available_port()

      {:ok, _pid} = Iso8583.Transport.HTTP.Server.start_link(
        port: port,
        name: :test_http_stop_server
      )

      # Verify server is running
      assert {:ok, _registered_pid} = Iso8583.Transport.HTTP.Server.lookup_server(:test_http_stop_server)

      # Stop the server
      assert :ok = Iso8583.Transport.HTTP.Server.stop(:test_http_stop_server)
    end

    test "returns error for non-existent server" do
      assert {:error, :not_found} = Iso8583.Transport.HTTP.Server.stop(:non_existent_http_server)
    end
  end

  describe "stats tracking" do
    test "initializes stats to zero" do
      port = get_available_port()

      {:ok, pid} = Iso8583.Transport.HTTP.Server.start_link(
        port: port,
        name: :test_http_stats_server
      )

      # Get state via State process
      state_pid = Process.whereis(Iso8583.Transport.HTTP.Server.State)
      assert state_pid != nil

      stats = GenServer.call(state_pid, :get_stats)

      assert stats.connection_time != nil
      assert is_integer(stats.bytes_sent)
      assert is_integer(stats.bytes_received)
      assert is_integer(stats.messages_received)

      Iso8583.Transport.HTTP.Server.stop(:test_http_stats_server)
      Process.sleep(100)
    end
  end

  # Helper function to get an available port
  defp get_available_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  # Helper function to wait for process to shut down
  defp wait_for_shutdown(pid, timeout) do
    wait_for_shutdown(pid, System.monotonic_time(:millisecond), timeout)
  end

  defp wait_for_shutdown(pid, start_time, timeout) do
    if not Process.alive?(pid) do
      :ok
    else
      if System.monotonic_time(:millisecond) - start_time > timeout do
        {:error, :timeout}
      else
        Process.sleep(10)
        wait_for_shutdown(pid, start_time, timeout)
      end
    end
  end
end

defmodule Iso8583.Transport.HTTP.ClientTest do
  use ExUnit.Case

  alias Iso8583.Transport.HTTP.Client

  describe "client configuration" do
    test "has child spec" do
      spec = Client.child_spec(url: "http://localhost:4000/iso8583")

      assert spec.id == Iso8583.Transport.HTTP.Client
      assert spec.restart == :permanent
      assert spec.type == :worker
    end
  end

  describe "start_link/1" do
    test "starts client with name registration" do
      {:ok, pid} = Client.start_link(
        url: "http://localhost:14000/iso8583",
        name: :test_http_client
      )

      assert Process.alive?(pid)
      Client.stop(:test_http_client)
    end
  end

  describe "lookup_client/1" do
    test "looks up client by registered name" do
      {:ok, pid} = Client.start_link(
        url: "http://localhost:14001/iso8583",
        name: :test_http_lookup_client
      )

      assert {:ok, lookup_pid} = Client.lookup_client(:test_http_lookup_client)
      assert lookup_pid == pid

      Client.stop(:test_http_lookup_client)
    end

    test "returns error for non-existent client" do
      assert {:error, :not_found} = Client.lookup_client(:non_existent_http_client)
    end
  end

  describe "set_receive_callback/2" do
    test "sets callback by PID" do
      {:ok, pid} = Client.start_link(
        url: "http://localhost:14002/iso8583"
      )

      test_pid = self()
      callback = fn _data, _context -> send(test_pid, {:http_received, :ok}) end

      assert :ok = Client.set_receive_callback(pid, callback)

      Client.stop(pid)
    end

    test "sets callback by registered name" do
      {:ok, _pid} = Client.start_link(
        url: "http://localhost:14003/iso8583",
        name: :test_http_callback_client
      )

      test_pid = self()
      callback = fn _data, _context -> send(test_pid, {:http_received, :ok}) end

      assert :ok = Client.set_receive_callback(:test_http_callback_client, callback)

      Client.stop(:test_http_callback_client)
    end

    test "returns error for non-existent client when setting callback by name" do
      callback = fn _data, _context -> :ok end

      assert {:error, :not_found} = Client.set_receive_callback(:non_existent_http_client, callback)
    end
  end

  describe "stop/1" do
    test "stops client by PID" do
      {:ok, pid} = Client.start_link(
        url: "http://localhost:14004/iso8583"
      )

      assert :ok = Client.stop(pid)
      refute Process.alive?(pid)
    end

    test "stops client by name" do
      {:ok, pid} = Client.start_link(
        url: "http://localhost:14005/iso8583",
        name: :test_http_stop_client
      )

      assert :ok = Client.stop(:test_http_stop_client)
      refute Process.alive?(pid)
    end

    test "returns error for non-existent client" do
      assert {:error, :not_found} = Client.stop(:non_existent_http_client)
    end
  end

  describe "connection stats tracking" do
    test "initializes connection stats to zero" do
      {:ok, pid} = Client.start_link(
        url: "http://localhost:14006/iso8583"
      )

      state = :sys.get_state(pid)
      assert state.bytes_sent == 0
      assert state.bytes_received == 0
      assert state.messages_received == 0

      Client.stop(pid)
    end
  end
end

defmodule Iso8583.Transport.WebSocket.ServerTest do
  use ExUnit.Case, async: false

  alias Iso8583.Transport.WebSocket.Server

  describe "server configuration" do
    test "has child spec" do
      spec = Server.child_spec(port: 4000)

      assert spec.id == Iso8583.Transport.WebSocket.Server
      assert spec.restart == :permanent
      assert spec.type == :supervisor
    end
  end

  describe "lookup_server/1" do
    test "looks up server by registered name" do
      port = get_available_port()

      {:ok, _pid} = Server.start_link(
        port: port,
        name: :test_ws_lookup_server
      )

      assert {:ok, server_pid} = Server.lookup_server(:test_ws_lookup_server)
      assert is_pid(server_pid)

      Server.stop(:test_ws_lookup_server)
      Process.sleep(100)
    end

    test "returns error for non-existent server" do
      assert {:error, :not_found} = Server.lookup_server(:non_existent_ws_server)
    end
  end

  describe "set_receive_callback/2" do
    test "sets callback by registered name" do
      port = get_available_port()

      {:ok, _pid} = Server.start_link(
        port: port,
        name: :test_ws_callback_server
      )

      test_pid = self()
      callback = fn _data, _context -> send(test_pid, {:ws_received, :ok}) end

      assert :ok = Server.set_receive_callback(:test_ws_callback_server, callback)

      Server.stop(:test_ws_callback_server)
      Process.sleep(100)
    end

    test "returns error for non-existent server when setting callback by name" do
      callback = fn _data, _context -> :ok end

      assert {:error, :not_found} = Server.set_receive_callback(:non_existent_ws_server, callback)
    end
  end

  describe "stop/2" do
    test "stops server by name" do
      port = get_available_port()

      {:ok, pid} = Server.start_link(
        port: port,
        name: :test_ws_stop_server
      )

      # Verify server is running
      assert {:ok, _registered_pid} = Server.lookup_server(:test_ws_stop_server)

      # Stop the server
      assert :ok = Server.stop(:test_ws_stop_server)
    end

    test "returns error for non-existent server" do
      assert {:error, :not_found} = Server.stop(:non_existent_ws_server)
    end
  end

  # Helper function to get an available port
  defp get_available_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end
end

defmodule Iso8583.Transport.WebSocketTest do
  use ExUnit.Case

  alias Iso8583.Transport.WebSocket

  describe "encode_framed/2" do
    test "encodes message with 2-byte length prefix" do
      message = <<1, 2, 3>>
      encoded = WebSocket.encode_framed(message, 2)

      assert encoded == <<0, 3, 1, 2, 3>>
    end

    test "encodes message with 1-byte length prefix" do
      message = <<1, 2, 3>>
      encoded = WebSocket.encode_framed(message, 1)

      assert encoded == <<3, 1, 2, 3>>
    end

    test "encodes message with 4-byte length prefix" do
      message = <<1, 2, 3>>
      encoded = WebSocket.encode_framed(message, 4)

      assert encoded == <<0, 0, 0, 3, 1, 2, 3>>
    end

    test "encodes empty message" do
      encoded = WebSocket.encode_framed(<<>>, 2)

      assert encoded == <<0, 0>>
    end

    test "encodes 255 byte message with 1-byte prefix" do
      message = :binary.copy(<<42>>, 255)
      encoded = WebSocket.encode_framed(message, 1)

      assert byte_size(encoded) == 256
      assert binary_part(encoded, 0, 1) == <<255>>
    end

    test "encodes large message with 2-byte prefix" do
      message = :binary.copy(<<42>>, 1000)
      encoded = WebSocket.encode_framed(message, 2)

      assert byte_size(encoded) == 1002
      assert binary_part(encoded, 0, 2) == <<3, 232>>  # 1000 in big-endian
    end
  end

  describe "decode_framed/2" do
    test "decodes complete message with 2-byte prefix" do
      buffer = <<0, 3, 1, 2, 3>>
      assert WebSocket.decode_framed(buffer, 2) == {:ok, <<1, 2, 3>>, <<>>}
    end

    test "decodes complete message with 1-byte prefix" do
      buffer = <<3, 1, 2, 3>>
      assert WebSocket.decode_framed(buffer, 1) == {:ok, <<1, 2, 3>>, <<>>}
    end

    test "decodes complete message with 4-byte prefix" do
      buffer = <<0, 0, 0, 3, 1, 2, 3>>
      assert WebSocket.decode_framed(buffer, 4) == {:ok, <<1, 2, 3>>, <<>>}
    end

    test "returns incomplete when buffer has only length prefix" do
      buffer = <<0, 10>>
      assert WebSocket.decode_framed(buffer, 2) == :incomplete
    end

    test "returns incomplete when buffer has partial message" do
      buffer = <<0, 10, 1, 2, 3>>
      assert WebSocket.decode_framed(buffer, 2) == :incomplete
    end

    test "returns incomplete when buffer is empty" do
      buffer = <<>>
      assert WebSocket.decode_framed(buffer, 2) == :incomplete
    end

    test "decodes message and returns remaining buffer" do
      buffer = <<0, 3, 1, 2, 3, 0, 5, 4, 5, 6, 7>>
      assert WebSocket.decode_framed(buffer, 2) == {:ok, <<1, 2, 3>>, <<0, 5, 4, 5, 6, 7>>}
    end

    test "decodes empty message" do
      buffer = <<0, 0, 1, 2, 3>>
      assert WebSocket.decode_framed(buffer, 2) == {:ok, <<>>, <<1, 2, 3>>}
    end

    test "handles max 2-byte length (65535)" do
      data = :binary.copy(<<42>>, 65535)
      buffer = <<255, 255, data::binary>>
      assert WebSocket.decode_framed(buffer, 2) == {:ok, data, <<>>}
    end
  end

  describe "encode/decode roundtrip" do
    test "roundtrip with 2-byte prefix" do
      original = <<0x02, 0x00, 0xB2, 0x20, 0x00, 0x00, 0x00, 0x10>>
      encoded = WebSocket.encode_framed(original, 2)
      assert {:ok, decoded, <<>>} = WebSocket.decode_framed(encoded, 2)
      assert decoded == original
    end

    test "roundtrip with 1-byte prefix" do
      original = <<1, 2, 3, 4, 5>>
      encoded = WebSocket.encode_framed(original, 1)
      assert {:ok, decoded, <<>>} = WebSocket.decode_framed(encoded, 1)
      assert decoded == original
    end

    test "roundtrip with 4-byte prefix" do
      original = :binary.copy(<<42>>, 1000)
      encoded = WebSocket.encode_framed(original, 4)
      assert {:ok, decoded, <<>>} = WebSocket.decode_framed(encoded, 4)
      assert decoded == original
    end
  end

  describe "WebSocket server configuration" do
    test "has child spec" do
      spec = Iso8583.Transport.WebSocket.Server.child_spec(port: 4000)

      assert spec.id == Iso8583.Transport.WebSocket.Server
      assert spec.restart == :permanent
      assert spec.type == :supervisor
    end
  end
end

defmodule Iso8583.Transport.WebSocket.ClientTest do
  use ExUnit.Case, async: false

  alias Iso8583.Transport.WebSocket.Client

  describe "client configuration" do
    test "has child spec" do
      spec = Client.child_spec(url: "ws://localhost:4000/ws")

      assert spec.id == Iso8583.Transport.WebSocket.Client
      assert spec.restart == :permanent
      assert spec.type == :worker
    end
  end

  describe "start_link/1" do
    test "accepts url option" do
      # The client will try to connect but will fail since no server is running
      # We're testing the option parsing here
      assert {:ok, pid} = Client.start_link(url: "ws://localhost:14321/ws", reconnect_interval: 100)
      assert Process.alive?(pid)

      Client.stop(pid)
      Process.sleep(200)  # Wait for reconnect attempt to not be scheduled
    end

    test "starts client with name registration" do
      assert {:ok, pid} = Client.start_link(
        url: "ws://localhost:14322/ws",
        name: :test_ws_client,
        reconnect_interval: 100
      )

      # Verify client is registered
      assert {:ok, registered_pid} = Client.lookup_client(:test_ws_client)
      assert registered_pid == pid

      Client.stop(pid)
      Process.sleep(200)
    end

    test "starts client with TPDU enabled" do
      assert {:ok, pid} = Client.start_link(
        url: "ws://localhost:14323/ws",
        tpdu_enabled: true,
        tpdu_address_size: 5,
        tpdu_source_address: <<0, 0, 0, 0, 1>>,
        tpdu_destination_address: <<0, 0, 0, 0, 2>>,
        reconnect_interval: 100
      )
      assert Process.alive?(pid)

      Client.stop(pid)
      Process.sleep(200)
    end

    test "starts client with custom prefix_bytes" do
      assert {:ok, pid} = Client.start_link(
        url: "ws://localhost:14324/ws",
        prefix_bytes: 4,
        reconnect_interval: 100
      )
      assert Process.alive?(pid)

      Client.stop(pid)
      Process.sleep(200)
    end

    test "starts client with custom headers" do
      assert {:ok, pid} = Client.start_link(
        url: "ws://localhost:14325/ws",
        headers: %{"Authorization" => "Bearer token123"},
        reconnect_interval: 100
      )
      assert Process.alive?(pid)

      Client.stop(pid)
      Process.sleep(200)
    end

    test "parses ws:// URL correctly" do
      assert {:ok, pid} = Client.start_link(
        url: "ws://localhost:8080/path",
        reconnect_interval: 100
      )
      assert Process.alive?(pid)

      Client.stop(pid)
      Process.sleep(200)
    end

    test "parses wss:// URL correctly" do
      assert {:ok, pid} = Client.start_link(
        url: "wss://localhost:8443/secure",
        reconnect_interval: 100
      )
      assert Process.alive?(pid)

      Client.stop(pid)
      Process.sleep(200)
    end
  end

  describe "lookup_client/1" do
    test "looks up client by registered name" do
      {:ok, _pid} = Client.start_link(
        url: "ws://localhost:14330/ws",
        name: :test_lookup_client,
        reconnect_interval: 100
      )

      assert {:ok, pid} = Client.lookup_client(:test_lookup_client)
      assert is_pid(pid)

      Client.stop(:test_lookup_client)
      Process.sleep(200)
    end

    test "returns error for non-existent client" do
      assert {:error, :not_found} = Client.lookup_client(:non_existent_client)
    end
  end

  describe "set_receive_callback/2" do
    test "sets callback by PID" do
      {:ok, pid} = Client.start_link(
        url: "ws://localhost:14331/ws",
        reconnect_interval: 100
      )

      test_pid = self()
      callback = fn _data, _context -> send(test_pid, {:ws_received, :ok}) end

      assert :ok = Client.set_receive_callback(pid, callback)

      Client.stop(pid)
      Process.sleep(200)
    end

    test "sets callback by registered name" do
      {:ok, _pid} = Client.start_link(
        url: "ws://localhost:14332/ws",
        name: :test_callback_client,
        reconnect_interval: 100
      )

      test_pid = self()
      callback = fn _data, _context -> send(test_pid, {:ws_received, :ok}) end

      assert :ok = Client.set_receive_callback(:test_callback_client, callback)

      Client.stop(:test_callback_client)
      Process.sleep(200)
    end

    test "returns error for non-existent client when setting callback by name" do
      callback = fn _data, _context -> :ok end

      assert {:error, :not_found} = Client.set_receive_callback(:non_existent_client, callback)
    end
  end

  describe "send/2" do
    test "sends data by PID" do
      {:ok, pid} = Client.start_link(
        url: "ws://localhost:14333/ws",
        reconnect_interval: 100
      )

      # Send will return {:error, :not_connected} since no server is running
      # but we're testing the function exists and handles the case
      result = Client.send(pid, <<0x02, 0x00, 0xB2, 0x20>>)
      # Result will be :ok if socket exists, {:error, :not_connected} if not
      assert result == :ok or result == {:error, :not_connected}

      Client.stop(pid)
      Process.sleep(200)
    end

    test "sends data by name" do
      {:ok, _pid} = Client.start_link(
        url: "ws://localhost:14334/ws",
        name: :test_send_client,
        reconnect_interval: 100
      )

      result = Client.send(:test_send_client, <<0x02, 0x00, 0xB2, 0x20>>)
      assert result == :ok or result == {:error, :not_connected}

      Client.stop(:test_send_client)
      Process.sleep(200)
    end

    test "returns error when sending to non-existent client by name" do
      assert {:error, :not_found} = Client.send(:non_existent_client, <<0x02, 0x00>>)
    end
  end

  describe "stop/1" do
    test "stops client by PID" do
      {:ok, pid} = Client.start_link(
        url: "ws://localhost:14340/ws",
        reconnect_interval: 100
      )

      assert :ok = Client.stop(pid)
      refute Process.alive?(pid)
    end

    test "stops client by name" do
      {:ok, _pid} = Client.start_link(
        url: "ws://localhost:14341/ws",
        name: :test_stop_client,
        reconnect_interval: 100
      )

      assert :ok = Client.stop(:test_stop_client)

      Process.sleep(100)
      assert {:error, :not_found} = Client.lookup_client(:test_stop_client)
    end

    test "returns error for non-existent client" do
      assert {:error, :not_found} = Client.stop(:non_existent_client)
    end
  end

  describe "WebSocket frame encoding" do
    test "client starts and initializes state" do
      {:ok, pid} = Client.start_link(
        url: "ws://localhost:14350/ws",
        reconnect_interval: 100
      )

      # Verify the process is alive
      assert Process.alive?(pid)

      # Get state via :sys.get_state (for testing)
      state = :sys.get_state(pid)
      assert state.url == "ws://localhost:14350/ws"
      assert state.prefix_bytes == 2  # default
      assert state.tpdu_enabled == false  # default
      assert is_integer(state.reconnect_interval)

      Client.stop(pid)
      Process.sleep(200)
    end
  end

  describe "TPDU configuration" do
    test "stores TPDU configuration in state" do
      {:ok, pid} = Client.start_link(
        url: "ws://localhost:14351/ws",
        tpdu_enabled: true,
        tpdu_address_size: 5,
        tpdu_source_address: <<1, 2, 3, 4, 5>>,
        tpdu_destination_address: <<6, 7, 8, 9, 10>>,
        reconnect_interval: 100
      )

      state = :sys.get_state(pid)
      assert state.tpdu_enabled == true
      assert state.tpdu_address_size == 5
      assert state.tpdu_source_address == <<1, 2, 3, 4, 5>>
      assert state.tpdu_destination_address == <<6, 7, 8, 9, 10>>

      Client.stop(pid)
      Process.sleep(200)
    end
  end

  describe "connection stats tracking" do
    test "initializes connection stats to zero" do
      {:ok, pid} = Client.start_link(
        url: "ws://localhost:14352/ws",
        reconnect_interval: 100
      )

      state = :sys.get_state(pid)
      assert state.bytes_sent == 0
      assert state.bytes_received == 0
      assert state.messages_received == 0

      Client.stop(pid)
      Process.sleep(200)
    end
  end

  describe "reconnect behavior" do
    test "uses default reconnect interval" do
      {:ok, pid} = Client.start_link(
        url: "ws://localhost:14353/ws"
      )

      state = :sys.get_state(pid)
      assert state.reconnect_interval == 5000  # default

      Client.stop(pid)
      Process.sleep(200)
    end

    test "uses custom reconnect interval" do
      {:ok, pid} = Client.start_link(
        url: "ws://localhost:14354/ws",
        reconnect_interval: 1000
      )

      state = :sys.get_state(pid)
      assert state.reconnect_interval == 1000

      Client.stop(pid)
      Process.sleep(200)
    end
  end
end
