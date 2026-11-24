#!/usr/bin/env bats
# The eight per-user config files this project writes, and what is the user's in
# them (issue 48, item 1). MEASURED at d738db8: a fake token or registry in each
# was gone after one run, with no copy and no message, and so was a token added
# after hardening. Every test here that plants one fails there.
#
# ~/.npmrc is merged. The other seven are replaced whole, but only a file that is
# exactly what was last written goes without a copy and a warning.

load helpers

ROOT="${BATS_TEST_DIRNAME}/../.."
ALL=npm,pnpm,yarn,pip,uv,bun,bundler
SEVEN="pnpm-yaml pnpm-rc yarn pip uv bun bundler"

setup() {
  common_setup
  # Every path under it, whatever the platform (pnpm's default differs on macOS).
  XDG="$TEST_HOME/.config"
}

f() { # <kind>: where harden.sh puts it here
  case "$1" in
    npmrc) echo "$TEST_HOME/.npmrc" ;;
    pnpm-yaml) echo "$XDG/pnpm/config.yaml" ;;
    pnpm-rc) echo "$XDG/pnpm/rc" ;;
    yarn) echo "$TEST_HOME/.yarnrc.yml" ;;
    pip) echo "$TEST_HOME/.config/pip/pip.conf" ;;
    uv) echo "$XDG/uv/uv.toml" ;;
    bun) echo "$XDG/.bunfig.toml" ;;
    bundler) echo "$TEST_HOME/.bundle/config" ;;
  esac
}

# apply [VAR=value ...]: one harden.sh run over the seven ecosystems
apply() { harden XDG_CONFIG_HOME="$XDG" ECOSYSTEMS="${ECO:-$ALL}" "$@" -- --emit=plain; }

# preflight: harden.sh --preflight in the same environment
pf() {
  env -i PATH="${TEST_BIN}:${PATH}" HOME="$TEST_HOME" XDG_CONFIG_HOME="$XDG" TMPDIR="$TEST_TMP" \
    bash "$HARDEN_SH" --preflight
}

# plant: a fake secret of the user's in each file, as each tool would hold it
plant() {
  mkdir -p "$XDG/pnpm" "$XDG/uv" "$TEST_HOME/.config/pip" "$TEST_HOME/.bundle"
  printf '//registry.example/:_authToken=SECRET-npmrc\n' > "$(f npmrc)"
  printf 'registry: https://u:SECRET-pnpm-yaml@example/\n' > "$(f pnpm-yaml)"
  printf 'registry=https://u:SECRET-pnpm-rc@example/\n' > "$(f pnpm-rc)"
  printf 'npmAuthToken: "SECRET-yarn"\n' > "$(f yarn)"
  printf '[global]\nindex-url = https://u:SECRET-pip@example/simple\n' > "$(f pip)"
  printf '[[index]]\nurl = "https://u:SECRET-uv@example/simple"\n' > "$(f uv)"
  printf '[install]\nregistry = "https://u:SECRET-bun@example"\n' > "$(f bun)"
  printf -- '---\nBUNDLE_GEMS__EXAMPLE: "u:SECRET-bundler"\n' > "$(f bundler)"
}

mode() { ls -ld "$1" | cut -c1-10; }

copies() { # <kind>: its copies, one per line
  local b
  for b in "$(f "$1")".*~; do [ -e "$b" ] && echo "$b"; done
  return 0
}

# the bytes of everything under the home but the run's own record
snapshot() {
  ( cd "$TEST_HOME" && find . -path ./.cache -prune -o \( -type f -o -type l \) -print | sort | while IFS= read -r p; do
      ls -ld "$p" | awk '{print $1, $3, $4}'; printf '%s ' "$p"; cksum < "$p"
    done )
}

# the same, but the two Python cutoffs, which harden.sh sets from the clock
snapshot_but_cutoffs() {
  ( cd "$TEST_HOME" && find . -path ./.cache -prune -o -type f -print | sort | while IFS= read -r p; do
      ls -ld "$p" | awk '{print $1, $3, $4}'; printf '%s ' "$p"
      sed -e 's/^\(exclude-newer = \).*/\1/' -e 's/^\(uploaded-prior-to = \).*/\1/' "$p" | cksum
    done )
}

settings() { printf '%s\n' ignore-scripts=true audit=true save-exact=true fund=false update-notifier=false min-release-age=2 allow-git=none; }

# block: the block harden.sh puts at the top of ~/.npmrc, read back from it
block() { sed -n '/^; >>> supply-chain-hardening: /,/^; <<< supply-chain-hardening$/p' "$(f npmrc)"; }

# rest: what is below the block
rest() { sed '1,/^; <<< supply-chain-hardening$/d' "$(f npmrc)"; }

npmrc_is_ours_then() { # <file with the expected rest>: the block first, then exactly those bytes
  block > "$BATS_TEST_TMPDIR/b"
  [ -s "$BATS_TEST_TMPDIR/b" ]
  settings > "$BATS_TEST_TMPDIR/s"
  diff <(grep -v '^;' "$BATS_TEST_TMPDIR/b") "$BATS_TEST_TMPDIR/s"
  cat "$BATS_TEST_TMPDIR/b" "$1" | cmp - "$(f npmrc)"
}

# the ucf_ functions on their own, for a rule no run of harden.sh reaches quickly
lib() {
  sed -n '/^# >>> user_config$/,/^# <<< user_config$/p' "$HARDEN_SH" > "$BATS_TEST_TMPDIR/lib.sh"
  # shellcheck disable=SC1091
  . "$BATS_TEST_TMPDIR/lib.sh"
}

# ------------------------------------------------------------- nothing is lost

