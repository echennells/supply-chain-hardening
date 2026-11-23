#!/usr/bin/env bats
# harden.sh --suggest — the adoption-time advisor.
#
# WHY THIS IS TESTED AT ALL. --suggest exists because the defaults break
# specific, predictable repos with an error that does not name this action
# (docs/design-principles.md, the attribution test). A wrong suggestion is
# therefore worse than no suggestion: it sends someone to allowlist the wrong
# package while their real breakage stays unexplained.
#
# The two cases that matter most are the boring ones — a clean repo must say
# "nothing needed" and exit 0, and the mode must never write anything.

load helpers

setup() {
  common_setup
  FIX="${BATS_TEST_TMPDIR}/fixture"
  mkdir -p "$FIX"
}

suggest() { harden -- "--suggest=$FIX"; }

@test "a clean repo gets an all-clear, not a crash" {
  # REGRESSION. The known-names fallback ends in a `for` loop whose last
  # iteration's grep returns 1; under `set -o pipefail` that failed the
  # enclosing command substitution and `set -e` killed the run. A repo with
  # no scripted dependencies — the case this mode most needs to answer —
  # printed a header and exited 1 with no advice at all.
  echo '{"name":"x","dependencies":{"lodash":"^4"}}' > "$FIX/package.json"
  run suggest
  [ "$status" -eq 0 ]
  [[ "$output" == *"No exceptions needed"* ]]
}

@test "an empty directory is an all-clear too" {
  run suggest
  [ "$status" -eq 0 ]
  [[ "$output" == *"No exceptions needed"* ]]
}

@test "it changes nothing — advisory mode writes no config" {
  echo '{"name":"x"}' > "$FIX/package.json"
  run suggest
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_HOME/.npmrc" ]
  [ ! -f "$TEST_HOME/.bunfig.toml" ]
}

@test "package-lock hasInstallScript is read as evidence, not guessed" {
  cat > "$FIX/package-lock.json" <<'EOF'
{ "lockfileVersion": 3,
  "packages": {
    "": { "name": "x" },
    "node_modules/esbuild": { "hasInstallScript": true },
    "node_modules/lodash": { "version": "4.17.21" }
  } }
EOF
  run suggest
  [ "$status" -eq 0 ]
  [[ "$output" == *"run code at install time: esbuild."* ]]
  [[ "$output" != *"lodash"* ]]
  # A lockfile answer is exact, so it must NOT carry the floor caveat.
  [[ "$output" != *"floor, not the full set"* ]]
}

@test "an npm project gets an npm fix, not pnpm_built_dependencies (VM#9)" {
  # MEASURED on old main: a package-lock.json repo with sqlite3 was told to set
  # pnpm_built_dependencies. Applying it changed ~/.config/pnpm only, and the
  # binding was still missing. The steps below were measured under the
  # hardening on npm 9.2.0, 11.19.1 and 12.2.3 (see suggest_for_repo).
  cat > "$FIX/package-lock.json" <<'EOF'
{ "packages": { "node_modules/sqlite3": { "hasInstallScript": true },
                "node_modules/sharp":   { "hasInstallScript": true } } }
EOF
  run suggest
  [ "$status" -eq 0 ]
  [[ "$output" != *"pnpm_built_dependencies: '"* ]]
  [[ "$output" == *"no per-package build allowlist for npm"* ]]
  [[ "$output" == *"npm rebuild sharp sqlite3 --ignore-scripts=false"* ]]
  [[ "$output" == *"npm approve-scripts sharp sqlite3"* ]]
}

@test "a pnpm project still gets the pnpm input, and the with: block sits under with:" {
  # The whole point is copy-paste. At 4 spaces it is not valid YAML under the
  # `with:` line printed directly above it, and the first thing the adopter
  # sees is a workflow parse error attributed to us.
  cat > "$FIX/pnpm-lock.yaml" <<'EOF'
lockfileVersion: '9.0'
packages:
  sharp@0.33.0:
    resolution: {integrity: sha512-aaa}
    requiresBuild: true
EOF
  run suggest
  [[ "$output" == *"        with:"* ]]
  [[ "$output" == *"          pnpm_built_dependencies: 'sharp'"* ]]
  [[ "$output" != *"npm rebuild"* ]]
}

