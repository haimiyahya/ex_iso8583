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

  ### Using the helper functions

      # Create and build using pipe operator
      iso_msg = ISOMsg.new("0200")
      |> ISOMsg.set_field(2, "1234567890123456789")
      |> ISOMsg.set_field(3, "000000")
      |> ISOMsg.set_field(4, "000000001234")
      |> ISOMsg.set_field(11, "000001")
      |> ISOMsg.set_field(41, "12345678")

      # Get fields
      pan = ISOMsg.get_field(iso_msg, 2)  # => "1234567890123456789"
      mti = ISOMsg.get_mti(iso_msg)       # => "0200"

      # Check for fields
      ISOMsg.has_field?(iso_msg, 2)  # => true
      ISOMsg.has_field?(iso_msg, 99) # => false

      # List all fields
      ISOMsg.fields(iso_msg)  # => [2, 3, 4, 11, 41]

  ### Converting between Structs and ISOMsg

      # Define your transaction struct
      defmodule MyApp.SaleRequest do
        defstruct [:pan, :amount, :stan, :terminal_id]

        def __iso_field_map__, do: %{
          2 => :pan,
          4 => :amount,
          11 => :stan,
          41 => :terminal_id
        }
        def __iso_mti__, do: "0200"
      end

      # Create request struct
      request = %MyApp.SaleRequest{
        pan: "1234567890123456789",
        amount: "000000001000",
        stan: "000001",
        terminal_id: "TERM001"
      }

      # Convert struct to ISOMsg
      field_map = MyApp.SaleRequest.__iso_field_map__()
      iso_msg = ISOMsg.from_struct(request, "0200", field_map)

      # Or use the struct's own function
      iso_msg = ISOMsg.from_struct(
        request,
        MyApp.SaleRequest.__iso_mti__,
        MyApp.SaleRequest.__iso_field_map__()
      )

      # Convert ISOMsg back to struct
      request2 = ISOMsg.to_struct(iso_msg, MyApp.SaleRequest, field_map)

  ### Working with formatters

      # Encode to wire format
      binary = Iso8583.Formatters.Binary.encode(iso_msg)

      # Decode from wire format
      {:ok, iso_msg2} = Iso8583.Formatters.Binary.decode(binary)

  ### Field-by-field operations

      # Get with default
      value = ISOMsg.get_field(iso_msg, 99, "default")  # => "default"

      # Update MTI
      iso_msg = ISOMsg.set_mti(iso_msg, "0210")

      # Delete a field
      iso_msg = ISOMsg.delete_field(iso_msg, 60)

      # Get all data as a map
      data = ISOMsg.get_data(iso_msg)

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

  @doc """
  Gets the MTI (Message Type Indicator) from the ISOMsg.

  ## Examples

      ISOMsg.get_mti(%ISOMsg{mti: "0200"})
      # => "0200"

  """
  @spec get_mti(t()) :: String.t()
  def get_mti(%__MODULE__{} = iso_msg), do: iso_msg.mti

  @doc """
  Sets the MTI (Message Type Indicator) for the ISOMsg.

  ## Examples

      ISOMsg.set_mti(%ISOMsg{}, "0200")
      # => %ISOMsg{mti: "0200"}

  """
  @spec set_mti(t(), String.t()) :: t()
  def set_mti(%__MODULE__{} = iso_msg, mti) when is_binary(mti) do
    %{iso_msg | mti: mti}
  end

  @doc """
  Gets the data map from the ISOMsg.

  ## Examples

      ISOMsg.get_data(%ISOMsg{data: %{2 => "123"}})
      # => %{2 => "123"}

  """
  @spec get_data(t()) :: %{pos_integer() => String.t()}
  def get_data(%__MODULE__{} = iso_msg), do: iso_msg.data

  @doc """
  Gets a field value from the ISOMsg.

  Returns `nil` if the field is not present.

  ## Examples

      ISOMsg.get_field(%ISOMsg{data: %{2 => "123456"}}, 2)
      # => "123456"

      ISOMsg.get_field(%ISOMsg{}, 2)
      # => nil

  """
  @spec get_field(t(), pos_integer()) :: String.t() | nil
  def get_field(%__MODULE__{data: data}, field_num) when is_integer(field_num) do
    Map.get(data, field_num)
  end

  @doc """
  Gets a field value with a default if not present.

  ## Examples

      ISOMsg.get_field(%ISOMsg{}, 2, "default")
      # => "default"

  """
  @spec get_field(t(), pos_integer(), String.t()) :: String.t()
  def get_field(%__MODULE__{data: data}, field_num, default) when is_integer(field_num) do
    Map.get(data, field_num, default)
  end

  @doc """
  Sets a field value in the ISOMsg.

  ## Examples

      ISOMsg.set_field(%ISOMsg{}, 2, "1234567890123456789")
      # => %ISOMsg{data: %{2 => "1234567890123456789"}}

  """
  @spec set_field(t(), pos_integer(), String.t()) :: t()
  def set_field(%__MODULE__{} = iso_msg, field_num, value)
      when is_integer(field_num) and is_binary(value) do
    %{iso_msg | data: Map.put(iso_msg.data, field_num, value)}
  end

  @doc """
  Deletes a field from the ISOMsg.

  ## Examples

      ISOMsg.delete_field(%ISOMsg{data: %{2 => "123"}}, 2)
      # => %ISOMsg{data: %{}}

  """
  @spec delete_field(t(), pos_integer()) :: t()
  def delete_field(%__MODULE__{} = iso_msg, field_num) when is_integer(field_num) do
    %{iso_msg | data: Map.delete(iso_msg.data, field_num)}
  end

  @doc """
  Returns a list of all field numbers present in the ISOMsg.

  ## Examples

      ISOMsg.fields(%ISOMsg{data: %{2 => "a", 4 => "b", 11 => "c"}})
      # => [2, 4, 11]

  """
  @spec fields(t()) :: [pos_integer()]
  def fields(%__MODULE__{data: data}) do
    Map.keys(data)
  end

  @doc """
  Checks if a field is present in the ISOMsg.

  ## Examples

      ISOMsg.has_field?(%ISOMsg{data: %{2 => "123"}}, 2)
      # => true

      ISOMsg.has_field?(%ISOMsg{}, 2)
      # => false

  """
  @spec has_field?(t(), pos_integer()) :: boolean()
  def has_field?(%__MODULE__{data: data}, field_num) when is_integer(field_num) do
    Map.has_key?(data, field_num)
  end

  @doc """
  Converts a struct to ISOMsg using the provided mapping.

  This helper function converts any struct to an ISOMsg by mapping
  struct fields to ISO field numbers.

  ## Parameters

  - `struct` - The struct to convert
  - `mti` - The Message Type Indicator
  - `field_map` - A map of ISO field numbers to struct field names

  ## Examples

      defmodule SaleRequest do
        defstruct [:pan, :amount, :stan]
      end

      request = %SaleRequest{pan: "123456...", amount: "1000", stan: "000001"}

      ISOMsg.from_struct(request, "0200", %{
        2 => :pan,
        4 => :amount,
        11 => :stan
      })
      # => %ISOMsg{mti: "0200", data: %{2 => "123456...", 4 => "1000", 11 => "000001"}}

  """
  @spec from_struct(struct(), String.t(), %{pos_integer() => atom()}) :: t()
  def from_struct(struct, mti, field_map) when is_map(struct) and is_binary(mti) and is_map(field_map) do
    data =
      Enum.reduce(field_map, %{}, fn {iso_field, struct_field}, acc ->
        case Map.get(struct, struct_field) do
          nil -> acc
          "" -> acc
          value -> Map.put(acc, iso_field, value)
        end
      end)

    %__MODULE__{mti: mti, data: data}
  end

  @doc """
  Converts an ISOMsg to a struct using the provided mapping.

  This helper function converts an ISOMsg to any struct by mapping
  ISO field numbers to struct field names.

  ## Parameters

  - `iso_msg` - The ISOMsg to convert
  - `struct_module` - The struct module to create
  - `field_map` - A map of ISO field numbers to struct field names

  ## Examples

      defmodule SaleRequest do
        defstruct [:pan, :amount, :stan]
      end

      iso_msg = ISOMsg.new("0200", %{2 => "123456...", 4 => "1000", 11 => "000001"})

      ISOMsg.to_struct(iso_msg, SaleRequest, %{
        2 => :pan,
        4 => :amount,
        11 => :stan
      })
      # => %SaleRequest{pan: "123456...", amount: "1000", stan: "000001"}

  """
  @spec to_struct(t(), module(), %{pos_integer() => atom()}) :: struct()
  def to_struct(%__MODULE__{} = iso_msg, struct_module, field_map)
      when is_atom(struct_module) and is_map(field_map) do

    field_values =
      Enum.reduce(field_map, %{}, fn {iso_field, struct_field}, acc ->
        case get_field(iso_msg, iso_field) do
          nil -> acc
          value -> Map.put(acc, struct_field, value)
        end
      end)

    struct(struct_module, field_values)
  end
end
