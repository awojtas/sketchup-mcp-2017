require 'sketchup'
require 'json'
require 'socket'
require 'fileutils'
require 'timeout'
require 'logger'
require 'tmpdir'
require 'stringio'

puts "MCP Extension loading..."

module SU_MCP
  # JSON-RPC 2.0 error codes (canonical + custom -320xx range)
  ERR_PARSE         = -32700
  ERR_INVALID_REQ   = -32600
  ERR_METHOD        = -32601
  ERR_INVALID_PARAM = -32602
  ERR_INTERNAL      = -32603
  ERR_TRANSPORT     = -32000
  ERR_TIMEOUT       = -32001
  ERR_RUBY_EXC      = -32002

  # Log levels
  LOG_DEBUG = 0
  LOG_INFO  = 1
  LOG_WARN  = 2
  LOG_ERROR = 3
  LOG_NAMES = { LOG_DEBUG => "DEBUG", LOG_INFO => "INFO", LOG_WARN => "WARN", LOG_ERROR => "ERROR" }

  class Server
    DEFAULT_PORT          = 9876
    DEFAULT_TIMEOUT       = 60      # seconds, per request
    DEFAULT_EVAL_TIMEOUT  = 30      # seconds, per eval_ruby call
    POLL_INTERVAL         = 0.05    # seconds between select() polls
    READ_CHUNK            = 16384   # bytes per non-blocking read
    MAX_REQUEST_BYTES     = 8 * 1024 * 1024  # 8 MB hard cap

    VERSION = "2.0.0"

    # Stated once and referenced from tool descriptions. Lengths crossing the
    # tool boundary are centimetres; SketchUp's own internal unit is inches,
    # which is what raw Ruby in eval_ruby returns.
    UNITS_NOTE = "Lengths at the tool boundary are centimetres unless a tool " \
                 "says otherwise. SketchUp internally uses inches, so raw Ruby " \
                 "in eval_ruby returns inches."

    def initialize(port: nil)
      @port        = (port || ENV['SKETCHUP_MCP_PORT'] || DEFAULT_PORT).to_i
      @server      = nil
      @running     = false
      @timer_id    = nil
      @clients     = []   # array of {sock:, buffer:, id: }
      @next_cid    = 1
      @in_tick     = false
      @log_level   = parse_log_level(ENV['SKETCHUP_MCP_LOG_LEVEL'] || 'INFO')
      # SketchUp's Ruby Console exposes no read API -- Sketchup::Console has no
      # :text, :history or :to_a -- so console output cannot be retrieved
      # programmatically, only copied out of the window by hand. Mirroring to a
      # file by default makes the log available to whoever is debugging.
      # Set SKETCHUP_MCP_LOG_FILE=none to disable.
      @log_to_file = ENV['SKETCHUP_MCP_LOG_FILE'] || File.join(Dir.tmpdir, 'sketchup_mcp.log')
      @log_to_file = nil if @log_to_file.to_s.downcase == 'none'
      @verbose_console = ENV['SKETCHUP_MCP_VERBOSE_CONSOLE'] == '1'
      @request_timeout  = (ENV['SKETCHUP_MCP_TIMEOUT']      || DEFAULT_TIMEOUT).to_i
      @eval_timeout     = (ENV['SKETCHUP_MCP_EVAL_TIMEOUT'] || DEFAULT_EVAL_TIMEOUT).to_i
    end

    # Bring up the Ruby Console. Called from start, not from the constructor:
    # the extension is constructed when SketchUp loads it at launch, so showing
    # the console here popped an empty window on every startup.
    def show_console
      begin
        SKETCHUP_CONSOLE.show
      rescue StandardError
        begin
          Sketchup.send_action("showRubyPanel:")
        rescue StandardError
          UI.start_timer(0) { SKETCHUP_CONSOLE.show rescue nil }
        end
      end
    end

    def parse_log_level(str)
      case str.to_s.upcase
      when 'DEBUG' then LOG_DEBUG
      when 'INFO'  then LOG_INFO
      when 'WARN'  then LOG_WARN
      when 'ERROR' then LOG_ERROR
      else LOG_INFO
      end
    end

    # Leveled logger. INFO and above go to the Ruby Console; DEBUG needs
    # @verbose_console. Lifecycle messages (server starting, listening,
    # stopping) are INFO, and the console line is the only feedback the menu
    # items give -- with the threshold at WARN, Start Server appeared to do
    # nothing at all. Per-request chatter is DEBUG, so this stays quiet in
    # normal use. Always appends to file if @log_to_file set.
    # Dual signature:
    #   log(level_int, msg_string)  — preferred
    #   log(msg_string)             — legacy, treated as DEBUG
    def log(level_or_msg, msg = nil)
      if msg.nil?
        level = LOG_DEBUG
        text = level_or_msg.to_s
      else
        level = level_or_msg
        text = msg.to_s
      end
      return if level < @log_level
      line = "[#{Time.now.strftime('%H:%M:%S')}] MCP #{LOG_NAMES[level]}: #{text}"
      if @verbose_console || level >= LOG_INFO
        begin
          SKETCHUP_CONSOLE.write(line + "\n")
        rescue
          puts line
        end
      end
      if @log_to_file
        begin
          File.open(@log_to_file, 'a') { |f| f.puts line }
        rescue
          # best effort
        end
      end
    end

    def debug(m); log(LOG_DEBUG, m); end
    def info(m);  log(LOG_INFO, m);  end
    def warn(m);  log(LOG_WARN, m);  end
    def error(m); log(LOG_ERROR, m); end

    def start
      return if @running

      # Starting the server is a deliberate action, so surfacing the console
      # here is helpful rather than intrusive -- it is where the logging goes.
      show_console

      begin
        info "Starting server v#{VERSION} on localhost:#{@port}"
        @server = TCPServer.new('127.0.0.1', @port)
        @running = true

        @timer_id = UI.start_timer(POLL_INTERVAL, true) { tick }
        info "Server listening on port #{@port} (timeout=#{@request_timeout}s, eval_timeout=#{@eval_timeout}s, log_level=#{LOG_NAMES[@log_level]})"
      rescue StandardError => e
        error "Startup failed: #{e.message}"
        error e.backtrace.first(5).join("\n")
        stop
      end
    end

    def stop
      info "Stopping server"
      @running = false

      UI.stop_timer(@timer_id) if @timer_id
      @timer_id = nil

      @clients.each do |c|
        begin c[:sock].close rescue nil end
      end
      @clients.clear

      @server.close rescue nil
      @server = nil
      info "Server stopped"
    end

    # Single tick of the UI timer: accept new connections, drain existing ones.
    #
    # Guarded against re-entry. SketchUp keeps firing UI timers while a previous
    # callback is still inside a blocking native call, so a long-running
    # model.export re-enters tick from underneath itself. Observed on Make 2017
    # during an STL export, which blocks for minutes:
    #
    #   main.rb:in `tick'          <- fired again
    #   main.rb:in `block in start'
    #   main.rb:in `export'
    #   main.rb:in `perform_export' <- still blocked in the first call
    #
    # @clients is then mutated from two stack frames at once, and a client can
    # be serviced or dropped while an outer frame still holds it. Skipping the
    # tick is correct: the timer fires again in 100ms.
    def tick
      return unless @running
      return if @in_tick

      @in_tick = true
      begin
        accept_new_connections
        service_clients
      ensure
        @in_tick = false
      end
    rescue StandardError => e
      error "tick error: #{e.message}"
      error e.backtrace.first(5).join("\n")
    end

    def accept_new_connections
      loop do
        ready = IO.select([@server], nil, nil, 0)
        break unless ready
        begin
          sock = @server.accept_nonblock
          cid = @next_cid
          @next_cid += 1
          @clients << { sock: sock, buffer: "".force_encoding(Encoding::BINARY), id: cid }
          # Lifecycle, not per-request chatter: this is how a user confirms the
          # two halves have actually found each other.
          info "Client ##{cid} connected"
        rescue IO::WaitReadable, Errno::EAGAIN
          break
        end
      end
    end

    def service_clients
      @clients.reject! do |c|
        begin
          drain_client(c)
          false  # keep
        rescue EOFError, Errno::ECONNRESET, Errno::EPIPE
          info "Client ##{c[:id]} disconnected"
          begin c[:sock].close rescue nil end
          true   # drop
        rescue StandardError => e
          error "Client ##{c[:id]} error: #{e.message}"
          begin c[:sock].close rescue nil end
          true
        end
      end
    end

    # Read any pending bytes on the client socket, try to parse as many
    # JSON messages as possible, dispatch each one, and write responses.
    # Supports two framing modes:
    #   1. Concatenated JSON (accumulate buffer, try parse, on success consume prefix)
    #   2. Newline-delimited JSON (back-compat with v0.1.x clients)
    def drain_client(client)
      sock = client[:sock]

      loop do
        begin
          chunk = sock.read_nonblock(READ_CHUNK)
          if chunk.nil? || chunk.empty?
            raise EOFError
          end
          client[:buffer] << chunk
        rescue IO::WaitReadable, Errno::EAGAIN
          break  # no more data for now
        end

        if client[:buffer].bytesize > MAX_REQUEST_BYTES
          send_error(sock, nil, ERR_INVALID_REQ, "Request exceeds #{MAX_REQUEST_BYTES} bytes")
          client[:buffer].clear
          raise EOFError
        end
      end

      # Extract and dispatch all complete messages in buffer
      loop do
        break if client[:buffer].empty?
        request, consumed = try_parse_json_prefix(client[:buffer])

        unless request
          # try_parse_json_prefix reports "invalid" and "incomplete" the same
          # way, so garbage at the head of the buffer would otherwise sit there
          # forever: every later request is appended behind it and nothing
          # parses again until the size cap trips and the client is dropped.
          # If the buffer cannot possibly become valid JSON, say so and reset.
          if unparseable_prefix?(client[:buffer])
            warn "Discarding unparseable input from client ##{client[:id]}"
            send_error(sock, nil, ERR_PARSE, "Parse error")
            client[:buffer] = "".force_encoding(Encoding::BINARY)
            next
          end
          break  # genuinely incomplete -- wait for more bytes
        end

        client[:buffer] = client[:buffer].byteslice(consumed, client[:buffer].bytesize - consumed) || "".force_encoding(Encoding::BINARY)
        handle_and_respond(sock, request)
      end
    end

    # A JSON-RPC message must begin with { or [. Anything else at the head of
    # the buffer can never become valid, however many more bytes arrive.
    def unparseable_prefix?(buffer)
      text = buffer.dup.force_encoding('UTF-8')
      text.lstrip!
      return false if text.nil? || text.empty?

      first = text[0]
      first != '{' && first != '['
    end

    # Try to parse a JSON object from the start of +buffer+.
    # Returns [parsed_hash, bytes_consumed] or [nil, 0] if incomplete/invalid.
    # Tolerates trailing whitespace/newlines between messages.
    def try_parse_json_prefix(buffer)
      text = buffer.dup.force_encoding('UTF-8')
      text.lstrip!
      return [nil, 0] if text.empty?

      # Fast path: newline-delimited
      if idx = text.index("\n")
        line = text[0..idx].strip
        if !line.empty?
          begin
            parsed = JSON.parse(line)
            consumed = buffer.bytesize - (text.bytesize - (idx + 1))
            return [parsed, consumed]
          rescue JSON::ParserError
            # fall through to incremental parse
          end
        end
      end

      # Slow path: incremental object parse
      depth = 0
      in_string = false
      escape = false
      text.each_char.with_index do |ch, i|
        if in_string
          if escape
            escape = false
          elsif ch == '\\'
            escape = true
          elsif ch == '"'
            in_string = false
          end
          next
        end
        case ch
        when '"' then in_string = true
        when '{' then depth += 1
        when '}' then
          depth -= 1
          if depth == 0
            candidate = text[0..i]
            begin
              parsed = JSON.parse(candidate)
              consumed = buffer.bytesize - (text.bytesize - (i + 1))
              return [parsed, consumed]
            rescue JSON::ParserError
              return [nil, 0]  # malformed — wait for more or treat as framing error
            end
          end
        end
      end
      [nil, 0]
    end

    def handle_and_respond(sock, request)
      req_id = request.is_a?(Hash) ? request["id"] : nil
      begin
        response = Timeout::timeout(@request_timeout) { handle_jsonrpc_request(request) }
        send_response(sock, response)
      rescue Timeout::Error
        warn "Request timeout (>#{@request_timeout}s)"
        send_error(sock, req_id, ERR_TIMEOUT, "Request timed out after #{@request_timeout}s")
      rescue StandardError => e
        error "Handler error: #{e.class}: #{e.message}"
        error e.backtrace.first(5).join("\n")
        send_error(sock, req_id, ERR_INTERNAL, e.message, backtrace: e.backtrace.first(5))
      end
    end

    def send_response(sock, response)
      body = response.to_json + "\n"
      sock.write(body)
      sock.flush
      debug "Sent #{body.bytesize} byte response"
    end

    def send_error(sock, id, code, message, data: nil, backtrace: nil)
      payload = {
        jsonrpc: "2.0",
        error: { code: code, message: message }.tap { |h|
          extra = {}
          extra[:backtrace] = backtrace if backtrace
          extra.merge!(data) if data.is_a?(Hash)
          h[:data] = extra unless extra.empty?
        },
        id: id
      }
      begin
        sock.write(payload.to_json + "\n")
        sock.flush
      rescue StandardError => e
        error "Failed to send error response: #{e.message}"
      end
    end

    private

    def handle_jsonrpc_request(request)
      log "Handling JSONRPC request: #{request.inspect}"
      
      # Handle direct command format (for backward compatibility)
      if request["command"]
        tool_request = {
          "method" => "tools/call",
          "params" => {
            "name" => request["command"],
            "arguments" => request["parameters"]
          },
          "jsonrpc" => request["jsonrpc"] || "2.0",
          "id" => request["id"]
        }
        log "Converting to tool request: #{tool_request.inspect}"
        return handle_tool_call(tool_request)
      end

      # Handle jsonrpc format
      case request["method"]
      when "tools/call"
        handle_tool_call(request)
      when "resources/list"
        {
          jsonrpc: request["jsonrpc"] || "2.0",
          result: { 
            resources: list_resources,
            success: true
          },
          id: request["id"]
        }
      when "prompts/list"
        {
          jsonrpc: request["jsonrpc"] || "2.0",
          result: { 
            prompts: [],
            success: true
          },
          id: request["id"]
        }
      else
        {
          jsonrpc: request["jsonrpc"] || "2.0",
          error: { 
            code: -32601, 
            message: "Method not found",
            data: { success: false }
          },
          id: request["id"]
        }
      end
    end

    def list_resources
      model = Sketchup.active_model
      return [] unless model
      
      model.entities.map do |entity|
        {
          id: entity.entityID,
          type: entity.typename.downcase
        }
      end
    end

    # Compact, bounded argument preview for the one-line call log. eval_ruby
    # payloads and geometry arrays get large, so this is a preview and not a
    # record -- the full request is still logged at DEBUG.
    def summarise_args(args)
      return "" unless args.is_a?(Hash) && !args.empty?

      text = args.map { |k, v| "#{k}=#{v.inspect}" }.join(" ")
      text = text[0, 100] + "..." if text.length > 100
      " (#{text})"
    end

    def handle_tool_call(request)
      log "Handling tool call: #{request.inspect}"
      tool_name = request["params"]["name"]
      args = request["params"]["arguments"]

      # One line per tool call at INFO, so the console shows what the agent is
      # doing without turning on DEBUG. Logged on entry rather than completion
      # on purpose: when a call hangs -- SketchUp's own STL exporter blocks the
      # UI thread indefinitely -- the last line in the console names the call
      # that did it.
      # Log the name the caller used. boolean_operation is exposed as solid_op,
      # so logging the internal name made the log ungreppable by tool name.
      public_name = (tool_name == "boolean_operation") ? "solid_op" : tool_name
      info "tool: #{public_name}#{summarise_args(args)}"

      begin
        result = case tool_name
        when "create_component"
          create_component(args)
        when "delete_component"
          delete_component(args)
        when "transform_component"
          transform_component(args)
        when "get_selection"
          get_selection
        when "export", "export_scene"
          export_scene(args)
        when "set_material"
          set_material(args)
        when "boolean_operation"
          boolean_operation(args)
        when "cut_pocket"
          cut_pocket(args)
        when "chamfer_edges"
          chamfer_edges(args)
        when "fillet_edges"
          fillet_edges(args)
        when "create_mortise_tenon"
          create_mortise_tenon(args)
        when "create_dovetail"
          create_dovetail(args)
        when "create_finger_joint"
          create_finger_joint(args)
        when "create_text"
          create_text(args)
        when "create_components"
          create_components(args)
        when "array_copy"
          array_copy(args)
        when "check_model"
          check_model(args)
        when "eval_ruby"
          eval_ruby(args)
        when "batch"
          batch(args)
        when "undo_last"
          undo_last(args)
        when "measure"
          measure(args)
        when "snapshot"
          snapshot(args)
        when "list_definitions"
          list_definitions(args)
        when "list_instances"
          list_instances(args)
        when "select"
          select_entities(args)
        when "units_info"
          units_info(args)
        when "transaction"
          transaction(args)
        when "ping"
          {
            success: true,
            result: {
              pong: true,
              version: VERSION,
              time: Time.now.to_f,
              sketchup: {
                version:        (Sketchup.version rescue nil),
                version_number: (Sketchup.version_number rescue nil),
                # is_pro? reports current entitlement, not edition: a fresh Make
                # install runs a 30-day Pro trial and reports true. Treat it as
                # "are Pro features available right now", nothing more.
                is_pro:         (Sketchup.is_pro? rescue nil),
                locale:         (Sketchup.get_locale rescue nil)
              },
              # Version-gated APIs, reported up front so callers can check
              # rather than discovering absence via NoMethodError mid-operation.
              capabilities: {
                solid_tools:         solid_tools_available?,
                active_section_plane: (Sketchup::Model.instance_methods.include?(:active_section_plane) rescue false),
                section_planes:       (Sketchup::Entities.instance_methods.include?(:add_section_plane) rescue false)
              },
              units: UNITS_NOTE
            }
          }
        else
          raise "Unknown tool: #{tool_name}"
        end

        debug "Tool call result: #{result.inspect[0, 500]}"
        if result[:success]
          # Serialize payload appropriately:
          # - Hash payloads (e.g. new eval_ruby) → JSON text
          # - Scalars → to_s
          # Newer handlers put their payload under :result. The original ones
          # return it as extra keys alongside :success -- get_selection gives
          # { success: true, entities: [...] }, for instance. Reading only
          # :result turned those into the bare string "Success" and threw the
          # data away, which is upstream issue #15: "get_selection is only
          # returning a generic Success message without any selection data".
          payload = result[:result]
          if payload.nil?
            extras = result.reject { |k, _v| k == :success }
            payload = extras.empty? ? nil : extras
          end

          payload_text = case payload
                        when nil  then "Success"
                        when Hash, Array then payload.to_json
                        else payload.to_s
                        end
          response = {
            jsonrpc: request["jsonrpc"] || "2.0",
            result: {
              content: [{ type: "text", text: payload_text }],
              isError: false,
              success: true,
              resourceId: result[:id],
              structured: payload.is_a?(Hash) ? payload : nil
              # Hash#compact is Ruby 2.4+; SketchUp 2017 has 2.2.4. reject is
              # equivalent and works everywhere. This line ran on every
              # successful tool call, so getting it wrong broke all of them.
            }.reject { |_k, v| v.nil? },
            id: request["id"]
          }
          debug "Sending success response (#{payload_text.bytesize} bytes)"
          response
        else
          response = {
            jsonrpc: request["jsonrpc"] || "2.0",
            error: {
              code: ERR_INTERNAL,
              message: result[:error] || "Operation failed",
              data: { success: false }
            },
            id: request["id"]
          }
          debug "Sending error response (operation-failed)"
          response
        end
      rescue StandardError => e
        error "Tool call error: #{e.class}: #{e.message}"
        response = {
          jsonrpc: request["jsonrpc"] || "2.0",
          error: {
            code: ERR_RUBY_EXC,
            message: e.message,
            data: { success: false, backtrace: e.backtrace.first(5) }
          },
          id: request["id"]
        }
        log "Sending error response: #{response.inspect}"
        response
      end
    end

    # ──────────────────────────────────────────────────────────────────
    # Model checks
    # ──────────────────────────────────────────────────────────────────
    #
    # Coplanar overlapping faces are the one worth having a tool for. Two
    # faces on the same plane covering the same area give the depth buffer a
    # tie to break, so which one draws changes as the camera moves: the
    # surface flickers between its own colour and whatever is behind it.
    #
    # SketchUp merges coplanar faces automatically WITHIN one context, which
    # is why this almost always happens ACROSS a container boundary -- a wall
    # panel inside a group, and a rectangle drawn later as loose geometry on
    # top of it. Nothing in the UI flags it, and the model measures perfectly
    # well, so it is only visible as a rendering artifact.
    #
    # The overlap test samples points rather than intersecting polygons
    # exactly: points are taken across the region where the two faces' bounds
    # meet, and a point lying inside BOTH faces proves the same area is
    # covered twice. That can miss a very thin sliver of overlap, so a clean
    # result is good evidence rather than a proof.

    # World-space plane, canonicalised so a plane and its flip share a key.
    def canonical_plane(normal, point)
      n = [normal.x, normal.y, normal.z]
      # Fix the sign from the first component that is clearly non-zero, so an
      # inward- and outward-facing pair of the same plane compare equal.
      lead = n.index { |v| v.abs > 1e-9 }
      return nil unless lead
      n = n.map { |v| -v } if n[lead] < 0
      d = -(n[0] * point.x + n[1] * point.y + n[2] * point.z)
      [n, d]
    end

    # Two axes spanning the plane, for laying out sample points on it.
    def plane_basis(normal)
      helper = if normal.z.abs <= normal.x.abs && normal.z.abs <= normal.y.abs
                 Geom::Vector3d.new(0, 0, 1)
               else
                 Geom::Vector3d.new(1, 0, 0)
               end
      u = normal.cross(helper)
      u.normalize!
      v = normal.cross(u)
      v.normalize!
      [u, v]
    end

    # Every face in the model with its world transform and container path.
    def each_world_face(model)
      found = []
      walk = lambda do |entities, transform, path|
        entities.each do |e|
          if e.is_a?(Sketchup::Face)
            found << { :face => e, :transform => transform, :path => path }
          elsif e.is_a?(Sketchup::Group)
            label = e.name.to_s.empty? ? "Group##{e.entityID}" : "#{e.name}##{e.entityID}"
            walk.call(e.entities, transform * e.transformation, path + [label])
          elsif e.is_a?(Sketchup::ComponentInstance)
            label = e.definition.name.to_s.empty? ? "Instance##{e.entityID}" : "#{e.definition.name}##{e.entityID}"
            walk.call(e.definition.entities, transform * e.transformation, path + [label])
          end
        end
      end
      walk.call(model.entities, Geom::Transformation.new, [])
      found
    end

    # Do these two faces cover any of the same area? Sampled across the region
    # where their bounds meet, which is the only place an overlap can be.
    def faces_share_area?(a, b, normal, steps = 6)
      lo = (0..2).map { |i| [a[:box].min.to_a[i], b[:box].min.to_a[i]].max }
      hi = (0..2).map { |i| [a[:box].max.to_a[i], b[:box].max.to_a[i]].min }
      return false if (0..2).any? { |i| hi[i] - lo[i] < -1e-6 }

      u, v = plane_basis(normal)
      corners = []
      [lo[0], hi[0]].each { |x| [lo[1], hi[1]].each { |y| [lo[2], hi[2]].each { |z|
        corners << Geom::Point3d.new(x, y, z) } } }
      us = corners.map { |p| p.x * u.x + p.y * u.y + p.z * u.z }
      vs = corners.map { |p| p.x * v.x + p.y * v.y + p.z * v.z }

      # Anchor the sample grid on a point known to be on the plane.
      anchor = a[:point]
      au = anchor.x * u.x + anchor.y * u.y + anchor.z * u.z
      av = anchor.x * v.x + anchor.y * v.y + anchor.z * v.z

      inv_a = a[:transform].inverse
      inv_b = b[:transform].inverse
      inside = Sketchup::Face::PointInside

      (0..steps).each do |i|
        du = us.min + (us.max - us.min) * i / steps.to_f
        (0..steps).each do |j|
          dv = vs.min + (vs.max - vs.min) * j / steps.to_f
          p = anchor.offset(u, du - au).offset(v, dv - av)
          next unless a[:face].classify_point(p.transform(inv_a)) == inside
          return true if b[:face].classify_point(p.transform(inv_b)) == inside
        end
      end
      false
    end

    def check_model(params)
      model = Sketchup.active_model
      raise "No active model" unless model

      reject_unknown_params!(params, %w[limit max_faces], "check_model")
      limit = (params["limit"] || 50).to_i
      max_faces = (params["max_faces"] || 4000).to_i

      entries = each_world_face(model)
      truncated_scan = entries.length > max_faces
      entries = entries[0, max_faces] if truncated_scan

      # Bucket by plane, so only faces that could possibly clash are compared.
      buckets = {}
      entries.each do |entry|
        face = entry[:face]
        verts = face.outer_loop.vertices
        next if verts.length < 3
        point = verts[0].position.transform(entry[:transform])
        normal = face.normal.transform(entry[:transform])
        next if normal.length == 0
        normal.normalize!
        plane = canonical_plane(normal, point)
        next unless plane

        key = [plane[0].map { |v| (v * 100).round }, (plane[1] * 100).round]
        entry[:point]  = point
        entry[:normal] = normal
        box = Geom::BoundingBox.new
        verts.each { |vv| box.add(vv.position.transform(entry[:transform])) }
        entry[:box]  = box
        entry[:area] = face.area * (2.54 ** 2)
        (buckets[key] ||= []) << entry
      end

      overlaps = []
      buckets.each_value do |group|
        next if group.length < 2
        group.each_with_index do |a, i|
          ((i + 1)...group.length).each do |j|
            b = group[j]
            # Same container and sharing edges is normal; SketchUp would have
            # merged a genuine duplicate there, so only real area counts.
            next unless faces_share_area?(a, b, a[:normal])
            overlaps << {
              a: { id: a[:face].entityID, container: a[:path],
                   area_cm2: a[:area].round(2),
                   material: (a[:face].material ? a[:face].material.name : nil) },
              b: { id: b[:face].entityID, container: b[:path],
                   area_cm2: b[:area].round(2),
                   material: (b[:face].material ? b[:face].material.name : nil) },
              plane_cm: point_to_cm(a[:point]),
              normal: [a[:normal].x.round(3), a[:normal].y.round(3), a[:normal].z.round(3)]
            }
          end
        end
      end

      # Groups that look like solids but are not close up: the other thing
      # that quietly breaks volume, boolean ops and export.
      open_shells = []
      model.entities.each do |e|
        next unless e.is_a?(Sketchup::Group) || e.is_a?(Sketchup::ComponentInstance)
        next if (e.manifold? rescue true)
        ents = e.is_a?(Sketchup::Group) ? e.entities : e.definition.entities
        faces = ents.grep(Sketchup::Face).length
        next if faces < 4   # a single face or two is deliberate, not a broken solid
        # Flat by construction -- a pane, a decal, a cut-out outline. It was
        # never going to be a solid, so calling it a broken one is just noise.
        b = e.bounds
        next if [b.width, b.height, b.depth].any? { |d| d.abs < 1e-6 }
        open_shells << { id: e.entityID,
                         name: (e.respond_to?(:name) ? e.name : ""),
                         faces: faces,
                         bounds_cm: solid_stats(e)[:bounds_cm] }
      end

      {
        success: true,
        result: {
          faces_scanned: entries.length,
          scan_truncated: truncated_scan,
          coplanar_overlaps: {
            count: overlaps.length,
            shown: [overlaps.length, limit].min,
            note: "Two faces on the same plane covering the same area. The " \
                  "depth buffer has no way to order them, so the surface " \
                  "flickers between them as the camera moves. Usually one is " \
                  "loose geometry drawn on top of a face inside a group. Fix " \
                  "by deleting whichever is redundant, or by moving the " \
                  "stray face into the group so SketchUp can merge it.",
            pairs: overlaps[0, limit]
          },
          open_shells: {
            count: open_shells.length,
            note: "Groups with several faces that do not close into a solid. " \
                  "They report no volume and cannot take part in solid " \
                  "operations or a clean export.",
            items: open_shells[0, limit]
          }
        }
      }
    end

    # Repeat an entity along a vector -- slats, pickets, balusters, shelves,
    # drawer runs.
    #
    # This is the one thing create_components cannot express: it repeats a
    # FINISHED entity, whatever that entity is. A board with a dovetail
    # already cut into it, a whole assembly, a component instance -- all
    # repeat as they are, where listing primitives out would mean rebuilding
    # the joinery on every one.
    #
    # entity.copy preserves the type, so a Group stays a Group and a
    # ComponentInstance stays an instance sharing its definition.
    def array_copy(params)
      model = Sketchup.active_model
      raise "No active model" unless model

      reject_unknown_params!(params, %w[id count offset], "array_copy")
      source = resolve_solid(model, params["id"], "source")

      count = (params["count"] || 0).to_i
      if count < 2
        raise "count must be at least 2 -- it is the total number of items in " \
              "the finished array, including the original, so count 12 adds 11 copies"
      end

      offset = params["offset"]
      unless offset.is_a?(Array) && offset.length == 3
        raise "offset must be [dx, dy, dz] in cm -- the step from one item to the next"
      end
      step_cm = offset.map { |v| v.to_f }
      if step_cm.all? { |v| v.abs < 1e-6 }
        raise "offset is zero, so every copy would land on top of the original"
      end

      before = solid_stats(source)
      source_transform = source.transformation

      committed = false
      copies = []
      begin
        model.start_operation("MCP array_copy", true)

        (1...count).each do |i|
          copy = source.copy
          raise "copy #{i} failed" unless copy && copy.valid?
          shift = Geom::Transformation.translation(
            Geom::Vector3d.new(step_cm[0] * i / 2.54,
                               step_cm[1] * i / 2.54,
                               step_cm[2] * i / 2.54))
          # Pre-multiply: the step is a world-space move, not a local one.
          copy.transformation = shift * source_transform
          copies << copy
        end

        # Each copy must sit exactly one step further along than the last.
        # Getting this wrong is how an array comes out at 2.54x its spacing,
        # or with the steps accumulating twice.
        stats = copies.each_with_index.map do |copy, idx|
          i = idx + 1
          after = solid_stats(copy)
          (0..2).each do |axis|
            want = before[:bounds_cm][:min][axis] + step_cm[axis] * i
            got  = after[:bounds_cm][:min][axis]
            if (got - want).abs > 0.01
              raise "copy #{i} landed at #{got.round(3)} cm on " \
                    "#{AXIS_NAMES[axis]} where #{want.round(3)} was expected, " \
                    "so the spacing is wrong. Nothing was created."
            end
          end
          if before[:manifold] && !after[:manifold]
            raise "copy #{i} is not a solid although the original is. " \
                  "Nothing was created."
          end
          after
        end

        model.commit_operation
        committed = true

        {
          success: true,
          result: {
            count: count,
            ids: [source.entityID] + copies.map { |c| c.entityID },
            added: copies.length,
            offset_cm: step_cm,
            source: before,
            copies: stats
          }
        }
      ensure
        if !committed && model.respond_to?(:abort_operation)
          model.abort_operation rescue nil
        end
      end
    end

    # Create several primitives in one call and one undo step.
    #
    # A model is rarely one box. Building a run of parts a call at a time
    # leaves a partial model behind when the fifth one is wrong, and a dozen
    # entries in the undo history to unpick by hand -- so callers reached for
    # eval_ruby instead and lost the unit handling with it.
    #
    # Every item is validated BEFORE anything is built, and the whole run is
    # one abortable operation, so a bad spec anywhere means nothing is created
    # rather than a half-built assembly to clean up.
    def create_components(params)
      model = Sketchup.active_model
      raise "No active model" unless model

      reject_unknown_params!(params, %w[items], "create_components")
      items = params["items"]
      unless items.is_a?(Array) && !items.empty?
        raise "items must be a non-empty array of component specs, each like " \
              "the arguments to create_component"
      end

      items.each_with_index do |spec, i|
        raise "items[#{i}] must be an object, got #{spec.class}" unless spec.is_a?(Hash)
        reject_unknown_params!(spec, %w[type position dimensions units], "create_components items[#{i}]")

        dims = spec["dimensions"] || [1, 1, 1]
        unless dims.is_a?(Array) && dims.length == 3 && dims.all? { |v| v.to_f > 0 }
          raise "items[#{i}]: dimensions must be three lengths greater than 0, " \
                "got #{dims.inspect}"
        end
        pos = spec["position"] || [0, 0, 0]
        unless pos.is_a?(Array) && pos.length == 3
          raise "items[#{i}]: position must be [x, y, z], got #{pos.inspect}"
        end
      end

      committed = false
      created = []
      begin
        model.start_operation("MCP create_components", true)

        items.each_with_index do |spec, i|
          begin
            result = create_component(spec)
          rescue StandardError => e
            raise "items[#{i}] (#{spec['type'] || 'cube'}) failed: #{e.message}. " \
                  "Nothing was created."
          end
          id = result[:id]
          raise "items[#{i}] produced no component. Nothing was created." unless id
          created << id
        end

        stats = created.map do |id|
          entity = model.find_entity_by_id(id)
          raise "a component vanished after creation. Nothing was created." unless entity && entity.valid?
          solid_stats(entity)
        end

        bad = stats.each_with_index.select { |s, _i| !s[:manifold] }
        unless bad.empty?
          raise "items #{bad.map { |_, i| i }.inspect} did not come out as solids, " \
                "so the dimensions are probably degenerate. Nothing was created."
        end

        model.commit_operation
        committed = true

        {
          success: true,
          result: {
            count: created.length,
            ids: created,
            components: stats
          }
        }
      ensure
        if !committed && model.respond_to?(:abort_operation)
          model.abort_operation rescue nil
        end
      end
    end

    def create_component(params)
      log "Creating component with params: #{params.inspect}"
      model = Sketchup.active_model
      log "Got active model: #{model.inspect}"
      entities = model.active_entities
      log "Got active entities: #{entities.inspect}"
      
      # Lengths at the tool boundary are centimetres; SketchUp geometry is
      # inches. This was passing values through raw, so asking for a 10cm cube
      # produced a 25.4cm one -- no error, and dimensionally plausible enough to
      # go unnoticed. Pass units: "in" to supply SketchUp internal units.
      reject_unknown_params!(params, %w[type position dimensions units], "create_component")
      scale = (params["units"].to_s.downcase == "in") ? 1.0 : (1.0 / 2.54)
      pos  = (params["position"]   || [0, 0, 0]).map { |v| v.to_f * scale }
      dims = (params["dimensions"] || [1, 1, 1]).map { |v| v.to_f * scale }
      
      case params["type"]
      when "cube"
        log "Creating cube at position #{pos.inspect} with dimensions #{dims.inspect}"
        
        begin
          group = entities.add_group
          log "Created group: #{group.inspect}"
          
          face = group.entities.add_face(
            [pos[0], pos[1], pos[2]],
            [pos[0] + dims[0], pos[1], pos[2]],
            [pos[0] + dims[0], pos[1] + dims[1], pos[2]],
            [pos[0], pos[1] + dims[1], pos[2]]
          )
          log "Created face: #{face.inspect}"
          
          extrude_up(face, dims[2])
          log "Pushed/pulled face by #{dims[2]}"
          
          result = { 
            id: group.entityID,
            success: true
          }
          log "Returning result: #{result.inspect}"
          result
        rescue StandardError => e
          log "Error in create_component: #{e.message}"
          log e.backtrace.join("\n")
          raise
        end
      when "cylinder"
        log "Creating cylinder at position #{pos.inspect} with dimensions #{dims.inspect}"
        
        begin
          # Create a group to contain the cylinder
          group = entities.add_group
          
          # Extract dimensions
          radius = dims[0] / 2.0
          height = dims[2]
          
          # Create a circle at the base
          center = [pos[0] + radius, pos[1] + radius, pos[2]]
          
          # Create points for a circle
          num_segments = 24  # Number of segments for the circle
          circle_points = []
          
          num_segments.times do |i|
            angle = Math::PI * 2 * i / num_segments
            x = center[0] + radius * Math.cos(angle)
            y = center[1] + radius * Math.sin(angle)
            z = center[2]
            circle_points << [x, y, z]
          end
          
          # Create the circular face
          face = group.entities.add_face(circle_points)
          
          # Extrude the face to create the cylinder
          extrude_up(face, height)
          
          result = { 
            id: group.entityID,
            success: true
          }
          log "Created cylinder, returning result: #{result.inspect}"
          result
        rescue StandardError => e
          log "Error creating cylinder: #{e.message}"
          log e.backtrace.join("\n")
          raise
        end
      when "sphere"
        log "Creating sphere at position #{pos.inspect} with dimensions #{dims.inspect}"
        
        begin
          # Create a group to contain the sphere
          group = entities.add_group
          
          # Extract dimensions
          radius = dims[0] / 2.0
          center = [pos[0] + radius, pos[1] + radius, pos[2] + radius]
          
          # Use SketchUp's built-in sphere method if available
          if Sketchup::Tools.respond_to?(:create_sphere)
            Sketchup::Tools.create_sphere(center, radius, 24, group.entities)
          else
            # Fallback implementation using polygons
            # Create a UV sphere with latitude and longitude segments
            segments = 16
            
            # Create points for the sphere
            points = []
            for lat_i in 0..segments
              lat = Math::PI * lat_i / segments
              for lon_i in 0..segments
                lon = 2 * Math::PI * lon_i / segments
                x = center[0] + radius * Math.sin(lat) * Math.cos(lon)
                y = center[1] + radius * Math.sin(lat) * Math.sin(lon)
                z = center[2] + radius * Math.cos(lat)
                points << [x, y, z]
              end
            end
            
            # Create faces for the sphere (simplified approach)
            for lat_i in 0...segments
              for lon_i in 0...segments
                i1 = lat_i * (segments + 1) + lon_i
                i2 = i1 + 1
                i3 = i1 + segments + 1
                i4 = i3 + 1
                
                # Create a quad face
                begin
                  group.entities.add_face(points[i1], points[i2], points[i4], points[i3])
                rescue StandardError => e
                  # Skip faces that can't be created (may happen at poles)
                  log "Skipping face: #{e.message}"
                end
              end
            end
          end
          
          result = { 
            id: group.entityID,
            success: true
          }
          log "Created sphere, returning result: #{result.inspect}"
          result
        rescue StandardError => e
          log "Error creating sphere: #{e.message}"
          log e.backtrace.join("\n")
          raise
        end
      when "cone"
        log "Creating cone at position #{pos.inspect} with dimensions #{dims.inspect}"
        
        begin
          # Create a group to contain the cone
          group = entities.add_group
          
          # Extract dimensions
          radius = dims[0] / 2.0
          height = dims[2]
          
          # Create a circle at the base
          center = [pos[0] + radius, pos[1] + radius, pos[2]]
          apex = [center[0], center[1], center[2] + height]
          
          # Create points for a circle
          num_segments = 24  # Number of segments for the circle
          circle_points = []
          
          num_segments.times do |i|
            angle = Math::PI * 2 * i / num_segments
            x = center[0] + radius * Math.cos(angle)
            y = center[1] + radius * Math.sin(angle)
            z = center[2]
            circle_points << [x, y, z]
          end
          
          # Create the circular face for the base
          base = group.entities.add_face(circle_points)
          
          # Create the cone sides
          (0...num_segments).each do |i|
            j = (i + 1) % num_segments
            # Create a triangular face from two adjacent points on the circle to the apex
            group.entities.add_face(circle_points[i], circle_points[j], apex)
          end
          
          result = { 
            id: group.entityID,
            success: true
          }
          log "Created cone, returning result: #{result.inspect}"
          result
        rescue StandardError => e
          log "Error creating cone: #{e.message}"
          log e.backtrace.join("\n")
          raise
        end
      else
        raise "Unknown component type: #{params["type"]}"
      end
    end

    def delete_component(params)
      model = Sketchup.active_model
      
      # Handle ID format - strip quotes if present
      id_str = params["id"].to_s.gsub('"', '')
      log "Looking for entity with ID: #{id_str}"
      
      entity = model.find_entity_by_id(id_str.to_i)
      
      if entity
        log "Found entity: #{entity.inspect}"
        deleted_id = entity.entityID
        entity.erase!
        # Return the id rather than nothing. With no payload this serialised to
        # the bare string "Success", leaving the caller unable to confirm what
        # was actually deleted.
        { success: true, id: deleted_id }
      else
        raise "Entity not found"
      end
    end

    def transform_component(params)
      model = Sketchup.active_model
      
      # Handle ID format - strip quotes if present
      id_str = params["id"].to_s.gsub('"', '')
      log "Looking for entity with ID: #{id_str}"
      
      entity = model.find_entity_by_id(id_str.to_i)
      
      if entity
        log "Found entity: #{entity.inspect}"
        
        # Position. Two defects were fixed here, both silent:
        #
        # 1. Values were passed straight to Geom::Point3d, which takes inches,
        #    while the boundary is centimetres. Asking to move 10 moved 25.4.
        # 2. Geom::Transformation.translation is a RELATIVE offset, but the
        #    argument is called "position" and measure reports "position_cm",
        #    so callers reasonably read it as absolute. It silently accumulated.
        #
        # Both meanings are now available and named for what they do. "position"
        # is absolute, matching measure's position_cm (the transformation
        # origin); "translate" is a relative offset.
        if params["position"] && params["translate"]
          raise "Pass either position (absolute) or translate (relative), not both"
        end

        before_origin = entity.respond_to?(:transformation) ? entity.transformation.origin : nil

        if params["translate"]
          delta = params["translate"]
          offset = Geom::Vector3d.new(delta[0].to_f / 2.54, delta[1].to_f / 2.54, delta[2].to_f / 2.54)
          log "Translating by #{delta.inspect} cm"
          entity.transform!(Geom::Transformation.translation(offset))

        elsif params["position"]
          pos = params["position"]
          target = Geom::Point3d.new(pos[0].to_f / 2.54, pos[1].to_f / 2.54, pos[2].to_f / 2.54)
          log "Moving to absolute position #{pos.inspect} cm"

          unless before_origin
            raise "This entity has no transformation, so it cannot be positioned " \
                  "absolutely. Use translate instead."
          end

          entity.transform!(Geom::Transformation.translation(target - before_origin))
        end
        
        # Handle rotation (in degrees)
        if params["rotation"]
          rot = params["rotation"]
          log "Rotating by #{rot.inspect} degrees"
          
          # Convert to radians
          x_rot = rot[0] * Math::PI / 180
          y_rot = rot[1] * Math::PI / 180
          z_rot = rot[2] * Math::PI / 180
          
          # Apply rotations
          if rot[0] != 0
            rotation = Geom::Transformation.rotation(entity.bounds.center, Geom::Vector3d.new(1, 0, 0), x_rot)
            entity.transform!(rotation)
          end
          
          if rot[1] != 0
            rotation = Geom::Transformation.rotation(entity.bounds.center, Geom::Vector3d.new(0, 1, 0), y_rot)
            entity.transform!(rotation)
          end
          
          if rot[2] != 0
            rotation = Geom::Transformation.rotation(entity.bounds.center, Geom::Vector3d.new(0, 0, 1), z_rot)
            entity.transform!(rotation)
          end
        end
        
        # Handle scale
        if params["scale"]
          scale = params["scale"]
          log "Scaling by #{scale.inspect}"
          
          # Create a transformation to scale the entity
          center = entity.bounds.center
          scaling = Geom::Transformation.scaling(center, scale[0], scale[1], scale[2])
          entity.transform!(scaling)
        end
        
        { success: true, id: entity.entityID }
      else
        raise "Entity not found"
      end
    end

    def get_selection
      model = Sketchup.active_model
      selection = model.selection
      
      log "Getting selection, count: #{selection.length}"
      
      selected_entities = selection.map do |entity|
        {
          id: entity.entityID,
          type: entity.typename.downcase
        }
      end
      
      { success: true, entities: selected_entities }
    end
    
    # model.export returns false, or raises, when no exporter is registered for
    # the target extension. Report that plainly.
    #
    # This replaces guards of the form `if Sketchup.require("sketchup.rb")`.
    # Sketchup.require returns false when the file is *already loaded*, and
    # sketchup.rb always is, so those guards took the else branch every time
    # and raised "<FORMAT> exporter not available" without ever attempting an
    # export -- on installs where the export in fact works fine.
    def perform_export(model, path, options, label)
      result = begin
        model.export(path, options)
      rescue ArgumentError, NotImplementedError, RuntimeError => e
        raise "#{label} exporter is not available in this SketchUp edition (#{e.message})"
      end

      raise "#{label} exporter is not available in this SketchUp edition" unless result
      raise "#{label} export reported success but wrote no file to #{path}" unless File.exist?(path)

      result
    end

    def export_scene(params)
      log "Exporting scene with params: #{params.inspect}"
      model = Sketchup.active_model
      
      format = params["format"] || "skp"
      
      begin
        # Create a temporary directory for exports
        temp_dir = File.join(ENV['TEMP'] || ENV['TMP'] || Dir.tmpdir, "sketchup_exports")
        FileUtils.mkdir_p(temp_dir) unless Dir.exist?(temp_dir)
        
        # Generate a unique filename
        timestamp = Time.now.strftime("%Y%m%d_%H%M%S")
        filename = "sketchup_export_#{timestamp}"
        
        case format.downcase
        when "skp"
          # Export as SketchUp file
          export_path = File.join(temp_dir, "#{filename}.skp")
          log "Exporting to SketchUp file: #{export_path}"
          model.save(export_path)
          
        when "obj"
          # Export as OBJ file
          export_path = File.join(temp_dir, "#{filename}.obj")
          log "Exporting to OBJ file: #{export_path}"
          
          options = {
            :triangulated_faces => true,
            :double_sided_faces => true,
            :edges => false,
            :texture_maps => true
          }
          perform_export(model, export_path, options, "OBJ")
          
        when "dae"
          # Export as COLLADA file
          export_path = File.join(temp_dir, "#{filename}.dae")
          log "Exporting to COLLADA file: #{export_path}"
          
          options = { :triangulated_faces => true }
          perform_export(model, export_path, options, "COLLADA")
          
        when "stl"
          # Verified twice on SketchUp Make 2017: this blocks for minutes,
          # writes no file, and the request times out. model.export enters
          # SketchUp's native code, where Ruby's Timeout cannot reach it, so
          # there is no way to bound the call from here -- the only safe option
          # is to refuse before making it. File > Export still works
          # interactively, where whatever it is waiting on would be visible.
          unless ENV['SKETCHUP_MCP_ALLOW_STL'] == '1'
            raise "STL export is disabled: on SketchUp Make 2017 it blocks " \
                  "indefinitely without producing a file, and cannot be " \
                  "interrupted once started. Use File > Export in SketchUp " \
                  "instead, or set SKETCHUP_MCP_ALLOW_STL=1 to try anyway."
          end

          export_path = File.join(temp_dir, "#{filename}.stl")
          log "Exporting to STL file: #{export_path}"
          
          options = { :units => "model" }
          perform_export(model, export_path, options, "STL")
          
        when "png", "jpg", "jpeg"
          # Export as image
          ext = format.downcase == "jpg" ? "jpeg" : format.downcase
          export_path = File.join(temp_dir, "#{filename}.#{ext}")
          log "Exporting to image file: #{export_path}"
          
          # Get the current view
          view = model.active_view
          
          # Set up options for the export
          options = {
            :filename => export_path,
            :width => params["width"] || 1920,
            :height => params["height"] || 1080,
            :antialias => true,
            :transparent => (ext == "png")
          }
          
          # Export the image
          view.write_image(options)
          
        else
          raise "Unsupported export format: #{format}"
        end
        
        log "Export completed successfully to: #{export_path}"
        
        { 
          success: true, 
          path: export_path,
          format: format
        }
      rescue StandardError => e
        log "Error in export_scene: #{e.message}"
        log e.backtrace.join("\n")
        raise
      end
    end
    
    def set_material(params)
      log "Setting material with params: #{params.inspect}"
      model = Sketchup.active_model
      
      # Handle ID format - strip quotes if present
      id_str = params["id"].to_s.gsub('"', '')
      log "Looking for entity with ID: #{id_str}"
      
      entity = model.find_entity_by_id(id_str.to_i)
      
      if entity
        log "Found entity: #{entity.inspect}"
        
        material_name = params["material"]
        log "Setting material to: #{material_name}"
        
        # Get or create the material
        material = model.materials[material_name]
        if !material
          # Create a new material if it doesn't exist
          material = model.materials.add(material_name)
          
          # Handle color specification
          case material_name.downcase
          when "red"
            material.color = Sketchup::Color.new(255, 0, 0)
          when "green"
            material.color = Sketchup::Color.new(0, 255, 0)
          when "blue"
            material.color = Sketchup::Color.new(0, 0, 255)
          when "yellow"
            material.color = Sketchup::Color.new(255, 255, 0)
          when "cyan", "turquoise"
            material.color = Sketchup::Color.new(0, 255, 255)
          when "magenta", "purple"
            material.color = Sketchup::Color.new(255, 0, 255)
          when "white"
            material.color = Sketchup::Color.new(255, 255, 255)
          when "black"
            material.color = Sketchup::Color.new(0, 0, 0)
          when "brown"
            material.color = Sketchup::Color.new(139, 69, 19)
          when "orange"
            material.color = Sketchup::Color.new(255, 165, 0)
          when "gray", "grey"
            material.color = Sketchup::Color.new(128, 128, 128)
          else
            # If it's a hex color code like "#FF0000"
            if material_name.start_with?("#") && material_name.length == 7
              begin
                r = material_name[1..2].to_i(16)
                g = material_name[3..4].to_i(16)
                b = material_name[5..6].to_i(16)
                material.color = Sketchup::Color.new(r, g, b)
              rescue
                # Default to a wood color if parsing fails
                material.color = Sketchup::Color.new(184, 134, 72)
              end
            else
              # Default to a wood color
              material.color = Sketchup::Color.new(184, 134, 72)
            end
          end
        end
        
        # Apply the material to the entity
        if entity.respond_to?(:material=)
          entity.material = material
        elsif entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
          # For groups and components, we need to apply to all faces
          entities = entity.is_a?(Sketchup::Group) ? entity.entities : entity.definition.entities
          entities.grep(Sketchup::Face).each { |face| face.material = material }
        end
        
        { success: true, id: entity.entityID }
      else
        raise "Entity not found"
      end
    end
    
    # Reject arguments the handler does not understand.
    #
    # A dropped argument is the same failure mode as a wrong unit conversion:
    # the call succeeds and quietly does something other than what was asked.
    # units was silently discarded for exactly this reason, so anyone passing
    # units: "in" got centimetres and no way to tell.
    def reject_unknown_params!(params, allowed, tool)
      return unless params.is_a?(Hash)

      unknown = params.keys.map { |k| k.to_s } - allowed
      return if unknown.empty?

      raise "#{tool}: unknown argument(s): #{unknown.join(', ')}. " \
            "Accepted: #{allowed.join(', ')}."
    end

    # Extrude a base face upward.
    #
    # add_face derives its normal from winding order, so a base face can come
    # out pointing -Z. pushpull then builds the solid *below* the requested
    # position -- a box asked for at z=0 spanning z=-30..0, with nothing to
    # indicate anything went wrong.
    def extrude_up(face, distance)
      face.reverse! if face.normal.z < 0
      face.pushpull(distance)
    end

    # Push a face into the solid it sits on.
    #
    # Which sign cuts inward depends on the face's winding order, which is not
    # something to reason about per orientation branch. Decide from geometry
    # instead: if the face normal points toward the middle of the surrounding
    # geometry, a positive push goes inward.
    #
    # Everything here is in the group's local coordinates, so no transform is
    # involved.
    def pushpull_into(face, entities, depth_inches)
      box = Geom::BoundingBox.new
      entities.each { |e| box.add(e.bounds) if e.respond_to?(:bounds) }

      toward_middle = face.bounds.center.vector_to(box.center)
      inward = if toward_middle.length > 0 && (face.normal % toward_middle) < 0
                 -1.0
               else
                 1.0
               end

      face.pushpull(depth_inches * inward)
    end

    # Cut a prismatic pocket into a solid by drawing a profile on one of its
    # faces and pushing inward -- exactly the gesture a person uses in SketchUp.
    #
    # This is the non-Pro path for material removal. Solid operations
    # (solid_op) are a Pro feature, but the great majority of real cuts --
    # mortises, notches, rebates, slots, holes -- are a flat profile extruded
    # into a face, which push/pull does natively on every edition.
    #
    # Only handles prismatic cuts from a planar face. Anything needing genuine
    # CSG (cutting with an arbitrary solid, angled or curved intersections)
    # still needs solid_op and therefore Pro.
    def cut_pocket(params)
      committed = false
      model = Sketchup.active_model
      raise "No active model" unless model

      reject_unknown_params!(params, %w[id points depth], "cut_pocket")
      target = resolve_solid(model, params["id"], "target")
      points = params["points"]
      unless points.is_a?(Array) && points.length >= 3
        raise "points must be an array of at least 3 [x, y, z] coordinates in cm, " \
              "describing a closed profile lying on one face of the solid"
      end

      depth_cm = params["depth"].to_f
      raise "depth must be greater than 0" unless depth_cm > 0

      entities = target.is_a?(Sketchup::Group) ? target.entities : target.definition.entities
      before = solid_stats(target)

      # Wrap the whole cut so a failed one is a no-op. Detecting a bad result
      # and then leaving it in the model -- telling the caller to run undo_last
      # -- makes the caller clean up after us.
      model.start_operation("MCP cut_pocket", true)

      # Caller works in world-space centimetres, matching the bounds measure
      # reports; SketchUp geometry is inches in the group's OWN space. Those
      # coincide only while the group sits at the origin untransformed, so a
      # profile taken from measure landed somewhere else entirely once the
      # solid had been moved -- and a profile that misses the surface adds a
      # detached slab rather than cutting.
      pts = points.map { |p| world_cm_to_local(target, p) }

      face = entities.add_face(pts)
      raise "Could not create a face from those points -- they must be coplanar " \
            "and describe a non-degenerate profile" unless face

      pushpull_into(face, entities, depth_cm / 2.54)

      after = solid_stats(target)

      unless after[:manifold]
        raise "The cut left the solid non-manifold. The profile probably does " \
              "not lie flat on a single face, or the depth passes through the " \
              "far side. The model was left unchanged."
      end

      if before[:volume_cm3] && after[:volume_cm3] && after[:volume_cm3] >= before[:volume_cm3]
        raise "The cut removed no material (#{before[:volume_cm3].round(1)} -> " \
              "#{after[:volume_cm3].round(1)} cm3). The profile is probably not " \
              "lying on the face you meant. The model was left unchanged."
      end

      model.commit_operation
      committed = true

      {
        success: true,
        result: {
          id: target.entityID,
          depth_cm: depth_cm,
          removed_cm3: (before[:volume_cm3] && after[:volume_cm3] ?
                        (before[:volume_cm3] - after[:volume_cm3]).round(3) : nil),
          before: before,
          after: after
        }
      }
    ensure
      # Any raise above -- profile off the surface, cut removed nothing,
      # non-manifold result -- rolls back instead of leaving debris behind.
      if !committed && model && model.respond_to?(:abort_operation)
        model.abort_operation rescue nil
      end
    end

    # Solid (boolean) operations.
    #
    # Two things make this easy to get catastrophically wrong by hand, which is
    # why it is a tool rather than something callers write in eval_ruby:
    #
    # 1. Sketchup::Group#subtract subtracts the RECEIVER from the ARGUMENT.
    #    So a.subtract(b) means "b minus a" -- the receiver is the cutter, and
    #    it reads backwards. Getting it wrong consumes the solid you meant to
    #    keep and leaves the cutter behind, and the result looks plausible.
    # 2. Solid operations are a SketchUp Pro feature. On Make they are absent.
    #
    # Callers name operands by role -- target is kept, tool does the cutting --
    # and never have to know the underlying order.
    def boolean_operation(params)
      model = Sketchup.active_model
      raise "No active model" unless model

      operation = normalise_boolean_operation(params["operation"])
      target = resolve_solid(model, params["target_id"], "target")
      tool   = resolve_solid(model, params["tool_id"], "tool")

      if target.entityID == tool.entityID
        raise "target_id and tool_id are the same entity (#{target.entityID})"
      end

      unless solid_tools_available?
        raise "Solid operations are not available in this SketchUp edition -- " \
              "they are a SketchUp Pro feature, absent from Make. " \
              "Use cut_pocket instead: give it a profile on a face of the " \
              "solid and a depth, and it removes the material by push/pull, " \
              "which works on every edition. That covers prismatic cuts -- " \
              "mortises, notches, rebates, slots, holes -- which is most of " \
              "them. Only genuinely non-prismatic cutting needs Pro."
      end

      before      = solid_stats(target)
      tool_before = solid_stats(tool)

      # Solid ops consume both operands, and the checks below can reject the
      # result after the fact. Without a wrapper that rejection leaves the
      # model mangled -- the same defect cut_pocket had.
      model.start_operation("MCP solid_op", true)
      committed = false

      unless before[:manifold]
        raise "target ##{target.entityID} is not a manifold solid, so the result " \
              "would be undefined. Fix the geometry before a boolean operation."
      end
      unless tool_before[:manifold]
        raise "tool ##{tool.entityID} is not a manifold solid, so the result " \
              "would be undefined. Fix the geometry before a boolean operation."
      end

      # Solid ops consume both operands. Copy the tool when the caller wants it
      # to survive, so "keep_tool" does not depend on operand order.
      operand = params["keep_tool"] ? tool.copy : tool

      # The receiver is the cutter, the argument survives. Confirmed on
      # SketchUp 2017: a 10cm cube subtract a 20cm cube (125cm3 overlap)
      # returns 7875cm3, i.e. the argument minus the overlap.
      result = case operation
               when "subtract"  then operand.subtract(target)
               when "union"     then operand.union(target)
               when "intersect" then operand.intersect(target)
               end

      if result.nil? || !result.valid?
        raise "#{operation} produced no result. The solids may not intersect, or " \
              "the operation may be unavailable in this SketchUp edition."
      end

      after = solid_stats(result)

      # The failure this guard exists for: the operands come back inverted, so
      # what survives is the tool with a bite out of it rather than the target
      # with a hole in it. That result looks entirely plausible -- manifold,
      # sensible face count -- and is only caught by rendering the model.
      #
      # Both operands are consumed and a new group returned, so the check is on
      # volume: a subtract can only remove material from whichever solid
      # survived. If the result matches the tool's starting volume more closely
      # than the target's, the wrong one survived.
      if operation == "subtract" && after[:volume_cm3] &&
         before[:volume_cm3] && tool_before[:volume_cm3]
        from_target = (before[:volume_cm3] - after[:volume_cm3]).abs
        from_tool   = (tool_before[:volume_cm3] - after[:volume_cm3]).abs

        if after[:volume_cm3] > before[:volume_cm3] * 1.01
          raise "subtract produced a solid LARGER than the target " \
                "(target was #{before[:volume_cm3].round(1)} cm3, result is " \
                "#{after[:volume_cm3].round(1)} cm3). The wrong operand survived. " \
                "The model was left unchanged."
        end

        # Only meaningful when the two solids differ in size; with equal volumes
        # both readings give the same answer and nothing can be concluded.
        if (before[:volume_cm3] - tool_before[:volume_cm3]).abs > 0.01 &&
           from_tool < from_target
          raise "subtract appears to have kept the tool rather than the target " \
                "(target #{before[:volume_cm3].round(1)} cm3, tool " \
                "#{tool_before[:volume_cm3].round(1)} cm3, result " \
                "#{after[:volume_cm3].round(1)} cm3). The model has changed -- " \
                "the model was left unchanged. Report this: it means the " \
                "operand order in boolean_operation is wrong for this SketchUp build."
        end
      end

      model.commit_operation
      committed = true

      {
        success: true,
        result: {
          id: result.entityID,
          operation: operation,
          target_before: before,
          result_after: after,
          tool_kept: params["keep_tool"] ? true : false
        }
      }
    ensure
      if !committed && model && model.respond_to?(:abort_operation)
        model.abort_operation rescue nil
      end
    end

    # Solid operations are a SketchUp Pro feature. Checking for the method is
    # more reliable than is_pro?, which reports entitlement rather than what is
    # actually callable.
    def solid_tools_available?
      # Lets the Make/non-Pro path be exercised on a Pro (or trial) install,
      # rather than waiting for a licence to lapse to find out what breaks.
      return false if ENV['SKETCHUP_MCP_NO_SOLID_TOOLS'] == '1'

      Sketchup::Group.instance_methods.include?(:subtract) &&
        Sketchup::Group.instance_methods.include?(:union)
    rescue StandardError
      false
    end

    # Accept the names people reach for, not just one spelling.
    def normalise_boolean_operation(value)
      case value.to_s.downcase
      when "subtract", "difference", "minus" then "subtract"
      when "union", "add", "join"            then "union"
      when "intersect", "intersection"       then "intersect"
      else
        raise "Invalid operation: #{value.inspect}. " \
              "Use 'subtract', 'union' or 'intersect'."
      end
    end

    def resolve_solid(model, raw_id, role)
      id = raw_id.to_s.gsub('"', '')
      raise "#{role}_id is required" if id.empty?

      entity = model.find_entity_by_id(id.to_i)
      raise "#{role} entity ##{id} not found" unless entity

      unless entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
        raise "#{role} ##{id} is a #{entity.class}; solid operations need a " \
              "group or component instance"
      end

      entity
    end

    # Enough to tell whether an operation did what the caller intended.
    # SketchUp works in inches internally; 1 in3 = 16.387064 cm3.
    def solid_stats(entity)
      entities = entity.is_a?(Sketchup::Group) ? entity.entities : entity.definition.entities
      bounds = entity.bounds

      {
        id: entity.entityID,
        manifold: (entity.manifold? rescue false),
        volume_cm3: (entity.volume > 0 ? (entity.volume * 16.387064).round(3) : nil rescue nil),
        faces: entities.grep(Sketchup::Face).length,
        bounds_cm: {
          min:  point_to_cm(bounds.min),
          max:  point_to_cm(bounds.max),
          size: [(bounds.width * 2.54).round(3),
                 (bounds.height * 2.54).round(3),
                 (bounds.depth * 2.54).round(3)]
        }
      }
    end

    # Build a Point3d from caller-supplied coordinates, scaling into SketchUp's
    # internal inches.
    def point_from(coords, scale)
      Geom::Point3d.new(coords[0].to_f * scale,
                        coords[1].to_f * scale,
                        coords[2].to_f * scale)
    end

    def point_to_cm(point)
      [(point.x * 2.54).round(3), (point.y * 2.54).round(3), (point.z * 2.54).round(3)]
    end


    def chamfer_edges(params)
      log "Chamfering edges with params: #{params.inspect}"
      model = Sketchup.active_model
      
      # Get entity ID
      entity_id = params["entity_id"].to_s.gsub('"', '')
      log "Looking for entity with ID: #{entity_id}"
      
      entity = model.find_entity_by_id(entity_id.to_i)
      unless entity
        raise "Entity not found: #{entity_id}"
      end
      
      # Ensure entity is a group or component instance
      unless entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
        raise "Chamfer operation requires a group or component instance"
      end
      
      # Get the distance parameter
      distance = params["distance"] || 0.5
      
      # Get the entities collection
      entities = entity.is_a?(Sketchup::Group) ? entity.entities : entity.definition.entities
      
      # Find all edges in the entity
      edges = entities.grep(Sketchup::Edge)
      
      # If specific edges are provided, filter the edges
      if params["edge_indices"] && params["edge_indices"].is_a?(Array)
        edge_indices = params["edge_indices"]
        edges = edges.select.with_index { |_, i| edge_indices.include?(i) }
      end
      
      # Create a new group to hold the result
      result_group = model.active_entities.add_group
      
      # Copy all entities from the original to the result
      entities.each do |e|
        e.copy(result_group.entities)
      end
      
      # Get the edges in the result group
      result_edges = result_group.entities.grep(Sketchup::Edge)
      
      # If specific edges were provided, filter the result edges
      if params["edge_indices"] && params["edge_indices"].is_a?(Array)
        edge_indices = params["edge_indices"]
        result_edges = result_edges.select.with_index { |_, i| edge_indices.include?(i) }
      end
      
      # Perform the chamfer operation
      begin
        # Create a transformation for the chamfer
        chamfer_transform = Geom::Transformation.scaling(1.0 - distance)
        
        # For each edge, create a chamfer
        result_edges.each do |edge|
          # Get the faces connected to this edge
          faces = edge.faces
          next if faces.length < 2
          
          # Get the start and end points of the edge
          start_point = edge.start.position
          end_point = edge.end.position
          
          # Calculate the midpoint of the edge
          midpoint = Geom::Point3d.new(
            (start_point.x + end_point.x) / 2.0,
            (start_point.y + end_point.y) / 2.0,
            (start_point.z + end_point.z) / 2.0
          )
          
          # Create a chamfer by creating a new face
          # This is a simplified approach - in a real implementation,
          # you would need to handle various edge cases
          new_points = []
          
          # For each vertex of the edge
          [edge.start, edge.end].each do |vertex|
            # Get all edges connected to this vertex
            connected_edges = vertex.edges - [edge]
            
            # For each connected edge
            connected_edges.each do |connected_edge|
              # Get the other vertex of the connected edge
              other_vertex = (connected_edge.vertices - [vertex])[0]
              
              # Calculate a point along the connected edge
              direction = other_vertex.position - vertex.position
              new_point = vertex.position.offset(direction, distance)
              
              new_points << new_point
            end
          end
          
          # Create a new face using the new points
          if new_points.length >= 3
            result_group.entities.add_face(new_points)
          end
        end
        
        # Clean up the original entity if requested
        if params["delete_original"]
          entity.erase! if entity.valid?
        end
        
        # Return the result
        { 
          success: true, 
          id: result_group.entityID
        }
      rescue StandardError => e
        log "Error in chamfer_edges: #{e.message}"
        log e.backtrace.join("\n")
        
        # Clean up the result group if there was an error
        result_group.erase! if result_group.valid?
        
        raise
      end
    end
    
    def fillet_edges(params)
      log "Filleting edges with params: #{params.inspect}"
      model = Sketchup.active_model
      
      # Get entity ID
      entity_id = params["entity_id"].to_s.gsub('"', '')
      log "Looking for entity with ID: #{entity_id}"
      
      entity = model.find_entity_by_id(entity_id.to_i)
      unless entity
        raise "Entity not found: #{entity_id}"
      end
      
      # Ensure entity is a group or component instance
      unless entity.is_a?(Sketchup::Group) || entity.is_a?(Sketchup::ComponentInstance)
        raise "Fillet operation requires a group or component instance"
      end
      
      # Get the radius parameter
      radius = params["radius"] || 0.5
      
      # Get the number of segments for the fillet
      segments = params["segments"] || 8
      
      # Get the entities collection
      entities = entity.is_a?(Sketchup::Group) ? entity.entities : entity.definition.entities
      
      # Find all edges in the entity
      edges = entities.grep(Sketchup::Edge)
      
      # If specific edges are provided, filter the edges
      if params["edge_indices"] && params["edge_indices"].is_a?(Array)
        edge_indices = params["edge_indices"]
        edges = edges.select.with_index { |_, i| edge_indices.include?(i) }
      end
      
      # Create a new group to hold the result
      result_group = model.active_entities.add_group
      
      # Copy all entities from the original to the result
      entities.each do |e|
        e.copy(result_group.entities)
      end
      
      # Get the edges in the result group
      result_edges = result_group.entities.grep(Sketchup::Edge)
      
      # If specific edges were provided, filter the result edges
      if params["edge_indices"] && params["edge_indices"].is_a?(Array)
        edge_indices = params["edge_indices"]
        result_edges = result_edges.select.with_index { |_, i| edge_indices.include?(i) }
      end
      
      # Perform the fillet operation
      begin
        # For each edge, create a fillet
        result_edges.each do |edge|
          # Get the faces connected to this edge
          faces = edge.faces
          next if faces.length < 2
          
          # Get the start and end points of the edge
          start_point = edge.start.position
          end_point = edge.end.position
          
          # Calculate the midpoint of the edge
          midpoint = Geom::Point3d.new(
            (start_point.x + end_point.x) / 2.0,
            (start_point.y + end_point.y) / 2.0,
            (start_point.z + end_point.z) / 2.0
          )
          
          # Calculate the edge vector
          edge_vector = end_point - start_point
          edge_length = edge_vector.length
          
          # Create points for the fillet curve
          fillet_points = []
          
          # Create a series of points along a circular arc
          (0..segments).each do |i|
            angle = Math::PI * i / segments
            
            # Calculate the point on the arc
            x = midpoint.x + radius * Math.cos(angle)
            y = midpoint.y + radius * Math.sin(angle)
            z = midpoint.z
            
            fillet_points << Geom::Point3d.new(x, y, z)
          end
          
          # Create edges connecting the fillet points
          (0...fillet_points.length - 1).each do |i|
            result_group.entities.add_line(fillet_points[i], fillet_points[i+1])
          end
          
          # Create a face from the fillet points
          if fillet_points.length >= 3
            result_group.entities.add_face(fillet_points)
          end
        end
        
        # Clean up the original entity if requested
        if params["delete_original"]
          entity.erase! if entity.valid?
        end
        
        # Return the result
        { 
          success: true, 
          id: result_group.entityID
        }
      rescue StandardError => e
        log "Error in fillet_edges: #{e.message}"
        log e.backtrace.join("\n")
        
        # Clean up the result group if there was an error
        result_group.erase! if result_group.valid?
        
        raise
      end
    end
    
    # ──────────────────────────────────────────────────────────────────
    # Joinery
    # ──────────────────────────────────────────────────────────────────
    #
    # All three joints are the same shape of problem: two boards that
    # overlap in space, and a set of prismatic cuts inside that overlap
    # which leave the two halves interlocking. Nothing here needs Pro --
    # every cut is a profile pushed into a face, the same gesture
    # cut_pocket uses.
    #
    # The previous implementations took abstract width/height/depth plus
    # offsets and guessed a face from a direction vector. They read the
    # boards' WORLD bounds and then added faces into the boards' LOCAL
    # entities, so the moment a board was moved the cuts landed somewhere
    # else -- which is how they came to shear and displace the workpiece
    # instead of cutting it. Geometry is derived from the overlap here,
    # every point is converted world -> local before use, and each board
    # is addressed by the ROLE the caller gave it rather than by where it
    # happens to sit.

    AXIS_NAMES = %w[x y z].freeze

    # Caller coordinates are world-space centimetres, matching what
    # measure reports. Group geometry lives in the group's own space.
    def world_cm_to_local(entity, coords)
      point = Geom::Point3d.new(coords[0].to_f / 2.54,
                                coords[1].to_f / 2.54,
                                coords[2].to_f / 2.54)
      point.transform(entity.transformation.inverse)
    end

    def world_bounds_cm(entity)
      bb = entity.bounds
      { :min => [bb.min.x * 2.54, bb.min.y * 2.54, bb.min.z * 2.54],
        :max => [bb.max.x * 2.54, bb.max.y * 2.54, bb.max.z * 2.54] }
    end

    def bounds_centre_cm(box)
      (0..2).map { |i| (box[:min][i] + box[:max][i]) / 2.0 }
    end

    # The region the joint is cut in: where the two boards share space.
    def joint_overlap_cm(a, b)
      ba = world_bounds_cm(a)
      bb = world_bounds_cm(b)
      min = (0..2).map { |i| [ba[:min][i], bb[:min][i]].max }
      max = (0..2).map { |i| [ba[:max][i], bb[:max][i]].min }

      if (0..2).any? { |i| max[i] - min[i] <= 1e-6 }
        raise "The two boards do not overlap, so there is no region to cut " \
              "the joint in. Position them so the joint end of one sits " \
              "inside the other by the depth of the joint. Board bounds " \
              "(cm): #{ba[:min].map { |v| v.round(2) }}-" \
              "#{ba[:max].map { |v| v.round(2) }} and " \
              "#{bb[:min].map { |v| v.round(2) }}-#{bb[:max].map { |v| v.round(2) }}."
      end

      { :min => min, :max => max }
    end

    # The axis along which the boards approach each other. Taken from the
    # separation of their centres rather than guessed from a face normal:
    # if the boards meet end to end, that separation is unambiguous.
    def joint_axis(a, b)
      ca = bounds_centre_cm(world_bounds_cm(a))
      cb = bounds_centre_cm(world_bounds_cm(b))
      sep = (0..2).map { |i| (cb[i] - ca[i]).abs }
      axis = sep.index(sep.max)

      rival = ((0..2).to_a - [axis]).map { |i| sep[i] }.max
      if sep[axis] <= 1e-6 || rival > sep[axis] * 0.5
        raise "Cannot tell which way the boards meet: their centres are " \
              "separated by #{sep.map { |v| v.round(2) }} cm on x/y/z, which " \
              "is ambiguous. Joinery expects two boards meeting along one " \
              "axis; position them so they are offset mainly on a single one."
      end

      axis
    end

    # A profile in the plane perpendicular to `normal_axis`, built from
    # (u, v) pairs and returned as world-centimetre points.
    def joint_profile(normal_axis, u_axis, v_axis, plane, uv_pairs)
      uv_pairs.map do |pair|
        p = [0.0, 0.0, 0.0]
        p[normal_axis] = plane
        p[u_axis] = pair[0]
        p[v_axis] = pair[1]
        p
      end
    end

    def joint_rect(normal_axis, u_axis, v_axis, plane, u0, u1, v0, v1)
      joint_profile(normal_axis, u_axis, v_axis, plane,
                    [[u0, v0], [u1, v0], [u1, v1], [u0, v1]])
    end

    # One prismatic cut. Deliberately does NOT open an operation: a joint is
    # several coordinated cuts and a half-cut joint is worse than none, so
    # the caller wraps the whole set in a single abortable operation.
    def apply_joint_cut(entity, points_world_cm, depth_cm)
      entities = entity.is_a?(Sketchup::Group) ? entity.entities : entity.definition.entities
      face = entities.add_face(points_world_cm.map { |p| world_cm_to_local(entity, p) })
      raise "Could not create a cut profile on ##{entity.entityID}: the " \
            "profile must be coplanar and lie on one face of the board." unless face
      pushpull_into(face, entities, depth_cm / 2.54)
    end

    # Shared driver: work out the joint frame, run the cuts inside one
    # operation, and verify the result before committing.
    #
    # The post-condition that matters is the volume identity. After any of
    # these joints the two boards must between them fill the overlap region
    # exactly once, so:
    #
    #   volume(a) + volume(b) == before(a) + before(b) - volume(overlap)
    #
    # That single identity catches material added instead of removed, cuts
    # placed on the wrong board, cuts that missed the overlap, gaps, and
    # the two halves interpenetrating -- every failure mode the old
    # implementations shipped with.
    def build_joint(params, name, id_keys, extra_keys)
      model = Sketchup.active_model
      raise "No active model" unless model
      reject_unknown_params!(params, id_keys + extra_keys, name)

      role_a, role_b = id_keys.map { |k| k.sub(/_id\z/, "") }
      a = resolve_solid(model, params[id_keys[0]], role_a)
      b = resolve_solid(model, params[id_keys[1]], role_b)
      if a.entityID == b.entityID
        raise "#{name}: #{id_keys[0]} and #{id_keys[1]} are the same entity " \
              "(##{a.entityID})"
      end

      before_a = solid_stats(a)
      before_b = solid_stats(b)
      [[a, before_a], [b, before_b]].each do |entity, stats|
        unless stats[:manifold] && stats[:volume_cm3]
          raise "board ##{entity.entityID} is not a manifold solid, so a joint " \
                "cut into it would be undefined. Fix the geometry first."
        end
      end

      axis    = joint_axis(a, b)
      overlap = joint_overlap_cm(a, b)
      j0 = overlap[:min][axis]
      j1 = overlap[:max][axis]

      # The board sitting lower on the joint axis reaches up to the far side
      # of the overlap; the higher one starts at the near side. Anything else
      # is one board passing through another, not two boards meeting.
      a_is_low = bounds_centre_cm(world_bounds_cm(a))[axis] <
                 bounds_centre_cm(world_bounds_cm(b))[axis]
      low = a_is_low ? a : b
      high = a_is_low ? b : a
      unless (world_bounds_cm(low)[:max][axis] - j1).abs < 1e-3 &&
             (world_bounds_cm(high)[:min][axis] - j0).abs < 1e-3
        raise "The boards do not meet end to end on the #{AXIS_NAMES[axis]} " \
              "axis -- one passes through the other rather than butting " \
              "against it. The joint region must be the end of one board " \
              "overlapping the end of the other."
      end

      others = (0..2).to_a - [axis]
      across = if params["across"]
                 idx = AXIS_NAMES.index(params["across"].to_s.downcase)
                 raise "across must be one of x, y, z" unless idx
                 if idx == axis
                   raise "across cannot be #{AXIS_NAMES[axis]}: that is the " \
                         "axis the boards meet along."
                 end
                 idx
               else
                 # Fingers and tails run across the width of a board, so
                 # default to the wider of the two remaining directions.
                 others.max_by { |i| overlap[:max][i] - overlap[:min][i] }
               end
      through = (others - [across])[0]

      # Each board's cuts start from its own end face and run inward. Bind
      # this to the board, not to a position, so a planner that says "cut
      # the socket into the mortise board" cannot silently cut the other one.
      end_plane      = {}
      shoulder_plane = {}
      end_plane[low.entityID]       = j1
      shoulder_plane[low.entityID]  = j0
      end_plane[high.entityID]      = j0
      shoulder_plane[high.entityID] = j1

      frame = {
        :axis => axis, :across => across, :through => through,
        :j0 => j0, :j1 => j1, :depth => j1 - j0,
        :a0 => overlap[:min][across], :a1 => overlap[:max][across],
        :t0 => overlap[:min][through], :t1 => overlap[:max][through],
        :a => a, :b => b, :low => low, :high => high,
        :end_plane => end_plane, :shoulder_plane => shoulder_plane
      }

      cuts = yield(frame, params)

      overlap_volume = (0..2).inject(1.0) do |acc, i|
        acc * (overlap[:max][i] - overlap[:min][i])
      end

      committed = false
      begin
        model.start_operation("MCP #{name}", true)
        cuts.each { |cut| apply_joint_cut(cut[0], cut[1], cut[2]) }

        after_a = solid_stats(a)
        after_b = solid_stats(b)

        unless after_a[:manifold] && after_b[:manifold] &&
               after_a[:volume_cm3] && after_b[:volume_cm3]
          raise "The joint left a board non-manifold, so the cuts did not lie " \
                "cleanly on the boards. The model was left unchanged."
        end

        expected  = before_a[:volume_cm3] + before_b[:volume_cm3] - overlap_volume
        actual    = after_a[:volume_cm3] + after_b[:volume_cm3]
        tolerance = [overlap_volume * 0.001, 0.01].max

        if (actual - expected).abs > tolerance
          raise "The joint does not interlock: the two boards together come " \
                "to #{actual.round(3)} cm3, where halves filling the overlap " \
                "exactly once would be #{expected.round(3)} cm3 (out by " \
                "#{(actual - expected).round(3)}). They overlap or leave a " \
                "gap. The model was left unchanged."
        end

        model.commit_operation
        committed = true

        {
          success: true,
          result: {
            joint: name,
            axis: AXIS_NAMES[axis],
            across: AXIS_NAMES[across],
            depth_cm: (j1 - j0).round(3),
            overlap_cm3: overlap_volume.round(3),
            cuts: cuts.length,
            boards: [
              { id: a.entityID, role: role_a, before: before_a, after: after_a,
                removed_cm3: (before_a[:volume_cm3] - after_a[:volume_cm3]).round(3) },
              { id: b.entityID, role: role_b, before: before_b, after: after_b,
                removed_cm3: (before_b[:volume_cm3] - after_b[:volume_cm3]).round(3) }
            ]
          }
        }
      ensure
        if !committed && model.respond_to?(:abort_operation)
          model.abort_operation rescue nil
        end
      end
    end

    # Box joint: alternating square fingers across the width of the joint.
    def create_finger_joint(params)
      build_joint(params, "create_finger_joint",
                  %w[board1_id board2_id], %w[fingers across]) do |f, p|
        count = (p["fingers"] || 5).to_i
        raise "fingers must be at least 2" if count < 2

        width = (f[:a1] - f[:a0]) / count.to_f
        cuts = []
        (0...count).each do |i|
          u0 = f[:a0] + i * width
          # board1 keeps the even bands, board2 the odd ones, so between
          # them they fill the overlap exactly once.
          board = i.odd? ? f[:a] : f[:b]
          cuts << [board,
                   joint_rect(f[:axis], f[:across], f[:through],
                              f[:end_plane][board.entityID],
                              u0, u0 + width, f[:t0], f[:t1]),
                   f[:depth]]
        end
        cuts
      end
    end

    # Mortise and tenon: a rectangular socket in one board, and the matching
    # stub left on the other by cutting its four shoulders away.
    def create_mortise_tenon(params)
      build_joint(params, "create_mortise_tenon",
                  %w[mortise_id tenon_id], %w[width height across]) do |f, p|
        span_a = f[:a1] - f[:a0]
        span_t = f[:t1] - f[:t0]
        w = (p["width"]  || span_a / 2.0).to_f
        h = (p["height"] || span_t / 3.0).to_f

        if w <= 0 || w >= span_a
          raise "width must be between 0 and #{span_a.round(2)} cm, the joint's " \
                "extent across #{AXIS_NAMES[f[:across]]}"
        end
        if h <= 0 || h >= span_t
          raise "height must be between 0 and #{span_t.round(2)} cm, the joint's " \
                "extent across #{AXIS_NAMES[f[:through]]}"
        end

        # Centred on the overlap.
        ac = (f[:a0] + f[:a1]) / 2.0
        tc = (f[:t0] + f[:t1]) / 2.0
        u0 = ac - w / 2.0
        u1 = ac + w / 2.0
        v0 = tc - h / 2.0
        v1 = tc + h / 2.0

        mortise = f[:a]
        tenon   = f[:b]
        cuts = []
        # The socket, cut into the mortise board's end face.
        cuts << [mortise,
                 joint_rect(f[:axis], f[:across], f[:through],
                            f[:end_plane][mortise.entityID], u0, u1, v0, v1),
                 f[:depth]]
        # The four shoulders, cut off the tenon board, leaving the stub.
        [[f[:a0], f[:a1], f[:t0], v0],
         [f[:a0], f[:a1], v1, f[:t1]],
         [f[:a0], u0, v0, v1],
         [u1, f[:a1], v0, v1]].each do |s|
          next if (s[1] - s[0]).abs < 1e-9 || (s[3] - s[2]).abs < 1e-9
          cuts << [tenon,
                   joint_rect(f[:axis], f[:across], f[:through],
                              f[:end_plane][tenon.entityID], s[0], s[1], s[2], s[3]),
                   f[:depth]]
        end
        cuts
      end
    end

    # Through dovetail. The taper lies in the plane of the boards' faces, so
    # each waste region is still a flat profile pushed straight through the
    # thickness -- prismatic, and therefore no Pro requirement.
    def create_dovetail(params)
      build_joint(params, "create_dovetail",
                  %w[tail_id pin_id], %w[tails angle across]) do |f, p|
        count = (p["tails"] || 2).to_i
        raise "tails must be at least 1" if count < 1
        angle = (p["angle"] || 10.0).to_f
        raise "angle must be between 0 and 45 degrees" if angle <= 0 || angle >= 45

        span  = f[:a1] - f[:a0]
        unit  = span / (2 * count + 1).to_f
        splay = f[:depth] * Math.tan(angle * Math::PI / 180.0)
        if splay >= unit
          raise "angle #{angle} splays the tails by #{splay.round(2)} cm over a " \
                "#{f[:depth].round(2)} cm joint, wider than the #{unit.round(2)} " \
                "cm spacing. Use a smaller angle or fewer tails."
        end

        tail_board = f[:a]
        pin_board  = f[:b]
        # Tails are narrow at the shoulder and wide at the tail board's own
        # end -- the flare is what stops the joint pulling apart.
        shoulder = f[:shoulder_plane][tail_board.entityID]
        tip      = f[:end_plane][tail_board.entityID]
        thickness = f[:t1] - f[:t0]

        tails = (0...count).map do |k|
          lo_edge = f[:a0] + (2 * k + 1) * unit
          [lo_edge, lo_edge + unit]
        end

        # Waste between and outside the tails, taken off the tail board. The
        # profile lies on the board's face and is pushed through the full
        # thickness, so the taper stays a flat extrusion.
        regions = []
        prev = f[:a0]
        tails.each do |t|
          regions << [prev, t[0]]
          prev = t[1]
        end
        regions << [prev, f[:a1]]

        cuts = []
        regions.each_with_index do |r, i|
          next if (r[1] - r[0]).abs < 1e-9
          # A waste region narrows by the splay wherever it abuts a tail; the
          # two outer regions abut one on a single side only.
          e0 = (i == 0) ? r[0] : r[0] + splay
          e1 = (i == regions.length - 1) ? r[1] : r[1] - splay
          cuts << [tail_board,
                   joint_profile(f[:through], f[:axis], f[:across], f[:t1],
                                 [[shoulder, r[0]], [tip, e0],
                                  [tip, e1], [shoulder, r[1]]]),
                   thickness]
        end

        # Sockets in the pin board, exactly the tail shapes.
        tails.each do |t|
          cuts << [pin_board,
                   joint_profile(f[:through], f[:axis], f[:across], f[:t1],
                                 [[shoulder, t[0]], [tip, t[0] - splay],
                                  [tip, t[1] + splay], [shoulder, t[1]]]),
                   thickness]
        end
        cuts
      end
    end

    # ──────────────────────────────────────────────────────────────────
    # 3D text
    # ──────────────────────────────────────────────────────────────────
    #
    # Raised lettering -- house numbers, signage, labels. SketchUp builds the
    # glyph outlines itself via add_3d_text, so this is real letterforms with
    # curves and counters, not something assembled from points.
    #
    # Two things make it worth a tool rather than raw eval_ruby:
    #
    # 1. add_3d_text returns true/false, NOT the geometry it created. Call it
    #    on active_entities and the result is loose in the model with nothing
    #    identifying it. It has to be given its own group first.
    # 2. Standing text up on a wall means building an axes transform. Get the
    #    handedness wrong and the text comes out MIRRORED -- and a mirrored
    #    glyph has identical bounds, volume and face count to a correct one,
    #    so nothing but looking at it will tell you. The reading direction is
    #    derived here rather than left to the caller.

    # Outward direction the lettering faces, i.e. the side you read it from.
    TEXT_FACINGS = {
      "+x" => [1.0, 0.0, 0.0], "-x" => [-1.0, 0.0, 0.0],
      "+y" => [0.0, 1.0, 0.0], "-y" => [0.0, -1.0, 0.0],
      "+z" => [0.0, 0.0, 1.0], "-z" => [0.0, 0.0, -1.0]
    }.freeze

    def create_text(params)
      model = Sketchup.active_model
      raise "No active model" unless model

      reject_unknown_params!(params, %w[text position facing height depth sink
                                        font bold italic name], "create_text")

      text = params["text"].to_s
      raise "text must not be empty" if text.strip.empty?

      key = (params["facing"] || "+z").to_s.downcase.strip
      key = "+" + key unless key =~ /\A[-+]/
      normal = TEXT_FACINGS[key]
      unless normal
        raise "facing must be one of #{TEXT_FACINGS.keys.join(', ')} -- the " \
              "direction the lettering faces, which is the side you read it from"
      end

      height_cm = (params["height"] || 5.0).to_f
      raise "height must be greater than 0" unless height_cm > 0
      depth_cm = (params["depth"] || 0.3).to_f
      raise "depth must be greater than 0" unless depth_cm > 0

      # Bedded this far into the surface so the back face is buried rather than
      # coplanar with it. 0 restores the flush placement, which looks correct
      # in every measurement and flickers on screen.
      sink_cm = params.key?("sink") ? params["sink"].to_f : 0.05
      raise "sink must be 0 or more" if sink_cm < 0

      position = params["position"] || [0.0, 0.0, 0.0]
      unless position.is_a?(Array) && position.length == 3
        raise "position must be [x, y, z] in cm -- where the lettering is " \
              "centred on the surface it sits on"
      end

      font   = (params["font"] || "Arial").to_s
      bold   = params["bold"] ? true : false
      italic = params["italic"] ? true : false

      # Reading direction from the facing, so the caller cannot produce
      # mirrored text: with up fixed, right = up x facing is the only
      # right-handed choice.
      facing = Geom::Vector3d.new(normal[0], normal[1], normal[2])
      up = if normal[2].abs > 0.5
             Geom::Vector3d.new(0, 1, 0)   # lettering laid flat
           else
             Geom::Vector3d.new(0, 0, 1)   # lettering standing on a wall
           end
      right = up.cross(facing)

      committed = false
      group = nil
      begin
        model.start_operation("MCP create_text", true)
        group = model.active_entities.add_group
        group.name = (params["name"] || "text #{text}").to_s

        built = group.entities.add_3d_text(
          text, TextAlignLeft, font, bold, italic,
          height_cm / 2.54, 0.0, 0.0, true,
          # Long enough to stand `depth` proud AND reach `sink` behind the
          # surface, so the back face is buried rather than coplanar with it.
          (depth_cm + sink_cm) / 2.54)

        unless built && group.entities.grep(Sketchup::Face).length > 0
          raise "SketchUp could not build 3D text for #{text.inspect} in font " \
                "#{font.inspect}. The font may not be installed -- try Arial."
        end

        # add_3d_text lays the glyphs in the XY plane extruded along +Z. Move
        # that frame onto the surface: reading along `right`, up along `up`,
        # and growing outward along `facing`, with the glyphs centred on the
        # requested point.
        #
        # The back face is bedded slightly INTO the surface rather than laid
        # flush on it. Flush means two faces on one plane covering the same
        # area, which gives the depth buffer a tie to break -- so the lettering
        # flickers against the wall as the camera moves. Burying the back face
        # removes the tie. It is the same defect check_model looks for, and
        # this tool used to create one every time it ran.
        b = group.bounds
        cx = (b.min.x + b.max.x) / 2.0
        cy = (b.min.y + b.max.y) / 2.0
        px = position[0].to_f / 2.54
        py = position[1].to_f / 2.54
        pz = position[2].to_f / 2.54
        back = -sink_cm / 2.54   # along `facing`, so negative is into the surface

        origin = Geom::Point3d.new(px - cx * right.x - cy * up.x + back * facing.x,
                                   py - cx * right.y - cy * up.y + back * facing.y,
                                   pz - cx * right.z - cy * up.z + back * facing.z)
        group.transformation = Geom::Transformation.axes(origin, right, up, facing)

        stats = solid_stats(group)

        # The lettering must stand proud of the surface by `depth` and reach
        # `sink` behind it -- not straddle the surface the wrong way round, and
        # not sit flush.
        axis = normal.index { |v| v != 0.0 }
        sign = normal[axis]
        near_face = stats[:bounds_cm][:min][axis]
        far_face  = stats[:bounds_cm][:max][axis]
        at = position[axis].to_f
        lo = sign > 0 ? at - sink_cm : at - depth_cm
        hi = sign > 0 ? at + depth_cm : at + sink_cm
        if (near_face - lo).abs > 0.01 || (far_face - hi).abs > 0.01
          raise "The lettering did not land on the surface: it spans " \
                "#{near_face.round(2)}..#{far_face.round(2)} cm on " \
                "#{AXIS_NAMES[axis]} where #{lo.round(2)}..#{hi.round(2)} was " \
                "expected. The model was left unchanged."
        end

        model.commit_operation
        committed = true

        {
          success: true,
          result: {
            id: group.entityID,
            name: group.name,
            text: text,
            facing: key,
            height_cm: height_cm,
            depth_cm: depth_cm,
            sink_cm: sink_cm,
            font: font,
            solid: stats[:manifold],
            volume_cm3: stats[:volume_cm3],
            faces: stats[:faces],
            bounds_cm: stats[:bounds_cm]
          }
        }
      ensure
        if !committed && model.respond_to?(:abort_operation)
          model.abort_operation rescue nil
        end
      end
    end
    
    # ──────────────────────────────────────────────────────────────────
    # Phase B: batch & undo_last
    # ──────────────────────────────────────────────────────────────────

    # batch({ "calls": [{"tool": "eval_ruby", "args": {...}}, ...],
    #         "wrap_undo": true, "undo_name": "MCP batch", "stop_on_error": true })
    # Runs each sub-call inside ONE model.start_operation / commit_operation,
    # returning an array of per-call results. Any call that raises either
    # aborts the whole batch (stop_on_error) or is recorded as an error
    # entry and the batch continues.
    def batch(params)
      calls = Array(params["calls"])
      wrap_undo     = params["wrap_undo"] != false  # default true
      undo_name     = params["undo_name"] || "MCP batch"
      stop_on_error = params["stop_on_error"] != false

      results = []
      model = Sketchup.active_model

      runner = lambda do
        calls.each_with_index do |call, i|
          begin
            tool_name = call["tool"] || call[:tool]
            args      = call["args"] || call[:args] || {}
            sub_req = {
              "jsonrpc" => "2.0",
              "method"  => "tools/call",
              "params"  => { "name" => tool_name, "arguments" => args },
              "id"      => "batch-#{i}"
            }
            resp = handle_tool_call(sub_req)
            if resp[:error] || resp["error"]
              err = resp[:error] || resp["error"]
              msg = err[:message] || err["message"]
              results << { index: i, success: false, error: msg }
              raise "batch[#{i}] failed: #{msg}" if stop_on_error
            else
              payload = resp[:result] || resp["result"]
              results << { index: i, success: true, result: payload }
            end
          rescue StandardError => e
            results << { index: i, success: false, error: e.message }
            raise if stop_on_error
          end
        end
      end

      if wrap_undo && model
        model.start_operation(undo_name, true)
        begin
          runner.call
          model.commit_operation
        rescue StandardError => e
          model.abort_operation rescue nil
          return { success: false, error: e.message, result: { completed: results.size, results: results } }
        end
      else
        runner.call
      end

      { success: true, result: { count: results.size, results: results } }
    end

    # undo_last({ "steps": 1 }) — undo N operations in active model
    def undo_last(params)
      steps = (params && params["steps"] || 1).to_i
      steps = 1 if steps < 1
      model = Sketchup.active_model
      raise "No active model" unless model
      # Sketchup::Model has start_operation / commit_operation /
      # abort_operation, but no undo_operation -- calling it raises
      # NoMethodError. The old rescue swallowed that and reported
      # "undone: 0", which reads as "nothing to undo" rather than "this has
      # never worked". Programmatic undo goes through the menu action.
      undone = 0
      errors = []

      steps.times do
        begin
          if model.respond_to?(:undo_operation)
            model.undo_operation
          else
            Sketchup.send_action("editUndo:")
          end
          undone += 1
        rescue StandardError => e
          errors << "#{e.class}: #{e.message}"
          break
        end
      end

      result = { undone: undone, requested: steps }
      # Surface the reason rather than silently under-reporting.
      result[:errors] = errors unless errors.empty?
      # send_action posts to SketchUp's UI queue rather than running inline, so
      # "requested" is what was asked for and dispatched -- the model may not
      # reflect it until the queue drains. Re-query if you need certainty.
      result[:dispatched_async] = true unless model.respond_to?(:undo_operation)
      { success: true, result: result }
    end

    # ──────────────────────────────────────────────────────────────────
    # Phase C: new capability tools
    # ──────────────────────────────────────────────────────────────────

    # measure({ "id": 12345 }) — bounds + position + material + class
    def measure(params)
      entity_id = (params["id"] || params["entity_id"]).to_i
      model = Sketchup.active_model
      raise "No active model" unless model
      entity = model.find_entity_by_id(entity_id)
      raise "No entity with id=#{entity_id}" unless entity

      data = {
        id: entity_id,
        class: entity.class.name,
        valid: entity.valid?
      }
      if entity.respond_to?(:bounds)
        bb = entity.bounds
        data[:bounds_cm] = {
          min: bb.min.to_a.map { |v| (v.to_f / 0.393700787).round(3) },
          max: bb.max.to_a.map { |v| (v.to_f / 0.393700787).round(3) },
          size: [bb.width, bb.height, bb.depth].map { |v| (v.to_f / 0.393700787).round(3) }
        }
      end
      if entity.respond_to?(:transformation)
        o = entity.transformation.origin
        data[:position_cm] = o.to_a.map { |v| (v.to_f / 0.393700787).round(3) }
      end
      if entity.respond_to?(:material) && entity.material
        data[:material] = { name: entity.material.display_name, color: entity.material.color.to_a }
      end
      if entity.is_a?(Sketchup::ComponentInstance)
        data[:definition] = entity.definition.name
      elsif entity.is_a?(Sketchup::Group)
        data[:group_name] = entity.name
      end
      { success: true, result: data }
    end

    # snapshot({ "width": 1600, "height": 1000, "camera": {...optional...}, "antialias": true })
    # Renders the current view to a temp PNG and returns the absolute path
    # plus width/height. Base64 encoding skipped by default (large payload).
    def snapshot(params)
      params ||= {}
      width  = (params["width"]  || 1600).to_i
      height = (params["height"] || 1000).to_i
      antialias = params["antialias"] != false
      compression = (params["compression"] || 0.9).to_f
      path = params["path"] || File.join(Dir.tmpdir, "sketchup_mcp_snapshot_#{Time.now.to_i}.png")

      model = Sketchup.active_model
      view = model.active_view

      if params["camera"]
        cam_p = params["camera"]
        # Camera coordinates are centimetres, matching measure and the rest of
        # the tool boundary. Geom::Point3d takes inches, so convert. Previously
        # these were passed straight through as inches, which silently placed
        # the camera ~2.5x too close -- often inside the model, producing a
        # render of the inside of a wall with no indication anything was wrong.
        # Pass units: "in" to supply SketchUp internal units instead.
        to_inches = (cam_p["units"].to_s.downcase == "in") ? 1.0 : (1.0 / 2.54)
        eye    = point_from(cam_p["eye"], to_inches)    if cam_p["eye"]
        target = point_from(cam_p["target"], to_inches) if cam_p["target"]
        up_v   = Geom::Vector3d.new(*cam_p["up"])    if cam_p["up"]
        persp  = cam_p.fetch("perspective", true)
        fov    = cam_p["fov"] || 50.0
        if eye && target && up_v
          view.camera = Sketchup::Camera.new(eye, target, up_v, persp, fov)
        end
      end

      view.write_image(path, width, height, antialias, compression)
      { success: true, result: { path: path, width: width, height: height } }
    end

    # list_definitions({ "name_match": "Sofa", "include_bounds": true })
    def list_definitions(params)
      params ||= {}
      model = Sketchup.active_model
      raise "No active model" unless model
      match = params["name_match"]
      include_bounds = params["include_bounds"] != false

      results = model.definitions.map do |d|
        entry = {
          name: d.name,
          guid: (d.guid rescue nil),
          instance_count: d.count_instances,
          is_component: d.is_a?(Sketchup::ComponentDefinition)
        }
        if include_bounds
          bb = d.bounds
          entry[:bounds_cm] = {
            size: [bb.width, bb.height, bb.depth].map { |v| (v.to_f / 0.393700787).round(3) }
          }
        end
        entry
      end

      if match && !match.empty?
        rx = Regexp.new(match, Regexp::IGNORECASE)
        # Regexp#match? is Ruby 2.4+; SketchUp 2017 runs 2.2.4. =~ is equivalent
        # here -- only truthiness is used -- and works on every version.
        results = results.select { |e| rx =~ e[:name].to_s }
      end

      { success: true, result: { count: results.size, definitions: results } }
    end

    # list_instances({ "definition_name": "Single Sofa", "limit": 200,
    #                  "bounds": { "min": [x,y,z], "max": [x,y,z] } })
    def list_instances(params)
      params ||= {}
      model = Sketchup.active_model
      raise "No active model" unless model
      want_def = params["definition_name"]
      limit = (params["limit"] || 500).to_i
      bb_filter = params["bounds"]

      collected = []
      walker = lambda do |ents|
        ents.each do |e|
          break if collected.size >= limit
          case e
          when Sketchup::ComponentInstance
            if !want_def || e.definition.name == want_def
              bb = e.bounds
              if pass_bb_filter?(bb, bb_filter)
                collected << {
                  id: e.entityID,
                  definition: e.definition.name,
                  position_cm: e.transformation.origin.to_a.map { |v| (v.to_f / 0.393700787).round(3) },
                  bounds_min_cm: bb.min.to_a.map { |v| (v.to_f / 0.393700787).round(3) },
                  bounds_max_cm: bb.max.to_a.map { |v| (v.to_f / 0.393700787).round(3) }
                }
              end
            end
          when Sketchup::Group
            if !want_def || e.name == want_def
              bb = e.bounds
              if pass_bb_filter?(bb, bb_filter)
                collected << {
                  id: e.entityID,
                  group_name: e.name,
                  bounds_min_cm: bb.min.to_a.map { |v| (v.to_f / 0.393700787).round(3) },
                  bounds_max_cm: bb.max.to_a.map { |v| (v.to_f / 0.393700787).round(3) }
                }
              end
            end
          end
        end
      end
      walker.call(model.entities)

      { success: true, result: { count: collected.size, instances: collected, truncated: collected.size >= limit } }
    end

    def pass_bb_filter?(bb, filter)
      return true unless filter
      min = filter["min"]; max = filter["max"]
      return true unless min && max
      !(bb.max.x < min[0] || bb.min.x > max[0] ||
        bb.max.y < min[1] || bb.min.y > max[1] ||
        bb.max.z < min[2] || bb.min.z > max[2])
    end

    # select({ "ids": [1234, 5678] }) — replaces current selection
    def select_entities(params)
      params ||= {}
      model = Sketchup.active_model
      raise "No active model" unless model
      ids = Array(params["ids"]).map(&:to_i)
      model.selection.clear
      resolved = ids.map { |i| model.find_entity_by_id(i) }.compact
      model.selection.add(resolved)
      { success: true, result: { requested: ids.size, selected: resolved.size, missing: ids.size - resolved.size } }
    end

    # units_info — expose length unit + conversion factors so the client
    # never has to guess inches vs cm.
    def units_info(params)
      model = Sketchup.active_model
      raise "No active model" unless model
      opts = model.options["UnitsOptions"]
      names = { 0 => "inches", 1 => "feet", 2 => "mm", 3 => "cm", 4 => "m" }
      {
        success: true,
        result: {
          length_unit_code: opts["LengthUnit"],
          length_unit_name: names[opts["LengthUnit"]] || "unknown",
          inches_per_cm: 1.cm.to_f,
          cm_per_inch: (1.0 / 1.cm.to_f),
          model_title: model.title,
          model_path: model.path
        }
      }
    end

    # transaction({ "action": "start"|"commit"|"abort", "name": "...", "disable_ui": true })
    # Gives the client explicit control over undo boundaries when not using
    # the auto-wrap in eval_ruby / batch.
    def transaction(params)
      params ||= {}
      model = Sketchup.active_model
      raise "No active model" unless model
      action = (params["action"] || "start").downcase
      case action
      when "start", "begin"
        model.start_operation(params["name"] || "MCP transaction", params["disable_ui"] != false)
        { success: true, result: { action: "started" } }
      when "commit", "end"
        model.commit_operation
        { success: true, result: { action: "committed" } }
      when "abort", "rollback", "cancel"
        model.abort_operation
        { success: true, result: { action: "aborted" } }
      else
        raise "Unknown transaction action: #{action}"
      end
    end

    # ──────────────────────────────────────────────────────────────────

    def eval_ruby(params)
      code = params["code"].to_s
      timeout_s = (params["timeout"] || @eval_timeout).to_i
      wrap_undo = params["wrap_undo"] != false  # default true

      # Sketchup.undo exists, but calling it from here does not do what people
      # expect: eval_ruby wraps submitted code in start_operation/commit_operation
      # by default, so an undo issued mid-operation has nothing to act on and
      # returns without changing the model. Reported as "succeeded and changed
      # nothing", which is the worst outcome when someone is recovering from a
      # bad edit. Redirect to the tools that own undo.
      if wrap_undo && code =~ /\bSketchup\s*\.\s*undo\b/
        raise "Sketchup.undo does nothing here: eval_ruby runs inside an open " \
              "operation, so there is nothing for it to undo. Use the undo_last " \
              "tool instead, or transaction(action: \"abort\") to roll back an " \
              "operation you opened yourself. Pass wrap_undo: false if you " \
              "genuinely need to drive undo from inside eval_ruby."
      end
      undo_name = params["undo_name"] || "MCP eval_ruby"

      debug "Evaluating Ruby code (#{code.bytesize} bytes, timeout=#{timeout_s}s, wrap_undo=#{wrap_undo})"

      begin
        # Evaluate inside a throwaway module so each call gets its own constant
        # namespace. Previously this used TOPLEVEL_BINDING.dup, and constants
        # leaked between calls -- "warning: already initialized constant E".
        #
        # module_eval is what does the work, not the binding: constant
        # assignment follows lexical scope, so eval(code, some_binding) still
        # defines constants on Object no matter which binding is passed.
        # Top-level constants (Sketchup, Geom, Math) still resolve normally.
        eval_scope = Module.new
        # Without this, `def helper; end` defines an instance method on the
        # module and calling helper(...) raises NoMethodError, because self is
        # the module itself. extend self puts the module in its own singleton
        # ancestry, so methods defined here are callable here. Constants stay
        # isolated -- verified both properties.
        eval_scope.extend(eval_scope)
        raw_result = nil

        # Capture anything the code prints. puts inside eval_ruby went to
        # SketchUp's Ruby Console and never came back over MCP, so the obvious
        # debugging reflex printed into a void.
        captured = StringIO.new
        runner = lambda do
          previous_stdout = $stdout
          begin
            $stdout = captured
            raw_result = eval_scope.module_eval(code, "(mcp eval_ruby)", 1)
          ensure
            $stdout = previous_stdout
          end
        end

        Timeout::timeout(timeout_s, Timeout::Error) do
          if wrap_undo && Sketchup.active_model
            Sketchup.active_model.start_operation(undo_name, true)
            begin
              runner.call
              Sketchup.active_model.commit_operation
            rescue StandardError
              Sketchup.active_model.abort_operation rescue nil
              raise
            end
          else
            runner.call
          end
        end

        debug "Code evaluation completed"

        # Structured result. JSON.generate refuses a bare scalar at the top
        # level, so String, boolean and numeric results -- Sketchup.version,
        # Sketchup.is_pro?, entity counts -- all came back as value: nil even
        # though they serialise perfectly well. Wrapping in an array proves
        # serialisability without that restriction.
        value_ok = begin
          JSON.generate([raw_result])
          true
        rescue StandardError
          false
        end

        {
          success: true,
          result: {
            # The value itself, not a pre-encoded string: the response is
            # serialised as a whole, so callers get a typed result rather than
            # JSON they have to parse a second time.
            value:   value_ok ? raw_result : nil,
            stdout:  (captured.string[0, 10_000] rescue nil),
            inspect: (raw_result.inspect[0, 10_000] rescue raw_result.to_s[0, 10_000]),
            class:   raw_result.class.name
          }
        }
      rescue Timeout::Error
        warn "eval_ruby timed out after #{timeout_s}s"
        raise "Ruby evaluation timed out after #{timeout_s}s (hint: pass {\"timeout\": N} to increase)"
      rescue StandardError => e
        error "eval_ruby error: #{e.class}: #{e.message}"
        debug e.backtrace.first(10).join("\n")

        # Keep the class and the line number. Flattening everything to
        # "divided by 0" leaves no way to locate the fault in a 40-line script
        # except by bisecting it. Frames from the submitted code are tagged
        # "(mcp eval_ruby)" by module_eval, so they can be picked out from the
        # extension's own frames.
        user_frames = (e.backtrace || []).select { |f| f.include?("(mcp eval_ruby)") }
        location = user_frames.first ? " at #{user_frames.first.sub('(mcp eval_ruby):', 'line ')}" : ""

        raise "#{e.class}: #{e.message}#{location}"
      end
    end
  end

  unless file_loaded?(__FILE__)
    @server = Server.new
    
    menu = UI.menu("Plugins").add_submenu("MCP Server")
    menu.add_item("Start Server") { @server.start }
    menu.add_item("Stop Server") { @server.stop }
    
    file_loaded(__FILE__)
  end
end 