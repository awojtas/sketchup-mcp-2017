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

## The world/local coordinate split (v2.9.0)

`measure` reports bounds in **world** space. `cut_pocket` took its profile in
centimetres, converted straight to inches, and added the face to the group's
**local** entities. Those two spaces coincide only while a group sits
untransformed, which is why this went unnoticed: a freshly created component
has an identity transform, so the obvious test passes.

Move the component first — which `transform_component` now does correctly —
and a profile copied from `measure` lands somewhere else entirely. Verified on
2017: a 10 cm cube moved to x=20, given a profile on its top face in the
coordinates `measure` had just reported, gained 108 cm³ instead of losing it.
The profile missed the solid, so push/pull extruded a detached slab. Only
`cut_pocket`'s volume post-condition caught it.

Profiles are now converted world → local against the target's transformation.
For an untransformed group that is a no-op, so nothing that already worked
changes.

## The joinery rebuild (v2.9.0)

`create_mortise_tenon`, `create_dovetail` and `create_finger_joint` were
disabled in v2.6.0 after live testing found all three destroyed the board they
were given. They read each board's **world** bounds, then added faces to the
board's **local** entities — the same defect as above, but unguarded, so the
damage was committed.

They are rebuilt on the gesture `cut_pocket` already got right: a flat profile
pushed into a face. Every one of these joints is prismatic, so none of them
needs SketchUp Pro.

Three things changed in the design, each addressing a way the originals went
wrong:

- **Geometry comes from the overlap, not from parameters.** The caller
  positions the two boards so their ends overlap; that intersection *is* the
  joint. The axis the boards meet along is taken from the separation of their
  centres, and an ambiguous separation is an error rather than a guess. This
  replaces the old abstract `width`/`height`/`depth` plus three offsets, which
  the caller had to reconcile with the boards' real orientation by hand.
- **Boards are addressed by role, not position.** The socket goes into the
  board passed as `mortise_id` whichever side of the joint it sits on. Binding
  cuts to "the board that happens to be lower" is how an operation ends up
  consuming the solid it meant to keep.
- **A joint is one operation.** Each joint is several coordinated cuts, and a
  half-cut joint is worse than none, so all of them run inside a single
  abortable operation.

### The post-condition

The check that makes this trustworthy is a volume identity. After any of these
joints the two boards must between them fill the overlap exactly once:

```
volume(a) + volume(b) == before(a) + before(b) - volume(overlap)
```

One identity catches material added instead of removed, cuts placed on the
wrong board, cuts that missed the overlap, gaps, and the two halves
interpenetrating. It is checked before the operation is committed, so a joint
that fails leaves the model untouched.

It was tested by deliberately breaking joints — planning no cuts at all, and
removing the same finger from both boards — and confirming both were rejected
and rolled back with the boards at their original volumes.

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
