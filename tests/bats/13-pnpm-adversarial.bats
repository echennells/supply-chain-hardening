#!/usr/bin/env bats
# Adversarial tests for pnpm: verify lifecycle scripts are blocked.

load setup

setup() {
  rm -f /tmp/marker-postinstall /tmp/marker-ssh-exfil /tmp/marker-preinstall
}

@test "ATTACK: pnpm postinstall is blocked" {
  cd /tmp && rm -rf pnpm-attack-test && mkdir pnpm-attack-test && cd pnpm-attack-test
  pnpm init >/dev/null 2>&1
  pnpm install /opt/test-fixtures/npm-postinstall-pkg 2>/dev/null || true
  [ ! -f /tmp/marker-postinstall ]
  rm -rf /tmp/pnpm-attack-test
}

@test "ATTACK: pnpm SSH key exfiltration is blocked" {
  cd /tmp && rm -rf pnpm-attack-test && mkdir pnpm-attack-test && cd pnpm-attack-test
  pnpm init >/dev/null 2>&1
  pnpm install /opt/test-fixtures/npm-read-ssh-keys 2>/dev/null || true
  [ ! -f /tmp/marker-ssh-exfil ]
  rm -rf /tmp/pnpm-attack-test
}

@test "ATTACK: pnpm preinstall hook is blocked" {
  cd /tmp && rm -rf pnpm-attack-test && mkdir pnpm-attack-test && cd pnpm-attack-test
  pnpm init >/dev/null 2>&1
  pnpm install /opt/test-fixtures/npm-preinstall-script 2>/dev/null || true
  [ ! -f /tmp/marker-preinstall ]
  rm -rf /tmp/pnpm-attack-test
}

@test "pnpm: block-exotic-subdeps governs SUBdeps only; direct deps stay allowed (pnpm >=11)" {
  # WHAT THIS CONTROL ACTUALLY IS. pnpm's blockExoticSubdeps, per its docs:
  # "only DIRECT dependencies ... may use exotic sources (like git)". It blocks
  # a TRANSITIVE dependency that points at a git/tarball/http source; it does
  # NOT block an exotic source you list yourself. It also defaults to true in
  # pnpm 11.
  #
  # An earlier version of this test did `pnpm add <tarball-url>` — a DIRECT dep —
  # and asserted pnpm should refuse it, treating the control like npm's
  # allow-git=none. That premise is wrong: a direct exotic dep is allowed by
  # design, so pnpm attempting the fetch is CORRECT, and the test failed on
  # pnpm 11 (where the control is active) for doing the right thing.
  #
  # The real subdep-blocking behavior cannot be exercised offline — it needs a
  # registry package whose transitive dependency is exotic, which this harness
  # cannot fabricate without a fixture registry. So this asserts the two things
  # that ARE verifiable: the setting is deployed, and pnpm does not over-block a
  # legitimate direct exotic dep (a real regression guard — over-blocking would
  # break normal installs).
  pnpm_major=$(pnpm --version 2>/dev/null | sed -nE 's/^([0-9]+)\..*/\1/p' | head -1)
  [[ "$pnpm_major" =~ ^[0-9]+$ ]] || skip "couldn't parse pnpm major version"
  [[ "$pnpm_major" -ge 11 ]] || skip "blockExoticSubdeps is a pnpm >=11 control (got: $(pnpm --version 2>/dev/null))"

  # deployed
  assert_file_contains "$HOME/.config/pnpm/config.yaml" 'blockExoticSubdeps: true'

  # direct exotic dep must remain ALLOWED (pnpm reaches the network / does not
  # refuse it outright). Non-resolvable host -> a network error is the expected
  # "it tried" signal; a "not allowed / blocked / refused" message would mean
  # pnpm is wrongly blocking direct deps.
  cd /tmp && rm -rf pnpm-exotic-test && mkdir pnpm-exotic-test && cd pnpm-exotic-test
  pnpm init >/dev/null 2>&1
  result=$(pnpm add "https://does-not-resolve.invalid/pkg.tgz" 2>&1 || true)
  rm -rf /tmp/pnpm-exotic-test
  # Correct behaviour is that pnpm ATTEMPTS the fetch (direct exotic deps are
  # allowed), which against a non-resolvable host surfaces a network error.
  # Assert the attempt positively; its ABSENCE would mean pnpm wrongly refused a
  # direct dep. (The original test asserted the opposite and failed here for
  # pnpm doing the right thing.)
  if echo "$result" | grep -qiE "ENOTFOUND|ENETUNREACH|getaddrinfo|fetch failed|could not resolve"; then
    return 0
  fi
  echo "FAIL: pnpm did not attempt the direct exotic dep — unexpected refusal of a DIRECT dep" >&2
  echo "$result" >&2
  return 1
}

@test "ATTACK: pnpm project-level postinstall is blocked (pnpm 11 config.yaml regression catcher)" {
  # pnpm 11+ ignores ~/.npmrc, ~/.config/pnpm/rc, /etc/npmrc, and
  # NPM_CONFIG_* env vars for non-auth settings. ONLY ~/.config/pnpm/config.yaml
  # (YAML, camelCase) blocks scripts in pnpm 11. This test catches a
  # regression where the role stops deploying config.yaml (or deploys it
  # incorrectly): the project's own postinstall would run, just like it
  # would on a host with no hardening at all. Dependency-level scripts
  # are blocked by pnpm 11's own defaults — this test specifically
  # exercises the PROJECT-level case which the role's config controls.
  rm -f /tmp/marker-project-postinstall
  cd /tmp && rm -rf pnpm-project-attack && mkdir pnpm-project-attack && cd pnpm-project-attack
  cat > package.json <<'EOF'
{"name":"victim","version":"1.0.0","scripts":{"postinstall":"touch /tmp/marker-project-postinstall"}}
EOF
  pnpm install --ignore-workspace 2>/dev/null || true
  [ ! -f /tmp/marker-project-postinstall ]
  rm -rf /tmp/pnpm-project-attack
  rm -f /tmp/marker-project-postinstall
}
