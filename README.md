# SketchupMCP 2017 - Sketchup Model Context Protocol Integration

> **A fork of [mhyrr/sketchup-mcp](https://github.com/mhyrr/sketchup-mcp)** that adds:
>
> - **Downloadable releases** — install a `.rbz` from [Releases](https://github.com/awojtas/sketchup-mcp-2017/releases) rather than building it yourself
> - **A fix for the freeze** — upstream locks SketchUp up whenever an agent connects
> - **SketchUp Make 2017 support** — tested against the last free desktop version
>
> Credit for the original work to [@mhyrr](https://github.com/mhyrr).
> Detail on the fixes: [what this fork changes](docs/fork-changes.md).

SketchupMCP connects Sketchup to Claude AI through the Model Context Protocol (MCP), allowing Claude to directly interact with and control Sketchup. This integration enables prompt-assisted 3D modeling, scene creation, and manipulation in Sketchup.

Big Shoutout to [Blender MCP](https://github.com/ahujasid/blender-mcp) for the inspiration and structure.

## SketchUp Make 2017

Tested against a real Make 2017 install (`17.2.2555`).

| | |
|---|---|
| Core tools | ✅ Working |
| `.obj` export | ✅ Working — but see the Pro-trial caveat in the docs |
| `.stl` export | ❌ Refused — hangs SketchUp; use File > Export |

Releases are unsigned. If your Extension Manager refuses to load one, set its loading policy to Unrestricted.

Full breakdown: [`docs/sketchup-make-2017.md`](docs/sketchup-make-2017.md).

## Features

* **Two-way communication**: Connect Claude AI to Sketchup through a TCP socket connection
* **Component manipulation**: Create, modify, delete, and transform components in Sketchup
* **Material control**: Apply and modify materials and colors
* **Scene inspection**: Get detailed information about the current Sketchup scene
* **Selection handling**: Get and manipulate selected components
* **Ruby code evaluation**: Execute arbitrary Ruby code directly in SketchUp for advanced operations

## How it fits together

There are two separate pieces, and they have a **server / client** relationship. Getting this straight makes the setup and the troubleshooting much easier.

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

### The server — the SketchUp extension

The `.rbz` you install into SketchUp. It opens a TCP socket on `127.0.0.1:9876` and waits for commands, which it executes against the open model.

**You start it manually, every SketchUp session**: `Extensions > MCP Server > Start Server`. Nothing starts it for you, and it does not run just because the extension is installed. If you skip this step, everything else will look correctly configured and still not work.

### The client — the `sketchup-mcp` Python package

Confusingly, this is the thing usually called "the MCP server", because it *is* an MCP server — to Claude. But in its relationship with SketchUp it is the **client**: it opens the connection to port 9876 and sends commands.

**Your coding agent starts this automatically** once it's registered (see below) — you don't launch it by hand for normal use. You *can* run it manually, which is useful for testing, because you get its log directly in the terminal:

```bash
uvx --from git+https://github.com/awojtas/sketchup-mcp-2017 sketchup-mcp
```

Run that way it prints its startup log and then waits on stdin. `Connected to SketchUp at localhost:9876` means the extension is running and reachable; `Could not connect` means you haven't started the server in SketchUp. Ctrl+C when done — the agent needs to launch its own copy.

## Installation

### Prerequisite: uv

The client is launched with [uv](https://docs.astral.sh/uv/). Install it first — if it's missing, Claude reports the MCP server as `failed` with error `-32000`, which looks like a bug in this project rather than a missing command.

```powershell
winget install --id=astral-sh.uv -e          # Windows
```
```bash
brew install uv                               # macOS
curl -LsSf https://astral.sh/uv/install.sh | sh   # Linux
```

Open a new terminal afterwards so `uv` is on `PATH`, and check with `uv --version`.

Prefer not to use uv? A plain pip install works too, as long as it's from git rather than PyPI — see the warning below:

```bash
pip install git+https://github.com/awojtas/sketchup-mcp-2017
claude mcp add sketchup -- sketchup-mcp
```

### Install the server (the SketchUp extension)

1. Download the latest `.rbz` from [Releases](https://github.com/awojtas/sketchup-mcp-2017/releases) (or build it yourself with `cd su_mcp && ruby package.rb`)
2. In Sketchup, go to Window > Extension Manager
3. Click "Install Extension" and select the downloaded `.rbz` file
4. Restart Sketchup

On SketchUp 2017 the Extension Manager may refuse to load an unsigned extension. If it does, open Extension Manager > Settings (gear icon) and set the loading policy to **Unrestricted**, then restart.

## Usage

### Both halves must run on the same machine

Both ends use loopback, so **Claude and SketchUp have to be on the same computer**. Running them on different machines needs an SSH tunnel forwarding port 9876.

That's deliberate — `eval_ruby` executes arbitrary Ruby inside SketchUp, so binding wider would expose remote code execution to your network.

### Step 1 — start the server (in SketchUp, every session)

1. In SketchUp, go to **Extensions > MCP Server > Start Server**.
2. The Ruby Console appears and logs `Starting server ... on localhost:9876` followed by `Server listening on port 9876`. That console line is the confirmation — the menu gives no other feedback.

This has to be done again each time you restart SketchUp.

To double-check the listener is actually up:

```bash
# Windows
netstat -ano | findstr 9876
# macOS / Linux
lsof -nP -iTCP:9876 -sTCP:LISTEN
```

### Step 2 — register the client with your agent (once)

#### Claude Code

```bash
claude mcp add sketchup -- uvx --from git+https://github.com/awojtas/sketchup-mcp-2017 sketchup-mcp
```

Then `/mcp` inside Claude Code to confirm. This is a one-off — from then on Claude Code launches the client itself whenever it needs it.

Note that the client will report as **connected even with SketchUp closed**: it only warns at startup and fails at tool-call time. A connected client is not proof the server is running.

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
> [PyPI package](https://pypi.org/project/sketchup-mcp/) is stale: 0.1.17 was published
> before upstream's own `instructions=`/`description=` FastMCP fix, so it raises a
> `TypeError` on startup against current versions of the `mcp` package. Installing from
> git, as above, avoids this. This fork does not publish to PyPI — upstream owns that name.

Once connected, Claude can interact with Sketchup using the following capabilities:

#### Tools

**Modelling** — `create_component`, `delete_component`, `transform_component`, `set_material`, `select`, `undo_last`

**Inspection** — `get_selection`, `measure`, `list_definitions`, `list_instances`, `units_info`, `snapshot`

**Joinery** — `create_dovetail`, `create_finger_joint`, `create_mortise_tenon`

**Other** — `export_scene`, `eval_ruby` (arbitrary Ruby in SketchUp), `batch` (several calls in one undo step), `transaction`, `ping`

### Example Commands

Here are some examples of what you can ask Claude to do:

* "Create a simple house model with a roof and windows"
* "Select all components and get their information"
* "Make the selected component red"
* "Move the selected component 10 units up"
* "Export the current scene as a 3D model"
* "Create a complex arts and crafts cabinet using Ruby code"

## Troubleshooting

**Claude shows the MCP server as `failed`.** Usually `uv` isn't installed, or isn't on `PATH` in the terminal Claude inherited. Install it, restart Claude. To see the real error, run the client by hand:

```bash
uvx --from git+https://github.com/awojtas/sketchup-mcp-2017 sketchup-mcp
```

**Claude connects, but tool calls fail.** The client connects whether or not SketchUp is listening, so a connected client proves nothing about the server. Check SketchUp is open and you've run **Extensions > MCP Server > Start Server** *this session* — it doesn't auto-start, including after a SketchUp restart.

**Extension Manager still shows the old version after installing a new `.rbz`.** Expected on SketchUp Make 2017: the version isn't refreshed by reopening Extension Manager. Close SketchUp entirely and reopen it, and the correct version appears. The update did install.

**Not sure the server is listening?**

```bash
netstat -ano | findstr 9876          # Windows
lsof -nP -iTCP:9876 -sTCP:LISTEN     # macOS / Linux
```

**Command failures.** The Ruby Console carries the server-side error. For more, set `SKETCHUP_MCP_LOG_LEVEL=DEBUG` and `SKETCHUP_MCP_VERBOSE_CONSOLE=1`.

**Timeouts.** `eval_ruby` is capped at 30s by default — raise `SKETCHUP_MCP_EVAL_TIMEOUT`, or break the work into smaller calls.

## Technical Details

### Communication Protocol

The system uses a simple JSON-based protocol over TCP sockets:

* **Commands** are sent as JSON objects with a `type` and optional `params`
* **Responses** are JSON objects with a `status` and `result` or `message`

## Building and releasing

The extension package is built by a standard-library-only Python script — no Ruby, no `rubyzip`, nothing to install. (Upstream's `su_mcp/package.rb` still works if you have the gem, but needing it is why [mhyrr/sketchup-mcp#10](https://github.com/mhyrr/sketchup-mcp/issues/10) went unanswered for so long.)

```bash
python3 scripts/build_rbz.py --version 1.6.0   # -> dist/su_mcp_v1.6.0.rbz
python3 scripts/check_ruby22_compat.py         # fails on any post-Ruby-2.2 syntax
```

To cut a release, push a tag:

```bash
git tag v1.6.0
git push origin v1.6.0
```

CI checks Ruby 2.2 compatibility, runs the socket regression suite, builds the `.rbz`, and publishes a GitHub Release with the file attached. The tag is the only place a version is written — it's stamped into `extension.json`, the loader, and `main.rb`'s `VERSION` at build time, and the build fails if any of the three disagree.

The *contents* of a build are deterministic: same source and version in, same files out, with fixed timestamps. The archive's compressed bytes are not — zlib's output varies between Python versions, so a `.rbz` built locally can differ in size from the one CI publishes while containing byte-identical files. Compare file contents, not the archive hash.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

Fixes that aren't specific to Make 2017 are better sent to [upstream](https://github.com/mhyrr/sketchup-mcp) so everyone benefits.

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
