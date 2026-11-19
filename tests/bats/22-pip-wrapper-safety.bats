#!/usr/bin/env bats
# Regression tests for pip-wrapper safety.
#
# Background:
# An earlier version of tasks/uv.yml gated the pip-wrapper deployment on
#   when: uv_binary_path.rc == 0 or ansible_user_id is defined
# Since gather_facts always sets ansible_user_id, the gate was vacuously
# true and the wrapper deployed on hosts without uv. With uv_binary_path
# .stdout empty, Jinja's default() (which only fires on undefined, not on
# defined-but-empty) substituted an empty string, producing:
#   exec  pip "$@"
# which re-execs through PATH back into the wrapper itself. Result:
# /usr/local/bin/pip became a recursion bomb that bricked pip system-wide
# on every host without uv (including apt's python3-pip).
#
# Existing tests never exercised the uv-absent code path because the test
# Dockerfile always installs uv. These tests check three complementary
# angles so the bug can't return silently.

load setup

@test "pip wrapper has a defensive guard against missing uv" {
  # Wrapper must refuse to run if its embedded uv path is empty or
  # non-executable, instead of falling through to `exec  pip "$@"`.
  # Skip when no uv is on PATH — the role intentionally doesn't deploy
  # the pip wrapper in that case (deploying a pip→uv redirect with no
  # uv would just produce a recursion bomb), so asserting wrapper
  # contents would fail for the wrong reason. The skip preserves the
  # property under test ("when deployed, the wrapper has the guard")
  # while admitting the role's correct refusal to deploy.
  command -v uv >/dev/null 2>&1 || skip "uv not on PATH; role correctly skipped wrapper deploy"
  assert_file_contains /usr/local/bin/pip "refusing to recurse"
}

@test "pip3 wrapper has a defensive guard against missing uv" {
  command -v uv >/dev/null 2>&1 || skip "uv not on PATH; role correctly skipped wrapper deploy"
  assert_file_contains /usr/local/bin/pip3 "refusing to recurse"
}

@test "uv.yml does not gate wrapper deployment on a vacuously-true expression" {
  # The when: condition must depend only on actual uv presence.
  # Specifically: must NOT include `ansible_user_id is defined`, which is
  # always true after gather_facts.
  taskfile="$ROLE_DIR/tasks/uv.yml"
  [ -f "$taskfile" ] || skip "role source not available at $taskfile"

  ! grep -qE "ansible_user_id[[:space:]]+is[[:space:]]+defined" "$taskfile"
}

@test "pip wrapper does not infinite-loop when uv binary is removed" {
  # Even if uv is removed after deployment, the wrapper must fail safely
  # (non-zero exit) rather than recurse forever. With a defensive guard,
  # the wrapper detects the missing binary and exits with 127. Without one,
  # it tries `exec <absolute-path> pip "$@"` which fails cleanly with
  # ENOENT — but if the wrapper was ever deployed with an empty path
  # (the original bug), this would loop until killed.

  uv_path=$(grep -oE "/[^ ']*/\.local/bin/uv|/usr/local/bin/uv|/usr/bin/uv" /usr/local/bin/pip | head -1)
  [ -n "$uv_path" ] || skip "couldn't extract uv path from wrapper"
  [ -x "$uv_path" ] || skip "uv at $uv_path not executable"

  # Move uv aside temporarily
  mv "$uv_path" "${uv_path}.bats-hidden"

  # Run pip wrapper with a 5-second timeout. Must NOT loop forever.
  run timeout 5 /usr/local/bin/pip --version

  # Restore uv before asserting (so the rest of the test suite still works)
  mv "${uv_path}.bats-hidden" "$uv_path"

  # 124 = timeout fired = infinite loop. Anything else = failed safely.
  [ "$status" -ne 124 ]
}

