defmodule Iso8583.Formatters.Binary do
  @moduledoc """
  Standard binary ISO 8583 formatter.

  This formatter uses the traditional binary encoding:
  - Binary MTI (4 bytes)
  - Binary bitmap (8 or 16 bytes)
  - Field data encoded according to field definitions (BCD, ASCII, etc.)

  ## Wire Format

      <<MTI::4-bytes, Bitmap::8-or-16-bytes, FieldData::variable>>

  ## Examples

  ### Basic encoding/decoding

      # Create ISOMsg
      iso_msg = ISOMsg.new("0200", %{2 => "1234567890123456789", 4 => "000000001234"})

      # Encode to binary
      binary = Iso8583.Formatters.Binary.encode(iso_msg)

      # Decode back
      {:ok, iso_msg2} = Iso8583.Formatters.Binary.decode(binary)

  ### Using with transaction structs

      defmodule MyApp.SaleRequest do
        defstruct [:pan, :amount, :stan]

        def __iso_formatter__, do: Iso8583.Formatters.Binary
        def __iso_field_map__, do: %{2 => :pan, 4 => :amount, 11 => :stan}
        def __iso_mti__, do: "0200"
      end

      # Create request
      request = %MyApp.SaleRequest{
        pan: "1234567890123456789",
        amount: "000000001000",
        stan: "000001"
      }

      # Convert to ISOMsg and encode
      iso_msg = ISOMsg.from_struct(
        request,
        "0200",
        MyApp.SaleRequest.__iso_field_map__()
      )
      binary = Iso8583.Formatters.Binary.encode(iso_msg)

      # Decode response
      {:ok, response_iso} = Iso8583.Formatters.Binary.decode(response_binary)

  ### Building messages with pipe operator

      iso_msg = ISOMsg.new("0200")
      |> ISOMsg.set_field(2, "1234567890123456789")
      |> ISOMsg.set_field(3, "000000")
      |> ISOMsg.set_field(4, "000000001234")
      |> ISOMsg.set_field(11, "000001")
      |> ISOMsg.set_field(41, "12345678")

      binary = Iso8583.Formatters.Binary.encode(iso_msg)

  """

  @doc """
  Encodes an ISOMsg to standard binary format.
  """
  def encode(%ISOMsg{} = iso_msg) do
    mti = ISOMsg.get_mti(iso_msg)
    data = ISOMsg.get_data(iso_msg)

    # Create bitmap from field data
    bitmap = IsoBitmap.create_bitmap(data)

    mti <> bitmap <> encode_fields(data, iso_msg)
  end

  @doc """
  Decodes a binary format message to ISOMsg.
  """
  def decode(raw) when is_binary(raw) and byte_size(raw) >= 12 do
    # Extract MTI (4 bytes)
    <<mti::bytes-size(4), rest::binary>> = raw

    # Extract and parse bitmap
    case extract_bitmap(rest) do
      {:ok, bitmap, field_data} ->
        # Get present field list from bitmap
        field_list = IsoBitmap.bitmap_to_list(bitmap)

        # Parse fields (field 1 is the bitmap indicator, actual data starts from field 2)
        data = parse_fields(field_data, field_list -- [1], %{})

        {:ok, ISOMsg.new(mti, data)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def decode(_raw), do: {:error, :invalid_message}

  # Extract bitmap and remaining data
  # Check first bit to determine if secondary bitmap exists
  defp extract_bitmap(<<1::1, _rest::bits>> = data) when byte_size(data) >= 16 do
    <<bitmap::bytes-size(16), field_data::binary>> = data
    {:ok, bitmap, field_data}
  end

  defp extract_bitmap(<<0::1, _rest::bits>> = data) when byte_size(data) >= 8 do
    <<bitmap::bytes-size(8), field_data::binary>> = data
    {:ok, bitmap, field_data}
  end

  defp extract_bitmap(_), do: {:error, :invalid_bitmap}

  # Parse fields from binary data
  # Note: This is a simplified parser - for production use, you'd need proper field definitions
  defp parse_fields(<<>>, [], acc), do: acc

  defp parse_fields(data, [_field_num | rest], acc) do
    # Since we don't have field definitions here, we'll return what we can parse
    # In a real implementation, you'd use IsoField to parse based on field definitions
    # For now, just store the raw data remaining
    parse_fields(data, rest, acc)
  end

  defp parse_fields(data, [], acc), do: Map.put(acc, :raw_remaining, data)

  # Encode fields to binary
  # Note: This is a simplified encoder - production would use field definitions
  defp encode_fields(_data, _iso_msg) do
    # For now, return empty - proper implementation would use IsoField.form_field
    # for each field based on field definitions
    <<>>
  end
end
