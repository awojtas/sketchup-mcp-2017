# SketchUp Make 2017 compatibility

SketchUp Make 2017 is the last free desktop release of SketchUp, and it remains widely used by hobbyists who won't pay for a subscription. This fork targets it explicitly.

**Status: verified against a real SketchUp Make 2017 install** (`Sketchup.version` → `17.2.2555`, Windows). The findings below are observed behaviour from that machine, not inference. Where something is still unconfirmed, it says so.

Ruby 2.2 compatibility is additionally enforced on every release by `scripts/check_ruby22_compat.py`, which fails the build if post-2.2 syntax appears in the extension. It's a heuristic scanner, not a Ruby 2.2 parser — no Ruby 2.2 build exists for modern CI images — so it catches the constructs people actually reach for, not every conceivable incompatibility.

## What Make 2017 constrains

| Constraint | Detail |
|---|---|
| Ruby version | 2.2.4 (SketchUp 2016 and earlier were 2.0.0; 2021+ moved to 2.7) |
| Extension loading | The Extension Manager has a loading policy that can restrict unsigned extensions |
| Platform | Windows and macOS only — no Linux build, so CI cannot run a real integration test |

## Confirmed working

| Behaviour | Evidence |
|---|---|
| Installs unsigned via Extension Manager | No loading-policy change needed on the test machine |
| Loads and registers its menu | `Extensions > MCP Server > Start Server` |
| TCP listener starts | `Server created on port 9876` |
| MCP client connects | `Client connected`, `ping` round-trips |
| `eval_ruby` | `Sketchup.version` returned `"17.2.2555"` |
| `create_component` | Cube created, entity id returned |
| `get_selection` | Returned an empty selection without error |
| `export` → `obj` | **Succeeded** — see below; this was not expected |

## Corrections to earlier assumptions

Two claims previously stated here, based on reading the source rather than running it, turned out to be wrong. Recorded because they shaped the code.

### `Sketchup.is_pro?` returns **true** on Make 2017

This was assumed `false` on Make — the obvious reading of the name, and what the Pro/Make exporter split implies. On the test machine it returns `true`.

A gate of the form `raise unless Sketchup.is_pro?` therefore does **not** reliably detect Make, and any such gate should be treated as unsound. One was added to `export_scene` for OBJ and has since been removed.

### OBJ export **works** on Make 2017

The widely-repeated claim is that OBJ is a Pro-only exporter absent from Make. On the test machine, `export` with `format: "obj"` completed and wrote a file:

```
MCP: Exporting to OBJ file: C:\Users\aidan\AppData\Local\Temp/sketchup_exports/sketchup_export_...obj
MCP: Export completed successfully to: ...
```

Whether that's because this install reports itself as Pro, or because Make 2017 genuinely ships the OBJ exporter, isn't yet distinguished. Either way, refusing OBJ up front was wrong, and that check has been removed. If an exporter genuinely is missing, the export call itself reports it.

## Open questions

### STL export does not complete

`export` with `format: "stl"` logged its start line and then the connection dropped, with no success or failure recorded:

```
MCP: Exporting to STL file: ...sketchup_export_...stl
MCP: Client disconnected
```

The likeliest reading is that `model.export` for STL blocked long enough for the client to time out. `model.export` runs on the UI thread, so a hang there stalls SketchUp itself — the same class of problem as the socket bug fixed in v1.7.0, but inside SketchUp's own exporter where we can't fix it.

Needs a repeat run with the console watched: does SketchUp recover, and does a file appear on disk afterwards? STL wasn't built into every SketchUp of that era — it came from a separately installed extension — so "no exporter registered" remains plausible.

## Fixed along the way

Bugs found and fixed while getting this working on 2017.

- **SketchUp froze whenever an MCP client connected** (v1.7.0). The socket loop called `client.gets` on SketchUp's UI thread; the Python client connects at startup and stays silent until a tool is invoked, so the UI blocked indefinitely. Now fully non-blocking.
- **Endless error spam in the Ruby Console** (v1.7.1). `Errno::ECONNABORTED` — what Windows raises when a connection drops — wasn't handled, so the dead socket was retried and re-logged on every tick.
- **Empty Ruby Console on every launch** (v1.7.0). The console was forced open at load, before anything had logged. It now appears when the server starts.
- **`Dir.tmpdir` without `require 'tmpdir'`.** Masked on Windows by `ENV['TEMP']`; would raise on macOS.
- **Export guards that tested nothing.** `if Sketchup.require("sketchup.rb")` is unconditionally truthy.
- **`String#match?` (Ruby 2.4) and `String.new(encoding:)` (Ruby 2.3)** — both imported with upstream PR #17, both fatal on 2017, both caught by the compatibility checker.
- **Malformed input wedged the connection.** Also from PR #17: invalid JSON and incomplete JSON were reported identically, so one bad byte sat at the head of the buffer and blocked every subsequent request until the size cap tripped.

## Verification checklist

Still to confirm on a real install:

1. STL export — completes, hangs, or errors? Does SketchUp recover?
2. `export` for `dae` and `png`.
3. `transform_component`, `set_material`, `delete_component`.
4. `eval_ruby` raising an error — does it propagate cleanly rather than killing the connection?
5. The v2.0.0 tools: `batch`, `snapshot`, `measure`, `select`, `list_definitions`, `list_instances`, `units_info`, `undo_last`, `transaction`.
6. macOS Make 2017 — untried. The `tmpdir` fix is macOS-specific and unexercised.
