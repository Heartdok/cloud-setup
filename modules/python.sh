# python — the repo's Python (uv reads .python-version) and its locked deps: `uv sync --frozen`
# shellcheck shell=bash

setup() { cd "$REPO" && [ -f pyproject.toml ] && uv python install && uv sync --frozen; }
status() { (cd "$REPO" && [ -d .venv ]) && echo "venv=ok" || echo "venv=missing"; }
