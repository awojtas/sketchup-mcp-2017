from mcp.server.fastmcp import FastMCP, Context, Image
import inspect
import socket
import json
import os
import threading
import logging
from dataclasses import dataclass, field
from contextlib import asynccontextmanager
from typing import AsyncIterator, Dict, Any, List, Optional, Tuple

# ───── Configuration (env-driven) ─────────────────────────────────────────
SKETCHUP_HOST    = os.environ.get("SKETCHUP_MCP_HOST", "localhost")
SKETCHUP_PORT    = int(os.environ.get("SKETCHUP_MCP_PORT", "9876"))
REQUEST_TIMEOUT  = float(os.environ.get("SKETCHUP_MCP_TIMEOUT", "60"))
LONG_TIMEOUT     = float(os.environ.get("SKETCHUP_MCP_LONG_TIMEOUT", "300"))
MAX_RETRIES      = int(os.environ.get("SKETCHUP_MCP_MAX_RETRIES", "2"))
READ_CHUNK       = int(os.environ.get("SKETCHUP_MCP_READ_CHUNK", "32768"))
LOG_LEVEL        = os.environ.get("SKETCHUP_MCP_LOG_LEVEL", "INFO").upper()

logging.basicConfig(
    level=getattr(logging, LOG_LEVEL, logging.INFO),
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
)
logger = logging.getLogger("SketchupMCPServer")

__version__ = "2.0.0"
logger.info("SketchupMCP Server %s starting up", __version__)


# ───── Typed errors ───────────────────────────────────────────────────────
class SketchupError(Exception):
    """Base for all SketchUp MCP client errors."""


class SketchupServerNotRunningError(SketchupError):
    """Raised when the in-SketchUp MCP server plugin isn't listening."""

    def __init__(self, host: str, port: int):
        super().__init__(
            f"SketchUp MCP server is not running on {host}:{port}. "
            "In SketchUp: Extensions → MCP Server → Start Server"
        )
        self.host = host
        self.port = port


class SketchupTransportError(SketchupError):
    """Socket-level failure (connection dropped, timeout, partial read)."""


class SketchupTimeoutError(SketchupError):
    """Request exceeded the configured timeout."""


class SketchupRubyError(SketchupError):
    """Ruby raised an exception in the SketchUp plugin."""

    def __init__(self, message: str, backtrace: Optional[List[str]] = None, code: Optional[int] = None):
        super().__init__(message)
        self.backtrace = backtrace or []
        self.code = code


