defmodule Ex_Iso8583 do
  def extract_iso_msg(iso_msg_without_tpdu, msg_type) do
    {:ok, bitmap, msg_data} = IsoBitmap.split_bitmap_and_msg(iso_msg_without_tpdu, msg_type)

    field_format_list = get_field_format_list(bitmap, msg_type)

    {fields, _} =
      field_format_list
      |> Enum.reduce({%{}, msg_data}, fn {position, field_format}, {accum, msg_data2} ->
        IsoField.extract_field(
          {position, field_format},
          {accum, msg_data2},
          msg_type[:field_header_type]
        )
      end)

    fields
  end

  def form_iso_msg(iso_data, msg_type) do
    bitmap = IsoBitmap.create_bitmap(iso_data)

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
      |> Enum.map(fn {a, b, c} ->
        {a, IsoField.form_field({a, b}, c, msg_type[:field_header_type])}
      end)

    concatenated_fields = List.foldl(formatted_values, "", fn {_, value}, acc -> acc <> value end)

    bitmap <> concatenated_fields
  end

  def get_field_format_list(bitmap, msg_type) do
    field_header_type = msg_type[:field_header_type]

    bitmap
    |> IsoBitmap.bitmap_to_list()
    # remove first element
    |> Enum.filter(fn a -> a > 1 end)
    |> get_field_format(field_header_type)
    |> Enum.map(fn {a, b} -> parse_data_element_format(a, b) end)
    |> Enum.sort_by(fn {a, _} -> a end)
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