@test "a yarn project is told there is no allowlist for it, not handed the pnpm input" {
  echo '{"dependencies":{"sharp":"^0.33"}}' > "$FIX/package.json"
  : > "$FIX/yarn.lock"
  run suggest
  [ "$status" -eq 0 ]
  [[ "$output" != *"pnpm_built_dependencies: '"* ]]
  [[ "$output" == *"no per-package build allowlist for either"* ]]
}

@test "a scoped pnpm package survives the version strip intact" {
  # pnpm quotes scoped keys ('@swc/core@1.4.0':). Stripping @version before
  # the quote left `'@swc/core` — an allowlist entry that matches nothing.
  cat > "$FIX/pnpm-lock.yaml" <<'EOF'
lockfileVersion: '9.0'
packages:
  '@swc/core@1.4.0':
    resolution: {integrity: sha512-aaa}
    requiresBuild: true
  lodash@4.17.21:
    resolution: {integrity: sha512-bbb}
snapshots: {}
EOF
  run suggest
  [ "$status" -eq 0 ]
  [[ "$output" == *"'@swc/core'"* ]]
  [[ "$output" != *"'@swc/core@1.4.0"* ]]
}

@test "with no lockfile the known-names scan is labelled as a floor" {
  echo '{"dependencies":{"sharp":"^0.33","lodash":"^4"}}' > "$FIX/package.json"
  run suggest
  [ "$status" -eq 0 ]
  [[ "$output" == *"sharp"* ]]
  [[ "$output" == *"floor, not the full set"* ]]
}

@test "the repo's own prepare script is called out — ignore-scripts skips it too" {
  # ignore-scripts is not dependency-only: `npm ci` also skips the root
  # package's prepare, which is how husky and patch-package stop running.
  # That failure surfaces later, elsewhere, with nothing pointing back here.
  echo '{"scripts":{"prepare":"husky","build":"tsc"}}' > "$FIX/package.json"
  run suggest
  [ "$status" -eq 0 ]
  [[ "$output" == *"prepare"* ]]
  [[ "$output" == *"will NOT run these"* ]]
}

@test "composer plugins are surfaced" {
  echo '{"config":{"allow-plugins":{"composer/installers":true}}}' > "$FIX/composer.json"
  run suggest
  [ "$status" -eq 0 ]
  [[ "$output" == *"composer_allow_plugins: 'true'"* ]]
}

@test "a Rust repo is told the age gate is inert without the backend" {
  echo '[package]' > "$FIX/Cargo.toml"
  run suggest
  [ "$status" -eq 0 ]
  [[ "$output" == *"install_cargo_cooldown: 'true'"* ]]
}

@test "Python gets a heads-up, not a fabricated finding" {
  # Whether a dependency has a wheel cannot be known without the network, so
  # this must never appear as a with: input.
  echo '[project]' > "$FIX/pyproject.toml"
  run suggest
  [ "$status" -eq 0 ]
  [[ "$output" == *"only-binary"* ]]
  [[ "$output" == *"heads-up rather than a finding"* ]]
}

@test "every suggestion ends by restating the ordering rule" {
  echo '[package]' > "$FIX/Cargo.toml"
  run suggest
  [[ "$output" == *"setup-* steps first"* ]]
}

@test "a path that is not a directory fails loudly" {
  run harden -- --suggest=/nonexistent-path-for-tests
  [ "$status" -eq 2 ]
  [[ "$output" == *"is not a directory"* ]]
}

@test "--suggest is advertised in --help" {
  run harden -- --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"--suggest"* ]]
}

# ------------------------------------------------------------- the Ansible form