# ───── Connection class ───────────────────────────────────────────────────
@dataclass
class SketchupConnection:
    host: str = SKETCHUP_HOST
    port: int = SKETCHUP_PORT
    sock: Optional[socket.socket] = None
    buffer: bytes = b""
    _next_id: int = 1
    _lock: threading.Lock = field(default_factory=threading.Lock)

    # ───── Connection lifecycle ─────────────────────────────────────────
    def _fresh_socket(self) -> socket.socket:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        return s

    def connect(self) -> None:
        """Open a connection, raising SketchupServerNotRunningError on refused."""
        if self.sock is not None:
            return
        try:
            self.sock = self._fresh_socket()
            self.sock.settimeout(5.0)
            self.sock.connect((self.host, self.port))
            self.sock.settimeout(None)
            self.buffer = b""
            logger.info("Connected to SketchUp at %s:%s", self.host, self.port)
        except ConnectionRefusedError as e:
            self.sock = None
            raise SketchupServerNotRunningError(self.host, self.port) from e
        except OSError as e:
            self.sock = None
            raise SketchupTransportError(f"Could not connect: {e}") from e

    def disconnect(self) -> None:
        if self.sock is not None:
            try:
                self.sock.close()
            except Exception:
                pass
        self.sock = None
        self.buffer = b""

    def _ensure_connected(self) -> None:
        if self.sock is None:
            self.connect()

    # ───── Framing: read until a complete JSON object is in buffer ──────
    def _read_until_json(self, timeout: float) -> Dict[str, Any]:
        """
        Accumulate bytes on self.buffer until a complete JSON message is
        present. Handles newline-delimited and concatenated framing.
        Returns the parsed dict and consumes its bytes from the buffer.
        """
        assert self.sock is not None
        self.sock.settimeout(timeout)
        end_time: Optional[float] = None
        import time

        while True:
            # First, try to parse what's already in the buffer.
            parsed, consumed = self._try_parse_prefix(self.buffer)
            if parsed is not None:
                self.buffer = self.buffer[consumed:]
                return parsed

            # Read more data.
            try:
                chunk = self.sock.recv(READ_CHUNK)
            except socket.timeout as e:
                raise SketchupTimeoutError(f"Read timed out after {timeout}s") from e
            except (ConnectionResetError, BrokenPipeError, OSError) as e:
                raise SketchupTransportError(f"Connection dropped during read: {e}") from e

            if not chunk:
                raise SketchupTransportError("Server closed connection before response completed")

            self.buffer += chunk

    @staticmethod
    def _try_parse_prefix(buf: bytes) -> Tuple[Optional[Dict[str, Any]], int]:
        """
        Try to parse a single JSON object from the beginning of buf.
        Skips leading whitespace. Returns (parsed, bytes_consumed) or
        (None, 0) if more data is needed.
        """
        if not buf:
            return None, 0
        # Skip leading whitespace
        i = 0
        while i < len(buf) and buf[i:i+1] in (b" ", b"\t", b"\r", b"\n"):
            i += 1
        if i == len(buf):
            return None, 0

        # Fast path: newline-delimited
        nl = buf.find(b"\n", i)
        if nl != -1:
            candidate = buf[i:nl].strip()
            if candidate:
                try:
                    return json.loads(candidate.decode("utf-8")), nl + 1
                except json.JSONDecodeError:
                    pass  # fall through to depth scan

        # Depth-based scan for a complete {...} object
        depth = 0
        in_str = False
        escape = False
        j = i
        while j < len(buf):
            c = buf[j:j+1]
            if in_str:
                if escape:
                    escape = False
                elif c == b"\\":
                    escape = True
                elif c == b'"':
                    in_str = False
            else:
                if c == b'"':
                    in_str = True
                elif c == b"{":
                    depth += 1
                elif c == b"}":
                    depth -= 1
                    if depth == 0:
                        candidate = buf[i:j+1]
                        try:
                            return json.loads(candidate.decode("utf-8")), j + 1
                        except json.JSONDecodeError:
                            return None, 0
            j += 1
        return None, 0

    # ───── Send request, receive response ──────────────────────────────
    def _next_request_id(self) -> int:
        with self._lock:
            rid = self._next_id
            self._next_id += 1
            return rid

    def send_command(
        self,
        method: str,
        params: Optional[Dict[str, Any]] = None,
        request_id: Any = None,
        timeout: Optional[float] = None,
    ) -> Dict[str, Any]:
        """
        Send a JSON-RPC request and return the `result` field.
        Raises typed exceptions for all failure modes.
        """
        timeout = timeout or REQUEST_TIMEOUT

        # Build request
        if method == "tools/call" and params and "name" in params and "arguments" in params:
            request = {"jsonrpc": "2.0", "method": method, "params": params}
        else:
            request = {
                "jsonrpc": "2.0",
                "method": "tools/call",
                "params": {"name": method, "arguments": params or {}},
            }
        request["id"] = request_id if request_id is not None else self._next_request_id()

        # Serialize under lock so concurrent callers don't interleave bytes
        with self._lock:
            last_error: Optional[Exception] = None
            for attempt in range(MAX_RETRIES + 1):
                try:
                    self._ensure_connected()
                    wire = (json.dumps(request) + "\n").encode("utf-8")
                    logger.debug("→ %s (%d bytes, attempt %d)", method, len(wire), attempt + 1)
                    assert self.sock is not None
                    self.sock.sendall(wire)
                    response = self._read_until_json(timeout)
                    logger.debug("← %s (id=%s)", method, response.get("id"))

                    # Reject wrong-id responses (stale retry collision)
                    if response.get("id") not in (None, request["id"]):
                        logger.warning(
                            "Discarding response with mismatched id: got %s, want %s",
                            response.get("id"), request["id"],
                        )
                        continue  # try to read next message

                    if "error" in response:
                        err = response["error"]
                        raise SketchupRubyError(
                            err.get("message", "Unknown error"),
                            backtrace=(err.get("data") or {}).get("backtrace"),
                            code=err.get("code"),
                        )
                    return response.get("result", {})

                except SketchupServerNotRunningError:
                    raise  # user-actionable, don't retry
                except SketchupRubyError:
                    raise  # application-level, don't retry
                except (SketchupTransportError, SketchupTimeoutError) as e:
                    last_error = e
                    logger.warning("Attempt %d/%d failed: %s", attempt + 1, MAX_RETRIES + 1, e)
                    self.disconnect()
                    if attempt >= MAX_RETRIES:
                        break
                    # brief backoff
                    import time
                    time.sleep(0.1 * (attempt + 1))

            assert last_error is not None
            raise last_error


# ───── Global connection singleton ────────────────────────────────────────
_sketchup_connection: Optional[SketchupConnection] = None
_conn_lock = threading.Lock()


