#!/usr/bin/env bats
# ECH-185 — the role must harden its OWN tool installs, not just the user's.
#
# The role installs its enforcement/audit tooling by calling the real package
# manager directly (stepping around its own /usr/local/bin wrappers, correctly —
# it can't route sfw/cargo-cooldown's install through the very gate they provide).
# But stepping around the wrapper must not mean stepping around the protection:
# the wrapper's job for npm is to block lifecycle scripts, so the role's own
# `npm install -g` calls must pass --ignore-scripts explicitly.
#
# --ignore-scripts is a universal npm CLI flag (all versions): load-bearing on
# npm <12, redundant-but-harmless on >=12 (native allowScripts). So the guard is
# unconditional — no version tiering needed.
#
# This is a STATIC guard over the role source (task files), not a runtime probe:
# "was --ignore-scripts used" is not observable on the applied host after the
# fact, so we assert it where it lives.

load setup

@test "own tools: every 'npm install -g' command in tasks/ passes --ignore-scripts" {
  local offenders
  offenders=$(grep -rnE 'command:.*npm install -g' "$ROLE_DIR"/tasks/*.yml 2>/dev/null \
                | grep -v -- '--ignore-scripts' || true)
  [ -z "$offenders" ] || {
    echo "npm install -g without --ignore-scripts (the role would run its own tool's" >&2
    echo "postinstall unblocked — the exact vector it blocks for users):" >&2
    echo "$offenders" >&2
    false
  }
}

# The installs run as root, whose PATH is sudo's secure_path. On a host whose only
# Node is per-user (fnm, nvm, volta, asdf) root cannot run the npm the role detected,
# so each install must wait on a become-time probe and the play records that reason,
# not a bare "install failed". Running the user's npm as root instead would let root
# execute files the user can edit. MEASURED on an fnm host before the gate: both
# installs "changed" and failed, and sfw's warm step blamed GitHub (exit 127).
@test "own tools: every 'npm install -g' task waits on a become-time check that root can run npm" {
  local f out offenders=""
  while IFS= read -r f; do
    out=$(awk '
      function check(  v, b) {
        if (blk !~ /command:[^\n]*npm install -g/) return
        if (match(blk, /npm_root_for_[a-z_]+\.rc \| default\(1\) == 0/) == 0) { print name " (no root check)"; return }
        v = substr(blk, RSTART, RLENGTH); sub(/\.rc.*/, "", v)
        b = probes[v]
        if (b == "" || b !~ /become: true/ || b !~ /command -v npm/) print name " (" v " is not a become-time command -v npm probe)"
      }
      /^- name:/ { if (reg != "") probes[reg] = blk; check(); blk = ""; reg = ""; name = $0 }
      { blk = blk $0 "\n" }
      /^  register: npm_root_for_/ { reg = $2 }
      END { if (reg != "") probes[reg] = blk; check() }
    ' "$f")
    [ -z "$out" ] || offenders="$offenders${f##*/}: $out"$'\n'
  done < <(grep -lE 'command:.*npm install -g' "$ROLE_DIR"/tasks/*.yml)
  [ -z "$offenders" ] || { echo "$offenders" >&2; false; }
}
