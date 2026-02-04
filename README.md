# Ex_Iso8583

An Elixir library for parsing and formatting ISO 8583 messages - the international standard for systems that exchange electronic transaction information.

## Architecture

### Module Overview

```
Ex_Iso8583
    |
    +-- IsoBitmap            - Bitmap management (creation, parsing, transformation)
    +-- IsoField             - Field extraction and formatting
    +-- IsoFieldFormat       - Field format definition parsing
    +-- IsoMsg               - Message structure definition
    +-- Util                 - Utility functions for data manipulation
    |
    +-- TransactionType      - Type-safe transaction struct definitions
    +-- TransactionTypeGroup - Transaction grouping (request/response pairs)
    |
    +-- TransactionProcessor - Pure functional transaction processing DSL
         +-- Middleware       - Logging, timing, validation, transformation
         +-- TimeoutWrapper   - Timeout handling with automatic timeout response
    |
    +-- Iso8583.Connectivity - Transport abstraction layer
         +-- Context          - Struct for transport metadata
         +-- Transport        - Behaviour for transport implementations
         +-- Handler          - Generic handler connecting processor + transport
         +-- Transport.TCP    - TCP Server and Client implementations
         +-- Transport.HTTP   - HTTP Server and Client implementations (planned)
         +-- Transport.UDP    - UDP Server and Client implementations (planned)
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

### Transaction Types

#### `TransactionType` - Type-Safe Transaction Definitions

Define strongly-typed transaction structs with automatic encoding/decoding:

```elixir
defmodule SaleRequest do
  use Ex_Iso8583.TransactionType

  transaction_type "0200", "001000"

  defstruct [:pan, :amount, :stan, :terminal_id, :processing_code]

  field_mapping %{
    pan: 2,
    amount: 4,
    stan: 11,
    terminal_id: 41,
    processing_code: 3
  }

  field_formats %{
    2 => "n ..19",
    3 => "n 6",
    4 => "n 12",
    11 => "n 6",
    41 => "ans ..8"
  }

  mandatory_fields [:pan, :amount, :stan, :processing_code]
end
```

**Key features:**
- Automatic ISO message encoding/decoding
- Type-safe field mapping
- Mandatory field validation
- Support for copyable fields (request → response)

#### `TransactionTypeGroup` - Transaction Grouping

Group related transaction types (request/response pairs):

```elixir
defmodule SaleTransaction do
  use Ex_Iso8583.TransactionTypeGroup

  request SaleRequest
  response SaleResponse

  response_mti "0210"
end
```

### Transaction Processing

#### `TransactionProcessor` - Pure Functional Handler DSL

The `TransactionProcessor` provides a macro-based DSL for defining transaction handlers with hooks and middleware. It follows a pure functional approach with no processes or supervision.

**Processing Flow:**

```
┌─────────────────────────────────────────────────────────────────────┐
│                         TransactionProcessor                         │
│                                                                     │
│  1. PARSE        Raw ISO Message ──► Request Struct                 │
│  2. FIND         Match Request Module ──► Handler                    │
│  3. VALIDATE     Check Mandatory Fields                              │
│  4. BEFORE HOOKS Execute validation/transform (can raise errors)     │
│  5. HANDLE       Execute business logic ──► Response Struct          │
│  6. AFTER HOOKS  Execute logging/post-processing                      │
│  7. RETURN       {:ok, Response} | {:error, Reason}                  │
└─────────────────────────────────────────────────────────────────────┘
```

**Define a processor:**

```elixir
defmodule MyProcessor do
  use TransactionProcessor

  config error_response_code_field: 39,
        error_message_field: 60

  # Sale handler with validation and logging hooks
  defhandler :sale, SaleRequest, SaleResponse,
    before_hooks: [:validate_amount],
    after_hooks: [:log_response] do

    def handle(%SaleRequest{amount: amount, stan: stan}) do
      # Business logic
      %SaleResponse{
        response_code: "00",
        amount: amount,
        stan: stan,
        auth_code: generate_auth_code()
      }
    end

    # Hooks must be public (def, not defp)
    def validate_amount(%SaleRequest{amount: amt} = req) when amt > 0, do: req
    def validate_amount(_), do: raise(ArgumentError, "Invalid amount")

    def log_response(resp), do: resp

    defp generate_auth_code, do: :rand.uniform(999_999) |> to_string()
  end

  # Void handler
  defhandler :void, VoidRequest, VoidResponse do
    def handle(%VoidRequest{stan: stan}) do
      %VoidResponse{response_code: "00", stan: stan}
    end
  end
end
```

**Use the processor:**

```elixir
# Process raw ISO message
{:ok, response} = MyProcessor.process(raw_iso_message)

