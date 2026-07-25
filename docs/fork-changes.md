# What this fork changes

Detail behind the summary in the README. Aimed at anyone maintaining this fork or considering the same fixes upstream.

## The UI-freeze bug (v1.7.0)

The headline reason this fork exists. Upstream's extension froze SketchUp whenever an agent connected — the window greyed out and stopped responding, recovering only when the agent's process exited.

SketchUp runs Ruby on its **main UI thread**. Upstream's socket loop accepted a connection and then called `client.gets`, which blocks until a newline arrives. The Python client opens its socket as soon as the process starts and then sends nothing until a tool is invoked. So `gets` waited on data that wasn't coming, with the UI thread parked inside it.

The loop is now fully non-blocking: each timer tick takes whatever bytes are available and returns immediately. Partial requests accumulate in a buffer across ticks, and the connection stays open between requests, which is what the Python client expects — the original closed after every request and forced a reconnect.

Threads aren't an option. The SketchUp Ruby API isn't thread-safe, and Ruby threads aren't scheduled while the main thread is blocked.

### Prior art

Two people hit this independently and opened upstream PRs — [#7](https://github.com/mhyrr/sketchup-mcp/pull/7) by @Noel-Alex and [#22](https://github.com/mhyrr/sketchup-mcp/pull/22) by @gleydson115-code. Both remain unmerged. #22's root-cause write-up is excellent and matches this diagnosis exactly.

Both *bound* the blocking read with a short timeout rather than removing it, which leaves two problems: the UI thread still stalls on every tick, and the read buffer is per-tick, so a request that doesn't arrive whole within the budget is discarded and the socket closed. `tests/test_socket_loop.rb` covers that fragmentation case along with the freeze itself.

## Imported from upstream PR #17 (v2.0.0)

[mhyrr/sketchup-mcp#17](https://github.com/mhyrr/sketchup-mcp/pull/17) by @rezaakm — a reliability and capability overhaul taking the tool count from 10 to 20, plus multi-client support, typed Python exceptions, a threading lock, a request-size cap, a `Timeout` guard on `eval_ruby`, and env-var configuration.

It had never been run against SketchUp 2017 and carried three defects:

- **`String#match?`** — Ruby 2.4+, fatal on 2017's 2.2.4. Replaced with `=~`.
- **`String.new(encoding:)`** — Ruby 2.3+; in 2.2 the Hash is coerced to a String and raises `TypeError`. Two occurrences on the socket read path. Replaced with `"".force_encoding`.
- **Malformed input wedged the connection.** `try_parse_json_prefix` reported "invalid" and "incomplete" identically, so one bad byte sat at the head of the buffer and blocked every later request until the size cap tripped. Now returns `-32700` and resets.

## Other fixes

- **Empty Ruby Console on every launch** (v1.7.0) — the console was forced open at load, before anything had logged. It now appears when the server starts.
- **Endless console error spam** (v1.7.1) — `Errno::ECONNABORTED`, which is what Windows raises when a connection drops, wasn't handled, so the dead socket was retried and re-logged on every tick.
- **Silent console** (v2.0.1) — PR #17's logger only wrote to the console at `WARN` and above, so `Start Server` appeared to do nothing. Lowered to `INFO`.
- **No sign a client connected** (v2.0.2) — connect/disconnect were logged at `DEBUG`. Promoted to `INFO`; they're the confirmation users look for.
- **Ctrl+C printed ~60 lines of traceback** (v2.0.2) — `main()` had no `KeyboardInterrupt` handler, so interrupting a manually-run client unwound through anyio and asyncio.
- **`Dir.tmpdir` without `require 'tmpdir'`** — masked on Windows by `ENV['TEMP']`; would raise on macOS.
- **Export guards that tested nothing** — `if Sketchup.require("sketchup.rb")` is unconditionally truthy, so a missing exporter failed opaquely.
- **The stale PyPI package** — upstream's README recommends `uvx sketchup-mcp`, but the published `0.1.17` predates upstream's own FastMCP fix and raises `TypeError` on startup against current `mcp` versions. This fork installs from git.

## Release tooling

- `scripts/build_rbz.py` — builds the `.rbz` using only the Python standard library. Upstream's `package.rb` needs the `rubyzip` gem, which is why [issue #10](https://github.com/mhyrr/sketchup-mcp/issues/10) ("cannot find the .rbz files") went unanswered. Asserts the archive layout SketchUp requires, and that every version string matches the tag. File contents are deterministic for a given source and version; the compressed archive bytes are not, since zlib output differs between Python versions.
- `scripts/check_ruby22_compat.py` — fails the build on syntax newer than Ruby 2.2.4. Heuristic rather than a real parse, since no Ruby 2.2 build exists for modern CI images. It caught both of PR #17's incompatibilities.
- `tests/test_socket_loop.rb` — drives the real socket loop against a real socket with the SketchUp runtime stubbed. Covers the freeze, persistent connections, TCP fragmentation, malformed input, dead-socket handling, reconnect, and console output.
