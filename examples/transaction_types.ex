defmodule ExampleTransactionTypes do
  @moduledoc """
  Example transaction type definitions using Ex_Iso8583.TransactionType.

  These examples show how to define structs for different ISO 8583 message types
  with field mappings, mandatory fields, validation, and processing code patterns.

  ## Processing Code Patterns

  The `processing_code` option supports wildcard patterns:
  - Exact match: `"000000"` matches only "000000"
  - Prefix wildcard: `"00*"` matches all codes starting with "00"
  - Suffix wildcard: `"*0000"` matches all codes ending with "0000"
  - Full wildcard: `"*"` matches all codes (default)
  """

  # Authorization Request for purchases (processing code: 00xxxx)
  defmodule AuthRequestPurchase do
    @moduledoc """
    Authorization Request for purchases (MTI 0100, processing code 00*).

    Used for purchase authorization requests.
    """
    use Ex_Iso8583.TransactionType

    defstruct [
      :pan,               # Primary Account Number (Field 2)
      :processing_code,   # Processing Code (Field 3)
      :amount,            # Transaction Amount (Field 4)
      :stan,              # System Trace Audit Number (Field 11)
      :terminal_id,       # Card Acceptor Terminal ID (Field 41)
      :merchant_id        # Card Acceptor ID (Field 42)
    ]

    transaction_type "0100", processing_code: "00*" do
      fields %{
        pan: 2,
        processing_code: 3,
        amount: 4,
        stan: 11,
        terminal_id: 41,
        merchant_id: 42
      }

      mandatory [:pan, :processing_code, :amount, :stan, :terminal_id, :merchant_id]
    end
  end

  # Authorization Request for cash advances (processing code: 01xxxx)
  defmodule AuthRequestCashAdvance do
    @moduledoc """
    Authorization Request for cash advances (MTI 0100, processing code 01*).

    Similar to purchases but may require additional validation.
    """
    use Ex_Iso8583.TransactionType

    defstruct [
      :pan,
      :processing_code,
      :amount,
      :stan,
      :terminal_id,
      :merchant_id,
      :cashback_amount   # Additional field for cash advances
    ]

    transaction_type "0100", processing_code: "01*" do
      fields %{
        pan: 2,
        processing_code: 3,
        amount: 4,
        stan: 11,
        terminal_id: 41,
        merchant_id: 42,
        cashback_amount: 50  # Cashback amount
      }

      mandatory [:pan, :processing_code, :amount, :stan, :terminal_id, :merchant_id, :cashback_amount]
    end
  end

  # Authorization Request with specific processing code (exact match: 020000)
  defmodule AuthRequestInquiry do
    @moduledoc """
    Authorization Request for balance inquiries (MTI 0100, processing code 020000).

    Uses exact match for processing code - only "020000" will match.
    """
    use Ex_Iso8583.TransactionType

    defstruct [
      :pan,
      :processing_code,
      :stan,
      :terminal_id
    ]

    transaction_type "0100", processing_code: "020000" do
      fields %{
        pan: 2,
        processing_code: 3,
        stan: 11,
        terminal_id: 41
      }

      mandatory [:pan, :processing_code, :stan, :terminal_id]
    end
  end

  # Default Authorization Request (catch-all for other processing codes)
  defmodule AuthRequestDefault do
    @moduledoc """
    Default Authorization Request (MTI 0100, processing code *).

    Catches all authorization requests that don't match a more specific pattern.
    Should be registered last in the list for proper fallback behavior.
    """
    use Ex_Iso8583.TransactionType

    defstruct [
      :pan,
      :processing_code,
      :stan
    ]

    transaction_type "0100", processing_code: "*" do
      fields %{
        pan: 2,
        processing_code: 3,
        stan: 11
      }

      mandatory [:pan, :processing_code, :stan]
    end
  end

  # Financial Request (all processing codes ending with 000)
  defmodule FinancialRequestDefault do
    @moduledoc """
    Financial Request (MTI 0200, processing code *000).

    Matches financial requests with processing codes ending with "000".
    """
    use Ex_Iso8583.TransactionType

    defstruct [
      :pan,
      :processing_code,
      :amount,
      :stan,
      :terminal_id,
      :merchant_id
    ]

    transaction_type "0200", processing_code: "*000" do
      fields %{
        pan: 2,
        processing_code: 3,
        amount: 4,
        stan: 11,
        terminal_id: 41,
        merchant_id: 42
      }

      mandatory [:pan, :processing_code, :amount, :stan, :terminal_id, :merchant_id]
    end
  end

  @doc """
  All transaction type modules for authorization requests.
  Ordered by specificity (most specific first).
  """
  def authorization_modules do
    [
      AuthRequestInquiry,      # Exact match: "020000"
      AuthRequestPurchase,     # Prefix match: "00*"
      AuthRequestCashAdvance,  # Prefix match: "01*"
      AuthRequestDefault       # Wildcard: "*"
    ]
  end

  @doc """
  All transaction type modules for financial requests.
  """
  def financial_modules do
    [FinancialRequestDefault]
  end

  @doc """
  Parse and route a message to the appropriate transaction type.
  """
  def route_message(iso_msg, msg_type, field_format) do
    all_modules = authorization_modules() ++ financial_modules()

    case Ex_Iso8583.TransactionType.find_and_parse(
      all_modules,
      iso_msg,
      msg_type,
      field_format
    ) do
      {:ok, txn} -> {:ok, txn}
      {:error, {:no_matching_transaction_type, mti, proc_code}} ->
        {:error, {:unsupported_transaction, mti, proc_code}}
      {:error, reason} -> {:error, reason}
    end
  end
end
