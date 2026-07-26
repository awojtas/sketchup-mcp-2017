# SketchupMCP 2017 — SketchUp Model Context Protocol integration

Control SketchUp from Claude: create and modify geometry, inspect the model, apply materials, cut joinery, or run Ruby directly.

> **A fork of [mhyrr/sketchup-mcp](https://github.com/mhyrr/sketchup-mcp)** that adds:
>
> - **Downloadable releases** — install a `.rbz` from [Releases](https://github.com/awojtas/sketchup-mcp-2017/releases) rather than building it yourself
> - **A fix for the freeze** — upstream locks SketchUp up whenever an agent connects
> - **SketchUp Make 2017 support** — tested against the last free desktop version
>
> Credit for the original work to [@mhyrr](https://github.com/mhyrr), and to [Blender MCP](https://github.com/ahujasid/blender-mcp) for the structure.
> Detail on the fixes: [what this fork changes](docs/fork-changes.md).

## SketchUp Make 2017

Tested against a real Make 2017 install (`17.2.2555`).

| | |
|---|---|
| Core tools | ✅ Working |
| `.obj` export | ✅ Working — but see the Pro-trial caveat in the docs |
| `.stl` export | ❌ Refused — hangs SketchUp; use File > Export |

Releases are unsigned. If your Extension Manager refuses to load one, set its loading policy to Unrestricted.

Full breakdown: [`docs/sketchup-make-2017.md`](docs/sketchup-make-2017.md).

## How it fits together

There are two pieces, in a **server / client** relationship. Getting this straight makes setup and troubleshooting much easier.

```
   Claude Code                sketchup-mcp                 SketchUp
   Claude Desktop             (Python package)             + su_mcp extension
  ┌──────────────┐   MCP     ┌──────────────────┐   TCP   ┌──────────────────┐
  │              │  stdio    │                  │  :9876  │                  │
  │   the agent  ├──────────▶│   THE CLIENT     ├────────▶│   THE SERVER     │
  │              │           │                  │         │   (listening)    │
  └──────────────┘           └──────────────────┘         └──────────────────┘
                              started automatically        started BY YOU from
                              by the agent                 the SketchUp menu
```

**The server** is the `.rbz` you install into SketchUp. It listens on `127.0.0.1:9876` and runs commands against the open model. **You start it manually, every session**: `Extensions > MCP Server > Start Server`. Nothing starts it for you, and installing the extension isn't enough. Skip it and everything else looks correctly configured but still won't work.

**The client** is the `sketchup-mcp` Python package. Confusingly it's usually called "the MCP server", because it *is* one — to Claude. But to SketchUp it's the client. Your agent launches it automatically once registered.

Both ends use loopback, so **Claude and SketchUp must be on the same machine**. That's deliberate: `eval_ruby` executes arbitrary Ruby inside SketchUp, so binding wider would expose remote code execution to your network. Running them apart needs an SSH tunnel forwarding port 9876.

## Installation

### Prerequisite: uv

The client is launched with [uv](https://docs.astral.sh/uv/). Install it first — if it's missing, Claude reports the MCP server as `failed` with error `-32000`, which looks like a bug in this project rather than a missing command.

```powershell
winget install --id=astral-sh.uv -e                # Windows
```
```bash
brew install uv                                    # macOS
curl -LsSf https://astral.sh/uv/install.sh | sh    # Linux
```

Open a new terminal afterwards so `uv` is on `PATH`, and check with `uv --version`.

### Install the extension

1. Download the latest `.rbz` from [Releases](https://github.com/awojtas/sketchup-mcp-2017/releases)
2. In SketchUp: Window > Extension Manager > Install Extension, and select the `.rbz`
3. Restart SketchUp

On 2017 the Extension Manager may refuse an unsigned extension. If so, open Extension Manager > Settings (gear icon), set the loading policy to **Unrestricted**, and restart.

### Register the client

#### Claude Code

```bash
uv tool install git+https://github.com/awojtas/sketchup-mcp-2017
claude mcp add sketchup -- sketchup-mcp
```

Then `/mcp` inside Claude Code to confirm. This is a one-off — from then on Claude Code launches the client itself.

Install once and start it directly, as above. `uvx --from git+...` also works but re-resolves and re-fetches from git on **every** start — measurably slower, and on Windows slow enough that Claude may time out. Raise the limit with `MCP_TIMEOUT` (milliseconds) if needed. To update later: `uv tool upgrade sketchup-mcp`.

Prefer pip? Fine, as long as it's from git rather than PyPI:

```bash
pip install git+https://github.com/awojtas/sketchup-mcp-2017
claude mcp add sketchup -- sketchup-mcp
```

#### Claude Desktop

```json
{
  "mcpServers": {
    "sketchup": {
      "command": "uvx",
      "args": ["--from", "git+https://github.com/awojtas/sketchup-mcp-2017", "sketchup-mcp"]
    }
  }
}
```

> **Don't use `uvx sketchup-mcp`.** Upstream's README recommends it, but the
> [PyPI package](https://pypi.org/project/sketchup-mcp/) is stale: `0.1.17` predates
> upstream's own FastMCP fix, so it raises a `TypeError` against current versions of the
> `mcp` package. Install from git instead. This fork doesn't publish to PyPI — upstream
> owns that name.

## Usage

Start the server in SketchUp (`Extensions > MCP Server > Start Server`) each session. The Ruby Console logs `Server listening on port 9876` — that line is the only confirmation the menu gives.

Then just ask:

* "Create a simple house model with a roof and windows"
* "Make the selected component red"
* "Cut a dovetail joint between these two boards"
* "Move the selected component 10 cm up"
* "Create a complex arts and crafts cabinet using Ruby code"

Lengths at the tool boundary are **centimetres**. Raw Ruby in `eval_ruby` returns SketchUp's internal inches.

### Tools

**Modelling** — `create_component`, `create_components` (many in one undo step), `create_text` (raised lettering), `delete_component`, `transform_component`, `cut_pocket`, `solid_op`, `set_material`, `select`, `undo_last`

**Joinery** — `create_dovetail`, `create_finger_joint`, `create_mortise_tenon`

**Inspection** — `get_selection`, `measure`, `list_definitions`, `list_instances`, `units_info`, `snapshot` (returns the render itself, so an agent can look at its work)

**Other** — `export_scene`, `eval_ruby` (arbitrary Ruby in SketchUp), `batch` (several calls in one undo step), `transaction`, `ping`

## Troubleshooting

**Claude shows the MCP server as `failed`.** Usually `uv` isn't installed, or isn't on `PATH` in the terminal Claude inherited. Install it and restart Claude. To see the real error, run the client by hand — it prints its startup log and waits on stdin:

```bash
uvx --from git+https://github.com/awojtas/sketchup-mcp-2017 sketchup-mcp
```

`Connected to SketchUp at localhost:9876` means the extension is reachable; `Could not connect` means you haven't started the server.

**Claude connects, but tool calls fail.** The client connects whether or not SketchUp is listening, so **a connected client proves nothing about the server**. Check SketchUp is open and that you started the server *this session* — it doesn't auto-start, including after a SketchUp restart.

**Is the listener actually up?**

```bash
netstat -ano | findstr 9876          # Windows
lsof -nP -iTCP:9876 -sTCP:LISTEN     # macOS / Linux
```

**Extension Manager still shows the old version after installing a new `.rbz`.** Expected on Make 2017 — the version isn't refreshed by reopening Extension Manager. Close SketchUp entirely and reopen. The update did install.

**Command failures.** The Ruby Console carries the server-side error, and the extension mirrors its log to `%TEMP%\sketchup_mcp.log` (the console has no read-back API). For more, set `SKETCHUP_MCP_LOG_LEVEL=DEBUG` and `SKETCHUP_MCP_VERBOSE_CONSOLE=1`.

**Timeouts.** `eval_ruby` is capped at 30s by default — raise `SKETCHUP_MCP_EVAL_TIMEOUT`, or break the work into smaller calls.

## Building and releasing

The extension is built by a standard-library-only Python script — no Ruby, no `rubyzip`.

```bash
python3 scripts/build_rbz.py --version 2.9.0   # -> dist/su_mcp_v2.9.0.rbz
python3 scripts/check_ruby22_compat.py         # fails on any post-Ruby-2.2 syntax
ruby tests/test_socket_loop.rb                 # socket regression suite
```

To cut a release, push a tag:

```bash
git tag v2.9.0 && git push origin v2.9.0
```

CI runs the checks, builds the `.rbz`, and publishes a GitHub Release with the file attached. The tag is the only place a version is written — it's stamped into `extension.json`, the loader, and `main.rb` at build time, and the build fails if they disagree.

Build *contents* are deterministic for a given source and version. The compressed archive bytes are not — zlib output varies between Python versions — so compare file contents, not archive hashes.

## Contributing

Contributions welcome. Fixes that aren't specific to Make 2017 are better sent [upstream](https://github.com/mhyrr/sketchup-mcp) so everyone benefits.

## License

MIT — see [`LICENSE`](LICENSE). Original copyright retained for [@mhyrr](https://github.com/mhyrr); fork modifications © Grainbox Limited.

<!-- sdlc-lifecycle:start -->
## SDLC progress

- ✅ Repo bootstrapped — `/repo-bootstrap`
- ❓ Solution designed — `/solution-design`
- ❓ Architecture designed — `/platform-design`
- ❓ Platform provisioned — `/platform-provision`
- ❓ Platform verified — `/platform-verify`
- ✅ Release-ready — `/repo-release-ready`
- ❓ Requirements drafted — `/requirements-create-from-design`
- ❓ Requirements validated — `/requirements-validation`
- ❓ Tasks planned — `/tasks-create-from-requirements`
- ❓ Implementation — `/task-implement`
- ❓ Implementation verified — `/requirements-verify-post-implementation`

✅ done · ⏳ in progress · ❓ not started — maintained by the sdlc-plugin skills.
<!-- sdlc-lifecycle:end -->
