defmodule UndefinedFieldTest do
  use ExUnit.Case
  doctest Ex_Iso8583

  alias Ex_Iso8583

  @msg_type %{bitmap_type: :binary, field_header_type: :bcd}

  @field_format %{
    2 => "n ..19",
    3 => "n 6",
    4 => "n 12",
    35 => "z ..37"
  }

  # A minimal format without fields 3, 4, 7 for testing undefined field scenarios
  @minimal_format %{
    2 => "n ..19"
  }

  describe "form_iso_msg/3 with undefined fields" do
    test "raises error when field in data is not defined in field_format" do
      data = %{3 => "123456", 5 => "000000000001"}  # field 5 is not defined

      assert_raise RuntimeError, ~r/Undefined field.*5/, fn ->
        Ex_Iso8583.form_iso_msg(data, @msg_type, @field_format)
      end
    end

    test "error message includes helpful information about missing field" do
      data = %{7 => "03231600"}  # field 7 is not defined

      assert_raise RuntimeError, ~r/Undefined field.*7.*field_format_definition/ms, fn ->
        Ex_Iso8583.form_iso_msg(data, @msg_type, @field_format)
      end
    end

    test "succeeds when all fields are defined" do
      data = %{
        3 => "123456",
        4 => "000000001234"
      }

      msg = Ex_Iso8583.form_iso_msg(data, @msg_type, @field_format)
      assert is_binary(msg)

      # Should be able to extract it back
      extracted = Ex_Iso8583.extract_iso_msg(msg, @msg_type, @field_format)
      assert extracted == data
    end
  end

  describe "extract_iso_msg/3 with undefined fields" do
    test "raises error when field in message is not defined in field_format" do
      # Create a message with field 3 only
      data = %{3 => "123456"}

      # First, create a valid message to use for testing
      valid_format = %{3 => "n 6"}
      msg = Ex_Iso8583.form_iso_msg(data, @msg_type, valid_format)

      # Now try to extract it with field 3 not defined (using minimal_format)
      assert_raise RuntimeError, ~r/Undefined field.*3/, fn ->
        Ex_Iso8583.extract_iso_msg(msg, @msg_type, @minimal_format)
      end
    end

    test "error message for extract includes helpful information" do
      data = %{4 => "000000001234"}

      # Create a message first
      valid_format = %{4 => "n 12"}
      msg = Ex_Iso8583.form_iso_msg(data, @msg_type, valid_format)

      # Try to extract with incomplete format (using minimal_format)
      assert_raise RuntimeError, ~r/Undefined field.*4/ms, fn ->
        Ex_Iso8583.extract_iso_msg(msg, @msg_type, @minimal_format)
      end
    end

    test "succeeds when all fields in message are defined" do
      data = %{
        3 => "123456",
        4 => "000000001234"
      }

      msg = Ex_Iso8583.form_iso_msg(data, @msg_type, @field_format)

      assert is_binary(msg)

      # Should be able to extract it back
      extracted = Ex_Iso8583.extract_iso_msg(msg, @msg_type, @field_format)
      assert extracted == data
    end
  end

  describe "multiple undefined fields" do
    test "lists all undefined fields in error message" do
      data = %{5 => "00001", 7 => "03231600", 99 => "00000000001"}

      assert_raise RuntimeError, ~r/5.*7.*99/ms, fn ->
        Ex_Iso8583.form_iso_msg(data, @msg_type, @field_format)
      end
    end
  end
end
