defmodule Iso8583.Formatter do
  @moduledoc """
  Behaviour for ISO 8583 message formatters.

  A formatter handles the conversion between ISOMsg structs and wire format binaries.
  Different backends may use different wire formats (binary, ASCII hex, etc.).

  ## Implementing a Formatter

  To create a custom formatter, implement this behaviour and define `encode/1` and `decode/1`.

      defmodule MyApp.MyFormatter do
        @behaviour Iso8583.Formatter

        @impl true
        def encode(%ISOMsg{} = iso_msg) do
          # Convert ISOMsg to wire format binary
          mti = ISOMsg.get_mti(iso_msg)
          # ... encoding logic
          mti <> bitmap <> fields_data
        end

        @impl true
        def decode(raw_binary) do
          # Convert wire format binary to ISOMsg
          # ... parsing logic
          {:ok, %ISOMsg{mti: mti, data: data}}
        end
      end

  ## Built-in Formatters

  - `Iso8583.Formatters.Binary` - Standard binary format (binary MTI, binary bitmap, BCD/ASCII fields)
  - `Iso8583.Formatters.AsciiHex` - ASCII hex format (ASCII MTI, ASCII hex bitmap, ASCII fields)

  ## Example: Building a Gateway with Different Formats

  This example shows how to use formatters to build a gateway that receives
  messages in binary format from terminals and forwards them in ASCII hex format
  to a legacy backend:

      # Define your transaction struct
      defmodule MyApp.SaleRequest do
        defstruct [:pan, :amount, :stan, :terminal_id]

        def __iso_formatter__, do: Iso8583.Formatters.Binary
        def __iso_field_map__, do: %{
          2 => :pan,
          4 => :amount,
          11 => :stan,
          41 => :terminal_id
        }
        def __iso_mti__, do: "0200"

        def new(attrs) do
          struct!(__MODULE__, %{
            pan: attrs.pan,
            amount: pad_amount(attrs.amount),
            stan: pad_stan(attrs.stan),
            terminal_id: attrs.terminal_id
          })
        end

        defp pad_amount(amount) when is_integer(amount) do
          amount |> to_string() |> String.pad_leading(12, "0")
        end
        defp pad_stan(stan) when is_integer(stan) do
          stan |> to_string() |> String.pad_leading(6, "0")
        end
      end

      # Backend client with ASCII Hex formatter (different format!)
      {Iso8583.Client, name: :legacy_backend,
       transport: Iso8583.Transport.TCP.Client,
       transport_opts: [
         host: "legacy.bank.example.com",
         port: 8100,
         framing: {:length_prefix, 2}
       ],
       formatter: Iso8583.Formatters.AsciiHex,
       request_timeout: 30000}

      # Gateway handles format transformation
      defmodule MyApp.Gateway do
        def handle_terminal_request(raw_binary, context) do
          # Decode using Binary formatter
          {:ok, iso_msg} = Iso8583.Formatters.Binary.decode(raw_binary)

          # Convert to struct
          request = ISOMsg.to_struct(iso_msg, MyApp.SaleRequest, %{
            2 => :pan, 4 => :amount, 11 => :stan, 41 => :terminal_id
          })

          # Send to backend - automatically encodes to ASCII Hex!
          Iso8583.Client.send_transaction(:legacy_backend, request)
        end
      end

  ## Example: Manual Encoding/Decoding

      # Create ISOMsg manually
      iso_msg = ISOMsg.new("0200")
      |> ISOMsg.set_field(2, "1234567890123456789")
      |> ISOMsg.set_field(4, "000000001234")
      |> ISOMsg.set_field(11, "000001")

      # Encode to binary
      binary = Iso8583.Formatters.Binary.encode(iso_msg)

      # Decode back
      {:ok, iso_msg2} = Iso8583.Formatters.Binary.decode(binary)

  ## Example: Working with Transaction Structs

      # Define request and response structs
      defmodule MyApp.SaleRequest do
        defstruct [:pan, :amount, :stan, :terminal_id]
        def __iso_formatter__, do: Iso8583.Formatters.Binary
        def __iso_field_map__, do: %{2 => :pan, 4 => :amount, 11 => :stan, 41 => :terminal_id}
        def __iso_mti__, do: "0200"
      end

      defmodule MyApp.SaleResponse do
        defstruct [:response_code, :auth_code, :amount, :stan]
        def __iso_formatter__, do: Iso8583.Formatters.Binary
        def __iso_field_map__, do: %{39 => :response_code, 38 => :auth_code, 4 => :amount, 11 => :stan}

        def approved?(%__MODULE__{response_code: "00"}), do: true
        def approved?(%__MODULE__{}), do: false
      end

      # Create request
      request = %MyApp.SaleRequest{
        pan: "1234567890123456789",
        amount: "000000001000",
        stan: "000001",
        terminal_id: "TERM001"
      }

      # Convert to ISOMsg
      field_map = MyApp.SaleRequest.__iso_field_map__()
      iso_msg = ISOMsg.from_struct(request, "0200", field_map)

      # Encode and send
      binary = Iso8583.Formatters.Binary.encode(iso_msg)

      # Decode response
      {:ok, response_iso} = Iso8583.Formatters.Binary.decode(response_binary)
      response = ISOMsg.to_struct(response_iso, MyApp.SaleResponse,
                                  MyApp.SaleResponse.__iso_field_map__())

      # Check approval
      MyApp.SaleResponse.approved?(response)  # => true or false

  """

  @doc """
  Encodes an ISOMsg struct to wire format binary.

  ## Parameters

  - `iso_msg` - ISOMsg struct to encode

  ## Returns

  - Wire format binary
  """
  @callback encode(ISOMsg.t()) :: binary()

  @doc """
  Decodes a wire format binary to an ISOMsg struct.

  ## Parameters

  - `raw` - Wire format binary to decode

  ## Returns

  - `{:ok, ISOMsg.t()}` on success
  - `{:error, reason}` on failure
  """
  @callback decode(binary()) :: {:ok, ISOMsg.t()} | {:error, term()}

  @optional_callbacks [encode: 1, decode: 1]
end
