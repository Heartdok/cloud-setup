# node — the repo's JS deps from its lockfile: `bun install --frozen-lockfile` (a package-lock.json is migrated by bun)
# shellcheck shell=bash

setup() { cd "$REPO" && [ -f package.json ] && bun install --frozen-lockfile; }
status() { (cd "$REPO" && [ -d node_modules ]) && echo "node_modules=ok" || echo "node_modules=missing"; }
