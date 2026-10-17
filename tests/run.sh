#!/usr/bin/env bash
# Offline tests: manifest parsing, repo discovery, the always-exit-0 contract, the time budget,
# self-download, pins, the session hook and installing without root. Nothing real is installed.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
fail=0; ok() { echo "  ✓ $*"; }; no() { echo "  ✗ $*"; fail=1; }
t="$(mktemp -d)"; trap 'chmod -R u+w "$t" 2>/dev/null; rm -rf "$t"' EXIT
lib() { bash -c ". '$here/lib/common.sh'; $1"; }
unset OP_CONNECT_HOST OP_CONNECT_TOKEN   # the session-layer hand-off is tested on purpose, below

# Manifest
printf '# comment\noffice  blender-mcp\npython # trailing\nexcel-native\n' > "$t/manifest"
[ "$(lib "resolve_modules '$t/manifest' | tr '\n' ' '")" = "core blender blender-mcp office python " ] \
  && ok "core first, requirements before dependents, unknown names dropped" || no "resolution: $(lib "resolve_modules '$t/manifest'")"
[ "$(lib "validate_manifest '$t/manifest'")" = excel-native ] && ! lib "validate_manifest '$t/manifest'" >/dev/null \
  && ok "unknown module named" || no "validate_manifest"
lib "validate_manifest '$t/none'" && ok "missing manifest is not an unknown module" || no "missing manifest"
lib 'known_modules' | grep -qx office && ! lib 'known_modules' | grep -qx core && ok "registry = modules/*.sh minus core" || no "known_modules"
[ -n "$(lib 'module_description office')" ] && ok "module descriptions" || no "module_description"

# Venue: Codex markers set CLOUD_VENUE=codex for repo steps; nothing else changes it.
[ "$(env -u CLOUD_VENUE -u CODEX_ENVIRONMENT_ID -u CODEX_CI bash -c ". '$here/lib/common.sh'; echo \"\${CLOUD_VENUE:-unset}\"")" = unset ] \
  && [ "$(env -u CLOUD_VENUE CODEX_ENVIRONMENT_ID=e1 bash -c ". '$here/lib/common.sh'; echo \"\$CLOUD_VENUE\"")" = codex ] \
  && [ "$(env CLOUD_VENUE=cursor CODEX_CI=1 bash -c ". '$here/lib/common.sh'; echo \"\$CLOUD_VENUE\"")" = cursor ] \
  && ok "venue: codex from Codex markers; unset otherwise (Claude); an explicit venue wins" || no "venue detection"

