defmodule Ex_Iso8583 do
  require Integer

  def extract_iso_msg(iso_msg_without_tpdu) do
    {:ok, bitmap, msg_data} = split_bitmap_and_msg(iso_msg_without_tpdu)

    field_format_list = get_field_format_list(bitmap)

    {fields, _} =
      field_format_list
      |> Enum.reduce({%{}, msg_data}, fn {position, field_format}, {accum, msg_data2} ->
        extract_field({position, field_format}, {accum, msg_data2})
      end)

    fields
  end

  def form_field(iso_data) do
    bitmap = create_bitmap(iso_data)

    field_format_list = get_field_format_list(bitmap)

    field_data_values =
      Map.to_list(iso_data)
      |> Enum.sort_by(fn {a, _} -> a end)

    field_format_and_values =
      for {{position, format}, {_, value}} <- Enum.zip(field_format_list, field_data_values) do
        {position, format, value}
      end

    # example output = [{1, {0, true, 12}, "10"}, {2, {0, true, 30}, "88888"}]

    formatted_values =
      field_format_and_values
      # will return {a, formatted_field}
      |> Enum.map(fn {a, b, c} -> {a, form_data_field(a, b, c)} end)

    concatenated_fields = List.foldl(formatted_values, "", fn {_, value}, acc -> acc <> value end)

    bitmap <> concatenated_fields
  end

  def form_data_field(_position, field_format, field_value) do
    header = form_field_header(field_format, field_value)
    body = form_field_value(field_format, field_value)
    header <> body
  end

  def form_field_header({0, _, _} = _field_format, _) do
    <<>>
  end

  def form_field_header({header_size, data_type, _max_len} = _field_format, field_value) do
    size =
      case data_type do
        :bcd ->
          div(byte_size(field_value), 2)

        :ascii ->
          byte_size(field_value)
          # todo: put the binary handler here
      end

    header =
      Integer.to_string(size)
      |> pad_left_string(header_size, "0")
      |> pad_left_string_if_odd_length("0")
      |> Base.decode16!()

    header
  end

  def form_field_value({header_size, data_type, max_len} = _field_format, field_value) do
    case data_type do
      :bcd -> field_value |> sanitize_numeric_string |> Base.decode16!()
      :ascii -> field_value |> check_if_required_pad_left(header_size, data_type, max_len)
      :binary -> field_value |> pad_left_string_if_odd_length("0") |> Base.decode16!()
    end
  end

  def extract_field({position, {0, data_type, max_length}}, {accum, iso_msg}) do
    {:ok, field_length} =
      case data_type do
        :bcd -> get_bcd_length(max_length)
        :ascii -> {:ok, max_length}
        :binary -> get_bcd_length(max_length)
      end

    <<field_value::binary-size(field_length)>> <> data_remaining = iso_msg

    field_value =
      case data_type do
        :bcd -> convert_bin_to_hex(field_value) |> (fn {:ok, val} -> val end).()
        :ascii -> field_value
        :binary -> convert_bin_to_hex(field_value) |> (fn {:ok, val} -> val end).()
      end

    {Map.put_new(accum, position, field_value), data_remaining}
  end

  def extract_field({position, {length_header, data_type, max_length}}, {accum, iso_msg}) do
    length_header =
      length_header
      |> div(2)
      |> make_even

    <<field_size::binary-size(length_header)>> <> data_remaining1 = iso_msg

    {field_sz, _} = field_size |> Base.encode16() |> Integer.parse()

    {:ok, field_sz} =
      case data_type do
        :bcd -> get_bcd_length(field_sz)
        :ascii -> {:ok, field_sz}
        :binary -> {:ok, field_sz}
      end

    <<field_value::binary-size(field_sz)>> <> data_remaining = data_remaining1

    {:ok, field_value} =
      case data_type do
        :bcd -> convert_bin_to_hex(field_value)
        :ascii -> {:ok, field_value}
        :binary -> convert_bin_to_hex(field_value)
      end

    truncate_length =
      cond do
        field_sz > max_length -> max_length
        true -> field_sz
      end

    <<field_value::binary-size(truncate_length)>> <> _ = field_value

    {Map.put_new(accum, position, field_value), data_remaining}
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

  def split_bitmap_and_msg(iso_msg_without_tpdu) do
    case check_binary_is_not_empty(iso_msg_without_tpdu) do
      true -> split_bitmap_and_msg_p(iso_msg_without_tpdu)
      false -> {:error, "Invalid Parameter"}
    end
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

  def bitmap_to_list(bitmap) do
    case is_binary(bitmap) do
      true ->
        for(<<r::1 <- bitmap>>, do: r)
        |> Enum.with_index(1)
        |> Enum.map(fn {a, b} -> {b, a} end)
        # remove first element
        |> Enum.filter(fn {a, _} -> a > 1 end)
        # remove field where the bit was not set
        |> Enum.filter(fn {_, b} -> b == 1 end)
        |> Enum.map(fn {a, _} -> a end)

      false ->
        []
    end
  end

  def get_field_format_list(bitmap) do
    bitmap
    |> bitmap_to_list
    |> get_field_format
    |> Enum.map(fn {a, b} -> parse_data_element_format(a, b) end)
    |> Enum.sort_by(fn {a, _} -> a end)
  end

  def create_bitmap(iso_data) do
    iso_data
    |> remove_empty_or_nil
    |> Map.keys()
    |> add_remove_first_bit
    |> list_of_bits
    |> list_to_bitmap
  end

  def remove_empty_or_nil(iso_data) do
    iso_data
    |> Enum.filter(fn {_, v} -> v != nil end)
    |> Enum.filter(fn {_, v} -> v != "" end)
    |> Enum.into(%{})
  end

  def add_remove_first_bit(list) do
    cond do
      Enum.max(list) > 64 and Enum.member?(list, 1) == false -> [1] ++ list
      Enum.max(list) < 64 and Enum.member?(list, 1) == true -> list -- [1]
      true -> list
    end
  end

  def list_of_bits(list) do
    max_bit =
      case list |> Enum.max() > 64 do
        true -> 128
        false -> 64
      end

    Enum.map(1..max_bit, fn a -> if(Enum.member?(list, a), do: 1, else: 0) end)
    # for a <- 
    # for n <- 1..max_bit, do: case Enum.member?(list, n), do: 1; else: 0 end end 
  end

  def list_to_bitmap(list) do
    case length(list) > 0 do
      true -> for i <- list, do: <<i::1>>, into: <<>>
      false -> <<0>>
    end
  end

  def get_field_format(list_of_bit) do
    ISODataElementFormat.iso_data_element_format_def(false)
    |> Enum.filter(fn {position, _} -> Enum.member?(list_of_bit, position) end)
  end

  def parse_data_element_format(position, format) do
    length_header =
      format
      |> (fn a ->
            if(Regex.match?(~r/\.{1,4}/, a),
              do: Regex.run(~r/\.{1,4}/, a) |> List.first(),
              else: ""
            )
          end).()
      |> String.length()

    data_type = nil

    data_type =
      case data_type == nil and Regex.match?(~r/a/, format) do
        true -> :ascii
        false -> data_type
      end

    data_type =
      case data_type == nil and Regex.match?(~r/n/, format) do
        true -> :bcd
        false -> data_type
      end

    data_type =
      case data_type == nil and Regex.match?(~r/b/, format) do
        true -> :binary
        false -> data_type
      end

    max_length =
      format
      |> (fn a ->
            if(Regex.match?(~r/\d+[b]*$/, a),
              do: Regex.run(~r/\d+[b]*$/, a) |> List.first(),
              else: ""
            )
          end).()
      |> sanitize_and_convert_string_to_int

    {position, {length_header, data_type, max_length}}
  end

  defp check_binary_is_not_empty(val) do
    is_binary(val) and byte_size(val) > 0
  end
end
