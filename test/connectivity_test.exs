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

defmodule Iso8583.Transport.TCP.ClientTest do
  use ExUnit.Case

  describe "client configuration" do
    test "has child spec" do
      spec = Iso8583.Transport.TCP.Client.child_spec(host: "localhost", port: 8080)

      assert spec.id == Iso8583.Transport.TCP.Client
      assert spec.restart == :permanent
      assert spec.type == :worker
    end
  end
end

defmodule Iso8583.Transport.TCP.ServerTest do
  use ExUnit.Case

  describe "server configuration" do
    test "has child spec" do
      spec = Iso8583.Transport.TCP.Server.child_spec(port: 8080)

      assert spec.id == Iso8583.Transport.TCP.Server
      assert spec.restart == :permanent
      assert spec.type == :worker
    end
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
end