# Process pre-parsed struct
request = %SaleRequest{amount: 10000, stan: "000123", pan: "...", terminal_id: "TERM001"}
{:ok, response} = MyProcessor.process_struct(request)
```

**Middleware:**

```elixir
defmodule MyProcessor do
  use TransactionProcessor

  # Built-in middleware
  use_middleware TransactionProcessor.Middleware.Logger
  use_middleware TransactionProcessor.Middleware.Timer

  # Or custom middleware
  defmodule AuthMiddleware do
    @behaviour TransactionProcessor.Middleware

    def call(request, next) do
      if authenticated?(request) do
        next.(request)
      else
        {:error, :unauthorized}
      end
    end
  end
end
```

**Key features:**
- **Type-safe handlers** - Compile-time validation for request/response types
- **Before/after hooks** - Validation, transformation, logging
- **Middleware pipeline** - Composable cross-cutting concerns
- **Error handling** - Automatic error response generation
- **Pure functional** - No processes, no supervision (handled separately)

#### `TransactionProcessor.TimeoutWrapper` - Timeout Handling

The `TimeoutWrapper` adds timeout capability to TransactionProcessor while keeping the core processor pure functional. It handles the side effects (timing) in a separate layer.

**Why use TimeoutWrapper?**

- **Database delays** - Protect against slow DB queries hanging transactions
- **External service calls** - Timeout when downstream services are unresponsive
- **Resource management** - Prevent resource exhaustion from hung transactions
- **SLA compliance** - Ensure transactions complete within time limits

**Configuration:**

```elixir
defmodule PaymentProcessor do
  use TransactionProcessor.TimeoutWrapper,
    processor: MyProcessor,                    # Required: processor to wrap
    timeouts: %{                                # Required: per-type timeouts (ms)
      # Fast transactions
      sale: 5000,                              # 5 seconds
      void: 3000,                              # 3 seconds
      refund: 3000,                            # 3 seconds
      balance_inquiry: 2000,                   # 2 seconds

      # Slower transactions
      sale_with_cashback: 7000,                # 7 seconds
      capture: 5000,                           # 5 seconds
      reversal: 4000,                          # 4 seconds

      # Batch operations (much slower)
      batch_close: 60000,                      # 60 seconds
      settlement: 120000,                      # 2 minutes

      # Default for unknown types
      default: 5000
    },
    timeout_response_field: 39,                 # Optional: field for timeout code (default: 39)
    timeout_response_code: "68"                 # Optional: timeout value (default: "68" per ISO 8583)
end

# Process raw ISO message with timeout
{:ok, response} = PaymentProcessor.process_with_timeout(raw_iso_message)

# Process pre-parsed struct with timeout
{:ok, response} = PaymentProcessor.process_struct_with_timeout(request_struct)
```

**Transaction Type Detection:**

Transaction types are automatically detected from MTI and Processing Code:

| MTI  | Processing Code | Transaction Type    |
|------|-----------------|---------------------|
| 0200 | 001000          | sale                |
| 0200 | 002000          | sale_with_cashback  |
| 0200 | 00xxxx          | balance_inquiry     |
| 0200 | 310000          | batch_close         |
| 0220 | 001000          | refund              |
| 0400 | 001000          | capture             |
| 0420 | 001000          | capture_refund      |
| 0400 | 002000          | void                |
| 0420 | 002000          | reversal            |
| 0500 | 001000          | settlement          |
| 0800 | 001000          | network_management  |

Use a custom detector for non-standard mappings:

```elixir
defmodule CustomProcessor do
  use TransactionProcessor.TimeoutWrapper,
    processor: MyProcessor,
    timeouts: %{custom_type: 5000},
    transaction_type_detector: &MyModule.detect_transaction_type/1
end
```

**Handling Timeout Responses:**

```elixir
case PaymentProcessor.process_with_timeout(raw_message) do
  {:ok, response} ->
    case Map.get(response, 39) do
      "68" ->
        # Transaction timed out
        Logger.warning("Transaction timed out", stan: Map.get(response, 11))
        # Response still has STAN and other copied fields for reconciliation

      "00" ->
        # Transaction approved
        Logger.info("Transaction approved")

      other ->
        # Other response code
        Logger.warning("Transaction declined: #{other}")
    end

  {:error, reason} ->
    Logger.error("Processing error: #{inspect(reason)}")
end
```

**Adding to Supervision Tree:**

The TimeoutWrapper requires a Task.Supervisor. Add it to your application's children:

```elixir
# In your application.ex
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    children = [
      TransactionProcessor.TimeoutSupervisor,
      # ... other children
    ]

    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

**Timeout Response Details:**

When a timeout occurs:
- The processing task is terminated immediately
- A timeout response is generated with your configured code (default: "68")
- Common fields are copied from the request (STAN, terminal ID, etc.)
- The response struct matches your expected response module type

**Timeout Value Guidelines:**

| Transaction Type | Recommended Timeout | Reason |
|-----------------|-------------------|--------|
| balance_inquiry | 2000ms | Quick database lookup |
| sale/void/refund | 5000ms | External API calls |
| capture          | 5000ms | Acquiring funds |
| reversal         | 4000ms | Fast processing needed |
| batch_close      | 60000ms | Multiple operations |
| settlement       | 120000ms | Batch processing |

