#!/usr/bin/env bats
# The env variables that outrank a project's OWN config, and the ones the role
# deliberately does not export.
#
# A project-directory config (uv.toml, pyproject.toml [tool.uv],
# pnpm-workspace.yaml) outranks the ~ and /etc files the role writes, so a
# repository can switch the age gate off for every command run inside it. An
# environment variable outranks the project (MEASURED 2026-11-20/21):
#   pnpm 11+  pnpm_config_minimum_release_age and _exclude (11.0.0 to 12.21.0)
#             -> exported by default, in /etc/profile.d and /etc/environment
#   uv        UV_EXCLUDE_NEWER (0.8.17 to 0.13.9)
#             -> opt-in (uv_exclude_newer_env): it also outranks a project that
#                pins an EARLIER cutoff so its uv.lock checks clean on every
#                host, and uv records the cutoff in uv.lock (defaults/main.yml)
# Not exported, and pinned here so nobody adds them back unmeasured:
#   pnpm_config_ignore_scripts  true silently skips a build the project approved
#                               (its own ignoreScripts: false + allowBuilds);
#                               false overrides a project's own true
#   UV_NO_BUILD                 no `uv pip` command reads it, so the pip wrapper
#                               is not covered, and it breaks
#                               supply-chain-allow-build (docs/limitations.md)
#
# The image applies the role with its defaults, so the opt-in uv variable is
# exercised through the shipped templates rendered with uv_exclude_newer_env on,
# then sourced the way a login shell sources /etc/profile.d.
#
# Network: the uv and pnpm resolution tests ask PyPI and the npm registry, and
# skip when they cannot (offline). The uv ones use a historical cutoff, so the
# expected version does not move: under 2024-10-15T00:00:00Z the newest
# packaging is 24.1 (24.2 came out 2024-11-08) and the newest idna is 3.10.

load setup

