#!/usr/bin/env python3
"""Drive the joinery tools against a running SketchUp and check the geometry.

The joinery tools were disabled once already because they returned success
while destroying the workpiece. Return values are not evidence, so this
measures instead: every joint is built from boards of known size, and the
resulting volumes are compared against what the joint must remove.

The load-bearing assertion is the same one the extension makes internally --
after a joint the two boards must between them fill their overlap region
exactly once:

    volume(a) + volume(b) == before(a) + before(b) - volume(overlap)

That catches material added instead of removed, cuts on the wrong board, cuts
that missed, gaps, and the halves interpenetrating.

Needs SketchUp running with the extension's server started (Extensions >
MCP Server > Start Server). Connects as an ordinary second client.

    python scripts/verify_joinery.py
"""

import json
import socket
import sys

HOST, PORT = "127.0.0.1", 9876
TOL = 0.05  # cm3


class Failure(Exception):
    pass


class Client:
    def __init__(self):
        self.sock = socket.create_connection((HOST, PORT), timeout=30)
        self.buf = b""
        self.n = 0

    def call(self, tool, args=None):
        self.n += 1
        req = {
            "jsonrpc": "2.0",
            "id": self.n,
            "method": "tools/call",
            "params": {"name": tool, "arguments": args or {}},
        }
        self.sock.sendall((json.dumps(req) + "\n").encode())
        while b"\n" not in self.buf:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise Failure("connection closed by SketchUp")
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        msg = json.loads(line.decode())
        # A tool that raises comes back as a JSON-RPC error, not a result.
        if "error" in msg:
            raise Failure(msg["error"].get("message", json.dumps(msg["error"])))
        result = msg.get("result") or {}
        if result.get("isError"):
            raise Failure(json.dumps(result)[:300])
        # The extension sends the payload twice: parsed under "structured",
        # and as JSON text for clients that only read content blocks.
        if result.get("structured") is not None:
            return result["structured"]
        content = result.get("content") or []
        if content and "text" in content[0]:
            return json.loads(content[0]["text"])
        return result

    def ruby(self, code):
        """Run Ruby and return its value, raising on error."""
        return self.call("eval_ruby", {"code": code}).get("value")


PASS, FAIL = [], []


def check(label, ok, detail=""):
    (PASS if ok else FAIL).append(label)
    print(("  PASS  " if ok else "  FAIL  ") + label + (f" -- {detail}" if detail and not ok else ""))


def near(a, b, tol=TOL):
    return a is not None and b is not None and abs(a - b) <= tol


# Boards are built with a non-identity group transform on purpose: local and
# world coordinates then differ, which is the condition the old tools got
# wrong and the condition every real model is in.
MAKE_BOARD = """
g = Sketchup.active_model.active_entities.add_group
f = g.entities.add_face([0,0,0],[%(sx)f/2.54,0,0],[%(sx)f/2.54,%(sy)f/2.54,0],[0,%(sy)f/2.54,0])
f.reverse! if f.normal.z < 0
f.pushpull(%(sz)f/2.54)
g.transformation = Geom::Transformation.new(
  Geom::Point3d.new(%(ox)f/2.54, %(oy)f/2.54, %(oz)f/2.54))
g.entityID
"""


def board(c, ox, oy, oz, sx, sy, sz):
    return int(c.ruby(MAKE_BOARD % dict(ox=ox, oy=oy, oz=oz, sx=sx, sy=sy, sz=sz)))


def volume(c, eid):
    return c.ruby(
        f"e = Sketchup.active_model.find_entity_by_id({eid}); "
        "e && e.valid? && e.manifold? ? (e.volume * 16.387064).round(4) : nil"
    )


def erase(c, ids):
    """Remove only the boards this script made.

    An earlier version wiped active_entities instead, which would have
    destroyed whatever the user had open. Test fixtures clean up after
    themselves; they do not clear the workspace.
    """
    for eid in ids:
        c.ruby(f"e = Sketchup.active_model.find_entity_by_id({eid}); "
               "e.erase! if e && e.valid?; nil")


def payload_for(args, ids):
    """Map the joint's id parameters onto the boards just created."""
    out = {k: v for k, v in args.items() if k != "_ids"}
    for i, key in enumerate(args["_ids"]):
        out[key] = str(ids[i])
    return out


def joint_case(c, label, tool, boards, args, expected_removed, overlap_cm3):
    """Build boards, cut the joint, and check both boards and the identity."""
    ids = [board(c, *b) for b in boards]
    try:
        before = [volume(c, i) for i in ids]
        try:
            c.call(tool, payload_for(args, ids))
        except Failure as e:
            check(f"{label}: joint cut", False, str(e)[:160])
            return
        after = [volume(c, i) for i in ids]

        for i, want in enumerate(expected_removed):
            got = None if after[i] is None else before[i] - after[i]
            check(f"{label}: board {i} removes {want} cm3", near(got, want),
                  f"got {got}")
        check(f"{label}: both boards still manifold",
              all(v is not None for v in after), f"volumes {after}")
        if all(v is not None for v in after):
            expect = before[0] + before[1] - overlap_cm3
            check(f"{label}: halves fill the overlap exactly once",
                  near(sum(after), expect), f"{sum(after):.3f} vs {expect:.3f}")
    finally:
        erase(c, ids)


