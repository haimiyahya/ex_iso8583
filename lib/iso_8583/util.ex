defmodule Util do
  @moduledoc """
  Utility functions for ISO 8583 message processing.

  Provides helper functions for string manipulation, BCD encoding/decoding,
  and data sanitization.
  """

  require Integer

  @doc """
  Flexible padding function supporting both left and right padding.

  ## Parameters
    - value: The string to pad
    - size: Target size
    - padding_char: Character to use for padding
    - direction: :left or :right

  ## Examples
      iex> Util.pad_string("abc", 5, "0", :left)
      "00abc"
      iex> Util.pad_string("abc", 5, " ", :right)
      "abc  "
  """
  def pad_string(value, size, padding_char, direction \\ :left) when is_binary(value) do
    value_len = byte_size(value)

    cond do
      value_len < size ->
        padding_count = size - value_len
        padding = String.duplicate(padding_char, padding_count)

        case direction do
          :right -> value <> padding
          _ -> padding <> value
        end

      value_len > size ->
        String.slice(value, byte_size(value) - size, size)

      true ->
        value
    end
  end

  def check_if_required_pad_left(value, 0, :bcd, max_len) do
    pad_left_bcd(value, max_len)
  end

  def check_if_required_pad_left(value, 0, :ascii, max_len) do
    pad_left_string(value, max_len, " ")
  end

  def check_if_required_pad_left(value, _, :bcd, _max_len) do
    value
  end

  def check_if_required_pad_left(value, _, :ascii, _max_len) do
    value
  end

  def pad_left_bcd(value, max_len) do
    max_len = div(max_len, 2)

    cond do
      byte_size(value) < max_len ->
        for(_i <- 1..(max_len - byte_size(value)), do: <<0>>, into: <<>>) <> value

      byte_size(value) > max_len ->
        :binary.part(value, byte_size(value) - max_len, max_len)

      byte_size(value) == max_len ->
        value
    end
  end

  def pad_left_string(value, size, padding_string) do
    cond do
      byte_size(value) < size ->
        for(_i <- 1..(size - byte_size(value)), do: padding_string, into: "") <> value

      byte_size(value) > size ->
        String.slice(value, byte_size(value) - size, size)

      byte_size(value) == size ->
        value
    end
  end

  def sanitize_numeric_string(field_value) do
    field_value
    |> String.replace(~r/[^\d]/, "")
  end

  def pad_left_string_if_odd_length(field_value, padding_char) do
    case rem(String.length(field_value), 2) > 0 do
      true -> padding_char <> field_value
      false -> field_value
    end
  end

  def pad_right_string_if_odd_length(field_value, padding_char) do
    case rem(String.length(field_value), 2) > 0 do
      true -> field_value <> padding_char
      false -> field_value
    end
  end

  def sanitize_and_convert_string_to_int(field_value) do
    {int_val, _} =
      field_value
      |> sanitize_numeric_string
      |> Integer.parse()

    int_val
  end

  def get_bcd_length(length) do
    case is_integer(length) and length > 0 do
      true -> {:ok, div(make_even(length), 2)}
      false -> {:error, "Invalid Parameter"}
    end
  end

  def convert_bin_to_hex(value) do
    case is_binary(value) and byte_size(value) > 0 do
      true -> {:ok, Base.encode16(value)}
      false -> {:error, "Invalid Parameter"}
    end
  end

  @doc """
  Converts binary to hex, raising on error (bang version).
  """
  def convert_bin_to_hex!(value) do
    case convert_bin_to_hex(value) do
      {:ok, result} -> result
      {:error, _} -> raise ArgumentError, "Invalid binary value"
    end
  end

  @doc """
  Takes the first n bytes from a binary.
  """
  def take_first_bytes(value, n) when is_binary(value) do
    bin_length = min(byte_size(value), n)
    binary_part(value, 0, bin_length)
  end

  def make_even(value) do
    case is_integer(value) and value > 0 do
      true ->
        value +
          case Integer.is_odd(value) do
            true -> 1
            false -> 0
          end

      false ->
        value
    end
  end

  def truncate_string(value, max_len) do
    String.slice(value, String.length(value) - max_len, max_len)
  end

  def truncate_string_take_left(value, max_len) do
    String.slice(value, 0, max_len)
  end
end
