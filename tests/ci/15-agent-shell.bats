#!/usr/bin/env bats
# harden.sh --home-only, run and checked the way an agent's runner runs commands.
#
# MEASURED on an agent VM on 2026-11-26 (docs/design-principles.md, "Agent runners"):
# every command went through `/bin/bash --norc --noprofile -c "umask 0007; ..."` as
# root with HOME=/home/hatch, whose passwd home is /root; its npm and bun were in a
# read-only image directory ahead of /usr/local/bin, and only the config files under
# HOME reached its shells. agent_sh and harden_agent (helpers.bash) start commands
# that way. What this suite cannot do is run as root or with a real read-only mount:
# it runs as a normal user, so "outside HOME" is a directory of this test's.
#
# The promise under test: in this mode nothing is written, moved, created or deleted
# outside HOME, sudo is never run, and a second run the same day changes nothing.

bats_require_minimum_version 1.5.0

load helpers

setup() { common_setup; }

rec() { sed -n "s/^$1=//p" "$OUT_FILE" | tail -n 1; }

# sudo_log_stub: a sudo first on PATH that records every call and then runs the
# command as this user, the way a passwordless sudo would for what harden.sh asks.
sudo_log_stub() {
  SUDO_LOG="$BATS_TEST_TMPDIR/sudo.log"
  stub_bin sudo 'echo "$*" >> "'"$SUDO_LOG"'"
while [ "$#" -gt 0 ]; do case "$1" in -n|-E|-H) shift ;; *) break ;; esac; done
exec "$@"'
}

# cutoff_day: the UTC date RELEASE_AGE_HOURS (48) ago, as harden.sh computes it.
cutoff_day() {
  date -u -d "48 hours ago" +%Y-%m-%d 2>/dev/null || date -u -v-48H +%Y-%m-%d
}

# home_state: every entry under HOME but the run record's directory, with its inode,
# mode and size, and the checksum of each file. Times are left to find -newer.
home_state() {
  ( cd "$TEST_HOME" && find . -path ./.cache/supply-chain-hardening -prune -o -print | LC_ALL=C sort \
    | while IFS= read -r p; do
        printf '%s ' "$p"; ls -ldin "$p" | awk '{print $1, $2, $6}'
        if [ -f "$p" ] && [ ! -L "$p" ]; then cksum < "$p"; fi
      done )
}

# --------------------------------------------------------------- sudo ----

@test "home-only: sudo is never run, also when WRITE_ETC=true and intel=sfw are passed, and it says they were ignored" {
  sudo_log_stub
  local t
  for t in bun composer cargo deno; do stub_bin "$t"; done
  run harden_agent WRITE_ETC=true INTEL=sfw INSTALL_CARGO_COOLDOWN=true
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -s "$SUDO_LOG" ] || { echo "sudo was called:"; cat "$SUDO_LOG"; false; }
  [[ "$output" == *"Ignored in this mode: WRITE_ETC=true, intel=sfw, INSTALL_CARGO_COOLDOWN=true."* ]]
  [ "$(rec sfw_installed)" = false ]
}

@test "home-only control: the same sudo stub IS called by a normal run" {
  # Without this the test above would pass with a stub harden.sh never looks for.
  [ "$(id -u)" -ne 0 ] || skip "as root harden.sh needs no sudo, so a normal run does not call it either"
  sudo_log_stub
  run harden ECOSYSTEMS=npm -- --emit=plain
  [ "$status" -eq 0 ]
  [ -s "$SUDO_LOG" ] || { echo "a normal run did not call the stub; the test above cannot tell"; false; }
  grep -q -- '-n true' "$SUDO_LOG"
}

@test "home-only: the GitHub adapter's files are not written; emit=github is ignored" {
  : > "$TEST_TMP/ghenv"; : > "$TEST_TMP/ghout"; : > "$TEST_TMP/ghsum"
  run harden_agent GITHUB_ACTIONS=true GITHUB_ENV="$TEST_TMP/ghenv" GITHUB_OUTPUT="$TEST_TMP/ghout" \
    GITHUB_STEP_SUMMARY="$TEST_TMP/ghsum" ECOSYSTEMS=npm,pip
  [ "$status" -eq 0 ]
  [ ! -s "$TEST_TMP/ghenv" ]
  [ ! -s "$TEST_TMP/ghout" ]
  [ ! -s "$TEST_TMP/ghsum" ]
  [[ "$output" == *"emit=github"* ]]
  [[ "$output" == *"Not reachable from HOME"* ]]
}

