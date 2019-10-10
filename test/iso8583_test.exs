defmodule Ex_Iso8583Test do
  use ExUnit.Case, async: true
  use ExUnitProperties
  use Bitwise
  doctest Ex_Iso8583

  property "fn Ex_Iso8583.list_to_bitmap/1 test => eight_byte_binary_with_first_bit_not_set -> Ex_Iso8583.bitmap_to_list/1 -> Ex_Iso8583.list_to_bitmap/1 === eight_byte_binary_with_first_bit_not_set" do
    check all bin <- eight_byte_binary_with_first_bit_not_set() do
      assert bin == (bin |> Ex_Iso8583.bitmap_to_list |> Ex_Iso8583.add_remove_first_bit |> Ex_Iso8583.list_of_bits |> Ex_Iso8583.list_to_bitmap)
    end
  end
  
  property "fn Ex_Iso8583.list_to_bitmap/1 test => sixteen_byte_binary_with_first_bit_is_set -> Ex_Iso8583.bitmap_to_list/1 -> Ex_Iso8583.list_to_bitmap/1 === sixteen_byte_binary_with_first_bit_is_set" do
    check all bin <- sixteen_byte_binary_with_first_bit_is_set() do
      assert bin == (bin |> Ex_Iso8583.bitmap_to_list |> Ex_Iso8583.add_remove_first_bit |> Ex_Iso8583.list_of_bits |> Ex_Iso8583.list_to_bitmap)
    end
  end
  
  def eight_byte_binary_with_first_bit_not_set() do
    StreamData.map(StreamData.binary(min_length: 8, max_length: 8), & turn_off_first_bit_of_a_binary(&1))
  end
  
  def sixteen_byte_binary_with_first_bit_is_set() do
    StreamData.map(StreamData.binary(min_length: 16, max_length: 16), & turn_on_first_bit_of_a_binary(&1))
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
