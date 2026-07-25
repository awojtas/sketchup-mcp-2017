# Drives the extension's socket loop outside SketchUp.
#
# The bug under test: the loop ran on SketchUp's UI thread and called
# client.gets, which blocks until a newline arrives. The Python client connects
# at startup and stays silent until a tool is invoked, so the UI froze.

$LOAD_PATH.unshift File.expand_path("support", __dir__)
$log_lines = []

require 'socket'
require 'json'
load File.expand_path("../su_mcp/su_mcp/main.rb", __dir__)

PORT = 9876
$failures = 0

def check(label, ok, detail = nil)
  puts(ok ? "  PASS  #{label}" : "  FAIL  #{label}#{detail ? " -- #{detail}" : ''}")
  $failures += 1 unless ok
end


# Poll until a response line shows up. Fixed poll counts race loopback
# delivery: polls take microseconds, so they can all run before the kernel
# has handed the bytes over.
def pump(server, client, timeout = 5)
  deadline = Time.now + timeout
  while Time.now < deadline
    server.send(:poll)
    return client.gets if IO.select([client], nil, nil, 0.02)
  end
  nil
end

server = SU_MCP::Server.new
server.instance_variable_set(:@port, PORT)
server.start
poll = lambda { server.send(:poll) }

# --- The regression itself -------------------------------------------------
# A client that connects and says nothing must not stall the caller. Before the
# fix this blocked forever; the assertion is on elapsed wall-clock time.
puts "\n1. Idle client must not block the UI thread"
client = TCPSocket.new('127.0.0.1', PORT)
t0 = Time.now
30.times { poll.call }
elapsed = Time.now - t0
check("30 polls with a silent connected client returned promptly", elapsed < 0.5,
      format("took %.3fs", elapsed))

# --- Normal request/response ----------------------------------------------
puts "\n2. Request gets a response"
client.write({ jsonrpc: "2.0", id: 1, method: "prompts/list" }.to_json + "\n")
client.flush
line = pump(server, client)
parsed = line ? JSON.parse(line) : nil
check("response received", !parsed.nil?, line.inspect)
check("id echoed back", parsed && parsed["id"] == 1, parsed.inspect)

# --- Persistence -----------------------------------------------------------
# The Python client reuses one socket across tool calls. Closing after each
# request forced a reconnect every time.
puts "\n3. Same socket serves a second request"
client.write({ jsonrpc: "2.0", id: 2, method: "prompts/list" }.to_json + "\n")
client.flush
line2 = pump(server, client)
parsed2 = line2 ? JSON.parse(line2) : nil
check("second response on the same connection", parsed2 && parsed2["id"] == 2, line2.inspect)

# --- TCP fragmentation -----------------------------------------------------
# A request split across segments must be reassembled across timer ticks, not
# discarded. A fixed per-tick read budget loses these.
puts "\n4. Request split across packets is reassembled"
payload = { jsonrpc: "2.0", id: 3, method: "prompts/list" }.to_json + "\n"
half = payload.length / 2
client.write(payload[0...half]); client.flush
20.times { server.send(:poll); sleep 0.005 }   # first half only; must not be dropped
client.write(payload[half..-1]); client.flush
line3 = pump(server, client)
parsed3 = line3 ? JSON.parse(line3) : nil
check("fragmented request answered", parsed3 && parsed3["id"] == 3, line3.inspect)

# --- Malformed input -------------------------------------------------------
puts "\n5. Malformed JSON yields a parse error, connection survives"
client.write("this is not json\n"); client.flush
line4 = pump(server, client)
parsed4 = line4 ? JSON.parse(line4) : nil
check("parse error returned", parsed4 && parsed4["error"] &&
      parsed4["error"]["code"] == -32700, line4.inspect)

client.write({ jsonrpc: "2.0", id: 5, method: "prompts/list" }.to_json + "\n")
client.flush
line5 = pump(server, client)
check("connection still usable afterwards", line5 && JSON.parse(line5)["id"] == 5, line5.inspect)

# --- Reconnect -------------------------------------------------------------
puts "\n6. Server recovers after the client disconnects"
client.close
20.times { server.send(:poll); sleep 0.005 }
check("client slot released", server.instance_variable_get(:@client).nil?)

client2 = TCPSocket.new('127.0.0.1', PORT)
20.times { server.send(:poll); sleep 0.005 }
client2.write({ jsonrpc: "2.0", id: 9, method: "prompts/list" }.to_json + "\n")
client2.flush
line6 = pump(server, client2)
check("new client served", line6 && JSON.parse(line6)["id"] == 9, line6.inspect)

client2.close
server.stop

puts "\n#{$failures.zero? ? 'ALL TESTS PASSED' : "#{$failures} FAILURE(S)"}"
exit($failures.zero? ? 0 : 1)
