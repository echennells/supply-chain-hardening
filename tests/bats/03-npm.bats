#!/usr/bin/env bats

load setup

@test "npm: ignore-scripts blocks postinstall" {
  rm -f /tmp/postinstall-marker
  cd /tmp && mkdir -p npm-script-test && cd npm-script-test
  npm init -y >/dev/null 2>&1
  npm install /opt/test-fixtures/npm-postinstall-pkg 2>/dev/null || true
  [ ! -f /tmp/postinstall-marker ]
  rm -rf /tmp/npm-script-test
}

@test "npm: ECH-149 — the file at npm's REAL globalconfig path is hardened, not just /etc/npmrc" {
  # ECH-149. The role used to deploy only /etc/npmrc, which npm reads as global
  # config ONLY on Debian/Ubuntu apt npm. On NodeSource (this image), nvm, fnm,
  # volta, asdf and the official node images, npm's globalconfig is
  # prefix-relative (/usr/etc/npmrc, /usr/local/etc/npmrc, …) and /etc/npmrc is
  # inert — so `sudo npm install` and other-user installs got no config-file
  # coverage. Assert the role deployed hardening to the path npm ACTUALLY reads,
  # rather than grepping the file the role chose to write. This is the
  # PARSED-vs-FUNCTIONAL discipline: ask npm where it reads, then check there.
  gp=$(npm config get globalconfig 2>/dev/null | tr -d '\r')
  [ -n "$gp" ] || skip "npm did not report a globalconfig path"
  [ -f "$gp" ]
  grep -q 'ignore-scripts=true' "$gp"
}

@test "npm: ECH-196 — npm's globalconfig carries no pnpm-only keys, so npm does not warn" {
  # ECH-196. The role once wrote pnpm's keys (minimum-release-age*) to npm's
  # resolved global config, and npm warned `Unknown global config` about them on
  # EVERY command (measured npm 11.19). The same for /etc/npmrc, where that is
  # npm's global config: tests/bats/01.
  gp=$(npm config get globalconfig 2>/dev/null | tr -d '\r')
  [ -n "$gp" ] || skip "npm did not report a globalconfig path"
  [ -f "$gp" ]
  ! grep -qE '^minimum-release-age' "$gp"
  # Behavioral: a plain npm command emits no unknown-config warning. Harmless on an
  # npm too old to warn; catches the regression on one that does.
  run npm config get registry
  [[ "$output" != *"Unknown global config"* ]]
}

@test "npm: .npmrc contains allow-git=none (file-content check)" {
  if npm_warns_about 11.9.0; then skip "npm $(npm --version) warns about the key, so the role leaves it out"; fi
  # File-content layer only. `npm config get allow-git` returns the literal
  # value from .npmrc regardless of whether npm honors the key — so a test
  # asserting "config get returns 'none'" passes whether the key is real
  # (npm >= 11) or made up. allow-git IS documented and enforced in
  # npm >= 11 per https://docs.npmjs.com/cli/v11/using-npm/config, but the
  # config-get-roundtrip pattern is the same shape the role hit with the
  # made-up COMPOSER_NO_SCRIPTS env var (test passed; no protection). The
  # behavioral check below tests enforcement; this one only tests the
  # file got written.
  result=$(npm config get allow-git)
  [ "$result" = "none" ]
}

@test "npm: allow-git=none blocks git deps behaviorally (npm >=11.9.0 only)" {
  # Behavioral verification of allow-git enforcement: allow-git=none refuses
  # git-URL dependencies. npm reads the key from 11.9.0 (MEASURED: 11.8.0
  # installed a git dependency with it set); below that this test skips.
  printf '%s\n%s\n' 11.9.0 "$(npm --version 2>/dev/null)" | sort -V -C \
    || skip "allow-git enforcement requires npm >= 11.9.0 (got: $(npm --version 2>/dev/null))"

  # Try installing from a git URL that won't resolve — if npm honors
  # allow-git=none it refuses BEFORE attempting any network fetch.
  # If npm doesn't honor (silently ignored), we'd see DNS-resolution
  # errors (ENOTFOUND / getaddrinfo) because npm would attempt the fetch.
  # Distinguishing these two failure modes is what makes this a real
  # behavioral test rather than a config-get-roundtrip.
  cd /tmp && rm -rf allow-git-test && mkdir allow-git-test && cd allow-git-test
  npm init -y >/dev/null 2>&1
  result=$(npm install "git+https://does-not-resolve.invalid/x.git" 2>&1 || true)
  rm -rf /tmp/allow-git-test

  if echo "$result" | grep -qiE "ENOTFOUND|ENETUNREACH|getaddrinfo|could not resolve"; then
    echo "FAIL: npm attempted DNS for the bogus git URL — allow-git=none NOT enforced" >&2
    echo "--- npm output ---" >&2
    echo "$result" >&2
    return 1
  fi
}

