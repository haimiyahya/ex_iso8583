defmodule Ex_Iso8583.MTI do
  @moduledoc """
  Message Type Indicator (MTI) parsing and validation for ISO 8583.

  The MTI is a 4-digit numeric code that defines the message type, format,
  and function class. It's typically the first field of an ISO 8583 message.

  ## MTI Structure

  The MTI consists of 4 digits:
  - Digit 1: ISO Version (0xxx, 1xxx, 2xxx, 8xxx)
  - Digit 2: Message Class (1xxx, 2xxx, 4xxx, etc.)
  - Digit 3: Message Function (xx0x, xx1x, xx2x, etc.)
  - Digit 4: Message Origin (xxx0, xxx1, xxx2, xxx5, etc.)

  ## Examples

      iex> MTI.parse("0100")
      {:ok, %{
        version: :iso_8583_1987,
        class: :authorization_request,
        function: :request,
        origin: :acquirer
      }}

      iex> MTI.valid?("0100")
      true

      iex> MTI.format(%{
      ...>   version: :iso_8583_1987,
      ...>   class: :authorization_request,
      ...>   function: :request,
      ...>   origin: :acquirer
      ...> })
      "0100"
  """

  @type mti :: String.t()
  @type version :: :iso_8583_1987 | :iso_8583_1993 | :iso_8583_2003 | :reserved_national
  @type message_class ::
          :authorization_request | :financial_request | :file_update_request |
          :network_management_request | :reversal_advice | :chargeback_request |
          :authorization_response | :financial_response | :file_update_response |
          :network_management_response | :reversal_response | :chargeback_response
  @type message_function ::
          :request | :request_response | :advice | :advice_response |
          :notification | :notification_ack | :instruction |
          :instruction_ack | :reserved
  @type message_origin ::
          :acquirer | :acquirer_repeat | :issuer | :issuer_repeat |
          :other | :other_repeat

  @type parsed_mti :: %{
          version: version(),
          class: message_class(),
          function: message_function(),
          origin: message_origin()
        }

  # ISO Version mappings (first digit)
  @versions %{
    "0" => :iso_8583_1987,
    "1" => :iso_8583_1993,
    "2" => :iso_8583_2003,
    "8" => :reserved_national
  }

  @versions_inverse Enum.into(@versions, %{}, fn {k, v} -> {v, k} end)

  # Message Class mappings (second digit)
  @classes %{
    "1" => :authorization_request,
    "2" => :financial_request,
    "3" => :file_update_request,
    "4" => :reversal_advice,
    "5" => :chargeback_request,
    "6" => :chargeback_advice,
    "7" => :network_management_request,
    "8" => :authorization_response,
    "9" => :financial_response,
    "0" => :file_update_response,
    "A" => :network_management_response,
    "B" => :reversal_response,
    "C" => :chargeback_response
  }

  @classes_inverse Enum.into(@classes, %{}, fn {k, v} -> {v, k} end)

  # Message Function mappings (third digit)
  @functions %{
    "0" => :request,
    "1" => :request_response,
    "2" => :advice,
    "3" => :advice_response,
    "4" => :notification,
    "5" => :notification_ack,
    "6" => :instruction,
    "7" => :instruction_ack,
    "8" => :reserved
  }

  @functions_inverse Enum.into(@functions, %{}, fn {k, v} -> {v, k} end)

  # Message Origin mappings (fourth digit)
  @origins %{
    "0" => :acquirer,
    "1" => :acquirer_repeat,
    "2" => :issuer,
    "3" => :issuer_repeat,
    "5" => :other,
    "6" => :other_repeat
  }

  @origins_inverse Enum.into(@origins, %{}, fn {k, v} -> {v, k} end)

  @doc """
  Parses an MTI string into its components.

  ## Parameters
    - mti: 4-character MTI string

  ## Returns
    `{:ok, parsed_mti}` if valid, `{:error, reason}` if invalid

  ## Examples

      iex> MTI.parse("0100")
      {:ok, %{version: :iso_8583_1987, class: :authorization_request, function: :request, origin: :acquirer}}

      iex> MTI.parse("0200")
      {:ok, %{version: :iso_8583_1987, class: :financial_request, function: :request, origin: :acquirer}}

      iex> MTI.parse("abcd")
      {:error, "Invalid MTI format"}
  """
  @spec parse(mti()) :: {:ok, parsed_mti()} | {:error, String.t()}
  def parse(mti) when is_binary(mti) and byte_size(mti) == 4 do
    mti_upper = String.upcase(mti)

    with {:ok, version} <- parse_version(String.at(mti_upper, 0)),
         {:ok, class} <- parse_class(String.at(mti_upper, 1)),
         {:ok, function} <- parse_function(String.at(mti_upper, 2)),
         {:ok, origin} <- parse_origin(String.at(mti_upper, 3)) do
      {:ok, %{version: version, class: class, function: function, origin: origin}}
    else
      {:error, _} = error -> error
    end
  end

  def parse(_), do: {:error, "Invalid MTI format: must be 4 characters"}

  defp parse_version(digit) do
    case Map.get(@versions, digit) do
      nil -> {:error, "Invalid ISO version: #{digit}"}
      version -> {:ok, version}
    end
  end

  defp parse_class(digit) do
    case Map.get(@classes, digit) do
      nil -> {:error, "Invalid message class: #{digit}"}
      class -> {:ok, class}
    end
  end

  defp parse_function(digit) do
    case Map.get(@functions, digit) do
      nil -> {:error, "Invalid message function: #{digit}"}
      function -> {:ok, function}
    end
  end

  defp parse_origin(digit) do
    case Map.get(@origins, digit) do
      nil -> {:error, "Invalid message origin: #{digit}"}
      origin -> {:ok, origin}
    end
  end

  @doc """
  Formats a parsed MTI map back into an MTI string.

  ## Examples

      iex> MTI.format(%{version: :iso_8583_1987, class: :authorization_request, function: :request, origin: :acquirer})
      "0100"
  """
  @spec format(parsed_mti()) :: mti()
  def format(%{version: version, class: class, function: function, origin: origin}) do
    version_digit = Map.get(@versions_inverse, version)
    class_digit = Map.get(@classes_inverse, class)
    function_digit = Map.get(@functions_inverse, function)
    origin_digit = Map.get(@origins_inverse, origin)

    version_digit <> class_digit <> function_digit <> origin_digit
  end

  @doc """
  Validates if a string is a valid MTI.

  ## Examples

      iex> MTI.valid?("0100")
      true

      iex> MTI.valid?("9999")
      false
  """
  @spec valid?(mti()) :: boolean()
  def valid?(mti) when is_binary(mti) and byte_size(mti) == 4 do
    case parse(mti) do
      {:ok, _} -> true
      _ -> false
    end
  end

  def valid?(_), do: false

  @doc """
  Returns a human-readable description of an MTI.

  ## Examples

      iex> MTI.describe("0100")
      "ISO 8583:1987 - Authorization Request - Request - Acquirer"
  """
  @spec describe(mti()) :: {:ok, String.t()} | {:error, String.t()}
  def describe(mti) do
    with {:ok, parsed} <- parse(mti) do
      description = """
      ISO Version: #{format_version(parsed.version)}
      Message Class: #{format_class(parsed.class)}
      Message Function: #{format_function(parsed.function)}
      Message Origin: #{format_origin(parsed.origin)}
      """
      |> String.trim()
      |> String.replace("\n", " - ")

      {:ok, description}
    end
  end

  defp format_version(:iso_8583_1987), do: "ISO 8583:1987"
  defp format_version(:iso_8583_1993), do: "ISO 8583:1993"
  defp format_version(:iso_8583_2003), do: "ISO 8583:2003"
  defp format_version(:reserved_national), do: "Reserved/National"

  defp format_class(:authorization_request), do: "Authorization Request"
  defp format_class(:financial_request), do: "Financial Request"
  defp format_class(:file_update_request), do: "File Update Request"
  defp format_class(:network_management_request), do: "Network Management Request"
  defp format_class(:reversal_advice), do: "Reversal Advice"
  defp format_class(:chargeback_request), do: "Chargeback Request"
  defp format_class(:authorization_response), do: "Authorization Response"
  defp format_class(:financial_response), do: "Financial Response"
  defp format_class(:file_update_response), do: "File Update Response"
  defp format_class(:network_management_response), do: "Network Management Response"
  defp format_class(:reversal_response), do: "Reversal Response"
  defp format_class(:chargeback_response), do: "Chargeback Response"

  defp format_function(:request), do: "Request"
  defp format_function(:request_response), do: "Request/Response"
  defp format_function(:advice), do: "Advice"
  defp format_function(:advice_response), do: "Advice/Response"
  defp format_function(:notification), do: "Notification"
  defp format_function(:notification_ack), do: "Notification Ack"
  defp format_function(:instruction), do: "Instruction"
  defp format_function(:instruction_ack), do: "Instruction Ack"
  defp format_function(:reserved), do: "Reserved"

  defp format_origin(:acquirer), do: "Acquirer"
  defp format_origin(:acquirer_repeat), do: "Acquirer Repeat"
  defp format_origin(:issuer), do: "Issuer"
  defp format_origin(:issuer_repeat), do: "Issuer Repeat"
  defp format_origin(:other), do: "Other"
  defp format_origin(:other_repeat), do: "Other Repeat"

  @doc """
  Common MTI constants for easy reference.
  """
  def authorization_request, do: "0100"
  def authorization_response, do: "0110"
  def financial_request, do: "0200"
  def financial_response, do: "0210"
  def reversal_request, do: "0400"
  def reversal_response, do: "0410"
  def network_management_request, do: "0800"
  def network_management_response, do: "0810"

  @doc """
  Checks if the MTI is a request message.
  """
  @spec request?(mti()) :: boolean()
  def request?(mti) do
    case parse(mti) do
      {:ok, %{function: function}} -> function in [:request, :instruction]
      _ -> false
    end
  end

  @doc """
  Checks if the MTI is a response message.
  """
  @spec response?(mti()) :: boolean()
  def response?(mti) do
    case parse(mti) do
      {:ok, %{function: function}} -> function in [:request_response, :advice_response, :instruction_ack]
      _ -> false
    end
  end

  @doc """
  Checks if the MTI is an authorization message.
  """
  @spec authorization?(mti()) :: boolean()
  def authorization?(mti) do
    case parse(mti) do
      {:ok, %{class: class}} -> class in [:authorization_request, :authorization_response]
      _ -> false
    end
  end

  @doc """
  Checks if the MTI is a financial message.
  """
  @spec financial?(mti()) :: boolean()
  def financial?(mti) do
    case parse(mti) do
      {:ok, %{class: class}} -> class in [:financial_request, :financial_response]
      _ -> false
    end
  end
end