@test "user config: a fake secret in each of the eight files is still on disk after the first run" {
  plant
  apply > "$BATS_TEST_TMPDIR/log" 2>&1
  grep -q 'SECRET-npmrc' "$(f npmrc)"                  # still in use
  [ -z "$(copies npmrc)" ]                             # so no copy was needed
  local k
  for k in $SEVEN; do
    assert_file_lacks "$(f "$k")" SECRET               # replaced
    [ "$(copies "$k" | wc -l)" -eq 1 ] || { echo "$k: $(copies "$k")"; return 1; }
    grep -q "SECRET-$k" "$(copies "$k")"
    [ "$(mode "$(copies "$k")")" = -rw------- ]
    grep -q "replaced $(f "$k"), which was not exactly what this project last wrote.*$(copies "$k")" "$BATS_TEST_TMPDIR/log" \
      || { cat "$BATS_TEST_TMPDIR/log"; return 1; }
  done
  # Paths, never contents.
  ! grep SECRET "$BATS_TEST_TMPDIR/log"
}

@test "user config: a token added after hardening survives the next run, in each of the eight" {
  apply >/dev/null 2>&1
  # Appended, so the file still carries the marker: recognising our files by the
  # marker alone deleted it (MEASURED at d738db8).
  local k
  for k in npmrc $SEVEN; do
    grep -q 'Managed by supply-chain-harden' "$(f "$k")"
    printf '# SECRET-%s\n' "$k" >> "$(f "$k")"
  done
  apply > "$BATS_TEST_TMPDIR/log" 2>&1
  grep -q 'SECRET-npmrc' "$(f npmrc)"
  for k in $SEVEN; do
    assert_file_lacks "$(f "$k")" SECRET
    grep -q "SECRET-$k" "$(copies "$k")" || { echo "$k lost"; return 1; }
  done
  ! grep SECRET "$BATS_TEST_TMPDIR/log"
}

@test "user config: a second run over user content changes nothing, makes no second copy, and is quiet" {
  plant
  apply >/dev/null 2>&1
  local before
  before=$(snapshot_but_cutoffs)
  apply > "$BATS_TEST_TMPDIR/log" 2>&1
  diff <(printf '%s\n' "$before") <(snapshot_but_cutoffs)
  ! grep -E 'replaced .*not exactly|took your own|not read' "$BATS_TEST_TMPDIR/log"
}

@test "user config: content that comes back every run is copied once, not once per run" {
  # A self-hosted runner whose jobs run 'bundle config set' first: the copies hold
  # the secret, so they must not pile up.
  local i
  for i in 1 2 3; do
    plant
    apply >/dev/null 2>&1
  done
  local k
  for k in $SEVEN; do
    [ "$(copies "$k" | wc -l)" -eq 1 ] || { copies "$k"; return 1; }
    [ "$(mode "$(copies "$k")")" = -rw------- ]
  done
}

@test "user config: no per-user file at all is created as before, and nothing is said about it" {
  apply > "$BATS_TEST_TMPDIR/log" 2>&1
  local k
  for k in npmrc $SEVEN; do
    [ -f "$(f "$k")" ]
    [ -z "$(copies "$k")" ]
  done
  [ "$(mode "$(f npmrc)")" = -rw------- ]
  [ "$(mode "$(f uv)")" = -rw-r--r-- ]
  ! grep -E 'replaced .*not exactly|took your own|is 0600 now' "$BATS_TEST_TMPDIR/log"
}

@test "user config: bunfig without XDG_CONFIG_HOME is kept the same way (~/.bunfig.toml)" {
  printf '[install]\nregistry = "https://u:SECRET-bun@example"\n' > "$TEST_HOME/.bunfig.toml"
  harden ECOSYSTEMS=bun -- --emit=plain >/dev/null 2>&1
  assert_file_lacks "$TEST_HOME/.bunfig.toml" SECRET
  grep -q SECRET-bun "$TEST_HOME"/.bunfig.toml.*~
}

# ------------------------------------------------------------------- upgrades
#
# tests/fixtures/user-config: what v2.0.0 and v2.1.0 wrote, each surface, made by
# running that version (role: ansible-core 2.16; no tools installed).

fixture() { # <version-surface>: put its eight files where they go
  local k d="$ROOT/tests/fixtures/user-config/$1"
  for k in npmrc $SEVEN; do
    mkdir -p "$(dirname "$(f "$k")")"
    cp "$d/$k" "$(f "$k")"
    chmod 644 "$(f "$k")"
  done
}

@test "user config: files v2.0.0 and v2.1.0 wrote, either surface, are upgraded without a word and without a copy" {
  local v k
  for v in v2.0.0-action v2.0.0-role v2.1.0-action v2.1.0-role; do
    rm -rf "$TEST_HOME"; mkdir -p "$TEST_HOME"
    fixture "$v"
    pf > "$BATS_TEST_TMPDIR/pf" || true
    ! grep -F "STOP  $TEST_HOME" "$BATS_TEST_TMPDIR/pf" || { echo "$v"; return 1; }
    apply > "$BATS_TEST_TMPDIR/log" 2>&1
    ! grep -E 'replaced .*not exactly|took your own|may set or defeat' "$BATS_TEST_TMPDIR/log" || { echo "$v"; return 1; }
    for k in npmrc $SEVEN; do
      [ -z "$(copies "$k")" ] || { echo "$v $k: $(copies "$k")"; return 1; }
      grep -q 'self-check ' "$(f "$k")" || { echo "$v $k"; return 1; }
    done
    : > "$BATS_TEST_TMPDIR/none"
    npmrc_is_ours_then "$BATS_TEST_TMPDIR/none" || { echo "$v"; return 1; }
  done
}

