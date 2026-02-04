defmodule Iso8583.Client do
  @moduledoc """
  High-level client for sending ISO 8583 transactions with automatic encoding/decoding.

  This module provides a simplified API for working with transaction structs
  instead of raw binaries. It handles the conversion between your transaction
  structs and ISO 8583 wire format automatically.

  ## Quick Start

  Define your transaction struct with formatter configuration:

      defmodule MyApp.SaleRequest do
        defstruct [:pan, :amount, :stan, :terminal_id]

        def __iso_formatter__, do: Iso8583.Formatters.Binary
        def __iso_field_map__, do: %{2 => :pan, 4 => :amount, 11 => :stan, 41 => :terminal_id}
        def __iso_mti__, do: "0200"
      end

  Then send a transaction:

      request = %SaleRequest{
        pan: "1234567890123456789",
        amount: "000000001234",
        stan: "000001",
        terminal_id: "12345678"
      }

      {:ok, response} = Iso8583.Client.send_transaction(:my_backend, request)

  ## Example: Complete Gateway/Proxy Application

  This example shows a complete application that receives messages from terminals
  in one format and forwards them to a backend in another format:

      # 1. Define your transaction types
      defmodule MyApp.SaleRequest do
        defstruct [:pan, :processing_code, :amount, :stan, :terminal_id]

        def __iso_formatter__, do: Iso8583.Formatters.Binary
        def __iso_field_map__, do: %{
          2  => :pan,
          3  => :processing_code,
          4  => :amount,
          11 => :stan,
          41 => :terminal_id
        }
        def __iso_mti__, do: "0200"

        def new(attrs) do
          struct!(__MODULE__, %{
            pan: attrs.pan,
            processing_code: Map.get(attrs, :processing_code, "000000"),
            amount: pad_amount(attrs.amount),
            stan: pad_stan(attrs.stan),
            terminal_id: attrs.terminal_id
          })
        end

        defp pad_amount(amount) when is_integer(amount) do
          amount |> to_string() |> String.pad_leading(12, "0")
        end
        defp pad_stan(stan) when is_integer(stan) do
          stan |> to_string() |> String.pad_leading(6, "0")
        end
      end

      defmodule MyApp.SaleResponse do
        defstruct [:response_code, :auth_code, :amount, :stan]

        def __iso_formatter__, do: Iso8583.Formatters.Binary
        def __iso_field_map__, do: %{
          39 => :response_code,
          38 => :auth_code,
          4  => :amount,
          11 => :stan
        }

        def approved?(%__MODULE__{response_code: "00"}), do: true
        def approved?(%__MODULE__{}), do: false
      end

      # 2. Configure your application with multiple backends
      defmodule MyApp.Application do
        use Application

        def start(_type, _args) do
          children = [
            # Backend client - Binary format
            {Iso8583.Client, name: :upstream_switch,
             transport: Iso8583.Transport.TCP.Client,
             transport_opts: [
               host: "switch.bank.example.com",
               port: 9000,
               framing: {:length_prefix, 2},
               reconnect_interval: 5000
             ],
             formatter: Iso8583.Formatters.Binary,
             request_timeout: 30000},

            # Legacy backend - ASCII Hex format!
            {Iso8583.Client, name: :legacy_backend,
             transport: Iso8583.Transport.TCP.Client,
             transport_opts: [
               host: "legacy.bank.example.com",
               port: 8100,
               framing: {:length_prefix, 2}
             ],
             formatter: Iso8583.Formatters.AsciiHex,
             request_timeout: 30000},

            # TCP Server - receives from terminals
            {Iso8583.Transport.TCP.Server,
             port: 8080,
             framing: {:length_prefix, 2},
             receive_callback: {MyApp.Gateway, :handle_terminal_request}}
          ]

          opts = [strategy: :one_for_one, name: MyApp.Supervisor]
          Supervisor.start_link(children, opts)
        end
      end

      # 3. Build your gateway
      defmodule MyApp.Gateway do
        use GenServer
        require Logger

        def handle_terminal_request(raw_binary, context) do
          # Decode using Binary formatter
          {:ok, iso_msg} = Iso8583.Formatters.Binary.decode(raw_binary)

          # Convert to struct
          request = ISOMsg.to_struct(iso_msg, MyApp.SaleRequest, %{
            2 => :pan, 3 => :processing_code, 4 => :amount,
            11 => :stan, 41 => :terminal_id
          })

          # Route based on card BIN
          backend = route_by_bin(request.pan)

          # Send - automatically encodes to correct format!
          case Iso8583.Client.send_transaction(backend, request) do
            {:ok, %MyApp.SaleResponse{} = response} ->
              Logger.info("Response: " <> response.response_code)
              # Send response back to terminal...
              handle_response(response, context)

            {:error, reason} ->
              Logger.error("Error: " <> inspect(reason))
          end

          :ok
        end

        defp route_by_bin(<<card_bin::6-bytes, _::binary>>) do
          case card_bin do
            "0011xx" -> :legacy_backend   # Legacy cards use ASCII Hex
            _ -> :upstream_switch        # Others use Binary
          end
        end
      end

      # 4. Use in IEx for testing
      # iex> request = MyApp.SaleRequest.new(%{
      # ...>   pan: "4848481234567890",
      # ...>   amount: 100_00,
      # ...>   stan: 123456,
      # ...>   terminal_id: "TERM001"
      # ...> })
      # iex> {:ok, response} = Iso8583.Client.send_transaction(:upstream_switch, request)
      # iex> MyApp.SaleResponse.approved?(response)
      # true

  ## Example: Request/Response with Different Formats

  This example shows handling messages between systems using different wire formats:

      # Terminal sends Binary, Backend expects ASCII Hex
      defmodule MyApp.FormatTransformer do
        def transform_for_backend(raw_binary) do
          # Decode from Binary (terminal format)
          {:ok, iso_msg} = Iso8583.Formatters.Binary.decode(raw_binary)

          # Convert to struct
          request = ISOMsg.to_struct(iso_msg, MyApp.SaleRequest,
                                    MyApp.SaleRequest.__iso_field_map__())

          # Send to backend - automatically encodes to ASCII Hex!
          Iso8583.Client.send_transaction(:legacy_backend, request)
        end

        def transform_for_terminal(response) do
          # Response struct comes back
          iso_msg = ISOMsg.from_struct(response, "0210",
                                      MyApp.SaleResponse.__iso_field_map__())

          # Encode to Binary for terminal
          Iso8583.Formatters.Binary.encode(iso_msg)
        end
      end

  ## Example: Multiple Transaction Types

  Define and handle different transaction types:

      defmodule MyApp.AuthRequest do
        defstruct [:pan, :amount, :stan, :terminal_id]
        def __iso_formatter__, do: Iso8583.Formatters.Binary
        def __iso_field_map__, do: %{2 => :pan, 4 => :amount, 11 => :stan, 41 => :terminal_id}
        def __iso_mti__, do: "0100"
      end

      defmodule MyApp.SaleRequest do
        defstruct [:pan, :amount, :stan, :terminal_id]
        def __iso_formatter__, do: Iso8583.Formatters.Binary
        def __iso_field_map__, do: %{2 => :pan, 4 => :amount, 11 => :stan, 41 => :terminal_id}
        def __iso_mti__, do: "0200"
      end

      defmodule MyApp.ReversalRequest do
        defstruct [:pan, :amount, :stan, :original_stan]
        def __iso_formatter__, do: Iso8583.Formatters.Binary
        def __iso_field_map__, do: %{2 => :pan, 4 => :amount, 11 => :stan, 90 => :original_stan}
        def __iso_mti__, do: "0400"
      end

      # Send different transaction types
      {:ok, auth_response} = Iso8583.Client.send_transaction(:backend, %AuthRequest{...})
      {:ok, sale_response} = Iso8583.Client.send_transaction(:backend, %SaleRequest{...})
      {:ok, reversal_response} = Iso8583.Client.send_transaction(:backend, %ReversalRequest{...})

  ## Configuration

  Clients must be registered in your supervision tree:

      defmodule MyApp.Application do
        def start(_type, _args) do
          children = [
            {Iso8583.Client, name: :my_backend,
             transport: Iso8583.Transport.TCP.Client,
             transport_opts: [host: "backend.example.com", port: 9000,
                             framing: {:length_prefix, 2}],
             formatter: Iso8583.Formatters.Binary}
          ]

          Supervisor.start_link(children, strategy: :one_for_one)
        end
      end

  ## Request/Response Correlation

  The client automatically correlates responses with requests using STAN (field 11).
  Each request must have a unique STAN for proper correlation.

  """

  use GenServer
  require Logger

  alias ISOMsg

  @type client_name :: atom()
  @type request :: struct()
  @type response :: struct()
  @type transport :: module()
  @type formatter :: module()

  defstruct [:name, :transport_pid, :formatter, :pending]

  # Client configuration
  defmodule Config do
    @moduledoc false
    defstruct [:name, :transport, :transport_opts, :formatter, :request_timeout]

    @type t :: %__MODULE__{
      name: atom(),
      transport: module(),
      transport_opts: Keyword.t(),
      formatter: module(),
      request_timeout: pos_integer()
    }
  end

  @doc """
  Starts the ISO 8583 client.

  ## Options

  - `:name` - Name to register the client (required)
  - `:transport` - Transport module (default: `Iso8583.Transport.TCP.Client`)
  - `:transport_opts` - Options passed to transport (host, port, framing, etc.)
  - `:formatter` - Formatter module (default: `Iso8583.Formatters.Binary`)
  - `:request_timeout` - Milliseconds to wait for response (default: 30000)

  """
  def start_link(opts) do
    {name, opts} = Keyword.pop!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Sends a transaction request.

  The request struct will be converted to ISOMsg using the struct's
  `__iso_field_map__/0` and `__iso_mti__/0` callbacks, encoded using
  the configured formatter, and sent via the transport.

  ## Parameters

  - `client` - Registered client name or pid
  - `request` - Request struct

  ## Returns

  - `{:ok, response_struct}` on success
  - `{:error, reason}` on failure

  ## Examples

      {:ok, response} = Iso8583.Client.send_transaction(:backend, request)

  """
  @spec send_transaction(client_name(), request()) :: {:ok, response()} | {:error, term()}
  def send_transaction(client, request) when is_atom(client) do
    GenServer.call(client, {:send_transaction, request})
  end

  def send_transaction(client_pid, request) when is_pid(client_pid) do
    GenServer.call(client_pid, {:send_transaction, request})
  end

  @doc """
  Sends a transaction with a custom timeout.

  """
  @spec send_transaction(client_name(), request(), pos_integer()) :: {:ok, response()} | {:error, term()}
  def send_transaction(client, request, timeout) when is_atom(client) and is_integer(timeout) do
    GenServer.call(client, {:send_transaction, request}, timeout)
  end

  @doc """
  Sends a raw ISO message (bypasses struct conversion).

  Use this when you have a pre-encoded ISOMsg or raw binary.

  ## Examples

      iso_msg = ISOMsg.new("0200", %{2 => "123456...", 4 => "000000001234"})
      Iso8583.Client.send_raw(:backend, iso_msg)

  """
  @spec send_raw(client_name(), ISOMsg.t() | binary()) :: :ok | {:error, term()}
  def send_raw(client, %ISOMsg{} = iso_msg) when is_atom(client) do
    GenServer.call(client, {:send_raw, iso_msg})
  end

  def send_raw(client, raw_binary) when is_atom(client) and is_binary(raw_binary) do
    GenServer.call(client, {:send_binary, raw_binary})
  end

  @impl true
  def init(opts) do
    transport = Keyword.get(opts, :transport, Iso8583.Transport.TCP.Client)
    transport_opts = Keyword.get(opts, :transport_opts, [])
    formatter = Keyword.get(opts, :formatter, Iso8583.Formatters.Binary)
    timeout = Keyword.get(opts, :request_timeout, 30000)

    # Start transport
    {:ok, transport_pid} = transport.start_link(transport_opts)

    # Set receive callback
    if function_exported?(transport, :set_receive_callback, 2) do
      transport.set_receive_callback(transport_pid, {__MODULE__, :handle_receive, [self()]})
    end

    state = %{
      name: Keyword.get(opts, :name),
      transport_pid: transport_pid,
      transport: transport,
      formatter: formatter,
      pending: %{},
      request_timeout: timeout
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:send_transaction, request}, from, state) do
    # Get formatter and field map from request struct
    formatter = get_formatter(request, state.formatter)
    field_map = get_field_map(request)
    field_defs = get_field_definitions(request)

    # Convert struct to ISOMsg
    mti = get_mti(request)
    iso_msg = ISOMsg.from_struct(request, mti, field_map)

    # Encode using formatter with field definitions
    encode_opts = if field_defs, do: [field_definitions: field_defs], else: []

    case formatter.encode(iso_msg, encode_opts) do
      raw_binary when is_binary(raw_binary) ->
        # Get STAN for correlation
        stan = Map.get(request, :stan) || ISOMsg.get_field(iso_msg, 11)

        # Store pending request
        pending = if stan do
          Map.put(state.pending, stan, {from, request})
        else
          Logger.warning("No STAN found for request, correlation not possible")
          state.pending
        end

        # Send via transport
        send_via_transport(state.transport, state.transport_pid, raw_binary)

        {:noreply, %{state | pending: pending}}

      other ->
        {:reply, {:error, {:encode_failed, other}}, state}
    end
  end

  def handle_call({:send_raw, %ISOMsg{} = iso_msg}, _from, state) do
    # Get field definitions from config if available
    field_defs = get_field_definitions_from_config(state)

    encode_opts = if field_defs, do: [field_definitions: field_defs], else: []

    case state.formatter.encode(iso_msg, encode_opts) do
      raw_binary when is_binary(raw_binary) ->
        send_via_transport(state.transport, state.transport_pid, raw_binary)
        {:reply, :ok, state}

      other ->
        {:reply, {:error, {:encode_failed, other}}, state}
    end
  end

  def handle_call({:send_binary, raw_binary}, _from, state) do
    send_via_transport(state.transport, state.transport_pid, raw_binary)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:timeout, stan}, state) do
    # Request timed out
    case Map.get(state.pending, stan) do
      {from, _request} ->
        GenServer.reply(from, {:error, :timeout})
        {:noreply, %{state | pending: Map.delete(state.pending, stan)}}

      nil ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:receive_response, raw_data, _context}, state) do
    # Get field definitions for response decoding
    field_defs = get_field_definitions_from_config(state)

    decode_opts = if field_defs, do: [field_definitions: field_defs], else: []

    # Decode response
    case state.formatter.decode(raw_data, decode_opts) do
      {:ok, %ISOMsg{} = iso_msg} ->
        stan = ISOMsg.get_field(iso_msg, 11)

        case Map.get(state.pending, stan) do
          {from, original_request} ->
            # Convert to response struct if original_request has response_module
            response = convert_to_response_struct(iso_msg, original_request)

            GenServer.reply(from, {:ok, response})
            {:noreply, %{state | pending: Map.delete(state.pending, stan)}}

          nil ->
            Logger.debug("Received response for unknown STAN: #{inspect(stan)}")
            {:noreply, state}
        end

      {:error, reason} ->
        Logger.error("Failed to decode response: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Receive callback from transport
  def handle_receive(raw_data, context, client_pid) do
    send(client_pid, {:receive_response, raw_data, context})
  end

  @impl true
  def terminate(_reason, state) do
    if state.transport_pid && Process.alive?(state.transport_pid) do
      state.transport.stop(state.transport_pid)
    end
    :ok
  end

  # Private helpers

  defp get_formatter(request, default_formatter) do
    if function_exported?(request.__struct__, :__iso_formatter__, 0) do
      request.__struct__.__iso_formatter__()
    else
      default_formatter
    end
  end

  defp get_field_map(request) do
    if function_exported?(request.__struct__, :__iso_field_map__, 0) do
      request.__struct__.__iso_field_map__()
    else
      %{}
    end
  end

  defp get_mti(request) do
    if function_exported?(request.__struct__, :__iso_mti__, 0) do
      request.__struct__.__iso_mti__()
    else
      Map.get(request, :mti, "0200")
    end
  end

  defp get_field_definitions(request) do
    if function_exported?(request.__struct__, :__iso_field_definitions__, 0) do
      request.__struct__.__iso_field_definitions__()
    else
      nil
    end
  end

  defp get_field_definitions_from_config(_state) do
    # Could be extended to read from client config
    nil
  end

  defp send_via_transport(transport, transport_pid, data) do
    transport.send(transport_pid, data)
  end

  defp convert_to_response_struct(%ISOMsg{} = iso_msg, original_request) do
    request_module = original_request.__struct__

    # Check if request has response module info
    response_module = if function_exported?(request_module, :__iso_response_module__, 0) do
      request_module.__iso_response_module__()
    else
      # Try to infer response module name
      request_name = Module.split(request_module) |> List.last()
      base_name = String.replace_suffix(request_name, "Request", "")
      response_name = String.replace_suffix(request_name, "Request", "Response")

      if base_name != request_name do
        # Was "XxxRequest" -> try "XxxResponse"
        Module.concat([request_module, Response])
      else
        # Try sibling module
        parent = request_module |> Module.split() |> Enum.drop(-1) |> Module.concat()
        Module.concat([parent, String.to_atom(response_name)])
      end
    end

    # Get field map for response
    field_map = if function_exported?(response_module, :__iso_field_map__, 0) do
      response_module.__iso_field_map__()
    else
      # Use request's field map as fallback
      if function_exported?(request_module, :__iso_field_map__, 0) do
        request_module.__iso_field_map__()
      else
        %{}
      end
    end

    # Convert ISOMsg to struct
    ISOMsg.to_struct(iso_msg, response_module, field_map)
  rescue
    _ ->
      # Return ISOMsg if struct conversion fails
      iso_msg
  end
end
