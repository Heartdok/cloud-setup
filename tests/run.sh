#!/usr/bin/env bash
# Offline tests: manifest parsing, repo discovery, the always-exit-0 contract, the time budget,
# self-download, pins and the session hook. Nothing is installed.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
fail=0; ok() { echo "  ✓ $*"; }; no() { echo "  ✗ $*"; fail=1; }
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
lib() { bash -c ". '$here/lib/common.sh'; $1"; }

# Manifest
printf '# comment\noffice  blender-mcp\npython # trailing\nexcel-native\n' > "$t/manifest"
[ "$(lib "resolve_modules '$t/manifest' | tr '\n' ' '")" = "core blender blender-mcp office python " ] \
  && ok "core first, requirements before dependents, unknown names dropped" || no "resolution: $(lib "resolve_modules '$t/manifest'")"
[ "$(lib "validate_manifest '$t/manifest'")" = excel-native ] && ! lib "validate_manifest '$t/manifest'" >/dev/null \
  && ok "unknown module named" || no "validate_manifest"
lib "validate_manifest '$t/none'" && ok "missing manifest is not an unknown module" || no "missing manifest"
lib 'known_modules' | grep -qx office && ! lib 'known_modules' | grep -qx core && ok "registry = modules/*.sh minus core" || no "known_modules"
[ -n "$(lib 'module_description office')" ] && ok "module descriptions" || no "module_description"

# Repo discovery
mkdir -p "$t/home/u/plain" "$t/home/u/proj/scripts/cloud" "$t/home/u/proj/sub" "$t/home/u/gitonly" "$t/empty"
touch "$t/home/u/proj/scripts/cloud/manifest"; git -C "$t/home/u/proj" init -q; git -C "$t/home/u/gitonly" init -q
disc() { (cd "$1" && CLOUD_SETUP_ROOTS="${2:-$t/home/*/*}" bash -c ". '$here/lib/common.sh'; discover_repo"); }
[ "$(disc "$t/home/u/proj/sub")" = "$(cd "$t/home/u/proj" && pwd -P)" ] && ok "discover: git toplevel of \$PWD" || no "discover toplevel: $(disc "$t/home/u/proj/sub")"
[ "$(disc "$t/empty")" = "$t/home/u/proj" ] && ok "discover: first repo with a manifest under the roots" || no "discover roots: $(disc "$t/empty")"
[ "$(disc "$t/empty" "$t/home/u/gitonly $t/home/u/plain")" = "$t/home/u/gitonly" ] && ok "discover: else the first git repo" || no "discover git: $(disc "$t/empty" "$t/home/u/gitonly")"
[ "$(disc "$t/empty" "$t/nowhere/*")" = "$t/empty" ] && ok "discover: else \$PWD" || no "discover pwd"

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
run() { (cd "$F/repo" && env -u CLOUD_SETUP_HOME HOME="$F/home" CLOUD_SETUP_ROOTS="${ROOTS:-$t/noroots/*}" CLOUD_SETUP_BUDGET="${BUDGET:-240}" bash "$F/setup.sh" "$@"); }
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
# Multi-repo: every repo with scripts/cloud/ under the roots joins; modules merge, each repo's
# setup.local.sh runs ("local:<name>" past the first), a repo-scoped module runs in each repo listing it.
mkdir -p "$F/roots/two/scripts/cloud" "$F/roots/bare"
printf 'good\n' > "$F/repo/scripts/cloud/manifest"; printf 'zlate scoped\n' > "$F/roots/two/scripts/cloud/manifest"
printf 'echo local-two-ran\n' > "$F/roots/two/scripts/cloud/setup.local.sh"
printf 'echo local-one-ran\n' > "$F/repo/scripts/cloud/setup.local.sh"
printf 'scope="repo"\nsetup() { echo "scoped-in $REPO"; }\n' > "$F/modules/scoped.sh"
out="$(ROOTS="$F/roots/*" run)"; res="$(cat "$F/home/.local/share/cloud-env/setup-result")"
log="$F/home/.local/share/cloud-env/setup.log"
grep -q 'core=ok good=ok scoped=ok zlate=ok local=ok local:two=ok' <<<"$out" && ! grep -q ERROR <<<"$res" \
  && ok "multi-repo: modules merged, each repo's setup.local.sh, clean result" || no "multi-repo: $out / $res"
grep -q "scoped-in $(cd "$F/roots/two" && pwd -P)\$" "$log" && ! grep -q "scoped-in $F/repo" "$log" \
  && ok "multi-repo: repo-scoped module runs in the repo that lists it" || no "multi-repo scope: $(grep scoped-in "$log")"
grep -q "repos=$(cd "$F/repo" && pwd -P) $(cd "$F/roots/two" && pwd -P) " "$log" && ok "multi-repo: \$PWD's repo first, bare dir skipped" || no "multi-repo order: $(head -1 "$log")"
printf 'nope2\n' >> "$F/roots/two/scripts/cloud/manifest"; ROOTS="$F/roots/*" run >/dev/null
grep -q 'unknown module(s) in two: nope2' "$F/home/.local/share/cloud-env/setup-result" && ok "multi-repo: unknown module names its repo" || no "multi-repo unknown: $(cat "$F/home/.local/share/cloud-env/setup-result")"
rm -rf "$F/roots" "$F/modules/scoped.sh" "$F/repo/scripts/cloud/setup.local.sh"
d2() { (cd "$1" && CLOUD_SETUP_ROOTS="$2" bash -c ". '$here/lib/common.sh'; discover_repos" | tr '\n' ' '); }
mkdir -p "$t/dr/a/scripts/cloud" "$t/dr/b/scripts/cloud" "$t/dr/c"; touch "$t/dr/a/scripts/cloud/session.local.sh" "$t/dr/b/scripts/cloud/secrets.manifest.json"
[ "$(d2 "$t/dr/b" "$t/dr/*")" = "$(cd "$t/dr/b" && pwd -P) $(cd "$t/dr/a" && pwd -P) " ] && ok "discover_repos: \$PWD first, any scripts/cloud file counts, deduplicated" || no "discover_repos: $(d2 "$t/dr/b" "$t/dr/*")"

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
[ -z "$(cd "$t/hkrun/r" && bash -c "$cmd")" ] && ok "session hook is a no-op outside remote sessions" || no "session hook ran locally"
echo '{"hooks":{"SessionStart":[{"hooks":[{"command":"bash scripts/cloud/session-start.sh"}]}]}}' > "$t/hkrun/r/.claude/settings.json"
[ -z "$(cd "$t/hkrun/r" && CLAUDE_CODE_REMOTE=true bash -c "$cmd")" ] && ok "session hook defers to the project's own hook" || no "session hook double-runs"

exit $fail
