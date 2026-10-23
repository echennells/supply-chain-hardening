#!/usr/bin/env bats
# Caller-context coverage — what the BARE command resolves to, not what an
# absolute path does.
#
# WHY THIS FILE EXISTS. Every other wrapper test in this suite invokes the tool
# by its absolute path — 22-pip-wrapper-safety.bats:66 runs
# `/usr/local/bin/pip --version`, 23-npm-path-wrapper.bats does the same for npm
# — which GUARANTEES the wrapper runs. That is the one thing a real caller never
# does. Coverage is a function of what `pip` or `cargo` resolves to in the
# caller's shell, and this suite could not observe that by construction. So an
# activated virtualenv silently bypassing the pip wrapper went undocumented
# until 2026-10-21, even though docs/limitations.md already described the
# identical failure for mise/asdf/volta shims.
#
# supply-chain-verify ALREADY detects this correctly, with FUNCTIONAL evidence,
# via the SCH_WRAPPER_PROBE run-probe: the wrapper appends its own path to a
# temp file when it executes, so the verifier OBSERVES a bypass instead of
# inferring it from PATH position. Inference cannot work — the Aikido
# safe-chain measurement proved it cannot tell a bypassed wrapper from one
# chained behind another wrap. The defect was never the instrument. It was that
# the verifier is only ever run in ONE context: at the end of the apply, in the
# apply's own non-login shell.
#
# This file runs it in the contexts callers are actually in, and asserts what
# each one gets — INCLUDING THE LOSSES. A context that drops a protection gets a
# test saying so, in the spirit of 09-python-adversarial.bats test #4, which
# asserts a documented bypass succeeds so a future change cannot silently alter
# it in either direction.

load setup

VERIFY=/usr/local/bin/supply-chain-verify

# A minimal sdist built by hand. Deliberately not via setuptools: this file must
# run on a host with no build backend, and the only property under test is that
# pip classifies it as a source distribution.
make_sdist() { # make_sdist <dir> -> prints the tarball path
  local d="$1" n=schprobe-0.0.1
  mkdir -p "$d/$n"
  printf 'from setuptools import setup\nsetup(name="schprobe", version="0.0.1")\n' > "$d/$n/setup.py"
  printf 'Metadata-Version: 2.1\nName: schprobe\nVersion: 0.0.1\n' > "$d/$n/PKG-INFO"
  tar -C "$d" -czf "$d/$n.tar.gz" "$n"
  printf '%s\n' "$d/$n.tar.gz"
}

# Did the role's wrapper for <tool> actually execute on a bare invocation?
# Echoes the probe file's contents — empty means it did not run.
probe_run() { # probe_run <tool> [args...]
  local tool="$1"; shift
  local p="$BATS_TEST_TMPDIR/probe.$tool.$$"
  : > "$p"
  SCH_WRAPPER_PROBE="$p" "$tool" "$@" >/dev/null 2>&1 || true
  cat "$p"
}

# First role-deployed wrapper present on this host, for the generic shadow tests.
first_wrapper() {
  local t
  for t in pip pip3 npm cargo deno bun composer; do
    [ -x "/usr/local/bin/$t" ] && grep -qs 'supply-chain' "/usr/local/bin/$t" && { printf '%s\n' "$t"; return 0; }
  done
  return 1
}

# ---------------------------------------------------------------- baseline ---

@test "caller: a bare command runs the role's wrapper (positive control)" {
  [ -x "$VERIFY" ] || skip "role not applied (no supply-chain-verify)"
  [ -x /usr/local/bin/pip ] || skip "pip wrapper not deployed (uv absent at apply time)"

  # The control the whole file depends on: on a stock PATH, `pip` IS the wrapper.
  [ "$(command -v pip)" = /usr/local/bin/pip ]
  [ "$(probe_run pip --version)" = /usr/local/bin/pip ]
}

