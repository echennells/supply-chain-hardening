#!/usr/bin/env bats
# The role and what is the user's in the eight per-user config files it writes
# (issue 48, item 1). ~/.npmrc is merged; the other seven are replaced whole, and
# the preflight refuses one that is not exactly what the role last wrote.
#
# MEASURED at d738db8: an apply dropped a fake token or registry from all eight,
# with no copy and no message, turned a 0600 ~/.npmrc into 0644, and did it again
# to a token added after hardening.
#
# Each test applies the role for a home of its own (HOME is what the role reads),
# with only the tasks that write these files. tests/ci/13-user-config.bats covers
# the same code on the action's side in more detail.

load setup

SEVEN="pnpm-yaml pnpm-rc yarn pip uv bun bundler"
TAGS=npm,pnpm,yarn,bun,uv,pip,bundler

setup() {
  require_root "applies the role, which writes /etc and /usr/local/bin"
  T=$(mktemp -d)
  H="$T/home"
  mkdir -p "$H"
  # What the role also writes outside the home, so a test can leave it as it was.
  SAVED="/etc/npmrc /etc/pip.conf /etc/uv/uv.toml /etc/environment /etc/profile.d/supply-chain-hardening.sh /usr/local/bin/pip /usr/local/bin/pip3 /usr/local/sbin/supply-chain-age-gate-refresh"
  local x
  for x in $SAVED; do
    if [ -e "$x" ]; then mkdir -p "$T/saved$(dirname "$x")"; cp -p "$x" "$T/saved$x"; fi
  done
}

teardown() {
  [ -n "${T:-}" ] || return 0
  local x
  for x in $SAVED; do
    if [ -e "$T/saved$x" ]; then cmp -s "$x" "$T/saved$x" || cp -p "$T/saved$x" "$x"; fi
  done
  rm -rf "$T"
}

f() { # <kind>
  case "$1" in
    npmrc) echo "$H/.npmrc" ;;
    pnpm-yaml) echo "$H/.config/pnpm/config.yaml" ;;
    pnpm-rc) echo "$H/.config/pnpm/rc" ;;
    yarn) echo "$H/.yarnrc.yml" ;;
    pip) echo "$H/.config/pip/pip.conf" ;;
    uv) echo "$H/.config/uv/uv.toml" ;;
    bun) echo "$H/.bunfig.toml" ;;
    bundler) echo "$H/.bundle/config" ;;
  esac
}

copies() { local b; for b in "$(f "$1")".*~; do [ -e "$b" ] && echo "$b"; done; return 0; }

role() { # [ansible args]: output in $output, the play's status in $status
  cd "$ROLE_DIR"
  run env -u XDG_CONFIG_HOME HOME="$H" ansible-playbook site.yml --connection=local --limit localhost \
    --tags "${ONLY:-$TAGS}" --skip-tags npq,socket \
    -e podman_enabled=false -e verify_protections=false -e socket_firewall_install=false -e age_gate_refresh=false "$@"
}

changed() { echo "$output" | sed -n 's/^localhost .*changed=\([0-9]*\).*/\1/p' | tail -1; }

plant() {
  mkdir -p "$H/.config/pnpm" "$H/.config/uv" "$H/.config/pip" "$H/.bundle"
  printf '# mine\n//registry.example/:_authToken=SECRET-npmrc\nfund=SECRETVALUE\n' > "$(f npmrc)"
  printf 'registry: https://u:SECRET-pnpm-yaml@example/\n' > "$(f pnpm-yaml)"
  printf 'registry=https://u:SECRET-pnpm-rc@example/\n' > "$(f pnpm-rc)"
  printf 'npmAuthToken: "SECRET-yarn"\n' > "$(f yarn)"
  printf '[global]\nindex-url = https://u:SECRET-pip@example/simple\n' > "$(f pip)"
  printf '[[index]]\nurl = "https://u:SECRET-uv@example/simple"\n' > "$(f uv)"
  printf '[install]\nregistry = "https://u:SECRET-bun@example"\n' > "$(f bun)"
  printf -- '---\nBUNDLE_GEMS__EXAMPLE: "u:SECRET-bundler"\n' > "$(f bundler)"
  local k
  for k in npmrc $SEVEN; do chmod 600 "$(f "$k")"; done
}

