defmodule FormValidationTest do
  use ExUnit.Case

  alias Ex_Iso8583

  @msg_type %{bitmap_type: :binary, field_header_type: :bcd}

  @field_format %{
    2 => "n ..19",
    3 => "n 6",
    4 => "n 12",
    11 => "n 6",
    39 => "n 3",
    41 => "ans 8",
    42 => "ans 15"
  }

  describe "form_iso_msg/4 with validate: true" do
    test "returns {:ok, binary} for valid field data" do
      data = %{
        2 => "1234567890123456789",
        3 => "000000",
        4 => "000000001234"
      }

      assert {:ok, binary} = Ex_Iso8583.form_iso_msg(data, @msg_type, @field_format, validate: true)
      assert is_binary(binary)
      assert byte_size(binary) > 0
    end

    test "returns error for undefined fields" do
      data = %{
        2 => "1234567890123456789",
        999 => "some_value"  # Undefined field
      }

      assert {:error, {:undefined_fields, undefined, _defined}} =
        Ex_Iso8583.form_iso_msg(data, @msg_type, @field_format, validate: true)

      assert 999 in undefined
    end

    test "returns error for invalid numeric field value" do
      data = %{
        2 => "ABC123",  # Should be numeric (n ..19)
        3 => "000000"
      }

      assert {:error, {:invalid_field_value, 2, _reason}} =
        Ex_Iso8583.form_iso_msg(data, @msg_type, @field_format, validate: true)
    end

    test "returns error for value exceeding maximum length" do
      data = %{
        3 => "1234567",  # Max length is 6
        4 => "000000001234"
      }

      assert {:error, {:invalid_field_value, 3, reason}} =
        Ex_Iso8583.form_iso_msg(data, @msg_type, @field_format, validate: true)

      assert reason =~ "exceeds maximum"
    end

    test "without validate option returns binary directly (backward compatible)" do
      data = %{
        2 => "1234567890123456789",
        3 => "000000",
        4 => "000000001234"
      }

      # Should return binary directly, not {:ok, binary}
      binary = Ex_Iso8583.form_iso_msg(data, @msg_type, @field_format)
      assert is_binary(binary)
    end
  end

  describe "TransactionType.form_and_validate/4" do
    # Define a test transaction type
    defmodule TestAuthRequest do
      use Ex_Iso8583.TransactionType

      defstruct [
        :pan,
        :processing_code,
        :amount,
        :stan,
        :terminal_id,
        :merchant_id
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

    test "forms valid message from struct" do
      request = %TestAuthRequest{
        pan: "1234567890123456789",
        processing_code: "000000",
        amount: "000000001234",
        stan: "000001",
        terminal_id: "12345678",
        merchant_id: "123456789012345"
      }

      assert {:ok, binary} = TestAuthRequest.form_and_validate(request, @msg_type, @field_format)
      assert is_binary(binary)
    end

    test "returns error for missing mandatory fields" do
      request = %TestAuthRequest{
        pan: "1234567890123456789",
        processing_code: "000000",
        amount: "000000001234"
        # Missing: stan, terminal_id, merchant_id
      }

      assert {:error, {:missing_fields, "0100", "*", missing}} =
        TestAuthRequest.form_and_validate(request, @msg_type, @field_format)

      assert :stan in missing
      assert :terminal_id in missing
      assert :merchant_id in missing
    end

    test "returns error for invalid field values" do
      request = %TestAuthRequest{
        pan: "ABC123",  # Invalid - should be numeric
        processing_code: "000000",
        amount: "000000001234",
        stan: "000001",
        terminal_id: "12345678",
        merchant_id: "123456789012345"
      }

      assert {:error, {:invalid_field_value, 2, _reason}} =
        TestAuthRequest.form_and_validate(request, @msg_type, @field_format)
    end
  end

  describe "TransactionTypeGroup.form_and_validate/4" do
    # Define a test transaction group
    defmodule TestSaleGroup do
      use Ex_Iso8583.TransactionTypeGroup

      defrequest mti: "0200", processing_code: "00*" do
        defstruct [:pan, :processing_code, :amount, :stan, :terminal_id, :merchant_id]

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

      defresponse mti: "0210", processing_code: "00*" do
        defstruct [:pan, :processing_code, :amount, :stan, :response_code]

        fields %{
          pan: 2,
          processing_code: 3,
          amount: 4,
          stan: 11,
          response_code: 39
        }

        mandatory [:pan, :processing_code, :amount, :stan, :response_code]
      end
    end

    test "forms valid message from request struct" do
      request = %TestSaleGroup.Request{
        pan: "1234567890123456789",
        processing_code: "000000",
        amount: "000000001234",
        stan: "000001",
        terminal_id: "12345678",
        merchant_id: "123456789012345"
      }

      assert {:ok, {:request, binary}} =
        TestSaleGroup.form_and_validate(request, @msg_type, @field_format)

      assert is_binary(binary)
    end

    test "forms valid message from response struct" do
      response = %TestSaleGroup.Response{
        pan: "1234567890123456789",
        processing_code: "000000",
        amount: "000000001234",
        stan: "000001",
        response_code: "000"
      }

      assert {:ok, {:response, binary}} =
        TestSaleGroup.form_and_validate(response, @msg_type, @field_format)

      assert is_binary(binary)
    end

    test "returns error for unknown struct type" do
      some_other_struct = %{
        __struct__: SomeOtherModule,
        pan: "1234567890123456789"
      }

      assert {:error, {:unknown_struct_type, _}} =
        TestSaleGroup.form_and_validate(some_other_struct, @msg_type, @field_format)
    end
  end

  describe "Validator.validate_field_value/3 with format strings" do
    alias Ex_Iso8583.Validator

    test "validates numeric format 'n 6'" do
      assert :ok == Validator.validate_field_value(3, "123456", "n 6")
    end

    test "validates variable length numeric 'n ..19'" do
      assert :ok == Validator.validate_field_value(2, "12345", "n ..19")
      assert :ok == Validator.validate_field_value(2, String.duplicate("1", 19), "n ..19")
    end

    test "rejects non-numeric for 'n' format" do
      assert {:error, _} = Validator.validate_field_value(3, "12a456", "n 6")
    end

    test "rejects value exceeding max length" do
      assert {:error, reason} = Validator.validate_field_value(3, "1234567", "n 6")
      assert reason =~ "exceeds maximum"
    end

    test "validates alphanumeric 'an' format" do
      assert :ok == Validator.validate_field_value(42, "ABC123", "an 15")
    end

    test "validates Track 2 'z ..37' format" do
      assert :ok == Validator.validate_field_value(35, "1234567890123456=D12340000000000", "z ..37")
    end

    test "rejects invalid Track 2 format" do
      assert {:error, _} = Validator.validate_field_value(35, "ABCD1234", "z ..37")
    end
  end
end
