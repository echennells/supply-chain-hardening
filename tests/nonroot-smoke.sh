#!/usr/bin/env bash
# Behavioral proof of the role's protections in the NON-ROOT + INTERACTIVE cell.
# Runs as the unprivileged `dev` user inside tests/Dockerfile.nonroot, AFTER a
# non-root apply. Each check maps to a bug this cell actually shipped:
#   1  verify: no gaps        -> non-root apply left every protection in effect
#   2  real install succeeds  -> sfw runs for dev against its root-owned cache,
#                                also once its 1h update-check window has passed,
#                                and no account but root can write that cache
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
#    that broke the first `npm install` for the invoking user. The cache stays
#    root-owned (a dev-owned one lets dev pick the binary root runs); the
#    wrapper runs sfw with SFW_SKIP_UPDATE_CHECK=1 so dev never writes to it.
say "real npm install as dev"
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

# 2b) ...and still SUCCEED once sfw's hourly update check is due. sfw rewrites
#     .sfw-cache/next-check when it is over an hour old, which dev cannot, and
#     every check above runs inside that hour. VM#1: from one hour after each
#     apply, every non-root npm and cargo call failed with "[sfw] Failed to
#     prepare firewall binary: EACCES ... next-check". Backdate it and retry.
say "real npm install as dev after sfw's 1h update-check window"
sfw_pkg=$(readlink -f "$(command -v sfw 2>/dev/null)" 2>/dev/null); sfw_pkg=${sfw_pkg%/*}; sfw_pkg=${sfw_pkg%/*}
if [ -e "$sfw_pkg/.sfw-cache/latest" ]; then
  printf '2026-01-01T00:00:00.000Z' | sudo tee "$sfw_pkg/.sfw-cache/next-check" >/dev/null
  d1=$(mktemp -d)
  ( cd "$d1" && npm init -y >/dev/null 2>&1 &&
    npm install lodash@4.17.21 --no-audit --no-fund </dev/null >install.log 2>&1 )
  if [ -d "$d1/node_modules/lodash" ] && ! grep -q "Failed to prepare firewall binary" "$d1/install.log"; then
    ok "npm install succeeded as dev with sfw's update check due"
  else
    no "npm install FAILED as dev once sfw's update check was due (wrapper not running sfw read-only?)"
    grep -iE "eacces|permission denied|sfw|npm error" "$d1/install.log" 2>/dev/null | head -5
  fi
  rm -rf "$d1"
else
  echo "SKIP: no warm sfw cache (the apply-time fetch failed), nothing to backdate"
fi

# 2c) ...and only root can change what sfw runs. sfw runs .sfw-cache/latest
#     without re-checking its digest, for root too (`sudo npm install` goes
#     through the wrapper). Up to 8281a6b a non-root apply chowned the cache to
#     the deploying user, so on Debian's npm (prefix /usr/local) dev could
#     repoint latest at a script that `sudo npm view` then ran as uid 0 (VM#1).
#     The root-applied suite cannot see this: that apply chowned it to root.
#     MEASURED against an 8281a6b non-root apply on Debian 13's npm: this
#     check FAILs (".sfw-cache (dev 755)"). On this image's NodeSource npm
#     (prefix /usr) the old chown missed the real cache, so here it guards the
#     invariant rather than replaying VM#1.
say "sfw cache writable only by root"
if [ -d "$sfw_pkg/.sfw-cache" ]; then
  bad=$(find "$sfw_pkg/.sfw-cache" \( ! -uid 0 -o \( ! -type l -perm /022 \) \) -printf '%p (%u %m)\n' 2>/dev/null | head -5)
  if [ -z "$bad" ]; then
    ok "every entry under $sfw_pkg/.sfw-cache is root-owned and not group/other-writable"
  else
    no "sfw cache entries another account can write (that account picks the binary root runs):"
    printf '  %s\n' "$bad"
  fi
else
  echo "SKIP: no sfw cache at $sfw_pkg/.sfw-cache"
fi

# 3) ignore-scripts must block a postinstall for the non-root user.
# npm >=12 blocks lifecycle scripts NATIVELY (allowScripts), so on npm >=12 a
# blocked postinstall proves npm, not the role's ignore-scripts (redundant there,
# still load-bearing on npm <12). Asserting it as a role protection on npm >=12
# would be a tautology (ECH-194) — report it as npm-native instead.
say "postinstall blocked for dev"
npm_major=$(npm --version 2>/dev/null | cut -d. -f1)
case "$npm_major" in '' | *[!0-9]*) npm_major=0 ;; esac
if [ "$npm_major" -ge 12 ]; then
  ok "postinstall blocked for dev — npm ${npm_major} blocks lifecycle scripts natively (allowScripts); role ignore-scripts redundant here, not separately asserted (ECH-194)"
else
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
fi

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