@test "the same exceptions are printed as Ansible extra vars, as JSON" {
  # pnpm_built_dependencies is a list in the role: `-e pnpm_built_dependencies=a,b`
  # would hand it a string, and the role would loop over its characters.
  cat > "$FIX/pnpm-lock.yaml" <<'YML'
lockfileVersion: '9.0'
packages:
  '@swc/core@1.4.0':
    requiresBuild: true
  sharp@0.33.0:
    requiresBuild: true
YML
  echo '{"config":{"allow-plugins":{"composer/installers":true}}}' > "$FIX/composer.json"
  run suggest
  [ "$status" -eq 0 ]
  [[ "$output" == *"          pnpm_built_dependencies: '@swc/core,sharp'"* ]]
  local line; line=$(grep -m1 "ansible-playbook" <<<"$output")
  [[ "$line" == *"site.yml --limit localhost -e '{"* ]] || { echo "$line"; return 1; }
  # The extra vars parse, and they are what the role defines: a list and a bool.
  local ev; ev=$(sed "s/.*-e '\(.*\)'$/\1/" <<<"$line")
  python3 - "$ev" "${BATS_TEST_DIRNAME}/../../defaults/main.yml" <<'PY'
import json, re, sys
d = json.loads(sys.argv[1])
assert d == {"pnpm_built_dependencies": ["@swc/core", "sharp"], "composer_allow_plugins": True}, d
src = open(sys.argv[2]).read()
assert re.search(r"(?m)^pnpm_built_dependencies: \[\]", src) and re.search(r"(?m)^composer_allow_plugins: false", src)
PY
}

@test "a clean repo needs no Ansible extra vars, and says so" {
  echo '{"dependencies":{"lodash":"^4"}}' > "$FIX/package.json"
  run suggest
  [ "$status" -eq 0 ]
  [[ "$output" == *"no extra vars are needed"* ]]
  [[ "$output" == *"ansible-playbook site.yml --limit localhost"* ]]
  [[ "$output" != *" -e "* ]]
}

@test "a Rust repo gets the role's cargo-cooldown note instead of an extra var" {
  # install_cargo_cooldown is an action input; the role builds cargo-cooldown by
  # default (cargo_cooldown_enforce: true in defaults/main.yml).
  echo '[package]' > "$FIX/Cargo.toml"
  run suggest
  [[ "$output" == *"install_cargo_cooldown: 'true'"* ]]
  [[ "$output" == *"cargo_cooldown_enforce=true"* ]]
  grep -q '^cargo_cooldown_enforce: true' "${BATS_TEST_DIRNAME}/../../defaults/main.yml"
}

# ------------------------------------------------- repo-local config, as files

# One line of the overrides list for file $1.
ov() { grep -F "  - $1: " <<<"$output"; }

@test "overrides: a repo with none says none was found, and where it looked" {
  echo '{"name":"x"}' > "$FIX/package.json"
  run suggest
  [ "$status" -eq 0 ]
  [[ "$output" == *"Repo-local config that outranks the host's: none found at the top of the repo"* ]]
}

@test "overrides: a project .npmrc is listed by key, with what outranks it, and never its tokens" {
  printf '%s\n' '; comment' 'ignore-scripts = false' 'min-release-age=0' 'min-release-age-exclude[]=lodash' \
    'allow-git=all' '//registry.npmjs.org/:_authToken=npm_SECRET123' 'audit=false' > "$FIX/.npmrc"
  run suggest
  [ "$status" -eq 0 ]
  [[ "$(ov .npmrc)" == *".npmrc: ignore-scripts=false — this project's npm runs install scripts"*"NPM_CONFIG_IGNORE_SCRIPTS outranks it"* ]]
  [[ "$(ov .npmrc)" == *".npmrc: min-release-age=0 — "* ]]
  [[ "$(ov .npmrc)" == *".npmrc: min-release-age-exclude[]=lodash — "*"Not closed by the role or the action."* ]]
  [[ "$(ov .npmrc)" == *".npmrc: allow-git=all — "*"NPM_CONFIG_ALLOW_GIT=none"* ]]
  [[ "$output" != *"SECRET123"* ]]
  [[ "$output" != *"audit=false"* ]]
}

