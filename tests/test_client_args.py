#!/usr/bin/env python3
"""Check that the client refuses unknown tool arguments.

FastMCP validates arguments with pydantic, which ignores extra fields by
default: `measure(id=1, sixe=5)` runs as `measure(id=1)`, so a mistyped or
invented parameter vanishes and the call proceeds on defaults. The extension
has reject_unknown_params! for this, but it never fires -- the argument is
dropped before it reaches the wire.

StrictFastMCP closes that. This suite exists because the guard is only useful
if it keeps working: it depends on FastMCP's call_tool staying the dispatch
point, and if a future version routes around it the failure would be silent,
which is the exact thing being guarded against.

Needs no SketchUp -- validation happens before any connection is made.

    python tests/test_client_args.py
"""

import asyncio
import inspect
import sys

from sketchup_mcp.server import mcp

failures = []


def check(label, ok, detail=""):
    print(("  PASS  " if ok else "  FAIL  ") + label + (f" -- {detail}" if detail and not ok else ""))
    if not ok:
        failures.append(label)


async def call(name, args):
    """Return None if validation passed, or the rejection message."""
    try:
        await mcp.call_tool(name, args)
        return None
    except ValueError as e:
        msg = str(e)
        # The context error comes from running outside a request; it means
        # validation passed and dispatch was attempted.
        return None if "Context is not available" in msg else msg
    except Exception:
        return None


async def main():
    print("unknown arguments are rejected")
    for name, args, bad in [
        ("measure", {"id": 1, "sixe": 5}, "sixe"),
        ("create_component", {"type": "cube", "size": [1, 2, 3]}, "size"),
        ("transform_component", {"id": "1", "positon": [1, 2, 3]}, "positon"),
        ("snapshot", {"width": 800, "hieght": 600}, "hieght"),
    ]:
        msg = await call(name, args)
        check(f"{name}: {bad} refused", msg is not None and bad in msg, f"got {msg!r}")
        if msg:
            check(f"{name}: message lists what is accepted", "Accepted:" in msg, msg)

    print("\nvalid arguments still pass validation")
    for name, args in [
        ("measure", {"id": 1}),
        ("create_component", {"type": "cube", "dimensions": [1, 2, 3]}),
        ("snapshot", {"width": 800, "height": 600}),
        ("create_components", {"items": [{"type": "cube"}]}),
    ]:
        msg = await call(name, args)
        check(f"{name}: accepted", msg is None, f"rejected with {msg!r}")

    print("\nevery registered tool is covered")
    tools = await mcp.list_tools()
    allowed = mcp._allowed_args
    missing = [t.name for t in tools if t.name not in allowed]
    check("no tool bypasses the check", not missing, f"unguarded: {missing}")

    # A tool registered by some other path would silently lose its guard, so
    # compare against the schema rather than trusting registration.
    print("\nthe allowed set matches each tool's schema")
    for t in tools:
        schema_args = set((t.inputSchema or {}).get("properties", {}))
        known = allowed.get(t.name, set())
        extra = schema_args - known
        check(f"{t.name}: schema and guard agree", not extra, f"schema-only: {sorted(extra)}")

    print()
    if failures:
        print(f"{len(failures)} FAILED")
        return 1
    print("all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
