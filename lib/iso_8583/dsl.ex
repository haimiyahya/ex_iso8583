defmodule Ex_Iso8583.DSL do
  @moduledoc """
  Compile-time DSL for defining ISO 8583 messages with validation.

  This module provides macros that validate field definitions at compile time,
  catching errors before runtime.

  ## Example

      defmodule MyMessage do
        use Ex_Iso8583.DSL

        @msg_type %{bitmap_type: :binary, field_header_type: :bcd}

        defisoformat do
          field 2, "n ..19"
          field 3, "n 6"
          field 4, "n 12"
          field 35, "z ..37"
        end
      end

      # At compile time, if you use an undefined field:
      # MyMessage.build(%{999 => "data"})  # Compile-time warning!
  """

  @doc false
  defmacro __using__(_opts) do
    quote do
      import Ex_Iso8583.DSL
      Module.register_attribute(__MODULE__, :iso_fields, accumulate: true)
      @before_compile Ex_Iso8583.DSL
    end
  end

  @doc """
  Defines the message format configuration.
  """
  defmacro defisoformat(do: block) do
    quote do
      import Ex_Iso8583.DSL, only: [field: 2]
      unquote(block)
      import Ex_Iso8583.DSL, only: []
    end
  end

  @doc """
  Defines a field with its format.
  At compile time, validates that the format string is valid.
  """
  defmacro field(number, format) when is_integer(number) and number >= 2 and number <= 128 do
    quote do
      @iso_fields {unquote(number), unquote(format)}
    end
  end

  defmacro field(number, _format) do
    compile_error!("Field number must be between 2 and 128, got: #{inspect(number)}")
  end

  defp compile_error!(message) do
    raise CompileError, description: message
  end

  @doc false
  defmacro __before_compile__(env) do
    fields = Module.get_attribute(env.module, :iso_fields)

    # Validate field numbers are unique
    field_numbers = Enum.map(fields, fn {num, _} -> num end)
    duplicates = field_numbers -- Enum.uniq(field_numbers)

    if duplicates != [] do
      raise CompileError,
        description: "Duplicate field numbers defined: #{inspect(duplicates)}"
    end

    # Build the format map
    format_map = Enum.into(fields, %{})

    quote do
      @field_format unquote(Macro.escape(format_map))

      @doc """
      Returns the field format definition for this message.
      """
      def field_format, do: @field_format

      @doc """
      Returns the list of defined field numbers.
      """
      def defined_fields, do: Map.keys(@field_format) |> Enum.sort()

      @doc """
      Builds an ISO 8583 message with compile-time field validation.
      """
      def build(data, msg_type \\ %{bitmap_type: :binary, field_header_type: :bcd}) do
        validate_fields_at_compile!(data)
        Ex_Iso8583.form_iso_msg(data, msg_type, @field_format)
      end

      @doc """
      Parses an ISO 8583 message with compile-time field validation.
      """
      def parse(message, msg_type \\ %{bitmap_type: :binary, field_header_type: :bcd}) do
        Ex_Iso8583.extract_iso_msg(message, msg_type, @field_format)
      end

      defp validate_fields_at_compile!(data) do
        undefined = Enum.filter(Map.keys(data), fn field ->
          field not in Map.keys(@field_format)
        end)

        if undefined != [] do
          raise RuntimeError, """
          Undefined field(s) in #{__MODULE__}: #{inspect(undefined)}

          Defined fields: #{inspect(defined_fields())}
          """
        end
      end
    end
  end
end