def get_sketchup_connection() -> SketchupConnection:
    """Return a connected singleton, lazily created. Thread-safe."""
    global _sketchup_connection
    with _conn_lock:
        if _sketchup_connection is None:
            _sketchup_connection = SketchupConnection()
        _sketchup_connection.connect()  # idempotent
        return _sketchup_connection


@asynccontextmanager
async def server_lifespan(server: FastMCP) -> AsyncIterator[Dict[str, Any]]:
    """Manage server startup and shutdown lifecycle."""
    logger.info("SketchupMCP server starting up")
    try:
        try:
            get_sketchup_connection()
            logger.info("Connected to SketchUp on startup")
        except SketchupServerNotRunningError as e:
            logger.warning(str(e))
        except SketchupTransportError as e:
            logger.warning("Transport error on startup: %s", e)
        yield {}
    finally:
        global _sketchup_connection
        with _conn_lock:
            if _sketchup_connection is not None:
                _sketchup_connection.disconnect()
                _sketchup_connection = None
        logger.info("SketchupMCP server shut down")


# Create MCP server with lifespan support
class StrictFastMCP(FastMCP):
    """Reject unknown tool arguments rather than silently dropping them.

    FastMCP validates arguments with pydantic, which ignores extra fields by
    default. So `measure(id=1, sixe=5)` runs as `measure(id=1)`: a mistyped or
    invented parameter vanishes and the call proceeds on defaults, which is
    how a request silently does something other than what was asked.

    The extension has reject_unknown_params! for exactly this, but it never
    fires, because the argument never reaches the wire. Checking here, against
    the tool's own signature, is the only place it can be caught.
    """

    def __init__(self, *args: Any, **kwargs: Any):
        super().__init__(*args, **kwargs)
        self._allowed_args: Dict[str, set] = {}

    def tool(self, *args: Any, **kwargs: Any):
        register = super().tool(*args, **kwargs)

        def decorator(fn):
            name = kwargs.get("name") or fn.__name__
            # ctx is injected by FastMCP, never sent by the caller.
            self._allowed_args[name] = {
                p for p in inspect.signature(fn).parameters if p != "ctx"
            }
            return register(fn)

        return decorator

    async def call_tool(self, name: str, arguments: Dict[str, Any]):
        allowed = self._allowed_args.get(name)
        if allowed is not None and isinstance(arguments, dict):
            unknown = sorted(set(arguments) - allowed)
            if unknown:
                raise ValueError(
                    f"{name}: unknown argument(s): {', '.join(unknown)}. "
                    f"Accepted: {', '.join(sorted(allowed))}."
                )
        return await super().call_tool(name, arguments)


mcp = StrictFastMCP(
    "SketchupMCP",
    instructions="SketchUp integration through the Model Context Protocol",
    lifespan=server_lifespan,
)

# Tool endpoints
@mcp.tool()
def create_component(
    ctx: Context,
    type: str = "cube",
    position: List[float] = None,
    dimensions: List[float] = None,
    units: str = "cm"
) -> str:
    """Create a primitive component in SketchUp.

    Args:
        type:       "cube", "cylinder", "sphere" or "cone".
        position:   [x, y, z] of the base corner/centre, in CENTIMETRES.
        dimensions: [x, y, z] extents, in CENTIMETRES.
        units:      "cm" (default) or "in" to supply SketchUp internal units.

    Solids are built UPWARD from the given z. Lengths are centimetres unless
    units is "in" -- these were previously passed through as inches, so a
    requested 10cm cube came out 25.4cm with no error.
    """
    try:
        logger.info(f"create_component called with type={type}, position={position}, dimensions={dimensions}, request_id={ctx.request_id}")
        
        sketchup = get_sketchup_connection()
        
        params = {
            "name": "create_component",
            "arguments": {
                "type": type,
                "position": position or [0,0,0],
                "dimensions": dimensions or [1,1,1],
                "units": units
            }
        }
        
        logger.info(f"Calling send_command with method='tools/call', params={params}, request_id={ctx.request_id}")
        
        result = sketchup.send_command(
            method="tools/call",
            params=params,
            request_id=ctx.request_id
        )
        
        logger.info(f"create_component result: {result}")
        return json.dumps(result)
    except Exception as e:
        logger.error(f"Error in create_component: {str(e)}")
        return f"Error creating component: {str(e)}"

@mcp.tool()
def delete_component(
    ctx: Context,
    id: str
) -> str:
    """Delete a component by ID"""
    try:
        sketchup = get_sketchup_connection()
        result = sketchup.send_command(
            method="tools/call",
            params={
                "name": "delete_component",
                "arguments": {"id": id}
            },
            request_id=ctx.request_id
        )
        return json.dumps(result)
    except Exception as e:
        return f"Error deleting component: {str(e)}"

