defmodule Util do
  @moduledoc """
  Utility functions for ISO 8583 message processing.

  Provides helper functions for string manipulation, BCD encoding/decoding,
  and data sanitization.

  ## Functions

  - Padding: `pad_string/4`, `pad_left_string/3`, `pad_left_bcd/2`
  - Length handling: `pad_left_string_if_odd_length/2`, `pad_right_string_if_odd_length/2`, `make_even/1`
  - Data sanitization: `sanitize_numeric_string/1`
  - Type conversion: `convert_bin_to_hex/1`, `sanitize_and_convert_string_to_int/1`
  - Length calculation: `get_bcd_length/1`
  - Truncation: `truncate_string/2`, `truncate_string_take_left/2`, `take_first_bytes/2`

  ## Examples

      # Pad a string to a specific length
      Util.pad_string("123", 6, "0", :left)
      # => "000123"

      # Sanitize numeric string (remove non-digits)
      Util.sanitize_numeric_string("12a34b56")
      # => "123456"

      # Convert binary to hex
      Util.convert_bin_to_hex!(<<0x12, 0x34>>)
      # => "1234"

  """

  require Integer

  @type padding_direction :: :left | :right

  @doc """
  Flexible padding function supporting both left and right padding.

  Pads the input value to the specified size using the given padding character
  and direction. If the value is longer than the target size, it is truncated
  from the appropriate side.

  ## Parameters
    - `value`: The string to pad
    - `size`: Target size in bytes
    - `padding_char`: Character to use for padding (single character string)
    - `direction`: `:left` or `:right` - which side to pad on

  ## Returns
    - Padded (or truncated) string

  ## Examples

      iex> Util.pad_string("abc", 5, "0", :left)
      "00abc"

      iex> Util.pad_string("abc", 5, " ", :right)
      "abc  "

      iex> Util.pad_string("abcdef", 4, "0", :left)
      "cdef"

      iex> Util.pad_string("abcd", 4, "0", :left)
      "abcd"

  """
  @spec pad_string(binary(), pos_integer(), String.t(), padding_direction()) :: binary()
  def pad_string(value, size, padding_char, direction \\ :left) when is_binary(value) do
    value_len = byte_size(value)

    cond do
      value_len < size ->
        padding_count = size - value_len
        padding = String.duplicate(padding_char, padding_count)

        case direction do
          :right -> value <> padding
          _ -> padding <> value
        end

      value_len > size ->
        String.slice(value, byte_size(value) - size, size)

      true ->
        value
    end
  end

  @doc """
  Checks if padding is required and applies BCD-specific padding.

  For BCD fields with no header (fixed length), applies BCD padding rules.
  For fields with a header, returns the value unchanged.

  ## Parameters
    - `value`: The value to potentially pad
    - `header_size`: Size of the length header (0 for fixed-length)
    - `data_type`: `:bcd` or `:ascii`
    - `max_len`: Maximum length for the field

  ## Returns
    - Padded or original value

  """
  @spec check_if_required_pad_left(String.t(), non_neg_integer(), :bcd | :ascii, pos_integer()) :: String.t()
  def check_if_required_pad_left(value, 0, :bcd, max_len) do
    pad_left_bcd(value, max_len)
  end

  def check_if_required_pad_left(value, 0, :ascii, max_len) do
    pad_left_string(value, max_len, " ")
  end

  def check_if_required_pad_left(value, _, :bcd, _max_len) do
    value
  end

  def check_if_required_pad_left(value, _, :ascii, _max_len) do
    value
  end

  @doc """
  Applies BCD (Binary Coded Decimal) padding to the left of a value.

  BCD padding adds zero bytes (`<<0>>`) to the left side of the binary.
  The max_len is divided by 2 since BCD packs 2 digits per byte.

  ## Parameters
    - `value`: The binary value to pad
    - `max_len`: Maximum length in nibbles (will be halved for byte length)

  ## Returns
    - Padded binary value

  ## Examples

      iex> Util.pad_left_bcd(<<0x12, 0x34>>, 8)
      <<0x00, 0x12, 0x34>>

  """
  @spec pad_left_bcd(binary(), pos_integer()) :: binary()
  def pad_left_bcd(value, max_len) do
    max_len = div(max_len, 2)

    cond do
      byte_size(value) < max_len ->
        for(_i <- 1..(max_len - byte_size(value))//1, do: <<0>>, into: <<>>) <> value

      byte_size(value) > max_len ->
        :binary.part(value, byte_size(value) - max_len, max_len)

      byte_size(value) == max_len ->
        value
    end
  end

  @doc """
  Pads a string to the left with the given padding string.

  ## Parameters
    - `value`: The string to pad
    - `size`: Target size in bytes
    - `padding_string`: String to use for padding (typically "0" or " ")

  ## Returns
    - Left-padded string

  ## Examples

      iex> Util.pad_left_string("123", 6, "0")
      "000123"

  """
  @spec pad_left_string(String.t(), pos_integer(), String.t()) :: String.t()
  def pad_left_string(value, size, padding_string) do
    cond do
      byte_size(value) < size ->
        for(_i <- 1..(size - byte_size(value))//1, do: padding_string, into: "") <> value

      byte_size(value) > size ->
        String.slice(value, byte_size(value) - size, size)

      byte_size(value) == size ->
        value
    end
  end

  @doc """
  Removes all non-numeric characters from a string.

  Useful for sanitizing input that should contain only digits.

  ## Parameters
    - `field_value`: The string to sanitize

  ## Returns
    - String containing only digits (0-9)

  ## Examples

      iex> Util.sanitize_numeric_string("12a34b56")
      "123456"

      iex> Util.sanitize_numeric_string("ABC-123-456")
      "123456"

  """
  @spec sanitize_numeric_string(String.t()) :: String.t()
  def sanitize_numeric_string(field_value) do
    field_value
    |> String.replace(~r/[^\d]/, "")
  end

  @doc """
  Pads a string to the left if its length is odd.

  Used to ensure strings have even length for BCD encoding,
  which requires an even number of digits.

  ## Parameters
    - `field_value`: The string to potentially pad
    - `padding_char`: Character to use for padding (typically "0")

  ## Returns
    - Padded string if odd length, original string if even length

  ## Examples

      iex> Util.pad_left_string_if_odd_length("123", "0")
      "0123"

      iex> Util.pad_left_string_if_odd_length("1234", "0")
      "1234"

  """
  @spec pad_left_string_if_odd_length(String.t(), String.t()) :: String.t()
  def pad_left_string_if_odd_length(field_value, padding_char) do
    case rem(String.length(field_value), 2) > 0 do
      true -> padding_char <> field_value
      false -> field_value
    end
  end

  @doc """
  Pads a string to the right if its length is odd.

  Used to ensure strings have even length for BCD encoding,
  particularly for Track 2 data which is right-padded.

  ## Parameters
    - `field_value`: The string to potentially pad
    - `padding_char`: Character to use for padding (typically "0")

  ## Returns
    - Padded string if odd length, original string if even length

  ## Examples

      iex> Util.pad_right_string_if_odd_length("123", "0")
      "1230"

      iex> Util.pad_right_string_if_odd_length("1234", "0")
      "1234"

  """
  @spec pad_right_string_if_odd_length(String.t(), String.t()) :: String.t()
  def pad_right_string_if_odd_length(field_value, padding_char) do
    case rem(String.length(field_value), 2) > 0 do
      true -> field_value <> padding_char
      false -> field_value
    end
  end

  @doc """
  Sanitizes a string to extract only digits and converts to integer.

  First removes all non-digit characters, then parses the result as an integer.

  ## Parameters
    - `field_value`: The string to convert

  ## Returns
    - Parsed integer value

  ## Examples

      iex> Util.sanitize_and_convert_string_to_int("ABC123DEF")
      123

      iex> Util.sanitize_and_convert_string_to_int("456")
      456

  """
  @spec sanitize_and_convert_string_to_int(String.t()) :: integer()
  def sanitize_and_convert_string_to_int(field_value) do
    {int_val, _} =
      field_value
      |> sanitize_numeric_string
      |> Integer.parse()

    int_val
  end

  @doc """
  Calculates the BCD byte length for a given digit length.

  BCD encoding packs 2 digits per byte, so this function divides
  the length by 2 (rounding up for odd numbers).

  ## Parameters
    - `length`: Number of digits (nibbles in BCD terminology)

  ## Returns
    - `{:ok, byte_length}` if input is valid
    - `{:error, "Invalid Parameter"}` if input is invalid

  ## Examples

      iex> Util.get_bcd_length(6)
      {:ok, 3}

      iex> Util.get_bcd_length(7)
      {:ok, 4}

      iex> Util.get_bcd_length(0)
      {:error, "Invalid Parameter"}

  """
  @spec get_bcd_length(pos_integer()) :: {:ok, pos_integer()} | {:error, String.t()}
  def get_bcd_length(length) do
    case is_integer(length) and length > 0 do
      true -> {:ok, div(make_even(length), 2)}
      false -> {:error, "Invalid Parameter"}
    end
  end

  @doc """
  Converts a binary to its hexadecimal string representation.

  ## Parameters
    - `value`: The binary to convert

  ## Returns
    - `{:ok, hex_string}` if input is valid binary
    - `{:error, "Invalid Parameter"}` if input is invalid

  ## Examples

      iex> Util.convert_bin_to_hex(<<0x12, 0x34>>)
      {:ok, "1234"}

      iex> Util.convert_bin_to_hex(<<>>)
      {:error, "Invalid Parameter"}

  """
  @spec convert_bin_to_hex(binary()) :: {:ok, String.t()} | {:error, String.t()}
  def convert_bin_to_hex(value) do
    case is_binary(value) and byte_size(value) > 0 do
      true -> {:ok, Base.encode16(value)}
      false -> {:error, "Invalid Parameter"}
    end
  end

  @doc """
  Converts binary to hex, raising on error (bang version).

  ## Parameters
    - `value`: The binary to convert

  ## Returns
    - Hexadecimal string

  ## Raises
    - `ArgumentError` if value is not a non-empty binary

  ## Examples

      iex> Util.convert_bin_to_hex!(<<0x12, 0x34>>)
      "1234"

      iex> Util.convert_bin_to_hex!(<<>>)
      ** (ArgumentError) Invalid binary value

  """
  @spec convert_bin_to_hex!(binary()) :: String.t()
  def convert_bin_to_hex!(value) do
    case convert_bin_to_hex(value) do
      {:ok, result} -> result
      {:error, _} -> raise ArgumentError, "Invalid binary value"
    end
  end

  @doc """
  Takes the first n bytes from a binary.

  If the binary is shorter than n bytes, returns the entire binary.

  ## Parameters
    - `value`: The binary to slice
    - `n`: Maximum number of bytes to take

  ## Returns
    - First n bytes of the binary

  ## Examples

      iex> Util.take_first_bytes(<<1, 2, 3, 4, 5>>, 3)
      <<1, 2, 3>>

      iex> Util.take_first_bytes(<<1, 2>>, 5)
      <<1, 2>>

  """
  @spec take_first_bytes(binary(), non_neg_integer()) :: binary()
  def take_first_bytes(value, n) when is_binary(value) do
    bin_length = min(byte_size(value), n)
    binary_part(value, 0, bin_length)
  end

  @doc """
  Rounds an integer up to the nearest even number.

  If the value is already even, returns it unchanged.
  If the value is odd, adds 1 to make it even.

  ## Parameters
    - `value`: Integer to round up

  ## Returns
    - Even integer greater than or equal to input

  ## Examples

      iex> Util.make_even(3)
      4

      iex> Util.make_even(4)
      4

      iex> Util.make_even(7)
      8

  """
  @spec make_even(integer()) :: integer()
  def make_even(value) do
    case is_integer(value) and value > 0 do
      true ->
        value +
          case Integer.is_odd(value) do
            true -> 1
            false -> 0
          end

      false ->
        value
    end
  end

  @doc """
  Truncates a string from the left, keeping the last max_len characters.

  ## Parameters
    - `value`: The string to truncate
    - `max_len`: Maximum length to keep (keeps from the right)

  ## Returns
    - Truncated string

  ## Examples

      iex> Util.truncate_string("abcdefghij", 4)
      "ghij"

  """
  @spec truncate_string(String.t(), pos_integer()) :: String.t()
  def truncate_string(value, max_len) do
    String.slice(value, String.length(value) - max_len, max_len)
  end

  @doc """
  Truncates a string from the right, keeping the first max_len characters.

  ## Parameters
    - `value`: The string to truncate
    - `max_len`: Maximum length to keep (keeps from the left)

  ## Returns
    - Truncated string

  ## Examples

      iex> Util.truncate_string_take_left("abcdefghij", 4)
      "abcd"

  """
  @spec truncate_string_take_left(String.t(), pos_integer()) :: String.t()
  def truncate_string_take_left(value, max_len) do
    String.slice(value, 0, max_len)
  end
end
