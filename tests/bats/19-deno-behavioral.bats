#!/usr/bin/env bats
# Behavioral tests for Deno.
# When deno_path_wrapper is enabled, the alias mechanism is removed and the
# alias-checking tests skip — see 24-deno-path-wrapper.bats for the wrapper
# tests that replace them.

load setup

@test "deno: binary is installed" {
  which deno || skip "deno not available on this platform"
}

@test "deno: cooldown alias is in profile.d" {
  [ -f /etc/profile.d/deno-cooldown.sh ] || skip "alias removed — deno_path_wrapper is active"
  assert_file_contains /etc/profile.d/deno-cooldown.sh "minimum-dependency-age"
}

@test "deno: cooldown alias uses correct duration" {
  [ -f /etc/profile.d/deno-cooldown.sh ] || skip "alias removed — deno_path_wrapper is active"
  assert_file_contains /etc/profile.d/deno-cooldown.sh "P2D"
}
