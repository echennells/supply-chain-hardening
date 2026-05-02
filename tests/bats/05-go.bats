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

@test "go: GONOSUMCHECK is empty" {
  result=$(go env GONOSUMCHECK)
  [ -z "$result" ]
}

@test "go: GONOSUMDB is empty" {
  result=$(go env GONOSUMDB)
  [ -z "$result" ]
}

@test "go: GOTOOLCHAIN is local" {
  result=$(go env GOTOOLCHAIN)
  [ "$result" = "local" ]
}