@test "home-only: TMPDIR and everything else outside HOME is left as it was" {
  # harden_agent hands it TMPDIR=TEST_TMP, outside HOME: bash's here-documents and the
  # tools it starts would write there. TEST_BIN is left out of the check because
  # harden_agent puts its pass-through stubs there before the run.
  local t
  for t in bun composer cargo deno; do stub_bin "$t"; done
  stub_go_env
  touch "$BATS_TEST_TMPDIR/mark"
  sleep 1
  touch "$BATS_TEST_TMPDIR/mark"
  run harden_agent
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  local newer
  newer=$(find "$BATS_TEST_TMPDIR" -newer "$BATS_TEST_TMPDIR/mark" \
            ! -path "$TEST_HOME" ! -path "$TEST_HOME/*" ! -path "$TEST_BIN" ! -path "$TEST_BIN/*")
  [ -z "$newer" ] || { echo "changed outside HOME:"; echo "$newer"; false; }
  [ -z "$(ls -A "$TEST_TMP")" ]
}

# ----------------------------------------------------------- wrappers ----

@test "home-only: tools outside HOME are neither wrapped nor moved, and each says what it goes without" {
  local t
  mkdir -p "$BATS_TEST_TMPDIR/orig"
  for t in bun composer cargo deno; do stub_bin "$t"; cp "$TEST_BIN/$t" "$BATS_TEST_TMPDIR/orig/$t"; done
  stub_symlink bunx "$TEST_BIN/bun"
  run harden_agent ECOSYSTEMS=bun,composer,cargo,deno
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  for t in bun composer cargo deno; do
    cmp "$TEST_BIN/$t" "$BATS_TEST_TMPDIR/orig/$t" || { echo "$t was changed"; false; }
    [ ! -e "$TEST_BIN/$t-real" ] || { echo "$t was moved aside"; false; }
    [[ "$output" == *"$t: no wrapper, because $TEST_BIN/$t is outside HOME"* ]] || { echo "no line for $t"; echo "$output"; false; }
  done
  [ -L "$TEST_BIN/bunx" ]
  [[ "$output" == *"deno has no age gate at all"* ]]
  [[ "$output" == *"no --locked"* ]]
  [ -z "$(rec wrappers_deployed)" ]
  [[ ",$(rec ecosystems_ineffective)," == *",deno,"* ]]
}

@test "home-only control: a normal run DOES wrap the same stubs" {
  # The stubs are wrappable where they are: TEST_BIN is this user's.
  local t
  for t in bun cargo deno; do stub_bin "$t"; done
  run harden ECOSYSTEMS=bun,cargo,deno -- --emit=plain
  [ "$status" -eq 0 ]
  for t in bun cargo deno; do
    [ -x "$TEST_BIN/$t-real" ] || { echo "$t was not wrapped by a normal run"; false; }
  done
}

@test "home-only: a tool under HOME is wrapped in place, -real beside it" {
  local d="$TEST_HOME/.bun/bin"
  mkdir -p "$d"
  printf '#!/bin/bash\ncase "${1:-}" in --version) echo 1.4.4 ;; *) echo "STUB:bun ARGS=[$*]" ;; esac\n' > "$d/bun"
  chmod +x "$d/bun"
  ln -s bun "$d/bunx"
  AGENT_PATH="$d:$TEST_BIN:$PATH" run harden_agent ECOSYSTEMS=bun
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ -x "$d/bun-real" ]
  [ "$(sed -n 2p "$d/bun")" = "# Managed by supply-chain-harden action" ]
  [ -f "$d/bunx" ]
  [ ! -L "$d/bunx" ]
  [ "$(rec wrappers_deployed)" = "bun,bunx" ]
  # and it is the wrapper that runs
  run agent_sh "PATH='$d':\$PATH; bun x"
  [[ "$output" == *"ARGS=[--no-install x]"* ]]
}

# ---------------------------------------------------------------- npm ----

npm_fixture() {
  MARKER="$BATS_TEST_TMPDIR/postinstall-ran"
  mkdir -p "$BATS_TEST_TMPDIR/evil" "$BATS_TEST_TMPDIR/proj"
  printf '{ "name": "evil-dep", "version": "1.0.0", "scripts": { "postinstall": "touch %s" } }\n' "$MARKER" \
    > "$BATS_TEST_TMPDIR/evil/package.json"
  printf '{ "name": "victim", "version": "1.0.0", "private": true }\n' > "$BATS_TEST_TMPDIR/proj/package.json"
}

