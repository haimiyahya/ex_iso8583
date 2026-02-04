defmodule TransactionProcessor.TimeoutWrapperTest do
  use ExUnit.Case

  # Start the TimeoutSupervisor for tests
  setup_all do
    start_supervised!(TransactionProcessor.TimeoutSupervisor)
    :ok
  end

  # Mock structs for testing
  defmodule SaleRequest do
    defstruct [:pan, :amount, :stan, :processing_code]
  end

  defmodule SaleResponse do
    defstruct [:response_code, :amount, :stan]
  end

  defmodule TimeoutTestProcessor do
    use TransactionProcessor

    config error_response_code_field: 39,
          error_message_field: 60

    defhandler :sale, SaleRequest, SaleResponse do
      def handle(%SaleRequest{amount: amount, stan: stan}) do
        # Simulate processing time
        Process.sleep(100)
        %SaleResponse{response_code: "00", amount: amount, stan: stan}
      end
    end
  end

  defmodule TimeoutTestWrapper do
    use TransactionProcessor.TimeoutWrapper,
      processor: TimeoutTestProcessor,
      timeouts: %{
        sale: 500,
        # Short timeout to trigger timeout in tests
        slow_sale: 50,
        # Very short timeout
        default: 1000
      },
      timeout_response_field: 39,
      timeout_response_code: "68"
  end

  describe "TimeoutWrapper" do
    test "has wrapper configuration" do
      config = TimeoutTestWrapper.__wrapper_config__()

      assert config[:processor] == TimeoutTestProcessor
      assert config[:timeouts][:sale] == 500
      assert config[:timeouts][:slow_sale] == 50
      assert config[:timeout_response_field] == 39
      assert config[:timeout_response_code] == "68"
    end

    test "returns timeout for configured transaction type" do
      assert TimeoutTestWrapper.get_timeout(:sale) == 500
      assert TimeoutTestWrapper.get_timeout(:slow_sale) == 50
    end

    test "returns nil for unconfigured transaction type" do
      assert TimeoutTestWrapper.get_timeout(:unknown) == nil
    end

    test "returns default timeout when configured" do
      assert TimeoutTestWrapper.get_timeout!(:unknown_with_default) == 1000
    end
  end

  describe "process_with_timeout" do
    test "completes successfully when processing finishes before timeout" do
      request = %SaleRequest{
        pan: "1234567890123456",
        amount: 10000,
        stan: "000123",
        processing_code: "001000"
      }

      # 100ms processing, 500ms timeout - should succeed
      assert {:ok, %SaleResponse{response_code: "00", amount: 10000, stan: "000123"}} =
               TimeoutTestWrapper.process_struct_with_timeout(request)
    end

    test "returns timeout response when processing exceeds timeout" do
      # Create a slow request by setting a special amount
      request = %SaleRequest{
        pan: "1234567890123456",
        amount: 99999,  # Triggers slow processing
        stan: "000124",
        processing_code: "001000"
      }

      # We'll test timeout by using a wrapper with very short timeout
      defmodule QuickTimeoutWrapper do
        use TransactionProcessor.TimeoutWrapper,
          processor: TimeoutTestProcessor,
          timeouts: %{
            sale: 10,  # 10ms timeout - will definitely timeout
            default: 10
          },
          timeout_response_code: "68"
      end

      request = %SaleRequest{
        pan: "1234567890123456",
        amount: 10000,
        stan: "000125",
        processing_code: "001000"
      }

      # Should return timeout response
      assert {:ok, response} = QuickTimeoutWrapper.process_struct_with_timeout(request)
      assert Map.get(response, 39) == "68"
    end
  end

  describe "transaction type detection" do
    test "detects sale transaction from MTI and processing code" do
      # MTI 0200, processing code 001000 = sale
      mti = "0200"
      processing_code = "001000"

      type = TransactionProcessor.TimeoutWrapper.default_transaction_type_detector(
        mti <> processing_code
      )

      assert type == :sale
    end

    test "detects refund transaction" do
      mti = "0220"
      processing_code = "001000"

      type = TransactionProcessor.TimeoutWrapper.default_transaction_type_detector(
        mti <> processing_code
      )

      assert type == :refund
    end

    test "detects settlement transaction" do
      mti = "0500"
      processing_code = "001000"

      type = TransactionProcessor.TimeoutWrapper.default_transaction_type_detector(
        mti <> processing_code
      )

      assert type == :settlement
    end

    test "returns default for unknown transaction" do
      mti = "0999"
      processing_code = "999999"

      type = TransactionProcessor.TimeoutWrapper.default_transaction_type_detector(
        mti <> processing_code
      )

      assert type == :default
    end
  end

  describe "timeout response builder" do
    test "builds timeout response with copied fields from request" do
      defmodule TestTimeoutWrapper do
        use TransactionProcessor.TimeoutWrapper,
          processor: TimeoutTestProcessor,
          timeouts: %{sale: 100},
          timeout_response_code: "68"
      end

      wrapper_struct = %TransactionProcessor.TimeoutWrapper{
        processor_module: TimeoutTestProcessor,
        timeouts: %{sale: 100},
        timeout_response_field: 39,
        timeout_response_code: "68"
      }

      request = %SaleRequest{
        pan: "1234567890123456",
        amount: 10000,
        stan: "000999",
        processing_code: "001000"
      }

      # Build timeout response
      response =
        TransactionProcessor.TimeoutWrapper.build_timeout_response(
          wrapper_struct,
          nil,
          request
        )

      assert Map.get(response, 39) == "68"
      assert Map.get(response, :stan) == "000999"
    end
  end

  describe "custom transaction type detector" do
    test "allows custom transaction type detection" do
      defmodule CustomDetectorWrapper do
        use TransactionProcessor.TimeoutWrapper,
          processor: TimeoutTestProcessor,
          timeouts: %{custom_type: 1000},
          transaction_type_detector: &__MODULE__.detect_custom/1

        def detect_custom(_message) do
          :custom_type
        end
      end

      assert CustomDetectorWrapper.get_timeout(:custom_type) == 1000
    end
  end
end
