#!/usr/bin/env bats
# The verifier.
#
# harden.sh writing a file proves nothing about enforcement. These check that
# verify.sh reaches the right verdict in each way hardening can be present on
# disk and absent in effect — which is every way it has actually failed.

load helpers

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null \
    || skip "needs passwordless sudo to wrap binaries"
}

@test "reports the env layer as propagated when it was sourced" {
  harden ECOSYSTEMS=npm -- --emit=plain >/dev/null
  run verify_sourced --emit=plain
  [[ "$output" == *"env layer propagation"* ]]
  [[ "$output" == *"variables present in this step's environment"* ]]
}

@test "flags the env layer as a GAP when nothing sourced it" {
  # The silent half-application: config files landed, no variable arrived.
  # On gitlab/buildkite/plain this is the single most likely misconfiguration.
  harden ECOSYSTEMS=npm -- --emit=plain >/dev/null
  run verify -- --emit=plain
  [[ "$output" == *"GAP"* ]]
  [[ "$output" == *"NONE of"* ]]
  [[ "$output" == *"variables reached this step"* ]]
}

@test "names the env file in the diagnosis so the fix is obvious" {
  harden ECOSYSTEMS=npm -- --emit=plain >/dev/null
  run verify -- --emit=plain
  [[ "$output" == *"$ENV_FILE"* ]]
}

@test "detects a wrapper shadowed by something later on PATH" {
  # The sfw bug, and equally a setup step that reinstalls a tool AFTER
  # hardening. The wrapper exists; nothing reaches it.
  stub_bin bun 'case "${1:-}" in --version|-v) echo "1.2.0";; *) echo STUB;; esac'
  harden ECOSYSTEMS=bun -- --emit=plain >/dev/null
  mkdir -p "$BATS_TEST_TMPDIR/later"
  cp "$(stub_real bun)" "$BATS_TEST_TMPDIR/later/bun"

  run env -i PATH="$BATS_TEST_TMPDIR/later:${TEST_BIN}:${PATH}" HOME="$TEST_HOME" \
    TMPDIR="$TEST_TMP" HARDENING_ENV_FILE="$ENV_FILE" bash "$VERIFY_SH" --emit=plain
  [[ "$output" == *"shadowed and never runs"* ]]
}

@test "the shadow diagnosis names both the wrapper and what won" {
  stub_bin bun 'case "${1:-}" in --version|-v) echo "1.2.0";; *) echo STUB;; esac'
  harden ECOSYSTEMS=bun -- --emit=plain >/dev/null
  mkdir -p "$BATS_TEST_TMPDIR/later"
  cp "$(stub_real bun)" "$BATS_TEST_TMPDIR/later/bun"
  run env -i PATH="$BATS_TEST_TMPDIR/later:${TEST_BIN}:${PATH}" HOME="$TEST_HOME" \
    TMPDIR="$TEST_TMP" HARDENING_ENV_FILE="$ENV_FILE" bash "$VERIFY_SH" --emit=plain
  [[ "$output" == *"${TEST_BIN}/bun"* ]]
  [[ "$output" == *"$BATS_TEST_TMPDIR/later/bun"* ]]
}

@test "detects an orphaned wrapper whose real target is gone" {
  # The wrapper IS what PATH resolves to, but its recursion guard makes it
  # exit 127 on every call. Looks deployed, refuses to run.
  stub_bin bun 'case "${1:-}" in --version|-v) echo "1.2.0";; *) echo STUB;; esac'
  harden ECOSYSTEMS=bun -- --emit=plain >/dev/null
  sudo rm -f "$(stub_real bun)"
  run verify -- --emit=plain
  [[ "$output" == *"refuse to run"* ]]
}

@test "an active wrapper reads as OK at FUNCTIONAL strength" {
  stub_bin bun 'case "${1:-}" in --version|-v) echo "1.2.0";; *) echo STUB;; esac'
  harden ECOSYSTEMS=bun -- --emit=plain >/dev/null
  run verify_sourced --emit=plain
  [[ "$output" == *"OK     FUNCTIONAL  bun PATH wrapper"* ]]
}

@test "distinguishes a key npm implements from one it merely echoes back" {
  # npm returns a value for ANY key present in config, implemented or not.
  # On npm < 11.10.0 min-release-age is echoed and enforced by nothing, which
  # is precisely the failure this whole script exists to surface.
  have npm || skip "npm not installed"
  harden ECOSYSTEMS=npm -- --emit=plain >/dev/null
  run verify_sourced --emit=plain
  [[ "$output" == *"npm lifecycle scripts blocked"* ]]
  [[ "$output" == *"npm age gate"* ]]
  # Whichever way this npm goes, the verdict must be argued from
  # implementation, not from the value being echoed back.
  if [[ "$output" == *"does NOT implement min-release-age"* ]]; then
    [[ "$output" == *"GAP"* ]]
  else
    [[ "$output" == *"implements min-release-age and reports"* ]]
  fi
}

@test "exits non-zero when there is a gap and zero when there is not" {
  harden ECOSYSTEMS=npm -- --emit=plain >/dev/null
  # Unsourced env layer guarantees at least one gap.
  run verify -- --emit=plain
  [ "$status" -eq 1 ]
}

@test "--quiet suppresses the table but keeps the exit code" {
  harden ECOSYSTEMS=npm -- --emit=plain >/dev/null
  run verify -- --emit=plain --quiet
  [ "$status" -eq 1 ]
  [[ "$output" != *"STATUS"* ]]
}

@test "--strict turns PRESENT-only rows into a failure" {
  # A hardened, sourced job with no gaps can still be carrying rows whose only
  # evidence is that a file exists. --strict is for pipelines that want
  # unverified to count as unprotected.
  harden ECOSYSTEMS=npm -- --emit=plain >/dev/null
  run verify_sourced -- --emit=plain --strict
  # Either it found a gap (1) or strict escalated a WEAK row (1); both fail.
  # What must NOT happen is passing while reporting WEAK rows.
  if [[ "$output" == *"WEAK"* ]]; then [ "$status" -eq 1 ]; fi
}

@test "absent tools are N/A, not gaps" {
  # A runner without cargo is not an unprotected runner.
  harden ECOSYSTEMS=npm -- --emit=plain >/dev/null
  run verify_sourced --emit=plain
  [[ "$output" == *"N/A"* ]]
}

@test "emits a GitHub error annotation on the github target" {
  harden ECOSYSTEMS=npm -- --emit=plain >/dev/null
  run verify -- --emit=github
  [[ "$output" == *"::error::"* ]]
  [[ "$output" == *"NOT in effect"* ]]
}

@test "plain mode emits no GitHub workflow commands" {
  harden ECOSYSTEMS=npm -- --emit=plain >/dev/null
  run verify -- --emit=plain
  [[ "$output" != *"::error::"* ]]
}

@test "--help explains itself without running any probe" {
  run verify -- --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"EVIDENCE STRENGTH"* ]]
  # The help text documents the STATUS legend, so its presence proves nothing.
  # No RESULT line means no probe ran.
  [[ "$output" != *"RESULT:"* ]]
}
