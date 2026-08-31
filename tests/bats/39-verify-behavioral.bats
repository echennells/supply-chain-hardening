#!/usr/bin/env bats
# supply-chain-verify: does the verifier actually catch a silently-broken
# protection, or does it just print a reassuring table?
#
# This suite deliberately does NOT assert "everything is OK on this host" —
# that would be a tautology test of the same kind that let six silent no-ops
# ship. It stages the real failure shapes with stand-in binaries on PATH and
# asserts the verifier reports a GAP for each one.

load setup

VERIFY=/usr/local/bin/supply-chain-verify

setup() {
  FAKEBIN="$BATS_TEST_TMPDIR/fakebin"
  mkdir -p "$FAKEBIN"
}

@test "verify: the command is deployed and executable" {
  [ -x "$VERIFY" ]
}

@test "verify: runs and emits the evidence-strength legend" {
  run "$VERIFY"
  # rc is 0 or 1 depending on the host; both are valid outcomes.
  echo "$output" | grep -q "STATUS"
  echo "$output" | grep -q "EVIDENCE"
  # The legend is load-bearing: a row's meaning depends on how it was proven.
  echo "$output" | grep -q "FUNCTIONAL = observed behavior"
  echo "$output" | grep -q "PARSED = the tool reported the"
}

@test "verify: --help works without running any probe" {
  run "$VERIFY" --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -qi "evidence strength"
}

@test "verify: BEHAVIORAL — catches yarn's npmMinimalAgeGate parsing to NaN" {
  # The c9a250f bug. The config file said exactly what we intended; yarn
  # parsed "2d" to NaN and applied no gate at all, with no warning. Grepping
  # our own file could never catch this. Asking yarn could.
  cat > "$FAKEBIN/yarn" <<'EOF'
#!/bin/bash
[ "$1" = "--version" ] && { echo "4.10.3"; exit 0; }
if [ "$1" = "config" ] && [ "$2" = "get" ]; then
  case "$3" in
    npmMinimalAgeGate) echo "NaN" ;;
    enableScripts)     echo "false" ;;
  esac
fi
EOF
  chmod +x "$FAKEBIN/yarn"
  PATH="$FAKEBIN:$PATH" run "$VERIFY"
  echo "$output" | grep -q "yarn age gate"
  echo "$output" | grep "yarn age gate" | grep -q "GAP"
  [ "$status" -eq 1 ]
}

@test "verify: BEHAVIORAL — catches an npq that is installed but suppressed" {
  # The bug QA found. npq fails OPEN below Node 20.13.0: one line to stderr,
  # passthrough to the real package manager, exit 0. Presence checks report
  # full coverage in exactly this state.
  cat > "$FAKEBIN/npq-hero" <<'EOF'
#!/bin/bash
echo "error: npq suppressed due to old node version" >&2
echo "9.2.0"
exit 0
EOF
  chmod +x "$FAKEBIN/npq-hero"
  PATH="$FAKEBIN:$PATH" run "$VERIFY"
  echo "$output" | grep "npq reputation checks" | grep -q "GAP"
  echo "$output" | grep "npq reputation checks" | grep -q "SUPPRESSED"
  [ "$status" -eq 1 ]
}

@test "verify: BEHAVIORAL — catches yarn 1.x ignoring .yarnrc.yml entirely" {
  cat > "$FAKEBIN/yarn" <<'EOF'
#!/bin/bash
[ "$1" = "--version" ] && { echo "1.22.22"; exit 0; }
EOF
  chmod +x "$FAKEBIN/yarn"
  PATH="$FAKEBIN:$PATH" run "$VERIFY"
  echo "$output" | grep "yarn hardening" | grep -q "GAP"
  [ "$status" -eq 1 ]
}

@test "verify: a working yarn is reported OK, so GAP is not the default answer" {
  # Counterweight to the tests above. A verifier that reports GAP for
  # everything would pass all of them and be useless.
  cat > "$FAKEBIN/yarn" <<'EOF'
#!/bin/bash
[ "$1" = "--version" ] && { echo "4.10.3"; exit 0; }
if [ "$1" = "config" ] && [ "$2" = "get" ]; then
  case "$3" in
    npmMinimalAgeGate) echo "2880" ;;
    enableScripts)     echo "false" ;;
  esac
fi
EOF
  chmod +x "$FAKEBIN/yarn"
  PATH="$FAKEBIN:$PATH" run "$VERIFY"
  echo "$output" | grep "yarn age gate" | grep -q "OK"
  echo "$output" | grep "yarn age gate" | grep -q "2880"
}

@test "verify: wrapper rows are labeled PRESENT, never counted as enforcement" {
  # PATH wrappers are the weakest evidence in the role: existence says nothing
  # about whether callers resolve through them. If a wrapper row ever claims
  # FUNCTIONAL, the evidence taxonomy has been undermined.
  run "$VERIFY"
  wrapper_rows=$(echo "$output" | grep "PATH wrapper" || true)
  if [ -n "$wrapper_rows" ]; then
    ! echo "$wrapper_rows" | grep -q "FUNCTIONAL"
  fi
}