**Features:**
- Per-transaction-type timeout configuration
- Automatic timeout response generation
- Task isolation for clean termination
- Transaction type detection from MTI + processing code
- No modification to TransactionProcessor required (wrapper pattern)

## Connectivity Layer

The connectivity layer provides **transport abstraction** - decoupling how ISO 8583 messages are transferred from your business logic.

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Your Application                         │
└─────────────────────────────────────────────────────────────┘
                              │
              ┌───────────────┴───────────────┐
              │                               │
      ┌───────────────┐               ┌───────────────┐
      │  TCP Server   │               │  HTTP Server  │
      │  (Terminals)  │               │  (REST API)   │
      └───────────────┘               └───────────────┘
              │                               │
              └───────────────┬───────────────┘
                              │
              ┌───────────────────────────────────────┐
              │        Iso8583.Handler                │
              │  - Pluggable Transport               │
              │  - Your TransactionProcessor         │
              └───────────────────────────────────────┘
                              │
              ┌───────────────────────────────────────┐
              │    TransactionProcessor               │
              │    (Your business logic)              │
              └───────────────────────────────────────┘
```

### Iso8583.Handler

The `Iso8583.Handler` module provides a `use` macro that creates a GenServer handler connecting your processor with any transport:

```elixir
defmodule MyApp.PaymentHandler do
  use Iso8583.Handler,
    processor: MyApp.PaymentProcessor,
    transport: Iso8583.Transport.TCP.Server,
    transport_opts: [
      port: 8080,
      acceptors: 10
    ]
end
```

Add to your supervision tree:

```elixir
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    children = [
      # TCP Server - accepts connections from terminals
      MyApp.PaymentHandler,

      # HTTP Server - for REST API
      {Iso8583.Handler,
       processor: MyApp.PaymentProcessor,
       transport: Iso8583.Transport.HTTP.Server,
       transport_opts: [port: 4000]},

      # TCP Client - connects to upstream acquirer
      {Iso8583.Handler,
       processor: MyApp.UpstreamProcessor,
       transport: Iso8583.Transport.TCP.Client,
       transport_opts: [
         host: "acquirer.example.com",
         port: 9000
       ]}
    ]

    opts = [strategy: :one_for_one]
    Supervisor.start_link(children, opts)
  end
end
```

### Available Transports

| Transport | Type | Description |
|-----------|------|-------------|
| `Iso8583.Transport.TCP.Server` | Server | Accept TCP connections from clients |
| `Iso8583.Transport.TCP.Client` | Client | Connect to TCP server |
| `Iso8583.Transport.UDP.Server` | Server | Receive UDP datagrams |
| `Iso8583.Transport.UDP.Client` | Client | Send UDP datagrams |
| `Iso8583.Transport.HTTP.Server` | Server | HTTP server (Plug/Bandit) |
| `Iso8583.Transport.HTTP.Client` | Client | HTTP client (Finch/Req) |

### TCP Server Transport

Accepts TCP connections and receives ISO 8583 messages:

```elixir
defmodule MyApp.TerminalHandler do
  use Iso8583.Handler,
    processor: MyApp.PaymentProcessor,
    transport: Iso8583.Transport.TCP.Server,
    transport_opts: [
      port: 8080,           # Port to listen on
      acceptors: 10,         # Number of acceptor processes
      packet_handler: :raw,  # How to parse messages (:raw, :line, {:size, bytes})
      timeout: 60000         # Connection idle timeout (ms)
    ]
end
```

**Packet Handlers:**
- `:raw` - Read entire socket buffer (default)
- `:line` - Read until newline
- `{:size, bytes}` - Read fixed-size messages

### TCP Client Transport

Connects to a remote TCP server:

```elixir
defmodule MyApp.UpstreamHandler do
  use Iso8583.Handler,
    processor: MyApp.UpstreamProcessor,
    transport: Iso8583.Transport.TCP.Client,
    transport_opts: [
      host: "acquirer.example.com",
      port: 9000,
      reconnect_interval: 5000,  # Reconnect delay on disconnect (ms)
      timeout: 60000
    ]
end
```

### Iso8583.Context

The context carries transport-specific metadata alongside messages:

```elixir
# Fields in context
%Iso8583.Context{
  transport_ref: socket,        # Transport-specific reference
  client_id: "client_123",      # Optional client identifier
  peer_address: {192, 168, 1, 100},  # Client's IP address
  request_id: "req-abc123",     # Correlation ID for tracing
  transport_metadata: %{        # Transport-specific data
    connection_time: 1234567890,
    bytes_received: 1024
  }
}
```

### Custom Transport

Implement your own transport by using the `Iso8583.Transport` behaviour:

```elixir
defmodule MyCustomTransport do
  @behaviour Iso8583.Transport

  def start_link(opts) do
    # Start your transport
  end

  def send(transport_ref, data) do
    # Send data
  end

  def set_receive_callback(pid, callback) do
    # Register callback for incoming messages
  end

  def stop(pid) do
    # Stop transport
  end
end
```

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