@test "user config: one line added to a file v2.0.0 or v2.1.0 wrote makes it the user's, whatever the line" {
  lib
  local v k line
  for v in v2.0.0-action v2.0.0-role v2.1.0-action v2.1.0-role; do
    for k in $SEVEN; do
      cp "$ROOT/tests/fixtures/user-config/$v/$k" "$BATS_TEST_TMPDIR/x"
      [ "$(user_cfg_class "$k" "$BATS_TEST_TMPDIR/x")" = ours ] || { echo "$v $k"; return 1; }
      for line in 'some-key = "v"' '# a comment of mine' '; //registry/:_authToken=x' '  indented: 1' '[section]' 'registry: https://example/'; do
        { cat "$ROOT/tests/fixtures/user-config/$v/$k"; printf '%s\n' "$line"; } > "$BATS_TEST_TMPDIR/x"
        [ "$(user_cfg_class "$k" "$BATS_TEST_TMPDIR/x")" = foreign ] || { echo "$v $k: $line"; return 1; }
      done
    done
  done
}

@test "user config: a token added to an old ~/.npmrc is kept, and only that" {
  local v
  for v in v2.0.0-action v2.0.0-role v2.1.0-action v2.1.0-role; do
    rm -rf "$TEST_HOME"; mkdir -p "$TEST_HOME"
    fixture "$v"
    printf '# mine\n//registry.example/:_authToken=SECRET\n\n@corp:registry=https://corp.example/\n' > "$BATS_TEST_TMPDIR/mine"
    cat "$BATS_TEST_TMPDIR/mine" >> "$(f npmrc)"
    ECO=npm apply > "$BATS_TEST_TMPDIR/log" 2>&1
    npmrc_is_ours_then "$BATS_TEST_TMPDIR/mine" || { echo "$v"; cat "$(f npmrc)"; return 1; }
    [ -z "$(copies npmrc)" ]
    ! grep SECRET "$BATS_TEST_TMPDIR/log"
  done
}

# --------------------------------------------------------------------- ~/.npmrc

@test "npmrc: every line that is not ours stays, byte for byte and in order" {
  printf '# top comment\n; another\n\n@corp:registry=https://corp.example/\n//corp.example/:_authToken=${CORP_TOKEN}\n  spaced = value  \ncafile=/etc/ssl/corp.pem\nproxy=http://p:1\n[section]\nfund=true\nno trailing newline' > "$(f npmrc)"
  cp "$(f npmrc)" "$BATS_TEST_TMPDIR/mine"
  ECO=npm apply > "$BATS_TEST_TMPDIR/log" 2>&1
  npmrc_is_ours_then "$BATS_TEST_TMPDIR/mine"
  ! grep -E 'took your own|may set or defeat' "$BATS_TEST_TMPDIR/log"
  cp "$(f npmrc)" "$BATS_TEST_TMPDIR/once"
  ECO=npm apply >/dev/null 2>&1
  cmp "$(f npmrc)" "$BATS_TEST_TMPDIR/once"
}

@test "npmrc: CRLF lines stay CRLF, and a CRLF-converted block is replaced, not doubled" {
  printf '//registry.example/:_authToken=SECRET\r\n\r\nproxy=http://p:1\r\n' > "$(f npmrc)"
  cp "$(f npmrc)" "$BATS_TEST_TMPDIR/mine"
  ECO=npm apply >/dev/null 2>&1
  npmrc_is_ours_then "$BATS_TEST_TMPDIR/mine"
  # an editor that saves the whole file with CRLF
  awk '{ sub(/\r$/, ""); printf "%s\r\n", $0 }' "$(f npmrc)" > "$BATS_TEST_TMPDIR/crlf"
  cat "$BATS_TEST_TMPDIR/crlf" > "$(f npmrc)"
  ECO=npm apply > "$BATS_TEST_TMPDIR/log" 2>&1
  npmrc_is_ours_then "$BATS_TEST_TMPDIR/mine"
  ! grep 'took your own' "$BATS_TEST_TMPDIR/log"
}

@test "npmrc: a user's line for one of our settings is taken out after a 0600 copy, named, and its value never printed" {
  # Every spelling npm's ini reader takes for the key (MEASURED, npm 6 to 12).
  printf '%b' 'fund=SECRETVALUE\n"ignore-scripts"=false\n'"'"'audit'"'"'=false\nsave-exact ;x=false\nupdate-notifier[]=true\n\xc2\xa0allow-git=all\nkeep=1\rmin-release-age=0\rkeep2=2\n' > "$(f npmrc)"
  chmod 600 "$(f npmrc)"
  cp "$(f npmrc)" "$BATS_TEST_TMPDIR/orig"
  ECO=npm apply > "$BATS_TEST_TMPDIR/log" 2>&1
  printf 'keep=1\rkeep2=2\n' > "$BATS_TEST_TMPDIR/mine"
  npmrc_is_ours_then "$BATS_TEST_TMPDIR/mine"
  grep -q 'took your own setting of fund, ignore-scripts, audit, save-exact, update-notifier, allow-git, min-release-age out of' "$BATS_TEST_TMPDIR/log" \
    || { cat "$BATS_TEST_TMPDIR/log"; return 1; }
  [ "$(copies npmrc | wc -l)" -eq 1 ]
  cmp "$(copies npmrc)" "$BATS_TEST_TMPDIR/orig"
  [ "$(mode "$(copies npmrc)")" = -rw------- ]
  grep -q "$(copies npmrc)" "$BATS_TEST_TMPDIR/log"
  ! grep SECRETVALUE "$BATS_TEST_TMPDIR/log"
  # and once only
  ECO=npm apply > "$BATS_TEST_TMPDIR/log" 2>&1
  ! grep 'took your own' "$BATS_TEST_TMPDIR/log"
  [ "$(copies npmrc | wc -l)" -eq 1 ]
}

