#!/usr/bin/env bats
# The age-gate refresher: keeps uv exclude-newer and pip uploaded-prior-to
# ROLLING instead of frozen at apply time.
#
# This image runs no systemd, so the role deploys the script and records the
# missing timer as a skipped protection; these tests drive the script
# directly. The timer and service units are only exercised on a systemd host.
#
# Every test stales the cutoffs itself and restores the files afterwards, so
# the outcome does not depend on how long ago the image was built.

load setup

R=/usr/local/sbin/supply-chain-age-gate-refresh
VERIFY=/usr/local/bin/supply-chain-verify
STALE=2026-01-01T00:00:00Z

# The role runs as root in this image, so the "user" files are root's.
files() {
  printf '%s\n' /etc/uv/uv.toml /etc/pip.conf /etc/profile.d/supply-chain-hardening.sh \
    "$HOME/.config/uv/uv.toml" "$HOME/.config/pip/pip.conf"
}

setup() {
  local f i=0
  while read -r f; do
    [ -f "$f" ] && cp -p "$f" "$BATS_TEST_TMPDIR/orig.$i"
    i=$((i + 1))
  done < <(files)
}

teardown() {
  local f i=0
  while read -r f; do
    [ -f "$BATS_TEST_TMPDIR/orig.$i" ] && cp -p "$BATS_TEST_TMPDIR/orig.$i" "$f"
    i=$((i + 1))
  done < <(files)
}

stale_all() {
  sed -i "s/^exclude-newer = \".*\"\$/exclude-newer = \"$STALE\"/" /etc/uv/uv.toml "$HOME/.config/uv/uv.toml"
  sed -i "s/^uploaded-prior-to = .*/uploaded-prior-to = $STALE/" /etc/pip.conf "$HOME/.config/pip/pip.conf"
  sed -i "s/^export PIP_UPLOADED_PRIOR_TO=.*/export PIP_UPLOADED_PRIOR_TO=$STALE/" /etc/profile.d/supply-chain-hardening.sh
}

# What the role would render today: the refresher's own window, same formula
# as uv_exclude_newer in defaults/main.yml.
today_cutoff() {
  local hours
  hours=$(sed -n 's/^hours=\([0-9]*\)$/\1/p' "$R")
  date -u -d "@$(( $(date -u +%s) - hours * 3600 ))" +%Y-%m-%dT00:00:00Z
}

refresh() { "$R" --system && "$R" --user; }

@test "refresher is deployed root-owned and executable; no timer without systemd" {
  [ -x "$R" ]
  [ "$(stat -c %U "$R")" = root ]
  [ ! -e /run/systemd/system ] || skip "this image runs systemd; the timer branch applies instead"
  [ ! -e /etc/systemd/system/supply-chain-age-gate-refresh.timer ]
}

@test "a stale cutoff in every file is advanced to today's rolling value" {
  stale_all
  run refresh
  echo "$output"
  [ "$status" -eq 0 ]
  local cut; cut=$(today_cutoff)
  grep -qx "exclude-newer = \"$cut\"" /etc/uv/uv.toml
  grep -qx "exclude-newer = \"$cut\"" "$HOME/.config/uv/uv.toml"
  grep -qx "uploaded-prior-to = $cut" /etc/pip.conf
  grep -qx "uploaded-prior-to = $cut" "$HOME/.config/pip/pip.conf"
  grep -qx "export PIP_UPLOADED_PRIOR_TO=$cut" /etc/profile.d/supply-chain-hardening.sh
}

@test "only the cutoff line changes, and owner and mode are kept" {
  stale_all
  local before="$BATS_TEST_TMPDIR/stale-uv.toml" mode
  cp -p /etc/uv/uv.toml "$before"
  mode=$(stat -c '%a %U' /etc/uv/uv.toml)
  refresh
  [ "$(diff "$before" /etc/uv/uv.toml | grep -c '^[<>]')" -eq 2 ]
  [ "$(stat -c '%a %U' /etc/uv/uv.toml)" = "$mode" ]
}

@test "a second run finds everything current and rewrites nothing" {
  stale_all
  refresh
  local ino; ino=$(stat -c %i /etc/pip.conf)
  run refresh
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(stat -c %i /etc/pip.conf)" = "$ino" ]
}

@test "a duplicated cutoff line is left alone and reported" {
  # Two role-shaped lines means someone edited the file's structure; the
  # refresher must not guess which one is ours. (A single line whose VALUE was
  # hand-edited is advanced like any other -- the next test pins that down.)
  stale_all
  printf 'exclude-newer = "%s"\n' "$STALE" >> /etc/uv/uv.toml
  run "$R" --system
  [[ "$output" == *"/etc/uv/uv.toml has 2 role-shaped cutoff lines"* ]]
  [ "$(grep -c "^exclude-newer = \"$STALE\"\$" /etc/uv/uv.toml)" -eq 2 ]
}

@test "every rewrite is logged with the value it replaced" {
  # The files are role-managed, so a hand-set cutoff value is advanced like any
  # other. What makes that safe to operate is that the log says what it replaced.
  stale_all
  run "$R" --system
  [[ "$output" == *"/etc/uv/uv.toml: $STALE -> $(today_cutoff)"* ]]
}

@test "with no argument, root also advances root's own files when root deployed the role" {
  # This image deploys as root. One root cron entry with no argument must keep
  # BOTH the /etc files and root's uv.toml/pip.conf rolling -- uv ranks the user
  # file above /etc/uv/uv.toml, so advancing only /etc would leave root frozen.
  [ "$(id -u)" = 0 ] || skip "needs root"
  grep -qx 'deploy_uid=0' "$R" || skip "the role was not deployed as root here"
  stale_all
  run "$R"
  [ "$status" -eq 0 ]
  local cut; cut=$(today_cutoff)
  grep -qx "exclude-newer = \"$cut\"" /etc/uv/uv.toml
  grep -qx "exclude-newer = \"$cut\"" "$HOME/.config/uv/uv.toml"
  grep -qx "uploaded-prior-to = $cut" "$HOME/.config/pip/pip.conf"
}

@test "the verifier reads the stale gate as a freeze and the refreshed one as OK" {
  command -v uv >/dev/null 2>&1 || skip "uv not installed"
  stale_all
  run "$VERIFY" --json
  [ "$(printf '%s' "$output" | jq -r '.rows[] | select(.protection == "uv age gate") | .status')" = WEAK ]
  [[ "$(printf '%s' "$output" | jq -r '.rows[] | select(.protection == "uv age gate") | .detail')" == *FREEZE* ]]
  refresh
  run "$VERIFY" --json
  [ "$(printf '%s' "$output" | jq -r '.rows[] | select(.protection == "uv age gate") | .status')" = OK ]
}
