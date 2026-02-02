# Ex_ISO8583 Improvement Roadmap

This document outlines potential improvements to the ex_iso8583 library, categorized by priority.

## High Priority (Critical Issues)

### 1. Custom Error Types

**Current State:** The library uses generic `RuntimeError` exceptions for all error scenarios.

**Proposed Improvement:** Implement specific exception types for different failure scenarios:

- `UndefinedFieldError` - Raised when a field is not defined in field_format_definition
- `InvalidFormatError` - Raised when a field format string is invalid
- `InvalidFieldValueError` - Raised when a field value doesn't match its expected format
- `BitmapError` - Raised when bitmap parsing fails
- `MessageLengthError` - Raised when message length is invalid

**Benefits:**
- Better error handling with pattern matching on specific exceptions
- Clearer error messages for debugging
- More professional API for library users

**Files to Modify:**
- Create: `lib/iso_8583/errors.ex`
- Modify: All modules that raise errors

---

### 2. Input Data Validation

**Current State:** No validation of field values before processing. Invalid data (e.g., non-numeric characters in BCD fields) may cause silent failures or unexpected behavior.

**Proposed Improvement:** Add comprehensive validation for all data types before processing:

- **BCD fields:** Validate only numeric characters (0-9)
- **ASCII fields:** Validate printable ASCII characters
- **Track 2 (z) fields:** Validate according to ISO/IEC 7813 format
- **Binary fields:** Validate even-length hex strings
- **Length validation:** Ensure values fit within max_length constraints

**Benefits:**
- Prevent silent failures and data corruption
- Fail fast with clear error messages
- Better data integrity in financial transactions

**Files to Modify:**
- Create: `lib/iso_8583/validator.ex`
- Modify: `Ex_Iso8583`, `IsoField`

---

### 3. Error Scenario Unit Tests

**Current State:** Tests primarily use property-based testing for happy paths. Missing unit tests for error scenarios and edge cases.

**Proposed Improvement:** Add comprehensive unit tests covering:

- Invalid field format strings
- Invalid field values (wrong data type, out of range)
- Malformed messages (incorrect bitmap, truncated data)
- Empty or nil inputs
- Boundary conditions (max lengths, empty strings)
- Error message content verification

**Benefits:**
- Better reliability and confidence in the codebase
- Regression testing for error handling
- Documentation through tests

**Files to Create:**
- `test/errors_test.exs`
- `test/validator_test.exs`
- `test/edge_cases_test.exs`

---

## Medium Priority (Major Enhancements)

### 4. Message Type Indicator (MTI) Support

**Current State:** No built-in support for MTI parsing/verification. MTI is typically handled separately from the main API.

**Proposed Improvement:** Add MTI validation and message type categorization:

- Parse MTI into components (version, class, function, origin)
- Validate MTI format (4-digit numeric)
- Provide helpers for common MTI values (authorization request, response, etc.)
- Integrate MTI with message building/parsing

**Benefits:**
- Complete ISO 8583 message structure support
- More convenient API for common operations
- Better message type validation

**Files to Modify:**
- Create: `lib/iso_8583/mti.ex`
- Modify: `Ex_Iso8583` (add MTI helpers)

---

### 5. Performance Optimization

**Current State:** Multiple binary operations and string conversions on every message. Format definitions are parsed on each use.

**Proposed Improvement:**

- Cache parsed field format definitions (convert strings to tuples once)
- Optimize binary operations in hot paths
- Reduce string conversions where possible
- Use iolists for concatenation instead of binary <> operations

**Benefits:**
- Better performance for high-volume message processing
- Reduced memory allocations
- Lower latency in transaction processing

**Files to Modify:**
- `IsoFieldFormat`, `IsoField`, `Ex_Iso8583`

---

### 6. Extended Data Type Support

**Current State:** Supports basic variable-length formats (., .., ..., ....). Missing some common ISO 8583 field types.

**Proposed Improvement:** Add support for:

- LLLVAR (3-digit length header)
- LLVAR (2-digit length header)
- LLLBVAR (binary length + binary data)
- Composite fields (subfields with their own formats)
- Currency and amount fields with proper encoding

**Benefits:**
- Wider compatibility with different ISO 8583 implementations
- Support for more field types from the ISO 8583 specification

**Files to Modify:**
- `IsoFieldFormat`, `IsoField`, `Util`

---

### 7. Documentation and Type Specs

**Current State:** Some modules lack `@spec` attributes. API documentation could be more comprehensive.

**Proposed Improvement:**

- Add `@spec` attributes to all public functions
- Add more examples in documentation
- Document error conditions for each function
- Add a "Guides" section for common use cases

**Benefits:**
- Better Dialyizer support for static analysis
- Improved IDE autocomplete and documentation
- Easier onboarding for new users

**Files to Modify:**
- All modules in `lib/iso_8583/`

---

## Low Priority (Nice to Have)

### 8. TPDU Handling

**Current State:** TPDU handling is minimal. Users must manually handle TPDU headers.

**Proposed Improvement:** Complete TPDU structure support:

- Parse TPDU header (destination/source addresses)
- Validate TPDU format
- Provide TPDU building helpers
- Integrate TPDU with message API

**Files to Modify:**
- `IsoMsg` module, or create new `lib/iso_8583/tpdu.ex`

---

### 9. Message Validation Suite

**Current State:** No comprehensive message validation against ISO 8583 specifications.

**Proposed Improvement:**

- Add message integrity validation
- Validate required fields for specific MTI types
- Check field dependencies (e.g., field 4 required for financial transactions)
- Add checksum/MAC validation helpers

**Files to Modify:**
- Create: `lib/iso_8583/message_validator.ex`

---

### 10. Configuration Management

**Current State:** Message configuration (msg_type, field_format) is passed as plain maps.

**Proposed Improvement:**

- Centralized configuration with schema validation
- Named configurations (e.g., `:default`, `:ascii_mode`)
- Configuration validation on load
- Mix config integration

**Files to Modify:**
- Create: `lib/iso_8583/config.ex`

---

## Code Quality Improvements

### 11. Reduce Code Duplication

**Issue:** Similar padding logic in multiple places.

**Solution:** Consolidate common operations in `Util` module.

---

### 12. Module Organization

**Issue:** `ISOMsg` struct exists but isn't integrated with main API.

**Solution:** Consider integrating struct usage throughout the API for a more structured approach.

---

### 13. Backward Compatibility

**Issue:** Some functions handle both old tuple formats and new map formats.

**Solution:** Clean up deprecated interfaces with version migration guide.

---

## Implementation Order Recommendation

1. **Custom Error Types** - Foundation for better error handling
2. **Input Data Validation** - Prevents data corruption
3. **Error Scenario Tests** - Ensures reliability
4. **MTI Support** - Completes message structure support
5. **Extended Data Types** - Wider compatibility
6. **Performance** - Optimize after functionality is complete
7. **Documentation** - Ongoing throughout development
