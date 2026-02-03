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

      # Build a message (without validation - applies padding/truncation)
      iso_msg = Ex_Iso8583.form_iso_msg(fields, msg_type, field_format)

      # Build a message with validation (returns {:ok, binary} or {:error, reason})
      {:ok, validated_msg} = Ex_Iso8583.form_iso_msg(fields, msg_type, field_format, validate: true)
  """

  @type field_format_definition :: %{pos_integer() => String.t() | map()}
  @type msg_type :: %{bitmap_type: :binary | :ascii, field_header_type: :bcd | :ascii, optional: padding :: map()}
  @type iso_data :: %{pos_integer() => String.t()}
  @type iso_message :: binary()
  @type field_number :: pos_integer()
  @type field_value :: String.t()

  alias Ex_Iso8583.Errors

  @doc """
  Extracts fields from an ISO 8583 binary message.

  ## Parameters
    - iso_msg_without_tpdu: Binary message (without MTI/TPDU headers)
    - msg_type: Configuration map with :bitmap_type and :field_header_type
    - field_format_definition: Map of field number to format string

  ## Returns
    Map of field numbers to their values

  ## Raises
    * `Errors.UndefinedFieldError` - if a field in the bitmap is not defined in field_format_definition
    * `Errors.BitmapError` - if the bitmap cannot be parsed
    * `Errors.MessageLengthError` - if message length is invalid
  """
  @spec extract_iso_msg(iso_message(), msg_type(), field_format_definition()) :: iso_data()
  def extract_iso_msg(iso_msg_without_tpdu, msg_type, field_format_definition) do
    {:ok, bitmap, msg_data} = IsoBitmap.split_bitmap_and_msg(iso_msg_without_tpdu, msg_type)

    # Validate that all fields in bitmap have format definitions
    bitmap_field_list = IsoBitmap.bitmap_to_list(bitmap) |> Enum.filter(&(&1 > 1))
    defined_field_numbers = Map.keys(field_format_definition)

    undefined_fields = Enum.filter(bitmap_field_list, fn field -> field not in defined_field_numbers end)

    if undefined_fields != [] do
      raise Errors.UndefinedFieldError,
        fields: undefined_fields,
        defined_fields: defined_field_numbers
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
    - opts: Keyword list of options
      - `:validate` - When true, validates field values and returns {:ok, binary} or {:error, reason}
                       When false (default), applies padding/truncation without validation

  ## Returns
    - Without validate option: Binary ISO 8583 message (bitmap + fields)
    - With validate: true: `{:ok, binary}` or `{:error, reason}`

  ## Options

    * `:validate` - Enable strict validation (default: false)
      - Validates all field values match their data type format
      - Validates field lengths are within limits (doesn't truncate)
      - Returns error tuple instead of raising

  ## Examples

      # Without validation (default - applies padding/truncation)
      iso_msg = Ex_Iso8583.form_iso_msg(fields, msg_type, field_format)

      # With validation (returns {:ok, binary} or {:error, reason})
      case Ex_Iso8583.form_iso_msg(fields, msg_type, field_format, validate: true) do
        {:ok, msg} -> msg  # Valid message
        {:error, {:invalid_field_value, field, reason}} -> handle_error()
      end

  ## Raises (when validate: false or not specified)
    * `Errors.UndefinedFieldError` - if a field in iso_data is not defined in field_format_definition
  """
  @spec form_iso_msg(iso_data(), msg_type(), field_format_definition()) :: iso_message()
  def form_iso_msg(iso_data, msg_type, field_format_definition) do
    form_iso_msg(iso_data, msg_type, field_format_definition, [])
  end

  @spec form_iso_msg(iso_data(), msg_type(), field_format_definition(), keyword()) :: iso_message() | {:ok, iso_message()} | {:error, term()}
  def form_iso_msg(iso_data, msg_type, field_format_definition, opts) do
    validate? = Keyword.get(opts, :validate, false)

    if validate? do
      form_iso_msg_with_validation(iso_data, msg_type, field_format_definition)
    else
      form_iso_msg_without_validation(iso_data, msg_type, field_format_definition)
    end
  end

  # Form message without validation (original behavior - applies padding/truncation)
  defp form_iso_msg_without_validation(iso_data, msg_type, field_format_definition) do
    # Validate that all fields in iso_data have format definitions
    defined_field_numbers = Map.keys(field_format_definition)

    undefined_fields =
      iso_data
      |> Map.keys()
      |> Enum.filter(fn field -> field not in defined_field_numbers end)

    if undefined_fields != [] do
      raise Errors.UndefinedFieldError,
        fields: undefined_fields,
        defined_fields: defined_field_numbers
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

  # Form message with validation (returns {:ok, binary} or {:error, reason})
  defp form_iso_msg_with_validation(iso_data, msg_type, field_format_definition) do
    # Validate that all fields in iso_data have format definitions
    defined_field_numbers = Map.keys(field_format_definition)

    undefined_fields =
      iso_data
      |> Map.keys()
      |> Enum.filter(fn field -> field not in defined_field_numbers end)

    with :ok <- validate_undefined_fields(undefined_fields, defined_field_numbers),
         :ok <- validate_all_field_values(iso_data, field_format_definition) do
      # All validations passed, form the message
      form_validated_message(iso_data, msg_type, field_format_definition)
    end
  end

  defp validate_undefined_fields([], _defined), do: :ok
  defp validate_undefined_fields(undefined_fields, defined_fields) do
    {:error, {:undefined_fields, undefined_fields, defined_fields}}
  end

  defp validate_all_field_values(iso_data, field_format_definition) do
    Enum.reduce_while(iso_data, :ok, fn {field_num, value}, _acc ->
      format = Map.get(field_format_definition, field_num)

      case Ex_Iso8583.Validator.validate_field_value(field_num, value, format) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:invalid_field_value, field_num, reason}}}
      end
    end)
  end

  defp form_validated_message(iso_data, msg_type, field_format_definition) do
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

    {:ok, bitmap <> concatenated_fields}
  end
end
