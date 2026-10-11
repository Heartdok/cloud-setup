#!/usr/bin/env bash
# Rewrite pins.env with the latest stable releases. Run by .github/workflows/bump-pins.yml,
# which opens a PR when anything changed. Each lookup that fails keeps the current pin.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
. ./pins.env

gh_latest() { # owner/repo → tag without leading v
  curl -fsSL ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} \
    "https://api.github.com/repos/$1/releases/latest" | jq -r '.tag_name' | sed 's/^v//; s/^bun-v//; s/^jq-//'
}
npm_latest() { curl -fsSL "https://registry.npmjs.org/$1/latest" | jq -r .version; }
set_pin() { # NAME value
  [ -n "$2" ] && [ "$2" != null ] || { echo "keep $1 (lookup failed)"; return; }
  sed -i.bak "s|^$1=.*|$1=$2|" pins.env && rm -f pins.env.bak
}

set_pin UV_PIN "$(gh_latest astral-sh/uv)"
set_pin BUN_PIN "$(gh_latest oven-sh/bun)"
set_pin PANDOC_PIN "$(gh_latest jgm/pandoc)"
set_pin GH_PIN "$(gh_latest cli/cli)"
set_pin JQ_PIN "$(gh_latest jqlang/jq)"
set_pin GIT_LFS_PIN "$(gh_latest git-lfs/git-lfs)"
set_pin NODE_PIN "$(curl -fsSL https://nodejs.org/dist/index.json | jq -r '[.[] | select(.lts != false)][0].version' | sed 's/^v//')"
set_pin CODEX_PIN "$(npm_latest @openai/codex)"
set_pin OP_CLI_PIN "$(curl -fsSL https://app-updates.agilebits.com/check/1/0/CLI2/en/2.0.0/N | jq -r .version)"

series="$(curl -fsSL https://download.blender.org/release/ | grep -oE 'Blender[0-9]+\.[0-9]+/' | sort -V | tail -1 | tr -d /)"
if [ -n "$series" ]; then
  tarball="$(curl -fsSL "https://download.blender.org/release/$series/" | grep -oE 'blender-[0-9.]+-linux-x64\.tar\.xz' | sort -V | tail -1)"
  ver="$(echo "$tarball" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
  sha="$(curl -fsSL "https://download.blender.org/release/$series/blender-$ver.sha256" 2>/dev/null | awk -v f="$tarball" '$2==f{print $1}')"
  if [ -n "$ver" ] && [ -n "$sha" ]; then set_pin BLENDER_PIN "$ver"; set_pin BLENDER_SHA256 "$sha"; else echo "keep BLENDER_PIN (no sha)"; fi
fi

set_pin BLENDER_MCP_REF "$(git ls-remote https://projects.blender.org/lab/blender_mcp.git refs/heads/main | cut -f1)"
git diff --stat -- pins.env