@test "npmrc: what npm login leaves (our settings, no comments, no block) is ours again, with no copy and no warning" {
  apply >/dev/null 2>&1
  # `npm login` and `npm config set` rewrite the file without its comments, the
  # block markers included, and chmod it 0600 (MEASURED, npm 6 to 12).
  { settings; echo '//registry.example/:_authToken=SECRET'; } > "$(f npmrc)"
  ECO=npm apply > "$BATS_TEST_TMPDIR/log" 2>&1
  echo '//registry.example/:_authToken=SECRET' > "$BATS_TEST_TMPDIR/mine"
  npmrc_is_ours_then "$BATS_TEST_TMPDIR/mine"
  [ -z "$(copies npmrc)" ]
  ! grep -E 'took your own|SECRET' "$BATS_TEST_TMPDIR/log"
}

@test "npmrc: the same with a real npm config set" {
  have npm || skip "npm not installed"
  apply >/dev/null 2>&1
  env -i PATH="$PATH" HOME="$TEST_HOME" npm config set //registry.example/:_authToken=SECRET --location=user >/dev/null 2>&1
  ! grep -q 'supply-chain-hardening' "$(f npmrc)" || skip "this npm kept the comments"
  ECO=npm apply > "$BATS_TEST_TMPDIR/log" 2>&1
  echo '//registry.example/:_authToken=SECRET' > "$BATS_TEST_TMPDIR/mine"
  npmrc_is_ours_then "$BATS_TEST_TMPDIR/mine" || { cat "$(f npmrc)"; return 1; }
  [ -z "$(copies npmrc)" ]
}

@test "npmrc: a line put inside the block stays, and an edited setting there is named" {
  apply >/dev/null 2>&1
  awk '{ print } /^audit=/ { print "//registry.example/:_authToken=SECRET"; print "; mine" } ' "$(f npmrc)" \
    | sed 's/^fund=false$/fund=true/' > "$BATS_TEST_TMPDIR/x"
  cat "$BATS_TEST_TMPDIR/x" > "$(f npmrc)"
  ECO=npm apply > "$BATS_TEST_TMPDIR/log" 2>&1
  printf '//registry.example/:_authToken=SECRET\n; mine\n' > "$BATS_TEST_TMPDIR/mine"
  npmrc_is_ours_then "$BATS_TEST_TMPDIR/mine" || { cat "$(f npmrc)"; return 1; }
  grep -q 'took your own setting of fund out of' "$BATS_TEST_TMPDIR/log"
}

@test "npmrc: a deleted end marker, and a block moved below other lines, lose nothing" {
  plant
  apply >/dev/null 2>&1
  { echo 'proxy=http://p:1'; grep -v '^; <<<' "$(f npmrc)"; } > "$BATS_TEST_TMPDIR/x"
  cat "$BATS_TEST_TMPDIR/x" > "$(f npmrc)"
  ECO=npm apply > "$BATS_TEST_TMPDIR/log" 2>&1
  printf 'proxy=http://p:1\n//registry.example/:_authToken=SECRET-npmrc\n' > "$BATS_TEST_TMPDIR/mine"
  npmrc_is_ours_then "$BATS_TEST_TMPDIR/mine" || { cat "$(f npmrc)"; return 1; }
  ! grep 'took your own' "$BATS_TEST_TMPDIR/log"
}

@test "npmrc: a changed window is our own line changing, not the user's" {
  plant
  apply >/dev/null 2>&1
  ECO=npm apply RELEASE_AGE_HOURS=168 > "$BATS_TEST_TMPDIR/log" 2>&1
  block | grep -qx 'min-release-age=7'
  [ "$(grep -c min-release-age "$(f npmrc)")" -eq 1 ]
  [ -z "$(copies npmrc)" ]
  ! grep 'took your own' "$BATS_TEST_TMPDIR/log"
}

@test "npmrc: a key that cannot be read with certainty is kept and named, not guessed at" {
  # shellcheck disable=SC2016
  printf '%s\n' '"ignore-scripts"=false' '${X}=1' 'ignore-${Y}=1' '//${HOST}/:_authToken=SECRET' '[fund]' 'a=b' > "$(f npmrc)"
  cp "$(f npmrc)" "$BATS_TEST_TMPDIR/mine"
  ECO=npm apply > "$BATS_TEST_TMPDIR/log" 2>&1
  npmrc_is_ours_then "$BATS_TEST_TMPDIR/mine"
  # shellcheck disable=SC2016
  grep -qF 'line 1, a quoted key with an escape in it; line 2, the key ${X}; line 3, the key ignore-${Y}; line 5, a [section] named after fund' "$BATS_TEST_TMPDIR/log" \
    || { cat "$BATS_TEST_TMPDIR/log"; return 1; }
  ! grep -E 'SECRET|HOST' "$BATS_TEST_TMPDIR/log"
}

@test "npmrc: before, which npm uses instead of min-release-age, is kept and named" {
  # MEASURED on npm 11.19.1 and 12.2.3: with min-release-age=36500 and
  # before=<yesterday> in one file, in either order, the install goes through.
  printf 'before=2026-01-01\n' > "$(f npmrc)"
  ECO=npm apply > "$BATS_TEST_TMPDIR/log" 2>&1
  rest | grep -qx 'before=2026-01-01'
  grep -q 'line 1, before, which npm uses instead of min-release-age' "$BATS_TEST_TMPDIR/log"
}

