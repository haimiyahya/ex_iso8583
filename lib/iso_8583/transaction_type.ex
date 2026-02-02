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

  ## Examples
      transaction_type "0100" do
        fields %{pan: 2, amount: 4}
        mandatory [:pan, :amount]
      end

      transaction_type "0100", processing_code: "00*" do
        fields %{pan: 2, amount: 4}
        mandatory [:pan, :amount]
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

    quote do
      @mti unquote(macro_escape(mti))
      @processing_code_pattern unquote(macro_escape(proc_code_pattern))
      @field_mapping unquote(Macro.escape(fields))
      @mandatory_fields unquote(Macro.escape(mandatory))
      @optional_fields unquote(Macro.escape(optional))

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
      def validate_and_create(field_data, processing_code, opts \\ []) do
        Ex_Iso8583.TransactionType.validate_and_create(
          __MODULE__,
          field_data,
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

  @doc """
  Parses and validates an ISO 8583 binary message.

  This is the main entry point for using a transaction type module.
  """
  def parse_and_validate(module, iso_msg, msg_type, field_format, opts \\ []) do
    # extract_iso_msg returns the field map directly, not {:ok, field_data}
    try do
      field_data = Ex_Iso8583.extract_iso_msg(iso_msg, msg_type, field_format)
      processing_code = Map.get(field_data, 3, "00")
      validate_and_create(module, field_data, processing_code, opts)
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  @doc """
  Validates a parsed ISO 8583 field map and creates a struct.

  Returns `{:ok, struct}` if valid, `{:error, reason}` if validation fails.
  """
  def validate_and_create(module, field_data, processing_code, opts \\ []) do
    # Check if this module matches the processing code
    pattern = module.processing_code_pattern()
    unless matches_pattern?(pattern, processing_code) do
      {:error, {:processing_code_mismatch, pattern, processing_code}}
    end

    field_mapping = module.field_mapping()
    mandatory = module.mandatory_fields()
    optional = module.optional_fields()

    # Get strict mode option (default true - reject extra fields)
    strict = Keyword.get(opts, :strict, true)

    # Check for missing mandatory fields
    missing_fields = check_mandatory_fields(field_data, field_mapping, mandatory)

    if missing_fields != [] do
      {:error, {:missing_fields, missing_fields}}
    else
      # Build the struct with allowed fields only
      allowed = MapSet.new(mandatory ++ optional)
      create_struct(module, field_data, field_mapping, allowed, strict)
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

  defp create_struct(module, field_data, field_mapping, allowed_fields, strict) do
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
        {:error, {:extra_fields, extra}}
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

  Returns `{:ok, struct}` if valid, `{:error, reason}` if validation fails
  or no matching transaction type is found.

  ## Examples
      modules = [AuthRequestPurchase, AuthRequestCashAdvance]

      case find_and_parse(modules, iso_msg, msg_type, field_format) do
        {:ok, txn} -> # handle success
        {:error, :no_match} -> # no transaction type matched
        {:error, reason} -> # other validation error
      end
  """
  def find_and_parse(modules, iso_msg, msg_type, field_format, opts \\ []) do
    try do
      field_data = Ex_Iso8583.extract_iso_msg(iso_msg, msg_type, field_format)
      mti = Map.get(field_data, 0)
      processing_code = Map.get(field_data, 3, "000000")

      case find_transaction_type(modules, mti, processing_code) do
        {:ok, module} ->
          validate_and_create(module, field_data, processing_code, opts)

        {:error, :no_match} ->
          {:error, {:no_matching_transaction_type, mti, processing_code}}
      end
    rescue
      e -> {:error, Exception.message(e)}
    end
  end
end
