#!/usr/bin/env bats
# /etc/environment is parsed by TWO consumers with DIFFERENT grammars:
#   - pam_env: tolerant. Accepts a bare `KEY=`, does $-expansion on values.
#   - systemd-environment-d-generator: strict. Rejects an empty-value `KEY=` as
#     "invalid syntax (around ...)" and logs it at every login. Active on hosts
#     where /usr/lib/environment.d/*.conf symlinks to /etc/environment
#     (Omarchy/Arch and others).
#
# For a long time the role's tests only ever checked pam_env's view — "did the
# variable end up set?" — and never that the file PARSES CLEANLY for both
# consumers. That blind spot is exactly how GOPRIVATE=/GONOPROXY=/GOINSECURE=
# (empty) shipped and warned on every login. The lesson: for a generated file
# with more than one parser, test it against EVERY parser's grammar, not just
# the tolerant one.
#
#   Tier 1 — a static lint of the INTERSECTION of both grammars. Always runs,
#            needs no systemd. Catches the whole class cheaply.
#   Tier 2 — runs the REAL systemd generator when it is present, with a positive
#            control so an environment that can't exercise it SKIPS rather than
#            passing silently (docs/design-principles.md Axis 4).

load setup

setup() {
  [ -f /etc/environment ] || skip "/etc/environment not present (role not applied on this host)"
  BLOCKFILE="$BATS_TEST_TMPDIR/block"
  awk '/# BEGIN SUPPLY CHAIN HARDENING/{f=1;next} /# END SUPPLY CHAIN HARDENING/{f=0} f' \
    /etc/environment > "$BLOCKFILE"
  [ -s "$BLOCKFILE" ] || skip "no SUPPLY CHAIN HARDENING block in /etc/environment"
}

# ---------------------------------------------------------------- Tier 1 -----

@test "grammar: no empty-value line (systemd environment.d rejects bare KEY=)" {
  # The reported bug. A bare `KEY=` is "invalid syntax" to the systemd generator.
  run grep -nE '^[A-Za-z_][A-Za-z0-9_]*=$' "$BLOCKFILE"
  [ "$status" -ne 0 ] || { echo "empty-value line(s):" >&2; echo "$output" >&2; false; }
}

@test "grammar: every managed line is a comment, blank, or well-formed KEY=VALUE" {
  # Anything else (a stray token, an indented key, a line without '=') is
  # rejected by systemd and mishandled by pam_env. grep -v prints the OFFENDERS;
  # a clean block yields none (grep exits non-zero).
  run grep -vnE '^([[:space:]]*#.*|[[:space:]]*$|[A-Za-z_][A-Za-z0-9_]*=.*)$' "$BLOCKFILE"
  [ "$status" -ne 0 ] || { echo "malformed line(s):" >&2; echo "$output" >&2; false; }
}

@test "grammar: no value contains an unescaped \$ (both parsers do variable expansion)" {
  # pam_env and environment.d BOTH expand ${VAR}/\$VAR. A literal '\$' in a value
  # would be silently rewritten — a quieter cousin of the empty-value bug.
  run grep -nE '^[A-Za-z_][A-Za-z0-9_]*=.*\$' "$BLOCKFILE"
  [ "$status" -ne 0 ] || { echo "value(s) with an unescaped \$:" >&2; echo "$output" >&2; false; }
}

@test "grammar: no value is wrapped in quotes (pam_env keeps them literally)" {
  # A quoted value ends up WITH the quotes in the exported string under pam_env.
  run grep -nE "^[A-Za-z_][A-Za-z0-9_]*=[\"']" "$BLOCKFILE"
  [ "$status" -ne 0 ] || { echo "quoted value(s):" >&2; echo "$output" >&2; false; }
}

@test "grammar: no duplicate keys in the managed block" {
  # Two fragments assigning the same KEY (e.g. a botched blockinfile merge)
  # is order-dependent and silently wrong. Keys must be unique.
  local dups
  dups=$(grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' "$BLOCKFILE" | sort | uniq -d)
  [ -z "$dups" ] || { echo "duplicate key(s):" >&2; echo "$dups" >&2; false; }
}

# ---------------------------------------------------------------- Tier 2 -----

@test "grammar (real parser): systemd-environment-d-generator accepts the managed block" {
  local gen=""
  local c
  for c in /usr/lib/systemd/systemd-environment-d-generator \
           /lib/systemd/systemd-environment-d-generator; do
    [ -x "$c" ] && { gen="$c"; break; }
  done
  [ -n "$gen" ] || skip "systemd-environment-d-generator not present (no systemd on this host)"

  local xdg="$BATS_TEST_TMPDIR/xdg"
  mkdir -p "$xdg/environment.d"
  # Our real block, isolated in a uniquely-named file so we can attribute any
  # warning to it specifically (the generator also reads the system dirs).
  cp "$BLOCKFILE" "$xdg/environment.d/99-sch-grammar-test.conf"
  # Positive control: a KNOWN-bad empty-value line in a separate file. If the
  # generator does NOT warn about THIS, either it isn't reading our dir or this
  # systemd version accepts bare KEY= (nothing to test) — SKIP, don't pass.
  printf 'SCH_BAD_CONTROL=\n' > "$xdg/environment.d/98-sch-badcontrol.conf"

  local err
  err="$(XDG_CONFIG_HOME="$xdg" "$gen" 2>&1 >/dev/null || true)"

  echo "$err" | grep "98-sch-badcontrol.conf" | grep -qi "invalid syntax" \
    || skip "generator did not flag the positive control here (cannot exercise the real parser)"

  # The assertion: no invalid-syntax warning references OUR block file.
  if echo "$err" | grep "99-sch-grammar-test.conf" | grep -qi "invalid syntax"; then
    echo "generator rejected a line in the managed block:" >&2
    echo "$err" | grep "99-sch-grammar-test.conf" >&2
    false
  fi
}