VERIFY=/usr/local/bin/supply-chain-verify
RENDER_DIR=/tmp/env-layer-render
UVCUT=2024-10-15T00:00:00Z
INSTANT_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}([.][0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$'

setup_file() {
  rm -rf "$RENDER_DIR"; mkdir -p "$RENDER_DIR"
  command -v ansible-playbook >/dev/null 2>&1 || return 0
  local pb="$RENDER_DIR/render.yml"
  # vars_files, not include_vars: task vars outrank vars_files, so each task can
  # change one knob while every derived value is still the shipped expression.
  cat > "$pb" <<'YML'
- hosts: localhost
  connection: local
  gather_facts: false
  vars_files: ["{{ role_dir }}/defaults/main.yml"]
  vars:
    env_t: "{{ role_dir }}/templates/supply-chain-env.sh.j2"
    refresh_t: "{{ role_dir }}/templates/age-gate-refresh.sh.j2"
    npm_files:
      - { t: supply-chain-env.sh.j2, e: sh }
      - { t: npmrc.j2, e: npmrc }
      - { t: etc-npmrc.j2, e: etc-npmrc }
    # What tasks/npm_versions.yml prints: the npm in use first, then the others;
    # "-" for one that does not say its version, nothing for none.
    npm_hosts:
      - { n: none, v: [] }
      - { n: unreadable, v: ["-"] }
      - { n: 9.2.0, v: ["9.2.0"] }
      - { n: 10.9.8, v: ["10.9.8"] }
      - { n: 11.1.0, v: ["11.1.0"] }
      - { n: 11.2.0, v: ["11.2.0"] }
      - { n: 11.8.0, v: ["11.8.0"] }
      - { n: 11.9.0, v: ["11.9.0"] }
      - { n: 11.10.0, v: ["11.10.0"] }
      - { n: 12.2.3, v: ["12.2.3"] }
      - { n: old-and-new, v: ["11.5.1", "11.19.1"] }
      - { n: old-and-11.9.0, v: ["11.5.1", "11.9.0"] }
      - { n: silent-in-use, v: ["9.2.0", "11.5.1"] }
      - { n: warning-in-use, v: ["11.5.1", "9.2.0"] }
  tasks:
    - ansible.builtin.setup: { gather_subset: [min] }
    - ansible.builtin.template: { src: "{{ env_t }}", dest: "{{ out }}/default.sh" }
    - ansible.builtin.template: { src: "{{ env_t }}", dest: "{{ out }}/optin-rolling.sh" }
      vars: { uv_exclude_newer_env: true }
    - ansible.builtin.template: { src: "{{ role_dir }}/templates/uv.toml.j2", dest: "{{ out }}/optin-rolling-uv.toml" }
      vars: { uv_exclude_newer_env: true }
    - ansible.builtin.template: { src: "{{ env_t }}", dest: "{{ out }}/optin-pinned.sh" }
      vars: { uv_exclude_newer_env: true, uv_exclude_newer: "2024-10-15T00:00:00Z" }
    - ansible.builtin.template: { src: "{{ env_t }}", dest: "{{ out }}/pin-{{ item.n }}.sh" }
      vars: { uv_exclude_newer_env: true, uv_exclude_newer: "{{ item.v }}" }
      loop:
        - { n: span-days, v: "2 days" }
        - { n: span-hours, v: "48 hours" }
        - { n: iso-duration, v: "P2D" }
        - { n: date, v: "2026-10-19" }
        - { n: offset, v: "2026-10-19T00:00:00+02:00" }
        - { n: fraction, v: "2026-10-19T00:00:00.5Z" }
    - ansible.builtin.template: { src: "{{ env_t }}", dest: "{{ out }}/exclude.sh" }
      vars: { pnpm_minimum_release_age_exclude: ["@myorg/internal", "left-pad"] }
    - ansible.builtin.template: { src: "{{ env_t }}", dest: "{{ out }}/allow.sh" }
      vars: { pnpm_built_dependencies: ["esbuild"] }
    - ansible.builtin.template: { src: "{{ role_dir }}/templates/{{ item.0.t }}", dest: "{{ out }}/npm-{{ item.1.n }}.{{ item.0.e }}" }
      vars: { sch_npm_versions_probe: { stdout_lines: "{{ item.1.v }}" } }
      loop: "{{ npm_files | product(npm_hosts) | list }}"
    - ansible.builtin.template: { src: "{{ refresh_t }}", dest: "{{ out }}/refresh-optin", mode: "0755" }
      vars: { uv_exclude_newer_env: true, sch_refresh_uv: true, sch_refresh_pip: true, socket_firewall_install: false }
    - ansible.builtin.template: { src: "{{ refresh_t }}", dest: "{{ out }}/refresh-default", mode: "0755" }
      vars: { sch_refresh_uv: true, sch_refresh_pip: true, socket_firewall_install: false }
YML
  ansible-playbook -i 'localhost,' -c local "$pb" -e "role_dir=$ROLE_DIR" -e "out=$RENDER_DIR" \
    </dev/null > "$RENDER_DIR/render.log" 2>&1 || true
}

needs_render() {
  [ -s "$RENDER_DIR/${1:-default.sh}" ] || skip "no render of ${1:-default.sh} (ansible-playbook unavailable, or the render failed: see $RENDER_DIR/render.log)"
}

# What a login shell gets from a rendered profile.d file: run "$@" after
# sourcing it, in an otherwise clean environment.
with_profile() { # file cmd...
  local f="$1"; shift
  env -i PATH="$PATH" HOME="$HOME" bash -c 'set -a; . "$1"; set +a; shift; exec "$@"' _ "$f" "$@"
}

uv_line() { grep -E '^export UV_EXCLUDE_NEWER=' "$1"; }

# ---------------------------------------------------------------- render -----

@test "render: UV_EXCLUDE_NEWER is not exported by default, in either env file" {
  needs_render
  [ -z "$(uv_line "$RENDER_DIR/default.sh")" ]
  # The image applied the role with the defaults.
  [ "$(grep -c 'UV_EXCLUDE_NEWER=' /etc/profile.d/supply-chain-hardening.sh)" = 0 ]
  [ "$(grep -c 'UV_EXCLUDE_NEWER' /etc/environment)" = 0 ]
}

@test "render: opted in, the rolling cutoff is exported, and it is the instant uv.toml gets" {
  needs_render optin-rolling.sh
  local line v
  line=$(uv_line "$RENDER_DIR/optin-rolling.sh")
  [[ "$line" =~ ^export\ UV_EXCLUDE_NEWER=([0-9]{4}-[0-9]{2}-[0-9]{2}T00:00:00Z)$ ]]
  v=${BASH_REMATCH[1]}
  grep -qx "exclude-newer = \"$v\"" "$RENDER_DIR/optin-rolling-uv.toml"
  # The pip gate shares the clock.
  grep -qx "export PIP_UPLOADED_PRIOR_TO=$v" "$RENDER_DIR/optin-rolling.sh"
}

@test "render: opted in, a pinned instant is exported exactly as pinned" {
  needs_render optin-pinned.sh
  [ "$(uv_line "$RENDER_DIR/optin-pinned.sh")" = "export UV_EXCLUDE_NEWER=$UVCUT" ]
  [ "$(uv_line "$RENDER_DIR/pin-offset.sh")" = "export UV_EXCLUDE_NEWER=2026-10-19T00:00:00+02:00" ]
  [ "$(uv_line "$RENDER_DIR/pin-fraction.sh")" = "export UV_EXCLUDE_NEWER=2026-10-19T00:00:00.5Z" ]
}

@test "render: a span, an ISO duration or a bare date is never exported, and no render is empty" {
  # An empty UV_EXCLUDE_NEWER is exit 2 on every uv; "48 hours" is exit 2 on
  # uv 0.9.16 and older, for every uv command (MEASURED). A date is local time.
  needs_render pin-span-days.sh
  local f
  for f in span-days span-hours iso-duration date; do
    [ -z "$(uv_line "$RENDER_DIR/pin-$f.sh")" ] || { echo "pin-$f exported: $(uv_line "$RENDER_DIR/pin-$f.sh")" >&2; return 1; }
  done
  for f in "$RENDER_DIR"/*.sh; do
    sh -n "$f"
    # Every UV_EXCLUDE_NEWER a render can produce, as the shell sees it.
    v=$(with_profile "$f" printenv UV_EXCLUDE_NEWER || true)
    if [ -n "$(uv_line "$f")" ]; then
      [[ "$v" =~ $INSTANT_RE ]] || { echo "$f: UV_EXCLUDE_NEWER='$v' is not an absolute instant" >&2; return 1; }
    else
      [ -z "$(with_profile "$f" sh -c 'echo ${UV_EXCLUDE_NEWER+set}')" ]
    fi
  done
}

@test "render: pnpm's variables are lower case, the exclude list is the operator's own JSON, ignore_scripts never" {
  needs_render exclude.sh
  grep -qx 'export pnpm_config_minimum_release_age=2880' "$RENDER_DIR/default.sh"
  [ "$(with_profile "$RENDER_DIR/default.sh" printenv pnpm_config_minimum_release_age_exclude)" = "[]" ]
  run with_profile "$RENDER_DIR/exclude.sh" python3 -c \
    'import json,os; print(json.loads(os.environ["pnpm_config_minimum_release_age_exclude"]))'
  [ "$status" -eq 0 ]
  [ "$output" = "['@myorg/internal', 'left-pad']" ]
  grep -qx "export pnpm_config_minimum_release_age_exclude='\[\"@myorg/internal\",\"left-pad\"\]'" "$RENDER_DIR/exclude.sh"
  local f
  for f in default.sh exclude.sh allow.sh optin-rolling.sh; do
    [ "$(grep -cE '^[[:space:]]*export[[:space:]]+(pnpm_config_ignore_scripts|PNPM_CONFIG_)' "$RENDER_DIR/$f")" = 0 ]
  done
}

@test "render: min-release-age and allow-git are left out of the npmrc files and the env layer exactly where npm warns about them" {
  # MEASURED: npm 11.2.0 to 11.9.0 warn on every command about a key they do not
  # know, older npm says nothing, and allow-git is known from 11.9.0,
  # min-release-age from 11.10.0. With several npms the one in use decides, unless
  # another one knows the key.
  needs_render npm-11.9.0.sh
  local c n want a g f
  for c in none:11 unreadable:11 9.2.0:11 10.9.8:11 11.1.0:11 11.2.0:00 11.8.0:00 11.9.0:01 11.10.0:11 12.2.3:11 \
           old-and-new:11 old-and-11.9.0:01 silent-in-use:11 warning-in-use:00; do
    n=${c%:*}; want=${c##*:}
    for f in "$RENDER_DIR/npm-$n.npmrc" "$RENDER_DIR/npm-$n.etc-npmrc"; do
      a=0; g=0
      grep -qx 'min-release-age=2' "$f" && a=1
      grep -qx 'allow-git=none' "$f" && g=1
      [ "$a$g" = "$want" ] || { echo "$f: min-release-age=$a allow-git=$g, expected $want" >&2; return 1; }
      grep -qx 'ignore-scripts=true' "$f"
    done
    f="$RENDER_DIR/npm-$n.sh"; a=0; g=0
    grep -qx 'export NPM_CONFIG_MIN_RELEASE_AGE=2' "$f" && a=1
    grep -qx 'export NPM_CONFIG_ALLOW_GIT=none' "$f" && g=1
    [ "$a$g" = "$want" ] || { echo "$f: min-release-age=$a allow-git=$g, expected $want" >&2; return 1; }
  done
  # The default render is the host's own npm, through the same expressions.
  grep -qx 'export NPM_CONFIG_IGNORE_SCRIPTS=true' "$RENDER_DIR/default.sh"
}

@test "deployed: /etc/environment has pnpm's age and empty exclude list; no UV_NO_BUILD or ignore_scripts anywhere" {
  assert_file_contains /etc/environment '^pnpm_config_minimum_release_age=2880$'
  assert_file_contains /etc/environment '^pnpm_config_minimum_release_age_exclude=\[\]$'
  [ "$(grep -c 'ignore_scripts\|UV_NO_BUILD' /etc/environment)" = 0 ]
  [ "$(grep -cE '^[[:space:]]*export[[:space:]]+(UV_NO_BUILD|pnpm_config_ignore_scripts)' /etc/profile.d/supply-chain-hardening.sh)" = 0 ]
}

# ---------------------------------------------------------------- refresh ----

@test "refresher: opted in, it advances the profile.d UV_EXCLUDE_NEWER line as it does the pip one" {
  needs_render refresh-optin
  require_root "rewrites /etc/profile.d, /etc/uv/uv.toml and /etc/pip.conf"
  # Without the opt-in the refresher never names the variable.
  [ "$(grep -c 'UV_EXCLUDE_NEWER=' "$RENDER_DIR/refresh-default")" = 0 ]
  [ "$(grep -c 'UV_EXCLUDE_NEWER=' /usr/local/sbin/supply-chain-age-gate-refresh)" = 0 ]
  grep -q 'advance /etc/profile.d/supply-chain-hardening.sh "^export UV_EXCLUDE_NEWER=' "$RENDER_DIR/refresh-optin"
  local f bak="$BATS_TEST_TMPDIR/bak" stale=2026-01-01T00:00:00Z cut hours
  mkdir -p "$bak"
  for f in /etc/profile.d/supply-chain-hardening.sh /etc/uv/uv.toml /etc/pip.conf; do cp -p "$f" "$bak/${f//\//_}"; done
  # An opted-in host whose cutoffs went stale.
  printf 'export UV_EXCLUDE_NEWER=%s\n' "$stale" >> /etc/profile.d/supply-chain-hardening.sh
  sed -i "s/^export PIP_UPLOADED_PRIOR_TO=.*/export PIP_UPLOADED_PRIOR_TO=$stale/" /etc/profile.d/supply-chain-hardening.sh
  run "$RENDER_DIR/refresh-optin" --system
  echo "$output"
  hours=$(sed -n 's/^hours=\([0-9]*\)$/\1/p' "$RENDER_DIR/refresh-optin")
  cut=$(date -u -d "@$(( $(date -u +%s) - hours * 3600 ))" +%Y-%m-%dT00:00:00Z)
  local ok=0
  grep -qx "export UV_EXCLUDE_NEWER=$cut" /etc/profile.d/supply-chain-hardening.sh \
    && grep -qx "export PIP_UPLOADED_PRIOR_TO=$cut" /etc/profile.d/supply-chain-hardening.sh \
    && [[ "$output" == *"/etc/profile.d/supply-chain-hardening.sh: $stale -> $cut"* ]] && ok=1
  for f in /etc/profile.d/supply-chain-hardening.sh /etc/uv/uv.toml /etc/pip.conf; do cp -p "$bak/${f//\//_}" "$f"; done
  [ "$status" -eq 0 ]
  [ "$ok" = 1 ]
}

# ---------------------------------------------------------------- uv ---------

# pypi_or_skip: skip when PyPI cannot be reached. Called from the test body:
# a skip inside $(...) would only end the subshell.
pypi_or_skip() {
  local d="$BATS_TEST_TMPDIR/pypi-probe" out
  mkdir -p "$d"; printf 'packaging\n' > "$d/req.in"
  out=$(cd "$d" && env -u UV_EXCLUDE_NEWER UV_CACHE_DIR="$BATS_TEST_TMPDIR/uvcache" \
        uv pip compile --quiet --no-header --exclude-newer "$UVCUT" req.in 2>&1) \
    || skip "PyPI unreachable (offline?): $(printf '%s' "$out" | head -1)"
}

# uv_pick <dir> <package> [profile file]: the version `uv pip compile` picks for
# <package> in <dir>, from a requirements file naming packaging and idna, with
# the rendered profile sourced when one is given.
uv_pick() {
  local d="$1" pkg="$2" prof="${3:-}"
  printf 'packaging\nidna\n' > "$d/req.in"
  if [ -n "$prof" ]; then
    (cd "$d" && with_profile "$prof" env UV_CACHE_DIR="$BATS_TEST_TMPDIR/uvcache" uv pip compile --quiet --no-header --no-annotate req.in)
  else
    (cd "$d" && env -u UV_EXCLUDE_NEWER UV_CACHE_DIR="$BATS_TEST_TMPDIR/uvcache" uv pip compile --quiet --no-header --no-annotate req.in)
  fi | sed -n "s/^$pkg==\([0-9.]*\).*/\1/p" | head -1
}

@test "uv: a repo uv.toml exclude-newer in 2099 wins without UV_EXCLUDE_NEWER, and loses to it when exported" {
  command -v uv >/dev/null 2>&1 || skip "uv not installed"
  needs_render optin-pinned.sh
  pypi_or_skip
  local d="$BATS_TEST_TMPDIR/uvrepo" v
  mkdir -p "$d"; printf 'exclude-newer = "2099-01-01T00:00:00Z"\n' > "$d/uv.toml"
  # FIXTURE CONTROL: the repo's own cutoff is in effect, so packaging newer than
  # the pinned cutoff's 24.1 resolves (a fixture where nothing newer exists
  # would pass the next assertion whatever the env did).
  v=$(uv_pick "$d" packaging)
  echo "without the env: packaging $v"
  [ -n "$v" ]
  [ "$v" != 24.1 ]
  # The profile.d an opted-in host gets, pinned to the historical cutoff.
  v=$(uv_pick "$d" packaging "$RENDER_DIR/optin-pinned.sh")
  echo "with the env: packaging $v"
  [ "$v" = 24.1 ]
}

# Reads packaging's locked version (and, with a second argument, the cutoff in
# [options]) from a uv.lock: tomllib (3.11+), then the tomli backport, else exit
# 3 so the test skips. Was tomllib-only, and failed on Ubuntu 22.04's Python
# 3.10 in round 3 of the real-VM test.
UVLOCK_PY='import sys
try:
    import tomllib as t
except ModuleNotFoundError:
    try:
        import tomli as t
    except ModuleNotFoundError:
        sys.exit(3)
d = t.load(open(sys.argv[1], "rb"))
v = [p["version"] for p in d["package"] if p["name"] == "packaging"][0]
print(v + (" " + d["options"]["exclude-newer"] if len(sys.argv) > 2 else ""))'

@test "uv: a pyproject [tool.uv] exclude-newer loses to the env for uv lock, and the lockfile records the env's cutoff" {
  command -v uv >/dev/null 2>&1 || skip "uv not installed"
  needs_render optin-pinned.sh
  pypi_or_skip
  local d="$BATS_TEST_TMPDIR/uvlock" out
  mkdir -p "$d"
  printf '[project]\nname = "envlock"\nversion = "0.1.0"\nrequires-python = ">=3.8"\ndependencies = ["packaging"]\n\n[tool.uv]\nexclude-newer = "2099-01-01T00:00:00Z"\n' > "$d/pyproject.toml"
  (cd "$d" && env -u UV_EXCLUDE_NEWER UV_CACHE_DIR="$BATS_TEST_TMPDIR/uvcache" uv lock)
  # FIXTURE CONTROL: without the env the project's own 2099 cutoff resolves past 24.1.
  run python3 -c "$UVLOCK_PY" "$d/uv.lock"
  [ "$status" -ne 3 ] || skip "no TOML parser to read uv.lock (Python < 3.11 without tomli)"
  [ "$status" -eq 0 ]
  [ "$output" != 24.1 ]
  rm -f "$d/uv.lock"
  (cd "$d" && with_profile "$RENDER_DIR/optin-pinned.sh" env UV_CACHE_DIR="$BATS_TEST_TMPDIR/uvcache" uv lock >/dev/null 2>&1)
  run python3 -c "$UVLOCK_PY" "$d/uv.lock" with-cutoff
  echo "$output"
  [ "$output" = "24.1 $UVCUT" ]
}

@test "uv: residual — a repo exclude-newer-package still loosens its package under the env; the rest stays gated" {
  command -v uv >/dev/null 2>&1 || skip "uv not installed"
  needs_render optin-pinned.sh
  pypi_or_skip
  local d="$BATS_TEST_TMPDIR/uvpkgres" p i
  mkdir -p "$d"; printf 'exclude-newer-package = { packaging = "2099-01-01T00:00:00Z" }\n' > "$d/uv.toml"
  ( cd "$d" && uv pip list --show-settings 2>/dev/null ) | tr -d ' \n' | grep -q 'PackageName("packaging",)' \
    || skip "this uv does not read exclude-newer-package"
  p=$(uv_pick "$d" packaging "$RENDER_DIR/optin-pinned.sh")
  i=$(uv_pick "$d" idna "$RENDER_DIR/optin-pinned.sh")
  echo "with the env: packaging $p idna $i"
  [ "$i" = 3.10 ]                   # the env's cutoff, for every package the repo did not name
  [ -n "$p" ]
  [ "$p" != 24.1 ]   # the repo's per-package 2099 still wins for packaging
}

@test "uv: run and tool run still work with the env exported" {
  command -v uv >/dev/null 2>&1 || skip "uv not installed"
  needs_render optin-pinned.sh
  pypi_or_skip
  local d="$BATS_TEST_TMPDIR/uvrun"
  mkdir -p "$d"
  printf '[project]\nname = "envrun"\nversion = "0.1.0"\nrequires-python = ">=3.8"\ndependencies = ["packaging"]\n' > "$d/pyproject.toml"
  run bash -c "cd '$d' && $(declare -f with_profile); with_profile '$RENDER_DIR/optin-pinned.sh' env UV_CACHE_DIR='$BATS_TEST_TMPDIR/uvcache' uv run --quiet python -c 'import packaging; print(packaging.__version__)'"
  echo "$output"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | tail -1)" = 24.1 ]
  run bash -c "cd /tmp && $(declare -f with_profile); with_profile '$RENDER_DIR/optin-pinned.sh' env UV_CACHE_DIR='$BATS_TEST_TMPDIR/uvcache' UV_TOOL_DIR='$BATS_TEST_TMPDIR/uvtools' uv tool run --quiet --from pyflakes pyflakes --version"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == 3.2.0* ]]   # the newest pyflakes before the pinned cutoff
}

