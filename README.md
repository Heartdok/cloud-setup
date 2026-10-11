# cloud-setup

A developer-toolchain installer for cloud coding sandboxes: the kind that run a **setup script**
as root on a fresh Ubuntu image, snapshot the result, and start every session from that snapshot.
A project lists the modules it wants in one file; this script installs them, quickly, idempotently,
and without ever failing the sandbox.

## Usage
Put this line in the sandbox's setup-script field:

```bash
curl -fsSL https://raw.githubusercontent.com/Heartdok/cloud-setup/main/setup.sh | bash || true
```

It downloads this repository anonymously (a tarball; no git, no credentials) to `/opt/cloud-setup`
(or `~/.local/share/cloud-setup` when not root), finds the projects, and installs `core` plus every
module their manifests name. `|| true` keeps the line safe even under a strict shell.

From a checkout: `bash setup.sh [--repo DIR] [--no-local] [--list]`.

## What it guarantees
- **Exit 0, always.** A failed step is recorded, never fatal: a non-zero setup script would stop
  the sandbox from starting.
- **A time budget.** Platforms stop caching a setup that runs for about five minutes, so steps share
  `CLOUD_SETUP_BUDGET` seconds (default 240). A step that overruns is killed, later ones are skipped,
  and the result says which.
- **A result you can read later**, in `$HOME/.local/share/cloud-env/`:
  - `setup-result`: `running: <step> (since T)` while running, then `base=<commit>`, followed by
    ` ERROR=<…>` if anything went wrong (unknown modules, failed or skipped steps, no manifest).
  - `setup.log`: everything the steps printed.

  A file that is missing or still says `running:` tells a session that the build-time setup did not
  run or was cut off, so a session-time layer can repair what is missing.

## Finding the project
Every candidate that contains `scripts/cloud/manifest` is a project: the git toplevel of the current
directory, the current directory, then each directory matching `/home/*/*` and `/root/*` (override
with `CLOUD_SETUP_ROOTS`). A sandbox that clones several repos side by side gets the union of their
manifests, and each repo's `setup.local.sh` runs (steps `local:<repo>`); per-repo modules (`node`,
`python`) act on the repos that list them, and the first repo that pins Bun sets its version.
Without a manifest anywhere, the first git repository found, else the current directory, gets `core`
only. `--repo DIR` (repeatable, or `CLOUD_SETUP_REPO`) skips the search.

## The manifest
`scripts/cloud/manifest` in the project: module names separated by spaces or newlines, `#` starts a
comment, `core` is implicit. An unknown name is reported in `setup-result` and the log, and the
known modules still install.

```
# scripts/cloud/manifest
agent-clis
office      # documents
python
```

Project-specific steps go in `scripts/cloud/setup.local.sh`, run after the modules (and inside the
same budget). A project's Bun version (`.bun-version`, or `"packageManager": "bun@X"` in
`package.json`) overrides the pin.

## Modules
`bash setup.sh --list` prints them.

| Module | Installs |
|---|---|
| `core` (always) | apt basics, `gh`, `jq`, `git-lfs`, uv, Bun, Node (if missing or < 20), pandoc, 1Password CLI `op`; a user-level Claude Code SessionStart hook that runs a project's `scripts/cloud/session-start.sh`. Bun is the only JS package manager: `npx` runs `bunx` and `npm` refuses with the bun equivalent. |
| `agent-clis` | Codex, Grok, Cursor Agent (`cursor-agent`) and Gemini CLIs. No sign-in. |
| `blender` | headless Blender, pinned and sha256-verified, with its system libraries and xvfb |
| `blender-mcp` | Blender Lab's MCP server as a uv tool, plus a `cloud-env-blender-mcp` launcher for `.mcp.json` (pulls in `blender`) |
| `office` | LibreOffice (headless), poppler, qpdf, ImageMagick, Office-metric fonts, python-docx/pptx/openpyxl/pandas/markitdown, docx/pptxgenjs/exceljs |
| `python` | the project's Python and locked deps (`uv sync --frozen`) |
| `node` | the project's JS deps (`bun install --frozen-lockfile`) |
| `wrangler` | Cloudflare's CLI |
| `tailscale` | the Tailscale client, installed only |

Nothing here signs in to anything or reads a secret: credentials don't exist yet when a setup script
runs, and the snapshot would keep them. Sign-in belongs to a session-time step.

Versions live in `pins.env`; a weekly workflow (`scripts/bump-pins.sh`) opens a PR to refresh them.

## Adding a module
Add `modules/<name>.sh`. Its first line is `# <name> — <one-line description>` (shown by
`--list`); it defines `setup()` (install; return non-zero on failure) and optionally `status()`
(one line of versions) and `requires="other-module …"`. Modules run in their own process with
`lib/common.sh` loaded, which provides `apt_install`, `link <name> <target>` (into `$BIN`), `ver`,
and `$BIN`, `$OPT`, `$SHARE`, `$REPO`, `$SUDO`. Keep `setup()` idempotent: it also runs when a
session repairs a snapshot. Run `bash tests/run.sh` and `shellcheck -x` before opening a PR.

## How updates land
Sandboxes rebuild their snapshot when the setup-script text or network settings change, or after
about a week. A change merged here reaches each sandbox at its next rebuild.

## License
MIT, see `LICENSE`.
