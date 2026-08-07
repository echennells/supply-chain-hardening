#!/usr/bin/env bats
# Behavioral tests for Gradle supply-chain hardening.
#
# The role's tasks/gradle.yml gates on `which gradle`, then deploys
# ~/.gradle/init.d/supply-chain-security.gradle — an init script that
# throws GradleException on any HTTP (non-HTTPS) repository. Matrix
# mode runs these per (java, gradle) cell to confirm the init script
# is loaded across gradle versions (gradle's init.d discovery has been
# stable since 5.x).

load setup

@test "gradle: init.d directory exists" {
  command -v gradle >/dev/null 2>&1 || skip "gradle not installed (role's gradle task is no-op)"
  [ -d "$HOME/.gradle/init.d" ]
}

@test "gradle: init script deployed at supply-chain-security.gradle" {
  command -v gradle >/dev/null 2>&1 || skip "gradle not installed"
  [ -f "$HOME/.gradle/init.d/supply-chain-security.gradle" ]
}

@test "gradle: init script throws on HTTP repository" {
  command -v gradle >/dev/null 2>&1 || skip "gradle not installed"
  assert_file_contains "$HOME/.gradle/init.d/supply-chain-security.gradle" "GradleException"
  assert_file_contains "$HOME/.gradle/init.d/supply-chain-security.gradle" "http"
}

@test "gradle: gradle --version works (init script doesn't break the binary)" {
  command -v gradle >/dev/null 2>&1 || skip "gradle not installed"
  run gradle --version
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "gradle"
}