# Repo discovery
mkdir -p "$t/home/u/plain" "$t/home/u/proj/scripts/cloud" "$t/home/u/proj/sub" "$t/home/u/gitonly" "$t/empty"
touch "$t/home/u/proj/scripts/cloud/manifest"; git -C "$t/home/u/proj" init -q; git -C "$t/home/u/gitonly" init -q
disc() { (cd "$1" && CLOUD_SETUP_ROOTS="${2:-$t/home/*/*}" bash -c ". '$here/lib/common.sh'; discover_repo"); }
[ "$(disc "$t/home/u/proj/sub")" = "$(cd "$t/home/u/proj" && pwd -P)" ] && ok "discover: git toplevel of \$PWD" || no "discover toplevel: $(disc "$t/home/u/proj/sub")"
[ "$(disc "$t/empty")" = "$t/home/u/proj" ] && ok "discover: first repo with a manifest under the roots" || no "discover roots: $(disc "$t/empty")"
[ "$(disc "$t/empty" "$t/home/u/gitonly $t/home/u/plain")" = "$t/home/u/gitonly" ] && ok "discover: else the first git repo" || no "discover git: $(disc "$t/empty" "$t/home/u/gitonly")"
[ "$(disc "$t/empty" "$t/nowhere/*")" = "$t/empty" ] && ok "discover: else \$PWD" || no "discover pwd"
mkdir -p "$t/home/u/zproj/scripts/cloud"; touch "$t/home/u/zproj/scripts/cloud/manifest"
discs() { (cd "$1" && CLOUD_SETUP_ROOTS="${2:-$t/home/*/*}" bash -c ". '$here/lib/common.sh'; discover_repos" | paste -sd' ' -); }
[ "$(discs "$t/empty")" = "$t/home/u/proj $t/home/u/zproj" ] && ok "discover: every repo with a manifest, in order" || no "discover all: $(discs "$t/empty")"
[ "$(discs "$t/home/u/proj/sub")" = "$(cd "$t/home/u/proj" && pwd -P) $(cd "$t/home/u/zproj" && pwd -P)" ] && ok "discover: a repo found twice is listed once" || no "discover dedup: $(discs "$t/home/u/proj/sub")"
[ "$(disc "$t/empty")" = "$t/home/u/proj" ] && ok "discover_repo: still the first" || no "discover_repo first"
rm -rf "$t/home/u/zproj"
# Multi-repo sandboxes (Codex Cloud) clone side by side under an undocumented root: the toplevel's
# siblings and $PWD's children count, with no roots at all.
mkdir -p "$t/ws/a/scripts/cloud" "$t/ws/b/scripts/cloud" "$t/ws/c"
touch "$t/ws/a/scripts/cloud/manifest" "$t/ws/b/scripts/cloud/manifest"; git -C "$t/ws/a" init -q
[ "$(discs "$t/ws/a" "$t/nowhere/*")" = "$(cd "$t/ws/a" && pwd -P) $(cd "$t/ws/b" && pwd -P)" ] && ok "discover: sibling repos of the toplevel" || no "discover siblings: $(discs "$t/ws/a" "$t/nowhere/*")"
[ "$(discs "$t/ws" "$t/nowhere/*")" = "$t/ws/a $t/ws/b" ] && ok "discover: repos under \$PWD" || no "discover children: $(discs "$t/ws" "$t/nowhere/*")"

# The contract: fake modules in a copy of this repo. Exit 0, result + log written, every problem named.
F="$t/fake"; mkdir -p "$F/modules" "$F/home" "$F/repo/scripts/cloud"
cp -R "$here/setup.sh" "$here/lib" "$here/pins.env" "$F/"
echo 'setup() { echo core-ran; }' > "$F/modules/core.sh"
echo 'setup() { true; }' > "$F/modules/good.sh"
echo 'setup() { return 3; }' > "$F/modules/bad.sh"
echo 'setup() { exit 7; }' > "$F/modules/dies.sh"
echo 'setup() { sleep 60; }' > "$F/modules/slow.sh"
echo 'setup() { true; }' > "$F/modules/zlate.sh"
printf 'good bad dies nope\n' > "$F/repo/scripts/cloud/manifest"
printf 'echo local-ran; exit 1\n' > "$F/repo/scripts/cloud/setup.local.sh"
run() { (cd "$F/repo" && env -u CLOUD_SETUP_HOME HOME="$F/home" CLOUD_SETUP_ROOTS="$F/none/*" CLOUD_SETUP_BUDGET="${BUDGET:-240}" bash "$F/setup.sh" "$@"); }
out="$(run)"; rc=$?
res="$(cat "$F/home/.local/share/cloud-env/setup-result" 2>/dev/null)"
[ $rc = 0 ] && ok "exits 0 although steps fail" || no "exit code $rc"
case "$res" in base=*" ERROR="*) ok "setup-result: base=… ERROR=…" ;; *) no "setup-result: $res" ;; esac
grep -q 'unknown module(s): nope' <<<"$res" && grep -q 'steps failed: bad dies local' <<<"$res" && ok "result names the unknown module and the failed steps" || no "result: $res"
grep -q 'core=ok bad=failed(3) dies=failed(7) good=ok local=failed(1)' <<<"$out" && ok "summary line per step" || no "summary: $out"
grep -q core-ran "$F/home/.local/share/cloud-env/setup.log" && grep -q local-ran "$F/home/.local/share/cloud-env/setup.log" && ok "steps log to setup.log" || no "setup.log"
run --no-local >/dev/null; ! grep -q 'failed:.* local' "$F/home/.local/share/cloud-env/setup-result" && ok "--no-local skips setup.local.sh" || no "--no-local"
rm "$F/repo/scripts/cloud/manifest"; run >/dev/null
grep -q 'no manifest' "$F/home/.local/share/cloud-env/setup-result" && ok "no manifest: core only, said so" || no "no manifest"
printf 'good\n' > "$F/repo/scripts/cloud/manifest"; rm "$F/repo/scripts/cloud/setup.local.sh"; run >/dev/null
[ "$(cut -c1-5 "$F/home/.local/share/cloud-env/setup-result")" = base= ] && ! grep -q ERROR "$F/home/.local/share/cloud-env/setup-result" \
  && ok "clean run: base=<sha>, no ERROR" || no "clean: $(cat "$F/home/.local/share/cloud-env/setup-result")"
# Session-layer hand-off: only with Connect configured; the repo's stub fetches (--fetch-only) and
# records the layer in ~/.cloud-env.source, then the layer's install-time.sh runs. Never fatal, and a
# failure is named without counting as a failed step (which would make sessions re-run the installer).
H="$F/home"; HL="$t/layer"; mkdir -p "$HL"
printf 'echo "stub $*" >> "%s/calls"; [ -n "${STUB_FAIL:-}" ] || echo "clone %s" > "$HOME/.cloud-env.source"\n' "$t" "$HL" > "$F/repo/scripts/cloud/env-setup.sh"
printf 'echo "install-time $*" >> "%s/calls"; exit "${IT_RC:-0}"\n' "$t" > "$HL/install-time.sh"
hres() { cat "$H/.local/share/cloud-env/setup-result"; }
rm -f "$t/calls"; run >/dev/null
[ ! -e "$t/calls" ] && ! grep -q "session layer" <<<"$(hres)" && ok "hand-off: no Connect → no-op" || no "hand-off ran without Connect: $(cat "$t/calls")"
out="$(OP_CONNECT_HOST=https://op.test OP_CONNECT_TOKEN=t run)"; rc=$?
[ $rc = 0 ] && [ "$(paste -sd'|' "$t/calls")" = "stub --fetch-only|install-time --repo $F/repo" ] && grep -q 'session-layer=ok' <<<"$out" \
  && ! grep -q ERROR "$H/.local/share/cloud-env/setup-result" && ok "hand-off: with Connect, stub --fetch-only then install-time.sh --repo" || no "hand-off: rc=$rc $out / $(cat "$t/calls")"
rm -f "$t/calls"; OP_CONNECT_HOST=https://op.test OP_CONNECT_TOKEN=t run --no-local >/dev/null
[ ! -e "$t/calls" ] && ok "hand-off: --no-local skips it (a session's repair run)" || no "hand-off ran with --no-local"
rm -f "$t/calls" "$H/.cloud-env.source"; out="$(OP_CONNECT_HOST=https://op.test OP_CONNECT_TOKEN=t STUB_FAIL=1 run)"; rc=$?
[ $rc = 0 ] && grep -q 'ERROR=session layer: not installed' <<<"$(hres)" && ! grep -q 'steps failed' <<<"$(hres)" && ! grep -q install-time "$t/calls" \
  && ok "hand-off: fetch fails → exit 0, named, not a failed step" || no "hand-off fetch failure: rc=$rc $(hres)"
out="$(OP_CONNECT_HOST=https://op.test OP_CONNECT_TOKEN=t IT_RC=5 run)"; rc=$?
[ $rc = 0 ] && grep -q 'session-layer=failed(5)' <<<"$out" && grep -q 'ERROR=session layer: not installed' <<<"$(hres)" && ! grep -q 'steps failed' <<<"$(hres)" \
  && ok "hand-off: install-time.sh fails → exit 0, named" || no "hand-off install-time failure: rc=$rc $out"
rm -f "$HL/install-time.sh"; OP_CONNECT_HOST=https://op.test OP_CONNECT_TOKEN=t run >/dev/null
grep -q 'session layer: not installed' <<<"$(hres)" && grep -q "has no install-time.sh" "$H/.local/share/cloud-env/setup.log" \
  && ok "hand-off: a layer without install-time.sh is named" || no "hand-off old layer: $(hres)"
rm -f "$F/repo/scripts/cloud/env-setup.sh" "$H/.cloud-env.source"; rm -rf "$HL"
# Several repos cloned side by side: the union of their manifests, each repo's setup.local.sh.
mkdir -p "$F/r2/a/scripts/cloud" "$F/r2/b/scripts/cloud"
printf 'good\n' > "$F/r2/a/scripts/cloud/manifest"; printf 'zlate good\n' > "$F/r2/b/scripts/cloud/manifest"
printf 'echo a-local\n' > "$F/r2/a/scripts/cloud/setup.local.sh"; printf 'echo b-local\n' > "$F/r2/b/scripts/cloud/setup.local.sh"
out="$(cd "$F/r2" && env -u CLOUD_SETUP_HOME HOME="$F/home" CLOUD_SETUP_ROOTS="$F/r2/*" bash "$F/setup.sh")"
grep -q 'core=ok good=ok zlate=ok local:a=ok local:b=ok' <<<"$out" && ! grep -q ERROR "$F/home/.local/share/cloud-env/setup-result" \
  && ok "several repos: union of manifests, every setup.local.sh" || no "several repos: $out"
out="$(cd "$F/r2" && env -u CLOUD_SETUP_HOME HOME="$F/home" CLOUD_SETUP_ROOTS="$F/none/*" bash "$F/setup.sh" --repo "$F/r2/b" --repo "$F/r2/a")"
grep -q 'core=ok good=ok zlate=ok local:b=ok local:a=ok' <<<"$out" && ok "--repo is repeatable" || no "--repo twice: $out"
# A stale stub (it records nothing) in the first repo: the hand-off tries the next repo's stub.
HL="$t/layer2"; mkdir -p "$HL"; printf 'exit 0\n' > "$HL/install-time.sh"
printf 'echo "stale $*" >> "%s/calls2"\n' "$t" > "$F/r2/a/scripts/cloud/env-setup.sh"
printf 'echo "fresh $*" >> "%s/calls2"; echo "clone %s" > "$HOME/.cloud-env.source"\n' "$t" "$HL" > "$F/r2/b/scripts/cloud/env-setup.sh"
rm -f "$t/calls2" "$F/home/.cloud-env.source"
out="$(cd "$F/r2" && env -u CLOUD_SETUP_HOME HOME="$F/home" CLOUD_SETUP_ROOTS="$F/r2/*" OP_CONNECT_HOST=https://op.test OP_CONNECT_TOKEN=t bash "$F/setup.sh")"
[ "$(paste -sd'|' "$t/calls2")" = "stale --fetch-only|fresh --fetch-only" ] && grep -q 'session-layer=ok' <<<"$out" \
  && ! grep -q ERROR "$F/home/.local/share/cloud-env/setup-result" && ok "hand-off: a stale stub falls through to the next repo's" || no "hand-off stale stub: $out / $(cat "$t/calls2")"
rm -f "$F/r2/a/scripts/cloud/env-setup.sh" "$F/r2/b/scripts/cloud/env-setup.sh" "$F/home/.cloud-env.source"; rm -rf "$HL"
mkdir -p "$F/r2/a/n" "$F/r2/b/n"; printf 'node\n' >> "$F/r2/b/scripts/cloud/manifest"
[ "$(REPO="$F/r2/a" REPOS="$F/r2/a
$F/r2/b" bash -c ". '$here/lib/common.sh'; repos_wanting node")" = "$F/r2/b" ] && ok "per-repo modules act only on the repos that list them" || no "repos_wanting"
[ "$(REPO="$F/r2/a" REPOS="$F/r2/a" bash -c ". '$here/lib/common.sh'; repos_wanting node")" = "$F/r2/a" ] && ok "one repo: per-repo modules act on it" || no "repos_wanting single"
mkdir -p "$t/pin2/a" "$t/pin2/b"; echo 1.2.3 > "$t/pin2/b/.bun-version"
[ "$(REPO="$t/pin2/a" REPOS="$t/pin2/a
$t/pin2/b" bash -c ". '$here/lib/common.sh'; echo \$BUN_PIN")" = 1.2.3 ] && ok "several repos: the first Bun pin wins" || no "bun pin across repos"

if command -v timeout >/dev/null; then
  printf 'slow zlate\n' > "$F/repo/scripts/cloud/manifest"; s=$(date +%s)
  out="$(BUDGET=12 run)"; rc=$?; d=$(( $(date +%s) - s ))
  [ $rc = 0 ] && [ $d -lt 30 ] && grep -q 'slow=timeout' <<<"$out" && grep -q 'zlate=skipped' <<<"$out" \
    && grep -q 'cut by the 12s budget: slow zlate' "$F/home/.local/share/cloud-env/setup-result" \
    && ok "budget: overrunning step killed, later steps skipped, still exit 0 (${d}s)" || no "budget: rc=$rc ${d}s $out"
else
  echo "  - budget test skipped (no timeout command)"
fi

# Self-download: piped from curl it fetches a tarball, records the commit, runs that copy.
git -C "$t" init -q src && cp -R "$here/setup.sh" "$here/lib" "$here/modules" "$here/pins.env" "$t/src/"
git -C "$t/src" add -A && git -C "$t/src" -c user.name=t -c user.email=t@example.com commit -qm t
git -C "$t/src" archive --format=tar.gz --prefix=cloud-setup-main/ -o "$t/src.tgz" HEAD
sha="$(git -C "$t/src" rev-parse HEAD)"
(cd "$t" && env HOME="$t/bh" CLOUD_SETUP_HOME="$t/dest" CLOUD_SETUP_TARBALL="file://$t/src.tgz" bash -s -- --fetch-only < "$here/setup.sh"); rc=$?
[ $rc = 0 ] && [ -f "$t/dest/modules/core.sh" ] && [ "$(cat "$t/dest/.commit")" = "$sha" ] \
  && ok "bootstrap: tarball unpacked, commit id from its header" || no "bootstrap rc=$rc commit=$(cat "$t/dest/.commit" 2>/dev/null)"
[ ! -e "$t/bh/.local/share/cloud-env/setup-result" ] && ok "--fetch-only installs nothing" || no "--fetch-only wrote a result"
touch "$t/mark"; sleep 1
(cd "$t" && env HOME="$t/bh" CLOUD_SETUP_HOME="$t/dest" CLOUD_SETUP_TARBALL="file://$t/src.tgz" bash -s -- --fetch-only < "$here/setup.sh")
[ -z "$(find "$t" -mindepth 1 -maxdepth 1 -newer "$t/mark")" ] && [ -z "$(find "$t/dest" -newer "$t/mark")" ] && ok "bootstrap: the same commit again → the copy is left as it is" || no "bootstrap rewrote: $(find "$t" -maxdepth 1 -newer "$t/mark"; find "$t/dest" -newer "$t/mark")"
(cd "$t" && env HOME="$t/bh" CLOUD_SETUP_HOME="$t/dest" CLOUD_SETUP_TARBALL="file://$t/missing.tgz" bash -s -- --fetch-only < "$here/setup.sh" 2>/dev/null)
[ $? = 0 ] && [ -f "$t/dest/setup.sh" ] && ok "bootstrap: download fails → keeps the existing copy" || no "bootstrap kept copy"
(cd "$t" && env HOME="$t/bh" CLOUD_SETUP_HOME="$t/nodest" CLOUD_SETUP_TARBALL="file://$t/missing.tgz" bash -s < "$here/setup.sh" 2>/dev/null); rc=$?
[ $rc = 0 ] && grep -q '^ERROR=could not download' "$t/bh/.local/share/cloud-env/setup-result" \
  && ok "bootstrap: nothing to run → exit 0, ERROR in setup-result" || no "bootstrap failure rc=$rc"
# The documented one-liner, under a strict shell with the download failing, still exits 0.
mkdir -p "$t/nocurl"; printf '#!/bin/sh\nexit 22\n' > "$t/nocurl/curl"; chmod +x "$t/nocurl/curl"
line="$(grep -m1 -o 'curl -fsSL https://raw.githubusercontent.com/[^ ]*/setup.sh | bash || true' "$here/README.md")"
[ -n "$line" ] && grep -qF "$line" "$here/setup.sh" && ok "README and setup.sh show the same one-liner" || no "one-liner drifted"
(cd "$t" && PATH="$t/nocurl:$PATH" bash -euo pipefail -c "$line") && ok "one-liner exits 0 under set -euo pipefail when the download fails" || no "one-liner fails under a strict shell"

# Pins
mkdir -p "$t/pin"; echo '{"packageManager": "bun@1.4.0"}' > "$t/pin/package.json"
[ "$(REPO="$t/pin" bash -c ". '$here/lib/common.sh'; echo \$BUN_PIN")" = 1.4.0 ] && ok "repo packageManager bun pin wins" || no "bun pin from package.json"
echo "v1.3.9" > "$t/pin/.bun-version"
[ "$(REPO="$t/pin" bash -c ". '$here/lib/common.sh'; echo \$BUN_PIN")" = 1.3.9 ] && ok ".bun-version wins over package.json" || no ".bun-version pin"

# User-level session hook
mkdir -p "$t/hk/.claude"; echo '{"theme":"dark","hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"echo mine"}]}]}}' > "$t/hk/.claude/settings.json"
HOME="$t/hk" bash -c ". '$here/lib/common.sh'; . '$here/modules/core.sh'; core_session_hook && core_session_hook"
hk="$t/hk/.claude/settings.json"
[ "$(jq '[.hooks.SessionStart[].hooks[].command | select(endswith("# cloud-setup"))] | length' "$hk")" = 1 ] && ok "session hook added once" || no "session hook count"
[ "$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$hk")" = "echo mine" ] && [ "$(jq -r .theme "$hk")" = dark ] && ok "session hook keeps other hooks/settings" || no "session hook clobbered settings"
mkdir -p "$t/hkrun/r/scripts/cloud" "$t/hkrun/r/.claude"
echo 'echo ran' > "$t/hkrun/r/scripts/cloud/session-start.sh"
cmd="$(jq -r '.hooks.SessionStart[-1].hooks[0].command' "$hk")"
[ "$(cd "$t/hkrun/r" && CLAUDE_CODE_REMOTE=true bash -c "$cmd")" = ran ] && ok "session hook runs the project's session-start" || no "session hook did not run"
[ -z "$(cd "$t/hkrun/r" && env -u CLAUDE_CODE_REMOTE bash -c "$cmd")" ] && ok "session hook is a no-op outside remote sessions" || no "session hook ran locally"
echo '{"hooks":{"SessionStart":[{"hooks":[{"command":"bash scripts/cloud/session-start.sh"}]}]}}' > "$t/hkrun/r/.claude/settings.json"
[ -z "$(cd "$t/hkrun/r" && CLAUDE_CODE_REMOTE=true bash -c "$cmd")" ] && ok "session hook defers to the project's own hook" || no "session hook double-runs"

# Without root or sudo (Codex Cloud builds as a plain user with no sudo binary): a PATH of real
# tools minus sudo/apt/dpkg/git, a fake id (uid 1000) and a fake curl serving release fixtures.
NR="$t/nr"; mkdir -p "$NR/fake" "$NR/tools" "$NR/rel" "$NR/home" "$NR/repo/scripts/cloud"
for c in bash sh env true mkdir ln rm mv cp cat sed grep awk tr head cut dirname basename uname mktemp \
         tar gzip chmod install sort comm ls cmp date paste tee timeout sha256sum shasum touch sleep wc find; do
  p="$(type -P "$c")" && ln -s "$p" "$NR/tools/$c"
done
realid="$(type -P id)"; realjq="$(type -P jq)"
case "$(uname -m)" in x86_64) narch=amd64 ;; *) narch=arm64 ;; esac
printf '#!/bin/sh\n[ "$1" = -u ] && { echo 1000; exit 0; }; exec %s "$@"\n' "$realid" > "$NR/fake/id"
printf '#!/bin/sh\necho "$*" >> %s/apt.log\n' "$NR" | tee "$NR/fake/apt-get" > "$NR/fake/add-apt-repository"
cat > "$NR/fake/curl" <<SH
#!/bin/sh
out=""; url=""
while [ \$# -gt 0 ]; do case "\$1" in -o) out="\$2"; shift 2 ;; http*) url="\$1"; shift ;; *) shift ;; esac; done
echo "\$url" >> "$NR/curl.log"
case "\$url" in https://bun.sh/install) f="$NR/rel/bun-install.sh" ;; *) f="$NR/rel/\${url#*/releases/download/}" ;; esac
[ -f "\$f" ] || exit 22
if [ -n "\$out" ]; then cp "\$f" "\$out"; else cat "\$f"; fi
SH
( . "$here/pins.env"
  printf '#!/bin/sh\necho v22.1.0\n' > "$NR/fake/node"
  printf '#!/bin/sh\necho "uv %s"\n' "$UV_PIN" > "$NR/fake/uv"
  printf '#!/bin/sh\necho %s\n' "$BUN_PIN" > "$NR/fake/bun"
  printf '#!/bin/sh\necho %s\n' "$OP_CLI_PIN" > "$NR/fake/op"
  a="$narch"
  sha() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }
  mkbin() { mkdir -p "$(dirname "$1")"; printf '#!/bin/sh\n%s\n' "$2" > "$1"; chmod +x "$1"; }
  r="$NR/rel/v$GH_PIN"; s="$t/stage/gh"; mkbin "$s/gh_${GH_PIN}_linux_$a/bin/gh" "echo 'gh version $GH_PIN (fixture)'"
  mkdir -p "$r" && tar -czf "$r/gh_${GH_PIN}_linux_$a.tar.gz" -C "$s" . \
    && echo "$(sha "$r/gh_${GH_PIN}_linux_$a.tar.gz")  gh_${GH_PIN}_linux_$a.tar.gz" > "$r/gh_${GH_PIN}_checksums.txt"
  r="$NR/rel/jq-$JQ_PIN"; mkbin "$r/jq-linux-$a" "[ \"\$1\" = --version ] && { echo jq-$JQ_PIN; exit 0; }; exec $realjq \"\$@\""
  echo "$(sha "$r/jq-linux-$a")  jq-linux-$a" > "$r/sha256sum.txt"
  r="$NR/rel/v$GIT_LFS_PIN"; s="$t/stage/lfs"; mkbin "$s/git-lfs-$GIT_LFS_PIN/git-lfs" "echo 'git-lfs/$GIT_LFS_PIN (fixture)'"
  f="git-lfs-linux-$a-v$GIT_LFS_PIN.tar.gz"; mkdir -p "$r" && tar -czf "$r/$f" -C "$s" . \
    && printf -- '-----BEGIN PGP SIGNED MESSAGE-----\nHash: SHA512\n\n%s *%s\n' "$(sha "$r/$f")" "$f" > "$r/sha256sums.asc"
  r="$NR/rel/$PANDOC_PIN"; s="$t/stage/pandoc"; mkbin "$s/pandoc-$PANDOC_PIN/bin/pandoc" "echo 'pandoc $PANDOC_PIN'"
  mkdir -p "$r" && tar -czf "$r/pandoc-$PANDOC_PIN-linux-$a.tar.gz" -C "$s" . )
