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

  ## Example Usage with Transaction Types

      defmodule MyApp.Transaction do
        use TransactionType

        # Define field-to-iso mapping
        def to_iso(%__MODULE__{} = txn) do
          ISOMsg.new()
          |> ISOMsg.set_mti(txn.mti)
          |> ISOMsg.set_field(2, txn.pan)
          |> ISOMsg.set_field(4, txn.amount)
          |> ISOMsg.set_field(11, txn.stan)
        end

        def from_iso(%ISOMsg{} = iso_msg) do
          %__MODULE__{
            mti: ISOMsg.get_mti(iso_msg),
            pan: ISOMsg.get_field(iso_msg, 2),
            amount: ISOMsg.get_field(iso_msg, 4),
            stan: ISOMsg.get_field(iso_msg, 11)
          }
        end
      end

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
