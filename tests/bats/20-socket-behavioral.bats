#!/usr/bin/env bats
# Behavioral tests for Socket Firewall.
# sfw requires Node >= 20. Tests skip on older versions.

load setup

setup() {
  NODE_MAJOR=$(node --version | sed 's/v\([0-9]*\).*/\1/')
  if [ "$NODE_MAJOR" -lt 20 ]; then
    skip "sfw requires Node >= 20 (found Node $NODE_MAJOR)"
  fi
}

# sfw's npm package is a launcher that asks the GitHub API for its firewall
# binary, unauthenticated: 60 calls an hour per IP, and hosted runners share IPs.
# MEASURED 2026-11-23: with the quota used up the API answers 403 and sfw 2.0.6
# exits 1 with "Unable to fetch latest release" within 0.3 s; 10 of 30 sfw smoke
# jobs that week started on a runner in that state. The role then moves sfw aside
# and records why, which is what it should do, so the test for a working install
# has nothing to check. Only that recorded reason skips it: an sfw that is
# missing for any other reason (EACCES, a timeout, a bad binary, no record at
# all) is a failure.
sfw_fetch_refused() { # <log of the apply>
  [ -f "$1" ] && grep -qE 'its runtime binary could not be fetched from GitHub \(exit 1: \[sfw\] Failed to prepare firewall binary: (Unable to fetch latest release|GET https://[^ ]+ failed with (403|429|5[0-9][0-9]))' "$1"
}

@test "sfw: binary is installed" {
  command -v sfw && return 0
  if sfw_fetch_refused /var/log/ansible-run.log; then
    # Moved aside by the role, not simply absent.
    ls "$(npm prefix -g)"/bin/sfw.broken
    skip "GitHub refused sfw's firewall binary when the image was built; the role recorded it and moved sfw aside"
  fi
  echo "sfw is not on PATH, and the apply did not record a refused download"
  return 1
}