chmod +x "$NR/fake/"*
nr() { /usr/bin/env -i HOME="$NR/home" PATH="$NR/fake:$NR/tools" TMPDIR="$t" CLOUD_SETUP_ROOTS="$NR/none/*" "$NR/tools/bash" "$@"; }
[ "$(nr -c ". '$here/lib/common.sh'; can_root || echo \$SUDO")" = need_root ] && ok "no sudo binary: \$SUDO refuses, can_root says no" || no "no-sudo detection"
echo office > "$NR/repo/scripts/cloud/manifest"
out="$(nr "$here/setup.sh" --repo "$NR/repo")"; rc=$?
nbin="$NR/home/.local/bin"; ( . "$here/pins.env"
  [ "$("$nbin/gh" --version)" = "gh version $GH_PIN (fixture)" ] && [ "$("$nbin/jq" --version)" = "jq-$JQ_PIN" ] \
    && [ "$("$nbin/git-lfs" --version)" = "git-lfs/$GIT_LFS_PIN (fixture)" ] && [ "$("$nbin/pandoc" --version)" = "pandoc $PANDOC_PIN" ] \
    && [ -d "$NR/home/.local/opt/gh_${GH_PIN}_linux_$narch" ] ) \
  && ok "no root: gh, jq, git-lfs, pandoc pinned in ~/.local" || no "no-root user-space installs: $(ls "$nbin" 2>&1)"