@test "npmrc: a byte-order mark stays at the start of the file" {
  printf '\357\273\277//registry.example/:_authToken=SECRET\n' > "$(f npmrc)"
  ECO=npm apply >/dev/null 2>&1
  [ "$(head -c 3 "$(f npmrc)" | od -An -tx1 | tr -d ' \n')" = efbbbf ]
  [ "$(LC_ALL=C grep -c "$(printf '\357\273\277')" "$(f npmrc)")" -eq 1 ]
  grep -qx '//registry.example/:_authToken=SECRET' "$(f npmrc)"
  cp "$(f npmrc)" "$BATS_TEST_TMPDIR/once"
  ECO=npm apply >/dev/null 2>&1
  cmp "$(f npmrc)" "$BATS_TEST_TMPDIR/once"
}

@test "npmrc: npm reads our settings from the merged file, whatever the user's lines are" {
  have npm || skip "npm not installed"
  local d="$BATS_TEST_TMPDIR/empty" k n=0 c
  mkdir -p "$d"
  ask() { (cd "$d" && env -i PATH="$PATH" HOME="$TEST_HOME" npm config get "$1" --userconfig "$(f npmrc)" 2>/dev/null); }
  for c in 'a=b\n' '[section]\nignore-scripts=false\n' 'ignore-scripts=false\n' '"ignore-scripts"=false\n' 'ignore-scripts ;x=false' \
           'ignore-scripts[]=false\n' 'x=1\rignore-scripts=false\r\n' '\xef\xbb\xbfignore-scripts=false\n' '\xc2\xa0ignore-scripts=false\n' \
           ' ignore-scripts = false \nfund=true\n' "'\"ignore-scripts\"'=false\n" '[s] \nignore-scripts=false\n' 'ignore-scripts#x=false\n'; do
    rm -f "$(f npmrc)"* ; n=$((n + 1))
    printf '%b' "$c" > "$(f npmrc)"
    ECO=npm apply >/dev/null 2>&1
    [ "$(ask ignore-scripts)" = true ] || { echo "case $n: $c: $(ask ignore-scripts)"; cat "$(f npmrc)"; return 1; }
    [ "$(ask fund)" = false ] || { echo "case $n: $c: fund $(ask fund)"; return 1; }
  done
  # FIXTURE CONTROL: without the rule, that line wins.
  printf 'ignore-scripts=true\n"ignore-scripts"=false\n' > "$(f npmrc)"
  [ "$(ask ignore-scripts)" = false ]
}

@test "npmrc: npm still sends the kept token" {
  have npm && have node || skip "npm not installed"
  # A registry that records the Authorization header it is sent.
  cat > "$BATS_TEST_TMPDIR/reg.js" <<'JS'
const http = require('http'), fs = require('fs')
const s = http.createServer((q, r) => {
  fs.appendFileSync(process.argv[3], (q.headers.authorization || 'none') + '\n')
  r.setHeader('content-type', 'application/json'); r.end('{"username":"me"}')
}).listen(0, '127.0.0.1', () => fs.writeFileSync(process.argv[2], String(s.address().port)))
setTimeout(() => process.exit(0), 60000)
JS
  node "$BATS_TEST_TMPDIR/reg.js" "$BATS_TEST_TMPDIR/port" "$BATS_TEST_TMPDIR/auth" 3>&- >/dev/null 2>&1 &
  local pid=$! i port
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -s "$BATS_TEST_TMPDIR/port" ] && break; sleep 0.25; done
  port=$(cat "$BATS_TEST_TMPDIR/port")
  printf 'registry=http://127.0.0.1:%s/\n//127.0.0.1:%s/:_authToken=FAKETOKEN\n' "$port" "$port" > "$(f npmrc)"
  chmod 600 "$(f npmrc)"
  ECO=npm apply >/dev/null 2>&1
  mkdir -p "$BATS_TEST_TMPDIR/empty"
  (cd "$BATS_TEST_TMPDIR/empty" && env -i PATH="$PATH" HOME="$TEST_HOME" npm whoami --userconfig "$(f npmrc)" >/dev/null 2>&1) || true
  kill "$pid" 2>/dev/null || true
  grep -qx 'Bearer FAKETOKEN' "$BATS_TEST_TMPDIR/auth" || { cat "$BATS_TEST_TMPDIR/auth"; return 1; }
}

# --------------------------------------------------------------- modes and links

@test "user config: ~/.npmrc ends 0600, or tighter if it was; nothing is loosened" {
  local m want
  for m in 644 600 660 400 444 666; do
    rm -f "$(f npmrc)"
    printf 'a=b\n' > "$(f npmrc)"; chmod "$m" "$(f npmrc)"
    ECO=npm apply > "$BATS_TEST_TMPDIR/log" 2>&1
    case "$m" in 4*) want=-r-------- ;; *) want=-rw------- ;; esac
    [ "$(mode "$(f npmrc)")" = "$want" ] || { echo "$m: $(mode "$(f npmrc)")"; return 1; }
    case "$m" in 600|400) ! grep 'is 0600 now' "$BATS_TEST_TMPDIR/log" ;; *) grep -q "$(f npmrc): other accounts could read it" "$BATS_TEST_TMPDIR/log" ;; esac
  done
}

@test "user config: the other seven keep their mode or get a tighter one" {
  plant
  local k
  for k in $SEVEN; do chmod 600 "$(f "$k")"; done
  apply >/dev/null 2>&1
  for k in $SEVEN; do [ "$(mode "$(f "$k")")" = -rw------- ] || { echo "$k $(mode "$(f "$k")")"; return 1; }; done
  # and over a file of our own, loosened by hand
  for k in $SEVEN; do chmod 666 "$(f "$k")"; done
  apply >/dev/null 2>&1
  for k in $SEVEN; do [ "$(mode "$(f "$k")")" = -rw-r--r-- ] || { echo "$k $(mode "$(f "$k")")"; return 1; }; done
}

