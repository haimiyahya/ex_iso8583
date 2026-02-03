defmodule IsoField do
  @moduledoc """
  Low-level ISO 8583 field formatting and extraction functions.

  This module handles the binary-level encoding and decoding of individual ISO 8583
  fields, including variable-length field headers, data type conversions (BCD, ASCII,
  binary, Track 2), and padding logic.

  ## Field Format Tuple

  Fields are represented as 4-element tuples:
  - `{header_size, data_type, max_length, padding_override}`

  ### Components

  - `header_size`: Number of digits in the length header (0 for fixed-length fields)
  - `data_type`: One of `:bcd`, `:ascii`, `:hex`, `:binary`, or `:z` (Track 2)
  - `max_length`: Maximum length of the field value
  - `padding_override`: Optional padding configuration or `nil`

  ## Data Types

  | Type   | Description                                 | Example                    |
  |--------|---------------------------------------------|----------------------------|
  | `:bcd` | Binary Coded Decimal (numeric, hex-encoded) | `"123456"` → `0x123456`    |
  | `:ascii`| ASCII alphanumeric string                   | `"ABC123"`                 |
  | `:hex`  | Hexadecimal string                           | `"1A2B3C"`                 |
  | `:binary`| Raw binary data                            | `<<1, 2, 3>>`              |
  | `:z`    | Track 2 data (ISO/IEC 7813)                  | `"1234567890123456=1234"`  |

  ## Examples

  ### Forming a field with BCD encoding

      field_format = {2, :bcd, 19, nil}
      field_value = "1234567890123456789"
      header_type = :bcd

      IsoField.form_field({2, field_format}, field_value, header_type)
      # Returns: <<0x13, 0x19, ...>> (length header + BCD-encoded data)

  ### Extracting a field from a message

      field_format = {2, :bcd, 19, nil}
      iso_msg = <<0x13, 0x19, 0x12, 0x34, 0x56...>>  # Header + data
      accum = %{}

      {result, remaining} = IsoField.extract_field({2, field_format}, {accum, iso_msg}, :bcd)
      # result: %{2 => "1234567890123456789"}

  ## Padding Behavior

  Padding is applied based on the following priority:
  1. Variable-length fields (header_size > 0): No padding
  2. Explicit padding override in field format
  3. Message type default padding configuration
  4. Legacy behavior (backward compatibility)

  """

  @type field_format :: {non_neg_integer(), data_type(), pos_integer(), padding_config() | nil}
  @type data_type :: :bcd | :ascii | :hex | :binary | :z
  @type padding_config :: %{
    char: String.t(),
    direction: :left | :right
  } | false
  @type field_position :: pos_integer()
  @type accumulator :: %{field_position() => String.t()}
  @type iso_message :: binary()
  @type field_result :: {accumulator(), iso_message()}

  @doc """
  Forms an ISO 8583 field with header and body (with padding support).

  This is the main function for creating encoded field data. It generates
  the length header (if applicable) and encodes the field value according
  to the data type and padding configuration.

  ## Parameters
    - `{position, field_format}`: Tuple containing field number and format specification
    - `field_value`: The string value to encode
    - `field_header_type`: `:bcd` or `:ascii` - how the length header is encoded
    - `msg_type`: Message type configuration map (may contain `:padding` settings)

  ## Returns
    - Encoded binary containing header (if variable length) + encoded field value

  ## Examples

      # Fixed-length numeric field
      format = {0, :bcd, 6, nil}
      IsoField.form_field({3, format}, "123456", :bcd, %{})
      # => <<0x12, 0x34, 0x56>>

      # Variable-length alphanumeric field with padding
      format = {2, :ascii, 19, %{char: " ", direction: :left}}
      IsoField.form_field({43, format}, "TEST", :ascii, %{})
      # => <<0, 16>> <> "TEST" (header: 16 bytes, padded left)

  """
  @spec form_field({field_position(), field_format()}, String.t(), :bcd | :ascii, map()) :: binary()
  def form_field({_position, field_format}, field_value, field_header_type, msg_type) do
    header = form_field_header(field_format, field_value, field_header_type)
    body = form_field_value(field_format, field_value, field_header_type, msg_type)

    header <> body
  end

  @doc """
  Forms an ISO 8583 field (backward compatible without msg_type).

  This function is provided for backward compatibility. It uses default
  padding behavior instead of msg_type-specific configuration.

  ## Parameters
    - `{position, field_format}`: Tuple containing field number and format specification
    - `field_value`: The string value to encode
    - `field_header_type`: `:bcd` or `:ascii` - how the length header is encoded

  ## Returns
    - Encoded binary containing header (if variable length) + encoded field value

  ## Examples

      format = {2, :bcd, 19, nil}
      IsoField.form_field({2, format}, "1234567890", :bcd)
      # => <<0x0A, 0x12, 0x34, 0x56, 0x78, 0x90>>

  """
  @spec form_field({field_position(), field_format()}, String.t(), :bcd | :ascii) :: binary()
  def form_field({_position, field_format}, field_value, field_header_type) do
    header = form_field_header(field_format, field_value, field_header_type)
    body = form_field_value(field_format, field_value, field_header_type, nil)

    header <> body
  end

  @doc """
  Generates the length header for a variable-length field.

  For fixed-length fields (header_size = 0), returns an empty binary.
  For variable-length fields, encodes the field length according to the
  field_header_type (:bcd or :ascii).

  ## Parameters
    - `field_format`: Field format tuple
    - `field_value`: The field value to measure
    - `field_header_type`: `:bcd` or `:ascii` - encoding for the header

  ## Returns
    - Binary header (empty for fixed-length fields)

  """
  @spec form_field_header(field_format(), String.t(), :bcd | :ascii) :: binary()
  def form_field_header({0, _, _, _}, _, _) do
    <<>>
  end

  def form_field_header(field_format, field_value, :bcd) do
    {header_size, data_type, max_len, _padding} = get_field_format_tuple(field_format)

    size =
      case data_type do
        :bcd -> byte_size(field_value)
        :hex -> div(byte_size(field_value), 2)
        :ascii -> byte_size(field_value)
        :binary -> byte_size(field_value)
        :z ->
          cond do
            byte_size(field_value) > max_len -> max_len
            true -> byte_size(field_value)
          end
      end

    header =
      Integer.to_string(size)
      |> Util.pad_left_string(header_size, "0")
      |> Util.pad_left_string_if_odd_length("0")
      |> Base.decode16!()

    header
  end

  def form_field_header(field_format, field_value, :ascii) do
    {header_size, _data_type, max_len, _padding} = get_field_format_tuple(field_format)

    size = byte_size(field_value)

    size =
      cond do
        size > max_len -> max_len
        true -> size
      end

    header =
      Integer.to_string(size)
      |> Util.pad_left_string(header_size, "0")

    header
  end

  @doc """
  Encodes a field value according to its data type.

  Handles encoding, padding, and truncation based on the field format
  specification. Different data types are encoded differently:
  - `:bcd`: Hex-encoded after numeric sanitization and padding
  - `:hex`: Returned as-is (no transformation)
  - `:ascii`: Kept as ASCII with optional padding
  - `:binary`: Truncated to specified byte length
  - `:z`: Track 2 data with right-padding for odd length

  ## Parameters
    - `field_format`: Field format tuple
    - `field_value`: The string value to encode
    - `field_header_type`: `:bcd` or `:ascii`
    - `msg_type`: Message type configuration (for padding defaults)

  ## Returns
    - Encoded binary field value

  """
  @spec form_field_value(field_format(), String.t(), :bcd | :ascii, map() | nil) :: binary()
  def form_field_value(field_format, field_value, :bcd, msg_type) do
    {header_size, data_type, max_len, padding_override} = get_field_format_tuple(field_format)

    case data_type do
      :bcd ->
        field_value
        |> Util.truncate_string_take_left(max_len)
        |> Util.sanitize_numeric_string()
        |> apply_padding_if_needed(header_size, data_type, max_len, padding_override, msg_type)
        |> Util.pad_left_string_if_odd_length("0")
        |> Base.decode16!()

      :hex ->
        field_value

      :ascii ->
        field_value
        |> Util.truncate_string_take_left(max_len)
        |> apply_padding_if_needed(header_size, data_type, max_len, padding_override, msg_type)

      :binary ->
        bin_length =
          case byte_size(field_value) > trunc(max_len/8) do
            true -> trunc(max_len/8)
            false -> byte_size(field_value)
          end

        binary_part(field_value, 0, bin_length)

      :z ->
        field_value
        |> Util.truncate_string_take_left(max_len)
        |> apply_padding_if_needed(header_size, data_type, max_len, padding_override, msg_type)
        |> Util.pad_right_string_if_odd_length("0")
        |> Base.decode16!()
    end
  end

  def form_field_value(field_format, field_value, :ascii, msg_type) do
    {header_size, data_type, max_len, padding_override} = get_field_format_tuple(field_format)

    case data_type do
      :bcd ->
        field_value
        |> Util.truncate_string_take_left(max_len)
        |> Util.sanitize_numeric_string()
        |> apply_padding_if_needed(header_size, data_type, max_len, padding_override, msg_type)

      :ascii ->
        field_value
        |> Util.truncate_string_take_left(max_len)
        |> apply_padding_if_needed(header_size, data_type, max_len, padding_override, msg_type)

      :z ->
        field_value
        |> Util.truncate_string_take_left(max_len)
        |> apply_padding_if_needed(header_size, data_type, max_len, padding_override, msg_type)

      :binary ->
        field_value
        |> Util.truncate_string_take_left(max_len)
        |> Util.pad_left_string_if_odd_length("0")
        |> Base.decode16!()
    end
  end

  # Apply padding based on override or msg_type defaults
  @spec apply_padding_if_needed(String.t(), non_neg_integer(), data_type(), pos_integer(), padding_config() | nil, map() | nil) :: String.t()
  defp apply_padding_if_needed(value, header_size, data_type, max_len, padding_override, msg_type) do
    cond do
      # Variable length field (has header) - no padding
      header_size > 0 ->
        value

      # Padding explicitly disabled
      padding_override == false ->
        value

      # Custom padding override
      is_map(padding_override) ->
        char = Map.get(padding_override, :char) || Map.get(padding_override, "char") || " "
        direction = Map.get(padding_override, :direction) || Map.get(padding_override, "direction") || :left
        apply_padding(value, max_len, char, direction)

      # Use msg_type defaults
      msg_type != nil ->
        padding_config = get_default_padding(data_type, msg_type)
        apply_padding(value, max_len, padding_config.char, padding_config.direction)

      # Backward compatible: use old behavior
      true ->
        apply_legacy_padding(value, header_size, data_type, max_len)
    end
  end

  @spec get_default_padding(data_type(), map()) :: %{char: String.t(), direction: :left | :right}
  defp get_default_padding(:bcd, msg_type) do
    padding = get_in(msg_type, [:padding, :bcd])
    char = padding[:char] || "0"
    direction = padding[:direction] || :left
    %{char: char, direction: direction}
  end

  defp get_default_padding(:ascii, msg_type) do
    padding = get_in(msg_type, [:padding, :ascii])
    char = padding[:char] || " "
    direction = padding[:direction] || :left
    %{char: char, direction: direction}
  end

  defp get_default_padding(:z, msg_type) do
    padding = get_in(msg_type, [:padding, :z]) || get_in(msg_type, [:padding, :bcd])
    char = padding[:char] || "0"
    direction = padding[:direction] || :right
    %{char: char, direction: direction}
  end

  defp get_default_padding(_other, _msg_type) do
    %{char: " ", direction: :left}
  end

  @spec apply_padding(String.t(), pos_integer(), String.t(), :left | :right) :: String.t()
  defp apply_padding(value, max_len, char, direction) do
    case direction do
      :left -> Util.pad_string(value, max_len, char, :left)
      :right -> Util.pad_string(value, max_len, char, :right)
      _ -> Util.pad_string(value, max_len, char, :left)
    end
  end

  # Backward compatible padding behavior
  # Only apply padding if value is actually shorter than max_len
  @spec apply_legacy_padding(String.t(), non_neg_integer(), data_type(), pos_integer()) :: String.t()
  defp apply_legacy_padding(value, 0, :bcd, max_len) do
    # For BCD data type in ASCII mode, pad_left_bcd is incorrect
    # because it divides max_len by 2 for BCD byte encoding
    # We should use regular string padding instead
    value_len = byte_size(value)
    if value_len < max_len do
      Util.pad_string(value, max_len, "0", :left)
    else
      value
    end
  end

  defp apply_legacy_padding(value, 0, :ascii, max_len) do
    value_len = byte_size(value)
    if value_len < max_len do
      Util.pad_left_string(value, max_len, " ")
    else
      value
    end
  end

  defp apply_legacy_padding(value, _, _, _), do: value

  @doc """
  Extracts a field from an ISO 8583 message binary.

  Parses the field header (if present) to determine the field length,
  extracts the appropriate number of bytes, decodes according to data type,
  and returns the field value along with the remaining message data.

  ## Parameters
    - `{position, field_format_tuple}`: Field number and format specification
    - `{accum, iso_msg}`: Accumulator map and remaining message binary
    - `field_header_type`: `:bcd` or `:ascii` - how the length header is encoded

  ## Returns
    - `{updated_accum, remaining_message}`: Updated accumulator with extracted field

  ## Examples

      # Fixed-length field
      format = {0, :bcd, 6, nil}
      iso_msg = <<0x12, 0x34, 0x56, 0x78, 0x90, 0x12, 0xFF, 0xFF>>
      {result, rest} = IsoField.extract_field({3, format}, {%{}, iso_msg}, :bcd)
      # result: %{3 => "123456"}
      # rest: <<0xFF, 0xFF>>

      # Variable-length field
      format = {2, :ascii, 19, nil}  # 2-digit ASCII length header
      iso_msg = <<0x30, 0x35, 0x41, 0x42, 0x43, 0x44, 0x45>>  # "05ABCDE"
      {result, rest} = IsoField.extract_field({43, format}, {%{}, iso_msg}, :ascii)
      # result: %{43 => "ABCDE"}
      # rest: <<>>

  """
  @spec extract_field({field_position(), field_format()}, {accumulator(), iso_message()}, :bcd | :ascii) :: field_result()
  def extract_field({position, field_format_tuple}, accum_and_iso_msg, field_header_type) do
    # Convert to 4-tuple format for consistent handling
    {header_size, data_type, max_length, _padding} = get_field_format_tuple(field_format_tuple)
    extract_field_by_tuple(position, header_size, data_type, max_length, accum_and_iso_msg, field_header_type)
  end

  @doc """
  Extracts a field using the explicit tuple format.

  This is the internal implementation that handles both fixed-length
  and variable-length fields with different data type encodings.
  """
  @spec extract_field_by_tuple(field_position(), non_neg_integer(), data_type(), pos_integer(), field_result(), :bcd | :ascii) :: field_result()
  def extract_field_by_tuple(position, 0, _data_type, max_length, {accum, iso_msg}, :ascii) do
    field_length = max_length
    <<field_value::binary-size(field_length)>> <> data_remaining = iso_msg

    field_value = field_value |> Util.truncate_string(max_length)

    {Map.put_new(accum, position, field_value), data_remaining}
  end

  def extract_field_by_tuple(position, 0, data_type, max_length, {accum, iso_msg}, :bcd) do
    {:ok, field_length} =
      case data_type do
        :bcd -> Util.get_bcd_length(max_length)
        :hex -> Util.get_bcd_length(max_length)
        :ascii -> {:ok, max_length}
        :binary -> {:ok, trunc(max_length/8)}
        :z -> Util.get_bcd_length(max_length)
      end

    <<field_value::binary-size(field_length)>> <> data_remaining = iso_msg
    field_value =
      case data_type do
        :bcd -> Util.convert_bin_to_hex(field_value) |> (fn {:ok, val} -> val end).()
        :hex -> Util.convert_bin_to_hex(field_value) |> (fn {:ok, val} -> val end).()
        :ascii -> field_value
        :binary -> field_value
      end

    field_value = field_value |> Util.truncate_string(max_length)

    {Map.put_new(accum, position, field_value), data_remaining}
  end

  def extract_field_by_tuple(position, length_header, _data_type, max_length, {accum, iso_msg}, :ascii) do
    <<field_size::binary-size(length_header)>> <> data_remaining1 = iso_msg

    {field_sz, _} = field_size |> Integer.parse()

    <<field_value::binary-size(field_sz)>> <> data_remaining = data_remaining1

    truncate_length =
      cond do
        field_sz > max_length -> max_length
        true -> field_sz
      end

    <<field_value::binary-size(truncate_length)>> <> _ = field_value

    {Map.put_new(accum, position, field_value), data_remaining}
  end

  def extract_field_by_tuple(position, length_header, data_type, max_length, {accum, iso_msg}, :bcd) do
    length_header = determine_header_binary_size(length_header)
    <<field_size::binary-size(length_header)>> <> data_remaining1 = iso_msg

    {field_sz, _} = field_size |> Base.encode16() |> Integer.parse()

    {:ok, field_sz_binary} =
      case data_type do
        :bcd -> Util.get_bcd_length(field_sz)
        :ascii -> {:ok, field_sz}
        :binary -> {:ok, field_sz}
        :z -> {:ok, trunc(Util.make_even(field_sz)/2)}
      end

    <<field_value::binary-size(field_sz_binary)>> <> data_remaining = data_remaining1

    {:ok, field_value} =
      case data_type do
        :bcd -> Util.convert_bin_to_hex(field_value)
        :ascii -> {:ok, field_value}
        :binary -> {:ok, field_value}
        :z -> Util.convert_bin_to_hex(field_value)
      end

    truncate_length =
      cond do
        field_sz > max_length -> max_length
        String.length(field_value) > field_sz -> field_sz
        true -> field_sz
      end

    <<field_value::binary-size(truncate_length)>> <> _ = field_value
    {Map.put_new(accum, position, field_value), data_remaining}
  end

  @doc """
  Calculates the binary size needed for a length header.

  BCD-encoded length headers use half the number of bytes as digits,
  rounded up for odd numbers. This function calculates the appropriate
  binary size.

  ## Examples

      IsoField.determine_header_binary_size(2)  # => 1
      IsoField.determine_header_binary_size(3)  # => 2

  """
  @spec determine_header_binary_size(pos_integer()) :: pos_integer()
  def determine_header_binary_size(length_header) do
    div(length_header + rem(length_header, 2), 2)
  end

  # Handle both 3-tuple (old) and 4-tuple (new) formats
  @spec get_field_format_tuple({non_neg_integer(), data_type(), pos_integer()}) :: {non_neg_integer(), data_type(), pos_integer(), nil}
  @spec get_field_format_tuple({non_neg_integer(), data_type(), pos_integer(), any()}) :: {non_neg_integer(), data_type(), pos_integer(), any()}
  defp get_field_format_tuple({h, d, l}), do: {h, d, l, nil}
  defp get_field_format_tuple({h, d, l, p}), do: {h, d, l, p}

end
