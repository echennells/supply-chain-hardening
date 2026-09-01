#!/usr/bin/env bats
# Age-gate OBSERVABILITY (SCV_AGE_NOTICE) — the npm wrapper's opt-in notice that
# surfaces npm min-release-age's otherwise-SILENT downgrade.
#
# min-release-age refuses a *pinned* fresh version (ETARGET "date before …") but
# for an unpinned/range spec it silently resolves to the newest version old
# enough and installs THAT with no error. Real protection, zero evidence: an
# agent or operator cannot tell the gate just spared them a <window-day-old
# release. SCV_AGE_NOTICE=1 makes that one skip visible on the non-interactive
# install path.
#
# These tests are hermetic: they render the wrapper with a STUB real-npm and a
# fake node_modules, so there is no registry call and no dependence on wall-clock
# package ages — deterministic in CI. The advisory runs AFTER enforcement and
# only PRINTS, so a parse miss is a missed line, never a bypass (see the wrapper).

load setup

# Render the wrapper (template with the jinja real-npm path substituted for a
# stub), plus a transparent stub sfw, into this test's private tmpdir.
_render() {
  BIN="$BATS_TEST_TMPDIR/bin"; mkdir -p "$BIN"
  # stub real npm: `view … --json` echoes $VIEW_JSON; anything else exits 0.
  cat > "$BIN/realnpm" <<'SH'
#!/bin/sh
for a in "$@"; do case "$a" in -*) ;; *) sub="$a"; break ;; esac; done
[ "$sub" = view ] && { cat "$VIEW_JSON"; exit 0; }
exit 0
SH
  # stub sfw: transparent passthrough, so the wrapper's sfw branch is hermetic.
  printf '#!/bin/sh\nexec "$@"\n' > "$BIN/sfw"
  chmod +x "$BIN/realnpm" "$BIN/sfw"
  WRAP="$BATS_TEST_TMPDIR/npm"
  sed "s#{{ npm_real_path.stdout }}#$BIN/realnpm#" \
    "$ROLE_DIR/templates/npm-wrapper.sh.j2" > "$WRAP"
  chmod +x "$WRAP"
}

# Build the registry view (latest published 1 day ago) and a fake installed
# copy at $installed under ./node_modules/<name>/package.json.
_scenario() {
  local latest="$1" installed="$2" name="$3"
  VIEW_JSON="$BATS_TEST_TMPDIR/view.json"; export VIEW_JSON
  printf '{"dist-tags":{"latest":"%s"},"version":"%s","time":{"%s":"%s"}}\n' \
    "$latest" "$latest" "$latest" "$(date -u -d '1 day ago' +%Y-%m-%dT%H:%M:%S.000Z)" \
    > "$VIEW_JSON"
  mkdir -p "$BATS_TEST_TMPDIR/proj/node_modules/$name"
  printf '{"name":"%s","version":"%s"}\n' "$name" "$installed" \
    > "$BATS_TEST_TMPDIR/proj/node_modules/$name/package.json"
}

@test "SCV_AGE_NOTICE=1 surfaces a silent age-gate downgrade" {
  _render; _scenario "10.73.0" "10.72.0" "@sentry/node"
  cd "$BATS_TEST_TMPDIR/proj"
  PATH="$BIN:$PATH" run env SCV_AGE_NOTICE=1 NPM_CONFIG_MIN_RELEASE_AGE=2 \
    "$WRAP" install @sentry/node
  [ "$status" -eq 0 ]
  [[ "$output" == *"age gate: @sentry/node@10.73.0"* ]]
  [[ "$output" == *"installed 10.72.0"* ]]
}

@test "default (no SCV_AGE_NOTICE) stays silent — behaviour unchanged" {
  _render; _scenario "10.73.0" "10.72.0" "@sentry/node"
  cd "$BATS_TEST_TMPDIR/proj"
  PATH="$BIN:$PATH" run env NPM_CONFIG_MIN_RELEASE_AGE=2 "$WRAP" install @sentry/node
  [ "$status" -eq 0 ]
  [[ "$output" != *"age gate:"* ]]
}

@test "no false positive when the installed version IS the latest" {
  _render; _scenario "10.72.0" "10.72.0" "@sentry/node"
  cd "$BATS_TEST_TMPDIR/proj"
  PATH="$BIN:$PATH" run env SCV_AGE_NOTICE=1 NPM_CONFIG_MIN_RELEASE_AGE=2 \
    "$WRAP" install @sentry/node
  [ "$status" -eq 0 ]
  [[ "$output" != *"age gate:"* ]]
}

@test "advisory does not fire for a non-install subcommand" {
  _render; _scenario "10.73.0" "10.72.0" "@sentry/node"
  cd "$BATS_TEST_TMPDIR/proj"
  PATH="$BIN:$PATH" run env SCV_AGE_NOTICE=1 NPM_CONFIG_MIN_RELEASE_AGE=2 \
    "$WRAP" view @sentry/node version
  [[ "$output" != *"age gate:"* ]]
}
