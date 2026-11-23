#!/usr/bin/env bats
# supply-chain-verify must not run code a checkout supplies, or code a
# directory other accounts can write supplies.
#
# AGENTS.md tells agents to run the verifier from inside a project too, and that
# may be a repo nobody reviewed. Tools read files from the working directory and
# every directory above it, and some of those files name code the tool then runs,
# for `--version` as much as for an install. MEASURED, each with a marker the
# checkout writes: .yarnrc.yml yarnPath and plugins (yarn 1.22.22, 4.1.0 to
# 4.19.0), rust-toolchain.toml `path =` (rustup 1.29.3), .mvn/jvm.config (maven
# 3.10.0), global.json sdk paths (.NET 10.0.404), pip.py beside `python3 -m pip`
# (pip 25.1.1), a go.mod toolchain line (go1.24.10), Poetry 2.5.2's
# .poetry/plugins, a project .corepack.env (corepack 0.36.0), and a pnpmfile
# (pnpm 10/11). The probes that build throwaway projects ran under /tmp, so a
# file planted there ran too (/tmp/.mvn/jvm.config, /tmp/rust-toolchain.toml,
# /tmp/Directory.Build.props, a /tmp/package.json workspace root on bun 1.3.0).
#
# This stages a checkout carrying all of them, runs the role's verifier inside
# it, and asserts no marker appears. A FIXTURE CONTROL runs the installed tools
# the unsafe way in the same checkout and requires the cheap traps to fire, so
# the test cannot pass because the traps are dead.

load setup

VERIFY=/usr/local/bin/supply-chain-verify

setup() {
  [ -x "$VERIFY" ] || skip "supply-chain-verify not deployed"
  MK="$BATS_TEST_TMPDIR/markers"
  mkdir -p "$MK"
}

teardown() {
  rm -rf /tmp/sch53-ww 2>/dev/null || true
}

markers() { ls "$MK" 2>/dev/null | tr '\n' ' '; }