@test "caller: bare shell — verifier reports the pip wrapper as observed running" {
  [ -x "$VERIFY" ] || skip "role not applied (no supply-chain-verify)"
  [ -x /usr/local/bin/pip ] || skip "pip wrapper not deployed"

  run "$VERIFY" --verbose
  echo "$output" | grep "pip PATH wrapper" | grep -q "OK"
  echo "$output" | grep "pip PATH wrapper" | grep -q "FUNCTIONAL"
}

# ------------------------------------------------- the virtualenv class -------

@test "caller: an activated python3 -m venv BYPASSES the pip wrapper" {
  [ -x "$VERIFY" ] || skip "role not applied (no supply-chain-verify)"
  [ -x /usr/local/bin/pip ] || skip "pip wrapper not deployed"
  command -v python3 >/dev/null 2>&1 || skip "python3 not installed"
  python3 -c 'import venv' 2>/dev/null || skip "python3 venv module not available"

  python3 -m venv "$BATS_TEST_TMPDIR/venv" >/dev/null 2>&1 || skip "venv creation failed (no ensurepip?)"
  . "$BATS_TEST_TMPDIR/venv/bin/activate"

  # pip is now the venv's own, seeded by ensurepip from the DISTRO pip.
  [ "$(command -v pip)" = "$BATS_TEST_TMPDIR/venv/bin/pip" ]
  # The run-probe is the instrument: empty means the wrapper never executed.
  [ -z "$(probe_run pip --version)" ]

  run "$VERIFY" --verbose
  echo "$output" | grep "pip PATH wrapper" | grep -q "GAP"
  echo "$output" | grep "pip PATH wrapper" | grep -q "did NOT run"
  deactivate
}

@test "caller: in a stock venv, only-binary still refuses an index-resolved sdist" {
  [ -f /etc/pip.conf ] || skip "/etc/pip.conf not deployed"
  grep -q 'only-binary' /etc/pip.conf || skip "pip_only_binary disabled on this host"
  command -v python3 >/dev/null 2>&1 || skip "python3 not installed"
  python3 -c 'import venv' 2>/dev/null || skip "python3 venv module not available"

  python3 -m venv "$BATS_TEST_TMPDIR/venv" >/dev/null 2>&1 || skip "venv creation failed"
  . "$BATS_TEST_TMPDIR/venv/bin/activate"
  sdist=$(make_sdist "$BATS_TEST_TMPDIR/sd")

  # The config layer survives the wrapper shadow — this is the half that holds.
  run pip install --dry-run --no-deps --no-index --find-links "$(dirname "$sdist")" schprobe
  [ "$status" -ne 0 ]
  echo "$output" | grep -qiE "no matching distribution|from versions: none"
  deactivate
}

@test "caller: in a stock venv, only-binary does NOT cover a DIRECT-PATH sdist" {
  # MEASURED 2026-10-21 and the reason this is its own test: only-binary is a
  # resolver-level constraint, so it gates requirements resolved through an
  # index or --find-links and NOT a tarball named directly on the command line.
  # uv's no-build is the layer that covers the direct path — and that layer is
  # exactly what the venv shadow removed. Asserting the LOSS, deliberately.
  [ -f /etc/pip.conf ] || skip "/etc/pip.conf not deployed"
  grep -q 'only-binary' /etc/pip.conf || skip "pip_only_binary disabled on this host"
  command -v python3 >/dev/null 2>&1 || skip "python3 not installed"
  python3 -c 'import venv' 2>/dev/null || skip "python3 venv module not available"

  python3 -m venv "$BATS_TEST_TMPDIR/venv" >/dev/null 2>&1 || skip "venv creation failed"
  . "$BATS_TEST_TMPDIR/venv/bin/activate"
  sdist=$(make_sdist "$BATS_TEST_TMPDIR/sd")

  run pip install --dry-run --no-deps "$sdist"
  # Not asserting success — a build backend may be absent. Asserting that pip
  # did not REFUSE it on only-binary grounds, which is the coverage claim.
  [[ "$output" != *"from versions: none"* ]]
  deactivate
}

