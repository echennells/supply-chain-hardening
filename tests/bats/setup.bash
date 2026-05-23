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
