#!/usr/bin/env bash
# Apply the role on a STOCK distro and report what actually enforces.
#
# WHY THIS EXISTS
#
# The bats suite builds its container from nodesource and tarballs, so it runs
# against current toolchains. Real hosts run distro packages that are one to
# three years behind, and the role's protections cluster at the newest versions
# of each tool:
#
#   npm min-release-age      npm >= 11.10.0   (Ubuntu 24.04 ships npm 9.2.0)
#   yarn hardening at all    yarn >= 2        (apt ships 1.22)
#   pnpm exotic-dep blocking pnpm >= 11
#   composer audit blocking  composer >= 2.9  (noble 2.7.1, bookworm 2.5.5)
#   npq reputation           node >= 20.13
#   sfw                      node >= 20
#
# So the suite has been answering "does the role work on a modern toolchain",
# while the question that matters is "does it work on the box someone actually
# has". This script asks the second one, using only what apt provides.
#
# Run inside a distro container:
#   docker run --rm -v "$PWD:/role" ubuntu:24.04 bash /role/tests/coverage/stock-distro-verify.sh
#
# Output is the supply-chain-verify table plus the tool versions it ran
# against. Always exits 0 — a GAP here is a finding to report, not a build
# failure. The point is to measure, not to gate.

set -u
export DEBIAN_FRONTEND=noninteractive

ROLE_DIR="${ROLE_DIR:-/role}"

echo "=============================================================="
echo " STOCK DISTRO COVERAGE"
echo " $(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")"
echo "=============================================================="

echo
echo "--- installing STOCK package managers (apt only, no nodesource) ---"
apt-get update -qq >/dev/null 2>&1
# Deliberately apt-only. Adding a vendor repo would install current versions
# and re-create the blind spot this script exists to remove.
apt-get install -y -qq --no-install-recommends \
  ansible python3 python3-pip nodejs npm golang-go composer curl ca-certificates \
  yarnpkg cargo rustc \
  >/dev/null 2>&1 || true

echo
# apt ships yarn classic as `yarnpkg`. Symlink it to `yarn` so the verifier
# measures it — this is exactly the yarn 1.x case the README now documents as
# receiving no hardening at all, and it went untested because the binary name
# differs from the one everything looks for.
if command -v yarnpkg >/dev/null 2>&1 && ! command -v yarn >/dev/null 2>&1; then
  ln -sf "$(command -v yarnpkg)" /usr/local/bin/yarn
fi

echo "--- tool versions this host actually has ---"
for t in ansible node npm yarn pnpm bun composer python3 pip3 go cargo; do
  if command -v "$t" >/dev/null 2>&1; then
    # `go` takes `go version`, not `--version` — the old form printed
    # "flag provided but not defined: -version" in every distro column.
    if [ "$t" = "go" ]; then
      v=$("$t" version 2>&1 | head -1)
    else
      v=$("$t" --version 2>&1 | head -1)
    fi
    printf "  %-10s %s\n" "$t" "$v"
  else
    printf "  %-10s (absent)\n" "$t"
  fi
done

echo
echo "--- applying the role ---"
cd "$ROLE_DIR" || exit 0
# release_age_hours default is fine; podman off to keep the run bounded.
ansible-playbook site.yml --connection=local --limit localhost \
  -e podman_enabled=false -e verify_protections=false \
  >/tmp/apply.log 2>&1
rc=$?
echo "  ansible-playbook rc=$rc"
if [ "$rc" -ne 0 ]; then
  echo "  --- tail of apply log ---"
  tail -25 /tmp/apply.log | sed 's/^/  /'
fi
echo "  recap: $(grep -E '^localhost' /tmp/apply.log | tail -1)"

echo
echo "--- protections the role reported as NOT applied ---"
sed -n '/were NOT applied/,/prerequisite and re-run/p' /tmp/apply.log | sed 's/^/  /' \
  || echo "  (none reported)"

echo
echo "--- WHAT ACTUALLY ENFORCES ---"
if [ -x /usr/local/bin/supply-chain-verify ]; then
  /usr/local/bin/supply-chain-verify || true
else
  echo "  supply-chain-verify was not deployed; applying verify tag only"
  ansible-playbook site.yml --connection=local --limit localhost \
    --tags verify -e podman_enabled=false >/dev/null 2>&1
  [ -x /usr/local/bin/supply-chain-verify ] && { /usr/local/bin/supply-chain-verify || true; }
fi

echo
echo "=============================================================="
exit 0