[ $rc = 0 ] && grep -q 'core=ok office=failed(1)' <<<"$out" && ok "no root: core ok, the apt-needing module fails by name" || no "no-root summary: $out"
grep -q 'needs root or passwordless sudo' "$NR/home/.local/share/cloud-env/setup.log" && ok "no root: the failure says root or passwordless sudo is needed" || no "no-root message"
grep -q 'system packages left to the image, missing: .*fontconfig' "$NR/home/.local/share/cloud-env/setup.log" && ok "no root: missing system packages named, not a failure" || no "no-root note"
[ ! -e "$NR/apt.log" ] && ok "no root: apt never invoked" || no "apt ran: $(cat "$NR/apt.log")"
[ "$(jq '[.hooks.SessionStart[].hooks[].command | select(endswith("# cloud-setup"))] | length' "$NR/home/.claude/settings.json")" = 1 ] \
  && ok "no root: session hook written with the user-space jq" || no "no-root session hook"
n="$(wc -l < "$NR/curl.log")"; nr "$here/setup.sh" --repo "$NR/repo" >/dev/null
[ "$(wc -l < "$NR/curl.log")" = "$n" ] && ok "no root: rerun downloads nothing" || no "no-root rerun downloaded: $(tail -n +"$((n + 1))" "$NR/curl.log")"
( . "$here/pins.env"; echo "0000  jq-linux-$narch" > "$NR/rel/jq-$JQ_PIN/sha256sum.txt" )
rm -f "$nbin/jq"; err="$(nr -c ". '$here/lib/common.sh'; . '$here/modules/core.sh'; core_jq" 2>&1)"; rc=$?
[ $rc != 0 ] && [ ! -e "$nbin/jq" ] && grep -q 'REFUSING jq-linux' <<<"$err" && ok "no root: a binary the release's sha256 list does not vouch for is refused" || no "checksum refusal: rc=$rc $err"
# apt_install: nothing missing needs no root; something missing without root fails by name; with
# passwordless sudo it is still apt.
printf '#!/bin/sh\n[ "$3" = absent ] && exit 1; printf "install ok installed"\n' > "$NR/fake/dpkg-query"; chmod +x "$NR/fake/dpkg-query"
nr -c ". '$here/lib/common.sh'; apt_install curl git" && [ ! -e "$NR/apt.log" ] && ok "apt_install: nothing missing → 0, no root needed" || no "apt_install nothing missing"
err="$(nr -c ". '$here/lib/common.sh'; apt_install curl absent" 2>&1)"; rc=$?
[ $rc != 0 ] && grep -q 'absent missing; installing needs root or passwordless sudo' <<<"$err" && [ ! -e "$NR/apt.log" ] \
  && ok "apt_install: missing without root → named failure" || no "apt_install no root: rc=$rc $err"
printf '#!/bin/sh\nexit 1\n' > "$NR/fake/sudo"; chmod +x "$NR/fake/sudo"
[ "$(nr -c ". '$here/lib/common.sh'; echo \$SUDO")" = need_root ] && ok "sudo that wants a password counts as no sudo" || no "password sudo"
printf '#!/bin/sh\n[ "$1" = -n ] && shift; exec "$@"\n' > "$NR/fake/sudo"
nr -c ". '$here/lib/common.sh'; apt_install curl absent" && grep -q 'install .*absent' "$NR/apt.log" \
  && ok "passwordless sudo: apt_install still uses apt" || no "sudo apt path: $(cat "$NR/apt.log" 2>/dev/null)"


# A writable HOME is what Claude Code (root) and Cursor (a user) have: nothing about it may change.
# Every path, the SessionStart hook, ~/.cloud-env.source and the summary line are as before, even
# with the read-only-HOME knobs set.
rm -f "$NR/fake/sudo" "$NR/fake/dpkg-query"   # back to no sudo at all, as on Codex Cloud
( . "$here/pins.env"; r="$NR/rel/jq-$JQ_PIN"   # and the jq checksum list the refusal test spoiled
  echo "$(if command -v sha256sum >/dev/null; then sha256sum "$r/jq-linux-$narch"; else shasum -a 256 "$r/jq-linux-$narch"; fi | cut -d' ' -f1)  jq-linux-$narch" > "$r/sha256sum.txt" )
WH="$t/wh"; mkdir -p "$WH/home" "$WH/ws" "$WH/fake"
printf '#!/bin/sh\n[ "$1" = -u ] && { echo 0; exit 0; }; exec %s "$@"\n' "$realid" > "$WH/fake/id"; chmod +x "$WH/fake/id"
paths='echo "$BIN|$OPT|$SHARE|$RO_HOME|$CLOUD_PREFIX|$IHOME"'
knobs=(CLOUD_SETUP_PREFIX="$WH/ws/p" CLOUD_SETUP_WORKSPACE="$WH/ws")
[ "$(env "${knobs[@]}" HOME="$WH/home" PATH="$WH/fake:$PATH" bash -c ". '$here/lib/common.sh' 2>/dev/null; $paths")" = "/usr/local/bin|/opt|$WH/home/.local/share/cloud-env|0||$WH/home" ] \
  && ok "writable HOME, root: /usr/local/bin, /opt, ~/.local/share/cloud-env as before (prefix knobs ignored)" || no "root paths: $(env "${knobs[@]}" HOME="$WH/home" PATH="$WH/fake:$PATH" bash -c ". '$here/lib/common.sh' 2>/dev/null; $paths")"
[ "$(nr -c "export ${knobs[*]}; HOME='$WH/home'; . '$here/lib/common.sh'; $paths")" = "$WH/home/.local/bin|$WH/home/.local/opt|$WH/home/.local/share/cloud-env|0||$WH/home" ] \
  && ok "writable HOME, plain user: ~/.local as before (prefix knobs ignored)" || no "user paths: $(nr -c "export ${knobs[*]}; HOME='$WH/home'; . '$here/lib/common.sh'; $paths")"
dh() { eval "$(sed -n '/^ro_prefix() {/,/^}/p;/^default_home() {/,/^}/p' "$here/setup.sh")"; default_home; }
[ "$(export "${knobs[@]}"; HOME="$WH/home" PATH="$WH/fake:$PATH" dh)" = /opt/cloud-setup ] && [ "$(export "${knobs[@]}"; HOME="$WH/home" dh)" = "$WH/home/.local/share/cloud-setup" ] \
  && ok "writable HOME: the installer's own home is /opt/cloud-setup (root) or ~/.local/share/cloud-setup, as before" || no "default_home with a writable HOME"
[ ! -e "$WH/ws/.cloud" ] && [ ! -e "$WH/ws/p" ] && ok "writable HOME: nothing created under the workspace or CLOUD_SETUP_PREFIX" || no "writable HOME wrote a prefix"
printf 'good\n' > "$F/repo/scripts/cloud/manifest"; rm -f "$F/repo/scripts/cloud/setup.local.sh"
out="$(cd "$F/repo" && env -u CLOUD_SETUP_HOME "${knobs[@]}" HOME="$F/home" CLOUD_SETUP_ROOTS="$F/none/*" bash "$F/setup.sh")"
grep -Eqx "cloud-setup: core=ok good=ok secs=[0-9]+ log=$F/home/.local/share/cloud-env/setup.log" <<<"$out" && ! grep -q 'prefix=' <<<"$out" \
  && [ "$(cut -c1-5 "$F/home/.local/share/cloud-env/setup-result")" = base= ] && [ ! -e "$WH/ws/.cloud" ] && [ ! -e "$WH/ws/p" ] \
  && ok "writable HOME: summary line unchanged (no prefix=), result in ~/.local/share/cloud-env" || no "writable HOME summary: $out"
HL="$t/layer2"; mkdir -p "$HL"; rm -f "$t/calls" "$F/home/.cloud-env.source"
printf 'echo "stub prefix=${CLOUD_SETUP_PREFIX:-unset}" >> "%s/calls"; echo "clone %s" > "$HOME/.cloud-env.source"\n' "$t" "$HL" > "$F/repo/scripts/cloud/env-setup.sh"
printf 'echo "install-time $*" >> "%s/calls"\n' "$t" > "$HL/install-time.sh"
(cd "$F/repo" && env -u CLOUD_SETUP_HOME -u CLOUD_SETUP_PREFIX HOME="$F/home" CLOUD_SETUP_WORKSPACE="$WH/ws" CLOUD_SETUP_ROOTS="$F/none/*" \
  OP_CONNECT_HOST=https://op.test OP_CONNECT_TOKEN=t bash "$F/setup.sh" >/dev/null)
[ "$(paste -sd'|' "$t/calls")" = "stub prefix=unset|install-time --repo $F/repo" ] && [ -f "$F/home/.cloud-env.source" ] && [ ! -e "$WH/ws/.cloud" ] \
  && ok "writable HOME: hand-off reads ~/.cloud-env.source, passes no prefix" || no "writable HOME hand-off: $(cat "$t/calls" 2>/dev/null)"
rm -f "$F/repo/scripts/cloud/env-setup.sh" "$F/home/.cloud-env.source"
nr "$here/setup.sh" --repo "$NR/repo" >/dev/null
[ "$(jq '[.hooks.SessionStart[].hooks[].command | select(endswith("# cloud-setup"))] | length' "$NR/home/.claude/settings.json")" = 1 ] && [ -x "$NR/home/.local/bin/gh" ] \
  && ok "writable HOME, plain user: SessionStart hook in ~/.claude, tools in ~/.local/bin" || no "writable HOME hook/tools"

# --reconcile (Codex Cloud's Maintenance script, before every task on a cached container): nothing
# off its pin → done in seconds, nothing written; a bumped pin → only that piece reinstalled.
NS="$NR/home/.local/share/cloud-env"; prior="$(cat "$NS/setup-result")"
rc_() { nr "$here/setup.sh" --repo "$NR/repo" --reconcile; }
touch "$t/mark"; sleep 1; n="$(wc -l < "$NR/curl.log")"; s=$(date +%s)
out="$(rc_)"; rc=$?; d=$(( $(date +%s) - s ))
[ $rc = 0 ] && grep -q '^cloud-setup reconcile: nothing off its pin' <<<"$out" && [ $d -le 5 ] && [ "$(wc -l < "$NR/curl.log")" = "$n" ] \
  && ok "reconcile: no drift → exit 0, ${d}s, no download" || no "reconcile no drift: rc=$rc ${d}s $out"
[ -z "$(find "$NR/home" "$here" -newer "$t/mark" 2>/dev/null)" ] && ok "reconcile: no drift → nothing written (result, log, tools, this repo)" || no "reconcile wrote: $(find "$NR/home" "$here" -newer "$t/mark")"
printf '#!/bin/sh\nv="${1#bun-v}"; [ "$v" = 1.9.8 ] && exit 1; mkdir -p "$BUN_INSTALL/bin" && printf "#!/bin/sh\\necho %%s\\n" "$v" > "$BUN_INSTALL/bin/bun" && chmod +x "$BUN_INSTALL/bin/bun"\n' > "$NR/rel/bun-install.sh"
echo 1.9.9 > "$NR/repo/.bun-version"; n="$(wc -l < "$NR/curl.log")"
out="$(rc_)"; rc=$?
[ $rc = 0 ] && grep -q 'drift=core:bun core=ok' <<<"$out" && [ "$(nr -c ". '$here/lib/common.sh'; bun --version")" = 1.9.9 ] \
  && [ "$(tail -n +"$((n + 1))" "$NR/curl.log")" = https://bun.sh/install ] \
  && ok "reconcile: a repo's bun pin bump → only bun reinstalled, the new one first on PATH" || no "reconcile bun bump: rc=$rc $out / $(tail -n +"$((n + 1))" "$NR/curl.log")"
[ "$(cat "$NS/setup-result")" = "$prior" ] && grep -q '^cloud-setup reconcile: drift=core:bun' "$NS/setup.log" \
  && ! grep '^cloud-setup:' "$NS/setup.log" | grep -q reconcile \
  && ok "reconcile: setup-result keeps the install's errors; no reconcile line reads as an install summary (^cloud-setup:)" || no "reconcile result/log: $(cat "$NS/setup-result")"
out="$(rc_)"; grep -q 'nothing off its pin' <<<"$out" && ok "reconcile: after a fix, back to the fast path" || no "reconcile second run: $out"
echo 1.9.8 > "$NR/repo/.bun-version"; out="$(rc_)"; rc=$?
[ $rc = 0 ] && grep -q 'core=failed(1)' <<<"$out" && [ "$(cat "$NS/setup-result")" = "$prior; reconcile failed: core" ] \
  && ok "reconcile: a failed reinstall → exit 0, named in setup-result after the install's errors" || no "reconcile failure: rc=$rc $out / $(cat "$NS/setup-result")"
echo 1.9.9 > "$NR/repo/.bun-version"; rc_ >/dev/null
[ "$(cat "$NS/setup-result")" = "$prior" ] && ok "reconcile: a later success clears its own earlier error, nothing else" || no "reconcile clear: $(cat "$NS/setup-result")"
echo "running: office (since 00:00:00)" > "$NS/setup-result"; echo 1.9.8 > "$NR/repo/.bun-version"; rc_ >/dev/null
[ "$(cat "$NS/setup-result")" = "running: office (since 00:00:00)" ] && ok "reconcile: a cut-off install's result is left for the session-time repair" || no "reconcile over running: $(cat "$NS/setup-result")"
echo "$prior" > "$NS/setup-result"; rm -f "$NR/repo/.bun-version" "$NR/home/.local/bin/bun" "$NR/home/.local/bin/bunx"; rm -rf "$NR/home/.local/opt/bun"
line="$(grep -m1 -o 'curl -fsSL https://raw.githubusercontent.com/[^ ]*/setup.sh | bash -s -- --reconcile || true' "$here/README.md")"
[ -n "$line" ] && grep -qF "$line" "$here/setup.sh" && ok "README and setup.sh show the same Maintenance line" || no "Maintenance line drifted"

# Root with a writable HOME (Codex Cloud's older universal image): BIN is /usr/local/bin, but the image's
# own bun/gh sit ahead of it on PATH, and ~/.local/bin is what agents put first. Every link is mirrored
# there. CLOUD_SETUP_BIN/OPT give the root layout without root.
M="$t/mir"; mkdir -p "$M/home/.local/bin" "$M/usr-local-bin" "$M/opt" "$M/image" "$M/tgt"
printf '#!/bin/sh\necho 1.2.14\n' > "$M/image/bun"; printf '#!/bin/sh\necho 1.4.2\n' > "$M/tgt/bun"; chmod +x "$M/image/bun" "$M/tgt/bun"
echo mine > "$M/home/.local/bin/owned"; echo ours > "$M/tgt/owned"; echo ours > "$M/tgt/cursor-agent"; ln -s "$M/home/.local/bin/cursor-agent" "$M/usr-local-bin/cursor-agent"; echo theirs > "$M/home/.local/bin/cursor-agent"
mir() { env HOME="$M/home" CLOUD_SETUP_BIN="$M/usr-local-bin" CLOUD_SETUP_OPT="$M/opt" bash -c ". '$here/lib/common.sh'; $1"; }
mir "link bun '$M/tgt/bun'; link owned '$M/tgt/owned'; link cursor-agent '$M/home/.local/bin/cursor-agent'; link vault '$M/tgt/bun'"
[ "$(PATH="$M/home/.local/bin:$M/image:$M/usr-local-bin:/usr/bin:/bin" bun --version)" = 1.4.2 ] \
  && [ "$(PATH="$M/image:$M/usr-local-bin:/usr/bin:/bin" bun --version)" = 1.2.14 ] \
  && [ "$(readlink "$M/home/.local/bin/bun")" = "$M/usr-local-bin/bun" ] && [ "$(readlink "$M/home/.local/bin/vault")" = "$M/usr-local-bin/vault" ] \
  && ok "root layout: a linked command is also in ~/.local/bin (the pinned bun beats the image's when it is first), pointing through BIN" || no "mirror: $(ls -l "$M/home/.local/bin")"
[ "$(cat "$M/home/.local/bin/owned")" = mine ] && [ ! -L "$M/home/.local/bin/owned" ] && [ "$(cat "$M/home/.local/bin/cursor-agent")" = theirs ] && [ ! -L "$M/home/.local/bin/cursor-agent" ] \
  && ok "root layout: a real file in ~/.local/bin is the owner's and stays; a link back to it is not made a loop" || no "mirror clobbered: $(ls -l "$M/home/.local/bin")"
mir "link bun '$M/tgt/owned'; mirror_bin bun"; [ "$(readlink "$M/usr-local-bin/bun")" = "$M/tgt/owned" ] && [ "$(readlink "$M/home/.local/bin/bun")" = "$M/usr-local-bin/bun" ] \
  && ok "root layout: re-linking a command re-points BIN's file and the mirror still follows it" || no "mirror relink"
rm -rf "$M/home2"; mkdir -p "$M/home2"
env HOME="$M/home2" CLOUD_SETUP_BIN="$M/home2/.local/bin" bash -c ". '$here/lib/common.sh'; link bun '$M/tgt/bun'; RO_HOME=1 BIN='$M/usr-local-bin' mirror_bin bun"
[ -L "$M/home2/.local/bin/bun" ] && [ "$(readlink "$M/home2/.local/bin/bun")" = "$M/tgt/bun" ] && ok "plain user (BIN is ~/.local/bin) and a read-only HOME: no mirror, nothing extra" || no "mirror when BIN is ~/.local/bin: $(ls -l "$M/home2/.local/bin")"
# A BIN link to a ~/.local/bin file that is missing must not get the reverse link (a 2-link cycle that reruns kept);
# a cycle already there is repaired. link() keeps ln's failure.
rm -rf "$M/home3"; mkdir -p "$M/home3/.local/bin" "$M/ub3"
ln -s "$M/home3/.local/bin/dang" "$M/ub3/dang"
env HOME="$M/home3" CLOUD_SETUP_BIN="$M/ub3" bash -c ". '$here/lib/common.sh'; mirror_bin dang; mirror_bin dang"
[ ! -e "$M/home3/.local/bin/dang" ] && [ ! -L "$M/home3/.local/bin/dang" ] && ok "mirror_bin: a BIN link to a missing ~/.local/bin file is not mirrored back (no cycle)" || no "mirror cycle: $(ls -l "$M/home3/.local/bin")"
ln -s "$M/ub3/dang" "$M/home3/.local/bin/dang"   # a cycle from an earlier version
env HOME="$M/home3" CLOUD_SETUP_BIN="$M/ub3" bash -c ". '$here/lib/common.sh'; mirror_bin dang"
[ ! -L "$M/home3/.local/bin/dang" ] && ok "mirror_bin: an existing 2-link cycle is repaired" || no "cycle kept"
env HOME="$M/home3" CLOUD_SETUP_BIN="$M/ub3" bash -c ". '$here/lib/common.sh'; chmod 555 '$M/ub3'; link x '$M/tgt/bun'"; rc=$?; chmod 755 "$M/ub3"
if [ -w "$M/ub3" ] && [ "$(id -u)" != 0 ]; then [ $rc != 0 ] && [ ! -e "$M/home3/.local/bin/x" ] && ok "link: a failed ln is reported, not masked by mirror_bin" || no "link masked ln failure rc=$rc"; fi

[ -z "$(mir "mirror_stale bun owned cursor-agent vault")" ] && rm "$M/home/.local/bin/vault" && [ "$(mir "mirror_stale bun vault")" = vault ] \
  && ok "mirror_stale: names only what mirror_bin would change (reconcile's mirror drift)" || no "mirror_stale: $(mir "mirror_stale bun owned cursor-agent vault")"
mir "mirror_bin vault"
# core's own shims and the uv/rust steps mirror too: an image npm/npx must not outrank them.
mir ". '$here/modules/core.sh'; core_no_npm" 2>/dev/null   # BSD install cannot read a pipe for npx: only Linux gets both
[ -L "$M/home/.local/bin/npm" ] && { [ ! -e "$M/usr-local-bin/npx" ] || [ -L "$M/home/.local/bin/npx" ]; } && ok "root layout: the npm/npx shims are mirrored" || no "npm shims not mirrored"

# A read-only HOME (Codex Cloud's setup: only /workspace and /tmp are writable): everything goes to
# <workspace>/.cloud, nothing under HOME, and the summary names the prefix.
RO="$t/ro"; mkdir -p "$RO/home" "$RO/ws" "$RO/repo/scripts/cloud"; : > "$RO/repo/scripts/cloud/manifest"; chmod 555 "$RO/home"
if [ -w "$RO/home" ]; then
  echo "  - read-only HOME tests skipped (running as root: chmod 555 does not stop writes)"
else
  ro() { /usr/bin/env -i HOME="$RO/home" PATH="$NR/fake:$NR/tools" TMPDIR="$t" CLOUD_SETUP_WORKSPACE="$RO/ws" CLOUD_SETUP_ROOTS="$NR/none/*" "$@"; }
  P="$RO/ws/.cloud"
  [ "$(ro "$NR/tools/bash" -c ". '$here/lib/common.sh'; $paths")" = "$P/bin|$P/opt|$P/share/cloud-env|1|$P|$P/home" ] \
    && ok "read-only HOME: bin, opt, share under <workspace>/.cloud" || no "read-only HOME paths: $(ro "$NR/tools/bash" -c ". '$here/lib/common.sh'; $paths")"
  [ "$(ro CLOUD_SETUP_PREFIX="$RO/ws/mine" "$NR/tools/bash" -c ". '$here/lib/common.sh'; echo \$BIN")" = "$RO/ws/mine/bin" ] \
    && ok "read-only HOME: CLOUD_SETUP_PREFIX wins" || no "CLOUD_SETUP_PREFIX"
  out="$(ro "$NR/tools/bash" "$here/setup.sh" --repo "$RO/repo")"; rc=$?
  ( . "$here/pins.env"
    [ "$("$P/bin/gh" --version)" = "gh version $GH_PIN (fixture)" ] && [ "$("$P/bin/jq" --version)" = "jq-$JQ_PIN" ] \
      && [ "$("$P/bin/pandoc" --version)" = "pandoc $PANDOC_PIN" ] && [ -d "$P/opt/gh_${GH_PIN}_linux_$narch" ] ) \
    && [ $rc = 0 ] && grep -Eq "^cloud-setup: core=ok secs=[0-9]+ prefix=$P log=$P/share/cloud-env/setup.log$" <<<"$out" \
    && ok "read-only HOME: core installs into the prefix, summary says prefix=" || no "read-only HOME run: rc=$rc $out $(ls "$P/bin" 2>&1)"
  [ "$(cut -c1-5 "$P/share/cloud-env/setup-result")" = base= ] && ! grep -q ERROR "$P/share/cloud-env/setup-result" \
    && ok "read-only HOME: setup-result in <prefix>/share/cloud-env, no error" || no "read-only result: $(cat "$P/share/cloud-env/setup-result" 2>&1)"
  grep -q 'HOME is read-only; user-level Claude Code SessionStart hook skipped' "$P/share/cloud-env/setup.log" \
    && ok "read-only HOME: SessionStart hook skipped with a note, core not failed" || no "read-only hook note"
  [ -z "$(ls -A "$RO/home")" ] && ok "read-only HOME: nothing written under HOME" || no "wrote under HOME: $(ls -A "$RO/home")"
  [ "$(ro "$NR/tools/bash" -c ". '$P/env'; echo \$CLOUD_PREFIX; command -v gh")" = "$P"$'\n'"$P/bin/gh" ] \
    && ok "read-only HOME: <prefix>/env records the prefix and puts its bin on PATH" || no "prefix env: $(cat "$P/env" 2>&1)"
  ( . "$here/pins.env"; printf '#!/bin/sh\necho "$HOME" > %s/uv-home; echo ok\n' "$RO" > "$NR/rel/uv-install.sh" )
  ro UV_PIN=none "$NR/tools/bash" -c ". '$here/lib/common.sh'; uv() { :; }; curl() { cat '$NR/rel/uv-install.sh'; }; . '$here/modules/core.sh'; core_uv" >/dev/null 2>&1
  [ "$(cat "$RO/uv-home" 2>/dev/null)" = "$P/home" ] && ok "read-only HOME: third-party installers get <prefix>/home as HOME" || no "installer HOME: $(cat "$RO/uv-home" 2>&1)"
  # Bootstrap (piped from curl): the self-download goes to <prefix>/share/cloud-setup; a failed one is
  # still recorded, in the prefix.
  (cd "$t" && ro PATH="$PATH" CLOUD_SETUP_TARBALL="file://$t/src.tgz" bash -s -- --fetch-only < "$here/setup.sh"); rc=$?
  [ $rc = 0 ] && [ "$(cat "$P/share/cloud-setup/.commit" 2>/dev/null)" = "$sha" ] && ok "read-only HOME: bootstrap downloads to <prefix>/share/cloud-setup" || no "read-only bootstrap rc=$rc"
  (cd "$t" && ro CLOUD_SETUP_PREFIX="$RO/ws/p2" CLOUD_SETUP_TARBALL="file://$t/missing.tgz" "$NR/tools/bash" -s < "$here/setup.sh" 2>/dev/null); rc=$?
  [ $rc = 0 ] && grep -q '^ERROR=could not download' "$RO/ws/p2/share/cloud-env/setup-result" && ok "read-only HOME: a failed bootstrap is recorded in the prefix" || no "read-only bootstrap failure rc=$rc"
  # Hand-off: the stub gets CLOUD_SETUP_PREFIX and records the layer in <prefix>/share/cloud-env/source.
  HL="$t/layer3"; mkdir -p "$HL"; rm -f "$t/calls"
  printf 'echo "stub prefix=$CLOUD_SETUP_PREFIX" >> "%s/calls"; echo "clone %s" > "$CLOUD_SETUP_PREFIX/share/cloud-env/source"\n' "$t" "$HL" > "$RO/repo/scripts/cloud/env-setup.sh"
  printf 'echo "install-time $*" >> "%s/calls"\n' "$t" > "$HL/install-time.sh"
  out="$(ro OP_CONNECT_HOST=https://op.test OP_CONNECT_TOKEN=t "$NR/tools/bash" "$here/setup.sh" --repo "$RO/repo")"
  [ "$(paste -sd'|' "$t/calls")" = "stub prefix=$P|install-time --repo $RO/repo" ] && grep -q 'session-layer=ok' <<<"$out" && [ -z "$(ls -A "$RO/home")" ] \
    && ok "read-only HOME: hand-off passes the prefix, reads <prefix>/share/cloud-env/source" || no "read-only hand-off: $out / $(cat "$t/calls" 2>/dev/null)"
fi

# The rust module: our own rustup (never the image's), standard dirs on a writable HOME, <prefix>/opt
# on a read-only one, wrappers in $BIN that pin RUSTUP_HOME/CARGO_HOME, the repo's toolchain pin.
# A fake curl serves a fake rustup-init (which lays down a fake rustup and proxies); no network.
RS="$t/rs"; RS_FIX="$RS/fix"; RS_LOG="$RS/calls.log"; export RS_FIX RS_LOG
mkdir -p "$RS/fake" "$RS/sys" "$RS_FIX" "$RS/ws" "$RS/repo/scripts/cloud" "$RS/repo2/scripts/cloud"
printf '#!/bin/sh\n[ "$1" = -u ] && { echo 1000; exit 0; }; exec %s "$@"\n' "$realid" > "$RS/fake/id"
cat > "$RS/fake/curl" <<'SH'
#!/bin/sh
echo "$*" >> "$RS_LOG.curl"
[ -z "${RS_CURL_FAIL:-}" ] || exit 22
case "$*" in *https://sh.rustup.rs*) cat "$RS_FIX/installer" ;; *) exit 22 ;; esac
SH
cat > "$RS_FIX/installer" <<'SH'
echo "init $* | HOME=$HOME RUSTUP_HOME=$RUSTUP_HOME CARGO_HOME=$CARGO_HOME SKIP=$RUSTUP_INIT_SKIP_PATH_CHECK" >> "$RS_LOG"
mkdir -p "$CARGO_HOME/bin" "$RUSTUP_HOME"
echo stable > "$RUSTUP_HOME/default"
cp "$RS_FIX/rustup" "$CARGO_HOME/bin/rustup"
for n in cargo rustc rustfmt cargo-clippy clippy-driver rustdoc; do cp "$RS_FIX/proxy" "$CARGO_HOME/bin/$n"; done
SH
cat > "$RS_FIX/pin" <<'SH'
# prints the channel a rust-toolchain[.toml] in $PWD pins (nothing without one)
for f in rust-toolchain.toml rust-toolchain; do
  [ -f "$PWD/$f" ] || continue
  v="$(sed -n 's/.*channel *= *"\([^"]*\)".*/\1/p' "$PWD/$f")"; [ -n "$v" ] || v="$(head -1 "$PWD/$f")"
  echo "$v"; break
done
SH
cat > "$RS_FIX/rustup" <<'SH'
#!/bin/sh
echo "rustup $* | pwd=$PWD RUSTUP_HOME=$RUSTUP_HOME CARGO_HOME=$CARGO_HOME" >> "$RS_LOG"
install_pin() { v="$(sh "$RS_FIX/pin")"; [ -n "$v" ] && echo "$v" >> "$RUSTUP_HOME/installed"; return 0; }
case "$1 $2" in
  "--version ") echo "rustup 1.99.0 (ours) RUSTUP_HOME=$RUSTUP_HOME CARGO_HOME=$CARGO_HOME" ;;
  "show active-toolchain") [ -f "$RUSTUP_HOME/default" ] ;;
  "default stable") echo stable > "$RUSTUP_HOME/default" ;;
  "toolchain install") [ -z "${RS_OLD_RUSTUP:-}" ] || exit 2; install_pin ;;
  "show ") install_pin ;;