@test "pip wrapper prefers a reachable system uv over an unreachable baked path (ECH-191)" {
  # The bug: tasks/uv.yml resolved uv preferring $HOME/.local/bin/uv, so on a
  # host with BOTH a system uv and a per-user uv it baked the home path into
  # the SYSTEM-WIDE wrapper. Any non-deploying, non-root user who can't
  # traverse that home (0750/0700) then hit the guard and lost pip entirely,
  # even though /usr/local/bin/uv was right there. The wrapper now resolves uv
  # at runtime, system copy first, so it self-heals for those callers.
  command -v uv >/dev/null 2>&1 || skip "uv not on PATH; wrapper not deployed"
  [ -x /usr/local/bin/uv ] || skip "no system uv to fall back to"

  # Reproduce the precondition: rewrite ONLY the baked deploy-time path to a
  # home dir that does not exist / this caller cannot reach.
  wrapper="$BATS_TEST_TMPDIR/pip"
  sed "s#^UV=.*#UV='/home/nonexistent-deployer/.local/bin/uv'#" /usr/local/bin/pip > "$wrapper"
  chmod +x "$wrapper"

  run "$wrapper" --version
  # The system-first fallback must resolve a reachable uv and proceed to exec,
  # NOT hit the "refusing to recurse" guard.
  [[ "$output" != *"refusing to recurse"* ]]
  [[ "$output" == *"redirected through uv"* ]]
}

teardown() { [ -n "${FAKE_DIR:-}" ] && rm -rf "$FAKE_DIR"; return 0; }

# ---- whose uv, and the pip surface uv pip does not have (VM#2, VM report s.6) ----
#
# MEASURED (VM#2, reproduced on Ubuntu 26.04 with uv 0.9.9): the system-wide
# wrapper exec'd the DEPLOYING user's ~/.local/bin/uv for `sudo pip` and for
# every other account, a file that user can replace. And `pip --version`,
# `--user` and `download` all failed with uv's own text, naming nothing here.

# A copy of the deployed wrapper whose baked uv is a fake that records its runs.
# $1 = owner uid for the fake (and its directory). Under /tmp, not
# BATS_TEST_TMPDIR, whose 0700 parent another account cannot traverse.
fake_uv_wrapper() {
  FAKE_DIR=$(mktemp -d /tmp/sch-fakeuv.XXXXXX)
  chmod 755 "$FAKE_DIR"
  cat > "$FAKE_DIR/uv" <<FAKE
#!/bin/sh
echo "fake-uv ran as \$(id -u): \$*" >> "$FAKE_DIR/runs"
case "\$1" in --version) echo "uv 9.9.9" ;; esac
case "\$*" in *fail*) exit 2 ;; esac
exit 0
FAKE
  chmod 755 "$FAKE_DIR/uv"
  : > "$FAKE_DIR/runs"; chmod 666 "$FAKE_DIR/runs"
  chown "$1" "$FAKE_DIR" "$FAKE_DIR/uv"
  sed "s#^UV=.*#UV='$FAKE_DIR/uv'#" /usr/local/bin/pip > "$FAKE_DIR/pip"
  chmod 755 "$FAKE_DIR/pip"
}

@test "pip wrapper: root refuses a uv owned by another account, attributably, and never runs it" {
  [ -f /usr/local/bin/pip ] || skip "pip wrapper not deployed"
  [ "$(id -u)" = 0 ] || skip "needs root to give the fake uv to another account"
  fake_uv_wrapper 65534
  # No system uv and no root uv on this PATH/HOME, so the baked one is the only candidate.
  [ -x /usr/local/bin/uv ] || [ -x /usr/bin/uv ] && skip "a system uv exists and would be used"
  run env -i PATH=/usr/bin:/bin HOME=/nonexistent "$FAKE_DIR/pip" install six
  [ "$status" -eq 126 ]
  [[ "$output" == *"[supply-chain-hardening] error: pip on this host is redirected to uv"* ]]
  [[ "$output" == *"$FAKE_DIR/uv"* ]]
  [ ! -s "$FAKE_DIR/runs" ]
}

