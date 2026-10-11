#!/usr/bin/env bash
# cloud-setup: a developer toolchain installer for cloud sandboxes, meant for the "setup script"
# step that runs as root before the agent starts and whose filesystem is then snapshotted.
#
#   curl -fsSL https://raw.githubusercontent.com/Heartdok/cloud-setup/main/setup.sh | bash || true
#
#   bash setup.sh [--repo DIR]   # core + the modules in DIR/scripts/cloud/manifest + its setup.local.sh;
#                                # repeatable. Without it: every cloned repo that has a manifest
#                 [--no-local]   # skip the repo's scripts/cloud/setup.local.sh and the session-layer hand-off
#                 [--fetch-only] # only download this repo to its home (below), install nothing
#                 [--list]       # known modules
#
# Piped from curl, it first downloads itself (a tarball, anonymously) to CLOUD_SETUP_HOME
# (/opt/cloud-setup as root, else ~/.local/share/cloud-setup) and runs that copy, so the modules
# and libraries are on disk and stay in the snapshot.
#
# Read-only HOME (Codex Cloud's setup: only /workspace and /tmp are writable): everything that
# would go under ~ goes under one writable prefix instead, $CLOUD_SETUP_PREFIX, else
# /workspace/.cloud (bin/, opt/, share/cloud-setup, share/cloud-env/), recorded in <prefix>/env and
# named as prefix=<dir> in the summary line. A writable HOME (Claude Code, Cursor) changes nothing.
#
# Contract: it ALWAYS exits 0 (a failing setup script fails the whole sandbox), and it stops
# starting new steps once CLOUD_SETUP_BUDGET seconds (default 240) are spent, killing a step that
# overruns, because platforms stop caching a setup that takes about five minutes. Progress:
#   $HOME/.local/share/cloud-env/setup-result   "running: <step> (since T)" while running, then
#                                               "base=<sha>[ ERROR=<what went wrong>]"
#   $HOME/.local/share/cloud-env/setup.log      everything the steps printed
# (CLOUD_SETUP_RESULT / CLOUD_SETUP_LOG override the two paths; <prefix>/share/cloud-env/ with a
# read-only HOME.)
#
# Session-layer hand-off: with 1Password Connect configured (OP_CONNECT_HOST + OP_CONNECT_TOKEN in
# the environment) and a repo that has scripts/cloud/env-setup.sh, that stub fetches the private
# session layer (--fetch-only) and the layer's install-time.sh runs. See handoff() below.
set -uo pipefail
set +x

SLUG="${CLOUD_SETUP_SLUG:-Heartdok/cloud-setup}"
REF="${CLOUD_SETUP_REF:-main}"

# lib/common.sh cloud_prefix, repeated for the bootstrap (no library yet): the writable prefix when
# HOME is read-only; fails when HOME is writable, and then nothing below changes.
ro_prefix() {
  [ -n "${HOME:-}" ] && [ -d "$HOME" ] && ! [ -w "$HOME" ] || return 1 # an existing, unwritable HOME only
  if [ -n "${CLOUD_SETUP_PREFIX:-}" ]; then echo "$CLOUD_SETUP_PREFIX"; return 0; fi
  local w="${CLOUD_SETUP_WORKSPACE:-/workspace}"
  if [ -d "$w" ] && [ -w "$w" ]; then echo "$w/.cloud"; else echo "${TMPDIR:-/tmp}/.cloud"; fi
}
default_home() {
  local p
  if p="$(ro_prefix)"; then echo "$p/share/cloud-setup"
  elif [ "$(id -u)" = 0 ]; then echo /opt/cloud-setup; else echo "$HOME/.local/share/cloud-setup"; fi
}

# Download this repo to $1 (replacing it only on success) and record its commit in $1/.commit.
# GitHub's tarballs carry the commit id in their pax header, so no git and no API call is needed.
fetch_self() {
  local dest="$1" tmp sha rc
  mkdir -p "$(dirname "$dest")" && tmp="$(mktemp -d "$(dirname "$dest")/.cloud-setup.XXXXXX")" || return 1
  if curl -fsSL --retry 2 --max-time 60 -o "$tmp/src.tgz" \
       "${CLOUD_SETUP_TARBALL:-https://codeload.github.com/$SLUG/tar.gz/$REF}" \
     && mkdir "$tmp/src" && tar -xzf "$tmp/src.tgz" -C "$tmp/src" --strip-components=1 \
     && [ -f "$tmp/src/setup.sh" ] && [ -f "$tmp/src/lib/common.sh" ]; then
    sha="$(gzip -dc "$tmp/src.tgz" 2>/dev/null | head -c 1024 | grep -ao 'comment=[0-9a-f]\{40\}' | head -1 | cut -d= -f2)"
    echo "${sha:-unknown}" > "$tmp/src/.commit"
    rm -rf "$dest.old" && { [ ! -e "$dest" ] || mv "$dest" "$dest.old"; } && mv "$tmp/src" "$dest"
    rc=$?; rm -rf "$tmp" "$dest.old"; return $rc
  fi
  rm -rf "$tmp"; return 1
}

