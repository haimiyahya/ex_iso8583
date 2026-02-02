defmodule Ex_Iso8583 do
  @moduledoc """
  Main API for ISO 8583 message parsing and formatting.

  ## Example

      # Define message type and field formats
      msg_type = %{bitmap_type: :binary, field_header_type: :bcd}

      field_format = %{
        2 => "n ..19",
        3 => "n 6",
        4 => "n 12",
        35 => "z ..37"
      }

      # Parse a message
      fields = Ex_Iso8583.extract_iso_msg(raw_msg, msg_type, field_format)

      # Build a message
      iso_msg = Ex_Iso8583.form_iso_msg(fields, msg_type, field_format)
  """

  @type field_format_definition :: %{pos_integer() => String.t() | map()}

  @doc """
  Extracts fields from an ISO 8583 binary message.

  ## Parameters
    - iso_msg_without_tpdu: Binary message (without MTI/TPDU headers)
    - msg_type: Configuration map with :bitmap_type and :field_header_type
    - field_format_definition: Map of field number to format string

  ## Returns
    Map of field numbers to their values

  ## Raises
    `RuntimeError` - if a field in the bitmap is not defined in field_format_definition
  """
  def extract_iso_msg(iso_msg_without_tpdu, msg_type, field_format_definition) do
    {:ok, bitmap, msg_data} = IsoBitmap.split_bitmap_and_msg(iso_msg_without_tpdu, msg_type)

    # Validate that all fields in bitmap have format definitions
    bitmap_field_list = IsoBitmap.bitmap_to_list(bitmap) |> Enum.filter(&(&1 > 1))
    defined_field_numbers = Map.keys(field_format_definition)

    undefined_fields = Enum.filter(bitmap_field_list, fn field -> field not in defined_field_numbers end)

    if undefined_fields != [] do
      raise RuntimeError, """
      Undefined field(s) in message: #{inspect(undefined_fields)}

      The following fields from the message bitmap are not defined in field_format_definition:
      #{inspect(undefined_fields)}

      Please add format definitions for these fields:

      #{Enum.map(undefined_fields, fn field -> "  #{field} => \"format_definition\"" end) |> Enum.join("\n")}

      Current field_format_definition keys: #{inspect(Map.keys(field_format_definition))}
      """
    end

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

  @doc """
  Builds an ISO 8583 binary message from a field map.

  ## Parameters
    - iso_data: Map of field numbers to their values
    - msg_type: Configuration map with :bitmap_type and :field_header_type
    - field_format_definition: Map of field number to format string

  ## Returns
    Binary ISO 8583 message (bitmap + fields)

  ## Raises
    `RuntimeError` - if a field in iso_data is not defined in field_format_definition
  """
  def form_iso_msg(iso_data, msg_type, field_format_definition) do
    # Validate that all fields in iso_data have format definitions
    undefined_fields =
      iso_data
      |> Map.keys()
      |> Enum.filter(fn field -> field not in Map.keys(field_format_definition) end)

    if undefined_fields != [] do
      raise RuntimeError, """
      Undefined field(s) in data: #{inspect(undefined_fields)}

      The following fields from iso_data are not defined in field_format_definition:
      #{inspect(undefined_fields)}

      Please add format definitions for these fields:

      #{Enum.map(undefined_fields, fn field -> "  #{field} => \"format_definition\"" end) |> Enum.join("\n")}

      Current field_format_definition keys: #{inspect(Map.keys(field_format_definition))}
      """
    end

    bitmap_type = msg_type[:bitmap_type]
    bitmap = IsoBitmap.create_bitmap(iso_data)

    field_format_list =
      IsoFieldFormat.get_field_format_list(bitmap, msg_type, field_format_definition)

    bitmap =
      case bitmap_type do
        :ascii -> Base.encode16(bitmap)
        :binary -> bitmap
      end

    field_data_values =
      iso_data
      |> Map.to_list()
      |> Enum.sort_by(fn {a, _} -> a end)

    field_format_and_values =
      for {{position, format}, {_, value}} <- Enum.zip(field_format_list, field_data_values) do
        {position, format, value}
      end

    formatted_values =
      Enum.map(field_format_and_values, fn {a, b, c} ->
        {a, IsoField.form_field({a, b}, c, msg_type[:field_header_type], msg_type)}
      end)

    concatenated_fields =
      Enum.reduce(formatted_values, "", fn {_, value}, acc -> acc <> value end)

    bitmap <> concatenated_fields
  end
end