verify_from() { # dir [VAR=value ...]
  local d="$1"; shift
  run env "$@" bash -c 'cd "$1" && shift && exec "$@"' _ "$d" "$VERIFY" --verbose
}

@test "verify: a repo's later exclude-newer under UV_EXCLUDE_NEWER is WEAK and says why; without it, GAP as before" {
  command -v uv >/dev/null 2>&1 || skip "uv not installed"
  needs_render optin-rolling.sh
  ( cd / && uv pip list --show-settings 2>/dev/null ) | tr -d ' \n' | grep -q 'exclude_newer:ExcludeNewer{global:Some(' \
    || skip "uv reports no global exclude-newer from / on this host"
  local d="$BATS_TEST_TMPDIR/uvmask" v
  mkdir -p "$d"; printf 'exclude-newer = "2099-01-01T00:00:00Z"\n' > "$d/uv.toml"
  v=$(with_profile "$RENDER_DIR/optin-rolling.sh" printenv UV_EXCLUDE_NEWER)
  # Ground truth first: in that directory uv takes the env's cutoff over the repo's.
  ( cd "$d" && UV_EXCLUDE_NEWER="$v" uv pip list --show-settings 2>/dev/null ) | tr -d ' \n' | grep -q "global:Some(Absolute($v"
  verify_from "$d" -u UV_EXCLUDE_NEWER
  echo "$output" | grep "uv repo config override"
  echo "$output" | grep "uv repo config override" | grep -q "^GAP"
  verify_from "$d" UV_EXCLUDE_NEWER="$v"
  echo "$output" | grep "uv repo config override"
  echo "$output" | grep "uv repo config override" | grep -q "^WEAK"
  echo "$output" | grep "uv repo config override" | grep -q "UV_EXCLUDE_NEWER=$v in this environment outranks it"
  echo "$output" | grep "uv repo config override" | grep -q -- "-> 2099-01-01T00:00:00Z"
  echo "$output" | grep "uv repo config override" | grep -q "cron"
  # The variable does not outrank exclude-newer-package, and the row still says GAP.
  printf 'exclude-newer-package = { botocore = "2099-01-01T00:00:00Z" }\n' > "$d/uv.toml"
  if ( cd "$d" && uv pip list --show-settings 2>/dev/null ) | tr -d ' \n' | grep -q 'PackageName("botocore",)'; then
    verify_from "$d" UV_EXCLUDE_NEWER="$v"
    echo "$output" | grep "uv repo config override" | grep -q "^GAP"
  fi
  # A repo that pins an EARLIER cutoff is not a weakening, with the env or without.
  printf 'exclude-newer = "2020-01-01T00:00:00Z"\n' > "$d/uv.toml"
  verify_from "$d" UV_EXCLUDE_NEWER="$v"
  echo "$output" | grep "uv repo config override" | grep -q "^OK"
}

