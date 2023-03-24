defmodule Ex_Iso8583 do
  def extract_iso_msg(iso_msg_without_tpdu, msg_type, field_format_definition) do
    {:ok, bitmap, msg_data} = IsoBitmap.split_bitmap_and_msg(iso_msg_without_tpdu, msg_type)

    field_format_list =
      IsoFieldFormat.get_field_format_list(bitmap, msg_type, field_format_definition)

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

  def form_iso_msg(iso_data, msg_type, field_format_definition) do

    bitmap_type = msg_type[:bitmap_type]

    bitmap = IsoBitmap.create_bitmap(iso_data)

    field_format_list =
      IsoFieldFormat.get_field_format_list(bitmap, msg_type, field_format_definition)

    bitmap = case bitmap_type do
      :ascii -> Base.encode16(bitmap)
      :binary -> bitmap
    end

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
end
