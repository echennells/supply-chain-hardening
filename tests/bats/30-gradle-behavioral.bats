#!/usr/bin/env bats
# Behavioral tests for Gradle supply-chain hardening.
#
# The role's tasks/gradle.yml gates on gradle OR a JDK (a ./gradlew build
# needs only java; CMP 4.5, tested in 25-integration-regressions.bats), then
# deploys ~/.gradle/init.d/supply-chain-security.gradle — an init script that
# throws GradleException on any HTTP (non-HTTPS) repository. Matrix
# mode runs these per (java, gradle) cell to confirm the init script
# is loaded across gradle versions (gradle's init.d discovery has been
# stable since 5.x).
#
# The path is resolved the way GRADLE does, not the way the shell does:
# $GRADLE_USER_HOME wins, and its default is <user.home>/.gradle where the JVM
# takes user.home from the PASSWD ENTRY, not from $HOME. tasks/gradle.yml
# resolves the same way (ansible_user_dir, which ansible reads out of passwd).
# Asserting on a bare $HOME would pass on a host where the role wrote the right
# file to the wrong place, and fail on one where it did the right thing.

load setup

gradle_home() {
  if [ -n "${GRADLE_USER_HOME:-}" ]; then
    printf '%s\n' "$GRADLE_USER_HOME"
    return
  fi
  local pw
  pw=$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6) || pw=""
  [ -n "$pw" ] || pw="$HOME"
  printf '%s\n' "$pw/.gradle"
}

@test "gradle: init.d directory exists" {
  command -v gradle >/dev/null 2>&1 || skip "gradle not installed (role's gradle task is no-op)"
  [ -d "$(gradle_home)/init.d" ]
}

@test "gradle: init script deployed at supply-chain-security.gradle" {
  command -v gradle >/dev/null 2>&1 || skip "gradle not installed"
  [ -f "$(gradle_home)/init.d/supply-chain-security.gradle" ]
}

@test "gradle: init script throws on HTTP repository" {
  command -v gradle >/dev/null 2>&1 || skip "gradle not installed"
  assert_file_contains "$(gradle_home)/init.d/supply-chain-security.gradle" "GradleException"
  assert_file_contains "$(gradle_home)/init.d/supply-chain-security.gradle" "http"
}

@test "gradle: gradle --version works (init script doesn't break the binary)" {
  command -v gradle >/dev/null 2>&1 || skip "gradle not installed"
  run gradle --version
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "gradle"
}

@test "gradle: init script refuses dynamic and changing versions (parity with harden.sh)" {
  command -v gradle >/dev/null 2>&1 || skip "gradle not installed"
  # action/harden.sh has always emitted these two; this file emitted only the
  # HTTP refusal until ECH-160. Guarded by respondsTo() so a gradle without the
  # methods degrades to the HTTP refusal instead of failing every build.
  assert_file_contains "$(gradle_home)/init.d/supply-chain-security.gradle" "failOnDynamicVersions"
  assert_file_contains "$(gradle_home)/init.d/supply-chain-security.gradle" "failOnChangingVersions"
  assert_file_contains "$(gradle_home)/init.d/supply-chain-security.gradle" "respondsTo"
}

@test "gradle: ECH-171 — HTTP refusal covers buildscript, pluginManagement and ivy, not just project repos" {
  command -v gradle >/dev/null 2>&1 || skip "gradle not installed"
  # The old script covered only allprojects.repositories + MavenArtifactRepository,
  # so http:// in buildscript{} (the plugin classpath, EXECUTED at configuration
  # time), settings pluginManagement{} and ivy{} passed silently. Behaviorally
  # verified on gradle 8.14.3 that these scopes are now refused; asserted by
  # content here (the role's test image has no gradle to run a build under).
  local f
  f="$(gradle_home)/init.d/supply-chain-security.gradle"
  assert_file_contains "$f" "buildscript.repositories"
  assert_file_contains "$f" "beforeSettings"
  assert_file_contains "$f" "pluginManagement.repositories"
  assert_file_contains "$f" "IvyArtifactRepository"
}

# Offline: a 1.+ selector on a SCRIPT classpath, resolved from a file:// repo
# that holds com.example:probe:1.0 (with maven-metadata.xml, so 1.+ CAN
# resolve). Plugins resolve into script classpaths: a project's
# buildscript.configurations for plugins{} / buildscript{} in build.gradle, the
# settings script's for the same blocks in settings.gradle. Only the deployed
# init script is in play: gradle loads it from the gradle user home.
# $1 = selector (1.+ or 1.0), $2 = where the buildscript{} block goes
# (project|settings)
gradle_script_classpath_run() {
  local t r bs
  t=$(mktemp -d)
  r="$t/repo/com/example/probe"
  mkdir -p "$r/1.0" "$t/proj"
  cat > "$r/maven-metadata.xml" <<'X'
<?xml version="1.0" encoding="UTF-8"?>
<metadata><groupId>com.example</groupId><artifactId>probe</artifactId>
<versioning><latest>1.0</latest><release>1.0</release><versions><version>1.0</version></versions><lastUpdated>20200101000000</lastUpdated></versioning></metadata>
X
  printf '%s' '<project xmlns="http://maven.apache.org/POM/4.0.0"><modelVersion>4.0.0</modelVersion><groupId>com.example</groupId><artifactId>probe</artifactId><version>1.0</version></project>' \
    > "$r/1.0/probe-1.0.pom"
  # A valid empty zip: EOCD is exactly 22 bytes.
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
  ( cd "$t/proj" && timeout 300 gradle --offline --no-daemon -q --console=plain help 2>&1 )
  local rc=$?
  rm -rf "$t"
  return $rc
}

@test "gradle: a dynamic version on the plugin classpath is refused, in build and settings scripts (CMP 4.6)" {
  command -v gradle >/dev/null 2>&1 || skip "gradle not installed"
  # failOn* covered allprojects{configurations} only, which does not reach the
  # script classpaths plugins resolve into. MEASURED (gradle 8.14.3 and 9.1.0,
  # role script at 8281a6b): a 1.+ plugin resolved and its code RAN from
  # plugins{}, buildscript{}, and both blocks in settings.gradle.
  local f where
  f="$(gradle_home)/init.d/supply-chain-security.gradle"
  assert_file_contains "$f" "buildscript.configurations.all(refuseDynamic)"
  assert_file_contains "$f" "settings.buildscript.configurations.all(refuseDynamic)"
  for where in project settings; do
    run gradle_script_classpath_run '1.+' "$where"
    echo "[$where] $output" | grep -iE 'dynamic|wrong|error' | head -5
    [ "$status" -ne 0 ]
    echo "$output" | grep -q 'Resolution strategy disallows usage of dynamic versions'
  done
}

@test "gradle: FIXTURE CONTROL — the same script classpath with a static 1.0 resolves" {
  command -v gradle >/dev/null 2>&1 || skip "gradle not installed"
  # Without this, a fixture gradle could not resolve at all would pass the
  # test above on any error; the assertion there also names the refusal.
  local where
  for where in project settings; do
    run gradle_script_classpath_run '1.0' "$where"
    echo "[$where] $output" | head -5
    [ "$status" -eq 0 ]
  done
}
