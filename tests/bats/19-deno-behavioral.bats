#!/usr/bin/env bats
# Behavioral tests for Deno.

load setup

@test "deno: binary is installed" {
  which deno || skip "deno not available on this platform"
}

@test "deno: cooldown alias is in profile.d" {
  assert_file_contains /etc/profile.d/deno-cooldown.sh "minimum-dependency-age"
}

@test "deno: cooldown alias uses correct duration" {
  assert_file_contains /etc/profile.d/deno-cooldown.sh "P2D"
}
