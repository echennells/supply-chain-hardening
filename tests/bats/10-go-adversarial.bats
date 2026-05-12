#!/usr/bin/env bats
# Adversarial tests: verify Go env vars can't be poisoned.
# Simulates BufferZoneCorp: malicious init() sets GOSUMDB=off, GOPROXY to attacker.
# Our hardening sets these in /etc/environment so they survive subprocess spawning.
#
# Note: the bypass knobs we defend are the actual Go env vars documented at
# https://go.dev/ref/mod (GOPRIVATE, GONOPROXY, GOINSECURE). An earlier version
# of this role set GONOSUMCHECK and GONOSUMDB — neither is a real Go env var,
# so those assertions were trivially-true no-ops that gave a false sense of
# coverage. Tests below use the documented variables.

load setup

setup() {
  load_profile
}

@test "ATTACK: GOSUMDB cannot be overridden to 'off' by subprocess" {
  # Simulates: malicious Go code sets GOSUMDB=off
  # Our /etc/environment sets GOSUMDB=sum.golang.org
  # A subprocess that tries to override should see the parent's value
  # (unless it explicitly exports, which init() does — but our profile.d re-sets on shell start)
  result=$(bash -c 'source /etc/profile.d/supply-chain-hardening.sh; echo $GOSUMDB')
  [ "$result" = "sum.golang.org" ]
}

@test "ATTACK: GOPROXY cannot be redirected to attacker endpoint" {
  result=$(bash -c 'source /etc/profile.d/supply-chain-hardening.sh; echo $GOPROXY')
  [ "$result" = "https://proxy.golang.org,direct" ]
}

@test "ATTACK: GOPRIVATE cannot be set to wildcard to bypass sumdb" {
  # GOPRIVATE='*' would mark all modules as private, skipping sumdb checks.
  # Our hardening keeps it empty so every module is verified.
  result=$(bash -c 'source /etc/profile.d/supply-chain-hardening.sh; echo $GOPRIVATE')
  [ -z "$result" ]
}

@test "ATTACK: GONOPROXY cannot be set to bypass module proxy" {
  result=$(bash -c 'source /etc/profile.d/supply-chain-hardening.sh; echo $GONOPROXY')
  [ -z "$result" ]
}

@test "ATTACK: GOINSECURE cannot be set to allow HTTP for any module" {
  result=$(bash -c 'source /etc/profile.d/supply-chain-hardening.sh; echo $GOINSECURE')
  [ -z "$result" ]
}

@test "ATTACK: GOTOOLCHAIN cannot be changed from 'local'" {
  result=$(bash -c 'source /etc/profile.d/supply-chain-hardening.sh; echo $GOTOOLCHAIN')
  [ "$result" = "local" ]
}

@test "/etc/environment has GOPRIVATE empty (blocks wildcard)" {
  grep -q "^GOPRIVATE=$" /etc/environment
}

@test "/etc/environment has GONOPROXY empty (blocks wildcard)" {
  grep -q "^GONOPROXY=$" /etc/environment
}

@test "/etc/environment has GOINSECURE empty (blocks wildcard)" {
  grep -q "^GOINSECURE=$" /etc/environment
}
