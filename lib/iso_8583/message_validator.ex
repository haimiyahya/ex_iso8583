defmodule Ex_Iso8583.MessageValidator do
  @moduledoc """
  Comprehensive message validation for ISO 8583 messages.

  This module provides validation functions to ensure ISO 8583 messages
  conform to specifications and business rules.

  ## Examples

      iex> MessageValidator.validate_message(data, msg_type, field_format)
      :ok

      iex> MessageValidator.validate_required_fields(data, "0100", config)
      :ok
  """

  alias Ex_Iso8583.Validator
  alias IsoBitmap
  alias IsoFieldFormat

  @type validation_result :: :ok | {:error, String.t()}

  # Required fields for common message types
  @required_fields %{
    # Authorization Request
    "0100" => [3, 4, 11, 41, 42],
    # Authorization Response
    "0110" => [3, 4, 11, 39, 41, 42],
    # Financial Request
    "0200" => [3, 4, 11, 22, 41, 42],
    # Financial Response
    "0210" => [3, 4, 11, 39, 41, 42],
    # Reversal Request
    "0400" => [3, 4, 11, 41, 42, 90],
    # Reversal Response
    "0410" => [3, 4, 11, 39, 41, 42],
    # Network Management Request
    "0800" => [70, 71],
    # Network Management Response
    "0810" => [70, 71]
  }

  # Field dependencies: if field X is present, field Y must also be present
  @field_dependencies %{
    # Track 2 data requires POS Entry Mode
    35 => {:if_present, 22},
    # Track 1 data requires POS Entry Mode
    45 => {:if_present, 22},
    # Account Identification 1 requires Account Identification 2
    102 => {:if_present, 103}
  }

  @doc """
  Validates a complete ISO 8583 message.

  Checks:
  - All fields are defined in field_format
  - All field values match their format constraints
  - Required fields for the MTI are present
  - Field dependencies are satisfied

  ## Parameters
    - data: Map of field numbers to values
    - mti: Message Type Indicator (4-digit string)
    - msg_type: Configuration map
    - field_format: Field format definitions

  ## Returns
    :ok if valid, {:error, reason} if invalid
  """
  @spec validate_message(map(), String.t(), map(), map()) :: validation_result()
  def validate_message(data, mti, msg_type, field_format) do
    with :ok <- validate_all_fields_defined(data, field_format),
         :ok <- validate_field_values(data, msg_type, field_format),
         :ok <- validate_required_fields_for_mti(data, mti),
         :ok <- validate_field_dependencies(data) do
      :ok
    else
      {:error, _} = error -> error
    end
  end

  @doc """
  Validates that all fields in the data are defined in field_format.
  """
  def validate_all_fields_defined(data, field_format) do
    defined_fields = Map.keys(field_format)

    undefined =
      data
      |> Map.keys()
      |> Enum.reject(fn field -> field in defined_fields end)

    if undefined == [] do
      :ok
    else
      {:error, "Undefined fields: #{inspect(undefined)}"}
    end
  end

  @doc """
  Validates that all field values match their format constraints.
  """
  def validate_field_values(data, msg_type, field_format) do
    bitmap = IsoBitmap.create_bitmap(data)
    field_list = IsoFieldFormat.get_field_format_list(bitmap, msg_type, field_format)

    errors =
      Enum.reduce(field_list, [], fn {field_num, {_header, data_type, max_len, _padding}}, acc ->
        value = Map.get(data, field_num)

        case Validator.validate_field_value(field_num, value, data_type, max_len) do
          :ok -> acc
          {:error, reason} -> [{field_num, reason} | acc]
        end
      end)

    if errors == [] do
      :ok
    else
      error_details =
        errors
        |> Enum.reverse()
        |> Enum.map(fn {field, reason} -> "  Field #{field}: #{reason}" end)
        |> Enum.join("\n")

      {:error, "Field value validation failed:\n#{error_details}"}
    end
  end

  @doc """
  Validates that all required fields for the given MTI are present.
  """
  def validate_required_fields_for_mti(data, mti) do
    required = Map.get(@required_fields, mti, [])

    missing =
      required
      |> Enum.reject(fn field -> Map.has_key?(data, field) end)

    if missing == [] do
      :ok
    else
      {:error, "Missing required fields for MTI #{mti}: #{inspect(missing)}"}
    end
  end

  @doc """
  Validates field dependencies are satisfied.

  For example, if Track 2 data (field 35) is present, POS Entry Mode (field 22)
  should also be present.
  """
  def validate_field_dependencies(data) do
    errors =
      Enum.reduce(@field_dependencies, [], fn {field, dependency}, acc ->
        if Map.has_key?(data, field) do
          case check_dependency(data, field, dependency) do
            :ok -> acc
            {:error, reason} -> [{field, reason} | acc]
          end
        else
          acc
        end
      end)

    if errors == [] do
      :ok
    else
      error_details =
        errors
        |> Enum.reverse()
        |> Enum.map(fn {field, reason} -> "  Field #{field}: #{reason}" end)
        |> Enum.join("\n")

      {:error, "Field dependency validation failed:\n#{error_details}"}
    end
  end

  defp check_dependency(data, _field, {:if_present, dependent_field}) do
    if Map.has_key?(data, dependent_field) do
      :ok
    else
      {:error, "Requires field #{dependent_field} to be present"}
    end
  end

  @doc """
  Validates message integrity by checking that the bitmap matches present fields.
  """
  def validate_bitmap_consistency(data, msg_binary, msg_type, field_format) do
    bitmap = IsoBitmap.create_bitmap(data)
    fields_in_data = Map.keys(data) |> Enum.sort()

    fields_in_bitmap =
      msg_binary
      |> IsoBitmap.split_bitmap_and_msg(msg_type)
      |> case do
        {:ok, bmp, _} -> IsoBitmap.bitmap_to_list(bmp) |> Enum.filter(&(&1 > 1))
        _ -> []
      end
      |> Enum.sort()

    if fields_in_data == fields_in_bitmap do
      :ok
    else
      only_in_data = fields_in_data -- fields_in_bitmap
      only_in_bitmap = fields_in_bitmap -- fields_in_data

      message =
        cond do
          only_in_data != [] and only_in_bitmap != [] ->
            "Bitmap inconsistency:\n  Only in data: #{inspect(only_in_data)}\n  Only in bitmap: #{inspect(only_in_bitmap)}"

          only_in_data != [] ->
            "Bitmap inconsistency: Fields in data but not in bitmap: #{inspect(only_in_data)}"

          only_in_bitmap != [] ->
            "Bitmap inconsistency: Fields in bitmap but not in data: #{inspect(only_in_bitmap)}"

          true ->
            "Bitmap inconsistency"
        end

      {:error, message}
    end
  end

  @doc """
  Validates a financial message has proper amount fields.
  """
  def validate_financial_message(data) do
    # Field 4 (Amount, Transaction) is required for financial messages
    if Map.has_key?(data, 4) do
      amount = Map.get(data, 4)

      if String.match?(amount, ~r/^\d+$/) do
        :ok
      else
        {:error, "Field 4 (Amount) must be numeric: #{inspect(amount)}"}
      end
    else
      {:error, "Financial message requires Field 4 (Amount)"}
    end
  end

  @doc """
  Validates an authorization message has proper card data.
  """
  def validate_authorization_message(data) do
    cond do
      not Map.has_key?(data, 2) and not Map.has_key?(data, 35) ->
        {:error, "Authorization message requires Field 2 (PAN) or Field 35 (Track 2)"}

      Map.has_key?(data, 2) and not String.match?(Map.get(data, 2), ~r/^\d+$/) ->
        {:error, "Field 2 (PAN) must be numeric"}

      Map.has_key?(data, 35) and not is_binary(Map.get(data, 35)) ->
        {:error, "Field 35 (Track 2) must be a binary/string"}

      true ->
        :ok
    end
  end

  @doc """
  Returns a validation report for a message with all checks.
  """
  def validation_report(data, mti, msg_type, field_format) do
    checks = [
      {"Fields defined", &validate_all_fields_defined(&1, field_format), data},
      {"Field values", &validate_field_values(&1, msg_type, field_format), data},
      {"Required fields for MTI", &validate_required_fields_for_mti(&1, mti), data},
      {"Field dependencies", &validate_field_dependencies/1, data}
    ]

    report =
      Enum.map(checks, fn {name, check_fn, check_data} ->
        result = apply(check_fn, [check_data])
        {name, result}
      end)

    %{
      valid?: Enum.all?(report, fn {_, r} -> r == :ok end),
      checks: report,
      mti: mti,
      field_count: map_size(data)
    }
  end
end
