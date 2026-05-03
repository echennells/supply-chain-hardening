#!/usr/bin/env bats
# Adversarial tests for Bun: verify lifecycle scripts are blocked.

load setup

setup() {
  rm -f /tmp/marker-postinstall /tmp/marker-ssh-exfil /tmp/marker-preinstall
}

@test "ATTACK: bun postinstall is blocked" {
  cd /tmp && rm -rf bun-attack-test && mkdir bun-attack-test && cd bun-attack-test
  echo '{"name":"bun-test"}' > package.json
  bun install /opt/test-fixtures/npm-postinstall-pkg 2>/dev/null || true
  [ ! -f /tmp/marker-postinstall ]
  rm -rf /tmp/bun-attack-test
}

@test "ATTACK: bun SSH key exfiltration is blocked" {
  cd /tmp && rm -rf bun-attack-test && mkdir bun-attack-test && cd bun-attack-test
  echo '{"name":"bun-test"}' > package.json
  bun install /opt/test-fixtures/npm-read-ssh-keys 2>/dev/null || true
  [ ! -f /tmp/marker-ssh-exfil ]
  rm -rf /tmp/bun-attack-test
}

@test "ATTACK: bun preinstall hook is blocked" {
  cd /tmp && rm -rf bun-attack-test && mkdir bun-attack-test && cd bun-attack-test
  echo '{"name":"bun-test"}' > package.json
  bun install /opt/test-fixtures/npm-preinstall-script 2>/dev/null || true
  [ ! -f /tmp/marker-preinstall ]
  rm -rf /tmp/bun-attack-test
}
