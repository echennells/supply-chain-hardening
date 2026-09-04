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

# GROUND TRUTH FIRST, THEN THE VERDICT.
#
# The bug these three tests exist to prevent was invisible to the tests that
# came before them, because those asserted the STRING the verifier prints
# rather than the FACT it is a claim about. They put one shape of front-runner
# on PATH — a plain copy of the real binary, which does not delegate — and
# checked for "shadowed and never runs". Under that fixture the claim happens
# to be true, so the test passed, and it would have passed no matter how wrong
# the verifier was about every other front-runner.
#
# `wrapper_actually_ran` answers the question by its own route: invoke the
# tool, ask the wrapper whether it executed. The verifier's verdict is then
# required to agree with an answer derived independently of it.
wrapper_actually_ran() {
  local probe="${BATS_TEST_TMPDIR}/ran.$$"
  rm -f "$probe"
  env PATH="$1" HOME="$TEST_HOME" SCH_WRAPPER_PROBE="$probe" \
      bun --version >/dev/null 2>&1 || true
  [ -s "$probe" ] && grep -q "supply-chain-harden" "$(head -1 "$probe")" 2>/dev/null
}

@test "a non-delegating binary in front really does bypass the wrapper" {
  # A setup step that reinstalls a tool AFTER hardening. The wrapper exists;
  # nothing reaches it. Ground truth and verdict must both say so.
  stub_bin bun 'case "${1:-}" in --version|-v) echo "1.2.0";; *) echo STUB;; esac'
  harden ECOSYSTEMS=bun -- --emit=plain >/dev/null
  mkdir -p "$BATS_TEST_TMPDIR/later"
  cp "$(stub_real bun)" "$BATS_TEST_TMPDIR/later/bun"
  local p="$BATS_TEST_TMPDIR/later:${TEST_BIN}:${PATH}"

  run wrapper_actually_ran "$p"
  [ "$status" -ne 0 ]              # fact: it did NOT run

  run env -i PATH="$p" HOME="$TEST_HOME" TMPDIR="$TEST_TMP" \
    HARDENING_ENV_FILE="$ENV_FILE" bash "$VERIFY_SH" --emit=plain
  [[ "$output" == *"did NOT run"* ]]
  [[ "$output" == *"bun PATH wrapper"* ]]
}

@test "a DELEGATING front-runner is not reported as bypassed" {
  # REGRESSION. MEASURED against a real Aikido safe-chain shim: it strips its
  # own directory from PATH and execs the next match, which is our wrapper, so
  # the wrapper ran on every call — while the verifier reported "shadowed and
  # never runs" at FUNCTIONAL strength. Every version manager (asdf, mise,
  # volta, nodenv, pyenv) is shim-first and delegates identically, so this
  # fired for those users with no second security tool anywhere.
  stub_bin bun 'case "${1:-}" in --version|-v) echo "1.2.0";; *) echo STUB;; esac'
  harden ECOSYSTEMS=bun -- --emit=plain >/dev/null

  mkdir -p "$BATS_TEST_TMPDIR/shims"
  cat > "$BATS_TEST_TMPDIR/shims/bun" <<EOF
#!/bin/sh
# a delegating shim: drop our own dir, hand off to whatever is next
_p=\$(echo "\$PATH" | sed "s|$BATS_TEST_TMPDIR/shims:||g")
exec env PATH="\$_p" bun "\$@"
EOF
  chmod +x "$BATS_TEST_TMPDIR/shims/bun"
  local p="$BATS_TEST_TMPDIR/shims:${TEST_BIN}:${PATH}"

  run wrapper_actually_ran "$p"
  [ "$status" -eq 0 ]              # fact: it DID run

  run env -i PATH="$p" HOME="$TEST_HOME" TMPDIR="$TEST_TMP" \
    HARDENING_ENV_FILE="$ENV_FILE" bash "$VERIFY_SH" --emit=plain
  [[ "$output" == *"observed running"* ]]
  [[ "$output" == *"chained behind"* ]]
  [[ "$output" != *"did NOT run"* ]]
}

@test "the verdict agrees with ground truth in both directions" {
  # The property the other two are instances of, asserted directly: whatever
  # the wrapper actually did, the verifier says the same thing. A future check
  # that re-introduces position-inference fails here even if someone updates
  # the message strings to match.
  stub_bin bun 'case "${1:-}" in --version|-v) echo "1.2.0";; *) echo STUB;; esac'
  harden ECOSYSTEMS=bun -- --emit=plain >/dev/null
  mkdir -p "$BATS_TEST_TMPDIR/blocker" "$BATS_TEST_TMPDIR/passthru"
  cp "$(stub_real bun)" "$BATS_TEST_TMPDIR/blocker/bun"
  cat > "$BATS_TEST_TMPDIR/passthru/bun" <<EOF
#!/bin/sh
_p=\$(echo "\$PATH" | sed "s|$BATS_TEST_TMPDIR/passthru:||g")
exec env PATH="\$_p" bun "\$@"
EOF
  chmod +x "$BATS_TEST_TMPDIR/passthru/bun"

  local dir
  for dir in blocker passthru; do
    local p="$BATS_TEST_TMPDIR/$dir:${TEST_BIN}:${PATH}"
    local truth=ran
    wrapper_actually_ran "$p" || truth=bypassed

    run env -i PATH="$p" HOME="$TEST_HOME" TMPDIR="$TEST_TMP" \
      HARDENING_ENV_FILE="$ENV_FILE" bash "$VERIFY_SH" --emit=plain
    local verdict=bypassed
    # Scope to the bun row: composer/cargo wrappers also print "observed
    # running", so an unscoped match reads THEIR success as bun's (the 'blocker'
    # case bun row correctly says "did NOT run", but the whole-output grep hit
    # composer's line -> false 'ran').
    echo "$output" | grep 'bun PATH wrapper' | grep -q "observed running" && verdict=ran

    [ "$truth" = "$verdict" ] || {
      echo "front-runner '$dir': wrapper $truth, verifier said $verdict"
      echo "$output" | grep 'bun PATH wrapper'
      return 1
    }
  done
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
