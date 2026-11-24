# shellcheck shell=bash
# central_refused <log>: Maven Central answered 429 in this run of maven, gradle or
# curl. GitHub's hosted runners share addresses, and Central rate-limits them.
#
# A run it refused says nothing about the hardening: neither a pass nor a fail. The
# callers print NOT TESTED. MEASURED shapes, kept as fixtures in
# tests/ci/fixtures/central-429/ (jobs 138217056780 and 138043538056):
#   maven   ... from/to central (https://repo.maven.apache.org/maven2): HTTP Status: 429
#           GET request to https://repo.maven.apache.org/... failed ... due to status 429
#   gradle  Could not GET 'https://repo.maven.apache.org/...'.
#              > Received status code 429 from server: Too Many Requests
central_refused() {
  grep -qE '(repo\.maven\.apache\.org|repo1\.maven\.org).*(HTTP Status: 429|status:? 429|429 Too Many Requests)' "$1" 2>/dev/null && return 0
  grep -qE 'Received status code 429 from server' "$1" 2>/dev/null \
    && grep -qE "Could not (GET|HEAD) 'https://(repo\.maven\.apache\.org|repo1\.maven\.org)" "$1" 2>/dev/null
}
