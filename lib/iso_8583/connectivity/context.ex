defmodule Iso8583.Context do
  @moduledoc """
  Transport context for ISO 8583 message handling.

  Contains metadata about the message source/destination that the transport
  needs to route responses correctly.

  ## Purpose

  When an ISO 8583 message is received, the raw binary data alone is not
  enough to send a response back. We need to know:
  - Where did this message come from?
  - How do we send the response back?
  - What connection/socket should we use?

  The context carries this transport-specific metadata alongside the message.

  ## Fields

  | Field | Type | Description |
  |-------|------|-------------|
  | `transport_ref` | `term()` | Transport-specific reference (socket, conn, etc.) |
  | `client_id` | `String.t() \| nil` | Optional identifier for the client |
  | `peer_address` | `:inet.socket_address() \| nil` | Client's network address |
  | `request_id` | `String.t() \| nil` | Correlation ID for logging/tracing |
  | `transport_metadata` | `map() \| nil` | Transport-specific extra data |

  ## Examples

      # TCP Server context
      context = Iso8583.Context.new(
        transport_ref: socket,
        client_id: "terminal_001",
        peer_address: {192, 168, 1, 100}
      )

      # HTTP Server context
      context = Iso8583.Context.new(
        transport_ref: conn,
        request_id: "req-123",
        peer_address: {127, 0, 0, 1},
        transport_metadata: %{method: "POST", path: "/iso8583"}
      )

      # UDP context
      context = Iso8583.Context.new(
        transport_ref: socket,
        peer_address: {192, 168, 1, 100},
        transport_metadata: %{peer_port: 8080}
      )

  ## Accessing Metadata

      # Put custom metadata
      context = Iso8583.Context.put_metadata(context, :connection_time, System.system_time())

      # Get custom metadata
      connection_time = Iso8583.Context.get_metadata(context, :connection_time)

  """

  import Bitwise

  defstruct [
    :transport_ref,
    :client_id,
    :peer_address,
    :request_id,
    :transport_metadata
  ]

  @type t :: %__MODULE__{
          transport_ref: reference() | pid() | term(),
          client_id: String.t() | nil,
          peer_address: :inet.socket_address() | nil,
          request_id: String.t() | nil,
          transport_metadata: map() | nil
        }

  @doc """
  Creates a new context from the given options.

  ## Parameters

  - `opts` - Keyword list or map with context fields

  ## Examples

      Iso8583.Context.new(transport_ref: socket, client_id: "client_001")
      #=> %Iso8583.Context{transport_ref: socket, client_id: "client_001", ...}

  """
  @spec new(keyword() | map()) :: t()
  def new(opts) when is_list(opts) do
    opts
    |> Enum.into(%{})
    |> new()
  end

  def new(opts) when is_map(opts) do
    struct(__MODULE__, opts)
  end

  @doc """
  Adds a key-value pair to transport metadata.

  Creates or updates the transport_metadata map with the given key and value.

  ## Parameters

  - `context` - The context struct
  - `key` - The metadata key
  - `value` - The metadata value

  ## Examples

      context = Iso8583.Context.new([])
      context = Iso8583.Context.put_metadata(context, :connection_time, System.system_time())

      Iso8583.Context.get_metadata(context, :connection_time)
      #=> 1234567890

  """
  @spec put_metadata(t(), atom(), term()) :: t()
  def put_metadata(%__MODULE__{} = context, key, value) do
    metadata = Map.get(context, :transport_metadata) || %{}
    %{context | transport_metadata: Map.put(metadata, key, value)}
  end

  @doc """
  Retrieves a value from transport metadata.

  ## Parameters

  - `context` - The context struct
  - `key` - The metadata key to retrieve
  - `default` - Default value if key not found (default: `nil`)

  ## Examples

      context = Iso8583.Context.put_metadata(
        Iso8583.Context.new([]),
        :retry_count,
        3
      )

      Iso8583.Context.get_metadata(context, :retry_count)
      #=> 3

      Iso8583.Context.get_metadata(context, :unknown_key, :default)
      #=> :default

  """
  @spec get_metadata(t(), atom(), term()) :: term()
  def get_metadata(%__MODULE__{} = context, key, default \\ nil) do
    metadata = Map.get(context, :transport_metadata)
    if metadata do
      Map.get(metadata, key, default)
    else
      default
    end
  end

  @doc """
  Returns the peer address as a human-readable string.

  ## Examples

      context = Iso8583.Context.new(peer_address: {192, 168, 1, 100})
      Iso8583.Context.peer_address_string(context)
      #=> "192.168.1.100"

      context = Iso8583.Context.new(peer_address: {0, 0, 0, 0, 0, 65535, 32322, 60101})
      Iso8583.Context.peer_address_string(context)
      #=> "192.168.235.101"

  """
  @spec peer_address_string(t()) :: String.t() | nil
  def peer_address_string(%__MODULE__{peer_address: nil}), do: nil

  def peer_address_string(%__MODULE__{peer_address: addr}) do
    :inet.ntoa(addr) |> to_string()
  end

  @doc """
  Merges a map of metadata into the context's transport_metadata.

  ## Examples

      context = Iso8583.Context.new([])
      context = Iso8583.Context.merge_metadata(context, %{
        connection_time: System.system_time(),
        retry_count: 0
      })

  """
  @spec merge_metadata(t(), map()) :: t()
  def merge_metadata(%__MODULE__{} = context, metadata) when is_map(metadata) do
    current_metadata = context.transport_metadata || %{}
    %{context | transport_metadata: Map.merge(current_metadata, metadata)}
  end

  @doc """
  Creates a context with a generated request ID.

  The request ID is a UUID v4 string, useful for tracing requests through
  the system.

  ## Examples

      context = Iso8583.Context.new_with_request_id(transport_ref: socket)
      context.request_id
      #=> "550e8400-e29b-41d4-a716-446655440000"

  """
  @spec new_with_request_id(keyword() | map()) :: t()
  def new_with_request_id(opts \\ []) do
    request_id = generate_request_id()
    opts = Keyword.put(opts, :request_id, request_id)
    new(opts)
  end

  # Private functions

  defp generate_request_id do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)
    # Set version to 4 (random UUID) and variant bits
    c = (c &&& 0x0FFF) ||| 0x4000
    d = (d &&& 0x3FFF) ||| 0x8000
    :erlang.list_to_binary(:io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e]))
  end
end
