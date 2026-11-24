# shellcheck shell=bash
# Shared by attacks.sh and normal-use.sh: what counts as "Maven Central refused".

# central_refused <log>: Maven Central answered 429 (GitHub's shared runner
# addresses meet its rate limit), in the words of maven, gradle and curl. Such a run
# says nothing about the hardening: it is neither a pass nor a fail.
central_refused() {
  grep -qE '(repo\.maven\.apache\.org|repo1\.maven\.org).*(status( code)?:? ?429|HTTP Status: 429|429 Too Many Requests)|status code 429 from server' "$1" 2>/dev/null
}

# bounded <seconds> <command...>: macOS has no timeout(1).
bounded() { perl -e 'alarm shift; exec @ARGV or exit 127' "$@"; }
