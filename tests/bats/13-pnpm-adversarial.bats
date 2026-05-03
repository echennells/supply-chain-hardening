#!/usr/bin/env bats
# Adversarial tests for pnpm: verify lifecycle scripts are blocked.

load setup

setup() {
  rm -f /tmp/marker-postinstall /tmp/marker-ssh-exfil /tmp/marker-preinstall
}

@test "ATTACK: pnpm postinstall is blocked" {
  cd /tmp && rm -rf pnpm-attack-test && mkdir pnpm-attack-test && cd pnpm-attack-test
  pnpm init >/dev/null 2>&1
  pnpm install /opt/test-fixtures/npm-postinstall-pkg 2>/dev/null || true
  [ ! -f /tmp/marker-postinstall ]
  rm -rf /tmp/pnpm-attack-test
}

@test "ATTACK: pnpm SSH key exfiltration is blocked" {
  cd /tmp && rm -rf pnpm-attack-test && mkdir pnpm-attack-test && cd pnpm-attack-test
  pnpm init >/dev/null 2>&1
  pnpm install /opt/test-fixtures/npm-read-ssh-keys 2>/dev/null || true
  [ ! -f /tmp/marker-ssh-exfil ]
  rm -rf /tmp/pnpm-attack-test
}

@test "ATTACK: pnpm preinstall hook is blocked" {
  cd /tmp && rm -rf pnpm-attack-test && mkdir pnpm-attack-test && cd pnpm-attack-test
  pnpm init >/dev/null 2>&1
  pnpm install /opt/test-fixtures/npm-preinstall-script 2>/dev/null || true
  [ ! -f /tmp/marker-preinstall ]
  rm -rf /tmp/pnpm-attack-test
}
