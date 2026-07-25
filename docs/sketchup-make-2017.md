# SketchUp Make 2017 compatibility

SketchUp Make 2017 is the last free desktop release of SketchUp, and it remains widely used by hobbyists who won't pay for a Pro subscription. This fork targets it explicitly.

**Current status: static analysis complete, live verification not yet done.** Nobody has yet installed the `.rbz` into a real Make 2017 instance and exercised the tools. The findings below come from reading the source against the known constraints of that release.

## What Make 2017 actually constrains

| Constraint | Detail |
|---|---|
| Ruby version | 2.2.4 (SketchUp 2016 and earlier were 2.0.0; 2021+ moved to 2.7) |
| Exporters | Make ships a reduced set. COLLADA (`.dae`), KMZ, and 2D image export are available. OBJ, FBX, DWG, DXF, 3DS, VRML are **Pro-only**. |
| Extension loading | The 2017 Extension Manager has a loading policy setting that defaults to restricting unidentified (unsigned) extensions. |
| Platform | Windows and macOS only. There is no Linux build, so CI cannot run a real integration test. |

## Findings

### ✅ Ruby syntax is clean

The extension source uses no syntax introduced after Ruby 2.2. Checked for and found absent: safe navigation (`&.`), squiggly heredocs (`<<~`), `Hash#dig` / `Array#dig`, `String#match?`, `Array#sum`, `Comparable#clamp`, `yield_self` / `then`, `filter_map`, pattern matching, endless method definitions, and hash-value shorthand.

### ✅ SketchUp API surface is clean

No calls to API introduced after SketchUp 2017. The extension sticks to long-stable entry points — `Sketchup.active_model`, `entities`, `definitions`, `materials`, `selection`, `model.export`, `model.save`. Nothing touches `Tags`, `LayerFolder`, `Entities#weld`, `active_path=`, `InstancePath`, or the overlays API, all of which postdate 2017.

### ✅ Dependencies are all standard library

`su_mcp/su_mcp/main.rb` requires only `sketchup`, `json`, `socket`, and `fileutils` — all present in SketchUp's bundled Ruby. No gems needed at runtime, which is essential since users install a `.rbz` rather than running `bundle install`.

### ✅ Socket binding is loopback-only

The TCP listener binds `127.0.0.1` (`main.rb:44`), not `0.0.0.0`. Given the extension exposes an `eval_ruby` command that runs arbitrary Ruby in-process, this matters a great deal — it must stay loopback.

### ❌ OBJ export will fail on Make

`main.rb:613-629` offers `obj` as an export format and calls `model.export`. The OBJ exporter is a Pro feature; on Make 2017 this raises rather than producing a file.

The guard around it doesn't help:

```ruby
if Sketchup.require("sketchup.rb")
```

`Sketchup.require` on an already-loaded file returns a truthy value regardless of whether any exporter is present, so this check always passes. It tests nothing. The same non-guard wraps the `dae` and `stl` branches.

**Fix direction:** replace the sham check with a real capability probe (attempt the export and rescue, or gate on `Sketchup.is_pro?`), and return a clear "OBJ export requires SketchUp Pro" message instead of an opaque failure.

### ⚠️ STL export is uncertain

`main.rb:643-653` offers `stl`. Whether STL export works on a stock Make 2017 depends on whether the SketchUp STL extension is present — it was distributed as a separate Extension Warehouse extension for much of that era rather than being built in. This needs checking on a real install; don't assume either way.

### ⚠️ `Dir.tmpdir` is called without requiring `tmpdir`

`main.rb:600`:

```ruby
temp_dir = File.join(ENV['TEMP'] || ENV['TMP'] || Dir.tmpdir, "sketchup_exports")
```

`tmpdir` is not among the requires at the top of the file. On Windows this is masked because `ENV['TEMP']` is set and short-circuits the expression. On macOS `TEMP` and `TMP` are typically unset, so evaluation reaches `Dir.tmpdir` and raises `NoMethodError` unless something else in the process happened to load `tmpdir` first. Adding `require 'tmpdir'` is a one-line fix.

### ⚠️ Unsigned extensions may not load

SketchUp 2017's Extension Manager defaults to a restrictive loading policy. An unsigned `.rbz` downloaded from GitHub Releases may be silently refused.

Two options: tell users to set the loading policy to Unrestricted (documented in the README), or sign the `.rbz` through the Extension Warehouse Developer Center, which is free and produces a signature SketchUp accepts by default. Signing is the better user experience if releases are meant for a general audience.

### ⚠️ No version guard exists

Nothing in the extension checks `Sketchup.version`, and `extension.json` declares no minimum. If a future change does need a newer API, there's no guard rail to catch it — it will simply break on 2017 at runtime. Worth adding a version check in the loader.

## Verification checklist for a real Make 2017 install

Nobody has run these yet. This is the list that turns "static analysis passed" into "verified".

1. Install the released `.rbz` via Window > Extension Manager; confirm it loads without changing the loading policy, and note the result either way.
2. Extensions > SketchupMCP > Start Server; confirm the Ruby Console reports the listener on 9876.
3. Connect the Python MCP server and run `get_scene_info` against an empty model.
4. `create_component`, then `get_selected_components`, `transform_component`, `set_material`, `delete_component`.
5. `eval_ruby` with a trivial expression, then something that raises, to check error propagation.
6. `export_scene` for each of `skp`, `dae`, `png` — expect success. Then `obj` and `stl` — record the actual failure mode.
7. Restart SketchUp and confirm the extension reloads cleanly.

Both Windows and macOS should be covered, since the `tmpdir` issue above is macOS-specific.