@test "caller: --system-site-packages is NOT a mitigation for the wrapper shadow" {
  [ -x "$VERIFY" ] || skip "role not applied (no supply-chain-verify)"
  [ -x /usr/local/bin/pip ] || skip "pip wrapper not deployed"
  command -v python3 >/dev/null 2>&1 || skip "python3 not installed"
  python3 -c 'import venv' 2>/dev/null || skip "python3 venv module not available"

  # The flag people reach for assuming it keeps the host's pip. It does not:
  # ensurepip still writes bin/pip into the venv.
  python3 -m venv --system-site-packages "$BATS_TEST_TMPDIR/ssp" >/dev/null 2>&1 || skip "venv creation failed"
  . "$BATS_TEST_TMPDIR/ssp/bin/activate"
  [ "$(command -v pip)" = "$BATS_TEST_TMPDIR/ssp/bin/pip" ]
  [ -z "$(probe_run pip --version)" ]
  deactivate
}

@test "caller: python3 -m pip bypasses the wrapper while command -v still names it" {
  # Why PATH-position inference cannot work, in one test: the module caller
  # never touches the wrapper, yet `command -v pip` still reports the wrapper
  # as the resolution. Any check that reasoned from PATH would call this covered.
  [ -x /usr/local/bin/pip ] || skip "pip wrapper not deployed"
  command -v python3 >/dev/null 2>&1 || skip "python3 not installed"
  python3 -m pip --version >/dev/null 2>&1 || skip "no importable pip module"

  [ "$(command -v pip)" = /usr/local/bin/pip ]

  p="$BATS_TEST_TMPDIR/modprobe"; : > "$p"
  SCH_WRAPPER_PROBE="$p" python3 -m pip --version >/dev/null 2>&1 || true
  [ ! -s "$p" ]
}

# --------------------------------------- generalised to every wrapped tool ---

@test "caller: a non-delegating shadow of a wrapped tool is seen as did-NOT-run" {
  [ -x "$VERIFY" ] || skip "role not applied (no supply-chain-verify)"
  tool=$(first_wrapper) || skip "no role-deployed PATH wrapper on this host"

  # A stand-in binary earlier on PATH that does NOT delegate — the shape of a
  # project-pinned toolchain or a CI-provided binary.
  fake="$BATS_TEST_TMPDIR/fakebin"; mkdir -p "$fake"
  printf '#!/bin/sh\nexit 0\n' > "$fake/$tool"
  chmod +x "$fake/$tool"

  PATH="$fake:$PATH" run "$VERIFY" --verbose
  echo "$output" | grep "$tool PATH wrapper" | grep -q "GAP"
  echo "$output" | grep "$tool PATH wrapper" | grep -q "FUNCTIONAL"
}

@test "caller: a DELEGATING shim still runs the wrapper — run-probe beats PATH inference" {
  # The measurement that killed PATH-position inference. A version-manager shim
  # strips its own dir from PATH and re-execs, so the wrapper DOES run even
  # though the bare command resolves somewhere else. A PATH check reports this
  # as bypassed; the run-probe correctly reports it as covered.
  [ -x "$VERIFY" ] || skip "role not applied (no supply-chain-verify)"
  tool=$(first_wrapper) || skip "no role-deployed PATH wrapper on this host"

  shim="$BATS_TEST_TMPDIR/shimbin"; mkdir -p "$shim"
  cat > "$shim/$tool" <<EOF
#!/bin/sh
# strip our own directory, then re-exec the real resolution (mise/asdf shape)
PATH=\$(printf '%s' "\$PATH" | sed "s#$shim:##")
export PATH
exec "$tool" "\$@"
EOF
  chmod +x "$shim/$tool"

  [ "$(PATH="$shim:$PATH" command -v "$tool")" = "$shim/$tool" ]
  out=$(PATH="$shim:$PATH" probe_run "$tool" --version)
  # The wrapper ran despite the bare command resolving to the shim.
  echo "$out" | grep -q "/usr/local/bin/$tool"
}

# ------------------------------------------ the audit context is itself one ---

