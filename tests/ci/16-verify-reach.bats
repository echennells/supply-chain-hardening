#!/usr/bin/env bats
# What THIS shell gets: the verifier's rows about the shell it runs in (the
# "shell reachability" block in action/verify.sh and templates/verify.sh.j2).
#
# MEASURED on two agent VMs (2026-11-26): one runner started every command as
# `/bin/bash --norc --noprofile -c "umask 0007; ..."`, as root with
# HOME=/home/hatch (passwd home /root), a PATH with no home directory on it and
# npm 10.9.4 in a read-only image directory; the other replayed a shell state
# saved once per session from `bash -ilc` with no terminal. These tests run the
# verifier in shells of those shapes, each with a control that differs in the
# one thing the row is about.
#
# The agent-shell helpers live here, not in helpers.bash, which other suites
# share.

load helpers

bats_require_minimum_version 1.5.0

setup() {
  common_setup
  bare_path
}

# Tests make directories unwritable; give them back so bats can remove them.
teardown() { chmod -R u+w "$BATS_TEST_TMPDIR" 2>/dev/null || true; }

ROOT="${BATS_TEST_DIRNAME}/../.."
ROLE_TPL="${ROOT}/templates/verify.sh.j2"
PROBES="${ROOT}/files/verify-probes.sh"

# agent_sh [VAR=value ...] <PATH> <command> [$0 [$1 ...]]: the first VM's
# runner. No startup file, umask 0007, the test's HOME, only <PATH>, and
# nothing else from this environment.
agent_sh() {
  local -a pre=()
  while [ $# -gt 0 ]; do
    case "$1" in [A-Za-z_]*=*) pre+=("$1"); shift ;; *) break ;; esac
  done
  local p="$1" c="$2"; shift 2
  env -i HOME="$TEST_HOME" PATH="$p" TMPDIR="$TEST_TMP" ${pre[@]+"${pre[@]}"} \
    /bin/bash --norc --noprofile -c "umask 0007; $c" "$@"
}

# reach_verify [VAR=value ...] <PATH> [verify.sh args]: verify.sh in that shell.
reach_verify() {
  local -a pre=()
  while [ $# -gt 0 ]; do
    case "$1" in [A-Za-z_]*=*) pre+=("$1"); shift ;; *) break ;; esac
  done
  local p="$1"; shift
  agent_sh ${pre[@]+"${pre[@]}"} "$p" 'exec bash "$0" --emit=plain "$@"' "$VERIFY_SH" "$@"
}

# The table row(s) for one protection, matched as a whole column.
row_of() { # <protection>
  awk -v p="$1" 'substr($0, 20, length(p)) == p && (length($0) == 19 + length(p) || substr($0, 20 + length(p), 1) == " ")' <<<"$output"
}

# forge [key=value ...]: a complete run record of ours (0644, so it is believed).
forge() {
  mkdir -p "$STATE_DIR"
  printf '%s\n' "$@" hardening_complete=true > "$OUT_FILE"
  chmod 0644 "$OUT_FILE"
}

block() { sed -n '/^# >>> shell reachability$/,/^# <<< shell reachability$/p' "$1"; }

# ---------------------------------------------------------------- the block --

@test "reach: the block is byte-identical on both surfaces, and both save PATH and HOME before anything moves them" {
  [ -n "$(block "$VERIFY_SH")" ]
  diff <(block "$ROLE_TPL") <(block "$VERIFY_SH")
  # The role's copy is a Jinja template.
  ! block "$ROLE_TPL" | grep -nE '\{\{|\{%|\{#' || false
  local f s p h
  for f in "$ROLE_TPL" "$VERIFY_SH"; do
    s=$(grep -n '^set -u$' "$f" | head -1 | cut -d: -f1)
    p=$(grep -nxF 'SCV_CALLER_PATH=${PATH-}' "$f" | cut -d: -f1)
    h=$(grep -nxF 'SCV_CALLER_HOME=${HOME-}' "$f" | cut -d: -f1)
    [ -n "$s" ] && [ -n "$p" ] && [ "$h" = $((p + 1)) ]
    # Nothing between `set -u` and the save but comments and blank lines.
    [ -z "$(sed -n "$((s + 1)),$((p - 1))p" "$f" | grep -vE '^(#.*)?$')" ]
    # The block comes before the first row that uses it, and before go
    # discovery, the first thing that changes PATH.
    [ "$(grep -n '^# <<< shell reachability$' "$f" | cut -d: -f1)" -lt "$(grep -n '^# >>> go discovery$' "$f" | cut -d: -f1)" ]
  done
  [ "$(grep -n '^# <<< shell reachability$' "$VERIFY_SH" | cut -d: -f1)" -lt "$(grep -nF 'scv_env_presence "$ENV_FILE"' "$VERIFY_SH" | cut -d: -f1)" ]
  [ "$(grep -n '^# <<< shell reachability$' "$ROLE_TPL" | cut -d: -f1)" -lt "$(grep -n '^scv_profile_env_row ' "$ROLE_TPL" | cut -d: -f1)" ]
}

