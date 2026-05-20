#!/usr/bin/env bats
# Documents the systemd coverage gap (finding M2 from the May 2026
# review): systemd services don't inherit /etc/environment by default
# (PAM-only mechanism), so env-var-only protections — specifically
# GOTOOLCHAIN — are missing for agents running as systemd units.
#
# These tests lock in the documented behavior. If a future change to
# the role (or to systemd's defaults) shifts what propagates, the
# tests fail and force re-evaluation of the README's coverage table.
#
# Container caveat: docker test containers usually don't run systemd
# (no init, no journald, no dbus). Where systemd is genuinely
# unavailable, tests skip; where we can simulate the relevant
# behavior (a process spawned with a clean environment, the way
# systemd would spawn it), we do.

load setup

@test "M2: env-var-only protection (GOTOOLCHAIN) is gone in a systemd-like clean environment" {
  # Simulates what `systemctl start <unit>` produces: a fresh process
  # with no inherited environment. systemd doesn't source
  # /etc/profile.d/ (it's not a shell) and doesn't read
  # /etc/environment automatically (that's pam_env's job, and systemd
  # services don't go through PAM unless they declare PAMName=).
  #
  # The config-file-backed protections (NPM_CONFIG_IGNORE_SCRIPTS,
  # PIP_DISABLE_PIP_VERSION_CHECK, etc.) are duplicated as files
  # the tools read regardless of env. GOTOOLCHAIN is the one
  # protection with no config-file equivalent — Go has no global
  # config file knob for it.
  result=$(env -i bash -c 'echo "${GOTOOLCHAIN:-UNSET}"')
  [ "$result" = "UNSET" ]
}

@test "M2: GOTOOLCHAIN is present in /etc/environment (so EnvironmentFile directive picks it up)" {
  # The workaround the README recommends is: add
  #   EnvironmentFile=/etc/environment
  # (or `Environment=GOTOOLCHAIN=local` directly) to the systemd unit
  # file. For that workaround to be useful, GOTOOLCHAIN must actually
  # exist in /etc/environment. Verify it's there.
  grep -qE "^GOTOOLCHAIN=" /etc/environment
}

@test "M2: /etc/environment GOTOOLCHAIN value matches the role's declared posture" {
  # If someone changes the role's go_toolchain default but forgets to
  # update what /etc/environment writes, systemd units following our
  # README guidance would inherit the stale value silently. Pin this.
  grep -qE "^GOTOOLCHAIN=local$" /etc/environment
}

@test "M2: when /etc/environment IS sourced (the documented workaround), GOTOOLCHAIN propagates" {
  # Simulates a systemd unit with EnvironmentFile=/etc/environment.
  # Reads /etc/environment in a clean shell and verifies GOTOOLCHAIN
  # ends up in the spawned process's env. This is the "this workaround
  # works" half of the M2 story — pair to the "without it, it's gone"
  # test above.
  result=$(env -i bash -c 'set -a; . /etc/environment; set +a; echo "$GOTOOLCHAIN"')
  [ "$result" = "local" ]
}

@test "M2: systemd binary exists OR test container can simulate (does not require live systemd)" {
  # Diagnostic to surface the test-environment situation. Always passes;
  # writes to bats log so a future reader knows what was/wasn't possible
  # in this particular container.
  if command -v systemctl >/dev/null 2>&1; then
    systemd_state=$(systemctl is-system-running 2>&1 || true)
    echo "# systemctl present; system state: $systemd_state" >&3
  else
    echo "# systemctl absent (simulating via env -i; behavior is equivalent for M2 purposes)" >&3
  fi
}

@test "M2: live systemd transient unit demonstrates the gap (if systemd available)" {
  # If the container has live systemd (rare for test containers, common
  # for actual production hosts), spawn a transient unit and prove
  # NPM_CONFIG_IGNORE_SCRIPTS is NOT in its environment despite being
  # in /etc/environment. This is the "real systemd" proof that
  # env-var protections evaporate.
  command -v systemctl >/dev/null 2>&1 || skip "systemctl not available"
  state=$(systemctl is-system-running 2>&1 || true)
  case "$state" in
    running|degraded) ;;  # live systemd, proceed
    *) skip "systemd not active (state: $state)" ;;
  esac

  unit="bats-m2-coverage-test"
  systemd-run --unit="$unit" --collect --wait \
    /bin/bash -c 'env > /tmp/m2-systemd-env-capture' \
    2>/dev/null || skip "systemd-run failed (container restriction)"

  # In a real systemd unit without EnvironmentFile, the env var is absent.
  ! grep -qE "^NPM_CONFIG_IGNORE_SCRIPTS=" /tmp/m2-systemd-env-capture
  ! grep -qE "^GOTOOLCHAIN=" /tmp/m2-systemd-env-capture

  rm -f /tmp/m2-systemd-env-capture
}
