#!/usr/bin/env bash
# Switch active uv version for a single matrix cell.
#
# Called by ../run.sh as:
#   switchers/uv.sh <python_label> <uv_version>
# e.g.:
#   switchers/uv.sh system 0.5.30
#
# Like pip.sh, the python axis is fixed at "system" because the cross-
# distro matrix exercises different pythons naturally. The interesting
# axis is uv version — uv ships fast and has had behavioral changes in
# recent versions (cache layout, --exclude-newer semantics, exit codes).
#
# install-versions.yml downloads each uv version to /usr/local/bin/uv-<v>.
# This switcher swaps the /usr/local/bin/uv symlink to point at the
# requested version.

set -euo pipefail

PYTHON_LABEL="${1:?usage: $0 <python_label> <uv_version>}"
UV_VERSION="${2:?usage: $0 <python_label> <uv_version>}"

[[ "$PYTHON_LABEL" = "system" ]] || {
  echo "switchers/uv.sh: only 'system' python is supported in v1 (got '$PYTHON_LABEL')" >&2
  exit 1
}

UV_BIN="/usr/local/bin/uv-${UV_VERSION}"
[[ -x "$UV_BIN" ]] || {
  echo "switchers/uv.sh: uv $UV_VERSION not installed at $UV_BIN" >&2
  exit 1
}

ln -sf "$UV_BIN" /usr/local/bin/uv

# Verify uv version matches. uv --version output looks like:
#   "uv 0.5.30 (abc1234 2026-01-15)"
reported=$(uv --version 2>/dev/null | sed -nE 's/^uv ([0-9.]+).*$/\1/p' | head -1)
if [[ "$reported" != "$UV_VERSION" ]]; then
  echo "switchers/uv.sh: expected uv $UV_VERSION, got '$reported'" >&2
  exit 1
fi

echo "switchers/uv.sh: python=$(python3 --version 2>&1) uv=$reported active"