# Not running from a checkout (piped from curl, or a lone copy): fetch one, run it.
bootstrap() {
  local dest="${CLOUD_SETUP_HOME:-$(default_home)}"
  fetch_self "$dest" || echo "cloud-setup: could not download $SLUG@$REF; trying an existing copy at $dest" >&2
  if [ -f "$dest/setup.sh" ] && [ -f "$dest/lib/common.sh" ]; then
    CLOUD_SETUP_HOME="$dest" exec bash "$dest/setup.sh" "$@" </dev/null
  fi
  local share p
  if p="$(ro_prefix)"; then share="${CLOUD_ENV_SHARE:-$p/share/cloud-env}"; else share="${CLOUD_ENV_SHARE:-$HOME/.local/share/cloud-env}"; fi
  case " $* " in *" --fetch-only "*) ;; *)
    mkdir -p "$share" 2>/dev/null \
      && echo "ERROR=could not download $SLUG@$REF and no copy at $dest" > "${CLOUD_SETUP_RESULT:-$share/setup-result}" ;;
  esac
  echo "cloud-setup: ERROR could not download $SLUG@$REF and no copy at $dest" >&2
  exit 0
}

run_step() { # name command...: one step, bounded by what is left of the budget; never fatal
  local name="$1" left rc; shift
  left=$(( deadline - $(date +%s) ))
  echo "running: $name (since $(date -u +%T))" > "$RESULT"
  echo "── $name" >> "$LOG"
  if [ "$left" -lt 10 ]; then summary+=" $name=skipped"; skipped+=" $name"; return 0; fi
  if [ -n "$TIMEOUT" ]; then "$TIMEOUT" -k 5 "$left" "$@" >>"$LOG" 2>&1 </dev/null; else "$@" >>"$LOG" 2>&1 </dev/null; fi
  rc=$?
  case "$rc" in
    0) summary+=" $name=ok" ;;
    124|137) summary+=" $name=timeout"; skipped+=" $name" ;;
    *) summary+=" $name=failed($rc)"; failed+=" $name" ;;
  esac
}

# The hand-off to a private session layer, which this public repo knows only by its contract:
#   - only with Connect configured (OP_CONNECT_HOST and OP_CONNECT_TOKEN set); otherwise a no-op
#   - each repo's scripts/cloud/env-setup.sh, in order, runs with --fetch-only until one has
#     recorded the layer (a repo can carry a stale stub from before a contract change): it fetches the
#     layer (reading any credential it needs in memory) and records "<how> <dir>" in
#     ~/.cloud-env.source (<prefix>/share/cloud-env/source with a read-only HOME; the prefix is
#     passed to the stub as CLOUD_SETUP_PREFIX)
#   - <dir>/install-time.sh --repo R... installs what needs no secret (wrappers, helpers)
# Nothing here reads or writes a secret. A failure is named in setup-result ("session layer: …")
# but is not a failed step: a session must not re-run the toolchain installer because of it.
handoff() {
  local r name=session-layer
  local -a args=() stubs=()
  [ -n "${OP_CONNECT_HOST:-}" ] && [ -n "${OP_CONNECT_TOKEN:-}" ] || return 0
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    args+=(--repo "$r")
    [ -f "$r/scripts/cloud/env-setup.sh" ] && stubs+=("$r/scripts/cloud/env-setup.sh")
  done <<< "$REPOS"
  [ "${#stubs[@]}" -gt 0 ] || { echo "session layer: Connect set, but no repo has scripts/cloud/env-setup.sh; skipped" >> "$LOG"; return 0; }
  # shellcheck disable=SC2088 # a label, not a path
  local mark="$HOME/.cloud-env.source" shown="~/.cloud-env.source"
  if [ "$RO_HOME" = 1 ]; then mark="$SHARE/source"; shown="$mark"; export CLOUD_SETUP_PREFIX="$CLOUD_PREFIX"; fi
  # shellcheck disable=SC2016 # expanded by the step's own shell
  run_step "$name" bash -c '
    mark="$1" shown="$2" n="$3"; shift 3
    base=""
    for stub in "${@:1:$n}"; do
      bash "$stub" --fetch-only
      base="$(awk "{print \$2}" "$mark" 2>/dev/null)"
      [ -n "$base" ] && break
      echo "session layer: $stub recorded nothing in $shown"
    done
    shift "$n"
    [ -n "$base" ] || { echo "session layer: not fetched (no $shown)"; exit 3; }
    [ -f "$base/install-time.sh" ] || { echo "session layer: $base has no install-time.sh"; exit 4; }
    bash "$base/install-time.sh" "$@"' _ "$mark" "$shown" "${#stubs[@]}" "${stubs[@]}" "${args[@]}"
  case " $failed " in *" $name "*) failed="${failed/ $name/}"; errors+=("session layer: not installed (log: $LOG)") ;; esac
  case " $skipped " in *" $name "*) skipped="${skipped/ $name/}"; errors+=("session layer: not installed, out of time") ;; esac
  return 0
}