@test "home-only: from the agent's shell npm reads ignore-scripts=true and a dependency's postinstall does not run" {
  have npm || skip "npm not installed"
  npm_fixture
  run harden_agent ECOSYSTEMS=npm
  [ "$status" -eq 0 ]
  local q
  q=$(mktemp -d "$TEST_TMP/q.XXXXXX")
  run --separate-stderr agent_sh NPM_CONFIG_GLOBALCONFIG="$NO_GLOBAL_NPMRC" "cd '$q' && npm config get ignore-scripts"
  [ "$status" -eq 0 ]
  [ "$output" = true ]
  run agent_sh NPM_CONFIG_GLOBALCONFIG="$NO_GLOBAL_NPMRC" \
    "npm install --prefix '$BATS_TEST_TMPDIR/proj' --no-audit --no-fund '$BATS_TEST_TMPDIR/evil'"
  [ ! -f "$MARKER" ] || { echo "postinstall EXECUTED from the agent's shell"; false; }
}

@test "home-only control: the same postinstall DOES run from the agent's shell unhardened" {
  have npm || skip "npm not installed"
  npm_fixture
  run agent_sh NPM_CONFIG_GLOBALCONFIG="$NO_GLOBAL_NPMRC" \
    "npm install --prefix '$BATS_TEST_TMPDIR/proj' --no-audit --no-fund '$BATS_TEST_TMPDIR/evil'"
  [ -f "$MARKER" ] || skip "npm did not run the postinstall even unhardened; fixture cannot discriminate"
}

# ------------------------------------------------------------- re-run ----

@test "home-only: a second run on the same day changes no file, makes no copy, and repeats no line before the summary" {
  local d
  for d in .bun/bin .cargo/bin .deno/bin .local/bin; do mkdir -p "$TEST_HOME/$d"; done
  printf '#!/bin/bash\necho 1.4.4\n' > "$TEST_HOME/.bun/bin/bun"
  printf '#!/bin/bash\necho cargo 1.90.0\n' > "$TEST_HOME/.cargo/bin/cargo"
  printf '#!/bin/bash\necho deno 2.9.8\n' > "$TEST_HOME/.deno/bin/deno"
  printf '#!/bin/bash\necho Composer version 2.11.2\n' > "$TEST_HOME/.local/bin/composer"
  chmod +x "$TEST_HOME"/.bun/bin/bun "$TEST_HOME"/.cargo/bin/cargo "$TEST_HOME"/.deno/bin/deno "$TEST_HOME"/.local/bin/composer
  ln -s bun "$TEST_HOME/.bun/bin/bunx"
  stub_npm 10.9.4
  stub_go_env
  local day
  day=$(date -u +%Y-%m-%d)
  export AGENT_PATH="$TEST_HOME/.bun/bin:$TEST_HOME/.cargo/bin:$TEST_HOME/.deno/bin:$TEST_HOME/.local/bin:$TEST_BIN:$PATH"

  run harden_agent
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  local first="$output"
  [[ "$first" == *"npm 10.9.4 does NOT implement min-release-age"* ]]
  assert_file_contains "$TEST_HOME/.config/go/env" '^GOTOOLCHAIN=local$'
  [ "$(rec wrappers_deployed)" = "bun,bunx,composer,cargo,deno" ]
  home_state > "$BATS_TEST_TMPDIR/before"
  touch "$TEST_TMP/mark"
  sleep 1

  run harden_agent
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ "$(date -u +%Y-%m-%d)" = "$day" ] || skip "the UTC day changed during the test, and with it the cutoff"
  home_state > "$BATS_TEST_TMPDIR/after"
  diff "$BATS_TEST_TMPDIR/before" "$BATS_TEST_TMPDIR/after"
  local newer
  newer=$(find "$TEST_HOME" -newer "$TEST_TMP/mark" ! -path "$STATE_DIR" ! -path "$STATE_DIR/*")
  [ -z "$newer" ] || { echo "changed by the second run:"; echo "$newer"; false; }
  [ -z "$(find "$TEST_HOME" -name '*~')" ]
  # The first run's lines are not repeated; the summary and the verdict are.
  [[ "$output" != *"does NOT implement min-release-age"* ]]
  [[ "$output" == *"lines an earlier --home-only run printed are not repeated"* ]]
  [[ "$output" == *"### Not reachable from HOME"* ]]
  [[ "$output" == *"done (--home-only). applied:"* ]]
  [ "$(rec wrappers_deployed)" = "bun,bunx,composer,cargo,deno" ]
}