@mcp.tool()
def transform_component(
    ctx: Context,
    id: str,
    position: List[float] = None,
    translate: List[float] = None,
    rotation: List[float] = None,
    scale: List[float] = None
) -> str:
    """Move, rotate or scale a component.

    Args:
        id:        entityID of the entity to transform.
        position:  ABSOLUTE destination [x, y, z] in CENTIMETRES. Moves the
                   entity so its origin lands here, matching the position_cm
                   that measure reports.
        translate: RELATIVE offset [dx, dy, dz] in CENTIMETRES.
        rotation:  [rx, ry, rz] in degrees, about the entity's bounds centre.
        scale:     [sx, sy, sz] multipliers.

    Pass position or translate, not both. Lengths are centimetres -- these
    were previously interpreted as inches, so asking to move 10 moved 25.4,
    and "position" silently behaved as a relative offset that accumulated.
    """
    try:
        sketchup = get_sketchup_connection()
        arguments = {"id": id}
        if position is not None:
            arguments["position"] = position
        if translate is not None:
            arguments["translate"] = translate
        if rotation is not None:
            arguments["rotation"] = rotation
        if scale is not None:
            arguments["scale"] = scale
            
        result = sketchup.send_command(
            method="tools/call",
            params={
                "name": "transform_component",
                "arguments": arguments
            },
            request_id=ctx.request_id
        )
        return json.dumps(result)
    except Exception as e:
        return f"Error transforming component: {str(e)}"

@mcp.tool()
def get_selection(ctx: Context) -> str:
    """Get currently selected components"""
    try:
        sketchup = get_sketchup_connection()
        result = sketchup.send_command(
            method="tools/call",
            params={
                "name": "get_selection",
                "arguments": {}
            },
            request_id=ctx.request_id
        )
        return json.dumps(result)
    except Exception as e:
        return f"Error getting selection: {str(e)}"

@mcp.tool()
def set_material(
    ctx: Context,
    id: str,
    material: str
) -> str:
    """Set material for a component"""
    try:
        sketchup = get_sketchup_connection()
        result = sketchup.send_command(
            method="tools/call",
            params={
                "name": "set_material",
                "arguments": {
                    "id": id,
                    "material": material
                }
            },
            request_id=ctx.request_id
        )
        return json.dumps(result)
    except Exception as e:
        return f"Error setting material: {str(e)}"

@mcp.tool()
def export_scene(
    ctx: Context,
    format: str = "skp"
) -> str:
    """Export the current scene"""
    try:
        sketchup = get_sketchup_connection()
        result = sketchup.send_command(
            method="tools/call",
            params={
                "name": "export",
                "arguments": {
                    "format": format
                }
            },
            request_id=ctx.request_id
        )
        return json.dumps(result)
    except Exception as e:
        return f"Error exporting scene: {str(e)}"

@mcp.tool()
def create_finger_joint(
    ctx: Context,
    board1_id: str,
    board2_id: str,
    fingers: int = 5,
    across: Optional[str] = None,
) -> str:
    """Cut a finger (box) joint between two boards.

    Position the two boards FIRST so their ends overlap by the depth of the
    joint -- that overlap is the joint, and everything else is derived from
    it. The boards must meet end to end along one axis; one passing through
    the other is rejected.

    Args:
        board1_id, board2_id: entityIDs of the two boards. board1 keeps the
                    first finger, board2 the next, alternating.
        fingers:    how many fingers across the joint (at least 2).
        across:     "x", "y" or "z" -- the axis the fingers alternate along.
                    Defaults to the wider of the two axes the boards do not
                    meet along, which is the board's width in normal use.

    Works without SketchUp Pro: every cut is a profile pushed into a face.

    The two boards must together fill the overlap region exactly once, and
    that is checked before anything is committed -- so a joint that would
    leave a gap, cut the wrong board, or have the halves interpenetrate
    fails and leaves the model untouched rather than looking plausible.
    """
    args = {"board1_id": board1_id, "board2_id": board2_id, "fingers": fingers}
    if across is not None:
        args["across"] = across
    return _call(ctx, "create_finger_joint", args)


