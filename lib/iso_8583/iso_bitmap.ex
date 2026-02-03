defmodule IsoBitmap do
  @moduledoc """
  Handles ISO 8583 bitmap operations.

  The bitmap indicates which data elements are present in an ISO 8583 message.
  - Primary bitmap: 8 bytes (64 bits) for fields 2-64
  - Secondary bitmap: 8 bytes (64 bits) for fields 65-128 (indicated by bit 1 being set)

  ## Bitmap Structure

  The bitmap is a binary where each bit represents a field number:
  - Bit 1: Secondary bitmap indicator
  - Bit 2: Field 2 (Primary Account Number)
  - Bit 3: Field 3 (Processing Code)
  - ...
  - Bit 64: Field 64
  - If bit 1 is set, a secondary bitmap follows for fields 65-128

  ## Examples

  Create a bitmap from field data:

      IsoBitmap.create_bitmap(%{2 => "1234567890", 3 => "000000"})
      # => <<0x60, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00>>
      # (bits 2 and 3 are set)

  Convert bitmap to list of field numbers:

      IsoBitmap.bitmap_to_list(<<0x60, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00>>)
      # => [2, 3]

  """

  @type iso_data :: %{pos_integer() => String.t()}
  @type bitmap :: binary()
  @type field_number :: pos_integer()
  @type field_list :: [field_number()]
  @type msg_type :: %{bitmap_type: :binary | :ascii} | map()

  @doc """
  Creates a bitmap from an ISO data map.

  Takes a map of field numbers to values and generates the appropriate
  bitmap (primary or primary+secondary) indicating which fields are present.

  ## Parameters
    - `iso_data`: Map of field numbers to their values

  ## Returns
    - Binary bitmap (8 or 16 bytes depending on highest field number)

  ## Examples

      iex> IsoBitmap.create_bitmap(%{2 => "1234567890", 3 => "000000"}) |> byte_size()
      8

      iex> IsoBitmap.create_bitmap(%{2 => "123", 65 => "data"}) |> byte_size()
      16

  """
  @spec create_bitmap(iso_data()) :: bitmap()
  def create_bitmap(iso_data) do
    iso_data
    |> remove_empty_or_nil()
    |> Map.keys()
    |> add_remove_first_field_number()
    |> list_of_fields_number_to_bit_list()
    |> list_to_bitmap()
  end

  @doc """
  Converts a bitmap binary to a list of field numbers that are present.

  Parses the bitmap and extracts all positions where bits are set to 1,
  returning the corresponding field numbers.

  ## Parameters
    - `bitmap`: Binary bitmap (8 or 16 bytes)

  ## Returns
    - List of field numbers present in the message

  ## Examples

      iex> IsoBitmap.bitmap_to_list(<<96, 0, 0, 0, 0, 0, 0, 0>>)
      [2, 3]

      iex> IsoBitmap.bitmap_to_list(<<128, 0, 0, 0, 0, 0, 0, 1>>)
      [1, 64]

      iex> IsoBitmap.bitmap_to_list(<<>>)
      []

  """
  @spec bitmap_to_list(bitmap()) :: field_list()
  def bitmap_to_list(bitmap) when is_binary(bitmap) do
    bitmap
    |> bits_to_list()
    |> filter_set_bits()
    |> extract_positions()
  end

  def bitmap_to_list(_bitmap), do: []

  @doc """
  Converts a list of bit positions to a bitmap binary.

  Creates a binary where bits at specified positions are set to 1.

  ## Parameters
    - `list`: List of bit positions (1-based)

  ## Returns
    - Binary bitmap

  ## Examples

      iex> IsoBitmap.list_to_bitmap([2, 3])
      <<1::size(2)>>

      iex> IsoBitmap.list_to_bitmap([1])
      <<1::size(1)>>

      iex> IsoBitmap.list_to_bitmap([])
      <<0>>

  """
  @spec list_to_bitmap([pos_integer()]) :: bitmap()
  def list_to_bitmap(list) when is_list(list) and length(list) > 0 do
    for i <- list, do: <<i::1>>, into: <<>>
  end

  def list_to_bitmap(_list), do: <<0>>

  @doc """
  Removes empty or nil values from the ISO data map.

  Filters out entries where the value is an empty string or nil,
  as these should not be included in the bitmap.

  ## Parameters
    - `iso_data`: Map of field numbers to values

  ## Returns
    - Filtered map containing only non-empty values

  ## Examples

      iex> IsoBitmap.remove_empty_or_nil(%{2 => "123", 3 => "", 4 => nil})
      %{2 => "123"}

  """
  @spec remove_empty_or_nil(iso_data()) :: iso_data()
  def remove_empty_or_nil(iso_data) do
    iso_data
    |> Enum.reject(fn {_, val} -> val == nil or val == "" end)
    |> Map.new()
  end

  @doc """
  Ensures field 1 is present if there are fields > 64, or removes it if all fields are < 64.

  Field 1 (the first bit in the bitmap) indicates the presence of a secondary bitmap.
  This function automatically adds or removes bit 1 based on the field numbers present.

  ## Parameters
    - `list`: List of field numbers

  ## Returns
    - Updated list with bit 1 added or removed as needed

  ## Examples

      iex> IsoBitmap.add_remove_first_field_number([2, 3, 65])
      [1, 2, 3, 65]

      iex> IsoBitmap.add_remove_first_field_number([1, 2, 3])
      [2, 3]

  """
  @spec add_remove_first_field_number([pos_integer()]) :: [pos_integer()]
  def add_remove_first_field_number(list) do
    max_field = Enum.max(list)

    cond do
      max_field > 64 and 1 not in list -> [1 | list]
      max_field < 64 and 1 in list -> List.delete(list, 1)
      true -> list
    end
  end

  @doc """
  Converts a list of field numbers to a bit list (0s and 1s).

  The bit list length is determined by the maximum field number (64 or 128).
  Positions corresponding to field numbers in the list are set to 1, others to 0.

  ## Parameters
    - `list`: List of field numbers

  ## Returns
    - List of 0s and 1s representing the bitmap state

  ## Examples

      iex> IsoBitmap.list_of_fields_number_to_bit_list([2, 3]) |> Enum.take(10)
      [0, 1, 1, 0, 0, 0, 0, 0, 0, 0]

      iex> IsoBitmap.list_of_fields_number_to_bit_list([2, 65]) |> Enum.take(10)
      [0, 1, 0, 0, 0, 0, 0, 0, 0, 0]

      iex> length(IsoBitmap.list_of_fields_number_to_bit_list([2, 3]))
      64

      iex> length(IsoBitmap.list_of_fields_number_to_bit_list([2, 65]))
      128

  """
  @spec list_of_fields_number_to_bit_list([pos_integer()]) :: [0 | 1]
  def list_of_fields_number_to_bit_list(list) do
    max_bit = if Enum.max(list) > 64, do: 128, else: 64

    Enum.map(1..max_bit//1, fn field_num ->
      if field_num in list, do: 1, else: 0
    end)
  end

  @doc """
  Transforms the bitmap based on type (:binary or :ascii).

  For ASCII-encoded bitmaps, converts from hexadecimal to binary.
  For binary bitmaps, returns unchanged.

  ## Parameters
    - `iso_msg`: Message containing bitmap
    - `type`: `:binary` or `:ascii`

  ## Returns
    - Transformed message with binary bitmap

  """
  @spec transform_bitmap(binary(), :binary | :ascii) :: binary()
  def transform_bitmap(iso_msg, :binary), do: iso_msg

  def transform_bitmap(iso_msg, :ascii) do
    first_byte = :binary.part(iso_msg, 0, 2) |> Base.decode16!()
    <<first_bit_flag::1, _::bits>> = first_byte

    bitmap_size = if first_bit_flag == 1, do: 16 * 2, else: 8 * 2
    <<bitmap::binary-size(bitmap_size), msg_data::bitstring>> = iso_msg

    Base.decode16!(bitmap) <> msg_data
  end

  @doc """
  Splits the message into bitmap and data portions.

  Extracts the bitmap from the beginning of the message and returns
  both the bitmap and the remaining message data.

  ## Parameters
    - `iso_msg`: Raw ISO message binary
    - `msg_type`: Configuration map with `:bitmap_type` key

  ## Returns
    - `{:ok, bitmap, msg_data}` on success
    - `{:error, "Invalid Parameter"}` on invalid input

  ## Examples

      iex> msg = <<0x60, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x12, 0x34>>
      iex> IsoBitmap.split_bitmap_and_msg(msg, %{bitmap_type: :binary})
      {:ok, <<0x60, 0, 0, 0, 0, 0, 0, 0>>, <<0x12, 0x34>>}

  """
  @spec split_bitmap_and_msg(binary(), msg_type()) :: {:ok, bitmap(), binary()} | {:error, String.t()}
  def split_bitmap_and_msg(iso_msg, msg_type) when is_binary(iso_msg) and byte_size(iso_msg) > 0 do
    bitmap_type = msg_type[:bitmap_type]

    iso_msg
    |> transform_bitmap(bitmap_type)
    |> split_bitmap_and_msg_p()
  end

  def split_bitmap_and_msg(_iso_msg), do: {:error, "Invalid Parameter"}

  # Private functions

  @spec split_bitmap_and_msg_p(bitmap()) :: {:ok, bitmap(), binary()} | {:error, String.t()}
  defp split_bitmap_and_msg_p(<<1::1, _::bits>> = iso_msg) do
    if byte_size(iso_msg) > 16 do
      <<bitmap::binary-size(16), msg_data::bitstring>> = iso_msg
      {:ok, bitmap, msg_data}
    else
      {:error, "Invalid Parameter"}
    end
  end

  defp split_bitmap_and_msg_p(<<0::1, _::bits>> = iso_msg) do
    if byte_size(iso_msg) > 8 do
      <<bitmap::binary-size(8), msg_data::bitstring>> = iso_msg
      {:ok, bitmap, msg_data}
    else
      {:error, "Invalid Parameter"}
    end
  end

  @spec bits_to_list(bitmap()) :: [0 | 1]
  defp bits_to_list(bitmap), do: for(<<bit::1 <- bitmap>>, do: bit)

  @spec filter_set_bits([0 | 1]) :: [{1 | 0, pos_integer()}]
  defp filter_set_bits(bits) do
    bits
    |> Enum.with_index(1)
    |> Enum.filter(fn {bit, _} -> bit == 1 end)
  end

  @spec extract_positions([{1 | 0, pos_integer()}]) :: [pos_integer()]
  defp extract_positions(bits_with_indices) do
    bits_with_indices
    |> Enum.map(fn {_, position} -> position end)
  end
end
