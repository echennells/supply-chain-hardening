#!/usr/bin/env bats
# Behavioral tests for Maven supply-chain hardening.
#
# The role's tasks/maven.yml is config-only — gates on mvn OR a JDK (a
# ./mvnw build needs only java; CMP 4.5, tested in
# 25-integration-regressions.bats), then deploys ~/.m2/settings.xml with an
# HTTPS-only central mirror
# and strict (`fail`) checksum policy. These tests verify the config
# was deployed correctly and that mvn can still execute. Matrix mode
# runs these per (java, maven) cell to confirm the config is read
# correctly across maven versions.
#
# ~ here is the passwd home of the uid, where maven reads it (user.home), not
# $HOME: tasks/passwd_home.yml, and 56-home-paths.bats for a HOME elsewhere.

load setup

maven_settings() {
  local pw
  pw=$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6) || pw=""
  case "$pw" in /?*) [ -d "$pw" ] && [ -w "$pw" ] || pw="" ;; *) pw="" ;; esac
  printf '%s\n' "${pw:-$HOME}/.m2/settings.xml"
}

@test "maven: ~/.m2/settings.xml exists" {
  command -v mvn >/dev/null 2>&1 || skip "mvn not installed (role's maven task is no-op)"
  [ -f "$(maven_settings)" ]
}

@test "maven: settings.xml forces HTTPS-only central mirror" {
  command -v mvn >/dev/null 2>&1 || skip "mvn not installed"
  assert_file_contains "$(maven_settings)" "https://repo.maven.apache.org/maven2"
  # Belt-and-suspenders: no <url>http://...</url> repository URL allowed.
  # Scoping to <url> tags only (not bare http://) because the file's
  # XML namespace declarations (xmlns, xsi:schemaLocation) contain
  # http:// URIs by W3C convention — those are identifiers, not fetched,
  # and matching them was the previous regex's bug.
  ! grep -qE "<url>[^<]*http://" "$(maven_settings)" || false
}

@test "maven: settings.xml enforces strict checksum policy" {
  command -v mvn >/dev/null 2>&1 || skip "mvn not installed"
  assert_file_contains "$(maven_settings)" "<checksumPolicy>fail</checksumPolicy>"
}

@test "maven: mvn --version works (config doesn't break the binary)" {
  command -v mvn >/dev/null 2>&1 || skip "mvn not installed"
  run mvn --version
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "apache maven"
}

# Maven keeps TWO repository lists — <repositories> (dependencies) and
# <pluginRepositories> (plugins) — and the super POM declares `central` in
# both. A policy set on only one list leaves the other on Maven's defaults.
# Exits non-zero naming every central entry, in an ACTIVE profile, that does
# not refuse a checksum mismatch or that re-enables snapshot lookups.
maven_central_policy_problems() { # $1 = settings.xml
  python3 -I - "$1" <<'PY'
import sys, xml.etree.ElementTree as E
root = E.parse(sys.argv[1]).getroot()
for el in root.iter():
    el.tag = el.tag.split('}')[-1]
active = {a.text.strip() for a in root.findall('activeProfiles/activeProfile') if a.text}
bad = []
for kind in ('repositories/repository', 'pluginRepositories/pluginRepository'):
    hits = [r for p in root.findall('profiles/profile')
            if (p.findtext('id') or '').strip() in active
            for r in p.findall(kind) if (r.findtext('id') or '').strip() == 'central']
    if not hits:
        bad.append(kind + ': no central entry in an active profile')
    for r in hits:
        if (r.findtext('releases/checksumPolicy') or '').strip() != 'fail':
            bad.append(kind + ': central releases checksumPolicy is not fail')
        if (r.findtext('snapshots/enabled') or '').strip() != 'false':
            bad.append(kind + ': central snapshots are not disabled')
print('\n'.join(bad))
sys.exit(1 if bad else 0)
PY
}

@test "maven: plugin repositories refuse a checksum mismatch too, and Central snapshots stay off (CMP 4.4)" {
  command -v mvn >/dev/null 2>&1 || skip "mvn not installed"
  # The role set checksumPolicy=fail under <repositories> only, so plugin jars
  # (code that runs inside the build) kept the default 'warn'. MEASURED on
  # maven 3.9.11 with a plugin jar served under a wrong .sha1: two WARNINGs
  # and BUILD SUCCESS, the tampered maven-compiler-plugin ran. The same
  # redefinition dropped the super POM's <snapshots><enabled>false</enabled>.
  run maven_central_policy_problems "$(maven_settings)"
  echo "$output"
  [ "$status" -eq 0 ]
}

# Offline: a plugin whose jar does not match its .sha1, in a file:// "Central".
# Maven validates checksums for file:// repositories as for https (MEASURED,
# 3.9.11), so no network or TLS is involved. The deployed settings are copied
# with every Central URL pointed at the fixture, which keeps their structure —
# the mirror, the profile, both repository lists — exactly as deployed.
# $1 = deployed settings.xml, $2 = good|bad (.sha1 of the plugin jar)
maven_plugin_checksum_run() {
  local t r
  t=$(mktemp -d)
  r="$t/central/com/example/fake-maven-plugin/1.0"
  mkdir -p "$r" "$t/proj"
  cat > "$r/fake-maven-plugin-1.0.pom" <<'X'
<project xmlns="http://maven.apache.org/POM/4.0.0"><modelVersion>4.0.0</modelVersion>
<groupId>com.example</groupId><artifactId>fake-maven-plugin</artifactId><version>1.0</version><packaging>maven-plugin</packaging></project>
X
  # A valid empty zip: EOCD is exactly 22 bytes.
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
  rm -rf "$t"
}

@test "maven: a plugin jar with a wrong checksum is refused at download, not warned about (CMP 4.4)" {
  command -v mvn >/dev/null 2>&1 || skip "mvn not installed"
  run maven_plugin_checksum_run "$(maven_settings)" bad
  echo "$output" | grep -E 'Checksum|ERROR' | head -5
  # The refusal itself, at ERROR level, for the plugin jar — not the warning
  # Maven prints under its default 'warn' policy before installing the jar.
  echo "$output" | grep -qE '^\[ERROR\].*fake-maven-plugin:jar:1\.0.*Checksum validation failed'
  ! echo "$output" | grep -q 'No plugin descriptor found'
}

@test "maven: FIXTURE CONTROL — the same plugin with a correct checksum gets past download" {
  command -v mvn >/dev/null 2>&1 || skip "mvn not installed"
  # Without this, a fixture Maven never fetched would pass the test above. The
  # empty jar has no plugin descriptor, so getting that far means the jar was
  # downloaded and accepted from the file:// Central.
  run maven_plugin_checksum_run "$(maven_settings)" good
  echo "$output" | grep -E 'Checksum|ERROR' | head -5
  echo "$output" | grep -q 'No plugin descriptor found'
  ! echo "$output" | grep -q 'Checksum validation failed'
}