trap_checkout() { # <dir>
  local d=$1
  rm -rf "$d"; mkdir -p "$d/sub" "$d/tc/bin" "$d/.mvn" "$d/.cargo" "$d/.venv/bin" "$d/.yarn"
  tjs() { printf 'require("fs").writeFileSync("%s/%s", "ran"); console.log("9.9.9");\n' "$MK" "$2" > "$1"; }
  tsh() { printf '#!/bin/sh\necho ran > "%s/%s"\necho 9.9.9\n' "$MK" "$2" > "$1"; chmod +x "$1"; }
  printf '{"name":"trap","version":"1.0.0","private":true,"packageManager":"yarn@4.9.4","scripts":{"preinstall":"echo ran > %s/npm-preinstall"}}\n' "$MK" > "$d/package.json"
  tjs "$d/.yarn/evil.cjs" yarn-yarnpath
  printf 'require("fs").writeFileSync("%s/yarn-plugin", "ran");\nmodule.exports = { name: "p", factory: () => ({}) };\n' "$MK" > "$d/.yarn/plug.cjs"
  printf 'yarnPath: .yarn/evil.cjs\nplugins:\n  - path: .yarn/plug.cjs\n    spec: plug\nnpmMinimalAgeGate: 0\n' > "$d/.yarnrc.yml"
  tjs "$d/.yarn/classic.js" yarn-classic-path; printf 'yarn-path ".yarn/classic.js"\n' > "$d/.yarnrc"
  printf 'COREPACK_ENABLE_UNSAFE_CUSTOM_URLS=1\nCOREPACK_NPM_REGISTRY=http://127.0.0.1:9\n' > "$d/.corepack.env"
  printf 'require("fs").writeFileSync("%s/pnpm-pnpmfile", "ran"); module.exports = { hooks: {} };\n' "$MK" > "$d/.pnpmfile.cjs"
  printf 'packages: ["sub"]\nminimumReleaseAge: 600\n' > "$d/pnpm-workspace.yaml"
  tjs "$d/.yarn/npm-onload.js" npm-onload; printf 'onload-script=%s/.yarn/npm-onload.js\n' "$d" > "$d/.npmrc"
  tsh "$d/tc/bin/cargo" rustup-path-cargo; tsh "$d/tc/bin/rustc" rustup-path-rustc
  printf '[toolchain]\npath = "%s/tc"\n' "$d" > "$d/rust-toolchain.toml"
  tsh "$d/tc/wrap" cargo-rustc-wrapper; printf '[build]\nrustc-wrapper = "%s/tc/wrap"\n' "$d" > "$d/.cargo/config.toml"
  tsh "$d/tc/oom" maven-jvm-config; printf -- '-Xmx3m -XX:OnOutOfMemoryError=%s/tc/oom\n' "$d" > "$d/.mvn/jvm.config"
  printf 'new File("%s/gradle-settings").text = "ran"\n' "$MK" > "$d/settings.gradle"
  mkdir -p "$d/.dotnet/sdk/99.0.100"; tsh "$d/.dotnet/sdk/99.0.100/dotnet.dll" dotnet-sdk
  printf '{"sdk":{"version":"99.0.100","paths":[".dotnet","$host$"],"rollForward":"disable"}}\n' > "$d/global.json"
  printf '<Project InitialTargets="T"><Target Name="T"><Exec Command="echo ran > %s/dotnet-props" /></Target></Project>\n' "$MK" > "$d/Directory.Build.props"
  printf 'open("%s/python-pip-py", "w").write("ran")\n' "$MK" > "$d/pip.py"; cp "$d/pip.py" "$d/sub/pip.py"
  tsh "$d/.venv/bin/python" uv-venv-python; ln -s python "$d/.venv/bin/python3"
  printf 'home = /usr/bin\nversion = 3.12.0\ninclude-system-site-packages = false\n' > "$d/.venv/pyvenv.cfg"
  printf '[project]\nname = "trap"\nversion = "0.1.0"\n[tool.poetry.requires-plugins]\nevil = { path = "./evil" }\n' > "$d/pyproject.toml"
  printf 'module trap\n\ngo 1.21\n\ntoolchain go1.999.0\n' > "$d/go.mod"
  printf 'File.write("%s/bundler-gemfile", "ran")\nsource "https://rubygems.org"\n' "$MK" > "$d/Gemfile"
  printf '{"name":"t/t","scripts":{"pre-command-run":"echo ran > %s/composer-script"}}\n' "$MK" > "$d/composer.json"
  tjs "$d/.yarn/bun-preload.js" bun-preload; printf 'preload = ["./.yarn/bun-preload.js"]\n' > "$d/bunfig.toml"
  printf '{"imports":{"x":"./.yarn/deno.ts"}}\n' > "$d/deno.json"
}

