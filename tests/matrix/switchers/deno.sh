#!/usr/bin/env bash
# Switch active deno version for a single matrix cell.
#
# Called by ../run.sh as:
#   switchers/deno.sh <python_label> <deno_version>
# e.g.:
#   switchers/deno.sh system 2.0.6
#
# Like pip.sh and uv.sh, the python axis is fixed at "system" — deno
# doesn't actually use python, but the framework expects a two-axis
# matrix. The interesting axis is deno version.
#
# Why this matters: the role's tasks/deno.yml deploys an in-place
# wrapper at the discovered deno location. The wrapper injects
# --minimum-dependency-age into fetching subcommands. Deno's CLI
# surface has changed between 1.x and 2.x (subcommand allowlist,
# flag handling, exit codes) — the wrapper needs to work across
# both. install-versions.yml provides each deno version as
# /usr/local/bin/deno-<version>; this switcher swaps the active
# /usr/local/bin/deno to one of them. Between cells we also remove
# any /usr/local/bin/deno-real left by a previous cell's role apply
# so the next role apply sees a fresh "is_real" binary to wrap.

set -euo pipefail

PYTHON_LABEL="${1:?usage: $0 <python_label> <deno_version>}"
DENO_VERSION="${2:?usage: $0 <python_label> <deno_version>}"

[[ "$PYTHON_LABEL" = "system" ]] || {
  echo "switchers/deno.sh: only 'system' python is supported in v1 (got '$PYTHON_LABEL')" >&2
  exit 1
}

DENO_BIN="/usr/local/bin/deno-${DENO_VERSION}"
[[ -x "$DENO_BIN" ]] || {
  echo "switchers/deno.sh: deno $DENO_VERSION not installed at $DENO_BIN" >&2
  exit 1
}

# Clean up any wrapper backup from a previous cell — the role's deno task
# moves the real binary to <path>-real before deploying the wrapper, and
# we want it to do that fresh against this cell's binary.
rm -f /usr/local/bin/deno-real

# Copy (not symlink) so the role's `mv deno deno-real` works cleanly.
# Symlinking and then mv'ing would rename the symlink, not the file —
# the role would end up with a wrapper pointing to a symlink to a
# versioned binary, which works but creates weird state for debugging.
cp -f "$DENO_BIN" /usr/local/bin/deno
chmod 0755 /usr/local/bin/deno

# Verify. deno --version output:
#   "deno 2.0.6 (stable, release, x86_64-unknown-linux-gnu)"
reported=$(deno --version 2>/dev/null | head -1 | sed -nE 's/^deno ([0-9.]+).*$/\1/p')
if [[ "$reported" != "$DENO_VERSION" ]]; then
  echo "switchers/deno.sh: expected deno $DENO_VERSION, got '$reported'" >&2
  exit 1
fi

echo "switchers/deno.sh: deno=$reported active"
