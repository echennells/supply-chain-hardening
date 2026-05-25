#!/usr/bin/env bash
# Switch active bun version for a single matrix cell.
#
# Called by ../run.sh as:
#   switchers/bun.sh <python_label> <bun_version>
# e.g.:
#   switchers/bun.sh system 1.1.20
#
# Like deno.sh, the "lang" axis is fixed at "system" — bun doesn't use
# python, but the framework expects a two-axis matrix. Tool axis is bun
# version. install-versions.yml provides each version at
# /usr/local/bin/bun-<version>; this switcher symlinks the active one to
# /usr/local/bin/bun.

set -euo pipefail

PYTHON_LABEL="${1:?usage: $0 <python_label> <bun_version>}"
BUN_VERSION="${2:?usage: $0 <python_label> <bun_version>}"

[[ "$PYTHON_LABEL" = "system" ]] || {
  echo "switchers/bun.sh: only 'system' lang is supported in v1 (got '$PYTHON_LABEL')" >&2
  exit 1
}

BUN_BIN="/usr/local/bin/bun-${BUN_VERSION}"
[[ -x "$BUN_BIN" ]] || {
  echo "switchers/bun.sh: bun $BUN_VERSION not installed at $BUN_BIN" >&2
  exit 1
}

ln -sf "$BUN_BIN" /usr/local/bin/bun

# bun --version output is just the version number, no prefix or suffix
reported=$(bun --version 2>/dev/null | head -1)
if [[ "$reported" != "$BUN_VERSION" ]]; then
  echo "switchers/bun.sh: expected bun $BUN_VERSION, got '$reported'" >&2
  exit 1
fi

echo "switchers/bun.sh: bun=$reported active"
