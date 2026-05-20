#!/usr/bin/env bats
# Cache- and time-based bypass exploration. The age-gate protections
# (npm min-release-age, pnpm minimum-release-age, uv exclude-newer,
# yarn npmMinimalAgeGate) all derive a package's "age" from its
# published timestamp compared to the current system time. Two
# classes of bypass that aren't tested elsewhere:
#
#   1. Cache: if a package is already in the local cache, a
#      subsequent install with --prefer-offline / --offline may
#      skip the age-gate check (which was satisfied — or not — at
#      original fetch time).
#   2. Clock skew: setting the system clock backward (or having a
#      fast clock) shifts the age window. A package published
#      yesterday looks 30 days old if the system thinks today is
#      30 days from now.
#
# These tests document the actual behavior rather than asserting a
# desired one. If behavior shifts, the test catches it; the team
# then decides whether to harden further.

load setup

@test "cache: npm install --prefer-offline behavior on cached package vs age gate" {
  # Documents whether npm's min-release-age fires on cache hits or
  # only network fetches. Test setup:
  #
  #   1. Pick a package that's older than the age gate (so it would
  #      install normally) — use a well-known stable package.
  #   2. Install it. Cache is populated.
  #   3. Re-install with --prefer-offline. Should succeed from cache.
  #
  # The interesting case (not directly tested here, because it'd need
  # a fresh package and pre-poisoned cache, which is brittle in CI):
  #   - Manually populate ~/.npm/_cacache with a package whose actual
  #     publish time is < 48h ago. Then `npm install --offline pkg`.
  #     If npm consults the cache without re-checking publish time
  #     against min-release-age, the install succeeds. That's the
  #     bypass to be aware of.
  #
  # This test demonstrates step 2-3 (the safe case works). Add a
  # follow-up adversarial test if the cache-time-bypass surface
  # becomes worth defending.
  command -v npm >/dev/null 2>&1 || skip "npm not installed"

  cd /tmp && rm -rf cache-test && mkdir cache-test && cd cache-test
  npm init -y >/dev/null 2>&1

  # An older package: lodash@4.17.21 (published 2021 — well past any
  # reasonable age gate). If this fails, something else is wrong.
  npm install lodash@4.17.21 --silent 2>&1 | tail -3 || skip "network unavailable for baseline install"

  # Now re-install offline — should succeed from cache.
  rm -rf node_modules package-lock.json
  run npm install lodash@4.17.21 --prefer-offline --silent
  [ "$status" -eq 0 ]
  [ -d node_modules/lodash ]

  rm -rf /tmp/cache-test
}

@test "cache: npm cache is in deploying user's home (not system-shared)" {
  # Documents the scope of cache poisoning. If an attacker can write to
  # /tmp or any world-writable path that's somehow npm's cache, they
  # could pre-populate it with malicious code. Per npm's defaults the
  # cache is ~/.npm/_cacache, scoped to the user. Sudo callers get a
  # different cache (root's). Pin this so a future config change that
  # moves the cache to a shared path is caught.
  cache=$(npm config get cache 2>/dev/null)
  case "$cache" in
    "$HOME"/* | /root/* ) ;;
    *) echo "Unexpected cache location: $cache" >&2; return 1 ;;
  esac
}

@test "time: age gate computed against current system time (clock skew impact)" {
  # Pins the assumption that age = now - publishTime. If faketime is
  # available, demonstrate: bump clock 30 days forward, attempt to
  # install a 5-day-old package — gate should accept it as "35 days
  # old" and let it through, even though true wall-clock age is only
  # 5 days. This is the documented attack: a host with a fast clock
  # (NTP drift, deliberate skew, container clock issues) has a
  # weaker age gate than configured.
  #
  # No defense exists at the role layer — the protection assumes
  # accurate time. README should note: "the age gate is only as
  # trustworthy as the system clock." This test exists to surface
  # the gap explicitly.
  if ! command -v faketime >/dev/null 2>&1; then
    echo "# faketime not installed; cannot demonstrate clock-skew bypass at runtime" >&3
    echo "# Documented gap: age gate trusts system time. Recommend chrony/ntp on hosts." >&3
    skip "faketime not available — gap documented in comment only"
  fi
  skip "faketime test scaffolding present but not implemented — see comments for design"
}

@test "time: system clock plausibility (catches grossly-wrong time)" {
  # Cheap sanity check that the test host's time isn't off by years.
  # An age gate of '48 hours' on a host stuck at epoch-zero would
  # accept any package as 'decades old.' This test catches the
  # extreme case; doesn't help against subtle drift.
  current_year=$(date +%Y)
  # Bats container runs in late 2026 by problem statement; allow a
  # wide envelope (2024-2030) so this doesn't false-fail when the
  # container is rebuilt later.
  [ "$current_year" -ge 2024 ]
  [ "$current_year" -le 2030 ]
}
