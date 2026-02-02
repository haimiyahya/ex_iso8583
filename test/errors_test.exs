defmodule ErrorsTest do
  use ExUnit.Case
  doctest Ex_Iso8583

  alias Ex_Iso8583
  alias Ex_Iso8583.Errors
  alias Ex_Iso8583.Validator

  @msg_type %{bitmap_type: :binary, field_header_type: :bcd}

  @field_format %{
    2 => "n ..19",
    3 => "n 6",
    4 => "n 12",
    35 => "z ..37"
  }

  describe "UndefinedFieldError" do
    test "exception message includes all undefined fields" do
      error = Errors.UndefinedFieldError.exception(
        fields: [5, 7, 99],
        defined_fields: [2, 3, 4]
      )

      assert error.message =~ "Undefined field(s)"
      assert error.message =~ "[5, 7, 99]"
      assert error.fields == [5, 7, 99]
    end

    test "exception message with single undefined field" do
      error = Errors.UndefinedFieldError.exception(
        fields: [7],
        defined_fields: [2, 3, 4]
      )

      assert error.message =~ "[7]"
      assert error.message =~ "7 => \"format_definition\""
    end

    test "can be raised and rescued with pattern matching" do
      assert_raise Errors.UndefinedFieldError, ~r/Undefined field/, fn ->
        raise Errors.UndefinedFieldError, fields: [5], defined_fields: []
      end
    end
  end

  describe "InvalidFormatError" do
    test "exception message includes field and format" do
      error = Errors.InvalidFormatError.exception(field: 10, format: "invalid")

      assert error.message =~ "Invalid format definition for field 10"
      assert error.message =~ "invalid"
      assert error.field == 10
      assert error.format == "invalid"
    end

    test "message includes examples of valid formats" do
      error = Errors.InvalidFormatError.exception(field: 5, format: "xyz")

      assert error.message =~ "n 6"
      assert error.message =~ "n ..19"
      assert error.message =~ "an ..15"
    end
  end

  describe "InvalidFieldValueError" do
    test "bcd_error creates error for non-numeric BCD values" do
      error = Errors.InvalidFieldValueError.bcd_error(3, "12a456")

      assert error.field == 3
      assert error.value == "12a456"
      assert error.reason =~ "numeric digits"
      assert error.reason =~ "a"
    end

    test "max_length_error includes actual and expected lengths" do
      error = Errors.InvalidFieldValueError.max_length_error(4, "1234567890123", 10)

      assert error.field == 4
      assert error.reason =~ "13"
      assert error.reason =~ "10"
    end

    test "track2_error for invalid Track 2 data" do
      error = Errors.InvalidFieldValueError.track2_error(35, "ABC123")

      assert error.field == 35
      assert error.reason =~ "Track 2"
    end

    test "generic exception with custom reason" do
      error = Errors.InvalidFieldValueError.exception(
        field: 5,
        value: "test",
        reason: "Custom error reason"
      )

      assert error.field == 5
      assert error.value == "test"
      assert error.reason == "Custom error reason"
    end
  end

  describe "BitmapError" do
    test "message_too_short includes expected and actual size" do
      error = Errors.BitmapError.message_too_short(4)

      assert error.reason =~ "too short"
      assert error.reason =~ "4 bytes"
    end

    test "invalid_binary error" do
      error = Errors.BitmapError.invalid_binary()

      assert error.reason =~ "Invalid binary"
    end
  end

  describe "MessageLengthError" do
    test "includes expected and actual lengths" do
      error = Errors.MessageLengthError.exception(
        expected: 100,
        actual: 50,
        field: nil
      )

      assert error.expected == 100
      assert error.actual == 50
      assert error.message =~ "100"
      assert error.message =~ "50"
    end

    test "includes field number when provided" do
      error = Errors.MessageLengthError.exception(
        expected: 10,
        actual: 5,
        field: 3
      )

      assert error.field == 3
      assert error.message =~ "Field 3"
    end
  end
end

