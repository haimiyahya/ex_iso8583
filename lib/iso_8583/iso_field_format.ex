defmodule IsoFieldFormat do
  def get_field_format_list(bitmap, msg_type, field_format_definition) do


    field_header_type = msg_type[:field_header_type]

    bitmap
    |> IsoBitmap.bitmap_to_list()
    # remove first element
    |> Enum.filter(fn a -> a > 1 end)
    |> get_field_format(field_header_type, field_format_definition)
    |> Enum.map(fn {a, b} -> parse_data_element_format(a, b) end)
    |> Enum.sort_by(fn {a, _} -> a end)
  end

  # def get_field_format(list_of_bit, format) do
  #  DataElementFormat.data_element_format_def(format)
  #  |> Enum.filter(fn {position, _} -> Enum.member?(list_of_bit, position) end)
  # end

  def get_field_format(list_of_bit, _format, field_format_definition) do
    field_format_definition
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
