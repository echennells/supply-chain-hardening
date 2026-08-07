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
  ! grep -q "check-revoke" "$HOME/.cargo/config.toml"
}

@test "cargo: config drops the mislabeled dep-info-basedir key" {
  # dep-info-basedir is a build-artifact path prefix, not a locking or
  # security knob. Previous role versions emitted it with a "locked
  # deps" comment that was outright false. Template now omits it.
  ! grep -q "dep-info-basedir" "$HOME/.cargo/config.toml"
}

@test "cargo: config sets [net] retry = 3" {
  assert_file_contains "$HOME/.cargo/config.toml" "retry = 3"
}

@test "cargo: reference deny.toml deployed at /etc/cargo/deny.toml" {
  # cargo-deny does NOT auto-merge a system config with project-local
  # deny.toml. The role deploys this as a reference baseline only —
  # users copy/symlink into their project or invoke with --config.
  assert_file_exists /etc/cargo/deny.toml
}

@test "cargo: deny.toml denies unknown registries and unknown git sources" {
  assert_file_contains /etc/cargo/deny.toml 'unknown-registry = "deny"'
  assert_file_contains /etc/cargo/deny.toml 'unknown-git = "deny"'
}

@test "cargo: deny.toml denies yanked crate versions" {
  assert_file_contains /etc/cargo/deny.toml 'yanked = "deny"'
}

@test "cargo: deny.toml is root-owned (non-root cannot tamper)" {
  owner=$(stat -c '%U' /etc/cargo/deny.toml 2>/dev/null || stat -f '%Su' /etc/cargo/deny.toml)
  [ "$owner" = "root" ]
}
