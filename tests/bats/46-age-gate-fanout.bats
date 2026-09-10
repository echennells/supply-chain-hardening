#!/usr/bin/env bats
# ECH-180 — property test over the release_age_hours fan-out.
#
# One input, release_age_hours, fans out to a different unit for every
# ecosystem: npm days, pnpm/yarn minutes, bun seconds, deno ISO-8601 duration.
# Each is derived INDEPENDENTLY in defaults/main.yml, and the "unit/threshold"
# bug recurred four times — a derivation going degenerate (0, "P0D", NaN,
# wrong unit) silently DISABLES that ecosystem's age gate with no error. The
# per-instance fixes floored each one, but nothing checked the whole fan-out
# against a range of inputs. This test does: it renders the ACTUAL defaults
# expressions for many release_age_hours values and asserts none is degenerate.
#
# It renders via ansible (the real defaults/main.yml, one invocation per input)
# so it exercises the shipped Jinja, not a copy. Requires ansible-playbook; the
# whole file skips where that is unavailable. Mirrors the render approach in the
# tier-rendering tests (28/32/33).

load setup

FANOUT_FILE=/tmp/age-gate-fanout.txt
# span: below 24h (the historic degenerate zone), the 24h boundary, and above.
INPUTS="1 6 12 23 24 25 48 72 168"

setup_file() {
  : > "$FANOUT_FILE"
  command -v ansible-playbook >/dev/null 2>&1 || return 0
  local pb; pb=$(mktemp).yml
  cat > "$pb" <<'YML'
- hosts: localhost
  connection: local
  gather_facts: false
  tasks:
    # Load the shipped defaults lazily; release_age_hours comes from --extra-vars.
    # Only the unit-derived vars are referenced, so uv_exclude_newer (which needs
    # gather_facts + GNU date) is never evaluated.
    - ansible.builtin.include_vars: "{{ role_defaults }}"
    - ansible.builtin.debug:
        msg: "FANOUT {{ release_age_hours }} {{ npm_minimum_release_age_days }} {{ pnpm_minimum_release_age_minutes }} {{ bun_minimum_release_age_seconds }} {{ yarn_minimal_age_gate }} {{ deno_minimum_dependency_age }}"
YML
  local h line
  for h in $INPUTS; do
    # </dev/null so ansible cannot drain the loop's stdin; grep the marker line
    # out of the debug output → "h npm pnpm bun yarn deno" (space-separated).
    line=$(ansible-playbook -i 'localhost,' -c local "$pb" \
             -e "role_defaults=$ROLE_DIR/defaults/main.yml" \
             -e "release_age_hours=$h" </dev/null 2>/dev/null \
           | grep -oE 'FANOUT [0-9]+ [0-9]+ [0-9]+ [0-9]+ [0-9]+ P[0-9]+D')
    [ -n "$line" ] && echo "${line#FANOUT }" >> "$FANOUT_FILE"
  done
  rm -f "$pb"
}

setup() {
  [ -s "$FANOUT_FILE" ] || skip "no renders (ansible-playbook unavailable on this host)"
}

@test "fan-out: every input rendered (no silent partial coverage)" {
  local want got
  want=$(printf '%s\n' $INPUTS | grep -c .)
  got=$(grep -c . "$FANOUT_FILE")
  [ "$got" -eq "$want" ] || { echo "rendered $got/$want inputs — some render failed silently" >&2; cat "$FANOUT_FILE" >&2; return 1; }
}

@test "fan-out: npm min-release-age is an integer >= 1 for every release_age_hours" {
  local h npm pnpm bun yarn deno
  while read -r h npm pnpm bun yarn deno; do
    [ -n "$h" ] || continue
    if ! [[ "$npm" =~ ^[0-9]+$ ]] || [ "$npm" -lt 1 ]; then
      echo "DEGENERATE npm at release_age_hours=$h: '$npm' (gate would be disabled)" >&2; return 1
    fi
  done < "$FANOUT_FILE"
}

@test "fan-out: pnpm minimumReleaseAge (minutes) is an integer >= 1 for every input" {
  local h npm pnpm bun yarn deno
  while read -r h npm pnpm bun yarn deno; do
    [ -n "$h" ] || continue
    if ! [[ "$pnpm" =~ ^[0-9]+$ ]] || [ "$pnpm" -lt 1 ]; then
      echo "DEGENERATE pnpm at release_age_hours=$h: '$pnpm'" >&2; return 1
    fi
  done < "$FANOUT_FILE"
}

@test "fan-out: bun minimumReleaseAge (seconds) is an integer >= 1 for every input" {
  local h npm pnpm bun yarn deno
  while read -r h npm pnpm bun yarn deno; do
    [ -n "$h" ] || continue
    if ! [[ "$bun" =~ ^[0-9]+$ ]] || [ "$bun" -lt 1 ]; then
      echo "DEGENERATE bun at release_age_hours=$h: '$bun'" >&2; return 1
    fi
  done < "$FANOUT_FILE"
}

@test "fan-out: yarn npmMinimalAgeGate (minutes) is an integer >= 1 for every input" {
  local h npm pnpm bun yarn deno
  while read -r h npm pnpm bun yarn deno; do
    [ -n "$h" ] || continue
    if ! [[ "$yarn" =~ ^[0-9]+$ ]] || [ "$yarn" -lt 1 ]; then
      echo "DEGENERATE yarn at release_age_hours=$h: '$yarn'" >&2; return 1
    fi
  done < "$FANOUT_FILE"
}

@test "fan-out: deno minimum-dependency-age is P<n>D with n >= 1 for every input" {
  # The historic failure was "P0D" below 24h — syntactically valid ISO-8601 that
  # disables the gate. Reject P0D, empty, and any non-P<n>D form.
  local h npm pnpm bun yarn deno
  while read -r h npm pnpm bun yarn deno; do
    [ -n "$h" ] || continue
    if ! [[ "$deno" =~ ^P[1-9][0-9]*D$ ]]; then
      echo "DEGENERATE deno at release_age_hours=$h: '$deno' (want P<n>D, n>=1)" >&2; return 1
    fi
  done < "$FANOUT_FILE"
}
