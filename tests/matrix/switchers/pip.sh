#!/usr/bin/env bash
# Switch active pip version for a single matrix cell.
#
# Called by ../run.sh as:
#   switchers/pip.sh <python_label> <pip_version>
# e.g.:
#   switchers/pip.sh system 24.3
#
# The python axis intentionally has one value ("system") because the cross-
# distro matrix already exercises different python versions naturally —
# Ubuntu 22.04 ships python 3.10, Ubuntu 24.04 ships 3.12, Debian 12 ships
# 3.11. Re-installing pythons inside a container per cell would duplicate
# what the distro axis already covers.
#
# The pip axis tests pip versions that real users have installed. The role's
# /usr/local/bin/pip wrapper redirects to uv regardless of pip version, but
# the wrapper itself is invoked with `python3 -m pip` for some scenarios
# (the documented bypass per README) and that path is pip-version-sensitive.

set -euo pipefail

PYTHON_LABEL="${1:?usage: $0 <python_label> <pip_version>}"
PIP_VERSION="${2:?usage: $0 <python_label> <pip_version>}"

[[ "$PYTHON_LABEL" = "system" ]] || {
  echo "switchers/pip.sh: only 'system' python is supported in v1 (got '$PYTHON_LABEL')" >&2
  exit 1
}

PYTHON_BIN="$(command -v python3)"
[[ -x "$PYTHON_BIN" ]] || { echo "switchers/pip.sh: python3 not on PATH" >&2; exit 1; }

# Install the requested pip version. Three options for handling PEP 668:
#   1. --break-system-packages — Debian 12 / Ubuntu 24.04 require this for
#      system-python pip installs
#   2. --user — installs to ~/.local/bin/pip; works pre-PEP-668 but doesn't
#      override the system pip
#   3. venv — too heavy per-cell
# Going with (1) because we're inside a disposable container; "breaking"
# system packages is meaningless here. If/when the matrix runs against a
# real (non-disposable) host, this script would need rethinking.
if [[ "$PIP_VERSION" = "bundled" ]]; then
  # Don't reinstall; use whatever the distro ships
  reported=$("$PYTHON_BIN" -m pip --version 2>/dev/null | sed -nE 's/^pip ([0-9.]+).*$/\1/p' | head -1)
else
  "$PYTHON_BIN" -m pip install --quiet --upgrade --break-system-packages "pip==$PIP_VERSION" 2>/dev/null \
    || "$PYTHON_BIN" -m pip install --quiet --upgrade "pip==$PIP_VERSION"
  reported=$("$PYTHON_BIN" -m pip --version 2>/dev/null | sed -nE 's/^pip ([0-9.]+).*$/\1/p' | head -1)
  if [[ -z "$reported" ]] || [[ ! "$reported" =~ ^${PIP_VERSION//./\\.} ]]; then
    echo "switchers/pip.sh: expected pip $PIP_VERSION, got '$reported'" >&2
    exit 1
  fi
fi

echo "switchers/pip.sh: python=$($PYTHON_BIN --version 2>&1) pip=$reported active"
