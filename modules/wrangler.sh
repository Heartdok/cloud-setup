# wrangler — Cloudflare's CLI (latest); authenticates itself from CLOUDFLARE_API_TOKEN / CLOUDFLARE_ACCOUNT_ID at run time
# shellcheck shell=bash

setup() {
  local dir="$SHARE/wrangler"
  mkdir -p "$dir" && { [ -f "$dir/package.json" ] || printf '{"private":true}\n' > "$dir/package.json"; }
  (cd "$dir" && bun add wrangler@latest >/dev/null) && link wrangler "$dir/node_modules/.bin/wrangler"
  wrangler --version >/dev/null
}

status() { echo "wrangler=$(ver wrangler --version)"; }
