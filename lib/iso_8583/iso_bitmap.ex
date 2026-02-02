defmodule IsoBitmap do
  @moduledoc """
  Handles ISO 8583 bitmap operations.

  The bitmap indicates which data elements are present in an ISO 8583 message.
  - Primary bitmap: 8 bytes (64 bits) for fields 2-64
  - Secondary bitmap: 8 bytes (64 bits) for fields 65-128 (indicated by bit 1 being set)
  """

  @doc """
  Creates a bitmap from an ISO data map.
  """
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
  """
  def bitmap_to_list(bitmap) when is_binary(bitmap) do
    bitmap
    |> bits_to_list()
    |> filter_set_bits()
    |> extract_positions()
  end

  def bitmap_to_list(_bitmap), do: []

  @doc """
  Converts a list of bit positions to a bitmap binary.
  """
  def list_to_bitmap(list) when is_list(list) and length(list) > 0 do
    for i <- list, do: <<i::1>>, into: <<>>
  end

  def list_to_bitmap(_list), do: <<0>>

  @doc """
  Removes empty or nil values from the ISO data map.
  """
  def remove_empty_or_nil(iso_data) do
    iso_data
    |> Enum.reject(fn {_, val} -> val == nil or val == "" end)
    |> Map.new()
  end

  @doc """
  Ensures field 1 is present if there are fields > 64, or removes it if all fields are < 64.
  Field 1 indicates the presence of a secondary bitmap.
  """
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
  """
  def list_of_fields_number_to_bit_list(list) do
    max_bit = if Enum.max(list) > 64, do: 128, else: 64

    Enum.map(1..max_bit, fn field_num ->
      if field_num in list, do: 1, else: 0
    end)
  end

  @doc """
  Transforms the bitmap based on type (:binary or :ascii).
  """
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
  """
  def split_bitmap_and_msg(iso_msg, msg_type) when is_binary(iso_msg) and byte_size(iso_msg) > 0 do
    bitmap_type = msg_type[:bitmap_type]

    iso_msg
    |> transform_bitmap(bitmap_type)
    |> split_bitmap_and_msg_p()
  end

  def split_bitmap_and_msg(_iso_msg), do: {:error, "Invalid Parameter"}

  # Private functions

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

  defp bits_to_list(bitmap), do: for(<<bit::1 <- bitmap>>, do: bit)

  defp filter_set_bits(bits) do
    bits
    |> Enum.with_index(1)
    |> Enum.filter(fn {bit, _} -> bit == 1 end)
  end

  defp extract_positions(bits_with_indices) do
    bits_with_indices
    |> Enum.map(fn {_, position} -> position end)
  end
end
