# agy — Google's Antigravity CLI (`agy`, latest; it updates itself), installed only: the session layer pulls its login
# Its installer checks the release's sha512 against the vendor's manifest, writes ~/.local/bin/agy
# (under IHOME when ~ is read-only) and leaves a present one alone.
# shellcheck shell=bash

setup() {
  local real="$IHOME/.local/bin/agy"
  if [ ! -x "$real" ]; then
    in_ihome timeout "${AGY_TIMEOUT:-120}" bash -c 'curl -fsSL https://antigravity.google/cli/install.sh | bash' >/dev/null || return 1
    [ -x "$real" ] || return 1
  fi
  [ "$BIN" = "$IHOME/.local/bin" ] || link agy "$real"
}

drift() { [ -z "$(mirror_stale agy)" ] || echo mirror; }
reconcile() { mirror_bin agy; }

status() { command -v agy >/dev/null || { echo agy=missing; return; }; local x; x="$(ver agy --version)"; echo "agy=${x:-ok}"; }
