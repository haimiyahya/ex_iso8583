defmodule Ex_Iso8583 do
  def extract_iso_msg(iso_msg_without_tpdu, msg_type) do
    {:ok, bitmap, msg_data} = split_bitmap_and_msg(iso_msg_without_tpdu, msg_type)

    field_format_list = get_field_format_list(bitmap, msg_type)

    {fields, _} =
      field_format_list
      |> Enum.reduce({%{}, msg_data}, fn {position, field_format}, {accum, msg_data2} ->
        extract_field({position, field_format}, {accum, msg_data2})
      end)

    fields
  end

  def form_iso_msg(iso_data, msg_type) do
    bitmap = create_bitmap(iso_data)

    field_format_list = get_field_format_list(bitmap, msg_type)

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
      |> Util.pad_left_string(header_size, "0")
      |> Util.pad_left_string_if_odd_length("0")
      |> Base.decode16!()

    header
  end

  def form_field_value({header_size, data_type, max_len} = _field_format, field_value) do
    case data_type do
      :bcd -> field_value |> Util.sanitize_numeric_string() |> Base.decode16!()
      :ascii -> field_value |> Util.check_if_required_pad_left(header_size, data_type, max_len)
      :binary -> field_value |> Util.pad_left_string_if_odd_length("0") |> Base.decode16!()
    end
  end

  def extract_field({position, {0, data_type, max_length}}, {accum, iso_msg}) do
    {:ok, field_length} =
      case data_type do
        :bcd -> Util.get_bcd_length(max_length)
        :ascii -> {:ok, max_length}
        :binary -> Util.get_bcd_length(max_length)
      end

    <<field_value::binary-size(field_length)>> <> data_remaining = iso_msg

    field_value =
      case data_type do
        :bcd -> Util.convert_bin_to_hex(field_value) |> (fn {:ok, val} -> val end).()
        :ascii -> field_value
        :binary -> Util.convert_bin_to_hex(field_value) |> (fn {:ok, val} -> val end).()
      end

    field_value = field_value |> Util.truncate_string(max_length)

    {Map.put_new(accum, position, field_value), data_remaining}
  end

  def extract_field({position, {length_header, data_type, max_length}}, {accum, iso_msg}) do
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

  def split_bitmap_and_msg(iso_msg_without_tpdu, msg_type)
      when is_binary(iso_msg_without_tpdu) and byte_size(iso_msg_without_tpdu) > 0 do
    bitmap_type = msg_type[:bitmap_type]

    iso_msg_without_tpdu
    |> transform_bitmap(bitmap_type)
    |> split_bitmap_and_msg_p
  end

  def split_bitmap_and_msg(_iso_msg_without_tpdu) do
    {:error, "Invalid Parameter"}
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

  def get_field_format_list(bitmap, msg_type) do
    field_header_type = msg_type[:field_header_type]

    bitmap
    |> bitmap_to_list
    # remove first element
    |> Enum.filter(fn a -> a > 1 end)
    |> get_field_format(field_header_type)
    |> Enum.map(fn {a, b} -> parse_data_element_format(a, b) end)
    |> Enum.sort_by(fn {a, _} -> a end)
  end

  def create_bitmap(iso_data) do
    iso_data
    |> remove_empty_or_nil
    |> Map.keys()
    |> add_remove_first_field_number
    |> list_of_fields_number_to_bit_list
    |> list_to_bitmap
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

  def get_field_format(list_of_bit, format) do
    DataElementFormat.data_element_format_def(format)
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
      |> Util.sanitize_and_convert_string_to_int()

    {position, {length_header, data_type, max_length}}
  end
end
