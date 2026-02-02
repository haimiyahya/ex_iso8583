defmodule Ex_Iso8583.TPDU do
  @moduledoc """
  TPDU (Transaction Propagation Data Unit) handling for ISO 8583 messages.

  The TPDU is an optional header that precedes the ISO 8583 message. It contains
  routing information used in some ISO 8583 implementations.

  ## TPDU Structure

  The TPDU consists of:
  - Destination Address: 5 bytes (or configurable)
  - Source Address: 5 bytes (or configurable)
  - Total: 10 bytes (typically)

  ## Examples

      iex> TPDU.parse(<<1, 2, 3, 4, 5, 6, 7, 8, 9, 10>>)
      {:ok, %{
        destination: <<1, 2, 3, 4, 5>>,
        source: <<6, 7, 8, 9, 10>>
      }}

      iex> TPDU.format(destination: <<1, 2, 3, 4, 5>>, source: <<6, 7, 8, 9, 10>>)
      <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10>>
  """

  @type tpdu :: %{
          destination: binary(),
          source: binary()
        }
  @type address_size :: pos_integer()

  @default_address_size 5

  @doc """
  Parses a TPDU binary into its components.

  ## Parameters
    - tpdu_binary: Binary TPDU data
    - address_size: Size of each address (default 5 bytes)

  ## Returns
    `{:ok, tpdu_map}` if valid, `{:error, reason}` if invalid

  ## Examples

      iex> TPDU.parse(<<1, 2, 3, 4, 5, 6, 7, 8, 9, 10>>)
      {:ok, %{destination: <<1, 2, 3, 4, 5>>, source: <<6, 7, 8, 9, 10>>}}
  """
  @spec parse(binary(), address_size()) :: {:ok, tpdu()} | {:error, String.t()}
  def parse(tpdu_binary, address_size \\ @default_address_size)

  def parse(tpdu_binary, address_size) when is_binary(tpdu_binary) and byte_size(tpdu_binary) >= address_size * 2 do
    <<destination::binary-size(address_size), source::binary-size(address_size), _rest::binary>> =
      tpdu_binary

    {:ok, %{destination: destination, source: source}}
  end

  def parse(_, _), do: {:error, "TPDU must be a binary or is too short"}

  @doc """
  Formats a TPDU map into a binary.

  ## Parameters
    - tpdu: Map with :destination and :source keys
    - address_size: Size of each address (default 5 bytes)

  ## Examples

      iex> TPDU.format(%{destination: <<1, 2, 3, 4, 5>>, source: <<6, 7, 8, 9, 10>>})
      <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10>>
  """
  @spec format(tpdu(), address_size()) :: binary()
  def format(tpdu, address_size \\ @default_address_size)

  def format(%{destination: dest, source: src}, address_size) do
    # Pad or truncate to address_size
    dest_bytes = pad_address(dest, address_size)
    src_bytes = pad_address(src, address_size)

    dest_bytes <> src_bytes
  end

  def format(_, _), do: {:error, "TPDU must be a map with :destination and :source keys"}

  defp pad_address(address, size) when byte_size(address) < size do
    padding = size - byte_size(address)
    <<0::size(padding * 8)>> <> address
  end

  defp pad_address(address, size) when byte_size(address) > size do
    binary_part(address, byte_size(address) - size, size)
  end

  defp pad_address(address, _size), do: address

  @doc """
  Validates a TPDU binary.

  ## Examples

      iex> TPDU.valid?(<<1, 2, 3, 4, 5, 6, 7, 8, 9, 10>>)
      true

      iex> TPDU.valid?(<<1, 2>>)
      false
  """
  @spec valid?(binary(), address_size()) :: boolean()
  def valid?(tpdu_binary, address_size \\ @default_address_size)

  def valid?(tpdu_binary, address_size) when is_binary(tpdu_binary) do
    byte_size(tpdu_binary) == address_size * 2
  end

  def valid?(_, _), do: false

  @doc """
  Extracts the TPDU from a message, returning both the TPDU and the remaining message.

  ## Examples

      iex> TPDU.extract(<<1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 0, 0>>)
      {:ok, %{destination: <<1, 2, 3, 4, 5>>, source: <<6, 7, 8, 9, 10>>}, <<0, 0>>}
  """
  @spec extract(binary(), address_size()) ::
          {:ok, tpdu(), binary()} | {:error, String.t()}
  def extract(message, address_size \\ @default_address_size)

  def extract(message, address_size) when is_binary(message) do
    tpdu_size = address_size * 2

    if byte_size(message) < tpdu_size do
      {:error, "Message too short to contain TPDU"}
    else
      <<tpdu_binary::binary-size(tpdu_size), rest::binary>> = message

      case parse(tpdu_binary, address_size) do
        {:ok, tpdu} -> {:ok, tpdu, rest}
        error -> error
      end
    end
  end

  def extract(_, _), do: {:error, "Message must be a binary"}

  @doc """
  Prepends a TPDU to an ISO 8583 message.

  ## Examples

      iex> TPDU.prepend(<<0, 0>>, %{destination: <<1, 2, 3, 4, 5>>, source: <<6, 7, 8, 9, 10>>})
      <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 0, 0>>
  """
  @spec prepend(binary(), tpdu(), address_size()) :: binary()
  def prepend(message, tpdu, address_size \\ @default_address_size)

  def prepend(message, tpdu, address_size) when is_binary(message) and is_map(tpdu) do
    format(tpdu, address_size) <> message
  end

  def prepend(_, _, _), do: {:error, "Invalid arguments"}

  @doc """
  Formats a TPDU address as a hex string for display.

  ## Examples

      iex> TPDU.format_address(<<1, 2, 3, 4, 5>>)
      "0102030405"
  """
  @spec format_address(binary()) :: String.t()
  def format_address(address) when is_binary(address) do
    Base.encode16(address, case: :lower)
  end

  @doc """
  Parses a hex string into a TPDU address.

  ## Examples

      iex> TPDU.parse_address("0102030405")
      {:ok, <<1, 2, 3, 4, 5>>}
  """
  @spec parse_address(String.t()) :: {:ok, binary()} | {:error, String.t()}
  def parse_address(hex_string) when is_binary(hex_string) do
    case Base.decode16(hex_string, case: :mixed) do
      {:ok, binary} -> {:ok, binary}
      :error -> {:error, "Invalid hex string"}
    end
  end
end
