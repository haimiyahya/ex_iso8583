defmodule Util do
  require Integer

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
    |> pad_left_string_if_odd_length("0")
  end

  def pad_left_string_if_odd_length(field_value, padding_char) do
    case rem(String.length(field_value), 2) > 0 do
      true -> padding_char <> field_value
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
    case is_integer(length) and length > 1 do
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
end