snapshot() { ( cd "$H" && find . -path ./.ansible -prune -o -path ./.cache -prune -o -path ./.npm -prune -o -path ./.local -prune -o \( -type f -o -type l \) -printf '%p %m %u %s\n' -exec cksum {} \; | sort ); }

@test "role: refuses the seven when they hold something of the user's, before anything is changed, and says which" {
  plant
  local before k
  before=$(snapshot)
  role --diff
  [ "$status" -ne 0 ]
  echo "$output" | grep -q '\[supply-chain-hardening\] Refusing to overwrite existing per-user config'
  for k in $SEVEN; do echo "$output" | grep -qF "$(f "$k")" || { echo "$k not named"; return 1; }; done
  echo "$output" | grep -q 'accept_user_config_overwrite=true'
  [ "$(changed)" = 0 ]
  diff <(echo "$before") <(snapshot)
  ! echo "$output" | grep SECRET
  # --tags for one of them stops on that one only
  ONLY=yarn role
  [ "$status" -ne 0 ]
  echo "$output" | grep -qF "$(f yarn)"
  ! echo "$output" | grep -qF "$(f uv)"
}

@test "role: --check --diff with the overwrite accepted says what would happen, changes nothing and prints no line of theirs" {
  plant
  local before
  before=$(snapshot)
  role --check --diff -e accept_user_config_overwrite=true
  [ "$status" -eq 0 ] || { echo "$output" | tail -30; return 1; }
  diff <(echo "$before") <(snapshot)
  echo "$output" | grep -qF "$(f npmrc): your own setting of fund would be taken out"
  echo "$output" | grep -qF "$(f uv): would be copied next to itself (0600) first"
  ! echo "$output" | grep SECRET
}

@test "role: with the overwrite accepted ~/.npmrc is merged, the seven are copied 0600 and replaced, nothing is lost or printed, and a second run changes nothing" {
  plant
  role -vvv --diff -e accept_user_config_overwrite=true
  [ "$status" -eq 0 ] || { echo "$output" | tail -30; return 1; }
  ! echo "$output" | grep SECRET
  local k before
  # ~/.npmrc: the token and the comment stay; fund, which is ours, went, after a copy
  grep -qx '//registry.example/:_authToken=SECRET-npmrc' "$(f npmrc)"
  grep -qx '# mine' "$(f npmrc)"
  ! grep -q SECRETVALUE "$(f npmrc)"
  grep -q 'fund=SECRETVALUE' "$(copies npmrc)"
  [ "$(stat -c %a "$(f npmrc)")" = 600 ]
  [ "$(stat -c %a "$(copies npmrc)")" = 600 ]
  head -1 "$(f npmrc)" | grep -q '^; >>> supply-chain-hardening: Managed by ansible-supply-chain-security; self-check sha256:'
  echo "$output" | grep -qF "$(f npmrc): your own setting of fund was taken out"
  for k in $SEVEN; do
    ! grep -q SECRET "$(f "$k")"
    grep -q 'Managed by ansible-supply-chain-security; self-check sha256:' "$(f "$k")" || { echo "$k"; return 1; }
    grep -q "SECRET-$k" "$(copies "$k")" || { echo "$k lost"; return 1; }
    [ "$(stat -c %a "$(copies "$k")")" = 600 ]
    [ "$(stat -c %a "$(f "$k")")" = 600 ]              # kept, not loosened to 0644
    echo "$output" | grep -qF "$(copies "$k")"
  done
  before=$(snapshot)
  role
  [ "$status" -eq 0 ]
  [ "$(changed)" = 0 ] || { echo "$output" | grep -A3 '^changed'; return 1; }
  diff <(echo "$before") <(snapshot)
}

@test "role: a token added after hardening stops the play for the seven, and stays in ~/.npmrc" {
  role
  [ "$status" -eq 0 ] || { echo "$output" | tail -30; return 1; }
  [ "$(stat -c %a "$(f npmrc)")" = 600 ]
  [ "$(stat -c %a "$(f uv)")" = 644 ]
  local k
  for k in npmrc $SEVEN; do printf '# SECRET-%s\n' "$k" >> "$(f "$k")"; done
  local before
  before=$(snapshot)
  role
  [ "$status" -ne 0 ]
  for k in $SEVEN; do echo "$output" | grep -qF "$(f "$k")" || { echo "$k not named"; return 1; }; done
  diff <(echo "$before") <(snapshot)
  ONLY=npm role
  [ "$status" -eq 0 ]
  grep -q SECRET-npmrc "$(f npmrc)"
  [ -z "$(copies npmrc)" ]
}

