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
  assert_file_contains /usr/local/bin/pip "refusing to recurse"
}

@test "pip3 wrapper has a defensive guard against missing uv" {
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