# The shared body under a preamble with only what it requires (row, have,
# run_bounded, requested), and optionally the block: rows as ROW|..., and stderr.
body_alone() { # <PATH> <extra preamble text>
  env -i PATH="$1" HOME="$TEST_HOME" TMPDIR="$TEST_TMP" /bin/bash --norc --noprofile -c "
row() { printf 'ROW|%s|%s|%s|%s\\n' \"\$@\"; }
have() { command -v \"\$1\" >/dev/null 2>&1; }
run_bounded() { shift; \"\$@\"; }
requested() { return 0; }
$2
. \"$PROBES\"" 2>&1
}

@test "reach: the shared body still runs under a preamble without the block, and uses it where there is one" {
  # files/verify-probes.sh calls the block's helpers behind a `type` test, so
  # a preamble without them loses those rows and clauses, not the run.
  [ "$(id -u)" != 0 ] || skip "a 0555 directory does not stop root"
  local ro="$BATS_TEST_TMPDIR/image/bin"
  old_tools "$ro"
  chmod a-w "$ro"
  uv_stub "$TEST_HOME/.local/bin" 0.13.9 48h
  run body_alone "$ro:$BARE_PATH" ""
  [[ "$output" == *"ROW|GAP|PARSED|yarn age gate|"* ]]
  [[ "$output" == *"ROW|OK|PARSED|uv age gate|"* ]]
  [[ "$output" != *"command not found"* ]]
  [[ "$output" != *"on this shell's PATH|"* ]]
  [[ "$output" != *" is at $ro/"* ]]
  # With the block, and the caller's PATH saved as both preambles do.
  run body_alone "$ro:$BARE_PATH" "SCV_CALLER_PATH=\$PATH; SCV_CALLER_HOME=\$HOME
$(block "$VERIFY_SH")"
  [[ "$output" != *"command not found"* ]]
  [[ "$output" == *"ROW|WEAK|PARSED|uv on this shell's PATH|the uv rows grade $TEST_HOME/.local/bin/uv,"* ]]
  [[ "$output" == *"ROW|GAP|PARSED|yarn age gate|"*". yarn is at $ro/yarn, in a directory its owner cannot write"* ]]
}

@test "reach: the role checks the profile.d file the role deploys, and its apply run says it is one" {
  local dest
  dest=$(sed -n 's/^[[:space:]]*dest: \(\/etc\/profile\.d\/supply-chain-hardening\.sh\)$/\1/p' "$ROOT/tasks/shell_env.yml")
  [ "$dest" = /etc/profile.d/supply-chain-hardening.sh ]
  grep -qx "scv_profile_env_row $dest" "$ROLE_TPL"
  grep -qx 'scv_jvm_home_row' "$ROLE_TPL"
  grep -qx 'scv_jvm_home_row' "$VERIFY_SH"
  # The apply's own run passes --apply-run, and no longer sets the variable.
  grep -qx '  ansible.builtin.command: /usr/local/bin/supply-chain-verify --apply-run' "$ROOT/tasks/verify.yml"
  ! grep -n 'SCV_APPLY_RUN' "$ROOT/tasks/verify.yml" || false
}

@test "reach: only the role's --apply-run sets SCV_APPLY_RUN; one exported by the caller does nothing" {
  # The role's reset line and argument loop, run as they are in the template
  # (the rest of the preamble is Jinja).
  local code
  [ "$(grep -cx 'SCV_APPLY_RUN=0' "$ROLE_TPL")" = 1 ]
  [ "$(grep -n '^SCV_APPLY_RUN=0$' "$ROLE_TPL" | cut -d: -f1)" -lt "$(grep -n '^for arg in "\$@"; do$' "$ROLE_TPL" | cut -d: -f1)" ]
  code="$(grep -x 'SCV_APPLY_RUN=0' "$ROLE_TPL")
$(sed -n '/^for arg in "\$@"; do$/,/^done$/p' "$ROLE_TPL")
echo \"apply=\$SCV_APPLY_RUN\""
  run env SCV_APPLY_RUN=1 /bin/bash --norc --noprofile -c "usage() { :; }; $code" _ --verbose
  [ "$output" = "apply=0" ]
  # Control: the flag.
  run env -u SCV_APPLY_RUN /bin/bash --norc --noprofile -c "usage() { :; }; $code" _ --verbose --apply-run
  [ "$output" = "apply=1" ]
  # The ci surface clears it too, before the block reads it.
  [ "$(grep -n '^SCV_APPLY_RUN=0$' "$VERIFY_SH" | cut -d: -f1)" -lt "$(grep -n '^# >>> shell reachability$' "$VERIFY_SH" | cut -d: -f1)" ]
}

# ------------------------------------------------------------ env layer (ci) --

@test "env layer (ci): a --norc --noprofile shell has none of the env file; the same shell after sourcing it has all" {
  mkdir -p "$STATE_DIR"
  printf 'export NPM_CONFIG_IGNORE_SCRIPTS=true\nexport GONOSUMDB=\nexport PIP_DISABLE_PIP_VERSION_CHECK=1\n' > "$ENV_FILE"
  chmod 0644 "$ENV_FILE"
  forge ecosystems_hardened=npm release_age_hours=48
  # Ground truth: the agent shell has none of them, the sourcing one all three.
  run agent_sh "$BARE_PATH" 'env | grep -cE "^(NPM_CONFIG_IGNORE_SCRIPTS|GONOSUMDB|PIP_DISABLE_PIP_VERSION_CHECK)="'
  [ "$output" = 0 ]
  run agent_sh "$BARE_PATH" '. "$0"; env | grep -cE "^(NPM_CONFIG_IGNORE_SCRIPTS|GONOSUMDB|PIP_DISABLE_PIP_VERSION_CHECK)="' "$ENV_FILE"
  [ "$output" = 3 ]
  run reach_verify "$BARE_PATH"
  row_of "env layer propagation"
  [[ "$(row_of "env layer propagation")" == "GAP    FUNCTIONAL  env layer propagation"*"NONE of 3 variables"* ]]
  [ "$status" -eq 1 ]
  run agent_sh "$BARE_PATH" '. "$1"; exec bash "$0" --emit=plain' "$VERIFY_SH" "$ENV_FILE"
  [[ "$(row_of "env layer propagation")" == "OK     FUNCTIONAL  env layer propagation"*"all 3 variables present"* ]]
}

@test "env layer (ci): env_layer=none in a complete record is N/A BYDESIGN; without the key it reads as before" {
  forge ecosystems_hardened=npm release_age_hours=48 home_only=true env_layer=none
  run reach_verify "$BARE_PATH"
  echo "$output" | grep 'env layer\|hardening run record' || true
  [[ "$(row_of "env layer propagation")" == "N/A    BYDESIGN    env layer propagation"*"wrote config files under HOME only (harden.sh --home-only)"* ]]
  # Nothing promised it, so no "<token> coverage" row stands in for it either.
  [ -z "$(row_of "env.propagation coverage")" ]
  # A stale env file from an earlier run does not bring the comparison back.
  mkdir -p "$STATE_DIR"; printf 'export NPM_CONFIG_IGNORE_SCRIPTS=true\n' > "$ENV_FILE"; chmod 0644 "$ENV_FILE"
  run reach_verify "$BARE_PATH"
  [[ "$(row_of "env layer propagation")" == "N/A    BYDESIGN    env layer propagation"* ]]
  rm -f "$ENV_FILE"

  # Control: an older record, without the keys, as before.
  forge ecosystems_hardened=npm release_age_hours=48
  run reach_verify "$BARE_PATH"
  [[ "$(row_of "env layer propagation")" == "WEAK   PRESENT     env layer propagation"*"no env file"* ]]

  # Only a record that is trusted and complete counts.
  printf 'ecosystems_hardened=npm\nhome_only=true\nenv_layer=none\n' > "$OUT_FILE"; chmod 0644 "$OUT_FILE"
  run reach_verify "$BARE_PATH"
  [[ "$(row_of "hardening run record")" == "GAP"*"never recorded completion"* ]]
  [[ "$(row_of "env layer propagation")" == "WEAK   PRESENT     env layer propagation"* ]]
  forge ecosystems_hardened=npm home_only=true env_layer=none
  chmod 0666 "$OUT_FILE"
  run reach_verify "$BARE_PATH"
  [[ "$(row_of "hardening run record")" == "GAP"*"writable by group or others"* ]]
  [[ "$(row_of "env layer propagation")" == "WEAK   PRESENT     env layer propagation"* ]]
}

@test "env layer (ci): a replayed shell state carries the env layer only if the state was saved with it" {
  # The second VM's runner: state saved once from `bash -ilc` with no terminal,
  # replayed into `bash -O extglob -c` under expand_aliases before each command.
  # Snapshot from an rc file of the test's, not the host's profile files.
  mkdir -p "$STATE_DIR"
  printf 'export NPM_CONFIG_IGNORE_SCRIPTS=true\nexport UV_LINK_MODE=copy\n' > "$ENV_FILE"; chmod 0644 "$ENV_FILE"
  forge ecosystems_hardened=npm release_age_hours=48
  snapshot() { # <rc file> -> state file
    env -i HOME="$TEST_HOME" PATH="$BARE_PATH" /bin/bash --noprofile --rcfile "$1" -ic 'declare -px; alias -p' </dev/null 2>/dev/null \
      | grep -vE '^declare -[a-zA-Z]*r[a-zA-Z]* ' > "$BATS_TEST_TMPDIR/state"
  }
  replay() {
    env -i HOME="$TEST_HOME" PATH="$BARE_PATH" TMPDIR="$TEST_TMP" /bin/bash -O extglob -c \
      'shopt -s expand_aliases; . "$1" 2>/dev/null
       exec bash "$0" --emit=plain' "$VERIFY_SH" "$BATS_TEST_TMPDIR/state"
  }
  printf '. %q\n' "$ENV_FILE" > "$BATS_TEST_TMPDIR/rc-with"
  printf 'alias ll=ls\n' > "$BATS_TEST_TMPDIR/rc-without"
  snapshot "$BATS_TEST_TMPDIR/rc-with"
  grep -q '^declare -x NPM_CONFIG_IGNORE_SCRIPTS="true"$' "$BATS_TEST_TMPDIR/state"
  run replay
  [[ "$(row_of "env layer propagation")" == "OK     FUNCTIONAL  env layer propagation"*"all 2 variables present"* ]]
  # Control: a state saved without it.
  snapshot "$BATS_TEST_TMPDIR/rc-without"
  grep -q '^alias ll=' "$BATS_TEST_TMPDIR/state"
  ! grep -q 'NPM_CONFIG_IGNORE_SCRIPTS' "$BATS_TEST_TMPDIR/state" || false
  run replay
  [[ "$(row_of "env layer propagation")" == "GAP    FUNCTIONAL  env layer propagation"*"NONE of 2"* ]]
}

# ---------------------------------------------------------- env layer (role) --

# The role's row on its own: the block from the template, a row() that prints,
# and the profile file named. In a fresh shell, so only what is passed is set.
role_env() { # [VAR=value ...] -- <profile file>
  local -a pre=()
  while [ "$1" != -- ]; do pre+=("$1"); shift; done
  shift
  env -i PATH="$BARE_PATH" HOME="$TEST_HOME" ${pre[@]+"${pre[@]}"} /bin/bash --norc --noprofile -c \
    "$(block "$ROLE_TPL")"$'\n''row() { printf "%s|%s|%s|%s\n" "$@"; }; scv_profile_env_row "$1"' _ "$1"
}

@test "env layer (role): all set is OK, none is a GAP naming the likely cause, some is WEAK" {
  local f="$BATS_TEST_TMPDIR/profile.sh"
  printf '# managed\nexport NPM_CONFIG_IGNORE_SCRIPTS=true\nexport GONOSUMDB=\nexport UV_LINK_MODE=copy\n' > "$f"
  run role_env -- "$f"
  echo "$output"
  [[ "$output" == "GAP|FUNCTIONAL|env layer propagation|NONE of the 3 variables $f exports are set in this shell. Most likely it loaded no startup file"* ]]
  # Control: the same shell after sourcing the file has every one.
  run env -i PATH="$BARE_PATH" HOME="$TEST_HOME" /bin/bash --norc --noprofile -c \
    ". \"\$1\"; $(block "$ROLE_TPL")"$'\n''row() { printf "%s|%s|%s|%s\n" "$@"; }; scv_profile_env_row "$1"' _ "$f"
  [ "$output" = "OK|FUNCTIONAL|env layer propagation|all 3 variables $f exports are set in this shell" ]
  # Empty counts as set: GONOSUMDB is empty on purpose.
  run role_env NPM_CONFIG_IGNORE_SCRIPTS=true GONOSUMDB= UV_LINK_MODE=copy -- "$f"
  [[ "$output" == "OK|FUNCTIONAL|"* ]]
  run role_env NPM_CONFIG_IGNORE_SCRIPTS=true -- "$f"
  [[ "$output" == "WEAK|FUNCTIONAL|env layer propagation|1/3 variables $f exports are set in this shell; missing: GONOSUMDB UV_LINK_MODE."* ]]
}

@test "env layer (role): the apply's own run is N/A, and a missing file is a GAP" {
  local f="$BATS_TEST_TMPDIR/profile.sh"
  printf 'export UV_LINK_MODE=copy\n' > "$f"
  run role_env SCV_APPLY_RUN=1 -- "$f"
  [[ "$output" == "N/A|BYDESIGN|env layer propagation|this is the apply's own run"* ]]
  # Control: the same shell without the marker.
  run role_env -- "$f"
  [[ "$output" == "GAP|FUNCTIONAL|"* ]]
  run role_env -- "$BATS_TEST_TMPDIR/nonexistent.sh"
  [ "$output" = "GAP|PRESENT|env layer propagation|$BATS_TEST_TMPDIR/nonexistent.sh is not there, so no shell gets the env layer. Re-apply the role" ]
}

# --------------------------------------------------- tools PATH does not reach --

# A uv that reports a span or an instant, in the Debug shape of
# `uv pip list --show-settings` (see uv_reporting in 07-verify.bats).
uv_stub() { # <dir> <version> [span]
  mkdir -p "$1"
  {
    printf '#!/bin/bash\ncase "$*" in\n'
    printf '  --version*|-V*) echo "uv %s" ;;\n' "$2"
    if [ -n "${3:-}" ]; then
      printf '  "pip list --show-settings") printf "%%s\\n" "PipSettings {" "    no_build: All," "    exclude_newer: ExcludeNewer {" "        global: Some(" "            Relative(" "                ExcludeNewerSpan(" "                    %s," "                )," "            )," "        )," "    }," "}" ;;\n' "$3"
    fi
    printf '  *) echo /tmp ;;\nesac\n'
  } > "$1/uv"
  chmod +x "$1/uv"
}

@test "reach: a uv found only in ~/.local/bin, off this shell's PATH, is WEAK; on PATH there is no such row" {
  uv_stub "$TEST_HOME/.local/bin" 0.13.9 48h
  forge ecosystems_hardened=uv release_age_hours=48
  # Ground truth: a bare `uv` in that shell finds nothing.
  run agent_sh "$BARE_PATH" 'command -v uv'
  [ "$status" -ne 0 ]
  run reach_verify "$BARE_PATH"
  [[ "$(row_of "uv on this shell's PATH")" == "WEAK   PARSED      uv on this shell's PATH"*"the uv rows grade $TEST_HOME/.local/bin/uv, but that directory is not on this shell's PATH, so a bare \`uv\` here finds nothing"* ]]
  [ -n "$(row_of "uv age gate")" ]
  # Control: the same uv with its directory on PATH.
  run agent_sh "$TEST_HOME/.local/bin:$BARE_PATH" 'command -v uv'
  [ "$output" = "$TEST_HOME/.local/bin/uv" ]
  run reach_verify "$TEST_HOME/.local/bin:$BARE_PATH"
  [ -n "$(row_of "uv age gate")" ]
  [ -z "$(row_of "uv on this shell's PATH")" ]
  # The role's apply run leaves these rows out (--apply-run, the test above);
  # the variable exported by a caller does not.
  run reach_verify SCV_APPLY_RUN=1 "$BARE_PATH"
  [ -n "$(row_of "uv age gate")" ]
  [[ "$(row_of "uv on this shell's PATH")" == "WEAK"* ]]
}

@test "reach: the row does not stand in for the tool's own rows in the coverage check" {
  # A shared body that stops right after the reach rows: the record promised
  # uv, and only "uv on this shell's PATH" names it. That is no uv probe.
  uv_stub "$TEST_HOME/.local/bin" 0.13.9 48h
  forge ecosystems_hardened=uv release_age_hours=48
  local cut="$BATS_TEST_TMPDIR/probes-cut.sh"
  awk '{ print } /^# yarn$/ { exit }' "$PROBES" > "$cut"
  grep -q 'scv_reach_row "${scv__rt%%:\*}"' "$cut"
  ! grep -q '^if have uv; then' "$cut" || false
  run reach_verify SCV_PROBES="$cut" "$BARE_PATH"
  [ -n "$(row_of "uv on this shell's PATH")" ]
  [[ "$(row_of "uv coverage")" == "GAP    PRESENT     uv coverage"*"emitted no row for it"* ]]
  # Control: the whole body has uv rows, so nothing is missing.
  run reach_verify "$BARE_PATH"
  [ -n "$(row_of "uv age gate")" ]
  [ -z "$(row_of "uv coverage")" ]
}

@test "reach: a copy in a directory the verifier adds comes first: the row names both" {
  # uv only in ~/.local/bin, so the verifier puts ~/.local/bin first on its
  # PATH, where another poetry sits than the one this shell runs.
  local sys="$BATS_TEST_TMPDIR/sysbin"
  mkdir -p "$sys" "$TEST_HOME/.local/bin"
  uv_stub "$TEST_HOME/.local/bin" 0.13.9 48h
  for d in "$sys" "$TEST_HOME/.local/bin"; do
    printf '#!/bin/bash\n[ "$2" = --version ] && echo "Poetry (version 2.5.1)"\nexit 0\n' > "$d/poetry"; chmod +x "$d/poetry"
  done
  run agent_sh "$BARE_PATH:$sys" 'command -v poetry'
  [ "$output" = "$sys/poetry" ]
  run reach_verify "$BARE_PATH:$sys"
  [[ "$(row_of "poetry on this shell's PATH")" == "WEAK   PARSED      poetry on this shell's PATH"*"the poetry rows grade $TEST_HOME/.local/bin/poetry, from a directory the verifier added to PATH, but a bare \`poetry\` here runs $sys/poetry"* ]]
  # A symlink to the copy this shell runs is the same file: no row.
  rm -f "$TEST_HOME/.local/bin/poetry"
  ln -s "$sys/poetry" "$TEST_HOME/.local/bin/poetry"
  [ "$TEST_HOME/.local/bin/poetry" -ef "$sys/poetry" ]
  run reach_verify "$BARE_PATH:$sys"
  [ -n "$(row_of "poetry publish-age gate")" ]
  [ -z "$(row_of "poetry on this shell's PATH")" ]
  # Control: no uv to look for in ~/.local/bin, so nothing is added and
  # poetry resolves as in this shell.
  rm -f "$TEST_HOME/.local/bin/uv"
  run reach_verify "$BARE_PATH:$sys"
  [ -n "$(row_of "poetry publish-age gate")" ]
  [ -z "$(row_of "poetry on this shell's PATH")" ]
}

@test "reach: a go the preamble finds in ~/go/bin is WEAK too, and not for an ecosystem the record left out" {
  [ ! -x /usr/local/go/bin/go ] || skip "go is at /usr/local/go/bin here, which the verifier looks in first"
  mkdir -p "$TEST_HOME/go/bin"
  printf '#!/bin/sh\ncase "$1" in version) echo "go version go1.24.2 linux/amd64" ;; esac\nexit 0\n' > "$TEST_HOME/go/bin/go"
  chmod +x "$TEST_HOME/go/bin/go"
  run reach_verify "$BARE_PATH"
  [[ "$(row_of "go on this shell's PATH")" == "WEAK   PARSED      go on this shell's PATH"*"$TEST_HOME/go/bin/go"* ]]
  forge ecosystems_hardened=npm release_age_hours=48
  run reach_verify "$BARE_PATH"
  [[ "$(row_of "go")" == "N/A    BYDESIGN    go"* ]]
  [ -z "$(row_of "go on this shell's PATH")" ]
}

# ----------------------------------------------------------------- JVM home --

# getent_home <home>: a getent whose passwd entry for this uid names <home>.
getent_home() {
  stub_bin getent "[ \"\$1\" = passwd ] && [ \"\$2\" = \"$(id -u)\" ] || exit 2
echo \"me:x:$(id -u):$(id -g)::$1:/bin/bash\""
}

@test "JVM home: gradle with GRADLE_USER_HOME unset and HOME not the passwd home is WEAK, naming both homes" {
  local pw="$BATS_TEST_TMPDIR/pwhome"
  mkdir -p "$pw"
  getent_home "$pw"
  stub_bin gradle 'exit 0'
  run reach_verify "$BARE_PATH"
  [[ "$(row_of "env JVM user home")" == "WEAK   PARSED      env JVM user home"*"HOME is $TEST_HOME, but the JVM takes user.home from the passwd entry of uid $(id -u), $pw: gradle reads $pw/.gradle, not $TEST_HOME/.gradle (GRADLE_USER_HOME would move it)" ]]
  # Control: GRADLE_USER_HOME set, so gradle reads that.
  run reach_verify GRADLE_USER_HOME="$TEST_HOME/.gradle" "$BARE_PATH"
  [ -z "$(row_of "env JVM user home")" ]
  # Control: HOME is the passwd home.
  getent_home "$TEST_HOME"
  run reach_verify "$BARE_PATH"
  [ -z "$(row_of "env JVM user home")" ]
  # A trailing slash or a symlink to it is the same home.
  ln -s "$TEST_HOME" "$BATS_TEST_TMPDIR/homelink"
  getent_home "$BATS_TEST_TMPDIR/homelink/"
  run reach_verify "$BARE_PATH"
  [ -z "$(row_of "env JVM user home")" ]
}

@test "JVM home: maven counts with no variable to set, the row is not a tool, and nothing JVM means no row" {
  local pw="$BATS_TEST_TMPDIR/pwhome"
  mkdir -p "$pw"
  getent_home "$pw"
  # Control first: no gradle and no maven, no row whatever the homes are.
  run reach_verify "$BARE_PATH"
  [ -z "$(row_of "env JVM user home")" ]
  stub_bin mvn 'exit 0'
  run reach_verify GRADLE_USER_HOME="$TEST_HOME/.gradle" "$BARE_PATH"
  [[ "$(row_of "env JVM user home")" == "WEAK"*"$pw: maven most likely reads $pw/.m2, not $TEST_HOME/.m2 (not measured)" ]]
  run --separate-stderr reach_verify GRADLE_USER_HOME="$TEST_HOME/.gradle" "$BARE_PATH" --json
  python3 -c '
import json, sys
d = json.load(sys.stdin)
assert any(r["protection"] == "env JVM user home" and r["status"] == "WEAK" for r in d["rows"]), d["rows"]
assert "env" not in d["result"]["tools_seen"], d["result"]
' <<<"$output"
}

@test "JVM home: with no getent, the passwd file answers" {
  # The fallback minimal images need. The entry is this account's real one, so
  # skip where /etc/passwd has none (macOS keeps accounts elsewhere).
  local pw
  pw=$(awk -F: -v u="$(id -u)" '$3 == u { print $6; exit }' /etc/passwd 2>/dev/null)
  [ -n "$pw" ] || skip "no /etc/passwd entry for uid $(id -u)"
  [ "$pw" != "$TEST_HOME" ]
  stub_bin getent 'exit 2'
  stub_bin gradle 'exit 0'
  run reach_verify "$BARE_PATH"
  [[ "$(row_of "env JVM user home")" == "WEAK"*"passwd entry of uid $(id -u), $pw: gradle reads $pw/.gradle,"* ]]
}

@test "JVM home: a tool the record did not ask for is left out, as its other rows are N/A" {
  local pw="$BATS_TEST_TMPDIR/pwhome"
  mkdir -p "$pw"
  getent_home "$pw"
  stub_bin gradle 'exit 0'
  stub_bin mvn 'exit 0'
  forge ecosystems_hardened=npm release_age_hours=48
  run reach_verify "$BARE_PATH"
  [[ "$(row_of "gradle HTTPS-only repos")" == "N/A    BYDESIGN    gradle HTTPS-only repos"* ]]
  [ -z "$(row_of "env JVM user home")" ]
  # Control: the same host with gradle in the record; maven still left out.
  forge ecosystems_hardened=npm,gradle release_age_hours=48
  run reach_verify "$BARE_PATH"
  [[ "$(row_of "env JVM user home")" == "WEAK"*"gradle reads $pw/.gradle, not $TEST_HOME/.gradle (GRADLE_USER_HOME would move it)" ]]
  [[ "$output" != *"maven most likely"* ]]
  forge ecosystems_hardened=maven release_age_hours=48
  run reach_verify "$BARE_PATH"
  [[ "$(row_of "env JVM user home")" == "WEAK"*"$pw: maven most likely reads $pw/.m2, not $TEST_HOME/.m2 (not measured)" ]]
}

@test "gradle: off PATH, an init script counts where gradle reads it (the passwd home), not under a HOME it does not read" {
  # gradle_script_deployed looked in $HOME/.gradle, which neither writer uses
  # when HOME is not the passwd home.
  local pw="$BATS_TEST_TMPDIR/pwhome"
  mkdir -p "$pw/.gradle/init.d"
  getent_home "$pw"
  : > "$pw/.gradle/init.d/supply-chain-security.gradle"
  run reach_verify "$BARE_PATH"
  [[ "$(row_of "gradle HTTPS-only repos")" == "WEAK   PRESENT     gradle HTTPS-only repos"*"an init script IS deployed under $pw/.gradle"* ]]
  [[ "$(row_of "gradle dynamic-version refusal")" == "WEAK   PRESENT     gradle dynamic-version refusal"*"deployed under $pw/.gradle"* ]]
  # Control: the script only under HOME, which gradle does not read here.
  rm -rf "$pw/.gradle"
  mkdir -p "$TEST_HOME/.gradle/init.d"
  : > "$TEST_HOME/.gradle/init.d/supply-chain-security.gradle"
  run reach_verify "$BARE_PATH"
  [[ "$(row_of "gradle HTTPS-only repos")" == "N/A    ABSENT      gradle HTTPS-only repos"*"no init script deployed"* ]]
  # ... unless GRADLE_USER_HOME points gradle there.
  run reach_verify GRADLE_USER_HOME="$TEST_HOME/.gradle" "$BARE_PATH"
  [[ "$(row_of "gradle HTTPS-only repos")" == "WEAK   PRESENT     gradle HTTPS-only repos"*"deployed under $TEST_HOME/.gradle"* ]]
}

# ------------------------------------------------- too old, and unchangeable --

# Stand-ins for the versions each GAP is about: npm 10.9.4 (no min-release-age),
# yarn 4.9.4 (no npmMinimalAgeGate), pnpm 10.15.1 (no minimumReleaseAge before
# 10.16.0), poetry 2.3.4 (no solver.min-release-age before 2.4.0).
old_tools() { # <dir>
  mkdir -p "$1"
  printf '#!/bin/bash\ncase "$*" in\n  --version) echo 10.9.4 ;;\n  "config get min-release-age"*) echo undefined ;;\n  "config get ignore-scripts"*) echo true ;;\n  *) echo ;;\nesac\n' > "$1/npm"
  printf '#!/bin/bash\ncase "$*" in\n  --version) echo 4.9.4 ;;\n  "config get npmMinimalAgeGate") echo "Usage Error: Couldn'"'"'t find a configuration settings named \\"npmMinimalAgeGate\\""; exit 1 ;;\n  *) exit 0 ;;\nesac\n' > "$1/yarn"
  printf '#!/bin/bash\ncase "$*" in\n  --version) echo 10.15.1 ;;\n  *) exit 0 ;;\nesac\n' > "$1/pnpm"
  printf '#!/bin/bash\ncase "$*" in\n  *--version) echo "Poetry (version 2.3.4)" ;;\n  *) exit 0 ;;\nesac\n' > "$1/poetry"
  chmod 0755 "$1/npm" "$1/yarn" "$1/pnpm" "$1/poetry"
}

@test "too old: in a directory this account cannot write, each toolchain GAP says where the tool is; writable, it says nothing more" {
  [ "$(id -u)" != 0 ] || skip "a 0555 directory does not stop root"
  local ro="$BATS_TEST_TMPDIR/image/bin" t
  old_tools "$ro"
  chmod a-w "$ro"
  run reach_verify "$ro:$BARE_PATH"
  chmod u+w "$ro"
  [[ "$(row_of "npm age gate")" == "GAP    FUNCTIONAL  npm age gate"*"(11.2.0 to 11.9.0). npm is at $ro/npm, in a directory its owner cannot write" ]]
  [[ "$(row_of "yarn age gate")" == "GAP"*"Only a yarn upgrade closes this. yarn is at $ro/yarn, in a directory its owner cannot write" ]]
  [[ "$(row_of "pnpm age gate")" == "GAP"*"Only a pnpm upgrade closes this. pnpm is at $ro/pnpm, in a directory its owner cannot write" ]]
  [[ "$(row_of "poetry publish-age gate")" == "GAP"*"still resolves. poetry is at $ro/poetry, in a directory its owner cannot write" ]]
  # No new row: one per protection, as before.
  for t in "npm age gate" "yarn age gate" "pnpm age gate" "poetry publish-age gate"; do
    [ "$(row_of "$t" | wc -l | tr -d ' ')" = 1 ]
  done
  # Control: the same tools in a writable directory.
  run reach_verify "$ro:$BARE_PATH"
  [[ "$(row_of "npm age gate")" == "GAP"*"(11.2.0 to 11.9.0)" ]]
  [[ "$(row_of "pnpm age gate")" == "GAP"*"Only a pnpm upgrade closes this" ]]
  [[ "$output" != *" is at $ro/"* ]]
}

@test "too old: a directory another account owns names it; as root, a directory root cannot write reads as image-owned" {
  [ "$(id -u)" != 0 ] || skip "run as a non-root user"
  local ro="$BATS_TEST_TMPDIR/rootbin" me
  me=$(id -un)
  if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    old_tools "$BATS_TEST_TMPDIR/src"
    sudo -n mkdir -p "$ro"
    sudo -n cp "$BATS_TEST_TMPDIR/src/npm" "$ro/npm"
    sudo -n chmod 0755 "$ro" "$ro/npm"
    [ "$(ls -ld "$ro" | awk '{print $3}')" = root ]
    run reach_verify "$ro:$BARE_PATH"
    sudo -n rm -rf "$ro"
    [[ "$(row_of "npm age gate")" == "GAP"*". npm is at $ro/npm: owned by root; upgrading needs that account" ]]
  fi
  # Root on a read-only mount, simulated: a 0555 directory of ours, and an id
  # that answers 0 for -u, so `[ -w ]` says no as it does for root on a
  # read-only filesystem. (A 0555 directory alone does not stop root.)
  old_tools "$BATS_TEST_TMPDIR/ro"
  chmod a-w "$BATS_TEST_TMPDIR/ro"
  stub_bin id "case \"\$*\" in -u) echo 0 ;; -un) echo root ;; *) exec $(type -P id) \"\$@\" ;; esac"
  run reach_verify "$BATS_TEST_TMPDIR/ro:$BARE_PATH"
  chmod u+w "$BATS_TEST_TMPDIR/ro"
  [[ "$(row_of "npm age gate")" == "GAP"*". npm is at $BATS_TEST_TMPDIR/ro/npm: read-only (image-owned?)" ]]
  [[ "$output" != *"owned by $me"* ]]
}

# --------------------------------------------- versions that read a relative --

# A python3 whose pip is <version>, reports uploaded-prior-to=<value>, and
# whose ensurepip seeds the same pip. [no-flag] for a pip without the option;
# [refused] for one that refuses the value, which fails its help as a real pip
# does (MEASURED, pip 26.0.1 to 26.3: exit 2, nothing on stdout).
pip_stub() { # <version> <value> [no-flag|refused] [pip dir]
  local help="echo '  --uploaded-prior-to <when>'"
  [ "${3:-}" != no-flag ] || help="echo '  --only-binary <format_control>'"
  [ "${3:-}" != refused ] || help="echo \"--uploaded-prior-to error: invalid value: '$2'\" >&2; exit 2"
  stub_bin python3 "case \"\$*\" in
  *'import ensurepip'*) echo $1; echo /nonexistent-prefix ;;
  '-m pip --version') echo 'pip $1 from ${4:-/nonexistent}/pip (python 3.12)' ;;
  '-m pip install --help') $help ;;
  '-m pip config list'*) echo \"global.uploaded-prior-to='$2'\" ;;
  *) exit 1 ;;
esac"
}

@test "pip: a P<n>D duration is OK on pip 26.1 and later, WEAK below; zero is a GAP, shorter than the window WEAK" {
  forge ecosystems_hardened=pip release_age_hours=48
  pip_stub 26.1 P3D
  run reach_verify "$BARE_PATH"
  [[ "$(row_of "pip native age gate")" == "OK     PARSED      pip native age gate"*"uploaded-prior-to='P3D' (72h), a window that moves with the clock"* ]]
  [[ "$(row_of "pip venv age gate")" == "OK     PARSED      pip venv age gate"*"seeds pip 26.1"*"'P3D' (72h)"* ]]
  # Control: the same value on pip 26.0.1, which refuses it (exit 2, MEASURED).
  pip_stub 26.0.1 P3D
  run reach_verify "$BARE_PATH"
  [[ "$(row_of "pip native age gate")" == "WEAK   PARSED      pip native age gate"*"the P<n>D form needs pip 26.1+"* ]]
  [[ "$(row_of "pip venv age gate")" == "WEAK   PARSED      pip venv age gate"*"not an absolute instant ending in Z; a duration needs pip 26.1 or later"* ]]
  pip_stub 26.2.2 P0D
  run reach_verify "$BARE_PATH"
  [[ "$(row_of "pip native age gate")" == "GAP    PARSED      pip native age gate"*"a window of zero"* ]]
  [[ "$(row_of "pip venv age gate")" == "GAP"*"a window of zero"* ]]
  pip_stub 26.2.2 P1D
  run reach_verify "$BARE_PATH"
  [[ "$(row_of "pip native age gate")" == "WEAK"*"(24h), shorter than the 48h promised here"* ]]
  # A leading zero is still days (pip 26.1.2 and 26.3 accept P08D, MEASURED),
  # not octal.
  pip_stub 26.2.2 P08D
  run reach_verify "$BARE_PATH"
  [[ "$(row_of "pip native age gate")" == "OK"*"'P08D' (192h)"* ]]
}

@test "pip: on 26.1 and later a duration that is not whole days is refused, a GAP, never OK" {
  # MEASURED (pip 26.1.2, 26.2.2, 26.3): PT48H, P1W, P1DT12H and P1M make every
  # pip install exit 2, while `pip config list` still prints them.
  local v
  forge ecosystems_hardened=pip release_age_hours=48
  for v in PT48H P1W P1DT12H P1M; do
    pip_stub 26.2.2 "$v"
    run reach_verify "$BARE_PATH"
    [[ "$(row_of "pip native age gate")" == "GAP    PARSED      pip native age gate"*"pip 26.2.2 refuses uploaded-prior-to='$v', so every pip install exits 2 and nothing is age-gated."* ]]
    [[ "$(row_of "pip venv age gate")" == "GAP    PARSED      pip venv age gate"*"python3 -m venv seeds pip 26.2.2, which refuses uploaded-prior-to='$v', so every pip install exits 2"* ]]
  done
  # Control: the whole-days form of the same 48h.
  pip_stub 26.2.2 P2D
  run reach_verify "$BARE_PATH"
  [[ "$(row_of "pip native age gate")" == "OK"*"'P2D' (48h)"* ]]
  [[ "$(row_of "pip venv age gate")" == "OK"*"'P2D' (48h)"* ]]
}

@test "pip: a pip whose help fails over its value is a GAP for the value, not one for a pip too old" {
  # A real pip refusing its value fails `pip install --help` too, so the row
  # never got to the value: it said pip lacked the option.
  forge ecosystems_hardened=pip release_age_hours=48
  pip_stub 26.3 PT48H refused
  run reach_verify "$BARE_PATH"
  [[ "$(row_of "pip native age gate")" == "GAP    PARSED      pip native age gate"*"pip 26.3 refuses uploaded-prior-to='PT48H', so every pip install exits 2"* ]]
  [[ "$output" != *"does NOT implement --uploaded-prior-to"* ]]
  # Control: a pip whose help has no such option and prints no error.
  pip_stub 24.0 "" no-flag
  run reach_verify "$BARE_PATH"
  [[ "$(row_of "pip native age gate")" == "GAP    PARSED      pip native age gate"*"pip 24.0 does NOT implement --uploaded-prior-to"* ]]
}

@test "pip: too old for the option, the GAP says where pip is when this account cannot change it" {
  [ "$(id -u)" != 0 ] || skip "a 0555 directory does not stop root"
  local site="$BATS_TEST_TMPDIR/site-packages"
  mkdir -p "$site/pip"
  forge ecosystems_hardened=pip release_age_hours=48
  pip_stub 24.0 "" no-flag "$site"
  chmod a-w "$site"
  run reach_verify "$BARE_PATH"
  chmod u+w "$site"
  [[ "$(row_of "pip native age gate")" == "GAP    PARSED      pip native age gate"*"not age-gated on this interpreter. pip is at $site, in a directory its owner cannot write" ]]
  run reach_verify "$BARE_PATH"
  [[ "$(row_of "pip native age gate")" == "GAP"*"not age-gated on this interpreter" ]]
}

@test "uv: a span is OK when it covers the window and every uv on PATH reads a span; a uv 0.9.16 there makes it WEAK" {
  forge ecosystems_hardened=uv release_age_hours=48
  uv_stub "$TEST_BIN" 0.13.9 48h
  run reach_verify "$BARE_PATH"
  [[ "$(row_of "uv age gate")" == "OK     PARSED      uv age gate"*"uv reports exclude-newer span 48h (48h), resolved against now on every run, and every uv on this shell's PATH is 0.9.17 or newer"* ]]
  # Control: a uv 0.9.16 further down this shell's PATH, which rejects the file.
  uv_stub "$BATS_TEST_TMPDIR/olduv" 0.9.16
  run reach_verify "$BARE_PATH:$BATS_TEST_TMPDIR/olduv"
  [[ "$(row_of "uv age gate")" == "WEAK   PARSED      uv age gate"*"but uv 0.9.16 at $BATS_TEST_TMPDIR/olduv/uv is on this shell's PATH"* ]]
  # 0.9.17 itself reads one.
  uv_stub "$BATS_TEST_TMPDIR/olduv" 0.9.17
  run reach_verify "$BARE_PATH:$BATS_TEST_TMPDIR/olduv"
  [[ "$(row_of "uv age gate")" == "OK"* ]]
  uv_stub "$TEST_BIN" 0.13.9 0s
  run reach_verify "$BARE_PATH"
  [[ "$(row_of "uv age gate")" == "GAP    PARSED      uv age gate"*"a window of zero"* ]]
  uv_stub "$TEST_BIN" 0.13.9 1d
  run reach_verify "$BARE_PATH"
  [[ "$(row_of "uv age gate")" == "WEAK"*"(24h), shorter than the 48h promised here"* ]]
  uv_stub "$TEST_BIN" 0.13.9 1w
  run reach_verify "$BARE_PATH"
  [[ "$(row_of "uv age gate")" == "OK"*"(168h)"* ]]
}

@test "uv: a uv under the working directory, or in a directory others can write, is not run; it keeps the span from OK" {
  # A bare `uv` runs $TEST_BIN/uv. The other one sits later on PATH, and
  # leaves a mark when it runs.
  local w="$BATS_TEST_TMPDIR/checkout"
  forge ecosystems_hardened=uv release_age_hours=48
  uv_stub "$TEST_BIN" 0.13.9 48h
  mkdir -p "$w/.venv/bin"
  printf '#!/bin/bash\n: > %q\necho "uv 0.13.9"\n' "$w/ran" > "$w/.venv/bin/uv"
  chmod 0755 "$w/.venv/bin/uv"
  run agent_sh "$BARE_PATH:$w/.venv/bin" 'cd "$1" && exec bash "$0" --emit=plain' "$VERIFY_SH" "$w"
  [[ "$(row_of "uv age gate")" == "WEAK   PARSED      uv age gate"*"but uv at $w/.venv/bin/uv (not run: under the working directory) is on this shell's PATH"* ]]
  [ ! -e "$w/ran" ]
  # Control: the same PATH from /, where it is run, and 0.13.9 reads a span.
  run agent_sh "$BARE_PATH:$w/.venv/bin" 'cd / && exec bash "$0" --emit=plain' "$VERIFY_SH"
  [[ "$(row_of "uv age gate")" == "OK"*"every uv on this shell's PATH is 0.9.17 or newer"* ]]
  [ -e "$w/ran" ]
  rm -f "$w/ran"
  chmod o+w "$w/.venv/bin"
  run agent_sh "$BARE_PATH:$w/.venv/bin" 'cd / && exec bash "$0" --emit=plain' "$VERIFY_SH"
  [[ "$(row_of "uv age gate")" == "WEAK"*"but uv at $w/.venv/bin/uv (not run: other accounts can write its directory)"* ]]
  [ ! -e "$w/ran" ]
}

# ------------------------------------------------------- home-only re-apply --

@test "home-only record: the fix for a frozen cutoff is harden.sh --home-only; an older record keeps the old wording" {
  forge ecosystems_hardened=pip release_age_hours=48 home_only=true env_layer=none
  pip_stub 26.2.2 2020-01-01T00:00:00Z
  run reach_verify "$BARE_PATH"
  [[ "$(row_of "pip native age gate")" == "WEAK"*"FREEZE"*"Re-run action/harden.sh --home-only to advance it. Nothing else does in that mode, so run it at the start of each session" ]]
  # Control: the same record without the key.
  forge ecosystems_hardened=pip release_age_hours=48
  run reach_verify "$BARE_PATH"
  [[ "$(row_of "pip native age gate")" == "WEAK"*"FREEZE"*"Re-run action/harden.sh to advance it, and re-source its env file"* ]]
  [[ "$output" != *"--home-only"* ]]
}

# A uv whose settings come from a per-user config only while there is one under
# HOME, as uv's do with no /etc/uv/uv.toml: the system-config row asks again
# with an empty HOME. Without the per-user file, <how>: none (uv's defaults),
# bad (uv refuses a malformed system file), system (a live system layer).
uv_sys_stub() { # <dir> <how>
  mkdir -p "$1"
  cat > "$1/uv" <<EOF
#!/bin/bash
span() { printf '%s\n' "PipSettings {" "    no_build: All," "    exclude_newer: ExcludeNewer {" "        global: Some(" "            Relative(" "                ExcludeNewerSpan(" "                    48h," "                )," "            )," "        )," "    }," "}"; }
case "\$*" in
  --version*|-V*) echo "uv 0.13.9" ;;
  "pip list --show-settings")
    if [ -f "\$HOME/.config/uv/uv.toml" ]; then span; exit 0; fi
    case "$2" in
      none)   printf '%s\n' "PipSettings {" "    no_build: None," "    exclude_newer: ExcludeNewer {" "        global: None," "    }," "}" ;;
      bad)    echo "error: Failed to parse: \\\`/etc/uv/uv.toml\\\`" >&2; exit 2 ;;
      system) printf '%s\n' "PipSettings {" "    no_build: All," "    exclude_newer: ExcludeNewer {" "        global: Some(" "            Absolute(" "                2026-11-25T00:00:00Z," "            )," "        )," "    }," "}" ;;
    esac ;;
  *) echo /tmp ;;
esac
EOF
  chmod +x "$1/uv"
}

@test "home-only record: uv's system config missing is N/A BYDESIGN, not a GAP a re-run closes; an older record keeps the GAP" {
  mkdir -p "$TEST_HOME/.config/uv"
  printf 'exclude-newer = "48 hours"\nno-build = true\n' > "$TEST_HOME/.config/uv/uv.toml"
  uv_sys_stub "$TEST_BIN" none
  # Ground truth: with HOME's file uv reports the settings, with an empty HOME none.
  run agent_sh "$BARE_PATH" 'uv pip list --show-settings | grep no_build'
  [[ "$output" == *"no_build: All,"* ]]
  run agent_sh "$BARE_PATH" 'HOME=$(mktemp -d) uv pip list --show-settings | grep no_build'
  [[ "$output" == *"no_build: None,"* ]]
  forge ecosystems_hardened=uv release_age_hours=48 home_only=true env_layer=none
  run reach_verify "$BARE_PATH" --fail-on=config
  echo "$output" | grep -E '^(GAP|WEAK)|uv system|fixable' || true
  [[ "$(row_of "uv system config (sudo/other users)")" == "N/A    BYDESIGN    uv system config (sudo/other users)"*"uv reports neither no-build nor exclude-newer, so sudo uv and other users on this host get no uv config. This run checks harden.sh --home-only, which by design writes no /etc file"* ]]
  [ "$status" -eq 0 ]
  [[ "$output" != *"RESULT: "*"gap(s)"* ]]

  # Control: the same host with a record without the key, a GAP a re-run closes.
  forge ecosystems_hardened=uv release_age_hours=48
  run reach_verify "$BARE_PATH" --fail-on=config
  [[ "$(row_of "uv system config (sudo/other users)")" == "GAP    PARSED      uv system config (sudo/other users)"*"needs /etc/uv/uv.toml"* ]]
  [[ "$output" == *"1 fixable by re-running the hardening, 0 no configuration can close"* ]]
  [ "$status" -eq 1 ]

  # With the key, only the last branch changes: a file uv refuses is still a GAP,
  # and a live system layer still OK.
  forge ecosystems_hardened=uv release_age_hours=48 home_only=true env_layer=none
  uv_sys_stub "$TEST_BIN" bad
  run reach_verify "$BARE_PATH" --fail-on=config
  [[ "$(row_of "uv system config (sudo/other users)")" == "GAP    FUNCTIONAL  uv system config (sudo/other users)"*"uv STILL refuses to run: error: Failed to parse"* ]]
  [ "$status" -eq 1 ]
  uv_sys_stub "$TEST_BIN" system
  run reach_verify "$BARE_PATH" --fail-on=config
  [[ "$(row_of "uv system config (sudo/other users)")" == "OK     PARSED      uv system config (sudo/other users)"*"cutoff 2026-11-25T00:00:00Z"* ]]
  [ "$status" -eq 0 ]

  # The role never applies --home-only: on its surface a SCV_HOME_ONLY from the
  # environment does nothing (action/verify.sh sets its own, never inherited).
  local def
  def=$(grep '^scv_home_only() ' "$PROBES")
  [ -n "$def" ]
  run env SCV_HOME_ONLY=1 bash -c "SCV_SURFACE=role; $def"$'\n''scv_home_only'
  [ "$status" -eq 1 ]
  run env SCV_HOME_ONLY=1 bash -c "SCV_SURFACE=ci; $def"$'\n''scv_home_only'
  [ "$status" -eq 0 ]
}

# A bun 1.4.4, unwrapped, as far as the bun rows ask it: bun usage for --help,
# the type-check error the age-gate row looks for, and an install that runs no
# script.
bun_stub() { # <dir>
  mkdir -p "$1"
  cat > "$1/bun" <<'EOF'
#!/bin/bash
case "${1:-}" in
  --version|-v) echo 1.4.4 ;;
  --help) echo "Usage: bun <command> [...flags] [...args]"; echo "  --no-install    Disable auto install in the Bun runtime" ;;
  pm) if grep -q '^minimumReleaseAge = "SCH-PROBE-SENTINEL"' bunfig.toml 2>/dev/null; then
        echo "error: Expected number of seconds for minimumReleaseAge"; fi ;;
esac
exit 0
EOF
  chmod +x "$1/bun"
}

@test "home-only record: a bun outside HOME stays a GAP, one a re-run cannot close; under HOME, or with an older record, one it can" {
  printf '[install]\nignoreScripts = true\nminimumReleaseAge = 172800\n' > "$TEST_HOME/.bunfig.toml"
  bun_stub "$TEST_BIN"
  # Ground truth: this shell's bun is outside HOME and is no wrapper.
  run agent_sh "$BARE_PATH" 'command -v bun'
  [ "$output" = "$TEST_BIN/bun" ]
  [[ "$output" != "$TEST_HOME"/* ]]
  ! grep -q supply-chain-harden "$TEST_BIN/bun" || false
  forge ecosystems_hardened=bun release_age_hours=48 home_only=true env_layer=none
  run reach_verify "$BARE_PATH" --fail-on=config
  echo "$output" | grep -E '^(GAP|WEAK)|fixable' || true
  [[ "$(row_of "bun runtime auto-install blocked")" == "GAP    PRESENT     bun runtime auto-install blocked"*"unwrapped binary at $TEST_BIN/bun;"*"harden.sh --home-only writes no wrapper outside HOME, so re-running it does not close this"* ]]
  [[ "$(row_of "bunx fetch-and-execute blocked")" == "GAP    PRESENT     bunx fetch-and-execute blocked"*"bunx is not on PATH and bun at $TEST_BIN/bun is unwrapped"*"re-running it does not close this" ]]
  [[ "$output" == *"0 fixable by re-running the hardening, 2 that a re-run cannot close (the tool is too old, does not run or has no such control, or needs a wrapper outside HOME or a variable, which --home-only does not write)."* ]]
  [ "$status" -eq 0 ]
  # A bunx beside it, linked to bun as bun installs it: the bunx branch.
  ln -s bun "$TEST_BIN/bunx"
  run reach_verify "$BARE_PATH" --fail-on=config
  [[ "$(row_of "bunx fetch-and-execute blocked")" == "GAP    PRESENT     bunx fetch-and-execute blocked"*"bunx resolves to an unwrapped binary at $TEST_BIN/bunx;"*"re-running it does not close this" ]]
  [ "$status" -eq 0 ]
  rm -f "$TEST_BIN/bunx"

  # Control: the same record and bun, with no home_only key. Both are GAPs a
  # re-run closes, as before, and --fail-on=config fails.
  forge ecosystems_hardened=bun release_age_hours=48
  run reach_verify "$BARE_PATH" --fail-on=config
  [[ "$(row_of "bun runtime auto-install blocked")" == "GAP    PRESENT     bun runtime auto-install blocked"*"is not consulted for \`bun run\` at all" ]]
  [[ "$output" == *"2 fixable by re-running the hardening, 0 no configuration can close"* ]]
  [[ "$output" != *"--home-only"* ]]
  [ "$status" -eq 1 ]

  # Control: home_only, with the bun under HOME, where a re-run writes its wrapper.
  forge ecosystems_hardened=bun release_age_hours=48 home_only=true env_layer=none
  rm -f "$TEST_BIN/bun"
  bun_stub "$TEST_HOME/.bun/bin"
  run reach_verify "$TEST_HOME/.bun/bin:$BARE_PATH" --fail-on=config
  [[ "$(row_of "bun runtime auto-install blocked")" == "GAP    PRESENT     bun runtime auto-install blocked"*"unwrapped binary at $TEST_HOME/.bun/bin/bun;"*"is not consulted for \`bun run\` at all" ]]
  [[ "$output" == *"2 fixable by re-running the hardening, 0 that a re-run cannot close"* ]]
  [ "$status" -eq 1 ]
}

# A cargo, unwrapped, as far as the cargo rows ask it: a version, and nothing else.
cargo_stub() { # <dir>
  mkdir -p "$1"
  printf '#!/bin/bash\ncase "${1:-}" in --version|-V) echo "cargo 1.95.0 (f2b3e4f5a 2026-10-01)" ;; esac\nexit 0\n' > "$1/cargo"
  chmod +x "$1/cargo"
}

@test "home-only record: a cargo outside HOME left unwrapped is a GAP a re-run cannot close; under HOME, or with an older record, one it can" {
  # MEASURED (2026-11-27, macOS): a rustup cargo outside the HOME harden.sh
  # --home-only was given failed --fail-on=config with "1 fixable".
  cargo_stub "$TEST_BIN"
  # Ground truth: this shell's cargo is outside HOME and is no wrapper.
  run agent_sh "$BARE_PATH" 'command -v cargo'
  [ "$output" = "$TEST_BIN/cargo" ]
  [[ "$output" != "$TEST_HOME"/* ]]
  ! grep -q supply-chain-harden "$TEST_BIN/cargo" || false
  forge ecosystems_hardened=cargo release_age_hours=48 home_only=true env_layer=none
  run reach_verify "$BARE_PATH" --fail-on=config
  echo "$output" | grep -E '^(GAP|WEAK)|fixable' || true
  [[ "$(row_of "cargo publish-age gate")" == "GAP    PRESENT     cargo publish-age gate"*"cargo is not wrapped"*"cargo resolves to $TEST_BIN/cargo. harden.sh --home-only writes no wrapper outside HOME, so re-running it does not close this" ]]
  [[ "$output" == *"0 fixable by re-running the hardening, 1 that a re-run cannot close"* ]]
  [ "$status" -eq 0 ]

  # Control: the same cargo with an older record, a GAP a re-run closes.
  forge ecosystems_hardened=cargo release_age_hours=48
  run reach_verify "$BARE_PATH" --fail-on=config
  [[ "$(row_of "cargo publish-age gate")" == "GAP    PRESENT     cargo publish-age gate"*"cargo resolves to $TEST_BIN/cargo" ]]
  [[ "$output" == *"1 fixable by re-running the hardening, 0 no configuration can close"* ]]
  [ "$status" -eq 1 ]

  # Control: home_only, with the cargo under HOME, where a re-run writes its wrapper.
  forge ecosystems_hardened=cargo release_age_hours=48 home_only=true env_layer=none
  rm -f "$TEST_BIN/cargo"
  cargo_stub "$TEST_HOME/.cargo/bin"
  run reach_verify "$TEST_HOME/.cargo/bin:$BARE_PATH" --fail-on=config
  [[ "$(row_of "cargo publish-age gate")" == "GAP    PRESENT     cargo publish-age gate"*"cargo resolves to $TEST_HOME/.cargo/bin/cargo" ]]
  [[ "$output" == *"1 fixable by re-running the hardening, 0 that a re-run cannot close"* ]]
  [ "$status" -eq 1 ]
}

# A deno 2.7.14, unwrapped: it runs and prints its version, and reads no npm
# min-release-age (2.8.0 is the first that does).
deno_stub() { # <dir>
  mkdir -p "$1"
  printf '#!/bin/bash\ncase "${1:-}" in --version|-V) echo "deno 2.7.14 (stable, release, x86_64-unknown-linux-gnu)" ;; esac\nexit 0\n' > "$1/deno"
  chmod +x "$1/deno"
}

@test "home-only record: a deno outside HOME without its wrapper is a GAP a re-run cannot close; under HOME, or with an older record, one it can" {
  local tail=", so no invocation is age-gated (deno 2.7.14 reads no npm min-release-age here)"
  deno_stub "$TEST_BIN"
  run agent_sh "$BARE_PATH" 'command -v deno'
  [ "$output" = "$TEST_BIN/deno" ]
  forge ecosystems_hardened=deno release_age_hours=48 home_only=true env_layer=none
  run reach_verify "$BARE_PATH" --fail-on=config
  echo "$output" | grep -E '^(GAP|WEAK)|fixable' || true
  [[ "$(row_of "deno publish-age gate")" == "GAP    PRESENT     deno publish-age gate"*"$TEST_BIN/deno"*"$tail. harden.sh --home-only writes no wrapper outside HOME, so re-running it does not close this" ]]
  [[ "$output" == *"0 fixable by re-running the hardening, 1 that a re-run cannot close"* ]]
  [ "$status" -eq 0 ]
  # A deno-real beside it: an upgrade wrote over the wrapper an earlier full apply put there.
  printf '#!/bin/bash\nexit 0\n' > "$TEST_BIN/deno-real"
  chmod +x "$TEST_BIN/deno-real"
  run reach_verify "$BARE_PATH" --fail-on=config
  [[ "$(row_of "deno publish-age gate")" == "GAP    PRESENT     deno publish-age gate"*"$TEST_BIN/deno-real is beside it"*"overwrote the wrapper. harden.sh --home-only writes no wrapper outside HOME, so re-running it does not close this" ]]
  [ "$status" -eq 0 ]

  # Control: the same deno with an older record, GAPs a re-run closes.
  forge ecosystems_hardened=deno release_age_hours=48
  run reach_verify "$BARE_PATH" --fail-on=config
  [[ "$(row_of "deno publish-age gate")" == "GAP    PRESENT     deno publish-age gate"*"overwrote the wrapper; re-run action/harden.sh" ]]
  [ "$status" -eq 1 ]
  rm -f "$TEST_BIN/deno-real"
  run reach_verify "$BARE_PATH" --fail-on=config
  [[ "$(row_of "deno publish-age gate")" == "GAP    PRESENT     deno publish-age gate"*"$TEST_BIN/deno"*"$tail" ]]
  [[ "$output" == *"1 fixable by re-running the hardening, 0 no configuration can close"* ]]
  [ "$status" -eq 1 ]

  # Control: home_only, with the deno under HOME, where a re-run writes its wrapper.
  forge ecosystems_hardened=deno release_age_hours=48 home_only=true env_layer=none
  rm -f "$TEST_BIN/deno"
  deno_stub "$TEST_HOME/.deno/bin"
  run reach_verify "$TEST_HOME/.deno/bin:$BARE_PATH" --fail-on=config
  [[ "$(row_of "deno publish-age gate")" == "GAP    PRESENT     deno publish-age gate"*"$TEST_HOME/.deno/bin/deno"*"$tail" ]]
  [[ "$output" == *"1 fixable by re-running the hardening, 0 that a re-run cannot close"* ]]
  [ "$status" -eq 1 ]
}

# A composer 2.11.2 whose config commands all fail and whose scripts run: on
# dump-autoload it echoes the script line as composer does when it dispatches
# one, writes the file the script would and vendor/autoload.php.
composer_stub() { # <dir>
  mkdir -p "$1"
  cat > "$1/composer" <<'EOF'
#!/bin/bash
case " $* " in
  *" --version "*) echo "Composer version 2.11.2 2026-10-01 12:00:00" ;;
  *" dump-autoload "*)
    echo "> @php -r \"file_put_contents(getenv('SCH_MARK'), '1');\""
    [ -z "${SCH_MARK:-}" ] || : > "$SCH_MARK"
    mkdir -p vendor && : > vendor/autoload.php ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$1/composer"
}

@test "home-only record: composer scripts running through an unwrapped composer outside HOME are a GAP a re-run cannot close; with an older record, one it can" {
  # The stub's other rows are GAPs a re-run closes in both runs (its config
  # commands fail), so the scripts row is told apart by the counts.
  local re_ho='([0-9]+) fixable by re-running the hardening, ([0-9]+) that a re-run cannot close'
  local re_old='([0-9]+) fixable by re-running the hardening, ([0-9]+) no configuration can close'
  local n
  composer_stub "$TEST_BIN"
  run agent_sh "$BARE_PATH" 'command -v composer'
  [ "$output" = "$TEST_BIN/composer" ]
  forge ecosystems_hardened=composer release_age_hours=48 home_only=true env_layer=none
  run reach_verify "$BARE_PATH" --fail-on=config
  echo "$output" | grep -E '^(GAP|WEAK)|fixable' || true
  [[ "$(row_of "composer lifecycle scripts blocked")" == "GAP    FUNCTIONAL  composer lifecycle scripts blocked"*"a post-autoload-dump script EXECUTED through"*"$TEST_BIN/composer"*"not blocked in this job. harden.sh --home-only writes no wrapper outside HOME and no env file, so re-running it does not close this" ]]
  [[ "$output" =~ $re_ho ]]
  [ "${BASH_REMATCH[2]}" = 1 ]
  n=${BASH_REMATCH[1]}

  # Control: the same composer with an older record: one more a re-run closes.
  forge ecosystems_hardened=composer release_age_hours=48
  run reach_verify "$BARE_PATH" --fail-on=config
  [[ "$(row_of "composer lifecycle scripts blocked")" == "GAP    FUNCTIONAL  composer lifecycle scripts blocked"*"EXECUTED through"*"$TEST_BIN/composer"*"composer scripts are not blocked in this job" ]]
  [[ "$output" =~ $re_old ]]
  [ "${BASH_REMATCH[2]}" = 0 ]
  [ "${BASH_REMATCH[1]}" -eq $((n + 1)) ]
  [ "$status" -eq 1 ]
}

@test "pnpm: one whose --version prints nothing is a GAP no configuration can close, after --home-only or not; one that runs and reads nothing is one a re-run closes" {
  # MEASURED (2026-11-27, macOS): Homebrew's pnpm, a corepack shim, printed no
  # version in an empty HOME and failed --fail-on=config with "2 fixable".
  stub_bin pnpm 'exit 0'
  run agent_sh "$BARE_PATH" 'cd / && pnpm --version; echo "rc=$?"'
  [ "$output" = "rc=0" ]
  forge ecosystems_hardened=pnpm release_age_hours=48
  run reach_verify "$BARE_PATH" --fail-on=config
  echo "$output" | grep -E '^(GAP|WEAK)|fixable' || true
  [[ "$(row_of "pnpm lifecycle scripts blocked")" == "GAP    FUNCTIONAL  pnpm lifecycle scripts blocked"*"'pnpm --version' from / returned nothing, so nothing about it could be checked" ]]
  [[ "$(row_of "pnpm age gate")" == "GAP    FUNCTIONAL  pnpm age gate"*"'pnpm --version' from / returned nothing, so nothing about it could be checked" ]]
  [[ "$output" == *"0 fixable by re-running the hardening, 2 no configuration can close (the tool is too old, does not run, or has no such control)."* ]]
  [ "$status" -eq 0 ]
  forge ecosystems_hardened=pnpm release_age_hours=48 home_only=true env_layer=none
  run reach_verify "$BARE_PATH" --fail-on=config
  [[ "$(row_of "pnpm age gate")" == "GAP    FUNCTIONAL  pnpm age gate"*"returned nothing"* ]]
  [[ "$output" == *"0 fixable by re-running the hardening, 2 that a re-run cannot close"* ]]
  [ "$status" -eq 0 ]

  # Control: a pnpm 11 that runs and reads none of what the hardening wrote.
  stub_bin pnpm 'case "$*" in --version) echo 11.0.0 ;; "config get "*) echo undefined ;; esac'
  forge ecosystems_hardened=pnpm release_age_hours=48
  run reach_verify "$BARE_PATH" --fail-on=config
  [[ "$(row_of "pnpm lifecycle scripts blocked")" == "GAP    PARSED      pnpm lifecycle scripts blocked"*"pnpm 11.0.0 reports ignore-scripts=undefined"* ]]
  [[ "$(row_of "pnpm age gate")" == "GAP    PARSED      pnpm age gate"*"pnpm 11.0.0 reports no minimumReleaseAge from its files"* ]]
  [[ "$output" == *"2 fixable by re-running the hardening, 0 no configuration can close"* ]]
  [ "$status" -eq 1 ]
}

# A dotnet SDK <version> that checks package signatures only when
# DOTNET_NUGET_SIGNATURE_VERIFICATION=true, as MEASURED on macOS with SDK 10.0.106
# (2026-11-27) and on Linux with 6.0.428: then signatureValidationMode=require
# refuses an unsigned package with NU3004, and without it the package restores
# whatever the config says. It answers no `nuget config` question, so the other
# nuget rows are WEAK or N/A.
dotnet_sig_stub() { # <version>
  stub_bin dotnet 'case "$*" in
  --list-sdks) echo "'"$1"' [/usr/local/share/dotnet/sdk]" ;;
  --version) echo '"$1"' ;;
  "nuget list source --format short") echo "E https://api.nuget.org/v3/index.json" ;;
  restore\ *)
    pk=""; prev=""
    for a in "$@"; do [ "$prev" = --packages ] && pk=$a; prev=$a; done
    cfg=NuGet.Config; [ -f "$cfg" ] || cfg="$HOME/.nuget/NuGet/NuGet.Config"
    if [ "${DOTNET_NUGET_SIGNATURE_VERIFICATION:-}" = true ] && grep -q "signatureValidationMode. value=.require" "$cfg" 2>/dev/null; then
      echo "error NU3004: Package Sch.Probe.Unsigned 1.0.0 from source probe: the package is not signed."; exit 1
    fi
    [ -n "$pk" ] && mkdir -p "$pk/sch.probe.unsigned/1.0.0" ;;
  *) exit 1 ;;
esac'
}
uname_stub() { # <what uname -s prints>
  stub_bin uname 'if [ "$*" = -s ]; then echo '"$1"'; else exec "'"$BATS_TEST_TMPDIR"'/bare/uname" "$@"; fi'
}

@test "nuget: an inert signatureValidationMode names what each platform needs; after --home-only it is a GAP a re-run cannot close" {
  local b64
  b64=$(type -P base64) || skip "no base64 to write the probe's unsigned package"
  ln -s "$b64" "$TEST_BIN/base64"
  mkdir -p "$TEST_HOME/.nuget/NuGet"
  printf '<configuration><config><add key="signatureValidationMode" value="require" /></config></configuration>\n' > "$TEST_HOME/.nuget/NuGet/NuGet.Config"
  dotnet_sig_stub 10.0.106
  uname_stub Darwin
  run agent_sh "$BARE_PATH" 'uname -s'
  [ "$output" = Darwin ]
  forge ecosystems_hardened=nuget release_age_hours=48 home_only=true env_layer=none
  # FIXTURE CONTROL: with the variable set, the host's config refuses the package.
  run reach_verify DOTNET_NUGET_SIGNATURE_VERIFICATION=true "$BARE_PATH" --fail-on=config
  echo "$output" | grep -E '^(GAP|WEAK)|nuget|fixable' || true
  [[ "$(row_of "nuget signature enforcement")" == "OK     FUNCTIONAL  nuget signature enforcement"*"refused an UNSIGNED package with NU3004"* ]]
  [ "$status" -eq 0 ]
  # Without it, the macOS reason, in the class a re-run cannot close.
  run reach_verify "$BARE_PATH" --fail-on=config
  echo "$output" | grep -E '^(GAP|WEAK)|nuget|fixable' || true
  [[ "$(row_of "nuget signature enforcement")" == "GAP    FUNCTIONAL  nuget signature enforcement"*"admitted an UNSIGNED package: the key is accepted and inert on SDK 10.0.106: on macOS NuGet verifies package signatures only when DOTNET_NUGET_SIGNATURE_VERIFICATION=true (MEASURED on SDK 10.0.106, 2026-11-27). harden.sh --home-only writes no env file, so it cannot set DOTNET_NUGET_SIGNATURE_VERIFICATION=true and re-running it does not close this" ]]
  [[ "$output" == *"0 fixable by re-running the hardening, 1 that a re-run cannot close"* ]]
  [ "$status" -eq 0 ]

  # Control: an older record, whose env file sets the variable: one a re-run closes.
  forge ecosystems_hardened=nuget release_age_hours=48
  run reach_verify "$BARE_PATH" --fail-on=config
  [[ "$(row_of "nuget signature enforcement")" == "GAP    FUNCTIONAL  nuget signature enforcement"*"on macOS NuGet verifies package signatures only when DOTNET_NUGET_SIGNATURE_VERIFICATION=true (MEASURED on SDK 10.0.106, 2026-11-27)" ]]
  [[ "$output" == *"1 fixable by re-running the hardening, 0 no configuration can close"* ]]
  [ "$status" -eq 1 ]

  # On Linux the reason stays the SDK tier measured there.
  dotnet_sig_stub 6.0.428
  uname_stub Linux
  run reach_verify "$BARE_PATH" --fail-on=config
  [[ "$(row_of "nuget signature enforcement")" == "GAP    FUNCTIONAL  nuget signature enforcement"*"admitted an UNSIGNED package: the key is accepted and inert on SDK 6.0.428 (enforcement needs SDK 8.0+ on Linux; measured inert on 6.0.428)" ]]
  [ "$status" -eq 1 ]
  forge ecosystems_hardened=nuget release_age_hours=48 home_only=true env_layer=none
  run reach_verify "$BARE_PATH" --fail-on=config
  [[ "$(row_of "nuget signature enforcement")" == "GAP"*"measured inert on 6.0.428). harden.sh --home-only writes no env file"* ]]
  [ "$status" -eq 0 ]
}
