#!/usr/bin/env bats
# Adversarial tests: simulate real supply chain attack patterns via npm.
# Each fixture has a "malicious" postinstall that writes a marker file.
# If ignore-scripts works, the marker will NOT exist.

load setup

setup() {
  # Clean all markers before each test
  rm -f /tmp/marker-ssh-exfil
  rm -f /tmp/marker-env-exfil
  rm -f /tmp/marker-ssh-persistence
  rm -f /tmp/marker-preinstall
  rm -f /tmp/marker-install-hook
  rm -f /tmp/marker-postinstall
  # Remove any fake authorized_keys entries from prior runs
  sed -i '/FAKE_TEST_KEY/d' /root/.ssh/authorized_keys 2>/dev/null || true
}

@test "ATTACK: npm postinstall SSH key exfiltration is blocked" {
  # Simulates BufferZoneCorp: postinstall reads ~/.ssh/id_rsa
  cd /tmp && rm -rf attack-test && mkdir attack-test && cd attack-test
  npm init -y >/dev/null 2>&1
  npm install /opt/test-fixtures/npm-read-ssh-keys 2>/dev/null || true
  [ ! -f /tmp/marker-ssh-exfil ]
  rm -rf /tmp/attack-test
}

@test "ATTACK: npm postinstall env var harvesting is blocked" {
  # Simulates credential harvesting: dumps env vars with token/key/secret
  cd /tmp && rm -rf attack-test && mkdir attack-test && cd attack-test
  npm init -y >/dev/null 2>&1
  npm install /opt/test-fixtures/npm-env-exfil 2>/dev/null || true
  [ ! -f /tmp/marker-env-exfil ]
  rm -rf /tmp/attack-test
}

@test "ATTACK: npm postinstall SSH persistence is blocked" {
  # Simulates BufferZoneCorp: appends attacker SSH key to authorized_keys
  cd /tmp && rm -rf attack-test && mkdir attack-test && cd attack-test
  npm init -y >/dev/null 2>&1
  npm install /opt/test-fixtures/npm-ssh-persistence 2>/dev/null || true
  [ ! -f /tmp/marker-ssh-persistence ]
  # Double-check: no fake key in authorized_keys
  ! grep -q "FAKE_TEST_KEY_NOT_REAL" /root/.ssh/authorized_keys 2>/dev/null
  rm -rf /tmp/attack-test
}

@test "ATTACK: npm preinstall hook is blocked" {
  # preinstall runs BEFORE package code is even unpacked
  cd /tmp && rm -rf attack-test && mkdir attack-test && cd attack-test
  npm init -y >/dev/null 2>&1
  npm install /opt/test-fixtures/npm-preinstall-script 2>/dev/null || true
  [ ! -f /tmp/marker-preinstall ]
  rm -rf /tmp/attack-test
}

@test "ATTACK: npm install lifecycle hook is blocked" {
  # The 'install' hook (distinct from pre/postinstall)
  cd /tmp && rm -rf attack-test && mkdir attack-test && cd attack-test
  npm init -y >/dev/null 2>&1
  npm install /opt/test-fixtures/npm-install-script 2>/dev/null || true
  [ ! -f /tmp/marker-install-hook ]
  rm -rf /tmp/attack-test
}

@test "DOCUMENTED BYPASS: npm install --ignore-scripts=false CLI flag bypasses hardening in non-PAM contexts" {
  # CLI flags outrank everything in npm's precedence (cli > env >
  # project > user > global > builtin). In any context where
  # NPM_CONFIG_IGNORE_SCRIPTS isn't in the environment (Docker CMD,
  # systemd unit without EnvironmentFile, anything not launched via
  # PAM — which is most agent contexts), passing
  # `--ignore-scripts=false` on the CLI silently re-enables script
  # execution. /etc/npmrc and ~/.npmrc both lose because CLI wins.
  #
  # No defense exists at the role layer — npm's CLI is designed to
  # let callers override config. The wrapper at /usr/local/bin/npm
  # passes args through unchanged; routing through sfw doesn't help
  # (network-layer filter, not a lifecycle interceptor). Documented
  # in README Limitations.
  #
  # This test asserts the bypass works (locks in the current reality).
  # If a future change adds wrapper-level arg filtering or some other
  # defense, this test fails and forces explicit re-evaluation.
  rm -f /tmp/postinstall-marker
  cd /tmp && rm -rf cli-bypass-test && mkdir cli-bypass-test && cd cli-bypass-test
  npm init -y >/dev/null 2>&1
  npm install --ignore-scripts=false /opt/test-fixtures/npm-postinstall-pkg 2>/dev/null || true
  marker_present=$([ -f /tmp/postinstall-marker ] && echo "yes" || echo "no")
  rm -rf /tmp/cli-bypass-test
  rm -f /tmp/postinstall-marker
  [ "$marker_present" = "yes" ]
}

@test "DOCUMENTED BYPASS: user-controlled ~/.npmrc overrides /etc/npmrc in non-PAM contexts" {
  # npm precedence (with no env var in play): per-user .npmrc beats
  # global .npmrc (/etc/npmrc). A user — or any process running as
  # that user — can write `ignore-scripts=false` to their own
  # ~/.npmrc and the role's /etc/npmrc protection is overridden.
  #
  # In PAM-launched contexts (login shells, ssh, sudo -i, cron),
  # NPM_CONFIG_IGNORE_SCRIPTS is in the env and DOES beat user
  # .npmrc — env > user config. The bypass shown here is specific
  # to non-PAM contexts: Docker CMD, systemd units without
  # EnvironmentFile, agent processes, the bats test environment.
  #
  # Documented in README Limitations alongside the M1/M2 entries.
  # If a future change adds defense (e.g., the role refuses to start
  # if ~/.npmrc is operator-modified, or PAM-style env loading is
  # extended into non-PAM contexts), this test fails and forces
  # re-evaluation.
  backup=$(mktemp)
  cp "$HOME/.npmrc" "$backup"

  # Attacker-controlled override at user level
  echo "ignore-scripts=false" > "$HOME/.npmrc"

  rm -f /tmp/postinstall-marker
  cd /tmp && rm -rf user-rc-bypass-test && mkdir user-rc-bypass-test && cd user-rc-bypass-test
  npm init -y >/dev/null 2>&1
  npm install /opt/test-fixtures/npm-postinstall-pkg 2>/dev/null || true
  marker_present=$([ -f /tmp/postinstall-marker ] && echo "yes" || echo "no")

  # Restore role-deployed .npmrc BEFORE asserting (cleanup-first pattern)
  mv "$backup" "$HOME/.npmrc"
  rm -rf /tmp/user-rc-bypass-test
  rm -f /tmp/postinstall-marker

  [ "$marker_present" = "yes" ]
}
