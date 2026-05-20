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

@test "ATTACK: npm install --ignore-scripts=false CLI flag does not bypass hardening" {
  # CLI flags outrank env vars in npm's precedence (cli > env > project >
  # user > global > builtin). A naive expectation is that
  # `--ignore-scripts=false` would defeat NPM_CONFIG_IGNORE_SCRIPTS=true
  # and run the postinstall. Today this is blocked (verified manually in
  # the May 2026 review) but the path that catches it isn't documented
  # in one place. Likely combo: env var + ~/.npmrc + /etc/npmrc all
  # set ignore-scripts=true, and `npm install --ignore-scripts=false`
  # only flips the CLI layer — the config layers remain. If npm changes
  # its merge behavior, or if someone removes one of those layers, this
  # test fails and surfaces the regression.
  #
  # If this test FAILS (postinstall ran), the documented bypass surface
  # has expanded; update README Limitations and decide whether to add a
  # wrapper-level reject for this flag combo.
  rm -f /tmp/postinstall-marker
  cd /tmp && rm -rf cli-bypass-test && mkdir cli-bypass-test && cd cli-bypass-test
  npm init -y >/dev/null 2>&1
  npm install --ignore-scripts=false /opt/test-fixtures/npm-postinstall-pkg 2>/dev/null || true
  [ ! -f /tmp/postinstall-marker ]
  rm -rf /tmp/cli-bypass-test
  rm -f /tmp/postinstall-marker
}

@test "ATTACK: user-level ~/.npmrc with ignore-scripts=false is overridden by env+system layers" {
  # Documents npm's precedence assumption: env var > user .npmrc.
  # If npm ever changes precedence (e.g., to make user config win), this
  # test fails and surfaces a real protection gap.
  # We intentionally write to ~/.npmrc here (overriding the role's value)
  # and expect the install to still be blocked because:
  #   - NPM_CONFIG_IGNORE_SCRIPTS=true (env) outranks user config
  #   - /etc/npmrc has ignore-scripts=true (lower priority than user
  #     but still beats default)
  #
  # Restores ~/.npmrc afterward so subsequent tests aren't contaminated.
  backup=$(mktemp)
  cp "$HOME/.npmrc" "$backup"

  # Write attacker-controlled override at user level
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

  [ "$marker_present" = "no" ]
}