@test "overrides: uv.toml and pyproject [tool.uv], tables and dotted keys included" {
  printf '%s\n' '[project]' 'name = "x"' '[tool.uv]' 'no-build = false' 'exclude-newer = "2099-01-01T00:00:00Z"' \
    '[tool.uv.exclude-newer-package]' 'foo = "2099-01-01"' > "$FIX/pyproject.toml"
  run suggest
  [[ "$(ov pyproject.toml)" == *"tool.uv.no-build = false"*"Not closed by the role or the action."* ]]
  [[ "$(ov pyproject.toml)" == *'tool.uv.exclude-newer = "2099-01-01T00:00:00Z"'*"uv_exclude_newer_env (agent_host turns it on)"* ]]
  [[ "$(ov pyproject.toml)" == *"tool.uv.exclude-newer-package (a table)"* ]]
  # uv reads uv.toml instead of [tool.uv] when both are there.
  printf 'no-build = false\npip.exclude-newer = "2099-01-01"\n' > "$FIX/uv.toml"
  run suggest
  [[ "$(ov uv.toml)" == *"no-build = false"* ]]
  [[ "$(ov uv.toml)" == *'pip.exclude-newer = "2099-01-01"'*"was not measured"* ]]
  [ -z "$(ov pyproject.toml)" ]
}

@test "overrides: pnpm-workspace.yaml, .yarnrc.yml and .bundle/config, lists and quoted keys included" {
  printf '%s\n' 'packages:' '  - "packages/*"' 'minimumReleaseAge: 0 # why' 'minimumReleaseAgeExclude:' '  - lodash' "  - '@foo/bar'" 'ignoreScripts: false' > "$FIX/pnpm-workspace.yaml"
  printf '%s\n' 'yarnPath: .yarn/releases/yarn-4.0.0.cjs' '"enableScripts": true' 'npmMinimalAgeGate: 0' 'npmPreapprovedPackages:' '- "left-pad"' 'plugins:' '  - path: .yarn/plugins/x.cjs' > "$FIX/.yarnrc.yml"
  mkdir -p "$FIX/.bundle"
  printf '%s\n' '---' 'BUNDLE_COOLDOWN: "0"' 'BUNDLE_FROZEN: "false"' 'BUNDLE_GEMS__CONTRIBSYS__COM: "user:SECRETPASS"' > "$FIX/.bundle/config"
  run suggest
  [[ "$(ov pnpm-workspace.yaml)" == *"minimumReleaseAge: 0 — "*"pnpm_config_minimum_release_age outranks it"* ]]
  [[ "$(ov pnpm-workspace.yaml)" == *"minimumReleaseAgeExclude: [lodash, @foo/bar] — "* ]]
  [[ "$(ov pnpm-workspace.yaml)" == *"ignoreScripts: false — "*"Not closed"* ]]
  [[ "$(ov .yarnrc.yml)" == *"enableScripts: true — "* ]]
  [[ "$(ov .yarnrc.yml)" == *"npmMinimalAgeGate: 0 — "* ]]
  [[ "$(ov .yarnrc.yml)" == *"npmPreapprovedPackages: [left-pad] — "* ]]
  [[ "$(ov .yarnrc.yml)" == *"yarnPath: .yarn/releases/yarn-4.0.0.cjs — "* ]]
  [[ "$(ov .yarnrc.yml)" == *"plugins: [path: .yarn/plugins/x.cjs] — "* ]]
  [[ "$(ov .bundle/config)" == *'BUNDLE_COOLDOWN: "0" — '* ]]
  [[ "$(ov .bundle/config)" == *'BUNDLE_FROZEN: "false" — '* ]]
  [[ "$output" != *"SECRETPASS"* ]]
  [[ "$output" != *"packages/"* ]]
}

@test "overrides: composer.json config.policy, and an unreadable composer.json is said so" {
  command -v python3 >/dev/null 2>&1 || skip "python3 not installed"
  echo '{"name":"t/t","config":{"policy":{"cooldown":{"ignore":["*"],"period":null}}}}' > "$FIX/composer.json"
  run suggest
  [[ "$(ov composer.json)" == *'config.policy.cooldown.ignore = ["*"]'*"Not closed"* ]]
  [[ "$(ov composer.json)" == *'config.policy.cooldown.period = null'*"COMPOSER_POLICY_COOLDOWN_PERIOD and _BLOCK outrank it"* ]]
  echo '{"name":"t/t","config":{"policy":false}}' > "$FIX/composer.json"
  run suggest
  [[ "$(ov composer.json)" == *'config.policy = false'* ]]
  echo '{"name":"t/t","config":' > "$FIX/composer.json"
  run suggest
  [[ "$(ov composer.json)" == *"unreadable: "* ]]
}

