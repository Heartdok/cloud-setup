# python — the repo's Python (uv reads .python-version) and its locked deps: `uv sync --frozen`
# shellcheck shell=bash

python_deps() { [ -f pyproject.toml ] && uv python install && uv sync --frozen; }
python_status() { [ -d .venv ] && echo "venv=ok" || echo "venv=missing"; }
setup() { in_repos_wanting python python_deps; }
status() { local r; while IFS= read -r r; do [ -n "$r" ] && (cd "$r" && python_status); done < <(repos_wanting python) | sort -u | paste -sd' '; }
