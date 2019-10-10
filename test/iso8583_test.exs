defmodule Ex_Iso8583Test do
  use ExUnit.Case, async: true
  use ExUnitProperties
  use Bitwise
  doctest Ex_Iso8583

  property "fn Ex_Iso8583.list_to_bitmap/1 test => eight_byte_binary_with_first_bit_not_set -> Ex_Iso8583.bitmap_to_list/1 -> Ex_Iso8583.list_to_bitmap/1 === eight_byte_binary_with_first_bit_not_set" do
    check all(bin <- eight_byte_binary_with_first_bit_not_set()) do
      assert bin ==
               bin
               |> Ex_Iso8583.bitmap_to_list()
               |> Ex_Iso8583.add_remove_first_field_number()
               |> Ex_Iso8583.list_of_fields_number_to_bit_list()
               |> Ex_Iso8583.list_to_bitmap()
    end
  end

  property "fn Ex_Iso8583.list_to_bitmap/1 test => sixteen_byte_binary_with_first_bit_is_set -> Ex_Iso8583.bitmap_to_list/1 -> Ex_Iso8583.list_to_bitmap/1 === sixteen_byte_binary_with_first_bit_is_set" do
    check all(bin <- sixteen_byte_binary_with_first_bit_is_set()) do
      assert bin ==
               bin
               |> Ex_Iso8583.bitmap_to_list()
               |> Ex_Iso8583.add_remove_first_field_number()
               |> Ex_Iso8583.list_of_fields_number_to_bit_list()
               |> Ex_Iso8583.list_to_bitmap()
    end
  end

  property "fn Ex_Iso8583.bitmap_to_list/1 and list_of_fields_number_to_bit_list/1 test => list_of_integer_between_2_till_64_ordered -> Ex_Iso8583.bitmap_to_list/1 -> Ex_Iso8583.list_to_bitmap/1 === list_of_integer_between_2_till_64_ordered" do
    check all(list <- list_of_integer_between_2_till_64_ordered()) do
      assert list ==
               list
               |> Ex_Iso8583.add_remove_first_field_number()
               |> Ex_Iso8583.list_of_fields_number_to_bit_list()
               |> Ex_Iso8583.list_to_bitmap()
               |> Ex_Iso8583.bitmap_to_list()
    end
  end

  property "fn Ex_Iso8583.bitmap_to_list/1 and list_of_fields_number_to_bit_list/1 test => list_of_integer_between_2_till_128_ordered -> Ex_Iso8583.bitmap_to_list/1 -> Ex_Iso8583.list_to_bitmap/1 === list_of_integer_between_2_till_128_ordered" do
    check all(list <- list_of_integer_between_2_till_128_ordered()) do
      assert list ==
               list
               |> Ex_Iso8583.add_remove_first_field_number()
               |> Ex_Iso8583.list_of_fields_number_to_bit_list()
               |> Ex_Iso8583.list_to_bitmap()
               |> Ex_Iso8583.bitmap_to_list()
    end
  end

  property "fn Ex_Iso8583.add_remove_first_field_number/1 test => list_of_integer_between_2_till_64_ordered -> Ex_Iso8583.add_remove_first_field_number/1 === list_of_integer_between_2_till_64_ordered" do
    check all(list <- list_of_integer_between_2_till_64_ordered()) do
      assert list ==
               list
               |> Ex_Iso8583.add_remove_first_field_number()
    end
  end

  property "fn Ex_Iso8583.add_remove_first_field_number/1 test => list_of_integer_between_2_till_128_ordered -> Ex_Iso8583.add_remove_first_field_number/1 === list_of_integer_between_2_till_128_ordered" do
    check all(list <- list_of_integer_between_2_till_128_ordered()) do
      assert list ==
               list
               |> Ex_Iso8583.add_remove_first_field_number()
    end
  end

  property "fn Ex_Iso8583.add_remove_first_field_number/1 test => list_of_integer_between_65_till_128_ordered -> Ex_Iso8583.add_remove_first_field_number/1 === list_of_integer_between_65_till_128_ordered" do
    check all(list <- list_of_integer_between_65_till_128_ordered()) do
      assert [1] ++ list ==
               list
               |> Ex_Iso8583.add_remove_first_field_number()
    end
  end

  def list_of_integer_between_2_till_64_ordered() do
    StreamData.uniq_list_of(StreamData.integer(2..64), min_length: 1, max_length: 20)
    |> StreamData.map(&Enum.sort(&1))
  end

  def list_of_integer_between_2_till_128_ordered() do
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

  def list_of_integer_between_65_till_128_ordered() do
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