# ---------------------------------------------------------------- pnpm -------

pnpm11_or_skip() {
  local major
  major=$(pnpm --version 2>/dev/null | sed -nE 's/^([0-9]+)\..*/\1/p' | head -1)
  [[ "$major" =~ ^[0-9]+$ ]] || skip "couldn't parse pnpm major version"
  [ "$major" -ge 11 ] || skip "pnpm_config_* is read from pnpm 11 (got: $(pnpm --version 2>/dev/null))"
}

# The registry's publish times for electron-to-chromium (released most days),
# once per file. Each test then knows which version is newest and whether it is
# younger than the 2880-minute gate.
ETC_TIMES="$RENDER_DIR/etc-times.tsv"
etc_times_or_skip() {
  if [ ! -s "$ETC_TIMES" ]; then
    curl -fsSL --max-time 60 https://registry.npmjs.org/electron-to-chromium 2>/dev/null | python3 -c '
import sys, json, datetime
d = json.load(sys.stdin)
now = datetime.datetime.now(datetime.timezone.utc)
for v, t in d["time"].items():
    if v in d["versions"] and v.startswith("1.5."):
        age = (now - datetime.datetime.fromisoformat(t.replace("Z", "+00:00"))).total_seconds() / 60
        print("%s\t%d" % (v, age))
' > "$ETC_TIMES" 2>/dev/null || true
  fi
  [ -s "$ETC_TIMES" ] || skip "npm registry unreachable (offline?)"
  local newest_age
  newest_age=$(sort -t. -k3,3n "$ETC_TIMES" | tail -1 | cut -f2)
  [ "$newest_age" -lt 2865 ] || skip "no electron-to-chromium release is younger than the 48h gate right now; gated and ungated resolve the same"
  # A version crossing the gate during the test would make either answer right.
  ! awk -F'\t' '$2 > 2860 && $2 < 2900 { f = 1 } END { exit !f }' "$ETC_TIMES" \
    || skip "a release is within minutes of the 48h boundary; try again later"
}
etc_age() { awk -F'\t' -v v="$1" '$1 == v { print $2 }' "$ETC_TIMES"; }

