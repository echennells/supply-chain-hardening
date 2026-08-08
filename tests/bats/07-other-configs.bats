#!/usr/bin/env bats

load setup

@test "composer: secure-http true" {
  assert_file_contains "$HOME/.config/composer/config.json" "secure-http"
}

@test "composer: preferred-install dist" {
  assert_file_contains "$HOME/.config/composer/config.json" "dist"
}

@test "bundler: BUNDLE_DISABLE_EXEC_LOAD true" {
  assert_file_contains "$HOME/.bundle/config" 'BUNDLE_DISABLE_EXEC_LOAD: "true"'
}

@test "cargo: git-fetch-with-cli = true" {
  assert_file_contains "$HOME/.cargo/config.toml" "git-fetch-with-cli = true"
}

# npq's aliases are deployed only when npq actually FUNCTIONS. npq bails out
# on Node < 20.13.0 by printing one line to stderr, passing through to the
# real package manager, and exiting 0 — so a present-but-suppressed npq vets
# nothing while `alias npm='npq-hero'` presents it as the protection layer.
# These tests therefore assert the file's presence conditionally, and assert
# its ABSENCE on hosts where npq cannot work. A test that unconditionally
# demanded the file would force the role back into deploying false coverage.
npq_is_functional() {
  command -v npq-hero >/dev/null 2>&1 || return 1
  ! npq-hero --version 2>&1 | grep -qi 'npq suppressed'
}

@test "npq aliases exist in profile.d (only when npq functions)" {
  if npq_is_functional; then
    assert_file_exists /etc/profile.d/npq-aliases.sh
  else
    # Must be absent — including on upgrade, where an earlier role version
    # deployed it before the functional check existed.
    [ ! -f /etc/profile.d/npq-aliases.sh ]
  fi
}

@test "npq: npm alias routes through npq-hero" {
  npq_is_functional || skip "npq non-functional on this Node ($(node --version 2>/dev/null)); aliases intentionally not deployed"
  assert_file_contains /etc/profile.d/npq-aliases.sh "alias npm='npq-hero'"
}

@test "npq: NPQ_DISABLE_AUTO_CONTINUE=true" {
  npq_is_functional || skip "npq non-functional on this Node ($(node --version 2>/dev/null)); aliases intentionally not deployed"
  assert_file_contains /etc/profile.d/npq-aliases.sh "NPQ_DISABLE_AUTO_CONTINUE=true"
}

@test "npq: BEHAVIORAL — an installed npq that is suppressed must not count as coverage" {
  # The regression this locks in. npq fails OPEN: `npq-hero install x` on an
  # unsupported Node prints a warning, runs plain npm, and exits 0. Detection
  # by `which npq-hero` (what the role used to do) reports full coverage in
  # exactly that state, and the coverage summary inherited the lie.
  #
  # Asserts the invariant rather than the environment: wherever npq is
  # present, its functional status and the alias file's presence agree.
  command -v npq-hero >/dev/null 2>&1 || skip "npq not installed on this host"
  if npq_is_functional; then
    [ -f /etc/profile.d/npq-aliases.sh ]
  else
    [ ! -f /etc/profile.d/npq-aliases.sh ]
    # and the gap must be reported, not silent — see tasks/npq.yml
    grep -q "npq requires Node >= 20.13.0" "$ROLE_DIR/tasks/npq.yml"
  fi
}
