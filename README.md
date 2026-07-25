# SketchupMCP 2017 - Sketchup Model Context Protocol Integration

> **This is a fork of [mhyrr/sketchup-mcp](https://github.com/mhyrr/sketchup-mcp).**
>
> It exists for two reasons the upstream project doesn't cover:
>
> 1. **Downloadable releases.** Upstream ships no releases, so you have to build the `.rbz` yourself. This fork publishes a ready-to-install `.rbz` on every tagged release.
> 2. **SketchUp Make 2017 support.** Make 2017 is the last free desktop SketchUp, and it runs Ruby 2.2.4 with a reduced exporter set. This fork verifies the extension against it and documents what does and doesn't work.
>
> All credit for the original work goes to [@mhyrr](https://github.com/mhyrr). Non-2017-specific fixes are contributed back upstream where possible.

SketchupMCP connects Sketchup to Claude AI through the Model Context Protocol (MCP), allowing Claude to directly interact with and control Sketchup. This integration enables prompt-assisted 3D modeling, scene creation, and manipulation in Sketchup.

Big Shoutout to [Blender MCP](https://github.com/ahujasid/blender-mcp) for the inspiration and structure.

## SketchUp Make 2017 compatibility

Status: **static analysis passed and enforced in CI; live verification pending.** See [`docs/sketchup-make-2017.md`](docs/sketchup-make-2017.md) for the full breakdown.

| Area | Make 2017 |
|---|---|
| Ruby syntax (2.2.4) | ✅ No post-2.2 syntax — checked on every release |
| SketchUp API surface | ✅ No post-2017 API calls |
| `.dae` / `.skp` / image export | ✅ Available |
| `.obj` export | ❌ Pro-only exporter — now fails with an explanatory message, use `dae` |
| `.stl` export | ⚠️ Depends on the SketchUp STL extension being installed |
| Extension loading | ℹ️ Releases are unsigned; set the loading policy to Unrestricted if yours objects |

## Features

* **Two-way communication**: Connect Claude AI to Sketchup through a TCP socket connection
* **Component manipulation**: Create, modify, delete, and transform components in Sketchup
* **Material control**: Apply and modify materials and colors
* **Scene inspection**: Get detailed information about the current Sketchup scene
* **Selection handling**: Get and manipulate selected components
* **Ruby code evaluation**: Execute arbitrary Ruby code directly in SketchUp for advanced operations

## Components

The system consists of two main components:

1. **Sketchup Extension**: A Sketchup extension that creates a TCP server within Sketchup to receive and execute commands
2. **MCP Server (`sketchup_mcp/server.py`)**: A Python server that implements the Model Context Protocol and connects to the Sketchup extension

## Installation

### Python Packaging

We're using uv so you'll need to ```brew install uv```

### Sketchup Extension

1. Download the latest `.rbz` from [Releases](https://github.com/awojtas/sketchup-mcp-2017/releases) (or build it yourself with `cd su_mcp && ruby package.rb`)
2. In Sketchup, go to Window > Extension Manager
3. Click "Install Extension" and select the downloaded `.rbz` file
4. Restart Sketchup

On SketchUp 2017 the Extension Manager may refuse to load an unsigned extension. If it does, open Extension Manager > Settings (gear icon) and set the loading policy to **Unrestricted**, then restart.

## Usage

### Both halves must run on the same machine

The extension listens on `127.0.0.1:9876` and the MCP server dials `localhost:9876`. That's loopback on both ends, so **Claude and SketchUp have to be on the same computer**. Running Claude on a different machine to the one running SketchUp will not connect without an SSH tunnel forwarding port 9876.

This is deliberate: the extension exposes an `eval_ruby` command that executes arbitrary Ruby inside SketchUp. Binding it to anything other than loopback would expose remote code execution to your network.

### Starting the Connection

1. In SketchUp, go to **Extensions > MCP Server > Start Server**.
2. The Ruby Console appears and logs `Starting server on localhost:9876...` followed by `Server started`. That console line is the confirmation — the menu gives no other feedback.

To double-check the listener is actually up:

```bash
# Windows
netstat -ano | findstr 9876
# macOS / Linux
lsof -nP -iTCP:9876 -sTCP:LISTEN
```

### Using with Claude Code

```bash
claude mcp add sketchup -- uvx --from git+https://github.com/awojtas/sketchup-mcp-2017 sketchup-mcp
```

Then `/mcp` inside Claude Code to confirm it connected.

### Using with Claude Desktop

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

* **Connection issues**: Make sure both the Sketchup extension server and the MCP server are running
* **Command failures**: Check the Ruby Console in Sketchup for error messages
* **Timeout errors**: Try simplifying your requests or breaking them into smaller steps

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
