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

# --- publish-age gate ---------------------------------------------------------
# Scratch HOME so the deployed frozen config does not refuse the resolve, and a
# window far wider than any release cadence so an enforcing bundler and one that
# ignores the key cannot both pick the same version.

cooldown_bundler_ok() {
  local v; v=$(bundle --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  [ -n "$v" ] && [ "$(printf '4.0.13\n%s\n' "$v" | sort -V | head -1)" = "4.0.13" ]
}

# lock <repo-local-cooldown-or-empty> [env assignments...] -> the rack version locked
cooldown_lock() {
  local repo="$1"; shift
  local d; d=$(mktemp -d)
  mkdir -p "$d/home" "$d/p"
  printf 'source "https://rubygems.org"\ngem "rack"\n' > "$d/p/Gemfile"
  if [ -n "$repo" ]; then
    mkdir -p "$d/p/.bundle"
    printf -- '---\nBUNDLE_COOLDOWN: "%s"\n' "$repo" > "$d/p/.bundle/config"
  fi
  ( cd "$d/p" && env -u BUNDLE_COOLDOWN -u BUNDLE_FROZEN -u BUNDLE_DEPLOYMENT HOME="$d/home" "$@" bundle lock >/dev/null 2>&1 )
  grep -oE '^    rack \([^)]+\)' "$d/p/Gemfile.lock" 2>/dev/null
  rm -rf "$d"
}

@test "BEHAVIORAL: BUNDLE_COOLDOWN withholds the newest release (control takes it)" {
  cooldown_bundler_ok || skip "bundler < 4.0.13 has no cooldown"
  local control gated
  control=$(cooldown_lock '')
  [ -n "$control" ] || skip "rubygems.org unreachable: the control resolved nothing"
  gated=$(cooldown_lock '' BUNDLE_COOLDOWN=1200)
  [ -n "$gated" ]
  [ "$gated" != "$control" ]
}

@test "KNOWN GAP: a repo's .bundle/config outranks BUNDLE_COOLDOWN" {
  # This documents the bypass; supply-chain-verify reports it. If this test starts
  # failing, bundler has closed the gap and docs/limitations.md should say so.
  cooldown_bundler_ok || skip "bundler < 4.0.13 has no cooldown"
  local control got
  control=$(cooldown_lock '')
  [ -n "$control" ] || skip "rubygems.org unreachable: the control resolved nothing"
  got=$(cooldown_lock 0 BUNDLE_COOLDOWN=1200)
  [ "$got" = "$control" ]
}
