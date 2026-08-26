#!/usr/bin/env bats
# The npm wrapper's INTERACTIVE branch, executed under a real pty.
#
# WHY THIS FILE EXISTS
#
# templates/npm-wrapper.sh.j2 forks on `[ -t 0 ] && [ -t 1 ]`:
#
#   TTY + npq  -> exec sfw npq-hero "$@"     reputation prompt + threat intel
#   non-TTY    -> exec sfw "$REAL_NPM" "$@"  threat intel only
#
# CI is never a TTY, so until now the interactive half was covered by exactly
# one assertion — 23-npm-path-wrapper.bats greps the wrapper for the literal
# string "[ -t 0 ]". That checks the branch was WRITTEN, not that it works.
#
# It matters more than the coverage suggests: the interactive path is the
# reputation layer, and reputation is the only thing in this role that
# addresses slopsquatting — an attacker pre-registering a plausible name an
# agent or human might guess. An age gate does nothing about a squat registered
# months ago.
#
# `script -qec` allocates a pty, so the same wrapper can be driven down both
# branches and the routing observed directly. Stub sfw/npq-hero on PATH report
# what they were invoked as; nothing real is installed.

load setup

setup() {
  WRAPPER=/usr/local/bin/npm
  STUBS="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$STUBS"

  # sfw stub: records what it was asked to wrap. That first argument IS the
  # branch discriminator — npq-hero on the interactive path, the real npm
  # binary on the non-interactive one.
  cat > "$STUBS/sfw" <<'EOF'
#!/bin/bash
echo "SFW_WRAPPED:$(basename "$1")"
exit 0
EOF
  cat > "$STUBS/npq-hero" <<'EOF'
#!/bin/bash
echo "NPQ_DIRECT:$1"
exit 0
EOF
  chmod +x "$STUBS/sfw" "$STUBS/npq-hero"
}

wrapper_is_ours() {
  [ -f "$WRAPPER" ] && grep -q "supply-chain-hardening" "$WRAPPER" 2>/dev/null
}

@test "tty: the pty harness itself works (guard against a vacuous pass)" {
  # If `script` silently failed to allocate a pty, every interactive test below
  # would exercise the non-interactive branch and pass for the wrong reason.
  command -v script >/dev/null 2>&1 || skip "util-linux script(1) not available"
  run script -qec 'test -t 1 && echo HAVE_TTY' /dev/null
  echo "$output" | grep -q "HAVE_TTY"
}

@test "tty: interactive npm install routes through npq (reputation layer)" {
  wrapper_is_ours || skip "npm PATH wrapper not deployed on this host"
  command -v script >/dev/null 2>&1 || skip "util-linux script(1) not available"

  run script -qec "PATH='$STUBS:$PATH' '$WRAPPER' install some-package" /dev/null
  echo "$output"
  # sfw must be invoked wrapping npq-hero — both layers, in that order.
  echo "$output" | grep -q "SFW_WRAPPED:npq-hero"
}

@test "tty: NON-interactive npm install skips npq and goes straight to sfw" {
  # The complement. npq would hang waiting for input in a script/agent/CI
  # context, so the wrapper must not route there without a terminal. If this
  # ever flips, unattended installs hang instead of being filtered.
  wrapper_is_ours || skip "npm PATH wrapper not deployed on this host"

  run env PATH="$STUBS:$PATH" "$WRAPPER" install some-package
  echo "$output"
  echo "$output" | grep -q "SFW_WRAPPED:"
  ! echo "$output" | grep -q "SFW_WRAPPED:npq-hero"
}

@test "tty: with sfw absent, interactive still reaches npq directly" {
  # Second rung of the fallback ladder. On a host where sfw could not install
  # (Node < 20) but npq works, interactive callers must still get reputation
  # checks rather than an unfiltered passthrough.
  wrapper_is_ours || skip "npm PATH wrapper not deployed on this host"
  command -v script >/dev/null 2>&1 || skip "util-linux script(1) not available"

  rm -f "$STUBS/sfw"
  # A PATH containing only the stubs plus the essentials, so the real sfw
  # cannot be found either.
  run script -qec "PATH='$STUBS:/usr/bin:/bin' '$WRAPPER' install some-package" /dev/null
  echo "$output"
  echo "$output" | grep -q "NPQ_DIRECT:install"
}

