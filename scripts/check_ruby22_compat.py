#!/usr/bin/env python3
"""Flag Ruby syntax newer than 2.2.4, which is what SketchUp 2017 embeds.

There is no Ruby parser that can be told "reject anything post-2.2", and no
Ruby 2.2 build is available on modern CI images, so this is a heuristic
scanner rather than a real parse. It strips comments and string literals
first, then looks for constructs introduced after 2.2.

Only the extension source matters -- the Python half runs outside SketchUp on
whatever interpreter the user has. Standard library only; no dependencies.

Usage: python3 scripts/check_ruby22_compat.py [paths...]
Exits non-zero if anything is found.
"""

import re
import sys
from pathlib import Path

DEFAULT_TARGETS = ["su_mcp.rb", "su_mcp/su_mcp.rb", "su_mcp/su_mcp/main.rb"]

# (label, compiled pattern, first Ruby version that accepts it)
CHECKS = [
    ("safe navigation operator (&.)", re.compile(r"&\."), "2.3"),
    ("squiggly heredoc (<<~)", re.compile(r"<<~"), "2.3"),
    ("Hash#dig / Array#dig", re.compile(r"\.dig\s*\("), "2.3"),
    ("String#match?", re.compile(r"\.match\?"), "2.4"),
    ("Array#sum", re.compile(r"\.sum\b(?!\s*=)"), "2.4"),
    ("Comparable#clamp", re.compile(r"\.clamp\s*\("), "2.4"),
    ("Object#yield_self", re.compile(r"\.yield_self\b"), "2.5"),
    ("Enumerable#filter_map", re.compile(r"\.filter_map\b"), "2.7"),
    ("Enumerable#tally", re.compile(r"\.tally\b"), "2.7"),
    ("numbered block param (_1)", re.compile(r"\b_1\b"), "2.7"),
    ("endless method definition", re.compile(r"^\s*def\s+[\w.]+(\([^)]*\))?\s*=\s*\S"), "3.0"),
    ("hash value omission", re.compile(r"\{[^}]*\b\w+:\s*[,}]"), "3.1"),
    ("anonymous block forwarding", re.compile(r"\(\s*&\s*\)"), "3.1"),
    # Not syntax, but a stdlib signature change that fails the same way: in
    # 2.2 String.new takes only a positional string, so the Hash is coerced
    # and raises TypeError. Use "".force_encoding(...) instead.
    ("String.new with keyword args", re.compile(r"String\.new\s*\(\s*\w+:"), "2.3"),
]

# Ruby lets you write string literals a dozen ways. Cover the ones that
# actually appear in this codebase rather than pretending to be a full lexer.
# Order matters: interpolation is neutralised before the surrounding quotes.
STRING_PATTERNS = [
    re.compile(r"#\{[^{}]*\}"),          # interpolation
    re.compile(r'"(?:\\.|[^"\\])*"'),    # double-quoted
    re.compile(r"'(?:\\.|[^'\\])*'"),    # single-quoted
    re.compile(r"%w\[[^\]]*\]"),         # word arrays
]
COMMENT_PATTERN = re.compile(r"#.*$")


def strip_noise(line: str) -> str:
    """Neutralise strings and comments so their contents can't trigger a match.

    Strings collapse to a run of 'S' rather than spaces. Spaces would make
    `message: "text"` read as Ruby 3.1's hash-value omission (`message:` then
    nothing before the comma), which is a false positive this codebase trips
    on repeatedly. A non-blank filler keeps the shape of the line intact.
    """
    for pattern in STRING_PATTERNS:
        line = pattern.sub(lambda m: "S" * len(m.group()), line)
    return COMMENT_PATTERN.sub(lambda m: " " * len(m.group()), line)


def scan(path: Path):
    findings = []
    in_heredoc_body = False
    in_block_comment = False

    for lineno, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        stripped = raw.strip()

        if stripped == "=begin":
            in_block_comment = True
            continue
        if stripped == "=end":
            in_block_comment = False
            continue
        if in_block_comment:
            continue

        # Crude heredoc handling: skip bodies, since they're data not code.
        if in_heredoc_body:
            if stripped in ("EOF", "EOS", "HEREDOC", "SQL", "RUBY"):
                in_heredoc_body = False
            continue
        if re.search(r"<<[-~]?['\"]?(EOF|EOS|HEREDOC|SQL|RUBY)\b", raw):
            in_heredoc_body = True

        line = strip_noise(raw)

        for label, pattern, version in CHECKS:
            if pattern.search(line):
                findings.append((lineno, label, version, raw.strip()))

    return findings


def main() -> int:
    targets = sys.argv[1:] or DEFAULT_TARGETS
    root = Path(__file__).resolve().parent.parent

    total = 0
    checked = 0

    for target in targets:
        candidate = Path(target)
        path = candidate if candidate.is_absolute() else root / target
        if not path.exists():
            print(f"warning: {target} not found, skipping", file=sys.stderr)
            continue

        checked += 1
        for lineno, label, version, source in scan(path):
            total += 1
            print(f"{target}:{lineno}: {label} -- needs Ruby {version}, SketchUp 2017 has 2.2.4")
            print(f"    {source}")

    if not checked:
        print("error: no files checked", file=sys.stderr)
        return 2

    if total:
        print(f"\nFound issues incompatible with SketchUp 2017's Ruby 2.2.4.")
        return 1

    print(f"OK: extension source is Ruby 2.2 compatible ({checked} files checked)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
