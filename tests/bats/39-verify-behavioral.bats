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

@test "verify: BEHAVIORAL — a yarn age gate that is not a whole number is a GAP" {
  # Asking yarn what it believes, rather than grepping the file we wrote, is
  # what catches a value yarn mangled. A non-numeric answer cannot be confirmed.
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
  PATH="$FAKEBIN:$PATH" run "$VERIFY" --verbose
  echo "$output" | grep -q "yarn age gate"
  echo "$output" | grep "yarn age gate" | grep -q "GAP"
  [ "$status" -eq 1 ]
}

@test "verify: BEHAVIORAL — yarn below 4.10 is a GAP that names 4.10, not 'the NaN failure'" {
  # MEASURED (VM#10, apt yarnpkg 4.1.0): `yarn config get npmMinimalAgeGate`
  # prints a usage error on STDOUT and exits 1. Old main read that text as the
  # value and reported "non-integer npmMinimalAgeGate='UsageError:...' (this is
  # the NaN failure)": the wrong cause, for a gap only an upgrade closes.
  cat > "$FAKEBIN/yarn" <<'EOF'
#!/bin/bash
[ "$1" = "--version" ] && { echo "4.1.0"; exit 0; }
if [ "$1" = "config" ] && [ "$2" = "get" ]; then
  case "$3" in
    npmMinimalAgeGate) echo 'Usage Error: Couldn'"'"'t find a configuration settings named "npmMinimalAgeGate"'; exit 1 ;;
    enableScripts)     echo "false" ;;
  esac
fi
EOF
  chmod +x "$FAKEBIN/yarn"
  PATH="$FAKEBIN:$PATH" run "$VERIFY" --verbose
  row=$(echo "$output" | grep "yarn age gate")
  echo "$row" | grep -q "GAP"
  echo "$row" | grep -q "4.10.0"
  ! echo "$row" | grep -q "NaN"
  echo "$output" | grep "yarn lifecycle scripts blocked" | grep -q "OK"
  [ "$status" -eq 1 ]
}

@test "verify: BEHAVIORAL — yarn 4.10 reading \"2d\" as 2 minutes is below the window" {
  # MEASURED 2026-11-19: yarn 4.10.3 reads "2d" as its leading integer, so a
  # gate written as a duration is 2 minutes, and `yarn config get` says 2.
  cat > "$FAKEBIN/yarn" <<'EOF'
#!/bin/bash
[ "$1" = "--version" ] && { echo "4.10.3"; exit 0; }
if [ "$1" = "config" ] && [ "$2" = "get" ]; then
  case "$3" in
    npmMinimalAgeGate) echo "2" ;;
    enableScripts)     echo "false" ;;
  esac
fi
EOF
  chmod +x "$FAKEBIN/yarn"
  PATH="$FAKEBIN:$PATH" run "$VERIFY" --verbose
  echo "$output" | grep "yarn age gate" | grep -q "WEAK"
  echo "$output" | grep "yarn age gate" | grep -q "below the"
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
  PATH="$FAKEBIN:$PATH" run "$VERIFY" --verbose
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
  PATH="$FAKEBIN:$PATH" run "$VERIFY" --verbose
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
  PATH="$FAKEBIN:$PATH" run "$VERIFY" --verbose
  echo "$output" | grep "yarn age gate" | grep -q "OK"
  echo "$output" | grep "yarn age gate" | grep -q "2880"
}

