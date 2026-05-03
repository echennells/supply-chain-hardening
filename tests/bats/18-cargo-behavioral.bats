#!/usr/bin/env bats
# Behavioral tests for Cargo/Rust.
# IMPORTANT: Cargo has NO build.rs blocking. This test DOCUMENTS the gap.

load setup

setup() {
  rm -f /tmp/marker-cargo-build-rs
}

@test "KNOWN GAP: Cargo build.rs executes during cargo build (no defense exists)" {
  # Like Ruby's extconf.rb, Cargo's build.rs always runs.
  # We document this as a known gap.
  cd /opt/test-fixtures/cargo-build-script
  cargo build 2>/dev/null || true

  if [ -f /tmp/marker-cargo-build-rs ]; then
    # Gap confirmed: build.rs ran. Expected — Cargo cannot block this.
    true
  else
    skip "build.rs did not execute (build may have failed for other reasons)"
  fi
}

@test "cargo: config enforces git-fetch-with-cli" {
  assert_file_contains "$HOME/.cargo/config.toml" "git-fetch-with-cli = true"
}

@test "cargo: config enforces SSL revocation checking" {
  assert_file_contains "$HOME/.cargo/config.toml" "check-revoke = true"
}
