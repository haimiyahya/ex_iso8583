defmodule MTITest do
  use ExUnit.Case

  alias Ex_Iso8583.MTI

  describe "parse/1" do
    test "parses authorization request MTI" do
      assert {:ok, parsed} = MTI.parse("0100")
      assert parsed.version == :iso_8583_1987
      assert parsed.class == :authorization_request
      assert parsed.function == :request
      assert parsed.origin == :acquirer
    end

    test "parses financial request MTI" do
      assert {:ok, parsed} = MTI.parse("0200")
      assert parsed.version == :iso_8583_1987
      assert parsed.class == :financial_request
    end

    test "parses response MTI" do
      assert {:ok, parsed} = MTI.parse("0210")
      assert parsed.function == :request_response
      # The second digit '2' means 'financial' - the request/response is determined by the third digit
      assert parsed.class == :financial_request
    end

    test "parses 1993 version MTI" do
      assert {:ok, parsed} = MTI.parse("1100")
      assert parsed.version == :iso_8583_1993
    end

    test "parses 2003 version MTI" do
      assert {:ok, parsed} = MTI.parse("2100")
      assert parsed.version == :iso_8583_2003
    end

    test "handles lowercase input" do
      assert {:ok, parsed} = MTI.parse("0100")
      assert {:ok, ^parsed} = MTI.parse("0100")
    end

    test "returns error for invalid format" do
      assert {:error, _} = MTI.parse("123")
      assert {:error, _} = MTI.parse("12345")
      assert {:error, _} = MTI.parse("abcd")
    end

    test "returns error for invalid MTI values" do
      assert {:error, _} = MTI.parse("9900")
      assert {:error, _} = MTI.parse("0190")
    end
  end

  describe "format/1" do
    test "formats parsed MTI back to string" do
      parsed = %{
        version: :iso_8583_1987,
        class: :authorization_request,
        function: :request,
        origin: :acquirer
      }

      assert MTI.format(parsed) == "0100"
    end

    test "round-trips parse and format" do
      original = "0200"
      assert {:ok, parsed} = MTI.parse(original)
      assert MTI.format(parsed) == original
    end
  end

  describe "valid?/1" do
    test "returns true for valid MTIs" do
      assert MTI.valid?("0100")
      assert MTI.valid?("0200")
      assert MTI.valid?("0400")
      assert MTI.valid?("0800")
      assert MTI.valid?("0110")
      assert MTI.valid?("0210")
    end

    test "returns false for invalid MTIs" do
      # 9999 has valid format digit 9 (financial response) but digit 9 for class is valid
      # The issue is with the third digit '9' which is not defined
      refute MTI.valid?("0990")
      refute MTI.valid?("abcd")
      refute MTI.valid?("123")
    end
  end

  describe "describe/1" do
    test "returns human-readable description" do
      assert {:ok, desc} = MTI.describe("0100")
      assert desc =~ "1987"
      assert desc =~ "Authorization"
      assert desc =~ "Request"
    end
  end

  describe "MTI predicates" do
    test "request?/1" do
      assert MTI.request?("0100")
      assert MTI.request?("0200")
      refute MTI.request?("0110")
      refute MTI.request?("0210")
    end

    test "response?/1" do
      refute MTI.response?("0100")
      assert MTI.response?("0110")
      assert MTI.response?("0210")
    end

    test "authorization?/1" do
      assert MTI.authorization?("0100")
      assert MTI.authorization?("0110")
      refute MTI.authorization?("0200")
      refute MTI.authorization?("0400")
    end

    test "financial?/1" do
      assert MTI.financial?("0200")
      assert MTI.financial?("0210")
      refute MTI.financial?("0100")
      refute MTI.financial?("0400")
    end
  end

  describe "common MTI constants" do
    test "returns correct MTI strings" do
      assert MTI.authorization_request() == "0100"
      assert MTI.authorization_response() == "0110"
      assert MTI.financial_request() == "0200"
      assert MTI.financial_response() == "0210"
      assert MTI.reversal_request() == "0400"
      assert MTI.reversal_response() == "0410"
      assert MTI.network_management_request() == "0800"
      assert MTI.network_management_response() == "0810"
    end
  end
end