# ------------------------------------------------------------ cutoffs ----

@test "home-only: uv gets a span when every uv reads one, and pip a cutoff at midnight" {
  have uv || skip "uv not installed"
  local v
  v=$(uv --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  awk -v a="$v" 'BEGIN { split(a, x, "."); exit !(x[1] > 0 || x[2] > 9 || (x[2] == 9 && x[3] >= 17)) }' \
    || skip "the uv here ($v) is older than 0.9.17"
  run harden_agent ECOSYSTEMS=uv,pip
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_file_contains "$TEST_HOME/.config/uv/uv.toml" '^exclude-newer = "48 hours"$'
  assert_file_contains "$TEST_HOME/.config/pip/pip.conf" "^uploaded-prior-to = $(cutoff_day)T00:00:00Z\$"
  # the real uv reads the file it got
  run agent_sh "uv pip list"
  [ "$status" -eq 0 ] || { echo "uv rejected it: $output"; cat "$TEST_HOME/.config/uv/uv.toml"; false; }
  [[ "$output" != *"failed to parse"* ]]
}

@test "home-only: a uv 0.9.16 anywhere on PATH, even last, keeps uv's cutoff an instant at midnight" {
  mkdir -p "$BATS_TEST_TMPDIR/olduv"
  printf '#!/bin/sh\necho "uv 0.9.16"\n' > "$BATS_TEST_TMPDIR/olduv/uv"
  chmod +x "$BATS_TEST_TMPDIR/olduv/uv"
  AGENT_PATH="$TEST_BIN:$PATH:$BATS_TEST_TMPDIR/olduv" run harden_agent ECOSYSTEMS=uv,pip
  [ "$status" -eq 0 ]
  assert_file_contains "$TEST_HOME/.config/uv/uv.toml" "^exclude-newer = \"$(cutoff_day)T00:00:00Z\"\$"
  assert_file_lacks "$TEST_HOME/.config/uv/uv.toml" "hours"
  assert_file_contains "$TEST_HOME/.config/pip/pip.conf" "^uploaded-prior-to = $(cutoff_day)T00:00:00Z\$"
}

@test "home-only: an old uv in ~/.local/bin counts though it is not on PATH" {
  have uv || skip "uv not installed"
  mkdir -p "$TEST_HOME/.local/bin"
  printf '#!/bin/sh\necho "uv 0.9.16"\n' > "$TEST_HOME/.local/bin/uv"
  chmod +x "$TEST_HOME/.local/bin/uv"
  run harden_agent ECOSYSTEMS=uv
  [ "$status" -eq 0 ]
  assert_file_contains "$TEST_HOME/.config/uv/uv.toml" "^exclude-newer = \"$(cutoff_day)T00:00:00Z\"\$"
}

@test "home-only: uv.toml switching between an instant and a span stays ours: no copy, no warning" {
  have uv || skip "uv not installed"
  mkdir -p "$BATS_TEST_TMPDIR/olduv"
  printf '#!/bin/sh\necho "uv 0.9.16"\n' > "$BATS_TEST_TMPDIR/olduv/uv"
  chmod +x "$BATS_TEST_TMPDIR/olduv/uv"
  local old="$TEST_BIN:$PATH:$BATS_TEST_TMPDIR/olduv" f="$TEST_HOME/.config/uv/uv.toml"
  AGENT_PATH="$old" run harden_agent ECOSYSTEMS=uv
  assert_file_contains "$f" 'T00:00:00Z"$'
  run harden_agent ECOSYSTEMS=uv
  [ "$status" -eq 0 ]
  [[ "$output" != *"replaced"* ]]
  AGENT_PATH="$old" run harden_agent ECOSYSTEMS=uv
  [ "$status" -eq 0 ]
  [[ "$output" != *"replaced"* ]]
  assert_file_contains "$f" 'T00:00:00Z"$'
  [ -z "$(find "$TEST_HOME/.config/uv" -name 'uv.toml.*')" ]
}

# --------------------------------------------------------- JVM homes ----

@test "home-only: HOME is not the passwd home, so nothing goes to the passwd home and gradle and maven say why" {
  local pw
  pw=$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6) || pw=""
  [ -n "$pw" ] || pw=$(awk -F: -v u="$(id -u)" '$3 == u { print $6; exit }' /etc/passwd 2>/dev/null) || pw=""
  stub_bin gradle
  stub_bin mvn
  local before after
  before=$(ls -la "$pw/.gradle" "$pw/.m2" 2>/dev/null; cksum "$pw/.gradle/init.gradle.kts" 2>/dev/null) || true
  touch "$TEST_TMP/mark"
  sleep 1
  run harden_agent ECOSYSTEMS=gradle,maven
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  if [ -n "$pw" ]; then
    after=$(ls -la "$pw/.gradle" "$pw/.m2" 2>/dev/null; cksum "$pw/.gradle/init.gradle.kts" 2>/dev/null) || true
    [ "$before" = "$after" ]
    [ -z "$(find "$pw/.gradle" "$pw/.m2" -newer "$TEST_TMP/mark" 2>/dev/null)" ]
    [[ "$output" == *"- gradle: the JVM reads $pw/.gradle, not $TEST_HOME/.gradle"* ]]
    [[ "$output" == *"- maven: the JVM reads $pw/.m2, not $TEST_HOME/.m2"* ]]
  else
    [[ "$output" == *"has no passwd entry"* ]]
  fi
  [ ! -e "$TEST_HOME/.gradle" ]
  [ ! -e "$TEST_HOME/.m2" ]
  [[ ",$(rec ecosystems_ineffective)," == *",gradle,maven,"* ]]
}

