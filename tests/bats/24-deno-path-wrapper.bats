#!/usr/bin/env bats
# Tests for the Deno PATH wrapper (deno_path_wrapper: true).
#
# Background: Deno has no global config file. The role's default mechanism is
# an alias at /etc/profile.d/deno-cooldown.sh, which only expands in interactive
# shells — leaving scripts, agents, and CI without age-gate coverage.
#
# The wrapper installs in-place at the discovered Deno binary location
# (typically ~/.deno/bin/deno) rather than /usr/local/bin/deno. That's
# because Deno's official curl-installer prepends ~/.deno/bin to PATH, so a
# /usr/local/bin wrapper would be silently bypassed. Installing in-place
# defeats PATH ordering by being upstream of it. The original deno binary
# is preserved as <path>-real in the same directory.

load setup

# Resolve the wrapper location once per test rather than hardcoding /usr/local/bin
get_deno_path() {
  command -v deno
}

@test "deno wrapper installed at the discovered deno location" {
  deno_path=$(get_deno_path)
  [ -n "$deno_path" ]
  # Wrapper contains our marker comment
  grep -q "supply-chain-hardening" "$deno_path"
}

@test "deno wrapper is executable" {
  deno_path=$(get_deno_path)
  [ -x "$deno_path" ]
}

@test "real deno binary preserved at <path>-real" {
  deno_path=$(get_deno_path)
  [ -f "${deno_path}-real" ]
  [ -x "${deno_path}-real" ]
}

@test "deno wrapper has recursion safety guard" {
  deno_path=$(get_deno_path)
  grep -q "refusing to recurse" "$deno_path"
}

@test "deno wrapper REAL_DENO points at <path>-real" {
  deno_path=$(get_deno_path)
  embedded=$(grep -E "^REAL_DENO=" "$deno_path" | head -1 | sed "s/REAL_DENO=//; s/'//g")
  [ -n "$embedded" ]
  [ "$embedded" = "${deno_path}-real" ]
  [ -x "$embedded" ]
}

@test "deno wrapper allowlist contains dep-fetching subcommands" {
  # Regression catcher: if someone narrows the allowlist, `run` or `cache`
  # would silently bypass the age-gate injection.
  deno_path=$(get_deno_path)
  grep -q "run" "$deno_path"
  grep -q "cache" "$deno_path"
  grep -q "install" "$deno_path"
  grep -q "test" "$deno_path"
  grep -q "compile" "$deno_path"
}

@test "deno alias mechanism is removed when wrapper is active" {
  # Mutually exclusive design — having both deployed would double-inject the
  # flag on interactive shells. The role removes the alias when wrapper is on.
  [ ! -f /etc/profile.d/deno-cooldown.sh ]
}

@test "deno wrapper injects --minimum-dependency-age for fetching subcommands" {
  # Behavioral check using a stub real-deno that echoes its args. Verifies
  # the wrapper actually adds the flag (not just that the wrapper text
  # contains the flag).
  deno_path=$(get_deno_path)
  embedded=$(grep -E "^REAL_DENO=" "$deno_path" | head -1 | sed "s/REAL_DENO=//; s/'//g")
  [ -n "$embedded" ] || skip "no embedded real-deno path"

  mv "$embedded" "${embedded}.bats-real"
  cat > "$embedded" <<'EOF'
#!/bin/sh
printf 'ARGS:'
for a in "$@"; do printf ' %s' "$a"; done
printf '\n'
EOF
  chmod +x "$embedded"

  run "$deno_path" run script.ts
  mv "${embedded}.bats-real" "$embedded"

  [ "$status" -eq 0 ]
  echo "$output" | grep -q -- "--minimum-dependency-age="
  echo "$output" | grep -q "run"
  echo "$output" | grep -q "script.ts"
}

@test "deno wrapper does NOT inject flag for non-fetching subcommands" {
  # Counterpart to the previous test: `deno fmt`, `--version`, etc. don't
  # accept --minimum-dependency-age and would error if injected. Verify the
  # bypass path is correct.
  deno_path=$(get_deno_path)
  embedded=$(grep -E "^REAL_DENO=" "$deno_path" | head -1 | sed "s/REAL_DENO=//; s/'//g")
  [ -n "$embedded" ] || skip "no embedded real-deno path"

  mv "$embedded" "${embedded}.bats-real"
  cat > "$embedded" <<'EOF'
#!/bin/sh
printf 'ARGS:'
for a in "$@"; do printf ' %s' "$a"; done
printf '\n'
EOF
  chmod +x "$embedded"

  run "$deno_path" fmt
  mv "${embedded}.bats-real" "$embedded"

  [ "$status" -eq 0 ]
  echo "$output" | grep -q "fmt"
  ! echo "$output" | grep -q -- "--minimum-dependency-age"
}

@test "deno rename task does not skip-on-stale-backup (M1 regression)" {
  # Background: an earlier revision of tasks/deno.yml gated the rename task on
  # `not deno_real_backup.stat.exists`. After a user reinstalled deno via the
  # official installer (which overwrites the wrapper), the next role re-run
  # would detect current binary as `is_real` and skip the rename — silently
  # preserving a stale backup. The wrapper would then be redeployed pointing
  # at the OLD deno, masking the user's upgrade (including any CVE patches).
  # This static check catches a regression that reintroduces the condition.
  taskfile="$ROLE_DIR/tasks/deno.yml"
  [ -f "$taskfile" ] || skip "role source not available at $taskfile"
  # Match only an active YAML list-item condition, not the explanatory comment
  # in the file that documents *why* this gate must not exist.
  ! grep -qE "^[[:space:]]+-[[:space:]]+not deno_real_backup\.stat\.exists" "$taskfile"
}

@test "deno wrapper recursion guard fires when real deno is missing" {
  deno_path=$(get_deno_path)
  embedded=$(grep -E "^REAL_DENO=" "$deno_path" | head -1 | sed "s/REAL_DENO=//; s/'//g")
  [ -n "$embedded" ] || skip "no embedded real-deno path"
  [ -x "$embedded" ] || skip "embedded deno path not executable"

  mv "$embedded" "${embedded}.bats-hidden"
  run timeout 5 "$deno_path" run script.ts
  mv "${embedded}.bats-hidden" "$embedded"

  [ "$status" -eq 127 ]
  echo "$output" | grep -q "refusing to recurse"
}
