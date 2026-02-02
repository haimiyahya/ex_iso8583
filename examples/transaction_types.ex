defmodule ExampleTransactionTypes do
  @moduledoc """
  Example transaction type definitions using Ex_Iso8583.TransactionType.

  These examples show how to define structs for different ISO 8583 message types
  with field mappings, mandatory fields, and validation.
  """

  defmodule AuthRequest do
    @moduledoc """
    Authorization Request (MTI 0100) transaction type.

    Used for authorization requests in card-present and card-not-present scenarios.
    """
    use Ex_Iso8583.TransactionType

    defstruct [
      :pan,               # Primary Account Number (Field 2)
      :processing_code,    # Processing Code (Field 3)
      :amount,            # Transaction Amount (Field 4)
      :stan,              # System Trace Audit Number (Field 11)
      :terminal_id,       # Card Acceptor Terminal ID (Field 41)
      :merchant_id        # Card Acceptor ID (Field 42)
    ]

    transaction_type "0100" do
      fields %{
        pan: 2,
        processing_code: 3,
        amount: 4,
        stan: 11,
        terminal_id: 41,
        merchant_id: 42
      }

      mandatory [:pan, :processing_code, :amount, :stan, :terminal_id, :merchant_id]

      # Processing code specific overrides
      processing_code "00" do
        # Purchase - same as default
        mandatory [:pan, :processing_code, :amount, :stan, :terminal_id, :merchant_id]
      end

      processing_code "01" do
        # Cash advance - same fields for now
        mandatory [:pan, :processing_code, :amount, :stan, :terminal_id, :merchant_id]
      end
    end
  end

  defmodule AuthResponse do
    @moduledoc """
    Authorization Response (MTI 0110) transaction type.
    """
    use Ex_Iso8583.TransactionType

    defstruct [
      :pan,
      :processing_code,
      :amount,
      :stan,
      :terminal_id,
      :merchant_id,
      :response_code
    ]

    transaction_type "0110" do
      fields %{
        pan: 2,
        processing_code: 3,
        amount: 4,
        stan: 11,
        terminal_id: 41,
        merchant_id: 42,
        response_code: 39
      }

      mandatory [:pan, :processing_code, :amount, :stan, :response_code]
      optional [:terminal_id, :merchant_id]
    end
  end

  defmodule FinancialRequest do
    @moduledoc """
    Financial Request (MTI 0200) transaction type.
    """
    use Ex_Iso8583.TransactionType

    defstruct [
      :pan,
      :processing_code,
      :amount,
      :stan,
      :terminal_id,
      :merchant_id,
      :pos_entry_mode
    ]

    transaction_type "0200" do
      fields %{
        pan: 2,
        processing_code: 3,
        amount: 4,
        stan: 11,
        pos_entry_mode: 22,
        terminal_id: 41,
        merchant_id: 42
      }

      mandatory [:pan, :processing_code, :amount, :stan, :pos_entry_mode, :terminal_id, :merchant_id]
      optional []
    end
  end

  defmodule FinancialResponse do
    @moduledoc """
    Financial Response (MTI 0210) transaction type.
    """
    use Ex_Iso8583.TransactionType

    defstruct [
      :pan,
      :processing_code,
      :amount,
      :stan,
      :terminal_id,
      :merchant_id,
      :response_code,
      :settlement_amount
    ]

    transaction_type "0210" do
      fields %{
        pan: 2,
        processing_code: 3,
        amount: 4,
        stan: 11,
        terminal_id: 41,
        merchant_id: 42,
        response_code: 39,
        settlement_amount: 49
      }

      mandatory [:pan, :processing_code, :amount, :stan, :response_code]
      optional [:terminal_id, :merchant_id, :settlement_amount]
    end
  end
end
