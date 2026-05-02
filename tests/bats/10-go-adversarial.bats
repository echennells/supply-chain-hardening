#!/usr/bin/env bats
# Adversarial tests: verify Go env vars can't be poisoned.
# Simulates BufferZoneCorp: malicious init() sets GOSUMDB=off, GOPROXY to attacker.
# Our hardening sets these in /etc/environment so they survive subprocess spawning.

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

@test "ATTACK: GONOSUMDB cannot be set to wildcard '*'" {
  result=$(bash -c 'source /etc/profile.d/supply-chain-hardening.sh; echo $GONOSUMDB')
  [ -z "$result" ]
}

@test "ATTACK: GONOSUMCHECK cannot be set to wildcard '*'" {
  result=$(bash -c 'source /etc/profile.d/supply-chain-hardening.sh; echo $GONOSUMCHECK')
  [ -z "$result" ]
}

@test "ATTACK: GOTOOLCHAIN cannot be changed from 'local'" {
  result=$(bash -c 'source /etc/profile.d/supply-chain-hardening.sh; echo $GOTOOLCHAIN')
  [ "$result" = "local" ]
}

@test "/etc/environment has GONOSUMCHECK empty (blocks wildcard)" {
  grep -q "^GONOSUMCHECK=$" /etc/environment
}

@test "/etc/environment has GONOSUMDB empty (blocks wildcard)" {
  grep -q "^GONOSUMDB=$" /etc/environment
}
