# node — the repo's JS deps from its lockfile: `bun install --frozen-lockfile` (a package-lock.json is migrated by bun)
# shellcheck shell=bash
# shellcheck disable=SC2034 # read by module_scope (lib/common.sh): setup runs in each repo listing it
scope="repo"

setup() { cd "$REPO" && [ -f package.json ] && bun install --frozen-lockfile; }
status() { (cd "$REPO" && [ -d node_modules ]) && echo "node_modules=ok" || echo "node_modules=missing"; }
