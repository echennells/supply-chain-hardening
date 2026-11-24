#!/usr/bin/env bats
# The attacks themselves, run for real.
#
# Everything else in this suite asserts that the right bytes landed in the
# right file. These assert that a package manager ACTUALLY REFUSES the thing
# the hardening exists to stop — the only tests that would survive a tool
# renaming a config key underneath us.
#
# Each one skips when its tool is absent rather than failing, so the suite
# stays useful on a bare checkout and gets stricter on a fuller machine.

load helpers

setup() { common_setup; }

# --- npm: lifecycle script execution ---------------------------------------

@test "npm: a package postinstall does not execute" {
  have npm || skip "npm not installed"
  local marker="$BATS_TEST_TMPDIR/postinstall-ran"

  mkdir -p "$BATS_TEST_TMPDIR/evil"
  cat > "$BATS_TEST_TMPDIR/evil/package.json" <<JSON
{ "name": "evil-dep", "version": "1.0.0",
  "scripts": { "postinstall": "touch $marker" } }
JSON

  mkdir -p "$BATS_TEST_TMPDIR/proj"
  cat > "$BATS_TEST_TMPDIR/proj/package.json" <<'JSON'
{ "name": "victim", "version": "1.0.0", "private": true }
JSON

  harden ECOSYSTEMS=npm -- --emit=plain >/dev/null

  # Install with the hardened HOME in force, offline-safe (local path dep).
  run env -i PATH="$PATH" HOME="$TEST_HOME" \
    npm install --prefix "$BATS_TEST_TMPDIR/proj" \
    --no-audit --no-fund "$BATS_TEST_TMPDIR/evil"

  [ ! -f "$marker" ] || {
    echo "postinstall EXECUTED — the attack this exists to stop got through"
    return 1
  }
}

@test "npm: the same postinstall DOES run unhardened (the test can detect it)" {
  have npm || skip "npm not installed"
  # A negative control. Without it, test 1 passes just as happily when the
  # fixture is broken and nothing would have run either way.
  local marker="$BATS_TEST_TMPDIR/control-ran"

  mkdir -p "$BATS_TEST_TMPDIR/evil"
  cat > "$BATS_TEST_TMPDIR/evil/package.json" <<JSON
{ "name": "evil-dep", "version": "1.0.0",
  "scripts": { "postinstall": "touch $marker" } }
JSON
  mkdir -p "$BATS_TEST_TMPDIR/proj"
  cat > "$BATS_TEST_TMPDIR/proj/package.json" <<'JSON'
{ "name": "victim", "version": "1.0.0", "private": true }
JSON

  # Pristine HOME: no hardening applied.
  mkdir -p "$BATS_TEST_TMPDIR/cleanhome"
  run env -i PATH="$PATH" HOME="$BATS_TEST_TMPDIR/cleanhome" \
    npm install --prefix "$BATS_TEST_TMPDIR/proj" \
    --no-audit --no-fund "$BATS_TEST_TMPDIR/evil"

  [ -f "$marker" ] || skip "npm did not run the postinstall even unhardened; fixture cannot discriminate"
}

