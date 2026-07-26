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

    # The three joinery tools are disabled.
    #
    # Live testing on 2.6.0 found all three destroy the board they are given:
    # a clean 800 cm3 manifold board comes back at -1 cubic inch (SketchUp's
    # "not a solid" sentinel) and manifold? == false. They do not cut -- they
    # displace, shear, or add material outside the workpiece -- and because
    # nothing wraps them in an abortable operation, the damage is committed.
    #
    # The push/pull rewrite that was meant to remove their SketchUp Pro
    # dependency introduced this, and it shipped without live verification.
    # Refusing is the only responsible state until they are rebuilt on
    # cut_pocket, which already does correctly the thing all three get wrong.
    def joinery_disabled!(name)
      raise "#{name} is disabled: it corrupts the workpiece rather than " \
            "cutting it, and commits the damage. Use cut_pocket to remove " \
            "material, or cut the joint interactively in SketchUp. " \
            "Tracking: the tool needs rebuilding on cut_pocket's " \
            "face-normal and post-condition logic."
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

      # Caller works in centimetres; SketchUp geometry is inches.
      pts = points.map { |p| Geom::Point3d.new(p[0].to_f / 2.54, p[1].to_f / 2.54, p[2].to_f / 2.54) }

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
    
    def create_mortise_tenon(params)
      joinery_disabled!("create_mortise_tenon")

      log "Creating mortise and tenon joint with params: #{params.inspect}"
      model = Sketchup.active_model
      
      # Get the mortise and tenon board IDs
      mortise_id = params["mortise_id"].to_s.gsub('"', '')
      tenon_id = params["tenon_id"].to_s.gsub('"', '')
      
      log "Looking for mortise board with ID: #{mortise_id}"
      mortise_board = model.find_entity_by_id(mortise_id.to_i)
      
      log "Looking for tenon board with ID: #{tenon_id}"
      tenon_board = model.find_entity_by_id(tenon_id.to_i)
      
      unless mortise_board && tenon_board
        missing = []
        missing << "mortise board" unless mortise_board
        missing << "tenon board" unless tenon_board
        raise "Entity not found: #{missing.join(', ')}"
      end
      
      # Ensure both entities are groups or component instances
      unless (mortise_board.is_a?(Sketchup::Group) || mortise_board.is_a?(Sketchup::ComponentInstance)) &&
             (tenon_board.is_a?(Sketchup::Group) || tenon_board.is_a?(Sketchup::ComponentInstance))
        raise "Mortise and tenon operation requires groups or component instances"
      end
      
      # Get joint parameters
      width = params["width"] || 1.0
      height = params["height"] || 1.0
      depth = params["depth"] || 1.0
      offset_x = params["offset_x"] || 0.0
      offset_y = params["offset_y"] || 0.0
      offset_z = params["offset_z"] || 0.0
      
      # Get the bounds of both boards
      mortise_bounds = mortise_board.bounds
      tenon_bounds = tenon_board.bounds
      
      # Determine the face to place the joint on based on the relative positions of the boards
      mortise_center = mortise_bounds.center
      tenon_center = tenon_bounds.center
      
      # Calculate the direction vector from mortise to tenon
      direction_vector = tenon_center - mortise_center
      
      # Determine which face of the mortise board is closest to the tenon board
      mortise_face_direction = determine_closest_face(direction_vector)
      
      # Create the mortise (hole) in the mortise board
      mortise_result = create_mortise(
        mortise_board, 
        width, 
        height, 
        depth, 
        mortise_face_direction,
        mortise_bounds,
        offset_x, 
        offset_y, 
        offset_z
      )
      
      # Determine which face of the tenon board is closest to the mortise board
      tenon_face_direction = determine_closest_face(direction_vector.reverse)
      
      # Create the tenon (projection) on the tenon board
      tenon_result = create_tenon(
        tenon_board, 
        width, 
        height, 
        depth, 
        tenon_face_direction,
        tenon_bounds,
        offset_x, 
        offset_y, 
        offset_z
      )
      
      # Return the result
      { 
        success: true, 
        mortise_id: mortise_result[:id],
        tenon_id: tenon_result[:id]
      }
    end
    
    def determine_closest_face(direction_vector)
      # Normalize the direction vector
      direction_vector.normalize!
      
      # Determine which axis has the largest component
      x_abs = direction_vector.x.abs
      y_abs = direction_vector.y.abs
      z_abs = direction_vector.z.abs
      
      if x_abs >= y_abs && x_abs >= z_abs
        # X-axis is dominant
        return direction_vector.x > 0 ? :east : :west
      elsif y_abs >= x_abs && y_abs >= z_abs
        # Y-axis is dominant
        return direction_vector.y > 0 ? :north : :south
      else
        # Z-axis is dominant
        return direction_vector.z > 0 ? :top : :bottom
      end
    end
    
    def create_mortise(board, width, height, depth, face_direction, bounds, offset_x, offset_y, offset_z)
      model = Sketchup.active_model
      
      # Get the board's entities
      entities = board.is_a?(Sketchup::Group) ? board.entities : board.definition.entities
      
      # Calculate the position of the mortise based on the face direction
      mortise_position = calculate_position_on_face(face_direction, bounds, width, height, depth, offset_x, offset_y, offset_z)
      
      log "Creating mortise at position: #{mortise_position.inspect} with dimensions: #{[width, height, depth].inspect}"
      
      # Draw the mortise profile directly on the board and push it inward --
      # the same gesture a person uses, and it works on every SketchUp edition.
      # The previous approach built a separate box and subtracted it, which
      # needs the Pro-only solid tools for a cut that does not require them.
      mortise_group = nil
      
      # Create the mortise box with the correct orientation
      case face_direction
      when :east, :west
        # Mortise on east or west face (YZ plane)
        mortise_face = entities.add_face(
          [mortise_position[0], mortise_position[1], mortise_position[2]],
          [mortise_position[0], mortise_position[1] + width, mortise_position[2]],
          [mortise_position[0], mortise_position[1] + width, mortise_position[2] + height],
          [mortise_position[0], mortise_position[1], mortise_position[2] + height]
        )
        pushpull_into(mortise_face, entities, depth)
      when :north, :south
        # Mortise on north or south face (XZ plane)
        mortise_face = entities.add_face(
          [mortise_position[0], mortise_position[1], mortise_position[2]],
          [mortise_position[0] + width, mortise_position[1], mortise_position[2]],
          [mortise_position[0] + width, mortise_position[1], mortise_position[2] + height],
          [mortise_position[0], mortise_position[1], mortise_position[2] + height]
        )
        pushpull_into(mortise_face, entities, depth)
      when :top, :bottom
        # Mortise on top or bottom face (XY plane)
        mortise_face = entities.add_face(
          [mortise_position[0], mortise_position[1], mortise_position[2]],
          [mortise_position[0] + width, mortise_position[1], mortise_position[2]],
          [mortise_position[0] + width, mortise_position[1] + height, mortise_position[2]],
          [mortise_position[0], mortise_position[1] + height, mortise_position[2]]
        )
        pushpull_into(mortise_face, entities, depth)
      end
      
      # Nothing to subtract: pushing the profile inward removed the material.
      
      # Clean up the temporary group
      mortise_group.erase!
      
      # Return the result
      { 
        success: true, 
        id: board.entityID
      }
    end
    
    def create_tenon(board, width, height, depth, face_direction, bounds, offset_x, offset_y, offset_z)
      model = Sketchup.active_model
      
      # Get the board's entities
      entities = board.is_a?(Sketchup::Group) ? board.entities : board.definition.entities
      
      # Calculate the position of the tenon based on the face direction
      tenon_position = calculate_position_on_face(face_direction, bounds, width, height, depth, offset_x, offset_y, offset_z)
      
      log "Creating tenon at position: #{tenon_position.inspect} with dimensions: #{[width, height, depth].inspect}"
      
      # Create a box for the tenon
      tenon_group = model.active_entities.add_group
      
      # Create the tenon box with the correct orientation
      case face_direction
      when :east, :west
        # Tenon on east or west face (YZ plane)
        tenon_face = tenon_group.entities.add_face(
          [tenon_position[0], tenon_position[1], tenon_position[2]],
          [tenon_position[0], tenon_position[1] + width, tenon_position[2]],
          [tenon_position[0], tenon_position[1] + width, tenon_position[2] + height],
          [tenon_position[0], tenon_position[1], tenon_position[2] + height]
        )
        tenon_face.pushpull(face_direction == :east ? depth : -depth)
      when :north, :south
        # Tenon on north or south face (XZ plane)
        tenon_face = tenon_group.entities.add_face(
          [tenon_position[0], tenon_position[1], tenon_position[2]],
          [tenon_position[0] + width, tenon_position[1], tenon_position[2]],
          [tenon_position[0] + width, tenon_position[1], tenon_position[2] + height],
          [tenon_position[0], tenon_position[1], tenon_position[2] + height]
        )
        tenon_face.pushpull(face_direction == :north ? depth : -depth)
      when :top, :bottom
        # Tenon on top or bottom face (XY plane)
        tenon_face = tenon_group.entities.add_face(
          [tenon_position[0], tenon_position[1], tenon_position[2]],
          [tenon_position[0] + width, tenon_position[1], tenon_position[2]],
          [tenon_position[0] + width, tenon_position[1] + height, tenon_position[2]],
          [tenon_position[0], tenon_position[1] + height, tenon_position[2]]
        )
        tenon_face.pushpull(face_direction == :top ? depth : -depth)
      end
      
      # Get the transformation of the board
      board_transform = board.transformation
      
      # Apply the inverse transformation to the tenon group
      tenon_group.transform!(board_transform.inverse)
      
      # Union the tenon with the board
      board_entities = board.is_a?(Sketchup::Group) ? board.entities : board.definition.entities
      board_entities.add_instance(tenon_group.entities.parent, Geom::Transformation.new)
      
      # Clean up the temporary group
      tenon_group.erase!
      
      # Return the result
      { 
        success: true, 
        id: board.entityID
      }
    end
    
    def calculate_position_on_face(face_direction, bounds, width, height, depth, offset_x, offset_y, offset_z)
      # Calculate the position on the specified face with offsets
      case face_direction
      when :east
        # Position on the east face (max X)
        [
          bounds.max.x,
          bounds.center.y - width/2 + offset_y,
          bounds.center.z - height/2 + offset_z
        ]
      when :west
        # Position on the west face (min X)
        [
          bounds.min.x,
          bounds.center.y - width/2 + offset_y,
          bounds.center.z - height/2 + offset_z
        ]
      when :north
        # Position on the north face (max Y)
        [
          bounds.center.x - width/2 + offset_x,
          bounds.max.y,
          bounds.center.z - height/2 + offset_z
        ]
      when :south
        # Position on the south face (min Y)
        [
          bounds.center.x - width/2 + offset_x,
          bounds.min.y,
          bounds.center.z - height/2 + offset_z
        ]
      when :top
        # Position on the top face (max Z)
        [
          bounds.center.x - width/2 + offset_x,
          bounds.center.y - height/2 + offset_y,
          bounds.max.z
        ]
      when :bottom
        # Position on the bottom face (min Z)
        [
          bounds.center.x - width/2 + offset_x,
          bounds.center.y - height/2 + offset_y,
          bounds.min.z
        ]
      end
    end
    
    def create_dovetail(params)
      joinery_disabled!("create_dovetail")

      log "Creating dovetail joint with params: #{params.inspect}"
      model = Sketchup.active_model
      
      # Get the tail and pin board IDs
      tail_id = params["tail_id"].to_s.gsub('"', '')
      pin_id = params["pin_id"].to_s.gsub('"', '')
      
      log "Looking for tail board with ID: #{tail_id}"
      tail_board = model.find_entity_by_id(tail_id.to_i)
      
      log "Looking for pin board with ID: #{pin_id}"
      pin_board = model.find_entity_by_id(pin_id.to_i)
      
      unless tail_board && pin_board
        missing = []
        missing << "tail board" unless tail_board
        missing << "pin board" unless pin_board
        raise "Entity not found: #{missing.join(', ')}"
      end
      
      # Ensure both entities are groups or component instances
      unless (tail_board.is_a?(Sketchup::Group) || tail_board.is_a?(Sketchup::ComponentInstance)) &&
             (pin_board.is_a?(Sketchup::Group) || pin_board.is_a?(Sketchup::ComponentInstance))
        raise "Dovetail operation requires groups or component instances"
      end
      
      # Get joint parameters
      width = params["width"] || 1.0
      height = params["height"] || 2.0
      depth = params["depth"] || 1.0
      angle = params["angle"] || 15.0  # Dovetail angle in degrees
      num_tails = params["num_tails"] || 3
      offset_x = params["offset_x"] || 0.0
      offset_y = params["offset_y"] || 0.0
      offset_z = params["offset_z"] || 0.0
      
      # Create the tails on the tail board
      tail_result = create_tails(tail_board, width, height, depth, angle, num_tails, offset_x, offset_y, offset_z)
      
      # Create the pins on the pin board
      pin_result = create_pins(pin_board, width, height, depth, angle, num_tails, offset_x, offset_y, offset_z)
      
      # Return the result
      { 
        success: true, 
        tail_id: tail_result[:id],
        pin_id: pin_result[:id]
      }
    end
    
    def create_tails(board, width, height, depth, angle, num_tails, offset_x, offset_y, offset_z)
      model = Sketchup.active_model
      
      # Get the board's entities
      entities = board.is_a?(Sketchup::Group) ? board.entities : board.definition.entities
      
      # Get the board's bounds
      bounds = board.bounds
      
      # Calculate the position of the dovetail joint
      center_x = bounds.center.x + offset_x
      center_y = bounds.center.y + offset_y
      center_z = bounds.center.z + offset_z
      
      # Calculate the width of each tail and space
      total_width = width
      tail_width = total_width / (2 * num_tails - 1)
      
      # Create a group for the tails
      tails_group = entities.add_group
      
      # Create each tail
      num_tails.times do |i|
        # Calculate the position of this tail
        tail_center_x = center_x - width/2 + tail_width * (2 * i)
        
        # Calculate the dovetail shape
        angle_rad = angle * Math::PI / 180.0
        tail_top_width = tail_width
        tail_bottom_width = tail_width + 2 * depth * Math.tan(angle_rad)
        
        # Create the tail shape
        tail_points = [
          [tail_center_x - tail_top_width/2, center_y - height/2, center_z],
          [tail_center_x + tail_top_width/2, center_y - height/2, center_z],
          [tail_center_x + tail_bottom_width/2, center_y - height/2, center_z - depth],
          [tail_center_x - tail_bottom_width/2, center_y - height/2, center_z - depth]
        ]
        
        # Create the tail face
        tail_face = tails_group.entities.add_face(tail_points)
        
        # Extrude the tail
        pushpull_into(tail_face, pins_group.entities, height)
      end
      
      # Return the result
      { 
        success: true, 
        id: board.entityID
      }
    end
    
    def create_pins(board, width, height, depth, angle, num_tails, offset_x, offset_y, offset_z)
      model = Sketchup.active_model
      
      # Get the board's entities
      entities = board.is_a?(Sketchup::Group) ? board.entities : board.definition.entities
      
      # Get the board's bounds
      bounds = board.bounds
      
      # Calculate the position of the dovetail joint
      center_x = bounds.center.x + offset_x
      center_y = bounds.center.y + offset_y
      center_z = bounds.center.z + offset_z
      
      # Calculate the width of each tail and space
      total_width = width
      tail_width = total_width / (2 * num_tails - 1)
      
      # Create a group for the pins
      pins_group = entities.add_group
      
      # Create a box for the entire pin area
      pin_area_face = pins_group.entities.add_face(
        [center_x - width/2, center_y - height/2, center_z],
        [center_x + width/2, center_y - height/2, center_z],
        [center_x + width/2, center_y + height/2, center_z],
        [center_x - width/2, center_y + height/2, center_z]
      )
      
      # Extrude the pin area
      pin_area_face.pushpull(depth)
      
      # Create each tail cutout
      num_tails.times do |i|
        # Calculate the position of this tail
        tail_center_x = center_x - width/2 + tail_width * (2 * i)
        
        # Calculate the dovetail shape
        angle_rad = angle * Math::PI / 180.0
        tail_top_width = tail_width
        tail_bottom_width = tail_width + 2 * depth * Math.tan(angle_rad)
        
        # Create a group for the tail cutout
        # Drawn straight onto the pin block and pushed through -- no solid op.
        
        # Create the tail cutout shape
        tail_points = [
          [tail_center_x - tail_top_width/2, center_y - height/2, center_z],
          [tail_center_x + tail_top_width/2, center_y - height/2, center_z],
          [tail_center_x + tail_bottom_width/2, center_y - height/2, center_z - depth],
          [tail_center_x - tail_bottom_width/2, center_y - height/2, center_z - depth]
        ]
        
        # Create the tail cutout face
        tail_face = pins_group.entities.add_face(tail_points)
        
        # Extrude the tail cutout
        pushpull_into(tail_face, pins_group.entities, height)
        
        # The push already removed the material; nothing to subtract.
      end
      
      # Return the result
      { 
        success: true, 
        id: board.entityID
      }
    end
    
    def create_finger_joint(params)
      joinery_disabled!("create_finger_joint")

      log "Creating finger joint with params: #{params.inspect}"
      model = Sketchup.active_model
      
      # Get the two board IDs
      board1_id = params["board1_id"].to_s.gsub('"', '')
      board2_id = params["board2_id"].to_s.gsub('"', '')
      
      log "Looking for board 1 with ID: #{board1_id}"
      board1 = model.find_entity_by_id(board1_id.to_i)
      
      log "Looking for board 2 with ID: #{board2_id}"
      board2 = model.find_entity_by_id(board2_id.to_i)
      
      unless board1 && board2
        missing = []
        missing << "board 1" unless board1
        missing << "board 2" unless board2
        raise "Entity not found: #{missing.join(', ')}"
      end
      
      # Ensure both entities are groups or component instances
      unless (board1.is_a?(Sketchup::Group) || board1.is_a?(Sketchup::ComponentInstance)) &&
             (board2.is_a?(Sketchup::Group) || board2.is_a?(Sketchup::ComponentInstance))
        raise "Finger joint operation requires groups or component instances"
      end
      
      # Get joint parameters
      width = params["width"] || 1.0
      height = params["height"] || 2.0
      depth = params["depth"] || 1.0
      num_fingers = params["num_fingers"] || 5
      offset_x = params["offset_x"] || 0.0
      offset_y = params["offset_y"] || 0.0
      offset_z = params["offset_z"] || 0.0
      
      # Create the fingers on board 1
      board1_result = create_board1_fingers(board1, width, height, depth, num_fingers, offset_x, offset_y, offset_z)
      
      # Create the matching slots on board 2
      board2_result = create_board2_slots(board2, width, height, depth, num_fingers, offset_x, offset_y, offset_z)
      
      # Return the result
      { 
        success: true, 
        board1_id: board1_result[:id],
        board2_id: board2_result[:id]
      }
    end
    
    def create_board1_fingers(board, width, height, depth, num_fingers, offset_x, offset_y, offset_z)
      model = Sketchup.active_model
      
      # Get the board's entities
      entities = board.is_a?(Sketchup::Group) ? board.entities : board.definition.entities
      
      # Get the board's bounds
      bounds = board.bounds
      
      # Calculate the position of the joint
      center_x = bounds.center.x + offset_x
      center_y = bounds.center.y + offset_y
      center_z = bounds.center.z + offset_z
      
      # Calculate the width of each finger
      finger_width = width / num_fingers
      
      # Create a group for the fingers
      fingers_group = entities.add_group
      
      # Create a base rectangle for the joint area
      base_face = fingers_group.entities.add_face(
        [center_x - width/2, center_y - height/2, center_z],
        [center_x + width/2, center_y - height/2, center_z],
        [center_x + width/2, center_y + height/2, center_z],
        [center_x - width/2, center_y + height/2, center_z]
      )
      
      # Create cutouts for the spaces between fingers
      (num_fingers / 2).times do |i|
        # Calculate the position of this cutout
        cutout_center_x = center_x - width/2 + finger_width * (2 * i + 1)
        
        # Create a group for the cutout
        # Drawn onto the workpiece and pushed through -- no solid op.
        
        # Create the cutout shape
        cutout_face = fingers_group.entities.add_face(
          [cutout_center_x - finger_width/2, center_y - height/2, center_z],
          [cutout_center_x + finger_width/2, center_y - height/2, center_z],
          [cutout_center_x + finger_width/2, center_y + height/2, center_z],
          [cutout_center_x - finger_width/2, center_y + height/2, center_z]
        )
        
        # Extrude the cutout
        pushpull_into(cutout_face, fingers_group.entities, depth)
        
        # The push already removed the material; nothing to subtract.
      end
      
      # Extrude the fingers
      base_face.pushpull(depth)
      
      # Return the result
      { 
        success: true, 
        id: board.entityID
      }
    end
    
    def create_board2_slots(board, width, height, depth, num_fingers, offset_x, offset_y, offset_z)
      model = Sketchup.active_model
      
      # Get the board's entities
      entities = board.is_a?(Sketchup::Group) ? board.entities : board.definition.entities
      
      # Get the board's bounds
      bounds = board.bounds
      
      # Calculate the position of the joint
      center_x = bounds.center.x + offset_x
      center_y = bounds.center.y + offset_y
      center_z = bounds.center.z + offset_z
      
      # Calculate the width of each finger
      finger_width = width / num_fingers
      
      # Create a group for the slots
      slots_group = entities.add_group
      
      # Create cutouts for the fingers from board 1
      (num_fingers / 2 + num_fingers % 2).times do |i|
        # Calculate the position of this cutout
        cutout_center_x = center_x - width/2 + finger_width * (2 * i)
        
        # Create a group for the cutout
        # Drawn onto the workpiece and pushed through -- no solid op.
        
        # Create the cutout shape
        cutout_face = entities.add_face(
          [cutout_center_x - finger_width/2, center_y - height/2, center_z],
          [cutout_center_x + finger_width/2, center_y - height/2, center_z],
          [cutout_center_x + finger_width/2, center_y + height/2, center_z],
          [cutout_center_x - finger_width/2, center_y + height/2, center_z]
        )
        
        # Extrude the cutout
        pushpull_into(cutout_face, entities, depth)
        
        # The push already removed the material; nothing to subtract.
      end
      
      # Return the result
      { 
        success: true, 
        id: board.entityID
      }
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