@test "sfw: only a recorded refusal excuses a missing sfw" {
  local p="its runtime binary could not be fetched from GitHub" e="[sfw] Failed to prepare firewall binary:" l
  while IFS= read -r l; do
    printf '%s\n' "$l" > "$BATS_TEST_TMPDIR/log"
    sfw_fetch_refused "$BATS_TEST_TMPDIR/log" || { echo "not excused: $l"; return 1; }
  done <<EOF
7. Socket Firewall - installed, but $p (exit 1: $e Unable to fetch latest release and no valid cached release found.). sfw is a shim
7. Socket Firewall - installed, but $p (exit 1: $e GET https://release-assets.example/x failed with 503). sfw is a shim
EOF
  while IFS= read -r l; do
    printf '%s\n' "$l" > "$BATS_TEST_TMPDIR/log"
    ! sfw_fetch_refused "$BATS_TEST_TMPDIR/log" || { echo "excused: $l"; return 1; }
  done <<EOF
7. Socket Firewall - installed, but $p (exit 1). sfw is a shim
7. Socket Firewall - installed, but $p (exit 1: $e EACCES: permission denied, mkdir '/x/.sfw-cache'). sfw is a shim
7. Socket Firewall - installed, but $p (exit 1: $e GET https://release-assets.example/x failed with 404). sfw is a shim
7. Socket Firewall - installed, but $p (exit 124: downloading latest sfw binary...). sfw is a shim
7. Socket Firewall - installed, but $p (exit 126: Exec format error). sfw is a shim
TASK [Record skipped protection - Socket Firewall binary could not be fetched]
EOF
  ! sfw_fetch_refused "$BATS_TEST_TMPDIR/nolog"
}

@test "sfw: can execute without permission errors" {
  run sfw --help 2>&1
  [[ ! "${output}" =~ "EACCES" ]]
  [[ ! "${output}" =~ "permission denied" ]]
}

@test "sfw: wraps npm install (routes it through Socket Firewall)" {
  cd /tmp && rm -rf sfw-test && mkdir sfw-test && cd sfw-test
  npm init -y >/dev/null 2>&1
  # sfw@2 is a thin launcher for the Socket Firewall binary: it proxies npm
  # transparently and only prints a banner when it BLOCKS a flagged package.
  # For a clean package it stays silent, so the old "socket|firewall|protected"
  # banner grep no longer matches (external UX change, verified 2026-08).
  # Assert interception by outcome instead — the wrapped install completes and
  # the package lands. Skip (don't fail) if sfw can't reach its binary/registry;
  # an offline runner shouldn't red the build over an external dependency.
  run sfw npm install cowsay
  if [ "$status" -ne 0 ]; then
    skip "sfw could not complete the install (offline / Socket binary unreachable)"
  fi
  [ -d node_modules/cowsay ]
  rm -rf /tmp/sfw-test
}

# --- sfw for a NON-ROOT caller ------------------------------------------------
#
# Everything above runs as root, the account that owns sfw's cache. sfw keeps
# that cache in its own package directory (root-owned after a root
# `npm install -g`) and rewrites .sfw-cache/next-check there whenever the last
# update check is more than an hour old (CHECK_TTL in sfw 2.0.6). A test that
# runs within an hour of the apply, as root, can never see what happens next.
# VM#1 (2026-11-19, 9 real hosts): on NodeSource hosts every non-root npm and
# cargo call failed with "[sfw] Failed to prepare firewall binary: EACCES ...
# next-check" from one hour after each apply. These tests backdate next-check
# and run npm as an ordinary account, so they cross that hour on purpose.

SFW_USER=sfwprobe

sfw_cache_dir() {
  local s
  s=$(readlink -f "$(command -v sfw 2>/dev/null)" 2>/dev/null) || return 1
  s=${s%/*}; s=${s%/*}
  [ -f "$s/package.json" ] || return 1
  echo "$s/.sfw-cache"
}

# A second account plus a world-readable local package and a project it owns.
# The package is a directory, so the install fetches nothing: the test measures
# sfw's own start-up, not the network.
sfw_user_project() {
  [ "$(id -u)" = 0 ] || skip "needs root to create a second account"
  id "$SFW_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$SFW_USER"
  PROJ=$(mktemp -d /tmp/sfw-nonroot.XXXXXX)
  mkdir -p "$PROJ/pkg" "$PROJ/app"
  printf '{"name":"sfw-probe-pkg","version":"1.0.0"}\n' > "$PROJ/pkg/package.json"
  printf '{"name":"sfw-probe-app","version":"1.0.0"}\n' > "$PROJ/app/package.json"
  chown -R "$SFW_USER" "$PROJ"
  chmod 755 "$PROJ"
}

sfw_preconditions() {
  command -v sfw >/dev/null 2>&1 || skip "sfw not installed"
  CACHE=$(sfw_cache_dir) || skip "sfw package layout not recognised"
  [ -e "$CACHE/latest" ] || skip "sfw cache is cold: the apply-time warm failed (offline?)"
  grep -q supply-chain-hardening /usr/local/bin/npm 2>/dev/null || skip "npm wrapper not deployed"
}

teardown() {
  if [ -n "${CACHE:-}" ] && [ -e "$CACHE.bats-cold" ]; then
    rm -rf "$CACHE"; mv "$CACHE.bats-cold" "$CACHE"
  fi
  if [ -n "${CACHE:-}" ] && [ -f "$BATS_TEST_TMPDIR/next-check" ]; then
    cp -p "$BATS_TEST_TMPDIR/next-check" "$CACHE/next-check"
  fi
  [ -n "${PROJ:-}" ] && rm -rf "$PROJ"
  return 0
}

@test "sfw: a non-root npm install still runs through sfw after the 1h update-check window" {
  sfw_preconditions
  sfw_user_project
  cp -p "$CACHE/next-check" "$BATS_TEST_TMPDIR/next-check" 2>/dev/null || true
  printf '2026-01-01T00:00:00.000Z' > "$CACHE/next-check"

  run su - "$SFW_USER" -c "cd '$PROJ/app' && npm install --no-audit --no-fund ../pkg 2>&1"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Failed to prepare firewall binary"* ]]
  # No wrapper warning means the wrapper took its sfw branch, not a pass-through.
  [[ "$output" != *"[supply-chain-hardening] warning"* ]]
  [ -e "$PROJ/app/node_modules/sfw-probe-pkg" ]

  # And positively: sfw's firewall is in the chain. It runs its child behind a
  # local proxy with its own CA (MEASURED, sfw-free 1.16.0: HTTPS_PROXY and
  # NODE_EXTRA_CA_CERTS=/tmp/sfw-*/socketFirewallCa.crt; neither is set
  # without sfw). `npm exec` goes through the same branch of the wrapper.
  printf 'console.log("CA=" + (process.env.NODE_EXTRA_CA_CERTS || "none"))\n' > "$PROJ/env.js"
  chmod 644 "$PROJ/env.js"
  run su - "$SFW_USER" -c "cd '$PROJ/app' && npm exec --yes -- node ../env.js 2>&1"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"CA="*socketFirewall* ]]

  # And sfw left the root-owned cache alone.
  [ "$(cat "$CACHE/next-check")" = "2026-01-01T00:00:00.000Z" ]
}

@test "sfw: the verifier's Socket Firewall row stays OK for a non-root caller after the 1h window" {
  # The verifier probes sfw too. Before it ran sfw the way the wrappers do,
  # this row turned GAP an hour after every apply (VM matrix: "+2 GAP after 1h").
  sfw_preconditions
  sfw_user_project
  [ -x /usr/local/bin/supply-chain-verify ] || skip "verifier not deployed"
  cp -p "$CACHE/next-check" "$BATS_TEST_TMPDIR/next-check" 2>/dev/null || true
  printf '2026-01-01T00:00:00.000Z' > "$CACHE/next-check"

  run su - "$SFW_USER" -c "cd '$PROJ' && /usr/local/bin/supply-chain-verify 2>&1"
  row=$(printf '%s\n' "$output" | sed 's/\x1b\[[0-9;]*m//g' | grep 'Socket Firewall')
  echo "$row"
  [[ "$row" == *OK* ]]
  [[ "$row" != *GAP* ]]
}

@test "sfw: with a cold cache a non-root npm install warns by name and proceeds" {
  # A root reinstall of sfw leaves the cache empty (npm replaces the package
  # directory), and only root can fill it: sfw downloads the binary
  # even with SFW_SKIP_UPDATE_CHECK=1 when nothing is cached. The wrapper must
  # say so in our name and pass through, as it does when sfw is absent, rather
  # than fail every install with sfw's "EACCES ... mkdir .sfw-cache".
  sfw_preconditions
  sfw_user_project
  mv "$CACHE" "$CACHE.bats-cold"

  run su - "$SFW_USER" -c "cd '$PROJ/app' && npm install --no-audit --no-fund ../pkg 2>&1"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[supply-chain-hardening] warning: sfw has no firewall binary cached"* ]]
  [[ "$output" != *"Failed to prepare firewall binary"* ]]
  [ -e "$PROJ/app/node_modules/sfw-probe-pkg" ]
  [ ! -e "$CACHE" ]
}

@test "sfw: the cold-cache warning names a command that leaves a binary every account can run" {
  # The warning used to say "run 'sudo sfw true' once". Where sudo runs that
  # under a umask of 077 (a caller's 077 carries through sudo on Debian 13, as
  # does sudoers `Defaults umask=0077`), sfw 2.0.6 downloaded the binary into a
  # 0700 cache and every other account kept getting this warning (MEASURED,
  # Ubuntu 24.04 with `Defaults umask=0077`). That cache is staged here from the
  # warm one, so nothing is downloaded: next-check is fresh, so root's run makes
  # no update check either.
  sfw_preconditions
  sfw_user_project
  cp -a "$CACHE" "$CACHE.bats-cold"
  chmod -R go-rwx "$CACHE"
  date -u -d '+30 min' +%Y-%m-%dT%H:%M:%S.000Z | tr -d '\n' > "$CACHE/next-check"
  run su - "$SFW_USER" -c "cd '$PROJ/app' && npm install --no-audit --no-fund ../pkg 2>&1"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"sfw has no firewall binary cached"* ]]
  cmd=$(printf '%s\n' "$output" | sed -n "s/.*run  \(sudo sh -c '[^']*'\)  once.*/\1/p" | head -n 1)
  echo "hint: $cmd"
  [[ "$cmd" == "sudo sh -c 'umask 022; sfw true && chmod -R go+rX $CACHE'" ]]
  # FIXTURE CONTROL: the old hint, `sfw true` as root, leaves the cache as it is.
  ( umask 077; sfw true ) >/dev/null 2>&1
  run su - "$SFW_USER" -c "cd '$PROJ/app' && npm install --no-audit --no-fund ../pkg 2>&1"
  [[ "$output" == *"sfw has no firewall binary cached"* ]]
  # The hint's command as root under umask 077 (the suite already runs as root,
  # so without its sudo): the warning is gone and nothing in the cache can be
  # written by another account.
  run bash -c "umask 077; ${cmd#sudo }"
  [ "$status" -eq 0 ]
  run su - "$SFW_USER" -c "cd '$PROJ/app' && npm install --no-audit --no-fund ../pkg 2>&1"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" != *"sfw has no firewall binary cached"* ]]
  run find "$CACHE" \( ! -uid 0 -o \( ! -type l -perm /022 \) \) -print
  [ -z "$output" ]
}

