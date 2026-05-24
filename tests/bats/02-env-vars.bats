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

@test "/etc/environment has GOSUMDB" {
  assert_file_contains /etc/environment "GOSUMDB=sum.golang.org"
}

@test "/etc/profile.d script exists" {
  assert_file_exists /etc/profile.d/supply-chain-hardening.sh
}
