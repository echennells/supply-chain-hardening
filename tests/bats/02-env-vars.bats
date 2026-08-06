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

@test "env: NPM_CONFIG_MIN_RELEASE_AGE=2 (correct npm key; 48h gate expressed in days)" {
  # npm's config key is `min-release-age` (unit: days) → env NPM_CONFIG_MIN_RELEASE_AGE.
  # release_age_hours=48 → npm_minimum_release_age_days=2.
  assert_env_equals NPM_CONFIG_MIN_RELEASE_AGE 2
}

@test "env: NPM_CONFIG_MINIMUM_RELEASE_AGE is NOT emitted (npm rejects it as Unknown env config)" {
  # Regression catcher: the MINIMUM_ variant maps to npm's `minimum-release-age`,
  # which npm does not recognize — it warns "Unknown env config" and will hard-error
  # in a future npm major. The env-var age gate must use the real key.
  ! grep -q "NPM_CONFIG_MINIMUM_RELEASE_AGE" /etc/profile.d/supply-chain-hardening.sh
  ! grep -q "NPM_CONFIG_MINIMUM_RELEASE_AGE" /etc/environment
}

@test "env: COMPOSER_NO_SCRIPTS=1" {
  assert_env_equals COMPOSER_NO_SCRIPTS 1
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