# etc_pick <dir> [VAR=value ...]: the electron-to-chromium version
# `pnpm install --lockfile-only` writes in <dir>, with a fresh cache and store
# (pnpm 11.0.x let one project's minimumReleaseAge: 0 metadata skip the gate for
# the next project sharing its cache). Runs with root's real deployed config.
etc_pick() {
  local d="$1"; shift
  [ -f "$d/package.json" ] || echo '{"name":"envage","version":"1.0.0","private":true,"dependencies":{"electron-to-chromium":"^1.5.480"}}' > "$d/package.json"
  rm -f "$d/pnpm-lock.yaml"
  (cd "$d" && env -u pnpm_config_minimum_release_age -u pnpm_config_minimum_release_age_exclude "$@" \
     pnpm install --lockfile-only --cache-dir "$(mktemp -d)" --store-dir "$(mktemp -d)" >/dev/null 2>&1) || true
  grep -oE 'electron-to-chromium@[0-9.]+' "$d/pnpm-lock.yaml" 2>/dev/null | head -1 | cut -d@ -f2
}
# profile_vars: the pnpm variables the deployed /etc/profile.d exports, as
# VAR=value arguments for etc_pick.
profile_vars() {
  env -i bash -c '. /etc/profile.d/supply-chain-hardening.sh; for k in pnpm_config_minimum_release_age pnpm_config_minimum_release_age_exclude; do printf "%s=%s\n" "$k" "${!k}"; done'
}