esac
exit 0
SH
cat > "$RS_FIX/proxy" <<'SH'
#!/bin/sh
case "$(basename "$0")" in
  rustc) v="$(sh "$RS_FIX/pin")"
         if [ -n "$v" ]; then grep -qx "$v" "$RUSTUP_HOME/installed" 2>/dev/null || { echo "toolchain '$v' is not installed" >&2; exit 1; }
         else [ -f "$RUSTUP_HOME/default" ] || exit 1; v=1.97.1; fi
         echo "rustc $v (fixture)" ;;
  *) echo "$(basename "$0") RUSTUP_HOME=$RUSTUP_HOME CARGO_HOME=$CARGO_HOME $*" ;;
esac
SH
printf '#!/bin/sh\necho SYSTEM-RUSTUP >> "$RS_LOG"; echo "rustup 1.20.0 (system)"\n' > "$RS/sys/rustup"; chmod +x "$RS/fake/"* "$RS/sys/rustup" "$RS_FIX/rustup" "$RS_FIX/proxy"
printf 'rust\n' > "$RS/repo/scripts/cloud/manifest"; printf 'node\n' > "$RS/repo2/scripts/cloud/manifest"
# rsmod <phase> <home> [VAR=val...]: run modules/rust.sh's phase as a session would (REPO from $RS_REPO).
rsmod() {
  local phase="$1" h="$2"; shift 2
  env HOME="$h" PATH="$RS/fake:$RS/sys:$PATH" REPO="${RS_REPO:-}" REPOS="${RS_REPOS:-${RS_REPO:-}}" CLOUD_SETUP_WORKSPACE="$RS/ws" \
    CLOUD_SETUP_PREFIX= "$@" bash -c ". '$here/lib/common.sh'; run_module $phase rust"
}
wrap() { printf '#!/bin/sh\n# cloud-setup rust: run the real %s from our own rustup\nexport RUSTUP_HOME=%s CARGO_HOME=%s\nexec %s/bin/%s "$@"\n' "$1" "$2" "$3" "$3" "$1"; }

