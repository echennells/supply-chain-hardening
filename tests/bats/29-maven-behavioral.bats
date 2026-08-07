#!/usr/bin/env bats
# Behavioral tests for Maven supply-chain hardening.
#
# The role's tasks/maven.yml is config-only — gates on `which mvn`,
# then deploys ~/.m2/settings.xml with an HTTPS-only central mirror
# and strict (`fail`) checksum policy. These tests verify the config
# was deployed correctly and that mvn can still execute. Matrix mode
# runs these per (java, maven) cell to confirm the config is read
# correctly across maven versions.

load setup

@test "maven: ~/.m2/settings.xml exists" {
  command -v mvn >/dev/null 2>&1 || skip "mvn not installed (role's maven task is no-op)"
  [ -f "$HOME/.m2/settings.xml" ]
}

@test "maven: settings.xml forces HTTPS-only central mirror" {
  command -v mvn >/dev/null 2>&1 || skip "mvn not installed"
  assert_file_contains "$HOME/.m2/settings.xml" "https://repo.maven.apache.org/maven2"
  # Belt-and-suspenders: no <url>http://...</url> repository URL allowed.
  # Scoping to <url> tags only (not bare http://) because the file's
  # XML namespace declarations (xmlns, xsi:schemaLocation) contain
  # http:// URIs by W3C convention — those are identifiers, not fetched,
  # and matching them was the previous regex's bug.
  ! grep -qE "<url>[^<]*http://" "$HOME/.m2/settings.xml"
}

@test "maven: settings.xml enforces strict checksum policy" {
  command -v mvn >/dev/null 2>&1 || skip "mvn not installed"
  assert_file_contains "$HOME/.m2/settings.xml" "<checksumPolicy>fail</checksumPolicy>"
}

@test "maven: mvn --version works (config doesn't break the binary)" {
  command -v mvn >/dev/null 2>&1 || skip "mvn not installed"
  run mvn --version
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "apache maven"
}