@test "pnpm 11+: a workspace minimumReleaseAge: 0 lifts the gate without the env, and not with the deployed one" {
  pnpm11_or_skip
  etc_times_or_skip
  local d="$BATS_TEST_TMPDIR/pnage" v
  mkdir -p "$d"; printf 'minimumReleaseAge: 0\n' > "$d/pnpm-workspace.yaml"
  # FIXTURE CONTROL: the workspace file outranks the role's config.yaml.
  v=$(etc_pick "$d")
  echo "without the env: $v ($(etc_age "$v") min old)"
  [ -n "$v" ]
  [ "$(etc_age "$v")" -lt 2880 ]
  mapfile -t pv < <(profile_vars)
  v=$(etc_pick "$d" "${pv[@]}")
  echo "with ${pv[*]}: $v ($(etc_age "$v") min old)"
  [ -n "$v" ]
  [ "$(etc_age "$v")" -ge 2880 ]
}

@test "pnpm 11+: a workspace exclude list beats the age variable alone; the exported [] cancels it" {
  pnpm11_or_skip
  etc_times_or_skip
  local d="$BATS_TEST_TMPDIR/pnexcl" v
  mkdir -p "$d"; printf 'minimumReleaseAgeExclude:\n  - electron-to-chromium\n' > "$d/pnpm-workspace.yaml"
  # Control: the age variable without the exclude variable leaves the exemption.
  v=$(etc_pick "$d" pnpm_config_minimum_release_age=2880)
  echo "age only: $v ($(etc_age "$v") min old)"
  [ -n "$v" ]
  [ "$(etc_age "$v")" -lt 2880 ]
  mapfile -t pv < <(profile_vars)
  v=$(etc_pick "$d" "${pv[@]}")
  echo "with ${pv[*]}: $v ($(etc_age "$v") min old)"
  [ -n "$v" ]
  [ "$(etc_age "$v")" -ge 2880 ]
}