@test "overrides: the interpreter that reads composer.json is started from /, not in the repo" {
  # A pyenv/asdf/mise python3 is a shim that reads the working directory.
  stub_bin python3 "pwd >> '$BATS_TEST_TMPDIR/pycwd'; exit 0"
  echo '{"name":"t/t","config":{"policy":false}}' > "$FIX/composer.json"
  ( cd "$FIX" && harden -- --suggest=. >/dev/null )
  [ -s "$BATS_TEST_TMPDIR/pycwd" ]
  [ "$(sort -u "$BATS_TEST_TMPDIR/pycwd")" = / ]
}

@test "overrides: cargo's repo-local files, the classic yarn rc, and a toolchain path" {
  mkdir -p "$FIX/.cargo"
  printf '%s\n' '[build]' 'rustc-wrapper = "./w"' '[alias]' 'b = "build"' '[source.crates-io]' 'replace-with = "m"' > "$FIX/.cargo/config.toml"
  printf '%s\n' '# a comment' '[allow.global]' 'minutes = 0' > "$FIX/cooldown.toml"
  printf '%s\n' '[toolchain]' 'path = "./tc"' > "$FIX/rust-toolchain.toml"
  printf '%s\n' 'yarn-path ".yarn/releases/yarn-1.22.0.cjs"' > "$FIX/.yarnrc"
  run suggest
  [[ "$(ov .cargo/config.toml)" == *'build.rustc-wrapper = "./w"; tables: alias, build, source.crates-io — '*"Not closed"* ]]
  [[ "$(ov cooldown.toml)" == *"[allow.global]; minutes = 0 — "* ]]
  [[ "$(ov cooldown.toml)" != *"a comment"* ]]
  [[ "$(ov rust-toolchain.toml)" == *'toolchain.path = "./tc" — '* ]]
  [[ "$(ov .yarnrc)" == *"yarn-path"* ]]
}

@test "overrides: escape sequences in a file reach the output as plain text" {
  printf 'ignore-scripts=false\x1b]0;pwned\x07\n' > "$FIX/.npmrc"
  run suggest
  [[ "$(ov .npmrc)" == *"ignore-scripts=false"* ]]
  ! grep -q $'\x1b' <<<"$output"
}

# The tools follow every spelling their format allows, and a repository that
# wants a gate off picks one this reader does not. Each form was MEASURED to be
# honoured, most of them on the tool named here (action/harden.sh, "repo-local
# config"). What must never happen is "none found".
@test "overrides: a spelling the readers do not follow is reported as not read, never as none found" {
  local n=0 c f body
  while IFS='|' read -r c f body; do
    [ -n "$c" ] || continue
    rm -rf "$FIX"; mkdir -p "$FIX"
    printf -- "$body" > "$FIX/$f"
    run suggest
    [ "$status" -eq 0 ] || { echo "$c: rc $status: $output"; return 1; }
    [[ "$output" != *"none found at the top of the repo"* ]] || { echo "$c: reported as none found"; return 1; }
    [ -n "$(ov "$f")" ] || { echo "$c: $f not listed: $output"; return 1; }
    n=$((n + 1))
  done <<'CASES'
toml inline table|pyproject.toml|[tool]\nuv = { no-build = false, exclude-newer = "2099-01-01" }\n
toml inline at the top|pyproject.toml|tool = { uv = { no-build = false } }\n
toml inline in uv.toml|uv.toml|pip = { no-build = false }\n
toml escaped key|pyproject.toml|[tool.uv]\n"exclude\\u002dnewer" = "2099-01-01"\n
toml escaped table|pyproject.toml|[tool."u\\u0076"]\nno-build-x = 1\n
toml byte-order mark|uv.toml|\357\273\277no-build = false\n
bunfig inline table|bunfig.toml|install = { minimumReleaseAge = 0 }\n
yaml flow document|pnpm-workspace.yaml|{minimumReleaseAge: 0, ignoreScripts: false}\n
yaml after a document marker|.yarnrc.yml|--- {enableScripts: true}\n
yaml indented top level|.yarnrc.yml|  enableScripts: true\n  npmMinimalAgeGate: 0\n
yaml escaped key|.yarnrc.yml|"enable\\x53cripts": true\n
yaml complex key|.yarnrc.yml|? "enable\\x53cripts"\n: true\n
yaml tagged key|pnpm-workspace.yaml|!!str minimumReleaseAge: 0\n
yaml merge|pnpm-workspace.yaml|x: &a\n  ignoreScripts: false\n<<: *a\n
yaml byte-order mark|.yarnrc.yml|\357\273\277enableScripts: true\n
yaml lone CR|.yarnrc.yml|# c\renableScripts: true\r
yaml aliased key|.yarnrc.yml|nodeLinker: &k "enable\\x53cripts"\n*k : true\n
yarn 1 format|.yarnrc.yml|# yarn lockfile v1\n"enable\\u0053cripts" true\n
npmrc quoted key|.npmrc|"ignore-scripts"=false\n
npmrc escaped key|.npmrc|"ignore\\u002dscripts"=false\n
npmrc variable in the key|.npmrc|ignore-${NOPE?}scripts=false\n
npmrc lone CR|.npmrc|# c\rignore-scripts=false\r
npmrc byte-order mark|.npmrc|\357\273\277ignore-scripts=false\n
npmrc a second, unread one|.npmrc|ignore-scripts=true\n"ignore\\u002dscripts"=false\n
yarn 1 quoted key|.yarnrc|"yarn-path" "./x.cjs"\n
yarn 1 escaped key|.yarnrc|"yarn\\u002dpath" "./x.cjs"\n
CASES
  [ "$n" -eq 26 ]
}