@test "tty: read-only subcommands bypass both helpers on either branch" {
  # `npm config get` must reach real npm untouched — sfw's banner corrupts
  # captured output, which is why the wrapper passes these through. Verified on
  # both branches because the passthrough sits ABOVE the TTY fork, and a future
  # edit could easily move it below.
  wrapper_is_ours || skip "npm PATH wrapper not deployed on this host"
  command -v script >/dev/null 2>&1 || skip "util-linux script(1) not available"

  run env PATH="$STUBS:$PATH" "$WRAPPER" config get ignore-scripts
  ! echo "$output" | grep -q "SFW_WRAPPED:"
  ! echo "$output" | grep -q "NPQ_DIRECT:"

  run script -qec "PATH='$STUBS:$PATH' '$WRAPPER' config get ignore-scripts" /dev/null
  ! echo "$output" | grep -q "SFW_WRAPPED:"
  ! echo "$output" | grep -q "NPQ_DIRECT:"
}

@test "tty: interactive install COMPLETES through npq without looping (re-entry guard)" {
  # The tests above use SINK stubs (print a marker, exit) — they prove the
  # wrapper ROUTES to sfw+npq but not that an install COMPLETES through them.
  # The real npq-hero, after approval, runs the package manager to perform the
  # install — npq -> npm -> wrapper -> npq. Without a re-entry guard that loops
  # forever (MEASURED on a real box: interactive `npm install`, answer yes, the
  # reputation panel re-prompts endlessly). A sink stub cannot surface it; this
  # uses a FAITHFUL, delegating npq stub, bounded so a regression fails fast.
  wrapper_is_ours || skip "npm PATH wrapper not deployed on this host"
  command -v script >/dev/null 2>&1 || skip "util-linux script(1) not available"

  rm -f /tmp/npq-reentry-count
  # npq stub that behaves like the real one: approve, then run the package
  # manager (which re-enters the wrapper). Bounded at 3 so the loop fails the
  # test instead of hanging the suite.
  cat > "$STUBS/npq-hero" <<'EOF'
#!/bin/sh
n=$(( $(cat /tmp/npq-reentry-count 2>/dev/null || echo 0) + 1 )); echo "$n" > /tmp/npq-reentry-count
[ "$n" -gt 3 ] && { echo "NPQ_LOOP"; exit 97; }
echo "NPQ_RAN:$n"
exec npm "$@"
EOF
  # sfw that actually delegates (pass-through), so both layers really run.
  printf '#!/bin/sh\nexec "$@"\n' > "$STUBS/sfw"
  # a stub "real npm" so the chain is hermetic (no registry/network)
  printf '#!/bin/sh\necho "REAL_NPM_DID_INSTALL:$*"\n' > "$STUBS/real-npm"
  # a copy of the DEPLOYED wrapper whose REAL_NPM points at our stub, so this
  # exercises the wrapper's actual routing + guard, not a hand-written mock.
  sed "s|^REAL_NPM=.*|REAL_NPM='$STUBS/real-npm'|" "$WRAPPER" > "$STUBS/npm"
  chmod +x "$STUBS/npq-hero" "$STUBS/sfw" "$STUBS/real-npm" "$STUBS/npm"

  run script -qec "PATH='$STUBS:$PATH' '$STUBS/npm' install some-package" /dev/null
  echo "$output"
  # the install must reach the real npm (completed), never the loop
  echo "$output" | grep -q "REAL_NPM_DID_INSTALL:install some-package"
  ! echo "$output" | grep -q "NPQ_LOOP"
  [ "$(cat /tmp/npq-reentry-count 2>/dev/null || echo 99)" -le 2 ]
}