@test "verify: wrapper FUNCTIONAL is earned by observation, never by existence" {
  # PRE-RUN-PROBE this asserted "wrapper rows are never FUNCTIONAL": existence
  # said nothing about whether callers resolve through them. The run-probe
  # changes that — it OBSERVES whether the wrapper actually ran, so a wrapper row
  # is now legitimately FUNCTIONAL ("observed running" / "did NOT run"). The
  # invariant that must still hold: FUNCTIONAL is earned by that observation and
  # NEVER claimed from mere position/existence — those stay WEAK PRESENT
  # ("predates the run-probe ... position evidence"). A regression that lets
  # existence read as FUNCTIONAL fails here.
  run "$VERIFY" --verbose
  wrapper_rows=$(echo "$output" | grep "PATH wrapper" || true)
  if [ -n "$wrapper_rows" ]; then
    ! echo "$wrapper_rows" | grep "FUNCTIONAL" | grep -qE "predates the run-probe|position evidence"
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
  PATH="$FAKEBIN:$PATH" run "$VERIFY" --verbose
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
  # A faithful CURRENT wrapper also carries the run-probe: it appends $0 to
  # $SCH_WRAPPER_PROBE so the verifier can OBSERVE it ran (a probe-less fixture
  # would resolve but read as WEAK PRESENT "predates the run-probe" — still
  # found, but this test wants the observed-running path specifically).
  cat > "$FAKEBIN/composer" <<EOF
#!/bin/bash
# supply-chain-hardening wrapper
REAL_COMPOSER='$FAKEBIN/composer-real'
if [ -n "\${SCH_WRAPPER_PROBE:-}" ]; then printf '%s\n' "\$0" >> "\$SCH_WRAPPER_PROBE" 2>/dev/null || true; fi
[ "\$1" = "--version" ] && echo "Composer version 2.9.0 2025-11-01"
EOF
  cp "$FAKEBIN/composer" "$FAKEBIN/composer-real"
  chmod +x "$FAKEBIN/composer" "$FAKEBIN/composer-real"
  PATH="$FAKEBIN:$PATH" run "$VERIFY" --verbose
  echo "$output" | grep "composer PATH wrapper" | grep -q "observed running"
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
  PATH="$FAKEBIN:$PATH" run "$VERIFY" --verbose
  echo "$output" | grep "composer audit blocking" | grep -q "OK"

  mk 2.7.1
  PATH="$FAKEBIN:$PATH" run "$VERIFY" --verbose
  echo "$output" | grep "composer audit blocking" | grep -q "GAP"

  mk 2.2.6
  PATH="$FAKEBIN:$PATH" run "$VERIFY" --verbose
  echo "$output" | grep "composer audit blocking" | grep -q "below 2.7"
}

@test "verify: npm_implements survives a version-manager shim (no false GAP under env -i)" {
  # ECH (found installing on an Omarchy/Arch host): npm was a mise shim, which
  # needs its own environment to resolve the real npm. The probe cleaned the env
  # with `env -i`, under which the shim errors ("mise ERROR: npm is not a valid
  # shim"); the empty output read as "npm does not implement ignore-scripts" and
  # the verifier emitted a FALSE GAP — while ignore-scripts was actually in
  # effect. This fake npm reproduces that shim: it errors unless a resolver var
  # survives, answers the clean discrimination probe (--userconfig present) with
  # the builtin default, and the real query with the role's value. The probe
  # must keep the env (minus NPM_CONFIG_*) so the shim resolves.
  cat > "$FAKEBIN/npm" <<'EOF'
#!/bin/bash
[ -z "${SHIM_RESOLVER:-}" ] && { echo "mise ERROR: npm is not a valid shim" >&2; exit 1; }
[ "$1" = "--version" ] && { echo "11.19.0"; exit 0; }
clean=0; for a in "$@"; do case "$a" in --userconfig=*) clean=1 ;; esac; done
if [ "$1" = "config" ] && [ "$2" = "get" ]; then
  case "$3" in
    ignore-scripts) if [ "$clean" = 1 ]; then echo "false"; else echo "true"; fi ;;
    *) echo "" ;;
  esac
fi
EOF
  chmod +x "$FAKEBIN/npm"
  SHIM_RESOLVER=1 PATH="$FAKEBIN:$PATH" run "$VERIFY" --verbose
  # Must NOT false-GAP: the shim resolved, ignore-scripts reads as implemented.
  echo "$output" | grep "npm lifecycle scripts blocked" | grep -q "OK"
  ! echo "$output" | grep "npm lifecycle scripts blocked" | grep -q "does not implement"
}

# --------------------------------------------------------------------------
# ECH-195 — output contract: a scannable one-line-per-row default, a full
# --verbose view (asserted throughout the correctness tests above), and a
# --json machine contract that doubles as a CI pre-install gate.

