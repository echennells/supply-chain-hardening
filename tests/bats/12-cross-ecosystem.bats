#!/usr/bin/env bats
# Cross-ecosystem tests: verify system-wide enforcement applies
# regardless of how commands are invoked.

load setup

setup() {
  rm -f /tmp/marker-*
}

@test "SYSTEM: /etc/environment is not writable by non-root" {
  # An agent shouldn't be able to modify the hardening
  perms=$(stat -c %a /etc/environment)
  [ "$perms" = "644" ]
}

@test "SYSTEM: /etc/profile.d/supply-chain-hardening.sh is not writable by non-root" {
  perms=$(stat -c %a /etc/profile.d/supply-chain-hardening.sh)
  [ "$perms" = "644" ]
}

@test "SYSTEM: pip wrapper is not writable by non-root" {
  perms=$(stat -c %a /usr/local/bin/pip)
  [ "$perms" = "755" ]
  owner=$(stat -c %U /usr/local/bin/pip)
  [ "$owner" = "root" ]
}

@test "SYSTEM: npm env vars apply in non-interactive bash -c" {
  # An agent running 'bash -c "npm install ..."' must still get the env vars
  result=$(bash -c 'source /etc/profile.d/supply-chain-hardening.sh && echo $NPM_CONFIG_IGNORE_SCRIPTS')
  [ "$result" = "true" ]
}

@test "SYSTEM: Python env vars apply in non-interactive bash -c" {
  result=$(bash -c 'source /etc/profile.d/supply-chain-hardening.sh && echo $PYTHONDONTWRITEBYTECODE')
  [ "$result" = "1" ]
}

@test "SYSTEM: Go env vars apply in non-interactive bash -c" {
  result=$(bash -c 'source /etc/profile.d/supply-chain-hardening.sh && echo $GOSUMDB')
  [ "$result" = "sum.golang.org" ]
}

@test "SYSTEM: Composer env vars apply in non-interactive bash -c" {
  result=$(bash -c 'source /etc/profile.d/supply-chain-hardening.sh && echo $COMPOSER_NO_SCRIPTS')
  [ "$result" = "1" ]
}

@test "SYSTEM: all markers clean after full test run" {
  # Paranoia check: no attack markers should exist
  markers=$(ls /tmp/marker-* 2>/dev/null | wc -l)
  [ "$markers" -eq 0 ]
}
