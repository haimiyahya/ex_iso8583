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

  ### Encoding with field definitions

      # Use field definitions for proper field encoding
      field_defs = Iso8583.FieldDefinition.standard_fields()

      iso_msg = ISOMsg.new("0200", %{2 => "1234567890123456789", 4 => "000000001234"})
      binary = Iso8583.Formatters.AsciiHex.encode(iso_msg, field_definitions: field_defs)

  ### Decoding with field definitions

      field_defs = Iso8583.FieldDefinition.standard_fields()
      {:ok, iso_msg} = Iso8583.Formatters.AsciiHex.decode(binary, field_definitions: field_defs)

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
        def __iso_field_definitions__, do: Iso8583.FieldDefinition.only([2, 4, 11])
      end

      # Configure client for legacy backend
      {Iso8583.Client, name: :legacy_backend,
       transport: Iso8583.Transport.TCP.Client,
       transport_opts: [host: "legacy.example.com", port: 8100],
       formatter: Iso8583.Formatters.AsciiHex}  # Different format!

      # Send - automatically encodes to ASCII Hex
      Iso8583.Client.send_transaction(:legacy_backend, %LegacySaleRequest{...})

  """

  @behaviour Iso8583.Formatter

  alias ISOMsg
  alias IsoBitmap
  alias IsoField
  alias Iso8583.FieldDefinition

  @doc """
  Encodes an ISOMsg to ASCII hex format.

  ## Options

  - `:field_definitions` - Map of field number to field definition tuples.
    If not provided, returns MTI + hex bitmap only (no field data).

  """
  def encode(%ISOMsg{} = iso_msg, opts \\ []) do
    mti = ISOMsg.get_mti(iso_msg)
    data = ISOMsg.get_data(iso_msg)

    # Create bitmap from field data
    bitmap = IsoBitmap.create_bitmap(data)

    # Convert bitmap to ASCII hex
    hex_bitmap = Base.encode16(bitmap, case: :upper)

    # Encode fields if field definitions provided
    fields_data = encode_fields(data, opts)

    mti <> hex_bitmap <> fields_data
  end

  @doc """
  Decodes an ASCII hex format message to ISOMsg.

  ## Options

  - `:field_definitions` - Map of field number to field definition tuples.
    If not provided, only MTI and bitmap are decoded (fields remain empty).

  """
  def decode(raw, opts \\ [])

  def decode(raw, opts) when is_binary(raw) and byte_size(raw) >= 20 do
    # Extract MTI (4 ASCII characters = 4 bytes)
    <<mti::bytes-size(4), rest::binary>> = raw

    # Extract and parse hex bitmap
    case extract_hex_bitmap(rest) do
      {:ok, bitmap, field_data} ->
        # Get present field list from bitmap
        field_list = IsoBitmap.bitmap_to_list(bitmap)

        # Parse fields
        data = if opts[:field_definitions] do
          parse_fields(field_data, field_list -- [1], opts[:field_definitions])
        else
          # Return raw remaining data if no field definitions
          parse_fields_simple(field_list, field_data)
        end

        {:ok, ISOMsg.new(mti, data)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def decode(_raw, _opts), do: {:error, :invalid_message}

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

  # Encode fields using field definitions (ASCII encoded)
  defp encode_fields(data, opts) do
    field_defs = Keyword.get(opts, :field_definitions, %{})

    # Sort fields by number for consistent encoding
    data
    |> Enum.sort_by(fn {field_num, _} -> field_num end)
    |> Enum.reduce(<<>>, fn {field_num, value}, acc ->
      case Map.get(field_defs, field_num) do
        nil ->
          # No definition, skip this field
          acc

        field_def ->
          acc <> encode_field(field_num, value, field_def, opts)
      end
    end)
  end

  # Encode a single field in ASCII format
  defp encode_field(field_num, value, field_def, _opts) do
    {header_size, iso_data_type, max_length, _padding} = FieldDefinition.to_iso_field_format(field_def)

    # For ASCII Hex format, fields are typically ASCII encoded
    # Use ASCII header type for variable length fields
    IsoField.form_field({field_num, {header_size, iso_data_type, max_length}}, value, :ascii)
  end

  # Parse fields using field definitions
  defp parse_fields(field_data, field_list, field_defs) do
    parse_fields(field_data, field_list, field_defs, %{})
  end

  defp parse_fields(<<>>, [], _field_defs, acc), do: acc

  defp parse_fields(data, [field_num | rest], field_defs, acc) do
    case Map.get(field_defs, field_num) do
      nil ->
        # No definition for this field, skip
        parse_fields(data, rest, field_defs, acc)

      field_def ->
        {header_size, iso_data_type, max_length, _padding} = FieldDefinition.to_iso_field_format(field_def)

        # ASCII Hex format uses ASCII headers for variable-length fields
        case IsoField.extract_field({field_num, {header_size, iso_data_type, max_length}}, {acc, data}, :ascii) do
          {updated_acc, remaining} ->
            parse_fields(remaining, rest, field_defs, updated_acc)
        end
    end
  end

  defp parse_fields(data, [], _field_defs, acc), do: Map.put(acc, :raw_remaining, data)

  # Simple parse without field definitions - just return empty map
  defp parse_fields_simple(_field_list, field_data) do
    %{raw_remaining: field_data}
  end
end