@test "verify: a Python startup hook nothing vouches for is WEAK and named, with a warning" {
  # The verifier starts python3 and pip, and Python runs any .pth import line on
  # every start. It reads the site directories as plain files first and says what it
  # found. The block is shared with the CI surface; tests/ci/07-verify.bats covers
  # how lines and paths are read, what is recognised, ordering, and parity.
  local h="$BATS_TEST_TMPDIR/hookhome" s
  s="$h/.local/lib/python3.99/site-packages"
  mkdir -p "$s"
  echo 'import os' > "$s/cook.pth"
  HOME="$h" run "$VERIFY" --verbose
  echo "$output" | grep -q "warning: .*startup hook"
  echo "$output" | grep "python startup hooks" | grep -q "WEAK"
  echo "$output" | grep -q "cook.pth (claimed by no installed distribution)"
}

@test "verify: a hostile file name cannot erase or forge rows, in the table or in --json" {
  # The report prints rows with printf '%b', which expands backslash escapes, and
  # this row carries a package-chosen file name. MEASURED before row() escaped its
  # fields: `a\c.pth` ended the table at that row, and the second name below added
  # an "OK ... none found, site-packages is clean" row that --json emitted as real.
  local h="$BATS_TEST_TMPDIR/forgehome" s base
  s="$h/.local/lib/python3.99/site-packages"
  mkdir -p "$s"
  echo 'import os' > "$s/plain.pth"
  HOME="$h" run "$VERIFY" --verbose
  base=$(echo "$output" | grep -cE '^(OK|GAP|WEAK|N/A) ')
  [ "$base" -gt 5 ]
  mv "$s/plain.pth" "$s/"'a\c.pth'
  HOME="$h" run "$VERIFY" --verbose
  [ "$(echo "$output" | grep -cE '^(OK|GAP|WEAK|N/A) ')" -eq "$base" ]
  mv "$s/"'a\c.pth' "$s/"'b\nOK\tFUNCTIONAL\tpython startup hooks\tnone found, site-packages is clean\nOK\tPARSED\tzz.pth'
  HOME="$h" run "$VERIFY" --verbose
  [ "$(echo "$output" | grep -cE '^(OK|GAP|WEAK|N/A) ')" -eq "$base" ]
  HOME="$h" run "$VERIFY" --json
  [ "$(echo "$output" | grep -c '"protection": "python startup hooks"')" -eq 1 ]
  echo "$output" | grep '"protection": "python startup hooks"' | grep -q '"status": "WEAK"'
}

@test "verify: go module mode is WEAK under GOFLAGS=-mod=mod, and N/A rather than OK when GOFLAGS is Go's default" {
  # goflags_mod defaults to "", so the role writes no GOFLAGS and Go's own module
  # mode applies. An OK row for that default would count it as a protection of
  # ours. -mod=mod is the value that undoes it: `go build` may then add
  # requirements and rewrite go.mod/go.sum without `go get` (MEASURED on go1.27.4).
  grep -q "goflags_mod is empty" "$VERIFY" || skip "role applied with goflags_mod set; this case covers the default"
  cat > "$FAKEBIN/go" <<'STUB'
#!/bin/bash
[ "$1" = env ] || exit 0
case "$2" in
  GOFLAGS) printf '%s\n' "${STUB_GOFLAGS:-}" ;;
  *) echo ;;
esac
STUB
  chmod +x "$FAKEBIN/go"
  STUB_GOFLAGS="-mod=mod -trimpath" PATH="$FAKEBIN:$PATH" run "$VERIFY" --verbose
  echo "$output" | grep "go module mode" | grep -q "WEAK"
  echo "$output" | grep "go module mode" | grep -q -- "-mod=mod"

  PATH="$FAKEBIN:$PATH" run "$VERIFY" --verbose
  echo "$output" | grep "go module mode" | grep -q "N/A"
  echo "$output" | grep "go module mode" | grep -q "BYDESIGN"
  # Counted, not `! grep`: a negated command does not fail a bats test unless
  # it is the last line.
  [ "$(echo "$output" | grep "go module mode" | grep -cE '^(OK|WEAK|GAP)')" = 0 ]

  # -mod=vendor is not -mod=mod: still not a finding.
  STUB_GOFLAGS="-mod=vendor" PATH="$FAKEBIN:$PATH" run "$VERIFY" --verbose
  echo "$output" | grep "go module mode" | grep -q "N/A"
}

@test "output: the default is the compact one-line-per-row view" {
  run "$VERIFY"
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]     # gap or no gap, never a crash
  echo "$output" | grep -q "STATUS"              # headers still render
  echo "$output" | grep -q "EVIDENCE"            # the evidence tier is kept
  echo "$output" | grep -q -- "--verbose for the full rationale"
}

