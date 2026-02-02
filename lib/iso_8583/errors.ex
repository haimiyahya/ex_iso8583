defmodule Ex_Iso8583.Errors do
  @moduledoc """
  Custom exception types for ISO 8583 processing errors.

  This module defines specific exception types that can be pattern matched
  for more precise error handling.

  ## Examples

      try do
        Ex_Iso8583.form_iso_msg(data, msg_type, field_format)
      rescue
        e in Ex_Iso8583.Errors.UndefinedFieldError ->
          IO.puts("Field not defined: " <> inspect(e.fields))
        e in Ex_Iso8583.Errors.InvalidFieldValueError ->
          IO.puts("Invalid value for field: " <> inspect(e.reason))
      end
  """

  @type field_number :: pos_integer()

  # ============================================================================
  # UndefinedFieldError
  # ============================================================================

  defmodule UndefinedFieldError do
    @moduledoc """
    Raised when a field is not defined in field_format_definition.

    This error occurs when trying to build or parse a message containing
    fields that haven't been configured with a format definition.
    """
    defexception [:message, :fields, :defined_fields]

    @impl true
    def exception(fields: fields, defined_fields: defined_fields) do
      sorted_fields = Enum.sort(fields)

      # Use custom formatting to avoid charlist representation
      fields_str = format_field_list(sorted_fields)
      defined_str = format_field_list(Enum.sort(defined_fields))

      message = """
      Undefined field(s) in message: #{fields_str}

      The following fields are not defined in field_format_definition:
      #{fields_str}

      Please add format definitions for these fields:

      #{Enum.map(sorted_fields, fn field -> "  #{field} => \"format_definition\"" end) |> Enum.join("\n")}

      Current defined fields: #{defined_str}
      """

      %__MODULE__{
        message: message,
        fields: fields,
        defined_fields: defined_fields
      }
    end

    defp format_field_list(list) when is_list(list) do
      "[" <> Enum.map_join(list, ", ", &Integer.to_string/1) <> "]"
    end
  end

  # ============================================================================
  # InvalidFormatError
  # ============================================================================

  defmodule InvalidFormatError do
    @moduledoc """
    Raised when a field format string is invalid.

    This error occurs when a format definition string doesn't match
    the expected pattern (e.g., "n ..19", "an 12", "z ..37").
    """
    defexception [:message, :field, :format]

    @impl true
    def exception(field: field, format: format) do
      message = """
      Invalid format definition for field #{field}: "#{format}"

      Expected format pattern: "[anzb][ .]{0,4}[0-9]+[b]?"

      Examples:
        - "n 6"         : Fixed 6-digit numeric (BCD)
        - "n ..19"      : Variable numeric, max 19 digits, 2-digit length header
        - "an ..15"     : Variable alphanumeric, max 15 chars, 2-digit header
        - "z ..37"      : Track 2 data, variable max 37
        - "b 64"        : Binary data, fixed 64 bytes
      """

      %__MODULE__{
        message: message,
        field: field,
        format: format
      }
    end
  end

  # ============================================================================
  # InvalidFieldValueError
  # ============================================================================

  defmodule InvalidFieldValueError do
    @moduledoc """
    Raised when a field value doesn't match its expected format.

    This error occurs when a field value contains invalid characters
    or doesn't conform to the data type constraints.
    """
    defexception [:message, :field, :value, :reason]

    @impl true
    def exception(field: field, value: value, reason: reason) do
      message = """
      Invalid value for field #{field}: #{inspect(value)}

      Reason: #{reason}

      Please ensure the value matches the field's data type format.
      """

      %__MODULE__{
        message: message,
        field: field,
        value: value,
        reason: reason
      }
    end

    @doc """
    Create an error for non-numeric BCD field values.
    """
    def bcd_error(field, value) do
      invalid_chars =
        value
        |> String.graphemes()
        |> Enum.filter(fn char -> char not in ~w(0 1 2 3 4 5 6 7 8 9) end)
        |> Enum.uniq()
        |> Enum.join("")

      exception(
        field: field,
        value: value,
        reason: "BCD fields must contain only numeric digits (0-9). Found: #{inspect(invalid_chars)}"
      )
    end

    @doc """
    Create an error for values exceeding maximum length.
    """
    def max_length_error(field, value, max_length) do
      actual_length = String.length(value)

      exception(
        field: field,
        value: value,
        reason: "Value length (#{actual_length}) exceeds maximum allowed length (#{max_length})"
      )
    end

    @doc """
    Create an error for invalid Track 2 data.
    """
    def track2_error(field, value) do
      exception(
        field: field,
        value: value,
        reason: "Track 2 (z) fields must start with numeric digits and contain only digits, '=', 'D', or 'F'"
      )
    end
  end

  # ============================================================================
  # BitmapError
  # ============================================================================

  defmodule BitmapError do
    @moduledoc """
    Raised when bitmap parsing or processing fails.

    This error occurs when the message bitmap is malformed or cannot be processed.
    """
    defexception [:message, :reason]

    @impl true
    def exception(reason: reason) do
      message = """
      Bitmap processing failed.

      Reason: #{reason}

      The bitmap indicates which fields are present in the ISO 8583 message.
      Ensure the message is properly formatted and contains a valid bitmap.
      """

      %__MODULE__{
        message: message,
        reason: reason
      }
    end

    @doc """
    Create an error for messages that are too short to contain a bitmap.
    """
    def message_too_short(actual_size) do
      exception(
        reason: "Message is too short to contain a valid bitmap. Got #{actual_size} bytes, need at least 8 bytes for primary bitmap."
      )
    end

    @doc """
    Create an error for invalid binary data.
    """
    def invalid_binary do
      exception(reason: "Invalid binary data for bitmap processing")
    end
  end

  # ============================================================================
  # MessageLengthError
  # ============================================================================

  defmodule MessageLengthError do
    @moduledoc """
    Raised when message length is invalid or unexpected.

    This error occurs when parsing a message and the data doesn't match
    expected lengths from the bitmap and field format definitions.
    """
    defexception [:message, :expected, :actual, :field]

    @impl true
    def exception(expected: expected, actual: actual, field: field) do
      message = """
      Message length mismatch.

      #{if field do
        "Field #{field}: Expected #{expected} bytes, got #{actual} bytes."
      else
        "Message: Expected #{expected} bytes total, got #{actual} bytes."
      end}
      """

      %__MODULE__{
        message: message,
        expected: expected,
        actual: actual,
        field: field
      }
    end
  end
end
