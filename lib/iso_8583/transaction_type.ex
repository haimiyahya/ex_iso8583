defmodule Ex_Iso8583.TransactionType do
  @moduledoc """
  DSL for defining ISO 8583 transaction types with validation.

  This module allows you to define Elixir structs for each transaction type,
  specify field mappings from ISO 8583 field numbers, and validate mandatory fields.

  The module depends on Ex_Iso8583 but Ex_Iso8583 does not depend on this module.

  ## Example

      defmodule AuthRequest do
        use Ex_Iso8583.TransactionType

        defstruct [
          :pan,              # Primary Account Number (Field 2)
          :processing_code,  # Processing Code (Field 3)
          :amount,           # Transaction Amount (Field 4)
          :stan,             # System Trace Audit Number (Field 11)
          :terminal_id,      # Card Acceptor Terminal ID (Field 41)
          :merchant_id       # Card Acceptor ID (Field 42)
        ]

        transaction_type "0100" do
          fields %{
            pan: 2,
            processing_code: 3,
            amount: 4,
            stan: 11,
            terminal_id: 41,
            merchant_id: 42
          }

          mandatory [:pan, :processing_code, :amount, :stan, :terminal_id, :merchant_id]
        end
      end

  After defining a transaction type, you can use it:

      case AuthRequest.parse_and_validate(raw_msg, msg_type, field_format) do
        {:ok, result} ->
          # result is an AuthRequest struct with only defined fields
          IO.puts("Amount: " <> inspect(result.amount))

        {:error, reason} ->
          # Handle validation error
          IO.puts("Validation failed: " <> inspect(reason))
      end
  """

  defmacro __using__(_opts) do
    quote do
      import Ex_Iso8583.TransactionType

      Module.register_attribute(__MODULE__, :txn_config, accumulate: true)
      @before_compile Ex_Iso8583.TransactionType
    end
  end

  @doc """
  Defines a transaction type for a specific MTI and optional processing code pattern.

  ## Options
    - `:processing_code` - Processing code pattern for matching. Supports:
      - Exact match: `"020000"` matches only "020000"
      - Prefix wildcard: `"01*"` matches "010000", "011234", etc.
      - Suffix wildcard: `"*1000"` matches "001000", "021000", etc.
      - Full wildcard: `"*"` matches all processing codes (default)

  ## Always Mandatory Fields

  The following ISO 8583 fields are **always mandatory** and must be included
  in every transaction type definition (in either `mandatory` or `optional`):
  - **Field 11** - STAN (System Trace Audit Number)
  - **Field 41** - Terminal ID
  - **Field 42** - Merchant ID

  This validation is enforced at **compile time**. If you forget to include these
  fields, you will get a compilation error with a helpful message.

  ## Examples
      transaction_type "0100" do
        fields %{
          pan: 2,
          amount: 4,
          stan: 11,        # Always mandatory
          terminal_id: 41, # Always mandatory
          merchant_id: 42  # Always mandatory
        }
        mandatory [:pan, :amount, :stan, :terminal_id, :merchant_id]
      end

      transaction_type "0100", processing_code: "00*" do
        fields %{pan: 2, amount: 4, stan: 11, terminal_id: 41, merchant_id: 42}
        mandatory [:pan, :amount]
        optional [:stan, :terminal_id, :merchant_id]  # Can be optional if populated elsewhere
      end
  """
  # Handle with processing_code option and do block: transaction_type "0100", processing_code: "00*" do
  # Elixir parses this as: transaction_type("0100", processing_code: "00*", do: ...)
  # Which is 3 args: mti, keyword list, and do block
  defmacro transaction_type(mti, [{:processing_code, pattern}], do: block) do
    quote do
      @txn_config {:mti, unquote(mti)}
      @txn_config {:processing_code_pattern, unquote(pattern)}
      unquote(block)
    end
  end

  # Handle without options: transaction_type "0100" do
  # Elixir parses this as: transaction_type("0100", do: ...)
  # Which is 2 args: mti and do block
  defmacro transaction_type(mti, do: block) do
    quote do
      @txn_config {:mti, unquote(mti)}
      @txn_config {:processing_code_pattern, "*"}
      unquote(block)
    end
  end

  @doc """
  Defines field mappings and validation rules.
  """
  defmacro fields(mapping) do
    quote do
      @txn_config {:fields, unquote(Macro.escape(mapping))}
    end
  end

  @doc """
  Defines mandatory fields.
  """
  defmacro mandatory(fields) do
    quote do
      @txn_config {:mandatory, unquote(Macro.escape(fields))}
    end
  end

  @doc """
  Defines optional fields.
  """
  defmacro optional(fields) do
    quote do
      @txn_config {:optional, unquote(Macro.escape(fields))}
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    config = Module.get_attribute(env.module, :txn_config)

    {mti, proc_code_pattern, fields, mandatory, optional} = build_config(config)

    # Compile-time validation
    validate_compile_time!(env.module, mti, fields, mandatory, optional)

    quote do
      @mti unquote(macro_escape(mti))
      @processing_code_pattern unquote(macro_escape(proc_code_pattern))
      @field_mapping unquote(Macro.escape(fields))
      @mandatory_fields unquote(Macro.escape(mandatory))
      @optional_fields unquote(Macro.escape(optional))
      @field_formats unquote(Macro.escape(build_field_formats_from_fields(fields)))

      @doc """
      Returns the MTI for this transaction type.
      """
      def mti, do: @mti

      @doc """
      Returns the processing code pattern for this transaction type.
      """
      def processing_code_pattern, do: @processing_code_pattern

      @doc """
      Checks if this transaction type matches the given MTI and processing code.
      """
      def matches?(mti, processing_code) do
        @mti == mti and Ex_Iso8583.TransactionType.matches_pattern?(@processing_code_pattern, processing_code)
      end

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
      Returns allowed field names (mandatory + optional).
      """
      def allowed_fields do
        @optional_fields ++ @mandatory_fields
      end

      @doc """
      Parses and validates an ISO 8583 binary message.

      Returns `{:ok, struct}` if valid, `{:error, reason}` if validation fails.
      """
      def parse_and_validate(iso_msg, msg_type, field_format, opts \\ []) do
        Ex_Iso8583.TransactionType.parse_and_validate(
          __MODULE__,
          iso_msg,
          msg_type,
          field_format,
          opts
        )
      end

      @doc """
      Validates an already parsed ISO 8583 field map.

      Returns `{:ok, struct}` if valid, `{:error, reason}` if validation fails.
      """
      def validate_and_create(field_data, mti, processing_code, opts \\ []) do
        Ex_Iso8583.TransactionType.validate_and_create(
          __MODULE__,
          field_data,
          mti,
          processing_code,
          opts
        )
      end

      @doc """
      Creates a struct from the given data without validation.
      """
      def create(data) when is_map(data) do
        Ex_Iso8583.TransactionType.create_struct(__MODULE__, data)
      end

      @doc """
      Forms and validates an ISO 8583 binary message from this struct.

      Validates that all mandatory fields are present, then forms the message
      with field value validation enabled.

      ## Parameters
        - struct: The transaction struct containing field values
        - msg_type: Message type configuration
        - field_format: Field format definitions
        - opts: Additional options (passed through to form_iso_msg)

      ## Returns
        - `{:ok, binary}` - Successfully formed message
        - `{:error, {:missing_fields, mti, processing_code, fields}}` - Missing mandatory fields
        - `{:error, {:invalid_field_value, field, reason}}` - Field value validation failed
        - `{:error, reason}` - Other errors

      ## Example

          case SaleRequest.form_and_validate(request, msg_type, field_format) do
            {:ok, iso_msg} -> send_message(iso_msg)
            {:error, {:missing_fields, _mti, _proc, fields}} -> handle_missing(fields)
            {:error, {:invalid_field_value, field, reason}} -> handle_invalid(field, reason)
          end
      """
      def form_and_validate(struct, msg_type, field_format, opts \\ []) do
        Ex_Iso8583.TransactionType.form_and_validate(
          __MODULE__,
          struct,
          msg_type,
          field_format,
          opts
        )
      end
    end
  end

  defp build_config(config) do
    mti = get_config(config, :mti)
    proc_code_pattern = get_config(config, :processing_code_pattern, "*")
    fields = get_config(config, :fields, %{}) |> unquote_ast()
    mandatory = get_config(config, :mandatory, []) |> unquote_ast()
    optional = get_config(config, :optional, []) |> unquote_ast()

    {mti, proc_code_pattern, fields, mandatory, optional}
  end

  # Unquote AST at compile time to get actual values
  defp unquote_ast(ast) do
    {val, _} = Code.eval_quoted(ast, [], __ENV__)
    val
  end

  defp get_config(config, key, default \\ nil) do
    Enum.find_value(config, default, fn
      {^key, val} -> val
      _ -> nil
    end)
  end

  defp macro_escape(nil), do: nil
  defp macro_escape(term), do: Macro.escape(term)

  # Build field formats map from fields map
  # Converts %{field_name => {field_num, format}} to %{field_num => format}
  # Also handles legacy format: %{field_name => field_num}
  defp build_field_formats_from_fields(fields) when is_map(fields) do
    Enum.map(fields, fn
      {_field_name, {field_num, format}} -> {field_num, format}
      {_field_name, field_num} when is_integer(field_num) -> {field_num, nil}
    end)
    |> Map.new()
  end

  # Always mandatory ISO 8583 fields (critical for transaction processing)
  # Field numbers: 11 = STAN, 41 = Terminal ID, 42 = Merchant ID
  @always_mandatory_field_numbers [11, 41, 42]

  # Compile-time validation for transaction type definitions
  defp validate_compile_time!(module, mti, fields, mandatory, optional) do
    field_keys = Map.keys(fields)

    # Validate 1: Always mandatory fields must be included
    # Find which always-mandatory field numbers are present in the fields mapping
    always_mandatory_names = @always_mandatory_field_numbers
      |> Enum.map(fn field_num ->
        Enum.find(fields, fn {_key, val} -> val == field_num end)
      end)
      |> Enum.filter(&(&1))
      |> Enum.map(fn {key, _val} -> key end)

    missing_always_mandatory = always_mandatory_names -- (mandatory ++ optional)
    if missing_always_mandatory != [] do
      raise CompileError,
        description: """
        [Ex_Iso8583.TransactionType] Fields 11 (STAN), 41 (Terminal ID), and 42 (Merchant ID) \
        are always mandatory for ISO 8583 compliance.

        Module: #{inspect(module)}
        MTI: #{inspect(mti)}

        Missing from `mandatory` or `optional`:
            #{inspect(missing_always_mandatory)}

        Please add these fields to your `mandatory` list:
            transaction_type "#{inspect(mti)}" do
              fields %{
                # ... your existing fields ...
                stan: 11,        # STAN - System Trace Audit Number
                terminal_id: 41, # Terminal ID
                merchant_id: 42  # Merchant ID
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
        [Ex_Iso8583.TransactionType] Fields in `mandatory` but not defined in `fields` mapping:

            #{inspect(invalid_mandatory)}

        Please add these fields to the fields mapping, or remove them from mandatory.
        """
    end

    # Validate 3: All optional fields must exist in fields mapping
    invalid_optional = optional -- field_keys
    if invalid_optional != [] do
      raise CompileError,
        description: """
        [Ex_Iso8583.TransactionType] Fields in `optional` but not defined in `fields` mapping:

            #{inspect(invalid_optional)}

        Please add these fields to the fields mapping, or remove them from optional.
        """
    end

    # Validate 4: mandatory and optional should not overlap
    overlap = MapSet.new(mandatory) |> MapSet.intersection(MapSet.new(optional)) |> MapSet.to_list()
    if overlap != [] do
      raise CompileError,
        description: """
        [Ex_Iso8583.TransactionType] Fields defined in both `mandatory` and `optional`:

            #{inspect(overlap)}

        A field can be either mandatory or optional, not both.
        """
    end

    :ok
  end

  @doc """
  Parses and validates an ISO 8583 binary message.

  This is the main entry point for using a transaction type module.
  """
  def parse_and_validate(module, iso_msg, msg_type, field_format, opts \\ []) do
    # extract_iso_msg returns the field map directly, not {:ok, field_data}
    try do
      field_data = Ex_Iso8583.extract_iso_msg(iso_msg, msg_type, field_format)
      # MTI is NOT included in field_data - it's a separate part of the ISO message
      # The module's MTI should be used since we're calling this on a specific module
      mti = module.mti()
      processing_code = Map.get(field_data, 3, "00")
      validate_and_create(module, field_data, mti, processing_code, opts)
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  @doc """
  Validates a parsed ISO 8583 field map and creates a struct.

  Returns `{:ok, struct}` if valid, `{:error, reason}` if validation fails.
  """
  def validate_and_create(module, field_data, mti, processing_code, opts \\ []) do
    # Check if this module matches the processing code
    pattern = module.processing_code_pattern()
    unless matches_pattern?(pattern, processing_code) do
      {:error, {:processing_code_mismatch, mti, pattern, processing_code}}
    end

    field_mapping = module.field_mapping()
    mandatory = module.mandatory_fields()
    optional = module.optional_fields()

    # Get strict mode option (default true - reject extra fields)
    strict = Keyword.get(opts, :strict, true)

    # Check for missing mandatory fields
    missing_fields = check_mandatory_fields(field_data, field_mapping, mandatory)

    if missing_fields != [] do
      {:error, {:missing_fields, mti, processing_code, missing_fields}}
    else
      # Build the struct with allowed fields only
      allowed = MapSet.new(mandatory ++ optional)
      create_struct(module, field_data, field_mapping, allowed, strict, mti, processing_code)
    end
  end

  defp check_mandatory_fields(field_data, field_mapping, mandatory) do
    Enum.filter(mandatory, fn field_name ->
      case Map.get(field_mapping, field_name) do
        nil -> false  # Field not in mapping, skip
        iso_field_num ->
          not Map.has_key?(field_data, iso_field_num) or
            Map.get(field_data, iso_field_num) in [nil, ""]
      end
    end)
  end

  defp create_struct(module, field_data, field_mapping, allowed_fields, strict, mti, processing_code) do
    # Build struct from field_data using field_mapping
    struct_data =
      Enum.reduce(field_mapping, %{}, fn {field_name, iso_field_num}, acc ->
        # Only include fields that are in allowed set and present in data
        if field_name in allowed_fields and Map.has_key?(field_data, iso_field_num) do
          value = Map.get(field_data, iso_field_num)
          Map.put(acc, field_name, value)
        else
          acc
        end
      end)

    # Check for extra fields if strict mode is enabled
    if strict do
      # Find fields that are in field_mapping and present in field_data,
      # but not in allowed_fields
      present_in_message =
        Enum.filter(field_mapping, fn {_field_name, iso_field_num} ->
          Map.has_key?(field_data, iso_field_num)
        end)
        |> Enum.map(fn {field_name, _} -> field_name end)

      extra = Enum.filter(present_in_message, &(&1 not in allowed_fields))

      if extra != [] do
        {:error, {:extra_fields, mti, processing_code, extra}}
      else
        {:ok, struct(module, struct_data)}
      end
    else
      {:ok, struct(module, struct_data)}
    end
  end

  @doc """
  Creates a struct from the given data without validation.

  Maps the ISO field data to the struct fields based on the field_mapping.
  """
  def create_struct(module, field_data) when is_map(field_data) do
    field_mapping = module.field_mapping()

    struct_data =
      Enum.reduce(field_mapping, %{}, fn {field_name, iso_field_num}, acc ->
        if Map.has_key?(field_data, iso_field_num) do
          Map.put(acc, field_name, Map.get(field_data, iso_field_num))
        else
          acc
        end
      end)

    struct(module, struct_data)
  end

  @doc """
  Forms and validates an ISO 8583 binary message from a transaction struct.

  Validates that all mandatory fields are present and have non-nil values,
  then forms the message with field value validation enabled.

  ## Parameters
    - module: The transaction type module
    - struct: The transaction struct containing field values
    - msg_type: Message type configuration
    - field_format: Field format definitions
    - opts: Additional options

  ## Returns
    - `{:ok, binary}` - Successfully formed message
    - `{:error, {:missing_fields, mti, processing_code, field_names}}` - Missing mandatory fields
    - `{:error, {:invalid_field_value, field_num, reason}}` - Field value validation failed
    - `{:error, reason}` - Other errors

  ## Example

      case Ex_Iso8583.TransactionType.form_and_validate(
        SaleRequest,
        request_struct,
        msg_type,
        field_format
      ) do
        {:ok, iso_msg} -> send_message(iso_msg)
        {:error, reason} -> handle_error(reason)
      end
  """
  def form_and_validate(module, struct, msg_type, field_format, _opts \\ []) do
    # Get module configuration
    mti = module.mti()
    processing_code = module.processing_code_pattern()
    field_mapping = module.field_mapping()
    mandatory = module.mandatory_fields()
    _optional = module.optional_fields()

    # Check for missing mandatory fields in the struct
    missing = check_missing_mandatory_in_struct(struct, mandatory)

    if missing != [] do
      {:error, {:missing_fields, mti, processing_code, missing}}
    else
      # Convert struct to ISO field data map
      iso_data = struct_to_iso_data(struct, field_mapping)

      # Form the message with validation enabled
      case Ex_Iso8583.form_iso_msg(iso_data, msg_type, field_format, validate: true) do
        {:ok, binary} -> {:ok, binary}
        {:error, reason} -> {:error, reason}
      end
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
    Enum.reduce(field_mapping, %{}, fn {field_name, iso_field_num}, acc ->
      case Map.get(struct, field_name) do
        nil -> acc  # Skip nil values
        value -> Map.put(acc, iso_field_num, value)
      end
    end)
  end

  @doc """
  Checks if a processing code matches a pattern.

  ## Patterns
    - Exact match: `"020000"` matches only "020000"
    - Prefix wildcard: `"01*"` matches any code starting with "01"
    - Suffix wildcard: `"*1000"` matches any code ending with "1000"
    - Full wildcard: `"*"` matches all codes

  ## Examples
      iex> matches_pattern?("020000", "020000")
      true
      iex> matches_pattern?("01*", "010000")
      true
      iex> matches_pattern?("01*", "020000")
      false
      iex> matches_pattern?("*1000", "001000")
      true
      iex> matches_pattern?("*", "anything")
      true
  """
  def matches_pattern?(pattern, code) when is_binary(pattern) and is_binary(code) do
    case pattern do
      "*" -> true
      _ ->
        # Handle prefix wildcard: "01*" matches "010000", "011234", etc.
        # Handle suffix wildcard: "*1000" matches "001000", "021000", etc.
        # Handle exact match: "020000" matches "020000" only
        parts = String.split(pattern, "*")

        case parts do
          [prefix, ""] ->
            # Ends with *: prefix wildcard
            String.starts_with?(code, prefix)

          ["", suffix] ->
            # Starts with *: suffix wildcard
            String.ends_with?(code, suffix)

          [prefix, suffix] ->
            # Middle *: prefix + suffix wildcard
            String.starts_with?(code, prefix) and String.ends_with?(code, suffix)

          [exact] ->
            # No wildcard: exact match
            code == exact
        end
    end
  end

  @doc """
  Finds the best matching transaction type module from a list.

  Matches are prioritized by:
  1. Exact match (pattern has no wildcard)
  2. Prefix match (pattern ends with *)
  3. Suffix match (pattern starts with *)
  4. Full wildcard (*)

  Returns `{:ok, module}` if a match is found, `{:error, :no_match}` otherwise.

  ## Examples
      modules = [AuthRequestPurchase, AuthRequestCashAdvance]

      {:ok, module} = find_transaction_type(modules, "0100", "000000")
  """
  def find_transaction_type(modules, mti, processing_code) when is_list(modules) do
    # Group modules by match type
    {exact_matches, prefix_matches, suffix_matches, wildcard_matches} =
      Enum.reduce(modules, {[], [], [], []}, fn module, {exact, prefix, suffix, wildcard} ->
        try do
          if module.mti() == mti do
            pattern = module.processing_code_pattern()
            if matches_pattern?(pattern, processing_code) do
              case pattern do
                "*" -> {exact, prefix, suffix, [module | wildcard]}
                <<"*", _rest::binary>> -> {exact, prefix, [module | suffix], wildcard}
                _prefix ->
                  if String.contains?(pattern, "*") do
                    {[module | exact], prefix, suffix, wildcard}
                  else
                    {[module | exact], prefix, suffix, wildcard}
                  end
              end
            else
              {exact, prefix, suffix, wildcard}
            end
          else
            {exact, prefix, suffix, wildcard}
          end
        rescue
          _ -> {exact, prefix, suffix, wildcard}
        end
      end)

    # Return best match (exact > prefix > suffix > wildcard)
    cond do
      exact_matches != [] -> {:ok, hd(exact_matches)}
      prefix_matches != [] -> {:ok, hd(prefix_matches)}
      suffix_matches != [] -> {:ok, hd(suffix_matches)}
      wildcard_matches != [] -> {:ok, hd(wildcard_matches)}
      true -> {:error, :no_match}
    end
  end

  @doc """
  Parses and validates a message by finding the matching transaction type.

  Takes a list of transaction type modules and automatically finds the
  one that matches the MTI and processing code.

  ## Returns
    - `{:ok, struct}` - Successfully parsed and validated
    - `{:error, {:no_matching_transaction_type, mti, processing_code}}` - No matching transaction type
    - `{:error, {:missing_fields, mti, processing_code, field_names}}` - Required fields missing
    - `{:error, {:extra_fields, mti, processing_code, field_names}}` - Extra fields present (strict mode)
    - `{:error, {:processing_code_mismatch, mti, pattern, processing_code}}` - Internal: pattern mismatch
    - `{:error, message}` - Other errors

  ## Examples
      modules = [AuthRequestPurchase, AuthRequestCashAdvance]

      case find_and_parse(modules, iso_msg, msg_type, field_format) do
        {:ok, txn} -> # handle success
        {:error, {:no_matching_transaction_type, mti, proc_code}} -> # no match
        {:error, {:missing_fields, mti, proc_code, fields}} -> # missing fields
        {:error, reason} -> # other error
      end
  """
  def find_and_parse(modules, iso_msg, msg_type, field_format, opts \\ []) do
    try do
      # Extract MTI from the beginning of the message (first 4 bytes)
      {mti, _msg_without_mti} = extract_mti(iso_msg, msg_type)

      field_data = Ex_Iso8583.extract_iso_msg(iso_msg, msg_type, field_format)
      processing_code = Map.get(field_data, 3, "000000")

      case find_transaction_type(modules, mti, processing_code) do
        {:ok, module} ->
          validate_and_create(module, field_data, mti, processing_code, opts)

        {:error, :no_match} ->
          {:error, {:no_matching_transaction_type, mti, processing_code}}
      end
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  @doc """
  Extracts the MTI (Message Type Indicator) from the beginning of an ISO message.

  MTI is typically the first 4 bytes (ASCII) or 2 bytes (BCD encoded).

  ## Returns
    - `{mti, rest_of_message}` - Tuple containing the MTI string and remaining message

  ## Examples
      iex> extract_mti_from_binary(<<"0100", rest::binary>>)
      {"0100", rest}
  """
  def extract_mti_from_binary(iso_msg, _msg_type \\ nil) do
    # Try ASCII MTI first (4 bytes)
    if byte_size(iso_msg) >= 4 do
      mti_bytes = binary_part(iso_msg, 0, 4)
      # Check if it looks like a numeric ASCII MTI
      if String.printable?(mti_bytes) and String.match?(mti_bytes, ~r/^\d+$/) do
        {mti_bytes, binary_part(iso_msg, 4, byte_size(iso_msg) - 4)}
      else
        # Try BCD (2 bytes) - convert each nibble to ASCII
        if byte_size(iso_msg) >= 2 do
          <<a::4, b::4, c::4, d::4>> = iso_msg
          mti = <<(a + ?0), (b + ?0), (c + ?0), (d + ?0)>>
          {mti, binary_part(iso_msg, 2, byte_size(iso_msg) - 2)}
        else
          {"0000", iso_msg}  # Default fallback
        end
      end
    else
      {"0000", iso_msg}  # Default fallback
    end
  end

  # Internal version that returns only MTI for use in find_and_parse
  defp extract_mti(iso_msg, msg_type) do
    {mti, _} = extract_mti_from_binary(iso_msg, msg_type)
    {mti, iso_msg}
  end
end