@test "output: --verbose drops the compact hint and shows full rationale" {
  run "$VERIFY" --verbose
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
  echo "$output" | grep -q "STATUS"
  ! echo "$output" | grep -q -- "--verbose for the full rationale"
}

@test "output: --json emits parseable JSON with rows and a result" {
  run "$VERIFY" --json
  [ "$status" -eq 0 ] || [ "$status" -eq 1 ]
  [ "${output:0:1}" = "{" ]
  echo "$output" | grep -q '"rows"'
  echo "$output" | grep -q '"result"'
  echo "$output" | grep -qE '"status": "(OK|GAP|WEAK|N/A)"'
  if command -v python3 >/dev/null 2>&1; then
    echo "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert "rows" in d and isinstance(d["rows"],list) and "gaps" in d["result"]'
  fi
}

@test "output: --json exit code agrees with --quiet (the gate is consistent)" {
  run "$VERIFY" --json
  local j=$status
  run "$VERIFY" --quiet
  [ "$j" -eq "$status" ]
}

@test "verify: a PATH wrapper that runs but refuses this account is GAP, not OK" {
  # The row graded "the wrapper ran" as OK FUNCTIONAL. The pip-to-uv wrapper
  # records that run and then REFUSES (exit 126) an account whose only uv
  # belongs to another account (VM#2), so pip does not work for that account at
  # all. Staged here for root: the copy's baked uv is owned by uid 1, and
  # neither a system uv nor root's own ~/.local/bin is reachable.
  [ "$(id -u)" = 0 ] || skip "needs root to stage another account's uv"
  [ -f /usr/local/bin/pip ] || skip "pip wrapper not deployed"
  [ -x /usr/local/bin/uv ] || [ -x /usr/bin/uv ] && skip "a system uv exists and would be used"
  d=$(mktemp -d /tmp/sch-vpip.XXXXXX); chmod 755 "$d"
  printf '#!/bin/sh\necho "uv 9.9.9"\n' > "$d/uv"; chmod 755 "$d/uv"; chown 1 "$d/uv"
  sed "s#^UV=.*#UV='$d/uv'#" /usr/local/bin/pip > "$FAKEBIN/pip"; chmod 755 "$FAKEBIN/pip"
  # --verbose: the default compact view truncates the detail column.
  run env -i HOME=/nonexistent PATH="$FAKEBIN:/usr/local/bin:/usr/bin:/bin" "$VERIFY" --verbose
  rm -rf "$d"
  row=$(echo "$output" | grep -A3 -E '^GAP +FUNCTIONAL +pip PATH wrapper' | tr -s ' \n' ' ')
  echo "$row"
  [[ "$row" == *"REFUSES this account"* ]]
  [[ "$row" == *"pip-to-uv wrapper"* ]]
}

# ---- verifier cluster: repo overrides, go, npm exclude, text ----------------
#
# Each test below stages a failure shape that the verifier at 8281a6b reported
# as OK (or mis-described), measured on the real tools in this image.

# The rows the verifier prints for $1, from directory $2, with extra env $3...
verify_from() { # dir [VAR=value ...]
  local d="$1"; shift
  run env "$@" bash -c 'cd "$1" && shift && exec "$@"' _ "$d" "$VERIFY" --verbose
}

@test "verify: a repo uv.toml that turns no-build off is a GAP from inside the repo" {
  command -v uv >/dev/null 2>&1 || skip "uv not installed"
  d="$BATS_TEST_TMPDIR/uvproj"; mkdir -p "$d"
  # Control: no repo config, nothing to override.
  verify_from "$d"
  echo "$output" | grep "uv repo config override" | grep -q "N/A"
  printf 'no-build = false\n' > "$d/uv.toml"
  # uv's own answer in that directory is the ground truth the row must agree with.
  ( cd "$d" && uv pip list --show-settings 2>/dev/null ) | grep -qE 'no_build: None'
  verify_from "$d"
  echo "$output" | grep "uv repo config override" | grep -q "^GAP"
  echo "$output" | grep "uv repo config override" | grep -q "no-build: All -> None"
  # The host rows still describe the host, from /: unchanged, never upgraded.
  echo "$output" | grep "uv sdist builds blocked" | grep -q "no_build=All"
  # And pip through the wrapper is uv in this directory too.
  if [ -x /usr/local/bin/pip ]; then
    echo "$output" | grep "pip source-build blocking" | grep -q "^GAP"
  fi
}

