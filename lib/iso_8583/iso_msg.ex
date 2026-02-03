defmodule ISOMsg do
  @moduledoc """
  Struct representing a complete ISO 8583 message.

  The ISOMsg struct encapsulates all components of an ISO 8583 message including
  the TPDU (Transaction Portal Data Unit), Message Type Indicator (MTI), and
  the field data. It provides configuration options for encoding/decoding behavior.

  ## Structure

  The struct has the following fields:

  | Field    | Type               | Default                              | Description |
  |----------|--------------------|--------------------------------------|-------------|
  | `:config` | `map/0`           | `%{ascii_format: false, ascii_bitmap: true, tpdu_length: 5}` | Encoding configuration |
  | `:tpdu`   | `String.t()`      | `""`                                 | TPDU header |
  | `:mti`    | `String.t()`      | `""`                                 | Message Type Indicator |
  | `:data`   | `map/0`           | `%{}`                                | Field data (field_number => value) |

  ## Config Options

  - `:ascii_format` - When `true`, encodes the bitmap in ASCII hexadecimal format
  - `:ascii_bitmap` - When `true`, uses ASCII encoding for the bitmap (when `false`, uses binary bitmap)
  - `:tpdu_length`  - Length of the TPDU header in bytes (typically 5 or 10)

  ## Examples

  ### Creating a new ISOMsg

      # Basic authorization request message
      msg = %ISOMsg{
        tpdu: "6000000000",
        mti: "0100",
        data: %{
          2 => "1234567890123456789",
          3 => "000000",
          4 => "000000001234",
          11 => "000001",
          41 => "12345678",
          42 => "123456789012345"
        }
      }

  ### With custom configuration

      msg = %ISOMsg{
        config: %{
          ascii_format: true,
          ascii_bitmap: true,
          tpdu_length: 10
        },
        tpdu: "6000000000",
        mti: "0200",
        data: %{2 => "1234567890123456789"}
      }

  """

  defstruct config: %{ascii_format: false, ascii_bitmap: true, tpdu_length: 5},
            tpdu: "",
            mti: "",
            data: %{}

  @type t :: %__MODULE__{
    config: config(),
    tpdu: String.t(),
    mti: String.t(),
    data: %{pos_integer() => String.t()}
  }

  @type config :: %{
    ascii_format: boolean(),
    ascii_bitmap: boolean(),
    tpdu_length: pos_integer()
  }

  @doc """
  Creates a new ISOMsg struct with default configuration.

  ## Examples

      ISOMsg.new()
      # => %ISOMsg{config: %{...}, tpdu: "", mti: "", data: %{}}

  """
  @spec new() :: t()
  def new do
    %__MODULE__{}
  end

  @doc """
  Creates a new ISOMsg with the given MTI and field data.

  ## Parameters
    - `mti`: Message Type Indicator (4-digit string)
    - `data`: Map of field numbers to values

  ## Returns
    - ISOMsg struct with the given MTI and data

  ## Examples

      ISOMsg.new("0100", %{2 => "1234567890123456789", 4 => "000000001234"})
      # => %ISOMsg{mti: "0100", data: %{2 => "1234567890123456789", 4 => "000000001234"}, ...}

  """
  @spec new(String.t(), %{pos_integer() => String.t()}) :: t()
  def new(mti, data) when is_binary(mti) and is_map(data) do
    %__MODULE__{mti: mti, data: data}
  end
end
