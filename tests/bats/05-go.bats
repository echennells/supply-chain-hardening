#!/usr/bin/env bats

load setup

setup() {
  load_profile
}

@test "go: GOSUMDB is sum.golang.org" {
  result=$(go env GOSUMDB)
  [ "$result" = "sum.golang.org" ]
}

@test "go: GOPROXY is official proxy" {
  result=$(go env GOPROXY)
  [ "$result" = "https://proxy.golang.org,direct" ]
}

@test "go: GOPRIVATE is empty (no modules exempted from sumdb)" {
  result=$(go env GOPRIVATE)
  [ -z "$result" ]
}

@test "go: GONOPROXY is empty (no modules bypass proxy)" {
  result=$(go env GONOPROXY)
  [ -z "$result" ]
}

@test "go: GOINSECURE is empty (HTTPS required for all modules)" {
  result=$(go env GOINSECURE)
  [ -z "$result" ]
}

@test "go: GOTOOLCHAIN is local" {
  result=$(go env GOTOOLCHAIN)
  [ "$result" = "local" ]
}