@test "role: the files v2.0.0 and v2.1.0 wrote, either surface, are upgraded without stopping or copying" {
  local v k d
  for v in v2.0.0-action v2.0.0-role v2.1.0-action v2.1.0-role; do
    rm -rf "$H"; mkdir -p "$H"
    for k in npmrc $SEVEN; do
      mkdir -p "$(dirname "$(f "$k")")"
      d="/opt/test-fixtures/user-config/$v/$k"
      [ -f "$d" ] || d="$ROLE_DIR/tests/fixtures/user-config/$v/$k"
      cp "$d" "$(f "$k")"; chmod 644 "$(f "$k")"
    done
    echo '//registry.example/:_authToken=SECRET-npmrc' >> "$(f npmrc)"
    role
    [ "$status" -eq 0 ] || { echo "$v"; echo "$output" | tail -30; return 1; }
    for k in npmrc $SEVEN; do
      [ -z "$(copies "$k")" ] || { echo "$v $k"; return 1; }
      grep -q 'Managed by ansible-supply-chain-security; self-check ' "$(f "$k")" || { echo "$v $k"; return 1; }
    done
    [ "$(sed '1,/^; <<< supply-chain-hardening$/d' "$(f npmrc)")" = '//registry.example/:_authToken=SECRET-npmrc' ] || { echo "$v"; cat "$(f npmrc)"; return 1; }
  done
}

@test "role: a symlinked ~/.npmrc is written through; one that cannot be written stops the play before anything changes" {
  mkdir -p "$H/dotfiles"
  printf '//registry.example/:_authToken=SECRET-npmrc\n' > "$H/dotfiles/npmrc"
  ln -s dotfiles/npmrc "$(f npmrc)"
  ONLY=npm role
  [ "$status" -eq 0 ] || { echo "$output" | tail -30; return 1; }
  [ -L "$(f npmrc)" ]
  grep -q SECRET-npmrc "$H/dotfiles/npmrc"
  grep -q '^ignore-scripts=true' "$H/dotfiles/npmrc"
  [ "$(stat -c %a "$H/dotfiles/npmrc")" = 600 ]
  rm -f "$(f npmrc)"; ln -s /dev/null "$(f npmrc)"
  role
  [ "$status" -ne 0 ]
  echo "$output" | grep -qF "$(f npmrc) is not a regular file"
  [ "$(changed)" = 0 ]
  [ -c /dev/null ]
}

@test "role: a cutoff the age-gate refresher advanced is still the role's own file" {
  # The deployed refresher targets the deploying user's files: root's here.
  local uv=/root/.config/uv/uv.toml pip=/root/.config/pip/pip.conf
  [ -x /usr/local/sbin/supply-chain-age-gate-refresh ] || skip "no refresher deployed"
  cp -p "$uv" "$T/uv"; cp -p "$pip" "$T/pip"
  sed -i 's/^exclude-newer = ".*"$/exclude-newer = "2020-01-01T00:00:00Z"/' "$uv"
  sed -i 's/^uploaded-prior-to = .*$/uploaded-prior-to = 2020-01-01T00:00:00Z/' "$pip"
  run /usr/local/sbin/supply-chain-age-gate-refresh --user
  local said="$output" cls
  cls=$(env -u XDG_CONFIG_HOME HOME=/root bash "$ROLE_DIR/files/user-config.sh" classify uv pip)
  local after_uv after_pip
  after_uv=$(grep '^exclude-newer' "$uv"); after_pip=$(grep '^uploaded-prior-to' "$pip")
  echo 'x = 1' >> "$uv"
  local edited
  edited=$(env -u XDG_CONFIG_HOME HOME=/root bash "$ROLE_DIR/files/user-config.sh" classify uv pip || true)
  cp -p "$T/uv" "$uv"; cp -p "$T/pip" "$pip"
  echo "$said"; echo "class: $cls; edited: $edited"
  [[ "$after_uv" != *2020-01-01* ]] && [[ "$after_pip" != *2020-01-01* ]]
  [ -z "$cls" ]
  [ "$edited" = "foreign $uv" ]
}
