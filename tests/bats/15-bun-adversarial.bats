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

@test "BEHAVIORAL: bun auto=\"disable\" refuses runtime auto-install" {
  # File-content test in 01-config-files.bats asserts `auto = "disable"` is
  # in ~/.bunfig.toml. This test verifies bun actually honors it. Bun's
  # default `auto = "auto"` would silently `bun add` a missing import at
  # runtime — a supply-chain hole because the package is fetched without
  # the user reviewing the lockfile or composer.json. With auto=disable,
  # bun must fail-loud on the missing import instead.
  cd /tmp && rm -rf bun-auto-test && mkdir bun-auto-test && cd bun-auto-test
  # Pick a real, small, harmless package that's NOT in this dir's
  # node_modules. cowsay is a stable, dependency-free package that bun
  # would happily auto-install if the setting were ignored.
  cat > script.ts <<'EOF'
import cowsay from "cowsay";
console.log(cowsay.say({ text: "auto-install fired" }));
EOF
  echo '{"name":"bun-auto-test"}' > package.json
  result=$(bun run script.ts 2>&1 || true)
  has_node_modules=$([ -d node_modules ] && echo "yes" || echo "no")
  rm -rf /tmp/bun-auto-test

  # If auto=disable is honored, bun fails to resolve cowsay and exits
  # non-zero with a "Cannot find" or "Could not resolve" message; no
  # node_modules is created.
  if [ "$has_node_modules" = "yes" ]; then
    echo "FAIL: bun created node_modules — auto-install fired despite auto=disable" >&2
    echo "--- bun output ---" >&2
    echo "$result" >&2
    return 1
  fi
  # Sanity check: the failure should be a resolution error, not e.g. a
  # syntax error in the test script.
  echo "$result" | grep -qiE "cannot find|could not resolve|not found|cowsay" \
    || { echo "UNEXPECTED bun output (neither resolved nor failed-as-expected):" >&2; echo "$result" >&2; return 1; }
}