# getent_home <dir>: a getent whose passwd entry for this uid names <dir> as its home.
getent_home() {
  stub_bin getent "echo 'u:x:$(id -u):$(id -g)::$1:/bin/sh'"
}

@test "home-only: a passwd home that is HOME gets gradle's init script and maven's settings" {
  getent_home "$TEST_HOME"
  run harden_agent ECOSYSTEMS=gradle,maven
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  assert_file_contains "$TEST_HOME/.gradle/init.gradle.kts" "Managed by supply-chain-harden action"
  assert_file_contains "$TEST_HOME/.m2/settings.xml" "Managed by supply-chain-harden action"
  [[ ",$(rec ecosystems_effective)," == *",gradle,maven,"* ]]
}

@test "home-only: a passwd home elsewhere gets nothing; a normal run writes the init script there (control)" {
  local pw="$BATS_TEST_TMPDIR/pwhome"
  mkdir -p "$pw"
  getent_home "$pw"
  run harden_agent ECOSYSTEMS=gradle,maven
  [ "$status" -eq 0 ]
  [ -z "$(ls -A "$pw")" ]
  [ ! -e "$TEST_HOME/.gradle" ]
  [ ! -e "$TEST_HOME/.m2" ]
  [[ "$output" == *"the JVM reads $pw/.gradle"* ]]
  # The control: the same passwd home, no GRADLE_USER_HOME, a normal run.
  run env -i PATH="$TEST_BIN:$PATH" HOME="$TEST_HOME" TMPDIR="$TEST_TMP" WRITE_ETC=false \
    ECOSYSTEMS=gradle bash "$HARDEN_SH" --emit=plain
  [ "$status" -eq 0 ]
  assert_file_contains "$pw/.gradle/init.gradle.kts" "Managed by supply-chain-harden action"
}

@test "home-only: GRADLE_USER_HOME set by the caller under HOME is written" {
  getent_home "$BATS_TEST_TMPDIR/elsewhere"
  run harden_agent GRADLE_USER_HOME="$TEST_HOME/g" ECOSYSTEMS=gradle
  [ "$status" -eq 0 ]
  assert_file_contains "$TEST_HOME/g/init.gradle.kts" "Managed by supply-chain-harden action"
}

# ------------------------------------------------- record and env file ----

@test "home-only: no env file, and the record says home_only=true and env_layer=none" {
  run harden_agent ECOSYSTEMS=npm,pip
  [ "$status" -eq 0 ]
  [ ! -e "$ENV_FILE" ]
  [ "$(rec home_only)" = true ]
  [ "$(rec env_layer)" = none ]
  [ "$(rec env_file)" = "" ]
  [ "$(rec hardening_complete)" = true ]
}

@test "home-only control: a normal run writes the env file and neither key" {
  run harden ECOSYSTEMS=npm -- --emit=plain
  [ "$status" -eq 0 ]
  [ -s "$ENV_FILE" ]
  ! grep -qE '^(home_only|env_layer)=' "$OUT_FILE" || false
}

@test "home-only: env-only settings are named as applied nowhere" {
  run harden_agent ECOSYSTEMS=composer,nuget
  [ "$status" -eq 0 ]
  [[ "$output" == *"env layer: none, so these apply nowhere: COMPOSER_SKIP_SCRIPTS, DOTNET_NUGET_SIGNATURE_VERIFICATION"* ]]
}

