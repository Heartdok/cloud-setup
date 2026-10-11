# python — the repo's Python (uv reads .python-version) and its locked deps: `uv sync --frozen`
# shellcheck shell=bash
# shellcheck disable=SC2034 # read by module_scope (lib/common.sh): setup runs in each repo listing it
scope="repo"

setup() { cd "$REPO" && [ -f pyproject.toml ] && uv python install && uv sync --frozen; }
status() { (cd "$REPO" && [ -d .venv ]) && echo "venv=ok" || echo "venv=missing"; }
