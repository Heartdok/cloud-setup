# blender-mcp — Blender Lab's MCP server (BLENDER_MCP_REF) as a uv tool, plus the `cloud-env-blender-mcp` launcher for .mcp.json
# Headless only: the *_for_cli and doc-search tools work in a sandbox; live-scene tools need a
# desktop Blender. Requires the blender module.
# shellcheck shell=bash

# shellcheck disable=SC2034 # read by lib/common.sh requires_of
requires="blender"

setup() {
  UV_TOOL_BIN_DIR="$BIN" uv tool install --force \
    "blender-mcp @ git+https://projects.blender.org/lab/blender_mcp.git@${BLENDER_MCP_REF}#subdirectory=mcp" || return 1
  launcher
}

# Reconcile: uv's receipt for the tool records the git rev it was installed from.
drift() { grep -qF "rev=$BLENDER_MCP_REF" "$(uv tool dir 2>/dev/null)/blender-mcp/uv-receipt.toml" 2>/dev/null || echo blender-mcp; }
reconcile() { setup; }

status() { command -v blender-mcp >/dev/null && echo "blender-mcp=ok" || echo "blender-mcp=missing"; }

# .mcp.json: {"mcpServers":{"blender":{"command":"cloud-env-blender-mcp"}}} — stdout is the MCP
# channel, so nothing else may print there.
launcher() {
  install -m 755 /dev/stdin "$BIN/cloud-env-blender-mcp" <<'SH'
#!/usr/bin/env bash
[ -n "${BLENDER_PATH:-}" ] || BLENDER_PATH="$(command -v blender 2>/dev/null)"; export BLENDER_PATH
exec blender-mcp "$@"
SH
}
