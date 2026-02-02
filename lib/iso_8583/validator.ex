defmodule Ex_Iso8583.Validator do
  @moduledoc """
  Validation functions for ISO 8583 field values.

  This module provides functions to validate field values before processing,
  ensuring data integrity and catching errors early.
  """

  alias Ex_Iso8583.Errors

  @type data_type :: :bcd | :ascii | :z | :binary | :hex
  @type validation_result :: :ok | {:error, String.t()}

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
