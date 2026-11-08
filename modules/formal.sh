# formal — Quint (QUINT_PIN) with its Rust evaluator and Apalache, LemmaScript (LEMMASCRIPT_PIN) with Dafny; pinned, releases sha256-verified
# Apalache runs on the JVM (17 or later; the JRE is installed when no java is on PATH). It is also
# put where Quint looks for its pinned Apalache (~/.quint/apalache-dist-<version>), so `quint verify`
# downloads nothing: keep APALACHE_PIN at the DEFAULT_APALACHE_VERSION_TAG of the Quint the repos pin.
# Quint's Rust evaluator goes where Quint looks for it (~/.quint/rust-evaluator-v<version>), as Quint
# fetches it through GitHub's API, which a cloud session may not reach: keep QUINT_EVALUATOR_PIN at the
# QUINT_EVALUATOR_VERSION of QUINT_PIN. Quint and LemmaScript's `lsc` are global Bun packages; a repo
# that pins Quint in its own package.json runs that copy. Dafny's release is self-contained (.NET
# runtime and Z3 inside).
# shellcheck shell=bash

setup() {
  { command -v java >/dev/null || apt_install openjdk-17-jre-headless; } || return 1
  apalache_install && dafny_install && js_install && evaluator_install
}

drift() { apalache_have || echo apalache; dafny_have || echo dafny; js_have || echo quint-lsc; evaluator_have || echo quint-evaluator; }
reconcile() { setup; }

status() {
  local a=missing d=missing q=missing e=missing
  apalache_have && a="$APALACHE_PIN"; dafny_have && d="$DAFNY_PIN"; js_have && q="$QUINT_PIN/$LEMMASCRIPT_PIN"; evaluator_have && e="$QUINT_EVALUATOR_PIN"
  echo "apalache=$a dafny=$d quint/lsc=$q quint-evaluator=$e"
}

quint_home() { echo "${QUINT_HOME:-$IHOME/.quint}"; }

js_have() {
  [ -e "$BIN/quint" ] && [ -e "$BIN/lsc" ] && "$BIN/quint" --version 2>/dev/null | grep -qx "$QUINT_PIN"
}
js_install() {
  local bin
  js_have && return 0
  in_ihome bun add -g "@informalsystems/quint@${QUINT_PIN}" "lemmascript@${LEMMASCRIPT_PIN}" >/dev/null || { echo "formal: bun add -g quint lemmascript failed" >&2; return 1; }
  bin="$(in_ihome bun pm bin -g)"
  link quint "$bin/quint" && link lsc "$bin/lsc"
  js_have
}

evaluator_dir() { echo "$(quint_home)/rust-evaluator-v${QUINT_EVALUATOR_PIN}"; }
evaluator_have() { [ -x "$(evaluator_dir)/quint_evaluator" ]; }
evaluator_install() {
  local tmp rc dir
  evaluator_have && return 0
  dir="$(evaluator_dir)"; tmp="$(mktemp -d)"
  curl -fsSL --retry 3 --max-time 300 -o "$tmp/e.tgz" \
      "https://github.com/informalsystems/quint/releases/download/evaluator%2Fv${QUINT_EVALUATOR_PIN}/quint_evaluator-x86_64-unknown-linux-gnu.tar.gz" \
    && echo "$QUINT_EVALUATOR_SHA256  $tmp/e.tgz" | sha256sum -c --status \
    && mkdir -p "$dir" && tar -xzf "$tmp/e.tgz" -C "$dir" quint_evaluator
  rc=$?; rm -rf "$tmp"
  [ $rc = 0 ] || echo "formal: Quint's Rust evaluator: download/verify/unpack failed" >&2
  return $rc
}

apalache_dest() { echo "$OPT/apalache-${APALACHE_PIN}"; }
apalache_have() { [ -x "$(apalache_dest)/bin/apalache-mc" ] && [ -f "$(apalache_dest)/lib/apalache.jar" ] && [ -e "$BIN/apalache-mc" ]; }
dafny_dest() { echo "$OPT/dafny-${DAFNY_PIN}"; }
dafny_have() { "$(dafny_dest)/dafny" --version 2>/dev/null | head -1 | grep -q "^${DAFNY_PIN}"; }

# url sha256 dest top: the release fetched, checked, unpacked, and its top directory moved to dest.
release_install() {
  local url="$1" sha="$2" dest="$3" top="$4" tmp rc
  tmp="$(mktemp -d)"
  curl -fsSL --retry 3 --max-time 600 -o "$tmp/release" "$url" \
    && echo "$sha  $tmp/release" | sha256sum -c --status \
    && case "$url" in *.zip) unzip -q "$tmp/release" -d "$tmp" ;; *) tar -xzf "$tmp/release" -C "$tmp" ;; esac \
    && rm -rf "$dest" && mv "$tmp/$top" "$dest"
  rc=$?; rm -rf "$tmp"
  [ $rc = 0 ] || echo "formal: download/verify/unpack failed ($url)" >&2
  return $rc
}

apalache_install() {
  local dest quint
  dest="$(apalache_dest)"
  if ! [ -f "$dest/lib/apalache.jar" ]; then
    release_install "https://github.com/apalache-mc/apalache/releases/download/v${APALACHE_PIN}/apalache.tgz" \
      "$APALACHE_SHA256" "$dest" apalache || return 1
  fi
  link apalache-mc "$dest/bin/apalache-mc"
  # Quint's own copy of its pinned Apalache, in QUINT_HOME (default ~/.quint) for whoever runs it.
  quint="$(quint_home)/apalache-dist-${APALACHE_PIN}"
  mkdir -p "$quint" 2>/dev/null && ln -sfn "$dest" "$quint/apalache"
  apalache_have
}

dafny_install() {
  [ "$(uname -m)" = x86_64 ] || { echo "dafny: linux-x64 only" >&2; return 1; }
  dafny_have || apt_install unzip || return 1
  if ! dafny_have; then
    release_install "https://github.com/dafny-lang/dafny/releases/download/v${DAFNY_PIN}/dafny-${DAFNY_PIN}-x64-ubuntu-22.04.zip" \
      "$DAFNY_SHA256" "$(dafny_dest)" dafny || return 1
  fi
  link dafny "$(dafny_dest)/dafny"
  dafny_have
}