@test "pnpm 11+: negative control — npm_config_minimum_release_age does nothing for pnpm" {
  pnpm11_or_skip
  etc_times_or_skip
  local d="$BATS_TEST_TMPDIR/pnneg" v
  mkdir -p "$d"; printf 'minimumReleaseAge: 0\n' > "$d/pnpm-workspace.yaml"
  v=$(etc_pick "$d" npm_config_minimum_release_age=2880 NPM_CONFIG_MINIMUM_RELEASE_AGE=2880)
  echo "npm_config_*: $v ($(etc_age "$v") min old)"
  [ -n "$v" ]
  [ "$(etc_age "$v")" -lt 2880 ]
}

# make_build_project <dir> [pnpm-workspace.yaml content]: tests/bats/37's fixture,
# a local directory dependency with a postinstall that writes $SCH_MARK. Offline.
make_build_project() {
  mkdir -p "$1/dep"
  cat > "$1/dep/package.json" <<'JSON'
{"name":"sch-build-fixture","version":"1.0.0","scripts":{"postinstall":"node -e \"require('fs').writeFileSync(process.env.SCH_MARK,'x')\""}}
JSON
  cat > "$1/package.json" <<'JSON'
{"name":"victim","version":"1.0.0","scripts":{"postinstall":"node -e \"require('fs').writeFileSync(process.env.SCH_MARK + '.root','x')\""},"dependencies":{"sch-build-fixture":"file:./dep"}}
JSON
  if [ -n "${2:-}" ]; then printf '%s\n' "$2" > "$1/pnpm-workspace.yaml"; fi
}

@test "pnpm 11+: residual — the env does not stop a workspace's ignoreScripts: false; nothing exports ignore_scripts" {
  pnpm11_or_skip
  local p="$BATS_TEST_TMPDIR/pnres"
  make_build_project "$p" "ignoreScripts: false"
  mapfile -t pv < <(profile_vars)
  run env "${pv[@]}" SCH_MARK="$p/marker" bash -c "cd '$p' && pnpm install --store-dir '$BATS_TEST_TMPDIR/store'"
  echo "$output"
  # The project's own postinstall ran: ignoreScripts is not part of the env layer.
  [ -f "$p/marker.root" ]
  [ -z "$(env -i bash -c '. /etc/profile.d/supply-chain-hardening.sh; echo ${pnpm_config_ignore_scripts+set}${PNPM_CONFIG_IGNORE_SCRIPTS+set}')" ]
}