[ -n "$(lib 'module_description rust')" ] && lib 'known_modules' | grep -qx rust \
  && ok "rust: registered, with a --list description" || no "rust module registry"
# Writable HOME, no repo pin: ~/.rustup, ~/.cargo; stable minimal; wrappers in ~/.local/bin; the image's rustup ignored.
H1="$RS/h1"; mkdir -p "$H1"; : > "$RS_LOG"; : > "$RS_LOG.curl"
RS_REPO="$RS/repo" rsmod setup "$H1" RUSTUP_HOME=/image/rustup CARGO_HOME=/image/cargo; rc=$?
[ $rc = 0 ] && [ -x "$H1/.cargo/bin/rustup" ] \
  && grep -qxF "init -y --no-modify-path --profile minimal | HOME=$H1 RUSTUP_HOME=$H1/.rustup CARGO_HOME=$H1/.cargo SKIP=yes" "$RS_LOG" \
  && grep -qxF -- "--proto =https --tlsv1.2 -sSf https://sh.rustup.rs" "$RS_LOG.curl" \
  && ok "rust: rustup installed in ~/.cargo + ~/.rustup (minimal, no rc edits), whatever the image exports" || no "rust writable HOME: rc=$rc $(cat "$RS_LOG")"
! grep -q 'toolchain install' "$RS_LOG" && ! grep -q SYSTEM-RUSTUP "$RS_LOG" && ok "rust: no pin → stable only; the system rustup is never run" || no "rust no-pin: $(cat "$RS_LOG")"
miss=""; for n in cargo rustc rustup rustfmt cargo-clippy clippy-driver rustdoc; do [ -x "$H1/.local/bin/$n" ] || miss="$miss $n"; done
[ -z "$miss" ] && [ "$(cat "$H1/.local/bin/rustup")" = "$(wrap rustup "$H1/.rustup" "$H1/.cargo")" ] \
  && ok "rust: wrappers for cargo rustc rustup rustfmt cargo-clippy clippy-driver rustdoc in \$BIN" || no "rust wrappers:$miss"