@mcp.tool()
def create_mortise_tenon(
    ctx: Context,
    mortise_id: str,
    tenon_id: str,
    width: Optional[float] = None,
    height: Optional[float] = None,
    across: Optional[str] = None,
) -> str:
    """Cut a mortise and tenon joint between two boards.

    Position the two boards FIRST so the tenon board's end overlaps the
    mortise board by the depth of the joint.

    Args:
        mortise_id: entityID of the board that gets the socket.
        tenon_id:   entityID of the board that keeps the stub. Its four
                    shoulders are cut away to leave the tenon.
        width:      tenon width in CENTIMETRES, across the joint's wider
                    axis. Defaults to half the joint's extent.
        height:     tenon thickness in CENTIMETRES. Defaults to a third of
                    the joint's extent, the usual rule of thumb.
        across:     "x", "y" or "z" -- which axis `width` is measured along.

    Roles are bound to the ids you give, not to where the boards sit: the
    socket goes into mortise_id whichever side of the joint it is on.

    Works without SketchUp Pro. Verified before commit: the two boards must
    together fill the overlap exactly once, or nothing is changed.
    """
    args = {"mortise_id": mortise_id, "tenon_id": tenon_id}
    if width is not None:
        args["width"] = width
    if height is not None:
        args["height"] = height
    if across is not None:
        args["across"] = across
    return _call(ctx, "create_mortise_tenon", args)


@mcp.tool()
def create_dovetail(
    ctx: Context,
    tail_id: str,
    pin_id: str,
    tails: int = 2,
    angle: float = 10.0,
    across: Optional[str] = None,
) -> str:
    """Cut a through dovetail joint between two boards.

    Position the two boards FIRST so their ends overlap by the depth of the
    joint -- for a through dovetail that overlap is the thickness of the
    mating board.

    Args:
        tail_id:  entityID of the board that keeps the tails. They flare
                  toward that board's own end, which is what stops the
                  joint pulling apart.
        pin_id:   entityID of the board that gets the matching sockets.
        tails:    how many tails (at least 1). Pins fall between them, with
                  a half pin at each edge.
        angle:    splay in DEGREES, 0 to 45. 10 is a common hardwood angle;
                  softwood is usually a little steeper.
        across:   "x", "y" or "z" -- the axis the tails are spaced along.

    The taper lies in the plane of the boards' faces, so each cut is still
    a flat profile pushed through the thickness -- no SketchUp Pro needed.

    Verified before commit: the two boards must together fill the overlap
    exactly once, or the model is left untouched.
    """
    args = {"tail_id": tail_id, "pin_id": pin_id, "tails": tails, "angle": angle}
    if across is not None:
        args["across"] = across
    return _call(ctx, "create_dovetail", args)

@mcp.tool()
def array_copy(ctx: Context, id: str, count: int, offset: List[float]) -> str:
    """Repeat an entity along a vector -- slats, pickets, balusters, shelves.

    This repeats a FINISHED entity, whatever it is: a board with a dovetail
    already cut, a whole assembly, a component instance. Listing primitives
    out with create_components would mean rebuilding the joinery on every one.

    Args:
        id:     entityID of the entity to repeat.
        count:  total items in the finished array, INCLUDING the original --
                count 12 adds 11 copies.
        offset: [dx, dy, dz] in CENTIMETRES, the step from one item to the next.

    Groups stay groups; component instances stay instances sharing their
    definition. For a grid, run it again on one of the resulting ids.

    Every copy's position is checked against where it should land before the
    operation is committed, so a wrong step -- or one applied in inches --
    fails rather than producing a plausible-looking array at the wrong pitch.
    """
    return _call(ctx, "array_copy",
                 {"id": id, "count": count, "offset": offset},
                 timeout=LONG_TIMEOUT)


@mcp.tool()
def create_components(ctx: Context, items: List[Dict[str, Any]]) -> str:
    """Create several primitives in one call and one undo step.

    A model is rarely one box. Building a run of parts a call at a time leaves
    a partial model behind when the fifth one is wrong, and a dozen entries in
    the undo history to unpick.

    Args:
        items: list of specs, each taking the same fields as create_component:
               {"type": "cube"|"cylinder"|"sphere"|"cone",
                "position": [x, y, z], "dimensions": [x, y, z],
                "units": "cm" (default) or "in"}

    Every item is validated before anything is built, and the whole run is one
    abortable operation -- so a bad spec anywhere means NOTHING is created,
    rather than a half-built assembly to clean up by hand.

    Returns each new id with its bounds and volume. Lengths are CENTIMETRES.

    For parts derived by computation rather than listed out, eval_ruby is
    still the tool -- it has a real loop.
    """
    return _call(ctx, "create_components", {"items": items}, timeout=LONG_TIMEOUT)


