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

  ### Encoding with field definitions

      # Use field definitions for proper field encoding
      field_defs = Iso8583.FieldDefinition.standard_fields()

      iso_msg = ISOMsg.new("0200", %{2 => "1234567890123456789", 4 => "000000001234"})
      binary = Iso8583.Formatters.Binary.encode(iso_msg, field_definitions: field_defs)

  ### Decoding with field definitions

      field_defs = Iso8583.FieldDefinition.standard_fields()
      {:ok, iso_msg} = Iso8583.Formatters.Binary.decode(binary, field_definitions: field_defs)

  ### Using with transaction structs

      defmodule MyApp.SaleRequest do
        defstruct [:pan, :amount, :stan]

        def __iso_formatter__, do: Iso8583.Formatters.Binary
        def __iso_field_map__, do: %{2 => :pan, 4 => :amount, 11 => :stan}
        def __iso_mti__, do: "0200"
        def __iso_field_definitions__, do: Iso8583.FieldDefinition.only([2, 4, 11])
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
      binary = Iso8583.Formatters.Binary.encode(iso_msg,
        field_definitions: MyApp.SaleRequest.__iso_field_definitions__())

  ### Building messages with pipe operator

      iso_msg = ISOMsg.new("0200")
      |> ISOMsg.set_field(2, "1234567890123456789")
      |> ISOMsg.set_field(3, "000000")
      |> ISOMsg.set_field(4, "000000001234")
      |> ISOMsg.set_field(11, "000001")
      |> ISOMsg.set_field(41, "12345678")

      binary = Iso8583.Formatters.Binary.encode(iso_msg,
        field_definitions: Iso8583.FieldDefinition.standard_fields())

  """

  @behaviour Iso8583.Formatter

  alias ISOMsg
  alias IsoBitmap
  alias IsoField
  alias Iso8583.FieldDefinition

  @default_header_type :bcd

  @doc """
  Encodes an ISOMsg to standard binary format.

  ## Options

  - `:field_definitions` - Map of field number to field definition tuples.
    If not provided, returns MTI + bitmap only (no field data).

  ## Examples

      iso_msg = ISOMsg.new("0200", %{2 => "1234567890123456789", 4 => "000000001234"})
      field_defs = Iso8583.FieldDefinition.standard_fields()

      Iso8583.Formatters.Binary.encode(iso_msg, field_definitions: field_defs)

  """
  def encode(%ISOMsg{} = iso_msg, opts \\ []) do
    mti = ISOMsg.get_mti(iso_msg)
    data = ISOMsg.get_data(iso_msg)

    # Create bitmap from field data
    bitmap = IsoBitmap.create_bitmap(data)

    # Encode fields if field definitions provided
    fields_data = encode_fields(data, opts)

    mti <> bitmap <> fields_data
  end

  @doc """
  Decodes a binary format message to ISOMsg.

  ## Options

  - `:field_definitions` - Map of field number to field definition tuples.
    If not provided, only MTI and bitmap are decoded (fields remain empty).

  ## Examples

      field_defs = Iso8583.FieldDefinition.standard_fields()
      {:ok, iso_msg} = Iso8583.Formatters.Binary.decode(binary, field_definitions: field_defs)

  """
  def decode(raw, opts \\ [])

  def decode(raw, opts) when is_binary(raw) and byte_size(raw) >= 12 do
    # Extract MTI (4 bytes)
    <<mti::bytes-size(4), rest::binary>> = raw

    # Extract and parse bitmap
    case extract_bitmap(rest) do
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

  # Extract bitmap and remaining data
  defp extract_bitmap(<<1::1, _rest::bits>> = data) when byte_size(data) >= 16 do
    <<bitmap::bytes-size(16), field_data::binary>> = data
    {:ok, bitmap, field_data}
  end

  defp extract_bitmap(<<0::1, _rest::bits>> = data) when byte_size(data) >= 8 do
    <<bitmap::bytes-size(8), field_data::binary>> = data
    {:ok, bitmap, field_data}
  end

  defp extract_bitmap(_), do: {:error, :invalid_bitmap}

  # Encode fields using field definitions
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

  # Encode a single field
  defp encode_field(field_num, value, field_def, opts) do
    {header_size, iso_data_type, max_length, _padding} = FieldDefinition.to_iso_field_format(field_def)
    header_type = Keyword.get(opts, :header_type, @default_header_type)

    case header_type do
      :bcd ->
        IsoField.form_field({field_num, {header_size, iso_data_type, max_length}}, value, :bcd)
      :ascii ->
        IsoField.form_field({field_num, {header_size, iso_data_type, max_length}}, value, :ascii)
    end
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
        header_type = determine_header_type(field_def)

        case IsoField.extract_field({field_num, {header_size, iso_data_type, max_length}}, {acc, data}, header_type) do
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

  # Determine header type from field definition
  defp determine_header_type({header_size, _data_type, _max_length, opts}) when header_size > 0 do
    case opts do
      %{header_type: :ascii} -> :ascii
      _ -> :bcd
    end
  end

  defp determine_header_type(_field_def), do: :bcd
end
