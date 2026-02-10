#!/usr/bin/env elixir

# Simple ISO 8583 WebSocket server for testing
# Run from ex_iso8583 directory

IO.puts("Starting ISO 8583 WebSocket Server on ws://localhost:4000/iso8583/ws")

# Simple callback that logs and approves
callback = fn message, context ->
  IO.inspect("Received ISO 8583 message", message: Base.encode16(message, case: :lower), context: context)

  # Build a simple approval response (MTI 0210, response code 00)
  # This is a minimal response - in production you'd parse and respond properly
  response = <<0x30, 0x32, 0x31, 0x30>>  # MTI 0210
  IO.inspect("Sending response", response: Base.encode16(response, case: :lower))
  response
end

# Start the WebSocket server directly
{:ok, _pid} = Iso8583.Transport.WebSocket.Server.start_link(
  port: 4000,
  path: "/iso8583/ws",
  name: :test_ws_server
)

# Set the callback
Iso8583.Transport.WebSocket.Server.set_receive_callback(:test_ws_server, callback)

IO.puts("Server started successfully!")
IO.puts("Press Ctrl+C to stop")

Process.sleep(:infinity)
