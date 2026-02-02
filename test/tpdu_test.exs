defmodule TPDUTest do
  use ExUnit.Case

  alias Ex_Iso8583.TPDU

  describe "parse/2" do
    test "parses a valid TPDU binary" do
      tpdu_binary = <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10>>
      assert {:ok, tpdu} = TPDU.parse(tpdu_binary)
      assert tpdu.destination == <<1, 2, 3, 4, 5>>
      assert tpdu.source == <<6, 7, 8, 9, 10>>
    end

    test "parses with custom address size" do
      tpdu_binary = <<1, 2, 3, 4, 5, 6>>
      assert {:ok, tpdu} = TPDU.parse(tpdu_binary, 3)
      assert tpdu.destination == <<1, 2, 3>>
      assert tpdu.source == <<4, 5, 6>>
    end

    test "returns error for too short TPDU" do
      assert {:error, _} = TPDU.parse(<<1, 2>>)
    end

    test "returns error for non-binary input" do
      assert {:error, _} = TPDU.parse(nil)
      assert {:error, _} = TPDU.parse(123)
    end
  end

  describe "format/2" do
    test "formats a TPDU map to binary" do
      tpdu = %{destination: <<1, 2, 3, 4, 5>>, source: <<6, 7, 8, 9, 10>>}
      binary = TPDU.format(tpdu)
      assert binary == <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10>>
    end

    test "pads addresses to correct size" do
      tpdu = %{destination: <<1, 2>>, source: <<3, 4>>}
      binary = TPDU.format(tpdu)
      assert byte_size(binary) == 10
      # Should be left-padded with zeros
      assert binary == <<0, 0, 0, 1, 2, 0, 0, 0, 3, 4>>
    end

    test "truncates addresses to correct size" do
      tpdu = %{destination: <<1, 2, 3, 4, 5, 6, 7>>, source: <<8, 9, 10, 11, 12, 13, 14>>}
      binary = TPDU.format(tpdu)
      assert byte_size(binary) == 10
      # Should take last 5 bytes
      assert binary == <<3, 4, 5, 6, 7, 10, 11, 12, 13, 14>>
    end
  end

  describe "valid?/2" do
    test "returns true for valid TPDU" do
      assert TPDU.valid?(<<1, 2, 3, 4, 5, 6, 7, 8, 9, 10>>)
    end

    test "returns false for invalid TPDU" do
      refute TPDU.valid?(<<1, 2>>)
      refute TPDU.valid?(<<1, 2, 3, 4, 5>>)
    end

    test "validates with custom address size" do
      assert TPDU.valid?(<<1, 2, 3, 4, 5, 6>>, 3)
      refute TPDU.valid?(<<1, 2, 3, 4>>, 3)
    end
  end

  describe "extract/2" do
    test "extracts TPDU from a message" do
      message = <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 100, 101, 102>>
      assert {:ok, tpdu, rest} = TPDU.extract(message)
      assert tpdu.destination == <<1, 2, 3, 4, 5>>
      assert tpdu.source == <<6, 7, 8, 9, 10>>
      assert rest == <<100, 101, 102>>
    end

    test "returns error for too short message" do
      assert {:error, _} = TPDU.extract(<<1, 2>>)
    end
  end

  describe "prepend/3" do
    test "prepends TPDU to a message" do
      message = <<100, 101, 102>>
      tpdu = %{destination: <<1, 2, 3, 4, 5>>, source: <<6, 7, 8, 9, 10>>}
      result = TPDU.prepend(message, tpdu)
      expected = <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 100, 101, 102>>
      assert result == expected
    end
  end

  describe "format_address/1" do
    test "formats address as hex string" do
      assert TPDU.format_address(<<1, 2, 3, 4, 5>>) == "0102030405"
    end

    test "formats single byte address" do
      assert TPDU.format_address(<<255>>) == "ff"
    end
  end

  describe "parse_address/1" do
    test "parses hex string to binary" do
      assert {:ok, <<1, 2, 3, 4, 5>>} = TPDU.parse_address("0102030405")
    end

    test "parses uppercase hex" do
      assert {:ok, <<255, 0>>} = TPDU.parse_address("FF00")
    end

    test "parses mixed case hex" do
      assert {:ok, <<255, 0>>} = TPDU.parse_address("Ff00")
    end

    test "returns error for invalid hex" do
      assert {:error, _} = TPDU.parse_address("xyz")
    end
  end

  describe "round-trip" do
    test "parse and format are inverses" do
      original = <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10>>
      assert {:ok, tpdu} = TPDU.parse(original)
      assert TPDU.format(tpdu) == original
    end
  end
end
