defmodule IsoField do

  def form_field({position, field_format}, field_value, :bcd) do

    header = form_field_header(field_format, field_value, :bcd)
    body = form_field_value(field_format, field_value, :bcd)

    header <> body
  end

  def form_field({_position, field_format}, field_value, :ascii) do

    header = form_field_header(field_format, field_value, :ascii)
    body = form_field_value(field_format, field_value, :ascii)
    header <> body
  end

  def form_field_header({0, _, _} = _field_format, _, _) do
    <<>>
  end

  def form_field_header({header_size, data_type, _max_len} = _field_format, field_value, :bcd) do

    size =
      case data_type do
        :bcd ->
          div(byte_size(field_value), 2)

        :hex ->
          div(byte_size(field_value), 2)

        :ascii ->
          byte_size(field_value)

        :binary ->
          byte_size(field_value)

        :z ->
          byte_size(field_value)*2
      end

    header =
      Integer.to_string(size)
      |> Util.pad_left_string(header_size, "0")
      |> Util.pad_left_string_if_odd_length("0")
      |> Base.decode16!()
    header
  end

  def form_field_header({header_size, _data_type, max_len} = _field_format, field_value, :ascii) do
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

  def form_field_value({header_size, data_type, max_len} = _field_format, field_value, :bcd) do
    case data_type do
      :bcd ->
        field_value
        |> Util.truncate_string_take_left(max_len)
        |> Util.sanitize_numeric_string()
        |> Util.pad_left_string_if_odd_length("0")
        |> Base.decode16!()

      :hex ->
        field_value

      :ascii ->
        field_value
        |> Util.truncate_string_take_left(max_len)
        |> Util.check_if_required_pad_left(header_size, data_type, max_len)

      :binary ->
        field_value

      :z ->
        field_value

    end
  end

  def form_field_value({_header_size, data_type, max_len} = _field_format, field_value, :ascii) do

    case data_type do
      :bcd ->
        field_value |> Util.truncate_string_take_left(max_len) |> Util.sanitize_numeric_string()

      :ascii ->
        field_value
        |> Util.truncate_string_take_left(max_len)

      :binary ->
        field_value
        |> Util.truncate_string_take_left(max_len)
        |> Util.pad_left_string_if_odd_length("0")
        |> Base.decode16!()
    end
  end

  def extract_field({position, {0, _data_type, max_length}}, {accum, iso_msg}, :ascii) do
    field_length = max_length
    <<field_value::binary-size(field_length)>> <> data_remaining = iso_msg
    field_value = field_value |> Util.truncate_string(max_length)

    {Map.put_new(accum, position, field_value), data_remaining}
  end

  def extract_field({position, {0, data_type, max_length}}, {accum, iso_msg}, :bcd) do
    {:ok, field_length} =
      case data_type do
        :bcd -> Util.get_bcd_length(max_length)
        :hex -> Util.get_bcd_length(max_length)
        :ascii -> {:ok, max_length}
        :binary -> Util.get_bcd_length(max_length)
      end

    <<field_value::binary-size(field_length)>> <> data_remaining = iso_msg

    field_value =
      case data_type do
        :bcd -> Util.convert_bin_to_hex(field_value) |> (fn {:ok, val} -> val end).()
        :hex -> Util.convert_bin_to_hex(field_value) |> (fn {:ok, val} -> val end).()
        :ascii -> field_value
        :binary -> Util.convert_bin_to_hex(field_value) |> (fn {:ok, val} -> val end).()
      end

    field_value = field_value |> Util.truncate_string(max_length)

    {Map.put_new(accum, position, field_value), data_remaining}
  end

  def extract_field({position, {length_header, _data_type, max_length}}, {accum, iso_msg}, :ascii) do
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

  def extract_field({position, {length_header, data_type, max_length}}, {accum, iso_msg}, :bcd) do
    length_header =
      length_header
      |> div(2)
      |> Util.make_even()

    <<field_size::binary-size(length_header)>> <> data_remaining1 = iso_msg

    {field_sz, _} = field_size |> Base.encode16() |> Integer.parse()

    {:ok, field_sz} =
      case data_type do
        :bcd -> Util.get_bcd_length(field_sz)
        :ascii -> {:ok, field_sz}
        :binary -> {:ok, field_sz}
      end

    <<field_value::binary-size(field_sz)>> <> data_remaining = data_remaining1

    {:ok, field_value} =
      case data_type do
        :bcd -> Util.convert_bin_to_hex(field_value)
        :ascii -> {:ok, field_value}
        :binary -> Util.convert_bin_to_hex(field_value)
      end

    truncate_length =
      cond do
        field_sz > max_length -> max_length
        true -> field_sz
      end

    <<field_value::binary-size(truncate_length)>> <> _ = field_value

    {Map.put_new(accum, position, field_value), data_remaining}
  end
end
