#!/bin/bash
# What a maven or gradle smoke run showed, from its exit status and its log:
#
#   blocked      refused by the setting the Action wrote, in the tool's own words
#   not-tested   Maven Central answered 429 before the setting could matter
#   not-blocked  anything else: the attack went through, or the run failed for a
#                reason nobody here has seen
#
#   verdict.sh maven|gradle <rc> <log>
#
# Prints "<verdict> <why>" and, on GitHub, sets the step output `verdict`.
#
# The maven job used to grep for `http.*blocked`, which its own fixture's group id
# matches in a download line (.../maven2/com/example/blocked/...): a run in which
# Central refused everything after that line read as "blocked". And a 429 with no
# such line read as "maven did NOT block the HTTP repo" (job 138217056780). So only
# the refusal naming the repository the fixture declared, from the mirror the Action
# wrote, counts, and it is looked for before anything else.
set -u
HERE=$(cd "$(dirname "$0")" && pwd -P)
# shellcheck source=../lib/central-429.sh
. "$HERE/../lib/central-429.sh"
tool=${1:-} rc=${2:-} log=${3:-} tried=""
[ -r "$log" ] || { echo "usage: verdict.sh maven|gradle <rc> <log>" >&2; exit 2; }
case "$tool" in
  maven)
    # Evidence that maven went to the http repository: no 429 excuses that.
    if grep -qE 'Downloading from http-repo: http://|from/to http-repo \(http://' "$log"; then tried=1; fi
    said=$(grep -E 'to central-https-only \(.*Blocked mirror for repositories: \[http-repo \(http://' "$log" | head -1) ;;
  gradle) said=$(grep -E 'Resolution strategy disallows usage of dynamic versions' "$log" | head -1) ;;
  *) echo "verdict.sh: unknown tool '$tool'" >&2; exit 2 ;;
esac
if [ -n "$said" ] && [ "$rc" != 0 ] && [ -z "$tried" ]; then
  v=blocked; why=$said
elif [ "$rc" != 0 ] && [ -z "$tried" ] && central_refused "$log"; then
  v=not-tested; why="Maven Central answered 429, so nothing was learned about the hardening"
else
  v=not-blocked; why="rc=$rc and ${tried:+maven went to the http repository: }no refusal from the setting the Action wrote"
fi
printf '%s %s\n' "$v" "$(printf '%s' "$why" | tr -s ' \t' ' ' | cut -c1-400)"
[ -z "${GITHUB_OUTPUT:-}" ] || echo "verdict=$v" >> "$GITHUB_OUTPUT"
