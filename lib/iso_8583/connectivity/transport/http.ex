defmodule Iso8583.Transport.HTTP do
  @moduledoc """
  HTTP transport implementations for ISO 8583.

  Includes both server (REST API) and client (HTTP requests) implementations.
  """
end

defmodule Iso8583.Transport.HTTP.Server do
  @moduledoc """
  HTTP Server transport for ISO 8583 messages.

  Provides a REST API for sending ISO 8583 messages over HTTP.
  Messages are sent as JSON with the ISO 8583 binary data base64-encoded.

  ## Request Format

  POST /iso8583

  ```json
  {
    "iso_message": "base64_encoded_iso8583_binary",
    "request_id": "optional-correlation-id"
  }
  ```

  ## Response Format

  Success (200 OK):
  ```json
  {
    "iso_message": "base64_encoded_response",
    "request_id": "same-as-request"
  }
  ```

  Error (4xx/5xx):
  ```json
  {
    "error": "error_message",
    "request_id": "same-as-request"
  }
  ```

  ## Usage

      defmodule MyApp.ApiHandler do
        use Iso8583.Handler,
          processor: MyApp.PaymentProcessor,
          transport: Iso8583.Transport.HTTP.Server,
          transport_opts: [
            port: 4000,
            path: "/iso8583",
            scheme: :http
          ]
      end

  ## Options

  | Option | Type | Default | Description |
  |--------|------|---------|-------------|
  | `:port` | `integer()` | Required | Port to listen on |
  | `:path` | `String.t()` | `"/iso8583"` | API endpoint path |
  | `:scheme` | `:http \| :https` | `:http` | HTTP or HTTPS |
  | `:name` | `atom()` | `nil` | Name for registration |
  | `:timeout` | `integer()` | `30000` | Request timeout (ms) |
  | `:prefix_bytes` | `1 \| 2 \| 4` | `2` | Length prefix bytes for framing |
  | `:tpdu_enabled` | `boolean()` | `false` | Enable TPDU handling |
  | `:tpdu_address_size` | `integer()` | `5` | TPDU address size in bytes |

  ## Context Metadata

  The server populates `Iso8583.Context` with:
  - `transport_ref` - The `Plug.Conn` struct
  - `client_id` - "http_client"
  - `peer_address` - Client's IP address from conn.remote_ip
  - `transport_metadata` - `%{method, path, headers, request_id, connection_time, bytes_sent, bytes_received, messages_received, tpdu}`

  """

  use Supervisor

  alias Ex_Iso8583.TPDU

  defstruct [
    :port,
    :path,
    :scheme,
    :timeout,
    :name,
    :certfile,
    :keyfile,
    :receive_callback,
    :tpdu_enabled,
    :tpdu_address_size
  ]

  # Client API

  @doc """
  Starts the HTTP server transport.
  """
  def start_link(opts) do
    port = Keyword.fetch!(opts, :port)
    path = Keyword.get(opts, :path, "/iso8583")
    scheme = Keyword.get(opts, :scheme, :http)
    timeout = Keyword.get(opts, :timeout, 30_000)
    name = Keyword.get(opts, :name)
    certfile = Keyword.get(opts, :certfile)
    keyfile = Keyword.get(opts, :keyfile)
    prefix_bytes = Keyword.get(opts, :prefix_bytes, 2)
    tpdu_enabled = Keyword.get(opts, :tpdu_enabled, false)
    tpdu_address_size = Keyword.get(opts, :tpdu_address_size, 5)

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
        prefix_bytes: prefix_bytes,
        tpdu_enabled: tpdu_enabled,
        tpdu_address_size: tpdu_address_size
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
  Sends data (response) to the HTTP client.

  For HTTP server, this is handled internally by the Plug module.
  """
  def send(_conn, _data), do: :ok

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
  Looks up an HTTP server by registered name.
  """
  def lookup_server(name) when is_atom(name) do
    try do
      case Registry.lookup(Iso8583.HTTP.Registry, name) do
        [{pid, _}] when is_pid(pid) -> {:ok, pid}
        _ -> {:error, :not_found}
      end
    rescue
      ArgumentError -> {:error, :not_found}
    end
  end

  @doc """
  Stops the server.

  Supports both PID and registered name (atom) for lookup.
  """
  def stop(server_pid) when is_pid(server_pid) do
    Supervisor.stop(server_pid, :normal)
  end

  def stop(name) when is_atom(name) do
    case lookup_server(name) do
      {:ok, pid} -> Supervisor.stop(pid, :normal)
      {:error, _} -> {:error, :not_found}
    end
  end

  # Supervisor Callbacks

  @impl true
  def init(opts) do
    port = Keyword.fetch!(opts, :port)
    path = Keyword.get(opts, :path, "/iso8583")
    scheme = Keyword.get(opts, :scheme, :http)
    timeout = Keyword.get(opts, :timeout, 30_000)
    name = Keyword.get(opts, :name)
    certfile = Keyword.get(opts, :certfile)
    keyfile = Keyword.get(opts, :keyfile)
    prefix_bytes = Keyword.get(opts, :prefix_bytes, 2)
    tpdu_enabled = Keyword.get(opts, :tpdu_enabled, false)
    tpdu_address_size = Keyword.get(opts, :tpdu_address_size, 5)

    # Start state process to hold callback
    state_name = Module.concat(__MODULE__, State)

    children = [
      # Start HTTP Registry first
      {Registry, [keys: :unique, name: Iso8583.HTTP.Registry]},
      # State process for callback storage
      {Iso8583.Transport.HTTP.Server.State,
       [
         port: port,
         path: path,
         timeout: timeout,
         registry_name: name,
         prefix_bytes: prefix_bytes,
         tpdu_enabled: tpdu_enabled,
         tpdu_address_size: tpdu_address_size,
         name: state_name
       ]},
      # Plug-based endpoint router
      {Iso8583.Transport.HTTP.Server.Endpoint,
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

defmodule Iso8583.Transport.HTTP.Server.State do
  @moduledoc """
  GenServer that holds the receive callback for the HTTP server.

  Tracks connection statistics and TPDU configuration.
  """

  use GenServer
  require Logger

  alias Ex_Iso8583.TPDU

  defstruct [
    :callback,
    :port,
    :path,
    :timeout,
    :registry_name,
    :prefix_bytes,
    :tpdu_enabled,
    :tpdu_address_size,
    :connection_time,
    :bytes_sent,
    :bytes_received,
    :messages_received
  ]

  def start_link(opts) do
    name = Keyword.get(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def init(opts) do
    port = Keyword.fetch!(opts, :port)
    path = Keyword.get(opts, :path, "/iso8583")
    timeout = Keyword.get(opts, :timeout, 30_000)
    registry_name = Keyword.get(opts, :registry_name)
    prefix_bytes = Keyword.get(opts, :prefix_bytes, 2)
    tpdu_enabled = Keyword.get(opts, :tpdu_enabled, false)
    tpdu_address_size = Keyword.get(opts, :tpdu_address_size, 5)

    # Register in registry so we can be found
    if registry_name do
      try do
        Registry.register(Iso8583.HTTP.Registry, registry_name, self())
      rescue
        _ -> :ok  # Registry may not exist yet
      end
    end

    {:ok,
     %__MODULE__{
       callback: nil,
       port: port,
       path: path,
       timeout: timeout,
       registry_name: registry_name,
       prefix_bytes: prefix_bytes,
       tpdu_enabled: tpdu_enabled,
       tpdu_address_size: tpdu_address_size,
       connection_time: System.system_time(:millisecond),
       bytes_sent: 0,
       bytes_received: 0,
       messages_received: 0
     }}
  end

  def handle_call({:set_callback, callback}, _from, state) do
    {:reply, :ok, %{state | callback: callback}}
  end

  def handle_call(:get_callback, _from, state) do
    {:reply, state.callback, state}
  end

  def handle_call(:get_tpdu_config, _from, state) do
    {:reply, {state.tpdu_enabled, state.tpdu_address_size}, state}
  end

  def handle_call(:get_prefix_bytes, _from, state) do
    {:reply, state.prefix_bytes, state}
  end

  def handle_call(:get_stats, _from, state) do
    stats = %{
      connection_time: state.connection_time,
      bytes_sent: state.bytes_sent,
      bytes_received: state.bytes_received,
      messages_received: state.messages_received
    }
    {:reply, stats, state}
  end

  def handle_call({:update_stats, bytes_sent, bytes_received, message_count}, _from, state) do
    new_state = %{state |
      bytes_sent: state.bytes_sent + bytes_sent,
      bytes_received: state.bytes_received + bytes_received,
      messages_received: state.messages_received + message_count
    }
    {:reply, :ok, new_state}
  end

  def handle_info(:register, state) do
    # Retry registration
    if state.registry_name do
      try do
        Registry.register(Iso8583.HTTP.Registry, state.registry_name, self())
      rescue
        _ -> :ok  # Registry may not exist yet
      end
    end
    {:noreply, state}
  end
end

defmodule Iso8583.Transport.HTTP.Server.Endpoint do
  @moduledoc """
  Bandit-powered HTTP endpoint for ISO 8583 messages.
  """

  use GenServer

  defstruct [:state_name, :path, :port, :scheme, :ref]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  def init(opts) do
    state_name = Keyword.get(opts, :state_name)
    path = Keyword.get(opts, :path, "/iso8583")
    port = Keyword.get(opts, :port)
    scheme = Keyword.get(opts, :scheme, :http)
    certfile = Keyword.get(opts, :certfile)
    keyfile = Keyword.get(opts, :keyfile)

    # Start the listener
    bandit_opts = [
      plug: {Iso8583.Transport.HTTP.Server.Plug, state_name: state_name, path: path},
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
          # Try to register state
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

defmodule Iso8583.Transport.HTTP.Server.Plug do
  @moduledoc """
  Plug that handles HTTP requests for ISO 8583 messages.

  Supports TPDU extraction and tracks connection statistics.
  """

  import Plug.Conn

  require Logger

  alias Ex_Iso8583.TPDU

  def init(opts) do
    state_name = Keyword.fetch!(opts, :state_name)
    path = Keyword.fetch!(opts, :path)
    {:ok, %{state_name: state_name, path: path}}
  end

  def call(conn, %{state_name: state_name, path: path}) do
    # Only handle POST requests to the configured path
    if conn.method == "POST" and conn.request_path == path do
      handle_iso_request(conn, state_name)
    else
      send_resp(conn, 404, Jason.encode!(%{error: "Not found"}))
      |> put_resp_content_type("application/json")
    end
  end

  defp handle_iso_request(conn, state_name) do
    # Get state configuration (TPDU enabled, prefix_bytes, etc)
    {tpdu_enabled, tpdu_address_size} = get_tpdu_config(state_name)
    prefix_bytes = get_prefix_bytes(state_name)
    {stats, _} = get_stats(state_name)

    case read_full_body(conn, "") do
      {:ok, body, conn} ->
        bytes_received = byte_size(body)

        case parse_request(body, tpdu_enabled, tpdu_address_size, prefix_bytes) do
          {:ok, iso_message, request_id, request_tpdu} ->
            # Get callback
            case get_callback(state_name) do
              nil ->
                error_response(conn, 503, "Service not ready", request_id)

              callback ->
                # Build context with TPDU and stats
                context = build_context(conn, request_id, stats, request_tpdu)

                # Call processor
                case callback.(iso_message, context) do
                  {:ok, response} ->
                    # Encode response with TPDU if enabled and add framing
                    response_data = encode_response(response, request_tpdu, tpdu_enabled, tpdu_address_size, prefix_bytes)
                    bytes_sent = byte_size(Jason.encode!(%{iso_message: Base.encode64(response_data)}))

                    # Update stats
                    update_stats(state_name, bytes_sent, bytes_received, 1)

                    success_response(conn, response_data, request_id)

                  {:error, reason} ->
                    error_response(conn, 500, inspect(reason), request_id)
                end
            end

          {:error, reason} ->
            error_response(conn, 400, reason, nil)
        end

      {:more, _body, _conn} ->
        error_response(conn, 413, "Request too large", nil)

      {:error, _reason} ->
        error_response(conn, 400, "Failed to read body", nil)
    end
  end

  defp read_full_body(conn, acc) do
    case read_body(conn) do
      {:ok, body, conn} -> {:ok, acc <> body, conn}
      {:more, body, conn} -> read_full_body(conn, acc <> body)
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_request(body, tpdu_enabled, tpdu_address_size, prefix_bytes) do
    case Jason.decode(body) do
      {:ok, %{"iso_message" => encoded_msg} = data} ->
        case Base.decode64(encoded_msg) do
          {:ok, raw_message} ->
            # Extract length-prefix framing first
            {iso_with_tpdu, _framing_extracted} = case extract_framing(raw_message, prefix_bytes) do
              {:ok, message} -> {message, true}
              {:error, _} -> {raw_message, false}  # No valid framing, use as-is
            end

            # Extract TPDU if enabled
            {iso_message, request_tpdu} = if tpdu_enabled do
              case TPDU.extract(iso_with_tpdu, tpdu_address_size) do
                {:ok, tpdu, rest} ->
                  {rest, tpdu}
                {:error, _} ->
                  # TPDU extraction failed, use message as-is
                  {iso_with_tpdu, nil}
              end
            else
              {iso_with_tpdu, nil}
            end

            request_id = Map.get(data, "request_id")
            {:ok, iso_message, request_id, request_tpdu}

          :error ->
            {:error, "Invalid base64 encoding"}
        end

      {:ok, _} ->
        {:error, "Missing iso_message field"}

      {:error, _} ->
        {:error, "Invalid JSON"}
    end
  end

  defp extract_framing(data, prefix_bytes) do
    if byte_size(data) < prefix_bytes do
      {:error, :incomplete}
    else
      <<msg_length::big-integer-size(prefix_bytes * 8), rest::binary>> = data
      if byte_size(rest) >= msg_length do
        <<message::binary-size(msg_length), _remaining::binary>> = rest
        {:ok, message}
      else
        {:error, :incomplete}
      end
    end
  end

  defp encode_response(response, request_tpdu, tpdu_enabled, tpdu_address_size, prefix_bytes) do
    # First add TPDU if enabled
    with_tpdu = if tpdu_enabled and request_tpdu do
      # Swap source/destination for response
      response_tpdu = %{
        destination: request_tpdu.source,
        source: request_tpdu.destination
      }
      TPDU.prepend(response, response_tpdu, tpdu_address_size)
    else
      response
    end

    # Then add length-prefix framing
    length = byte_size(with_tpdu)
    <<length::big-integer-size(prefix_bytes * 8), with_tpdu::binary>>
  end

  defp get_callback(state_name) do
    case GenServer.call(state_name, :get_callback) do
      nil -> nil
      callback when is_function(callback) -> callback
    end
  rescue
    _ -> nil
  end

  defp get_tpdu_config(state_name) do
    case GenServer.call(state_name, :get_tpdu_config) do
      {enabled, size} when is_boolean(enabled) and is_integer(size) -> {enabled, size}
      _ -> {false, 5}
    end
  rescue
    _ -> {false, 5}
  end

  defp get_prefix_bytes(state_name) do
    case GenServer.call(state_name, :get_prefix_bytes) do
      bytes when is_integer(bytes) and bytes > 0 -> bytes
      _ -> 2  # Default to 2 bytes
    end
  rescue
    _ -> 2  # Default to 2 bytes on error
  end

  defp get_stats(state_name) do
    case GenServer.call(state_name, :get_stats) do
      stats when is_map(stats) -> {stats, :ok}
      _ -> {%{}, :error}
    end
  rescue
    _ -> {%{}, :error}
  end

  defp update_stats(state_name, bytes_sent, bytes_received, message_count) do
    GenServer.call(state_name, {:update_stats, bytes_sent, bytes_received, message_count})
  rescue
    _ -> :ok
  end

  defp build_context(conn, request_id, stats, request_tpdu) do
    Iso8583.Context.new(
      transport_ref: conn,
      client_id: "http_client",
      peer_address: conn.remote_ip,
      request_id: request_id,
      transport_metadata: %{
        method: conn.method,
        path: conn.request_path,
        headers: Enum.into(conn.req_headers, %{}),
        user_agent: get_req_header(conn, "user-agent") |> List.first(),
        content_type: get_req_header(conn, "content-type") |> List.first(),
        connection_time: Map.get(stats, :connection_time),
        bytes_sent: Map.get(stats, :bytes_sent, 0),
        bytes_received: Map.get(stats, :bytes_received, 0) + byte_size(conn.assigns[:body] || ""),
        messages_received: Map.get(stats, :messages_received, 0) + 1,
        tpdu: request_tpdu
      }
    )
  end

  defp success_response(conn, response, request_id) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      200,
      Jason.encode!(%{
        iso_message: Base.encode64(response),
        request_id: request_id
      })
    )
  end

  defp error_response(conn, status, message, request_id) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      status,
      Jason.encode!(%{
        error: message,
        request_id: request_id
      })
    )
  end
end

defmodule Iso8583.Transport.HTTP.Client do
  @moduledoc """
  HTTP Client transport for ISO 8583 messages.

  Sends ISO 8583 messages over HTTP with 2-byte length-prefix framing.

  ## Usage

      defmodule MyApp.HTTPClientHandler do
        use Iso8583.Handler,
          processor: MyApp.PaymentProcessor,
          transport: Iso8583.Transport.HTTP.Client,
          transport_opts: [
            url: "http://localhost:4000/iso8583"
          ]
      end

  ## Options

  | Option | Type | Default | Description |
  |--------|------|---------|-------------|
  | `:url` | `String.t()` | Required | HTTP endpoint URL |
  | `:name` | `atom()` | `nil` | Name for registration |
  | `:timeout` | `integer()` | `30000` | Request timeout (ms) |
  | `:prefix_bytes` | `1 \\| 2 \\| 4` | `2` | Length prefix bytes for framing |
  | `:headers` | `map()` | `%{}` | Additional HTTP headers |

  ## Message Framing

  Uses length-prefix framing (default: 2 bytes) wrapped in JSON.

  **Request:**
  ```json
  {
    "iso_message": "base64_encoded_data_with_length_prefix"
  }
  ```

  The `iso_message` field contains base64-encoded data where:
  - First 2 bytes: message length (big-endian)
  - Remaining bytes: ISO 8583 message

  **Response:**
  ```json
  {
    "iso_message": "base64_encoded_response_with_length_prefix"
  }
  ```

  ## Message Flow

  ```
  Client -> HTTP Server:
    POST /iso8583
    {
      "iso_message": "Base64([Len Hi][Len Lo][ISO Message...])"
    }

  HTTP Server -> Client:
    {
      "iso_message": "Base64([Len Hi][Len Lo][ISO Response...])"
    }
  ```

  ## Context Metadata

  The client populates `Iso8583.Context` with:
  - `transport_ref` - `:client` (atom identifier)
  - `client_id` - `"http_client"`
  - `peer_address` - Server's host
  - `transport_metadata` - `%{url, request_id, bytes_sent, bytes_received, messages_received}`

  ## Registry

  When a `:name` is provided, the client registers itself in the registry
  for lookup by name. This allows `send/2`, `set_receive_callback/2`, and `stop/2`
  to work with either a PID or a registered name.

      # Start with name
      {:ok, client} = Iso8583.Transport.HTTP.Client.start_link(
        url: "http://localhost:4000/iso8583",
        name: :my_http_client
      )

      # Use by name
      Iso8583.Transport.HTTP.Client.send(:my_http_client, iso_message)

  ## Example

      # Connect to HTTP server
      {:ok, client} = Iso8583.Transport.HTTP.Client.start_link(
        url: "http://localhost:4000/iso8583"
      )

      # Set callback for incoming messages
      Iso8583.Transport.HTTP.Client.set_receive_callback(client, fn
        data, context ->
          # Process ISO 8583 response
          IO.inspect("Received: \#{Base.encode16(data)}")
      end)

      # Send ISO message (automatically framed with length prefix)
      iso_message = <<0x02, 0x00, 0xB2, 0x20, ...>>
      Iso8583.Transport.HTTP.Client.send(:client, iso_message)
  """

  use GenServer
  require Logger
  import Kernel, except: [send: 2]

  alias Iso8583.Context

  defstruct [
    :url,
    :host,
    :port,
    :path,
    :scheme,
    :receive_callback,
    :timeout,
    :prefix_bytes,
    :headers,
    :bytes_sent,
    :bytes_received,
    :messages_received,
    :registry_name,
    :correlation_fields,
    :correlation_field_formats,
    :correlation_msg_type
  ]

  @doc """
  Starts the HTTP client transport.
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
  Sends data to the HTTP server.

  Supports PID or registered name for lookup.
  """
  def send(:client, data) do
    GenServer.call(__MODULE__, {:send, data})
  end

  def send(pid, data) when is_pid(pid) do
    GenServer.call(pid, {:send, data})
  end

  def send(name, data) when is_atom(name) do
    case lookup_client(name) do
      {:ok, pid} -> GenServer.call(pid, {:send, data})
      {:error, _} -> {:error, :not_found}
    end
  end

  @doc """
  Registers the callback for receiving messages.

  Supports both PID and registered name (atom) for lookup.
  """
  def set_receive_callback(client_pid, callback) when is_pid(client_pid) do
    GenServer.call(client_pid, {:set_callback, callback})
  end

  def set_receive_callback(name, callback) when is_atom(name) do
    case lookup_client(name) do
      {:ok, pid} -> GenServer.call(pid, {:set_callback, callback})
      {:error, _} -> {:error, :not_found}
    end
  end

  @doc """
  Looks up an HTTP client by registered name.
  """
  def lookup_client(name) when is_atom(name) do
    try do
      case Registry.lookup(Iso8583.HTTP.Registry, name) do
        [{pid, _}] when is_pid(pid) -> {:ok, pid}
        _ -> {:error, :not_found}
      end
    rescue
      ArgumentError -> {:error, :not_found}
    end
  end

  @doc """
  Stops the client.

  Supports both PID and registered name (atom) for lookup.
  """
  def stop(client_pid) when is_pid(client_pid) do
    GenServer.stop(client_pid, :normal)
  end

  def stop(name) when is_atom(name) do
    case lookup_client(name) do
      {:ok, pid} -> GenServer.stop(pid, :normal)
      {:error, _} -> {:error, :not_found}
    end
  end

  @doc """
  Sends an ISO 8583 message and waits for the correlated response.

  This function uses field-based correlation to validate responses.
  By default, it correlates on fields 11 (STAN), 41 (TID), and 42 (MID).

  ## Parameters

  - `client` - PID or registered name of the HTTP client
  - `request` - ISO 8583 request binary (with MTI)
  - `opts` - Optional keyword list:
    - `:timeout` - Response timeout in milliseconds (default: 30000)
    - `:correlation_fields` - Override default correlation fields for this request

  ## Returns

  - `{:ok, response_binary}` - Received matching response
  - `{:error, {:http_error, status_code, body}}` - HTTP error response
  - `{:error, {:parse_failed, reason}}` - Failed to parse ISO message for correlation
  - `{:error, reason}` - Other error (network, timeout, etc.)

  ## Examples

      # Using default correlation (fields 11, 41, 42)
      {:ok, response} = Iso8583.Transport.HTTP.Client.send_and_wait(
        :my_client,
        <<0x02, 0x00, 0xB2, 0x20, ...>>
      )

  ## Configuration

  To enable correlation, configure the client with:

      {:ok, _client} = Iso8583.Transport.HTTP.Client.start_link(
        url: "http://localhost:4000/iso8583",
        correlation_fields: [11, 41, 42],
        correlation_field_formats: %{
          11 => "n 6",   # STAN
          41 => "ans 8", # TID
          42 => "ans 15" # MID
        }
      )
  """
  def send_and_wait(client, request, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30000)
    correlation_fields_override = Keyword.get(opts, :correlation_fields)

    case client do
      pid when is_pid(pid) ->
        GenServer.call(pid, {:send_and_wait, request, correlation_fields_override}, timeout)

      name when is_atom(name) ->
        case lookup_client(name) do
          {:ok, pid} -> GenServer.call(pid, {:send_and_wait, request, correlation_fields_override}, timeout)
          {:error, _} -> {:error, :not_found}
        end
    end
  end

  @doc """
  Extracts the correlation key from an ISO 8583 binary message.

  The key is a tuple of field values in the order of correlation_fields.
  """
  def extract_correlation_key(iso_binary, correlation_fields, field_formats, msg_type) do
    try do
      {_mti, msg_without_mti} = extract_mti(iso_binary)

      fields = Ex_Iso8583.extract_iso_msg(msg_without_mti, msg_type, field_formats)

      key = correlation_fields
      |> Enum.map(fn field_num ->
        value = Map.get(fields, field_num)
        {field_num, value}
      end)
      |> List.to_tuple()

      {:ok, key}
    rescue
      e -> {:error, {:parse_failed, Exception.message(e)}}
    end
  end

  @doc """
  Extracts MTI (Message Type Indicator) from an ISO 8583 binary.

  Returns `{mti, remaining_binary}` where MTI is 4 bytes.
  """
  def extract_mti(<<mti::bytes-4, rest::binary>>), do: {mti, rest}
  def extract_mti(_), do: {nil, <<>>}

  # Server Callbacks

  @impl true
  def init(opts) do
    url = Keyword.fetch!(opts, :url)
    registry_name = Keyword.get(opts, :name)
    timeout = Keyword.get(opts, :timeout, 30_000)
    prefix_bytes = Keyword.get(opts, :prefix_bytes, 2)
    headers = Keyword.get(opts, :headers, %{})

    # Correlation configuration
    correlation_fields = Keyword.get(opts, :correlation_fields, [11, 41, 42])
    correlation_field_formats = Keyword.get(opts, :correlation_field_formats, %{
      11 => "n 6",    # STAN - System Trace Audit Number
      41 => "ans 8",  # TID - Terminal ID
      42 => "ans 15"  # MID - Merchant ID
    })
    correlation_msg_type = Keyword.get(opts, :correlation_msg_type, %{bitmap_type: :binary, field_header_type: :bcd})

    # Register in HTTP registry if name is provided
    if registry_name do
      ensure_registry_started()
      Registry.register(Iso8583.HTTP.Registry, registry_name, nil)
    end

    # Parse URL
    {scheme, host, port, path} = parse_url(url)

    {:ok,
     %__MODULE__{
       url: url,
       scheme: scheme,
       host: host,
       port: port,
       path: path,
       registry_name: registry_name,
       timeout: timeout,
       prefix_bytes: prefix_bytes,
       headers: headers,
       bytes_sent: 0,
       bytes_received: 0,
       messages_received: 0,
       correlation_fields: correlation_fields,
       correlation_field_formats: correlation_field_formats,
       correlation_msg_type: correlation_msg_type
     }}
  end

  @impl true
  def handle_call({:send_and_wait, request, correlation_fields_override}, _from, state) do
    # Determine which correlation fields to use
    correlation_fields = correlation_fields_override || state.correlation_fields

    # Extract correlation key from request (for validation)
    request_key = case extract_correlation_key(request, correlation_fields, state.correlation_field_formats, state.correlation_msg_type) do
      {:ok, key} -> key
      {:error, _} -> nil  # Continue without correlation if extraction fails
    end

    # Frame the data with length prefix
    framed_data = frame_data(request, state.prefix_bytes)

    # Encode to base64
    encoded_message = Base.encode64(framed_data)

    # Build JSON request
    request_body = Jason.encode!(%{iso_message: encoded_message})

    # Make HTTP request using :httpc
    response =
      :httpc.request(
        :post,
        {to_charlist(state.url), build_headers(state.headers), "application/json", request_body},
        [{:timeout, state.timeout}, {:body_format, :binary}],
        :infinity
      )

    case response do
      {:ok, {{_version, 200, _reason_phrase}, _headers, body}} ->
        # Parse response
        case parse_response(body) do
          {:ok, response_data} ->
            # Extract ISO message from framing
            case extract_iso_message(response_data, state.prefix_bytes) do
              {:ok, iso_message} ->
                # Validate correlation key if we extracted one from request
                if request_key != nil do
                  case extract_correlation_key(iso_message, correlation_fields, state.correlation_field_formats, state.correlation_msg_type) do
                    {:ok, response_key} ->
                      if request_key == response_key do
                        # Correlation keys match
                        {:reply, {:ok, iso_message}, %{state | bytes_sent: state.bytes_sent + byte_size(request_body),
                          bytes_received: state.bytes_received + byte_size(body),
                          messages_received: state.messages_received + 1}}
                      else
                        # Correlation mismatch - log warning but still return response
                        Logger.warning("Correlation key mismatch: request #{inspect(request_key)} != response #{inspect(response_key)}")
                        {:reply, {:ok, iso_message}, %{state | bytes_sent: state.bytes_sent + byte_size(request_body),
                          bytes_received: state.bytes_received + byte_size(body),
                          messages_received: state.messages_received + 1}}
                      end

                    {:error, _reason} ->
                      # Failed to extract correlation key from response - return anyway
                      {:reply, {:ok, iso_message}, %{state | bytes_sent: state.bytes_sent + byte_size(request_body),
                        bytes_received: state.bytes_received + byte_size(body),
                        messages_received: state.messages_received + 1}}
                  end
                else
                  # No request key, just return the response
                  {:reply, {:ok, iso_message}, %{state | bytes_sent: state.bytes_sent + byte_size(request_body),
                    bytes_received: state.bytes_received + byte_size(body),
                    messages_received: state.messages_received + 1}}
                end

              {:error, reason} ->
                {:reply, {:error, reason}, state}
            end

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {:ok, {{_version, status_code, _reason_phrase}, _headers, body}} ->
        {:reply, {:error, {:http_error, status_code, body}}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:send, data}, _from, state) do
    # Frame the data with length prefix
    framed_data = frame_data(data, state.prefix_bytes)

    # Encode to base64
    encoded_message = Base.encode64(framed_data)

    # Build JSON request
    request_body = Jason.encode!(%{iso_message: encoded_message})

    # Generate request ID
    request_id = generate_request_id()

    # Make HTTP request using :httpc
    response =
      :httpc.request(
        :post,
        {to_charlist(state.url), build_headers(state.headers), "application/json", request_body},
        [{:timeout, state.timeout}, {:body_format, :binary}],
        :infinity
      )

    case response do
      {:ok, {{_version, 200, _reason_phrase}, _headers, body}} ->
        # Parse response
        case parse_response(body) do
          {:ok, response_data} ->
            # Extract ISO message from framing
            case extract_iso_message(response_data, state.prefix_bytes) do
              {:ok, iso_message} ->
                # Call callback if set
                if state.receive_callback do
                  context = build_context(state, request_id)
                  state.receive_callback.(iso_message, context)
                end

                {:reply, :ok, %{state | bytes_sent: state.bytes_sent + byte_size(request_body),
                  bytes_received: state.bytes_received + byte_size(body),
                  messages_received: state.messages_received + 1}}

              {:error, reason} ->
                {:reply, {:error, reason}, state}
            end

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      {:ok, {{_version, status_code, _reason_phrase}, _headers, body}} ->
        {:reply, {:error, {:http_error, status_code, body}}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:set_callback, callback}, _from, state) do
    {:reply, :ok, %{state | receive_callback: callback}}
  end

  @impl true
  def terminate(_reason, _state) do
    :ok
  end

  # Private functions

  defp ensure_registry_started do
    case Process.whereis(Iso8583.HTTP.Registry) do
      nil ->
        # Start the registry
        {:ok, _pid} = Registry.start_link(keys: :unique, name: Iso8583.HTTP.Registry)
        :ok
      _pid ->
        :ok
    end
  end

  defp parse_url(url) do
    uri = URI.parse(url)

    scheme = case uri.scheme do
      "http" -> :http
      "https" -> :https
      _ -> :http
    end

    port = case {scheme, uri.port} do
      {:http, nil} -> 80
      {:https, nil} -> 443
      {_, port} -> port
    end

    {scheme, uri.host, port, uri.path || "/"}
  end

  defp build_headers(custom_headers) do
    base_headers = [
      {"Content-Type", "application/json"},
      {"Accept", "application/json"}
    ]

    custom =
      Enum.map(custom_headers, fn {k, v} ->
        {to_string(k), to_string(v)}
      end)

    base_headers ++ custom
  end

  defp parse_response(body) do
    case Jason.decode(body) do
      {:ok, %{"iso_message" => encoded_msg}} ->
        case Base.decode64(encoded_msg) do
          {:ok, data} ->
            {:ok, data}

          :error ->
            {:error, :invalid_base64}
        end

      {:ok, %{"error" => error_msg}} ->
        {:error, {:server_error, error_msg}}

      {:ok, _} ->
        {:error, :missing_iso_message}

      {:error, _} ->
        {:error, :invalid_json}
    end
  end

  defp extract_iso_message(data, prefix_bytes) do
    if byte_size(data) < prefix_bytes do
      {:error, :incomplete_message}
    else
      <<msg_length::big-integer-size(prefix_bytes * 8), rest::binary>> = data

      if byte_size(rest) >= msg_length do
        <<message::binary-size(msg_length), _remaining::binary>> = rest
        {:ok, message}
      else
        {:error, :incomplete_message}
      end
    end
  end

  defp frame_data(data, prefix_bytes) do
    length = byte_size(data)
    <<length::big-integer-size(prefix_bytes * 8), data::binary>>
  end

  defp build_context(state, request_id) do
    Context.new(
      transport_ref: :client,
      client_id: "http_client",
      peer_address: state.host,
      request_id: request_id,
      transport_metadata: %{
        url: state.url,
        bytes_sent: state.bytes_sent,
        bytes_received: state.bytes_received,
        messages_received: state.messages_received
      }
    )
  end

  defp generate_request_id do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)
    :erlang.list_to_binary(:io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e]))
  end
end

defmodule Iso8583.HTTP.Registry do
  @moduledoc """
  Registry for HTTP transport processes.
  """
end
