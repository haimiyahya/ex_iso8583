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
    # for a <- 
    # for n <- 1..max_bit, do: case Enum.member?(list, n), do: 1; else: 0 end end 
  end
end