@test "npm: the hardened npmrc is what npm actually reads" {
  have npm || skip "npm not installed"
  harden ECOSYSTEMS=npm -- --emit=plain >/dev/null
  run env -i PATH="$PATH" HOME="$TEST_HOME" npm config get ignore-scripts
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "npm: npm reports the age gate under the key we wrote" {
  have npm || skip "npm not installed"
  harden ECOSYSTEMS=npm RELEASE_AGE_HOURS=96 -- --emit=plain >/dev/null
  run --separate-stderr env -i PATH="$PATH" HOME="$TEST_HOME" npm config get min-release-age
  [ "$status" -eq 0 ]
  if npm_ge 11.14.0 || ! npm_ge 11.2.0; then
    [ "$output" = "4" ]
  elif npm_ge 11.10.0; then
    # MEASURED on 11.10.0 to 11.13.0: npm enforces the key and prints null for it,
    # and prints the cutoff it became as `before`.
    [ "$output" = "null" ]
    run --separate-stderr env -i PATH="$PATH" HOME="$TEST_HOME" npm config get before
    [ "$output" != "null" ]
  else
    # 11.2.0 to 11.9.0 do not know the key and warn about it, so it is not written.
    [ "$output" = "undefined" ]
  fi
}

@test "npm: no npm command warns about a key or variable the hardening wrote" {
  # npm 11.2.0 to 11.9.0 print `npm warn Unknown user config "min-release-age"` (or
  # env, or global) on every command for a key they do not know. Asked of the real
  # npm with the files and the env layer in force, and with each on its own.
  have npm || skip "npm not installed"
  harden ECOSYSTEMS=npm -- --emit=plain >/dev/null
  local v="npm $(npm --version 2>/dev/null)"
  run --separate-stderr env -i PATH="$PATH" HOME="$TEST_HOME" npm config get ignore-scripts
  [ "$output" = true ]
  [[ "$stderr" != *"Unknown"* ]] || { echo "$v, the files: $stderr"; false; }
  mkdir -p "$BATS_TEST_TMPDIR/nohome"
  run --separate-stderr env -i PATH="$PATH" HOME="$BATS_TEST_TMPDIR/nohome" bash -c "source '$ENV_FILE'; npm config get ignore-scripts"
  [ "$output" = true ]
  [[ "$stderr" != *"Unknown"* ]] || { echo "$v, the env layer: $stderr"; false; }
  run --separate-stderr env -i PATH="$PATH" HOME="$TEST_HOME" bash -c "source '$ENV_FILE'; npm --version"
  [[ "$stderr" != *"Unknown"* ]] || { echo "$v, both: $stderr"; false; }
}

# --- npm: git dependencies under setup-node's redirect ----------------------
#
# actions/setup-node with registry-url writes its own .npmrc under RUNNER_TEMP
# and exports NPM_CONFIG_USERCONFIG at it (src/authutil.ts), so npm never reads
# the ~/.npmrc harden.sh writes, and its npm reads its prefix's etc/npmrc, not
# /etc/npmrc. allow-git=none was in the files only, so in that setup a git
# dependency installed (MEASURED on npm 11.19.1). Offline: the dependency is a
# git+file:// repository made here.

# Prints the git+file URL of a one-commit package repository.
npm_git_fixture() {
  local src="$BATS_TEST_TMPDIR/gitdep-src" bare="$BATS_TEST_TMPDIR/gitdep.git"
  mkdir -p "$src"
  printf '{"name":"gitdep","version":"1.0.0"}\n' > "$src/package.json"
  git -C "$src" init -q
  git -C "$src" add -A
  git -C "$src" -c user.email=t@t -c user.name=t commit -qm init
  git clone -q --bare "$src" "$bare"
  printf 'git+file://%s' "$bare"
}

# npm_install_git_dep <url> [env...]: a fresh project depending on <url>,
# installed in a later "step" (GITHUB_ENV applied, setup-node's .npmrc in
# force). Sets status/output; the dependency is installed iff
# $BATS_TEST_TMPDIR/proj/node_modules/gitdep exists.
npm_install_git_dep() {
  local url="$1"; shift
  local proj="$BATS_TEST_TMPDIR/proj" rt="$BATS_TEST_TMPDIR/rt" kv
  rm -rf "$proj"; mkdir -p "$proj" "$rt"
  printf '{"name":"p","version":"1.0.0","private":true,"dependencies":{"gitdep":"%s"}}\n' "$url" > "$proj/package.json"
  # What setup-node writes for registry-url (src/authutil.ts).
  printf '//registry.npmjs.org/:_authToken=${NODE_AUTH_TOKEN}\nregistry=https://registry.npmjs.org/\n' > "$rt/.npmrc"
  local -a envs=(PATH="$PATH" HOME="$TEST_HOME" NPM_CONFIG_USERCONFIG="$rt/.npmrc" NODE_AUTH_TOKEN=XXXXX-XXXXX-XXXXX-XXXXX)
  while IFS= read -r kv; do [ -n "$kv" ] && envs+=("$kv"); done < "$TEST_TMP/ghenv"
  run env -i "${envs[@]}" "$@" npm install --prefix "$proj" --no-audit --no-fund
}

@test "npm: under setup-node's NPM_CONFIG_USERCONFIG, a git dependency is refused (allow-git=none from the env layer)" {
  have npm || skip "npm not installed"
  have git || skip "git not installed"
  npm_ge 11.9.0 || skip "npm $(npm --version) predates allow-git (11.9.0)"
  local url; url=$(npm_git_fixture)
  harden ECOSYSTEMS=npm GITHUB_ACTIONS=true GITHUB_ENV="$TEST_TMP/ghenv" \
         GITHUB_OUTPUT="$TEST_TMP/ghout" GITHUB_STEP_SUMMARY="$TEST_TMP/ghsum" >/dev/null
  npm_install_git_dep "$url"
  [ "$status" -ne 0 ]
  [[ "$output" == *EALLOWGIT* ]] || { echo "refused, but not by allow-git:"; echo "$output"; return 1; }
  [ ! -e "$BATS_TEST_TMPDIR/proj/node_modules/gitdep" ]
}

@test "npm: FIXTURE CONTROL - the same redirect installs the git dependency without the variable" {
  # Without NPM_CONFIG_ALLOW_GIT the files are all that is left, and under the
  # redirect npm reads none of them: this is the bug, and it shows the fixture
  # installs when nothing refuses it. npm 12 refuses git dependencies by
  # default (MEASURED, 12.2.3), so there the control allows them explicitly.
  have npm || skip "npm not installed"
  have git || skip "git not installed"
  local url; url=$(npm_git_fixture)
  harden ECOSYSTEMS=npm GITHUB_ACTIONS=true GITHUB_ENV="$TEST_TMP/ghenv" \
         GITHUB_OUTPUT="$TEST_TMP/ghout" GITHUB_STEP_SUMMARY="$TEST_TMP/ghsum" >/dev/null
  filter_file "$TEST_TMP/ghenv" grep -v '^NPM_CONFIG_ALLOW_GIT='
  if npm_ge 12.0.0; then npm_install_git_dep "$url" NPM_CONFIG_ALLOW_GIT=all; else npm_install_git_dep "$url"; fi
  [ "$status" -eq 0 ] || { echo "the fixture did not install: $output"; return 1; }
  [ -e "$BATS_TEST_TMPDIR/proj/node_modules/gitdep/package.json" ]
}

# --- uv: sdist execution ---------------------------------------------------

@test "uv: accepts the rendered uv.toml rather than erroring on it" {
  have uv || skip "uv not installed"
  # The failure this guards: on uv before 0.9.17, a relative duration in
  # exclude-newer makes uv's TOML parser reject the file, breaking EVERY uv
  # invocation rather than just weakening the gate. (0.9.17 added relative
  # durations; the action writes an absolute instant for every uv.)
  harden ECOSYSTEMS=uv -- --emit=plain >/dev/null
  run env -i PATH="$PATH" HOME="$TEST_HOME" uv pip list
  [ "$status" -eq 0 ] || {
    echo "uv rejected its own config file:"; echo "$output"
    cat "$TEST_HOME/.config/uv/uv.toml"
    return 1
  }
}

@test "uv: refuses to build an sdist, so setup.py cannot execute" {
  have uv || skip "uv not installed"
  local marker="$BATS_TEST_TMPDIR/setuppy-ran"
  local pkg="$BATS_TEST_TMPDIR/sdistpkg"
  mkdir -p "$pkg"
  cat > "$pkg/setup.py" <<PY
import os
open(os.environ.get("MARKER", "$marker"), "w").close()
from setuptools import setup
setup(name="evil-sdist", version="1.0.0")
PY
  cat > "$pkg/pyproject.toml" <<'TOML'
[build-system]
requires = ["setuptools"]
build-backend = "setuptools.build_meta"
TOML

  harden ECOSYSTEMS=uv -- --emit=plain >/dev/null
  run env -i PATH="$PATH" HOME="$TEST_HOME" \
    uv pip install --system --no-cache "$pkg"
  # It must fail, and it must fail because building was refused.
  [ "$status" -ne 0 ]
  [ ! -f "$marker" ]
}

# --- the env layer, applied ------------------------------------------------

@test "sourcing the env file makes npm behave as hardened" {
  have npm || skip "npm not installed"
  # This is the mechanism a Drone/Woodpecker step or a Dockerfile would use:
  # config files came along on disk, and the env layer is picked up by hand.
  harden ECOSYSTEMS=npm -- --emit=plain >/dev/null
  run env -i PATH="$PATH" HOME="$BATS_TEST_TMPDIR/cleanhome2" bash -c "
    mkdir -p '$BATS_TEST_TMPDIR/cleanhome2'
    source '$ENV_FILE'
    npm config get ignore-scripts"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

# --- bundler ----------------------------------------------------------------

@test "bundler: bundler itself reads our age gate back" {
  # PARSED-strength: proves bundler read our file and accepted the key. Note
  # what this does NOT prove — see the next test.
  have bundle || skip "bundler not installed"
  harden ECOSYSTEMS=bundler -- --emit=plain >/dev/null
  run env -i PATH="$PATH" HOME="$TEST_HOME" bundle config get cooldown
  [ "$status" -eq 0 ]
  [[ "$output" == *"2"* ]]
  [[ "$output" == *".bundle/config"* ]]
}

@test "bundler: config get echoes ANY key, so it is not evidence on its own" {
  # The npm trap, reproduced in Ruby. `bundle config get <anything>` reports a
  # value for a key bundler has never heard of, so a passing `config get` says
  # the file was READ, not that the setting is implemented. This test exists so
  # nobody later mistakes the test above for proof of enforcement.
  have bundle || skip "bundler not installed"
  run env -i PATH="$PATH" HOME="$TEST_HOME" \
    BUNDLE_TOTALLY_FAKE_KEY=9 bundle config get totally_fake_key
  [ "$status" -eq 0 ]
  [[ "$output" == *"9"* ]]
}

@test "bundler: cooldown is a real registered setting, not an echoed one" {
  # The discriminator the action uses: bundler registers cooldown in its own
  # NUMBER_KEYS table alongside jobs/retry/timeout. That distinguishes
  # implemented from merely echoed, which config get cannot.
  #
  # cooldown landed in bundler 4.0.13 (BUNDLE_COOLDOWN, integer days, 0=off).
  # On an older bundler the key does not exist and the gate is correctly INERT
  # (harden.sh reports PARTIAL, not enforced), so the premise is not testable
  # here — skip rather than fail. On >= 4.0.13 we still ASSERT it, so a future
  # rename regresses loudly instead of silently disarming the only Ruby control.
  command -v ruby >/dev/null 2>&1 || skip "ruby not installed"
  run ruby -e 'require "bundler"; exit(2) if Gem::Version.new(Bundler::VERSION) < Gem::Version.new("4.0.13"); exit(Bundler::Settings::NUMBER_KEYS.include?("cooldown") ? 0 : 1)'
  [ "$status" -ne 2 ] || skip "local bundler predates cooldown (< 4.0.13); gate is INERT here, premise not testable"
  [ "$status" -eq 0 ]
}

# --- composer: harden.sh must not run a checkout's code -----------------------
# The action runs in the GitHub workspace, i.e. inside the checkout, before any
# wrapper exists. MEASURED on composer 2.11.2 at 8281a6b: harden.sh's
# `composer --version` activated the plugin the checkout's allow-plugins enables
# (committed to vendor/), and `composer config --global home` activated it again
# and ran the checkout's root pre-command-run script.

composer_hostile_checkout() {
  have composer || skip "composer not installed"
  have php || skip "php not installed"
  REAL_COMPOSER=$(command -v composer)
  # harden() no longer wraps a host composer (shield_host_tools in
  # helpers.bash), but one a real hardening run, or an older copy of this suite,
  # wrapped may still be on PATH. Go around that wrapper to the binary it execs.
  if grep -q 'supply-chain-harden' "$REAL_COMPOSER" 2>/dev/null; then
    REAL_COMPOSER=$(sed -n "s/^REAL_COMPOSER='\(.*\)'\$/\1/p" "$REAL_COMPOSER" | head -1)
    [ -n "$REAL_COMPOSER" ] && [ -x "$REAL_COMPOSER" ] || skip "composer on PATH is a hardening wrapper whose real binary could not be read"
  fi
  CH="$BATS_TEST_TMPDIR/checkout"
  PLUGIN_MARK="$BATS_TEST_TMPDIR/plugin-ran"; SCRIPT_MARK="$BATS_TEST_TMPDIR/script-ran"
  mkdir -p "$CH/plugin/src" "$CH/app"
  cat > "$CH/plugin/composer.json" <<'J'
{ "name": "evil/probe", "type": "composer-plugin", "version": "1.0.0",
  "require": { "composer-plugin-api": "^2.0" },
  "autoload": { "psr-4": { "Evil\\": "src/" } },
  "extra": { "class": "Evil\\Plugin" } }
J
  cat > "$CH/plugin/src/Plugin.php" <<P
<?php
namespace Evil;
use Composer\\Composer; use Composer\\IO\\IOInterface; use Composer\\Plugin\\PluginInterface;
class Plugin implements PluginInterface {
  public function activate(Composer \$c, IOInterface \$io) { file_put_contents('$PLUGIN_MARK', implode(' ', \$_SERVER['argv']) . "\n", FILE_APPEND); }
  public function deactivate(Composer \$c, IOInterface \$io) {}
  public function uninstall(Composer \$c, IOInterface \$io) {}
}
P
  cat > "$CH/app/composer.json" <<J
{ "name": "victim/app", "version": "0.0.0",
  "repositories": [ { "type": "path", "url": "../plugin", "options": { "symlink": false } } ],
  "require": { "evil/probe": "*" },
  "scripts": { "pre-command-run": "echo ran >> $SCRIPT_MARK" },
  "config": { "allow-plugins": { "evil/probe": true } } }
J
  ( cd "$CH/app" && env -u COMPOSER_SKIP_SCRIPTS HOME="$CH" COMPOSER_HOME="$CH/ch" COMPOSER_ALLOW_SUPERUSER=1 \
      "$REAL_COMPOSER" install --no-interaction ) >/dev/null 2>&1 || true
  [ -f "$CH/app/vendor/composer/installed.json" ] || skip "could not stage vendor/ from the path repository"
  rm -f "$PLUGIN_MARK" "$SCRIPT_MARK"
  # A stub that execs the real composer, so harden.sh wraps the stub in TEST_BIN
  # and never touches the system composer.
  stub_bin composer "exec '$REAL_COMPOSER' \"\$@\""
}

@test "composer: the hostile checkout fires without the protections (the test can detect it)" {
  composer_hostile_checkout
  ( cd "$CH/app" && env -i PATH="$TEST_BIN:$PATH" HOME="$TEST_HOME" COMPOSER_ALLOW_SUPERUSER=1 \
      composer config --global home --no-ansi ) >/dev/null 2>&1 || true
  [ -f "$PLUGIN_MARK" ] || skip "this composer ($("$REAL_COMPOSER" --version --no-ansi 2>/dev/null | head -1)) does not activate a checkout plugin on 'config --global' (MEASURED: 2.2.6 through 2.11.2 all do)"
}

@test "composer: harden.sh run inside a checkout runs none of its plugins or scripts" {
  composer_hostile_checkout
  cd "$CH/app"
  run harden ECOSYSTEMS=composer -- --emit=plain
  [ ! -f "$PLUGIN_MARK" ] || { echo "plugin ran: $(cat "$PLUGIN_MARK")" >&2; return 1; }
  [ ! -f "$SCRIPT_MARK" ] || { echo "the checkout's pre-command-run script ran" >&2; return 1; }
}

# ---- go: GOFLAGS is left to go ------------------------------------------------
#
# Earlier versions of harden.sh wrote GOFLAGS=-mod=readonly (env layer AND `go env -w`).
# MEASURED on go1.22.12 and go1.27.4: without vendor/ that is go's default; with
# vendor/ it makes go ignore the vendored copy (offline: a proxy dial error that
# names neither GOFLAGS nor this action; online: the proxy copy is compiled
# instead). go is a stub here, so this proves what harden.sh WRITES; the
# container suite (05-go.bats) proves the build behaviour with the real go.
# stub_go_env is in helpers.bash.

@test "go: harden.sh writes no GOFLAGS, to the env layer or to go env -w" {
  stub_go_env
  run harden ECOSYSTEMS=go -- --emit=plain
  [ "$status" -eq 0 ]
  # Counted, not `! grep`: bats does not fail a test on a negated command
  # unless it is the last line.
  [ "$(grep -c "GOFLAGS" "$ENV_FILE")" = 0 ]
  [ "$(grep -c "^GOFLAGS=" "$TEST_HOME/.config/go/env")" = 0 ]
  # The settings that do differ from go's defaults are still persisted.
  grep -qx "GOTOOLCHAIN=local" "$TEST_HOME/.config/go/env"
  grep -qx "GOSUMDB=sum.golang.org" "$TEST_HOME/.config/go/env"
}

@test "go: an earlier version's GOFLAGS=-mod=readonly is removed from go env; anyone else's GOFLAGS is kept" {
  stub_go_env
  mkdir -p "$TEST_HOME/.config/go"
  echo "GOFLAGS=-mod=readonly" > "$TEST_HOME/.config/go/env"
  run harden ECOSYSTEMS=go -- --emit=plain
  [ "$status" -eq 0 ]
  [ "$(grep -c "^GOFLAGS=" "$TEST_HOME/.config/go/env")" = 0 ]
  [[ "$output" == *"removed GOFLAGS=-mod=readonly"* ]]

  echo "GOFLAGS=-trimpath" > "$TEST_HOME/.config/go/env"
  run harden ECOSYSTEMS=go -- --emit=plain
  [ "$status" -eq 0 ]
  grep -qx "GOFLAGS=-trimpath" "$TEST_HOME/.config/go/env"
}

# Offline maven probe: a plugin whose jar does not match its .sha1, served from
# a file:// "Central". Maven validates checksums for file:// as for https
# (MEASURED, 3.9.11), so no network or TLS is needed. The settings harden.sh
# wrote are copied with every Central URL pointed at the fixture, which keeps
# their structure exactly as deployed. $1 = settings.xml, $2 = good|bad
maven_plugin_checksum_run() {
  local t r
  t=$(mktemp -d "${BATS_TEST_TMPDIR}/mvn.XXXXXX")
  r="$t/central/com/example/fake-maven-plugin/1.0"
  mkdir -p "$r" "$t/proj"
  cat > "$r/fake-maven-plugin-1.0.pom" <<'X'
<project xmlns="http://maven.apache.org/POM/4.0.0"><modelVersion>4.0.0</modelVersion>
<groupId>com.example</groupId><artifactId>fake-maven-plugin</artifactId><version>1.0</version><packaging>maven-plugin</packaging></project>
X
  printf 'PK\005\006\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000' \
    > "$r/fake-maven-plugin-1.0.jar"
  sha1sum "$r/fake-maven-plugin-1.0.pom" | cut -d' ' -f1 > "$r/fake-maven-plugin-1.0.pom.sha1"
  if [ "$2" = bad ]; then
    echo 0000000000000000000000000000000000000000 > "$r/fake-maven-plugin-1.0.jar.sha1"
  else
    sha1sum "$r/fake-maven-plugin-1.0.jar" | cut -d' ' -f1 > "$r/fake-maven-plugin-1.0.jar.sha1"
  fi
  printf '%s' '<project xmlns="http://maven.apache.org/POM/4.0.0"><modelVersion>4.0.0</modelVersion><groupId>x</groupId><artifactId>y</artifactId><version>1</version><packaging>pom</packaging></project>' \
    > "$t/proj/pom.xml"
  sed "s|https://repo.maven.apache.org/maven2|file://$t/central|g" "$1" > "$t/settings.xml"
  ( cd "$t/proj" && mvn -B -s "$t/settings.xml" -Dmaven.repo.local="$t/lr" \
      com.example:fake-maven-plugin:1.0:x 2>&1 )
}

@test "maven: a plugin jar with a wrong checksum is refused at download (CMP 4.4)" {
  # Before: checksumPolicy=fail covered <repositories> only, and the super
  # POM's separate pluginRepository central kept 'warn' — the jar installed
  # with a WARNING. Assert the ERROR-level refusal for the plugin jar itself.
  have mvn || skip "maven not installed"
  harden ECOSYSTEMS=maven -- --emit=plain >/dev/null
  run maven_plugin_checksum_run "$TEST_HOME/.m2/settings.xml" bad
  echo "$output" | grep -E 'Checksum|ERROR' | head -5
  echo "$output" | grep -qE '^\[ERROR\].*fake-maven-plugin:jar:1\.0.*Checksum validation failed'
  ! echo "$output" | grep -q 'No plugin descriptor found'
}

@test "maven: FIXTURE CONTROL — the same plugin with a correct checksum gets past download" {
  have mvn || skip "maven not installed"
  harden ECOSYSTEMS=maven -- --emit=plain >/dev/null
  run maven_plugin_checksum_run "$TEST_HOME/.m2/settings.xml" good
  echo "$output" | grep -E 'Checksum|ERROR' | head -5
  echo "$output" | grep -q 'No plugin descriptor found'
  ! echo "$output" | grep -q 'Checksum validation failed'
}

# Offline gradle probe (CMP 4.6): a 1.+ selector on a SCRIPT classpath,
# resolved from a file:// repo that holds com.example:probe:1.0 with its
# maven-metadata.xml, so 1.+ CAN resolve. Plugins resolve into script
# classpaths: a project's buildscript.configurations for plugins{} /
# buildscript{} in build.gradle, the settings script's for the same blocks in
# settings.gradle. gradle loads harden.sh's init.gradle.kts from the gradle
# user home it wrote. $1 = selector, $2 = project|settings
gradle_script_classpath_run() {
  local t r bs
  t=$(mktemp -d "${BATS_TEST_TMPDIR}/gr.XXXXXX")
  r="$t/repo/com/example/probe"
  mkdir -p "$r/1.0" "$t/proj"
  cat > "$r/maven-metadata.xml" <<'X'
<?xml version="1.0" encoding="UTF-8"?>
<metadata><groupId>com.example</groupId><artifactId>probe</artifactId>
<versioning><latest>1.0</latest><release>1.0</release><versions><version>1.0</version></versions><lastUpdated>20200101000000</lastUpdated></versioning></metadata>
X
  printf '%s' '<project xmlns="http://maven.apache.org/POM/4.0.0"><modelVersion>4.0.0</modelVersion><groupId>com.example</groupId><artifactId>probe</artifactId><version>1.0</version></project>' \
    > "$r/1.0/probe-1.0.pom"
  printf 'PK\005\006\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000' \
    > "$r/1.0/probe-1.0.jar"
  bs="buildscript { repositories { maven { url = uri('file://$t/repo') } }
  dependencies { classpath 'com.example:probe:$1' } }"
  if [ "$2" = settings ]; then
    printf "%s\nrootProject.name = 'p'\n" "$bs" > "$t/proj/settings.gradle"
    : > "$t/proj/build.gradle"
  else
    echo "rootProject.name = 'p'" > "$t/proj/settings.gradle"
    printf '%s\n' "$bs" > "$t/proj/build.gradle"
  fi
  # macOS runners have no timeout(1); bound the run only where it exists.
  local to=()
  if have timeout; then to=(timeout 300); elif have gtimeout; then to=(gtimeout 300); fi
  ( cd "$t/proj" && GRADLE_USER_HOME="$TEST_HOME/.gradle" \
      ${to[@]+"${to[@]}"} gradle --offline --no-daemon -q --console=plain help 2>&1 )
}

@test "gradle: a dynamic version on the plugin classpath is refused, in build and settings scripts (CMP 4.6)" {
  # Before: failOn* covered allprojects{configurations} only. MEASURED (gradle
  # 8.14.3 and 9.1.0, this script at 8281a6b): a 1.+ plugin resolved and its
  # code RAN from plugins{}, buildscript{} and both blocks in settings.gradle.
  have gradle || skip "gradle not installed"
  harden ECOSYSTEMS=gradle -- --emit=plain >/dev/null
  local where
  for where in project settings; do
    run gradle_script_classpath_run '1.+' "$where"
    echo "[$where] $output" | grep -iE 'dynamic|wrong|error' | head -5
    [ "$status" -ne 0 ]
    echo "$output" | grep -q 'Resolution strategy disallows usage of dynamic versions'
  done
}

@test "gradle: FIXTURE CONTROL — the same script classpath with a static 1.0 resolves" {
  have gradle || skip "gradle not installed"
  harden ECOSYSTEMS=gradle -- --emit=plain >/dev/null
  local where
  for where in project settings; do
    run gradle_script_classpath_run '1.0' "$where"
    echo "[$where] $output" | head -5
    [ "$status" -eq 0 ]
  done
}