@test "user config: a symlinked file is written through, and the link stays" {
  mkdir -p "$TEST_HOME/dotfiles"
  plant
  local k
  for k in npmrc $SEVEN; do
    mv "$(f "$k")" "$TEST_HOME/dotfiles/$k"
    ln -s "$TEST_HOME/dotfiles/$k" "$(f "$k")"
  done
  # a relative link too
  rm -f "$(f npmrc)"; ln -s dotfiles/npmrc "$(f npmrc)"
  apply >/dev/null 2>&1
  for k in npmrc $SEVEN; do
    [ -L "$(f "$k")" ] || { echo "$k: link gone"; return 1; }
    [ ! -L "$TEST_HOME/dotfiles/$k" ]
    grep -q 'Managed by supply-chain-harden' "$TEST_HOME/dotfiles/$k" || { echo "$k"; return 1; }
  done
  grep -q SECRET-npmrc "$TEST_HOME/dotfiles/npmrc"
  # the copies are next to the link, not in the dotfiles checkout somebody commits
  [ -z "$(ls "$TEST_HOME/dotfiles" | grep '~$')" ]
  for k in $SEVEN; do grep -q "SECRET-$k" "$(copies "$k")"; done
  local before
  before=$(snapshot_but_cutoffs)
  apply >/dev/null 2>&1
  diff <(printf '%s\n' "$before") <(snapshot_but_cutoffs)
}

@test "user config: a dangling link is filled in; a link to a device is refused and the device left alone" {
  ln -s "$TEST_HOME/elsewhere" "$(f npmrc)"
  ECO=npm apply >/dev/null 2>&1
  [ -L "$(f npmrc)" ]
  grep -q '^ignore-scripts=true' "$TEST_HOME/elsewhere"
  rm -f "$(f npmrc)"; ln -s /dev/null "$(f npmrc)"
  ECO=npm run apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"$(f npmrc) is not a regular file; it was left as it is"* ]]
  [ -c /dev/null ]
  run pf
  [[ "$output" == *"STOP  $(f npmrc): is not a regular file"* ]]
}

@test "user config: a file in the way that cannot be written is refused by name, and nothing in it changes" {
  [ "$(id -u)" -ne 0 ] || skip "running as root: nothing is unreadable"
  printf 'a=SECRET\n' > "$(f npmrc)"; chmod 000 "$(f npmrc)"
  ECO=npm run apply
  chmod 600 "$(f npmrc)"
  [ "$status" -eq 1 ]
  [[ "$output" == *"npm: $(f npmrc) cannot be read by"* ]]
  [ "$(cat "$(f npmrc)")" = a=SECRET ]
  # a directory that cannot be written to, with a file that can: written in place
  ECO=uv apply >/dev/null 2>&1
  chmod 555 "$(dirname "$(f uv)")"
  ECO=uv run apply RELEASE_AGE_HOURS=72
  chmod 755 "$(dirname "$(f uv)")"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  # and with one that cannot be, nor copied: refused, unchanged
  printf 'x = "SECRET"\n' > "$(f uv)"
  chmod 555 "$(dirname "$(f uv)")"
  ECO=uv run apply
  chmod 755 "$(dirname "$(f uv)")"
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not copy $(f uv) next to itself"* ]]
  [ "$(cat "$(f uv)")" = 'x = "SECRET"' ]
}

@test "user config: a read-only home is refused by name, not with a bare shell error" {
  [ "$(id -u)" -ne 0 ] || skip "running as root"
  local state="$BATS_TEST_TMPDIR/state"
  mkdir -p "$state"
  chmod 555 "$TEST_HOME"
  ECO=npm run apply RUNNER_TEMP="$state"
  chmod 755 "$TEST_HOME"
  [ "$status" -eq 1 ]
  [[ "$output" == *"npm: $(f npmrc) cannot be created: $TEST_HOME is not a directory this account can write to"* ]] || { echo "$output"; return 1; }
  [ ! -e "$(f npmrc)" ]
}

@test "user config: a file another account owns is refused, and kept" {
  sudo -n true 2>/dev/null || skip "no passwordless sudo"
  [ "$(id -u)" -ne 0 ] || skip "running as root"
  printf 'a=SECRET\n' > "$(f npmrc)"
  sudo chown 0 "$(f npmrc)"
  ECO=npm run apply
  [ "$status" -eq 1 ]
  [[ "$output" == *"$(f npmrc) belongs to another account (root); it was left as it is"* ]]
  grep -q SECRET "$(f npmrc)"
}

@test "user config: a killed run leaves the old file or the new one, never half of one" {
  # The write is a rename: no other process ever sees the target empty.
  plant
  lib
  local i=0 bad="$BATS_TEST_TMPDIR/bad"
  settings | sed '1s/^/; Managed by supply-chain-harden action\n/' > "$BATS_TEST_TMPDIR/body"
  ( while [ ! -e "$BATS_TEST_TMPDIR/stop" ]; do
      grep -q SECRET-npmrc "$(f npmrc)" 2>/dev/null || { echo half >> "$bad"; }
    done ) 3>&- &
  local pid=$!
  while [ "$i" -lt 20 ]; do
    i=$((i + 1))
    { echo "; Managed by supply-chain-harden action"; echo "min-release-age=$i"; } | ucf_npmrc "$(f npmrc)" >/dev/null
  done
  touch "$BATS_TEST_TMPDIR/stop"; wait "$pid" 2>/dev/null || true
  [ ! -e "$bad" ] || { wc -l "$bad"; return 1; }
  [ -z "$(ls -A "$TEST_HOME" | grep '^\.sch-')" ]
}

# -------------------------------------------------------------- the self-check

