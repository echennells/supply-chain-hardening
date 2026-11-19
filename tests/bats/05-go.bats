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

# A module whose only dependency exists ONLY in vendor/: no network, no module
# cache, no go.sum. go's default (-mod=vendor when vendor/ exists, go >= 1.14)
# builds it; an explicit -mod=readonly ignores vendor/ and cannot.
# MEASURED on go1.22.12 and go1.27.4 with this exact fixture.
make_vendored_module() {
  local d="$1"
  mkdir -p "$d/vendor/example.com/vendored-dep"
  printf 'module example.com/vendtest\n\ngo 1.21\n\nrequire example.com/vendored-dep v1.0.0\n' > "$d/go.mod"
  printf 'package dep\n\nconst Where = "vendor"\n' > "$d/vendor/example.com/vendored-dep/dep.go"
  printf '# example.com/vendored-dep v1.0.0\n## explicit\nexample.com/vendored-dep\n' > "$d/vendor/modules.txt"
  printf 'package main\n\nimport (\n\t"fmt"\n\n\tdep "example.com/vendored-dep"\n)\n\nfunc main() { fmt.Println(dep.Where) }\n' > "$d/main.go"
}

@test "go: a vendored module builds from vendor/ with no network under the hardened env" {
  # Regression catcher for GOFLAGS=-mod=readonly (written host-wide by
  # earlier versions): it made go ignore vendor/, so this build failed offline with a
  # proxy error naming neither GOFLAGS nor the role. GOPROXY=off stands in for
  # "offline"; GOFLAGS is whatever the hardened environment provides.
  d=$(mktemp -d); make_vendored_module "$d"; cd "$d"
  set +e; out=$(GOPROXY=off go build -o vend . 2>&1); rc=$?; set -e
  if [ "$rc" -ne 0 ]; then
    echo "FAIL: vendored build refused (rc=$rc) with GOFLAGS='$(go env GOFLAGS)': $out" >&2
    return 1
  fi
  [ "$(./vend)" = "vendor" ]
  rm -rf "$d"
}

@test "go: FIXTURE CONTROL — the same module does NOT build with -mod=readonly (the fixture can tell the two apart)" {
  d=$(mktemp -d); make_vendored_module "$d"; cd "$d"
  set +e; out=$(GOFLAGS=-mod=readonly GOPROXY=off go build -o vend . 2>&1); rc=$?; set -e
  [ "$rc" -ne 0 ]
  [ ! -e vend ]
  # The refusal is go looking past vendor/ for the module, not an unrelated error.
  [[ "$out" == *"example.com/vendored-dep"* ]]
  rm -rf "$d"
}