[ "$(env RUSTUP_HOME=/image/rustup CARGO_HOME=/image/cargo "$H1/.local/bin/cargo" build)" = "cargo RUSTUP_HOME=$H1/.rustup CARGO_HOME=$H1/.cargo build" ] \
  && ok "rust: a wrapper overrides the image's RUSTUP_HOME/CARGO_HOME and passes arguments" || no "rust wrapper env"
# A system rustup first on PATH is not reused: ours is installed, and $BIN's wrapper is what `rustup` resolves to.
[ "$(env PATH="$H1/.local/bin:$RS/sys:$PATH" bash -c 'command -v rustup')" = "$H1/.local/bin/rustup" ] && [ "$(PATH="$H1/.local/bin:$RS/sys:$PATH" rustup --version)" = "rustup 1.99.0 (ours) RUSTUP_HOME=$H1/.rustup CARGO_HOME=$H1/.cargo" ] \
  && ok "rust: an existing system rustup is not reused (ours wins on PATH)" || no "rust system rustup shadowing"
[ "$(RS_REPO="$RS/repo" rsmod status "$H1")" = "rust=1.97.1" ] && ok "rust: status → rust=1.97.1" || no "rust status: $(RS_REPO="$RS/repo" rsmod status "$H1")"
# Idempotent: a rerun downloads nothing, re-runs no installer.
n="$(wc -l < "$RS_LOG.curl")"; RS_REPO="$RS/repo" rsmod setup "$H1"; rc=$?
[ $rc = 0 ] && [ "$(wc -l < "$RS_LOG.curl")" = "$n" ] && [ "$(grep -c '^init ' "$RS_LOG")" = 1 ] && ok "rust: rerun is a no-op (no download, no second install)" || no "rust rerun: rc=$rc"
# Pins: rust-toolchain.toml → `rustup toolchain install` in that repo; the pinned channel is what runs there.
printf '[toolchain]\nchannel = "1.95.0"\ncomponents = ["clippy"]\n' > "$RS/repo/rust-toolchain.toml"
: > "$RS_LOG"; RS_REPO="$RS/repo" rsmod setup "$H1"; rc=$?
[ $rc = 0 ] && grep -qF "rustup toolchain install | pwd=$RS/repo " "$RS_LOG" && [ "$(RS_REPO="$RS/repo" rsmod status "$H1")" = "rust=1.95.0" ] \
  && ok "rust: rust-toolchain.toml honored (installed from the repo dir; status shows the pin)" || no "rust pin: rc=$rc $(cat "$RS_LOG")"