# The other side: what an ordinary repo holds must not be reported as odd, or the
# line stops meaning anything.
@test "overrides: comments, tokens and regexes in ordinary files are not reported as unread" {
  printf '%s\n' '//registry.npmjs.org/:_authToken=${NPM_TOKEN}' 'audit=false' '# ignore-scripts=false' '; min-release-age=0' 'save-exact' > "$FIX/.npmrc"
  printf '%s\n' 'packages:' '  - "packages/*"' '# ignoreScripts: false' 'catalog:' '  react: ^19.0.0' > "$FIX/pnpm-workspace.yaml"
  printf '%s\n' '[project]' 'name = "x"' '[tool.coverage.report]' 'exclude_lines = ["if \\.x", "\\.py"]' '[tool.ruff]' 'extend-exclude = ["\\.foo"]' '[tool.uv]' 'dev-dependencies = ["no-build-isolation-x"]' > "$FIX/pyproject.toml"
  printf '%s\n' 'nodeLinker: node-modules' 'npmScopes:' '  acme:' '    npmRegistryServer: "https://npm.example"' > "$FIX/.yarnrc.yml"
  printf '%s\r\n' '[install]' 'exact = true' > "$FIX/bunfig.toml"
  run suggest
  [ "$status" -eq 0 ]
  [[ "$output" == *"none found at the top of the repo"* ]] || { echo "$output"; return 1; }
}

@test "overrides: bunfig.toml and poetry.toml" {
  printf '%s\n' '[install]' 'minimumReleaseAge = 0' 'minimumReleaseAgeExcludes = ["left-pad"]' 'ignoreScripts = false' > "$FIX/bunfig.toml"
  printf '%s\n' '[solver]' 'min-release-age = 0' 'min-release-age-exclude = ["requests"]' > "$FIX/poetry.toml"
  run suggest
  [[ "$(ov bunfig.toml)" == *"install.minimumReleaseAge = 0 — this project's Bun age gate"*"Not closed"* ]]
  [[ "$(ov bunfig.toml)" == *'install.minimumReleaseAgeExcludes = ["left-pad"] — '* ]]
  [[ "$(ov bunfig.toml)" == *"install.ignoreScripts = false — "* ]]
  [[ "$(ov poetry.toml)" == *"solver.min-release-age = 0 — "*"POETRY_SOLVER_MIN_RELEASE_AGE outranks it"* ]]
  [[ "$(ov poetry.toml)" == *'solver.min-release-age-exclude = ["requests"] — '*"Not closed"* ]]
}

