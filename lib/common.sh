# Shared helpers, sourced by setup.sh and by every module step. Also a library for a session-time
# layer built on top: it can source this file and override module_exists / known_modules /
# run_module to add its own per-module steps.
# shellcheck shell=bash
set +x

export CLOUD_SETUP_HOME="${CLOUD_SETUP_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=../pins.env
. "$CLOUD_SETUP_HOME/pins.env"

# A repo's own Bun pin wins over pins.env: .bun-version, else package.json "packageManager": "bun@X".
repo_pins() {
  [ -n "${REPO:-}" ] || return 0
  local rb
  rb="$( { tr -d '[:space:]' < "$REPO/.bun-version"; } 2>/dev/null)"
  [ -n "$rb" ] || rb="$(sed -n 's/.*"packageManager"[[:space:]]*:[[:space:]]*"bun@\([0-9][0-9.]*\)".*/\1/p' "$REPO/package.json" 2>/dev/null | head -1)"
  # shellcheck disable=SC2034 # read by modules/core.sh
  [ -z "$rb" ] || BUN_PIN="${rb#v}"
}
repo_pins

export DEBIAN_FRONTEND=noninteractive
export PATH="/usr/local/bin:$HOME/.local/bin:$HOME/.bun/bin:$PATH"

if [ "$(id -u)" = 0 ]; then BIN=/usr/local/bin; OPT=/opt; else BIN="$HOME/.local/bin"; OPT="$HOME/.local/opt"; fi
SHARE="${CLOUD_ENV_SHARE:-$HOME/.local/share/cloud-env}"
mkdir -p "$BIN" "$OPT" "$SHARE"

link() { ln -sfn "$2" "$BIN/$1"; } # name target

SUDO=""; [ "$(id -u)" = 0 ] || SUDO="sudo -n" # some sandboxes build as a sudo-capable user
apt_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'; }
apt_update() { # once per setup run (APT_STAMP, shared across steps), else once per shell
  if [ -n "${APT_STAMP:-}" ]; then [ -f "$APT_STAMP" ] && return 0
  else [ -n "${_APT_UPDATED:-}" ] && return 0; fi
  $SUDO apt-get update -qq || return 1
  _APT_UPDATED=1; [ -z "${APT_STAMP:-}" ] || touch "$APT_STAMP"
}
apt_stale() { _APT_UPDATED=""; [ -z "${APT_STAMP:-}" ] || rm -f "$APT_STAMP"; } # after adding a source
apt_install() { # packages...: quiet, idempotent; no apt-get at all when everything is installed
  [ -z "$SUDO" ] || $SUDO true 2>/dev/null || { echo "apt_install needs root or passwordless sudo: $*" >&2; return 1; }
  local p missing=()
  for p in "$@"; do apt_installed "$p" || missing+=("$p"); done
  [ ${#missing[@]} -eq 0 ] && return 0
  apt_update && $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "${missing[@]}"
}

ver() { "$@" 2>/dev/null | head -1 | grep -Eo '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1; }

# The project repo: the first candidate holding scripts/cloud/manifest, else the first git repo,
# else $PWD. Candidates: the git toplevel of $PWD, $PWD, then every directory matching
# CLOUD_SETUP_ROOTS (default "/home/*/* /root/*": where sandboxes clone projects).
discover_repo() {
  local d top first="" roots="${CLOUD_SETUP_ROOTS:-/home/*/* /root/*}"
  local -a cands=()
  top="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null)" && cands+=("$top")
  cands+=("$PWD")
  # shellcheck disable=SC2206 # the roots are globs
  cands+=($roots)
  for d in "${cands[@]}"; do
    [ -d "$d" ] || continue
    [ -f "$d/scripts/cloud/manifest" ] && { echo "$d"; return 0; }
    [ -z "$first" ] && [ -e "$d/.git" ] && first="$d"
  done
  echo "${first:-$PWD}"
}

# Module registry: every modules/<name>.sh is a module; there is no other list.
module_exists() { [ -f "$CLOUD_SETUP_HOME/modules/$1.sh" ]; }
known_modules() { (cd "$CLOUD_SETUP_HOME/modules" && ls ./*.sh) | sed 's|^\./||; s|\.sh$||' | grep -vx core | sort; }
module_description() { sed -n '1s/^# [a-z0-9-]* — //p' "$CLOUD_SETUP_HOME/modules/$1.sh" 2>/dev/null; }
requires_of() { sed -n 's/^requires="\(.*\)"/\1/p' "$CLOUD_SETUP_HOME/modules/$1.sh" 2>/dev/null; }

# Manifest: whitespace/newline separated module names, '#' comments.
read_manifest() { [ -f "$1" ] && sed 's/#.*//' "$1" | tr -s ' \t' '\n' | grep -v '^$' | sort -u; }

validate_manifest() { # file → prints unknown names; returns 1 if any
  local bad; bad="$(comm -23 <(read_manifest "$1") <(known_modules))"
  [ -z "$bad" ] && return 0
  echo "$bad"; return 1
}

resolve_modules() { # manifest → core, then requested modules with their requirements first
  local m r
  echo core
  read_manifest "$1" | while read -r m; do
    module_exists "$m" || continue
    for r in $(requires_of "$m"); do echo "$r"; done; echo "$m"
  done | awk '!seen[$0]++'
}

run_module() { # phase name: source modules/<name>.sh in a subshell, call <phase>() if defined
  ( # shellcheck disable=SC1090
    . "$CLOUD_SETUP_HOME/modules/$2.sh"
    if declare -F "$1" >/dev/null; then "$1"; else exit 0; fi )
}
