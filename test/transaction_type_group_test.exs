defmodule TransactionTypeGroupTest do
  use ExUnit.Case

  alias Ex_Iso8583

  # Define a transaction group for testing
  defmodule SaleTransaction do
    @moduledoc "Sale transaction type for testing"
    use Ex_Iso8583.TransactionTypeGroup

    defrequest mti: "0100", processing_code: "00*" do
      defstruct [
        :pan,
        :processing_code,
        :amount,
        :stan,
        :terminal_id,
        :merchant_id
      ]

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

    defresponse mti: "0110", processing_code: "00*" do
      defstruct [
        :pan,
        :processing_code,
        :amount,
        :stan,
        :response_code
      ]

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

  describe "defrequest macro" do
    test "creates a Request module" do
      assert Code.ensure_loaded?(SaleTransaction.Request)
      assert function_exported?(SaleTransaction.Request, :mti, 0)
      assert SaleTransaction.Request.mti() == "0100"
    end

    test "Request has correct field mapping" do
      mapping = SaleTransaction.Request.field_mapping()

      assert mapping.pan == 2
      assert mapping.processing_code == 3
      assert mapping.amount == 4
      assert mapping.stan == 11
      assert mapping.terminal_id == 41
      assert mapping.merchant_id == 42
    end

    test "Request has correct processing code pattern" do
      assert SaleTransaction.Request.processing_code_pattern() == "00*"
    end

    test "Request can parse and validate a message" do
      data = %{
        2 => "1234567890123456789",
        3 => "000000",
        4 => "000000001234",
        11 => "000001",
        41 => "12345678",
        42 => "123456789012345"
      }

      iso_msg = Ex_Iso8583.form_iso_msg(data, @msg_type, @field_format)

      assert {:ok, req} = SaleTransaction.Request.parse_and_validate(iso_msg, @msg_type, @field_format)
      assert %SaleTransaction.Request{} = req
      assert req.pan == "0123456789012345678"
      assert req.processing_code == "000000"
      assert req.amount == "000000001234"
    end
  end

  describe "defresponse macro" do
    test "creates a Response module" do
      assert Code.ensure_loaded?(SaleTransaction.Response)
      assert function_exported?(SaleTransaction.Response, :mti, 0)
      assert SaleTransaction.Response.mti() == "0110"
    end

    test "Response has correct field mapping" do
      mapping = SaleTransaction.Response.field_mapping()

      assert mapping.pan == 2
      assert mapping.processing_code == 3
      assert mapping.amount == 4
      assert mapping.stan == 11
      assert mapping.response_code == 39
    end

    test "Response has correct processing code pattern" do
      assert SaleTransaction.Response.processing_code_pattern() == "00*"
    end

    test "Response can parse and validate a message" do
      data = %{
        2 => "1234567890123456789",
        3 => "000000",
        4 => "000000001234",
        11 => "000001",
        39 => "000"
      }

      iso_msg = Ex_Iso8583.form_iso_msg(data, @msg_type, @field_format)

      assert {:ok, resp} = SaleTransaction.Response.parse_and_validate(iso_msg, @msg_type, @field_format)
      assert %SaleTransaction.Response{} = resp
      assert resp.pan == "0123456789012345678"
      assert resp.processing_code == "000000"
      assert resp.amount == "000000001234"
      assert resp.response_code == "000"
    end
  end

  describe "request_module/0" do
    test "returns the Request module" do
      assert SaleTransaction.request_module() == SaleTransaction.Request
    end
  end

  describe "response_module/0" do
    test "returns the Response module" do
      assert SaleTransaction.response_module() == SaleTransaction.Response
    end
  end

  describe "find_pair/1" do
    test "returns Request module for :request" do
      assert {:ok, SaleTransaction.Request} = SaleTransaction.find_pair(:request)
    end

    test "returns Response module for :response" do
      assert {:ok, SaleTransaction.Response} = SaleTransaction.find_pair(:response)
    end
  end

  describe "find_pair/2" do
    test "finds Request by MTI and processing code" do
      assert {:ok, SaleTransaction.Request} = SaleTransaction.find_pair("0100", "000000")
      assert {:ok, SaleTransaction.Request} = SaleTransaction.find_pair("0100", "001234")
    end

    test "finds Response by MTI and processing code" do
      assert {:ok, SaleTransaction.Response} = SaleTransaction.find_pair("0110", "000000")
      assert {:ok, SaleTransaction.Response} = SaleTransaction.find_pair("0110", "009999")
    end

    test "returns error for non-matching MTI" do
      assert {:error, :no_match} = SaleTransaction.find_pair("0200", "000000")
    end

    test "returns error for non-matching processing code" do
      assert {:error, :no_match} = SaleTransaction.find_pair("0100", "010000")
    end
  end

  describe "transaction_modules/0" do
    test "returns both Request and Response modules" do
      modules = SaleTransaction.transaction_modules()

      assert SaleTransaction.Request in modules
      assert SaleTransaction.Response in modules
      assert length(modules) == 2
    end
  end

  describe "parse/2" do
    setup do
      request_data = %{
        2 => "1234567890123456789",
        3 => "000000",
        4 => "000000001234",
        11 => "000001",
        41 => "12345678",
        42 => "123456789012345"
      }

      response_data = %{
        2 => "1234567890123456789",
        3 => "000000",
        4 => "000000001234",
        11 => "000001",
        39 => "000"
      }

      request_msg = Ex_Iso8583.form_iso_msg(request_data, @msg_type, @field_format)
      response_msg = Ex_Iso8583.form_iso_msg(response_data, @msg_type, @field_format)

      %{request_msg: request_msg, response_msg: response_msg}
    end

    test "parses a request message and returns {:ok, {:request, struct}}", %{request_msg: request_msg} do
      assert {:ok, {:request, req}} = SaleTransaction.parse(request_msg, @msg_type, @field_format)
      assert %SaleTransaction.Request{} = req
      assert req.pan == "0123456789012345678"
      assert req.amount == "000000001234"
    end

    test "parses a response message and returns {:ok, {:response, struct}}", %{response_msg: response_msg} do
      assert {:ok, {:response, resp}} = SaleTransaction.parse(response_msg, @msg_type, @field_format)
      assert %SaleTransaction.Response{} = resp
      assert resp.pan == "0123456789012345678"
      assert resp.response_code == "000"
    end

    test "returns error for non-matching MTI" do
      # Create a message with different MTI
      data = %{3 => "000000", 4 => "000000001234"}
      msg = Ex_Iso8583.form_iso_msg(data, @msg_type, @field_format)

      # Since parse/2 tries both modules, and neither will match due to
      # missing mandatory fields, we expect an error about missing fields
      assert {:error, _reason} = SaleTransaction.parse(msg, @msg_type, @field_format)
    end

    test "returns error for invalid message" do
      assert {:error, _} = SaleTransaction.parse(<<>>, @msg_type, @field_format)
    end
  end

  describe "request and response relationship" do
    test "Request and Response have matching processing code patterns" do
      assert SaleTransaction.Request.processing_code_pattern() ==
        SaleTransaction.Response.processing_code_pattern()
    end

    test "Request MTI is request type (odd third digit = 0)" do
      mti = SaleTransaction.Request.mti()
      <<_::2-bytes, third_digit::binary-size(1), _::binary>> = mti
      assert third_digit == "0"
    end

    test "Response MTI is response type (odd third digit = 1)" do
      mti = SaleTransaction.Response.mti()
      <<_::2-bytes, third_digit::binary-size(1), _::binary>> = mti
      assert third_digit == "1"
    end
  end

  describe "transaction group with only request" do
    defmodule RequestOnlyTransaction do
      use Ex_Iso8583.TransactionTypeGroup

      defrequest mti: "0200", processing_code: "01*" do
        defstruct [:pan, :amount]

        fields %{pan: 2, amount: 4}
        mandatory [:pan, :amount]
      end
    end

    test "find_pair(:response) returns error when response not defined" do
      assert {:error, :not_defined} = RequestOnlyTransaction.find_pair(:response)
    end

    test "transaction_modules returns only Request" do
      modules = RequestOnlyTransaction.transaction_modules()
      assert length(modules) == 1
      assert RequestOnlyTransaction.Request in modules
    end
  end

  describe "compile-time validation" do
    test "request module has compile-time validation" do
      code = """
      defmodule BadRequestTransaction do
        use Ex_Iso8583.TransactionTypeGroup

        defrequest mti: "0100", processing_code: "00*" do
          defstruct [:pan, :amount]

          fields %{pan: 2, amount: 4}
          mandatory [:pan, :stan]  # stan not in fields!
        end
      end
      """

      assert_raise CompileError, ~r/Fields in `mandatory` but not defined in `fields` mapping/, fn ->
        Code.compile_string(code)
      end
    end

    test "response module has compile-time validation" do
      code = """
      defmodule BadResponseTransaction do
        use Ex_Iso8583.TransactionTypeGroup

        defresponse mti: "0110", processing_code: "00*" do
          defstruct [:pan, :amount]

          fields %{pan: 2, amount: 4}
          mandatory [:pan]
          optional [:pan, :amount]  # pan in both!
        end
      end
      """

      assert_raise CompileError, ~r/Fields defined in both `mandatory` and `optional`/, fn ->
        Code.compile_string(code)
      end
    end
  end
end
