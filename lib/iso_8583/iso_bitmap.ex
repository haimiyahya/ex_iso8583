defmodule IsoBitmap do
  def create_bitmap(iso_data) do

    iso_data
    |> remove_empty_or_nil
    |> Map.keys()
    |> add_remove_first_field_number
    |> list_of_fields_number_to_bit_list
    |> list_to_bitmap

  end



  def bitmap_to_list(bitmap) do
    case is_binary(bitmap) do
      true ->
        for(<<r::1 <- bitmap>>, do: r)
        |> Enum.with_index(1)
        |> Enum.map(fn {a, b} -> {b, a} end)
        # remove field where the bit was not set
        |> Enum.filter(fn {_, b} -> b == 1 end)
        |> Enum.map(fn {a, _} -> a end)

      false ->
        []
    end
  end

  def list_to_bitmap(list) do
    case length(list) > 0 do
      true -> for i <- list, do: <<i::1>>, into: <<>>
      false -> <<0>>
    end
  end

  def remove_empty_or_nil(iso_data) do
    iso_data
    |> Enum.filter(fn {_, val} -> val != nil end)
    |> Enum.filter(fn {_, val} -> val != "" end)
    |> Enum.into(%{})
  end

  def add_remove_first_field_number(list) do
    cond do
      Enum.max(list) > 64 and Enum.member?(list, 1) == false -> [1] ++ list
      Enum.max(list) < 64 and Enum.member?(list, 1) == true -> list -- [1]
      true -> list
    end
  end

  def list_of_fields_number_to_bit_list(list) do
    max_bit =
      case list |> Enum.max() > 64 do
        true -> 128
        false -> 64
      end

    Enum.map(1..max_bit, fn a -> if(Enum.member?(list, a), do: 1, else: 0) end)

  end

  def transform_bitmap(iso_msg_without_tpdu, :binary) do
    iso_msg_without_tpdu
  end

  def transform_bitmap(iso_msg_without_tpdu, :ascii) do
    # get the first byte of the bitmap
    first_byte =
      :binary.part(iso_msg_without_tpdu, 0, 2)
      |> Base.decode16!()

    <<first_bit_flag::1, _tail::bitstring>> = first_byte

    bitmap_size =
      case first_bit_flag do
        0 -> 8 * 2
        1 -> 16 * 2
      end

    <<bitmap::binary-size(bitmap_size), msg_data::bitstring>> = iso_msg_without_tpdu

    Base.decode16!(bitmap) <> msg_data
  end

  def split_bitmap_and_msg_p(<<1::1, _tail::bitstring>> = iso_msg_without_tpdu) do
    case byte_size(iso_msg_without_tpdu) > 16 do
      true ->
        <<bitmap::binary-size(16), msg_data::bitstring>> = iso_msg_without_tpdu
        {:ok, bitmap, msg_data}

      false ->
        {:error, "Invalid Parameter"}
    end
  end

  def split_bitmap_and_msg_p(<<0::1, _tail::bitstring>> = iso_msg_without_tpdu) do
    case byte_size(iso_msg_without_tpdu) > 8 do
      true ->
        <<bitmap::binary-size(8), msg_data::bitstring>> = iso_msg_without_tpdu
        {:ok, bitmap, msg_data}

      false ->
        {:error, "Invalid Parameter"}
    end
  end

  def split_bitmap_and_msg(iso_msg_without_tpdu, msg_type)
      when is_binary(iso_msg_without_tpdu) and byte_size(iso_msg_without_tpdu) > 0 do
    bitmap_type = msg_type[:bitmap_type]

    iso_msg_without_tpdu
    |> transform_bitmap(bitmap_type)
    |> split_bitmap_and_msg_p()
  end

  def split_bitmap_and_msg(_iso_msg_without_tpdu) do
    {:error, "Invalid Parameter"}
  end
end
