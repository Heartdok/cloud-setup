# node — the repo's JS deps from its lockfile: `bun install --frozen-lockfile` (a package-lock.json is migrated by bun)
# shellcheck shell=bash

node_deps() { [ -f package.json ] && bun install --frozen-lockfile; }
node_status() { [ -d node_modules ] && echo "node_modules=ok" || echo "node_modules=missing"; }
setup() { in_repos_wanting node node_deps; }
status() { local r; while IFS= read -r r; do [ -n "$r" ] && (cd "$r" && node_status); done < <(repos_wanting node) | sort -u | paste -sd' '; }
