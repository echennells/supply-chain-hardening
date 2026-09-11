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