@test "pip wrapper: an account runs its own uv" {
  [ -f /usr/local/bin/pip ] || skip "pip wrapper not deployed"
  [ "$(id -u)" = 0 ] || skip "needs root to run as another account"
  command -v setpriv >/dev/null || skip "setpriv not installed"
  fake_uv_wrapper 65534
  run setpriv --reuid=65534 --regid=65534 --clear-groups \
    env -i PATH=/usr/bin:/bin HOME=/nonexistent "$FAKE_DIR/pip" list
  [ "$status" -eq 0 ]
  grep -q "fake-uv ran as 65534: pip list" "$FAKE_DIR/runs"
}

@test "pip wrapper: --version answers, naming uv and the redirect" {
  [ -f /usr/local/bin/pip ] || skip "pip wrapper not deployed"
  command -v uv >/dev/null 2>&1 || skip "uv not on PATH; wrapper not deployed"
  run /usr/local/bin/pip --version
  [ "$status" -eq 0 ]
  [[ "$output" == *"uv-pip "* ]]
  [[ "$output" == *"redirected to \`uv pip\` by supply-chain-hardening"* ]]
  run /usr/local/bin/pip3 -V
  [ "$status" -eq 0 ]
}

@test "pip wrapper: --user is refused with a message naming the control and the route" {
  [ -f /usr/local/bin/pip ] || skip "pip wrapper not deployed"
  command -v uv >/dev/null 2>&1 || skip "uv not on PATH; wrapper not deployed"
  run /usr/local/bin/pip install --user six
  [ "$status" -eq 2 ]
  [[ "$output" == *"[supply-chain-hardening] error: 'pip --user' is not available here"* ]]
  [[ "$output" == *"pip-to-uv wrapper"* ]]
  [[ "$output" == *"uv tool install"* ]]
}

@test "pip wrapper: download is refused with a message naming the control" {
  [ -f /usr/local/bin/pip ] || skip "pip wrapper not deployed"
  command -v uv >/dev/null 2>&1 || skip "uv not on PATH; wrapper not deployed"
  run /usr/local/bin/pip download six
  [ "$status" -eq 2 ]
  [[ "$output" == *"[supply-chain-hardening] error: 'pip download' is not available here"* ]]
  # A package that happens to be called "download" is not the subcommand.
  fake_uv_wrapper 0
  run "$FAKE_DIR/pip" install download
  [ "$status" -eq 0 ]
  grep -q "pip install download" "$FAKE_DIR/runs"
}

@test "pip wrapper: download is still recognised after a general option that takes a value" {
  # `pip --python X download six` read X as the subcommand, so the attributed
  # refusal was skipped and uv's own error came first (VM#2 review).
  [ -f /usr/local/bin/pip ] || skip "pip wrapper not deployed"
  [ "$(id -u)" = 0 ] || skip "fixture is root-owned"
  [ -x /usr/local/bin/uv ] || [ -x /usr/bin/uv ] && skip "a system uv exists and would be used"
  fake_uv_wrapper 0
  run "$FAKE_DIR/pip" --python /usr/bin/python3 download six
  [ "$status" -eq 2 ]
  [[ "$output" == *"[supply-chain-hardening] error: 'pip download' is not available here"* ]]
  run "$FAKE_DIR/pip" --cache-dir /tmp/sch-cache download six
  [ "$status" -eq 2 ]
  [ ! -s "$FAKE_DIR/runs" ]
  # The value of such an option is not mistaken for the subcommand either way.
  run "$FAKE_DIR/pip" --cache-dir download install six
  [ "$status" -eq 0 ]
  grep -q "pip --cache-dir download install six" "$FAKE_DIR/runs"
}