@mcp.tool()
def create_text(
    ctx: Context,
    text: str,
    position: List[float],
    facing: str = "+z",
    height: float = 5.0,
    depth: float = 0.3,
    font: str = "Arial",
    bold: bool = False,
    italic: bool = False,
    name: Optional[str] = None,
) -> str:
    """Create raised 3D lettering -- house numbers, signage, labels.

    SketchUp builds the glyph outlines, so these are real letterforms with
    curves and counters, not shapes approximated from points. Use this rather
    than cut_pocket for anything textual: a letter is not a prismatic profile
    you can write out as coordinates.

    Args:
        text:     the string to build.
        position: [x, y, z] in CENTIMETRES -- where the lettering is CENTRED
                  on the surface it sits on. It grows outward from there.
        facing:   "+x", "-x", "+y", "-y", "+z" or "-z" -- the direction the
                  lettering faces, meaning the side you read it from. To put
                  a number on a wall whose outer surface faces -x, pass "-x"
                  and a position on that wall.
        height:   cap height in centimetres.
        depth:    how far it stands proud of the surface, in centimetres.
        font:     font name. Falls back with an error if not installed.
        bold, italic: font styling.
        name:     name for the resulting group.

    Returns the new group's id, bounds, volume and face count. The lettering
    is a separate solid group sitting on the surface -- "stuck on" rather than
    carved in. Engraving instead needs solid_op, which requires Pro.

    The reading direction is derived from `facing`, so the text cannot come
    out mirrored. That matters because a mirrored glyph has identical bounds,
    volume and face count to a correct one -- only looking at it, or trusting
    this, will tell you.

    Works without SketchUp Pro.
    """
    args: Dict[str, Any] = {
        "text": text, "position": position, "facing": facing,
        "height": height, "depth": depth, "font": font,
        "bold": bold, "italic": italic,
    }
    if name is not None:
        args["name"] = name
    return _call(ctx, "create_text", args)


@mcp.tool()
def eval_ruby(
    ctx: Context,
    code: str
) -> str:
    """Evaluate arbitrary Ruby code in SketchUp.

    Units: SketchUp works in INCHES internally, so raw Ruby here returns
    inches. The purpose-built tools use centimetres at their boundary. Use
    `.cm` / `.m` on numbers, or convert explicitly, to avoid mixing the two.

    Undo is NOT yours to drive from here. This code runs inside an open
    operation, so `Sketchup.undo` has nothing to act on and will appear to
    succeed while changing nothing. To undo, use the `undo_last` tool; to roll
    back an operation you opened yourself, use `transaction(action="abort")`.

    Boolean/solid operations: prefer the `solid_op` tool. `Group#subtract`
    subtracts the RECEIVER from the ARGUMENT, which reads backwards, and both
    operands are consumed and replaced by a new group. Getting it wrong
    destroys the solid you meant to keep and returns something that looks
    valid. `Sketchup::Entities` has no `subtract` at all -- only groups and
    component instances do.

    Constants defined here do NOT leak between calls (each call gets its own
    module scope), and neither do local variables. Pass state via entityIDs.
    """
    try:
        logger.info(f"eval_ruby called with code length: {len(code)}")
        
        sketchup = get_sketchup_connection()
        
        result = sketchup.send_command(
            method="tools/call",
            params={
                "name": "eval_ruby",
                "arguments": {
                    "code": code
                }
            },
            request_id=ctx.request_id
        )
        
        logger.info(f"eval_ruby result: {result}")
        
        # Format the response to include the result
        response = {
            "success": True,
            "result": result.get("content", [{"text": "Success"}])[0].get("text", "Success") if isinstance(result.get("content"), list) and len(result.get("content", [])) > 0 else "Success"
        }
        
        return json.dumps(response)
    except Exception as e:
        logger.error(f"Error in eval_ruby: {str(e)}")
        return json.dumps({
            "success": False,
            "error": str(e)
        })

# ──────────────────────────────────────────────────────────────────────────
# Phase B + C: new tools (batch, undo_last, measure, snapshot,
# list_definitions, list_instances, select, units_info, transaction)
# ──────────────────────────────────────────────────────────────────────────

def _text_of(result: Dict[str, Any]) -> str:
    """Extract the text payload from a SketchUp tool-call response."""
    content = result.get("content")
    if isinstance(content, list) and content:
        item = content[0]
        if isinstance(item, dict):
            return item.get("text", "")
    return ""


