#!/usr/bin/env bats
# Adversarial tests for Bun: verify lifecycle scripts are blocked.

load setup

setup() {
  rm -f /tmp/marker-postinstall /tmp/marker-ssh-exfil /tmp/marker-preinstall
}

@test "ATTACK: bun postinstall is blocked" {
  cd /tmp && rm -rf bun-attack-test && mkdir bun-attack-test && cd bun-attack-test
  echo '{"name":"bun-test"}' > package.json
  bun install /opt/test-fixtures/npm-postinstall-pkg 2>/dev/null || true
  [ ! -f /tmp/marker-postinstall ]
  rm -rf /tmp/bun-attack-test
}

@test "ATTACK: bun SSH key exfiltration is blocked" {
  cd /tmp && rm -rf bun-attack-test && mkdir bun-attack-test && cd bun-attack-test
  echo '{"name":"bun-test"}' > package.json
  bun install /opt/test-fixtures/npm-read-ssh-keys 2>/dev/null || true
  [ ! -f /tmp/marker-ssh-exfil ]
  rm -rf /tmp/bun-attack-test
}

@test "ATTACK: bun preinstall hook is blocked" {
  cd /tmp && rm -rf bun-attack-test && mkdir bun-attack-test && cd bun-attack-test
  echo '{"name":"bun-test"}' > package.json
  bun install /opt/test-fixtures/npm-preinstall-script 2>/dev/null || true
  [ ! -f /tmp/marker-preinstall ]
  rm -rf /tmp/bun-attack-test
}

@test "BEHAVIORAL: bun PATH wrapper blocks runtime auto-install on bun run" {
  # The /usr/local/bin/bun WRAPPER (not ~/.bunfig.toml — see commit
  # history for why) is what closes the runtime auto-install gap. Per
  # bun's docs, the global bunfig is NOT consulted for `bun run`, so
  # `auto = "disable"` in ~/.bunfig.toml is silently ignored by this
  # code path. The wrapper injects --no-install on every non-package-
  # management invocation, which IS honored by `bun run`.
  #
  # This test verifies the wrapper's behavior end-to-end: import a
  # known-good harmless package that's NOT in node_modules, run via
  # `bun run`, assert the wrapper makes bun fail-loud instead of
  # silently downloading.
  cd /tmp && rm -rf bun-auto-test && mkdir bun-auto-test && cd bun-auto-test
  cat > script.ts <<'EOF'
import isPositive from "is-positive";
console.log("auto-install fired");
EOF
  echo '{"name":"bun-auto-test"}' > package.json
  result=$(bun run script.ts 2>&1 || true)
  has_node_modules=$([ -d node_modules ] && echo "yes" || echo "no")
  rm -rf /tmp/bun-auto-test

  # Wrapper-honored case: bun fails to resolve, no node_modules is
  # created. If node_modules exists, the wrapper failed to inject
  # --no-install OR bun ignored the flag.
  if [ "$has_node_modules" = "yes" ]; then
    echo "FAIL: bun created node_modules — wrapper did not block auto-install" >&2
    echo "--- bun output ---" >&2
    echo "$result" >&2
    return 1
  fi
  # Sanity check: the failure should be a resolution error, not a
  # syntax error or other unexpected failure.
  echo "$result" | grep -qiE "cannot find|could not resolve|not found|is-positive" \
    || { echo "UNEXPECTED bun output (neither resolved nor failed-as-expected):" >&2; echo "$result" >&2; return 1; }
}

@test "FIXTURE CONTROL: bun-real CAN auto-install (proves the wrapper is what's blocking)" {
  # Counterpart to the BEHAVIORAL test above. Runs the same script
  # using bun-real (the wrapper-bypassed original binary). The auto-
  # install SHOULD fire here, proving:
  #   1. The test fixture is real — the script does import a missing
  #      package and bun's default behavior IS to auto-install it
  #   2. The wrapper above is what's blocking, not some unrelated
  #      environment artifact (no node_modules in CWD, network
  #      unavailable, etc.)
  # If this test fails, the BEHAVIORAL test above may be a tautology.
  [ -x /usr/local/bin/bun-real ] || skip "bun-real not present (bun_path_wrapper may be false)"

  cd /tmp && rm -rf bun-control-test && mkdir bun-control-test && cd bun-control-test
  cat > script.ts <<'EOF'
import isPositive from "is-positive";
console.log("auto-install fired");
EOF
  echo '{"name":"bun-control-test"}' > package.json
  # Use env -i to strip any wrapper-relevant env vars (NPM_*, etc.).
  # Use HOME=/tmp/bun-control-test so ~/.bunfig.toml from the deploying
  # user doesn't leak in — though even with leakage, ~/.bunfig.toml
  # doesn't affect `bun run` per bun's docs, so this is belt-and-
  # suspenders for test isolation.
  result=$(env -i HOME=/tmp/bun-control-test PATH=/usr/local/bin:/usr/bin:/bin \
    /usr/local/bin/bun-real run script.ts 2>&1 || true)
  has_node_modules=$([ -d node_modules ] && echo "yes" || echo "no")
  rm -rf /tmp/bun-control-test

  # Default bun behavior IS to auto-install. node_modules should appear
  # OR the script should succeed (output "auto-install fired"). Either
  # signals the fixture would have fired in the absence of hardening.
  if [ "$has_node_modules" = "no" ] && ! echo "$result" | grep -q "auto-install fired"; then
    echo "FAIL: bun-real didn't auto-install — fixture may be broken or environment is preventing install" >&2
    echo "(if this fails consistently, the BEHAVIORAL test above is tautological)" >&2
    echo "--- bun-real output ---" >&2
    echo "$result" >&2
    return 1
  fi
}
