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
  # The apply's own run sets SCV_APPLY_RUN on the command that runs the verifier.
  awk '/ansible.builtin.command: \/usr\/local\/bin\/supply-chain-verify/ { c = 1; next }
       c && /^    SCV_APPLY_RUN: "1"$/ { found = 1 }
       c && /^- name:/ { c = 0 }
       END { exit !found }' "$ROOT/tasks/verify.yml"
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
  [[ "$output" == "N/A|-|env layer propagation|this is the apply's own run"* ]]
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
  # The role's apply run leaves these rows out.
  run reach_verify SCV_APPLY_RUN=1 "$BARE_PATH"
  [ -n "$(row_of "uv age gate")" ]
  [ -z "$(row_of "uv on this shell's PATH")" ]
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
  [[ "$(row_of "env JVM user home")" == "WEAK   PARSED      env JVM user home"*"HOME is $TEST_HOME, but the JVM takes user.home from the passwd entry of uid $(id -u), $pw, so the gradle files under HOME are not read: gradle reads $pw/.gradle"* ]]
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
  [[ "$(row_of "env JVM user home")" == "WEAK"*"the maven files under HOME are not read: maven most likely reads $pw/.m2 (not measured)"* ]]
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
  [[ "$(row_of "env JVM user home")" == "WEAK"*"passwd entry of uid $(id -u), $pw,"* ]]
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
# whose ensurepip seeds the same pip. [no-flag] for a pip without the option.
pip_stub() { # <version> <value> [no-flag] [pip dir]
  local help="  --uploaded-prior-to <when>"
  [ "${3:-}" != no-flag ] || help="  --only-binary <format_control>"
  stub_bin python3 "case \"\$*\" in
  *'import ensurepip'*) echo $1; echo /nonexistent-prefix ;;
  '-m pip --version') echo 'pip $1 from ${4:-/nonexistent}/pip (python 3.12)' ;;
  '-m pip install --help') echo '$help' ;;
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
  [[ "$(row_of "pip venv age gate")" == "WEAK   PARSED      pip venv age gate"*"not an absolute instant ending in Z, or a duration it reads"* ]]
  pip_stub 26.2.2 PT48H
  run reach_verify "$BARE_PATH"
  [[ "$(row_of "pip native age gate")" == "OK"*"(48h)"* ]]
  pip_stub 26.2.2 P0D
  run reach_verify "$BARE_PATH"
  [[ "$(row_of "pip native age gate")" == "GAP    PARSED      pip native age gate"*"a window of zero"* ]]
  [[ "$(row_of "pip venv age gate")" == "GAP"*"a window of zero"* ]]
  pip_stub 26.2.2 P1D
  run reach_verify "$BARE_PATH"
  [[ "$(row_of "pip native age gate")" == "WEAK"*"(24h), shorter than the 48h promised here"* ]]
  # A form it cannot read as a length stays WEAK.
  pip_stub 26.2.2 P1M
  run reach_verify "$BARE_PATH"
  [[ "$(row_of "pip native age gate")" == "WEAK"*"'P1M', a duration the verifier cannot read as a length"* ]]
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