main() {
  local here="$1" repos="${CLOUD_SETUP_REPO:-}" local_step=1 m r; shift
  while [ $# -gt 0 ]; do case "$1" in
    --repo) [ -z "${2:-}" ] || repos="${repos:+$repos
}$2"; shift 2 ;;
    --no-local) local_step=0; shift ;;
    --fetch-only) exit 0 ;;   # we are a checkout already
    --list) export CLOUD_SETUP_HOME="$here"
            # shellcheck source=lib/common.sh
            . "$here/lib/common.sh"
            for m in $(known_modules); do printf '%-12s %s\n' "$m" "$(module_description "$m")"; done
            exit 0 ;;
    *) shift ;;
  esac; done

  export CLOUD_SETUP_HOME="$here"
  # shellcheck source=lib/common.sh
  . "$here/lib/common.sh"
  # Every repo the session cloned that has a manifest (one per line); REPO is the first.
  REPOS="${repos:-$(discover_repos)}"; REPO="${REPOS%%$'\n'*}"; export REPOS REPO
  repo_pins

  local t0 budget manifest base err=""
  t0=$(date +%s); budget="${CLOUD_SETUP_BUDGET:-240}"; deadline=$(( t0 + budget ))
  summary=""; failed=""; skipped=""
  TIMEOUT="$(command -v timeout || true)"
  mkdir -p "$SHARE"
  RESULT="${CLOUD_SETUP_RESULT:-$SHARE/setup-result}"
  LOG="${CLOUD_SETUP_LOG:-$SHARE/setup.log}"
  : 2>/dev/null >"$LOG" || LOG=/tmp/cloud-setup.log
  export LOG
  base="$(head -c 7 "$here/.commit" 2>/dev/null)"
  case "$base" in ""|unknown) base="$(git -C "$here" rev-parse --short HEAD 2>/dev/null || echo local)" ;; esac
  echo "cloud-setup base=$base repo=$(echo "$REPOS" | paste -sd' ' -) budget=${budget}s started $(date -u +%FT%TZ)" >> "$LOG"
  # Read-only HOME: say where everything went, at a fixed path inside the prefix (`. <prefix>/env`).
  [ "$RO_HOME" = 1 ] && printf '# cloud-setup: HOME is read-only, so tools live here. Use: . %s/env\nexport CLOUD_PREFIX=%q\nexport PATH="%s:$PATH"\n' \
    "$CLOUD_PREFIX" "$CLOUD_PREFIX" "$BIN" > "$CLOUD_PREFIX/env"

  # The modules are the union of every repo's manifest.
  local -a errors=()
  manifest="$(mktemp "${TMPDIR:-/tmp}/cloud-setup-manifest.XXXXXX")"
  while IFS= read -r r; do
    if [ ! -f "$r/scripts/cloud/manifest" ]; then
      errors+=("no manifest at $r/scripts/cloud/manifest (core only)")
    else
      bad="$(validate_manifest "$r/scripts/cloud/manifest")" \
        || errors+=("unknown module(s): $(echo "$bad" | tr '\n' ' ')— known: $(known_modules | tr '\n' ' ')")
      cat "$r/scripts/cloud/manifest" >> "$manifest"; echo >> "$manifest"
    fi
  done <<< "$REPOS"

  # One apt-get update per run, shared by the steps (each runs in its own process).
  APT_STAMP="$(mktemp -u "${TMPDIR:-/tmp}/cloud-setup-apt.XXXXXX")"; export APT_STAMP
  for m in $(resolve_modules "$manifest"); do
    # shellcheck disable=SC2016 # expanded by the step's own shell
    run_step "$m" bash -c '. "$CLOUD_SETUP_HOME/lib/common.sh"; run_module setup "$1"' _ "$m"
  done
  # Repo-specific extras stay in the repo: each repo's, named local (local:<repo> with several).
  if [ "$local_step" = 1 ]; then
    while IFS= read -r r; do
      [ -f "$r/scripts/cloud/setup.local.sh" ] || continue
      if [ "$REPO" = "$REPOS" ]; then m=local; else m="local:$(basename "$r")"; fi
      run_step "$m" bash "$r/scripts/cloud/setup.local.sh"
    done <<< "$REPOS"
  fi
  rm -f "$APT_STAMP" "$manifest"
  [ "$local_step" = 1 ] && handoff


  [ -n "$failed" ] && errors+=("steps failed:$failed")
  [ -n "$skipped" ] && errors+=("steps cut by the ${budget}s budget:$skipped")
  [ ${#errors[@]} -gt 0 ] && err="$(printf '%s; ' "${errors[@]}")" && err="${err%; }"
  echo "base=$base${err:+ ERROR=$err}" > "$RESULT"
  echo "cloud-setup:$summary secs=$(( $(date +%s) - t0 ))${CLOUD_PREFIX:+ prefix=$CLOUD_PREFIX} log=$LOG${err:+
cloud-setup: ERROR $err}" | tee -a "$LOG"
  exit 0
}

self="${BASH_SOURCE[0]:-}"
here=""; [ -n "$self" ] && [ -f "$self" ] && here="$(cd "$(dirname "$self")" && pwd)"
if [ -n "$here" ] && [ -f "$here/lib/common.sh" ]; then main "$here" "$@"; else bootstrap "$@"; fi
exit 0
