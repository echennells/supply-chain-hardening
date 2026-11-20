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
  # Every test here runs the preflight as a second account, which this creates
  # with a sudoers drop-in. As a normal user that fails at useradd and bats
  # reports one "setup_file failed" line in place of all seven tests, which is
  # how they went unreported on every VM run of the suite. In the container
  # suite (root) they run.
  require_root "creates the $TEST_USER account and an /etc/sudoers.d drop-in"
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
  # Nothing was created when setup_file skipped (not root), and /etc/sudoers.d
  # is not searchable by a normal user, so rm -f would fail and turn the skip
  # into a "teardown_file failed".
  [ "$(id -u)" = 0 ] || return 0
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

# ---- sudo-rs vs ansible-core's become prompt ----
#
# MEASURED on Ubuntu 26.04 (sudo-rs 0.2.13): with a password prompt, every
# become on ansible-core < 2.20.11 and on 2.21.0-2.21.5 stops with "Timed out
# waiting for become success or become password prompt" (rc=4). The preflight
# refuses that combination before the first become, naming the fix. These tests
# put a stub `sudo` first on PATH, so they need neither sudo-rs nor a second
# ansible-core: the stub answers `--version` as sudo-rs (or classic sudo) and
# `-n true` as "a password is needed" (or not), and hands everything else to the
# real sudo, so the become tasks later in preflight still work. Whether the
# refusal SHOULD fire depends on the runner's ansible-core, so each test works
# that out from `ansible --version` instead of assuming the image's version.
# The verdict cannot be pinned from here: `-e '{"ansible_version": {...}}'`
# does not override the real ansible_version on any core from 2.14 to 2.22
# (MEASURED, 2.14.18 to 2.22.0). So on a fixed core the refusal test checks
# that nothing is refused and then reports itself SKIPPED, rather than
# passing: a tests/Dockerfile move to a fixed core must not turn it into a
# quiet pass that no longer exercises the refusal.

# Is the ansible-core on PATH one of the releases that time out under sudo-rs?
# Prints "affected" or "fixed"; prints nothing when the version cannot be read.
ansible_core_verdict() {
  local v
  v=$(ansible --version 2>/dev/null | sed -nE '1s/.*core ([0-9]+\.[0-9]+\.[0-9]+).*/\1/p')
  [ -n "$v" ] || return 0
  python3 - "$v" <<'PY2'
import sys
v = tuple(int(x) for x in sys.argv[1].split("."))
bad = v < (2, 20, 11) or ((2, 21, 0) <= v < (2, 21, 6))
print("affected" if bad else "fixed")
PY2
}

# make_sudo_stub <version line> <rc for `sudo -n true`>
# Under /tmp, not BATS_TEST_TMPDIR: the second account has to traverse it.
make_sudo_stub() {
  STUB_DIR=$(mktemp -d /tmp/sch-sudo-stub.XXXXXX)
  cat > "$STUB_DIR/sudo" <<EOF
#!/bin/sh
case "\$*" in
  --version) echo '$1'; exit 0 ;;
  '-n true') exit $2 ;;
esac
exec /usr/bin/sudo "\$@"
EOF
  chmod 755 "$STUB_DIR" "$STUB_DIR/sudo"
}

teardown() {
  [ -z "${STUB_DIR:-}" ] || rm -rf "$STUB_DIR"
}

# A bare `! cmd` does not fail a bats test unless it is the last command, so
# absence is asserted through a function that returns non-zero.
refute_output_has() {
  if echo "$output" | grep -q -- "$1"; then
    echo "unexpected in output: $1" >&2
    return 1
  fi
}

run_pf_with_stub() {
  su "$TEST_USER" -c "cd /tmp && PATH='$STUB_DIR':\$PATH ansible-playbook pf-guard.yml $* 2>&1"
}

@test "sudo-rs guard: a password prompt on an affected ansible-core is refused, naming the fix" {
  command -v sudo >/dev/null 2>&1 || skip "sudo not available"
  local verdict; verdict=$(ansible_core_verdict)
  [ -n "$verdict" ] || skip "could not read the ansible-core version"
  make_sudo_stub "sudo-rs 0.2.13-0ubuntu1.2" 1
  run run_pf_with_stub
  echo "ansible-core verdict: $verdict"; echo "$output" | tail -15
  if [ "$verdict" = affected ]; then
    [ "$status" -ne 0 ]
    echo "$output" | grep -q "\[supply-chain-hardening\] preflight: ansible-core [0-9.]* cannot answer the sudo-rs password prompt"
    echo "$output" | grep -q "sudo-rs 0.2.13"
    echo "$output" | grep -q "pipx install 'ansible-core>=2.21.6'"
    echo "$output" | grep -q "NOPASSWD"
    # It must stop BEFORE the first become task, not after that task timed out.
    refute_output_has "Detect non-managed existing system config files"
  else
    # A fixed ansible-core answers sudo-rs's prompt: nothing to refuse.
    [ "$status" -eq 0 ]
    refute_output_has "cannot answer the sudo-rs password prompt"
    skip "ansible-core here answers sudo-rs's prompt, so the refusal itself was not exercised (needs < 2.20.11 or 2.21.0-2.21.5)"
  fi
}

@test "sudo-rs guard: sudo-rs without a password prompt (NOPASSWD) is allowed on any ansible-core" {
  command -v sudo >/dev/null 2>&1 || skip "sudo not available"
  make_sudo_stub "sudo-rs 0.2.13-0ubuntu1.2" 0
  run run_pf_with_stub
  echo "$output" | tail -15
  [ "$status" -eq 0 ]
  refute_output_has "cannot answer the sudo-rs password prompt"
  echo "$output" | grep -q "Privilege context OK"
}

@test "sudo-rs guard: classic sudo with a password prompt is not refused" {
  command -v sudo >/dev/null 2>&1 || skip "sudo not available"
  make_sudo_stub "Sudo version 1.9.15p5" 1
  run run_pf_with_stub
  echo "$output" | tail -15
  [ "$status" -eq 0 ]
  refute_output_has "cannot answer the sudo-rs password prompt"
}