@test "sfw: no account but root can change the binary sfw runs" {
  # sfw runs .sfw-cache/latest without re-checking its digest, for root too
  # (`sudo npm install` goes through the wrapper). VM#1: on Debian's npm the
  # role chowned the cache to the deploying user, who repointed latest at a
  # script that `sudo npm view` then ran as uid 0.
  sfw_preconditions
  run find "$CACHE" \( ! -uid 0 -o \( ! -type l -perm /022 \) \) -print
  echo "$output"
  [ -z "$output" ]
  t=$(readlink -f "$CACHE/latest")
  [[ "$t" == "$CACHE"/* ]]
  [ "$(stat -c %u "$t")" = 0 ]
}

@test "sfw: the verifier reports an sfw cache another account can write" {
  # The apply resets such a cache (40-upgrade-convergence), but only when it
  # runs. Between applies the Socket Firewall row read OK over it: MEASURED on
  # a host with the cache at 0777 and a user-owned `latest`, "OK FUNCTIONAL
  # Socket Firewall". Each state is restored before anything is asserted.
  sfw_preconditions
  [ "$(id -u)" = 0 ] || skip "needs root to change the cache's owner"
  [ -x /usr/local/bin/supply-chain-verify ] || skip "verifier not deployed"
  id "$SFW_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$SFW_USER"
  mode=$(stat -c %a "$CACHE")

  chmod 0777 "$CACHE"
  run /usr/local/bin/supply-chain-verify --verbose
  chmod "$mode" "$CACHE"
  row=$(printf '%s\n' "$output" | sed 's/\x1b\[[0-9;]*m//g' | grep 'Socket Firewall')
  echo "$row"
  [[ "$row" == *GAP* ]]
  [[ "$row" == *"$CACHE is root 777"* ]]
  [[ "$row" == *"Re-apply the role"* ]]

  chown -h "$SFW_USER" "$CACHE/latest"
  run /usr/local/bin/supply-chain-verify --verbose
  chown -h root "$CACHE/latest"
  row=$(printf '%s\n' "$output" | sed 's/\x1b\[[0-9;]*m//g' | grep 'Socket Firewall')
  echo "$row"
  [[ "$row" == *GAP* ]]
  [[ "$row" == *"$CACHE/latest is $SFW_USER"* ]]
}
