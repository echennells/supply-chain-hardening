#!/usr/bin/env bats
# Pre-flight guard: refuse invocations where privilege escalation would write
# per-user config into the wrong home directory.
#
# The bug this catches: per-user destinations are "{{ ansible_env.HOME }}/..."
# and facts are gathered under the play's become settings. Running the role
# with `--become` (or `sudo ansible-playbook`) from a non-root account makes
# ansible_env.HOME = /root, so every per-user file lands in root's home and
# $HOME-relative tool detection finds nothing and skips — while the recap
# still reports failed=0. Green run, unhardened machine.
#
# Detection keys on SUDO_USER, which sudo sets only when a non-root account
# escalated. The four privilege cases and the escape hatch are all asserted
# here so a future change can't silently reintroduce the mis-target (or start
# false-positiving on legitimate root runs, which would break every host).

load setup

# Self-sufficient ROLE_DIR: the shared setup.bash exports it on some branches
# but not others, and this file runs the role's real preflight.yml.
if [ -z "${ROLE_DIR:-}" ]; then
  if [ -d /opt/ansible-supply-chain-security ]; then
    ROLE_DIR=/opt/ansible-supply-chain-security
  else
    ROLE_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  fi
  export ROLE_DIR
fi

TEST_USER=pfguard

setup_file() {
  id "$TEST_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$TEST_USER"
  echo "$TEST_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$TEST_USER"
  chmod 440 "/etc/sudoers.d/$TEST_USER"
  cat > /tmp/pf-guard.yml <<EOF
- hosts: localhost
  connection: local
  vars:
    release_age_hours: 48
  tasks:
    - import_tasks: $ROLE_DIR/tasks/preflight.yml
EOF
  chmod 644 /tmp/pf-guard.yml
}

teardown_file() {
  rm -f /tmp/pf-guard.yml "/etc/sudoers.d/$TEST_USER"
}

# Run the preflight playbook, optionally as $TEST_USER and/or with --become.
# Echoes output; returns ansible's exit code.
run_pf() {
  local as_user="$1"; shift
  if [ "$as_user" = "root" ]; then
    (cd /tmp && ansible-playbook pf-guard.yml "$@" 2>&1)
  else
    su "$TEST_USER" -c "cd /tmp && ansible-playbook pf-guard.yml $* 2>&1"
  fi
}

@test "become-guard: non-root WITHOUT become is allowed (the intended invocation)" {
  run run_pf "$TEST_USER"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Privilege context OK"
  # per-user config must target the invoking user's home, not root's
  echo "$output" | grep -q "/home/$TEST_USER"
}

@test "become-guard: non-root WITH --become is REFUSED (the mis-target bug)" {
  run run_pf "$TEST_USER" --become
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "Refusing to run"
  # the message must name the escalating user and the wrong destination
  echo "$output" | grep -q "$TEST_USER"
  echo "$output" | grep -q "/root"
}

@test "become-guard: root directly is allowed (no false positive)" {
  run run_pf root
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Privilege context OK"
}

@test "become-guard: root WITH --become is allowed (no false positive)" {
  run run_pf root --become
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Privilege context OK"
}

@test "become-guard: accept_root_home_targeting=true overrides the refusal" {
  run run_pf "$TEST_USER" --become -e accept_root_home_targeting=true
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q "Refusing to run"
}

@test "become-guard: a sudo-derived root shell (sudo -i) is REFUSED, like sudo ansible-playbook" {
  # The case the original guard's comment table got wrong. It claimed
  #   "root directly -> HOME=/root, SUDO_USER unset (legitimate)"
  # and the "no false positive" test above exercises only a genuine root
  # login, where that is true. But `sudo -i` / `sudo su -` is how most
  # operators actually become root, and sudo DOES export SUDO_USER into the
  # resulting shell. Such a run is environmentally identical to
  # `sudo ansible-playbook` and writes to /root just the same, so it must be
  # treated identically: refused, with the documented opt-in.
  #
  # This test pins that behavior in both directions — it fails if the guard
  # stops catching sudo-derived root, and it fails if someone "fixes" the
  # false positive by exempting SUDO_USER without exempting the equivalent
  # sudo ansible-playbook invocation.
  command -v sudo >/dev/null 2>&1 || skip "sudo not available"
  run su "$TEST_USER" -c "sudo -i bash -c 'cd /tmp && ansible-playbook pf-guard.yml' 2>&1"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "Refusing to run"
  echo "$output" | grep -q "$TEST_USER"
}

@test "become-guard: detection is escalation-method agnostic (not sudo-only)" {
  # The guard's primary signal is `id -un` under become:false, which reports
  # the real invoking account no matter how the play escalates. This is what
  # closes the original SUDO_USER-only blind spot: become_method su / doas /
  # pbrun set no SUDO_USER, so a SUDO_USER-only guard would let the
  # mis-target through silently.
  #
  # Asserting on the role source rather than spawning a doas host: the
  # invariant is that the guard does not depend on SUDO_USER alone.
  grep -q "become: false" "$ROLE_DIR/tasks/preflight.yml"
  grep -q "preflight_invoking_user" "$ROLE_DIR/tasks/preflight.yml"
}