# What a file says is printed, so a link must not turn this into a way to print
# some other file: an agent shows this output to people, and a CI job logs it.
@test "overrides: a symlink is reported and never followed" {
  local secret="$BATS_TEST_TMPDIR/secret" f
  mkdir -p "$secret"
  printf '%s\n' '[default]' 'aws_secret_access_key = LEAKME123' 'ignore-scripts=LEAKME123' 'enableScripts: LEAKME123' 'no-build = "LEAKME123"' 'yarn-path LEAKME123' > "$secret/creds"
  cp "$secret/creds" "$secret/config"; cp "$secret/creds" "$secret/config.toml"
  for f in cooldown.toml .npmrc uv.toml pyproject.toml bunfig.toml poetry.toml pnpm-workspace.yaml .yarnrc.yml .yarnrc composer.json rust-toolchain.toml rust-toolchain; do
    ln -s "$secret/creds" "$FIX/$f"
  done
  ln -s "$secret" "$FIX/.cargo"
  ln -s "$secret" "$FIX/.bundle"
  run suggest
  [ "$status" -eq 0 ]
  [[ "$output" != *"LEAKME123"* ]] || { echo "$output"; return 1; }
  for f in cooldown.toml .npmrc uv.toml pyproject.toml bunfig.toml poetry.toml pnpm-workspace.yaml .yarnrc.yml .yarnrc composer.json rust-toolchain.toml .cargo/config.toml .bundle/config; do
    [[ "$(ov "$f")" == *"a symlink to "* ]] || { echo "$f: not reported: $output"; return 1; }
  done
}

@test "overrides: a file that cannot be read is said so" {
  [ "$(id -u)" -ne 0 ] || skip "root reads everything"
  printf 'ignore-scripts=false\n' > "$FIX/.npmrc"
  chmod 000 "$FIX/.npmrc"
  run suggest
  chmod 600 "$FIX/.npmrc"
  [[ "$(ov .npmrc)" == *"not readable"* ]]
}

@test "a package name that no registry package can have is never printed into a command" {
  echo '{"name":"x"}' > "$FIX/package.json"
  printf 'lockfileVersion: 9\npackages:\n  esbuild@1.0.0:\n    requiresBuild: true\n  $(touch${IFS}x)@1:\n    requiresBuild: true\n  --ignore-scripts=false@1:\n    requiresBuild: true\n  bad\033]0;t\007name@1:\n    requiresBuild: true\n' > "$FIX/pnpm-lock.yaml"
  run suggest
  [ "$status" -eq 0 ]
  [[ "$output" == *"pnpm_built_dependencies: 'esbuild'"* ]] || { echo "$output"; return 1; }
  [[ "$output" == *"whose name no registry package can have: 3."* ]] || { echo "$output"; return 1; }
  [[ "$output" != *'$(touch'* ]]
  ! grep -q $'\x1b' <<<"$output"
}

@test "suggest runs nothing in the repo, and no package manager at all" {
  # Every tool a repo's config can name, stubbed first on PATH to record a run.
  # python3 is the one the script may use (an isolated interpreter on a file
  # path); a pip.py or a sitecustomize in the repo must not reach it.
  local t
  for t in npm npx pnpm yarn bun bunx uv pip pip3 composer php cargo rustc bundle bundler gem go mvn gradle dotnet deno poetry node git; do
    stub_bin "$t" "echo '$t' >> '$BATS_TEST_TMPDIR/ran'"
  done
  printf 'ignore-scripts=false\n' > "$FIX/.npmrc"
  printf '[tool.uv]\nno-build = false\n' > "$FIX/pyproject.toml"
  echo '{"name":"t/t","config":{"policy":false},"require":{"composer/installers":"*"}}' > "$FIX/composer.json"
  printf 'import os; open("%s", "w").write("ran")\n' "$BATS_TEST_TMPDIR/pyran" > "$FIX/json.py"
  cp "$FIX/json.py" "$FIX/sitecustomize.py"
  ( cd "$FIX" && run suggest && [ "$status" -eq 0 ] && [[ "$output" == *"config.policy = false"* ]] )
  [ ! -e "$BATS_TEST_TMPDIR/ran" ] || { cat "$BATS_TEST_TMPDIR/ran"; return 1; }
  [ ! -e "$BATS_TEST_TMPDIR/pyran" ]
}
