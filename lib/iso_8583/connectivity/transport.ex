defmodule Iso8583.Transport do
  @moduledoc """
  Behaviour for ISO 8583 transport implementations.

  A transport handles how ISO 8583 messages are sent and received.
  Implementations can be:

  - **Connection-oriented** (TCP Server, TCP Client)
  - **Connectionless** (UDP Server, UDP Client)
  - **Request/Response** (HTTP Client)
  - **Streaming** (HTTP Server with streaming response)

  ## Architecture

      ┌─────────────────────────────────────────────────────────────┐
      │                     Iso8583.Handler                          │
      │  (Connects Processor + Transport, handles message flow)     │
      └─────────────────────────────────────────────────────────────┘
                                  │
                    ┌─────────────┴─────────────┐
                    │                           │
          Implements @callback               @callback
                    │                           │
      ┌─────────────────────┐       ┌─────────────────────┐
      │   TCP.Server        │       │   TCP.Client        │
      │   (accepts conns)   │       │   (connects out)    │
      └─────────────────────┘       └─────────────────────┘

  ## Implementing a Transport

  To create a custom transport, implement this behaviour:

      defmodule MyCustomTransport do
        @behaviour Iso8583.Transport

        @impl true
        def start_link(opts) do
          # Start your transport (e.g., listen on port, connect to remote)
          {:ok, pid}
        end

        @impl true
        def child_spec(opts) do
          # Define how this transport fits into a supervision tree
          %{
            id: __MODULE__,
            start: {__MODULE__, :start_link, [opts]},
            restart: :permanent,
            type: :worker
          }
        end

        @impl true
        def send(transport_ref, data) do
          # Send raw ISO 8583 binary data
          # For servers: send response to client
          # For clients: send request to remote
          :ok
        end

        @impl true
        def set_receive_callback(transport_pid, callback) do
          # Register callback: (raw_message, context) -> term()
          # Called when a message arrives
          :ok
        end

        @impl true
        def stop(transport_pid) do
          # Gracefully stop the transport
          :ok
        end
      end

  ## Callbacks

  ### `start_link/1`

  Starts the transport process.

  **Parameters:**
  - `opts` - Keyword list of transport-specific options

  **Returns:** `{:ok, pid} | {:error, reason}`

  ### `child_spec/1`

  Defines how the transport can be added to a supervision tree.

  **Parameters:**
  - `opts` - Keyword list of transport-specific options

  **Returns:** A `Supervisor.child_spec/0` map

  ### `send/2`

  Sends raw ISO 8583 binary data.

  **Parameters:**
  - `transport_ref` - Transport-specific reference (socket, connection ID, etc.)
  - `data` - Raw ISO 8583 binary message to send

  **Returns:** `:ok | {:ok, reference} | {:error, reason}`

  ### `set_receive_callback/2`

  Registers a callback function to handle incoming messages.

  **Parameters:**
  - `transport_pid` - PID of the transport process
  - `callback` - Function `(raw_message :: binary(), context :: Iso8583.Context.t()) -> term()`

  **Returns:** `:ok | {:error, reason}`

  ### `stop/1`

  Stops the transport process.

  **Parameters:**
  - `transport_pid_or_atom` - PID or name of the transport process

  **Returns:** `:ok`

  ## Built-in Transports

  | Module | Type | Description |
  |--------|------|-------------|
  | `Iso8583.Transport.TCP.Server` | Server | Accept TCP connections from clients |
  | `Iso8583.Transport.TCP.Client` | Client | Connect to TCP server |
  | `Iso8583.Transport.UDP.Server` | Server | Receive UDP datagrams |
  | `Iso8583.Transport.UDP.Client` | Client | Send UDP datagrams |
  | `Iso8583.Transport.HTTP.Server` | Server | HTTP server (Plug/Bandit) |
  | `Iso8583.Transport.HTTP.Client` | Client | HTTP client (Finch/Req) |

  ## Transport Metadata in Context

  Each transport should populate the `Iso8583.Context` with relevant metadata:

  | Transport | Context.transport_ref | Context.transport_metadata |
  |-----------|----------------------|----------------------------|
  | TCP Server | `socket` (port) | `connection_time`, `bytes_received` |
  | TCP Client | `socket` (port) | `connection_time`, `bytes_sent` |
  | UDP Server | `socket` (port) | `peer_port`, `datagram_size` |
  | UDP Client | `socket` (port) | `peer_port` |
  | HTTP Server | `Plug.Conn` | `method`, `path`, `headers` |
  | HTTP Client | `request_ref` | `status_code`, `response_time` |

  ## Example: Using a Transport with Handler

      defmodule MyApp.PaymentHandler do
        use Iso8583.Handler,
          processor: MyApp.PaymentProcessor,
          transport: Iso8583.Transport.TCP.Server,
          transport_opts: [
            port: 8080,
            acceptors: 10,
            packet_handler: &MyApp.PacketHandler.handle/2
          ]
      end

      # In your application supervision tree
      children = [
        MyApp.PaymentHandler
      ]

  """

  @doc """
  Starts the transport process.

  Implementations should initialize their transport (e.g., listen on port,
  connect to remote server, start HTTP server).

  ## Parameters

  - `opts` - Keyword list of transport-specific options

  ## Returns

  - `{:ok, pid}` - Transport started successfully
  - `{:error, reason}` - Failed to start

  """
  @callback start_link(opts :: keyword()) :: Supervisor.on_start()

  @doc """
  Defines how the transport can be added to a supervision tree.

  Should return a child specification map.

  ## Parameters

  - `opts` - Keyword list of transport-specific options

  ## Returns

  A `Supervisor.child_spec/0` map with keys: `:id`, `:start`, `:restart`, `:type`

  """
  @callback child_spec(opts :: keyword()) :: Supervisor.child_spec()

  @doc """
  Sends raw ISO 8583 binary data.

  For **servers**: sends response to a connected client
  For **clients**: sends request to remote endpoint

  ## Parameters

  - `transport_ref` - Transport-specific reference (socket, connection ID, etc.)
  - `data` - Raw ISO 8583 binary message

  ## Returns

  - `:ok` - Message sent successfully
  - `{:ok, reference}` - Message sent, reference returned for tracking
  - `{:error, reason}` - Failed to send

  """
  @callback send(transport_ref :: term(), data :: binary()) :: :ok | {:ok, term()} | {:error, term()}

  @doc """
  Registers a callback for handling incoming messages.

  The callback will be invoked with:
  - `raw_message` - The raw ISO 8583 binary message
  - `context` - An `Iso8583.Context.t()` with transport metadata

  ## Parameters

  - `transport_pid` - PID of the transport process
  - `callback` - Function `(binary(), Iso8583.Context.t()) -> term()`

  ## Returns

  - `:ok` - Callback registered successfully
  - `{:error, reason}` - Failed to register callback

  """
  @callback set_receive_callback(transport_pid :: pid(), callback :: function()) :: :ok | {:error, term()}

  @doc """
  Stops the transport process.

  Should gracefully shut down the transport, closing connections
  and releasing resources.

  ## Parameters

  - `transport_pid_or_atom` - PID or registered name of the transport

  ## Returns

  - `:ok` - Stopped successfully

  """
  @callback stop(transport_pid_or_atom :: pid() | atom()) :: :ok

  @optional_callbacks [child_spec: 1, stop: 1]
end
