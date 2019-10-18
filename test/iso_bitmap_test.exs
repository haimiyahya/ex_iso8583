defmodule IsoBitmapTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  use Bitwise
  doctest IsoBitmap

  property "fn IsoBitmap.list_to_bitmap/1 test => eight_byte_binary_with_first_bit_not_set -> IsoBitmap.bitmap_to_list/1 -> IsoBitmap.list_to_bitmap/1 === eight_byte_binary_with_first_bit_not_set" do
    check all(bin <- eight_byte_binary_with_first_bit_not_set()) do
      assert bin ==
               bin
               |> IsoBitmap.bitmap_to_list()
               |> IsoBitmap.add_remove_first_field_number()
               |> IsoBitmap.list_of_fields_number_to_bit_list()
               |> IsoBitmap.list_to_bitmap()
    end
  end

  property "fn IsoBitmap.list_to_bitmap/1 test => sixteen_byte_binary_with_first_bit_is_set -> IsoBitmap.bitmap_to_list/1 -> IsoBitmap.list_to_bitmap/1 === sixteen_byte_binary_with_first_bit_is_set" do
    check all(bin <- sixteen_byte_binary_with_first_bit_is_set()) do
      assert bin ==
               bin
               |> IsoBitmap.bitmap_to_list()
               |> IsoBitmap.add_remove_first_field_number()
               |> IsoBitmap.list_of_fields_number_to_bit_list()
               |> IsoBitmap.list_to_bitmap()
    end
  end

  property "fn IsoBitmap.bitmap_to_list/1 and list_of_fields_number_to_bit_list/1 test => list_of_integers_between_2_till_64_ordered -> IsoBitmap.bitmap_to_list/1 -> IsoBitmap.list_to_bitmap/1 === list_of_integers_between_2_till_64_ordered" do
    check all(list <- list_of_integers_between_2_till_64_ordered()) do
      assert list ==
               list
               |> IsoBitmap.add_remove_first_field_number()
               |> IsoBitmap.list_of_fields_number_to_bit_list()
               |> IsoBitmap.list_to_bitmap()
               |> IsoBitmap.bitmap_to_list()
    end
  end

  property "fn IsoBitmap.bitmap_to_list/1 and list_of_fields_number_to_bit_list/1 test => list_of_integers_between_2_till_128_ordered -> IsoBitmap.bitmap_to_list/1 -> IsoBitmap.list_to_bitmap/1 === list_of_integers_between_2_till_128_ordered" do
    check all(list <- list_of_integers_between_2_till_128_ordered()) do
      assert list ==
               list
               |> IsoBitmap.add_remove_first_field_number()
               |> IsoBitmap.list_of_fields_number_to_bit_list()
               |> IsoBitmap.list_to_bitmap()
               |> IsoBitmap.bitmap_to_list()
    end
  end

  property "fn IsoBitmap.add_remove_first_field_number/1 test => list_of_integers_between_2_till_64_ordered -> IsoBitmap.add_remove_first_field_number/1 === list_of_integers_between_2_till_64_ordered" do
    check all(list <- list_of_integers_between_2_till_64_ordered()) do
      assert list ==
               list
               |> IsoBitmap.add_remove_first_field_number()
    end
  end

  property "fn IsoBitmap.add_remove_first_field_number/1 test => list_of_integers_between_2_till_128_ordered -> IsoBitmap.add_remove_first_field_number/1 === list_of_integers_between_2_till_128_ordered" do
    check all(list <- list_of_integers_between_2_till_128_ordered()) do
      assert list ==
               list
               |> IsoBitmap.add_remove_first_field_number()
    end
  end

  property "fn IsoBitmap.add_remove_first_field_number/1 test => list_of_integers_between_65_till_128_ordered -> IsoBitmap.add_remove_first_field_number/1 === list_of_integers_between_65_till_128_ordered" do
    check all(list <- list_of_integers_between_65_till_128_ordered()) do
      assert [1] ++ list ==
               list
               |> IsoBitmap.add_remove_first_field_number()
    end
  end

  # property "fn Ex_Iso8583.remove_empty_or_nil/1 test => list_of_tuple_with_one_dummy_empty_value -> Ex_Iso8583.add_remove_first_field_number/1 === list_of_tuple_with_one_dummy_empty_value" do
  #  check all(
  #          data <-
  #            list_of_tuple_with_one_dummy_empty_value()
  #        ) do
  #    assert Map.delete(data, 2) ==
  #             data
  #             |> Ex_Iso8583.remove_empty_or_nil()
  #  end
  # end

  # list_of_tuple_with_key_and_string_value_between_1_to_999_length_with_key_2_set_to_empty

  # def list_of_tuple_with_one_dummy_empty_value() do
  #  StreamData.map_of(
  #    StreamData.integer(3..64),
  #    StreamData.string(:ascii, min_length: 1, max_length: 999),
  #    min_length: 7,
  #    max_length: 63
  #  )
  #  |> StreamData.map(&Map.put_new(&1, 2, ""))
  # end

  def list_of_integers_between_2_till_64_ordered() do
    StreamData.uniq_list_of(StreamData.integer(2..64), min_length: 1, max_length: 20)
    |> StreamData.map(&Enum.sort(&1))
  end

  def list_of_integers_between_2_till_128_ordered() do
    StreamData.uniq_list_of(StreamData.integer(2..128), min_length: 1, max_length: 20)
    |> StreamData.map(
      &case Enum.any?(&1, fn x -> x >= 65 end),
        do:
          (
            true -> [1] ++ &1
            false -> [1, 65] ++ &1
          )
    )
    |> StreamData.map(&Enum.sort(&1))
  end

  def list_of_integers_between_65_till_128_ordered() do
    StreamData.uniq_list_of(StreamData.integer(65..128), min_length: 1, max_length: 20)
    |> StreamData.map(&Enum.sort(&1))
  end

  def eight_byte_binary_with_first_bit_not_set() do
    StreamData.binary(min_length: 8, max_length: 8)
    |> StreamData.map(&turn_off_first_bit_of_a_binary(&1))
  end

  def sixteen_byte_binary_with_first_bit_is_set() do
    StreamData.binary(min_length: 16, max_length: 16)
    |> StreamData.map(&turn_on_first_bit_of_a_binary(&1))
  end

  def turn_off_first_bit_of_a_binary(binary_input) do
    <<first_byte::binary-size(1)>> <> remaining = binary_input
    <<:binary.decode_unsigned(first_byte) &&& 127>> <> remaining
  end

  def turn_on_first_bit_of_a_binary(binary_input) do
    <<first_byte::binary-size(1)>> <> remaining = binary_input
    <<:binary.decode_unsigned(first_byte) ||| 128>> <> remaining
  end
end