def _call(ctx: Context, tool: str, args: Optional[Dict[str, Any]] = None,
          timeout: Optional[float] = None) -> str:
    """Low-level call helper: returns JSON string of the tool response."""
    try:
        conn = get_sketchup_connection()
        result = conn.send_command(
            method="tools/call",
            params={"name": tool, "arguments": args or {}},
            request_id=ctx.request_id,
            timeout=timeout,
        )
        # Prefer the structured payload if present, else the text.
        structured = result.get("structured")
        if structured is not None:
            return json.dumps({"success": True, "result": structured})
        text = _text_of(result)
        return json.dumps({"success": True, "result": text})
    except SketchupServerNotRunningError as e:
        logger.error(str(e))
        return json.dumps({"success": False, "error": str(e), "kind": "server_not_running"})
    except SketchupRubyError as e:
        logger.error("Ruby error: %s", e)
        return json.dumps({"success": False, "error": str(e), "kind": "ruby_error",
                           "backtrace": e.backtrace, "code": e.code})
    except (SketchupTimeoutError, SketchupTransportError) as e:
        logger.error("Transport: %s", e)
        return json.dumps({"success": False, "error": str(e), "kind": "transport"})
    except Exception as e:
        logger.exception("Unexpected error in %s", tool)
        return json.dumps({"success": False, "error": str(e), "kind": "unexpected"})


@mcp.tool()
def batch(ctx: Context, calls: List[Dict[str, Any]],
          wrap_undo: bool = True, undo_name: str = "MCP batch",
          stop_on_error: bool = True) -> str:
    """Run multiple tool calls as one undo-wrapped transaction.

    Args:
        calls: List of {"tool": "<name>", "args": {...}} objects.
        wrap_undo: Wrap the whole batch in start_operation/commit_operation.
        undo_name: Label for the undo history entry.
        stop_on_error: If True, abort the whole batch on first failure.
    """
    return _call(ctx, "batch",
                 {"calls": calls, "wrap_undo": wrap_undo,
                  "undo_name": undo_name, "stop_on_error": stop_on_error},
                 timeout=LONG_TIMEOUT)


@mcp.tool()
def undo_last(ctx: Context, steps: int = 1) -> str:
    """Undo the last N operations on the active model."""
    return _call(ctx, "undo_last", {"steps": steps})


@mcp.tool()
def measure(ctx: Context, id: int) -> str:
    """Return bounds (cm), position, material, and class for an entity by id."""
    return _call(ctx, "measure", {"id": id})


@mcp.tool()
def snapshot(ctx: Context, width: int = 1600, height: int = 1000,
             camera: Optional[Dict[str, Any]] = None,
             antialias: bool = True, path: Optional[str] = None,
             compression: float = 0.9, as_image: bool = True):
    """Render the active view and return the image.

    Look at the result. Geometry that is wrong -- mirrored, inside out, built
    downward, in the wrong place -- routinely returns numbers that look right,
    and rendering is the cheapest way to catch it.

    Args:
        width, height: Output pixel dimensions. Smaller is cheaper to send;
                       around 1000x700 is plenty to inspect a model.
        camera: Optional {eye: [x,y,z], target: [x,y,z], up: [x,y,z],
                          perspective: bool, fov: float}. Lengths in CM.
        antialias: Enable 2x AA.
        path: Destination path (default: temp file).
        compression: PNG compression 0..1.
        as_image: Return the render itself, plus JSON metadata. Set false for
                  just the path -- useful when writing a file for a human.
    """
    args: Dict[str, Any] = {
        "width": width, "height": height,
        "antialias": antialias, "compression": compression,
    }
    if camera is not None:
        args["camera"] = camera
    if path is not None:
        args["path"] = path
    result = _call(ctx, "snapshot", args, timeout=LONG_TIMEOUT)

    if not as_image:
        return result

    # Returning the render itself, not just where it was written. Modelling is
    # verified by looking, and a path costs the caller an extra read -- or,
    # worse, gets taken on trust. The JSON still rides along as a text block,
    # so anything parsing the path keeps working.
    try:
        rendered = json.loads(result).get("result", {}).get("path")
        if rendered and os.path.isfile(rendered):
            return [Image(path=rendered), result]
    except (ValueError, TypeError, OSError) as e:
        logger.warning(f"snapshot: returning path only, could not attach image: {e}")
    return result


@mcp.tool()
def list_definitions(ctx: Context, name_match: Optional[str] = None,
                     include_bounds: bool = True) -> str:
    """List all component definitions in the active model.

    Args:
        name_match: Case-insensitive regex to filter by name.
        include_bounds: Include per-definition bounds in cm.
    """
    args: Dict[str, Any] = {"include_bounds": include_bounds}
    if name_match is not None:
        args["name_match"] = name_match
    return _call(ctx, "list_definitions", args)