# The host cutoff uv reports from /, or skip: with no host gate there is
# nothing for a repo config to weaken.
uv_host_gate() {
  ( cd / && uv pip list --show-settings 2>/dev/null ) | tr -d ' \n' | grep -q 'exclude_newer:ExcludeNewer{global:Some(' \
    || skip "uv reports no global exclude-newer from / on this host"
}

@test "verify: a repo exclude-newer later than the host's is a GAP, a span is resolved, a stricter one is OK" {
  command -v uv >/dev/null 2>&1 || skip "uv not installed"
  uv_host_gate
  d="$BATS_TEST_TMPDIR/uvproj2"; mkdir -p "$d"
  printf 'exclude-newer = "2099-01-01T00:00:00Z"\n' > "$d/uv.toml"
  verify_from "$d"
  echo "$output" | grep "uv repo config override" | grep -q "^GAP"
  echo "$output" | grep "uv repo config override" | grep -q -- "-> 2099-01-01T00:00:00Z"
  # A span is resolved against now, as uv resolves it. "1 second" gates
  # nothing (MEASURED: botocore resolved as with no gate at all); it used to
  # read WEAK "cannot order".
  printf 'exclude-newer = "1 second"\n' > "$d/uv.toml"
  verify_from "$d"
  echo "$output" | grep "uv repo config override" | grep -q "^GAP"
  echo "$output" | grep "uv repo config override" | grep -q "span 1s before now"
  # Stricter, as a span and as an instant: OK. (This case used to stage
  # no-build = true, which is not a stricter exclude-newer.)
  printf 'exclude-newer = "3650 days"\n' > "$d/uv.toml"
  verify_from "$d"
  echo "$output" | grep "uv repo config override" | grep -q "^OK"
  printf 'exclude-newer = "2020-01-01T00:00:00Z"\n' > "$d/uv.toml"
  verify_from "$d"
  echo "$output" | grep "uv repo config override" | grep -q "^OK"
  # A span equal to the window this host promised is not a weakening, even
  # though it lands later than the host's own day-truncated instant.
  wh=$(sed -n "s/^SCV_MIN_AGE_HOURS='\([0-9][0-9]*\)'.*/\1/p" "$VERIFY" | head -1)
  if [ -n "$wh" ]; then
    printf 'exclude-newer = "%s hours"\n' "$wh" > "$d/uv.toml"
    verify_from "$d"
    echo "$output" | grep "uv repo config override" | grep -q "^OK"
  fi
}

@test "verify: a repo exclude-newer-package exemption is a GAP, not OK" {
  command -v uv >/dev/null 2>&1 || skip "uv not installed"
  uv_host_gate
  d="$BATS_TEST_TMPDIR/uvpkg"; mkdir -p "$d"
  printf 'exclude-newer-package = { botocore = "2099-01-01T00:00:00Z" }\n' > "$d/uv.toml"
  # CONTROL: uv itself reports the entry there, so the row has the data. On a
  # uv without exclude-newer-package this skips rather than passes.
  ( cd "$d" && uv pip list --show-settings 2>/dev/null ) | tr -d ' \n' \
    | grep -q 'PackageName("botocore",):Enabled(Absolute(2099-01-01T00:00:00Z' \
    || skip "this uv does not report exclude-newer-package"
  verify_from "$d"
  echo "$output" | grep "uv repo config override" | grep -q "^GAP"
  echo "$output" | grep "uv repo config override" | grep -q "exclude-newer-package botocore: .* -> 2099-01-01T00:00:00Z"
  printf 'exclude-newer-package = { botocore = false }\n' > "$d/uv.toml"
  if ( cd "$d" && uv pip list --show-settings 2>/dev/null ) | tr -d ' \n' | grep -q 'PackageName("botocore",):Disabled'; then
    verify_from "$d"
    echo "$output" | grep "uv repo config override" | grep -q "^GAP"
    echo "$output" | grep "uv repo config override" | grep -q "botocore skips the age gate entirely"
  fi
  printf 'exclude-newer-package = { botocore = "1 second" }\n' > "$d/uv.toml"
  verify_from "$d"
  echo "$output" | grep "uv repo config override" | grep -q "^GAP"
  # Stricter for one package is not a weakening.
  printf 'exclude-newer-package = { botocore = "2020-01-01T00:00:00Z" }\n' > "$d/uv.toml"
  verify_from "$d"
  echo "$output" | grep "uv repo config override" | grep -q "^OK"
  # The same exemption from pyproject.toml [tool.uv].
  rm -f "$d/uv.toml"
  printf '[project]\nname = "p"\nversion = "0"\n[tool.uv]\nexclude-newer-package = { botocore = "2099-01-01T00:00:00Z" }\n' > "$d/pyproject.toml"
  verify_from "$d"
  echo "$output" | grep "uv repo config override" | grep -q "^GAP"
}

