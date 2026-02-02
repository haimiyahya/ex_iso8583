defmodule TransactionTypeTest do
  use ExUnit.Case

  alias Ex_Iso8583

  # Define example transaction type within test module
  defmodule AuthRequest do
    @moduledoc "Authorization Request transaction type for testing"
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
    end
  end

  @msg_type %{bitmap_type: :binary, field_header_type: :bcd}

  @field_format %{
    2 => "n ..19",
    3 => "n 6",
    4 => "n 12",
    11 => "n 6",
    22 => "n 3",
    39 => "n 3",
    41 => "ans 8",
    42 => "ans 15",
    49 => "n 12"
  }

  describe "transaction_type definition" do
    test "defines MTI for the transaction type" do
      assert AuthRequest.mti() == "0100"
    end

    test "defines field mapping" do
      mapping = AuthRequest.field_mapping()

      assert mapping.pan == 2
      assert mapping.processing_code == 3
      assert mapping.amount == 4
      assert mapping.stan == 11
      assert mapping.terminal_id == 41
      assert mapping.merchant_id == 42
    end

    test "returns mandatory fields for default processing code" do
      mandatory = AuthRequest.mandatory_fields()

      assert :pan in mandatory
      assert :processing_code in mandatory
      assert :amount in mandatory
      assert :stan in mandatory
      assert :terminal_id in mandatory
      assert :merchant_id in mandatory
    end

    test "returns optional fields" do
      optional = AuthRequest.optional_fields()
      # AuthRequest doesn't have optional fields in the example
      assert is_list(optional)
    end
  end

  describe "parse_and_validate/4" do
    setup do
      # Create a valid authorization request message
      data = %{
        2 => "1234567890123456789",
        3 => "000000",
        4 => "000000001234",
        11 => "000001",
        41 => "12345678",
        42 => "123456789012345"
      }

      iso_msg = Ex_Iso8583.form_iso_msg(data, @msg_type, @field_format)

      %{iso_msg: iso_msg, data: data}
    end

    test "parses valid message and creates struct", %{iso_msg: iso_msg, data: data} do
      assert {:ok, txn} = AuthRequest.parse_and_validate(iso_msg, @msg_type, @field_format)

      assert %AuthRequest{} = txn
      # PAN is left-padded with zero to 19 digits due to format "n ..19"
      assert txn.pan == "0123456789012345678"
      assert txn.processing_code == "000000"
      assert txn.amount == "000000001234"
      assert txn.stan == "000001"
      assert txn.terminal_id == "12345678"
      assert txn.merchant_id == "123456789012345"
    end

    test "returns error when mandatory field is missing", %{iso_msg: iso_msg} do
      # Create message without PAN (field 2)
      data = %{
        3 => "000000",
        4 => "000000001234",
        11 => "000001",
        41 => "12345678",
        42 => "123456789012345"
      }

      iso_msg = Ex_Iso8583.form_iso_msg(data, @msg_type, @field_format)

      assert {:error, {:missing_fields, missing}} =
        AuthRequest.parse_and_validate(iso_msg, @msg_type, @field_format)

      assert :pan in missing
    end

    test "ignores extra fields by default", %{iso_msg: iso_msg} do
      # Add extra field 22 (POS Entry Mode) which is not in AuthRequest definition
      data = %{
        2 => "1234567890123456789",
        3 => "000000",
        4 => "000000001234",
        11 => "000001",
        22 => "012",
        41 => "12345678",
        42 => "123456789012345"
      }

      iso_msg = Ex_Iso8583.form_iso_msg(data, @msg_type, @field_format)

      assert {:ok, txn} = AuthRequest.parse_and_validate(iso_msg, @msg_type, @field_format)
      # The struct doesn't have pos_entry_mode field
      refute Map.has_key?(txn, :pos_entry_mode)
    end

    test "returns error for extra fields when strict: true", %{iso_msg: iso_msg} do
      # First, define a transaction type with optional fields
      defmodule StrictAuthRequest do
        use Ex_Iso8583.TransactionType

        defstruct [:pan, :processing_code, :amount, :stan, :terminal_id, :merchant_id, :pos_entry_mode, :currency_code]

        transaction_type "0100" do
          fields %{
            pan: 2,
            processing_code: 3,
            amount: 4,
            stan: 11,
            pos_entry_mode: 22,
            currency_code: 49,
            terminal_id: 41,
            merchant_id: 42
          }

          mandatory [:pan, :processing_code, :amount, :stan, :terminal_id, :merchant_id]
          optional [:pos_entry_mode]
          # Note: currency_code is in field_mapping but NOT in optional/mandatory
        end
      end

      # Now create a message with field 49 (currency code) which is mapped but not allowed
      data = %{
        2 => "1234567890123456789",
        3 => "000000",
        4 => "000000001234",
        11 => "000001",
        49 => "840",  # USD currency code - mapped but not in allowed fields
        41 => "12345678",
        42 => "123456789012345"
      }

      iso_msg = Ex_Iso8583.form_iso_msg(data, @msg_type, @field_format)

      assert {:error, {:extra_fields, extra}} =
        StrictAuthRequest.parse_and_validate(iso_msg, @msg_type, @field_format, strict: true)

      # The extra field is the currency_code
      assert :currency_code in extra
    end

    test "allows extra fields when strict: false" do
      # Define a transaction type
      defmodule FlexibleAuthRequest do
        use Ex_Iso8583.TransactionType

        defstruct [:pan, :processing_code, :amount, :stan, :terminal_id, :merchant_id]

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
        end
      end

      data = %{
        2 => "1234567890123456789",
        3 => "000000",
        4 => "000000001234",
        11 => "000001",
        22 => "012",  # Extra field not in definition
        41 => "12345678",
        42 => "123456789012345"
      }

      iso_msg = Ex_Iso8583.form_iso_msg(data, @msg_type, @field_format)

      assert {:ok, txn} =
        FlexibleAuthRequest.parse_and_validate(iso_msg, @msg_type, @field_format, strict: false)

      # Should succeed, extra field ignored
      # PAN is left-padded with zero to 19 digits due to format "n ..19"
      assert txn.pan == "0123456789012345678"
    end
  end

  describe "validate_and_create/3" do
    test "creates struct from already parsed field data" do
      field_data = %{
        2 => "1234567890123456789",
        3 => "000000",
        4 => "000000001234",
        11 => "000001",
        41 => "12345678",
        42 => "123456789012345"
      }

      assert {:ok, txn} = AuthRequest.validate_and_create(field_data, "00")

      assert %AuthRequest{} = txn
      assert txn.pan == "1234567890123456789"
    end

    test "uses processing code specific mandatory fields" do
      # For AuthRequest, processing code "01" has the same mandatory fields
      field_data = %{
        2 => "1234567890123456789",
        3 => "010000",
        4 => "000000001234",
        11 => "000001",
        41 => "12345678",
        42 => "123456789012345"
      }

      assert {:ok, txn} = AuthRequest.validate_and_create(field_data, "01")

      assert %AuthRequest{} = txn
      assert txn.processing_code == "010000"
    end

    test "returns error for missing fields" do
      field_data = %{
        2 => "1234567890123456789",
        3 => "000000",
        4 => "000000001234"
        # Missing stan, terminal_id, merchant_id
      }

      assert {:error, {:missing_fields, missing}} =
        AuthRequest.validate_and_create(field_data, "00")

      assert :stan in missing
      assert :terminal_id in missing
      assert :merchant_id in missing
    end
  end

  describe "create/1" do
    test "creates struct without validation" do
      field_data = %{
        2 => "1234567890123456789",
        3 => "000000"
      }

      txn = AuthRequest.create(field_data)

      assert %AuthRequest{} = txn
      assert txn.pan == "1234567890123456789"
      assert txn.processing_code == "000000"
    end
  end

  describe "integration with Ex_Iso8583" do
    test "transaction type module does not affect Ex_Iso8583" do
      # Ex_Iso8583 should work independently
      data = %{3 => "123456", 4 => "000000001234"}
      msg = Ex_Iso8583.form_iso_msg(data, @msg_type, @field_format)

      assert is_binary(msg)

      extracted = Ex_Iso8583.extract_iso_msg(msg, @msg_type, @field_format)
      assert extracted == data
    end
  end

  describe "multiple transaction types" do
    # Define additional transaction types for testing
    defmodule AuthResponse do
      @moduledoc "Authorization Response transaction type for testing"
      use Ex_Iso8583.TransactionType

      defstruct [:pan, :processing_code, :amount, :stan, :terminal_id, :merchant_id, :response_code]

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
      @moduledoc "Financial Request transaction type for testing"
      use Ex_Iso8583.TransactionType

      defstruct [:pan, :processing_code, :amount, :stan, :terminal_id, :merchant_id, :pos_entry_mode]

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
      end
    end

    test "each transaction type has its own MTI" do
      assert AuthRequest.mti() == "0100"
      assert AuthResponse.mti() == "0110"
      assert FinancialRequest.mti() == "0200"
    end

    test "each transaction type has its own field mappings" do
      assert Map.get(AuthRequest.field_mapping(), :response_code) == nil
      assert Map.get(AuthResponse.field_mapping(), :response_code) == 39
      assert Map.get(FinancialRequest.field_mapping(), :pos_entry_mode) == 22
    end
  end

  describe "processing code patterns" do
    # Define transaction types with different processing code patterns
    defmodule PurchaseRequest do
      use Ex_Iso8583.TransactionType
      defstruct [:pan, :processing_code, :amount]
      transaction_type "0100", processing_code: "00*" do
        fields %{pan: 2, processing_code: 3, amount: 4}
        mandatory [:pan, :processing_code, :amount]
      end
    end

    defmodule CashAdvanceRequest do
      use Ex_Iso8583.TransactionType
      defstruct [:pan, :processing_code, :amount, :cashback]
      transaction_type "0100", processing_code: "01*" do
        fields %{pan: 2, processing_code: 3, amount: 4, cashback: 50}
        mandatory [:pan, :processing_code, :amount, :cashback]
      end
    end

    defmodule InquiryRequest do
      use Ex_Iso8583.TransactionType
      defstruct [:pan, :processing_code, :stan]
      transaction_type "0100", processing_code: "020000" do
        fields %{pan: 2, processing_code: 3, stan: 11}
        mandatory [:pan, :processing_code, :stan]
      end
    end

    defmodule DefaultRequest do
      use Ex_Iso8583.TransactionType
      defstruct [:pan, :processing_code]
      transaction_type "0100", processing_code: "*" do
        fields %{pan: 2, processing_code: 3}
        mandatory [:pan, :processing_code]
      end
    end

    alias Ex_Iso8583.TransactionType

    test "matches_pattern?/2 matches exact patterns" do
      assert TransactionType.matches_pattern?("020000", "020000")
      refute TransactionType.matches_pattern?("020000", "020001")
    end

    test "matches_pattern?/2 matches prefix wildcards" do
      assert TransactionType.matches_pattern?("00*", "000000")
      assert TransactionType.matches_pattern?("00*", "001234")
      assert TransactionType.matches_pattern?("00*", "009999")
      refute TransactionType.matches_pattern?("00*", "010000")
      refute TransactionType.matches_pattern?("00*", "990000")
    end

    test "matches_pattern?/2 matches suffix wildcards" do
      assert TransactionType.matches_pattern?("*000", "000000")
      assert TransactionType.matches_pattern?("*000", "99000")
      assert TransactionType.matches_pattern?("*000", "12345000")
      refute TransactionType.matches_pattern?("*000", "000001")
      refute TransactionType.matches_pattern?("*000", "001230")
    end

    test "matches_pattern?/2 matches full wildcard" do
      assert TransactionType.matches_pattern?("*", "anything")
      assert TransactionType.matches_pattern?("*", "000000")
      assert TransactionType.matches_pattern?("*", "999999")
      assert TransactionType.matches_pattern?("*", "")
    end

    test "transaction_type/2 returns processing_code_pattern" do
      assert PurchaseRequest.processing_code_pattern() == "00*"
      assert CashAdvanceRequest.processing_code_pattern() == "01*"
      assert InquiryRequest.processing_code_pattern() == "020000"
      assert DefaultRequest.processing_code_pattern() == "*"
    end

    test "matches?/2 checks if MTI and processing code match" do
      assert PurchaseRequest.matches?("0100", "000000")
      assert PurchaseRequest.matches?("0100", "001234")
      refute PurchaseRequest.matches?("0100", "010000")
      refute PurchaseRequest.matches?("0110", "000000")

      assert InquiryRequest.matches?("0100", "020000")
      refute InquiryRequest.matches?("0100", "020001")

      assert DefaultRequest.matches?("0100", "999999")
      assert DefaultRequest.matches?("0100", "123456")
    end

    test "find_transaction_type/3 finds exact match over wildcard" do
      modules = [PurchaseRequest, InquiryRequest, DefaultRequest]

      # Exact match should be preferred over prefix/wildcard
      assert {:ok, InquiryRequest} = TransactionType.find_transaction_type(modules, "0100", "020000")

      # Prefix match should be found
      assert {:ok, PurchaseRequest} = TransactionType.find_transaction_type(modules, "0100", "000000")
      assert {:ok, PurchaseRequest} = TransactionType.find_transaction_type(modules, "0100", "009999")

      # Fallback to wildcard
      assert {:ok, DefaultRequest} = TransactionType.find_transaction_type(modules, "0100", "999999")

      # No match for different MTI
      assert {:error, :no_match} = TransactionType.find_transaction_type(modules, "0200", "000000")
    end

    test "find_transaction_type/3 prioritizes exact > prefix > suffix > wildcard" do
      # Define modules with different pattern types for the same MTI
      defmodule ExactPattern do
        use Ex_Iso8583.TransactionType
        defstruct [:pan]
        transaction_type "0200", processing_code: "000000" do
          fields %{pan: 2}
          mandatory [:pan]
        end
      end

      defmodule PrefixPattern do
        use Ex_Iso8583.TransactionType
        defstruct [:pan, :amount]
        transaction_type "0200", processing_code: "00*" do
          fields %{pan: 2, amount: 4}
          mandatory [:pan, :amount]
        end
      end

      defmodule SuffixPattern do
        use Ex_Iso8583.TransactionType
        defstruct [:pan, :stan]
        transaction_type "0200", processing_code: "*000" do
          fields %{pan: 2, stan: 11}
          mandatory [:pan, :stan]
        end
      end

      defmodule WildcardPattern do
        use Ex_Iso8583.TransactionType
        defstruct [:pan]
        transaction_type "0200", processing_code: "*" do
          fields %{pan: 2}
          mandatory [:pan]
        end
      end

      modules = [PrefixPattern, SuffixPattern, WildcardPattern, ExactPattern]

      # Exact match wins
      assert {:ok, ExactPattern} = TransactionType.find_transaction_type(modules, "0200", "000000")

      # Prefix match comes before suffix
      assert {:ok, PrefixPattern} = TransactionType.find_transaction_type(modules, "0200", "001234")

      # Suffix match
      assert {:ok, SuffixPattern} = TransactionType.find_transaction_type(modules, "0200", "99000")

      # Wildcard fallback
      assert {:ok, WildcardPattern} = TransactionType.find_transaction_type(modules, "0200", "999999")
    end
  end
end
