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

Non-root without sudo (Codex Cloud) is supported for `core`: gh, jq, git-lfs and pandoc install as
pinned user-space binaries in `~/.local`, and a module that needs apt fails by name.

**Read-only HOME** (Codex Cloud's setup: the root filesystem and `/home/agent` are read-only, only
`/workspace` and `/tmp` are writable, and only `/workspace` reaches the snapshot): everything that
would go under `~` goes under one writable prefix instead, `$CLOUD_SETUP_PREFIX`, else
`/workspace/.cloud` (`CLOUD_SETUP_WORKSPACE` moves `/workspace`, for tests), else `$TMPDIR/.cloud`.
It holds `bin/`, `opt/`, `share/cloud-setup/` (this repo), `share/cloud-env/` (the result files below),
and `env`, which records the prefix: `. /workspace/.cloud/env` puts its `bin` on PATH. Installers
that write to `~` (Bun's, uv's, Grok's, Cursor's) get `<prefix>/home` as their HOME; core skips the
user-level SessionStart hook with a note; the summary line ends with `prefix=<dir>`. This applies
only when `$HOME` exists and is not writable: with a writable HOME (Claude Code as root, Cursor as
a user) every path, hook and output line is what it was before, and the tests check that.

**Root with a writable HOME** (Claude Code; Codex Cloud's older universal image, user `root`): tools
go to `/usr/local/bin`, but an image can put its own Bun or `gh` on a PATH ahead of it, while
`~/.local/bin` is the directory an agent puts first (`export PATH=$HOME/.local/bin:$PATH`). So every
command core links or wraps is also a symlink in `~/.local/bin` pointing at the `/usr/local/bin`
file (`mirror_bin` in `lib/common.sh`); a real file already there is left alone. A plain user's
`BIN` already is `~/.local/bin`, and with a read-only HOME nothing changes.

From a checkout: `bash setup.sh [--repo DIR] [--no-local] [--reconcile] [--list]` (`--no-local` also
skips the session-layer hand-off below; `--reconcile` is the next section).

## Cached containers: `--reconcile`
A platform that caches the container after setup keeps the tool versions it had then: a pin bumped
here, or a repo's `.bun-version` changed on a branch, does not apply until the cache is rebuilt. Where
the platform runs a step before each task on the cached container, put this line there:

```bash
curl -fsSL https://raw.githubusercontent.com/Heartdok/cloud-setup/main/setup.sh | bash -s -- --reconcile || true
```

It fetches this repo (the copy on disk is left untouched when the commit is the same), resolves every
pin as an install does (the repo's `.bun-version`, then `package.json` `packageManager`, then
`pins.env`), and asks each module in the manifests what is off its pin. Only those pieces are
reinstalled; then the `~/.local/bin` mirror is refreshed, `setup-result` is rewritten (the install's
own errors kept, a failed reinstall added as `reconcile failed: <module>`), and the run is appended
to `setup.log` as `cloud-setup reconcile: …`. **With nothing off its pin it takes about a second and
writes nothing.** It exits 0 always, and leaves a missing or cut-off `setup-result` alone for a
session-time repair.

Reconciled: `core` (uv, Bun, pandoc, `op`; `jq`, `gh`, `git-lfs` where they are pinned, i.e. without
root; the mirror), `agent-clis` (Codex), `blender`, `blender-mcp` (its git ref). Not reconciled:
what is not pinned (Node ≥ 20 from the image, Grok/Cursor/Gemini/wrangler at latest, apt packages)
and a repo's own dependencies (`node`, `python`, `rust` toolchains), which are the repo's to refresh.

Per platform (from their docs, 2026-10-17):

| Platform | Before each task on a cached container | Use |
|---|---|---|
| Codex Cloud (legacy environments) | **Maintenance script**: runs when a cached container is resumed, after the task's branch is checked out. The cache lasts up to 12 hours and is rebuilt when the setup script, maintenance script, environment variables or secrets change. ([docs](https://learn.chatgpt.com/docs/environments/cloud-environment)) | The line above. Setting it rebuilds the cache once. |
| Codex Cloud (current environments) | No maintenance field: an Install script and a Start skill; the prepared filesystem is rebuilt by **Republish**. ([docs](https://learn.chatgpt.com/docs/environments/cloud-environments)) | Nothing to wire; republish after a pin change. |
| Claude Code on the web | No maintenance field. The setup snapshot is rebuilt when the setup script or allowed hosts change, or after about seven days; a **SessionStart hook** runs on every session start and resume. ([docs](https://code.claude.com/docs/en/cloud-environments)) | Optional: a SessionStart hook (e.g. the session layer's) can run `bash "$CLOUD_SETUP_HOME/setup.sh" --reconcile`. |
| Cursor Cloud agents | `install` runs only when a Build is made; after an agent boots from a Build, **`start`** runs. ([docs](https://cursor.com/docs/cloud-agent/setup)) | Optional: `start` in `environment.json` can run the line above. |

## What it guarantees
- **Exit 0, always.** A failed step is recorded, never fatal: a non-zero setup script would stop
  the sandbox from starting.
- **A time budget.** Platforms stop caching a setup that runs for about five minutes, so steps share
  `CLOUD_SETUP_BUDGET` seconds (default 240). A step that overruns is killed, later ones are skipped,
  and the result says which.
- **A result you can read later**, in `$HOME/.local/share/cloud-env/` (`<prefix>/share/cloud-env/`
  with a read-only HOME):
  - `setup-result`: `running: <step> (since T)` while running, then `base=<commit>`, followed by
    ` ERROR=<…>` if anything went wrong (unknown modules, failed or skipped steps, no manifest).
  - `setup.log`: everything the steps printed.

  A file that is missing or still says `running:` tells a session that the build-time setup did not
  run or was cut off, so a session-time layer can repair what is missing.

## Finding the project
Every candidate that contains `scripts/cloud/manifest` is a project: the git toplevel of the current
directory, the current directory, the toplevel's sibling directories and the current directory's
children (multi-repo sandboxes such as Codex Cloud clone side by side under an undocumented root),
then each directory matching `/workspace/*`, `/agent/repos/*` (Cursor Cloud), `/home/*/*` and `/root/*` (override with
`CLOUD_SETUP_ROOTS`). A sandbox that clones several repos side by side gets the union of their
manifests, and each repo's `setup.local.sh` runs (steps `local:<repo>`); per-repo modules (`node`,
`python`, `rust`) act on the repos that list them, and the first repo that pins Bun sets its version.
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
| `rust` | a user-space Rust toolchain from our own rustup (never the image's): each repo's `rust-toolchain[.toml]` pin, else stable minimal. In `~/.cargo` + `~/.rustup`, or `<prefix>/opt/{cargo,rustup}` with a read-only HOME; wrappers for `cargo`, `rustc`, `rustup`, `rustfmt`, `cargo-clippy`, `clippy-driver`, `rustdoc` in the bin dir set `RUSTUP_HOME`/`CARGO_HOME`, so `<prefix>/bin` on `PATH` is enough |
| `tailscale` | the Tailscale client, installed only |

Nothing here signs in to anything or reads a secret: credentials don't exist yet when a setup script
runs, and the snapshot would keep them. Sign-in belongs to a session-time step.

## Session-layer hand-off
A private session layer (secrets, sign-ins) cannot live in this public repo, and some platforms run
nothing when a task starts (Codex Cloud). So when **1Password Connect is configured**
(`OP_CONNECT_HOST` and `OP_CONNECT_TOKEN` set while the setup script runs) and a repo has
`scripts/cloud/env-setup.sh`, the installer runs, after the modules:

1. `bash <repo>/scripts/cloud/env-setup.sh --fetch-only`: the repo's stub fetches the layer and
   records `<how> <dir>` in `~/.cloud-env.source` (read-only HOME: `<prefix>/share/cloud-env/source`,
   with the prefix passed as `CLOUD_SETUP_PREFIX`);
2. `bash <dir>/install-time.sh --repo <repo>…`: the layer installs what needs no secret.

This repo never reads a secret; the stub reads what it needs in memory, and the snapshot keeps none.
Without Connect, or with `--no-local`, it does nothing. A failure is named in `setup-result`
(`session layer: …`) and is not a failed step. The private parts stay in
[Heartdok/cloud-env](https://github.com/Heartdok/cloud-env).

Versions live in `pins.env`; a weekly workflow (`scripts/bump-pins.sh`) opens a PR to refresh them.

## Adding a module
Add `modules/<name>.sh`. Its first line is `# <name> — <one-line description>` (shown by
`--list`); it defines `setup()` (install; return non-zero on failure) and optionally `status()`
(one line of versions), `requires="other-module …"`, and, for what it pins, `drift()` (print the
pieces off their pin, one per line, nothing when all are right; fast, and it writes nothing) with
`reconcile <piece>…` (reinstall those; reuse the check `setup()` starts with so the two agree). Modules run in their own process with
`lib/common.sh` loaded, which provides `apt_install`, `link <name> <target>` (into `$BIN`), `ver`,
`can_root`, and `$BIN`, `$OPT`, `$SHARE`, `$REPO`, `$SUDO` (empty as root, `sudo -n` with
passwordless sudo, else a stub that fails saying so). A vendor installer that writes to `~` runs
under `in_ihome` and finds its files under `$IHOME` (HOME, or `<prefix>/home` when HOME is
read-only). Keep `setup()` idempotent: it also runs when
a session repairs a snapshot. Run `bash tests/run.sh` and `shellcheck -x` before opening a PR.

## How updates land
Sandboxes rebuild their snapshot when the setup-script text or network settings change, or after
about a week. A change merged here reaches each sandbox at its next rebuild, or at its next task
where `--reconcile` runs before each one (above).

## License
MIT, see `LICENSE`.