@test "pnpm 11+: why ignore_scripts is not exported — true silently skips a build the project approved" {
  # The route defaults/main.yml documents for pnpm 11+: ignoreScripts: false +
  # allowBuilds in the project. MEASURED on 11.0.9, 11.28.13 and 12.21.0: with
  # pnpm_config_ignore_scripts=true the approved build does not run, exit 0,
  # and pnpm says nothing.
  pnpm11_or_skip
  local p="$BATS_TEST_TMPDIR/pnwhy"
  make_build_project "$p" $'ignoreScripts: false\nallowBuilds:\n  \'sch-build-fixture@file:dep\': true'
  run env SCH_MARK="$p/marker" bash -c "cd '$p' && pnpm install --store-dir '$BATS_TEST_TMPDIR/store1'"
  echo "$output"
  # CONTROL: this pnpm honours the route (the key format is the 11.28+ one).
  [ "$status" -eq 0 ] && [ -f "$p/marker" ] || skip "this pnpm does not run the build under the documented route (allowBuilds key format differs before 11.28)"
  rm -rf "$p/node_modules" "$p/marker" "$p/marker.root"
  run env pnpm_config_ignore_scripts=true SCH_MARK="$p/marker" bash -c "cd '$p' && pnpm install --store-dir '$BATS_TEST_TMPDIR/store2'"
  echo "$output"
  [ "$status" -eq 0 ]
  [ ! -f "$p/marker" ]
  [[ "$output" != *"ERR_PNPM"* ]]
}

@test "pnpm 10: the pnpm_config_* exports are inert and print nothing" {
  local major
  major=$(pnpm --version 2>/dev/null | sed -nE 's/^([0-9]+)\..*/\1/p' | head -1)
  [ "$major" = 10 ] || skip "pnpm 10 only (got: $(pnpm --version 2>/dev/null))"
  local d="$BATS_TEST_TMPDIR/pn10"
  mkdir -p "$d"; echo '{"name":"p10","version":"1.0.0","private":true}' > "$d/package.json"
  mapfile -t pv < <(profile_vars)
  run env "${pv[@]}" bash -c "cd '$d' && pnpm install --lockfile-only 2>&1"
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" != *"pnpm_config"* ]]
  [ "$(cd "$d" && env "${pv[@]}" pnpm config get minimum-release-age)" = "$(cd "$d" && pnpm config get minimum-release-age)" ]
}

@test "verify: a workspace minimumReleaseAge: 0 is a GAP without the env, WEAK naming it with the env" {
  pnpm11_or_skip
  local d="$BATS_TEST_TMPDIR/pnverify"
  mkdir -p "$d"; echo '{"name":"pv","version":"1.0.0","private":true}' > "$d/package.json"
  printf 'minimumReleaseAge: 0\n' > "$d/pnpm-workspace.yaml"
  verify_from "$d" -u pnpm_config_minimum_release_age -u PNPM_CONFIG_MINIMUM_RELEASE_AGE
  echo "$output" | grep "pnpm repo config override"
  echo "$output" | grep "pnpm repo config override" | grep -q "^GAP"
  verify_from "$d" pnpm_config_minimum_release_age=2880
  echo "$output" | grep "pnpm repo config override"
  echo "$output" | grep "pnpm repo config override" | grep -q "^WEAK"
  echo "$output" | grep "pnpm repo config override" | grep -q "pnpm_config_minimum_release_age=2880 in this environment outranks it"
  # The host row asks pnpm from /, so the workspace value is no longer its answer.
  echo "$output" | grep "pnpm age gate" | grep -qv "minimum-release-age=0"
}

@test "verify: run from a project, the verifier never runs the project's pnpmfile" {
  # MEASURED on pnpm 10.34.9, 11.0.0 and 11.28.13: `pnpm config get` in a
  # project loads its .pnpmfile.cjs (top level and updateConfig hook). The pnpm
  # rows used to ask from the working directory; they ask from / now, and the
  # workspace row reads the file.
  command -v pnpm >/dev/null 2>&1 || skip "pnpm not installed"
  local d="$BATS_TEST_TMPDIR/pnhook" m="$BATS_TEST_TMPDIR/pnpmfile-ran" ctl=none
  mkdir -p "$d"; echo '{"name":"ph","version":"1.0.0","private":true}' > "$d/package.json"
  printf 'minimumReleaseAge: 600\n' > "$d/pnpm-workspace.yaml"
  printf 'require("fs").writeFileSync(%s, "x"); module.exports = { hooks: {} }\n' "'$m'" > "$d/.pnpmfile.cjs"
  # FIXTURE CONTROL: does this pnpm run the file when asked in the project?
  (cd "$d" && pnpm config get minimumReleaseAge >/dev/null 2>&1) || true
  if [ -e "$m" ]; then ctl=ran; rm -f "$m"; fi
  verify_from "$d"
  echo "$output" | grep "pnpm repo config override"
  [ ! -e "$m" ] || { echo "the verifier ran the project's pnpmfile" >&2; return 1; }
  # Judged from the file (unless this pnpm has no age gate at all).
  echo "$output" | grep "pnpm repo config override" | grep -qE "^N/A.*has no minimumReleaseAge|minimumReleaseAge 600"
  [ "$ctl" = ran ] || skip "pnpm $(pnpm --version) does not run a pnpmfile for config get (12.21.0 does not), so the control cannot discriminate; the verifier still ran none"
}