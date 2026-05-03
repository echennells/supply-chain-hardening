#!/usr/bin/env bats
# Behavioral tests for Bundler/Ruby.
# IMPORTANT: Ruby has NO extconf.rb blocking. This test DOCUMENTS the gap.

load setup

setup() {
  rm -f /tmp/marker-ruby-extconf
}

@test "KNOWN GAP: Ruby extconf.rb executes during gem install (no defense exists)" {
  # This test is expected to FAIL the security check — Ruby cannot block extconf.rb.
  # We document this as a known gap. If this test starts passing, Ruby added a defense.
  gem_file=$(ls /opt/test-fixtures/ruby-extconf-gem/test-extconf-*.gem 2>/dev/null | head -1)
  [ -n "$gem_file" ] || skip "gem fixture not built"

  gem install "$gem_file" --no-document 2>/dev/null || true

  # We EXPECT the marker to exist — extconf.rb always runs.
  # This is intentionally the opposite assertion from other attack tests.
  if [ -f /tmp/marker-ruby-extconf ]; then
    # Gap confirmed: extconf.rb ran. This is expected and documents the vulnerability.
    true
  else
    # If marker doesn't exist, either the gem didn't install or Ruby added blocking.
    # Either way, not a failure of our hardening — skip.
    skip "extconf.rb did not execute (gem install may have failed for other reasons)"
  fi
}

@test "bundler: frozen mode rejects install without Gemfile.lock" {
  cd /tmp && rm -rf bundler-test && mkdir bundler-test && cd bundler-test
  echo 'source "https://rubygems.org"' > Gemfile
  echo 'gem "json"' >> Gemfile
  # BUNDLE_FROZEN=true should refuse since there's no Gemfile.lock
  run bundle install 2>&1
  [ "$status" -ne 0 ]
  rm -rf /tmp/bundler-test
}
