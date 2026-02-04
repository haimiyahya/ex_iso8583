defmodule TransactionProcessor.TimeoutWrapper do
  @moduledoc """
  Wrapper that adds timeout capability to TransactionProcessor.

  This layer handles the side effects (timing) while keeping
  TransactionProcessor pure and testable.

  ## Features

  - Configurable timeout per transaction type
  - Configurable timeout response field and code
  - Graceful task termination on timeout
  - Automatic timeout response generation

  ## Transaction Type Detection

  Transaction types are determined from the MTI (Message Type Indicator)
  and Processing Code fields:

  | MTI  | Processing Code | Transaction Type |
  |------|-----------------|------------------|
  | 0200 | 001000          | sale             |
  | 0200 | 002000          | sale_with_cashback|
  | 0220 | 001000          | refund           |
  | 0400 | 001000          | capture          |
  | 0420 | 001000          | capture_refund   |
  | 0200 | 000000          | balance_inquiry  |
  | 0200 | 310000          | batch_close      |
  | 0500 | 001000          | settlement       |
  | 0420 | 001000          | reversal         |
  | 0400 | 001000          | void             |

  ## Usage

  Basic usage with default configuration:

      defmodule MyApp.Processor do
        use TransactionProcessor.TimeoutWrapper,
          processor: MyProcessor,
          timeouts: %{
            sale: 5000,
            refund: 3000,
            settlement: 30000
          }
      end

      # Process with timeout
      {:ok, response} = MyApp.Processor.process_with_timeout(raw_message)

  ## Configuration Options

  - `:processor` - The processor module to wrap (required)
  - `:timeouts` - Map of transaction type to timeout in milliseconds (required)
  - `:timeout_response_field` - Field number for timeout response code (default: 39)
  - `:timeout_response_code` - Value for timeout response (default: "68")
  - `:task_supervisor` - Task supervisor name (default: TransactionProcessor.TaskSupervisor)

  ## Example

      defmodule PaymentProcessor do
        use TransactionProcessor.TimeoutWrapper,
          processor: TransactionProcessor,
          timeouts: %{
            # Fast transactions
            sale: 5000,
            void: 3000,
            refund: 3000,
            balance_inquiry: 2000,

            # Slower transactions
            sale_with_cashback: 7000,
            capture: 5000,
            reversal: 4000,

            # Batch operations (much slower)
            batch_close: 60000,
            settlement: 120000
          },
          timeout_response_field: 39,
          timeout_response_code: "68"
      end

      # Process a sale with 5 second timeout
      case PaymentProcessor.process_with_timeout(raw_sale_message) do
        {:ok, response} ->
          if Map.get(response, 39) == "68" do
            # Transaction timed out
            Logger.warning("Transaction timed out")
          else
            # Transaction succeeded
            Logger.info("Transaction completed")
          end

        {:error, _reason} ->
          Logger.error("Transaction failed")
      end

  ## Custom Transaction Type Mapping

  You can provide a custom function to determine transaction types:

      defmodule CustomProcessor do
        use TransactionProcessor.TimeoutWrapper,
          processor: MyProcessor,
          timeouts: %{default: 5000},
          transaction_type_detector: &MyCustomDetector.detect/1
      end

  """

  alias Ex_Iso8583.IsoBitmap
  alias Ex_Iso8583.IsoField

  @type t :: %__MODULE__{
          processor_module: module(),
          timeouts: %{atom() => pos_integer()},
          timeout_response_field: integer(),
          timeout_response_code: String.t(),
          task_supervisor: atom(),
          transaction_type_detector: (binary() -> atom())
        }

  defstruct [
    :processor_module,
    :timeouts,
    timeout_response_field: 39,
    timeout_response_code: "68",
    task_supervisor: TransactionProcessor.TaskSupervisor,
    transaction_type_detector: &__MODULE__.default_transaction_type_detector/1
  ]

  @doc """
  Macro for using TimeoutWrapper with configuration.
  """
  defmacro __using__(opts) do
    quote do
      @wrapper_config unquote(opts)

      @doc """
      Process a raw ISO 8583 message with timeout.

      Returns {:ok, response} or {:error, reason}.
      """
      def process_with_timeout(raw_message, context \\ %{}) do
        TransactionProcessor.TimeoutWrapper.process(__MODULE__, raw_message, context)
      end

      @doc """
      Process a pre-parsed request struct with timeout.

      Returns {:ok, response} or {:error, reason}.
      """
      def process_struct_with_timeout(request_struct, context \\ %{}) do
        TransactionProcessor.TimeoutWrapper.process_struct(__MODULE__, request_struct, context)
      end

      @doc """
      Returns the wrapper configuration.
      """
      def __wrapper_config__, do: @wrapper_config

      @doc """
      Returns the timeout for a given transaction type.

      Returns the specifically configured timeout for the transaction type,
      or `nil` if not specifically configured. Use `get_timeout!/1` to get
      the timeout with default fallback.
      """
      def get_timeout(transaction_type) do
        TransactionProcessor.TimeoutWrapper.get_timeout(__MODULE__, transaction_type)
      end

      @doc """
      Returns the timeout for a transaction type, falling back to default if configured.

      Returns `nil` if no timeout is configured for the type and no default is set.
      """
      def get_timeout!(transaction_type) do
        case get_timeout(transaction_type) do
          nil ->
            # Return default timeout if configured
            config = @wrapper_config
            timeouts = Keyword.get(config, :timeouts, %{})
            Map.get(timeouts, :default)

          timeout ->
            timeout
        end
      end
    end
  end

  @doc """
  Process a raw ISO 8583 message with timeout.

  ## Parameters

  - `wrapper_or_config` - Wrapper module or wrapper struct
  - `raw_message` - Raw ISO 8583 binary message
  - `context` - Optional context map

  ## Returns

  - `{:ok, response}` - Successful processing or timeout response
  - `{:error, reason}` - Error occurred

  ## Examples

      # Using wrapper module
      {:ok, response} = PaymentProcessor.process_with_timeout(raw_message)

      # Using wrapper struct directly
      wrapper = %TransactionProcessor.TimeoutWrapper{
        processor_module: MyProcessor,
        timeouts: %{sale: 5000}
      }
      {:ok, response} = TransactionProcessor.TimeoutWrapper.process(wrapper, raw_message)
  """
  @spec process(module() | t(), binary(), map()) :: {:ok, struct()} | {:error, term()}
  def process(wrapper_or_config, raw_message, context \\ %{})

  def process(wrapper_module, raw_message, context) when is_atom(wrapper_module) do
    wrapper = build_wrapper_from_config(wrapper_module)
    do_process(wrapper, raw_message, context)
  end

  def process(%__MODULE__{} = wrapper, raw_message, context) do
    do_process(wrapper, raw_message, context)
  end

  @doc """
  Process a pre-parsed request struct with timeout.

  ## Parameters

  - `wrapper_or_config` - Wrapper module or wrapper struct
  - `request_struct` - Pre-parsed transaction request struct
  - `context` - Optional context map

  ## Returns

  - `{:ok, response}` - Successful processing or timeout response
  - `{:error, reason}` - Error occurred
  """
  @spec process_struct(module() | t(), struct(), map()) :: {:ok, struct()} | {:error, term()}
  def process_struct(wrapper_or_config, request_struct, context \\ %{})

  def process_struct(wrapper_module, request_struct, context) when is_atom(wrapper_module) do
    wrapper = build_wrapper_from_config(wrapper_module)
    do_process_struct(wrapper, request_struct, context)
  end

  def process_struct(%__MODULE__{} = wrapper, request_struct, context) do
    do_process_struct(wrapper, request_struct, context)
  end

  @doc """
  Returns the timeout for a given transaction type.

  Returns `nil` if no timeout is configured for the transaction type.
  """
  @spec get_timeout(module() | t(), atom()) :: pos_integer() | nil
  def get_timeout(wrapper_or_config, transaction_type)

  def get_timeout(wrapper_module, transaction_type) when is_atom(wrapper_module) do
    wrapper = build_wrapper_from_config(wrapper_module)
    Map.get(wrapper.timeouts, transaction_type)
  end

  def get_timeout(%__MODULE__{} = wrapper, transaction_type) do
    Map.get(wrapper.timeouts, transaction_type)
  end

  @doc """
  Builds a timeout response from a request struct or raw message.

  ## Parameters

  - `wrapper` - The wrapper struct
  - `raw_message` - Optional raw ISO message
  - `request_struct` - Optional request struct

  ## Returns

  A response struct with timeout code set.

  """
  def build_timeout_response(wrapper, raw_message \\ nil, request_struct \\ nil) do
    build_timeout_response_impl(wrapper, raw_message, request_struct)
  end

  # Private functions

  defp build_timeout_response_impl(wrapper, raw_message, request_struct) do
    cond do
      request_struct != nil ->
        build_timeout_response_from_struct(wrapper, request_struct)

      raw_message != nil ->
        build_timeout_response_from_raw(wrapper, raw_message)

      true ->
        # No message info, return minimal error response
        %{
          wrapper.timeout_response_field => wrapper.timeout_response_code
        }
    end
  end

  defp do_process(wrapper, raw_message, context) do
    # 1. Determine transaction type from message
    transaction_type = wrapper.transaction_type_detector.(raw_message)

    # 2. Get timeout for this transaction type
    timeout = get_timeout_for_transaction(wrapper, transaction_type, raw_message)

    # 3. Run processor with timeout
    execute_with_timeout(
      wrapper.processor_module,
      raw_message,
      timeout,
      wrapper,
      context
    )
  end

  defp do_process_struct(wrapper, request_struct, context) do
    # 1. Determine transaction type from struct
    transaction_type = determine_transaction_type_from_struct(request_struct)

    # 2. Get timeout for this transaction type
    timeout = get_timeout_for_transaction(wrapper, transaction_type, nil)

    # 3. Run processor with timeout
    execute_with_timeout_struct(
      wrapper.processor_module,
      request_struct,
      timeout,
      wrapper,
      context
    )
  end

  defp execute_with_timeout(processor_module, raw_message, timeout, wrapper, context) do
    task =
      Task.Supervisor.async_nolink(wrapper.task_supervisor, fn ->
        processor_module.process(raw_message, context)
      end)

    await_result(task, timeout, wrapper, raw_message, nil)
  end

  defp execute_with_timeout_struct(processor_module, request_struct, timeout, wrapper, context) do
    task =
      Task.Supervisor.async_nolink(wrapper.task_supervisor, fn ->
        processor_module.process_struct(request_struct, context)
      end)

    await_result(task, timeout, wrapper, nil, request_struct)
  end

  defp await_result(task, timeout, wrapper, raw_message, request_struct) do
    case Task.yield(task, timeout) do
      {:ok, {:ok, response}} ->
        {:ok, response}

      {:ok, {:error, _reason} = error} ->
        error

      {:exit, :timeout} ->
        # Task timed out, shut it down
        Task.shutdown(task, :brutal_kill)

        # Build timeout response
        timeout_response = build_timeout_response_impl(wrapper, raw_message, request_struct)
        {:ok, timeout_response}

      nil ->
        # Task is still running but timed out
        Task.shutdown(task, :brutal_kill)

        timeout_response = build_timeout_response_impl(wrapper, raw_message, request_struct)
        {:ok, timeout_response}

      {:exit, reason} ->
        {:error, {:task_exit, reason}}
    end
  end

  defp get_timeout_for_transaction(wrapper, transaction_type, _raw_message) do
    case Map.get(wrapper.timeouts, transaction_type) do
      nil ->
        case Map.get(wrapper.timeouts, :default) do
          nil -> raise ArgumentError, "No timeout configured for transaction type: #{transaction_type}, and no :default timeout"
          default_timeout -> default_timeout
        end

      timeout when is_integer(timeout) and timeout > 0 ->
        timeout
    end
  end

  defp build_timeout_response_from_struct(wrapper, request_struct) do
    # Find the handler to get the response module
    case TransactionProcessor.find_handler(wrapper.processor_module, request_struct) do
      {:ok, handler} ->
        build_response_with_fields(wrapper, handler.response_module, request_struct)

      {:error, :not_found} ->
        # No handler found, return minimal error
        %{
          wrapper.timeout_response_field => wrapper.timeout_response_code
        }
    end
  end

  defp build_timeout_response_from_raw(wrapper, raw_message) do
    # Try to parse the raw message to get request struct
    case TransactionProcessor.parse_message(
           wrapper.processor_module,
           raw_message,
           %{}
         ) do
      {:ok, request_struct} ->
        build_timeout_response_from_struct(wrapper, request_struct)

      {:error, _} ->
        # Could not parse, return minimal error response
        %{
          wrapper.timeout_response_field => wrapper.timeout_response_code
        }
    end
  end

  defp build_response_with_fields(wrapper, response_module, request_struct) do
    # Build base response struct
    base_response =
      if function_exported?(response_module, :__transaction_type__, 2) do
        response_module.__transaction_type__(
          :struct,
          %{}
        )
      else
        %{}
      end

    # Set timeout response code
    base_response
    |> Map.put(wrapper.timeout_response_field, wrapper.timeout_response_code)
    |> copy_common_fields(request_struct, response_module)
  end

  defp copy_common_fields(response, request_struct, response_module) do
    # Common fields to copy from request to response for timeout
    common_fields = [
      :stan,        # System Trace Audit Number (field 11)
      :mti,         # Message Type Indicator
      :processing_code,
      :terminal_id,
      :merchant_id
    ]

    # Also check for copyable fields from transaction type
    copyable_fields =
      if function_exported?(response_module, :__transaction_type__, 2) do
        case response_module.__transaction_type__(:copyable_fields, []) do
          fields when is_list(fields) -> fields
          _ -> []
        end
      else
        []
      end

    all_fields_to_copy = Enum.uniq(common_fields ++ copyable_fields)

    Enum.reduce(all_fields_to_copy, response, fn field, acc ->
      case Map.fetch(request_struct, field) do
        {:ok, value} -> Map.put(acc, field, value)
        :error -> acc
      end
    end)
  end

  defp build_wrapper_from_config(wrapper_module) do
    config = wrapper_module.__wrapper_config__()

    %__MODULE__{
      processor_module: Keyword.get(config, :processor),
      timeouts: Keyword.get(config, :timeouts, %{}),
      timeout_response_field: Keyword.get(config, :timeout_response_field, 39),
      timeout_response_code: Keyword.get(config, :timeout_response_code, "68"),
      task_supervisor: Keyword.get(config, :task_supervisor, TransactionProcessor.TaskSupervisor),
      transaction_type_detector: Keyword.get(config, :transaction_type_detector, &__MODULE__.default_transaction_type_detector/1)
    }
  end

  defp determine_transaction_type_from_struct(request_struct) do
    # Try to get transaction type from the struct's module or attributes
    cond do
      Map.has_key?(request_struct, :__transaction_type__) ->
        request_struct.__transaction_type__

      function_exported?(request_struct.__struct__, :__transaction_type__, 2) ->
        case request_struct.__struct__.__transaction_type__(:transaction_type, []) do
          nil -> :default
          type when is_atom(type) -> type
          _ -> :default
        end

      true ->
        :default
    end
  end

  @doc """
  Default transaction type detector.

  Determines transaction type from MTI (first 4 bytes) and Processing Code (field 3).

  ## Transaction Type Mapping

  | MTI  | Processing Code | Transaction Type      |
  |------|-----------------|-----------------------|
  | 0200 | 00xxxx          | balance_inquiry       |
  | 0200 | 001000          | sale                  |
  | 0200 | 002000          | sale_with_cashback    |
  | 0200 | 310000          | batch_close           |
  | 0220 | 001000          | refund                |
  | 0400 | 001000          | capture               |
  | 0420 | 001000          | capture_refund        |
  | 0400 | 002000          | void                  |
  | 0420 | 002000          | reversal              |
  | 0500 | 001000          | settlement            |
  | 0800 | 001000          | network_management    |

  Returns `:default` if transaction type cannot be determined.
  """
  def default_transaction_type_detector(raw_message) do
    with {:ok, mti} <- extract_mti(raw_message),
         {:ok, processing_code} <- extract_processing_code(raw_message) do
      map_to_transaction_type(mti, processing_code)
    else
      _ -> :default
    end
  end

  defp extract_mti(<<mti::bytes-size(4), _rest::binary>>) when is_binary(mti), do: {:ok, mti}
  defp extract_mti(<<_rest::binary>>), do: {:error, :no_mti}

  # For BCD-encoded MTI (common in ISO 8583)
  defp extract_mti(raw_message) when byte_size(raw_message) >= 2 do
    try do
      # Try to decode BCD MTI
      <<mti_bcd::bytes-size(2), _rest::binary>> = raw_message
      mti = Ex_Iso8583.Util.bcd_to_str(mti_bcd)
      if String.length(mti) == 4 do
        {:ok, mti}
      else
        {:error, :invalid_mti}
      end
    rescue
      _ -> {:error, :no_mti}
    end
  end

  defp extract_mti(_), do: {:error, :no_mti}

  defp extract_processing_code(raw_message) do
    # Processing code is typically field 3 (6 digits, fixed or variable)
    # For simplicity, we'll assume it's at a known position after MTI and bitmap
    # In a real implementation, you'd parse the full ISO message

    # For now, return a default - this should be overridden with a custom detector
    {:ok, "001000"}
  end

  defp map_to_transaction_type("0200", "001000"), do: :sale
  defp map_to_transaction_type("0200", "002000"), do: :sale_with_cashback
  defp map_to_transaction_type("0200", "310000"), do: :batch_close
  defp map_to_transaction_type("0200", "00" <> _), do: :balance_inquiry
  defp map_to_transaction_type("0220", "001000"), do: :refund
  defp map_to_transaction_type("0400", "001000"), do: :capture
  defp map_to_transaction_type("0420", "001000"), do: :capture_refund
  defp map_to_transaction_type("0400", "002000"), do: :void
  defp map_to_transaction_type("0420", "002000"), do: :reversal
  defp map_to_transaction_type("0500", "001000"), do: :settlement
  defp map_to_transaction_type("0800", _), do: :network_management
  defp map_to_transaction_type(_, _), do: :default
end

defmodule TransactionProcessor.TimeoutSupervisor do
  @moduledoc """
  Task supervisor for async transaction processing with timeouts.

  This supervisor should be added to your application's supervision tree
  to ensure proper isolation of timed-out tasks.

  ## Adding to Supervision Tree

      children = [
        TransactionProcessor.TimeoutSupervisor
      ]

      opts = [strategy: :one_for_one, name: MySupervisor]
      Supervisor.start_link(children, opts)
  """

  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    # Start a Task.Supervisor as a child
    children = [
      {Task.Supervisor, name: TransactionProcessor.TaskSupervisor}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end

defmodule TransactionProcessor.TaskSupervisor do
  @moduledoc false
  # This is the actual Task.Supervisor used by TimeoutWrapper
  # It's started by TransactionProcessor.TimeoutSupervisor
end
