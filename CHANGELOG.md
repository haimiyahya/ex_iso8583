# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.4.0] - 2025-02-02

### Added
- **Custom Error Types** (`lib/iso_8583/errors.ex`)
  - `UndefinedFieldError` - Raised when field not defined in field_format
  - `InvalidFormatError` - Raised when field format string is invalid
  - `InvalidFieldValueError` - Raised when field value doesn't match format
  - `BitmapError` - Raised when bitmap parsing fails
  - `MessageLengthError` - Raised when message length is invalid

- **Input Data Validation** (`lib/iso_8583/validator.ex`)
  - `validate_field_value/4` - Validates field values against data types
  - `validate_message/1` - Validates message has minimum required data
  - `validate_format_definition/2` - Validates format definition strings
  - BCD validation (only digits 0-9)
  - Track 2 validation (ISO/IEC 7813 format)
  - Hex validation
  - Max length enforcement

- **MTI (Message Type Indicator) Support** (`lib/iso_8583/mti.ex`)
  - `parse/1` - Parse MTI into version, class, function, origin
  - `format/1` - Format parsed MTI back to string
  - `valid?/1` - Validate MTI format
  - `describe/1` - Human-readable MTI description
  - Predicates: `request?/1`, `response?/1`, `authorization?/1`, `financial?/1`
  - Common MTI constants (authorization_request, financial_request, etc.)

- **Extended Data Type Support** (`lib/iso_8583/iso_field_format.ex`)
  - LLVAR notation: `"n LLVAR 19"` equivalent to `"n ..19"`
  - LLLVAR notation: `"n LLLVAR 999"` equivalent to `"n ...999"`
  - LLLLVAR notation: `"n LLLLVAR 9999"` equivalent to `"n ....9999"`
  - LVAR notation: `"n LVAR 6"` equivalent to `"n .6"`
  - `normalize_format_string/1` - Converts keywords to dot notation

- **TPDU Handling** (`lib/iso_8583/tpdu.ex`)
  - `parse/2` - Parse TPDU binary into destination/source
  - `format/2` - Format TPDU map to binary
  - `valid?/2` - Validate TPDU format
  - `extract/2` - Extract TPDU from message
  - `prepend/3` - Prepend TPDU to message
  - `format_address/1`, `parse_address/1` - Address utilities

- **Message Validation Suite** (`lib/iso_8583/message_validator.ex`)
  - `validate_message/4` - Complete message validation
  - `validate_all_fields_defined/2` - Check all fields are defined
  - `validate_field_values/3` - Validate field values match format
  - `validate_required_fields_for_mti/2` - Check required fields
  - `validate_field_dependencies/1` - Check field dependencies
  - `validate_financial_message/1` - Financial message validation
  - `validate_authorization_message/1` - Authorization message validation
  - `validation_report/4` - Generate validation report

- **Compile-Time DSL** (`lib/iso_8583/dsl.ex`)
  - `defisoformat` macro for defining message formats
  - `field` macro for defining individual fields
  - Auto-generates `field_format/0`, `defined_fields/0`, `build/2`, `parse/2`

- **Documentation**
  - `ROADMAP.md` - Documented potential improvements
  - Enhanced module documentation with @moduledoc
  - Added @type and @spec attributes throughout

### Changed
- **Error Handling** - Replaced `RuntimeError` with specific exception types
- **API** - Updated main API to use custom error types
- **Type Specs** - Added comprehensive @spec and @type attributes
- **Version** - Bumped from 0.3.2 to 0.4.0

### Fixed
- Error message formatting to avoid charlist representation for single-element lists
- Format string validation to support both uppercase and lowercase data type codes
- Validation regex to support multi-letter type codes (e.g., "an")

## [0.3.2] - Previous Release

### Features
- Basic ISO 8583 message parsing and formatting
- Bitmap handling (primary and secondary)
- Field extraction and formatting
- Track 2 data support
- Property-based tests with StreamData

---

## Module Structure

```
lib/
├── iso_8583.ex                 # Main API
├── iso_8583/
│   ├── errors.ex              # Custom exception types
│   ├── validator.ex           # Input validation
│   ├── mti.ex                 # Message Type Indicator handling
│   ├── tpdu.ex                # TPDU handling
│   ├── message_validator.ex   # Message validation suite
│   ├── dsl.ex                 # Compile-time DSL
│   ├── iso_bitmap.ex          # Bitmap operations (top-level)
│   ├── iso_field.ex           # Field operations (top-level)
│   ├── iso_field_format.ex    # Format parsing
│   └── util.ex                # Utility functions
```

---

## Migration Guide

### From 0.3.x to 0.4.0

#### Error Handling
Previously, the library raised `RuntimeError` for all errors. Now it raises specific exception types:

```elixir
# Before
try do
  Ex_Iso8583.form_iso_msg(data, msg_type, field_format)
rescue
  e in RuntimeError -> handle_error(e)
end

# After
try do
  Ex_Iso8583.form_iso_msg(data, msg_type, field_format)
rescue
  e in Ex_Iso8583.Errors.UndefinedFieldError -> handle_undefined(e)
  e in Ex_Iso8583.Errors.InvalidFieldValueError -> handle_invalid_value(e)
end
```

#### Extended Format Notation
New format notations are now supported:

```elixir
# All equivalent:
field_format = %{
  2 => "n ..19",      # Dot notation (original)
  2 => "n LLVAR 19",  # LLVAR notation (new)
}

# All equivalent:
field_format = %{
  48 => "n ...999",      # Dot notation (original)
  48 => "n LLLVAR 999",  # LLLVAR notation (new)
}
```