@test "user config: any change to a file we wrote is noticed; a cutoff the refresher advanced is not one" {
  apply >/dev/null 2>&1
  lib
  local k
  for k in $SEVEN; do
    [ "$(user_cfg_class "$k" "$(f "$k")")" = ours ] || { echo "$k"; cat "$(f "$k")"; return 1; }
    cp "$(f "$k")" "$BATS_TEST_TMPDIR/x"; printf ' ' >> "$BATS_TEST_TMPDIR/x"
    [ "$(user_cfg_class "$k" "$BATS_TEST_TMPDIR/x")" = foreign ] || { echo "$k: one space"; return 1; }
    grep -v "$(grep -v '^[#;]' "$(f "$k")" | sed -n '3p' | cut -c1-6)" "$(f "$k")" > "$BATS_TEST_TMPDIR/x"
    [ "$(user_cfg_class "$k" "$BATS_TEST_TMPDIR/x")" = foreign ] || { echo "$k: a line gone"; return 1; }
    # the marker without its checksum, over a line of the user's
    { sed 's/; self-check .*//' "$(f "$k")"; echo 'x = "SECRET"'; } > "$BATS_TEST_TMPDIR/x"
    [ "$(user_cfg_class "$k" "$BATS_TEST_TMPDIR/x")" = foreign ] || { echo "$k: marker cut"; return 1; }
    # no marker
    grep -v 'Managed by' "$(f "$k")" > "$BATS_TEST_TMPDIR/x"; echo 'x = "SECRET"' >> "$BATS_TEST_TMPDIR/x"
    [ "$(user_cfg_class "$k" "$BATS_TEST_TMPDIR/x")" = foreign ] || { echo "$k: no marker"; return 1; }
  done
  # templates/age-gate-refresh.sh.j2 rewrites these two lines in place
  sed 's/^exclude-newer = ".*"$/exclude-newer = "2026-12-31T00:00:00Z"/' "$(f uv)" > "$BATS_TEST_TMPDIR/x"
  ! cmp -s "$(f uv)" "$BATS_TEST_TMPDIR/x"
  [ "$(user_cfg_class uv "$BATS_TEST_TMPDIR/x")" = ours ]
  sed 's/^uploaded-prior-to = .*$/uploaded-prior-to = 2026-12-31T00:00:00Z/' "$(f pip)" > "$BATS_TEST_TMPDIR/x"
  ! cmp -s "$(f pip)" "$BATS_TEST_TMPDIR/x"
  [ "$(user_cfg_class pip "$BATS_TEST_TMPDIR/x")" = ours ]
  # only in the shape the refresher writes, and only those lines
  sed 's/^exclude-newer = ".*"$/exclude-newer = "SECRET"/' "$(f uv)" > "$BATS_TEST_TMPDIR/x"
  [ "$(user_cfg_class uv "$BATS_TEST_TMPDIR/x")" = foreign ]
}

@test "user config: the self-check's refresher lines are the ones templates/age-gate-refresh.sh.j2 rewrites" {
  local t="$ROOT/templates/age-gate-refresh.sh.j2"
  grep -qF "ts='[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}T[0-9:.]*Z'" "$t"
  grep -qF "local ts='[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}T[0-9:.]*Z'" "$HARDEN_SH"
  grep -qF '"^exclude-newer = \"$ts\"\$"' "$t"
  grep -qF '"^uploaded-prior-to = $ts\$"' "$t"
  [ "$(grep -c 'advance .*uv.toml\|advance .*pip.conf' "$t")" -eq 4 ]
}

@test "user config: with no sha256 tool the check is a cksum, and still works" {
  lib
  local d="$BATS_TEST_TMPDIR/nosha" t p
  mkdir -p "$d"
  for t in awk bash basename cat chmod cksum cmp cut date dirname env grep head id ls mkdir mktemp mv od readlink rm sed sh tr uname wc; do
    p=$(type -P "$t") && ln -s "$p" "$d/$t"
  done
  printf '# Managed by supply-chain-harden action\nno-build = true\n' | PATH="$d" ucf_replace uv "$TEST_HOME/uv.toml"
  grep -q 'self-check cksum:' "$TEST_HOME/uv.toml"
  [ "$(PATH="$d" user_cfg_class uv "$TEST_HOME/uv.toml")" = ours ]
  # and where there is one, it is still checked the way it was written
  [ "$(user_cfg_class uv "$TEST_HOME/uv.toml")" = ours ]
  echo 'x = 1' >> "$TEST_HOME/uv.toml"
  [ "$(PATH="$d" user_cfg_class uv "$TEST_HOME/uv.toml")" = foreign ]
}

# -------------------------------------------------------------------- preflight

