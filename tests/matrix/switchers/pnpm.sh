#!/usr/bin/env bash
# Switch active Node + pnpm for a single matrix cell.
#
# Called by ../run.sh as:
#   switchers/pnpm.sh <node_major> <pnpm_version>
# e.g.:
#   switchers/pnpm.sh 22 11
#
# After this returns successfully:
#   - `node` and `npm` on PATH resolve to the requested Node major
#   - `pnpm` on PATH resolves to the requested pnpm version (via corepack)
#   - Both report the expected versions
#
# pnpm is the most version-sensitive ecosystem in the role — pnpm 10 reads
# ~/.config/pnpm/rc (ini format) while pnpm 11+ only reads
# ~/.config/pnpm/config.yaml (YAML). The role deploys both files so it
# stays correct across the version boundary, but the bats tests need to
# actually run against each version to verify that.

set -euo pipefail

NODE_MAJOR="${1:?usage: $0 <node_major> <pnpm_version>}"
PNPM_VERSION="${2:?usage: $0 <node_major> <pnpm_version>}"

NODE_DIR="/opt/node-${NODE_MAJOR}"
[[ -d "$NODE_DIR/bin" ]] || {
  echo "switchers/pnpm.sh: node $NODE_MAJOR not installed at $NODE_DIR" >&2
  exit 1
}

# Switch active Node by symlinking its binaries into /usr/local/bin. This
# beats PATH manipulation because the role's tests assume node/npm/pnpm are
# resolvable via PATH-search, and /usr/local/bin is in the default PATH on
# every supported distro.
for bin in node npm npx corepack; do
  if [[ -x "$NODE_DIR/bin/$bin" ]]; then
    ln -sf "$NODE_DIR/bin/$bin" "/usr/local/bin/$bin"
  fi
done

# Verify Node version matches
node_reported=$(node --version 2>/dev/null | sed -nE 's/^v([0-9]+)\..*/\1/p' | head -1)
if [[ "$node_reported" != "$NODE_MAJOR" ]]; then
  echo "switchers/pnpm.sh: expected node $NODE_MAJOR, got '$node_reported'" >&2
  exit 1
fi

# Activate the requested pnpm via corepack. Corepack ships with Node ≥ 14.19
# and is the supported way to switch package managers without globally
# `npm install -g`-ing them. The --activate flag writes pnpm to a
# corepack-managed shim in $PATH.
corepack enable 2>/dev/null
corepack prepare "pnpm@${PNPM_VERSION}" --activate >/dev/null 2>&1

# Verify pnpm major version matches (we pin majors, not patches, since
# pnpm patches roll fast and the role's version-sensitive logic is
# major-keyed: rc vs config.yaml is decided by pnpm major).
pnpm_full=$(pnpm --version 2>/dev/null)
pnpm_major=$(echo "$pnpm_full" | sed -nE 's/^([0-9]+)\..*/\1/p' | head -1)
if [[ "$pnpm_major" != "${PNPM_VERSION%%.*}" ]]; then
  echo "switchers/pnpm.sh: expected pnpm $PNPM_VERSION, got '$pnpm_full'" >&2
  exit 1
fi

echo "switchers/pnpm.sh: node=v$(node --version | sed 's/^v//') pnpm=$pnpm_full active"
