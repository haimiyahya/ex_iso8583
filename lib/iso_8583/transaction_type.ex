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
      import Ex_Iso8583.TransactionType,
        only: [
          transaction_type: 2,
          fields: 1,
          mandatory: 1,
          optional: 1,
          processing_code: 2
        ]

      Module.register_attribute(__MODULE__, :txn_config, accumulate: true)
      @before_compile Ex_Iso8583.TransactionType
    end
  end

  @doc """
  Defines a transaction type for a specific MTI.
  """
  defmacro transaction_type(mti, [{:do, block}]) do
    quote do
      @txn_config {:mti, unquote(mti)}
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

  @doc """
  Defines processing code specific overrides.
  """
  defmacro processing_code(code, [{:do, block}]) do
    quote do
      @txn_config {:processing_code, unquote(code), unquote(Macro.escape(block))}
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    config = Module.get_attribute(env.module, :txn_config)

    {mti, fields, mandatory_map, optional_map} = build_config(config)

    quote do
      @mti unquote(macro_escape(mti))
      @field_mapping unquote(Macro.escape(fields))
      @mandatory_fields unquote(Macro.escape(mandatory_map))
      @optional_fields unquote(Macro.escape(optional_map))

      @doc """
      Returns the MTI for this transaction type.
      """
      def mti, do: @mti

      @doc """
      Returns the field mapping (struct fields to ISO field numbers).
      """
      def field_mapping, do: @field_mapping

      @doc """
      Returns mandatory field names for a given processing code.
      Defaults to the general mandatory list if no processing code override exists.
      """
      def mandatory_fields(processing_code \\ nil) do
        Map.get(@mandatory_fields, processing_code, @mandatory_fields[:default] || [])
      end

      @doc """
      Returns optional field names.
      """
      def optional_fields, do: Map.get(@optional_fields, :default, [])

      @doc """
      Returns allowed field names (mandatory + optional).
      """
      def allowed_fields do
        optional = Map.get(@optional_fields, :default, [])
        mandatory = Map.get(@mandatory_fields, :default, []) || []
        optional ++ mandatory
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
    fields = get_config(config, :fields, %{}) |> unquote_ast()
    mandatory = get_config(config, :mandatory, []) |> unquote_ast()
    optional = get_config(config, :optional, []) |> unquote_ast()

    # Group mandatory fields by processing code
    mandatory_map = build_processing_code_map(config, mandatory)
    optional_map = %{default: optional}

    {mti, fields, mandatory_map, optional_map}
  end

  # Unquote AST at compile time to get actual values
  defp unquote_ast(ast) do
    {val, _} = Code.eval_quoted(ast, [], __ENV__)
    val
  end

  defp get_config(config, key, default \\ nil) do
    Enum.find_value(config, default, fn
      {:processing_code, _code, [^key, val]} -> val
      {^key, val} -> val
      _ -> nil
    end)
  end

  defp build_processing_code_map(config, default_list) do
    # Start with default mandatory fields
    # Find all processing_code entries with mandatory
    entries = Enum.filter(config, fn
      {:processing_code, _code, [:mandatory, _]} -> true
      _ -> false
    end)

    # Build map with default
    map = %{default: default_list}

    # Add processing code specific entries
    Enum.reduce(entries, map, fn
      {:processing_code, code, [:mandatory, fields]}, acc ->
        Map.put(acc, code, fields)
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
    field_mapping = module.field_mapping()
    mandatory = module.mandatory_fields(processing_code)
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
end
