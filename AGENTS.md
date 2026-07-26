# AGENTS.md

This file provides guidance to Agents (Claude Code, Copilot, Cursor, Codex, etc.) when working with code in this repository.

## Project Overview

sketchup-mcp-2017 is a fork of [mhyrr/sketchup-mcp](https://github.com/mhyrr/sketchup-mcp) that adds downloadable `.rbz` releases and verifies the extension against **SketchUp Make 2017** — the last free desktop version of SketchUp.

The upstream project ships no releases, so users must build the `.rbz` themselves. This fork exists to close that gap and to keep the extension working on Make 2017 specifically.

## The SketchUp Make 2017 constraint

This is the single most important thing to know before changing Ruby code here.

- **Ruby 2.2.4.** SketchUp 2017 embeds Ruby 2.2.4. Anything from Ruby 2.3+ is a hard runtime error, not a warning. No safe navigation (`&.`), no squiggly heredocs (`<<~`), no `Hash#dig` / `Array#dig`, no `String#match?`, no `Array#sum`, no `Comparable#clamp`, no `yield_self` / `then`, no `filter_map`, no pattern matching, no endless method definitions, no hash-value shorthand.
- **Make is not Pro.** SketchUp Make has a materially smaller exporter set than Pro. COLLADA (`.dae`) and KMZ are available; OBJ, FBX, DWG, DXF and 3DS exporters are **Pro-only** and will fail at runtime on Make.
- **Extension loading policy.** SketchUp 2017's Extension Manager defaults to a restricted loading policy, so an unsigned `.rbz` may refuse to load. Signing is free via the Extension Warehouse Developer Center.

When adding Ruby, target Ruby 2.2 syntax and guard any API that postdates SketchUp 2017 behind a `Sketchup.version` check.

## Repository layout

- `su_mcp/` — the SketchUp extension (Ruby). `su_mcp.rb` is the loader, `su_mcp/main.rb` is the TCP server and command dispatch, `extension.json` is the manifest, `package.rb` is upstream's builder.
- `src/sketchup_mcp/` — the Python MCP server that Claude talks to; bridges MCP to the extension's TCP socket.
- `scripts/` — build, verification, and dev-loop tooling. Executable helpers belong here, not at the repo root.
- `docs/` — all documentation. Only `README.md`, `AGENTS.md`, and `CLAUDE.md` are allowed at the root.
- `examples/` — sample scripts driving the server.

The two halves communicate over a JSON-over-TCP socket on port 9876.

`su_mcp.rb` at the **repo root** is a stale duplicate of the packaged loader at `su_mcp/su_mcp.rb` — older version string, not referenced by anything, and not included in the `.rbz`. Edit the packaged one; the root copy is dead.

## Documentation Guidelines

Keep documentation concise and focused.

- Code should be self-documenting where possible. Reach for prose only when "why" isn't obvious from the code.
- Markdown files in the **repo root** are limited to `README.md`, `AGENTS.md`, and `CLAUDE.md`. Everything else lives under `/docs`.
- Filenames are kebab-case and descriptive (e.g. `docs/testing-architecture.md`, `docs/oauth-setup.md`).
- Don't create new docs unless explicitly asked, or when documenting architectural decisions, security/deployment guides, or troubleshooting procedures.
- **Never embed counts in prose or docs.** "Four peer projects studied" → "peer projects studied"; "21 functional domains" → "functional domains". Counts go stale the moment a list changes; anyone who wants the number can count. Exception: numbered steps are fine — order matters there.

## Debugging and Troubleshooting Principles

Systematic discovery beats theory-driven fixes.

1. **Start with discovery, not theory.** Use `find`, `git ls-files`, `git status --ignored`, and `grep` to verify what exists. Don't assume.
2. **Ask before guessing.** "What changed recently?", "What's the full error?", "Any context I should know?" Domain knowledge beats assumptions.
3. **Verify assumptions before building solutions.** If something "should" work a certain way, prove it with a simple command first.
4. **Listen to contradictory evidence.** "This worked yesterday" means something changed — not that the system is fundamentally broken. When a fix fails repeatedly, the theory is wrong.
5. **Reset when stuck.** After 2–3 failed attempts, list assumptions, verify each one, start fresh.

Good debugging is systematic elimination, not clever solutions.

Extension-side errors surface in SketchUp's Ruby Console (Window > Ruby Console). The extension also logs there via its own `log` helper, and mirrors to `%TEMP%\sketchup_mcp.log` — read the file, since the console has no read-back API.

### Don't call blocking or modal SketchUp APIs from `eval_ruby`

`Sketchup.open_file`, `UI.messagebox` and anything else that opens a dialog or pumps the message loop will **re-enter the extension's timer tick** from inside the tool call, then blow `eval_ruby`'s `Timeout` guard:

```
tick error: execution expired
  (mcp eval_ruby):2:in `open_file'
```

Worse, a modal dialog wedges the socket loop until a human dismisses it, so the agent cannot recover on its own. Opening and closing documents is the user's job — ask, don't drive it.

### SketchUp silently reverts some edits

A coplanar face is not always a fault, and a successful move is not always a move.

Glue-to components — windows and doors stuck to a wall — are *required* to lie exactly on the face they are glued to; a cutting one also punches the opening through it. Move one off that plane and SketchUp's validity check reverts it, reporting:

```
Glued CGroup (4223) not on or parallel to glue plane. - fixed
```

The edit applies, `measure` confirms it, a snapshot looks right, and then it disappears at the next validity check. There is no Ruby API for that checker (`Model#validate`, `#fix_problems` and friends do not exist in 2017), so nothing surfaces it in-process.

`behavior.is2d?` identifies a glue-to container, and its own local Z is the glue-plane normal — verified against glued windows and a door whose local Z matched their host wall normal exactly. `transform_component` and `array_copy` refuse off-plane moves on that basis, and `check_model` excludes glue-to components from coplanar findings. Sliding one *within* its plane is legitimate.

The general lesson: **never fix a coplanar overlap by nudging one face off the plane.** That trades a visible rendering artifact for two surfaces with an invisible gap, which still measures and exports wrongly. Merge the contexts, or delete the redundant face.

### Raw Ruby traps that return a plausible wrong answer

Full detail and evidence in `docs/sketchup-make-2017.md`. The ones that cost the most time:

- **`pushpull` follows the face normal**, so cutting into a solid is always a *negative* distance. Positive on a downward-facing face extrudes a boss instead of boring a hole, and it looks right until you check the bounds.
- **`BoundingBox#height` is Y and `#depth` is Z.** Only `#width` means what it says.
- **`add_face` returns `nil`** when the loop you drew merely splits an existing face. Locate the resulting face with `classify_point` rather than treating `nil` as failure.
- **`DefinitionList#remove` does not exist on 2017**, and `purge_unused` takes every unused definition with it.
- **Setting `pages.selected_page` animates**, so a snapshot taken in the same breath renders the previous scene while the layer state already reads as the new one. Disable `PageOptions ShowTransition` first.
- **Scenes store no geometry positions** — camera, layers, style, section planes and shadows only. Exploded views need duplicated geometry that then goes stale; say so before offering one.

## Agent Guidelines

### Token efficiency

To preserve tokens for actual problem-solving:

1. **Don't run builds** unless explicitly asked, or unless required to validate a change.
2. **Don't run `npm install` / `pnpm install`** unless explicitly asked. Assume deps are installed.
3. **Don't create new GitHub issue labels** — only use what already exists. Surface the gap instead.

### Scope discipline

- Don't add features, refactor, or introduce abstractions beyond what the task requires.
- A bug fix doesn't need surrounding cleanup. A one-shot operation doesn't need a helper.
- Three similar lines beats a premature abstraction.
- Validate at system boundaries (user input, external APIs). Trust internal code.

### Merging

The repo owner has authorised agents to merge their own PRs here without asking, provided CI is green. Squash-merge and delete the branch. `main` is protected by a ruleset, so everything still goes through a PR — direct pushes to `main` are rejected.

This authorisation covers **this** repo and the owner's other personal repos. It does not extend to `mhyrr/sketchup-mcp` upstream or any repo the owner doesn't control — contributions there follow the normal review process.

### Fork discipline

This is a fork with an active upstream. Keep changes minimal and rebase-friendly so upstream commits can still be merged. Fixes that aren't 2017-specific are good candidates to contribute back to `mhyrr/sketchup-mcp` rather than diverging.

## Adding Third-Party Packages

Before adding any dependency:

1. **Verify the package exists and exports what you think it does** — check the npm/PyPI/crates.io page, not your memory. Slopsquatting is real.
2. **Prefer framework-native APIs.** Built-ins are more reliable and always compatible.
3. **Test that it builds** after adding. Don't commit a package you haven't exercised at least once.

The extension half must depend on **nothing** outside SketchUp's bundled Ruby standard library — users install a `.rbz`, not a gem.

## Security Best Practices

Generate inherently safe code rather than retrofitting safety later. Adhere to OWASP, particularly OWASP ASVS.

- **No hardcoded secrets.** API keys, DB credentials, signing keys → environment variables or a secrets manager. Never in source.
- **Validate and sanitise all untrusted input** against an allow-list. Use parameterised queries; never string-concatenate SQL.
- **Encode output context-aware.** HTML, JSON, shell — each needs its own encoding to defeat XSS / injection.
- **Authorise server-side, every time.** Never rely on client-side checks. Tie checks to the authenticated session/token.
- **Encrypt in transit and at rest.** TLS everywhere; hash passwords with `bcrypt` / `argon2`, never store plain.
- **Rate-limit state-changing endpoints** and bound resource consumption (uploads, query results, computations).
- **CSRF protect** state-changing requests; mark session cookies `SameSite=Lax|Strict` and `Secure`.
- **SSRF defence**: allow-list protocols, hostnames, and IP ranges for any server-side fetch driven by user input.

### This project's specific exposure

The extension opens a TCP listener inside SketchUp and exposes an `eval_ruby` command that executes arbitrary Ruby in-process. That is remote code execution by design. Keep the listener bound to loopback, never widen it to `0.0.0.0`, and treat any change to the socket binding or the eval path as security-critical.

## Development Environment

- **Python side**: Python 3.10+, managed with `uv`. `uv sync` to install.
- **Ruby side**: no local Ruby needed to edit; SketchUp supplies the runtime. Building the `.rbz` locally needs Ruby with the `rubyzip` gem (`gem install rubyzip`), or just zip the `su_mcp/` contents by hand.
- **Testing against 2017**: requires a Windows or macOS machine with SketchUp Make 2017 installed. There is no Linux build of SketchUp.

## Development Commands

```bash
# Python MCP server
uv sync                      # install dependencies
uv run sketchup-mcp          # run the MCP server

# Build the extension package (stdlib only — no Ruby, no rubyzip)
python3 scripts/build_rbz.py --version 1.6.0

# Verify the extension still runs on SketchUp 2017's Ruby 2.2.4
python3 scripts/check_ruby22_compat.py
```

Upstream's `su_mcp/package.rb` is left in place but is not the canonical builder — it needs the `rubyzip` gem, which is precisely what blocked people from producing an `.rbz` at all.

## Releasing

Releases are tag-driven. Push `v<MAJOR>.<MINOR>.<PATCH>` and `.github/workflows/release.yml` runs the 2.2 compatibility check, builds the `.rbz`, and publishes a GitHub Release with the artifact attached.

The tag is the **only** place a version is written. `build_rbz.py` stamps it into `extension.json` and the loader at build time. Don't reintroduce hardcoded version bumps — three copies had already drifted to 1.6.0 / 1.5.0 / 0.1.17 before this was centralised.

The archive layout is load-bearing. SketchUp needs `su_mcp.rb`, `su_mcp/main.rb`, and `extension.json` at the **archive root**; nesting them one level deeper produces an extension that installs silently and then does nothing. `build_rbz.py` asserts this after writing.