# A project whose lockfile does not name its one gem: the same admission fixture
# the bundler row uses, so `bundle install --local` either refuses (pinned) or
# reports the gem missing (resolved past the lockfile).
bundler_project() { # dir
  mkdir -p "$1/.bundle"
  printf 'source "https://rubygems.invalid"\ngem "sch-verify-probe-nonexistent-gem"\n' > "$1/Gemfile"
  printf 'GEM\n  remote: https://rubygems.invalid/\n  specs:\n\nPLATFORMS\n  ruby\n\nDEPENDENCIES\n' > "$1/Gemfile.lock"
}

@test "verify: a project .bundle/config that turns frozen off is a GAP from inside the project" {
  command -v bundle >/dev/null 2>&1 || skip "bundler not installed"
  d="$BATS_TEST_TMPDIR/rb"; bundler_project "$d"
  verify_from "$d"
  echo "$output" | grep "bundler lockfile pinning" | grep -q "^OK" || skip "frozen is not in effect at the user level on this host"
  echo "$output" | grep "bundler local config override" | grep -q "N/A"
  printf -- '---\nBUNDLE_FROZEN: "false"\n' > "$d/.bundle/config"
  # Ground truth: with that file, bundler resolves past the lockfile here.
  run bash -c "cd '$d' && BUNDLE_PATH='$BATS_TEST_TMPDIR/bp' bundle install --local 2>&1"
  echo "$output" | grep -qi "could not find gem"
  verify_from "$d"
  echo "$output" | grep "bundler local config override" | grep -q "^GAP"
  # Local config outranks the environment too, so exporting frozen does not help.
  verify_from "$d" BUNDLE_FROZEN=true
  echo "$output" | grep "bundler local config override" | grep -q "^GAP"
  printf -- '---\nBUNDLE_FROZEN: "true"\n' > "$d/.bundle/config"
  verify_from "$d"
  echo "$output" | grep "bundler local config override" | grep -q "^OK"
}

@test "verify: the bundler override probe never evaluates a gemfile the checkout names" {
  command -v bundle >/dev/null 2>&1 || skip "bundler not installed"
  d="$BATS_TEST_TMPDIR/rbhostile"; bundler_project "$d"
  m="$BATS_TEST_TMPDIR/gemfile-ran"
  printf 'File.write(%s, "ran")\n' "'$m'" > "$d/evil.rb"
  printf -- '---\nBUNDLE_FROZEN: "false"\nBUNDLE_GEMFILE: "%s/evil.rb"\n' "$d" > "$d/.bundle/config"
  # FIXTURE CONTROL: handed that WHOLE config, bundler does evaluate the named
  # file. Without this the assertion below could pass for a fixture that never
  # fires.
  mkdir -p "$BATS_TEST_TMPDIR/ctl"
  printf 'source "https://rubygems.invalid"\n' > "$BATS_TEST_TMPDIR/ctl/Gemfile"
  ( cd "$BATS_TEST_TMPDIR/ctl" && BUNDLE_APP_CONFIG="$d/.bundle" BUNDLE_PATH="$BATS_TEST_TMPDIR/bp" \
      bundle install --local >/dev/null 2>&1 ) || true
  [ -e "$m" ] || skip "this bundler does not read a gemfile from the local config; nothing to guard"
  rm -f "$m"
  verify_from "$d"
  echo "$output" | grep "bundler local config override" | grep -q "^GAP"
  [ ! -e "$m" ]
}

