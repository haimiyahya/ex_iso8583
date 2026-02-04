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

  ## Context Metadata

  The server populates `Iso8583.Context` with:
  - `transport_ref` - The `Plug.Conn` struct
  - `client_id` - "http_client"
  - `peer_address` - Client's IP address from conn.remote_ip
  - `transport_metadata` - `%{method, path, headers, request_id}`

  """

  use Supervisor

  alias Iso8583.Context

  defstruct [
    :port,
    :path,
    :scheme,
    :timeout,
    :name,
    :certfile,
    :keyfile,
    :receive_callback
  ]

  # Client API

  @doc """
  Starts the HTTP server transport.
  """
  @impl true
  def start_link(opts) do
    port = Keyword.fetch!(opts, :port)
    path = Keyword.get(opts, :path, "/iso8583")
    scheme = Keyword.get(opts, :scheme, :http)
    timeout = Keyword.get(opts, :timeout, 30_000)
    name = Keyword.get(opts, :name)
    certfile = Keyword.get(opts, :certfile)
    keyfile = Keyword.get(opts, :keyfile)

    Supervisor.start_link(
      __MODULE__,
      [
        port: port,
        path: path,
        scheme: scheme,
        timeout: timeout,
        name: name,
        certfile: certfile,
        keyfile: keyfile
      ],
      name: name
    )
  end

  @doc """
  Returns the child spec for supervision.
  """
  @impl true
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
  @impl true
  def send(_conn, _data), do: :ok

  @doc """
  Registers the callback for receiving messages.
  """
  @impl true
  def set_receive_callback(server_pid, callback) when is_pid(server_pid) do
    GenServer.call(server_pid, {:set_callback, callback})
  end

  def set_receive_callback(name, callback) when is_atom(name) do
    # Find the state process via registry
    case Registry.lookup(Iso8583.HTTP.Registry, name) do
      [{pid, _}] -> GenServer.call(pid, {:set_callback, callback})
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Stops the server.
  """
  @impl true
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
    path = Keyword.get(opts, :path, "/iso8583")
    scheme = Keyword.get(opts, :scheme, :http)
    timeout = Keyword.get(opts, :timeout, 30_000)
    name = Keyword.get(opts, :name)
    certfile = Keyword.get(opts, :certfile)
    keyfile = Keyword.get(opts, :keyfile)

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
  """

  use GenServer

  defstruct [:callback, :port, :path, :timeout, :registry_name]

  def start_link(opts) do
    name = Keyword.get(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def init(opts) do
    port = Keyword.fetch!(opts, :port)
    path = Keyword.get(opts, :path, "/iso8583")
    timeout = Keyword.get(opts, :timeout, 30_000)
    registry_name = Keyword.get(opts, :registry_name)

    # Register in registry so we can be found
    if registry_name do
      try do
        Registry.register(Iso8583.HTTP.Registry, registry_name, self())
      rescue
        _ -> :ok  # Registry may not exist yet
      end
    end

    {:ok, %__MODULE__{callback: nil, port: port, path: path, timeout: timeout, registry_name: registry_name}}
  end

  def handle_call({:set_callback, callback}, _from, state) do
    {:reply, :ok, %{state | callback: callback}}
  end

  def handle_call(:get_callback, _from, state) do
    {:reply, state.callback, state}
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

    case Bandit.start_link(bandit_opts) do
      {:ok, pid} ->
        # Try to register state
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

defmodule Iso8583.Transport.HTTP.Server.Plug do
  @moduledoc """
  Plug that handles HTTP requests for ISO 8583 messages.
  """

  import Plug.Conn

  require Logger

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
    case read_full_body(conn, "") do
      {:ok, body, conn} ->
        case parse_request(body) do
          {:ok, iso_message, request_id} ->
            # Get callback
            case get_callback(state_name) do
              nil ->
                error_response(conn, 503, "Service not ready", request_id)

              callback ->
                # Build context
                context = build_context(conn, request_id)

                # Call processor
                case callback.(iso_message, context) do
                  {:ok, response} ->
                    success_response(conn, response, request_id)

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

  defp parse_request(body) do
    case Jason.decode(body) do
      {:ok, %{"iso_message" => encoded_msg} = data} ->
        case Base.decode64(encoded_msg) do
          {:ok, iso_message} ->
            request_id = Map.get(data, "request_id")
            {:ok, iso_message, request_id}

          :error ->
            {:error, "Invalid base64 encoding"}
        end

      {:ok, _} ->
        {:error, "Missing iso_message field"}

      {:error, _} ->
        {:error, "Invalid JSON"}
    end
  end

  defp get_callback(state_name) do
    case GenServer.call(state_name, :get_callback) do
      nil -> nil
      callback when is_function(callback) -> callback
    end
  rescue
    _ -> nil
  end

  defp build_context(conn, request_id) do
    Context.new(
      transport_ref: conn,
      client_id: "http_client",
      peer_address: conn.remote_ip,
      request_id: request_id,
      transport_metadata: %{
        method: conn.method,
        path: conn.request_path,
        headers: Enum.into(conn.req_headers, %{}),
        user_agent: get_req_header(conn, "user-agent") |> List.first(),
        content_type: get_req_header(conn, "content-type") |> List.first()
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

defmodule Iso8583.HTTP.Registry do
  @moduledoc """
  Registry for HTTP transport processes.
  """
end
