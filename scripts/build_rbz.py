#!/usr/bin/env python3
"""Build the installable SketchUp extension package (.rbz).

Upstream ships su_mcp/package.rb, which needs Ruby plus the rubyzip gem. That
dependency is the reason people in mhyrr/sketchup-mcp#10 couldn't produce a
.rbz at all. This builder uses only the Python standard library, so it runs
anywhere -- including CI -- with nothing installed.

An .rbz is just a zip with a renamed extension. SketchUp requires a specific
layout at the archive root:

    su_mcp.rb          <- registers the extension
    su_mcp/main.rb     <- the implementation it loads
    extension.json     <- metadata

Getting this wrong (zipping the containing folder rather than its contents) is
the usual cause of "the extension installs but nothing appears in the menu".

Usage:
    python3 scripts/build_rbz.py --version 1.6.0 [--output-dir dist]
"""

import argparse
import json
import re
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "su_mcp"

# (source file, path inside the archive)
LAYOUT = [
    (SRC / "su_mcp.rb", "su_mcp.rb"),
    (SRC / "su_mcp" / "main.rb", "su_mcp/main.rb"),
    (SRC / "extension.json", "extension.json"),
]

VERSION_RE = re.compile(r"^\d+\.\d+\.\d+$")


def stamp_extension_json(text: str, version: str) -> str:
    """Set the version field, preserving the rest of the manifest as-is."""
    manifest = json.loads(text)
    manifest["version"] = version
    return json.dumps(manifest, indent=2) + "\n"


def stamp_loader(text: str, version: str) -> str:
    """Rewrite ext.version in the loader so it matches the release tag.

    The three version strings in this repo (extension.json, the loader, and
    pyproject.toml) had drifted to 1.6.0 / 1.5.0 / 0.1.17. Stamping at build
    time keeps the artifact internally consistent without needing a commit
    that bumps versions in three places.
    """
    return re.sub(
        r"(ext\.version\s*=\s*)['\"][^'\"]*['\"]",
        lambda m: "{}'{}'".format(m.group(1), version),
        text,
    )


def build(version: str, output_dir: Path) -> Path:
    missing = [str(src.relative_to(ROOT)) for src, _ in LAYOUT if not src.exists()]
    if missing:
        raise SystemExit("error: missing source files: " + ", ".join(missing))

    output_dir.mkdir(parents=True, exist_ok=True)
    target = output_dir / "su_mcp_v{}.rbz".format(version)
    if target.exists():
        target.unlink()

    with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED) as archive:
        for src, arcname in LAYOUT:
            text = src.read_text(encoding="utf-8")

            if arcname == "extension.json":
                text = stamp_extension_json(text, version)
            elif arcname == "su_mcp.rb":
                text = stamp_loader(text, version)

            # Fixed timestamp so identical input yields an identical archive.
            info = zipfile.ZipInfo(arcname, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            archive.writestr(info, text)
            print("  added {}".format(arcname))

    return target


def verify(path: Path) -> None:
    """Re-open the archive and assert the layout SketchUp needs."""
    with zipfile.ZipFile(path) as archive:
        names = set(archive.namelist())
        broken = archive.testzip()

    if broken:
        raise SystemExit("error: corrupt entry in archive: {}".format(broken))

    expected = {arcname for _, arcname in LAYOUT}
    if names != expected:
        raise SystemExit(
            "error: unexpected archive layout\n  expected: {}\n  got:      {}".format(
                sorted(expected), sorted(names)
            )
        )

    # The single most common packaging mistake, called out explicitly.
    if any(n.startswith("su_mcp/su_mcp") for n in names):
        raise SystemExit("error: contents are nested one level too deep")


def main() -> int:
    parser = argparse.ArgumentParser(description="Build the SketchUp .rbz package")
    parser.add_argument("--version", required=True, help="release version, e.g. 1.6.0")
    parser.add_argument("--output-dir", default="dist", type=Path)
    args = parser.parse_args()

    version = args.version.lstrip("v")
    if not VERSION_RE.match(version):
        raise SystemExit("error: version must be MAJOR.MINOR.PATCH, got {!r}".format(version))

    output_dir = args.output_dir
    if not output_dir.is_absolute():
        output_dir = ROOT / output_dir

    print("Building su_mcp v{}".format(version))
    target = build(version, output_dir)
    verify(target)

    size_kb = target.stat().st_size / 1024
    print("\nBuilt {} ({:.1f} KB)".format(target.relative_to(ROOT), size_kb))
    return 0


if __name__ == "__main__":
    sys.exit(main())
