#!/usr/bin/env bats

load setup

setup() {
  load_profile
}

@test "env: NPM_CONFIG_IGNORE_SCRIPTS=true" {
  assert_env_equals NPM_CONFIG_IGNORE_SCRIPTS true
}

@test "env: NPM_CONFIG_AUDIT=true" {
  assert_env_equals NPM_CONFIG_AUDIT true
}

@test "env: NPM_CONFIG_SAVE_EXACT=true" {
  assert_env_equals NPM_CONFIG_SAVE_EXACT true
}

@test "env: NPM_CONFIG_FUND=false" {
  assert_env_equals NPM_CONFIG_FUND false
}

@test "env: UV_NO_SYSTEM_CONFIG is NOT set (would self-disable /etc/uv/uv.toml fallback)" {
  # Regression catcher. The role briefly set UV_NO_SYSTEM_CONFIG=1 as a
  # "block malicious /etc/uv/" defense, but the role itself deploys
  # /etc/uv/uv.toml as the sudo/non-deploying-user fallback. The env
  # var would make uv ignore that file in PAM-loaded shells — exactly
  # the contexts the fallback exists for.
  [ -z "$UV_NO_SYSTEM_CONFIG" ]
}

@test "env: NPM_CONFIG_MIN_RELEASE_AGE=2 (correct npm key; 48h gate expressed in days)" {
  # npm's config key is `min-release-age` (unit: days) → env NPM_CONFIG_MIN_RELEASE_AGE.
  # release_age_hours=48 → npm_minimum_release_age_days=2.
  assert_env_equals NPM_CONFIG_MIN_RELEASE_AGE 2
}

@test "env: NPM_CONFIG_MINIMUM_RELEASE_AGE is NOT emitted (npm rejects it as Unknown env config)" {
  # Regression catcher: the MINIMUM_ variant maps to npm's `minimum-release-age`,
  # which npm does not recognize — it warns "Unknown env config" and will hard-error
  # in a future npm major. The env-var age gate must use the real key.
  # NOTE: COMPOSER_NO_SCRIPTS test intentionally dropped here — that var is a
  # made-up name the role no longer emits; COMPOSER_SKIP_SCRIPTS is tested below.
  ! grep -q "NPM_CONFIG_MINIMUM_RELEASE_AGE" /etc/profile.d/supply-chain-hardening.sh
  ! grep -q "NPM_CONFIG_MINIMUM_RELEASE_AGE" /etc/environment
}

@test "env: GOSUMDB=sum.golang.org" {
  assert_env_equals GOSUMDB sum.golang.org
}

@test "env: GOPROXY set to official proxy" {
  assert_env_equals GOPROXY "https://proxy.golang.org,direct"
}

@test "env: GOFLAGS=-mod=readonly" {
  assert_env_equals GOFLAGS "-mod=readonly"
}

@test "env: GOTOOLCHAIN=local" {
  assert_env_equals GOTOOLCHAIN local
}

@test "env: COMPOSER_SKIP_SCRIPTS enumerates post-install-cmd (belt-and-suspenders for php composer.phar callers)" {
  # The /usr/local/bin/composer wrapper is the primary protection; this
  # env var covers PAM-loaded shells that invoke composer via php
  # composer.phar (bypassing the wrapper). Composer 2.9+ honors it.
  # We assert against one representative event rather than the whole
  # 24-event list — the env var either contains the comma-separated list
  # or it doesn't, and asserting on the most-common event is a robust
  # sentinel that catches regression without locking in the exact text.
  [[ "$COMPOSER_SKIP_SCRIPTS" == *"post-install-cmd"* ]]
}

@test "env: COMPOSER_ALLOW_SUPERUSER=1 (suppress 'do not run as root' noise in CI/agent contexts)" {
  assert_env_equals COMPOSER_ALLOW_SUPERUSER 1
}

@test "/etc/environment has NPM_CONFIG_IGNORE_SCRIPTS" {
  assert_file_contains /etc/environment "NPM_CONFIG_IGNORE_SCRIPTS=true"
}

@test "/etc/environment has NPM_CONFIG_MIN_RELEASE_AGE (correct key, days unit)" {
  assert_file_contains /etc/environment "NPM_CONFIG_MIN_RELEASE_AGE=2"
}

@test "/etc/environment has GOSUMDB" {
  assert_file_contains /etc/environment "GOSUMDB=sum.golang.org"
}

@test "/etc/profile.d script exists" {
  assert_file_exists /etc/profile.d/supply-chain-hardening.sh
}
