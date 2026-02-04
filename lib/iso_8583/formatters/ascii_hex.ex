defmodule Iso8583.Formatters.AsciiHex do
  @moduledoc """
  ASCII Hex ISO 8583 formatter.

  This formatter uses ASCII encoding with hex-encoded bitmap:
  - ASCII MTI (4 ASCII characters)
  - ASCII Hex bitmap (16 or 32 ASCII hex characters = 8 or 16 bytes)
  - Field data in ASCII format

  ## Wire Format

      <<MTI::4-ascii-chars, HexBitmap::16-or-32-hex-chars, FieldData::variable>>

  ## Difference from Binary Format

  The key difference is the bitmap encoding:
  - Binary: `<<0x60, 0x00, ...>>` (raw bytes)
  - ASCII Hex: `"6000..."` (ASCII hex string)

  This format is commonly used by legacy systems that prefer ASCII-based protocols.

  ## Examples

  ### Basic encoding/decoding

      # Create ISOMsg
      iso_msg = ISOMsg.new("0200", %{2 => "1234567890123456789", 4 => "000000001234"})

      # Encode to ASCII hex format
      binary = Iso8583.Formatters.AsciiHex.encode(iso_msg)
      # Results in: "0200" <> "60000000..." (ASCII hex bitmap) <> field data

      # Decode back
      {:ok, iso_msg2} = Iso8583.Formatters.AsciiHex.decode(binary)

  ### Converting between Binary and ASCII Hex formats

      # Decode from Binary, encode to ASCII Hex
      {:ok, iso_msg} = Iso8583.Formatters.Binary.decode(binary_data)

      # Convert to ASCII Hex for legacy backend
      ascii_hex_binary = Iso8583.Formatters.AsciiHex.encode(iso_msg)

      # Send to legacy system...

  ### Using with different backends

      # Define struct for ASCII Hex backend
      defmodule MyApp.LegacySaleRequest do
        defstruct [:pan, :amount, :stan]

        def __iso_formatter__, do: Iso8583.Formatters.AsciiHex
        def __iso_field_map__, do: %{2 => :pan, 4 => :amount, 11 => :stan}
        def __iso_mti__, do: "0200"
      end

      # Configure client for legacy backend
      {Iso8583.Client, name: :legacy_backend,
       transport: Iso8583.Transport.TCP.Client,
       transport_opts: [host: "legacy.example.com", port: 8100],
       formatter: Iso8583.Formatters.AsciiHex}  # Different format!

      # Send - automatically encodes to ASCII Hex
      Iso8583.Client.send_transaction(:legacy_backend, %LegacySaleRequest{...})

  """

  @doc """
  Encodes an ISOMsg to ASCII hex format.
  """
  def encode(%ISOMsg{} = iso_msg) do
    mti = ISOMsg.get_mti(iso_msg)
    data = ISOMsg.get_data(iso_msg)

    # Create bitmap from field data
    bitmap = IsoBitmap.create_bitmap(data)

    # Convert bitmap to ASCII hex
    hex_bitmap = Base.encode16(bitmap, case: :upper)

    mti <> hex_bitmap <> encode_fields(data)
  end

  @doc """
  Decodes an ASCII hex format message to ISOMsg.
  """
  def decode(raw) when is_binary(raw) and byte_size(raw) >= 20 do
    # Extract MTI (4 ASCII characters = 4 bytes)
    <<mti::bytes-size(4), rest::binary>> = raw

    # Extract and parse bitmap (16 or 32 hex chars)
    case extract_hex_bitmap(rest) do
      {:ok, bitmap, field_data} ->
        # Get present field list from bitmap
        field_list = IsoBitmap.bitmap_to_list(bitmap)

        # Parse fields
        data = parse_fields(field_data, field_list -- [1], %{})

        {:ok, ISOMsg.new(mti, data)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def decode(_raw), do: {:error, :invalid_message}

  # Extract ASCII hex bitmap and remaining data
  defp extract_hex_bitmap(<<first_byte::utf8, _rest::binary>> = data) when first_byte in ?0..?9
    when first_byte in ?A..?F
    when first_byte in ?a..?f do

    # Check if secondary bitmap present by looking at first hex char
    # First hex char's first bit determines secondary bitmap
    <<first_hex_char::utf8, _::binary>> = data

    # Convert first hex char to integer to check bit 1
    first_nibble = String.to_integer(<<first_hex_char>>, 16)

    bitmap_size = if Bitwise.band(first_nibble, 8) == 8, do: 32, else: 16

    if byte_size(data) >= bitmap_size do
      <<hex_bitmap::bytes-size(bitmap_size), field_data::binary>> = data
      bitmap = Base.decode16!(hex_bitmap, case: :mixed)
      {:ok, bitmap, field_data}
    else
      {:error, :invalid_bitmap}
    end
  end

  defp extract_hex_bitmap(_), do: {:error, :invalid_bitmap}

  # Parse fields from binary data
  defp parse_fields(<<>>, [], acc), do: acc

  defp parse_fields(data, [_field_num | rest], acc) do
    # Simplified - proper implementation would use field definitions
    parse_fields(data, rest, acc)
  end

  defp parse_fields(data, [], acc), do: Map.put(acc, :raw_remaining, data)

  # Encode fields to binary (ASCII format)
  defp encode_fields(_data) do
    # For now, return empty - proper implementation would use field definitions
    <<>>
  end
end
