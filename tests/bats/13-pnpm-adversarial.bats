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

@test "BEHAVIORAL: pnpm block-exotic-subdeps refuses tarball/http deps before network" {
  # File-content tests in 01-config-files.bats assert block-exotic-subdeps=true
  # is written to ~/.config/pnpm/rc. This test verifies pnpm actually honors
  # the key — same shape as the npm allow-git=none behavioral test in
  # 03-npm.bats. Distinguishes "pnpm refused before network" (enforcement
  # working) from "pnpm attempted DNS" (key silently ignored).
  cd /tmp && rm -rf pnpm-exotic-test && mkdir pnpm-exotic-test && cd pnpm-exotic-test
  pnpm init >/dev/null 2>&1
  # Tarball URL pointing at a non-resolvable host. If block-exotic-subdeps
  # is honored, pnpm refuses without DNS. If silently ignored, pnpm tries
  # the fetch and surfaces ENOTFOUND / getaddrinfo errors.
  result=$(pnpm add "https://does-not-resolve.invalid/pkg.tgz" 2>&1 || true)
  rm -rf /tmp/pnpm-exotic-test

  if echo "$result" | grep -qiE "ENOTFOUND|ENETUNREACH|getaddrinfo|could not resolve|getaddrinfo ENOTFOUND"; then
    echo "FAIL: pnpm attempted DNS for the exotic dep — block-exotic-subdeps NOT enforced" >&2
    echo "--- pnpm output ---" >&2
    echo "$result" >&2
    return 1
  fi
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