@mcp.tool()
def list_instances(ctx: Context, definition_name: Optional[str] = None,
                   limit: int = 500,
                   bounds: Optional[Dict[str, List[float]]] = None) -> str:
    """List instances (components + groups) in the active model.

    Args:
        definition_name: Exact definition/group name filter.
        limit: Max entries to return.
        bounds: Optional {"min":[x,y,z], "max":[x,y,z]} bbox filter (inches).
    """
    args: Dict[str, Any] = {"limit": limit}
    if definition_name is not None:
        args["definition_name"] = definition_name
    if bounds is not None:
        args["bounds"] = bounds
    return _call(ctx, "list_instances", args)


@mcp.tool()
def select(ctx: Context, ids: List[int]) -> str:
    """Replace the current SketchUp selection with the given entity IDs."""
    return _call(ctx, "select", {"ids": ids})


@mcp.tool()
def units_info(ctx: Context) -> str:
    """Return model length unit and conversion factors."""
    return _call(ctx, "units_info")


@mcp.tool()
def transaction(ctx: Context, action: str, name: str = "MCP transaction",
                disable_ui: bool = True) -> str:
    """Explicit undo-transaction control.

    Args:
        action: 'start', 'commit', or 'abort'.
        name: Undo label (start only).
        disable_ui: Disable UI refresh during operation (start only).
    """
    return _call(ctx, "transaction",
                 {"action": action, "name": name, "disable_ui": disable_ui})


@mcp.tool()
def cut_pocket(ctx: Context, id: int, points: List[List[float]], depth: float) -> str:
    """Cut a pocket into a solid by drawing a profile on a face and pushing inward.

    This is the way to remove material WITHOUT SketchUp Pro. Solid operations
    (solid_op) are Pro-only, but most real cuts -- mortises, notches, rebates,
    slots, holes -- are just a flat profile extruded into a face, which is
    exactly what push/pull does, on every SketchUp edition.

    Prefer this over solid_op whenever the cut is prismatic. It is simpler, it
    does not consume and replace the solid, and it works for Make users.

    Args:
        id:     entityID of the solid to cut.
        points: the profile, as [[x,y,z], ...] in CENTIMETRES. Must be coplanar
                and lie on one face of the solid. Order around the outline.
        depth:  how far to cut in, in centimetres. Always positive -- the
                inward direction is worked out from the geometry.

    Unlike solid_op the solid keeps its entityID. Returns how much material was
    removed, and fails loudly if the cut removed nothing or left the solid
    non-manifold, rather than leaving you with a plausible-looking wrong shape.

    For cuts that genuinely need boolean geometry -- an arbitrary solid as the
    cutter, angled or curved intersections -- use solid_op, which needs Pro.
    """
    return _call(ctx, "cut_pocket", {"id": id, "points": points, "depth": depth})


@mcp.tool()
def solid_op(ctx: Context, operation: str, target_id: int, tool_id: int,
             keep_tool: bool = False) -> str:
    """Boolean (solid) operation between two solids: subtract, union, intersect.

    Prefer this over calling .subtract/.union/.intersect yourself in eval_ruby.
    SketchUp's Group#subtract subtracts the RECEIVER from the ARGUMENT, which
    reads backwards, and getting it wrong destroys the solid you meant to keep
    while returning a plausible-looking result. This names operands by role and
    verifies the outcome.

    Args:
        operation: "subtract", "union" or "intersect".
                   ("difference"/"intersection" are accepted as aliases.)
        target_id: entityID of the solid to KEEP and modify.
        tool_id:   entityID of the solid doing the cutting.
        keep_tool: leave the tool solid in the model (it is consumed otherwise).

    Both operands must be manifold solids (groups or component instances), and
    both are consumed: a NEW group is returned, so use the returned id
    afterwards rather than target_id.

    Returns before/after volume, face count, bounds and manifold state for the
    target, so a destroyed or inverted result is visible rather than silent.
    Lengths are centimetres, volumes cubic centimetres.

    Requires SketchUp Pro -- solid operations are absent on Make. Check
    ping()["capabilities"]["solid_tools"] first.
    """
    return _call(ctx, "boolean_operation", {
        "operation": operation,
        "target_id": target_id,
        "tool_id": tool_id,
        "keep_tool": keep_tool,
    })


@mcp.tool()
def ping(ctx: Context) -> str:
    """Cheap health check: returns server version and timestamp."""
    return _call(ctx, "ping")


def main():
    try:
        mcp.run()
    except KeyboardInterrupt:
        # Running this by hand to check connectivity is a documented workflow,
        # and Ctrl+C is how you end it. Without this, the interrupt unwinds
        # through anyio and asyncio and prints ~60 lines of traceback, which
        # reads as a crash rather than a normal exit.
        logger.info("Interrupted, shutting down")
        return 0


if __name__ == "__main__":
    main()