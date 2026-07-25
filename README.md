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

Status: **static analysis passed, live verification pending.** See [`docs/sketchup-make-2017.md`](docs/sketchup-make-2017.md) for the full breakdown.

| Area | Make 2017 |
|---|---|
| Ruby syntax (2.2.4) | ✅ No post-2.2 syntax in the extension |
| SketchUp API surface | ✅ No post-2017 API calls |
| `.dae` / `.skp` / image export | ✅ Available |
| `.obj` export | ❌ Pro-only exporter — fails on Make |
| Extension loading | ⚠️ Unsigned `.rbz` may be blocked by the default loading policy |

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

### Starting the Connection

1. In Sketchup, go to Extensions > SketchupMCP > Start Server
2. The server will start on the default port (9876)
3. Make sure the MCP server is running in your terminal

### Using with Claude

Configure Claude to use the MCP server by adding the following to your Claude configuration:

```json
    "mcpServers": {
        "sketchup": {
            "command": "uvx",
            "args": [
                "sketchup-mcp"
            ]
        }
    }
```

This will pull the [latest from PyPI](https://pypi.org/project/sketchup-mcp/)

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

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

MIT — see [`LICENSE`](LICENSE). Original copyright retained for [@mhyrr](https://github.com/mhyrr); fork modifications © Grainbox Limited.

<!-- sdlc-lifecycle:start -->
## SDLC progress

- ✅ Repo bootstrapped — `/repo-bootstrap`
- ❓ Solution designed — `/solution-design`
- ❓ Architecture designed — `/platform-design`
- ❓ Platform provisioned — `/platform-provision`
- ❓ Platform verified — `/platform-verify`
- ❓ Release-ready — `/repo-release-ready`
- ❓ Requirements drafted — `/requirements-create-from-design`
- ❓ Requirements validated — `/requirements-validation`
- ❓ Tasks planned — `/tasks-create-from-requirements`
- ❓ Implementation — `/task-implement`
- ❓ Implementation verified — `/requirements-verify-post-implementation`

✅ done · ⏳ in progress · ❓ not started — maintained by the sdlc-plugin skills.
<!-- sdlc-lifecycle:end -->
