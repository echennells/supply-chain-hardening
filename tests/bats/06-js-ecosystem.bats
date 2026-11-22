#!/usr/bin/env bats

load setup

@test "pnpm: minimum-release-age set" {
  assert_file_contains "$HOME/.config/pnpm/rc" "minimum-release-age="
}

@test "yarn: npmMinimalAgeGate set" {
  assert_file_contains "$HOME/.yarnrc.yml" "npmMinimalAgeGate"
}

@test "yarn: npmMinimalAgeGate is a BARE INTEGER (minutes), not a duration string" {
  # Regression catcher for the silent no-op. yarn reads this setting in
  # minutes, and yarn 4.10.x reads a unit-suffixed value as its leading integer:
  # "2d" is a 2-MINUTE gate, with no warning or error, so the 48h gate is
  # invisibly absent (MEASURED 2026-11-19, yarn 4.10.3; 4.11.0 parses "2d" as
  # 2880). The old "presence" assertion above passed happily on the broken
  # value, which is why this one matches the VALUE shape.
  grep -qE '^npmMinimalAgeGate: [0-9]+$' "$HOME/.yarnrc.yml"
}

@test "yarn: npmMinimalAgeGate carries no unit suffix (d/h/m) or quotes" {
  # Any letter after the colon means a duration string slipped back in.
  ! grep -qE '^npmMinimalAgeGate:.*[A-Za-z]' "$HOME/.yarnrc.yml"
}

@test "yarn: defaultSemverRangePrefix is empty string" {
  assert_file_contains "$HOME/.yarnrc.yml" 'defaultSemverRangePrefix: ""'
}

@test "yarn: /etc/yarnrc.yml is never read, so sudo coverage is root's own ~/.yarnrc.yml" {
  # The role used to write /etc/yarnrc.yml "for sudo and other users". MEASURED
  # on Yarn 4.9.4 to 4.18.1: Yarn Berry reads no system-wide file. Pinned to
  # 4.11.0, whose defaults (enableScripts true, gate 0) cannot pass for ours.
  require_root "plants /etc/yarnrc.yml for one command"
  command -v corepack >/dev/null 2>&1 || skip "corepack not installed"
  [ ! -e /etc/yarnrc.yml ] || skip "an /etc/yarnrc.yml is already here, and it is not this test's to move"
  local root_home d e
  root_home=~root
  d=$(mktemp -d); e=$(mktemp -d)
  printf '{"name":"p","version":"0.0.0","packageManager":"yarn@4.11.0"}\n' > "$d/package.json"
  export COREPACK_ENABLE_DOWNLOAD_PROMPT=0 COREPACK_HOME="${COREPACK_HOME:-$root_home/.cache/node/corepack}"
  # An account with no ~/.yarnrc.yml (an empty HOME), with /etc/yarnrc.yml set.
  printf 'enableScripts: false\nnpmMinimalAgeGate: 4321\n' > /etc/yarnrc.yml
  run bash -c "cd '$d' && HOME='$e' yarn config get npmMinimalAgeGate"
  rm -f /etc/yarnrc.yml
  [ "$status" -eq 0 ] || skip "corepack could not run yarn 4.11.0 here: $output"
  [ "$(tail -1 <<<"$output")" != 4321 ]
  run bash -c "cd '$d' && HOME='$e' yarn config get enableScripts"
  [ "$(tail -1 <<<"$output")" = true ]
  # A sudo'd yarn has HOME=/root, so root's own file is what applies.
  run bash -c "cd '$d' && HOME='$root_home' yarn config get npmMinimalAgeGate"
  [ "$(tail -1 <<<"$output")" = "$(sed -n 's/^npmMinimalAgeGate: //p' "$root_home/.yarnrc.yml")" ]
  run bash -c "cd '$d' && HOME='$root_home' yarn config get enableScripts"
  [ "$(tail -1 <<<"$output")" = false ]
  rm -rf "$d" "$e"
}

@test "bun: minimumReleaseAge set" {
  assert_file_contains "$HOME/.bunfig.toml" "minimumReleaseAge"
}

@test "deno: cooldown alias exists in profile.d" {
  [ -f /etc/profile.d/deno-cooldown.sh ] || skip "alias removed — deno_path_wrapper is active (covered by 24-deno-path-wrapper.bats)"
  assert_file_contains /etc/profile.d/deno-cooldown.sh "minimum-dependency-age"
}
