#!/usr/bin/env bash

# Shared helpers for all BATS test files

# Resolve the role directory in both environments:
#   - Inside the test Docker image: role copied to /opt/ansible-supply-chain-security
#     (see tests/Dockerfile); tests/bats lives at a sibling /opt/tests/bats, so a
#     BATS_TEST_DIRNAME-relative walk would land at /opt instead of the role dir.
#     Prefer the well-known Docker path when it exists.
#   - Local clone (any host, any path): walk up two dirs from the test file's
#     location (tests/bats/x.bats -> repo root). Works on dev machines and CI
#     runners regardless of where the repo was checked out.
# Override by exporting ROLE_DIR before invoking bats.
if [ -z "${ROLE_DIR:-}" ]; then
  if [ -d /opt/ansible-supply-chain-security ]; then
    ROLE_DIR=/opt/ansible-supply-chain-security
  else
    ROLE_DIR="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  fi
fi
export ROLE_DIR

load_profile() {
  source /etc/profile.d/supply-chain-hardening.sh 2>/dev/null || true
}

assert_file_contains() {
  local file="$1"
  local pattern="$2"
  if ! grep -q "$pattern" "$file" 2>/dev/null; then
    echo "FAIL: '$file' does not contain '$pattern'" >&2
    echo "--- file contents ---" >&2
    cat "$file" >&2 2>/dev/null || echo "(file not found)" >&2
    return 1
  fi
}

assert_file_exists() {
  local file="$1"
  if [ ! -f "$file" ]; then
    echo "FAIL: '$file' does not exist" >&2
    return 1
  fi
}

assert_env_equals() {
  local var="$1"
  local expected="$2"
  local actual="${!var}"
  if [ "$actual" != "$expected" ]; then
    echo "FAIL: \$$var = '$actual', expected '$expected'" >&2
    return 1
  fi
}

# Locate a fixture's built sdist regardless of PEP 625 filename normalization.
# setuptools >= 69 renders the sdist filename's name component with UNDERSCORES
# (test-setup-exfil -> test_setup_exfil-<ver>.tar.gz), so globs hard-coded to the
# hyphen spelling silently MISS on Ubuntu 26.04 / modern setuptools and the
# adversarial test SKIPS — a coverage loss that reads as green (ECH-172,
# docs/design-principles.md Axis 4 "absent signal read as a passing signal").
# Each fixture dir holds exactly one package, so match any *.tar.gz. If dist/
# exists but holds no sdist, FAIL LOUDLY (return 2) rather than let the caller
# skip — the guard that stops the silent skip from re-appearing. If dist/ is
# absent (fixture not built in this environment), return empty so the caller can
# legitimately skip.
find_fixture_sdist() {
  local dir="/opt/test-fixtures/$1"
  [ -d "$dir/dist" ] || return 0
  local sdist
  sdist=$(ls "$dir"/dist/*.tar.gz 2>/dev/null | head -1)
  if [ -z "$sdist" ]; then
    echo "find_fixture_sdist: '$dir/dist' exists but holds no .tar.gz — fixture produced no sdist (ECH-172 silent-skip guard)." >&2
    ls -la "$dir/dist" >&2 2>/dev/null || true
    return 2
  fi
  printf '%s\n' "$sdist"
}

# npm >= 12 blocks dependency lifecycle scripts NATIVELY (allowScripts, a
# deferred-approval allowlist), independently of the role's ignore-scripts and
# even of a --ignore-scripts=false / user-.npmrc override (MEASURED, npm 12.0.2:
# the postinstall is blocked with "not covered by allowScripts" regardless).
# That makes every "did a malicious npm script run?" assertion npm-version
# specific: the "blocked" tests become tautologies (npm blocks whether or not
# the role's config is set) and the documented --ignore-scripts=false /
# user-.npmrc BYPASS tests stop reproducing (npm blocks the bypass too). On
# npm >= 12 skip with the reason rather than assert something that is no longer
# about the role (ECH-194); the role's ignore-scripts stays load-bearing on
# npm < 12, which is where these tests remain real.
skip_if_npm_ge_12() {
  local major
  major=$(npm --version 2>/dev/null | cut -d. -f1)
  case "$major" in '' | *[!0-9]*) return 0 ;; esac
  if [ "$major" -ge 12 ]; then
    skip "${1:-npm >=12 blocks lifecycle scripts natively (allowScripts); this assertion is no longer about the role (ECH-194)}"
  fi
}

# Validate that a file parses as TOML, portably across Python versions.
# `tomllib` is stdlib only on Python 3.11+; Ubuntu 22.04 ships 3.10, where these
# tests otherwise erupt in ModuleNotFoundError (20+ false failures — invisible in
# CI, which runs the suite only on 24.04/py3.12). Prefer tomllib, fall back to
# the `tomli` backport, and if neither exists SKIP with a clear reason rather
# than error: a missing parser is a harness gap, not a role failure (the file is
# still deployed; we just can't validate its TOML on this host). Must be called
# directly from a @test body so bats's exit-based `skip` takes effect.
assert_valid_toml() {
  local f="$1" rc
  # NB: the python call is wrapped in `if`, not run bare with `rc=$?`. bats runs
  # test bodies under errexit, so a bare non-zero exit (e.g. no parser -> 3) would
  # kill the test at this line before rc/`skip` are reached. errexit is suppressed
  # inside an `if` condition, so this captures the code and lets `skip` fire.
  if python3 - "$f" <<'PY'
import sys
try:
    import tomllib as t
except ModuleNotFoundError:
    try:
        import tomli as t          # backport for Python < 3.11
    except ModuleNotFoundError:
        sys.exit(3)                # no parser available
try:
    with open(sys.argv[1], "rb") as fh:
        t.load(fh)
except Exception as e:             # any parse failure is a real fail
    print("TOML parse error: %s" % e, file=sys.stderr)
    sys.exit(1)
PY
  then rc=0; else rc=$?; fi
  case "$rc" in
    0) return 0 ;;
    3) skip "no TOML parser on this host (need Python 3.11+ tomllib or the tomli backport); cannot validate $f" ;;
    *) echo "FAIL: $f is not valid TOML" >&2; cat "$f" >&2; return 1 ;;
  esac
}