@test "home-only: go with no go installed is not applied, as there is no env layer to carry it" {
  bare_path
  AGENT_PATH="$BARE_PATH" run harden_agent ECOSYSTEMS=go
  [ "$status" -eq 0 ]
  [[ ",$(rec ecosystems_ineffective)," == *",go,"* ]]
  [ ! -e "$TEST_HOME/.config/go" ]
}

# --------------------------------------------------------- the guard ----

@test "home-only: a directory whose name starts with HOME's is outside it (CARGO_HOME=\${HOME}x)" {
  local ch="${TEST_HOME}x/.cargo"
  run harden_agent CARGO_HOME="$ch" ECOSYSTEMS=cargo
  [ "$status" -eq 0 ]
  [ ! -e "${TEST_HOME}x" ]
  [[ "$output" == *"cargo: $ch/config.toml is outside HOME (CARGO_HOME)"* ]]
  [[ ",$(rec ecosystems_ineffective)," == *",cargo,"* ]]
}

@test "home-only: XDG_CONFIG_HOME outside HOME keeps pnpm, uv, bun and go out of it" {
  local x="$BATS_TEST_TMPDIR/xdg" e skipped="pnpm uv bun go"
  # go's config directory on macOS is ~/Library/Application Support, whatever
  # XDG_CONFIG_HOME says (os.UserConfigDir), so there go stays in HOME.
  [ "$(uname -s)" != Darwin ] || skipped="pnpm uv bun"
  stub_go_env
  run harden_agent XDG_CONFIG_HOME="$x" ECOSYSTEMS=pnpm,uv,bun,go
  [ "$status" -eq 0 ] || { echo "$output"; false; }
  [ ! -e "$x" ]
  for e in $skipped; do [[ ",$(rec ecosystems_ineffective)," == *",$e,"* ]] || { echo "$e: $output"; false; }; done
  [[ "$output" == *"(XDG_CONFIG_HOME)"* ]]
}

@test "home-only: a ~/.npmrc that links out of HOME is not written through" {
  local out="$BATS_TEST_TMPDIR/shared-npmrc"
  printf 'registry=https://registry.example/\n' > "$out"
  ln -s "$out" "$TEST_HOME/.npmrc"
  local sum
  sum=$(cksum < "$out")
  run harden_agent ECOSYSTEMS=npm
  [ "$status" -eq 0 ]
  [ "$(cksum < "$out")" = "$sum" ]
  [[ "$output" == *"$TEST_HOME/.npmrc leads outside HOME, through a symbolic link"* ]]
  [[ ",$(rec ecosystems_ineffective)," == *",npm,"* ]]
}

@test "home-only control: a normal run DOES write through that link" {
  local out="$BATS_TEST_TMPDIR/shared-npmrc"
  printf 'registry=https://registry.example/\n' > "$out"
  ln -s "$out" "$TEST_HOME/.npmrc"
  run harden ECOSYSTEMS=npm -- --emit=plain
  [ "$status" -eq 0 ]
  assert_file_contains "$out" "ignore-scripts=true"
}

@test "home-only: a run record outside HOME is refused before anything is written" {
  run harden_agent HARDENING_OUTPUT_FILE="$BATS_TEST_TMPDIR/rec/out" ECOSYSTEMS=npm
  [ "$status" -eq 2 ]
  [[ "$output" == *"run record would go to"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/rec" ]
  [ -z "$(ls -A "$TEST_HOME")" ]
}

@test "home-only: HOME_ONLY=true is the same switch as the flag" {
  sudo_log_stub
  run env -i PATH="$TEST_BIN:$PATH" HOME="$TEST_HOME" TMPDIR="$TEST_TMP" HOME_ONLY=true ECOSYSTEMS=npm \
    bash "$HARDEN_SH" --emit=plain
  [ "$status" -eq 0 ]
  [ "$(rec home_only)" = true ]
  [ ! -e "$ENV_FILE" ]
  [ ! -s "$SUDO_LOG" ]
}

@test "home-only: --preflight with it, and a HOME_ONLY that is not true or false, are refused" {
  run harden_agent -- --preflight
  [ "$status" -eq 2 ]
  [[ "$output" == *"does not combine with --home-only"* ]]
  run harden HOME_ONLY=yes ECOSYSTEMS=npm -- --emit=plain
  [ "$status" -eq 2 ]
  [[ "$output" == *"HOME_ONLY must be true or false"* ]]
}
