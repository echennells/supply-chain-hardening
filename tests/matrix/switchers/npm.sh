#!/usr/bin/env bash
# Switch active Node + npm for a single matrix cell.
#
# Called by ../run.sh as:
#   switchers/npm.sh <node_major> <npm_version>
# e.g.:
#   switchers/npm.sh 22 bundled
#   switchers/npm.sh 22 11
#
# Where npm_version is either a specific version (e.g. "10.8.1") or
# "bundled" to use whatever npm ships with the requested Node major.
#
# This is a sibling of pnpm.sh — both switch Node via /opt/node-N
# symlinks, but this one targets npm itself rather than corepack-managed
# pnpm. The role's npm hardening goes through /usr/local/bin/npm
# (deployed by tasks/npm.yml as a wrapper), and the matrix verifies that
# wrapper works against different npm versions.

set -euo pipefail

NODE_MAJOR="${1:?usage: $0 <node_major> <npm_version|bundled>}"
NPM_VERSION="${2:?usage: $0 <node_major> <npm_version|bundled>}"

NODE_DIR="/opt/node-${NODE_MAJOR}"
[[ -d "$NODE_DIR/bin" ]] || {
  echo "switchers/npm.sh: node $NODE_MAJOR not installed at $NODE_DIR" >&2
  exit 1
}

# Symlink the Node bundle's binaries to /usr/local/bin. Symlinks not copies
# because Node's npm/npx are themselves js wrappers that look for their
# sibling node binary via relative paths — a copy out of the bundle would
# break that. Role-side npm wrapper is layered on top of this (the role
# will mv our /usr/local/bin/npm symlink to /usr/local/bin/npm-real and
# write its own wrapper in the spot, on re-apply).
for bin in node npm npx corepack; do
  if [[ -x "$NODE_DIR/bin/$bin" ]]; then
    ln -sf "$NODE_DIR/bin/$bin" "/usr/local/bin/$bin"
  fi
done

# Verify Node version matches
node_reported=$(node --version 2>/dev/null | sed -nE 's/^v([0-9]+)\..*/\1/p' | head -1)
if [[ "$node_reported" != "$NODE_MAJOR" ]]; then
  echo "switchers/npm.sh: expected node $NODE_MAJOR, got '$node_reported'" >&2
  exit 1
fi

# Optionally upgrade npm to a specific version
if [[ "$NPM_VERSION" != "bundled" ]]; then
  npm install -g --silent "npm@${NPM_VERSION}" 2>/dev/null || {
    echo "switchers/npm.sh: failed to install npm@${NPM_VERSION}" >&2
    exit 1
  }
fi

npm_reported=$(npm --version 2>/dev/null)
if [[ "$NPM_VERSION" != "bundled" ]]; then
  npm_major=$(echo "$npm_reported" | sed -nE 's/^([0-9]+)\..*/\1/p')
  if [[ "$npm_major" != "${NPM_VERSION%%.*}" ]]; then
    echo "switchers/npm.sh: expected npm $NPM_VERSION, got '$npm_reported'" >&2
    exit 1
  fi
fi

echo "switchers/npm.sh: node=v$(node --version | sed 's/^v//') npm=$npm_reported active"
