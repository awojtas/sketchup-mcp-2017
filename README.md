# SketchupMCP 2017 - Sketchup Model Context Protocol Integration

> **This is a fork of [mhyrr/sketchup-mcp](https://github.com/mhyrr/sketchup-mcp).**
>
> It exists for three reasons the upstream project doesn't cover:
>
> 1. **A fix for the UI-freeze bug.** Upstream's extension blocks SketchUp's main thread the moment an MCP client connects, freezing the application until the client disconnects. In practice that means SketchUp hangs as soon as you start Claude, before you've asked it to do anything. Details below.
> 2. **Downloadable releases.** Upstream ships no releases, so you have to build the `.rbz` yourself — and its build script needs a Ruby gem most people don't have. This fork publishes a ready-to-install `.rbz` on every tagged release.
> 3. **SketchUp Make 2017 support.** Make 2017 is the last free desktop SketchUp, and it runs Ruby 2.2.4 with a reduced exporter set. This fork verifies the extension against it and documents what does and doesn't work.
>
> All credit for the original work goes to [@mhyrr](https://github.com/mhyrr). Non-2017-specific fixes are offered back upstream where possible.

SketchupMCP connects Sketchup to Claude AI through the Model Context Protocol (MCP), allowing Claude to directly interact with and control Sketchup. This integration enables prompt-assisted 3D modeling, scene creation, and manipulation in Sketchup.

Big Shoutout to [Blender MCP](https://github.com/ahujasid/blender-mcp) for the inspiration and structure.

### The UI-freeze bug

SketchUp runs Ruby on its **main UI thread**. Upstream's socket loop accepted a connection and then called `client.gets`, which blocks until a newline arrives.

The Python MCP server opens its socket as soon as the process starts and then sends nothing until you invoke a tool. So `gets` waited on data that wasn't coming, the UI thread sat inside that call, and SketchUp greyed out and stopped responding to clicks — recovering only when the MCP server exited and closed the socket.

This fork replaces that with a fully non-blocking loop: each timer tick drains whatever bytes are available and processes any complete messages, never waiting. Partial requests accumulate in a buffer across ticks, and the connection is kept open rather than closed after every request, which is what the Python client expects.

Threads aren't an option here — the SketchUp Ruby API isn't thread-safe, and Ruby threads don't get scheduled while the main thread is blocked anyway.

Two other people hit this independently and proposed fixes upstream ([#7](https://github.com/mhyrr/sketchup-mcp/pull/7) by @Noel-Alex, [#22](https://github.com/mhyrr/sketchup-mcp/pull/22) by @gleydson115-code); both are unmerged. Both cap the blocking read at a short timeout rather than removing it, which leaves the UI thread stalling briefly on every tick and discards partially-received requests when the budget expires. `tests/test_socket_loop.rb` covers that fragmentation case, along with the freeze itself.

## SketchUp Make 2017 compatibility

Status: **verified against a real SketchUp Make 2017 install** (`17.2.2555`), with Ruby 2.2 compatibility enforced in CI. See [`docs/sketchup-make-2017.md`](docs/sketchup-make-2017.md) for the full breakdown.

| Area | Make 2017 |
|---|---|
| Ruby syntax (2.2.4) | ✅ No post-2.2 syntax — checked on every release |
| SketchUp API surface | ✅ No post-2017 API calls |
| Core tools (`eval_ruby`, `create_component`, `get_selection`, `ping`) | ✅ Confirmed working on real Make 2017 |
| `.obj` export | ✅ Confirmed working — contrary to the common "Pro-only" claim |
| `.stl` export | ❌ Does not complete; connection times out mid-export |
| `Sketchup.is_pro?` | ⚠️ Returns `true` on Make 2017 — unusable for detecting Make |
| Extension loading | ℹ️ Releases are unsigned; set the loading policy to Unrestricted if yours objects |

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

So it wears two hats:

| Direction | Role |
|---|---|
| Towards Claude | MCP **server** — exposes the tools Claude can call |
| Towards SketchUp | TCP **client** — connects to the extension and sends it work |

**Your coding agent starts this automatically** once it's registered (see below) — you don't launch it by hand for normal use. You *can* run it manually, which is useful for testing, because you get its log directly in the terminal:

```bash
uvx --from git+https://github.com/awojtas/sketchup-mcp-2017 sketchup-mcp
```

Run that way it prints its startup log and then waits on stdin. `Connected to SketchUp at localhost:9876` means the extension is running and reachable; `Could not connect` means you haven't started the server in SketchUp. Ctrl+C when done — the agent needs to launch its own copy.

### Which one is broken?

| Symptom | Which half |
|---|---|
| Claude reports the MCP server as `failed` | Client — it isn't starting. Check `uv` is installed. |
| Claude connects, but tool calls fail | Server — the extension isn't started, or SketchUp isn't running |
| Nothing in the Ruby Console on Start Server | Server — see Troubleshooting |
| Works, then stops working after reopening SketchUp | Server — restarting SketchUp does not restart it; use the menu again |

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

The server binds `127.0.0.1:9876` and the client dials `localhost:9876`. That's loopback on both ends, so **Claude and SketchUp have to be on the same computer**. Running Claude on a different machine from SketchUp will not connect without an SSH tunnel forwarding port 9876.

This is deliberate: the extension exposes an `eval_ruby` command that executes arbitrary Ruby inside SketchUp. Binding it to anything other than loopback would expose remote code execution to your network.

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

* `get_scene_info` - Gets information about the current Sketchup scene
* `get_selected_components` - Gets information about currently selected components
* `create_component` - Create a new component with specified parameters
* `delete_component` - Remove a component from the scene
* `transform_component` - Move, rotate, or scale a component
* `set_material` - Apply materials to components
* `export_scene` - Export the current scene to various formats
* `eval_ruby` - Execute arbitrary Ruby code in SketchUp for advanced operations

### Example Commands

Here are some examples of what you can ask Claude to do:

* "Create a simple house model with a roof and windows"
* "Select all components and get their information"
* "Make the selected component red"
* "Move the selected component 10 units up"
* "Export the current scene as a 3D model"
* "Create a complex arts and crafts cabinet using Ruby code"

## Troubleshooting

Work out **which half** is at fault first — see [Which one is broken?](#which-one-is-broken) above.

**Claude shows the MCP server as `failed`, error `-32000`.** The client isn't starting, and this error says nothing useful about why. Run it by hand to see the real message:

```bash
uvx --from git+https://github.com/awojtas/sketchup-mcp-2017 sketchup-mcp
```

Most often `uv` isn't installed, or isn't on `PATH` yet in the terminal Claude inherited. Restart Claude after installing it.

**Claude is connected, but every tool call fails.** The client connects happily whether or not SketchUp is listening — it only warns at startup. So a connected client tells you nothing about the server. Check SketchUp is open and you've run **Extensions > MCP Server > Start Server** this session.

**Nothing appears in the Ruby Console when you click Start Server.** On v2.0.0 exactly this happened: lifecycle messages were logged below the console's threshold. Fixed in v2.0.1. If you're on 2.0.0, upgrade. To confirm the listener independently of the console:

```bash
netstat -ano | findstr 9876          # Windows
lsof -nP -iTCP:9876 -sTCP:LISTEN     # macOS / Linux
```

**It worked, then stopped after restarting SketchUp.** The server does not auto-start. Run the menu item again.

**Extension Manager shows the old version after installing a new `.rbz`.** It caches the loaded list. Restart SketchUp and check again — the new version is usually installed correctly despite what the dialog says.

**SketchUp freezes when Claude connects.** That's the upstream bug, fixed in v1.7.0. You're running an old build or upstream's.

**Command failures.** The Ruby Console carries the server-side error. For more detail, set `SKETCHUP_MCP_LOG_LEVEL=DEBUG` and `SKETCHUP_MCP_VERBOSE_CONSOLE=1`.

**Timeout errors.** `eval_ruby` is capped (default 30s, `SKETCHUP_MCP_EVAL_TIMEOUT`). Long-running geometry work may need a larger value or breaking into smaller calls.

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

CI checks Ruby 2.2 compatibility, builds the `.rbz`, and publishes a GitHub Release with the file attached. The tag is the only place the version is written — it's stamped into `extension.json` and the loader at build time, so the three version strings can't drift apart again. Builds are byte-for-byte reproducible.

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
