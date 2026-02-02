defmodule MessageValidatorTest do
  use ExUnit.Case

  alias Ex_Iso8583.MessageValidator
  alias Ex_Iso8583

  @msg_type %{bitmap_type: :binary, field_header_type: :bcd}

  @field_format %{
    2 => "n ..19",
    3 => "n 6",
    4 => "n 12",
    11 => "n 6",
    22 => "n 3",
    35 => "z ..37",
    39 => "n 3",
    41 => "ans 8",
    42 => "ans 15",
    70 => "n 3",
    90 => "n 42"
  }

  describe "validate_required_fields_for_mti/2" do
    test "passes when all required fields are present" do
      data = %{3 => "123456", 4 => "000000001234", 11 => "000001", 41 => "12345678", 42 => "123456789012345"}
      assert :ok = MessageValidator.validate_required_fields_for_mti(data, "0100")
    end

    test "fails when required fields are missing" do
      data = %{3 => "123456", 4 => "000000001234"}
      assert {:error, message} = MessageValidator.validate_required_fields_for_mti(data, "0100")
      assert message =~ "Missing required"
    end

    test "passes for MTI not in required list" do
      data = %{3 => "123456"}
      assert :ok = MessageValidator.validate_required_fields_for_mti(data, "0500")
    end
  end

  describe "validate_all_fields_defined/2" do
    test "passes when all fields are defined" do
      data = %{3 => "123456", 4 => "000000001234"}
      assert :ok = MessageValidator.validate_all_fields_defined(data, @field_format)
    end

    test "fails when undefined fields are present" do
      data = %{3 => "123456", 99 => "undefined"}
      assert {:error, message} = MessageValidator.validate_all_fields_defined(data, @field_format)
      assert message =~ "Undefined"
    end
  end

  describe "validate_field_dependencies/1" do
    test "passes when dependencies are satisfied" do
      # Track 2 data (35) with POS Entry Mode (22)
      data = %{22 => "012", 35 => "1234567890123456=123456789012345"}
      assert :ok = MessageValidator.validate_field_dependencies(data)
    end

    test "fails when dependencies are not met" do
      # Track 2 data (35) without POS Entry Mode (22)
      data = %{35 => "1234567890123456=123456789012345"}
      assert {:error, message} = MessageValidator.validate_field_dependencies(data)
      assert message =~ "Requires field 22"
    end

    test "passes when dependent field is not present" do
      # No Track 2 data, so no dependency check needed
      data = %{3 => "123456"}
      assert :ok = MessageValidator.validate_field_dependencies(data)
    end
  end

  describe "validate_financial_message/1" do
    test "passes when amount is valid" do
      data = %{4 => "000000001234"}
      assert :ok = MessageValidator.validate_financial_message(data)
    end

    test "fails when amount is missing" do
      data = %{3 => "123456"}
      assert {:error, message} = MessageValidator.validate_financial_message(data)
      assert message =~ "requires Field 4"
    end

    test "fails when amount is not numeric" do
      data = %{4 => "abc123"}
      assert {:error, message} = MessageValidator.validate_financial_message(data)
      assert message =~ "must be numeric"
    end
  end

  describe "validate_authorization_message/1" do
    test "passes when PAN is present and valid" do
      data = %{2 => "1234567890123456"}
      assert :ok = MessageValidator.validate_authorization_message(data)
    end

    test "passes when Track 2 is present" do
      data = %{35 => "1234567890123456=123456789012345"}
      assert :ok = MessageValidator.validate_authorization_message(data)
    end

    test "fails when neither PAN nor Track 2 is present" do
      data = %{3 => "123456"}
      assert {:error, message} = MessageValidator.validate_authorization_message(data)
      assert message =~ "requires Field 2"
    end

    test "fails when PAN is not numeric" do
      data = %{2 => "abcd123456789012"}
      assert {:error, message} = MessageValidator.validate_authorization_message(data)
      assert message =~ "must be numeric"
    end
  end

  describe "validation_report/4" do
    test "generates report for valid message" do
      data = %{
        3 => "123456",
        4 => "000000001234",
        11 => "000001",
        41 => "12345678",
        42 => "123456789012345"
      }

      report = MessageValidator.validation_report(data, "0100", @msg_type, @field_format)

      assert report.valid? == true
      assert report.mti == "0100"
      assert report.field_count == 5
      assert Enum.all?(report.checks, fn {_, result} -> result == :ok end)
    end

    test "generates report for invalid message" do
      data = %{3 => "123456", 99 => "undefined"}

      report = MessageValidator.validation_report(data, "0100", @msg_type, @field_format)

      assert report.valid? == false
      failed_count = Enum.count(report.checks, fn {_, r} -> r != :ok end)
      assert failed_count > 0
    end
  end

  describe "validate_message/4" do
    test "validates a complete valid message" do
      data = %{
        3 => "123456",
        4 => "000000001234",
        11 => "000001",
        41 => "12345678",
        42 => "123456789012345"
      }

      assert :ok = MessageValidator.validate_message(data, "0100", @msg_type, @field_format)
    end

    test "fails validation for message with undefined fields" do
      data = %{3 => "123456", 99 => "undefined"}

      assert {:error, _} = MessageValidator.validate_message(data, "0100", @msg_type, @field_format)
    end
  end
end
