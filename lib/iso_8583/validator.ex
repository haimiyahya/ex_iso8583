defmodule Ex_Iso8583.Validator do
  @moduledoc """
  Validation functions for ISO 8583 field values.

  This module provides functions to validate field values before processing,
  ensuring data integrity and catching errors early.
  """

  alias Ex_Iso8583.Errors

  @type data_type :: :bcd | :ascii | :z | :binary | :hex | :ans
  @type validation_result :: :ok | {:error, String.t()}

  @doc """
  Validates a field value against its format string.

  ## Parameters
    - field: Field number
    - value: Field value to validate
    - format: Format string (e.g., "n ..19", "an 12", "z ..37") or format tuple

  ## Returns
    :ok if valid, {:error, reason} if invalid

  ## Examples

      iex> Validator.validate_field_value(3, "123456", "n 6")
      :ok

      iex> Validator.validate_field_value(3, "12a456", "n 6")
      {:error, "Field 3 must contain only digits (0-9)"}

      iex> Validator.validate_field_value(3, "123456", {2, :bcd, 6, nil})
      :ok
  """
  def validate_field_value(field, value, format) when is_binary(format) do
    with {:ok, parsed_format} <- parse_format_string(format),
         :ok <- validate_value_against_format(field, value, parsed_format) do
      :ok
    end
  end

  def validate_field_value(field, value, {_header, _data_type, _max_len, _padding} = format_tuple) do
    validate_value_against_format(field, value, format_tuple)
  end

  # Parse format string like "n ..19", "an 12", "z ..37" into components
  defp parse_format_string(format_string) do
    normalized = IsoFieldFormat.normalize_format_string(format_string)

    case Regex.run(~r/^([a-zA-Z]+)(\s*)(\.+)?(\s*)(\d+)$/, normalized) do
      [_, type_code, _dots, dots, _, max_len_str] ->
        data_type = parse_data_type(type_code)
        max_len = String.to_integer(max_len_str)
        # Determine header size based on dots (variable length indicator)
        header_size = if is_nil(dots) or dots == "", do: 0, else: String.length(dots)
        {:ok, {header_size, data_type, max_len, nil}}

      nil ->
        case Regex.run(~r/^([a-zA-Z]+)(\s*)(\.+)?(\s*)(\d+)(b)$/, normalized) do
          [_, type_code, _dots, dots, _, max_len_str, _] ->
            data_type = parse_data_type(type_code)
            max_len = String.to_integer(max_len_str)
            header_size = if is_nil(dots) or dots == "", do: 0, else: String.length(dots)
            {:ok, {header_size, data_type, max_len, nil}}

          nil ->
            {:error, "Invalid format string: #{format_string}"}
        end
    end
  end

  defp parse_data_type("n"), do: :bcd
  defp parse_data_type("N"), do: :bcd
  defp parse_data_type("a"), do: :ascii
  defp parse_data_type("A"), do: :ascii
  defp parse_data_type("an"), do: :ascii
  defp parse_data_type("AN"), do: :ascii
  defp parse_data_type("ans"), do: :ascii
  defp parse_data_type("ANS"), do: :ascii
  defp parse_data_type("z"), do: :z
  defp parse_data_type("Z"), do: :z
  defp parse_data_type("b"), do: :binary
  defp parse_data_type("B"), do: :binary
  defp parse_data_type(_), do: :ascii  # Default to ASCII for unknown types

  defp validate_value_against_format(field, value, {_header, data_type, max_len, _padding}) do
    with :ok <- validate_data_type(field, value, data_type),
         :ok <- validate_max_length_for_struct(field, value, max_len) do
      :ok
    end
  end

  defp validate_data_type(field, value, :bcd) do
    if String.match?(value, ~r/^\d+$/) do
      :ok
    else
      {:error, "Field #{field} must contain only digits (0-9)"}
    end
  end

  defp validate_data_type(field, value, :ascii) do
    if String.printable?(value) and
         String.to_charlist(value)
         |> Enum.all?(fn c -> c >= 32 and c <= 126 end) do
      :ok
    else
      {:error, "Field #{field} must contain only printable ASCII characters"}
    end
  end

  defp validate_data_type(field, value, :z) do
    cond do
      not String.match?(value, ~r/^\d/) ->
        {:error, "Field #{field} (Track 2) must start with a digit"}

      String.match?(value, ~r/^[\d=DF]*$/) ->
        :ok

      true ->
        {:error, "Field #{field} (Track 2) contains invalid characters (only 0-9, =, D, F allowed)"}
    end
  end

  defp validate_data_type(_field, _value, :binary) do
    # Binary data can be anything
    :ok
  end

  defp validate_max_length_for_struct(_field, value, max_len) do
    value_len = String.length(value)

    if value_len > max_len do
      {:error, "Value length #{value_len} exceeds maximum #{max_len}"}
    else
      :ok
    end
  end

  @doc """
  Validates a field value against its data type and constraints.

  ## Parameters
    - field: Field number
    - value: Field value to validate
    - data_type: One of :bcd, :ascii, :z, :binary, :hex
    - max_length: Maximum allowed length (optional)

  ## Returns
    :ok if valid, raises Errors.InvalidFieldValueError if invalid

  ## Examples

      iex> Validator.validate_field_value(3, "123456", :bcd, 6)
      :ok

      iex> Validator.validate_field_value(3, "12a456", :bcd, 6)
      ** (Errors.InvalidFieldValueError) ...
  """
  def validate_field_value(field, value, data_type, max_length \\ nil)

  def validate_field_value(field, value, :bcd, max_length) when is_binary(value) do
    with :ok <- validate_bcd_chars(field, value),
         :ok <- validate_max_length(field, value, max_length) do
      :ok
    end
  end

  def validate_field_value(field, value, :ascii, max_length) when is_binary(value) do
    with :ok <- validate_ascii_chars(field, value),
         :ok <- validate_max_length(field, value, max_length) do
      :ok
    end
  end

  def validate_field_value(field, value, :ans, max_length) when is_binary(value) do
    # ANS (Alphanumeric with Special) is validated same as ASCII - printable characters
    with :ok <- validate_ascii_chars(field, value),
         :ok <- validate_max_length(field, value, max_length) do
      :ok
    end
  end

  def validate_field_value(field, value, :z, max_length) when is_binary(value) do
    with :ok <- validate_track2_format(field, value),
         :ok <- validate_max_length(field, value, max_length) do
      :ok
    end
  end

  def validate_field_value(field, value, :binary, max_length) when is_binary(value) do
    validate_max_length(field, value, max_length)
  end

  def validate_field_value(field, value, :hex, max_length) when is_binary(value) do
    with :ok <- validate_hex_chars(field, value),
         :ok <- validate_max_length(field, value, max_length) do
      :ok
    end
  end

  # ============================================================================
  # BCD Validation - Only digits 0-9 allowed
  # ============================================================================

  defp validate_bcd_chars(field, value) do
    if String.match?(value, ~r/^\d+$/) do
      :ok
    else
      raise Errors.InvalidFieldValueError.bcd_error(field, value)
    end
  end

  # ============================================================================
  # ASCII Validation - Printable ASCII characters
  # ============================================================================

  defp validate_ascii_chars(_field, value) do
    if String.printable?(value) and
         String.to_charlist(value)
         |> Enum.all?(fn c -> c >= 32 and c <= 126 end) do
      :ok
    else
      {:error, "Contains non-ASCII printable characters"}
    end
  end

  # ============================================================================
  # Track 2 Validation - ISO/IEC 7813 format
  # ============================================================================

  defp validate_track2_format(field, value) do
    # Track 2 format: starts with primary account number (digits),
    # can contain '=', 'D', 'F' as separators, and discretionary data
    cond do
      # Must start with a digit (PAN - Primary Account Number)
      not String.match?(value, ~r/^\d/) ->
        raise Errors.InvalidFieldValueError,
          field: field,
          value: value,
          reason: "Track 2 data must start with a digit (Primary Account Number)"

      # Valid characters: digits, '=', 'D', 'F'
      String.match?(value, ~r/^[\d=DF]*$/) ->
        :ok

      true ->
        raise Errors.InvalidFieldValueError.track2_error(field, value)
    end
  end

  # ============================================================================
  # Hex Validation - Even-length hex string
  # ============================================================================

  defp validate_hex_chars(field, value) do
    trimmed = String.trim_leading(value, "0x")

    if String.match?(trimmed, ~r/^[0-9A-Fa-f]*$/) do
      :ok
    else
      raise Errors.InvalidFieldValueError,
        field: field,
        value: value,
        reason: "Hex fields must contain only hexadecimal characters (0-9, A-F)"
    end
  end

  # ============================================================================
  # Max Length Validation
  # ============================================================================

  defp validate_max_length(_field, _value, nil), do: :ok

  defp validate_max_length(field, value, max_length) do
    value_length = String.length(value)

    if value_length > max_length do
      raise Errors.InvalidFieldValueError.max_length_error(field, value, max_length)
    else
      :ok
    end
  end

  @doc """
  Validates that a message is not empty and has minimum required data.

  ## Parameters
    - message: Binary message to validate

  ## Returns
    :ok if valid, {:error, reason} if invalid
  """
  def validate_message(message) when is_binary(message) do
    if byte_size(message) < 8 do
      {:error, "Message too short: must be at least 8 bytes for bitmap"}
    else
      :ok
    end
  end

  def validate_message(_), do: {:error, "Message must be a binary"}

  @doc """
  Validates field format definition string.

  ## Parameters
    - field: Field number
    - format: Format string (e.g., "n ..19", "an 12")

  ## Returns
    :ok if valid, raises Errors.InvalidFormatError if invalid
  """
  def validate_format_definition(field, format) when is_binary(format) do
    # Basic validation: should match pattern like "n ..19", "an 12", "z ..37"
    # Support both single-letter (n, a, z, b) and two-letter (an) type codes
    case Regex.run(~r/^([aA][nN]?|[nN]|[zZ]|[bB])(\s*)(\.+)?(\s*)(\d+)(b)?$/, format) do
      nil ->
        raise Errors.InvalidFormatError, field: field, format: format

      _match ->
        :ok
    end
  end

  def validate_format_definition(field, _format) do
    raise Errors.InvalidFormatError,
      field: field,
      format: "invalid type (expected string)"
  end

  @doc """
  Returns a validator function for the given data type.

  Useful for creating validation pipelines.
  """
  @spec validator_for(data_type(), non_neg_integer() | nil) :: (pos_integer(), String.t() -> :ok)
  def validator_for(data_type, max_length \\ nil) do
    fn field, value -> validate_field_value(field, value, data_type, max_length) end
  end
end
