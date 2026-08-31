#!/usr/bin/env bash
# Behavioral proof of the role's protections in the NON-ROOT + INTERACTIVE cell.
# Runs as the unprivileged `dev` user inside tests/Dockerfile.nonroot, AFTER a
# non-root apply. Each check maps to a bug this cell actually shipped:
#   1  verify: no gaps        -> non-root apply left every protection in effect
#   2  real install succeeds  -> the sfw cache is writable by dev (not root-owned EACCES)
#   3  postinstall blocked    -> ignore-scripts is enforced for the ordinary user
#   4  interactive no-loop     -> the npm->npq->npm re-entry guard terminates
set -u
fail=0
ok(){ printf 'PASS: %s\n' "$1"; }
no(){ printf 'FAIL: %s\n' "$1"; fail=1; }
say(){ printf '\n=== %s ===\n' "$1"; }

say "context"
u=$(id -un)
echo "user=$u  npm=$(command -v npm) ($(npm --version 2>&1))  home=$HOME"
[ "$u" = "dev" ] || no "expected to run as non-root 'dev', got '$u'"
[ "$(id -u)" != "0" ] || no "running as root — this image is meant to prove the NON-root cell"

# 1) The verifier must find NO GAPS after a non-root apply. This is the load
#    -bearing regression guard: the npq-alias break and the failed global
#    installs all surfaced here as gaps that root-apply never produced.
say "verify: no gaps as non-root"
vout=$(/usr/local/bin/supply-chain-verify 2>&1); vrc=$?
printf '%s\n' "$vout" | tail -45
# Tolerate ONLY the Socket Firewall gap: sfw's firewall binary is fetched from
# GitHub at apply time (best-effort, network-dependent) and the role records it
# as a skipped protection when the fetch fails — a CI runner's network flakes on
# it. Any OTHER gap is a real regression this smoke must catch (e.g. the pip
# PATH wrapper before uv was installed).
unexpected=$(printf '%s\n' "$vout" | sed 's/\x1b\[[0-9;]*m//g' \
  | grep -E '(^|[[:space:]])GAP[[:space:]]' | grep -viE 'Socket Firewall')
if [ -z "$unexpected" ]; then
  ok "verify: no unexpected gaps as non-root (sfw binary-fetch is best-effort/network-dependent; rc=$vrc)"
else
  no "verify reports UNEXPECTED gaps after non-root apply (rc=$vrc):"
  printf '  %s\n' "$unexpected"
fi

# 2) A real install as dev must SUCCEED — guards the root-owned sfw cache EACCES
#    that broke the first `npm install` for the invoking user.
say "real npm install as dev (sfw cache writable?)"
d1=$(mktemp -d)
( cd "$d1" && npm init -y >/dev/null 2>&1 &&
  npm install lodash@4.17.21 --no-audit --no-fund </dev/null >install.log 2>&1 )
if [ -d "$d1/node_modules/lodash" ]; then
  ok "npm install succeeded as dev"
else
  no "npm install FAILED as dev (sfw cache / wrapper regression?)"
  grep -iE "eacces|permission denied|sfw|npm error" "$d1/install.log" 2>/dev/null | head -5
fi
rm -rf "$d1"

# 3) ignore-scripts must block a postinstall for the non-root user.
say "postinstall blocked for dev"
rm -f /tmp/postinstall-marker
d2=$(mktemp -d)
( cd "$d2" && npm init -y >/dev/null 2>&1 &&
  npm install /home/dev/fixtures/npm-postinstall-pkg </dev/null >/dev/null 2>&1 || true )
if [ -e /tmp/postinstall-marker ]; then
  no "postinstall RAN — ignore-scripts not enforced for dev"
else
  ok "postinstall blocked for dev"
fi
rm -rf "$d2" /tmp/postinstall-marker

# 4) The INTERACTIVE wrapper branch must not infinite-loop. `script` gives a real
#    pty so `[ -t 0 ] && [ -t 1 ]` is true and the wrapper hands off to npq; a
#    missing re-entry guard makes npq -> npm -> npq loop forever. We answer any
#    prompt with `yes` so npq PROCEEDS to re-invoke npm (the exact round-trip the
#    guard must break) and assert only that the process RETURNS — a loop shows up
#    as the 90s timeout (rc 124). npq/sfw's network verdict is deliberately not
#    asserted; this test owns termination, not reputation.
say "interactive pty: no infinite loop"
if script -qec 'test -t 0 && test -t 1 && echo HAVE_TTY' /dev/null 2>/dev/null | grep -q HAVE_TTY; then
  d3=$(mktemp -d)
  ( cd "$d3" && npm init -y >/dev/null 2>&1 )
  t0=$(date +%s)
  # `yes` answers npq's interactive continue-prompt so it PROCEEDS to re-invoke
  # npm — the exact round-trip a missing re-entry guard turns into an endless
  # npm->npq->npm loop. Completion is the proof the guard terminates it; a loop
  # (or a hung prompt) instead burns the 90s and trips the timeout. Trailing
  # SIGPIPE/SIGKILL as `yes`/`script` tear down AFTER completion is expected and
  # ignored — we judge on the install, not the pipeline's exit signal.
  timeout 90 bash -c "cd '$d3' && yes 2>/dev/null | script -qec 'npm install lodash@4.17.21 --no-audit --no-fund' /dev/null >/dev/null 2>&1" >/dev/null 2>&1
  trc=$?
  t1=$(date +%s); elapsed=$((t1 - t0))
  installed=no; [ -d "$d3/node_modules/lodash" ] && installed=yes
  rm -rf "$d3"
  if [ "$installed" = yes ]; then
    ok "interactive install COMPLETED in ${elapsed}s — wrapper->npq->npm round-trip terminated (no loop)"
  elif [ "$trc" -eq 124 ]; then
    no "interactive install TIMED OUT after ${elapsed}s — wrapper is looping (re-entry guard regressed)"
  else
    ok "interactive path returned in ${elapsed}s without installing (npq/sfw declined) — no loop"
  fi
else
  no "pty harness vacuous: script did not allocate a tty; interactive test inconclusive"
fi

say "summary"
if [ "$fail" -eq 0 ]; then
  echo "ALL NON-ROOT / INTERACTIVE SMOKES PASSED"
else
  echo "NON-ROOT / INTERACTIVE SMOKES FAILED"
fi
exit "$fail"
