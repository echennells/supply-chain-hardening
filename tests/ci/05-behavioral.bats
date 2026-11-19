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
  run env -i PATH="$PATH" HOME="$TEST_HOME" npm config get min-release-age
  [ "$status" -eq 0 ]
  [ "$output" = "4" ]
}

# --- uv: sdist execution ---------------------------------------------------

@test "uv: accepts the rendered uv.toml rather than erroring on it" {
  have uv || skip "uv not installed"
  # The failure this guards: a relative duration in exclude-newer makes uv's
  # TOML parser reject the file, breaking EVERY uv invocation rather than
  # just weakening the gate.
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
  ( cd "$t/proj" && GRADLE_USER_HOME="$TEST_HOME/.gradle" \
      timeout 300 gradle --offline --no-daemon -q --console=plain help 2>&1 )
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