# npm_git_project <dir>: a project depending on a one-commit git+file://
# repository, so nothing reaches the network.
npm_git_project() {
  local d="$1" src="$1-src"
  rm -rf "$d" "$src" "$src.git"; mkdir -p "$d" "$src"
  printf '{"name":"gitdep","version":"1.0.0"}\n' > "$src/package.json"
  git -C "$src" init -q && git -C "$src" add -A \
    && git -C "$src" -c user.email=t@t -c user.name=t commit -qm init \
    && git clone -q --bare "$src" "$src.git"
  printf '{"name":"p","version":"1.0.0","private":true,"dependencies":{"gitdep":"git+file://%s"}}\n' "$src.git" > "$d/package.json"
}

@test "npm: with the user config redirected and a project .npmrc allow-git=all, the env layer still refuses a git dependency" {
  # actions/setup-node exports NPM_CONFIG_USERCONFIG at its own .npmrc, so npm
  # skips ~/.npmrc; a project .npmrc can say allow-git=all. NPM_CONFIG_ALLOW_GIT
  # outranks both (MEASURED on npm 11.9.0 to 12.2.3).
  printf '%s\n%s\n' 11.9.0 "$(npm --version 2>/dev/null)" | sort -V -C \
    || skip "npm $(npm --version 2>/dev/null) predates allow-git (11.9.0), so nothing can refuse the dependency"
  command -v git >/dev/null || skip "git not installed"
  local d="$BATS_TEST_TMPDIR/gitproj" rc="$BATS_TEST_TMPDIR/redirected-npmrc"
  npm_git_project "$d"
  printf 'allow-git=all\n' > "$d/.npmrc"
  : > "$rc"
  run env -i PATH="$PATH" HOME="$HOME" bash -c ". /etc/profile.d/supply-chain-hardening.sh; cd '$d' && NPM_CONFIG_USERCONFIG='$rc' npm install --no-audit --no-fund 2>&1"
  [ "$status" -ne 0 ]
  [[ "$output" == *EALLOWGIT* ]] || { echo "refused, but not by allow-git: $output"; return 1; }
  [ ! -e "$d/node_modules/gitdep" ]
}

@test "npm: FIXTURE CONTROL - the same redirect and project .npmrc install the git dependency without the variable" {
  printf '%s\n%s\n' 11.9.0 "$(npm --version 2>/dev/null)" | sort -V -C || skip "npm predates allow-git (11.9.0)"
  command -v git >/dev/null || skip "git not installed"
  local d="$BATS_TEST_TMPDIR/gitproj" rc="$BATS_TEST_TMPDIR/redirected-npmrc"
  npm_git_project "$d"
  printf 'allow-git=all\n' > "$d/.npmrc"
  : > "$rc"
  run env -i PATH="$PATH" HOME="$HOME" bash -c ". /etc/profile.d/supply-chain-hardening.sh; unset NPM_CONFIG_ALLOW_GIT; cd '$d' && NPM_CONFIG_USERCONFIG='$rc' npm install --no-audit --no-fund 2>&1"
  [ "$status" -eq 0 ] || { echo "the fixture did not install: $output"; return 1; }
  [ -e "$d/node_modules/gitdep/package.json" ]
}

@test "npm: config get ignore-scripts returns true" {
  result=$(npm config get ignore-scripts)
  [ "$result" = "true" ]
}
