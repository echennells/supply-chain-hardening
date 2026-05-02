#!/usr/bin/env bats

load setup

@test "pnpm: minimum-release-age set" {
  assert_file_contains "$HOME/.config/pnpm/rc" "minimum-release-age="
}

@test "yarn: npmMinimalAgeGate set" {
  assert_file_contains "$HOME/.yarnrc.yml" "npmMinimalAgeGate"
}

@test "yarn: defaultSemverRangePrefix is empty string" {
  assert_file_contains "$HOME/.yarnrc.yml" 'defaultSemverRangePrefix: ""'
}

@test "bun: minimumReleaseAge set" {
  assert_file_contains "$HOME/.bunfig.toml" "minimumReleaseAge"
}

@test "deno: cooldown alias exists in profile.d" {
  assert_file_exists /etc/profile.d/deno-cooldown.sh
  assert_file_contains /etc/profile.d/deno-cooldown.sh "minimum-dependency-age"
}