def reject_case(c, label, tool, boards, args):
    """The call must fail AND leave both boards exactly as they were."""
    ids = [board(c, *b) for b in boards]
    try:
        before = [volume(c, i) for i in ids]
        try:
            c.call(tool, payload_for(args, ids))
            check(f"{label}: rejected", False, "call succeeded but should not have")
            return
        except Failure:
            check(f"{label}: rejected", True)
        after = [volume(c, i) for i in ids]
        check(f"{label}: both boards left untouched", before == after,
              f"{before} -> {after}")
    finally:
        erase(c, ids)


def main():
    try:
        c = Client()
    except OSError as e:
        print(f"Cannot reach SketchUp on {HOST}:{PORT} ({e}).")
        print("Start it: Extensions > MCP Server > Start Server.")
        return 2

    ver = c.call("ping")["version"]
    print(f"Connected to extension v{ver}")

    # Each case erases only the boards it made, so this is safe to run against
    # whatever happens to be open. The test boards are separate groups and
    # never interact with existing geometry.
    before_count = c.ruby("Sketchup.active_model.active_entities.length")
    print(f"Model has {before_count} entities; test boards are added and removed.\n")

    print("finger joint")
    # Two 20x10x2 boards overlapping 2 cm; 5 fingers of 2 cm across the width.
    # board1 keeps 3 bands (removes 2), board2 keeps 2 (removes 3), 8 cm3 each.
    joint_case(c, "finger", "create_finger_joint",
               [(0, 0, 0, 20, 10, 2), (18, 0, 0, 20, 10, 2)],
               {"_ids": ["board1_id", "board2_id"], "fingers": 5},
               [16.0, 24.0], overlap_cm3=40.0)

    print("mortise and tenon")
    # 4x2 tenon through a 3 cm deep joint: socket 24 cm3, shoulders 96 cm3.
    joint_case(c, "mortise", "create_mortise_tenon",
               [(0, 0, 0, 20, 10, 4), (17, 0, 0, 20, 10, 4)],
               {"_ids": ["mortise_id", "tenon_id"], "width": 4.0, "height": 2.0},
               [24.0, 96.0], overlap_cm3=120.0)

    print("mortise and tenon, roles reversed")
    # The socket must follow mortise_id, not whichever board sits lower.
    joint_case(c, "mortise-swapped", "create_mortise_tenon",
               [(17, 0, 0, 20, 10, 4), (0, 0, 0, 20, 10, 4)],
               {"_ids": ["mortise_id", "tenon_id"], "width": 4.0, "height": 2.0},
               [24.0, 96.0], overlap_cm3=120.0)

    print("dovetail")
    # 2 tails, splay 0.4 cm over a 2 cm joint (atan(0.2) = 11.3099 deg).
    joint_case(c, "dovetail", "create_dovetail",
               [(0, 0, 0, 20, 10, 2), (18, 0, 0, 20, 10, 2)],
               {"_ids": ["tail_id", "pin_id"], "tails": 2, "angle": 11.309932},
               [20.8, 19.2], overlap_cm3=40.0)

    print("rejections")
    reject_case(c, "boards that never touch", "create_finger_joint",
                [(0, 0, 0, 10, 10, 2), (40, 0, 0, 10, 10, 2)],
                {"_ids": ["board1_id", "board2_id"]})
    reject_case(c, "one board passing through the other", "create_finger_joint",
                [(0, 0, 0, 40, 10, 2), (10, 0, 0, 10, 10, 2)],
                {"_ids": ["board1_id", "board2_id"]})
    # Both ids pointing at one board: the tool must notice rather than cut it
    # twice and call the result a joint.
    dup = board(c, 0, 0, 0, 20, 10, 2)
    try:
        dup_before = volume(c, dup)
        try:
            c.call("create_finger_joint", {"board1_id": str(dup), "board2_id": str(dup)})
            check("the same board given twice: rejected", False, "call succeeded")
        except Failure:
            check("the same board given twice: rejected", True)
        check("the same board given twice: board left untouched",
              volume(c, dup) == dup_before)
    finally:
        erase(c, [dup])

    print("\ncut_pocket world coordinates")
    # A board away from the origin, with a non-identity transform: a profile
    # in the coordinates measure reports must cut it, not miss it and extrude
    # a detached slab.
    eid = board(c, 20, 5, 3, 10, 10, 2)
    try:
        before = volume(c, eid)
        c.call("cut_pocket", {"id": eid,
                              "points": [[22, 7, 5], [28, 7, 5], [28, 12, 5], [22, 12, 5]],
                              "depth": 1.0})
        after = volume(c, eid)
        check("cut_pocket: profile in world coordinates removes 30 cm3",
              near(before - after if after else None, 30.0), f"{before} -> {after}")
    finally:
        erase(c, [eid])

    left = c.ruby("Sketchup.active_model.active_entities.length")
    check("the model is left as it was found", left == before_count,
          f"{before_count} entities before, {left} after")
    print()
    if FAIL:
        print(f"{len(FAIL)} FAILED, {len(PASS)} passed")
        return 1
    print(f"all {len(PASS)} checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
