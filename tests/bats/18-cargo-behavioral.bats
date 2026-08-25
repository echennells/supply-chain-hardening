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

@test "cargo: config drops the Windows-only check-revoke key" {
  # check-revoke is a CertGetCertificateChain CRL/OCSP toggle that only
  # applies on Windows — Linux cargo ignores it entirely. Previous role
  # versions emitted it as if it were a Linux SSL hardening knob. The
  # template now omits it; this test catches a regression where it
  # comes back.
  # Anchor to an actual key assignment — the template legitimately MENTIONS
  # this key in a comment explaining why it is not emitted, and a bare grep
  # matches that comment (false positive).
  ! grep -qE '^[[:space:]]*check-revoke[[:space:]]*=' "$HOME/.cargo/config.toml"
}

@test "cargo: config drops the mislabeled dep-info-basedir key" {
  # dep-info-basedir is a build-artifact path prefix, not a locking or
  # security knob. Previous role versions emitted it with a "locked
  # deps" comment that was outright false. Template now omits it.
  # Anchor to an actual key assignment (see note above — comment false positive).
  ! grep -qE '^[[:space:]]*dep-info-basedir[[:space:]]*=' "$HOME/.cargo/config.toml"
}

@test "cargo: config sets [net] retry = 3" {
  assert_file_contains "$HOME/.cargo/config.toml" "retry = 3"
}
