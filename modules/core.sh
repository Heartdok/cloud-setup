# core — always installed: apt basics, gh, jq, git-lfs, uv, Bun (the only JS package manager: npm/npx
# are shimmed to bun), Node runtime (if missing or < 20), pandoc, 1Password CLI (install only), and
# a user-level SessionStart hook that runs a project's scripts/cloud/session-start.sh.
# Without root or passwordless sudo, gh, jq, git-lfs and pandoc are pinned release binaries in
# $BIN/$OPT (~/.local) instead, and missing system packages are left to the image and named once.
# With a read-only HOME (Codex Cloud) $BIN/$OPT are the writable prefix (lib/common.sh), installers
# that write to ~ get a scratch HOME there, and the SessionStart hook is skipped with a note.
# shellcheck shell=bash

setup() {
  local rc=0
  core_packages || rc=1
  core_node || rc=1
  core_uv || rc=1
  core_bun || rc=1
  core_no_npm || rc=1
  core_pandoc || rc=1
  core_op || rc=1
  core_session_hook || rc=1
  return $rc
}

CORE_APT="ca-certificates curl unzip xz-utils gnupg jq git git-lfs gh fontconfig"

# As root or with passwordless sudo: apt. Without either (Codex Cloud builds as a plain user with
# no sudo binary): gh, jq and git-lfs as pinned release binaries; the system packages that have no
# sane user-space install are the image's business, named once when missing and not a failure.
core_packages() {
  # shellcheck disable=SC2086 # a word list
  if can_root; then apt_install $CORE_APT; return; fi
  local rc=0 p c missing=()
  core_jq || rc=1
  core_gh || rc=1
  core_git_lfs || rc=1
  for p in ca-certificates:/etc/ssl/certs/ca-certificates.crt curl:curl unzip:unzip xz-utils:xz \
           gnupg:gpg git:git fontconfig:fc-cache; do
    c="${p#*:}"; p="${p%%:*}"
    apt_installed "$p" || command -v "$c" >/dev/null 2>&1 || [ -e "$c" ] || missing+=("$p")
  done
  [ ${#missing[@]} -eq 0 ] \
    || echo "core: no root or passwordless sudo; system packages left to the image, missing: ${missing[*]}"
  return $rc
}

core_arch() { case "$(uname -m)" in x86_64) echo amd64 ;; aarch64|arm64) echo arm64 ;; *) return 1 ;; esac; }
sha256_of() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }

# A copy the image already has is kept; ours (in $BIN) must match its pin.
core_have() { # command pin
  local p; p="$(command -v "$1" 2>/dev/null)" || return 1
  case "$p" in "$BIN"/*) [ "$(ver "$1" --version)" = "$2" ] ;; esac
}

# A pinned release asset into <out>, refused unless the sha256 list the release publishes vouches
# for it (no list given: HTTPS only, as with the .deb it replaces).
core_fetch() { # url sums-url out
  local name="${1##*/}" want
  curl -fsSL --retry 2 --max-time 300 -o "$3" "$1" || { echo "core: download failed: $1" >&2; return 1; }
  [ -n "$2" ] || return 0
  want="$(curl -fsSL --retry 2 --max-time 60 "$2" | awk -v f="$name" '{n = $2; sub(/^\*/, "", n)} n == f {print $1; exit}')"
  [ -n "$want" ] && [ "$want" = "$(sha256_of "$3")" ] && return 0
  echo "core: REFUSING $name — its sha256 is not in $2" >&2; return 1
}

# A pinned release tarball unpacked whole to $OPT/<dir>, one binary in it linked into $BIN.
core_tarball() { # url sums-url dir binary-in-dir name
  local tmp rc; tmp="$(mktemp -d)"
  core_fetch "$1" "$2" "$tmp/a.tgz" && tar -xzf "$tmp/a.tgz" -C "$tmp" && [ -x "$tmp/$3/$4" ] \
    && rm -rf "${OPT:?}/$3" && mv "$tmp/$3" "$OPT/$3" && link "$5" "$OPT/$3/$4"
  rc=$?; rm -rf "$tmp"; hash -r; return $rc
}

core_jq() {
  core_ok_jq && return 0
  local arch tmp rc base="https://github.com/jqlang/jq/releases/download/jq-${JQ_PIN}"
  arch="$(core_arch)" || return 1; tmp="$(mktemp -d)"
  core_fetch "$base/jq-linux-$arch" "$base/sha256sum.txt" "$tmp/jq" && install -m 755 "$tmp/jq" "$BIN/jq"
  rc=$?; rm -rf "$tmp"; hash -r; [ $rc = 0 ] && [ "$(ver jq --version)" = "$JQ_PIN" ]
}