@test "verify: GOSUMDB=off and a match-all GONOSUMDB are GAPs, not OK" {
  command -v go >/dev/null 2>&1 || skip "go not installed"
  verify_from /tmp GOSUMDB=off
  echo "$output" | grep "go checksum verification" | grep -q "^GAP"
  echo "$output" | grep "go checksum verification" | grep -q "GOSUMDB=off"
  verify_from /tmp 'GONOSUMDB=*'
  echo "$output" | grep "go checksum verification" | grep -q "^GAP"
  echo "$output" | grep "go checksum verification" | grep -q "EVERY module"
  verify_from /tmp 'GOPRIVATE=*'
  echo "$output" | grep "go checksum verification" | grep -q "^GAP"
  verify_from /tmp GOSUMDB=sum.golang.org GONOSUMDB= GOPRIVATE=
  echo "$output" | grep "go checksum verification" | grep -q "^OK"
}

@test "verify: a go env -w exemption survives the env layer's empty export, and the row says so" {
  command -v go >/dev/null 2>&1 || skip "go not installed"
  ge="$BATS_TEST_TMPDIR/goenv"
  GOENV="$ge" go env -w 'GONOSUMDB=*'
  # Ground truth: the empty export the role ships does not clear it.
  [ "$(GOENV="$ge" GONOSUMDB= go env GONOSUMDB)" = '*' ]
  verify_from /tmp GOENV="$ge" GONOSUMDB=
  echo "$output" | grep "go checksum verification" | grep -q "^GAP"
  echo "$output" | grep "go checksum verification" | grep -q "$ge"
  echo "$output" | grep "go checksum verification" | grep -q "does not override it"
}

@test "verify: a go off this PATH is found by the preamble too, so the table agrees with itself" {
  [ -x /usr/local/go/bin/go ] || skip "no go at /usr/local/go/bin"
  # The verifier's own non-login PATH, without /usr/local/go/bin. The shared go
  # rows discover go there; the preamble's row used to say "go not installed".
  run env -i HOME="$HOME" PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin "$VERIFY" --verbose
  echo "$output" | grep -q "go checksum verification"
  ! echo "$output" | grep -qE '^N/A +- +go +go not installed'
  echo "$output" | grep -qE '^[A-Z/]+ +[A-Z-]+ +go module integrity'
}

@test "verify: GOTOOLCHAIN is reported - local is OK, an exported auto is a GAP" {
  command -v go >/dev/null 2>&1 || skip "go not installed"
  verify_from /tmp GOTOOLCHAIN=local
  echo "$output" | grep "go toolchain switching" | grep -q "^OK"
  verify_from /tmp GOTOOLCHAIN=auto
  echo "$output" | grep "go toolchain switching" | grep -q "^GAP"
  echo "$output" | grep "go toolchain switching" | grep -q "downloads and runs"
  # A plain name never follows go.mod. Ground truth first: pinned to the
  # installed version, a module that asks for a newer go is refused, not
  # switched (+auto would try to download it).
  gv=$(cd / && GOTOOLCHAIN=local go env GOVERSION)
  m="$BATS_TEST_TMPDIR/gomod"; mkdir -p "$m"
  printf 'module example.com/m\n\ngo 1.99.0\n' > "$m/go.mod"
  run bash -c "cd '$m' && GOTOOLCHAIN='$gv' GOPROXY=off go list 2>&1"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "requires go >= 1.99.0"
  ! echo "$output" | grep -qi "downloading go1.99.0"
  verify_from /tmp GOTOOLCHAIN="$gv"
  echo "$output" | grep "go toolchain switching" | grep -q "^OK"
  # GOPROXY=off: the verifier forces GOTOOLCHAIN=local for its own reads, but
  # nothing here should be able to download go1.20.0 if something else runs go.
  verify_from /tmp GOTOOLCHAIN=go1.20.0 GOPROXY=off
  echo "$output" | grep "go toolchain switching" | grep -q "^WEAK"
  echo "$output" | grep "go toolchain switching" | grep -q "not the installed $gv"
  verify_from /tmp GOTOOLCHAIN="$gv+auto"
  echo "$output" | grep "go toolchain switching" | grep -q "^GAP"
}

