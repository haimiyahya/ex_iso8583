defmodule Iso8583.FieldDefinition do
  @moduledoc """
  Field definitions for ISO 8583 message encoding and decoding.

  This module provides:
  - A standard field definition map for common ISO 8583 fields
  - Functions to create custom field definitions
  - Field format conversion helpers

  ## Field Format

  Each field is defined as a tuple:
  `{header_size, data_type, max_length, padding}`

  - `header_size`: Length header size (0=fixed, 2=LLVAR, 3=LLLVAR)
  - `data_type`: `:bcd` (numeric packed), `:ascii` (text), `:z` (Track 2), `:binary`
  - `max_length`: Maximum field length in characters
  - `padding`: Optional padding configuration

  ## Standard Field Definitions

  The module provides `standard_fields/0` which returns a map of all 128 ISO 8583
  fields with their common definitions.

  ## Examples

  ### Get a field definition

      field_def = Iso8583.FieldDefinition.get(2)
      # => {2, :n, :llvar, 19}

  ### Create custom field definitions

      defmodule MyApp.Fields do
        import Iso8583.FieldDefinition

        def fields do
          %{
            2 => field(:n, :llvar, 19),        # PAN
            3 => field(:n, :fixed, 6),         # Processing code
            4 => field(:n, :fixed, 12),        # Amount
            11 => field(:n, :fixed, 6),        # STAN
            39 => field(:n, :fixed, 2),        # Response code
            41 => field(:ans, :fixed, 8)       # Terminal ID
          }
        end
      end

  ### Use with formatter

      field_defs = MyApp.Fields.fields()
      binary = Iso8583.Formatters.Binary.encode(iso_msg, field_definitions: field_defs)

  ### Override header type for specific fields

      field_defs = %{
        2 => {:llvar_bcd, 19},     # PAN with BCD length header
        48 => {:lllvar_ascii, 999}   # Additional data with ASCII length header
      }

  """

  @type header_type :: :fixed | :llvar | :lllvar | :llvar_bcd | :lllvar_bcd | :llvar_ascii | :lllvar_ascii
  @type data_type :: :n | :an | :ans | :z | :b
  @type field_def :: {non_neg_integer(), data_type(), pos_integer()} |
                   {non_neg_integer(), data_type(), pos_integer(), header_type()} |
                   {non_neg_integer(), data_type(), pos_integer(), header_type(), map() | nil}

  # Standard ISO 8583 field definitions based on 1987 and 1993 versions
  @standard_fields %{
    # Bitmap is implicit (field 1)
    2 => {2, :n, 19, nil},              # Primary Account Number (PAN)
    3 => {0, :n, 6, nil},               # Processing Code
    4 => {0, :n, 12, nil},              # Transaction Amount
    5 => {0, :n, 12, nil},              # Settlement Amount
    6 => {0, :n, 12, nil},              # Cardholder Billing Amount
    7 => {0, :n, 10, nil},              # Transmission Date & Time (MMDDhhmmss)
    8 => {0, :n, 8, nil},               # Cardholder Billing Conversion Rate
    9 => {0, :n, 8, nil},               # Cardholder Billing Conversion Rate
    10 => {0, :n, 8, nil},              # Cardholder Billing Conversion Rate
    11 => {0, :n, 6, nil},              # System Trace Audit Number (STAN)
    12 => {0, :n, 6, nil},              # Local Transaction Time
    13 => {0, :n, 4, nil},              # Local Transaction Date
    14 => {0, :n, 4, nil},              # Expiration Date
    15 => {0, :n, 4, nil},              # Settlement Date
    16 => {0, :n, 4, nil},              # Conversion Date
    17 => {0, :n, 4, nil},              # Capture Date
    18 => {0, :n, 4, nil},              # Merchant Type
    19 => {0, :n, 3, nil},              # Acquiring Institution Country Code
    20 => {0, :n, 3, nil},              # PAN Extended Country Code
    21 => {0, :n, 3, nil},              # Forwarding Institution Country Code
    22 => {0, :n, 3, nil},              # Point of Service Entry Mode
    23 => {0, :n, 3, nil},              # Card Sequence Number
    24 => {0, :n, 3, nil},              # Function Code
    25 => {0, :n, 2, nil},              # Point of Service Condition Code
    26 => {0, :n, 2, nil},              # Point of Service PIN Capture Code
    27 => {0, :n, 1, nil},              # Authorization ID Response Length
    28 => {0, :n, 6, nil},              # Amount Transaction Fee
    29 => {0, :n, 3, nil},              # Amount Settlement Fee
    30 => {0, :n, 3, nil},              # Amount Transaction Fee
    31 => {0, :n, 3, nil},              # Amount Settlement Fee
    32 => {0, :n, 11, nil},             # Acquiring Institution ID Code
    33 => {0, :n, 11, nil},             # Forwarding Institution ID Code
    34 => {0, :an, 28, nil},            # Primary Account Number Extended
    35 => {2, :z, 37, nil},              # Track 2 Data
    36 => {0, :n, 3, nil},              # Track 3 Data
    37 => {0, :n, 12, nil},             # Retrieval Reference Number
    38 => {0, :an, 6, nil},             # Authorization ID Response
    39 => {0, :an, 2, nil},             # Response Code
    40 => {0, :an, 3, nil},             # Service Code
    41 => {0, :ans, 8, nil},            # Card Acceptor Terminal ID
    42 => {0, :ans, 15, nil},           # Card Acceptor ID Code
    43 => {2, :ans, 40, nil},           # Card Acceptor Name/Location
    44 => {0, :ans, 25, nil},           # Additional Response Data
    45 => {0, :ans, 76, nil},           # Track 1 Data
    46 => {0, :ans, 2048, nil},         # Additional Data - ISO
    47 => {0, :an, 3, nil},             # Additional Data - National
    48 => {3, :ans, 999, nil},          # Additional Data - Private
    49 => {0, :an, 3, nil},             # Currency Code, Transaction
    50 => {0, :an, 3, nil},             # Currency Code, Settlement
    51 => {0, :an, 3, nil},             # Currency Code, Cardholder Billing
    52 => {0, :b, 8, nil},               # PIN Data
    53 => {0, :n, 16, nil},             # Security Control Information
    54 => {0, :ans, 120, nil},           # Additional Amounts
    55 => {0, :an, 2, nil},             # ICC Data - EMV
    56 => {0, :b, 8, nil},              # Reserved - ISO
    57 => {0, :b, 8, nil},              # Reserved - National
    58 => {0, :b, 8, nil},              # Reserved - Private
    59 => {0, :n, 22, nil},             # Reserved - ISO
    60 => {2, :ans, 999, nil},          # Reserved - Private
    61 => {0, :ans, 999, nil},          # Reserved - Private
    62 => {0, :b, 8, nil},              # Reserved - Private
    63 => {0, :b, 8, nil},              # Reserved - Private
    64 => {0, :b, 8, nil},              # Reserved - Private
    65 => {0, :b, 8, nil},              # Reserved - Private
    66 => {0, :b, 8, nil},              # Reserved - Private
    67 => {0, :b, 8, nil},              # Reserved - Private
    68 => {0, :b, 8, nil},              # Reserved - Private
    69 => {0, :b, 8, nil},              # Reserved - Private
    70 => {0, :b, 8, nil},              # Reserved - Private
    71 => {0, :b, 8, nil},              # Reserved - Private
    72 => {0, :b, 8, nil},              # Reserved - Private
    73 => {0, :b, 8, nil},              # Reserved - Private
    74 => {0, :b, 8, nil},              # Reserved - Private
    75 => {0, :b, 8, nil},              # Reserved - Private
    76 => {0, :b, 8, nil},              # Reserved - Private
    77 => {0, :b, 8, nil},              # Reserved - Private
    78 => {0, :b, 8, nil},              # Reserved - Private
    79 => {0, :b, 8, nil},              # Reserved - Private
    80 => {0, :b, 8, nil},              # Reserved - Private
    81 => {0, :b, 8, nil},              # Reserved - Private
    82 => {0, :b, 8, nil},              # Reserved - Private
    83 => {0, :b, 8, nil},              # Reserved - Private
    84 => {0, :b, 8, nil},              # Reserved - Private
    85 => {0, :b, 8, nil},              # Reserved - Private
    86 => {0, :b, 8, nil},              # Reserved - Private
    87 => {0, :b, 8, nil},              # Reserved - Private
    88 => {0, :b, 8, nil},              # Reserved - Private
    89 => {0, :b, 8, nil},              # Reserved - Private
    90 => {0, :b, 8, nil},              # Reserved - Private
    91 => {0, :b, 8, nil},              # Reserved - Private
    92 => {0, :b, 8, nil},              # Reserved - Private
    93 => {0, :b, 8, nil},              # Reserved - Private
    94 => {0, :b, 8, nil},              # Reserved - Private
    95 => {0, :b, 8, nil},              # Reserved - Private
    96 => {0, :b, 8, nil},              # Reserved - Private
    97 => {0, :b, 8, nil},              # Reserved - Private
    98 => {0, :b, 8, nil},              # Reserved - Private
    99 => {0, :b, 8, nil},              # Reserved - Private
    100 => {0, :b, 8, nil},             # Reserved - Private
    101 => {0, :b, 8, nil},             # Reserved - Private
    102 => {0, :b, 8, nil},             # Reserved - ISO
    103 => {0, :b, 8, nil},             # Reserved - National
    104 => {0, :b, 8, nil},             # Reserved - Private
    105 => {0, :b, 8, nil},             # Reserved - Private
    106 => {0, :b, 8, nil},             # Reserved - Private
    107 => {0, :b, 8, nil},             # Reserved - Private
    108 => {0, :b, 8, nil},             # Reserved - Private
    109 => {0, :b, 8, nil},             # Reserved - Private
    110 => {0, :b, 8, nil},             # Reserved - Private
    111 => {0, :b, 8, nil},             # Reserved - Private
    112 => {0, :n, 6, nil},             # Reserved - National
    113 => {0, :n, 28, nil},            # Reserved - Private
    114 => {0, :n, 28, nil},            # Reserved - Private
    115 => {0, :b, 8, nil},             # Reserved - Private
    116 => {0, :b, 8, nil},             # Reserved - National
    117 => {0, :b, 8, nil},             # Reserved - Private
    118 => {0, :b, 8, nil},             # Reserved - Private
    119 => {0, :b, 8, nil},             # Reserved - Private
    120 => {0, :b, 8, nil},             # Reserved - Private
    121 => {0, :b, 8, nil},             # Reserved - Private
    122 => {0, :b, 8, nil},             # Reserved - Private
    123 => {0, :b, 8, nil},             # Reserved - Private
    124 => {0, :b, 8, nil},             # Reserved - Private
    125 => {0, :b, 8, nil},             # Reserved - Private
    126 => {0, :b, 8, nil},             # Reserved - Private
    127 => {0, :b, 8, nil},             # Reserved - Private
    128 => {0, :b, 8, nil}              # Reserved - Private
  }

  @doc """
  Returns the standard ISO 8583 field definitions map.

  ## Example

      field_defs = Iso8583.FieldDefinition.standard_fields()
      # => %{2 => {2, :n, 19, nil}, 3 => {0, :n, 6, nil}, ...}

  """
  def standard_fields, do: @standard_fields

  @doc """
  Gets a field definition by field number.

  Returns the field format tuple or `nil` if not defined.

  ## Example

      Iso8583.FieldDefinition.get(2)
      # => {2, :n, 19, nil}

      Iso8583.FieldDefinition.get(999)
      # => nil

  """
  def get(field_number) when is_integer(field_number) do
    Map.get(@standard_fields, field_number)
  end

  @doc """
  Creates a field definition tuple.

  ## Parameters

  - `data_type`: `:n` (numeric), `:an` (alphanumeric), `:ans` (alphanumeric + special), `:z` (Track 2), `:b` (binary)
  - `format`: `:fixed`, `:llvar`, `:lllvar`
  - `length`: Maximum field length

  ## Options

  - `:header_type`: `:bcd` or `:ascii` for length header encoding (default: `:bcd`)
  - `:padding`: Padding configuration map with `:char` and `:direction` keys

  ## Examples

      field(:n, :fixed, 6)
      # => {0, :n, 6, nil}

      field(:n, :llvar, 19)
      # => {2, :n, 19, nil}

      field(:an, :llvar, 40, header_type: :ascii)
      # => {2, :an, 40, %{header_type: :ascii}}

  """
  def field(data_type, format, length, opts \\ []) do
    header_size = case format do
      :fixed -> 0
      :llvar -> 2
      :lllvar -> 3
    end

    padding = Keyword.get(opts, :padding)
    header_type = Keyword.get(opts, :header_type, :bcd)

    base = {header_size, convert_data_type(data_type), length, padding}

    case header_type do
      :ascii -> {header_size, convert_data_type(data_type), length, %{header_type: :ascii}}
      :bcd -> base
    end
  end

  @doc """
  Converts a shorthand data type to IsoField-compatible data type.

  ## Examples

      convert_data_type(:n)
      # => :bcd

      convert_data_type(:an)
      # => :ascii

      convert_data_type(:ans)
      # => :ascii

      convert_data_type(:z)
      # => :z

      convert_data_type(:b)
      # => :binary

  """
  def convert_data_type(:n), do: :bcd
  def convert_data_type(:an), do: :ascii
  def convert_data_type(:ans), do: :ascii
  def convert_data_type(:z), do: :z
  def convert_data_type(:b), do: :binary
  def convert_data_type(:bcd), do: :bcd
  def convert_data_type(:ascii), do: :ascii
  def convert_data_type(:binary), do: :binary

  @doc """
  Converts a field definition to the format expected by IsoField.

  ## Examples

      to_iso_field_format({2, :n, 19, nil})
      # => {2, :bcd, 19, nil}

      to_iso_field_format({2, :an, 40, %{header_type: :ascii}})
      # => {2, :ascii, 40, nil}

  """
  def to_iso_field_format({header_size, data_type, max_length, opts}) when is_list(opts) do
    {header_size, convert_data_type(data_type), max_length, nil}
  end

  def to_iso_field_format({header_size, data_type, max_length, opts}) when is_map(opts) do
    iso_data_type = convert_data_type(data_type)
    # Handle header_type option
    case Map.get(opts, :header_type) do
      :ascii -> {header_size, iso_data_type, max_length, nil}
      _ -> {header_size, iso_data_type, max_length, nil}
    end
  end

  def to_iso_field_format({header_size, data_type, max_length}) do
    {header_size, convert_data_type(data_type), max_length, nil}
  end

  @doc """
  Merges custom field definitions with standard field definitions.

  Custom definitions override standard ones.

  ## Example

      custom = %{
        48 => {3, :ans, 999, nil},  # Override field 48
        200 => {2, :n, 19, nil}      # Add custom field
      }

      Iso8583.FieldDefinition.merge(custom)
      # => %{...standard fields..., 48 => {3, :ans, 999, nil}, 200 => {...}}

  """
  def merge(custom_fields) when is_map(custom_fields) do
    Map.merge(@standard_fields, custom_fields)
  end

  @doc """
  Creates a minimal field definition map for a given set of fields.

  Useful for quick testing or when you only need a few fields.

  ## Example

      Iso8583.FieldDefinition.only([2, 4, 11, 39])
      # => %{2 => {2, :n, 19, nil}, 4 => {0, :n, 12, nil}, 11 => {0, :n, 6, nil}, 39 => {0, :an, 2, nil}}

  """
  def only(field_numbers) when is_list(field_numbers) do
    Enum.reduce(field_numbers, %{}, fn field_num, acc ->
      case get(field_num) do
        nil -> acc
        def -> Map.put(acc, field_num, def)
      end
    end)
  end
end
