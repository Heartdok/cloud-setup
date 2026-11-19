# cpsat — Google OR-Tools' CP-SAT solver for Python (ORTOOLS_PIN): `from ortools.sat.python import cp_model` in python3
# Installed with pip into the python3 on PATH (the image's), as root or with sudo. Without root it goes to
# the user site (`pip --user`); with a read-only HOME it fails by name.
# shellcheck shell=bash

cpsat_have() { [ "$(python3 -c 'import ortools; print(ortools.__version__)' 2>/dev/null)" = "$ORTOOLS_PIN" ]; }

setup() {
  cpsat_have && return 0
  local py; py="$(command -v python3)" || { echo "cpsat: no python3 on PATH" >&2; return 1; }
  local pip=("$py" -m pip install --quiet --disable-pip-version-check "ortools==$ORTOOLS_PIN")
  # sudo's own PATH may find another python3, hence the absolute path.
  # shellcheck disable=SC2206 # $SUDO is empty, `sudo -n` or a refusing stub: split on purpose
  if can_root; then pip=($SUDO "${pip[@]}"); else pip+=(--user); fi
  # Debian-family pythons refuse pip outside a venv (PEP 668); this python3 is the sandbox's own.
  "${pip[@]}" >/dev/null 2>&1 || "${pip[@]}" --break-system-packages >/dev/null 2>&1 || { echo "cpsat: pip install ortools==$ORTOOLS_PIN failed" >&2; return 1; }
  cpsat_have
}

drift() { cpsat_have || echo ortools; }
reconcile() { setup; }

status() { local v; v="$(python3 -c 'import ortools; print(ortools.__version__)' 2>/dev/null)"; echo "ortools=${v:-missing}"; }