@test "verifier in a booby-trapped checkout: none of its traps fire (FIXTURE CONTROL: they fire when the tools run there)" {
  local d="$BATS_TEST_TMPDIR/trap" fired=""
  trap_checkout "$d"
  # FIXTURE CONTROL: the installed tools, run the unsafe way, set the traps off.
  ( cd "$d" && python3 -m pip --version ) >/dev/null 2>&1 || true
  [ -e "$MK/python-pip-py" ] && fired="$fired python"
  if command -v uv >/dev/null 2>&1; then
    ( cd "$d" && uv pip list ) >/dev/null 2>&1 || true
    [ -e "$MK/uv-venv-python" ] && fired="$fired uv"
  fi
  case "$(readlink -f "$(command -v cargo 2>/dev/null)" 2>/dev/null)" in
    */rustup) ( cd "$d" && RUSTUP_AUTO_INSTALL=0 cargo --version ) >/dev/null 2>&1 || true
              [ -e "$MK/rustup-path-cargo" ] && fired="$fired rustup" ;;
  esac
  if command -v bundle >/dev/null 2>&1; then
    ( cd "$d" && env -u BUNDLE_APP_CONFIG bundle check ) >/dev/null 2>&1 || true
    [ -e "$MK/bundler-gemfile" ] && fired="$fired bundler"
  fi
  if command -v mvn >/dev/null 2>&1; then
    ( cd "$d/sub" && mvn -v ) >/dev/null 2>&1 || true
    [ -e "$MK/maven-jvm-config" ] && fired="$fired maven"
  fi
  echo "controls fired:$fired ($(markers))"
  [[ "$fired" == *python* ]]
  # Every installed tool among these must have fired: a dead trap proves nothing.
  if command -v uv >/dev/null 2>&1; then [[ "$fired" == *uv* ]]; fi
  if command -v bundle >/dev/null 2>&1; then [[ "$fired" == *bundler* ]]; fi
  rm -f "$MK"/*
  run bash -c 'cd "$1" && exec "$2" --verbose' _ "$d/sub" "$VERIFY"
  echo "$output" | grep -E "repo config override|yarn" | cut -c1-220
  [ -z "$(markers)" ] || { echo "the verifier ran: $(markers)" >&2; return 1; }
  # It still reported what the checkout changes, from the files.
  echo "$output" | grep "yarn repo config override" | grep -q "the checkout's own yarn"
  echo "$output" | grep -q "pnpm repo config override"
}

@test "verifier with a world-writable TMPDIR: probe projects go under a private base, and files planted above TMPDIR do not run" {
  local ww=/tmp/sch53-ww shims="$BATS_TEST_TMPDIR/shims" log="$BATS_TEST_TMPDIR/tool-tmpdirs" t real tmps
  rm -rf "$ww"; mkdir -p "$ww/sub" "$ww/tc/bin" "$ww/.mvn" "$ww/h"; chmod 1777 "$ww"
  printf '#!/bin/sh\necho ran > "%s/tmp-maven-jvm-config"\n' "$MK" > "$ww/tc/oom"; chmod +x "$ww/tc/oom"
  printf -- '-Xmx3m -XX:OnOutOfMemoryError=%s/tc/oom\n' "$ww" > "$ww/.mvn/jvm.config"
  printf '#!/bin/sh\necho ran > "%s/tmp-rustup-path"\necho cargo 9.9.9\n' "$MK" > "$ww/tc/bin/cargo"; chmod +x "$ww/tc/bin/cargo"
  printf '[toolchain]\npath = "%s/tc"\n' "$ww" > "$ww/rust-toolchain.toml"
  printf '{"name":"tmproot","private":true,"workspaces":["*"],"scripts":{"preinstall":"echo ran > %s/tmp-bun-root","postinstall":"echo ran > %s/tmp-bun-root-post"}}\n' "$MK" "$MK" > "$ww/package.json"
  printf 'ignore-scripts=false\n' > "$ww/.npmrc"
  # Record the TMPDIR every tool the verifier starts was given.
  mkdir -p "$shims"
  for t in npm node bun bundle composer python3; do
    real=$(command -v "$t" 2>/dev/null) || continue
    printf '#!/bin/sh\nprintf "%%s\\n" "${TMPDIR:-}" >> "%s"\nexec "%s" "$@"\n' "$log" "$real" > "$shims/$t"; chmod +x "$shims/$t"
  done
  run env PATH="$shims:$PATH" TMPDIR="$ww/sub" bash -c 'cd / && exec "$1"' _ "$VERIFY"
  # A probe that starts a tool under env -i passes no TMPDIR; that tool runs in
  # one of the probe's own directories, under the same scratch dir.
  tmps=$(grep -v '^$' "$log" | sort -u)
  echo "TMPDIR seen: $tmps"
  [ -n "$tmps" ]
  [ "$(printf '%s\n' "$tmps" | grep -vc "^$HOME/.cache/supply-chain-hardening/scv\.")" -eq 0 ]
  [ -z "$(ls -d "$HOME"/.cache/supply-chain-hardening/scv.* 2>/dev/null)" ]
  [ -z "$(markers)" ] || { echo "a planted file ran: $(markers)" >&2; return 1; }
  [[ "$output" != *"found no directory for the probes"* ]]
  # CONTROL: with no private base the probes stay under that TMPDIR, and the
  # verifier says so. (A HOME under the world-writable dir has no private base.)
  rm -f "$log"
  run env PATH="$shims:$PATH" TMPDIR="$ww/sub" HOME="$ww/h" bash -c 'cd / && exec "$1"' _ "$VERIFY"
  echo "$output" | grep -q "warning: found no directory for the probes' throwaway projects"
  sort -u "$log" | grep -q "^$ww/sub"
}
