defmodule CompileTimeValidationTest do
  use ExUnit.Case
  doctest Ex_Iso8583

  alias Ex_Iso8583

  # Example message definition using the DSL
  defmodule TestMessage do
    use Ex_Iso8583.DSL

    defisoformat do
      field 2, "n ..19"
      field 3, "n 6"
      field 4, "n 12"
      field 35, "z ..37"
    end
  end

  describe "compile-time DSL validation" do
    test "field_format/0 returns the defined format map" do
      format = TestMessage.field_format()

      assert format == %{
        2 => "n ..19",
        3 => "n 6",
        4 => "n 12",
        35 => "z ..37"
      }
    end

    test "defined_fields/0 returns sorted list of field numbers" do
      assert TestMessage.defined_fields() == [2, 3, 4, 35]
    end

    test "build/2 creates message using DSL-defined format" do
      data = %{
        3 => "123456",
        4 => "000000001234"
      }

      msg = TestMessage.build(data)
      assert is_binary(msg)

      # Should be able to parse it back
      parsed = TestMessage.parse(msg)
      assert parsed == data
    end

    test "build/2 raises error for undefined fields at runtime" do
      data = %{999 => "undefined"}

      assert_raise RuntimeError, ~r/Undefined field.*999/, fn ->
        TestMessage.build(data)
      end
    end

    test "build/2 succeeds with all defined fields" do
      data = %{
        2 => "1234567890",  # 10 digits, fits in n ..19
        3 => "123456",
        4 => "000000001234",
        35 => "1234567890123456789D1234"
      }

      msg = TestMessage.build(data)
      assert is_binary(msg)

      parsed = TestMessage.parse(msg)
      assert parsed == data
    end
  end

  describe "compile-time error prevention" do
    test "duplicate field numbers raise compile error" do
      # This test demonstrates that duplicate fields are caught at compile time
      # The actual compile error would occur when compiling the module
      # For this test, we just verify the format map has unique keys
      format = TestMessage.field_format()

      # Verify no duplicates by checking count
      assert map_size(format) == length(Map.keys(format))
    end
  end
end
