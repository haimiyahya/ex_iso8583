defmodule TransactionProcessor.Middleware do
  @moduledoc """
  Middleware pipeline for TransactionProcessor.

  Middleware allows you to plug in cross-cutting concerns such as:
  - Logging
  - Metrics/timing
  - Request/response transformation
  - Validation
  - Error handling

  ## Middleware Protocol

  A middleware is a module that implements the `call/2` function:

      defmodule MyMiddleware do
        @behaviour TransactionProcessor.Middleware

        @impl true
        def call(request, next) do
          # Pre-processing
          Logger.debug("Processing request")

          # Call next middleware/handler
          response = next.(request)

          # Post-processing
          Logger.debug("Got response")

          response
        end
      end

  ## Usage

      defmodule MyProcessor do
        use TransactionProcessor

        use_middleware MyMiddleware
        use_middleware AnotherMiddleware

        defhandler :sale, SaleRequest, SaleResponse do
          def handle(req), do: %SaleResponse{}
        end
      end

  Middleware are executed in the order they are defined (first = outermost).

  ## Stopping the Pipeline

  A middleware can stop the pipeline early by returning a response
  without calling `next.(request)`:

      defmodule AuthMiddleware do
        def call(request, next) do
          if authenticated?(request) do
            next.(request)
          else
            {:error, :unauthorized}
          end
        end
      end
  """

  @doc """
  Invokes the middleware chain.

  Middleware modules must implement this callback.
  """
  @callback call(struct(), (struct() -> term())) :: term()

  @doc """
  Builds a middleware pipeline from a list of middleware modules.

  Returns a function that executes the middleware in order.
  """
  @spec build_pipeline([module()], (struct() -> term())) :: (struct() -> term())
  def build_pipeline(middleware, handler) when is_list(middleware) do
    middleware
    |> Enum.reverse()
    |> Enum.reduce(handler, fn mw, acc ->
      fn request -> mw.call(request, acc) end
    end)
  end

  @doc """
  Executes a middleware pipeline with a request.
  """
  @spec execute([module()], struct(), (struct() -> term())) :: term()
  def execute(middleware, request, handler) when is_list(middleware) do
    pipeline = build_pipeline(middleware, handler)
    pipeline.(request)
  end

  defmodule Logger do
    @moduledoc """
    Middleware that logs requests and responses.

    ## Options

    - `:log_level` - Log level to use (:debug, :info, :warn, :error)
    - `:log_function` - Custom function for logging (default: Elixir.Logger)
    - `:filter_fields` - List of fields to redact (e.g., [:pan, :cvv])

    ## Example

        use_middleware {TransactionProcessor.Middleware.Logger,
         log_level: :info, filter_fields: [:pan]}
    """

    @behaviour TransactionProcessor.Middleware

    defstruct [:log_level, :log_function, :filter_fields]

    def new(opts \\ []) do
      %__MODULE__{
        log_level: Keyword.get(opts, :log_level, :info),
        log_function: Keyword.get(opts, :log_function, Elixir.Logger),
        filter_fields: Keyword.get(opts, :filter_fields, [])
      }
    end

    @impl true
    def call(request, next) do
      config = get_config(request)
      log_fn = config.log_function
      level = config.log_level

      # Filter sensitive fields
      filtered_request = filter_fields(request, config.filter_fields)

      # Log request
      apply(log_fn, level, ["Transaction request: #{inspect(filtered_request)}"])

      # Execute next
      response = next.(request)

      # Log response
      filtered_response = filter_fields(response, config.filter_fields)
      apply(log_fn, level, ["Transaction response: #{inspect(filtered_response)}"])

      response
    end

    defp get_config(%{__middleware_config__: %{} = config}), do: config
    defp get_config(_), do: %__MODULE__{} |> new()

    defp filter_fields(struct, fields) when is_list(fields) do
      Enum.reduce(fields, struct, fn field, acc ->
        if Map.has_key?(acc, field) do
          Map.put(acc, field, "[REDACTED]")
        else
          acc
        end
      end)
    end
  end

  defmodule Timer do
    @moduledoc """
    Middleware that times request execution.

    The duration is stored in the response struct under `:__duration__`.

    ## Example

        use_middleware TransactionProcessor.Middleware.Timer
    """

    @behaviour TransactionProcessor.Middleware

    @impl true
    def call(request, next) do
      start = System.monotonic_time(:microsecond)

      response = next.(request)

      duration = System.monotonic_time(:microsecond) - start

      # Add duration to response
      case response do
        %{__struct__: _struct} = resp when is_map(resp) ->
          Map.put(resp, :__duration__, duration)

        other ->
          other
      end
    end
  end

  defmodule Validator do
    @moduledoc """
    Middleware that validates requests before processing.

    ## Options

    - `:validate_fn` - Function that takes a request and returns :ok or {:error, reason}

    ## Example

        use_middleware {TransactionProcessor.Middleware.Validator,
         validate_fn: fn
           %{amount: amount} when is_integer(amount) and amount > 0 -> :ok
           _ -> {:error, :invalid_amount}
         end}
    """

    @behaviour TransactionProcessor.Middleware

    defstruct [:validate_fn]

    def new(opts \\ []) do
      validate_fn = Keyword.get(opts, :validate_fn, fn _ -> :ok end)
      %__MODULE__{validate_fn: validate_fn}
    end

    def call(request, next) do
      config = get_config(request)
      validate_fn = config.validate_fn

      case validate_fn.(request) do
        :ok ->
          next.(request)

        {:error, _reason} = error ->
          error
      end
    end

    defp get_config(%{__middleware_config__: %{} = config}), do: config
    defp get_config(_), do: %__MODULE__{} |> new()
  end

  defmodule Transformer do
    @moduledoc """
    Middleware that transforms requests before processing.

    ## Options

    - `:transform_fn` - Function that takes a request and returns a transformed request

    ## Example

        use_middleware {TransactionProcessor.Middleware.Transformer,
         transform_fn: fn
           %{pan: pan} = req -> Map.put(req, :pan, String.trim(pan))
           req -> req
         end}
    """

    @behaviour TransactionProcessor.Middleware

    defstruct [:transform_fn]

    def new(opts \\ []) do
      transform_fn = Keyword.get(opts, :transform_fn, fn req -> req end)
      %__MODULE__{transform_fn: transform_fn}
    end

    def call(request, next) do
      config = get_config(request)
      transform_fn = config.transform_fn
      transformed = transform_fn.(request)
      next.(transformed)
    end

    defp get_config(%{__middleware_config__: %{} = config}), do: config
    defp get_config(_), do: %__MODULE__{} |> new()
  end
end

defmodule TransactionProcessor.Pipeline do
  @moduledoc """
  A composable pipeline for transaction processing middleware.

  Allows building middleware chains with explicit ordering.
  """

  @type t :: %__MODULE__{
          middleware: [module() | {module(), keyword()}]
        }

  defstruct middleware: []

  @doc """
  Creates a new empty pipeline.
  """
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Adds middleware to the pipeline.

  ## Parameters

  - `pipeline` - The pipeline struct
  - `middleware` - A module or {module, opts} tuple

  ## Example

      Pipeline.new()
      |> Pipeline.add(MyMiddleware)
      |> Pipeline.add({LoggerMiddleware, log_level: :debug})
  """
  @spec add(t(), module() | {module(), keyword()}) :: t()
  def add(%__MODULE__{middleware: mw} = pipeline, middleware) do
    %{pipeline | middleware: mw ++ [middleware]}
  end

  @doc """
  Executes the pipeline with a request and handler function.
  """
  @spec execute(t(), struct(), (struct() -> term())) :: term()
  def execute(%__MODULE__{middleware: mw}, request, handler) do
    TransactionProcessor.Middleware.execute(mw, request, handler)
  end
end
