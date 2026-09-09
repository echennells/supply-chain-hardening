#!/usr/bin/env bats
# Tier 3 of the "test a generated config against its REAL consumer" lesson
# (origin: 44-etc-environment-grammar.bats). Each config file the role writes is
# fed to the tool that parses it; a malformed file makes that tool error. This
# asserts the file PARSES CLEANLY — a different question from the behavioral
# verifier, which asserts the setting takes EFFECT. The /etc/environment
# empty-var bug was precisely a clean-EFFECT / broken-PARSE split, invisible to
# effect-only tests.
#
# Coverage is limited to configs with a reliable, fast, offline-ish parse check.
# Intentionally NOT covered — stated so the gap is explicit, not silent
# (docs/design-principles.md Axis 4, "absent signal read as a passing signal"):
#   - /etc/yarnrc.yml : yarn berry's config reader needs a project context and
#                       its exit status is unreliable outside one.
#   - gradle init script : parsing it needs a full JVM + gradle run (slow, and
#                          usually reaches the network) — wrong shape for a lint.

load setup

@test "parse: pip reads /etc/pip.conf without error" {
  command -v python3 >/dev/null 2>&1 || skip "python3 not installed"
  python3 -m pip --version >/dev/null 2>&1 || skip "pip module not available"
  [ -f /etc/pip.conf ] || skip "/etc/pip.conf not deployed on this host"
  run python3 -m pip config list
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
}

@test "parse: uv reads /etc/uv/uv.toml without error" {
  command -v uv >/dev/null 2>&1 || skip "uv not installed"
  [ -f /etc/uv/uv.toml ] || skip "/etc/uv/uv.toml not deployed on this host"
  # Any uv invocation loads system config first; malformed TOML => non-zero exit.
  run uv cache dir
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
}

@test "parse: npm reads npmrc without a hard error" {
  command -v npm >/dev/null 2>&1 || skip "npm not installed"
  # npm only WARNS (exit 0) on unknown keys; a genuine parse failure surfaces as
  # an "Error:" line. Assert both: clean exit and no Error line.
  run npm config ls
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
  [[ "$output" != *"Error:"* ]] || { echo "$output" >&2; false; }
}

@test "parse: composer reads its global config without error" {
  command -v composer >/dev/null 2>&1 || skip "composer not installed"
  run composer config --global --list
  [ "$status" -eq 0 ] || { echo "$output" >&2; false; }
}
