defmodule Ex_Iso8583.TransactionRequest do
  @moduledoc """
  DSL for defining ISO 8583 request types (for the sending party).

  This module complements `Ex_Iso8583.TransactionType` (which is for receiving/parsing)
  by providing a DSL for defining and sending ISO 8583 request messages.

  ## Key Features

  - **Compile-time validation** - Ensures mandatory fields are defined at compile time
  - **Request formation** - Forms ISO 8583 binary messages from structs
  - **Type-safe pairing** - Links requests with expected response types
  - **Field validation** - Validates field values before forming messages

  ## Architecture

      ┌─────────────────────────────────────────────────────────────────┐
      │                     Sending Party (Gateway/Acquirer)             │
      │                                                                  │
      │  ┌──────────────────┐         ┌─────────────────────────────┐   │
      │  │ TransactionRequest│────────►│     form_and_validate/3      │   │
      │  │   (DSL for        │         │  - Validates mandatory fields│   │
      │  │    requests)      │         │  - Forms ISO binary          │   │
      │  └──────────────────┘         └─────────────────────────────┘   │
      │            │                                                    │
      │            ▼                                                    │
      │  ┌─────────────────────────────────────────────────────────────┐│
      │  │                   Transport Layer                           ││
      │  │  - WebSocket.Client.send_and_wait/3                        ││
      │  │  - TCP.Client.send_and_wait/3                              ││
      │  │  - HTTP.Client.send_and_wait/3                             ││
      │  └─────────────────────────────────────────────────────────────┘│
      │                                                                  │
      └─────────────────────────────────────────────────────────────────┘

  ## Comparison: TransactionType vs TransactionRequest

  | Aspect | TransactionType | TransactionRequest |
  |--------|----------------|-------------------|
  | Purpose | Parsing incoming messages | Forming outgoing messages |
  | Direction | Receiver (Server) | Sender (Client) |
  | Main Function | `parse_and_validate/4` | `form_and_validate/3` |
  | Use Case | Acquirer receiving requests | Gateway sending requests |

  ## Quick Start

  Define a request type:

      defmodule SaleRequest do
        use Ex_Iso8583.TransactionRequest

        defstruct [
          :pan,
          :processing_code,
          :amount,
          :stan,
          :terminal_id,
          :merchant_id
        ]

        request "0200" do
          # Map struct fields to ISO field numbers
          fields %{
            pan: {2, "n ..19"},
            processing_code: {3, "n 6"},
            amount: {4, "n 12"},
            stan: {11, "n 6"},
            terminal_id: {41, "ans 8"},
            merchant_id: {42, "ans 15"}
          }

          # Fields that must be present before forming the message
          mandatory [:pan, :amount, :stan, :terminal_id, :merchant_id]

          # Expected response type (for type-safe pairing)
          response_type SaleResponse
        end
      end

  Then use it to send a request:

      # Create the request struct
      request = %SaleRequest{
        pan: "1234567890123456",
        amount: "000000001234",  # 12.34 in cents
        stan: "000001",
        terminal_id: "TERM0001",
        merchant_id: "MERCHANT01"
      }

      # Form the binary message with validation
      msg_type = %{bitmap_type: :binary, field_header_type: :bcd}
      field_formats = SaleRequest.field_formats()

      case SaleRequest.form_and_validate(request, msg_type, field_formats) do
        {:ok, iso_binary} ->
          # Send via transport
          {:ok, response} = Transport.send_and_wait(iso_binary)

          # Parse response using the paired response type
          {:ok, parsed} = SaleResponse.parse(response, msg_type, field_formats)

        {:error, {:missing_fields, fields}} ->
          # Handle missing fields
          IO.puts("Missing required fields: \#{inspect(fields)}")
      end

  ## Compile-Time Validation

  The following validations occur at compile time:

  1. **Always mandatory fields** - Fields 11 (STAN), 41 (TID), 42 (MID) must be
     declared in either `mandatory` or `optional`
  2. **Field mapping consistency** - All fields in `mandatory`/`optional` must be
     defined in `fields` mapping
  3. **Field format syntax** - Field format strings must be valid ISO 8583 format

  ## Request Definition Options

      request "0200" do
        fields %{
          field_name: {field_number, "format"},
          # Example: pan: {2, "n ..19"}
        }

        mandatory [:field1, :field2]
        optional [:field3]

        response_type ResponseModule
      end

  ### Field Format Syntax

  | Format | Description | Example |
  |--------|-------------|---------|
  | `"n 6"` | Fixed 6 numeric digits | `{3, "n 6"}` - Processing Code |
  | `"n ..19"` | Variable numeric, max 19 digits | `{2, "n ..19"}` - PAN |
  | `"ans 8"` | Fixed 8 alphanumeric | `{41, "ans 8"}` - TID |
  | `"ans ..15"` | Variable alphanumeric, max 15 | `{42, "ans ..15"}` - MID |

  ## Functions Generated

  When you use `TransactionRequest`, the following functions are generated:

  - `mti/0` - Returns the MTI for this request type
  - `field_mapping/0` - Returns the field map (struct field => ISO field number)
  - `field_formats/0` - Returns the field formats map (ISO field number => format string)
  - `mandatory_fields/0` - Returns the list of mandatory field names
  - `optional_fields/0` - Returns the list of optional field names
  - `response_type/0` - Returns the paired response type module (if declared)
  - `form_and_validate/3` - Forms binary from struct with validation
  - `new/1` - Creates a new request struct with automatic padding

  ## Type-Safe Request-Response Pattern

  Define paired request and response modules:

      defmodule AuthRequest do
        use Ex_Iso8583.TransactionRequest

        defstruct [:pan, :amount, :stan, :terminal_id, :merchant_id]

        request "0100" do
          fields %{
            pan: {2, "n ..19"},
            amount: {4, "n 12"},
            stan: {11, "n 6"},
            terminal_id: {41, "ans 8"},
            merchant_id: {42, "ans 15"}
          }
          mandatory [:pan, :amount, :stan, :terminal_id, :merchant_id]
          response_type AuthResponse
        end
      end

      defmodule AuthResponse do
        use Ex_Iso8583.TransactionType

        defstruct [:response_code, :stan, :auth_code]

        transaction_type "0110" do
          fields %{
            response_code: {39, "an 2"},
            stan: {11, "n 6"},
            auth_code: {38, "an 6"}
          }
          mandatory [:response_code, :stan]
        end
      end

  Then create a type-safe send function:

      def send_auth(request \\ %AuthRequest{}) do
        msg_type = %{bitmap_type: :binary, field_header_type: :bcd}

        with {:ok, binary} <- AuthRequest.form_and_validate(request, msg_type, AuthRequest.field_formats()),
             {:ok, response_binary} <- Transport.send_and_wait(binary),
             {:ok, response} <- AuthResponse.parse_and_validate(response_binary, msg_type, AuthResponse.field_formats()) do
          {:ok, response}
        end
      end
  """

  @always_mandatory_field_numbers [11, 41, 42]

  @doc """
  Using macro that sets up the module for request type definition.
  """
  defmacro __using__(_opts) do
    quote do
      import Ex_Iso8583.TransactionRequest

      Module.register_attribute(__MODULE__, :request_config, accumulate: true)
      @before_compile Ex_Iso8583.TransactionRequest
    end
  end

  @doc """
  Defines a request type with MTI and configuration.

  ## Parameters

  - `mti` - Message Type Indicator (e.g., "0200", "0400")

  ## Options

  - `:processing_code` - Processing code for this request type (optional)

  ## Example

      request "0200" do
        fields %{pan: {2, "n ..19"}, amount: {4, "n 12"}}
        mandatory [:pan, :amount]
      end

      request "0200", processing_code: "00*" do
        fields %{pan: {2, "n ..19"}, amount: {4, "n 12"}}
        mandatory [:pan, :amount]
      end
  """
  defmacro request(mti, opts \\ [], do: block) do
    quote do
      @request_config {:mti, unquote(mti)}
      @request_config {:processing_code, unquote(Keyword.get(opts, :processing_code, "*"))}
      unquote(block)
    end
  end

  @doc """
  Defines the field mapping from struct fields to ISO 8583 field numbers with formats.

  ## Format

      fields %{
        field_name: {field_number, "format_string"}
      }

  ## Example

      fields %{
        pan: {2, "n ..19"},           # Field 2, variable numeric up to 19 digits
        processing_code: {3, "n 6"},  # Field 3, fixed 6 numeric digits
        amount: {4, "n 12"},          # Field 4, fixed 12 numeric digits
        stan: {11, "n 6"},            # Field 11, fixed 6 numeric digits
        terminal_id: {41, "ans 8"},   # Field 41, fixed 8 alphanumeric
        merchant_id: {42, "ans 15"}   # Field 42, fixed 15 alphanumeric
      }

  """
  defmacro fields(mapping) do
    quote do
      @request_config {:fields, unquote(Macro.escape(mapping))}
    end
  end

  @doc """
  Defines mandatory fields that must be present before forming the message.

  ## Example

      mandatory [:pan, :amount, :stan, :terminal_id, :merchant_id]
  """
  defmacro mandatory(fields) do
    quote do
      @request_config {:mandatory, unquote(Macro.escape(fields))}
    end
  end

  @doc """
  Defines optional fields that may be present.

  ## Example

      optional [:cardholder_name, :currency_code]
  """
  defmacro optional(fields) do
    quote do
      @request_config {:optional, unquote(Macro.escape(fields))}
    end
  end

  @doc """
  Defines the expected response type for this request.

  This enables type-safe request-response pairing.

  ## Example

      response_type SaleResponse
  """
  defmacro response_type(module) do
    quote do
      @request_config {:response_type, unquote(module)}
    end
  end

  @doc """
  Validates field format string syntax.
  """
  def validate_field_format(format_string) when is_binary(format_string) do
    case String.split(format_string, " ", trim: true) do
      [type, length] ->
        validate_type_and_length(type, length)

      _ ->
        {:error, :invalid_format}
    end
  end

  defp validate_type_and_length(type, length) do
    # Valid types: n, ns, an, ans, asn, as, a, b, z
    # Also allow any combination that starts with valid type
    valid_types = ["n", "ns", "an", "ans", "asn", "as", "a", "b", "z"]

    type_valid = type in valid_types or
      String.starts_with?(type, "n") or
      String.starts_with?(type, "ans") or
      String.starts_with?(type, "an") or
      String.starts_with?(type, "asn") or
      String.starts_with?(type, "a") or
      String.starts_with?(type, "b") or
      String.starts_with?(type, "z")

    length_valid = validate_length_spec(length)

    if type_valid and length_valid do
      :ok
    else
      {:error, :invalid_format}
    end
  end

  defp validate_length_spec("." <> rest) do
    # Variable length: "..19" or just "."
    case rest do
      "" -> :ok
      num when is_binary(num) ->
        case Integer.parse(num) do
          {_, ""} -> :ok
          _ -> :error
        end
      _ -> :error
    end
  end

  defp validate_length_spec(length) do
    # Fixed length: "6", "12", etc.
    case Integer.parse(length) do
      {_, ""} -> :ok
      _ -> :error
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    config = Module.get_attribute(env.module, :request_config)

    {mti, processing_code, fields, mandatory, optional, response_type} = build_config(config)

    # Compile-time validation
    validate_compile_time!(env.module, mti, fields, mandatory, optional)

    quote do
      @mti unquote(macro_escape(mti))
      @processing_code unquote(macro_escape(processing_code))
      @field_mapping unquote(Macro.escape(fields))
      @field_formats unquote(Macro.escape(build_field_formats(fields)))
      @mandatory_fields unquote(Macro.escape(mandatory))
      @optional_fields unquote(Macro.escape(optional))
      @response_type unquote(Macro.escape(response_type))

      @doc """
      Returns the MTI for this request type.
      """
      def mti, do: @mti

      @doc """
      Returns the processing code pattern for this request type.
      """
      def processing_code, do: @processing_code

      @doc """
      Returns the field mapping (struct fields to ISO field numbers).
      """
      def field_mapping, do: @field_mapping

      @doc """
      Returns the field formats map (ISO field numbers to format strings).
      """
      def field_formats, do: @field_formats

      @doc """
      Returns mandatory field names.
      """
      def mandatory_fields, do: @mandatory_fields

      @doc """
      Returns optional field names.
      """
      def optional_fields, do: @optional_fields

      @doc """
      Returns the expected response type module (if declared).
      """
      def response_type, do: @response_type

      @doc """
      Creates a new request struct with automatic field padding.

      ## Examples

          request = SaleRequest.new(%{
            pan: "1234567890123456",
            amount: 12_34,  # Integer amount in cents
            stan: 1,        # Integer STAN
            terminal_id: "TERM0001"
          })

      The `new/1` function automatically pads:
      - Integer amounts to 12 digits with leading zeros
      - Integer STAN to 6 digits with leading zeros
      - Uses values as-is if already strings

      """
      def new(attrs) when is_map(attrs) do
        new(attrs, __MODULE__)
      end

      defp new(attrs, module) do
        struct_data =
          Enum.reduce(attrs, %{}, fn {key, value}, acc ->
            padded_value = pad_field_value(key, value, module)
            Map.put(acc, key, padded_value)
          end)

        struct(module, struct_data)
      end

      defp pad_field_value(:amount, value, _module) when is_integer(value) do
        value |> to_string() |> String.pad_leading(12, "0")
      end
      defp pad_field_value(:amount, value, _module) when is_binary(value), do: value
      defp pad_field_value(:stan, value, _module) when is_integer(value) do
        value |> to_string() |> String.pad_leading(6, "0")
      end
      defp pad_field_value(:stan, value, _module) when is_binary(value), do: value
      defp pad_field_value(_key, value, _module), do: value

      @doc """
      Forms and validates an ISO 8583 binary message from this request struct.

      Validates that all mandatory fields are present, then forms the message.

      ## Parameters

        - `request` - The request struct containing field values
        - `msg_type` - Message type configuration
        - `field_format` - Field format definitions (use `field_formats/0`)

      ## Returns

        - `{:ok, binary}` - Successfully formed message
        - `{:error, {:missing_fields, mti, fields}}` - Missing mandatory fields
        - `{:error, reason}` - Other errors

      ## Example

          msg_type = %{bitmap_type: :binary, field_header_type: :bcd}

          case SaleRequest.form_and_validate(request, msg_type, SaleRequest.field_formats()) do
            {:ok, iso_binary} -> send_message(iso_binary)
            {:error, {:missing_fields, _mti, fields}} -> handle_missing(fields)
          end
      """
      def form_and_validate(request, msg_type, field_format) do
        Ex_Iso8583.TransactionRequest.form_and_validate(
          __MODULE__,
          request,
          msg_type,
          field_format
        )
      end

      @doc """
      Sends this request and waits for the paired response.

      This is a convenience function that combines:
      1. Form and validate the request
      2. Send via transport
      3. Parse the response using the paired response type

      ## Parameters

        - `request` - The request struct
        - `transport` - Transport module (must implement `send_and_wait/3`)
        - `msg_type` - Message type configuration
        - `opts` - Additional options

      ## Options

        - `:timeout` - Response timeout in milliseconds (default: 30000)

      ## Returns

        - `{:ok, response_struct}` - Successfully sent and received response
        - `{:error, reason}` - Error occurred

      ## Example

          {:ok, response} = SaleRequest.send_and_wait(
            request,
            MyTransportClient,
            %{bitmap_type: :binary, field_header_type: :bcd}
          )
      """
      def send_and_wait(request, transport, msg_type, opts \\ []) do
        Ex_Iso8583.TransactionRequest.send_and_wait(
          __MODULE__,
          request,
          transport,
          msg_type,
          opts
        )
      end
    end
  end

  defp build_config(config) do
    mti = get_config(config, :mti)
    processing_code = get_config(config, :processing_code, "*")
    fields = get_config(config, :fields, %{}) |> unquote_ast()
    mandatory = get_config(config, :mandatory, []) |> unquote_ast()
    optional = get_config(config, :optional, []) |> unquote_ast()
    response_type = get_config(config, :response_type, nil) |> unquote_ast()

    {mti, processing_code, fields, mandatory, optional, response_type}
  end

  defp get_config(config, key, default \\ nil) do
    Enum.find_value(config, default, fn
      {^key, val} -> val
      _ -> nil
    end)
  end

  # Unquote AST at compile time to get actual values
  defp unquote_ast(ast) do
    {val, _} = Code.eval_quoted(ast, [], __ENV__)
    val
  end

  defp macro_escape(nil), do: nil
  defp macro_escape(term), do: Macro.escape(term)

  defp build_field_formats(fields_map) do
    Enum.map(fields_map, fn {_field_name, {field_num, format}} ->
      {field_num, format}
    end)
    |> Map.new()
  end

  # Always mandatory ISO 8583 fields (critical for transaction processing)
  @always_mandatory_field_numbers [11, 41, 42]

  defp validate_compile_time!(module, mti, fields, mandatory, optional) do
    field_keys = Map.keys(fields)

    # Validate 1: Always mandatory fields must be included
    always_mandatory_names = @always_mandatory_field_numbers
      |> Enum.map(fn field_num ->
        Enum.find(fields, fn {_key, {num, _fmt}} -> num == field_num end)
      end)
      |> Enum.filter(&(&1))
      |> Enum.map(fn {key, _val} -> key end)

    missing_always_mandatory = always_mandatory_names -- (mandatory ++ optional)
    if missing_always_mandatory != [] do
      raise CompileError,
        description: """
        [Ex_Iso8583.TransactionRequest] Fields 11 (STAN), 41 (Terminal ID), and 42 (Merchant ID) \
        are always mandatory for ISO 8583 compliance.

        Module: #{inspect(module)}
        MTI: #{inspect(mti)}

        Missing from `mandatory` or `optional`:
            #{inspect(missing_always_mandatory)}

        Please add these fields to your `fields` and `mandatory` lists:
            request "#{inspect(mti)}" do
              fields %{
                # ... your existing fields ...
                stan: {11, "n 6"},        # STAN - System Trace Audit Number
                terminal_id: {41, "ans 8"}, # Terminal ID
                merchant_id: {42, "ans 15"}  # Merchant ID
              }

              mandatory #{inspect([:stan] ++ mandatory)}
            end
        """
    end

    # Validate 2: All mandatory fields must exist in fields mapping
    invalid_mandatory = mandatory -- field_keys
    if invalid_mandatory != [] do
      raise CompileError,
        description: """
        [Ex_Iso8583.TransactionRequest] Fields in `mandatory` but not defined in `fields` mapping:

            #{inspect(invalid_mandatory)}

        Please add these fields to the fields mapping, or remove them from mandatory.
        """
    end

    # Validate 3: All optional fields must exist in fields mapping
    invalid_optional = optional -- field_keys
    if invalid_optional != [] do
      raise CompileError,
        description: """
        [Ex_Iso8583.TransactionRequest] Fields in `optional` but not defined in `fields` mapping:

            #{inspect(invalid_optional)}

        Please add these fields to the fields mapping, or remove them from optional.
        """
    end

    # Validate 4: mandatory and optional should not overlap
    overlap = MapSet.new(mandatory) |> MapSet.intersection(MapSet.new(optional)) |> MapSet.to_list()
    if overlap != [] do
      raise CompileError,
        description: """
        [Ex_Iso8583.TransactionRequest] Fields defined in both `mandatory` and `optional`:

            #{inspect(overlap)}

        A field can be either mandatory or optional, not both.
        """
    end

    :ok
  end

  @doc """
  Forms and validates an ISO 8583 binary message from a request struct.

  Validates that all mandatory fields are present and have non-nil values,
  then forms the message with field value validation enabled.

  ## Parameters

    - `module` - The request type module
    - `request` - The request struct containing field values
    - `msg_type` - Message type configuration (e.g., %{bitmap_type: :binary, field_header_type: :bcd})
    - `field_format` - Field format definitions

  ## Returns

    - `{:ok, binary}` - Successfully formed message (including MTI prefix)
    - `{:error, {:missing_fields, mti, field_names}}` - Missing mandatory fields
    - `{:error, reason}` - Other errors
  """
  def form_and_validate(module, request, msg_type, field_format) do
    mti = module.mti()
    field_mapping = module.field_mapping()
    mandatory = module.mandatory_fields()

    # Check for missing mandatory fields in the struct
    missing = check_missing_mandatory_in_struct(request, mandatory)

    if missing != [] do
      {:error, {:missing_fields, mti, missing}}
    else
      # Convert struct to ISO field data map
      iso_data = struct_to_iso_data(request, field_mapping)

      # Form the message with validation enabled
      # form_iso_msg returns just the bitmap + fields, so we prepend the MTI
      case Ex_Iso8583.form_iso_msg(iso_data, msg_type, field_format, validate: true) do
        {:ok, binary} -> {:ok, mti <> binary}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Sends a request and waits for the paired response.

  This is a type-safe operation that:
  1. Forms and validates the request
  2. Sends via the transport
  3. Parses the response using the paired response type

  ## Parameters

    - `request_module` - The request type module
    - `request` - The request struct
    - `transport` - Transport module (must implement `send_and_wait/3`)
    - `msg_type` - Message type configuration
    - `opts` - Additional options

  ## Returns

    - `{:ok, response_struct}` - Successfully sent and received response
    - `{:error, reason}` - Error occurred
  """
  def send_and_wait(request_module, request, transport, msg_type, opts \\ []) do
    with {:ok, request_binary} <- form_and_validate(request_module, request, msg_type, request_module.field_formats()),
         {:ok, response_binary} <- transport.send_and_wait(request_binary, opts),
         {:ok, response} <- parse_response(request_module, response_binary, msg_type, opts) do
      {:ok, response}
    end
  end

  defp parse_response(request_module, response_binary, msg_type, _opts) do
    response_type_module = request_module.response_type()

    if response_type_module do
      # Get field formats from response type if available, otherwise use request's
      field_formats = if function_exported?(response_type_module, :field_formats, 0) do
        response_type_module.field_formats()
      else
        request_module.field_formats()
      end

      # Use the paired response type to parse
      if function_exported?(response_type_module, :parse_and_validate, 3) do
        response_type_module.parse_and_validate(response_binary, msg_type, field_formats)
      else
        # Fallback to TransactionType parsing
        Ex_Iso8583.TransactionType.parse_and_validate(
          response_type_module,
          response_binary,
          msg_type,
          field_formats
        )
      end
    else
      # No response type defined, return raw binary
      {:ok, response_binary}
    end
  end

  # Check which mandatory fields are missing or nil in the struct
  defp check_missing_mandatory_in_struct(struct, mandatory) do
    Enum.filter(mandatory, fn field_name ->
      value = Map.get(struct, field_name)
      is_nil(value) or value == ""
    end)
  end

  # Convert struct to ISO field data map using field_mapping
  defp struct_to_iso_data(struct, field_mapping) do
    Enum.reduce(field_mapping, %{}, fn {field_name, {iso_field_num, _format}}, acc ->
      case Map.get(struct, field_name) do
        nil -> acc  # Skip nil values
        value -> Map.put(acc, iso_field_num, value)
      end
    end)
  end
end