defmodule ValidatorTest do
  use ExUnit.Case

  alias Ex_Iso8583.Validator
  alias Ex_Iso8583.Errors

  describe "validate_field_value - BCD fields" do
    test "accepts valid numeric values" do
      assert Validator.validate_field_value(3, "123456", :bcd, 6) == :ok
      assert Validator.validate_field_value(4, "000000001234", :bcd, 12) == :ok
    end

    test "rejects non-numeric BCD values" do
      assert_raise Errors.InvalidFieldValueError, ~r/numeric digits/, fn ->
        Validator.validate_field_value(3, "12a456", :bcd, 6)
      end
    end

    test "rejects values exceeding max length" do
      assert_raise Errors.InvalidFieldValueError, ~r/exceeds maximum/, fn ->
        Validator.validate_field_value(3, "1234567", :bcd, 6)
      end
    end

    test "accepts values at max length boundary" do
      assert Validator.validate_field_value(3, "123456", :bcd, 6) == :ok
    end
  end

  describe "validate_field_value - ASCII fields" do
    test "accepts valid ASCII values" do
      assert Validator.validate_field_value(42, "ABC123", :ascii, 10) == :ok
    end

    test "rejects non-printable characters" do
      assert {:error, _} = Validator.validate_field_value(42, <<0>>, :ascii, 10)
    end
  end

  describe "validate_field_value - Track 2 (z) fields" do
    test "accepts valid Track 2 format starting with digits" do
      assert Validator.validate_field_value(35, "1234567890123456=D12340000000000", :z, 37) == :ok
    end

    test "rejects Track 2 not starting with digit" do
      assert_raise Errors.InvalidFieldValueError, ~r/start with a digit/, fn ->
        Validator.validate_field_value(35, "ABCD1234", :z, 37)
      end
    end

    test "rejects Track 2 with invalid characters" do
      assert_raise Errors.InvalidFieldValueError, ~r/Track 2/, fn ->
        Validator.validate_field_value(35, "1234@5678", :z, 37)
      end
    end

    test "accepts Track 2 with valid special characters" do
      # Track 2 allows '=', 'D', 'F' as separators
      assert Validator.validate_field_value(35, "1234567890123456=1234567890123456", :z, 37) == :ok
      assert Validator.validate_field_value(35, "1234567890123456D1234567890123456", :z, 37) == :ok
    end
  end

  describe "validate_field_value - Binary fields" do
    test "accepts any binary data" do
      assert Validator.validate_field_value(55, <<1, 2, 3, 4>>, :binary, 4) == :ok
    end

    test "enforces max length on binary fields" do
      assert_raise Errors.InvalidFieldValueError, ~r/exceeds maximum/, fn ->
        Validator.validate_field_value(55, <<1, 2, 3, 4, 5>>, :binary, 4)
      end
    end
  end

  describe "validate_field_value - Hex fields" do
    test "accepts valid hex strings" do
      assert Validator.validate_field_value(64, "1A2B3C4D", :hex, 8) == :ok
      assert Validator.validate_field_value(64, "abcd", :hex, 4) == :ok
    end

    test "rejects invalid hex characters" do
      assert_raise Errors.InvalidFieldValueError, ~r/hexadecimal/, fn ->
        Validator.validate_field_value(64, "1G2H", :hex, 4)
      end
    end
  end

  describe "validate_message" do
    test "accepts valid message length" do
      assert Validator.validate_message(<<0, 0, 0, 0, 0, 0, 0, 0>>) == :ok
      assert Validator.validate_message(<<1::1, 0::63>>) == :ok
    end

    test "rejects messages too short for bitmap" do
      assert {:error, message} = Validator.validate_message(<<1, 2>>)
      assert message =~ "too short"
    end

    test "rejects non-binary input" do
      assert Validator.validate_message(nil) == {:error, "Message must be a binary"}
      assert Validator.validate_message(123) == {:error, "Message must be a binary"}
    end
  end

  describe "validate_format_definition" do
    test "accepts valid format strings" do
      assert Validator.validate_format_definition(3, "n 6") == :ok
      assert Validator.validate_format_definition(2, "n ..19") == :ok
      # Test alphanumeric in both cases
      assert Validator.validate_format_definition(42, "an ..15") == :ok
      assert Validator.validate_format_definition(43, "AN ..15") == :ok
      assert Validator.validate_format_definition(35, "z ..37") == :ok
      assert Validator.validate_format_definition(64, "b 64") == :ok
      assert Validator.validate_format_definition(48, "N 3") == :ok
    end

    test "accepts format with trailing b for binary" do
      assert Validator.validate_format_definition(52, "n 8b") == :ok
    end

    test "rejects invalid format strings" do
      assert_raise Errors.InvalidFormatError, fn ->
        Validator.validate_format_definition(3, "invalid")
      end
    end

    test "rejects non-string format definitions" do
      assert_raise Errors.InvalidFormatError, fn ->
        Validator.validate_format_definition(3, 123)
      end
    end
  end

  describe "validator_for" do
    test "returns a validator function for BCD type" do
      validator = Validator.validator_for(:bcd, 6)
      assert validator.(3, "123456") == :ok

      assert_raise Errors.InvalidFieldValueError, fn ->
        validator.(3, "12a456")
      end
    end

    test "returns a validator function for ASCII type" do
      validator = Validator.validator_for(:ascii, 10)
      assert validator.(42, "ABC123") == :ok
    end

    test "returns validator without max length when not specified" do
      validator = Validator.validator_for(:bcd)
      # Should not raise length error
      assert validator.(3, String.duplicate("1", 100)) == :ok
    end
  end
end
