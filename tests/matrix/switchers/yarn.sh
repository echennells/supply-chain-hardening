#!/usr/bin/env bash
# Switch active Node + yarn for a single matrix cell.
#
# Called by ../run.sh as:
#   switchers/yarn.sh <node_major> <yarn_version>
# e.g.:
#   switchers/yarn.sh 22 4.5.3
#
# Same structure as pnpm.sh — switches Node via /opt/node-N symlinks,
# then activates the requested yarn via corepack. The bats test
# (14-yarn-adversarial.bats) now writes packageManager dynamically based
# on the currently-active yarn, so per-cell matrix coverage actually
# exercises the matrix's yarn version (previously the test pinned
# yarn@4.9.1 which made matrix coverage tautological).

set -euo pipefail

NODE_MAJOR="${1:?usage: $0 <node_major> <yarn_version>}"
YARN_VERSION="${2:?usage: $0 <node_major> <yarn_version>}"

NODE_DIR="/opt/node-${NODE_MAJOR}"
[[ -d "$NODE_DIR/bin" ]] || {
  echo "switchers/yarn.sh: node $NODE_MAJOR not installed at $NODE_DIR" >&2
  exit 1
}

for bin in node npm npx corepack; do
  if [[ -x "$NODE_DIR/bin/$bin" ]]; then
    ln -sf "$NODE_DIR/bin/$bin" "/usr/local/bin/$bin"
  fi
done

node_reported=$(node --version 2>/dev/null | sed -nE 's/^v([0-9]+)\..*/\1/p' | head -1)
if [[ "$node_reported" != "$NODE_MAJOR" ]]; then
  echo "switchers/yarn.sh: expected node $NODE_MAJOR, got '$node_reported'" >&2
  exit 1
fi

corepack enable 2>/dev/null
corepack prepare "yarn@${YARN_VERSION}" --activate >/dev/null 2>&1

yarn_reported=$(yarn --version 2>/dev/null)
yarn_major=$(echo "$yarn_reported" | sed -nE 's/^([0-9]+)\..*/\1/p')
if [[ "$yarn_major" != "${YARN_VERSION%%.*}" ]]; then
  echo "switchers/yarn.sh: expected yarn $YARN_VERSION, got '$yarn_reported'" >&2
  exit 1
fi

echo "switchers/yarn.sh: node=v$(node --version | sed 's/^v//') yarn=$yarn_reported active"