@test "pip wrapper: with no uv this account can run, the error names the redirect and the fix" {
  # A uv in a home this account cannot enter is invisible, so this is the
  # branch a second account lands in when the deployer's home is 0750 and the
  # baked uv is there. It used to say only "uv not found ...; refusing to recurse".
  [ -f /usr/local/bin/pip ] || skip "pip wrapper not deployed"
  [ "$(id -u)" = 0 ] || skip "needs root to run as another account"
  command -v setpriv >/dev/null || skip "setpriv not installed"
  [ -x /usr/local/bin/uv ] || [ -x /usr/bin/uv ] && skip "a system uv exists and would be used"
  # The baked uv is real and root-owned, but in a 0700 directory the caller
  # cannot enter, as the deployer's ~/.local/bin is behind a 0750 home.
  FAKE_DIR=$(mktemp -d /tmp/sch-nouv.XXXXXX); chmod 755 "$FAKE_DIR"
  mkdir -m 0700 "$FAKE_DIR/private"
  printf '#!/bin/sh\nexit 0\n' > "$FAKE_DIR/private/uv"; chmod 755 "$FAKE_DIR/private/uv"
  sed "s#^UV=.*#UV='$FAKE_DIR/private/uv'#" /usr/local/bin/pip > "$FAKE_DIR/pip"
  chmod 755 "$FAKE_DIR/pip"
  run setpriv --reuid=65534 --regid=65534 --clear-groups \
    env -i PATH=/usr/bin:/bin HOME=/nonexistent "$FAKE_DIR/pip" install six
  [ "$status" -eq 127 ]
  [[ "$output" == *"[supply-chain-hardening] error: pip on this host is redirected to uv (the pip-to-uv wrapper)"* ]]
  [[ "$output" == *"Install uv for this account"* ]]
  [[ "$output" == *"/usr/local/bin/uv for root and every account"* ]]
}

@test "pip wrapper: a root-owned uv in the caller's own directory is the caller's to run" {
  [ -f /usr/local/bin/pip ] || skip "pip wrapper not deployed"
  [ "$(id -u)" = 0 ] || skip "needs root to run as another account"
  command -v setpriv >/dev/null || skip "setpriv not installed"
  [ -x /usr/local/bin/uv ] || [ -x /usr/bin/uv ] && skip "a system uv exists and would be used"
  fake_uv_wrapper 0
  chown 65534 "$FAKE_DIR"
  run setpriv --reuid=65534 --regid=65534 --clear-groups \
    env -i PATH=/usr/bin:/bin HOME=/nonexistent "$FAKE_DIR/pip" list
  [ "$status" -eq 0 ]
  grep -q "fake-uv ran as 65534: pip list" "$FAKE_DIR/runs"
}

@test "pip wrapper: when uv refuses, the wrapper says it was this host's hardening, keeping uv's exit code" {
  [ -f /usr/local/bin/pip ] || skip "pip wrapper not deployed"
  [ "$(id -u)" = 0 ] || skip "fixture is root-owned"
  fake_uv_wrapper 0
  run env -i PATH=/usr/bin:/bin HOME=/nonexistent "$FAKE_DIR/pip" install fail-please
  [ "$status" -eq 2 ]
  [[ "$output" == *"[supply-chain-hardening] note: uv pip exited 2"* ]]
  [[ "$output" == *"supply-chain-allow-build"* ]]
  run env -i PATH=/usr/bin:/bin HOME=/nonexistent "$FAKE_DIR/pip" install six
  [ "$status" -eq 0 ]
  [[ "$output" != *"note: uv pip exited"* ]]
}

@test "pip wrapper: a real sdist is still refused through the wrapper (no-build unchanged)" {
  [ -f /usr/local/bin/pip ] || skip "pip wrapper not deployed"
  command -v uv >/dev/null 2>&1 || skip "uv not on PATH; wrapper not deployed"
  sdist=$(find_fixture_sdist python-sdist-pkg)
  [ -n "$sdist" ] || skip "sdist fixture not built"
  uv venv -q "$BATS_TEST_TMPDIR/venv"
  run env VIRTUAL_ENV="$BATS_TEST_TMPDIR/venv" /usr/local/bin/pip install "$sdist"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Building source distributions"*"disabled"* ]]
  [[ "$output" == *"supply-chain-allow-build"* ]]
}