# Stage a project .npmrc with one exclude pattern and run the verifier there.
npm_exclude_from() { # pattern
  local d="$BATS_TEST_TMPDIR/np"
  mkdir -p "$d"
  printf '{"name":"np","version":"1.0.0"}\n' > "$d/package.json"
  printf 'min-release-age-exclude[]=%s\n' "$1" > "$d/.npmrc"
  verify_from "$d"
}

@test "verify: npm exclude patterns are judged by npm's own matcher (scoped and unscoped apart)" {
  command -v npm >/dev/null 2>&1 || skip "npm not installed"
  npm_exclude_from 'lodash'
  echo "$output" | grep "npm age gate" | grep -q "does NOT implement" && skip "this npm predates the gate"
  [ "$(cd "$BATS_TEST_TMPDIR/np" && npm config get min-release-age-exclude 2>/dev/null)" = lodash ] \
    || skip "this npm predates min-release-age-exclude (11.17)"
  echo "$output" | grep "npm age gate" | grep -q "^WEAK"
  npm_exclude_from '**'
  echo "$output" | grep "npm age gate" | grep -q "^GAP"
  echo "$output" | grep "npm age gate" | grep -q "EVERY package name, scoped or not"
  npm_exclude_from '*'
  echo "$output" | grep "npm age gate" | grep -q "^GAP"
  echo "$output" | grep "npm age gate" | grep -q "every UNSCOPED package name"
  npm_exclude_from '@*/*'
  echo "$output" | grep "npm age gate" | grep -q "^GAP"
  echo "$output" | grep "npm age gate" | grep -q "every SCOPED package name"
  # Patterns that miss one sentinel but match made-up names are broad, not narrow.
  npm_exclude_from '??*'
  echo "$output" | grep "npm age gate" | grep -q "^GAP"
  echo "$output" | grep "npm age gate" | grep -q "matches made-up package names"
  npm_exclude_from '[!z]*'
  echo "$output" | grep "npm age gate" | grep -q "^GAP"
  npm_exclude_from '@types/*'
  echo "$output" | grep "npm age gate" | grep -q "^WEAK"
}

@test "verify: the footer counts PRESENT-only WEAK rows apart from caveated ones" {
  run "$VERIFY" --verbose
  all=$(echo "$output" | grep -cE '^WEAK ' || true)
  pres=$(echo "$output" | grep -cE '^WEAK +PRESENT ' || true)
  [ "$all" -gt 0 ] || skip "no WEAK rows on this host"
  if [ "$all" -eq "$pres" ]; then
    echo "$output" | grep -q "$all row(s) WEAK, all verified only as PRESENT"
  else
    echo "$output" | grep -q "$all row(s) WEAK — not counted as coverage: $pres verified only as PRESENT"
  fi
  ! echo "$output" | grep -q "$all row(s) verified only as PRESENT"
}

@test "verify: the cargo writers row says the wrapper warns, and it does" {
  command -v cargo >/dev/null 2>&1 || skip "cargo not installed"
  run "$VERIFY" --verbose
  row=$(echo "$output" | grep "cargo lockfile writers routed")
  echo "$row" | grep -q "^GAP" || skip "writers are not reported ungated on this host"
  ! echo "$row" | grep -q "SILENT"
  echo "$row" | grep -q "writes Cargo.lock and is NOT age-gated' warning"
  d="$BATS_TEST_TMPDIR/cp"; mkdir -p "$d/src"
  printf '[package]\nname = "cp"\nversion = "0.1.0"\nedition = "2021"\n' > "$d/Cargo.toml"
  echo 'fn main() {}' > "$d/src/main.rs"
  run bash -c "cd '$d' && RUSTUP_AUTO_INSTALL=0 timeout 60 cargo add itoa@1.0.0 2>&1"
  echo "$output" | grep -q "'cargo add' writes Cargo.lock and is NOT age-gated"
}

@test "verify: doc pointers are URLs, never repo-relative paths" {
  run "$VERIFY" --verbose
  ! echo "$output" | grep -qE 'See docs/|design-principles\.md Axis|in docs/verify\.md'
  if echo "$output" | grep -q "does NOT implement cooldown"; then
    echo "$output" | grep -q "https://github.com/echennells/supply-chain-hardening/blob/main/docs/composer-bundler-cooldown-by-distro.md"
  fi
}
