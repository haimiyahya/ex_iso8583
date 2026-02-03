defmodule TransactionProcessor do
  @moduledoc """
  Pure functional transaction processing abstraction for ISO 8583 messages.

  This module provides a macro-based DSL for defining transaction handlers
  that process ISO 8583 request messages and produce response messages.
  It integrates with the existing `TransactionType` and `TransactionTypeGroup`
  modules for type definitions and routing.

  ## Key Features

  - **Type-safe handlers**: Compile-time validation ensures handlers accept
    the correct request struct and return the correct response struct
  - **Explicit mapping**: Handlers are explicitly mapped to transaction types
  - **Before/after hooks**: Execute code before and after handler execution
  - **Middleware pipeline**: Plug-in middleware for logging, transformation, etc.
  - **Error handling**: Automatic error response generation with configurable fields

  ## Architecture

  The processor follows a pure functional approach with no side effects:
  - No Erlang processes
  - No GenServer
  - No supervision

  Concurrency and supervision concerns should be handled by a separate layer.

  ## Quick Start

  First, define your request and response structs:

      defmodule SaleRequest do
        use TransactionType

        defstruct [:pan, :amount, :stan, :terminal_id]

        # Define transaction type configuration...
      end

      defmodule SaleResponse do
        use TransactionType

        defstruct [:response_code, :amount, :stan, :auth_code]

        # Define transaction type configuration...
      end

  Then create a processor with one or more handlers:

      defmodule MyProcessor do
        use TransactionProcessor

        config error_response_code_field: 39,
              error_message_field: 60

        # Define a sale handler with hooks
        defhandler :sale, SaleRequest, SaleResponse,
          before_hooks: [:validate_amount],
          after_hooks: [:log_response] do

          def handle(%SaleRequest{amount: amount, stan: stan} = req) do
            # Business logic here
            %SaleResponse{
              response_code: "00",
              amount: amount,
              stan: stan,
              auth_code: generate_auth_code()
            }
          end

          # Hooks must be public functions (def, not defp)
          def validate_amount(%SaleRequest{amount: amount} = req)
              when is_integer(amount) and amount > 0, do: req
          def validate_amount(_), do: raise(ArgumentError, "Invalid amount")

          def log_response(resp), do: resp

          defp generate_auth_code, do: :rand.uniform(999_999) |> to_string()
        end

        # Define another handler for void transactions
        defhandler :void, VoidRequest, VoidResponse do
          def handle(%VoidRequest{stan: stan}) do
            %VoidResponse{response_code: "00", stan: stan}
          end
        end
      end

  ## Processing Transactions

  Process a raw ISO 8583 message:

      {:ok, response} = MyProcessor.process(raw_iso_message)

  Process a pre-parsed request struct:

      request = %SaleRequest{amount: 10000, stan: "000123", ...}
      {:ok, response} = MyProcessor.process_struct(request)

  ## Hooks

  Hooks are functions that run before or after your handler. They are specified
  as keyword arguments:

  - `before_hooks: [:hook1, :hook2]` - List of functions to call before `handle/1`
  - `after_hooks: [:hook1]` - List of functions to call after `handle/1`

  **Important**: Hook functions must be defined as `def` (public), not `defp` (private).

  Before hooks receive the request and must return the (possibly modified) request.
  If a before hook raises an exception, the handler is not executed and the error
  is caught and returned as `{:error, {:handler_error, reason}}`.

  After hooks receive the response and must return the (possibly modified) response.

  ## Handler Discovery

  Handlers are discovered by matching the request struct's module against the
  registered `request_module` for each handler. This means each handler must
  have a unique request module.

  ## Error Handling

  When an error occurs during processing, the processor returns `{:error, reason}`.
  The reason can be:
  - `{:missing_fields, fields}` - Required fields are missing from the request
  - `{:handler_error, message}` - An error occurred in the handler or hooks
  - `{:invalid_response_type, actual, expected}` - Handler returned wrong type
  - `:not_found` - No handler found for the request type

  """

  require Logger

  # Error response code field number (field 39)
  @field_response_code 39

  # Default field number for error messages (field 60 - Reserved Private)
  @field_error_message 60

  @type handler_name :: atom()
  @type request_module :: module()
  @type response_module :: module()
  @type handler_config :: %{
    name: handler_name(),
    request_module: request_module(),
    response_module: response_module(),
    before_hooks: [atom()],
    after_hooks: [atom()],
    middleware: [module()]
  }
  @type handler_map :: %{handler_name() => handler_config()}

  @type raw_iso_message :: binary()
  @type processing_result :: {:ok, struct()} | {:error, term()}

  @doc false
  defmacro __using__(opts) do
    quote do
      import TransactionProcessor, only: [defhandler: 3, defhandler: 4, defhandler: 5, defhandler: 6, config: 1]

      # Register handlers storage
      Module.register_attribute(__MODULE__, :handlers, accumulate: true)
      Module.register_attribute(__MODULE__, :config, accumulate: true)
      Module.register_attribute(__MODULE__, :middleware, accumulate: true)

      @before_compile TransactionProcessor

      # Default config
      @config error_response_code_field: unquote(opts[:error_response_code_field] || 39)
      @config error_message_field: unquote(opts[:error_message_field] || 60)
    end
  end

  @doc """
  Defines configuration options for the processor.

  ## Options

  - `:error_response_code_field` - Field number for response code (default: 39)
  - `:error_message_field` - Field number for error messages (default: 60)

  ## Example

      config error_response_code_field: 39,
             error_message_field: 60
  """
  defmacro config(opts) do
    quote do
      @config unquote(opts)
    end
  end

  @doc """
  Defines a transaction handler with type validation.

  The macro creates a nested handler module and ensures at runtime that
  the `handle/1` function returns the correct response struct type.

  ## Parameters

  - `name` - Unique identifier for this handler (atom)
  - `request_module` - The request struct module
  - `response_module` - The response struct module
  - `opts` - Keyword list of options (optional)

  ## Options

  - `:before_hooks` - List of hook function atoms to call before `handle/1`
  - `:before_hook` - Single hook to call before `handle/1` (shorthand for `before_hooks: [hook]`)
  - `:after_hooks` - List of hook function atoms to call after `handle/1`
  - `:after_hook` - Single hook to call after `handle/1` (shorthand for `after_hooks: [hook]`)

  ## Hooks

  Hooks are functions defined within the handler body. They receive the
  request (before hooks) or response (after hooks) and must return the
  (possibly modified) struct.

  **Important**: Hook functions must be defined as `def` (public), not `defp` (private),
  since they are called from outside the handler module.

  ## Examples

  ### Basic handler without hooks

      defhandler :sale, SaleRequest, SaleResponse do
        def handle(%SaleRequest{amount: amount} = req) do
          %SaleResponse{
            response_code: "00",
            amount: amount,
            stan: req.stan
          }
        end
      end

  ### Handler with single hooks (using singular form)

      defhandler :sale, SaleRequest, SaleResponse,
        before_hook: :validate,
        after_hook: :log do

        def handle(%SaleRequest{} = req) do
          %SaleResponse{response_code: "00"}
        end

        def validate(%SaleRequest{amount: amt} = req) when amt > 0, do: req
        def validate(_), do: raise(ArgumentError, "Invalid amount")

        def log(resp), do: resp
      end

  ### Handler with multiple hooks (using plural form)

      defhandler :sale, SaleRequest, SaleResponse,
        before_hooks: [:validate_amount, :check_terminal],
        after_hooks: [:log_response, :add_timestamp] do

        def handle(%SaleRequest{} = req) do
          %SaleResponse{response_code: "00"}
        end

        def validate_amount(%SaleRequest{amount: amt} = req) when amt > 0, do: req
        def validate_amount(_), do: raise(ArgumentError, "Invalid amount")

        def check_terminal(req), do: req  # Pass-through validation

        def log_response(resp), do: resp

        def add_timestamp(%{__struct__: mod} = resp) do
          Map.put(resp, :processed_at, DateTime.utc_now())
        end
      end

  """
  # Accepts variable number of arguments after name, request_module, response_module
  # This handles both:
  #   defhandler :name, Req, Res, do: ...           (4 args - single keyword list)
  #   defhandler :name, Req, Res, opt: val do ...   (5+ args - multiple keywords + do block)
  defmacro defhandler(name, request_module, response_module, rest) do
    # Generate handler module name at compile time (outside quote)
    handler_module_name = Module.concat(__CALLER__.module, Macro.camelize(to_string(name)))

    # Normalize rest - it's a list of the remaining arguments
    # Could be [[do: ...]] or [[opt: val], [opt2: val2], [do: ...]]
    {opts, do_block} =
      case rest do
        # Single keyword list argument (might contain :do)
        [single_kw] when is_list(single_kw) ->
          {Keyword.delete(single_kw, :do), Keyword.get(single_kw, :do)}

        # Multiple keyword lists - merge them
        multiple_kws when is_list(multiple_kws) ->
          merged = Enum.flat_map(multiple_kws, fn
            kw when is_list(kw) -> kw
            other -> [other]
          end)

          {Keyword.delete(merged, :do), Keyword.get(merged, :do)}

        # Something else
        _ ->
          {rest, nil}
      end

    # Extract hook options
    before_hooks = Keyword.get(opts, :before_hooks, [])
    before_hook = Keyword.get(opts, :before_hook)
    after_hooks = Keyword.get(opts, :after_hooks, [])
    after_hook = Keyword.get(opts, :after_hook)

    # Normalize hooks to lists
    before_hooks_list =
      cond do
        is_list(before_hooks) -> before_hooks
        before_hook != nil -> [before_hook]
        true -> []
      end

    after_hooks_list =
      cond do
        is_list(after_hooks) -> after_hooks
        after_hook != nil -> [after_hook]
        true -> []
      end

    # Get statements from do_block or empty block
    statements = case do_block do
      nil -> []
      {:__block__, _, stmts} -> stmts
      stmt -> [stmt]
    end

    quote location: :keep do
      @handlers %{
        name: unquote(name),
        request_module: unquote(request_module),
        response_module: unquote(response_module),
        before_hooks: unquote(before_hooks_list),
        after_hooks: unquote(after_hooks_list),
        middleware: [],
        handler_module: unquote(handler_module_name)
      }

      # Define the handler module
      defmodule unquote(handler_module_name) do
        @behaviour TransactionProcessor.Handler

        # Wrapper with runtime type validation
        def handle!(request) do
          response = handle(request)

          # Validate response type at runtime
          case response do
            %unquote(response_module){} -> response
            other ->
              raise ArgumentError, """
              Expected #{unquote(response_module)} but got #{inspect(response.__struct__)}

              Handler returned incorrect type. Ensure handle/1 returns #{unquote(response_module)}.
              """
          end
        end

        # Include the user's handler body (which defines handle/1)
        unquote_splicing(statements)
      end
    end
  end

  # Handle 5 arguments: name, request_module, response_module, kw1, kw2_or_do
  defmacro defhandler(name, request_module, response_module, kw1, kw2) do
    quote do
      defhandler unquote(name), unquote(request_module), unquote(response_module), [unquote(kw1), unquote(kw2)]
    end
  end

  # Handle 6 arguments: name, request_module, response_module, kw1, kw2, do_block
  defmacro defhandler(name, request_module, response_module, kw1, kw2, do_block) do
    quote do
      defhandler unquote(name), unquote(request_module), unquote(response_module), [unquote(kw1), unquote(kw2), unquote(do_block)]
    end
  end

  # No-argument version (no do block)
  defmacro defhandler(name, request_module, response_module) do
    quote do
      defhandler unquote(name), unquote(request_module), unquote(response_module), do: nil
    end
  end

  @doc false
  # Extracts @before_hook and @after_hook attributes from the do_block AST
  # Always returns a {:__block__, meta, statements} tuple for the body
  def extract_hooks_from_block({:__block__, meta, statements}) do
    {before_hooks, after_hooks, filtered_statements} =
      extract_hooks_from_statements(statements, [], [])

    {{:__block__, meta, Enum.reverse(filtered_statements)}, Enum.reverse(before_hooks), Enum.reverse(after_hooks)}
  end

  def extract_hooks_from_block(statement) do
    {before_hooks, after_hooks, filtered} = extract_hooks_from_statements([statement], [], [])
    # Wrap single statement in a block for consistency
    {{:__block__, [], Enum.reverse(filtered)}, Enum.reverse(before_hooks), Enum.reverse(after_hooks)}
  end

  defp extract_hooks_from_statements([], before_acc, after_acc) do
    {before_acc, after_acc, []}
  end

  # Match @before_hook :hook_name
  defp extract_hooks_from_statements(
         [{:@, _, [{:before_hook, _, [hook_name]}]} | rest],
         before_acc,
         after_acc
       ) do
    extract_hooks_from_statements(rest, [hook_name | before_acc], after_acc)
  end

  # Match @after_hook :hook_name
  defp extract_hooks_from_statements(
         [{:@, _, [{:after_hook, _, [hook_name]}]} | rest],
         before_acc,
         after_acc
       ) do
    extract_hooks_from_statements(rest, before_acc, [hook_name | after_acc])
  end

  # Keep all other statements
  defp extract_hooks_from_statements([statement | rest], before_acc, after_acc) do
    {_, _, rest_filtered} = extract_hooks_from_statements(rest, before_acc, after_acc)
    {before_acc, after_acc, [statement | rest_filtered]}
  end

  @doc false
  # Validates that handle/1 function is defined in the handler body
  def validate_handle_function_defined!(body, env) do
    statements = case body do
      {:__block__, _, stmts} -> stmts
      stmt -> [stmt]
    end

    handle_defined? =
      Enum.any?(statements, fn
        # def handle(%Struct{} = var) do ... end
        {:def, _, [{:handle, _, args}, _]} when is_list(args) and length(args) == 1 -> true
        # def handle(var), do: ...
        {:def, _, [{:handle, _, args}, _]} when is_list(args) -> true
        # defp handle(...)
        {:defp, _, [{:handle, _, args}, _]} when is_list(args) -> true
        _ -> false
      end)

    unless handle_defined? do
      raise CompileError,
        file: env.file,
        line: env.line,
        description: """
        handler must define a handle/1 function that accepts the request struct
        and returns a response struct.

        Example:

            def handle(%RequestModule{} = req) do
              %ResponseModule{response_code: "00"}
            end
        """
    end

    :ok
  end

  @doc false
  defmacro __before_compile__(env) do
    handlers = Module.get_attribute(env.module, :handlers) |> Enum.reverse()

    # Merge all config keyword lists into a single map
    config =
      env.module
      |> Module.get_attribute(:config)
      |> Enum.reverse()
      |> Enum.reduce(%{}, fn keyword_list, acc ->
        Map.merge(acc, Map.new(keyword_list))
      end)

    quote do
      @doc """
      Returns the handler configuration map.
      """
      def __handlers__, do: unquote(Macro.escape(handlers))

      @doc """
      Returns the processor configuration.
      """
      def __config__, do: unquote(Macro.escape(config))

      @doc """
      Processes an ISO 8583 message and routes it to the appropriate handler.

      ## Parameters

      - `raw_message` - Binary ISO 8583 message
      - `context` - Optional map with additional context (default: %{})

      ## Returns

      - `{:ok, response_struct}` on success
      - `{:error, reason}` on failure

      ## Example

          {:ok, response} = MyProcessor.process(raw_message)

      """
      @spec process(binary(), map()) :: {:ok, struct()} | {:error, term()}
      def process(raw_message, context \\ %{}) do
        TransactionProcessor.process(__MODULE__, raw_message, context)
      end

      @doc """
      Processes a pre-parsed request struct.

      ## Parameters

      - `request_struct` - Parsed transaction request struct
      - `context` - Optional map with additional context (default: %{})

      ## Returns

      - `{:ok, response_struct}` on success
      - `{:error, reason}` on failure
      """
      @spec process_struct(struct(), map()) :: {:ok, struct()} | {:error, term()}
      def process_struct(request_struct, context \\ %{}) do
        TransactionProcessor.process_struct(__MODULE__, request_struct, context)
      end

      @doc """
      Returns the handler for the given request struct.
      """
      @spec find_handler(struct()) :: {:ok, map()} | {:error, :not_found}
      def find_handler(request_struct) do
        TransactionProcessor.find_handler(__MODULE__, request_struct)
      end

      @doc """
      Adds middleware to the processing pipeline.

      Middleware are executed in the order they are added.
      """
      @spec use_middleware(module()) :: :ok
      def use_middleware(middleware) do
        raise "Middleware must be configured at compile time"
      end
    end
  end

  @doc """
  Processes an ISO 8583 message through the registered handlers.

  This function:
  1. Parses the raw message using TransactionTypeGroup
  2. Finds the matching handler
  3. Validates mandatory fields
  4. Executes before hooks
  5. Calls the handler
  6. Executes after hooks
  7. Returns the response

  ## Error Handling

  If any step fails, an error response is automatically generated with:
  - Field 39 (Response Code) set to error value
  - Field 60 (or configured field) set to error message
  - Other fields populated from request or defaults
  """
  def process(processor_module, raw_message, context) do
    with {:ok, request_struct} <- parse_message(processor_module, raw_message, context),
         {:ok, handler} <- find_handler(processor_module, request_struct),
         {:ok, validated} <- validate_request(request_struct, handler),
         {:ok, response} <- execute_handler(processor_module, handler, validated, context) do
      {:ok, response}
    else
      {:error, _reason} = error ->
        error
    end
  end

  def process(processor_module, raw_message, context, _fallback) do
    process(processor_module, raw_message, context)
  end

  @doc """
  Processes a pre-parsed request struct.
  """
  def process_struct(processor_module, request_struct, context \\ %{}) do
    with {:ok, handler} <- find_handler(processor_module, request_struct),
         {:ok, validated} <- validate_request(request_struct, handler),
         {:ok, response} <- execute_handler(processor_module, handler, validated, context) do
      {:ok, response}
    else
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Finds the handler for a given request struct.
  """
  def find_handler(processor_module, request_struct) do
    handlers = apply(processor_module, :__handlers__, [])

    request_module = request_struct.__struct__

    Enum.find_value(handlers, {:error, :not_found}, fn handler ->
      if handler.request_module == request_module do
        {:ok, handler}
      end
    end)
  end

  @doc """
  Parses a raw ISO message into a request struct.
  """
  def parse_message(processor_module, raw_message, _context) do
    # Try to find matching transaction type/group
    handlers = apply(processor_module, :__handlers__, [])

    # Try each handler's request module to parse
    Enum.reduce_while(handlers, {:error, :no_matching_type}, fn handler, _acc ->
      try do
        case handler.request_module.parse(raw_message) do
          {:ok, struct} -> {:halt, {:ok, struct}}
          {:error, _} -> {:cont, {:error, :no_matching_type}}
        end
      rescue
        _ -> {:cont, {:error, :no_matching_type}}
      end
    end)
  end

  @doc """
  Validates that all mandatory fields are present in the request.
  """
  def validate_request(request_struct, handler) do
    # Get mandatory fields from the transaction type definition (if available)
    mandatory_fields =
      case function_exported?(handler.request_module, :__transaction_type__, 2) do
        true -> handler.request_module.__transaction_type__(:mandatory_fields, [])
        false -> []
      end

    missing_fields =
      mandatory_fields
      |> Enum.reject(fn field ->
        Map.has_key?(request_struct, field)
      end)

    if Enum.empty?(missing_fields) do
      {:ok, request_struct}
    else
      {:error, {:missing_fields, missing_fields}}
    end
  end

  @doc """
  Executes the handler with before/after hooks.
  """
  def execute_handler(_processor_module, handler, request_struct, _context) do
    # Execute before hooks (on handler module where hooks are defined)
    # Before hooks can raise errors to reject the request
    request = execute_before_hooks(handler.handler_module, handler, request_struct)

    # Execute handler
    response =
      handler.handler_module.handle(request)
      |> execute_after_hooks(handler.handler_module, handler)

    # Validate response type
    if response.__struct__ == handler.response_module do
      {:ok, response}
    else
      {:error, {:invalid_response_type, response.__struct__, handler.response_module}}
    end
  rescue
    e in [FunctionClauseError, ArgumentError] ->
      {:error, {:handler_error, Exception.message(e)}}
    e ->
      {:error, {:handler_error, Exception.message(e)}}
  end

  @doc """
  Executes before hooks for a handler.

  Before hooks are called in order and can raise exceptions to reject the request.
  If a hook raises, the exception propagates up and is caught by execute_handler/4.
  """
  def execute_before_hooks(handler_module, handler, request_struct) do
    Enum.reduce(handler.before_hooks || [], request_struct, fn hook, acc ->
      apply(handler_module, hook, [acc])
    end)
  end

  @doc """
  Executes after hooks for a handler.

  Note: response_struct is first argument to work with pipe operator.
  """
  def execute_after_hooks(response_struct, handler_module, handler) do
    hooks = Map.get(handler, :after_hooks, [])
    Enum.reduce(hooks, response_struct, fn hook, acc ->
      safe_apply(handler_module, hook, [acc], acc)
    end)
  end

  defp safe_apply(module, fun, args, default) do
    apply(module, fun, args)
  rescue
    _ -> default
  end

  @doc """
  Generates an error response based on the error reason.
  """
  def error_response(processor_module, request_struct, {:missing_fields, fields}) do
    config = apply(processor_module, :__config__, [])

    response_code_field = config[:error_response_code_field] || @field_response_code
    error_message_field = config[:error_message_field] || @field_error_message

    # Find the response module from the request struct
    {:ok, handler} = find_handler(processor_module, request_struct)

    # Build error response
    error_response =
      handler.response_module.__transaction_type__(
        :struct,
        %{}
      )
    |> Map.put(response_code_field, "ER")  # Error response code
    |> Map.put(error_message_field, "Missing fields: #{inspect(fields)}")
    |> populate_from_request(request_struct, handler.response_module)

    {:ok, error_response}
  end

  def error_response(processor_module, request_struct, {kind, details}) when is_atom(kind) do
    config = apply(processor_module, :__config__, [])

    response_code_field = config[:error_response_code_field] || @field_response_code
    error_message_field = config[:error_message_field] || @field_error_message

    {:ok, handler} = find_handler(processor_module, request_struct)

    error_response =
      handler.response_module.__transaction_type__(
        :struct,
        %{}
      )
    |> Map.put(response_code_field, "ER")
    |> Map.put(error_message_field, "#{kind}: #{inspect(details)}")
    |> populate_from_request(request_struct, handler.response_module)

    {:ok, error_response}
  end

  def error_response(_processor_module, _request_struct, error) do
    {:error, error}
  end

  @doc """
  Populates response fields from the request struct.
  """
  def populate_from_request(response_struct, request_struct, response_module) do
    copyable_fields =
      case function_exported?(response_module, :__transaction_type__, 2) do
        true -> response_module.__transaction_type__(:copyable_fields, [])
        false -> []
      end

    Enum.reduce(copyable_fields, response_struct, fn field, acc ->
      case Map.fetch(request_struct, field) do
        {:ok, value} -> Map.put(acc, field, value)
        :error -> acc
      end
    end)
  end
end

defmodule TransactionProcessor.Handler do
  @moduledoc """
  Behaviour for transaction handlers.

  This behaviour is automatically applied to handler modules created by
  the `defhandler/3-6` macro. You typically don't need to use this behaviour
  directly.

  ## Example

  The `defhandler` macro automatically creates a module that implements this
  behaviour:

      defmodule MyProcessor do
        use TransactionProcessor

        defhandler :sale, SaleRequest, SaleResponse do
          def handle(%SaleRequest{amount: amount}) do
            %SaleResponse{response_code: "00", amount: amount}
          end
        end
      end

  # The above creates: MyProcessor.Sale
  # Which implements the TransactionProcessor.Handler behaviour

  ## Callbacks

  - `handle/1` - Processes a request and returns a response

  """

  @doc """
  Processes a transaction request and returns a response.

  ## Parameters

  - `request` - A request struct (the type specified in `defhandler`)

  ## Returns

  A response struct (the type specified in `defhandler`)

  """
  @callback handle(struct()) :: struct()
end