@test "verify: BEHAVIORAL — an npm that ECHOES an unimplemented key is a GAP, not OK" {
  # The false positive this script itself shipped. `npm config get <key>`
  # returns whatever is in the config for ANY key, implemented or not:
  #
  #   $ echo 'this-key-does-not-exist=hello' >> ~/.npmrc
  #   $ npm config get this-key-does-not-exist
  #   hello
  #
  # So on npm 10.9.8 the verifier reported "OK PARSED npm age gate" for
  # min-release-age, a feature that did not land until npm 11.10.0 — a green
  # row for a protection doing nothing, which is the exact failure the whole
  # script exists to catch. CI showed this OK on Node 20 and 22 while passing.
  #
  # This stand-in reproduces the shape: it echoes our value normally, but has
  # no built-in default when asked with config and env stripped.
  cat > "$FAKEBIN/npm" <<'EOF'
#!/bin/bash
[ "$1" = "--version" ] && { echo "10.9.8"; exit 0; }
clean=0
for a in "$@"; do case "$a" in --userconfig=*|--globalconfig=*) clean=1 ;; esac; done
if [ "$1" = "config" ] && [ "$2" = "get" ]; then
  case "$3" in
    min-release-age)
      # implemented? no. clean query must reveal that.
      if [ "$clean" = "1" ]; then echo "undefined"; else echo "2"; fi ;;
    ignore-scripts)
      if [ "$clean" = "1" ]; then echo "false"; else echo "true"; fi ;;
    *) echo "undefined" ;;
  esac
fi
EOF
  chmod +x "$FAKEBIN/npm"
  PATH="$FAKEBIN:$PATH" run "$VERIFY"
  # the age gate must be reported as a GAP despite npm echoing "2"
  echo "$output" | grep "npm age gate" | grep -q "GAP"
  echo "$output" | grep "npm age gate" | grep -q "does NOT implement"
  # ...while a genuinely implemented key on the same tool still reads OK,
  # so this is discrimination and not blanket pessimism
  echo "$output" | grep "npm lifecycle scripts blocked" | grep -q "OK"
  [ "$status" -eq 1 ]
}

@test "verify: BEHAVIORAL — a wrapper outside /usr/local/bin is found, not reported absent" {
  # QA found the inverse of the npm false OK: a WORKING protection reported as
  # absent. Only npm and pip/pip3 deploy to /usr/local/bin — composer, deno,
  # bun and bunx are written to the DISCOVERED binary path (on stock Ubuntu
  # 24.04 that is /usr/bin/composer). The probe looked in one directory, so it
  # said "not deployed" for a wrapper that was installed and working.
  # The stand-in must mirror the real composer wrapper: it embeds
  # REAL_COMPOSER='<path>' and its recursion guard refuses unless that path is
  # executable. The verifier checks THAT embedded target — the same thing every
  # wrapper's guard checks — not a <tool>-real filename, because npm and pip
  # embed a path and never create a <tool>-real file. A fixture without the
  # embed is not a faithful wrapper (and its own guard would refuse).
  cat > "$FAKEBIN/composer" <<EOF
#!/bin/bash
# supply-chain-hardening wrapper
REAL_COMPOSER='$FAKEBIN/composer-real'
[ "\$1" = "--version" ] && echo "Composer version 2.9.0 2025-11-01"
EOF
  cp "$FAKEBIN/composer" "$FAKEBIN/composer-real"
  chmod +x "$FAKEBIN/composer" "$FAKEBIN/composer-real"
  PATH="$FAKEBIN:$PATH" run "$VERIFY"
  echo "$output" | grep "composer PATH wrapper" | grep -q "active at"
  ! echo "$output" | grep "composer PATH wrapper" | grep -q "not deployed"
}

@test "verify: composer audit blocking is version-tiered, not assumed" {
  # Distro composer is routinely below the floors the role targets:
  # jammy 2.2.6, bookworm 2.5.5, noble 2.7.1 — none reach the 2.9 needed for
  # audit.block-insecure / block-abandoned. Before this row existed the
  # verifier emitted nothing at all for composer, which read as "fine".
  #
  # The stand-in also answers `composer config --global --list --source`,
  # which the shared probe body (files/verify-probes.sh) requires. A version
  # at or above the 2.9 floor is a CAPABILITY claim and nothing more — the
  # probe will not call it OK until composer also reports the audit keys back
  # WITH a source file, because composer echoes any audit subkey verbatim
  # (measured on 2.7.1/2.8.12/2.10.3, invented keys included). A fixture that
  # only answers --version therefore reads as "supports it, cannot confirm
  # it", which is the honest answer and not what this test is about.
  mk() {
    cat > "$FAKEBIN/composer" <<EOF
#!/bin/bash
case "\$1" in
  --version) echo "Composer version $1 2024-01-01"; exit 0 ;;
  config)
    shift
    for a in "\$@"; do [ "\$a" = "--list" ] && { list=1; }; done
    if [ -n "\${list:-}" ]; then
      echo "[home] \$HOME/.config/composer (default)"
      echo "[secure-http] true (\$HOME/.config/composer/config.json)"
      echo "[allow-plugins] false (\$HOME/.config/composer/config.json)"
      echo "[audit.block-insecure] true (\$HOME/.config/composer/config.json)"
      echo "[audit.block-abandoned] true (\$HOME/.config/composer/config.json)"
      exit 0
    fi
    # single-key query: answer for keys composer really implements, so the
    # verifier's composer_implements() discriminator behaves as designed
    for a in "\$@"; do
      case "\$a" in secure-http|allow-plugins) echo true; exit 0 ;; esac
    done
    exit 1 ;;
esac
exit 1
EOF
    chmod +x "$FAKEBIN/composer"
  }

  mk 2.9.0
  PATH="$FAKEBIN:$PATH" run "$VERIFY"
  echo "$output" | grep "composer audit blocking" | grep -q "OK"

  mk 2.7.1
  PATH="$FAKEBIN:$PATH" run "$VERIFY"
  echo "$output" | grep "composer audit blocking" | grep -q "GAP"

  mk 2.2.6
  PATH="$FAKEBIN:$PATH" run "$VERIFY"
  echo "$output" | grep "composer audit blocking" | grep -q "below 2.7"
}
