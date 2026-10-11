# agent-clis — coding-agent CLIs, installed only (no sign-in): Codex (CODEX_PIN), Grok, Cursor Agent (`cursor-agent`), Gemini CLI
# Codex comes from the npm registry via bun (its native binary linked), Grok and Cursor from their
# vendors' installers, Gemini from the npm registry via bun. Signing in is left to the session.
# shellcheck shell=bash

setup() {
  local rc=0
  agent_codex || rc=1
  agent_grok || rc=1
  agent_cursor || rc=1
  agent_gemini || rc=1
  return $rc
}

status() { echo "codex=$(_agent_v codex) grok=$(_agent_v grok) cursor=$(_agent_v cursor-agent) gemini=$(_agent_v gemini)"; }
_agent_v() { command -v "$1" >/dev/null || { echo missing; return; }; local x; x="$(ver "$1" --version)"; echo "${x:-ok}"; }

# Each installer gets at most AGENT_CLIS_TIMEOUT seconds (default 240).
_agent_cap() { if command -v timeout >/dev/null; then timeout "${AGENT_CLIS_TIMEOUT:-240}" "$@"; else "$@"; fi; }

_codex_real() { find "$1/node_modules/@openai" -path '*/vendor/*/bin/codex' -type f 2>/dev/null | head -1; }
agent_codex() {
  local dir="$SHARE/codex" real
  real="$(_codex_real "$dir")"
  if [ -z "$real" ] || [ "$("$real" --version 2>/dev/null)" != "codex-cli $CODEX_PIN" ]; then
    command -v bun >/dev/null 2>&1 || return 1
    rm -rf "$dir" && mkdir -p "$dir" && printf '{"private":true}\n' > "$dir/package.json"
    (cd "$dir" && _agent_cap bun add "@openai/codex@$CODEX_PIN" >/dev/null 2>&1) || return 1
    real="$(_codex_real "$dir")"
    [ -n "$real" ] || return 1
  fi
  link codex "$real"
}

# The installer puts the binary in ~/.grok/bin (under IHOME, the prefix's scratch home, when ~ is
# read-only). A `grok` already on $BIN (e.g. a wrapper written by a session layer) is left alone.
agent_grok() {
  local real="$IHOME/.grok/bin/grok"
  if [ ! -x "$real" ]; then
    in_ihome _agent_cap bash -c 'curl -fsSL https://x.ai/cli/install.sh | bash' >/dev/null 2>&1 || return 1
    [ -x "$real" ] || return 1
  fi
  [ -e "$BIN/grok" ] || link grok "$real"
}

# Cursor's installer links `agent` and `cursor-agent` into ~/.local/bin. Grok's installer also
# claims `agent`, so the unambiguous name everywhere here is `cursor-agent`.
agent_cursor() {
  [ -x "$IHOME/.local/bin/cursor-agent" ] || in_ihome _agent_cap bash -c 'curl -fsS https://cursor.com/install | bash' >/dev/null || return 1
  [ -x "$IHOME/.local/bin/cursor-agent" ] || return 1
  [ "$BIN" = "$IHOME/.local/bin" ] || link cursor-agent "$IHOME/.local/bin/cursor-agent"
}

agent_gemini() {
  local dir="$SHARE/gemini"
  mkdir -p "$dir" && { [ -f "$dir/package.json" ] || printf '{"private":true}\n' > "$dir/package.json"; }
  (cd "$dir" && _agent_cap bun add @google/gemini-cli@latest >/dev/null) && link gemini "$dir/node_modules/.bin/gemini"
}