@test "caller: the verifier ignores tool-override env vars (the audit cannot be forged)" {
  # REGRESSION GUARD. The first cut of the host-tool discovery block led each
  # tool's search list with that tool's own override variable (XDG_BIN_HOME,
  # BUN_INSTALL, DENO_INSTALL, PNPM_HOME). Because discovery PREPENDS the match
  # to PATH, that let a caller choose which binary the AUDIT executes. MEASURED
  # before the fix, with PATH byte-identical to an honest run and only
  # XDG_BIN_HOME set: the verifier reported `uv 99.9.9 started`, `no_build=All`
  # and a forged exclude-newer cutoff as OK. A forged clean audit, plus code
  # execution in a context that is root whenever the verifier runs under become.
  #
  # sudo's secure_path protects PATH; it does NOT protect these variables, and
  # sudoers env_keep or `sudo -E` can carry them through. So this must stay a
  # test rather than a comment.
  [ -x "$VERIFY" ] || skip "role not applied (no supply-chain-verify)"

  evil="$BATS_TEST_TMPDIR/evil"; mkdir -p "$evil"
  for tool in uv bun bunx deno pnpm composer; do
    cat > "$evil/$tool" <<'EOF'
#!/bin/sh
echo "SCH-FORGED-99.9.9"
printf '    no_build: All,\n    index_strategy: FirstIndex,\n'
EOF
    chmod +x "$evil/$tool"
  done

  XDG_BIN_HOME="$evil" BUN_INSTALL="$evil" DENO_INSTALL="$evil" PNPM_HOME="$evil" \
    run "$VERIFY" --verbose

  # The planted binaries must never have been executed as evidence.
  [[ "$output" != *"SCH-FORGED-99.9.9"* ]]
}

@test "caller: discovery finds a tool in a documented location that PATH hides" {
  # This test previously asserted the OPPOSITE — that an N/A row was a statement
  # about PATH rather than about the host — and it was RIGHT until the host-tool
  # discovery block landed. That block exists because the apply runs the verifier
  # through ansible.builtin.command, a non-login shell, so a tool installed to a
  # per-user directory was reported "not installed" on a host that had it
  # installed and hardened: a green that came from blindness.
  #
  # It now asserts the post-fix contract. Keeping the test and inverting it, rather
  # than deleting it, is the point — the behaviour changed deliberately and a
  # future regression should fail here.
  [ -x "$VERIFY" ] || skip "role not applied (no supply-chain-verify)"
  command -v uv >/dev/null 2>&1 || skip "uv not on PATH; nothing to hide from the verifier"

  uvdir=$(dirname "$(command -v uv)")
  # Only meaningful when uv lives in a location discovery knows about.
  case "$uvdir" in
    "$HOME/.local/bin"|"$HOME/.cargo/bin") ;;
    *) skip "uv at $uvdir is outside the documented locations discovery searches" ;;
  esac
  stripped=$(printf '%s' "$PATH" | sed "s#$uvdir:##; s#:$uvdir##")

  # PATH can no longer hide it: the audit reports real uv verdicts, not N/A.
  PATH="$stripped" run "$VERIFY" --verbose
  echo "$output" | grep -q "uv age gate"
  [[ "$output" != *"uv not installed"* ]]
}

@test "caller: a tool outside every documented location is still invisible" {
  # The honest residual of the fix. Discovery is a fixed list, deliberately — it
  # does not source the user's dotfiles, so a tool installed somewhere nobody
  # documents is still reported as absent. Asserting the limitation so it is a
  # known boundary rather than a surprise, and so nobody "fixes" it by running
  # the audit under a login shell.
  [ -x "$VERIFY" ] || skip "role not applied (no supply-chain-verify)"

  odd="$BATS_TEST_TMPDIR/nowhere/bin"; mkdir -p "$odd"
  printf '#!/bin/sh\nexit 0\n' > "$odd/deno"; chmod +x "$odd/deno"
  command -v deno >/dev/null 2>&1 && skip "a real deno is on PATH; cannot assert absence"

  run "$VERIFY" --verbose
  echo "$output" | grep -qi "deno"
  echo "$output" | grep -i "deno" | grep -qiE "not installed|N/A"
}
