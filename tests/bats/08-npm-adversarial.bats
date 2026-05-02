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
