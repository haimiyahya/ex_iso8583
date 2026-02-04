defmodule Iso8583.Handler do
  @moduledoc """
  Generic handler that connects Processor + Transport.

  This module provides a `use` macro that creates a GenServer handler
  which:
  1. Starts a transport (TCP, HTTP, UDP, etc.)
  2. Receives messages from the transport
  3. Processes them using the provided processor
  4. Sends responses back through the transport

  ## Architecture

      ┌─────────────────────────────────────────────────────────────┐
      │                      Your Application                       │
      └─────────────────────────────────────────────────────────────┘
                                  │
      ┌─────────────────────────────────────────────────────────────┐
      │                     Iso8583.Handler                         │
      │  - Uses your TransactionProcessor                          │
      │  - Uses your chosen Transport                              │
      │  - Connects them together                                  │
      └─────────────────────────────────────────────────────────────┘
                          │               │
              ┌───────────┘               └───────────┐
              │                                       │
      ┌─────────────────────┐             ┌─────────────────────┐
      │   TransactionProcessor│             │   Transport         │
      │   (Your business logic)│             │   (TCP/HTTP/UDP)    │
      └─────────────────────┘             └─────────────────────┘

  ## Usage

  Define a handler in your application:

      defmodule MyApp.PaymentHandler do
        use Iso8583.Handler,
          processor: MyApp.PaymentProcessor,
          transport: Iso8583.Transport.TCP.Server,
          transport_opts: [
            port: 8080,
            acceptors: 10
          ]
      end

  Add it to your supervision tree:

      defmodule MyApp.Application do
        use Application

        def start(_type, _args) do
          children = [
            # TCP Server - accepts connections from terminals
            MyApp.PaymentHandler,

            # HTTP Server - for REST API
            {Iso8583.Handler,
             processor: MyApp.PaymentProcessor,
             transport: Iso8583.Transport.HTTP.Server,
             transport_opts: [port: 4000]},

            # TCP Client - connects to upstream acquirer
            {Iso8583.Handler,
             processor: MyApp.UpstreamProcessor,
             transport: Iso8583.Transport.TCP.Client,
             transport_opts: [
               host: "acquirer.example.com",
               port: 9000
             ]}
          ]

          opts = [strategy: :one_for_one]
          Supervisor.start_link(children, opts)
        end
      end

  ## Options

  When using `Iso8583.Handler`, you must provide:

  | Option | Type | Required | Description |
  |--------|------|----------|-------------|
  | `:processor` | `module()` | Yes | TransactionProcessor module to use |
  | `:transport` | `module()` | Yes | Transport module (implements `Iso8583.Transport`) |
  | `:transport_opts` | `keyword()` | No | Options passed to transport |

  Optional options:

  | Option | Type | Default | Description |
  |--------|------|---------|-------------|
  | `:name` | `atom()` | `nil` | Name for GenServer registration |
  | `:log_level` | `atom()` | `:info` | Log level for messages (`:debug`, `:info`, `:warn`, `:error`) |

  ## Message Flow

      1. Transport receives raw ISO message
      2. Transport calls receive callback (Handler)
      3. Handler calls Processor.process_with_timeout/2
      4. Processor returns {:ok, response} or {:error, reason}
      5. Handler calls Transport.send/2 to send response
      6. Response sent back to client

  ## Error Handling

  The handler handles different error scenarios:

  | Error | Handler Behavior |
  |-------|-----------------|
  | Parse error | Log error, optionally send error response |
  | Processing error | Log error, optionally send error response |
  | Timeout | Processor already returns timeout response |
  | Send error | Log error, connection may be closed by transport |

  ## Customizing Behavior

  You can override the default behavior by implementing callbacks:

      defmodule MyApp.CustomHandler do
        use Iso8583.Handler,
          processor: MyApp.PaymentProcessor,
          transport: Iso8583.Transport.TCP.Server,
          transport_opts: [port: 8080]

        # Override to add custom logging
        def handle_receive(raw_message, context) do
          # Your custom logging here
          super(raw_message, context)
        end

        # Override to add metrics
        def handle_response({:ok, response}, context, start_time) do
          # Your custom metrics here
          super({:ok, response}, context, start_time)
        end

        def handle_response({:error, reason}, _context, _start_time) do
          # Your error handling here
        end
      end

  ## Overridable Callbacks

  - `handle_receive/2` - Called when message received from transport
  - `handle_response/3` - Called with processing result
  - `handle_send_error/2` - Called when sending response fails

  """

  alias Iso8583.Context

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      use GenServer
      require Logger

      @processor Keyword.fetch!(opts, :processor)
      @transport Keyword.fetch!(opts, :transport)
      @transport_opts Keyword.get(opts, :transport_opts, [])
      @log_level Keyword.get(opts, :log_level, :info)

      @doc """
      Starts the handler.
      """
      def start_link(opts \\ []) do
        {handler_opts, transport_opts} = Keyword.split(opts, [:name, :log_level])

        # Start transport first
        case @transport.start_link(@transport_opts ++ transport_opts) do
          {:ok, transport_pid} ->
            # Start handler with transport
            handler_opts =
              handler_opts
              |> Keyword.put(:transport, transport_pid)
              |> Keyword.put(:log_level, Keyword.get(handler_opts, :log_level, @log_level))

            GenServer.start_link(__MODULE__, handler_opts, handler_opts)

          {:error, reason} ->
            {:error, {:transport_start_failed, reason}}
        end
      end

      @doc """
      Returns the handler's child spec for supervision.
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
      Returns the processor module.
      """
      def __processor__, do: @processor

      @doc """
      Returns the transport module.
      """
      def __transport__, do: @transport

      @impl true
      def init(opts) do
        transport_pid = Keyword.fetch!(opts, :transport)
        log_level = Keyword.get(opts, :log_level, @log_level)

        # Register receive callback
        case @transport.set_receive_callback(transport_pid, &handle_receive/2) do
          :ok ->
            {:ok,
             %{
               transport: transport_pid,
               processor: @processor,
               log_level: log_level
             }}

          {:error, reason} ->
            {:stop, {:callback_registration_failed, reason}}
        end
      end

      @impl true
      def handle_cast(_msg, state), do: {:noreply, state}

      @impl true
      def handle_info(_msg, state), do: {:noreply, state}

      @impl true
      def terminate(_reason, _state), do: :ok

      #
      # Callbacks (can be overridden)
      #

      @doc """
      Handles incoming message from transport.

      Called by transport when a message arrives.
      """
      def handle_receive(raw_message, %Context{} = context) do
        start_time = System.monotonic_time(:millisecond)

        log(__MODULE__, "Received ISO message (#{byte_size(raw_message)} bytes)", context,
          level: :debug
        )

        case @processor.process_with_timeout(raw_message, context) do
          {:ok, response} ->
            handle_response({:ok, response}, context, start_time)

          {:error, reason} ->
            handle_response({:error, reason}, context, start_time)
        end
      end

      @doc """
      Handles processing result.

      Sends response back through transport on success.
      """
      def handle_response({:ok, response}, context, start_time) do
        duration = System.monotonic_time(:millisecond) - start_time

        log(__MODULE__, "Processing completed in #{duration}ms", context, level: :debug)

        case @transport.send(context.transport_ref, response) do
          :ok ->
            log(__MODULE__, "Response sent", context, level: :debug)
            :ok

          {:ok, _ref} ->
            log(__MODULE__, "Response sent", context, level: :debug)
            :ok

          {:error, reason} ->
            handle_send_error(response, reason, context)
        end
      end

      @doc """
      Handles processing error.
      """
      def handle_response({:error, reason}, context, _start_time) do
        log(__MODULE__, "Processing failed: #{inspect(reason)}", context, level: :error)
        :ok
      end

      @doc """
      Handles send error.
      """
      def handle_send_error(_response, reason, context) do
        log(__MODULE__, "Failed to send response: #{inspect(reason)}", context, level: :error)
        :ok
      end

      defoverridable handle_receive: 2,
                     handle_response: 3,
                     handle_send_error: 3

      #
      # Private functions
      #

      defp log(module, message, context, opts) do
        level = Keyword.get(opts, :level, :info)

        log_message = [
          "[#{module}] ",
          message,
          case Context.peer_address_string(context) do
            nil -> ""
            addr -> " from #{addr}"
          end,
          case context.request_id do
            nil -> ""
            id -> " [#{id}]"
          end
        ]

        apply(Logger, level, [log_message])
      end
    end
  end
end
