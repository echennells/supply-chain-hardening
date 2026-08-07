#!/usr/bin/env bats

load setup

@test "pnpm: minimum-release-age set" {
  assert_file_contains "$HOME/.config/pnpm/rc" "minimum-release-age="
}

@test "yarn: npmMinimalAgeGate set" {
  assert_file_contains "$HOME/.yarnrc.yml" "npmMinimalAgeGate"
}

@test "yarn: npmMinimalAgeGate is a BARE INTEGER (minutes), not a duration string" {
  # Regression catcher for the silent no-op. yarn 4.10+ types this setting as
  # integer minutes; a unit-suffixed value ("2d") parses to NaN and yarn applies
  # NO age filtering — with no warning or error, so the gate is invisibly absent.
  # The old "presence" assertion above passed happily on the broken value, which
  # is why this one matches the VALUE shape.
  # Verified on yarn 4.10.3: "36500d" (100y) installed a fresh package;
  # 52560000 (same 100y in minutes) correctly blocked it.
  grep -qE '^npmMinimalAgeGate: [0-9]+$' "$HOME/.yarnrc.yml"
}

@test "yarn: npmMinimalAgeGate carries no unit suffix (d/h/m) or quotes" {
  # Any letter after the colon means a duration string slipped back in.
  ! grep -qE '^npmMinimalAgeGate:.*[A-Za-z]' "$HOME/.yarnrc.yml"
}

@test "yarn: defaultSemverRangePrefix is empty string" {
  assert_file_contains "$HOME/.yarnrc.yml" 'defaultSemverRangePrefix: ""'
}

@test "bun: minimumReleaseAge set" {
  assert_file_contains "$HOME/.bunfig.toml" "minimumReleaseAge"
}

@test "deno: cooldown alias exists in profile.d" {
  [ -f /etc/profile.d/deno-cooldown.sh ] || skip "alias removed — deno_path_wrapper is active (covered by 24-deno-path-wrapper.bats)"
  assert_file_contains /etc/profile.d/deno-cooldown.sh "minimum-dependency-age"
}
