defmodule IsoField do

  # New form_field with padding support
  def form_field({_position, field_format}, field_value, field_header_type, msg_type) do
    header = form_field_header(field_format, field_value, field_header_type)
    body = form_field_value(field_format, field_value, field_header_type, msg_type)

    header <> body
  end

  # Backward compatible: form_field without msg_type (uses default padding behavior)
  def form_field({_position, field_format}, field_value, field_header_type) do
    header = form_field_header(field_format, field_value, field_header_type)
    body = form_field_value(field_format, field_value, field_header_type, nil)

    header <> body
  end

  # Handle both 3-tuple (old) and 4-tuple (new) formats
  defp get_field_format_tuple({h, d, l}), do: {h, d, l, nil}
  defp get_field_format_tuple({h, d, l, p}), do: {h, d, l, p}

  def form_field_header({0, _, _, _}, _, _) do
    <<>>
  end

  def form_field_header(field_format, field_value, :bcd) do
    {header_size, data_type, max_len, _padding} = get_field_format_tuple(field_format)

    size =
      case data_type do
        :bcd -> byte_size(field_value)
        :hex -> div(byte_size(field_value), 2)
        :ascii -> byte_size(field_value)
        :binary -> byte_size(field_value)
        :z ->
          cond do
            byte_size(field_value) > max_len -> max_len
            true -> byte_size(field_value)
          end
      end

    header =
      Integer.to_string(size)
      |> Util.pad_left_string(header_size, "0")
      |> Util.pad_left_string_if_odd_length("0")
      |> Base.decode16!()

    header
  end

  def form_field_header(field_format, field_value, :ascii) do
    {header_size, _data_type, max_len, _padding} = get_field_format_tuple(field_format)

    size = byte_size(field_value)

    size =
      cond do
        size > max_len -> max_len
        true -> size
      end

    header =
      Integer.to_string(size)
      |> Util.pad_left_string(header_size, "0")

    header
  end

  def form_field_value(field_format, field_value, :bcd, msg_type) do
    {header_size, data_type, max_len, padding_override} = get_field_format_tuple(field_format)

    case data_type do
      :bcd ->
        field_value
        |> Util.truncate_string_take_left(max_len)
        |> Util.sanitize_numeric_string()
        |> apply_padding_if_needed(header_size, data_type, max_len, padding_override, msg_type)
        |> Util.pad_left_string_if_odd_length("0")
        |> Base.decode16!()

      :hex ->
        field_value

      :ascii ->
        field_value
        |> Util.truncate_string_take_left(max_len)
        |> apply_padding_if_needed(header_size, data_type, max_len, padding_override, msg_type)

      :binary ->
        bin_length =
          case byte_size(field_value) > trunc(max_len/8) do
            true -> trunc(max_len/8)
            false -> byte_size(field_value)
          end

        binary_part(field_value, 0, bin_length)

      :z ->
        field_value
        |> Util.truncate_string_take_left(max_len)
        |> apply_padding_if_needed(header_size, data_type, max_len, padding_override, msg_type)
        |> Util.pad_right_string_if_odd_length("0")
        |> Base.decode16!()
    end
  end

  def form_field_value(field_format, field_value, :ascii, msg_type) do
    {header_size, data_type, max_len, padding_override} = get_field_format_tuple(field_format)

    case data_type do
      :bcd ->
        field_value
        |> Util.truncate_string_take_left(max_len)
        |> Util.sanitize_numeric_string()
        |> apply_padding_if_needed(header_size, data_type, max_len, padding_override, msg_type)

      :ascii ->
        field_value
        |> Util.truncate_string_take_left(max_len)
        |> apply_padding_if_needed(header_size, data_type, max_len, padding_override, msg_type)

      :z ->
        field_value
        |> Util.truncate_string_take_left(max_len)
        |> apply_padding_if_needed(header_size, data_type, max_len, padding_override, msg_type)

      :binary ->
        field_value
        |> Util.truncate_string_take_left(max_len)
        |> Util.pad_left_string_if_odd_length("0")
        |> Base.decode16!()
    end
  end

  # Apply padding based on override or msg_type defaults
  defp apply_padding_if_needed(value, header_size, data_type, max_len, padding_override, msg_type) do
    cond do
      # Variable length field (has header) - no padding
      header_size > 0 ->
        value

      # Padding explicitly disabled
      padding_override == false ->
        value

      # Custom padding override
      is_map(padding_override) ->
        char = Map.get(padding_override, :char) || Map.get(padding_override, "char") || " "
        direction = Map.get(padding_override, :direction) || Map.get(padding_override, "direction") || :left
        apply_padding(value, max_len, char, direction)

      # Use msg_type defaults
      msg_type != nil ->
        padding_config = get_default_padding(data_type, msg_type)
        apply_padding(value, max_len, padding_config.char, padding_config.direction)

      # Backward compatible: use old behavior
      true ->
        apply_legacy_padding(value, header_size, data_type, max_len)
    end
  end

  defp get_default_padding(:bcd, msg_type) do
    padding = get_in(msg_type, [:padding, :bcd])
    char = padding[:char] || "0"
    direction = padding[:direction] || :left
    %{char: char, direction: direction}
  end

  defp get_default_padding(:ascii, msg_type) do
    padding = get_in(msg_type, [:padding, :ascii])
    char = padding[:char] || " "
    direction = padding[:direction] || :left
    %{char: char, direction: direction}
  end

  defp get_default_padding(:z, msg_type) do
    padding = get_in(msg_type, [:padding, :z]) || get_in(msg_type, [:padding, :bcd])
    char = padding[:char] || "0"
    direction = padding[:direction] || :right
    %{char: char, direction: direction}
  end

  defp get_default_padding(_other, _msg_type) do
    %{char: " ", direction: :left}
  end

  defp apply_padding(value, max_len, char, direction) do
    case direction do
      :left -> Util.pad_string(value, max_len, char, :left)
      :right -> Util.pad_string(value, max_len, char, :right)
      _ -> Util.pad_string(value, max_len, char, :left)
    end
  end

  # Backward compatible padding behavior
  # Only apply padding if value is actually shorter than max_len
  defp apply_legacy_padding(value, 0, :bcd, max_len) do
    # For BCD data type in ASCII mode, pad_left_bcd is incorrect
    # because it divides max_len by 2 for BCD byte encoding
    # We should use regular string padding instead
    value_len = byte_size(value)
    if value_len < max_len do
      Util.pad_string(value, max_len, "0", :left)
    else
      value
    end
  end

  defp apply_legacy_padding(value, 0, :ascii, max_len) do
    value_len = byte_size(value)
    if value_len < max_len do
      Util.pad_left_string(value, max_len, " ")
    else
      value
    end
  end

  defp apply_legacy_padding(value, _, _, _), do: value

  # Handle both 3-tuple and 4-tuple for extract_field (backward compatibility)
  def extract_field({position, field_format_tuple}, accum_and_iso_msg, field_header_type) do
    # Convert to 4-tuple format for consistent handling
    {header_size, data_type, max_length, _padding} = get_field_format_tuple(field_format_tuple)
    extract_field_by_tuple(position, header_size, data_type, max_length, accum_and_iso_msg, field_header_type)
  end

  def extract_field_by_tuple(position, 0, _data_type, max_length, {accum, iso_msg}, :ascii) do
    field_length = max_length
    <<field_value::binary-size(field_length)>> <> data_remaining = iso_msg

    field_value = field_value |> Util.truncate_string(max_length)

    {Map.put_new(accum, position, field_value), data_remaining}
  end

  def extract_field_by_tuple(position, 0, data_type, max_length, {accum, iso_msg}, :bcd) do
    {:ok, field_length} =
      case data_type do
        :bcd -> Util.get_bcd_length(max_length)
        :hex -> Util.get_bcd_length(max_length)
        :ascii -> {:ok, max_length}
        :binary -> {:ok, trunc(max_length/8)}
        :z -> Util.get_bcd_length(max_length)
      end

    <<field_value::binary-size(field_length)>> <> data_remaining = iso_msg
    field_value =
      case data_type do
        :bcd -> Util.convert_bin_to_hex(field_value) |> (fn {:ok, val} -> val end).()
        :hex -> Util.convert_bin_to_hex(field_value) |> (fn {:ok, val} -> val end).()
        :ascii -> field_value
        :binary -> field_value
      end

    field_value = field_value |> Util.truncate_string(max_length)

    {Map.put_new(accum, position, field_value), data_remaining}
  end

  def extract_field_by_tuple(position, length_header, _data_type, max_length, {accum, iso_msg}, :ascii) do
    <<field_size::binary-size(length_header)>> <> data_remaining1 = iso_msg

    {field_sz, _} = field_size |> Integer.parse()

    <<field_value::binary-size(field_sz)>> <> data_remaining = data_remaining1

    truncate_length =
      cond do
        field_sz > max_length -> max_length
        true -> field_sz
      end

    <<field_value::binary-size(truncate_length)>> <> _ = field_value

    {Map.put_new(accum, position, field_value), data_remaining}
  end

  def extract_field_by_tuple(position, length_header, data_type, max_length, {accum, iso_msg}, :bcd) do
    length_header = determine_header_binary_size(length_header)
    <<field_size::binary-size(length_header)>> <> data_remaining1 = iso_msg

    {field_sz, _} = field_size |> Base.encode16() |> Integer.parse()

    {:ok, field_sz_binary} =
      case data_type do
        :bcd -> Util.get_bcd_length(field_sz)
        :ascii -> {:ok, field_sz}
        :binary -> {:ok, field_sz}
        :z -> {:ok, trunc(Util.make_even(field_sz)/2)}
      end

    <<field_value::binary-size(field_sz_binary)>> <> data_remaining = data_remaining1

    {:ok, field_value} =
      case data_type do
        :bcd -> Util.convert_bin_to_hex(field_value)
        :ascii -> {:ok, field_value}
        :binary -> {:ok, field_value}
        :z -> Util.convert_bin_to_hex(field_value)
      end

    truncate_length =
      cond do
        field_sz > max_length -> max_length
        String.length(field_value) > field_sz -> field_sz
        true -> field_sz
      end

    <<field_value::binary-size(truncate_length)>> <> _ = field_value
    {Map.put_new(accum, position, field_value), data_remaining}
  end

  def determine_header_binary_size(length_header) do
    div(length_header + rem(length_header, 2), 2)
  end

end