rm "$RS/repo/rust-toolchain.toml"; echo 1.94.0 > "$RS/repo/rust-toolchain"; rm -f "$H1/.rustup/installed"; : > "$RS_LOG"
RS_REPO="$RS/repo" rsmod setup "$H1"; rc=$?
[ $rc = 0 ] && [ "$(RS_REPO="$RS/repo" rsmod status "$H1")" = "rust=1.94.0" ] && ok "rust: legacy rust-toolchain file honored" || no "rust legacy pin: rc=$rc"
rm -f "$H1/.rustup/installed"; : > "$RS_LOG"; RS_REPO="$RS/repo" rsmod setup "$H1" RS_OLD_RUSTUP=1; rc=$?
[ $rc = 0 ] && grep -qF "rustup show | pwd=$RS/repo " "$RS_LOG" && [ "$(RS_REPO="$RS/repo" rsmod status "$H1")" = "rust=1.94.0" ] \
  && ok "rust: an older rustup (no 'toolchain install' without arguments) falls back to 'rustup show'" || no "rust old rustup: rc=$rc $(cat "$RS_LOG")"
# Several repos: only the ones whose manifest lists rust are acted on.
printf '[toolchain]\nchannel = "1.80.0"\n' > "$RS/repo2/rust-toolchain.toml"; rm -f "$H1/.rustup/installed"; : > "$RS_LOG"
RS_REPO="$RS/repo" RS_REPOS="$RS/repo
$RS/repo2" rsmod setup "$H1"
grep -qF "pwd=$RS/repo " "$RS_LOG" && ! grep -qF "pwd=$RS/repo2" "$RS_LOG" && ok "rust: several repos: only those whose manifest names rust" || no "rust several repos: $(cat "$RS_LOG")"
rm -f "$RS/repo/rust-toolchain" "$RS/repo2/rust-toolchain.toml"
# Failure is a failed step (non-zero, named), never a crash; status says missing. Through setup.sh: exit 0.
H2="$RS/h2"; mkdir -p "$H2"; err="$(RS_REPO="$RS/repo" rsmod setup "$H2" RS_CURL_FAIL=1 2>&1)"; rc=$?
[ $rc != 0 ] && grep -q 'rust: rustup install failed' <<<"$err" && [ ! -e "$H2/.local/bin/cargo" ] && [ "$(RS_REPO="$RS/repo" rsmod status "$H2")" = "rust=missing" ] \
  && ok "rust: download fails → non-zero, named, no wrappers; status → rust=missing" || no "rust failure: rc=$rc $err"
cp "$here/modules/rust.sh" "$F/modules/rust.sh"; printf 'rust\n' > "$F/repo/scripts/cloud/manifest"; mkdir -p "$F/rh"
out="$(cd "$F/repo" && env -u CLOUD_SETUP_HOME HOME="$F/rh" PATH="$RS/fake:$PATH" RS_CURL_FAIL=1 CLOUD_SETUP_ROOTS="$F/none/*" bash "$F/setup.sh")"; rc=$?
[ $rc = 0 ] && grep -q 'rust=failed(1)' <<<"$out" && ok "rust: through setup.sh a failed install still exits 0" || no "rust via setup.sh: rc=$rc $out"
rm "$F/modules/rust.sh"
# Read-only HOME (Codex Cloud): the existing prefix's opt/ holds rustup + cargo, wrappers go in its bin/, HOME stays untouched.
RH="$RS/rohome"; mkdir -p "$RH"; chmod 555 "$RH"
if [ -w "$RH" ]; then
  echo "  - rust read-only HOME tests skipped (running as root: chmod 555 does not stop writes)"
else
  P="$RS/ws/.cloud"; : > "$RS_LOG"
  RS_REPO="$RS/repo" rsmod setup "$RH" RUSTUP_HOME=/image/rustup CARGO_HOME=/image/cargo; rc=$?
  [ $rc = 0 ] && [ -x "$P/opt/cargo/bin/rustup" ] && [ -z "$(ls -A "$RH")" ] \
    && grep -qxF "init -y --no-modify-path --profile minimal | HOME=$P/home RUSTUP_HOME=$P/opt/rustup CARGO_HOME=$P/opt/cargo SKIP=yes" "$RS_LOG" \
    && ok "rust: read-only HOME → <prefix>/opt/{rustup,cargo}, installer gets <prefix>/home, nothing under HOME" || no "rust read-only: rc=$rc $(cat "$RS_LOG"; ls -A "$RH")"
  miss=""; for n in cargo rustc rustup rustfmt cargo-clippy clippy-driver rustdoc; do [ -x "$P/bin/$n" ] || miss="$miss $n"; done
  [ -z "$miss" ] && [ "$(cat "$P/bin/cargo")" = "$(wrap cargo "$P/opt/rustup" "$P/opt/cargo")" ] \
    && ok "rust: read-only HOME: the seven wrappers are in <prefix>/bin" || no "rust read-only wrappers:$miss"
  [ "$(env -i RS_FIX="$RS_FIX" RS_LOG="$RS_LOG" PATH="$P/bin:/usr/bin:/bin" "$NR/tools/bash" -c 'cargo test; rustc -V' 2>&1)" = "cargo RUSTUP_HOME=$P/opt/rustup CARGO_HOME=$P/opt/cargo test"$'\n'"rustc 1.97.1 (fixture)" ] \
    && ok "rust: read-only HOME: an agent that only has <prefix>/bin on PATH gets the right RUSTUP_HOME/CARGO_HOME" || no "rust read-only agent PATH: $(env -i RS_FIX="$RS_FIX" RS_LOG="$RS_LOG" PATH="$P/bin:/usr/bin:/bin" "$NR/tools/bash" -c "cargo test; rustc -V" 2>&1)"
  [ "$(RS_REPO="$RS/repo" rsmod status "$RH")" = "rust=1.97.1" ] && ok "rust: read-only HOME: status → rust=1.97.1" || no "rust read-only status"
fi

exit $fail
