#!/usr/bin/env bats
# Behavioral tests for Socket Firewall.
# sfw requires Node >= 20. Tests skip on older versions.

load setup

setup() {
  NODE_MAJOR=$(node --version | sed 's/v\([0-9]*\).*/\1/')
  if [ "$NODE_MAJOR" -lt 20 ]; then
    skip "sfw requires Node >= 20 (found Node $NODE_MAJOR)"
  fi
}

@test "sfw: binary is installed" {
  which sfw
}

@test "sfw: can execute without permission errors" {
  run sfw --help 2>&1
  [[ ! "${output}" =~ "EACCES" ]]
  [[ ! "${output}" =~ "permission denied" ]]
}

@test "sfw: intercepts npm install and shows protection banner" {
  cd /tmp && rm -rf sfw-test && mkdir sfw-test && cd sfw-test
  npm init -y >/dev/null 2>&1
  output=$(sfw npm install cowsay 2>&1)
  echo "$output" | grep -qi "socket\|firewall\|protected"
  rm -rf /tmp/sfw-test
}
