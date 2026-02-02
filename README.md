# Ex_Iso8583

An Elixir library for parsing and formatting ISO 8583 messages - the international standard for systems that exchange electronic transaction information.

## Architecture

### Module Overview

```
Ex_Iso8583
    |
    +-- IsoBitmap       - Bitmap management (creation, parsing, transformation)
    +-- IsoField        - Field extraction and formatting
    +-- IsoFieldFormat  - Field format definition parsing
    +-- IsoMsg          - Message structure definition
    +-- Util            - Utility functions for data manipulation
```

### Core Modules

#### `Ex_Iso8583` - Main API

The primary entry point for ISO 8583 message operations:

- `extract_iso_msg/3` - Parse an ISO 8583 binary message into a map of fields
- `form_iso_msg/3` - Build an ISO 8583 binary message from a field map

#### `IsoBitmap` - Bitmap Management

Handles the bitmap that indicates which data elements are present in a message:

- **Binary Bitmap** - Raw binary format (8 or 16 bytes)
- **ASCII Bitmap** - Hex-encoded string representation (16 or 32 characters)

Key functions:
- `create_bitmap/1` - Create bitmap from field map
- `bitmap_to_list/1` - Convert bitmap to list of field numbers present
- `list_to_bitmap/1` - Convert field list to binary bitmap
- `split_bitmap_and_msg/2` - Separate bitmap from message data

The bitmap follows ISO 8583 standards:
- If bit 1 is set → Secondary bitmap exists (fields 65-128)
- If bit 1 is NOT set → Only primary bitmap (fields 2-64)

#### `IsoField` - Field Operations

Handles individual field formatting and extraction:

**Supported Data Types:**
| Type | Description |
|------|-------------|
| `:bcd` | Binary Coded Decimal - numeric data packed 2 digits per byte |
| `:ascii` | ASCII text representation |
| `:z` | Track 2 data (special BCD encoding) |
| `:binary` | Raw binary data |
| `:hex` | Hexadecimal data |

Key functions:
- `form_field/3` - Format a single field for output
- `extract_field/3` - Extract a single field from input

#### `IsoFieldFormat` - Format Definition Parser

Parses field format definitions like `"n ..19"` or `"an ...12"`:

**Format Syntax:**
- `n` - Numeric
- `a` - Alphabetic
- `an` - Alphanumeric
- `ans` - Alphanumeric + Special
- `b` - Binary
- `z` - Track 2
- `x+n` - Variable length with header

**Length Indicators:**
- `n 6` - Fixed length of 6
- `n ..19` - Variable length up to 19 (with 2-byte header)
- `n ...104` - Variable length up to 104 (with 3-byte header)

#### `IsoMsg` - Message Structure

Defines a struct for ISO message representation:
```elixir
defstruct config: %{ascii_format: false, ascii_bitmap: true, tpdu_length: 10},
          tpdu: "",
          mti: "",
          data: %{}
```

#### `Util` - Utility Functions

Common helper functions:
- String padding (left/right with BCD/ASCII)
- Numeric sanitization
- BCD length calculation
- Binary-to-hex conversion

## Installation

```elixir
def deps do
  [
    {:ex_iso8583, "~> 0.3.2"}
  ]
end
```

## Usage

### Message Type Configuration

Define your message type format:

```elixir
# For BCD-packed fields
msg_type_bcd = %{
  bitmap_type: :binary,    # or :ascii for hex-encoded bitmap
  field_header_type: :bcd  # or :ascii
}

# For ASCII fields
msg_type_ascii = %{
  bitmap_type: :ascii,
  field_header_type: :ascii
}
```

### Padding Configuration

Configure default padding behavior for fixed-length fields:

```elixir
msg_type_with_padding = %{
  bitmap_type: :binary,
  field_header_type: :bcd,
  padding: %{
    bcd: %{char: "0", direction: :left},    # Default: pad with zeros on the left
    ascii: %{char: " ", direction: :left},  # Default: pad with spaces on the left
    z: %{char: "0", direction: :right}      # Track 2: pad with zeros on the right
  }
}
```

**Per-Field Padding Override**

Override padding for specific fields using a map format:

```elixir
field_format = %{
  # Simple string format (uses default padding)
  2 => "n ..19",
  3 => "n 6",
  4 => "n 12",

  # Map format with custom padding
  48 => %{
    format: "ans ...999",
    padding: %{char: " ", direction: :right}  # Right-pad with spaces
  },

  # Disable padding for a specific field
  42 => %{
    format: "ans ...999",
    padding: false
  }
}
```

**Padding Options:**

| Option | Type | Description |
|--------|------|-------------|
| `char` | String | Character to use for padding (e.g., `"0"`, `" "`) |
| `direction` | Atom | `:left` or `:right` |
| `false` | Boolean | Disable padding for this field |

**Note:** Padding only applies to fixed-length fields (fields without a length header). Variable-length fields (with `..` or `...` in format) are not padded.

### Field Format Definition

Define the format for each data element:

```elixir
field_format = %{
  2 => "n ..19",   # Field 2: Numeric, variable up to 19 digits (2-byte length header)
  3 => "n 6",      # Field 3: Numeric, fixed 6 digits (no header)
  4 => "n 12",     # Field 4: Numeric, fixed 12 digits
  35 => "z ..37",  # Field 35: Track 2 data, variable up to 37
  52 => "b 64",    # Field 52: Binary, 8 bytes (64 bits)
  # ... more fields
}
```

### Parsing a Message

```elixir
# Raw ISO message (without MTI/TPDU)
raw_msg = <<0x22, 0x00, 0x02, 0x20, 0x00, 0x00, 0x04, 0x00, ...>>

# Parse into a map
fields = Ex_Iso8583.extract_iso_msg(raw_msg, msg_type_bcd, field_format)
# => %{2 => "1234567890123456789", 3 => "123456", 4 => "000000001234", ...}
```

### Building a Message

```elixir
# Define field data
data = %{
  2 => "1234567890123456789",
  3 => "123456",
  4 => "000000001234",
  35 => "1234567890123456789D231201234567890"
}

# Build ISO message binary
iso_msg = Ex_Iso8583.form_iso_msg(data, msg_type_bcd, field_format)
# => <<0x22, 0x00, 0x02, 0x20, ...>>
```

## ISO 8583 Message Structure

```
+--------+--------+----------+------------------+
|  MTI   | Bitmap |  Fields  |   Field Data     |
| 4 bytes| 8/16   | (Variable) per bitmap    |
+--------+--------+----------+------------------+
```

1. **MTI** (Message Type Indicator) - 4 digits defining the message class
2. **Bitmap** - Indicates which fields are present
3. **Fields** - Data elements as defined by the bitmap

## Data Type Details

### BCD (Binary Coded Decimal)
- Each byte contains 2 digits (nibbles)
- "1234" becomes `0x12 0x34`
- Odd-length values are left-padded with "0" before encoding

### Track 2 (Type Z)
- Used for magnetic stripe data (Field 35)
- Similar to BCD but with different padding rules

### ASCII
- Direct character representation
- "1234" is `0x31 0x32 0x33 0x34`

### Binary
- Raw bytes, no encoding conversion

## Testing

Run the test suite:

```bash
mix test
```

The project uses property-based testing with `stream_data` for robust validation.

## License

See [LICENSE](LICENSE) file for details.