@test "preflight: STOP for each of the seven that is not ours, a note for ~/.npmrc, and it is what the run does" {
  plant
  printf 'fund=true\nbefore=2026-01-01\n' >> "$(f npmrc)"
  chmod 644 "$(f npmrc)"
  local before k
  before=$(snapshot)
  pf > "$BATS_TEST_TMPDIR/pf" || true
  diff <(printf '%s\n' "$before") <(snapshot)          # it changed nothing
  ! grep SECRET "$BATS_TEST_TMPDIR/pf"
  for k in $SEVEN; do
    grep -qF "STOP  $(f "$k"): not exactly what this project last wrote" "$BATS_TEST_TMPDIR/pf" || { cat "$BATS_TEST_TMPDIR/pf"; return 1; }
  done
  ! grep -F "STOP  $(f npmrc)" "$BATS_TEST_TMPDIR/pf"
  grep -qF "note  $(f npmrc): merged, never replaced" "$BATS_TEST_TMPDIR/pf"
  grep -qF "note  $(f npmrc): except your own setting of fund, which would win over the block" "$BATS_TEST_TMPDIR/pf"
  grep -qF "note  $(f npmrc): kept, but may set or defeat one of the settings in the block: line 3, before" "$BATS_TEST_TMPDIR/pf"
  grep -qF "note  $(f npmrc): other accounts can read it (-rw-r--r--); it becomes 0600." "$BATS_TEST_TMPDIR/pf"
  # The run then says the same.
  apply > "$BATS_TEST_TMPDIR/log" 2>&1
  grep -q 'took your own setting of fund out of' "$BATS_TEST_TMPDIR/log"
  grep -q 'line 3, before, which npm uses' "$BATS_TEST_TMPDIR/log"
  grep -q "other accounts could read it (-rw-r--r--); it is 0600 now" "$BATS_TEST_TMPDIR/log"
  # And after it nothing stops.
  pf > "$BATS_TEST_TMPDIR/pf" || true
  ! grep -F "STOP  $TEST_HOME" "$BATS_TEST_TMPDIR/pf"
  for k in $SEVEN; do
    grep -qF "$(f "$k"): exactly what this project last wrote, replaced as before" "$BATS_TEST_TMPDIR/pf" || { cat "$BATS_TEST_TMPDIR/pf"; return 1; }
  done
  ! grep 'except your own setting\|it becomes 0600' "$BATS_TEST_TMPDIR/pf"
}

@test "preflight: a home with none of the eight says each will be created" {
  pf > "$BATS_TEST_TMPDIR/pf" || true
  local k
  for k in npmrc $SEVEN; do
    grep -qF "$(f "$k"): not there, will be created" "$BATS_TEST_TMPDIR/pf" || { cat "$BATS_TEST_TMPDIR/pf"; return 1; }
  done
  [ -z "$(find "$TEST_HOME" -type f)" ]
}

# --------------------------------------------------------- the same on both surfaces

@test "user config: the block in files/user-config.sh is harden.sh's, byte for byte" {
  sed -n '/^# >>> user_config$/,/^# <<< user_config$/p' "$ROOT/files/user-config.sh" > "$BATS_TEST_TMPDIR/role"
  sed -n '/^# >>> user_config$/,/^# <<< user_config$/p' "$HARDEN_SH" > "$BATS_TEST_TMPDIR/act"
  [ "$(wc -l < "$BATS_TEST_TMPDIR/role")" -gt 300 ]
  diff "$BATS_TEST_TMPDIR/role" "$BATS_TEST_TMPDIR/act"
  # no second copy of any of it in harden.sh
  [ "$(grep -c '^user_cfg_class() {' "$HARDEN_SH")" -eq 1 ]
}

@test "user config: the script parses on bash 3.2 and BSD terms (no bash 4 construct)" {
  bash -n "$ROOT/files/user-config.sh"
  ! grep -nE 'declare -A|mapfile|readarray|\$\{[a-z_]+(,,|\^\^)|readlink -f|sed -i|grep -P|stat -c' "$ROOT/files/user-config.sh"
}

@test "user config: each of the eight is written through the shared code on both surfaces, and by nothing else" {
  local k
  for k in npmrc $SEVEN; do
    [ "$(grep -c "put_user_cfg $k " "$HARDEN_SH")" -eq 1 ] || { echo "harden.sh: $k"; return 1; }
  done
  [ "$(cat "$ROOT"/tasks/*.yml | grep -c 'ansible.builtin.script: user-config.sh npmrc$')" -eq 1 ]
  for k in $SEVEN; do
    [ "$(cat "$ROOT"/tasks/*.yml | grep -c "ansible.builtin.script: user-config.sh replace $k\$")" -eq 1 ] || { echo "role: $k"; return 1; }
  done
  # no template or redirect into one of them is left
  ! grep -nE '> "\$HOME/\.(npmrc|yarnrc\.yml|bundle/config|config/(pnpm|pip))' "$HARDEN_SH"
  ! grep -nE 'dest: .*(ansible_env\.HOME \}\}/\.(npmrc|yarnrc\.yml|bundle/config)|\.config/pip/pip\.conf|pnpm_config_dir|uv_config_dir|bun_bunfig_path)' "$ROOT"/tasks/*.yml
}

@test "user config: the role's tasks judge the same files, at the paths they write" {
  # tasks/preflight.yml names every kind, with the tags of its include.
  lib
  local k
  for k in $UCF_KINDS cargo maven nuget; do
    grep -qE "^      $k: \[" "$ROOT/tasks/preflight.yml" || { echo "$k"; return 1; }
  done
  # and the role's own path expression for each is the one ucf_path gives
  HOME=/h XDG_CONFIG_HOME=/x
  [ "$(ucf_path uv)" = /x/uv/uv.toml ] && [ "$(ucf_path bun)" = /x/.bunfig.toml ] && [ "$(ucf_path pnpm-rc)" = /x/pnpm/rc ]
  [ "$(ucf_path pip)" = /h/.config/pip/pip.conf ]      # tasks/pip.yml does not follow XDG_CONFIG_HOME
  unset XDG_CONFIG_HOME
  [ "$(ucf_path uv)" = /h/.config/uv/uv.toml ] && [ "$(ucf_path bun)" = /h/.bunfig.toml ]
  [ "$(ucf_path npmrc)" = /h/.npmrc ] && [ "$(ucf_path yarn)" = /h/.yarnrc.yml ] && [ "$(ucf_path bundler)" = /h/.bundle/config ]
  case "$(uname -s)" in
    Darwin) [ "$(ucf_path pnpm-yaml)" = /h/Library/Preferences/pnpm/config.yaml ] ;;
    *) [ "$(ucf_path pnpm-yaml)" = /h/.config/pnpm/config.yaml ] ;;
  esac
}
