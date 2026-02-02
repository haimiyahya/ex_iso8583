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

  def parse_data_element_format(position, {_header_size, _data_type, _max_length} = format_tuple) do
    # Handle pre-parsed tuple format for backward compatibility
    {position, Tuple.to_list(format_tuple) ++ [nil] |> List.to_tuple()}
  end

  def parse_data_element_format(position, format) when is_binary(format) do
    # Simple string format: "n ..19", "an 12", etc.
    {length_header, data_type, max_length} = parse_format_string(format)

    padding_config = nil  # Use default from msg_type
    {position, {length_header, data_type, max_length, padding_config}}
  end

  def parse_data_element_format(position, format_definition) when is_map(format_definition) do
    # Map format: %{format: "n ..19", padding: %{char: " ", direction: :left}}
    format_string = Map.get(format_definition, :format) || Map.get(format_definition, "format")
    padding_override = Map.get(format_definition, :padding) || Map.get(format_definition, "padding")

    {length_header, data_type, max_length} = parse_format_string(format_string)

    # padding_override can be:
    # - nil: use default from msg_type
    # - false: disable padding
    # - %{char: "...", direction: :left/:right}: custom padding
    padding_config = padding_override

    {position, {length_header, data_type, max_length, padding_config}}
  end

  defp parse_format_string(format) do
    length_header =
      format
      |> (fn a ->
            if(Regex.match?(~r/\.{1,4}/, a),
              do: Regex.run(~r/\.{1,4}/, a) |> List.first(),
              else: ""
            )
          end).()
      |> String.length()

    data_type = determine_data_type(format)

    max_length =
      format
      |> (fn a ->
            if(Regex.match?(~r/\d+[b]*$/, a),
              do: Regex.run(~r/\d+[b]*$/, a) |> List.first(),
              else: ""
            )
          end).()
      |> Util.sanitize_and_convert_string_to_int()

    {length_header, data_type, max_length}
  end

  defp determine_data_type(format) do
    cond do
      Regex.match?(~r/z/i, format) -> :z
      Regex.match?(~r/b/, format) and not Regex.match?(~r/bcd/i, format) -> :binary
      Regex.match?(~r/a/, format) and not Regex.match?(~r/n/, format) -> :ascii
      Regex.match?(~r/n/, format) -> :bcd
      true -> :ascii  # default fallback
    end
  end
end
