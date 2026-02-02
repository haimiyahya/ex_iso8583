defmodule IsoFieldFormat do
  @moduledoc """
  Parses ISO 8583 field format definitions.

  Supports multiple format notations:
  - Dot notation: "n ..19", "an ..12", "z ..37"
  - LLVAR notation: "n LLVAR 19", "an LLVAR 12"
  - LLLVAR notation: "n LLLVAR 999", "an LLLVAR 999"
  - Map format with padding override: %{format: "n ..19", padding: %{char: " ", direction: :left}}

  ## Length Header Sizes
  - Fixed (no header): `n 6` (fixed 6 digits)
  - LVAR (1-digit header): `n .6` (variable, max 6, 1-digit length)
  - LLVAR (2-digit header): `n ..19` or `n LLVAR 19` (variable, max 19, 2-digit length)
  - LLLVAR (3-digit header): `n ...999` or `n LLLVAR 999` (variable, max 999, 3-digit length)
  - LLLLVAR (4-digit header): `n ....9999` (variable, max 9999, 4-digit length)
  """

  @doc """
  Gets the list of field formats present in the message based on the bitmap.
  """
  def get_field_format_list(bitmap, msg_type, field_format_definition) do
    field_header_type = msg_type[:field_header_type]

    bitmap
    |> IsoBitmap.bitmap_to_list()
    |> Enum.filter(fn a -> a > 1 end)
    |> get_field_format(field_header_type, field_format_definition)
    |> Enum.map(fn {a, b} -> parse_data_element_format(a, b) end)
    |> Enum.sort_by(fn {a, _} -> a end)
  end

  def get_field_format(list_of_bit, _format, field_format_definition) do
    field_format_definition
    |> Enum.filter(fn {position, _} -> Enum.member?(list_of_bit, position) end)
  end

  @doc """
  Parses a field format definition.

  Supports three formats:
  1. Pre-parsed tuple: `{header_size, data_type, max_length}`
  2. String format: `"n ..19"`, `"an 12"`, etc.
  3. Map format with padding: `%{format: "n ..19", padding: %{char: " ", direction: :left}}`

  Returns `{position, {header_size, data_type, max_length, padding_config}}`
  """
  def parse_data_element_format(position, {_h, _d, _l} = format_tuple) do
    # Handle pre-parsed tuple format for backward compatibility
    {position, Tuple.to_list(format_tuple) ++ [nil] |> List.to_tuple()}
  end

  def parse_data_element_format(position, format) when is_binary(format) do
    {length_header, data_type, max_length} = parse_format_string(format)
    {position, {length_header, data_type, max_length, nil}}
  end

  def parse_data_element_format(position, format_definition) when is_map(format_definition) do
    format_string = Map.get(format_definition, :format) || Map.get(format_definition, "format")
    padding_override = Map.get(format_definition, :padding) || Map.get(format_definition, "padding")

    {length_header, data_type, max_length} = parse_format_string(format_string)
    {position, {length_header, data_type, max_length, padding_override}}
  end

  defp parse_format_string(format) do
    normalized = normalize_format_string(format)
    length_header = extract_length_header(normalized)
    data_type = extract_data_type(normalized)
    max_length = extract_max_length(normalized)
    {length_header, data_type, max_length}
  end

  @doc """
  Normalizes format strings to convert LLVAR/LLLVAR notation to dot notation.
  """
  def normalize_format_string(format) when is_binary(format) do
    format_upcase = String.upcase(format)

    cond do
      # Handle LLVAR notation (2-digit length header)
      Regex.match?(~r/\bLLVAR\b/, format_upcase) ->
        Regex.replace(~r/\bLLVAR\b/, format_upcase, "..")

      # Handle LLLVAR notation (3-digit length header)
      Regex.match?(~r/\bLLLVAR\b/, format_upcase) ->
        Regex.replace(~r/\bLLLVAR\b/, format_upcase, "...")

      # Handle LLLLVAR notation (4-digit length header)
      Regex.match?(~r/\bLLLLVAR\b/, format_upcase) ->
        Regex.replace(~r/\bLLLLVAR\b/, format_upcase, "....")

      # Handle LVAR notation (1-digit length header)
      Regex.match?(~r/\bLVAR\b/, format_upcase) ->
        Regex.replace(~r/\bLVAR\b/, format_upcase, ".")

      true ->
        format
    end
  end

  defp extract_length_header(format) do
    case Regex.run(~r/\.{1,4}/, format) do
      nil -> 0
      dots -> dots |> hd() |> String.length()
    end
  end

  defp extract_max_length(format) do
    case Regex.run(~r/\d+[b]*$/, format) do
      nil -> 0
      match -> match |> hd() |> Util.sanitize_and_convert_string_to_int()
    end
  end

  defp extract_data_type(format) do
    data_type = nil

    data_type =
      if data_type == nil and Regex.match?(~r/a/i, format), do: :ascii, else: data_type

    data_type =
      if data_type == nil and Regex.match?(~r/n/i, format), do: :bcd, else: data_type

    data_type =
      if data_type == nil and Regex.match?(~r/z/i, format), do: :z, else: data_type

    data_type =
      if data_type == nil and Regex.match?(~r/b/i, format), do: :binary, else: data_type

    data_type || :ascii
  end
end
