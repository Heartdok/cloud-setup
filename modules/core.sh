# core — always installed: apt basics, gh, jq, git-lfs, uv, Bun (the only JS package manager: npm/npx
# are shimmed to bun), Node runtime (if missing or < 20), pandoc, 1Password CLI (install only), and
# a user-level SessionStart hook that runs a project's scripts/cloud/session-start.sh.
# shellcheck shell=bash

setup() {
  local rc=0
  apt_install ca-certificates curl unzip xz-utils gnupg jq git git-lfs gh fontconfig || rc=1
  core_node || rc=1
  core_uv || rc=1
  core_bun || rc=1
  core_no_npm || rc=1
  core_pandoc || rc=1
  core_op || rc=1
  core_session_hook || rc=1
  return $rc
}

status() { echo "node=$(ver node --version) uv=$(ver uv --version) bun=$(ver bun --version) pandoc=$(ver pandoc --version) op=$(ver op --version) gh=$(ver gh --version)"; }

# Claude Code cloud threads may start outside any one project (every repo cloned side by side), so
# a project's own SessionStart hook can go unloaded. This user-level hook runs the project's
# scripts/cloud/session-start.sh instead: in Claude Code remote sessions only, and not when the
# project's settings already run it. Tagged so reruns replace it rather than add another.
CORE_SESSION_HOOK='[ "${CLAUDE_CODE_REMOTE:-}" = true ] || exit 0; p="${CLAUDE_PROJECT_DIR:-$PWD}"; grep -qs scripts/cloud/session-start.sh "$p/.claude/settings.json" && exit 0; for d in "$p" /home/*/* /root/*; do [ -f "$d/scripts/cloud/session-start.sh" ] && { bash "$d/scripts/cloud/session-start.sh"; break; }; done; true # cloud-setup'
core_session_hook() {
  local s="$HOME/.claude/settings.json"
  mkdir -p "$HOME/.claude"; [ -s "$s" ] || echo '{}' > "$s"
  jq --arg c "$CORE_SESSION_HOOK" '
    .hooks.SessionStart = ([.hooks.SessionStart // [] | .[]
                            | select([.hooks[]?.command] | any(endswith("# cloud-setup")) | not)]
                           + [{matcher: "startup|resume|clear|compact",
                               hooks: [{type: "command", command: $c, timeout: 300}]}])' \
    "$s" > "$s.new" || { rm -f "$s.new"; return 1; }
  if cmp -s "$s" "$s.new"; then rm -f "$s.new"; else mv "$s.new" "$s"; fi
}

core_uv() {
  [ "$(ver uv --version)" = "$UV_PIN" ] && return 0
  curl -LsSf "https://astral.sh/uv/${UV_PIN}/install.sh" | env UV_INSTALL_DIR="$BIN" UV_NO_MODIFY_PATH=1 sh
  hash -r; [ "$(ver uv --version)" = "$UV_PIN" ]
}

core_node() { # keep an image's own Node >= 20; otherwise the pinned LTS tarball
  local have; have="$(node --version 2>/dev/null | sed 's/^v//; s/\..*//')"
  [ "${have:-0}" -ge 20 ] && return 0
  local arch; case "$(uname -m)" in x86_64) arch=x64 ;; aarch64|arm64) arch=arm64 ;; *) return 1 ;; esac
  local dir="$OPT/node-v${NODE_PIN}-linux-$arch"
  [ -x "$dir/bin/node" ] || curl -fsSL "https://nodejs.org/dist/v${NODE_PIN}/node-v${NODE_PIN}-linux-$arch.tar.xz" | tar -xJ -C "$OPT" || return 1
  link node "$dir/bin/node"   # runtime only (wrangler, codex); packages go through bun
  hash -r; node --version >/dev/null
}

# Bun only: `npx` runs bunx; `npm` refuses with the bun equivalent (shadows any image npm).
core_no_npm() {
  printf '#!/bin/sh\nexec bunx "$@"\n' | install -m 755 /dev/stdin "$BIN/npx"
  install -m 755 /dev/stdin "$BIN/npm" <<'SH'
#!/bin/sh
case "$1" in
  i|install|add) hint="bun add / bun install" ;; ci) hint="bun install --frozen-lockfile" ;;
  run|run-script) hint="bun run" ;; exec|x) hint="bunx" ;; *) hint="bun $*" ;;
esac
echo "npm is disabled in this environment (Bun only). Use: $hint" >&2; exit 1
SH
}

core_bun() {
  [ "$(bun --version 2>/dev/null)" = "$BUN_PIN" ] && return 0
  curl -fsSL https://bun.sh/install | env BUN_INSTALL="$OPT/bun" bash -s -- "bun-v${BUN_PIN}" \
    && link bun "$OPT/bun/bin/bun" && link bunx "$OPT/bun/bin/bun"
  hash -r; [ "$(bun --version)" = "$BUN_PIN" ]
}

core_pandoc() {
  [ "$(ver pandoc --version)" = "$PANDOC_PIN" ] && return 0
  local arch deb
  case "$(uname -m)" in x86_64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; *) return 1 ;; esac
  deb="$(mktemp --suffix=.deb)"
  curl -fsSL -o "$deb" "https://github.com/jgm/pandoc/releases/download/${PANDOC_PIN}/pandoc-${PANDOC_PIN}-1-$arch.deb" \
    && $SUDO dpkg -i "$deb"; local rc=$?; rm -f "$deb"; return $rc
}

# 1Password's signed zip, verified against its release key when the key can be fetched.
core_op() {
  [ "$(op --version 2>/dev/null)" = "$OP_CLI_PIN" ] && return 0
  local key=3FEF9748469ADBE15DA7CA80AC2D62742012EA22 arch tmp
  case "$(uname -m)" in x86_64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; *) return 1 ;; esac
  tmp="$(mktemp -d)"
  curl -fsSL --max-time 120 -o "$tmp/op.zip" \
    "https://cache.agilebits.com/dist/1P/op2/pkg/v${OP_CLI_PIN}/op_linux_${arch}_v${OP_CLI_PIN}.zip" \
    && (cd "$tmp" && unzip -q op.zip) || { rm -rf "$tmp"; return 1; }
  export GNUPGHOME="$tmp/gnupg"; mkdir -m 700 "$GNUPGHOME"
  gpg --batch --quiet --keyserver hkps://keyserver.ubuntu.com --recv-keys "$key" >/dev/null 2>&1 || true
  if gpg --batch --list-keys "$key" >/dev/null 2>&1 && ! gpg --batch --quiet --verify "$tmp/op.sig" "$tmp/op" >/dev/null 2>&1; then
    echo "core: REFUSING op — signature does not verify" >&2; rm -rf "$tmp"; return 1
  fi
  install -m 755 "$tmp/op" "$SHARE/op" && link op "$SHARE/op"; rm -rf "$tmp"; unset GNUPGHOME
  [ "$(op --version)" = "$OP_CLI_PIN" ]
}
