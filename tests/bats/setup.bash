#!/usr/bin/env bash

# Shared helpers for all BATS test files

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