core_gh() {
  core_ok_gh && return 0
  local arch base="https://github.com/cli/cli/releases/download/v${GH_PIN}"
  arch="$(core_arch)" || return 1
  core_tarball "$base/gh_${GH_PIN}_linux_$arch.tar.gz" "$base/gh_${GH_PIN}_checksums.txt" \
    "gh_${GH_PIN}_linux_$arch" bin/gh gh && [ "$(ver gh --version)" = "$GH_PIN" ]
}

core_git_lfs() { # sha256sums.asc is clearsigned; its hash lines are read, the signature is not checked
  core_ok_git_lfs && return 0
  local arch base="https://github.com/git-lfs/git-lfs/releases/download/v${GIT_LFS_PIN}"
  arch="$(core_arch)" || return 1
  core_tarball "$base/git-lfs-linux-$arch-v${GIT_LFS_PIN}.tar.gz" "$base/sha256sums.asc" \
    "git-lfs-${GIT_LFS_PIN}" git-lfs git-lfs && [ "$(ver git-lfs --version)" = "$GIT_LFS_PIN" ]
}

# Reconcile (setup.sh --reconcile, a cached container's per-task step): each pinned piece's check is
# the one its installer starts with, so the two cannot disagree. jq, gh and git-lfs are pinned only
# without root (as root they are apt's); node is not pinned (an image's own >= 20 is kept).
core_ok_uv() { [ "$(ver uv --version)" = "$UV_PIN" ]; }
core_ok_bun() { [ "$(bun --version 2>/dev/null)" = "$BUN_PIN" ]; }
core_ok_pandoc() { [ "$(ver pandoc --version)" = "$PANDOC_PIN" ]; }
core_ok_op() { [ "$(op --version 2>/dev/null)" = "$OP_CLI_PIN" ]; }
core_ok_jq() { core_have jq "$JQ_PIN"; }
core_ok_gh() { core_have gh "$GH_PIN"; }
core_ok_git_lfs() { core_have git-lfs "$GIT_LFS_PIN"; }
core_pinned() { echo uv bun pandoc op; can_root || echo jq gh git_lfs; }
CORE_MIRRORED="uv uvx bun bunx npm npx node op gh jq git-lfs pandoc"
drift() { # → the pieces that are not at their pin, one per line; nothing when all are
  local p
  for p in $(core_pinned); do "core_ok_$p" || echo "$p"; done
  [ -z "$(mirror_stale $CORE_MIRRORED)" ] || echo mirror   # word list
}
reconcile() { # piece...: reinstall those, then refresh the ~/.local/bin mirror
  local p rc=0
  for p in "$@"; do [ "$p" = mirror ] || "core_$p" || rc=1; done
  mirror_bin $CORE_MIRRORED   # word list
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
  if [ "$RO_HOME" = 1 ]; then # Codex Cloud: no Claude Code there, and ~/.claude cannot be written
    echo "core: HOME is read-only; user-level Claude Code SessionStart hook skipped"; return 0
  fi
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
  core_ok_uv && { mirror_bin uv uvx; return 0; }
  curl -LsSf "https://astral.sh/uv/${UV_PIN}/install.sh" | in_ihome env UV_INSTALL_DIR="$BIN" UV_NO_MODIFY_PATH=1 sh
  hash -r; mirror_bin uv uvx; core_ok_uv
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
  mirror_bin npm npx
}

core_bun() {
  core_ok_bun && { mirror_bin bun bunx; return 0; }
  curl -fsSL https://bun.sh/install | in_ihome env BUN_INSTALL="$OPT/bun" bash -s -- "bun-v${BUN_PIN}" \
    && link bun "$OPT/bun/bin/bun" && link bunx "$OPT/bun/bin/bun"
  hash -r; core_ok_bun
}

core_pandoc() {
  core_ok_pandoc && return 0
  local arch deb
  arch="$(core_arch)" || return 1
  if ! can_root; then # the same release's static tarball (it publishes no checksum list)
    core_tarball "https://github.com/jgm/pandoc/releases/download/${PANDOC_PIN}/pandoc-${PANDOC_PIN}-linux-$arch.tar.gz" "" \
      "pandoc-${PANDOC_PIN}" bin/pandoc pandoc && [ "$(ver pandoc --version)" = "$PANDOC_PIN" ]
    return
  fi
  deb="$(mktemp --suffix=.deb)"
  curl -fsSL -o "$deb" "https://github.com/jgm/pandoc/releases/download/${PANDOC_PIN}/pandoc-${PANDOC_PIN}-1-$arch.deb" \
    && $SUDO dpkg -i "$deb"; local rc=$?; rm -f "$deb"; return $rc
}

# 1Password's signed zip, verified against its release key when the key can be fetched.
core_op() {
  core_ok_op && return 0
  local key=3FEF9748469ADBE15DA7CA80AC2D62742012EA22 arch tmp
  arch="$(core_arch)" || return 1
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
  core_ok_op
}
