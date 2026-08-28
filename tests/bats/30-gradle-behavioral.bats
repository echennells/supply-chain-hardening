#!/usr/bin/env bats
# Behavioral tests for Gradle supply-chain hardening.
#
# The role's tasks/gradle.yml gates on `which gradle`, then deploys
# ~/.gradle/init.d/supply-chain-security.gradle — an init script that
# throws GradleException on any HTTP (non-HTTPS) repository. Matrix
# mode runs these per (java, gradle) cell to confirm the init script
# is loaded across gradle versions (gradle's init.d discovery has been
# stable since 5.x).
#
# The path is resolved the way GRADLE does, not the way the shell does:
# $GRADLE_USER_HOME wins, and its default is <user.home>/.gradle where the JVM
# takes user.home from the PASSWD ENTRY, not from $HOME. tasks/gradle.yml
# resolves the same way (ansible_user_dir, which ansible reads out of passwd).
# Asserting on a bare $HOME would pass on a host where the role wrote the right
# file to the wrong place, and fail on one where it did the right thing.

load setup

gradle_home() {
  if [ -n "${GRADLE_USER_HOME:-}" ]; then
    printf '%s\n' "$GRADLE_USER_HOME"
    return
  fi
  local pw
  pw=$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6) || pw=""
  [ -n "$pw" ] || pw="$HOME"
  printf '%s\n' "$pw/.gradle"
}

@test "gradle: init.d directory exists" {
  command -v gradle >/dev/null 2>&1 || skip "gradle not installed (role's gradle task is no-op)"
  [ -d "$(gradle_home)/init.d" ]
}

@test "gradle: init script deployed at supply-chain-security.gradle" {
  command -v gradle >/dev/null 2>&1 || skip "gradle not installed"
  [ -f "$(gradle_home)/init.d/supply-chain-security.gradle" ]
}

@test "gradle: init script throws on HTTP repository" {
  command -v gradle >/dev/null 2>&1 || skip "gradle not installed"
  assert_file_contains "$(gradle_home)/init.d/supply-chain-security.gradle" "GradleException"
  assert_file_contains "$(gradle_home)/init.d/supply-chain-security.gradle" "http"
}

@test "gradle: gradle --version works (init script doesn't break the binary)" {
  command -v gradle >/dev/null 2>&1 || skip "gradle not installed"
  run gradle --version
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "gradle"
}

@test "gradle: init script refuses dynamic and changing versions (parity with harden.sh)" {
  command -v gradle >/dev/null 2>&1 || skip "gradle not installed"
  # action/harden.sh has always emitted these two; this file emitted only the
  # HTTP refusal until ECH-160. Guarded by respondsTo() so a gradle without the
  # methods degrades to the HTTP refusal instead of failing every build.
  assert_file_contains "$(gradle_home)/init.d/supply-chain-security.gradle" "failOnDynamicVersions"
  assert_file_contains "$(gradle_home)/init.d/supply-chain-security.gradle" "failOnChangingVersions"
  assert_file_contains "$(gradle_home)/init.d/supply-chain-security.gradle" "respondsTo"
}
