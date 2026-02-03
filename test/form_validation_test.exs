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

  describe "Validator.validate_field_value/4 with data types" do
    alias Ex_Iso8583.Validator

    test "validates BCD (numeric) data type" do
      assert :ok == Validator.validate_field_value(3, "123456", :bcd, 6)
      assert :ok == Validator.validate_field_value(3, "0", :bcd, 6)
    end

    test "rejects non-numeric for BCD data type" do
      assert_raise Ex_Iso8583.Errors.InvalidFieldValueError, fn ->
        Validator.validate_field_value(3, "12a456", :bcd, 6)
      end
    end

    test "validates ASCII data type" do
      assert :ok == Validator.validate_field_value(42, "ABC123!@#", :ascii, 15)
      assert :ok == Validator.validate_field_value(42, "Test Value", :ascii, 15)
    end

    test "validates ANS (alphanumeric special) data type" do
      assert :ok == Validator.validate_field_value(43, "ABC123!@#$%", :ans, 15)
      assert :ok == Validator.validate_field_value(43, "Test Value", :ans, 15)
    end

    test "rejects non-printable ASCII" do
      assert {:error, _} = Validator.validate_field_value(42, "Test\x01Value", :ascii, 15)
    end

    test "validates Track 2 (z) data type" do
      assert :ok == Validator.validate_field_value(35, "1234567890123456=D12340000000000", :z, 37)
      assert :ok == Validator.validate_field_value(35, "1234=5678", :z, 37)
    end

    test "validates Track 2 with D and F separators" do
      assert :ok == Validator.validate_field_value(35, "1234567890123456D1234", :z, 37)
      assert :ok == Validator.validate_field_value(35, "1234567890123456F1234", :z, 37)
    end

    test "rejects Track 2 not starting with digit" do
      assert_raise Ex_Iso8583.Errors.InvalidFieldValueError, ~r/Track 2 data must start with a digit/, fn ->
        Validator.validate_field_value(35, "ABCD1234", :z, 37)
      end
    end

    test "rejects Track 2 with invalid characters" do
      assert_raise Ex_Iso8583.Errors.InvalidFieldValueError, ~r/Track 2/, fn ->
        Validator.validate_field_value(35, "1234X5678", :z, 37)
      end
    end

    test "validates binary data type" do
      assert :ok == Validator.validate_field_value(55, <<1, 2, 3, 4>>, :binary, 4)
      assert :ok == Validator.validate_field_value(55, "anything", :binary, 10)
    end

    test "validates hex data type" do
      assert :ok == Validator.validate_field_value(48, "1A2B3C", :hex, 10)
      assert :ok == Validator.validate_field_value(48, "0x1A2B3C", :hex, 10)
      assert :ok == Validator.validate_field_value(48, "abc123", :hex, 10)
      assert :ok == Validator.validate_field_value(48, "ABCDEF", :hex, 10)
      assert :ok == Validator.validate_field_value(48, "0x", :hex, 10)
    end

    test "rejects invalid hex values" do
      assert_raise Ex_Iso8583.Errors.InvalidFieldValueError, ~r/hex/, fn ->
        Validator.validate_field_value(48, "GHIJKL", :hex, 10)
      end

      assert_raise Ex_Iso8583.Errors.InvalidFieldValueError, ~r/hex/, fn ->
        Validator.validate_field_value(48, "1A2B3G", :hex, 10)
      end
    end
  end

  describe "Validator.validate_field_value/4 with format tuples" do
    alias Ex_Iso8583.Validator

    test "validates with format tuple {header, data_type, max_len, padding}" do
      assert :ok == Validator.validate_field_value(3, "123456", {0, :bcd, 6, nil})
      assert :ok == Validator.validate_field_value(2, "12345", {2, :bcd, 19, nil})
    end

    test "rejects invalid data type with format tuple" do
      assert {:error, _} = Validator.validate_field_value(3, "ABC123", {0, :bcd, 6, nil})
    end

    test "rejects value exceeding max length with format tuple" do
      assert {:error, _} = Validator.validate_field_value(3, "1234567", {0, :bcd, 6, nil})
    end
  end

  describe "boundary condition tests" do
    alias Ex_Iso8583.Validator

    test "accepts value at exact maximum length" do
      assert :ok == Validator.validate_field_value(4, String.duplicate("1", 12), "n 12")
      assert :ok == Validator.validate_field_value(2, String.duplicate("1", 19), "n ..19")
      assert :ok == Validator.validate_field_value(42, "ABC12345", "an 8")
    end

    test "rejects value exceeding maximum by one" do
      assert {:error, _} = Validator.validate_field_value(4, String.duplicate("1", 13), "n 12")
      assert {:error, _} = Validator.validate_field_value(2, String.duplicate("1", 20), "n ..19")
    end

    test "validates with max_length parameter" do
      assert :ok == Validator.validate_field_value(3, "123", :bcd, 6)
      assert :ok == Validator.validate_field_value(3, "123456", :bcd, 6)
    end

    test "rejects when exceeding max_length parameter" do
      assert_raise Ex_Iso8583.Errors.InvalidFieldValueError, ~r/maximum/, fn ->
        Validator.validate_field_value(3, "1234567", :bcd, 6)
      end
    end

    test "accepts when max_length is nil (no limit)" do
      long_value = String.duplicate("1", 100)
      assert :ok == Validator.validate_field_value(3, long_value, :bcd, nil)
    end
  end

  describe "edge case tests" do
    alias Ex_Iso8583.Validator

    test "validates single character values" do
      assert :ok == Validator.validate_field_value(3, "1", :bcd, 6)
      assert :ok == Validator.validate_field_value(42, "A", :ascii, 15)
    end

    test "validates all zeros" do
      assert :ok == Validator.validate_field_value(3, "000000", :bcd, 6)
      assert :ok == Validator.validate_field_value(4, "000000000000", :bcd, 12)
    end

    test "validates all nines" do
      assert :ok == Validator.validate_field_value(3, "999999", :bcd, 6)
      assert :ok == Validator.validate_field_value(4, "999999999999", :bcd, 12)
    end

    test "validates spaces in ASCII fields" do
      assert :ok == Validator.validate_field_value(42, "   ", :ascii, 15)
      assert :ok == Validator.validate_field_value(42, " ABC ", :ascii, 15)
    end

    test "validates special characters in ASCII fields" do
      assert :ok == Validator.validate_field_value(42, "!@#$%^&*()", :ascii, 15)
      assert :ok == Validator.validate_field_value(42, "[]{};':\",./<>?", :ascii, 20)
    end
  end

  describe "format string edge cases" do
    alias Ex_Iso8583.Validator

    test "validates uppercase format codes" do
      assert :ok == Validator.validate_field_value(3, "123456", "N 6")
      assert :ok == Validator.validate_field_value(42, "ABC123", "AN 15")
      assert :ok == Validator.validate_field_value(35, "1234=5678", "Z ..37")
    end

    test "validates mixed case format codes" do
      assert :ok == Validator.validate_field_value(42, "ABC123", "An 15")
      assert :ok == Validator.validate_field_value(42, "ABC123", "aN 15")
    end

    test "validates ANS format code" do
      assert :ok == Validator.validate_field_value(43, "ABC!@#", "ANS 15")
      assert :ok == Validator.validate_field_value(43, "ABC123!@#", "ANS 15")
    end

    test "validates format with extra spaces" do
      assert :ok == Validator.validate_field_value(3, "123456", "n   6")
      assert :ok == Validator.validate_field_value(2, "12345", "n  ..19")
    end

    test "validates binary format 'b'" do
      assert :ok == Validator.validate_field_value(55, "somedata", "b 100")
      assert :ok == Validator.validate_field_value(55, <<1, 2, 3>>, "b 10")
    end
  end

  describe "mixed validation scenarios" do
    test "returns first error when multiple fields are invalid" do
      data = %{
        2 => "ABC123",   # Invalid - should be numeric
        3 => "XYZ789",   # Invalid - should be numeric
        4 => "000000001234"  # Valid
      }

      # Should return first error encountered (field order may vary)
      assert {:error, {:invalid_field_value, field, _reason}} =
        Ex_Iso8583.form_iso_msg(data, @msg_type, @field_format, validate: true)

      assert field in [2, 3]
    end

    test "validates all fields when all are valid" do
      data = %{
        2 => "1234567890123456789",
        3 => "000000",
        4 => "000000001234",
        11 => "000001",
        39 => "000",
        41 => "12345678",
        42 => "123456789012345"
      }

      assert {:ok, binary} =
        Ex_Iso8583.form_iso_msg(data, @msg_type, @field_format, validate: true)

      assert is_binary(binary)
    end
  end

  describe "error message verification" do
    alias Ex_Iso8583.Validator

    test "returns descriptive error for invalid numeric field" do
      assert {:error, "Field 2 must contain only digits (0-9)"} =
        Validator.validate_field_value(2, "ABC123", "n ..19")
    end

    test "returns descriptive error for invalid ASCII field" do
      assert {:error, "Field 42 must contain only printable ASCII characters"} =
        Validator.validate_field_value(42, "Test\x01Value", "ans 15")
    end

    test "returns descriptive error for Track 2 not starting with digit" do
      assert {:error, "Field 35 (Track 2) must start with a digit"} =
        Validator.validate_field_value(35, "=1234567890123456", "z ..37")
    end

    test "returns descriptive error for invalid Track 2 characters" do
      assert {:error, "Field 35 (Track 2) contains invalid characters (only 0-9, =, D, F allowed)"} =
        Validator.validate_field_value(35, "1234X5678", "z ..37")
    end

    test "returns descriptive error for length exceeded" do
      assert {:error, "Value length 7 exceeds maximum 6"} =
        Validator.validate_field_value(3, "1234567", "n 6")
    end
  end

  describe "Track 2 edge cases" do
    alias Ex_Iso8583.Validator

    test "validates Track 2 with equals separator" do
      assert :ok == Validator.validate_field_value(35, "1234567890123456=1234567890123", "z ..37")
    end

    test "validates Track 2 with D separator" do
      assert :ok == Validator.validate_field_value(35, "1234567890123456D1234567890123", "z ..37")
    end

    test "validates Track 2 with F separator" do
      assert :ok == Validator.validate_field_value(35, "1234567890123456F1234567890123", "z ..37")
    end

    test "validates Track 2 with only PAN (no separator)" do
      assert :ok == Validator.validate_field_value(35, "1234567890123456", "z ..37")
    end

    test "validates Track 2 with single digit" do
      assert :ok == Validator.validate_field_value(35, "1", "z ..37")
    end

    test "rejects Track 2 starting with equals" do
      assert {:error, _} = Validator.validate_field_value(35, "=1234567890123456", "z ..37")
    end

    test "rejects Track 2 starting with D" do
      assert {:error, _} = Validator.validate_field_value(35, "D1234567890123456", "z ..37")
    end

    test "rejects Track 2 starting with F" do
      assert {:error, _} = Validator.validate_field_value(35, "F1234567890123456", "z ..37")
    end
  end
end
