#!/usr/bin/env bash

# Shared helpers for all BATS test files

# Resolve the role directory in both environments:
#   - Inside the test Docker image: role copied to /opt/ansible-supply-chain-security
#     (see tests/Dockerfile); tests/bats lives at a sibling /opt/tests/bats, so a
#     BATS_TEST_DIRNAME-relative walk would land at /opt instead of the role dir.
#     Prefer the well-known Docker path when it exists.
#   - Local clone (any host, any path): walk up two dirs from the test file's
#     location (tests/bats/x.bats -> repo root). Works on dev machines and CI
#     runners regardless of where the repo was checked out.
# Override by exporting ROLE_DIR before invoking bats.
if [ -z "${ROLE_DIR:-}" ]; then
  if [ -d /opt/ansible-supply-chain-security ]; then
    ROLE_DIR=/opt/ansible-supply-chain-security
  else
    ROLE_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  fi
fi
export ROLE_DIR

load_profile() {
  source /etc/profile.d/supply-chain-hardening.sh 2>/dev/null || true
}

assert_file_contains() {
  local file="$1"
  local pattern="$2"
  if ! grep -q "$pattern" "$file" 2>/dev/null; then
    echo "FAIL: '$file' does not contain '$pattern'" >&2
    echo "--- file contents ---" >&2
    cat "$file" >&2 2>/dev/null || echo "(file not found)" >&2
    return 1
  fi
}

assert_file_exists() {
  local file="$1"
  if [ ! -f "$file" ]; then
    echo "FAIL: '$file' does not exist" >&2
    return 1
  fi
}

assert_env_equals() {
  local var="$1"
  local expected="$2"
  local actual="${!var}"
  if [ "$actual" != "$expected" ]; then
    echo "FAIL: \$$var = '$actual', expected '$expected'" >&2
    return 1
  fi
}

# Locate a fixture's built sdist regardless of PEP 625 filename normalization.
# setuptools >= 69 renders the sdist filename's name component with UNDERSCORES
# (test-setup-exfil -> test_setup_exfil-<ver>.tar.gz), so globs hard-coded to the
# hyphen spelling silently MISS on Ubuntu 26.04 / modern setuptools and the
# adversarial test SKIPS — a coverage loss that reads as green (ECH-172,
# docs/design-principles.md Axis 4 "absent signal read as a passing signal").
# Each fixture dir holds exactly one package, so match any *.tar.gz. If dist/
# exists but holds no sdist, FAIL LOUDLY (return 2) rather than let the caller
# skip — the guard that stops the silent skip from re-appearing. If dist/ is
# absent (fixture not built in this environment), return empty so the caller can
# legitimately skip.
find_fixture_sdist() {
  local dir="/opt/test-fixtures/$1"
  [ -d "$dir/dist" ] || return 0
  local sdist
  sdist=$(ls "$dir"/dist/*.tar.gz 2>/dev/null | head -1)
  if [ -z "$sdist" ]; then
    echo "find_fixture_sdist: '$dir/dist' exists but holds no .tar.gz — fixture produced no sdist (ECH-172 silent-skip guard)." >&2
    ls -la "$dir/dist" >&2 2>/dev/null || true
    return 2
  fi
  printf '%s\n' "$sdist"
}
