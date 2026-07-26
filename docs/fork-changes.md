# What this fork changes

Upstream is [mhyrr/sketchup-mcp](https://github.com/mhyrr/sketchup-mcp). This fork ships releases, fixes the UI freeze, and keeps the extension working on SketchUp Make 2017.

Per-change detail lives in the git history and the linked PRs; this is the shape of it.

## The UI freeze

The headline reason the fork exists. Upstream's extension froze SketchUp whenever an agent connected, recovering only when the agent exited.

SketchUp runs Ruby on its main UI thread. Upstream accepted a connection then called `client.gets`, which blocks until a newline arrives — and the Python client connects at startup, then sends nothing until a tool is invoked. So the UI thread sat parked inside `gets`.

The loop is now non-blocking: each timer tick takes whatever bytes are available and returns. Partial requests accumulate across ticks, and connections stay open between requests. Threads aren't an option — the SketchUp API isn't thread-safe, and Ruby threads aren't scheduled while the main thread blocks.

Two people hit this independently and opened upstream PRs ([#7](https://github.com/mhyrr/sketchup-mcp/pull/7), [#22](https://github.com/mhyrr/sketchup-mcp/pull/22)); both remain unmerged. Both *bounded* the blocking read rather than removing it, which still stalls the UI every tick and discards any request that doesn't arrive whole within the budget.

## Ruby 2.2 compatibility

SketchUp 2017 embeds Ruby 2.2.4, where anything newer is a hard runtime error rather than a warning. Importing upstream [PR #17](https://github.com/mhyrr/sketchup-mcp/pull/17) brought three defects that had never been run against 2017: `String#match?` (2.4+), `String.new(encoding:)` (2.3+), and later `Hash#compact` (2.4+). Each broke every tool call in the field.

Two guards now catch these: `scripts/check_ruby22_compat.py` scans statically, and `tests/test_socket_loop.rb` undefines the offending methods so the suite fails at runtime on paths the tests actually drive. The static scan alone missed `Hash#compact`.

## World versus local coordinates

`measure` reports **world** bounds; group geometry lives in the group's **own** space. Those coincide only while a group sits untransformed, so the bug hid behind every freshly created component.

`cut_pocket` converted its profile straight to inches and added the face to the group's local entities. Move the component first and a profile copied from `measure` lands somewhere else — verified on 2017, a cube moved to x=20 *gained* 108 cm³ instead of losing it, because the profile missed the solid and push/pull extruded a detached slab. Profiles are now converted world → local, which is a no-op for an untransformed group.

The same defect is what disabled the three joinery tools in v2.6.0: they read world bounds, cut in local space, and committed the damage. They are rebuilt on `cut_pocket`'s gesture — a flat profile pushed into a face, which needs no Pro — with geometry derived from the boards' overlap, boards addressed by role rather than position, and all of a joint's cuts in one abortable operation.

What makes that trustworthy is a post-condition rather than a return value: after a joint the two boards must between them fill their overlap exactly once.

```
volume(a) + volume(b) == before(a) + before(b) - volume(overlap)
```

That one identity catches material added instead of removed, cuts on the wrong board, cuts that missed, gaps, and the halves interpenetrating. `scripts/verify_joinery.py` checks it against a running SketchUp.

## Other fixes

- **Empty Ruby Console on every launch** — the console was forced open at load, before anything had logged.
- **Endless console error spam** — `Errno::ECONNABORTED`, which is what Windows raises when a connection drops, wasn't handled, so the dead socket was retried and re-logged every tick.
- **Silent console, then no sign a client connected** — PR #17's logger only wrote at `WARN` and above, and connect/disconnect sat at `DEBUG`. Both are the confirmation users look for.
- **Ctrl+C printed a wall of traceback** — `main()` had no `KeyboardInterrupt` handler.
- **Malformed input wedged the connection** — "invalid" and "incomplete" were reported identically, so one bad byte blocked every later request. Now returns `-32700` and resets.
- **`Dir.tmpdir` without `require 'tmpdir'`** — masked on Windows by `ENV['TEMP']`; would raise on macOS.
- **Export guards that tested nothing** — `if Sketchup.require("sketchup.rb")` is unconditionally truthy, so a missing exporter failed opaquely.
- **The stale PyPI package** — upstream's README recommends `uvx sketchup-mcp`, but the published `0.1.17` predates upstream's own FastMCP fix and raises `TypeError` against current `mcp` versions. This fork installs from git.

## Release tooling

`scripts/build_rbz.py` builds the `.rbz` with only the Python standard library. Upstream's `package.rb` needs the `rubyzip` gem, which is why [issue #10](https://github.com/mhyrr/sketchup-mcp/issues/10) ("cannot find the .rbz files") went unanswered.

Releases are tag-driven, and the tag is the only place a version is written. File contents are deterministic for a given source and version; the compressed archive bytes are not, since zlib output differs between Python versions — so compare contents, not archive hashes.
