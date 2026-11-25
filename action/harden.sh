#!/usr/bin/env bash
# Supply Chain Hardening — CI runtime.
#
# Applies package-manager-level hardening to a CI runner before subsequent
# steps execute. Mirrors a subset of the echennells.supply_chain_hardening
# Ansible role — the parts that apply in an ephemeral CI runner context.
# Skips role concerns that don't (podman policy, preflight conflict
# detection, systemd /etc/environment loading), keeps the parts that do
# (config files, PATH wrappers, env vars, optional sfw wrapper).
#
# PORTABILITY
#
# This script is CI-generic. The hardening lands in three layers and only
# one of them is platform-dependent:
#
#   1. Config files on disk (~/.npmrc, uv.toml, .bunfig.toml, ...) —
#      persist for the life of the job on every platform. No coupling.
#   2. PATH wrappers (bun, bunx, composer, deno, cargo) wrapped in place
#      at their discovered path. No coupling.
#   3. Env vars — the only layer that needs the platform's own mechanism
#      for reaching later steps, and everywhere a redundant second layer
#      behind (1). Routed through write_env() below.
#
# Everything platform-specific in this file goes through the adapter in
# the "CI platform adapter" section. Adding a platform means adding one
# case arm to each of those functions — not touching any harden_* code.
#
# GitHub Actions is the first-class adapter (see ../action/action.yml).
# The others are implemented but not yet exercised by CI; see the
# portability note in action/README.md before relying on them.

set -euo pipefail

# ---- Inputs (env-driven by action.yml, or set directly when invoked bare) ----
ECOSYSTEMS="${ECOSYSTEMS:-npm,pnpm,yarn,pip,uv,bun,composer,cargo,go,bundler,deno,maven,gradle,nuget}"
RELEASE_AGE_HOURS="${RELEASE_AGE_HOURS:-48}"
STRICT="${STRICT:-true}"
# ---- intel layer (optional malware intelligence) ----
#
# `intel` is capability-named; `INSTALL_SFW` is the older vendor-named form,
# still accepted. Resolved to INSTALL_SFW=true|false once, here, so nothing
# downstream has to know both spellings.
#
# CONFLICT IS AN ERROR, NOT A PRECEDENCE RULE. `intel: none` next to
# `install_sfw: true` has no defensible winner, and picking one silently means
# a workflow that reads as "intel off" can be running intel, or the reverse.
# Both are bad in a security control, so refuse and say so.
INTEL="${INTEL:-}"
INSTALL_SFW="${INSTALL_SFW:-}"
case "$INTEL" in
  ""|none|sfw) ;;
  *)
    echo "[supply-chain-harden] error: intel='$INTEL' is not recognised" >&2
    echo "  supported: none (default), sfw" >&2
    exit 2 ;;
esac
# A non-empty INTEL means the input was set EXPLICITLY (action.yml defaults it to
# empty, not 'none'), so intel + install_sfw together is the "both set" conflict —
# INCLUDING intel: none + install_sfw: true, which previously slipped past the
# now-removed `!= none` clause and silently turned intel ON against an explicit
# `intel: none`. Unset intel (empty) still lets legacy install_sfw win below.
if [ -n "$INSTALL_SFW" ] && [ -n "$INTEL" ]; then
  echo "[supply-chain-harden] error: set either 'intel' or the deprecated 'install_sfw', not both" >&2
  echo "  got intel='$INTEL' and install_sfw='$INSTALL_SFW'" >&2
  exit 2
fi
if [ -n "$INSTALL_SFW" ]; then
  case "$INSTALL_SFW" in
    true)  INTEL="sfw" ;;
    false) INTEL="none" ;;
    *)
      echo "[supply-chain-harden] error: install_sfw must be true or false, got '$INSTALL_SFW'" >&2
      exit 2 ;;
  esac
  echo "[supply-chain-harden] notice: 'install_sfw' is deprecated — use 'intel: ${INTEL}'" >&2
fi
[ -n "$INTEL" ] || INTEL="none"
case "$INTEL" in sfw) INSTALL_SFW=true ;; *) INSTALL_SFW=false ;; esac
WRITE_ETC="${WRITE_ETC:-true}"
COMPOSER_ALLOW_PLUGINS="${COMPOSER_ALLOW_PLUGINS:-false}"
PNPM_BUILT_DEPENDENCIES="${PNPM_BUILT_DEPENDENCIES:-}"
INSTALL_CARGO_COOLDOWN="${INSTALL_CARGO_COOLDOWN:-false}"
# Tool pins this script installs. Kept equal to the role's defaults/main.yml
# (cargo_cooldown_version, sfw_version, and for the sfw binary
# sfw_binary_version and sfw_binary_checksums); tests/ci/06-role-parity.bats
# checks.
# Unpinned, `cargo install cargo-cooldown` took 0.4.2 (MSRV 1.97): the install
# FAILED on rust 1.93 with the error discarded, and on rust >= 1.97 every
# later `cargo build` in an MSRV job died with "requires Cargo 1.97".
CARGO_COOLDOWN_VERSION="0.3.5"
SFW_NPM_VERSION="2.0.6"
# The firewall binary sfw gets here when it cannot fetch its own (see
# sfw_seed_binary): a floor, where the role's first install is the pin.
SFW_BINARY_VERSION="v1.16.0"
SFW_BINARY_SHA256_LINUX_X86_64="1f24d2628aeb3995f1f2651509e37641c7c41d07749ac68594ecb5bb2dd44d8a"
SFW_BINARY_SHA256_LINUX_ARM64="474cdb684e42d33d4b697dedd7d90c159d71380be0e53c496f0e7097c3617a6c"
SFW_BINARY_SHA256_MACOS_X86_64="b574931bc2b3c36a9bf07ac07b9c07894f8cd314efc91bc5e4fe1c371b56adca"
SFW_BINARY_SHA256_MACOS_ARM64="29df049df2ef705a8ce726c6c41fe73a6034f6b1cd0d87f3f15a780d074b6d83"
# Follows `intel` unless set explicitly. It used to default true on its own, so
# with the default intel: none every cargo wrapper was rendered to route through
# an sfw that was never installed: a no-op at runtime, and a GAP in verify,
# which rightly refuses to count a no-op as filtering (issue #29). Explicit true
# still means "route through an sfw I installed myself", and verify still holds
# it to that.
CARGO_SOCKET_FIREWALL="${CARGO_SOCKET_FIREWALL:-$INSTALL_SFW}"
case "$CARGO_SOCKET_FIREWALL" in
  true|false) ;;
  *)
    echo "[supply-chain-harden] error: cargo_socket_firewall must be true or false, got '$CARGO_SOCKET_FIREWALL'" >&2
    exit 2 ;;
esac

# ---- CI platform adapter ----
#
# EMIT selects how env vars, step outputs and log annotations are
# expressed. "auto" detects from the platform's own marker variables.
# Set explicitly (--emit=gitlab, or EMIT=gitlab) to override.
EMIT="${EMIT:-auto}"

# Bare-invocation flag parsing. action.yml passes everything by env, so
# this only fires when a human or a non-GitHub CI calls the script directly.
SUGGEST=0
SUGGEST_PATH="."
PREFLIGHT=0
PREFLIGHT_REPO=""
for _arg in "$@"; do
  case "$_arg" in
    --emit=*) EMIT="${_arg#--emit=}" ;;
    --suggest) SUGGEST=1 ;;
    --suggest=*) SUGGEST=1; SUGGEST_PATH="${_arg#--suggest=}" ;;
    --preflight) PREFLIGHT=1 ;;
    --preflight=*) PREFLIGHT=1; PREFLIGHT_REPO="${_arg#--preflight=}" ;;
    --help|-h)
      echo "usage: harden.sh [--emit=auto|github|gitlab|circleci|azure|buildkite|plain]"
      echo "       harden.sh --suggest[=PATH]   inspect a repo and print the inputs it needs,"
      echo "                                    the same as Ansible extra vars, and any"
      echo "                                    repo-local config that outranks the host's"
      echo "       harden.sh --preflight[=REPO] say what applying would stop on and which"
      echo "                                    package managers are here, and with REPO the"
      echo "                                    --suggest output for it; writes nothing"
      echo "       configuration is read from env: ECOSYSTEMS, RELEASE_AGE_HOURS,"
      echo "       STRICT, INSTALL_SFW, WRITE_ETC, COMPOSER_ALLOW_PLUGINS,"
      echo "       PNPM_BUILT_DEPENDENCIES, INSTALL_CARGO_COOLDOWN"
      exit 0
      ;;
    *) echo "[supply-chain-harden] warning: unrecognised argument '$_arg' — ignoring" >&2 ;;
  esac
done

# ---- helpers the read-only modes share with the run ----
#
# --suggest and --preflight run and exit before anything below is written, so
# the functions they need are defined here, ahead of them. The run uses the same
# ones: the preflight must judge a file or a version exactly as the apply will.

# >>> user_config
# ---- the per-user config files this project writes ----
#
# MEASURED (d738db8, issue 48): eight per-user files were replaced whole, on
# every run, with no copy and no message. A fake token or registry in each was
# gone after one run, and so was a token `npm login` added after hardening. Now:
#
#   ~/.npmrc is merged. This project's settings go in a marked block at the TOP
#   of the file and every other line stays, byte for byte (ucf_npmrc).
#
#   pnpm's config.yaml and rc, .yarnrc.yml, pip.conf, uv.toml, bunfig,
#   ~/.bundle/config, cargo's config.toml, Maven's settings.xml, NuGet.Config and
#   Composer's config.json are still replaced whole, but only a file that is
#   exactly what was last written is replaced without a word. The marker line
#   carries a checksum of the rest of the file (ucf_sign), so a line added later
#   shows. JSON has no comment to carry one, so Composer's is judged by its lines:
#   ours when some version of this project has written every one of them.
#   Anything else is the user's: the role refuses to touch it, and harden.sh
#   copies it next to itself (0600) and says so.
#
# Nothing here prints a line from a user's file: paths, key names from this
# project's own list, and line numbers only.

UCF_KINDS="npmrc pnpm-yaml pnpm-rc yarn pip uv bun bundler cargo maven nuget composer composer-home"

# ucf_path <kind>: where that file is for this user, as the role resolves it.
ucf_path() {
  local d="${XDG_CONFIG_HOME:-$HOME/.config}"
  case "$1" in
    pnpm-yaml|pnpm-rc)
      if [ -z "${XDG_CONFIG_HOME:-}" ] && [ "$(uname -s 2>/dev/null)" = Darwin ]; then
        d="$HOME/Library/Preferences"
      fi ;;
  esac
  case "$1" in
    npmrc)     printf '%s\n' "$HOME/.npmrc" ;;
    pnpm-yaml) printf '%s\n' "$d/pnpm/config.yaml" ;;
    pnpm-rc)   printf '%s\n' "$d/pnpm/rc" ;;
    yarn)      printf '%s\n' "$HOME/.yarnrc.yml" ;;
    pip)       printf '%s\n' "$HOME/.config/pip/pip.conf" ;;
    uv)        printf '%s\n' "$d/uv/uv.toml" ;;
    bun)       printf '%s\n' "${XDG_CONFIG_HOME:-$HOME}/.bunfig.toml" ;;
    bundler)   printf '%s\n' "$HOME/.bundle/config" ;;
    cargo)     printf '%s\n' "${CARGO_HOME:-$HOME/.cargo}/config.toml" ;;
    maven)     printf '%s\n' "$HOME/.m2/settings.xml" ;;
    nuget)     printf '%s\n' "${DOTNET_CLI_HOME:-$HOME}/.nuget/NuGet/NuGet.Config" ;;
    composer)  printf '%s\n' "$(ucf_composer_base)/config.json" ;;
    composer-home)
      d=$(ucf_composer_home)
      [ "$d" = "$(ucf_composer_base)" ] || printf '%s\n' "$d/config.json" ;;
    npm-global)
      d=$(ucf_npm) || return 0
      d=$(ucf_npm_global "$d") || return 0
      case "$d" in /etc/npmrc) ;; /*) printf '%s\n' "$d" ;; esac ;;
  esac
}

# ucf_npm: the npm tasks/npm.yml finds, in its order.
ucf_npm() {
  local p
  for p in /usr/bin/npm /usr/local/bin/npm "$HOME/.volta/bin/npm" "$HOME/.asdf/shims/npm" "$HOME/.nodenv/shims/npm" \
           "$HOME"/.nvm/versions/node/*/bin/npm "${FNM_DIR:-$HOME/.local/share/fnm}"/node-versions/*/installation/bin/npm \
           "$HOME"/.local/share/fnm/node-versions/*/installation/bin/npm "$HOME"/.fnm/node-versions/*/installation/bin/npm; do
    if [ -x "$p" ]; then printf '%s\n' "$p"; return 0; fi
  done
  PATH="/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin:$PATH" command -v npm 2>/dev/null
}

# ucf_npm_global <npm>: the file that npm reads as its global config. Asked of npm, from
# /, with the settings of this account out of the way (its npmrc, the npm_config_*
# variables in any case, and PREFIX and DESTDIR, which npm reads too): a prefix= or
# globalconfig= there names another file than the one every other account's npm reads,
# root's included. And with everything off that makes it write (MEASURED with find
# -newer: npm 6.14.18, 8.19.4, 9.9.4, 10.9.11, 11.2.0, 11.19.1 and 12.2.3 write a log, a
# compile cache or an update check without this, nothing with it). Root runs no npm that
# another account controls.
ucf_npm_global() (
  [ "$(id -u)" != 0 ] || [ -z "$(ucf_roots "$1")" ] || exit 0
  cd / || exit 1
  for v in $(env | LC_ALL=C sed -n 's/^\([Nn][Pp][Mm]_[Cc][Oo][Nn][Ff][Ii][Gg]_[A-Za-z0-9_]*\)=.*/\1/p'); do
    unset "$v"
  done
  unset PREFIX DESTDIR NODE_OPTIONS
  export npm_config_userconfig=/dev/null npm_config_logs_max=0 npm_config_cache=/dev/null/x
  export npm_config_update_notifier=false NODE_DISABLE_COMPILE_CACHE=1
  "$1" config get globalconfig 2>/dev/null | tail -1
)

# ucf_composer_base: the directory written whether or not composer is here. Not
# ~/.config/composer when only ~/.composer is there: composer takes the first of
# the two that exists wherever an XDG_ variable or /etc/xdg does, so making the
# first hid ~/.composer and the tokens in its auth.json (MEASURED, 2.11.2).
ucf_composer_base() {
  if [ ! -d "$HOME/.config/composer" ] && [ -d "$HOME/.composer" ]; then
    printf '%s\n' "$HOME/.composer"
  else
    printf '%s\n' "$HOME/.config/composer"
  fi
}

# ucf_composer_home: the directory composer reads, once ucf_composer_base is there,
# without starting composer (`composer config --global home` writes into the home:
# MEASURED, 2.0.14). Composer's own rule, compared with it over 288 combinations of
# COMPOSER_HOME, XDG_ variables, /etc/xdg and directories on 2.0.14, 2.2.6, 2.5.5,
# 2.7.1, 2.8.8 and 2.11.2.
ucf_composer_home() {
  local d
  if [ -n "${COMPOSER_HOME:-}" ]; then printf '%s\n' "$COMPOSER_HOME"; return 0; fi
  if [ -d /etc/xdg ] || [ -n "$(env | grep '^XDG_')" ]; then
    d="${XDG_CONFIG_HOME:-$HOME/.config}/composer"
    if [ -d "$d" ] || [ "$d" = "$(ucf_composer_base)" ] || [ ! -d "$HOME/.composer" ]; then
      printf '%s\n' "$d"; return 0
    fi
  fi
  printf '%s\n' "$HOME/.composer"
}

# ucf_applies <kind>: whether the role would write that file on this host.
# maven and nuget have a tool gate (tasks/maven.yml: mvn, or a JDK a ./mvnw build
# would run on; tasks/nuget.yml); every other file is written ahead of its tool.
ucf_applies() {
  case "$1" in
    maven) command -v mvn >/dev/null 2>&1 || command -v java >/dev/null 2>&1 \
             || { [ -n "${JAVA_HOME:-}" ] && [ -x "${JAVA_HOME:-}/bin/java" ]; } ;;
    nuget) command -v dotnet >/dev/null 2>&1 ;;
    composer-home) command -v composer >/dev/null 2>&1 && [ -n "$(ucf_path composer-home)" ] ;;
  esac
}

# ucf_sum [algorithm]: "<algorithm>:<checksum>" of stdin. sha256 where a tool for
# it exists, else cksum, which POSIX requires. Given an algorithm, that one or
# nothing, so a file whose checksum cannot be computed here counts as changed.
ucf_sum() {
  local a="${1:-}" s=""
  if [ "$a" != cksum ]; then
    if command -v sha256sum >/dev/null 2>&1; then s=$(sha256sum)
    elif command -v shasum >/dev/null 2>&1; then s=$(shasum -a 256)
    elif command -v openssl >/dev/null 2>&1; then s=$(openssl dgst -sha256 -r)
    fi
    s=${s%% *}
    if [ -n "$s" ]; then printf 'sha256:%s\n' "$s"; return 0; fi
    [ -z "$a" ] || return 0
  fi
  s=$(cksum) || return 0
  set -- $s
  printf 'cksum:%s-%s\n' "$1" "$2"
}

# ucf_body <n>: stdin without line <n> (the marker), as the checksum covers it.
# The cutoff line supply-chain-age-gate-refresh advances in place (uv.toml and
# pip.conf, the exact shape templates/age-gate-refresh.sh.j2 matches) counts
# without its date, so an advanced file is still the one that was written.
ucf_body() {
  local ts='[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}T[0-9:.]*Z'
  LC_ALL=C sed -e "${1}d" -e "s/^exclude-newer = \"$ts\"\$/exclude-newer = \"\"/" \
    -e "s/^uploaded-prior-to = $ts\$/uploaded-prior-to = /"
}

# ucf_marker <file>: the number of its marker line (the first or second: a
# ~/.bundle/config has to open with ---, and XML with its declaration) and the
# checksum in it, if any.
ucf_marker() {
  local l n=0 re='^(# |; |<!-- )Managed by (ansible-supply-chain-security|supply-chain-harden|supply-chain-harden action)(; self-check ([a-z0-9]+:[0-9a-f-]+))?( -->)?$'
  while [ "$n" -lt 2 ] && { IFS= read -r l || [ -n "$l" ]; }; do
    n=$((n + 1))
    if [[ "$l" =~ $re ]]; then printf '%s %s\n' "$n" "${BASH_REMATCH[4]:-}"; return 0; fi
  done < "$1"
  return 0
}

# ucf_sign: stdin, whose first or second line is a bare marker, with the
# checksum added to that line.
ucf_sign() {
  local body l n=0 at=0 sum
  body=$(cat)
  while [ "$n" -lt 2 ] && IFS= read -r l; do
    n=$((n + 1))
    case "$l" in "# Managed by "*|"; Managed by "*|"<!-- Managed by "*" -->") at=$n; break ;; esac
  done <<<"$body"
  [ "$at" -gt 0 ] || return 1
  sum=$(printf '%s\n' "$body" | ucf_body "$at" | ucf_sum)
  case "$l" in *" -->") l="${l% -->}; self-check $sum -->" ;; *) l="$l; self-check $sum" ;; esac
  n=0
  while IFS= read -r sum; do
    n=$((n + 1))
    if [ "$n" = "$at" ]; then printf '%s\n' "$l"; else printf '%s\n' "$sum"; fi
  done <<<"$body"
}

# ucf_settings <kind>: every setting line any version of this project has
# written to that file, as one extended regex. With UCF_LINES this is how a file
# from before the checksum is told from one with something added to it.
ucf_settings() {
  local b='(true|false)' pkg='"?@?[A-Za-z0-9_./-]+"?'
  case "$1" in
    pnpm-yaml) printf '%s' "(ignoreScripts|minimumReleaseAgeStrict|blockExoticSubdeps|verifyStoreIntegrity|preferFrozenLockfile): $b|minimumReleaseAge: [0-9]+|minimumReleaseAgeExclude:( \[\])?|onlyBuiltDependencies:|  - $pkg" ;;
    pnpm-rc)   printf '%s' "(minimum-release-age-strict|block-exotic-subdeps|verify-store-integrity|prefer-frozen-lockfile|ignore-scripts)=$b|minimum-release-age=[0-9]+|(minimum-release-age-exclude|only-built-dependencies)\[\]=$pkg" ;;
    yarn)      printf '%s' "npmMinimalAgeGate: \"?[0-9]+[a-z]?\"?|(enableScripts|enableTelemetry|enableImmutableInstalls|enableImmutableCache|enableHardenedMode): $b|defaultSemverRangePrefix: \"\"|checksumBehavior: [a-z]+|(unsafeHttpWhitelist|approvedGitRepositories):( \[\])?|  - \"[A-Za-z0-9*.:_-]+\"" ;;
    pip)       printf '%s' "\[(global|install)\]|disable-pip-version-check = $b|uploaded-prior-to = [0-9A-Z:.+-]+|only-binary = :all:|require-hashes = true" ;;
    uv)        printf '%s' "\[pip\]|index-strategy = \"[a-z-]+\"|allow-insecure-host = \[\]?|  \"[A-Za-z0-9*.:_-]+\",|\]|exclude-newer = \"[0-9A-Za-z:.+ -]+\"|no-build = true|(verify|require)-hashes = true" ;;
    bun)       printf '%s' "\[install(\.security)?\]|minimumReleaseAge = [0-9]+|(exact|ignoreScripts|lifecycleScripts|frozenLockfile|saveTextLockfile) = $b|auto = \"[a-z]+\"|scanner = \"[@A-Za-z0-9_./-]+\"" ;;
    npm-global) printf '%s' "(ignore-scripts|audit|save-exact|fund|update-notifier|minimum-release-age-strict|block-exotic-subdeps)=$b|(min-release-age|minimum-release-age)=[0-9]+|allow-git=none|(minimum-release-age-exclude|only-built-dependencies)\[\]=$pkg" ;;
    cargo)     printf '%s' "root = \"[A-Za-z0-9._/-]+\"" ;;
    composer*) # (a template's "{% endif %}" ate the line break after it, hence the closing braces)
      printf '%s' "\{|  \"config\": \{|    \"(secure-http|lock|scripts-are-disabled)\": true,|    \"preferred-install\": \"dist\",|    \"allow-plugins\": (true|false|\{\}),?(  \})?|    \"audit\": \{|      \"abandoned\": \"[a-z]+\",?(    \},?)?(  \})?|      \"block-insecure\": $b,|      \"block-abandoned\": $b(    \},?)?(  \})?|    \},?|    \"policy\": \{|      \"cooldown\": \{|        \"period\": [0-9]+,|        \"block\": true|      \}|  \}|\}" ;;
    bundler)   printf '%s' "---|BUNDLE_(FROZEN|DEPLOYMENT|DISABLE_EXEC_LOAD|DISABLE_CHECKSUM_VALIDATION): \"$b\"|BUNDLE_COOLDOWN: \"[0-9]+\"" ;;
  esac
}

# The comment lines every version before the checksum wrote to these files, and
# every line of the cargo, Maven and NuGet ones, as the cksum of each with its
# numbers replaced by N. Taken from the full history of the templates, of the tasks
# that held file bodies, and of harden.sh. A file written since is recognised by its
# checksum, so this list does not grow.
UCF_LINES="
16525038 21871804 32150554 43907897 45371623 47931416 55973644 69316955 75018455 92254761 99047990
105001757 105892395 128665454 164957136 175274273 178849623 180963873 200300571 205262278
227981860 231743868 239698099 244582398 249062952 253515295 264950892 264997010 265990664
267721498 287077081 317215674 322868702 332741136 365023710 378289750 387007019 391023080
400057024 404142847 406588281 413501176 423346594 442000343 456403245 457662746 480185687
492417082 495546462 498809095 525078076 533827307 534359993 538589194 541135190 544577991
554815028 566593694 574086755 587546401 590162472 594244189 600144794 605195884 609895156
620068839 623983281 625798930 633619625 645071874 659341542 662095973 665169919 667208199
671640442 676397890 676452693 678903473 685523158 690175511 698746493 706861579 740279536
752989721 754514485 761418702 763897198 767642206 780035631 787965426 806849663 807176139
811096765 811858366 819089461 819514087 822283647 837637123 844578259 850984450 851995495
853144288 857513513 864647159 868637979 871175528 871339096 878886439 882036600 887397410
887840420 889024284 913529607 914394579 929101728 946961410 952718198 956752516 957363945
962375387 967119353 971991551 973005913 978051292 990068066 1010244358 1019191397 1034315139
1045039222 1056865907 1086581569 1094282732 1097107875 1130301015 1130513908 1133061042 1143484216
1147999481 1150240927 1171045470 1181850251 1185378280 1198410501 1208393765 1218543117 1220014093
1223360892 1261714146 1263262543 1265749696 1266284216 1279840774 1286739529 1299265572 1315033360
1317891570 1321245308 1326837714 1352502691 1353146482 1370691130 1378950304 1409658597 1412089512
1415879662 1416207569 1442417585 1443997311 1458290740 1460165626 1467162857 1484159843 1487549359
1503295801 1503828058 1506383425 1528186005 1545777852 1555761671 1561625287 1568436816 1587709424
1590698284 1591424799 1596979382 1602124173 1604734001 1615633999 1617717831 1624869757 1629313848
1639599188 1663085182 1665228443 1665385156 1685634919 1688887071 1691294512 1693356012 1702901289
1717377404 1726122871 1731640410 1752775115 1770362664 1779340826 1780025923 1787715694 1795300060
1796776748 1804999554 1808856842 1824550374 1825130484 1848409489 1856235253 1862209121 1876759700
1885420368 1886008490 1890543521 1899201586 1926614231 1929107881 1933481240 1940260606 1951441247
1959004320 1974900389 1986693095 1990388406 1997119027 1998983759 2001361852 2008011601 2013828265
2020712404 2029760290 2036418807 2041416390 2059790614 2065949424 2067845263 2071261798 2073041987
2093210585 2097239662 2097937815 2107048927 2110414816 2111733905 2127375107 2151704586 2163831583
2164390978 2177254588 2189032946 2195906590 2205464476 2217588667 2222828683 2225056686 2231711062
2244097877 2244240049 2245258341 2247086009 2250113593 2257637074 2270544086 2282546424 2287750646
2294124807 2298240656 2302859127 2307443183 2308009035 2344062860 2344336215 2368994911 2375681719
2375709704 2380494202 2396691812 2405118425 2406300254 2418201151 2418603402 2423330056 2424955648
2437712885 2450664865 2460113068 2462106124 2466004924 2483611390 2490405041 2500571310 2508979248
2512201841 2520848859 2525961786 2530280945 2532656106 2582809921 2589908363 2599848016 2602417845
2608169811 2623014578 2635693143 2639177799 2641149129 2641150404 2646182193 2663064860 2664931995
2668204022 2675788109 2676103573 2678035591 2692919221 2693733235 2698339475 2699926567 2730118179
2735555215 2740590091 2748165258 2757639096 2803650760 2804934355 2806616818 2815040139 2819576305
2828038750 2829134946 2859044314 2862455256 2872993376 2875338965 2879118241 2890406335 2893314068
2906792237 2931523466 2941754597 2942384899 2942702396 2946211536 2947594206 2953723617 2962640778
2965115596 3002072409 3011098759 3030239236 3031490675 3041204051 3043122243 3059239056 3063172753
3070869805 3082536336 3084694776 3088475917 3091039106 3103206383 3109696787 3125889587 3138848547
3146333249 3167505492 3174496324 3176005236 3181547447 3183432067 3200846651 3207794189 3220286758
3225303355 3240026043 3255040544 3259375870 3267656043 3271537414 3290714861 3294750702 3304346521
3307975335 3308486726 3310122909 3318799363 3318987807 3332470975 3344313876 3359503045 3365361455
3366898389 3369899408 3371086111 3375723095 3377219643 3381418214 3405234329 3407597702 3411670937
3428684975 3446823395 3447275383 3477144607 3501233636 3501782603 3514636630 3520396622 3530521840
3530917337 3534719225 3534829072 3538692411 3540864410 3544835939 3552374706 3554673801 3559392846
3561851686 3570113122 3574820150 3592020093 3600443778 3615099103 3616788605 3628264553 3639601594
3643812220 3716039824 3733802210 3744651278 3774832778 3782170922 3784552113 3789297986 3790384087
3794482279 3803650350 3811320475 3814041862 3815688115 3820819069 3854269605 3857682206 3873997537
3874019171 3879323867 3883983730 3887455320 3892647386 3894417574 3898244350 3907023923 3918509061
3919420630 3919764144 3928389811 3939373795 3943714449 3955134236 3979503096 3980610148 3981753617
3993801748 4013068897 4022390717 4027145760 4037019286 4050652467 4059418307 4071878307 4072044868
4081681318 4093752315 4096805746 4100189372 4119373269 4121261445 4143239405 4144104894 4145960931
4147756996 4148688032 4151822944 4152993966 4154458387 4162136566 4163794268 4167262084 4173452971
4173685148 4175278786 4177171127 4180754901 4199336900 4211861283 4212708504 4217618386 4246611539
4250529193 4257410267 4263887137 4264870084 4266726453 4279237107 4280704102
"
ucf_our_line() { # <line>
  local c
  c=$(printf '%s\n' "$1" | LC_ALL=C sed 's/[0-9][0-9]*/N/g' | cksum) || return 1
  case "$UCF_LINES" in *[[:space:]]"${c%% *}"[[:space:]]*) return 0 ;; esac
  return 1
}

# ucf_old_file <kind> <file>: a file with no checksum (from before it, or
# Composer's) that holds only lines this project has written, so that nothing of
# the user's goes with it. The first seven also carried a marker, but for the
# role's ~/.bundle/config, which then has to be the whole file it wrote.
ucf_old_file() {
  local l rest re
  rest=$(LC_ALL=C tr -d '[:space:]' < "$2")
  [ -n "$rest" ] || return 0
  re=$(ucf_settings "$1")
  case "$1" in
    composer*)
      # what composer itself writes the first time it is asked anything
      case "$rest" in '{}'|'{"config":{}}') return 0 ;; esac
      rest=$(LC_ALL=C grep -vxE -e "$re" "$2") || true
      [ -z "$(printf '%s' "$rest" | LC_ALL=C tr -d '[:space:]')" ]; return ;;
    bundler)
      rest=$(sed 's/^\(BUNDLE_COOLDOWN: \)"[0-9][0-9]*"$/\1N/' "$2" | tr '\n' ' ')
      case "$rest" in
        '--- BUNDLE_FROZEN: "true" BUNDLE_DEPLOYMENT: "true" BUNDLE_DISABLE_EXEC_LOAD: "true" ') return 0 ;;
        '--- BUNDLE_FROZEN: "true" BUNDLE_COOLDOWN: N BUNDLE_DISABLE_CHECKSUM_VALIDATION: "false" ') return 0 ;;
      esac ;;
  esac
  case "$1" in cargo|maven|nuget) ;; *) [ -n "$(ucf_marker "$2")" ] || return 1 ;; esac
  rest=$(LC_ALL=C grep -vxE -e "${re:+$re|}(# |; |<!-- )Managed by (ansible-supply-chain-security|supply-chain-harden|supply-chain-harden action)( -->)?" "$2") || true
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    case "$1:$l" in cargo:*|maven:*|nuget:*|*:"#"*|*:";"*) ;; *) return 1 ;; esac
    ucf_our_line "$l" || return 1
  done <<<"$rest"
  return 0
}

# user_cfg_class <kind> <path> -> ours | stock | foreign
#
# Whether a per-user config file that is replaced whole is this project's: exactly
# what was last written, or what a version from before the checksum wrote with
# nothing added (ucf_old_file). A marker alone is not enough: a credential added
# after hardening sits in a file that carries it. stock is dotnet's own first-run
# NuGet.Config, which lists nuget.org and nothing else.
user_cfg_class() {
  local m s=""
  m=$(ucf_marker "$2")
  case "$m" in *" "?*) s=${m#* } ;; esac
  if [ -n "$s" ]; then
    if [ "$(ucf_body "${m%% *}" < "$2" | ucf_sum "${s%%:*}")" = "$s" ]; then echo ours; else echo foreign; fi
    return 0
  fi
  if ucf_old_file "$1" "$2"; then echo ours; return 0; fi
  # dotnet's first-run file, compared with the BOM, comments and whitespace
  # stripped (MEASURED, apt dotnet-sdk-8.0 8.0.134: the first `dotnet nuget list
  # source` in a fresh home writes it, opening with a UTF-8 byte-order mark and
  # with no trailing newline).
  if [ "$1" = nuget ] \
     && [ "$(tr -d '\r\n' < "$2" | LC_ALL=C sed "s/^$(printf '\357\273\277')//; s/<!--[^>]*-->//g" | tr -d ' \t')" = \
          '<?xmlversion="1.0"encoding="utf-8"?><configuration><packageSources><addkey="nuget.org"value="https://api.nuget.org/v3/index.json"protocolVersion="3"/></packageSources></configuration>' ]; then
    echo stock; return 0
  fi
  echo foreign
}

# ucf_real <path>: the file it names, every symlink followed (macOS had no
# `readlink -f` before 12.3). Fails on a loop or a directory that is not there.
ucf_real() {
  local p="$1" l d n=0
  while [ -L "$p" ]; do
    n=$((n + 1))
    [ "$n" -le 40 ] || return 1
    l=$(readlink "$p") || return 1
    case "$l" in
      /*) p="$l" ;;
      *)  p="${p%/*}/$l" ;;
    esac
  done
  d=$(cd -P -- "$(dirname -- "$p")" 2>/dev/null && pwd -P) || return 1
  printf '%s/%s\n' "${d%/}" "${p##*/}"
}

ucf_ls() { ls -ldn -- "$1" 2>/dev/null | awk '{print substr($1, 1, 10), $3, $4}'; } # <path>: mode string, uid, gid

# ---- root writes only to paths no other account controls ----
#
# ucf_roots <path> [plain]: why root must not write there; nothing when it may. Followed
# part by part from /: every part that is there is root's and writable by root alone, so
# no other account can change where the write goes, before it or while it runs. A
# symbolic link in such a directory is root's own and is followed; with "plain" there is
# none, the path is exactly where the file is.
ucf_roots() {
  local rest="${1#/}" cur="" c s n=0
  case "$1" in
    *[[:cntrl:]]*) echo "has a control character in it"; return 0 ;;
    /*) ;;
    *) echo "is not an absolute path"; return 0 ;;
  esac
  case "$1/" in *//*|*/./*|*/../*) echo "is not a plain path"; return 0 ;; esac
  while :; do
    s=$(ucf_ls "${cur:-/}")
    case "$s" in
      ??????????" 0 "*) ;;
      *) echo "is in ${cur:-/}, which is not root's"; return 0 ;;
    esac
    case "$s" in
      ?????w*|????????w*)
        # root's own file, where no other account can put another in its place
        if [ "${2:-}" = plain ] || [ -n "$rest" ] || [ ! -f "$cur" ]; then
          echo "is in ${cur:-/}, which other accounts can write to"; return 0
        fi ;;
    esac
    [ -n "$rest" ] || return 0
    c=${rest%%/*}
    case "$rest" in */*) rest=${rest#*/} ;; *) rest="" ;; esac
    case "$c" in
      ""|.) continue ;;
      ..) cur=${cur%/*}; continue ;;
    esac
    if [ -L "$cur/$c" ]; then
      n=$((n + 1))
      if [ "${2:-}" = plain ] || [ "$n" -gt 40 ]; then echo "goes through $cur/$c, a symbolic link"; return 0; fi
      s=$(readlink "$cur/$c") || { echo "goes through $cur/$c, a symbolic link that cannot be read"; return 0; }
      case "$s" in /*) cur="" rest="${s#/}${rest:+/$rest}" ;; *) rest="$s${rest:+/$rest}" ;; esac
      continue
    fi
    cur="$cur/$c"
    # Not there: root makes it, in a directory only root can write to.
    [ -e "$cur" ] || return 0
  done
}

# ucf_no_root <kind> <path>: why root does not write that file; nothing when it may.
ucf_no_root() {
  local why
  case "$1:$2" in
    npm-global:*/etc/npmrc|npm-global:/etc/npm/npmrc) why=$(ucf_roots "$2" plain) ;;
    npm-global:*) why="is not what npm names its global config" ;;
    *) why=$(ucf_roots "$2") ;;
  esac
  [ -z "$why" ] || printf '%s, and root writes only to paths no other account controls\n' "$why"
}

# ucf_kept_out <kind> <path>: the same, for this process: nothing unless it is a root that
# was reached from another account (UCF_ROOT=1, or sudo or doas, which say so).
ucf_kept_out() {
  local why
  [ "$(id -u)" = 0 ] || return 0
  if [ "${UCF_ROOT:-0}" = 1 ]; then ucf_no_root "$1" "$2"; return 0; fi
  if [ "${SUDO_UID:-0}" != 0 ] || [ "${DOAS_USER:-root}" != root ]; then
    why=$(ucf_no_root "$1" "$2")
    [ -z "$why" ] || printf '%s (run this as %s, not as root)\n' "$why" "${SUDO_USER:-${DOAS_USER:-that account}}"
  fi
}

# ucf_global_by <path>: "user" or "root", who writes npm's global config there: the user
# in a home or prefix of the user's own, root anywhere else.
ucf_global_by() {
  local d o
  if [ "$(id -u)" != 0 ]; then
    case "$1" in "$HOME"/*) echo user; return 0 ;; esac
    d=$(dirname -- "$1")
    while [ ! -d "$d" ] && [ "$d" != / ]; do d=$(dirname -- "$d"); done
    o=$(ucf_ls "$d/."); o=${o#* }
    if [ "${o%% *}" = "$(id -u)" ]; then echo user; return 0; fi
  fi
  echo root
}

# ucf_blocked <kind> <path>: why that file cannot be written as it has to be;
# nothing when it can. Judged before anything is touched.
ucf_blocked() {
  local kind="$1" path="$2" real d u t
  t=$(ucf_kept_out "$kind" "$path")
  if [ -n "$t" ]; then printf '%s\n' "$t"; return 0; fi
  if [ -L "$path" ] && ! ucf_real "$path" >/dev/null; then
    echo "is a symbolic link to a path that cannot be followed"; return 0
  fi
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    d=$(dirname -- "$path")
    while [ ! -e "$d" ] && [ "$d" != / ]; do d=$(dirname -- "$d"); done
    [ -d "$d" ] && [ -w "$d" ] || echo "cannot be created: $d is not a directory this account can write to"
    return 0
  fi
  real=$(ucf_real "$path") || { echo "cannot be resolved"; return 0; }
  if [ ! -e "$real" ]; then
    [ -w "${real%/*}/" ] || echo "points at $real, which cannot be created"
    return 0
  fi
  if [ ! -f "$real" ]; then echo "is not a regular file"; return 0; fi
  if [ ! -r "$real" ]; then echo "cannot be read by $(id -un)"; return 0; fi
  u=$(ucf_ls "$real"); u=${u#* }; u=${u%% *}
  if [ "$(id -u)" != 0 ]; then
    if [ "$u" != "$(id -u)" ]; then echo "belongs to another account ($(ls -ld -- "$real" | awk '{print $3}'))"; return 0; fi
  elif [ -L "$path" ]; then
    # Root, following a link: never through one that another account owns into a
    # file that is not that account's.
    t=$(ucf_ls "$path"); t=${t#* }; t=${t%% *}
    if [ "$t" != 0 ] && [ "$t" != "$u" ]; then echo "is a link owned by uid $t to a file owned by uid $u"; return 0; fi
  fi
  if [ ! -w "${real%/*}/" ]; then echo "cannot be replaced: ${real%/*} is not writable by $(id -un)"; return 0; fi
  if [ "$kind" = npmrc ] && [ "$(LC_ALL=C tr -d '\000' < "$real" | wc -c)" -ne "$(wc -c < "$real")" ]; then
    echo "holds NUL bytes (UTF-16?), which npm does not read either"
  fi
  return 0
}

# ucf_stuck <kind> <path>: the same, as a preflight has to judge it. A file that is
# ours does not stop anything: the write comes only if it has to change (a shared
# CARGO_HOME, where another account already wrote the same one).
ucf_stuck() {
  local why
  why=$(ucf_blocked "$1" "$2")
  [ -n "$why" ] || return 0
  if [ "$1" != npmrc ] && [ -z "$(ucf_kept_out "$1" "$2")" ] && [ -f "$2" ] && [ -r "$2" ] \
     && [ "$(user_cfg_class "$1" "$2")" = ours ]; then return 0; fi
  printf '%s\n' "$why"
}

# ucf_mode <path> <600|644|=644>: the mode string that file ends with: what it has,
# with anything that mode does not grant taken away. 600, or 644 less the umask,
# for a file that is not there yet. =644 is 644 whatever it was: a system file every
# account has to read, with nothing but ours in it.
ucf_mode() {
  local s r=- w=- g=- o=-
  if [ "$2" = =644 ]; then echo "-rw-r--r--"; return 0; fi
  if [ -e "$1" ]; then
    s=$(ucf_ls "$1")
  elif [ "$2" = 600 ]; then
    s="-rw-------"
  else
    s="-rw-"
    if [ $(( 0$(umask) & 040 )) -eq 0 ]; then s="${s}r--"; else s="${s}---"; fi
    if [ $(( 0$(umask) & 004 )) -eq 0 ]; then s="${s}r--"; else s="${s}---"; fi
  fi
  case "$s" in ?r*) r=r ;; esac
  case "$s" in ??w*) w=w ;; esac
  if [ "$2" != 600 ]; then
    case "$s" in ????r*) g=r ;; esac
    case "$s" in ???????r*) o=r ;; esac
  fi
  printf -- '-%s%s-%s--%s--\n' "$r" "$w" "$g" "$o"
}

ucf_chmod() { # <file> <mode string from ucf_mode>
  local u="" g="" o=""
  case "$2" in ?r*) u=r ;; esac
  case "$2" in ??w*) u="${u}w" ;; esac
  case "$2" in ????r*) g=r ;; esac
  case "$2" in ???????r*) o=r ;; esac
  chmod "u=$u,g=$g,o=$o" "$1"
}

# ucf_temp <file>: a new 0600 file in the same directory (mktemp: never one that
# is there already, and never through a link); prints its name.
ucf_temp() { ( umask 077; mktemp "$(dirname -- "$1")/.sch-XXXXXX" 2>/dev/null ); }

# ucf_put <path> <600|644|=644> <content>: write it, atomically: a temporary file in the
# same directory, renamed over, so a run killed at any point leaves the old file or
# the new one. Through a symlink to the file it names, the owner kept, and the mode
# as ucf_mode says. Where the rename is impossible (a file bind-mounted into a
# container) it is written in place, with a copy of the old one kept until the new
# one is complete. A subshell, for its trap.
ucf_put() (
  path="$1" content="$3" tmp="" bak="" own=""
  trap '[ -z "$tmp" ] || rm -f -- "$tmp"' EXIT
  trap 'exit 1' HUP INT TERM
  # A directory that is there keeps its mode, whatever it is.
  [ -d "$(dirname -- "$path")" ] || mkdir -p -- "$(dirname -- "$path")" 2>/dev/null || exit 1
  real=$(ucf_real "$path") || exit 1
  mode=$(ucf_mode "$real" "$2")
  if [ -e "$real" ]; then own=$(ucf_ls "$real"); own=${own#* }; fi
  tmp=$(ucf_temp "$real") || { tmp=""; exit 1; }
  printf '%s' "$content" > "$tmp" 2>/dev/null || exit 1
  if [ -n "$own" ] && [ "$(id -u)" = 0 ]; then
    chown -h "${own% *}:${own#* }" "$tmp" 2>/dev/null || exit 1
  elif [ -n "$own" ]; then
    # A group this account is not in cannot be kept, and no other group gets what
    # it had.
    chgrp "${own#* }" "$tmp" 2>/dev/null || mode="${mode:0:4}---${mode:7}"
  fi
  ucf_chmod "$tmp" "$mode" || exit 1
  if mv -f -- "$tmp" "$real" 2>/dev/null; then tmp=""; exit 0; fi
  [ -f "$real" ] && [ -w "$real" ] || exit 1
  bak=$(ucf_copy_new "$real") || exit 1
  if cat -- "$tmp" > "$real" && cmp -s "$tmp" "$real" && ucf_chmod "$real" "$mode"; then rm -f -- "$bak"; exit 0; fi
  printf 'error: %s may be incomplete; as it was, it is at %s\n' "$path" "$bak"
  exit 1
)

# ucf_copy_new <path>: a 0600 copy next to it, named as ansible's backup names one
# (<file>.<pid>.<YYYY-MM-DD@HH:MM:SS>~); prints the name. Complete before it has
# that name, and never over anything already there.
ucf_copy_new() {
  local p="$1" b tmp own n=1
  tmp=$(ucf_temp "$p") || return 1
  if ! cat -- "$p" > "$tmp" 2>/dev/null || ! cmp -s "$p" "$tmp"; then rm -f -- "$tmp"; return 1; fi
  if [ "$(id -u)" = 0 ]; then
    own=$(ls -ldnL -- "$p" | awk '{print $3 ":" $4}'); chown -h "$own" "$tmp" 2>/dev/null || true
  fi
  b="$p.$$.$(date +%Y-%m-%d@%H:%M:%S)"
  while [ -e "$b~" ] || [ -L "$b~" ]; do
    n=$((n + 1))
    [ "$n" -le 20 ] || { rm -f -- "$tmp"; return 1; }
    b="$p.$$.$(date +%Y-%m-%d@%H:%M:%S)-$n"
  done
  mv -f -- "$tmp" "$b~" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
  [ -f "$b~" ] && [ ! -L "$b~" ] && cmp -s "$p" "$b~" || return 1
  printf '%s\n' "$b~"
}

# ucf_copy <path>: the same, but a copy with the same bytes that is there already
# is reused: on a runner whose jobs put the same token back every time, that keeps
# one copy of it and not one per job.
ucf_copy() {
  local b
  for b in "$1".[0-9]*.[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]@*"~"; do
    if [ -f "$b" ] && [ ! -L "$b" ] && cmp -s "$1" "$b" && chmod 600 "$b" 2>/dev/null; then
      printf '%s\n' "$b"; return 0
    fi
  done
  ucf_copy_new "$1"
}

# ucf_replace <kind> <path>: replace one of them with the body on stdin. Prints
# "ok" or "changed", "copy <file>" ("-" in a dry run) when the user's version is
# kept, "stock <file>" when dotnet's own is, and "error: <why>" with status 1.
# UCF_DRY=1 reports and writes nothing. With UCF_FOREIGN=refuse a file with the
# user's settings is left alone: "refused <path>", status 42.
ucf_replace() {
  local kind="$1" path="$2" want why bak cls=absent m=644
  # Before anything of it is read.
  why=$(ucf_kept_out "$kind" "$path")
  if [ -n "$why" ]; then printf 'error: %s %s; it was left as it is\n' "$path" "$why"; return 1; fi
  if [ "$kind" = npm-global ] && [ "$(id -u)" = 0 ]; then m="=644"; fi
  case "$kind" in
    composer*) want=$(cat) ;;
    *) want=$(ucf_sign) || { echo "error: no marker line in the new $kind file"; return 1; } ;;
  esac
  if [ -f "$path" ] && [ -r "$path" ]; then
    cls=$(user_cfg_class "$kind" "$path")
    if [ "$cls" = ours ] && printf '%s\n' "$want" | cmp -s - "$path" \
       && [ "$(ucf_ls "$(ucf_real "$path")" | cut -c1-10)" = "$(ucf_mode "$(ucf_real "$path")" "$m")" ]; then
      echo ok; return 0
    fi
  fi
  why=$(ucf_blocked "$kind" "$path")
  if [ -n "$why" ]; then printf 'error: %s %s; it was left as it is\n' "$path" "$why"; return 1; fi
  if [ "$cls" = foreign ] && [ "${UCF_FOREIGN:-keep}" = refuse ]; then
    printf 'refused %s\n' "$path"; return 42
  fi
  if [ "$cls" = foreign ] || [ "$cls" = stock ]; then
    bak=-
    if [ "${UCF_DRY:-0}" != 1 ]; then
      bak=$(ucf_copy "$path") || { printf 'error: could not copy %s next to itself before replacing it; it was left as it is\n' "$path"; return 1; }
    fi
    if [ "$cls" = stock ]; then printf 'stock %s\n' "$bak"; else printf 'copy %s\n' "$bak"; fi
  fi
  if [ "${UCF_DRY:-0}" != 1 ]; then
    ucf_put "$path" "$m" "$want"$'\n' || { printf 'error: could not write %s\n' "$path"; return 1; }
  fi
  echo changed
}

# ---- ~/.npmrc ----
#
# npm's ini reader (MEASURED with `npm config get` on 6.14.18, 8.19.4, 10.8.2,
# 10.9.9, 11.2.0, 11.19.1 and 12.2.3): the last of two lines for a key wins, keys
# after a [section] nest under it, a key may be quoted, followed by a comment, or
# spelled key[], a carriage return alone ends a line, Unicode spaces around a key
# are trimmed, and ${VAR} in a key is expanded. `npm login` and `npm config set`
# rewrite the file without its comments, this project's block markers included,
# and chmod it 0600.

# ucf_trim <text>: JavaScript's trim(), in REPLY. For LC_ALL=C.
ucf_trim() {
  local s="$1" p zs=$'\342\200[\200\201\202\203\204\205\206\207\210\211\212\250\251\257]'
  while p=$s; do
    case "$s" in
      [[:space:]]*) s=${s#?} ;;
      $'\302\240'*) s=${s#??} ;;
      $'\357\273\277'*|$'\341\232\200'*|$'\342\201\237'*|$'\343\200\200'*|$zs*) s=${s#???} ;;
    esac
    case "$s" in
      *[[:space:]]) s=${s%?} ;;
      *$'\302\240') s=${s%??} ;;
      *$'\357\273\277'|*$'\341\232\200'|*$'\342\201\237'|*$'\343\200\200'|*$zs) s=${s%???} ;;
    esac
    [ "$p" != "$s" ] || break
  done
  REPLY=$s
}

# ucf_unsafe <text>: npm's ini unsafe() (quotes, comments), in REPLY. Fails on a
# quoted text with an escape in it, which only a JSON parser can read.
ucf_unsafe() {
  local s t
  ucf_trim "$1"; s=$REPLY
  case "$s" in
    \'*\')
      s=${s#\'}; s=${s%\'}
      ucf_trim "$s"
      case "$REPLY" in \"*\") s=$REPLY ;; *) REPLY=$s; return 0 ;; esac ;;
  esac
  case "$s" in
    \"*\")
      t=${s#\"}; t=${t%\"}
      case "$t" in *\\*) return 1 ;; *\"*) REPLY=$s ;; *) REPLY=$t ;; esac
      return 0 ;;
  esac
  # Up to the first ; or #. One with a \ before it does not end the text for npm;
  # what is cut there keeps the \, and no key or value of ours has one.
  ucf_trim "${s%%[;#]*}"
  return 0
}

# ucf_npmrc_scan <content> <new block body> <block intact: 0|1> <old whole file: role|action|"">
# Goes through the file as npm would read it. Prints "removed <key>", "stricter
# <key>" and "unsure <what>" lines, a record separator, and the lines that stay,
# byte for byte, with an x after them so a command substitution keeps the last
# newline.
ucf_npmrc_scan() (
  LC_ALL=C
  nl=$'\n' cr=$'\r' open='${' close='}'
  intact=$3 old=$4 keep="" notes="" seen=" " n=0 section="" skip=0 loose=0
  keys=" " vals=$nl body="$nl$2$nl"
  while IFS= read -r l; do
    case "$l" in ""|";"*|"#"*) ;; *=*) keys="$keys${l%%=*} "; vals="$vals$l$nl" ;; esac
  done <<<"$2"
  ours() { case "$1" in ""|*[[:space:]]*) return 1 ;; esac; case "$keys" in *" $1 "*) return 0 ;; esac; return 1; }
  note() { case "$nl$notes" in *"$nl$1$nl"*) ;; *) notes="$notes$1$nl" ;; esac; }
  # drop <text of one line>: true when it does not stay, because it is this
  # project's or because it is the user's and sets one of our settings
  drop() {
    local seg="$1" k v s g d t arr=0
    case "$seg" in
      "; >>> supply-chain-hardening: "*) if [ "$intact" = 1 ]; then skip=1; else loose=1; fi; return 0 ;;
      "; <<< supply-chain-hardening") skip=0; return 0 ;;
    esac
    [ "$skip" = 0 ] || return 0
    ucf_trim "$seg"
    case "$REPLY" in
      "") return 1 ;;
      ";"*|"#"*)
        [ -n "$old" ] || [ "$loose" = 1 ] || return 1
        case "$seg" in "; Managed by ansible-supply-chain-security"|"; Managed by supply-chain-harden action") return 0 ;; esac
        case "$body" in *"$nl$seg$nl"*) return 0 ;; esac
        ucf_our_line "$seg"; return ;;
    esac
    # A [section]. With a space after the ] it is one for npm 10 and later and a
    # key for npm 8 and earlier (measured), so keys after it may be top-level.
    s=$seg
    while :; do case "$s" in *[[:space:]]) s=${s%?} ;; *) break ;; esac; done
    case "$s" in
      "["*"]")
        g=${s#"["}; g=${g%"]"}
        case "$g" in
          *"]"*) ;;
          *)
            if [ "$s" = "$seg" ]; then section=in; elif [ "$section" != in ]; then section=maybe; fi
            if ucf_unsafe "$g" && ours "${REPLY%%.*}"; then note "unsure line $n, a [section] named after ${REPLY%%.*}"; fi
            return 1 ;;
        esac ;;
    esac
    [ "$section" != in ] || return 1
    case "$seg" in
      "="*) return 1 ;;
      *=*) k=${seg%%=*}; v=${seg#*=} ;;
      *) k=$seg; v=true ;;
    esac
    if ! ucf_unsafe "$k"; then
      note "unsure line $n, a quoted key with an escape in it"; return 1
    fi
    k=$REPLY
    case "$k" in ?*"[]") arr=1; k=${k%"[]"} ;; esac
    case "$k" in
      *"$open"*"$close"*)
        # a glob of what the expanded key can be, and the key as it is shown
        g="" d="" t=$k
        while :; do
          case "$t" in *"$open"*"$close"*) ;; *) break ;; esac
          s=${t%%"$open"*}; t=${t#*"$open"}
          g="$g$s*" d="$d$s"
          t=${t#*"$close"}
          d="$d$open...$close"
        done
        g="$g$t" d="$d$t"
        case "$g" in *[!a-z*-]*) return 1 ;; esac
        for s in $keys; do
          # shellcheck disable=SC2254  # $g is a glob, and is meant to match as one
          case "$s" in $g) note "unsure line $n, the key $d"; return 1 ;; esac
        done
        return 1 ;;
    esac
    if [ "$k" = before ] && ours min-release-age; then
      note "unsure line $n, before, which npm uses instead of min-release-age"; return 1
    fi
    ours "$k" || return 1
    if ucf_unsafe "$v"; then v=$REPLY; fi
    if [ "$arr" = 0 ]; then
      # the same setting the block has: nothing of the user's is lost
      case "$vals" in *"$nl$k=$v$nl"*) seen="$seen$k "; return 0 ;; esac
      # a file an older version wrote whole: its own line for each key
      if [ -n "$old" ]; then
        case "$seen" in
          *" $k "*) ;;
          *)
            seen="$seen$k "
            case "$old:$k=$v" in
              *:min-release-age=|*:min-release-age=*[!0-9]*) ;;
              *:min-release-age=*|*:allow-git=none) return 0 ;;
              *:allow-git=*) ;;
              role:*=true|role:*=false) return 0 ;;
              action:ignore-scripts=true|action:audit=true|action:save-exact=true) return 0 ;;
              action:fund=false|action:update-notifier=false) return 0 ;;
            esac ;;
        esac
      fi
    fi
    # a longer window of the user's own: it wins over the block's, and may
    if [ "$arr:$k" = 0:min-release-age ]; then
      t=${vals#*"${nl}min-release-age="}; t=${t%%"$nl"*}
      case "$v:$t" in
        0*|*[!0-9:]*|:*|*:|?????????*:*) ;;
        *) if [ "$v" -gt "$t" ]; then note "stricter min-release-age"; return 1; fi ;;
      esac
    fi
    note "removed $k"
    return 0
  }
  rest=$1
  while [ -n "$rest" ]; do
    n=$((n + 1))
    case "$rest" in
      *"$nl"*) line=${rest%%"$nl"*}; end=$nl; rest=${rest#*"$nl"} ;;
      *) line=$rest; end=""; rest="" ;;
    esac
    # npm ends a line at a carriage return too, so each part is one
    while :; do
      case "$line" in
        *"$cr"*)
          seg=${line%%"$cr"*}; line=${line#*"$cr"}
          if [ -z "$line" ]; then
            if drop "$seg"; then :; else keep="$keep$seg$cr$end"; fi
            break
          fi
          if drop "$seg"; then :; else keep="$keep$seg$cr"; fi ;;
        *)
          if drop "$line"; then :; else keep="$keep$line$end"; fi
          break ;;
      esac
    done
  done
  # Never drop to the end of the file: a block that did not end was not intact.
  [ "$skip" = 0 ] || exit 1
  printf '%s\036%sx' "$notes" "$keep"
)

# ucf_npmrc <path>: merge the settings on stdin (a marker line, comments and
# key=value lines) into that npmrc. Prints
#   removed <key>   a line of the user's for one of our settings was taken out:
#                   the last line for a key wins, so it would beat the block
#   stricter <key>  a line that stays: a longer window than ours, which it beats
#   unsure <what>   a line that stays, and that may set or defeat one of ours
#   copy <file>     where the file as it was is kept; only when one was removed
#                   ("-" in a dry run)
#   mode <string>   other accounts could read it, and no longer can
#   ok | changed, or "error: <why>" and status 1.
# UCF_DRY=1 reports and writes nothing.
ucf_npmrc() {
  local path="$1" want who sum new real="" cur="" bom="" out notes keep intact=0 old="" why bak m="" blk
  local nl=$'\n' cr=$'\r' rs=$'\036' utf8=$'\357\273\277'
  want=$(cat)
  who=$(printf '%s\n' "$want" | sed -n '1s/^; Managed by //p')
  [ -n "$who" ] || { echo "error: no marker line in the new npmrc settings"; return 1; }
  want="; These lines are rewritten on every run. Your own settings go below them.$nl${want#*"$nl"}"
  why=$(ucf_blocked npmrc "$path")
  if [ -n "$why" ]; then printf 'error: %s %s; it was left as it is\n' "$path" "$why"; return 1; fi
  if [ -e "$path" ]; then
    real=$(ucf_real "$path")
    cur=$(cat -- "$real"; printf x); cur=${cur%x}
    case "$cur" in "$utf8"*) bom=$utf8; cur=${cur#"$utf8"} ;; esac
    m=$(printf '%s' "$cur" | LC_ALL=C sed -n 's/^; >>> supply-chain-hardening: Managed by [a-z -]*; self-check \([a-z0-9]*:[0-9a-f-]*\)$/\1/p' | sed -n 1p)
    if [ -n "$m" ]; then
      # From the first begin marker to its end marker, which has to be there:
      # without it the range runs to the end of the file, over the user's lines.
      blk=$(printf '%s' "$cur" | LC_ALL=C sed -n '/^; >>> supply-chain-hardening: /,/^; <<< supply-chain-hardening$/p')
      case "$blk" in
        *"$nl; <<< supply-chain-hardening")
          if [ "$(printf '%s\n' "$blk" | LC_ALL=C sed -e 1d -e '$d' | ucf_sum "${m%%:*}")" = "$m" ]; then intact=1; fi ;;
      esac
    fi
    case "$nl${cur//$cr/}$nl" in
      *"$nl; >>> supply-chain-hardening: "*) ;;
      *"$nl; Managed by ansible-supply-chain-security$nl"*) old=role ;;
      *"$nl; Managed by supply-chain-harden action$nl"*) old=action ;;
    esac
  fi
  out=$(ucf_npmrc_scan "$cur" "$want" "$intact" "$old") || { printf 'error: could not read %s\n' "$path"; return 1; }
  case "$out" in *"$rs"*x) ;; *) printf 'error: could not read %s\n' "$path"; return 1 ;; esac
  notes=${out%%"$rs"*}; keep=${out#*"$rs"}; keep=${keep%x}
  sum=$(printf '%s\n' "$want" | ucf_sum)
  new="$bom; >>> supply-chain-hardening: Managed by $who; self-check $sum$nl$want$nl; <<< supply-chain-hardening$nl$keep"
  printf '%s' "$notes"
  if [ -n "$real" ]; then
    m=$(ucf_ls "$real"); m=${m%% *}
    case "$m" in ????r*|???????r*) printf 'mode %s\n' "$m" ;; esac
    if [ "$new" = "$bom$cur" ] && [ "$m" = "$(ucf_mode "$real" 600)" ]; then echo ok; return 0; fi
  fi
  case "$nl$notes" in
    *"$nl"removed\ *)
      bak=-
      if [ "${UCF_DRY:-0}" != 1 ]; then
        bak=$(ucf_copy "$path") || { printf 'error: could not copy %s next to itself before taking lines out of it; it was left as it is\n' "$path"; return 1; }
      fi
      printf 'copy %s\n' "$bak" ;;
  esac
  if [ "${UCF_DRY:-0}" != 1 ]; then
    ucf_put "$path" 600 "$new" || { printf 'error: could not write %s\n' "$path"; return 1; }
  fi
  echo changed
}
# <<< user_config

# npm_settings <days>: what goes in the npmrc files, after the marker line.
npm_settings() {
  echo "; Managed by supply-chain-harden action
ignore-scripts=true
audit=true
save-exact=true
fund=false
update-notifier=false
min-release-age=$1
allow-git=none"
}

# detect_version <key> <command>: returns the version string the command
# prints (typically major.minor.patch), or empty if the binary isn't
# installed OR if the version command fails for any reason. Used for
# version-tiering decisions per ecosystem.
#
# Defensive against tools that exit non-zero on --version (some wrappers,
# uv-redirected pip, broken installs) because `set -e` would otherwise
# halt the script on a benign "we couldn't detect the version" path.
detect_version() {
  local _key="$1"  # unused; documentation hook for the caller's intent
  local cmd="$2"
  if ! command -v "${cmd%% *}" >/dev/null 2>&1; then
    echo ""
    return 0
  fi
  local out
  # From /, never the working directory. The action runs this step in the job's
  # checkout, and tools read files there and in every directory above it that
  # name code they then run, for --version too. MEASURED: a .yarnrc.yml yarnPath
  # (yarn 1.22.22, 4.1.0-4.19.0), .mvn/jvm.config (maven 3.10.0), a global.json
  # sdk "paths" entry (.NET 10.0.404) and Poetry 2.5.2's .poetry/plugins all ran
  # for --version. This reports the host's tool, which is what gets configured.
  out=$(cd / && $cmd 2>&1 || true)
  echo "$out" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || true
}

# version_ge <a> <b>: returns 0 if a >= b semver-style, 1 otherwise.
# Treats missing patch as .0. Used for version-tiering checks.
version_ge() {
  local a="$1" b="$2"
  # read -ra rather than unquoted expansion under IFS=. — the latter is also
  # subject to globbing, so a version string containing * or ? would expand
  # against the cwd instead of splitting.
  local -a a_parts b_parts
  IFS=. read -ra a_parts <<< "$a"
  IFS=. read -ra b_parts <<< "$b"
  # Normalize to 3 components
  while [[ ${#a_parts[@]} -lt 3 ]]; do a_parts+=("0"); done
  while [[ ${#b_parts[@]} -lt 3 ]]; do b_parts+=("0"); done
  for i in 0 1 2; do
    local av=${a_parts[$i]:-0} bv=${b_parts[$i]:-0}
    if (( av > bv )); then return 0; fi
    if (( av < bv )); then return 1; fi
  done
  return 0  # equal counts as ge
}

# ---- --suggest: tell a repo what it needs BEFORE the first failed build ----
#
# WHY THIS EXISTS.
#
# The defaults are strict, and for a repo that installs from lockfiles and has
# no native dependencies they are also invisible. For every other repo the
# first encounter with this action is a broken build whose error message does
# not mention this action: `ignore-scripts` turns a missing native binding into
# a node-gyp failure, `--no-scripts` turns a composer plugin into a missing
# autoload entry. That fails the attribution test in docs/design-principles.md
# ("when this control breaks something legitimate, does the error name the
# control?"), and the observed consequence of failing it is not a support
# ticket — it is the two lines being deleted from the workflow.
#
# This mode reads the manifests and prints the `with:` block the repo needs (and
# the same exceptions as extra vars for the Ansible role), so the exceptions
# are chosen at adoption time from evidence rather than reverse-engineered from
# a stack trace. It also lists repo-local config that outranks the host's.
#
# It reports; it changes nothing. Run it locally, or as a one-off job.
#
# EVIDENCE, NOT GUESSWORK, WHERE THE LOCKFILE HAS IT. npm records
# `hasInstallScript: true` and pnpm records `requiresBuild: true` per package —
# those are the package manager's own answer to "does this run code on
# install", so where a lockfile is present the list is exact. yarn.lock and
# bun's binary lockfile carry no such marker, so those fall back to a
# known-names scan, which is a floor and is labelled as one.
_sg_note() { printf '  - %s\n' "$*"; }

suggest_scripted_deps() {
  # Emits one package name per line. Deduped and sorted by the caller.
  local dir="$1"
  if [ -f "$dir/package-lock.json" ]; then
    if command -v jq >/dev/null 2>&1; then
      jq -r '(.packages // {}) | to_entries[]
             | select(.value.hasInstallScript == true)
             | .key | sub("^.*node_modules/"; "")' \
         "$dir/package-lock.json" 2>/dev/null || true
    else
      # npm writes one "node_modules/<name>": { per line, so the nearest
      # preceding key line is the owning package. Approximate by construction:
      # it depends on npm's formatting, which jq does not.
      awk -F'"' '/^ *"node_modules\// { split($2, p, "node_modules/"); key=p[length(p)] }
                 /"hasInstallScript": *true/ { if (key != "") print key }' \
         "$dir/package-lock.json" 2>/dev/null || true
    fi
  fi
  if [ -f "$dir/pnpm-lock.yaml" ]; then
    # Quotes come off BEFORE the version suffix: pnpm quotes scoped keys
    # ('@swc/core@1.4.0':), and a trailing quote makes the @version strip land
    # one character short, yielding '@swc/core with the quote still attached.
    awk '/^packages:/ { inp=1; next }
         /^[^ ]/ { inp=0 }
         inp && /^  [^ ]/ { key=$1; sub(/:$/, "", key)
                            gsub(/\047|"/, "", key)
                            # strip the @version suffix, keeping @scope/name
                            sub(/@[^@\/]*$/, "", key) }
         inp && /requiresBuild: *true/ { if (key != "") print key }' \
       "$dir/pnpm-lock.yaml" 2>/dev/null || true
  fi
  # Fallback for lockfiles with no marker (yarn, bun) or no lockfile at all.
  if [ ! -f "$dir/package-lock.json" ] && [ ! -f "$dir/pnpm-lock.yaml" ] \
     && [ -f "$dir/package.json" ]; then
    local known p
    known="esbuild sharp node-sass sass-embedded puppeteer puppeteer-core
           playwright canvas bcrypt better-sqlite3 sqlite3 cypress electron
           @swc/core re2 @parcel/watcher lightningcss node-pty keytar
           sodium-native argon2 usb serialport deasync msgpackr-extract"
    for p in $known; do
      grep -q "\"$p\"[[:space:]]*:" "$dir/package.json" 2>/dev/null && echo "$p"
    done
  fi
  # A `for` loop's status is its last iteration's, so a final non-matching
  # grep returns 1 — and under `set -o pipefail` that failed the enclosing
  # command substitution and `set -e` killed the whole run. MEASURED: a repo
  # with no scripted dependencies (the common case, and the one this mode most
  # needs to answer) printed the header and exited 1 with no output.
  return 0
}

# ---- repo-local config that outranks the host's, read as files ----
#
# A file in the project directory outranks the ~ and /etc files the role and
# this script write, so a repository can lift a protection without touching
# any of them. The role cannot close that, and supply-chain-verify reports it
# only when it is run from inside the project, after the fact. So --suggest
# names it before anything is applied. Every finding says what outranks the
# repo's value, if anything does; the measurements are in docs/limitations.md,
# "Repo-local configuration can outrank the role's user + system config".
#
# FILES ONLY (docs/design-principles.md, "The verifier test"). Nothing in the
# repo runs, no package manager is started in it, and only the keys named below
# are printed: a project .npmrc or .bundle/config can hold a token.
#
# These readers are deliberately simple: a line or a table at a time, with the
# value printed as it is written. The tools follow every spelling their format
# allows, and a repository that wants a gate off will not choose the plain one.
# MEASURED, each honoured from the project directory: a quoted key, an escaped
# one, `ignore-${NOPE?}scripts=false` and a lone CR as the line break (npm
# 11.19.1); a flow mapping, an escaped, tagged, aliased or `? complex` key, an
# indented top level, `--- {key: v}` and a lone CR (pnpm 11.29.0, Yarn 4.18.1,
# not every form on both); Yarn's own yarn 1 format under a `# yarn lockfile v1`
# line; an inline table, a dotted key and an escaped key or table (uv 0.13.9); an
# inline table (Bun 1.4.5); a quoted or escaped yarn-path (Yarn 1.22.22); a
# byte-order mark (npm, pnpm, Yarn, uv). So a key that a
# file mentions more often than a reader accounted for is reported as not read
# (_sg_net), never as absent.
#
# NO SYMLINK IS FOLLOWED, and what a file says is printed, so this must not be a
# way to print some other file: MEASURED, a cooldown.toml pointing at a
# credentials file put its contents in the output, which an agent shows to
# people and a CI job logs. The link itself is reported.
#
# Octal, not a character class: BusyBox tr has none, and keeps only the class's
# own letters (MEASURED, BusyBox 1.37.0). At most 20 lines from one reader; the
# rest of a longer list is then reported as not read. awk reads to the end, so
# nothing upstream is cut off by a closed pipe.
_sg_clean() { LC_ALL=C tr -cd '\12\40-\176' | cut -c1-160 | awk 'NR <= 20'; }

# _sg_text <file>: the text as the tools split it into lines. A lone CR is a line
# break to npm, pnpm and Yarn, a byte-order mark is skipped, and NULs go so that
# grep treats the rest as text.
_sg_text() {
  LC_ALL=C tr '\r' '\n' < "$1" 2>/dev/null | LC_ALL=C tr -d '\000' \
    | LC_ALL=C sed "1s/^$(printf '\357\273\277')//"
}

# _sg_have <repo> <path in it>: 0 when there is a file here to read. A symlink,
# or a directory on the way that is one, is reported and not followed.
_sg_have() {
  local p="$1/$2" link=""
  case "$2" in */*) [ -L "$1/${2%%/*}" ] && link="$1/${2%%/*}" ;; esac
  [ -L "$p" ] && link=$p
  if [ -n "$link" ]; then
    _sg_override "$2" "a symlink to $(readlink "$link" 2>/dev/null | _sg_clean | head -1)" "the tool follows it and this reader does not, because it can point at any file on this machine. Look at what it points to."
    return 1
  fi
  [ -f "$p" ] || return 1
  if [ ! -r "$p" ]; then
    _sg_override "$2" "not readable" "its settings were not read."
    return 1
  fi
  return 0
}

# _sg_net <label> <file> <ini|toml|yaml|yarn1> <key>...: what the readers missed.
# A key on more non-comment lines than the caller's `hits` account for, or a key
# spelled so that a text search cannot see it (an escape, npm's ${VAR} in a key,
# YAML's `? key`), is reported for a person to look at.
_sg_net() {
  local label="$1" f="$2" kind="$3" k re n h why="" odd="" cm='^[[:space:]]*#'
  shift 3
  if [ "$kind" = ini ]; then cm='^[[:space:]]*[#;]'; fi
  for k in "$@"; do
    re="(^|[^A-Za-z0-9_-])${k}([^A-Za-z0-9_-]|\$)"
    n=$(_sg_text "$f" | { LC_ALL=C grep -vE "$cm" || :; } | { LC_ALL=C grep -cE -- "$re" || :; })
    h=$(printf '%s\n' ${hits[@]+"${hits[@]}"} | { LC_ALL=C grep -cE -- "$re" || :; })
    if [ "${n:-0}" -gt "${h:-0}" ]; then why="${why:+$why, }$k"; fi
  done
  if [ -n "$why" ]; then
    _sg_override "$label" "$why" "mentioned in a form this reader does not follow, so a value was not read. The tool may honour it: open the file."
  fi
  case "$kind" in
    ini)   re='^[^=]*(\\|[$][{])' ;;
    toml)  re='(^|[{,.])[[:space:]]*"[^"]*\\[^"]*"[[:space:]]*[=.]|^[[:space:]]*\[[^"=]*"[^"]*\\[^"]*"[^"=]*\]+[[:space:]]*(#.*)?$' ;;
    yarn1) re='^[[:space:]]*"[^"]*\\' ;;
    *)     re='"[^"]*\\[^"]*"[[:space:]]*:|^[[:space:]]*[?]([[:space:]]|$)|^[*]' ;;
  esac
  odd=$(_sg_text "$f" | { LC_ALL=C grep -vE "$cm" || :; } | { LC_ALL=C grep -cE -- "$re" || :; })
  if [ "${odd:-0}" -gt 0 ]; then
    _sg_override "$label" "a key written with an escape or a variable" "it can spell any setting, and this reader does not decode it. The tool does: open the file."
  fi
}

# _sg_ini <file> <key>... -> "key=value" per line (.npmrc; `key[]` counts as key)
_sg_ini() {
  local f="$1"; shift
  awk -v keys="$*" '
    BEGIN { n = split(keys, k, " "); for (i = 1; i <= n; i++) want[k[i]] = 1 }
    /^[ \t]*[;#]/ { next }
    # A key with no "=" is true.
    { i = index($0, "="); if (!i) { key = $0; val = "true" } else { key = substr($0, 1, i - 1); val = substr($0, i + 1) }
      gsub(/^[ \t]+|[ \t]+$/, "", key); gsub(/^[ \t]+|[ \t]+$/, "", val)
      if (key ~ /^".*"$/ || key ~ /^\047.*\047$/) key = substr(key, 2, length(key) - 2)
      base = key; sub(/\[\]$/, "", base)
      if (base in want) print key "=" val }' 2>/dev/null < <(_sg_text "$f") | _sg_clean
}

# _sg_toml <file> <dotted.path>... -> "path = value" per line; a table of that
# name is "path (a table)". Dotted keys and dotted table headers both work.
_sg_toml() {
  local f="$1"; shift
  awk -v paths="$*" '
    BEGIN { n = split(paths, p, " "); for (i = 1; i <= n; i++) want[p[i]] = 1 }
    /^[ \t]*#/ { next }
    /^[ \t]*\[[^]]*\]+[ \t]*(#.*)?$/ {
      sec = $0; sub(/^[ \t]*\[+[ \t]*/, "", sec); sub(/[ \t]*\].*$/, "", sec)
      gsub(/["\047 \t]/, "", sec)
      if (sec in want) print sec " (a table)"
      next
    }
    { line = $0; sub(/^[ \t]+/, "", line)
      if (match(line, /^("[^"]*"|\047[^\047]*\047|[A-Za-z0-9_-]+)([ \t]*[.][ \t]*("[^"]*"|[A-Za-z0-9_-]+))*[ \t]*=/)) {
        key = substr(line, 1, RLENGTH - 1); val = substr(line, RLENGTH + 1)
        gsub(/["\047 \t]/, "", key); gsub(/^[ \t]+|[ \t]+$/, "", val)
        full = (sec == "" ? key : sec "." key)
        if (full in want) print full " = " val
      } }' 2>/dev/null < <(_sg_text "$f") | _sg_clean
}

# _sg_yaml <file> <top-level key>... -> "key: value" per line; a list below the
# key is folded to "key: [a, b]".
_sg_yaml() {
  local f="$1"; shift
  awk -v keys="$*" '
    function flush() {
      if (cur == "") return
      if (items != "") v = "[" items "]"
      if (v == "") v = "(a value on the lines below that this reader does not follow)"
      print cur ": " v; cur = ""
    }
    BEGIN { n = split(keys, k, " "); for (i = 1; i <= n; i++) want[k[i]] = 1; cur = "" }
    /^[ \t]*#/ { next }
    /^[^ \t#-]/ {
      flush()
      if (match($0, /^["\047]?[A-Za-z0-9_-]+["\047]?[ \t]*:/)) {
        key = substr($0, 1, RLENGTH - 1); v = substr($0, RLENGTH + 1)
        gsub(/["\047 \t]/, "", key); sub(/^[ \t]+/, "", v)
        if (v ~ /^#/) v = ""; else sub(/[ \t]+#.*$/, "", v)
        items = ""
        if (key in want) cur = key
      }
      next
    }
    cur != "" && /^[ \t]*-[ \t]/ {
      it = $0; sub(/^[ \t]*-[ \t]+/, "", it); gsub(/["\047]/, "", it); sub(/[ \t]+#.*$/, "", it)
      items = items (items == "" ? "" : ", ") it; next
    }
    END { flush() }' 2>/dev/null < <(_sg_text "$f") | _sg_clean
}

# _sg_composer_policy <composer.json> -> "config.policy = <json>" and
# "config.policy.cooldown.<k> = <json>", or "unreadable: why", or nothing.
# -I -S: an isolated interpreter that processes no site directory, so neither
# the working directory nor a .pth file runs anything. Started from /, on an
# absolute path: python3 may be a version manager's shim, which reads files in
# the working directory to choose what it runs.
_sg_composer_policy() {
  if command -v python3 >/dev/null 2>&1; then
    (cd / && python3 -I -S - "$1" 2>/dev/null) <<'PY' | _sg_clean
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        d = json.load(f)
except Exception as e:
    print("unreadable: " + (str(e).splitlines() or ["?"])[0])
    sys.exit(0)
cfg = d.get("config") if isinstance(d, dict) else None
pol = cfg.get("policy") if isinstance(cfg, dict) else None
if pol is None:
    sys.exit(0)
if not isinstance(pol, dict):
    print("config.policy = " + json.dumps(pol))
    sys.exit(0)
cd = pol.get("cooldown")
if isinstance(cd, dict):
    for k in ("period", "block", "ignore"):
        if k in cd:
            print("config.policy.cooldown." + k + " = " + json.dumps(cd[k]))
elif "cooldown" in pol:
    print("config.policy.cooldown = " + json.dumps(cd))
PY
  elif grep -qE '"policy"|\\u' "$1" 2>/dev/null; then
    echo "unreadable: no python3 here to read a \"policy\" key with"
  fi
}

# What outranks a repo's value, if anything. One place, so the wording and the
# facts change together.
_sg_role_env="on a host hardened by the role, the env layer outranks it in login shells and PAM sessions, not in systemd units, a container CMD or a cleaned environment"
_sg_ci_env="in CI, later steps that have the action's env layer carry it too"
_sg_open="Not closed by the role or the action."

# Appends to the caller's `overrides` array: "<file>: <line> — <effect>".
_sg_override() { overrides+=("$1: $2 — $3"); }

# Every repo-local override this reads, for the repo at $1.
suggest_overrides() {
  local d l f tables
  local -a hits
  d=$(CDPATH="" cd -- "$1" 2>/dev/null && pwd) || return 0
  _sg_hits() { hits=(); while IFS= read -r l; do [ -n "$l" ] && hits+=("$l"); done; }

  if _sg_have "$d" .npmrc; then
    _sg_hits < <(_sg_ini "$d/.npmrc" ignore-scripts min-release-age min-release-age-exclude minimum-release-age allow-git)
    for l in ${hits[@]+"${hits[@]}"}; do
      case "$l" in
        ignore-scripts=*) _sg_override .npmrc "$l" "this project's npm runs install scripts when it is false. NPM_CONFIG_IGNORE_SCRIPTS outranks it: ${_sg_role_env}; ${_sg_ci_env}." ;;
        min-release-age=*) _sg_override .npmrc "$l" "this project's npm age gate, in days; 0 turns it off. NPM_CONFIG_MIN_RELEASE_AGE outranks it: ${_sg_role_env}; ${_sg_ci_env}." ;;
        min-release-age-exclude*) _sg_override .npmrc "$l" "these packages skip npm's age gate (npm 11.17+). ${_sg_open}" ;;
        minimum-release-age=*) _sg_override .npmrc "$l" "pnpm 10's age gate for this project (pnpm 11 does not read .npmrc for this). ${_sg_open}" ;;
        allow-git=*) _sg_override .npmrc "$l" "whether this project's npm installs git dependencies. NPM_CONFIG_ALLOW_GIT=none outranks it on npm 11.9.0+: ${_sg_role_env}; ${_sg_ci_env}." ;;
      esac
    done
    _sg_net .npmrc "$d/.npmrc" ini ignore-scripts min-release-age min-release-age-exclude minimum-release-age allow-git
  fi

  # uv reads uv.toml if there is one, else pyproject.toml's [tool.uv].
  for f in uv.toml pyproject.toml; do
    _sg_have "$d" "$f" || continue
    if [ "$f" = uv.toml ]; then
      _sg_hits < <(_sg_toml "$d/$f" no-build exclude-newer exclude-newer-package pip.no-build pip.exclude-newer)
    else
      _sg_hits < <(_sg_toml "$d/$f" tool.uv.no-build tool.uv.exclude-newer tool.uv.exclude-newer-package tool.uv.pip.no-build tool.uv.pip.exclude-newer)
    fi
    for l in ${hits[@]+"${hits[@]}"}; do
      case "$l" in
        *exclude-newer-package*) _sg_override "$f" "$l" "loosens uv's cutoff for the packages it names. ${_sg_open}" ;;
        *pip.exclude-newer*) _sg_override "$f" "$l" "\`uv pip\`'s own cutoff for this project. Whether UV_EXCLUDE_NEWER outranks this form was not measured; treat it as not closed." ;;
        *exclude-newer*) _sg_override "$f" "$l" "this project's own uv cutoff, instead of the host's. On a role host with uv_exclude_newer_env (agent_host turns it on), UV_EXCLUDE_NEWER outranks it in login shells; otherwise, and in CI, not closed." ;;
        *no-build*) _sg_override "$f" "$l" "uv's source-build block for this project; false lifts it for every uv command run here. ${_sg_open}" ;;
      esac
    done
    _sg_net "$f" "$d/$f" toml no-build exclude-newer exclude-newer-package
    [ "$f" = uv.toml ] && break
  done

  if _sg_have "$d" bunfig.toml; then
    _sg_hits < <(_sg_toml "$d/bunfig.toml" install.minimumReleaseAge install.minimumReleaseAgeExcludes install.ignoreScripts)
    for l in ${hits[@]+"${hits[@]}"}; do
      case "$l" in
        *minimumReleaseAgeExcludes*) _sg_override bunfig.toml "$l" "these packages skip Bun's age gate (measured on Bun 1.4.5). ${_sg_open}" ;;
        *minimumReleaseAge*) _sg_override bunfig.toml "$l" "this project's Bun age gate, in seconds; 0 turns it off (measured on Bun 1.4.5). ${_sg_open}" ;;
        *ignoreScripts*) _sg_override bunfig.toml "$l" "false runs the scripts of every package this project trusts (measured on Bun 1.4.5). ${_sg_open}" ;;
      esac
    done
    _sg_net bunfig.toml "$d/bunfig.toml" toml minimumReleaseAge minimumReleaseAgeExcludes ignoreScripts
  fi

  if _sg_have "$d" poetry.toml; then
    _sg_hits < <(_sg_toml "$d/poetry.toml" solver.min-release-age solver.min-release-age-exclude solver.min-release-age-exclude-source)
    for l in ${hits[@]+"${hits[@]}"}; do
      case "$l" in
        *min-release-age-exclude*) _sg_override poetry.toml "$l" "these skip Poetry's age gate; it outranks POETRY_SOLVER_MIN_RELEASE_AGE too. ${_sg_open}" ;;
        *min-release-age*) _sg_override poetry.toml "$l" "this project's Poetry age gate, in days. POETRY_SOLVER_MIN_RELEASE_AGE outranks it: ${_sg_role_env}; ${_sg_ci_env}." ;;
      esac
    done
    _sg_net poetry.toml "$d/poetry.toml" toml min-release-age min-release-age-exclude min-release-age-exclude-source
  fi

  if _sg_have "$d" pnpm-workspace.yaml; then
    _sg_hits < <(_sg_yaml "$d/pnpm-workspace.yaml" minimumReleaseAge minimumReleaseAgeExclude minimumReleaseAgeStrict ignoreScripts)
    for l in ${hits[@]+"${hits[@]}"}; do
      case "$l" in
        minimumReleaseAgeExclude:*) _sg_override pnpm-workspace.yaml "$l" "these packages skip pnpm's age gate. On pnpm 11+, pnpm_config_minimum_release_age_exclude outranks it: ${_sg_role_env}. On pnpm 10, and in CI, not closed." ;;
        minimumReleaseAgeStrict:*) _sg_override pnpm-workspace.yaml "$l" "false lets a too-new exact pin install. ${_sg_open}" ;;
        minimumReleaseAge:*) _sg_override pnpm-workspace.yaml "$l" "this project's pnpm age gate, in minutes. On pnpm 11+, pnpm_config_minimum_release_age outranks it: ${_sg_role_env}. On pnpm 10, and in CI, not closed." ;;
        ignoreScripts:*) _sg_override pnpm-workspace.yaml "$l" "false runs this project's own lifecycle scripts and the builds it allows. ${_sg_open}" ;;
      esac
    done
    _sg_net pnpm-workspace.yaml "$d/pnpm-workspace.yaml" yaml minimumReleaseAge minimumReleaseAgeExclude minimumReleaseAgeStrict ignoreScripts
  fi

  if _sg_have "$d" .yarnrc.yml; then
    _sg_hits < <(_sg_yaml "$d/.yarnrc.yml" enableScripts npmMinimalAgeGate npmPreapprovedPackages yarnPath plugins)
    for l in ${hits[@]+"${hits[@]}"}; do
      case "$l" in
        enableScripts:*) _sg_override .yarnrc.yml "$l" "true runs install scripts in this project. ${_sg_open}" ;;
        npmMinimalAgeGate:*) _sg_override .yarnrc.yml "$l" "this project's yarn age gate, in minutes (Yarn 4.10+). ${_sg_open}" ;;
        npmPreapprovedPackages:*) _sg_override .yarnrc.yml "$l" "these packages skip yarn's age gate. ${_sg_open}" ;;
        yarnPath:*) _sg_override .yarnrc.yml "$l" "this project's own yarn runs for every yarn command here, and it decides which gates exist. ${_sg_open}" ;;
        plugins:*) _sg_override .yarnrc.yml "$l" "code loaded into yarn for every command here. ${_sg_open}" ;;
      esac
    done
    if [ "$(_sg_text "$d/.yarnrc.yml" | { LC_ALL=C grep -ciE '^#[[:space:]]+yarn[[:space:]]+lockfile[[:space:]]+v1' || :; })" -gt 0 ]; then
      _sg_override .yarnrc.yml "marked \"yarn lockfile v1\"" "yarn parses such a file by yarn 1's rules, which this reader does not follow: open the file."
    fi
    _sg_net .yarnrc.yml "$d/.yarnrc.yml" yaml enableScripts npmMinimalAgeGate npmPreapprovedPackages yarnPath plugins
  fi
  if _sg_have "$d" .yarnrc; then
    _sg_hits < <(_sg_text "$d/.yarnrc" | { LC_ALL=C grep -E '^[[:space:]]*"?yarn-path"?([[:space:]]|$)' || :; } | _sg_clean)
    for l in ${hits[@]+"${hits[@]}"}; do
      _sg_override .yarnrc "$l" "this project's own yarn 1 runs for every yarn command here. ${_sg_open}"
    done
    _sg_net .yarnrc "$d/.yarnrc" yarn1 yarn-path
  fi

  if _sg_have "$d" .bundle/config; then
    _sg_hits < <(_sg_yaml "$d/.bundle/config" BUNDLE_COOLDOWN BUNDLE_FROZEN)
    for l in ${hits[@]+"${hits[@]}"}; do
      case "$l" in
        BUNDLE_COOLDOWN:*) _sg_override .bundle/config "$l" "Bundler's age gate for this project, in days; it outranks the BUNDLE_COOLDOWN both surfaces export (measured on Bundler 4.0.13 to 4.1.0). ${_sg_open}" ;;
        BUNDLE_FROZEN:*) _sg_override .bundle/config "$l" "a project setting outranks ~/.bundle/config; false turns frozen mode off here. ${_sg_open}" ;;
      esac
    done
    _sg_net .bundle/config "$d/.bundle/config" yaml BUNDLE_COOLDOWN BUNDLE_FROZEN
  fi

  if _sg_have "$d" composer.json; then
    _sg_hits < <(_sg_composer_policy "$d/composer.json")
    for l in ${hits[@]+"${hits[@]}"}; do
      case "$l" in
        unreadable:*) _sg_override composer.json "$l" "config.policy could not be read; look for it in the file." ;;
        *cooldown.ignore*) _sg_override composer.json "$l" "these packages skip Composer's age gate (\"*\" is every package); it outranks COMPOSER_POLICY_COOLDOWN_PERIOD and _BLOCK (measured on Composer 2.11.1). ${_sg_open}" ;;
        *cooldown.period*|*cooldown.block*) _sg_override composer.json "$l" "Composer's age gate for this project. COMPOSER_POLICY_COOLDOWN_PERIOD and _BLOCK outrank it (measured on 2.11.1): ${_sg_role_env}; ${_sg_ci_env}." ;;
        config.policy*) _sg_override composer.json "$l" "false turns Composer's policy off, age gate and advisory blocking included (measured on 2.11.2). Neither surface exports COMPOSER_POLICY, which outranks it. ${_sg_open}" ;;
      esac
    done
  fi

  for f in .cargo/config.toml .cargo/config; do
    _sg_have "$d" "$f" || continue
    _sg_hits < <(_sg_toml "$d/$f" build.rustc-wrapper build.rustc-workspace-wrapper build.rustc)
    l=$(printf '%s\n' ${hits[@]+"${hits[@]}"} | awk 'NR <= 3 && $0 != ""' | tr '\n' ';' | sed 's/;$//')
    tables=$(_sg_text "$d/$f" | sed -n 's/^[[:space:]]*\[\{1,2\}[[:space:]]*\([^]]*\).*/\1/p' | tr -d '"'"'"' \t' | sort -u | tr '\n' ',' | sed 's/,$//; s/,/, /g' | _sg_clean)
    _sg_override "$f" "${l:+$l; }tables: ${tables:-none}" "cargo reads it for every cargo command here, and \`cargo metadata\` (which an IDE runs on folder open) runs a rustc-wrapper it names. ${_sg_open}"
    _sg_net "$f" "$d/$f" toml rustc-wrapper rustc-workspace-wrapper rustc
  done
  if _sg_have "$d" cooldown.toml; then
    l=$(_sg_text "$d/cooldown.toml" | { grep -vE '^[[:space:]]*(#|$)' || :; } | awk 'NR <= 6' | tr '\n' ';' | sed 's/;$//; s/;/; /g' | _sg_clean)
    _sg_override cooldown.toml "${l:-(empty)}" "cargo-cooldown reads it; the wrapper pins the windows, but allow entries in it still exempt crates. Not closed."
  fi
  for f in rust-toolchain.toml rust-toolchain; do
    _sg_have "$d" "$f" || continue
    _sg_hits < <(_sg_toml "$d/$f" toolchain.path)
    for l in ${hits[@]+"${hits[@]}"}; do
      _sg_override "$f" "$l" "rustup runs the cargo under that path in this project, so the cargo wrapper never sees those commands. ${_sg_open}"
    done
    _sg_net "$f" "$d/$f" toml path
  done
}

suggest_for_repo() {
  local dir="${1:-.}"
  local -a with_lines=() notes=() overrides=() ansible=()
  local found_any=0 cargo_note=0

  if [ ! -d "$dir" ]; then
    echo "[supply-chain-harden] error: '$dir' is not a directory" >&2
    return 2
  fi

  echo "supply-chain-hardening — suggested configuration for ${dir}"
  echo ""

  # --- npm/pnpm/yarn/bun: packages whose install runs code ---
  # Only names a registry package can have. These are printed into commands a
  # person or an agent is told to run, and a lockfile is the repo's to write:
  # MEASURED, a package-lock.json entry named `$(...)`, or one holding a newline
  # or a terminal escape, came out as it was written. A leading dash would be an
  # option to npm.
  local scripted scripted_all odd_names=0
  local name_re='^(@[A-Za-z0-9._][A-Za-z0-9._-]*/)?[A-Za-z0-9._][A-Za-z0-9._-]*$'
  scripted_all=$(suggest_scripted_deps "$dir" | sed '/^$/d' | sort -u) || true
  scripted=$(printf '%s\n' "$scripted_all" | { LC_ALL=C grep -E "$name_re" || :; } | tr '\n' ',' | sed 's/,$//') || true
  odd_names=$(printf '%s\n' "$scripted_all" | sed '/^$/d' | { LC_ALL=C grep -cvE "$name_re" || :; }) || true
  if [ "${odd_names:-0}" -gt 0 ]; then
    found_any=1
    notes+=("Entries marked as running code at install time whose name no registry package can have: ${odd_names}. They are not printed here. Look at the lockfile before installing from it.")
  fi
  # THE FIX DEPENDS ON THE PACKAGE MANAGER. pnpm_built_dependencies writes
  # pnpm's config and nothing else. MEASURED (VM#9): a package-lock.json repo
  # with sqlite3 was told to set it, did, and the binding was still missing,
  # because only ~/.config/pnpm changed. npm has no per-package allowlist that
  # survives ignore-scripts=true; what works is an explicit rebuild step.
  # MEASURED 2026-11-19 with a dependency whose install script writes a
  # marker, under ~/.npmrc + NPM_CONFIG_IGNORE_SCRIPTS=true:
  #   npm rebuild <pkg>                         did nothing    9.2.0, 11.19.1, 12.2.3
  #   npm rebuild <pkg> --ignore-scripts=false  ran it         9.2.0, 11.19.1
  #                                             did nothing    12.2.3 (allowScripts gate)
  #   npm approve-scripts <pkg>, then the same  ran it         12.2.3
  # and npm config get ignore-scripts still answered true afterwards.
  local scripted_sp="${scripted//,/ }"
  local npm_fix="\`- run: npm rebuild ${scripted_sp} --ignore-scripts=false\` as its own step after the install. On npm 12, run \`npm approve-scripts ${scripted_sp}\` once and commit the allowScripts entry it adds to package.json, or that rebuild skips them too"
  if [ -n "$scripted" ]; then
    found_any=1
    notes+=("These packages run code at install time: ${scripted}. \`ignore-scripts\` blocks that by default, which for native modules means the install 'succeeds' and the binding is missing.")
    if [ -f "$dir/pnpm-lock.yaml" ]; then
      with_lines+=("          pnpm_built_dependencies: '$scripted'")
      ansible+=("pnpm_built_dependencies")
      notes+=("pnpm: allowlisting them restores their build scripts and nothing else. On pnpm 11+ that input cannot allowlist anything: pnpm 11 has no global build allowlist. Also list these as \`allowBuilds\` in the project's pnpm-workspace.yaml.")
    fi
    if [ -f "$dir/package-lock.json" ]; then
      notes+=("npm (package-lock.json): there is no per-package build allowlist for npm here; \`pnpm_built_dependencies\` changes pnpm's config only. To build the ones you trust, add ${npm_fix}.")
    fi
    if [ ! -f "$dir/package-lock.json" ] && [ ! -f "$dir/pnpm-lock.yaml" ]; then
      notes+=("This list came from a known-names scan, not a lockfile — treat it as a floor, not the full set. Commit a package-lock.json or pnpm-lock.yaml and re-run for the exact answer.")
      if [ -f "$dir/yarn.lock" ] || [ -f "$dir/bun.lock" ] || [ -f "$dir/bun.lockb" ]; then
        notes+=("yarn and bun: this action has no per-package build allowlist for either, so these builds stay blocked under it. \`pnpm_built_dependencies\` changes pnpm's config only.")
      else
        notes+=("With no lockfile it is not known which package manager installs these. pnpm: set \`pnpm_built_dependencies: '$scripted'\` (and \`allowBuilds\` on pnpm 11+). npm: add ${npm_fix}.")
      fi
    fi
  fi

  # --- the repo's OWN lifecycle scripts ---
  #
  # ignore-scripts is not limited to dependencies: `npm ci` also skips the root
  # package's own prepare/postinstall. That is how husky and patch-package
  # stop running, and the failure surfaces later and elsewhere (a missing git
  # hook, an unpatched dependency) with nothing pointing back here.
  if [ -f "$dir/package.json" ]; then
    local own
    own=$(grep -oE '"(prepare|postinstall|preinstall|install|prepublish)"[[:space:]]*:' \
          "$dir/package.json" 2>/dev/null | tr -d '":' | tr -d ' ' | sort -u | tr '\n' ' ' || true)
    if [ -n "$own" ]; then
      found_any=1
      notes+=("Your own package.json defines: ${own}— \`npm ci\` will NOT run these while ignore-scripts is on. If one of them is load-bearing (husky, patch-package), run it explicitly as its own step, e.g. \`- run: npm run prepare\`.")
    fi
  fi

  # --- composer ---
  if [ -f "$dir/composer.json" ]; then
    local needs_plugins=0
    grep -q '"allow-plugins"' "$dir/composer.json" 2>/dev/null && needs_plugins=1
    local plug
    for plug in composer/installers phpstan/extension-installer \
                dealerdirect/phpcodesniffer-composer-installer php-http/discovery \
                symfony/flex cweagans/composer-patches; do
      grep -q "\"$plug\"" "$dir/composer.json" 2>/dev/null && needs_plugins=1
    done
    if [ "$needs_plugins" = "1" ]; then
      found_any=1
      with_lines+=("          composer_allow_plugins: 'true'")
      ansible+=("composer_allow_plugins")
      notes+=("composer.json declares plugins. The wrapper injects \`--no-plugins\` by default, which silently skips them; \`--no-scripts\` still applies either way.")
    fi
    if grep -q '"scripts"' "$dir/composer.json" 2>/dev/null; then
      found_any=1
      notes+=("composer.json defines scripts. Lifecycle scripts (post-install-cmd, post-update-cmd, post-autoload-dump, ...) are skipped: the wrapper injects \`--no-scripts\`, COMPOSER_SKIP_SCRIPTS lists them as well, and there is no input to disable either. A script run by name still runs (\`composer test\`, \`composer run-script lint\`); one whose name is also a prefix of a built-in command (\`check\`, \`req\`) is refused, so run it as \`composer run-script <name>\`. Run a lifecycle event you need as its own step: \`COMPOSER_SKIP_SCRIPTS= composer run-script post-install-cmd\`.")
    fi
  fi

  # --- cargo ---
  if [ -f "$dir/Cargo.toml" ]; then
    found_any=1
    with_lines+=("          install_cargo_cooldown: 'true'")
    cargo_note=1
    notes+=("Rust detected. Without the cargo-cooldown backend the publish-age gate's config is written but nothing enforces it — you get \`--locked\` only. It compiles from source (minutes on a cold runner), so cache it or accept the cost. cargo is also the one ecosystem where \`build.rs\` runs at compile time with your privileges and cannot be blocked, which is what the age gate is standing in for.")
  fi

  # --- python ---
  if [ -f "$dir/pyproject.toml" ] || [ -f "$dir/setup.py" ] \
     || [ -f "$dir/requirements.txt" ]; then
    notes+=("Python detected. pip is set to \`only-binary=:all:\` — a dependency published only as an sdist will fail to resolve. If that happens, use \`uv pip install\` (it honours no-build with better errors), or drop \`pip\` from \`ecosystems\`. Whether a given dependency has a wheel for this platform cannot be determined without the network, so this is a heads-up rather than a finding.")
  fi

  suggest_overrides "$dir"

  # --- output ---
  if [ "$found_any" = "0" ] && [ ${#notes[@]} -eq 0 ]; then
    echo "No exceptions needed. The defaults should work as-is:"
    echo ""
    echo "      - uses: echennells/supply-chain-hardening/action@v2"
    echo ""
    echo "With the Ansible role, no extra vars are needed either:"
    echo ""
    echo "      ansible-playbook site.yml --limit localhost"
    echo ""
    echo "Still put it after your setup-* steps and before your installs, and add"
    echo "the verify action after your installs."
    _sg_print_overrides
    return 0
  fi

  if [ ${#with_lines[@]} -gt 0 ]; then
    echo "Add this to your workflow:"
    echo ""
    echo "      - uses: echennells/supply-chain-hardening/action@v2"
    echo "        with:"
    printf '%s\n' "${with_lines[@]}"
    echo ""
  else
    echo "No action inputs need changing. Read the notes below before your first build."
    echo ""
  fi

  # The same evidence for the role. Extra vars in JSON: pnpm_built_dependencies
  # is a list, and key=value would hand the role a string.
  local ev=""
  case " ${ansible[*]:-} " in
    *" pnpm_built_dependencies "*)
      local names="" n
      for n in ${scripted//,/ }; do
        case "$n" in *[!A-Za-z0-9@/._-]*) continue ;; esac
        names="${names:+$names, }\"$n\""
      done
      [ -n "$names" ] && ev="${ev:+$ev, }\"pnpm_built_dependencies\": [$names]" ;;
  esac
  case " ${ansible[*]:-} " in
    *" composer_allow_plugins "*) ev="${ev:+$ev, }\"composer_allow_plugins\": true" ;;
  esac
  if [ -n "$ev" ]; then
    echo "With the Ansible role, the same exceptions as extra vars:"
    echo ""
    echo "      ansible-playbook site.yml --limit localhost -e '{$ev}'"
  else
    echo "With the Ansible role, no extra vars are needed:"
    echo ""
    echo "      ansible-playbook site.yml --limit localhost"
  fi
  if [ "$cargo_note" = "1" ]; then
    echo ""
    echo "      (install_cargo_cooldown has no role counterpart to pass: the role"
    echo "       builds cargo-cooldown by default, cargo_cooldown_enforce=true.)"
  fi
  echo ""

  if [ ${#notes[@]} -gt 0 ]; then
    echo "Why, and what else to know:"
    echo ""
    local n
    for n in "${notes[@]}"; do _sg_note "$n"; done
    echo ""
  fi

  _sg_print_overrides
  echo "Order still matters more than any of the above: setup-* steps first,"
  echo "then this action, then your installs, then the verify action."
}

# Reads the caller's `overrides` array (bash's dynamic scope) and says what was
# looked for, so an empty list reads as "looked and found none", not as silence.
_sg_print_overrides() {
  local o
  echo ""
  if [ ${#overrides[@]} -eq 0 ]; then
    echo "Repo-local config that outranks the host's: none found at the top of the repo"
    echo "(.npmrc, uv.toml, pyproject [tool.uv], bunfig.toml, poetry.toml, pnpm-workspace.yaml,"
    echo ".yarnrc.yml, .yarnrc, .bundle/config, composer.json, .cargo/config.toml, cooldown.toml,"
    echo "rust-toolchain). Other files can do it too, and were not read: deno.json, NuGet.Config,"
    echo "Maven's and Gradle's, package.json's packageManager (corepack and pnpm run the version"
    echo "it names), and anything below the top of the repo."
  else
    echo "Repo-local config that outranks the host's, as the files are written:"
    echo ""
    for o in "${overrides[@]}"; do _sg_note "$o"; done
    echo ""
    echo "Only the top of the repo was read, and the files as text: nothing in the repo"
    echo "ran. deno.json, NuGet.Config, Maven's and Gradle's files and package.json's"
    echo "packageManager were not read. After applying, run the verifier from inside the"
    echo "repo; it reports the uv, pnpm, yarn, composer and bundler ones as rows."
  fi
  echo ""
}

# ---- --preflight: what applying would meet here, before anything is written ----
#
# For the agent or person who is about to apply the role (or this script) and
# owes the host's owner a picture of what will happen first. It answers, before
# a single task runs: can the play run at all (Ansible present and recent
# enough, the caller not root, sudo, GNU date), which existing files would stop
# it, which package managers are here, and, for a repo, what --suggest says.
#
# WHY HERE AND NOT IN ANSIBLE. The first thing to know is whether Ansible is
# there at all, which a play cannot answer. And the role's own preflight is not
# a preview: it stops at the first refusal, and its /etc check escalates, so a
# host whose sudo needs a password gets a prompt before anything is reported.
# `ansible-playbook --check` is not one either: the role's probes really run
# under it (check_mode: false, by design, so a dry run is accurate), and it
# stops at the first refusal and prints the whole task stream.
#
# The judgement is the role's: the same files and markers as tasks/preflight.yml
# (tests/ci/11-preflight.bats compares the two), the same user_cfg_class as the
# apply, and the same ansible-core and GNU-date conditions.
#
# IT CHANGES NO FILE, AND NEVER READS ONE AS ROOT. MEASURED in the test image
# with `find / -newer` over the whole filesystem, as root and as a user with
# passwordless sudo: nothing moved but the test's own output. The container has
# no syslog, so that could not show the one trace there is: a non-root caller
# runs `sudo -n true` once, to learn whether sudo needs a password, as the role's
# preflight does, and sudo logs it like any other call (MEASURED on Ubuntu 24.04,
# a journal and auth.log line). It never prompts. Not measured: macOS, sudo-rs.
# Versions come from files where a command that prints one writes something
# (ansible-core, go) or downloads (pnpm, yarn), and for npm; otherwise the
# command runs from / (_pf_version says which). For a tool whose version would be
# a write, or that was not measured, only its path is printed.
#
# Exit 0 when nothing above would stop the play, 1 when something would: each
# such line starts with STOP.
preflight_report() {
  local repo="${1:-}" block=0 me uid f cls ver sv is_rs=0 need_pw=1 path note out=""
  me=$(id -un 2>/dev/null || echo "?"); uid=$(id -u)
  local marker='Managed by (ansible-supply-chain-security|supply-chain-harden)'
  _pf_stop() { block=1; printf '  STOP  %s\n' "$*"; }
  _pf_note() { printf '  note  %s\n' "$*"; }
  _pf_line() { printf '        %s\n' "$*"; }

  echo "supply-chain-hardening preflight for ${me}@$(hostname 2>/dev/null || echo this host). It reads; it changes nothing."
  echo ""

  echo "Who would run the play (as this user, without sudo or --become):"
  _pf_line "user $me (uid $uid), HOME=${HOME:-<unset>}"
  if [ -z "${HOME:-}" ]; then
    _pf_stop "HOME is not set, so there is nowhere for per-user config to go and nothing under it was looked at."
    echo ""
    echo "Set HOME and run this again. Nothing was changed here."
    return 1
  fi
  if [ "$uid" -eq 0 ]; then
    # The role's guard (tasks/preflight.yml): HOME is root's and the account
    # that started this is not root.
    if [ "${HOME:-}" = /root ] && [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER:-}" != root ]; then
      _pf_stop "running as root under sudo from '$SUDO_USER': the role refuses that, because per-user config would land in root's home. Run ansible-playbook as $SUDO_USER, and the role escalates by itself where root is needed."
    elif [ "${HOME:-}" != /root ]; then
      _pf_note "running as root with HOME=${HOME:-<unset>}; per-user config lands there."
    else
      _pf_note "running as root: the role hardens root's own home and the system files."
    fi
    need_pw=0
  elif command -v sudo >/dev/null 2>&1; then
    if sudo -n true >/dev/null 2>&1; then
      need_pw=0; _pf_line "sudo works without a password"
    else
      _pf_line "sudo asks for a password: run ansible-playbook with -K (or this user has no sudo rights at all)"
    fi
    sv=$(sudo --version 2>/dev/null | head -1) || true
    case "$sv" in sudo-rs*) is_rs=1 ;; esac
  else
    _pf_stop "no sudo on PATH and not root: the role needs root for /etc, /usr/local/bin and /etc/environment, and Ansible escalates with sudo unless told otherwise."
  fi

  echo ""
  echo "Ansible on this machine:"
  if path=$(command -v ansible-playbook 2>/dev/null); then
    ver=$(_pf_ansible_version "$path")
    _pf_line "ansible-core ${ver:-(version not read)} ($path)"
    [ -n "$ver" ] || _pf_note "its version could not be read without starting it; the role needs ansible-core >= 2.14, and on sudo-rs with a password prompt 2.20.11+, 2.21.6+ or 2.22+."
    if [ -n "$ver" ]; then
      version_ge "$ver" 2.14 || _pf_stop "ansible-core $ver is below 2.14, the role's documented minimum (README.md)."
      # tasks/preflight.yml: sudo-rs's prompt is not one this ansible-core can
      # answer, so every task that needs root would time out or hang.
      if [ "$is_rs" = 1 ] && [ "$need_pw" = 1 ] \
         && { ! version_ge "$ver" 2.20.11 || { version_ge "$ver" 2.21.0 && ! version_ge "$ver" 2.21.6; }; }; then
        _pf_stop "this host's sudo is sudo-rs and asks for a password, which ansible-core $ver cannot answer (measured on 2.16 to 2.21.5). Use ansible-core 2.20.11+, 2.21.6+ or 2.22+ for this user (pipx install 'ansible-core>=2.21.6'), or NOPASSWD sudo for the apply."
      fi
    fi
  else
    _pf_stop "ansible-playbook not found. Install ansible-core >= 2.14 for this user, or use action/harden.sh --emit=plain (narrower, see AGENTS.md)."
  fi
  # The role's probe is `date -u -d @0`. BSD date (macOS) reads -d as "set the
  # kernel's daylight-saving value", so there the probe is not run at all.
  f=$(date --version 2>/dev/null | head -1) || true
  if [ "${f#*GNU}" != "$f" ]; then
    :
  elif [ "$(uname -s 2>/dev/null)" = Darwin ] \
       || [ "$(date -u -d @0 +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" != "1970-01-01T00:00:00Z" ]; then
    _pf_stop "this machine's date is not GNU date, which the role's rolling uv/pip cutoff needs (macOS: brew install coreutils and put its gnubin first on PATH for this shell, or pin uv_exclude_newer to an instant)."
  fi

  echo ""
  echo "Files the play stops on (it did not write them; nothing is changed until they are dealt with):"
  for f in /etc/npmrc /etc/pip.conf /etc/uv/uv.toml; do
    [ -f "$f" ] || continue
    if [ ! -r "$f" ]; then
      _pf_note "$f: not readable by $me; the role reads it as root and decides."
    elif grep -qE "$marker" "$f" 2>/dev/null; then
      _pf_line "$f: written by this project, replaced as before"
    else
      _pf_stop "$f: not written by this project, and often a corporate registry. Show it to the owner; only with their agreement, -e accept_etc_overwrite=true replaces it."
    fi
  done
  # npm's global config, where that is not /etc/npmrc. action/harden.sh does not
  # write it.
  f=$(ucf_path npm-global)
  if [ -n "$f" ]; then
    case "$(ucf_global_by "$f")" in
      root) out=$(ucf_no_root npm-global "$f") ;;
      user) out=$(ucf_stuck npm-global "$f") ;;
    esac
  fi
  if [ -n "$out" ]; then
    _pf_note "$f: npm's global config. It $out. The role leaves it alone and lists it in the run summary."
  elif [ -n "$f" ] && [ ! -e "$f" ]; then
    _pf_line "$f: npm's global config, not there, will be created"
  elif [ -n "$f" ] && [ ! -f "$f" ]; then
    _pf_stop "$f: npm's global config, and not a regular file."
  elif [ -n "$f" ] && [ ! -r "$f" ]; then
    _pf_note "$f: npm's global config, not readable by $me; the role reads it as root and decides."
  elif [ -n "$f" ] && [ "$(user_cfg_class npm-global "$f")" = ours ]; then
    _pf_line "$f: npm's global config, exactly what this project last wrote, replaced as before"
  elif [ -n "$f" ]; then
    _pf_stop "$f: npm's global config, not exactly what this project last wrote, and often a corporate registry and its token. Tell the owner, without printing it; only with their agreement, -e accept_etc_overwrite=true copies it next to itself (0600) and replaces it."
  fi
  # The files in a home directory. Same code as the apply (ucf_*, user_cfg_class),
  # so what is said here is what happens; which file is whose is asked of the file
  # itself, and no line of one is printed.
  local l gone maybe longer mode hours="$RELEASE_AGE_HOURS"
  _pf_user_file() { # <kind>
    ucf_applies "$1" || return 0
    f=$(ucf_path "$1")
    out=$(ucf_stuck "$1" "$f")
    if [ -n "$out" ]; then
      _pf_stop "$f: $out. Both the role and action/harden.sh stop on that; accept_user_config_overwrite does not change it."
      return 0
    fi
    if [ ! -e "$f" ]; then _pf_line "$f: not there, will be created"; return 0; fi
    [ "$1" != npmrc ] || { _pf_npmrc; return 0; }
    case "$(user_cfg_class "$1" "$f")" in
      ours) _pf_line "$f: exactly what this project last wrote, replaced as before" ;;
      stock) _pf_note "$f: dotnet's own first-run file; replaced without stopping, after a copy next to it (0600)." ;;
      *) _pf_stop "$f: not exactly what this project last wrote, so it may hold a private registry or a login token. Tell the owner, without printing it; only with their agreement, -e accept_user_config_overwrite=true copies it next to itself (0600) and replaces it." ;;
    esac
  }
  _pf_npmrc() { # ~/.npmrc is merged, so it never stops the play; say what changes in it
    case "$hours" in ""|*[!0-9]*) hours=48 ;; esac
    hours=$((10#$hours / 24)); [ "$hours" -ge 1 ] || hours=1
    out=$(npm_settings "$hours" | UCF_DRY=1 ucf_npmrc "$f") || true
    gone="" maybe="" longer="" mode=""
    while IFS= read -r l; do
      case "$l" in
        "removed "*) gone="${gone:+$gone, }${l#removed }" ;;
        "unsure "*)  maybe="${maybe:+$maybe; }${l#unsure }" ;;
        "stricter "*) longer=${l#stricter } ;;
        "mode "*)    mode=${l#mode } ;;
      esac
    done <<<"$out"
    _pf_note "$f: merged, never replaced. Its own lines stay as they are, login tokens and registries included, below this project's block of settings."
    if [ -n "$gone" ]; then
      _pf_note "$f: except your own setting of $gone, which would win over the block (min-release-age compared with $hours days). It is taken out, after a copy of the file next to it (0600)."
    fi
    [ -z "$longer" ] || _pf_note "$f: your own $longer stays, because it is longer than this project's ($hours days). It applies where NPM_CONFIG_MIN_RELEASE_AGE is not set; that variable outranks the file."
    [ -z "$maybe" ] || _pf_note "$f: kept, but may set or defeat one of the settings in the block: $maybe."
    [ -z "$mode" ] || _pf_note "$f: other accounts can read it ($mode); it becomes 0600."
  }
  for l in $UCF_KINDS; do _pf_user_file "$l"; done
  # Not a stop, and not read: as a non-root user the role leaves root's yarn file
  # alone if it did not write it, and lists it in the run summary
  # (tasks/yarn.yml). Finding out needs root, and nobody has agreed to anything
  # yet, so the preflight never escalates to read a file.
  if [ "$uid" -ne 0 ]; then
    _pf_note "/root/.yarnrc.yml: not looked at (needs root). If it is there and not this project's, the role leaves it alone and says so in the run summary."
  fi
  _pf_line "(action/harden.sh does not stop on a per-user file it did not write: it copies it next to itself, replaces it and warns. It writes /etc with sudo where it can.)"

  echo ""
  echo "Package managers here (the role configures what it finds; it installs none of them):"
  for f in node npm pnpm yarn bun deno uv python3 go rustc cargo composer bundle gem poetry mvn gradle dotnet npq-hero sfw; do
    path=$(command -v "$f" 2>/dev/null) || continue
    ver=$(_pf_version "$f" "$path")
    note=""
    case "$f" in
      npm)   if _pf_below "$ver" 11.10.0; then note="; its age gate needs npm 11.10.0"; fi ;;
      yarn)  if _pf_below "$ver" 4.10.0; then note="; its age gate needs Yarn 4.10"; fi ;;
      bun)   if _pf_below "$ver" 1.3.0; then note="; its age gate needs Bun 1.3.0"; fi ;;
      rustc) if _pf_below "$ver" 1.91.1; then note="; the cargo age gate's backend needs rustc 1.91.1"; fi ;;
    esac
    _pf_line "$f ${ver:-(version not read)} ($path)$note"
  done
  if [ -n "$(command -v python3 2>/dev/null)" ]; then
    _pf_line "(pip: the role redirects pip to uv where uv is present; pip's own age gate needs pip 26)"
  fi

  if [ -n "$repo" ]; then
    echo ""
    echo "What --suggest says for $repo:"
    echo ""
    suggest_for_repo "$repo" | sed 's/^/  /' || true
    echo ""
  else
    echo ""
    echo "For a repo headed into CI, or whose agents will run on this host, add its path:"
    echo "  action/harden.sh --preflight=/path/to/repo"
  fi

  echo ""
  if [ "$block" = 1 ]; then
    echo "STOP lines above end the play before it changes anything. Show this to the"
    echo "person who owns the host and wait for their answer. Nothing was changed here."
    return 1
  fi
  echo "Nothing above would stop the play. Show this to the person who owns the host"
  echo "and wait for their OK before applying. Nothing was changed here."
}

# _pf_ansible_version <ansible-playbook>: ansible-core's version, from its own
# package files. Not `ansible-playbook --version`: that creates ~/.ansible
# (MEASURED, ansible-core 2.16.3, find -newer over the filesystem). Empty when
# the package is not where the script's interpreter puts it.
_pf_ansible_version() {
  local r py pre d
  r=$(readlink -f "$1" 2>/dev/null) || return 0
  py=$(head -1 "$r" 2>/dev/null | sed -e 's/^#![[:space:]]*//' -e 's/[[:space:]].*//') || true
  # `#!/usr/bin/env python3`: which python3 that is here.
  case "$py" in */env) py=$(command -v python3 2>/dev/null) || true ;; esac
  # The interpreter's own lib directories; for the system's python, also where
  # pip and pip --user put packages. A launcher that names neither (a shell
  # wrapper) says nothing about which ansible it starts.
  case "$py" in
    /*/bin/*)
      pre=${py%/bin/*}
      case "$pre" in
        /usr|/usr/local) set -- "$pre"/lib/python3*/dist-packages /usr/lib/python3/dist-packages \
            /usr/local/lib/python3*/dist-packages "${HOME:-/nonexistent}"/.local/lib/python3*/site-packages ;;
        *) set -- "$pre"/lib/python3*/site-packages "$pre"/lib/python3*/dist-packages ;;
      esac ;;
    *) return 0 ;;
  esac
  for d in "$@"; do
    [ -f "$d/ansible/release.py" ] || continue
    sed -n "s/^__version__[[:space:]]*=[[:space:]]*['\"]\([0-9][^'\"]*\)['\"].*/\1/p" "$d/ansible/release.py" 2>/dev/null | head -1
    return 0
  done
  return 0
}

# _pf_below <version> <minimum>: 0 when a version was read and is below minimum.
_pf_below() { [ -n "$1" ] && ! version_ge "$1" "$2"; }

# _pf_version <tool> <path>: a version without writing anything, or nothing.
# The commands run here wrote nothing in the measurement above. Others download
# (a corepack shim), write a telemetry file (go, read from GOROOT instead), or
# start a JVM or a first-run setup that was not measured (gradle, mvn, dotnet,
# composer, gem, bundle, poetry, npq, sfw): those print nothing and are named
# with their path only.
_pf_version() {
  local t="$1" r d
  case "$t" in
    node|deno|bun|uv) detect_version "$t" "$t --version" ;;
    # Go writes telemetry counters under ~/.config/go for every `go` command,
    # `go version` included (MEASURED, go1.24.2), so GOROOT's VERSION file is
    # read instead.
    go)
      r=$(readlink -f "$2" 2>/dev/null) || return 0
      sed -n 's/^go\([0-9][0-9.]*\).*/\1/p' "${r%/bin/*}/VERSION" 2>/dev/null | head -1 || true ;;
    python3) detect_version python3 "python3 -V" ;;
    # A rustup proxy would otherwise download the toolchain to answer.
    rustc|cargo) RUSTUP_AUTO_INSTALL=0 detect_version "$t" "$t --version" ;;
    npm|pnpm|yarn)
      # From the package itself, not by running it: pnpm and yarn behind corepack
      # fetch a release to answer, and npm is node startup either way. A wrapper
      # this project deployed names the real binary in REAL_NPM=.
      r=$2
      if grep -q 'supply-chain-harden' "$r" 2>/dev/null; then
        d=$(sed -n "s/^REAL_[A-Z]*='\([^']*\)'.*/\1/p" "$r" 2>/dev/null | head -1) || true
        [ -n "$d" ] && r=$d
      fi
      r=$(readlink -f "$r" 2>/dev/null) || return 0
      case "$r" in */corepack/*|*/corepack.js) return 0 ;; esac
      d=${r%/*}
      while [ -n "$d" ] && [ "$d" != / ]; do
        if [ -f "$d/package.json" ]; then
          if [ "$(sed -n 's/^[[:space:]]*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$d/package.json" 2>/dev/null | head -1)" = "$t" ]; then
            sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([0-9][^"]*\)".*/\1/p' "$d/package.json" 2>/dev/null | head -1 || true
          fi
          return 0
        fi
        d=${d%/*}
      done ;;
    *) : ;;
  esac
  return 0
}

if [ "$SUGGEST" = "1" ]; then
  suggest_for_repo "$SUGGEST_PATH"
  exit $?
fi

if [ "$PREFLIGHT" = "1" ]; then
  preflight_report "$PREFLIGHT_REPO"
  exit $?
fi

detect_platform() {
  # Ordered by signal specificity. Each platform's own marker first; the
  # bare-$BASH_ENV fallback last, because BASH_ENV is a plain bash feature
  # that can be set outside any CI.
  if   [[ -n "${GITHUB_ACTIONS:-}" || -n "${GITHUB_ENV:-}" ]]; then echo github
  elif [[ -n "${GITLAB_CI:-}"      ]]; then echo gitlab
  elif [[ -n "${CIRCLECI:-}"       ]]; then echo circleci
  elif [[ -n "${TF_BUILD:-}"       ]]; then echo azure
  elif [[ -n "${BUILDKITE:-}"      ]]; then echo buildkite
  elif [[ -n "${BASH_ENV:-}"       ]]; then echo circleci
  else echo plain
  fi
}

PLATFORM="$EMIT"
if [[ "$PLATFORM" == "auto" ]]; then
  PLATFORM=$(detect_platform)
fi
case "$PLATFORM" in
  github|gitlab|circleci|azure|buildkite|plain) ;;
  *)
    echo "[supply-chain-harden] error: unknown --emit target '$PLATFORM'" >&2
    echo "  supported: auto, github, gitlab, circleci, azure, buildkite, plain" >&2
    exit 2
    ;;
esac

# ---- privilege: resolve ONCE, never assume ----
#
# MEASURED DEFECT. This script called `sudo` unconditionally in 24 places with
# no check that sudo exists. In a container job — `container: node:24-slim` and
# friends — the job usually runs AS ROOT and slim images routinely ship without
# the sudo package, because root has no use for it. So the very first wrapper
# deployment ran `sudo mv`, got "sudo: command not found", and `set -e` killed
# the run at exit 127.
#
# Two consequences, both measured with ECOSYSTEMS=bun,npm,pip,uv,go:
#   - only .bunfig.toml was written. npm, pip, uv and go never ran at all —
#     the same "one failure eats every downstream ecosystem" shape the role
#     already fixed and documented in tasks/go.yml.
#   - no summary, no outputs file. A step gating on ecosystems-effective got
#     an empty string rather than a verdict.
#
# The irony is that the privilege was never the problem: as root the target is
# already writable. We asked for permission we had, through a program that was
# not installed.
#
# So resolve the escalation method once:
#   root          -> no escalation needed, run the command directly
#   sudo works    -> use it
#   neither       -> CAN_ESCALATE=0; the config layer (which needs no
#                    privilege and is the load-bearing layer anyway) still
#                    applies, and wrapper deployment degrades with a recorded
#                    reason instead of taking the run down.
if [ "$(id -u)" -eq 0 ]; then
  SUDO=""
  CAN_ESCALATE=1
elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
  SUDO="sudo"
  CAN_ESCALATE=1
else
  SUDO=""
  CAN_ESCALATE=0
fi

# ---- Log annotations (platform-specific markup, identical semantics) ----
log()  { echo "[supply-chain-harden] $*"; }

notice() {
  case "$PLATFORM" in
    github) echo "::notice::$*" ;;
    azure)  echo "##vso[task.logissue type=warning]$*" ;;
    *)      echo "[supply-chain-harden] notice: $*" ;;
  esac
}

warn() {
  case "$PLATFORM" in
    github) echo "::warning::$*" ;;
    azure)  echo "##vso[task.logissue type=warning]$*" ;;
    *)      echo "[supply-chain-harden] warning: $*" >&2 ;;
  esac
}

err() {
  case "$PLATFORM" in
    github) echo "::error::$*" ;;
    azure)  echo "##vso[task.logissue type=error]$*" ;;
    *)      echo "[supply-chain-harden] error: $*" >&2 ;;
  esac
}

# >>> run_bounded
# run_bounded <seconds> <command> [args...]: runs the command, stopped after
# <seconds>: timeout(1) where it exists, then gtimeout (Homebrew coreutils),
# then a background-and-kill fallback. Stock macOS has neither, and a missing
# bound must turn into neither a missing command nor a hang. Returns the
# command's status, or 124 when it was stopped, as timeout(1) does. Variables
# assigned on the call (`VAR=x run_bounded ...`) reach the command. Like
# timeout(1), which signals its whole process group, the fallback stops what
# the command started as well (found with pgrep), so a child left holding a
# $( ) open cannot keep the hang going. The same block is in action/harden.sh,
# action/verify.sh and templates/verify.sh.j2; tests/ci/07-verify.bats checks
# that they match.
run_bounded() {
  local _rb_secs="$1" _rb_pid _rb_w _rb_rc=0 _rb_t0="$SECONDS"
  shift
  if command -v timeout >/dev/null 2>&1; then timeout "$_rb_secs" "$@"; return; fi
  if command -v gtimeout >/dev/null 2>&1; then gtimeout "$_rb_secs" "$@"; return; fi
  "$@" &
  _rb_pid=$!
  # The watcher writes nowhere: inside $( ), an inherited stdout would hold
  # the substitution open until the watcher's own sleep ended.
  ( _rb_n=0
    while kill -0 "$_rb_pid" 2>/dev/null; do
      if [ "$_rb_n" -ge "$_rb_secs" ]; then
        _rb_all=$_rb_pid _rb_q=$_rb_pid
        while _rb_q=$(pgrep -P "$(echo $_rb_q | tr ' ' ',')" 2>/dev/null | tr '\n' ' ') \
              && [ -n "${_rb_q%% }" ]; do
          _rb_all="$_rb_all $_rb_q"
        done
        kill -TERM $_rb_all 2>/dev/null || true
        sleep 2
        kill -KILL $_rb_all 2>/dev/null || true
        exit 0
      fi
      sleep 1
      _rb_n=$((_rb_n + 1))
    done ) >/dev/null 2>&1 &
  _rb_w=$!
  # 2>/dev/null: bash 3.2 reports the stopped job ("Terminated") here.
  wait "$_rb_pid" 2>/dev/null || _rb_rc=$?
  kill "$_rb_w" 2>/dev/null || true
  wait "$_rb_w" 2>/dev/null || true
  if [ "$_rb_rc" -gt 128 ] && [ $((SECONDS - _rb_t0)) -ge "$_rb_secs" ]; then
    return 124
  fi
  return "$_rb_rc"
}
# <<< run_bounded

# GitLab's collapsible sections require section_end to carry the SAME name
# as its section_start, but every end_section call site is argument-less.
# Track the open section instead of re-deriving it, or GitLab renders the
# section as never-closed.
CURRENT_SECTION=""

section() {
  CURRENT_SECTION=$(echo "$*" | tr -c '[:alnum:]_' '_')
  case "$PLATFORM" in
    github) echo "::group::[supply-chain-harden] $*" ;;
    azure)  echo "##[group][supply-chain-harden] $*" ;;
    gitlab) printf '\e[0Ksection_start:0:%s\r\e[0K[supply-chain-harden] %s\n' "$CURRENT_SECTION" "$*" ;;
    *)      echo "[supply-chain-harden] --- $* ---" ;;
  esac
}

end_section() {
  case "$PLATFORM" in
    github) echo "::endgroup::" ;;
    azure)  echo "##[endgroup]" ;;
    gitlab) printf '\e[0Ksection_end:0:%s\r\e[0K\n' "${CURRENT_SECTION:-section}" ;;
    *)      : ;;
  esac
  CURRENT_SECTION=""
}

if [[ -z "${HOME:-}" || ! -d "$HOME" ]]; then
  err "HOME is unset or not a directory (got: '${HOME:-}'). Cannot deploy user-level config."
  exit 2
fi

# ---- Nothing this script creates is writable by group or others ----
#
# MEASURED (harden.sh at 6c77f4e, run as root under `umask 0000`, the default of
# GitLab's Docker and Kubernetes executors): /etc/uv was left drwxrwxrwx, every
# per-user config and the directory it sat in (~/.npmrc, ~/.cargo,
# ~/.config/uv/uv.toml, ~/.m2/settings.xml, 32 paths in all) world-writable, and
# with intel=sfw the root `npm install -g` left /usr/local/lib/node_modules/sfw,
# the code root runs on every npm call, 0777. Any other account could rewrite
# what the next build reads or root executes.
#
# go-w is added to whatever the caller's umask is, here, before the first
# write, so it also covers every tool this script starts (npm, cargo, go env
# -w). A stricter umask (077) is kept. The few files every account must be
# able to read (/etc, the wrappers, the sfw install) get explicit modes where
# they are written. SCH_CALLER_UMASK is kept for the one place that honours the
# caller's own grant: a directory created for an explicit HARDENING_ENV_FILE.
SCH_CALLER_UMASK=$(umask)
umask go-w

# ---- The env file and the run record: where they go, and who else can touch them ----
#
# The env file is the canonical, platform-neutral artifact. It is written on
# EVERY platform, so there is always one sourceable file holding the whole env
# layer even where the platform has no step-to-step mechanism. On
# Drone/Woodpecker and other per-step-container runners it is the only way the
# env layer survives a step boundary. The run record (.outputs) beside it is
# what verify.sh reads to learn what this job promised.
#
# MEASURED DEFECT (VM#3, Ubuntu 26.04, --emit=plain). Both used a FIXED NAME
# under ${RUNNER_TEMP:-${TMPDIR:-/tmp}}, which outside a CI runner is /tmp, a
# directory every local user can write. Another user pre-created
# /tmp/supply-chain-hardening.env holding a payload. harden.sh refused to
# overwrite it (rc=2), the documented recipe's next line sourced it anyway, and
# the payload ran as the person hardening. A forged .outputs beside it scoped
# the verifier down to "this job hardened: npm". Where fs.protected_regular=0, a
# 0666 file the other user owned was even written INTO, because `: >` keeps an
# existing file's owner, and they appended to it afterwards.
#
# Three changes:
#   1. With no RUNNER_TEMP the default directory is per-user,
#      $HOME/.cache/supply-chain-hardening, created 0700. Not $TMPDIR, which is
#      often /tmp itself. Not $XDG_RUNTIME_DIR, which cron, `su` and most
#      containers do not set, so a later verify.sh could look somewhere else.
#      RUNNER_TEMP is GitHub's per-job directory, owned by the runner user, so
#      that path is unchanged. action/verify.sh resolves the same default.
#   2. A file that already exists must be a regular file we own that group and
#      others cannot write. The directory it is in, and every directory above
#      that, must not let another user swap what is below it: world-writable
#      only with the sticky bit, and then only when we or root own it.
#      Anything else is refused before a byte is written, with the reason.
#   3. Each file is created by mktemp in its own directory and renamed over the
#      target. An existing inode, and any descriptor someone holds on it, is
#      never written through.
SCH_STATE_DIR="${RUNNER_TEMP:-$HOME/.cache/supply-chain-hardening}"
HARDENING_ENV_FILE="${HARDENING_ENV_FILE:-$SCH_STATE_DIR/supply-chain-hardening.env}"
HARDENING_OUTPUT_FILE="${HARDENING_OUTPUT_FILE:-$SCH_STATE_DIR/supply-chain-hardening.outputs}"

# The 10-character mode string, as `ls -ld` prints it on GNU and BSD alike.
# -L: a symlink's own mode is lrwxrwxrwx on Linux whatever it points to.
_sch_mode() { ls -ldL -- "$1" 2>/dev/null | cut -c1-10; }

# _sch_unsafe_target <file>: prints why <file> must not be (re)created; silent when it may.
_sch_unsafe_target() {
  local f="$1" d m
  d=$(dirname -- "$f")
  if [ -L "$f" ]; then echo "is a symbolic link"; return 0; fi
  if [ -e "$f" ]; then
    [ -f "$f" ] || { echo "exists and is not a regular file"; return 0; }
    [ -O "$f" ] || { echo "already exists and belongs to another user ($(ls -ld -- "$f" | awk '{print $3}'))"; return 0; }
    m=$(_sch_mode "$f")
    case "$m" in ?????w*|????????w*) echo "already exists and is writable by group or others ($m)"; return 0 ;; esac
  fi
  _sch_dir_walk "$d"
}

# _sch_dir_walk <dir>: prints why another user could swap the file in <dir>,
# or <dir> itself, or any directory above it; silent when no one can.
#
# Every directory from <dir> up to /, as written and as resolved (a symlinked
# component is judged by where it points). Each one decides who can rename the
# entry below it, so one open directory anywhere above lets that user move ours
# aside and put their own in its place. For each directory:
#   world-writable, no sticky bit -> anyone can.
#   world-writable, sticky        -> its owner still can: the sticky bit
#                                    restricts everyone EXCEPT the directory's
#                                    owner. Accepted only when that is us or root.
# MEASURED (review of the VM#3 fix): HARDENING_ENV_FILE in another user's 1777
# directory was accepted with a warning, and that user deleted and replaced
# the file; a later `source` ran their code. Under `umask 0000` (GitLab's
# Docker and Kubernetes executors) `mkdir -p` made ~/.cache drwxrwxrwx, the
# parent of the 0700 leaf, and the old check looked at the leaf only.
#
# Group-writable is not refused: with per-user groups and umask 002 (the Ubuntu
# default) every project directory is 0775, and the group is a trust grant
# somebody made on purpose. Nor is a directory merely OWNED by another user, if
# it is not world-writable. A GitHub `container:` job is the case in mind: it
# runs as root by default, and its RUNNER_TEMP is a host directory bind-mounted
# in, owned by the runner's uid (no smoke job runs in a container, so this is
# not exercised by CI).
_sch_dir_walk() {
  local d="$1" phys p m o me
  me=$(id -u)
  case "$d" in /*) ;; *) d="$PWD/$d" ;; esac
  phys=$(cd -P -- "$d" 2>/dev/null && pwd -P) || phys=""
  [ "$phys" = "$d" ] && phys=""
  for p in "$d" ${phys:+"$phys"}; do
    while :; do
      m=$(_sch_mode "$p")
      case "$m" in
        ????????w[tT])
          o=$(ls -ldnL -- "$p" 2>/dev/null | awk '{print $3}')
          if [ "$o" != "$me" ] && [ "$o" != 0 ]; then
            if [ "$p" = "$d" ] || [ "$p" = "$phys" ]; then
              echo "is in $p, a sticky directory that another user ($(ls -ldL -- "$p" | awk '{print $3}')) owns. The sticky bit stops everyone except the directory's owner, who can delete the file and put their own in its place"
            else
              echo "is below $p, a sticky directory that another user ($(ls -ldL -- "$p" | awk '{print $3}')) owns, who can rename the directory under it and put their own in its place"
            fi
            return 0
          fi ;;
        ????????w*)
          if [ "$p" = "$d" ] || [ "$p" = "$phys" ]; then
            echo "is in $p, which every user can write to and which has no sticky bit ($m), so anyone could replace the file after it is written"
          else
            echo "is below $p, which every user can write to and which has no sticky bit ($m), so anyone could rename the directory under it and put their own in its place"
          fi
          return 0 ;;
      esac
      [ "$p" = / ] && break
      p=$(dirname -- "$p")
    done
  done
  return 0
}

# _sch_create <file> <what> <override var>: <file> now exists, empty, 0644, ours. Exits 2 otherwise.
_sch_create() {
  local f="$1" what="$2" var="$3" d why tmp=""
  d=$(dirname -- "$f")
  # The directory is not guaranteed to exist: a caller can point the override
  # at a path it has not created yet. Whatever we create is never
  # world-writable, whatever the caller's umask: under GitLab's `umask 0000`
  # a plain `mkdir -p` made every new directory 0777, which the walk above
  # then refuses.
  if [ "$d" = "$HOME/.cache/supply-chain-hardening" ]; then
    # 077 for every directory this creates, ~/.cache included, not the leaf alone.
    [ -d "$d" ] || ( umask 077 && mkdir -p -- "$d" ) 2>/dev/null || true
  else
    # The caller's umask plus o-w: a group-shared directory stays group-shared.
    [ -d "$d" ] || ( umask "$(printf '%04o' "$(( 0$SCH_CALLER_UMASK | 02 ))")" && mkdir -p -- "$d" ) 2>/dev/null || true
  fi
  why=$(_sch_unsafe_target "$f")
  if [ -n "$why" ]; then
    err "refusing to write the $what: '$f' $why. Another user may control what a later step sources or trusts. Remove it, or set $var to a path in a directory only you can write."
    exit 2
  fi
  # 0644, not mktemp's 0600: the file holds no secret, and a profile.d line
  # that sources it for every user (action/examples/Dockerfile) must be able to
  # read it. What matters is who can WRITE it.
  if ! tmp=$(mktemp "$d/.supply-chain-hardening.XXXXXX" 2>/dev/null) \
     || ! chmod 644 "$tmp" 2>/dev/null \
     || ! mv -f -- "$tmp" "$f" 2>/dev/null; then
    [ -n "$tmp" ] && rm -f -- "$tmp" 2>/dev/null
    err "cannot write the $what at '$f'"
    echo "  set $var to a writable path" >&2
    exit 2
  fi
  # What the refusals leave: the file directly in a sticky world-writable
  # directory that we or root own, such as /tmp. No other user can replace it
  # while it exists. Once a reboot or a cleanup removes it, anyone can put a
  # file at the same path, and a `source` of that path runs it.
  if [ "$what" = "env file" ]; then
    case "$(_sch_mode "$d")" in
      ????????w*)
        warn "the $what is in $d, which every user can write to. While the file exists no other user can replace it, but once a reboot or a cleanup removes it anyone can put a file at that path, and a later \`source\` of it, in a shell where this harden.sh run did not just succeed, runs their file. Prefer a per-user directory." ;;
    esac
  fi
  return 0
}
_sch_create "$HARDENING_ENV_FILE"    "env file"    HARDENING_ENV_FILE
_sch_create "$HARDENING_OUTPUT_FILE" "run record"  HARDENING_OUTPUT_FILE

# ---- Validation ----
if ! [[ "$RELEASE_AGE_HOURS" =~ ^[0-9]+$ ]]; then
  err "release_age_hours must be a non-negative integer (got: '$RELEASE_AGE_HOURS')"
  exit 2
fi
# Normalise to base 10. Bash arithmetic reads a leading zero as OCTAL, so '072'
# passed the check above and then became 58 hours in every $(( )) below (the
# pnpm, yarn, bun and cargo windows) while cooldown.toml and the summary said 72;
# '08' and '09' were arithmetic errors outright.
RELEASE_AGE_HOURS=$((10#$RELEASE_AGE_HOURS))
if [[ "$RELEASE_AGE_HOURS" -lt 1 ]]; then
  err "release_age_hours must be >= 1 (got: $RELEASE_AGE_HOURS). Setting to 0 silently disables the age gate across every ecosystem."
  exit 2
fi

# ---- Env / output emission ----
#
# write_env always appends to the canonical env file, always exports into
# this process (so the script's own probes see hardened values), and then
# additionally uses the platform's native mechanism where one exists.
write_env() {
  local k="$1" v="$2"
  printf 'export %s=%q\n' "$k" "$v" >> "$HARDENING_ENV_FILE"
  export "${k}=${v}"
  case "$PLATFORM" in
    github)   echo "$k=$v" >> "$GITHUB_ENV" ;;
    circleci) printf 'export %s=%q\n' "$k" "$v" >> "${BASH_ENV:-/dev/null}" ;;
    azure)    echo "##vso[task.setvariable variable=$k]$v" ;;
    # No native step-to-step mechanism. Note the export above reaches only
    # THIS process and its children — harden.sh runs as a subprocess, so the
    # calling job shell does not inherit it. On these targets the env file is
    # the mechanism and the caller must source it:
    #
    #   ./harden.sh --emit=gitlab &&
    #     source "${HARDENING_ENV_FILE:-${RUNNER_TEMP:-$HOME/.cache/supply-chain-hardening}/supply-chain-hardening.env}"
    #
    # (that expansion is the default path: see "The env file and the run
    # record" above)
    #
    # The config-file and wrapper layers need no such step; they are already
    # on disk. Buildkite conventionally does the source in a pre-command hook.
    gitlab|buildkite|plain) : ;;
  esac
}

# WHICH JOB WROTE THIS RECORD.
#
# On a self-hosted runner the temp dir outlives the job, so yesterday's
# outputs file is still sitting there when today's verify step reads it — and
# it would silently scope today's verification to yesterday's ecosystem list.
# verify.sh compares this against its own job identity and ignores a record
# that belongs to somebody else. Empty on a platform with no job identity,
# which verify.sh treats as "cannot tell" and accepts.
job_identity() {
  if   [[ -n "${GITHUB_RUN_ID:-}" ]]; then
    printf '%s-%s-%s' "${GITHUB_RUN_ID}" "${GITHUB_RUN_ATTEMPT:-1}" "${GITHUB_JOB:-}"
  elif [[ -n "${CI_JOB_ID:-}" ]];              then printf '%s' "$CI_JOB_ID"
  elif [[ -n "${BUILDKITE_JOB_ID:-}" ]];       then printf '%s' "$BUILDKITE_JOB_ID"
  elif [[ -n "${CIRCLE_WORKFLOW_JOB_ID:-}" ]]; then printf '%s' "$CIRCLE_WORKFLOW_JOB_ID"
  elif [[ -n "${BUILD_BUILDID:-}" ]];          then printf '%s' "$BUILD_BUILDID"
  fi
}

emit_output() {
  local k="$1" v="$2"
  printf '%s=%s\n' "$k" "$v" >> "$HARDENING_OUTPUT_FILE"
  case "$PLATFORM" in
    github) echo "$k=$v" >> "${GITHUB_OUTPUT:-/dev/null}" ;;
    azure)  echo "##vso[task.setvariable variable=$k;isOutput=true]$v" ;;
    *)      : ;;
  esac
}

# Job summary. GitHub renders markdown under the job; everywhere else the
# same markdown goes to stdout so it is at least in the log.
emit_summary() {
  case "$PLATFORM" in
    github) cat >> "${GITHUB_STEP_SUMMARY:-/dev/null}" ;;
    *)      cat ;;
  esac
}

# ---- Early opt-out ----
#
# CI-specific: per-step opt-out. If a workflow step needs to bypass
# hardening (e.g., bootstrap step that legitimately needs install scripts),
# setting SUPPLY_CHAIN_HARDEN_SKIP=true on that step's env causes the
# script to exit early without applying any hardening. Use sparingly —
# the whole point of running this is to harden subsequent steps.
if [[ "${SUPPLY_CHAIN_HARDEN_SKIP:-false}" == "true" ]]; then
  notice "SUPPLY_CHAIN_HARDEN_SKIP=true — hardening intentionally skipped for this step"
  emit_output ecosystems_hardened ""
  emit_output release_age_hours "$RELEASE_AGE_HOURS"
  emit_output sfw_installed false
  emit_output tool_versions "{}"
  emit_output env_file "$HARDENING_ENV_FILE"
  emit_output wrappers_deployed ""
  emit_output job_id "$(job_identity)"
  # NO hardening_complete marker. Nothing was hardened, so the verifier must
  # NOT scope itself to this record — it widens back to checking every
  # installed tool and says out loud that the scope is unknown. An
  # intentional skip is still an unhardened job.
  exit 0
fi

# ---- Derived values ----
NPM_AGE_DAYS=$(( RELEASE_AGE_HOURS / 24 ))
[[ "$NPM_AGE_DAYS" -lt 1 ]] && NPM_AGE_DAYS=1     # npm wants integer days
PNPM_AGE_MINUTES=$(( RELEASE_AGE_HOURS * 60 ))
BUN_AGE_SECONDS=$(( RELEASE_AGE_HOURS * 3600 ))
COMPOSER_COOLDOWN_SECONDS=$(( RELEASE_AGE_HOURS * 3600 ))
POETRY_AGE_DAYS=$NPM_AGE_DAYS                     # integer days, floored at 1 like npm
DENO_AGE_ISO="P$(( RELEASE_AGE_HOURS / 24 ))D"
[[ "$DENO_AGE_ISO" == "P0D" ]] && DENO_AGE_ISO="P1D"
# INTEGER MINUTES, rendered unquoted. Yarn 4.10.x reads a duration string as
# its leading integer, in minutes: "2d" is a 2-minute gate, quoted or not
# (MEASURED 2026-11-19, yarn 4.10.3; "36500d" read as 36500). Yarn 4.11.0
# parses durations ("2d" = 2880). Integer minutes mean the same on every yarn
# that has the key, and yarn has no second age-gate layer to fall back on. The
# role has derived this in minutes since c9a250f; the action once shipped "2d".
# (An older note here said "2d" parsed to NaN. Re-measured, it does not.)
YARN_AGE=$(( RELEASE_AGE_HOURS * 60 ))
# uv's exclude-newer is written as an absolute RFC 3339 datetime. A
# relative span such as "48 hours" is accepted only from uv 0.9.17 (its
# changelog: "Add support for relative durations in exclude-newer",
# #16814). MEASURED: 0.9.16 fails the whole config with "failed to parse
# year in date", breaking every uv invocation; 0.9.17 resolves the span to
# now minus 48h. The runner's uv version is not known here, so the absolute
# form is the one every uv reads. Same bug the Ansible role had in
# defaults/main.yml (fixed in b96bb7e); the action re-introduced it
# independently at the bash layer.
#
# BSD date (macOS runners) takes -v-Nh where GNU takes -d "N hours ago".
# Try GNU first, fall back to BSD — CI runners are usually Linux but
# macOS runners exist on every platform this script now targets.
if UV_EXCLUDE_NEWER=$(date -u -d "${RELEASE_AGE_HOURS} hours ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null); then
  :
elif UV_EXCLUDE_NEWER=$(date -u -v-"${RELEASE_AGE_HOURS}"H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null); then
  :
else
  err "cannot compute the uv exclude-newer timestamp: neither GNU nor BSD date syntax worked"
  exit 2
fi

write_etc() {
  local path="$1"
  # Always consume stdin so upstream `cat <<EOF | write_etc ...` doesn't
  # SIGPIPE-then-fail-the-pipeline when WRITE_ETC=false. `set -o pipefail`
  # would otherwise halt the script on the first ecosystem that calls
  # write_etc with WRITE_ETC=false.
  local content dir owner
  content=$(cat)
  if [[ "$WRITE_ETC" != "true" ]]; then
    return 0
  fi
  dir=$(dirname "$path")
  if [[ "${CAN_ESCALATE:-0}" -ne 1 ]]; then
    # NO ROOT AND NO SUDO. The per-user config for this ecosystem was already
    # written by the caller, so skipping /etc is a reduction in coverage (sudo
    # callers in a later step), not a loss of protection, and it is never fatal.
    #
    # MEASURED (6c77f4e): root ran harden.sh, then a second account ran it in
    # the same container. When root's run had been under umask 0000, /etc/uv
    # was drwxrwxrwx, so the directory test passed, `tee` hit root's 0644
    # uv.toml, and set -e ended the run on a bare "tee: /etc/uv/uv.toml:
    # Permission denied" with every ecosystem after uv not applied. Without
    # privilege this writes only what this account already owns: a file
    # another account owns is left alone and named, and a directory another
    # account owns is not written into even when its mode allows it, because
    # root's tools would then read a file this account controls.
    if [[ -e "$path" && ! -O "$path" ]]; then
      owner=$(ls -ld -- "$path" | awk '{print $3}')
      if grep -qE 'Managed by (ansible-supply-chain-security|supply-chain-harden)' "$path" 2>/dev/null; then
        log "$path is already in place, written by an earlier hardening run as $owner, and is left as it is: this run has no root and no usable sudo to update a file $owner owns. Per-user config applies to $(id -un). To update it, re-run harden.sh as $owner or with sudo."
      else
        warn "cannot write $path: it belongs to $owner, this project did not write it, and this run has no root and no usable sudo. Per-user config still applies, but a later \`sudo\` step reads $owner's file. To replace it, re-run harden.sh as root or with sudo."
      fi
      return 0
    fi
    if [[ ! -d "$dir" || ! -w "$dir" ]]; then
      warn "cannot write $path (no root and no usable sudo) — per-user config still applies, but a later \`sudo\` step will not see it"
      return 0
    fi
    if [[ ! -O "$dir" ]]; then
      owner=$(ls -ld -- "$dir" | awk '{print $3}')
      warn "not writing $path: $dir belongs to $owner but this account can write to it ($(_sch_mode "$dir")), so a file created there would be one $(id -un) controls and $owner's tools read. Per-user config still applies. Remove group and other write from $dir (chmod go-w, as $owner), or re-run harden.sh as root or with sudo."
      return 0
    fi
  fi
  # 0755 for a directory this creates (/etc/uv) whatever the umask: under 077 it
  # was 0700, and no other account could read the uv.toml inside it.
  $SUDO mkdir -p -m 0755 "$dir"
  # And converge one an earlier run left writable by others (/etc/uv after a run
  # under umask 0000, measured above). /etc itself is the system's, not ours.
  if [[ "$dir" != /etc ]]; then
    case "$(_sch_mode "$dir")" in
      ?????w*|????????w*)
        $SUDO chmod go-w "$dir"
        log "removed group and other write from $dir, which an earlier run left writable by other accounts" ;;
    esac
  fi
  echo "$content" | $SUDO tee "$path" >/dev/null
  $SUDO chmod 644 "$path"
}

# can_write <target> — can we create or replace this path, with or without
# escalation? Checks the DIRECTORY, because replacing a file is an unlink plus
# a create and both are governed by directory permissions, not by the file's
# own mode. That distinction is the one the role got wrong once already: a
# root-owned 0755 wrapper inside a user-owned directory was removed and
# replaced by that unprivileged user (docs/design-principles.md, the
# anti-tamper corollary).
can_write() {
  local target="$1" dir
  dir=$(dirname "$target")
  [ -w "$dir" ] && return 0                 # ours outright — no escalation needed
  [ "${CAN_ESCALATE:-0}" -eq 1 ] && return 0
  return 1
}

# ucf_as_root <kind> <path>, the new body on stdin: ucf_replace, run as root with
# the functions above handed over as text. Root's shell gets no variable of this
# one's, and finds its tools in the system's directories only.
ucf_as_root() {
  local body
  body=$(cat)
  {
    # shellcheck disable=SC2046  # one word each: they are function names
    declare -f $(declare -F | awk '$3 ~ /^(ucf_|user_cfg_class$)/ { print $3 }')
    declare -p UCF_LINES
    printf 'umask 022\nUCF_ROOT=1 UCF_FOREIGN=keep\nucf_replace %q %q <<<%q\n' "$1" "$2" "$body"
  } | $SUDO /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME=/ bash
}

# put_user_cfg <kind> <path>, the new body on stdin — writes one of the per-user
# files above ("the per-user config files this project writes") and says what that
# did to anything of the user's in it. Paths and key names only: these files hold
# tokens, and this is a job log. With PUT_AS_ROOT=1 the file is one in root's home:
# it is read and written as root, and a run that cannot write it says so and goes
# on, because the user's own file is already in place.
put_user_cfg() {
  local kind="$1" path="$2" out rc=0 l bak="" gone="" maybe="" longer="" tool="${1%%-*}"
  if [[ "${PUT_AS_ROOT:-}" == 1 ]]; then
    out=$(ucf_as_root "$kind" "$path") || rc=$?
  elif [[ "$kind" == npmrc ]]; then
    out=$(ucf_npmrc "$path") || rc=$?
  else
    out=$(ucf_replace "$kind" "$path") || rc=$?
  fi
  while IFS= read -r l; do
    case "$l" in
      "copy "*)    bak=${l#copy } ;;
      "stock "*)   log "$tool: replaced dotnet's first-run $path (nuget.org only); copy at ${l#stock }" ;;
      "removed "*) gone="${gone:+$gone, }${l#removed }" ;;
      "unsure "*)  maybe="${maybe:+$maybe; }${l#unsure }" ;;
      "stricter "*) longer=${l#stricter } ;;
      "mode "*)    log "$path: other accounts could read it (${l#mode }); it is 0600 now" ;;
      "error: "*)
        if [[ "${PUT_AS_ROOT:-}" == 1 ]]; then warn "${tool%rc}: ${l#error: }"; else err "${tool%rc}: ${l#error: }"; fi ;;
    esac
  done <<<"$out"
  if [[ "$rc" -ne 0 ]]; then
    [[ -z "$bak" ]] || err "${tool%rc}: a copy of $path from before this run is at $bak"
    if [[ "${PUT_AS_ROOT:-}" == 1 ]]; then return 0; fi
    exit 1
  fi
  if [[ -n "$gone" ]]; then
    warn "npm: took your own setting of $gone out of $path, because a line after this project's block would win over it. The file as it was is at $bak"
  elif [[ -n "$bak" ]]; then
    warn "$tool: replaced $path, which was not exactly what this project last wrote. Any registry, token or other setting you added to it no longer applies; the previous file is at $bak"
  fi
  if [[ -n "$longer" ]]; then
    log "npm: kept your own $longer in $path, which is longer than this project's. It applies where NPM_CONFIG_MIN_RELEASE_AGE is not set; that variable outranks the file"
  fi
  if [[ -n "$maybe" ]]; then
    warn "npm: kept, in $path, lines that may set or defeat one of the settings this project writes there: $maybe"
  fi
}

# require_privilege <tool> <target> — gate for wrapper deployment.
#
# Wrappers are the ONLY mechanism for deno's age gate, bun's --no-install,
# bunx, composer --no-scripts, cargo --locked and the sfw route, so losing one
# is a real reduction and has to be recorded rather than logged and forgotten.
# $3/$4 optional: the degrade status + message. Defaults suit ecosystems WITH a
# config layer (npm/cargo/composer) — "PARTIAL, config still applies". A
# wrapper-only ecosystem (deno) passes NONE + its own message: with the wrapper
# undeployed, nothing is enforced, so PARTIAL would overstate coverage.
require_privilege() {
  local tool="$1" target="$2"
  local status="${3:-PARTIAL}"
  local msg="${4:-PATH wrapper not deployed: no root and no usable sudo in this job (common in \`container:\` jobs on slim images). Config-file layer still applies.}"
  local owner
  if ! can_write "$target"; then
    warn "$tool: cannot deploy the PATH wrapper at $target — this job has no root and no usable sudo."
    # Status must be one of APPLIED / PARTIAL / INERT / NONE — an invented word
    # lands in neither summary list and the ecosystem disappears from the verdict
    # line while still showing in the table below it.
    set_eco_status "$tool" "$status" "$msg"
    return 1
  fi
  # The directory lets this account in, but the wrapper already there is
  # another account's: an earlier run as root left it in a directory others can
  # write (the official rust images' /usr/local/cargo/bin is 0777). MEASURED
  # (6c77f4e): a second account's run then died on a bare "cp: cannot create
  # regular file '.../cargo': Permission denied", and nothing after cargo was
  # applied. Re-rendering it would mean replacing a file another account owns
  # (root runs it), so leave it, say whose it is, and carry on with the
  # per-user layer. A tool binary that is not our wrapper is wrapped as before.
  if [[ "${CAN_ESCALATE:-0}" -ne 1 && -f "$target" && ! -O "$target" ]] \
     && grep -q 'supply-chain-harden' "$target" 2>/dev/null; then
    owner=$(ls -ld -- "$target" | awk '{print $3}')
    warn "$tool: the PATH wrapper at $target belongs to $owner, from an earlier hardening run, and is left as it is: this job has no root and no usable sudo to replace a file $owner owns. It still runs when $(id -un) calls $tool. To update it, re-run harden.sh as $owner or with sudo."
    set_eco_status "$tool" "$status" "PATH wrapper not re-deployed: the one at $target belongs to $owner and this job has no root and no usable sudo. Config-file layer still applies."
    return 1
  fi
  return 0
}

# subst_inplace <file> <sed-script>
#
# `sed -i` is NOT portable and there is no form that works on both: GNU takes
# a bare -i, BSD (macOS) requires -i '' and reads the next argument as the
# backup suffix otherwise. On a macOS runner `sed -i "s|a|b|" file` consumed
# the script as the suffix and then choked on the path with
# "invalid command code f", killing every wrapper that renders through a
# placeholder. Write to a sibling and move instead.
subst_inplace() {
  local file="$1" script="$2"
  sed "$script" "$file" > "${file}.new" && mv "${file}.new" "$file"
}

# Escape a value for safe use as the REPLACEMENT half of `sed "s|__X__|VALUE|"`.
# Drops newlines (a wrapper value — a path, flag, or bool — is never multiline)
# and escapes the sed metacharacters `\ & |`, so a value cannot close the `s|||`
# delimiter to inject a sed command (e.g. the `e <cmd>` command) or splice a line
# into a wrapper body that is then $SUDO-written to a root-owned path. These
# inputs are operator/CI config, not attacker-controlled, so this is robustness
# parity with the npm/bun/composer wrappers (which interpolate via single-quoted
# heredocs), not a fix for a reachable vulnerability.
sed_repl() { printf '%s' "$1" | tr -d '\n\r' | sed 's/[\\&|]/\\&/g'; }

# PER-ECOSYSTEM EFFECT, as distinct from per-ecosystem ATTEMPT.
#
# HARDENED records what was REQUESTED and not unknown. It does not record
# whether anything is actually in force, and it was being reported — in the
# summary, in the final line, and in the ecosystems_hardened output — as
# though it did. Measured example: with ECOSYSTEMS=npm,cargo,deno on a host
# with neither cargo nor deno, the run said "npm,cargo,deno hardened". deno's
# ONLY mechanism is a PATH wrapper, so deno received nothing whatsoever.
#
#   APPLIED  every layer this ecosystem depends on is in place
#   PARTIAL  some layers landed, at least one did not
#   NONE     nothing effective was applied
#   INERT    written and correct, but the installed tool does not implement it
#
# Anything in HARDENED with no explicit status defaults to APPLIED at report
# time — a handler that knows it is degraded says so.
ECO_KEYS=()
ECO_STATUS=()
ECO_NOTE=()
set_eco_status() {
  local k="$1" s="$2" n="${3:-}" i
  for i in "${!ECO_KEYS[@]}"; do
    if [ "${ECO_KEYS[$i]}" = "$k" ]; then ECO_STATUS[$i]="$s"; ECO_NOTE[$i]="$n"; return 0; fi
  done
  ECO_KEYS+=("$k"); ECO_STATUS+=("$s"); ECO_NOTE+=("$n")
}
eco_status_of() {
  local k="$1" i
  for i in "${!ECO_KEYS[@]}"; do
    [ "${ECO_KEYS[$i]}" = "$k" ] && { printf '%s' "${ECO_STATUS[$i]}"; return 0; }
  done
  printf 'APPLIED'
}
eco_note_of() {
  local k="$1" i
  for i in "${!ECO_KEYS[@]}"; do
    [ "${ECO_KEYS[$i]}" = "$k" ] && { printf '%s' "${ECO_NOTE[$i]}"; return 0; }
  done
  printf ''
}

HARDENED=()
SFW_INSTALLED=false

# WRAPPERS ACTUALLY DEPLOYED, recorded for the verifier.
#
# This is the other half of the ecosystem list. A PATH wrapper is a separate
# decision from hardening the ecosystem — composer's config is written even
# when composer is absent and no wrapper lands — so `ecosystems_hardened`
# cannot answer "was a bun wrapper supposed to be here?". Without that answer
# verify.sh had to report a missing wrapper as WEAK, and WEAK does not move
# the exit code: a job with every wrapper and a job with none printed the same
# verdict. Recorded here, a promised-and-missing wrapper is a GAP.
#
# Indexed array, appended at each deploy site AFTER the chmod succeeds, so the
# record says deployed only where one is. bash 3.2 safe (see TV_KEYS below).
WRAPPED=()
record_wrapper() { WRAPPED+=("$1"); }

# TOOL VERSIONS — parallel indexed arrays, NOT an associative array.
#
# `declare -A` needs bash 4.0. macOS ships bash 3.2 (2007; Apple froze it at
# the last GPLv2 release), and `#!/usr/bin/env bash` finds that one. So on a
# macOS runner the associative array aborted the script at startup with
# "declare: -A: invalid option" — every ecosystem unhardened, before a single
# config file was written. Indexed arrays work in 3.2.
TV_KEYS=()
TV_VALS=()
set_tool_version() {
  local k="$1" v="$2" i
  for i in "${!TV_KEYS[@]}"; do
    if [ "${TV_KEYS[$i]}" = "$k" ]; then TV_VALS[$i]="$v"; return 0; fi
  done
  TV_KEYS+=("$k"); TV_VALS+=("$v")
}

# ---- Per-ecosystem handlers ----

harden_npm() {
  section "npm"
  local npm_v
  npm_v=$(detect_version npm "npm --version")
  write_env NPM_CONFIG_IGNORE_SCRIPTS  true
  write_env NPM_CONFIG_AUDIT           true
  write_env NPM_CONFIG_SAVE_EXACT      true
  write_env NPM_CONFIG_FUND            false
  write_env NPM_CONFIG_UPDATE_NOTIFIER false
  # NPM_CONFIG_MIN_RELEASE_AGE stays exported, unlike pnpm's variable (see
  # harden_pnpm), although it also outranks a project's own .npmrc in both
  # directions. The files below are not always read: actions/setup-node with
  # registry-url writes its own .npmrc under RUNNER_TEMP and exports
  # NPM_CONFIG_USERCONFIG at it (src/authutil.ts, CHECKED 2026-11-22), so npm
  # skips ~/.npmrc, and a setup-node npm reads its prefix's etc/npmrc, not
  # /etc/npmrc. In that setup the env var is the only age gate npm sees.
  write_env NPM_CONFIG_MIN_RELEASE_AGE "$NPM_AGE_DAYS"
  # allow-git=none needs the env form for the same reason. Written only to the
  # files below, it was not applied under setup-node's redirect: npm 11.19.1
  # reported allow-git=all there and installed a git dependency (MEASURED
  # 2026-11-22 with this script's own files in place). Unlike the age window it
  # is an on/off switch at its strictest value, so a project can lose nothing
  # to it; a project's own .npmrc allow-git=all no longer re-enables git
  # dependencies (the variable outranks it, MEASURED on npm 11.9.0 to 12.2.3).
  # Version-gated: npm reads allow-git from 11.9.0, and npm 11.2.0 to 11.8.x
  # print `npm warn Unknown env config "allow-git"` on every command when it
  # is set (MEASURED). An npm not found yet is assumed current, as for the age
  # gate below.
  if [[ -z "$npm_v" ]] || version_ge "$npm_v" "11.9.0"; then
    write_env NPM_CONFIG_ALLOW_GIT none
  fi

  local content
  content=$(npm_settings "$NPM_AGE_DAYS")

  # Merged, never replaced: it is where `npm login` keeps its token.
  put_user_cfg npmrc "$HOME/.npmrc" <<<"$content"
  echo "$content" | write_etc /etc/npmrc

  HARDENED+=("npm")
  set_tool_version "npm" "$npm_v"
  # SAY IT HERE, NOT ONLY IN THE VERIFIER.
  #
  # min-release-age landed in npm 11.10.0. Older npm ACCEPTS the key, echoes
  # it back from `npm config get`, and enforces nothing — so the line below
  # would otherwise claim an age gate that does not exist. GitHub's
  # ubuntu-24.04 runners ship npm 10.9.8, which means the default runner is
  # the inert case.
  #
  # The version is already in hand from detect_version, so this costs nothing.
  # Leaving it to `action/verify.sh` put the truth behind an opt-in step, while
  # the mandatory tool asserted the opposite.
  if [[ -n "$npm_v" ]] && ! version_ge "$npm_v" "11.9.0"; then
    log "npm: allow-git=none written to the npmrc files, but npm $npm_v predates it (npm 11.9.0), so git dependencies still install; NPM_CONFIG_ALLOW_GIT not exported"
  fi
  if [[ -n "$npm_v" ]] && ! version_ge "$npm_v" "11.10.0"; then
    warn "npm $npm_v does NOT implement min-release-age (added in npm 11.10.0) — the age gate is written and NOT enforced. Script blocking is unaffected. Install npm >= 11.10 before this action (e.g. setup-node 24, or npm i -g npm@latest) to make it effective."
    set_eco_status npm INERT "age gate written but npm $npm_v does not implement min-release-age; script blocking still applies"
    log "npm: ignore-scripts=true (age gate written but INERT on npm $npm_v)"
  else
    log "npm: ignore-scripts=true, min-release-age=${NPM_AGE_DAYS}d"
  fi
  end_section
}

harden_pnpm() {
  section "pnpm"
  mkdir -p "$HOME/.config/pnpm"

  # Parse pnpm_built_dependencies input (comma-separated allowlist).
  # When non-empty: switch from blanket ignore-scripts=true to
  # onlyBuiltDependencies semantic — listed packages CAN run build
  # scripts, everything else is blocked. Mirrors role's pnpm_built_dependencies.
  local -a pnpm_allowlist=()
  if [[ -n "$PNPM_BUILT_DEPENDENCIES" ]]; then
    # Reject control chars in the raw input. bash's `read -ra <<<` truncates
    # at newline, so without this check a multi-line input would silently
    # drop everything after the first \n. Fail loud instead.
    #
    # NOTE: grep '[[:cntrl:]]' won't match newlines — grep reads line-by-line
    # so the newline is consumed as line separator before pattern matching.
    # Use bash globbing instead which sees the raw string.
    if [[ "$PNPM_BUILT_DEPENDENCIES" == *$'\n'* || \
          "$PNPM_BUILT_DEPENDENCIES" == *$'\r'* || \
          "$PNPM_BUILT_DEPENDENCIES" == *$'\t'* ]]; then
      err "pnpm_built_dependencies must not contain control characters (newlines, tabs, CR). Use comma-separated format: 'esbuild,sharp'"
      exit 2
    fi
    IFS=',' read -ra _raw_pkgs <<< "$PNPM_BUILT_DEPENDENCIES"
    for pkg in "${_raw_pkgs[@]}"; do
      pkg=$(echo "$pkg" | xargs)  # trim whitespace
      [[ -z "$pkg" ]] && continue
      # Validate: package names are letters/digits/underscore/period/hyphen/slash, optional @scope prefix.
      # Same regex as role's tasks/pnpm.yml. Reject anything else (special
      # chars, shell metacharacters) — defense against injection into the
      # deployed config file.
      if ! [[ "$pkg" =~ ^@?[a-zA-Z0-9_./-]+$ ]]; then
        err "pnpm_built_dependencies entry '$pkg' contains invalid characters; refusing to deploy"
        exit 2
      fi
      pnpm_allowlist+=("$pkg")
    done
  fi

  # pnpm 11+ format (YAML, camelCase). This is the load-bearing file
  # for pnpm 11 — it ignores ~/.npmrc, ~/.config/pnpm/rc (the older
  # ini-format file), and /etc/npmrc for non-auth settings.
  #
  # THE ALLOWLIST IS NOT WRITTEN HERE. No pnpm version builds a package because
  # this global file lists it: pnpm 10 reads the rc below, and pnpm 11 and 12
  # ignore onlyBuiltDependencies here (MEASURED on 11.0.0, 11.28.12, 12.21.0:
  # ERR_PNPM_IGNORED_BUILDS). `allowBuilds` is rejected in this file too, so on
  # pnpm 11+ there is no global allowlist at all; it has to be the project's
  # pnpm-workspace.yaml. Writing the list anyway was not just inert: a scoped
  # name went out unquoted (`  - @scope/pkg`), which is invalid YAML, and every
  # pnpm 11.0.0 command (even --version) then failed to load its config.
  #
  # `ignoreScripts: false` with an allowlist is NOT a fail-open: pnpm 10+
  # default-denies dependency build scripts regardless (the approve-builds
  # gate), and false is what lets a project's allowBuilds take effect. It does
  # let the project's own lifecycle scripts run (MEASURED on pnpm 11.28.12 and
  # 12.21.0); the role's pnpm-config.yaml.j2 makes the same trade.
  {
    echo "# Managed by supply-chain-harden action"
    if [[ ${#pnpm_allowlist[@]} -gt 0 ]]; then
      echo "ignoreScripts: false"
    else
      echo "ignoreScripts: true"
    fi
    echo "minimumReleaseAge: $PNPM_AGE_MINUTES"
    echo "minimumReleaseAgeStrict: $STRICT"
    echo "minimumReleaseAgeExclude: []"
    echo "blockExoticSubdeps: true"
    # Store integrity: hash-checks the store against the lockfile. Readable
    # from the global config, unlike onlyBuiltDependencies.
    # preferFrozenLockfile is deliberately NOT written: pnpm defaults it to
    # true, and an explicit value turns OFF pnpm's own CI frozen-lockfile
    # default on pnpm 11 before 11.28.1 and 12 before 12.8.0 (MEASURED with
    # CI=true and an out-of-sync lockfile: the lockfile was rewritten).
    echo "verifyStoreIntegrity: true"
  } | put_user_cfg pnpm-yaml "$HOME/.config/pnpm/config.yaml"

  # pnpm 10 format (ini, kebab-case). Belt-and-suspenders so we cover
  # both major versions; pnpm 10 still reads this file.
  {
    echo "; Managed by supply-chain-harden action"
    echo "minimum-release-age=$PNPM_AGE_MINUTES"
    echo "minimum-release-age-strict=$STRICT"
    echo "block-exotic-subdeps=true"
    if [[ ${#pnpm_allowlist[@]} -gt 0 ]]; then
      echo "ignore-scripts=false"
      for pkg in "${pnpm_allowlist[@]}"; do
        echo "only-built-dependencies[]=$pkg"
      done
    else
      echo "ignore-scripts=true"
    fi
  } | put_user_cfg pnpm-rc "$HOME/.config/pnpm/rc"

  # NO pnpm_config_* VARIABLES ARE EXPORTED HERE, although the role exports two.
  # pnpm 11+ reads pnpm_config_* from the environment, and that outranks a
  # project's pnpm-workspace.yaml, which outranks the config.yaml above
  # (MEASURED on 11.0.0, 11.0.9, 11.28.13 and 12.21.0). On a host the repository
  # may be one someone cloned, so the role's values win over its workspace file.
  # In CI the repository is the project being built, so its own choices stand:
  #   - pnpm_config_minimum_release_age would set the window exactly, in both
  #     directions, so a project that chose a longer one (14 days is common
  #     advice) would silently get the action's shorter one. config.yaml above
  #     still gives the action's window to a project that sets none, and
  #     nothing redirects it: with NPM_CONFIG_USERCONFIG pointed elsewhere, as
  #     actions/setup-node does for registry-url, pnpm 11.28.13 and 12.21.0
  #     still refused a 14-hour-old release (ERR_PNPM_NO_MATURE_MATCHING_VERSION;
  #     MEASURED 2026-11-22, with a gate-0 control that installed it). npm is
  #     different; see NPM_CONFIG_MIN_RELEASE_AGE in harden_npm.
  #   - pnpm_config_minimum_release_age_exclude would wipe the project's own
  #     list, and a monorepo exempting its own freshly published packages would
  #     fail with ERR_PNPM_MINIMUM_RELEASE_AGE_VIOLATION and no knob here.
  #   - pnpm_config_ignore_scripts is exported by neither: true silently skips
  #     the builds a project approves with its own ignoreScripts: false +
  #     allowBuilds, and false would override a project's own ignoreScripts: true.
  # A workspace minimumReleaseAge: 0 is the project's call. verify.sh, run from
  # the checkout, reports it in its "pnpm repo config override" row, as it does
  # a repo's uv and composer config.

  HARDENED+=("pnpm")
  local pnpm_version
  pnpm_version=$(detect_version pnpm "pnpm --version")
  set_tool_version "pnpm" "$pnpm_version"
  if [[ ${#pnpm_allowlist[@]} -gt 0 ]]; then
    log "pnpm: onlyBuiltDependencies=[${pnpm_allowlist[*]}] (pnpm 10 rc), minimumReleaseAge=${PNPM_AGE_MINUTES}m"
    if [[ -z "$pnpm_version" ]] || version_ge "$pnpm_version" "11.0.0"; then
      warn "pnpm_built_dependencies takes effect on pnpm 10 only. pnpm ${pnpm_version:-11+} has no global build allowlist: add the packages to the project's pnpm-workspace.yaml as allowBuilds (e.g. 'allowBuilds: {${pnpm_allowlist[0]}: true}'), or their install fails with ERR_PNPM_IGNORED_BUILDS"
    fi
  else
    log "pnpm: ignoreScripts=true (blanket block), minimumReleaseAge=${PNPM_AGE_MINUTES}m"
  fi
  end_section
}

harden_yarn() {
  section "yarn"
  local yarn_version
  yarn_version=$(detect_version yarn "yarn --version")
  # enableHardenedMode is Yarn 4.0+. Silently ignored on older yarn; we
  # could emit unconditionally but yarn 3.x warns on unknown keys.
  local has_hardened=true
  if [[ -n "$yarn_version" ]] && ! version_ge "$yarn_version" "4.0.0"; then
    has_hardened=false
  fi

  _yarn_config() {
    echo "# Managed by supply-chain-harden action"
    echo "npmMinimalAgeGate: $YARN_AGE"
    echo "enableScripts: false"
    echo "defaultSemverRangePrefix: \"\""
    echo "enableTelemetry: false"
    echo "enableImmutableInstalls: true"
    echo "enableImmutableCache: false"   # true fails every cold-cache install (YN0056); see the role default
    echo "checksumBehavior: throw"
    # Empty allowlist = no host may be fetched over plain HTTP. yarn treats an
    # absent key as "no restriction", so emitting [] is what closes it.
    echo "unsafeHttpWhitelist: []"
    if [[ "$has_hardened" == "true" ]]; then
      echo "enableHardenedMode: true"
    fi
  }
  local yarn_body
  yarn_body=$(_yarn_config)
  put_user_cfg yarn "$HOME/.yarnrc.yml" <<<"$yarn_body"

  # Root's ~/.yarnrc.yml, not /etc/yarnrc.yml: Yarn Berry reads no system-wide
  # file (MEASURED on 4.9.4, 4.10.3, 4.11.0 and 4.18.1: settings in
  # /etc/yarnrc.yml never took effect, and the bundles name no /etc path), and
  # on Linux sudo sets HOME=/root (MEASURED: sudo 1.9.13p3 on Debian 12,
  # 1.9.15p5 on Ubuntu 24.04), so this is the file a later `sudo yarn` step
  # reads. See tasks/yarn.yml. Root's home from the passwd database: /var/root
  # on macOS. Root's own file is in use for `sudo yarn` and may hold a registry
  # and its token, so it is judged and kept by the same rule as the user's, as
  # root. An /etc/yarnrc.yml an earlier version wrote is removed; anyone else's is
  # left alone.
  local root_home
  root_home=~root
  case "$root_home" in /*) ;; *) root_home="" ;; esac
  if [[ "$WRITE_ETC" == "true" ]] && can_write /etc/yarnrc.yml && $SUDO test -f /etc/yarnrc.yml \
     && $SUDO grep -qE 'Managed by (ansible-supply-chain-security|supply-chain-harden)' /etc/yarnrc.yml 2>/dev/null; then
    $SUDO rm -f /etc/yarnrc.yml && log "yarn: removed /etc/yarnrc.yml, which an earlier version wrote and Yarn never reads"
  fi
  if [[ "$WRITE_ETC" == "true" && -n "$root_home" && "$root_home" != "$HOME" ]]; then
    if [[ "${CAN_ESCALATE:-0}" -eq 1 ]]; then
      PUT_AS_ROOT=1 put_user_cfg yarn "$root_home/.yarnrc.yml" <<<"$yarn_body"
    else
      warn "cannot write $root_home/.yarnrc.yml (no root and no usable sudo) — per-user config still applies, but a later \`sudo\` step will not see it"
    fi
  fi

  HARDENED+=("yarn")
  set_tool_version "yarn" "$yarn_version"
  # SAY IT HERE, NOT ONLY IN THE VERIFIER — the npm rule above, for yarn.
  #
  # npmMinimalAgeGate arrived in Yarn 4.10.0. Older Berry ignores the key in
  # ~/.yarnrc.yml without a word (MEASURED: 4.1.0, the apt yarnpkg on Debian 13
  # and Ubuntu 26.04, and 4.9.4: exit 0, no warning), and Yarn 1.x (classic)
  # never reads .yarnrc.yml at all. This used to report yarn as "Fully
  # applied" on 4.1.0 while a release 13 hours old installed (VM#10).
  if [[ -n "$yarn_version" ]] && ! version_ge "$yarn_version" "2.0.0"; then
    warn "yarn $yarn_version is Yarn 1.x (classic), which never reads .yarnrc.yml — none of the yarn settings are in force: no age gate and no enableScripts. Yarn 4.10 or later is needed."
    set_eco_status yarn NONE "yarn $yarn_version is classic and never reads .yarnrc.yml; nothing written for yarn is in force"
    log "yarn: .yarnrc.yml written but NOT read by yarn $yarn_version (classic)"
  elif [[ -n "$yarn_version" ]] && ! version_ge "$yarn_version" "4.10.0"; then
    warn "yarn $yarn_version does NOT implement npmMinimalAgeGate (added in Yarn 4.10.0) — the age gate is written and NOT enforced. enableScripts=false still applies. Install Yarn 4.10 or later before this step to make it effective."
    set_eco_status yarn INERT "age gate written but yarn $yarn_version does not implement npmMinimalAgeGate (Yarn 4.10.0); enableScripts=false still applies"
    log "yarn: enableScripts=false (age gate written but INERT on yarn $yarn_version)$([[ "$has_hardened" == "true" ]] && echo ", enableHardenedMode=true")"
  else
    log "yarn: enableScripts=false, npmMinimalAgeGate=${YARN_AGE}$([[ "$has_hardened" == "true" ]] && echo ", enableHardenedMode=true")"
  fi
  end_section
}

harden_pip() {
  section "pip"
  write_env PIP_DISABLE_PIP_VERSION_CHECK 1
  write_env PYTHONDONTWRITEBYTECODE       1
  # pip 26.0+ native age gate. Shares uv's cutoff deliberately: one clock for
  # both Python gates. Accepted and inert on every pre-26 pip (MEASURED across
  # ten versions), so it ships unconditionally. UV_EXCLUDE_NEWER is guaranteed
  # non-empty and Z-suffixed here -- the computation above hard-exits on failure,
  # which matters because a MALFORMED value makes pip >= 26 exit 2 on every
  # install for every user on the host.
  write_env PIP_UPLOADED_PRIOR_TO         "$UV_EXCLUDE_NEWER"
  # Poetry reads neither pip.conf nor uv.toml (MEASURED on 2.5.1), so it needs its
  # own gate. The env var outranks a repo's poetry.toml. The file is only created,
  # never edited: it is the user's whole Poetry config, and a second [solver] table
  # would be invalid TOML.
  write_env POETRY_SOLVER_MIN_RELEASE_AGE "$POETRY_AGE_DAYS"
  local poetry_cfg="${POETRY_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/pypoetry}/config.toml"
  if [[ ! -e "$poetry_cfg" ]]; then
    mkdir -p "$(dirname "$poetry_cfg")"
    printf '[solver]\nmin-release-age = %s\n' "$POETRY_AGE_DAYS" > "$poetry_cfg"
  fi
  local poetry_version
  poetry_version=$(detect_version poetry "poetry --version")
  if [[ -n "$poetry_version" ]] && ! version_ge "$poetry_version" "2.4.0"; then
    notice "poetry $poetry_version has no solver.min-release-age (MEASURED: added in 2.4.0), and it reads neither pip.conf nor uv.toml, so it is not age-gated on this runner."
  fi

  mkdir -p "$HOME/.config/pip"
  put_user_cfg pip "$HOME/.config/pip/pip.conf" <<EOF
; Managed by supply-chain-harden action
[global]
disable-pip-version-check = true
; pip's native age gate (pip 26.0+; accepted and inert below that). MUST be
; under [global]: under [install] it does not cover \`pip download\`,
; \`pip wheel\` or \`pip index\`.
uploaded-prior-to = $UV_EXCLUDE_NEWER

[install]
; Refuse sdists — blocks the March-2026 LiteLLM / BufferZoneCorp-class attack
; (NOT the October-2026 LiteLLM wheel-startup-hook compromise)
; where setup.py executes arbitrary code at install time.
only-binary = :all:
EOF

  cat <<EOF | write_etc /etc/pip.conf
; Managed by supply-chain-harden action
[global]
disable-pip-version-check = true
uploaded-prior-to = $UV_EXCLUDE_NEWER

[install]
only-binary = :all:
EOF

  HARDENED+=("pip")
  set_tool_version "pip" "$(detect_version pip "pip --version")"
  log "pip: only-binary=:all: (refuses sdist setup.py execution), uploaded-prior-to=$UV_EXCLUDE_NEWER (pip 26.0+ age gate)"
  end_section
}

harden_uv() {
  section "uv"
  write_env UV_LINK_MODE copy
  # UV_EXCLUDE_NEWER IS DELIBERATELY NOT EXPORTED, although it would outrank a
  # repository's own exclude-newer (the role exports it only when
  # uv_exclude_newer_env is set). It also outranks a project that pins an
  # earlier exclude-newer so that its uv.lock checks clean everywhere, and uv
  # records the cutoff in uv.lock. MEASURED (pyproject pinning 2024-05-01, host
  # cutoff 2024-10-01): on uv 0.8.17, 0.11.16 and 0.12.7 that project's
  # `uv sync --locked` fails with it set and passes without it; on 0.13.9 a
  # lockfile written with it set fails `--locked` wherever it is not. A CI job
  # is where `--locked` runs. Projects with no exclude-newer of their own
  # behaved the same either way. See docs/limitations.md.

  # WHERE THE USER-LEVEL uv.toml LIVES — resolved from uv's environment, never
  # hardcoded. uv's user config is $XDG_CONFIG_HOME/uv/uv.toml and falls back
  # to $HOME/.config/uv/uv.toml only when XDG_CONFIG_HOME is unset. MEASURED:
  # with uv.toml written to $HOME/.config/uv while XDG_CONFIG_HOME pointed
  # elsewhere, `uv --show-settings` reports no_build: None — uv read nothing of
  # ours, and the old verifier row still said OK because the checker shared the
  # writer's wrong assumption. docs/design-principles.md Axis 5, "Assumed
  # canonical config homes".
  # NOT MEASURED, per uv's documentation only: UV_CONFIG_FILE / --config-file
  # names an explicit uv.toml that overrides the discovered user config. We do
  # not write to it (it is a caller-owned path); a runner that sets it is not
  # covered by the file we write here.
  local uv_config_dir
  uv_config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/uv"

  mkdir -p "$uv_config_dir"
  put_user_cfg uv "$uv_config_dir/uv.toml" <<EOF
# Managed by supply-chain-harden action
exclude-newer = "$UV_EXCLUDE_NEWER"
no-build = true
index-strategy = "first-index"
allow-insecure-host = []

[pip]
verify-hashes = true
EOF

  cat <<EOF | write_etc /etc/uv/uv.toml
# Managed by supply-chain-harden action
exclude-newer = "$UV_EXCLUDE_NEWER"
no-build = true
index-strategy = "first-index"
allow-insecure-host = []

[pip]
verify-hashes = true
EOF

  HARDENED+=("uv")
  set_tool_version "uv" "$(detect_version uv "uv --version")"
  log "uv: exclude-newer='$UV_EXCLUDE_NEWER', no-build=true, index-strategy=first-index (user config at $uv_config_dir/uv.toml)"
  end_section
}

harden_composer() {
  section "composer"

  local composer_version
  # --no-plugins, and the home lookup below runs from an empty directory:
  # MEASURED on composer 2.11.2, run with a checkout as the working directory
  # (the GitHub workspace), `composer --version` activated the plugin that
  # checkout's allow-plugins enables, and `composer config --global home` also
  # ran its root "pre-command-run" script, before any wrapper existed.
  # The version probe also gives composer no project (COMPOSER names a file that
  # cannot exist; reading a version needs none, and a step that only looks must
  # not boot the checkout it runs in), and both probes run with
  # COMPOSER_ALLOW_SUPERUSER=1 and -n, so a root run on a terminal does not stop
  # at composer's hidden "Continue as root/super user?" prompt. See the composer
  # version probe in files/verify-probes.sh.
  composer_version=$(COMPOSER=/dev/null/composer.json COMPOSER_ALLOW_SUPERUSER=1 \
    detect_version composer "composer --version --no-ansi --no-plugins --no-interaction")
  # Tier-render:
  #   composer >= 2.9 : audit.block-insecure + block-abandoned + abandoned=fail
  #   composer 2.7-2.8: audit.abandoned=fail only
  #   composer < 2.7  : no audit block (audit key added in 2.7.0)
  #   undetected      : same as < 2.7 (safe baseline)
  local has_audit=false has_block=false
  if [[ -n "$composer_version" ]]; then
    version_ge "$composer_version" "2.7.0" && has_audit=true
    version_ge "$composer_version" "2.9.0" && has_block=true
  fi

  # allow-plugins is tiered SEPARATELY, on 2.2.15.
  #
  # MEASURED (composer 2.0.14 -> 2.10.3, 16 phars): "allow-plugins": false is
  # a HARD FATAL below 2.2.15 —
  #     PHP Fatal error: Uncaught TypeError: array_merge():
  #     Argument #1 must be of type array, false given
  # exit 255 on install / config / dump-autoload, i.e. everything except
  # --version. Ubuntu 22.04 ships composer 2.2.6, so writing the literal
  # false bricked composer on every jammy runner. `{}` — the empty allowlist
  # — is accepted by 2.2.6 AND blocks every plugin just the same, so it is
  # what we emit below 2.2.15 and whenever the version is undetected.
  # (allow-plugins only exists from 2.2.0 at all; below that the key is inert
  # either way and --no-plugins in the wrapper is the layer doing the work.)
  # ALWAYS {} when denying, with NO version predicate. `false` is a hard fatal
  # (array_merge(): Argument #1 must be of type array, bool given -> exit 255)
  # and the fix was NOT backported linearly:
  #   2.2.6 FATAL   2.2.14 FATAL   2.2.15 safe   2.2.16 safe
  #   2.3.0 FATAL   2.3.5 FATAL    2.3.7 FATAL   2.3.8 safe   2.4.0+ safe
  # So a `>= 2.2.15` predicate emits the bricking value across 2.3.0-2.3.7,
  # because 2.3.0 sorts ABOVE 2.2.15 while predating the fix. MEASURED: {}
  # returns rc 0 on every version 2.2.6 -> 2.10.3 and still refuses plugins,
  # so the tier bought nothing and could only ever be wrong. Deleting the
  # predicate deletes the whole bug class.
  local allow_plugins_json="{}"
  if [[ "$COMPOSER_ALLOW_PLUGINS" == "true" ]]; then
    allow_plugins_json="true"
  fi

  local composer_body composer_base
  _composer_config() {
    echo "{"
    echo "  \"config\": {"
    echo "    \"secure-http\": true,"
    echo "    \"lock\": true,"
    echo "    \"preferred-install\": \"dist\","
    if [[ "$has_audit" == "true" ]]; then
      echo "    \"allow-plugins\": $allow_plugins_json,"
      echo "    \"audit\": {"
      if [[ "$has_block" == "true" ]]; then
        echo "      \"abandoned\": \"fail\","
        echo "      \"block-insecure\": true,"
        echo "      \"block-abandoned\": true"
      else
        echo "      \"abandoned\": \"fail\""
      fi
      echo "    },"
    else
      echo "    \"allow-plugins\": $allow_plugins_json,"
    fi
    # The publish-age gate is written on every version: MEASURED 2.0.9 -> 2.10.3
    # ignore it with exit 0, and it enforces from 2.11.0. It does not disturb the
    # audit block above (MEASURED on 2.11.1, see templates/composer-config.json.j2).
    echo "    \"policy\": {"
    echo "      \"cooldown\": {"
    echo "        \"period\": $COMPOSER_COOLDOWN_SECONDS,"
    echo "        \"block\": true"
    echo "      }"
    echo "    }"
    echo "  }"
    echo "}"
  }
  composer_body=$(_composer_config)
  # auth.json, where composer keeps tokens, is neither read nor written here.
  composer_base=$(ucf_composer_base)
  mkdir -p "$composer_base"
  put_user_cfg composer "$composer_base/config.json" <<<"$composer_body"

  # That directory is not where composer reads on every host: with no XDG_*
  # variable set it was ~/.composer (MEASURED), which left the file above unread
  # and the audit keys off. Worked out by composer's own rule, as the role does, not
  # by asking composer: `composer config --global home` writes into the home it is
  # asked about (see tasks/composer.yml).
  local composer_home
  if command -v composer >/dev/null 2>&1; then
    composer_home=$(ucf_path composer-home)
    if [[ -n "$composer_home" ]]; then
      mkdir -p "$(dirname "$composer_home")"
      put_user_cfg composer-home "$composer_home" <<<"$composer_body"
    fi
  fi

  HARDENED+=("composer")
  set_tool_version "composer" "$composer_version"

  # COMPOSER_SKIP_SCRIPTS env var: belt-and-suspenders for `php composer.phar`
  # callers that bypass the wrapper but inherit the action's env.
  #
  # MEASURED: honoured from composer 2.8.6 — ignored on 2.2.6, 2.7.1, 2.8.4 and
  # 2.8.5 (every script ran with it set), honoured on 2.8.6+. (This comment said "2.9+" before; the number
  # was wrong and it was the number everyone cited.) On 2.2-2.7 the var is
  # inert, so the notice below says so instead of leaving an env var in the
  # log that reads as coverage.
  write_env COMPOSER_SKIP_SCRIPTS \
    "pre-install-cmd,post-install-cmd,pre-update-cmd,post-update-cmd,pre-autoload-dump,post-autoload-dump,post-root-package-install,post-create-project-cmd,pre-package-install,post-package-install,pre-package-update,post-package-update,pre-package-uninstall,post-package-uninstall,pre-command-run"
  # No COMPOSER_ALLOW_SUPERUSER here: the wrapper sets it for its own run only.
  # In the job's environment it switched off composer's root guard for every
  # caller that bypasses the wrapper (MEASURED 2.7.1/2.11.2: without it a
  # non-interactive root run disables plugins; with it a checkout-allowed plugin
  # ran). See templates/supply-chain-env.sh.j2.
  # The env form outranks a checked-out composer.json (MEASURED on 2.11.1: a
  # repo's "period": null or "block": false turns off the config.json gate and
  # not these). A repo's "ignore" list still wins; verify.sh reports that.
  write_env COMPOSER_POLICY_COOLDOWN_PERIOD "$COMPOSER_COOLDOWN_SECONDS"
  write_env COMPOSER_POLICY_COOLDOWN_BLOCK  1

  if [[ -n "$composer_version" ]] && ! version_ge "$composer_version" "2.11.0"; then
    notice "composer $composer_version ignores config.policy.cooldown (MEASURED: added in 2.11.0), so the publish-age gate is written and NOT enforced on this runner. Install a current composer before this step to activate it."
  fi

  if [[ -n "$composer_version" ]] && ! version_ge "$composer_version" "2.8.6"; then
    notice "composer $composer_version ignores COMPOSER_SKIP_SCRIPTS (MEASURED: honoured from 2.8.6). The env-var backup layer is INERT on this runner — the PATH wrapper below is the only thing blocking composer scripts, and \`php composer.phar\` callers that bypass it are not covered."
  fi

  # PATH wrapper at the DISCOVERED composer location (wrap in-place —
  # same fix as bun). Wrapping at /usr/local/bin/composer breaks when
  # composer is installed elsewhere (e.g., /usr/bin/composer via apt)
  # because the user's PATH might resolve apt composer first.
  local real_composer
  real_composer=$(command -v composer 2>/dev/null || true)
  if [[ -z "$real_composer" ]]; then
    log "composer not installed — wrapper not deployed (config still written)"
    # composer's script blocking is wrapper-only; the config covers plugins
    # and secure-http but not --no-scripts.
    set_eco_status composer PARTIAL "config written; script blocking needs the wrapper, and composer was not installed"
    end_section
    return 0
  fi

  local wrapper_target="$real_composer"
  require_privilege composer "$wrapper_target" || { end_section; return 0; }
  if grep -q "supply-chain-harden" "$real_composer" 2>/dev/null; then
    if [[ -x "${real_composer}-real" ]]; then
      real_composer="${real_composer}-real"
    else
      warn "composer wrapper present at $wrapper_target but ${wrapper_target}-real missing; skipping re-wrap"
      end_section
      return 0
    fi
  else
    $SUDO mv "$real_composer" "${real_composer}-real"
    real_composer="${real_composer}-real"
  fi

  local inject_no_plugins=true
  [[ "$COMPOSER_ALLOW_PLUGINS" == "true" ]] && inject_no_plugins=false

  # --no-scripts IS NOT AN APPLICATION-LEVEL OPTION ON COMPOSER <= 2.1.
  # MEASURED (2.0.14 -> 2.10.3): on 2.0/2.1 only install, update, require,
  # remove, dump-autoload, create-project and reinstall (2.1) declare it
  # (`composer list --format=json` on 2.1.14), so a wrapper that injects it
  # unconditionally makes `composer show`, `composer config` and
  # `composer diagnose` die with
  #     The "--no-scripts" option does not exist.
  # It became global in composer 2.2.0. Inject unconditionally at or above
  # that; below it (and when the version is undetected — safe baseline) the
  # wrapper injects only for the subcommands that declare it.
  # --no-plugins IS application-level on 2.0/2.1 and is always injected.
  local no_scripts_is_global=false
  if [[ -n "$composer_version" ]] && version_ge "$composer_version" "2.2.0"; then
    no_scripts_is_global=true
  fi

  # Two heredocs: the first is UNQUOTED and carries only the values decided
  # here; the second is QUOTED, so the wrapper's own $variables, $(...) and
  # backticks reach the file as written (tests/ci/heredoc-scan.py). The body
  # is the same logic as templates/composer-wrapper.sh.j2.
  {
    cat <<EOF
#!/bin/bash
# Managed by supply-chain-harden action
#
# --no-scripts is an application-level option only from composer 2.2.0
# (MEASURED 2.0.14 -> 2.10.3). NO_SCRIPTS_IS_GLOBAL below was rendered from
# the composer version detected when this wrapper was written
# (${composer_version:-undetected}); when it is false the wrapper injects
# --no-scripts only for the commands that declare it on 2.0/2.1 (install,
# update, require, remove, dump-autoload, create-project, reinstall), under any
# alias or unique prefix of their names, because injecting it elsewhere there
# fails with
#     The "--no-scripts" option does not exist.
REAL_COMPOSER='$real_composer'
WRAPPER_PATH='$wrapper_target'
NO_SCRIPTS_IS_GLOBAL=$no_scripts_is_global
# false when the composer_allow_plugins input is true.
INJECT_NO_PLUGINS=$inject_no_plugins
COOLDOWN_SECONDS=$COMPOSER_COOLDOWN_SECONDS
EOF
    cat <<'EOF'
#
# LIFECYCLE SCRIPTS ARE BLOCKED; A SCRIPT YOU ASK FOR BY NAME RUNS.
# Composer only ever runs scripts from the ROOT composer.json, never a
# dependency's; dependency code reaches composer through plugins, which
# --no-plugins and allow-plugins block separately. Lifecycle events
# (post-install-cmd, post-update-cmd, post-autoload-dump, pre-command-run, ...)
# fire as a side effect of install, update, require and the rest, and get
# --no-scripts. `composer run-script <name>`, `composer run <name>` and
# `composer <name>` for a name under "scripts" are explicit runs, like
# `npm test`, and get none: --no-scripts does not refuse them, it empties them.
# MEASURED on composer 2.2.6 -> 2.11.2: `composer test` exited 0 having run
# nothing, and `composer run-script test` said 'Script "test" is not defined'.
# A name counts as a script only when it is a "scripts" key (or one of its
# "scripts-aliases") in the composer.json composer will read AND is not a
# built-in command or a script event name; composer never lets a script shadow
# a built-in, so a checkout with a script called "install" still gets
# `composer install --no-scripts`. A name that is a script AND a prefix of a
# built-in (`req`, `upd`, `check`), or a "scripts-aliases" alias spelled like a
# built-in (`i`, `upgrade`), is refused: composer runs the script there
# (MEASURED on 2.7.1 and 2.11.2) although the caller typed a built-in.
# Full reasoning: templates/composer-wrapper.sh.j2.

# RUN-PROBE. Record that this wrapper actually executed.
#
# Costs nothing on a real invocation: SCH_WRAPPER_PROBE is unset, so this is
# one test. verify.sh sets it to a temp file, invokes the tool, and reads back
# which wrappers ran.
#
# It replaces inferring "did our wrapper run" from PATH position, which CANNOT
# distinguish a wrapper that was bypassed from one that is chained behind
# another wrap. MEASURED: with an Aikido safe-chain shim first on PATH, the
# wrapper ran on every call and the verifier reported "shadowed and never
# runs" at FUNCTIONAL strength -- the strongest evidence grade, asserting the
# opposite of the fact.
#
# The value is caller-controlled, so it is only ever a redirect target. Never
# interpolate it into a command.
if [ -n "${SCH_WRAPPER_PROBE:-}" ]; then
  printf '%s\n' "$0" >> "$SCH_WRAPPER_PROBE" 2>/dev/null || true
fi

if [ -z "$REAL_COMPOSER" ] || [ ! -x "$REAL_COMPOSER" ] || [ "$REAL_COMPOSER" = "$WRAPPER_PATH" ]; then
  echo "[supply-chain-harden] error: real composer not found at '$REAL_COMPOSER'; refusing to recurse" >&2
  exit 127
fi
# Only here, not in the job's environment: wrapped runs carry --no-plugins, and
# composer's own root guard (a non-interactive root run disables plugins) stays
# on for anything that bypasses this wrapper.
export COMPOSER_ALLOW_SUPERUSER=1
# Publish-age gate (composer >= 2.11.0). Set unconditionally so a step's own env
# cannot shorten the window; `composer --no-cooldown` still gets through, on
# purpose, as composer's escape hatch for an urgent fix.
export COMPOSER_POLICY_COOLDOWN_PERIOD="$COOLDOWN_SECONDS"
export COMPOSER_POLICY_COOLDOWN_BLOCK=1

# The subcommand is the first non-option token. -d/--working-dir is composer's
# only value-taking global option, so its value is not the subcommand; it is
# kept because it moves the composer.json composer reads. In a cluster of short
# options that ends in d (`-nd DIR`), d still takes the next token, but composer
# does not change directory for it (MEASURED on 2.5.5, 2.7.1 and 2.11.2:
# `composer -nd DIR test` ran the test script of the current directory), so
# that value is skipped and not kept.
SUBCOMMAND=""; WORKDIR=""; skip_next=0
for arg in "$@"; do
  if [ "$skip_next" = 1 ]; then skip_next=0; WORKDIR="$arg"; continue; fi
  if [ "$skip_next" = 2 ]; then skip_next=0; continue; fi
  case "$arg" in
    -d|--working-dir) skip_next=1; continue ;;
    --working-dir=*) WORKDIR="${arg#--working-dir=}"; continue ;;
    -d?*) WORKDIR="${arg#-d}"; continue ;;
    --*) continue ;;
    -?*d) case "${arg%d}" in *d*) ;; *) skip_next=2 ;; esac; continue ;;
    -*) continue ;;
  esac
  SUBCOMMAND="$arg"; break
done

# Every built-in command and alias of composer 2.1.14, 2.2.6, 2.5.5, 2.7.1,
# 2.8.8, 2.9.5 and 2.11.2 (MEASURED: `composer list --format=json --no-plugins`
# in an empty directory). A script cannot shadow one of these names.
# This is a fixed list, not an answer from the composer on this host. A built-in
# added after 2.11.2 is missing from it, so a project script of that name would
# not get --no-scripts while composer runs the built-in; and on a composer older
# than a name here (audit and bump on 2.2), a script of that name gets
# --no-scripts and runs nothing. Add new built-ins here when composer ships them.
BUILTIN_COMMANDS=' _complete about archive audit browse bump cc check-platform-reqs clear-cache clearcache completion config create-project depends diagnose dump-autoload dumpautoload exec fund global help home i info init install licenses list outdated policy prohibits r reinstall remove repo repository require rm run run-script search self-update selfupdate show status suggests u uninstall update upgrade validate why why-not '
# The twelve script event names (Composer\Script\ScriptEvents, identical in
# 2.1.14, 2.2.6 and 2.11.2). Composer never registers them as commands.
SCRIPT_EVENTS=' pre-install-cmd post-install-cmd pre-update-cmd post-update-cmd pre-status-cmd post-status-cmd pre-autoload-dump post-autoload-dump post-root-package-install post-create-project-cmd pre-archive-cmd post-archive-cmd '

# The built-ins whose name starts with $1, ignoring case: what composer's console
# resolves a name to when no command has exactly that name (a unique prefix,
# case-sensitive first, then case-insensitive).
builtins_starting_with() {
  local want b out=""
  want=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  for b in $BUILTIN_COMMANDS; do
    case "$b" in "$want"*) out="${out:+$out, }$b" ;; esac
  done
  printf '%s' "$out"
}

# The command composer runs for the built-in name $1 (an alias names its command).
canonical_builtin() {
  case "$1" in
    i) echo install ;;
    u|upgrade) echo update ;;
    r) echo require ;;
    rm|uninstall) echo remove ;;
    dumpautoload) echo dump-autoload ;;
    selfupdate) echo self-update ;;
    cc|clearcache) echo clear-cache ;;
    info) echo show ;;
    why) echo depends ;;
    why-not) echo prohibits ;;
    run) echo run-script ;;
    home) echo browse ;;
    repo) echo repository ;;
    *) echo "$1" ;;
  esac
}

# The built-in command composer runs for $1, resolved the way its console does:
# an exact name or alias, else the one command that every built-in starting with
# $1 belongs to. Prints nothing when composer would call $1 ambiguous or unknown
# (it then refuses to run anything).
builtin_command_for() {
  local b c one=""
  case "$BUILTIN_COMMANDS" in *" $1 "*) canonical_builtin "$1"; return 0 ;; esac
  for b in $(builtins_starting_with "$1" | tr -d ','); do
    c=$(canonical_builtin "$b")
    if [ -z "$one" ]; then one=$c
    elif [ "$one" != "$c" ]; then return 0
    fi
  done
  printf '%s\n' "$one"
}

# How the composer.json composer will read defines the name $1: prints "key"
# for a "scripts" key, "alias<TAB><key>" for a "scripts-aliases" alias of a
# key, and nothing otherwise. It finds the file the way composer does:
# $COMPOSER (default composer.json) in the -d directory or the current one, else
# the nearest parent below $HOME that has one (composer's use-parent-dir walk).
# It decodes it with json_decode, as composer does when it registers script
# commands, so the two read the same file the same way. php is whatever runs
# composer itself. Nothing is executed from the project.
root_script_def() {
  local f="${COMPOSER:-composer.json}" dir home
  case "$f" in
    /*) ;;
    *)
      if [ -n "$WORKDIR" ]; then
        f="$WORKDIR/$f"
      elif [ ! -e "$f" ]; then
        home=$(cd "${HOME:-/}" 2>/dev/null && pwd -P)
        dir=$(dirname "$(pwd -P)")
        while [ "$dir" != "/" ] && [ "$dir" != "$home" ]; do
          if [ -e "$dir/$f" ]; then f="$dir/$f"; break; fi
          dir=$(dirname "$dir")
        done
      fi ;;
  esac
  [ -f "$f" ] && [ -r "$f" ] || return 0
  php -r '
    $j = json_decode((string) file_get_contents($argv[1]), true);
    $n = $argv[2];
    if (!is_array($j) || !isset($j["scripts"]) || !is_array($j["scripts"])) exit(0);
    if (array_key_exists($n, $j["scripts"])) { echo "key\n"; exit(0); }
    if (!isset($j["scripts-aliases"]) || !is_array($j["scripts-aliases"])) exit(0);
    foreach ($j["scripts-aliases"] as $script => $aliases) {
      if (isset($j["scripts"][$script]) && in_array($n, (array) $aliases, true)) {
        echo "alias\t", preg_replace("/[[:cntrl:]]/", "?", (string) $script), "\n"; exit(0);
      }
    }' "$f" "$1" 2>/dev/null
}

# A name composer may run as a project script while the caller typed a built-in
# (see the header): refuse it, and say how to ask for each one unambiguously.
refuse_script_name() { # $1 = what the project defines it as, $2 = the built-in(s), $3 = the script
  echo "[supply-chain-harden] refusing 'composer $SUBCOMMAND': '$SUBCOMMAND' is $1 in this project's composer.json and also names composer's built-in '$2'. Composer would run the project's script, with scripts enabled, instead of the built-in. Run the script with 'composer run-script $3', or the built-in by its full name." >&2
  exit 2
}

EXPLICIT_SCRIPT=false
case "$SUBCOMMAND" in
  run-script|run) EXPLICIT_SCRIPT=true ;;
  '') ;;
  *)
    case "$SCRIPT_EVENTS" in *" $SUBCOMMAND "*) ;; *)
      SCRIPT_DEF=$(root_script_def "$SUBCOMMAND")
      case "$BUILTIN_COMMANDS" in
        *" $SUBCOMMAND "*)
          # composer skips a scripts KEY named after a built-in, not an alias
          case "$SCRIPT_DEF" in
            alias*) refuse_script_name "a scripts-aliases alias" "$SUBCOMMAND" "${SCRIPT_DEF#alias?}" ;;
          esac ;;
        *)
          case "$SCRIPT_DEF" in
            key|alias*)
              also=$(builtins_starting_with "$SUBCOMMAND")
              script="$SUBCOMMAND"; kind="a script"
              case "$SCRIPT_DEF" in alias*) script="${SCRIPT_DEF#alias?}"; kind="a scripts-aliases alias" ;; esac
              [ -z "$also" ] || refuse_script_name "$kind" "$also" "$script"
              EXPLICIT_SCRIPT=true ;;
          esac ;;
      esac ;;
    esac ;;
esac

FLAGS=()
if [ "$EXPLICIT_SCRIPT" = "true" ]; then
  :  # the caller named a root script: run it
elif [ "$NO_SCRIPTS_IS_GLOBAL" = "true" ]; then
  FLAGS+=(--no-scripts)
else
  # composer <= 2.1: only the commands that declare --no-scripts get it, on the
  # command composer resolves the name to. An alias or a unique prefix (`req`,
  # `upd`, `dump`) is the same command: MEASURED on 2.1.14, when only the full
  # names got it, those ran the root update and autoload-dump scripts.
  case "$(builtin_command_for "$SUBCOMMAND")" in
    install|update|require|remove|dump-autoload|create-project|reinstall)
      FLAGS+=(--no-scripts) ;;
  esac
fi
if [ "$INJECT_NO_PLUGINS" = "true" ]; then
  FLAGS+=(--no-plugins)
fi

exec "$REAL_COMPOSER" ${FLAGS[@]+"${FLAGS[@]}"} "$@"
EOF
  } | $SUDO tee "$wrapper_target" >/dev/null
  $SUDO chmod 755 "$wrapper_target"
  local wrap_desc="--no-scripts on every invocation except a script run by name"
  if [[ "$no_scripts_is_global" != "true" ]]; then
    wrap_desc="--no-scripts on install/update/require/remove/dump-autoload/create-project/reinstall only"
    notice "composer ${composer_version:-undetected} does not accept --no-scripts as a global option (MEASURED: it became one in 2.2.0). The wrapper injects it only for the commands that declare it there (install, update, require, remove, dump-autoload, create-project, reinstall, under any alias or abbreviation); every other command, exec included, runs WITHOUT it on this runner. Upgrade composer to >= 2.2 and re-run to close the gap."
  fi
  [[ "$COMPOSER_ALLOW_PLUGINS" == "true" ]] || wrap_desc="$wrap_desc, --no-plugins"
  log "composer: wrapper deployed at $wrapper_target ($wrap_desc)"
  record_wrapper composer
  end_section
}

harden_bun() {
  section "bun"

  local bun_version
  bun_version=$(detect_version bun "bun --version")

  # VERSION TIERING — MEASURED across bun 1.1.38 / 1.2.0 / 1.2.10 / 1.2.20 /
  # 1.2.22 / 1.2.23 / 1.3.0 / 1.4.0:
  #
  #   ignoreScripts      INERT below bun 1.2.0. The GLOBAL bunfig and a LOCAL
  #                      bunfig are BOTH ignored there; only the CLI
  #                      --ignore-scripts blocks lifecycle scripts on 1.1.x.
  #                      Honoured 1.2.0 -> 1.4.0.
  #   minimumReleaseAge  DOES NOT EXIST below bun 1.3.0 (absent through
  #                      1.2.23). Present 1.3.0 -> 1.4.0.
  #   saveTextLockfile   bun 1.2.0+; older bun defaults to binary bun.lockb.
  #   exact / frozenLockfile / auto = "disable"
  #                      universal 1.1.38 -> 1.4.0. auto = "disable" is still
  #                      a valid enum value on 1.4.0 — do not "fix" it.
  #
  # Below its threshold a key is OMITTED rather than written-and-ignored, and
  # the gap is announced with notice() — so the job log says the protection
  # is missing instead of the file claiming a protection bun never applies.
  #
  # Version UNDETECTED (bun not installed on this runner, or --version
  # failed): emit everything. bun accepts unknown [install] keys SILENTLY
  # (measured on all eight versions above), so an over-emitted key is inert
  # on old bun, while an under-emitted one would leave a modern bun
  # unhardened. This is the opposite of composer's tiering, where the emit
  # direction is the one that can brick the tool.
  local has_save_text_lockfile=true has_ignore_scripts=true has_min_release_age=true
  if [[ -n "$bun_version" ]]; then
    if ! version_ge "$bun_version" "1.2.0"; then
      has_save_text_lockfile=false
      has_ignore_scripts=false
    fi
    if ! version_ge "$bun_version" "1.3.0"; then
      has_min_release_age=false
    fi
  fi

  # FAIL-WHOLE HAZARD, not fail-silent. bun rejects the ENTIRE bunfig on ONE
  # bad value — "Invalid Bunfig: failed to load bunfig", exit 1 — MEASURED
  # with a QUOTED minimumReleaseAge (minimumReleaseAge = "2d") on bun 1.3.0
  # through 1.4.3, which want a number of seconds there. bun 1.4.4 accepts a
  # duration string (MEASURED), but the runner's bun version is not known
  # here, and a bare integer of seconds works on every bun from 1.3.0. On
  # the versions that reject it, one malformed key disarms every other key
  # in the file AND breaks bun itself, so a bad value here is strictly worse
  # than writing nothing. BUN_AGE_SECONDS is
  # $(( RELEASE_AGE_HOURS * 3600 )), i.e. always a bare integer and never
  # quoted — but RELEASE_AGE_HOURS is caller-supplied, so a negative or
  # otherwise non-integer value drops the key rather than risking the file.
  # Never interpolate a duration string ("2d") or a quoted number here.
  if [[ "$has_min_release_age" == "true" ]] && ! [[ "$BUN_AGE_SECONDS" =~ ^[0-9]+$ ]]; then
    has_min_release_age=false
    warn "bun: RELEASE_AGE_HOURS=$RELEASE_AGE_HOURS yields minimumReleaseAge='$BUN_AGE_SECONDS', which is not a bare non-negative integer of seconds. The key is omitted rather than risk the file: bun 1.3.0 through 1.4.3 reject the WHOLE bunfig on a non-numeric minimumReleaseAge, which would disarm every other key and break bun on this runner. bun's install age gate is NOT enforced."
  fi

  # WHERE THE GLOBAL BUNFIG LIVES — resolved from bun's environment, never
  # hardcoded. MEASURED (1.1.38 -> 1.4.0): bun reads
  #   $XDG_CONFIG_HOME/.bunfig.toml  — DOT-PREFIXED — when XDG_CONFIG_HOME is
  #                                    set, and
  #   $HOME/.bunfig.toml             — only when XDG_CONFIG_HOME is unset.
  # There is NO fallback between them: with XDG_CONFIG_HOME pointing at a
  # directory holding no .bunfig.toml, $HOME/.bunfig.toml is never read (the
  # fixture's preinstall ran). $XDG_CONFIG_HOME/bunfig.toml WITHOUT the dot
  # is not read either. This wrote $HOME/.bunfig.toml unconditionally, which
  # was dead on every runner image that sets XDG_CONFIG_HOME — the wrappers
  # below were the only surviving layer there.
  # docs/design-principles.md Axis 5, "Assumed canonical config homes".
  local bunfig_path
  if [[ -n "${XDG_CONFIG_HOME:-}" ]]; then
    bunfig_path="$XDG_CONFIG_HOME/.bunfig.toml"
  else
    bunfig_path="$HOME/.bunfig.toml"
  fi
  mkdir -p "$(dirname "$bunfig_path")"

  # The bunfig is install-time hardening. NOTE: per bun's docs, this file is
  # NOT consulted for `bun run`; only for `bun install`. The runtime
  # auto-install gap is closed by the wrapper below.
  #
  # ignoreScripts (NOT lifecycleScripts — earlier action versions wrote
  # the wrong key which bun silently ignored) blocks bun install's
  # preinstall/install/postinstall/prepare hooks. Fixed 2026-05-28 after
  # a fresh audit caught the made-up key. Same bug-shape as the original
  # composer COMPOSER_NO_SCRIPTS bug we shipped + later fixed.
  #
  # Written with `if` blocks, not `[[ ... ]] && echo`: a false test as the
  # last command of the group would return 1 and `set -e` would kill the run.
  {
    echo "# Managed by supply-chain-harden action"
    echo "[install]"
    if [[ "$has_min_release_age" == "true" ]]; then
      echo "minimumReleaseAge = $BUN_AGE_SECONDS"
    fi
    echo "exact = true"
    if [[ "$has_ignore_scripts" == "true" ]]; then
      echo "ignoreScripts = true"
    fi
    echo "frozenLockfile = true"
    echo 'auto = "disable"'
    if [[ "$has_save_text_lockfile" == "true" ]]; then
      echo "saveTextLockfile = true"
    fi
  } | put_user_cfg bun "$bunfig_path"
  log "bun: global bunfig written at $bunfig_path"

  if [[ "$has_ignore_scripts" != "true" ]]; then
    notice "bun $bun_version ignores the [install] ignoreScripts bunfig key (MEASURED inert below 1.2.0 in BOTH a global and a local bunfig; honoured 1.2.0+), so it was not written. \`bun install\` lifecycle scripts are NOT blocked by config on this runner — only the CLI --ignore-scripts blocks them on this version. Upgrade bun to >= 1.2.0 and re-run."
  fi
  # Guarded on the version, not on has_min_release_age: the bad-value branch
  # above already warned for its own reason and must not claim "old bun".
  if [[ -n "$bun_version" ]] && ! version_ge "$bun_version" "1.3.0"; then
    notice "bun $bun_version has no [install] minimumReleaseAge key (MEASURED: added in 1.3.0, absent through 1.2.23), so it was not written. \`bun install\` on this runner will accept a package published seconds ago; the ${BUN_AGE_SECONDS}s cooldown is not enforced. Upgrade bun to >= 1.3.0 and re-run."
  fi

  HARDENED+=("bun")
  set_tool_version "bun" "$bun_version"

  # PATH wrapper at the DISCOVERED bun location (wrap in-place — same
  # pattern as deno). Critical for CI runners where bun is commonly
  # installed at ~/.bun/bin/bun (the official installer prepends it to
  # PATH) which comes BEFORE /usr/local/bin in resolution order.
  # A wrapper at /usr/local/bin/bun would be silently bypassed in that
  # configuration. Closes the runtime auto-install gap that
  # ~/.bunfig.toml cannot close (bun's docs: "Currently, bunfig.toml
  # is only automatically loaded for `bun run` in a local project (it
  # doesn't check for a global .bunfig.toml).")
  local real_bun
  real_bun=$(command -v bun 2>/dev/null || true)
  if [[ -z "$real_bun" ]]; then
    log "bun not installed — wrapper not deployed (only the global bunfig written)"
    # bunfig covers install-time; the runtime auto-install gap and bunx
    # fetch-and-execute are wrapper-only.
    set_eco_status bun PARTIAL "bunfig written; runtime auto-install and bunx need the wrappers, and bun was not installed"
    end_section
    return 0
  fi

  local wrapper_target="$real_bun"
  require_privilege bun "$wrapper_target" || { end_section; return 0; }
  # If the discovered bun IS our wrapper from a prior step (re-run within
  # the same job), find the real binary at -real and re-wrap.
  if grep -q "supply-chain-harden" "$real_bun" 2>/dev/null; then
    if [[ -x "${real_bun}-real" ]]; then
      real_bun="${real_bun}-real"
    else
      warn "bun wrapper present at $wrapper_target but ${wrapper_target}-real missing; skipping re-wrap"
      end_section
      return 0
    fi
  else
    # Move the real binary to -real, then deploy wrapper at the original
    # location so PATH-resolved invocations hit the wrapper. Use sudo
    # because ~/.bun/bin is owned by the runner user but /usr/local/bin
    # isn't, and we want this to work in both cases.
    $SUDO mv "$real_bun" "${real_bun}-real"
    real_bun="${real_bun}-real"
  fi

  cat <<EOF | $SUDO tee "$wrapper_target" >/dev/null
#!/bin/bash
# Managed by supply-chain-harden action
REAL_BUN='$real_bun'
# RUN-PROBE. Record that this wrapper actually executed.
#
# Costs nothing on a real invocation: SCH_WRAPPER_PROBE is unset, so this is
# one test. verify.sh sets it to a temp file, invokes the tool, and reads back
# which wrappers ran.
#
# It replaces inferring "did our wrapper run" from PATH position, which CANNOT
# distinguish a wrapper that was bypassed from one that is chained behind
# another wrap. MEASURED: with an Aikido safe-chain shim first on PATH, the
# wrapper ran on every call and the verifier reported "shadowed and never
# runs" at FUNCTIONAL strength -- the strongest evidence grade, asserting the
# opposite of the fact.
#
# The value is caller-controlled, so it is only ever a redirect target. Never
# interpolate it into a command.
if [ -n "\${SCH_WRAPPER_PROBE:-}" ]; then
  printf '%s\n' "\$0" >> "\$SCH_WRAPPER_PROBE" 2>/dev/null || true
fi

if [ -z "\$REAL_BUN" ] || [ ! -x "\$REAL_BUN" ] || [ "\$REAL_BUN" = "$wrapper_target" ]; then
  echo "[supply-chain-harden] error: real bun not found at '\$REAL_BUN'; refusing to recurse" >&2
  exit 127
fi
# Package-mgmt subcommands consult bunfig as normal.
case "\${1:-}" in
  install|i|add|a|remove|rm|uninstall|un|update|up|upgrade|link|unlink|pm|outdated|why|audit|publish|patch|patch-commit|init|create)
    exec "\$REAL_BUN" "\$@"
    ;;
  --version|-v|--help|-h|--revision)
    # Only as the WHOLE command line. MEASURED on bun 1.4.4: with more after
    # it, bun ignores the flag -- \`bun --version x cowsay hi\` downloaded and
    # ran cowsay -- so passing any leading metadata flag through was a
    # one-flag bypass. With --no-install in front bun refuses it.
    if [ "\$#" -eq 1 ]; then
      exec "\$REAL_BUN" "\$@"
    fi
    exec "\$REAL_BUN" --no-install "\$@"
    ;;
  *)
    exec "\$REAL_BUN" --no-install "\$@"
    ;;
esac
EOF
  $SUDO chmod 755 "$wrapper_target"
  log "bun: wrapper deployed at $wrapper_target (injects --no-install for runtime paths)"
  record_wrapper bun

  # ---- bunx ----
  #
  # `bunx <pkg>` downloads a package from npm and executes it in one step —
  # the bun equivalent of npx, and a genuine hole: a typosquatted name is
  # fetched and run immediately with no age gate and no script blocking.
  #
  # Wrapping `bun` above does NOT cover it. bunx is a SEPARATE entry point
  # (the official installer creates ~/.bun/bin/bunx alongside bun), and the
  # global bunfig does not apply to it either — so none of
  # minimumReleaseAge / ignoreScripts / frozenLockfile reach this path.
  # Verified 2026-08 on a host where the bun wrapper was already deployed:
  # `bunx cowsay` still auto-downloaded and executed. That is finding V5;
  # the role fixed it in templates/bunx-wrapper.sh.j2 and this is the port.
  #
  # TWO SUBTLETIES, both load-bearing:
  #  1. bun decides it is in "bunx mode" from argv[0], so the real binary
  #     must be invoked with `exec -a bunx`. A plain exec runs it in
  #     ordinary bun mode and silently changes every bunx invocation.
  #  2. bunx is normally a SYMLINK to the bun binary. Pointing this wrapper
  #     at a `bunx-real` backup would resolve through that symlink to the
  #     bun *wrapper* deployed above — re-injecting flags and losing
  #     argv[0]. So it points at the real bun binary directly.
  local real_bunx
  real_bunx=$(command -v bunx 2>/dev/null || true)
  if [[ -z "$real_bunx" ]]; then
    # bunx not on PATH; try the conventional sibling of the bun we wrapped.
    local sibling
    sibling="$(dirname "$wrapper_target")/bunx"
    [[ -e "$sibling" ]] && real_bunx="$sibling"
  fi

  if [[ -z "$real_bunx" ]]; then
    log "bunx not found — no bunx wrapper deployed"
  elif ! require_privilege bun "$real_bunx" PARTIAL "bunx PATH wrapper not deployed at $real_bunx: no root and no usable sudo in this job. The bun wrapper and the bunfig apply, but \`bunx <pkg>\` goes through neither."; then
    # bunx can live in a directory bun does not: bun in ~/.bun/bin, bunx in
    # /usr/local/bin. The gate above asked about bun's directory only. MEASURED
    # (v2.1.0, main 8cfc1c4): the `rm` below then died on "Permission denied",
    # and nothing after bun was applied, nor any summary printed.
    :
  else
    # REMOVE FIRST, THEN WRITE. bunx is normally a SYMLINK to the bun binary,
    # and by this point that symlink resolves to the bun WRAPPER deployed
    # above. `tee` follows symlinks, so writing straight to $real_bunx wrote
    # the bunx wrapper's contents *through* the link and clobbered the bun
    # wrapper — leaving a single file that injected --no-install into every
    # invocation, including `bun install`. That breaks bun installs outright
    # while still looking successfully hardened in the log.
    #
    # No -real backup is kept: unlike bun, bunx carries no unique binary. It
    # is a symlink, and the thing it pointed at is already preserved as
    # bun-real by the wrap above.
    $SUDO rm -f "$real_bunx"
    cat <<EOF | $SUDO tee "$real_bunx" >/dev/null
#!/bin/bash
# Managed by supply-chain-harden
REAL_BUN='$real_bun'
# RUN-PROBE. Record that this wrapper actually executed.
#
# Costs nothing on a real invocation: SCH_WRAPPER_PROBE is unset, so this is
# one test. verify.sh sets it to a temp file, invokes the tool, and reads back
# which wrappers ran.
#
# It replaces inferring "did our wrapper run" from PATH position, which CANNOT
# distinguish a wrapper that was bypassed from one that is chained behind
# another wrap. MEASURED: with an Aikido safe-chain shim first on PATH, the
# wrapper ran on every call and the verifier reported "shadowed and never
# runs" at FUNCTIONAL strength -- the strongest evidence grade, asserting the
# opposite of the fact.
#
# The value is caller-controlled, so it is only ever a redirect target. Never
# interpolate it into a command.
if [ -n "\${SCH_WRAPPER_PROBE:-}" ]; then
  printf '%s\n' "\$0" >> "\$SCH_WRAPPER_PROBE" 2>/dev/null || true
fi

if [ -z "\$REAL_BUN" ] || [ ! -x "\$REAL_BUN" ] || [ "\$REAL_BUN" = "$real_bunx" ]; then
  echo "[supply-chain-harden] error: real bun not found at '\$REAL_BUN'; refusing to recurse" >&2
  exit 127
fi
# Metadata flags don't resolve or execute a package — pass them through.
case "\${1:-}" in
  --version|-v|--help|-h|--revision)
    # ONLY when the flag is the WHOLE command line. MEASURED on bun 1.4.3:
    # with a package name after it, bunx ignores the flag's metadata meaning
    # and fetch-and-executes the package anyway -- \`bunx --version cowsay hi\`
    # downloaded cowsay from npm and ran it, rc 0, with NO cache involved. So
    # this arm was a complete bypass of the --no-install injection below,
    # independent of cache state, reachable by prepending one flag.
    #
    # \`\$# -eq 1\` is the shape to use rather than dropping the arm or injecting
    # --no-install into it: tests/ci/04-wrappers.bats:142 runs \`bunx --version\`
    # and asserts the output carries no --no-install, and that stays green
    # here. Every other argv shape falls through to the hardened path.
    if [ "\$#" -eq 1 ]; then
      exec -a bunx "\$REAL_BUN" "\$@"
    fi
    ;;
esac
exec -a bunx "\$REAL_BUN" --no-install "\$@"
EOF
    $SUDO chmod 755 "$real_bunx"
    log "bunx: wrapper deployed at $real_bunx (injects --no-install; fails closed on uninstalled packages)"
    record_wrapper bunx
  fi

  end_section
}

harden_cargo() {
  section "cargo"
  local cargo_home="${CARGO_HOME:-$HOME/.cargo}"
  mkdir -p "$cargo_home"

  put_user_cfg cargo "$cargo_home/config.toml" <<'EOF'
# Managed by supply-chain-harden
# Note: build.rs / proc-macro execution CANNOT be blocked by cargo config —
# structural gap. Refusing to RESOLVE a too-new version is the only control
# that prevents execution, which is what cooldown.toml below is for.
# Run cargo-deny / cargo-audit in your workflow for detection.
[net]
git-fetch-with-cli = true
retry = 3
EOF

  # ---- publish-age gate config ----
  #
  # Deployed at $CARGO_HOME/cooldown.toml, the weakest level of
  # cargo-cooldown's precedence chain (env > member > workspace > CARGO_HOME)
  # and the only one that applies to every project without per-repo opt-in.
  # On its own, the weakest level would let a repo's committed cooldown.toml
  # override this file. It does not, because the wrapper below exports the same
  # policy into the ENVIRONMENT, which outranks every file level — see
  # sanitize_cooldown_env in the WRAPPER heredoc. Residuals: a repo file still
  # supplies [[allow.exact]] rules (the env pin does not touch those), and a
  # caller who reaches cargo WITHOUT the wrapper is back to file precedence.
  #
  # Writing this costs nothing and is harmless when the cargo-cooldown binary
  # is absent, so it is unconditional; the binary itself is opt-in below.
  local violation_action="deny"
  [[ "$STRICT" == "true" ]] || violation_action="fallback"
  cat > "$cargo_home/cooldown.toml" <<EOF
# Managed by supply-chain-harden
[cooldown]
# "deny" fails the command and restores the original Cargo.lock when a
# resolved version is younger than the window. "fallback" only downgrades
# and warns — a fail-open posture, so it is used only when strict=false.
incompatible-publish-age = "$violation_action"
# "floor": versions already pinned in an existing Cargo.lock are accepted as
# a baseline. Without it every existing lockfile starts failing the first
# time the gate applies, which is how a control gets switched off by an
# irritated developer within the hour. The gate therefore covers NEW OR
# CHANGED resolutions; the wrapper's --locked half holds the rest.
lockfile-baseline = "floor"
fallback-accept = "auto"

[registry]
global-min-publish-age = "$RELEASE_AGE_HOURS hours"
EOF

  HARDENED+=("cargo")
  # RUSTUP_AUTO_INSTALL=0: on a rustup host `cargo` is a proxy, and when the active
  # toolchain is not installed (a rust-toolchain.toml pinning one, or a fresh
  # RUSTUP_HOME) a bare `cargo --version` goes and downloads it. MEASURED on
  # rustup 1.29.3 with a toolchain named and a fresh HOME: 8 s and 757 MB, from a
  # hardening step that installs nothing. It also filled the disk of the macos-15
  # runner, one toolchain per test HOME. stderr is dropped so rustup's "toolchain
  # 1.85.0 is not installed" cannot be read back as cargo's version.
  # From /: through a rustup proxy a checkout's rust-toolchain.toml `path =`
  # picks the cargo that answers (MEASURED, rustup 1.29.3). See detect_version.
  set_tool_version "cargo" "$(cd / && RUSTUP_AUTO_INSTALL=0 cargo --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || true)"

  # ---- optional cargo-cooldown backend ----
  #
  # Opt-in because `cargo install cargo-cooldown` compiles from source and
  # costs minutes on a cold runner — the same reasoning as install_sfw. Off
  # by default, the config above sits inert and the wrapper still injects
  # --locked, which is the cheap half of the protection.
  local cooldown_bin=""
  if [[ "$INSTALL_CARGO_COOLDOWN" == "true" ]]; then
    if command -v cargo >/dev/null 2>&1; then
      log "installing cargo-cooldown ${CARGO_COOLDOWN_VERSION} (compiles from source; this takes a few minutes)"
      # Pinned (see CARGO_COOLDOWN_VERSION). stderr is KEPT for the warning:
      # it used to go to /dev/null, which hid cargo's own explanation
      # ("cargo-cooldown 0.4.2 requires rustc 1.97") of why the gate was absent.
      local cc_err cc_rc=0
      # From /, so neither the checkout's .cargo/config.toml (a rustc-wrapper)
      # nor its rust-toolchain.toml takes part in building the gate itself.
      cc_err=$(cd / && cargo install --locked "cargo-cooldown@${CARGO_COOLDOWN_VERSION}" 2>&1 >/dev/null) || cc_rc=$?
      if [[ "$cc_rc" -eq 0 ]]; then
        cooldown_bin="$cargo_home/bin"
        log "cargo-cooldown ${CARGO_COOLDOWN_VERSION} installed at $cooldown_bin"
        set_tool_version "cargo-cooldown" "$CARGO_COOLDOWN_VERSION"
      else
        warn "cargo-cooldown ${CARGO_COOLDOWN_VERSION} install failed (rc=$cc_rc: $(printf '%s' "$cc_err" | grep -E '^(error|  )' | head -n 3 | tr '\n' ' ')) — the age gate config is deployed but nothing enforces it; --locked injection still applies"
      fi
    else
      warn "install_cargo_cooldown=true but cargo is not installed — skipping"
    fi
  elif [[ -x "$cargo_home/bin/cargo-cooldown" ]]; then
    # Already present on the runner (cached toolchain, prior step).
    cooldown_bin="$cargo_home/bin"
  fi

  # ---- PATH wrapper ----
  local real_cargo
  real_cargo=$(command -v cargo 2>/dev/null || true)
  if [[ -z "$real_cargo" ]]; then
    log "cargo not installed — config written, wrapper not deployed"
    # --locked has no config or env route at all; it is wrapper-only.
    set_eco_status cargo PARTIAL "config and cooldown.toml written; --locked injection needs the wrapper, and cargo was not installed"
    end_section
    return 0
  fi

  local wrapper_target="$real_cargo"
  require_privilege cargo "$wrapper_target" || { end_section; return 0; }
  if grep -q "supply-chain-harden" "$real_cargo" 2>/dev/null; then
    if [[ -x "${real_cargo}-real" ]]; then
      real_cargo="${real_cargo}-real"
    else
      warn "cargo wrapper present at $wrapper_target but ${wrapper_target}-real missing; skipping re-wrap"
      end_section
      return 0
    fi
  else
    # Moved FIRST, before anything else touches this path: the wrapper is later
    # written with `cp`, and `cp` onto a symlink writes THROUGH it — into the
    # shared rustup binary, replacing rustc, rustfmt and every other proxy.
    $SUDO mv "$real_cargo" "${real_cargo}-real"
    real_cargo="${real_cargo}-real"
  fi

  # ARGV[0]-SAFE BACKUP — parity with tasks/cargo.yml "Prepare cargo-real".
  # rustup's cargo is a symlink to the rustup binary, which dispatches on the
  # name it is invoked as, so a backup called cargo-real is rejected:
  #   error: unknown proxy name: 'cargo-real'
  # The wrapper's own `exec -a cargo` covers ITS call, but cargo hands
  # subcommands its own path via $CARGO, so cargo-cooldown re-enters as
  # cargo-real and dies; so does the `sfw` branch of run_real, which cannot set
  # argv[0] at all. This surface did a plain rename while run_real's comment
  # already claimed "cargo-real is an argv[0] shim on rustup hosts". MEASURED
  # before this change, rustup cargo + cargo-cooldown: every routed
  # `cargo check` failed with exactly the error above. So on rustup the backup
  # becomes a two-line shim restoring argv[0]=cargo. Applied on the re-wrap
  # path too, because a runner that ran an older action already has the broken
  # symlink and the branch above would otherwise reuse it.
  #
  # Three proxy layouts, all one multicall binary that dispatches on argv[0]:
  # a symlink to `rustup` (rustup's default), a symlink to `rustup-init`
  # (Homebrew's rustup formula), and a HARDLINK to rustup (RUSTUP_HARDLINK_PROXIES,
  # and the default on older rustup) -- the last is no symlink at all, so it is
  # recognised by sharing an inode with the sibling `rustup`.
  local cargo_target="" tmp_shim cargo_sib
  if [[ -L "$real_cargo" ]]; then
    cargo_target=$(readlink -f "$real_cargo" 2>/dev/null || true)
    case "$(basename "${cargo_target:-none}")" in rustup|rustup-init) ;; *) cargo_target="" ;; esac
  fi
  cargo_sib="$(dirname "$real_cargo")/rustup"
  if [[ -z "$cargo_target" && ! -L "$real_cargo" && -f "$cargo_sib" && "$real_cargo" -ef "$cargo_sib" ]]; then
    cargo_target=$(readlink -f "$cargo_sib" 2>/dev/null || true)
  fi
  if [[ -n "$cargo_target" ]]; then
    tmp_shim=$(mktemp)
    printf '#!/bin/bash\n# supply-chain-harden: argv[0] shim for the rustup cargo proxy.\n# rustup dispatches on the name it is invoked as, so a file called\n# cargo-real is rejected as an unknown proxy. Restore argv[0]=cargo.\nexec -a cargo "%s" "$@"\n' "$cargo_target" > "$tmp_shim"
    chmod 0755 "$tmp_shim"
    # mv replaces the directory entry; it neither follows a symlink nor
    # writes into a hardlink's shared inode (the rustup binary).
    $SUDO mv -f "$tmp_shim" "$real_cargo"
    log "cargo: ${real_cargo} is an argv[0] shim for rustup (a renamed rustup proxy is rejected as an unknown proxy)"
  fi

  # ---- which backend the wrapper runs (absolute path) ----
  #
  # A wrapper the invoking user does not own (apt's /usr/bin/cargo, a root
  # job's /usr/local/cargo/bin) runs for root and for every other account, so
  # its backend must not be a file in this user's $CARGO_HOME/bin, which this
  # user can rewrite. MEASURED (VM#2, role and plain path alike): the old
  # wrapper prepended that directory to PATH, and root and a second account
  # then ran this user's cargo-cooldown and ~/.cargo/bin/cargo. A shared
  # wrapper therefore gets a ROOT-OWNED copy under /usr/local/libexec; if that
  # cannot be made, the wrapper still works for this user and refuses, with a
  # message, for everyone else. Numeric 0 for owner and group: macOS has no
  # group named root.
  local cooldown_exe=""
  if [[ -n "$cooldown_bin" ]]; then
    cooldown_exe="$cooldown_bin/cargo-cooldown"
    if [[ "$(id -u)" -eq 0 || ! -O "$(dirname "$wrapper_target")" ]]; then
      local sys_cooldown=/usr/local/libexec/supply-chain-hardening/cargo/cargo-cooldown
      if [[ "${CAN_ESCALATE:-0}" -eq 1 ]] \
         && $SUDO install -d -o 0 -g 0 -m 0755 "$(dirname "$sys_cooldown")" \
         && $SUDO install -o 0 -g 0 -m 0755 "$cooldown_exe" "$sys_cooldown"; then
        cooldown_exe="$sys_cooldown"
        log "cargo: $wrapper_target is shared, so its wrapper names a root-owned copy of the gate backend, $sys_cooldown"
        # cargo, not the wrapper, starts the backend, and it looks in
        # $CARGO_HOME/bin before the directory the wrapper appends to PATH.
        # MEASURED (rust:1.100.0-slim-trixie): root's builds there ran
        # /usr/local/cargo/bin/cargo-cooldown, not the copy above.
        if [[ -x "$cooldown_bin/cargo-cooldown" ]]; then
          log "cargo: note: cargo starts the first cargo-cooldown in \$CARGO_HOME/bin, then PATH, so $(id -un)'s builds run $cooldown_bin/cargo-cooldown (or one earlier on PATH), not that copy; see docs/limitations.md"
        fi
      else
        warn "cargo: $wrapper_target is shared, but no root-owned copy of cargo-cooldown could be installed; the wrapper gates builds for $(id -un) and refuses the backend for root and other accounts"
      fi
    fi
  fi

  # Written via placeholders + sed rather than an interpolating heredoc: the
  # wrapper is dense with $ and the escaping is where this kind of code goes
  # wrong silently.
  local tmp_wrapper
  tmp_wrapper=$(mktemp)
  cat > "$tmp_wrapper" <<'WRAPPER'
#!/bin/bash
# cargo — supply-chain-harden wrapper
#
# SCOPE. A FIRST-INVOCATION control, not an enforcement boundary. Three
# mechanisms route around it and none can be closed from here: cargo
# overwrites $CARGO with its own resolved toolchain path, so build scripts
# and third-party subcommands re-enter unwrapped; a repo-local
# rust-toolchain.toml with `path =` supplies its own cargo; RUSTC_WRAPPER and
# repo-local .cargo/config.toml execute code with no registry involvement.
# It raises the floor for ordinary invocations. Containing build.rs is a
# separate concern this does not attempt.
#
# WHAT IT DOES
#   1. --locked injection. There is no config or env route to --locked
#      (CARGO_LOCKED is not a thing), so a wrapper is the only mechanism.
#   2. Prefix-exec: routes resolution-affecting commands through
#      `cargo cooldown` when that backend is present.
#
# PARSING. The subcommand is the FIRST NON-FLAG ARGUMENT. Reading argv[1]
# directly is wrong: `cargo -q build` and `cargo --color always build` are
# ordinary CI forms, and treating `-q` as the subcommand silently disables
# every control here. Five of cargo's global flags take a value and must be
# skipped, or `--color always build` resolves to the subcommand "always".

set -u

REAL_CARGO='__REAL_CARGO__'

# cargo's internal test clock. Set to a future date it defeats cargo 1.100's
# native publish-age gate (MEASURED: __CARGO_TEST_INVOCATION_TIME=2099-...
# admitted a version the gate refused). Only cargo's own test suite needs it.
unset __CARGO_TEST_INVOCATION_TIME
# RUN-PROBE. Record that this wrapper actually executed.
#
# Costs nothing on a real invocation: SCH_WRAPPER_PROBE is unset, so this is
# one test. verify.sh sets it to a temp file, invokes the tool, and reads back
# which wrappers ran.
#
# It replaces inferring "did our wrapper run" from PATH position, which CANNOT
# distinguish a wrapper that was bypassed from one that is chained behind
# another wrap. MEASURED: with an Aikido safe-chain shim first on PATH, the
# wrapper ran on every call and the verifier reported "shadowed and never
# runs" at FUNCTIONAL strength -- the strongest evidence grade, asserting the
# opposite of the fact.
#
# The value is caller-controlled, so it is only ever a redirect target. Never
# interpolate it into a command.
if [ -n "${SCH_WRAPPER_PROBE:-}" ]; then
  printf '%s\n' "$0" >> "$SCH_WRAPPER_PROBE" 2>/dev/null || true
fi


# THE GATE BACKEND, BY ABSOLUTE PATH, AND WHOSE IT IS. Parity with the role's
# templates/cargo-wrapper.sh.j2, which carries the measurement record (VM#2):
# this wrapper used to PREPEND $CARGO_HOME/bin to PATH, and at a system path
# (/usr/bin/cargo) that made root and every other account run the hardening
# user's cargo-cooldown and ~/.cargo/bin/cargo, files that user can replace.
# harden.sh now renders the backend's absolute path: the one in $CARGO_HOME/bin
# when the wrapped cargo is the invoking user's own, a ROOT-OWNED copy under
# /usr/local/libexec/supply-chain-hardening/ otherwise. Nothing is prepended,
# and use_cooldown refuses a backend whose owner is neither the caller nor root.
COOLDOWN_EXE='__COOLDOWN_EXE__'

if [ -z "$REAL_CARGO" ] || [ ! -x "$REAL_CARGO" ] || [ "$REAL_CARGO" = "$0" ]; then
  echo "[supply-chain-harden] error: real cargo not found at '$REAL_CARGO'; refusing to recurse" >&2
  exit 127
fi

# cargo-cooldown invokes cargo internally; without this the inner call routes
# back into cooldown forever.
if [ -n "${SUPPLY_CHAIN_CARGO_WRAPPED:-}" ]; then
  exec "$REAL_CARGO" "$@"
fi

# ARGV[0] MUST BE "cargo". rustup's cargo is a symlink to the rustup binary,
# which dispatches on the name it was invoked as; a backup named cargo-real
# is rejected with "unknown proxy name: 'cargo-real'". On a non-rustup cargo
# argv[0] is not consulted, so this is safe for both shapes.
# Threat-intel filtering for the paths that actually touch the registry.
#
# sfw is only prefixed when SCH_NET=1 — set by the dispatch arms below on the
# resolution-affecting commands and nowhere else, so `cargo fmt` and friends
# are not routed through a network filter that has nothing to inspect.
#
# Guarded by `command -v sfw` rather than assumed: sfw is opt-in
# (install_sfw), and a cargo wrapper that hard-required it would break every
# build on a runner that did not install it. Absent sfw, this is a no-op.
#
# sfw runs READ-ONLY. Its cache sits in its own package directory, which a
# root `npm install -g` makes root-owned, and by default it rewrites
# .sfw-cache/next-check there once the last update check is an hour old; a
# non-root caller cannot, and sfw treats that as fatal. MEASURED (sfw 2.0.6,
# this action at 8281a6b, a non-root user): one hour after hardening, every
# npm, npx and cargo call through sfw failed with "[sfw] Failed to prepare
# firewall binary: EACCES ... next-check". SFW_SKIP_UPDATE_CHECK=1 runs the
# cached binary without writing (MEASURED). A COLD cache still needs a
# download, which only root can do unless the caller can write the cache, so
# otherwise it warns and runs cargo unfiltered.
if [ "__CARGO_SFW__" = "true" ]; then
  SFW_SKIP_UPDATE_CHECK=1; export SFW_SKIP_UPDATE_CHECK
fi
sfw_ready() {
  local s p
  [ "$(id -u)" = 0 ] && return 0
  s=$(readlink -f "$(command -v sfw)" 2>/dev/null) || return 0
  p=${s%/*}; p=${p%/*}
  [ -f "$p/package.json" ] || return 0
  [ -e "$p/.sfw-cache/latest" ] && return 0
  if [ -e "$p/.sfw-cache" ]; then [ -w "$p/.sfw-cache" ] && return 0
  else [ -w "$p" ] && return 0; fi
  echo "[supply-chain-harden] warning: sfw has no firewall binary cached that this account can run ($p/.sfw-cache), and only root can fetch it; run  sudo sh -c 'umask 022; sfw true && chmod -R go+rX $p/.sfw-cache'  once, or re-run the hardening step. cargo call not filtered through threat intel" >&2
  return 1
}
run_real() {
  local pfx=""
  if [ "__CARGO_SFW__" = "true" ] && [ "${SCH_NET:-0}" = "1" ] \
     && command -v sfw >/dev/null 2>&1 && sfw_ready; then
    pfx="sfw"
  fi
  if [ -n "$pfx" ]; then
    # sfw execs the child itself, so argv[0] cannot be set here. Safe because
    # cargo-real is an argv[0] shim on rustup hosts.
    exec "$pfx" "$REAL_CARGO" "$@"
  fi
  exec -a cargo "$REAL_CARGO" "$@"
}

# May THIS caller run "$1" as the gate backend? Only when no other account can
# choose what runs there. Walking up from the file: one the caller owns (not
# root) ends the walk, yes (your own file, or a root-owned file in your own
# directory); a root-owned one must be writable by neither group nor others, or
# for a directory be sticky (/tmp), and the walk goes on; anything else is no.
# Parity with the role's templates/cargo-wrapper.sh.j2. find(1), not stat(1):
# `stat -c` is GNU-only and this runs on macOS runners.
backend_trusted() {
  _bt_why=""
  _bt_me=""
  [ "$(id -u)" != 0 ] && _bt_me=$(id -un 2>/dev/null || id -u)
  _bt_p=$(readlink -f "$1" 2>/dev/null) || _bt_p="$1"
  case "$_bt_p" in /*) ;; *) _bt_why="$1 is not an absolute path"; return 1 ;; esac
  if [ -n "$_bt_me" ] && [ -O "$_bt_p" ]; then return 0; fi
  if [ -z "$(find "$_bt_p" -maxdepth 0 -user 0 ! -perm -020 ! -perm -002 2>/dev/null)" ]; then
    _bt_why="$_bt_p is not owned by root${_bt_me:+ or by $_bt_me}, or is writable by its group or others"
    return 1
  fi
  while [ "$_bt_p" != "/" ]; do
    _bt_p=$(dirname "$_bt_p")
    if [ -n "$_bt_me" ] && [ -O "$_bt_p" ]; then return 0; fi
    if [ -z "$(find "$_bt_p" -maxdepth 0 -user 0 \( -perm -1000 -o \( ! -perm -020 ! -perm -002 \) \) 2>/dev/null)" ]; then
      _bt_why="directory $_bt_p is not owned by root${_bt_me:+ or by $_bt_me}, or is writable by its group or others"
      return 1
    fi
  done
  return 0
}

cooldown_installed() {
  local c
  for c in "$COOLDOWN_EXE" "$(command -v cargo-cooldown 2>/dev/null)"; do
    [ -n "$c" ] && [ -x "$c" ] && return 0
  done
  return 1
}

# Pick the backend for a gated command or REFUSE (exit 126); a quiet degrade
# would leave the command ungated exactly when it runs as someone else. cargo
# still starts the backend (`cargo-real cooldown build`), because cargo is what
# consumes a leading +toolchain / -C / --config, so the backend's directory is
# APPENDED to PATH when neither $CARGO_HOME/bin nor PATH covers it: appending
# cannot change what any name already on PATH resolves to. What is vouched for
# here is not always what runs: cargo looks in $CARGO_HOME/bin first (unless it
# is on PATH, where PATH order decides), then along PATH, and starts any other
# cargo-cooldown it finds there unchecked. MEASURED in rust:1.100.0-slim-trixie:
# root's build ran /usr/local/cargo/bin/cargo-cooldown (a 0777 directory), not
# the root-owned libexec copy this wrapper named. See the role template and
# docs/limitations.md.
use_cooldown() {
  local c d refused=""
  COOLDOWN=""
  for c in "$COOLDOWN_EXE" "$(command -v cargo-cooldown 2>/dev/null)"; do
    [ -n "$c" ] && [ -x "$c" ] || continue
    if backend_trusted "$c"; then COOLDOWN="$c"; break; fi
    refused="$_bt_why"
  done
  if [ -z "$COOLDOWN" ]; then
    echo "[supply-chain-harden] error: refusing to run the cargo publish-age gate backend as $(id -un): $refused, so another account could choose what runs here. Re-run harden.sh with sudo available to give a shared cargo a root-owned backend, or run cargo as the account that owns this one. (cargo wrapper: $0)" >&2
    exit 126
  fi
  d=$(dirname "$COOLDOWN")
  case ":$PATH:" in
    *":$d:"*) ;;
    *) [ "$d" = "${CARGO_HOME:-$HOME/.cargo}/bin" ] || { PATH="$PATH:$d"; export PATH; } ;;
  esac
}

subcmd=""
skip_value=0
for arg in "$@"; do
  if [ "$skip_value" = "1" ]; then skip_value=0; continue; fi
  case "$arg" in
    +*) ;;                                             # rustup toolchain override
    --color|--explain|-C|--config|-Z) skip_value=1 ;;  # these take a value
    -*) ;;
    *) subcmd="$arg"; break ;;
  esac
done

# Scan only the args cargo parses — everything after `--` is the user's program.
has_resolution_flag() {
  local a
  for a in "$@"; do
    [ "$a" = "--" ] && return 1
    case "$a" in --locked|--frozen|--offline) return 0 ;; esac
  done
  return 1
}

# Walk up for a lockfile: cargo is routinely run from a workspace
# subdirectory, so checking only ./Cargo.lock would skip --locked for most
# real invocations. Records the directory in LOCK_DIR.
has_lockfile() {
  local d="$PWD"
  LOCK_DIR=""
  while [ -n "$d" ] && [ "$d" != "/" ]; do
    [ -f "$d/Cargo.lock" ] && { LOCK_DIR="$d"; return 0; }
    d="$(dirname "$d")"
  done
  [ -f "/Cargo.lock" ] && { LOCK_DIR="/"; return 0; }
  return 1
}

# --locked is OURS, so say so when it is about to bite: after a Cargo.toml edit
# cargo stops with "cannot update the lock file ... because --locked was passed
# to prevent this" (MEASURED, cargo 1.93.1, on this plain path), naming a flag
# the caller never typed. Parity with the role wrapper, which records the
# measurement; fires only when a manifest is newer than the lockfile.
locked_note() {
  local m
  for m in "$PWD/Cargo.toml" "${LOCK_DIR%/}/Cargo.toml"; do
    if [ -f "$m" ] && [ "$m" -nt "${LOCK_DIR%/}/Cargo.lock" ]; then
      echo "[supply-chain-harden] note: this cargo wrapper adds --locked because a Cargo.lock exists, and $m is newer than it. If cargo stops with \"--locked was passed\", that flag is ours: record the change with 'cargo update --workspace', then build again." >&2
      return 0
    fi
  done
  return 0
}

# Insert EXTRA immediately after the subcommand, never appended:
# `cargo run -- prog` would otherwise hand the flag to prog.
exec_with() {
  local extra="$1"; shift
  local -a out=()
  local inserted=0 a
  for a in "$@"; do
    out+=("$a")
    if [ "$inserted" = "0" ] && [ "$a" = "$subcmd" ]; then
      out+=("$extra"); inserted=1
    fi
  done
  run_real "${out[@]}"
}

# Replace the subcommand token IN PLACE. Order matters: rustup requires
# `+toolchain` to be the first argument, so rebuilding as `<sub> <rest>` and
# appending leading globals produces `cooldown build +nightly`, which rustup
# rejects.
exec_sub() {
  local b="$1" c="$2"; shift 2
  local -a out=()
  local done_sub=0 a
  for a in "$@"; do
    if [ "$done_sub" = "0" ] && [ "$a" = "$subcmd" ]; then
      out+=("$b" "$c"); done_sub=1
    else
      out+=("$a")
    fi
  done
  run_real "${out[@]}"
}

# Occupy cargo-cooldown's TOP precedence level (environment) with this run's
# policy, instead of leaving it to the caller. Parity with the role's
# templates/cargo-wrapper.sh.j2, which carries the full measurement record:
# cargo-cooldown ranks env > member > workspace > $CARGO_HOME/cooldown.toml, so
# any of ten exported variables, or simply relocating CARGO_HOME, switched the
# gate off while the rows still read healthy.
#
# ONE SPELLING PER SETTING. COOLDOWN_ENFORCEMENT is a compat alias of
# COOLDOWN_INCOMPATIBLE_PUBLISH_AGE (likewise *_CARGO_COMPATIBLE_ACCEPT of
# *_FALLBACK_ACCEPT), and cargo-cooldown ABORTS when both are set and disagree.
# This surface writes "fallback" whenever strict=false, so exporting
# ENFORCEMENT=strict here would have failed every non-strict CI build. MEASURED:
#   Error: environment defines incompatible `COOLDOWN_ENFORCEMENT` and
#   `COOLDOWN_INCOMPATIBLE_PUBLISH_AGE` values
# Aliases are cleared; only canonical names are pinned, to the values the
# cooldown.toml above was written with.
#
# NOT A FIX FOR A COMMITTED cooldown.toml. The pins win for every setting that
# has an environment form (global and crates.io windows, now, skip_registries,
# the violation action, the lockfile baseline), but `[allow.global] minutes`,
# `[[allow.package]]`, `[[allow.exact]]` and `[registries.<alt>]` windows have
# none, and a repo's cooldown.toml can still use them to loosen the gate.
# MEASURED on cargo-cooldown 0.3.5: `[allow.global] minutes = 0` committed next
# to Cargo.toml still admits a crate published hours ago. Treat a cooldown.toml
# in an untrusted repo as a bypass.
# Does the real cargo have the native publish-age gate (stable since 1.100)?
# RUSTUP_AUTO_INSTALL=0 so a version probe can never download a toolchain.
cargo_has_native_gate() {
  _ng_minor=$(RUSTUP_AUTO_INSTALL=0 "$REAL_CARGO" --version 2>/dev/null | sed -n 's/^cargo 1\.\([0-9][0-9]*\)\..*/\1/p')
  [ -n "$_ng_minor" ] && [ "$_ng_minor" -ge 100 ]
}

sanitize_cooldown_env() {
  _sc_env=$(env)
  _sc_had=''
  for _sc_v in COOLDOWN_MINUTES COOLDOWN_ENFORCEMENT COOLDOWN_INCOMPATIBLE_PUBLISH_AGE \
               COOLDOWN_FALLBACK_ACCEPT COOLDOWN_CARGO_COMPATIBLE_ACCEPT \
               COOLDOWN_LOCKFILE_BASELINE COOLDOWN_NOW COOLDOWN_SKIP_REGISTRIES \
               CARGO_REGISTRY_GLOBAL_MIN_PUBLISH_AGE CARGO_REGISTRY_MIN_PUBLISH_AGE; do
    if printf '%s\n' "$_sc_env" | grep -q "^$_sc_v="; then
      _sc_had="$_sc_had $_sc_v"
    fi
    unset "$_sc_v"
  done
  # Per-registry windows (CARGO_REGISTRIES_<NAME>_MIN_PUBLISH_AGE): names match a
  # fixed [A-Za-z0-9_] pattern, so the word-split cannot carry anything else.
  for _sc_v in $(printf '%s\n' "$_sc_env" | sed -n 's/^\(CARGO_REGISTRIES_[A-Za-z0-9_]*_MIN_PUBLISH_AGE\)=.*/\1/p'); do
    _sc_had="$_sc_had $_sc_v"
    unset "$_sc_v"
  done
  # A dashed name (CARGO_REGISTRIES_my-reg_MIN_PUBLISH_AGE) is a valid registry
  # name to cargo-cooldown but not an identifier to bash, so it cannot be unset.
  if printf '%s\n' "$_sc_env" | grep -q '^CARGO_REGISTRIES_[^=]*[^A-Za-z0-9_=][^=]*_MIN_PUBLISH_AGE='; then
    echo "[supply-chain-harden] error: a CARGO_REGISTRIES_*_MIN_PUBLISH_AGE variable with a non-identifier name is set; this wrapper cannot clear it and it would override this run's publish-age window. Unset it and retry." >&2
    exit 2
  fi
  if [ -n "$_sc_had" ]; then
    echo "[supply-chain-harden] note: overriding caller publish-age setting(s):$_sc_had - this run's __RELEASE_AGE_HOURS__h/__VIOLATION_ACTION__ policy applies instead." >&2
  fi
  export COOLDOWN_MINUTES=__MIN_AGE_MIN__
  # The crates.io window, read by CARGO-COOLDOWN (a repo cooldown.toml's
  # `[registry] min-publish-age` otherwise sets it). Cargo itself gates nothing
  # on this name. MEASURED (itoa = "1", "365 days"): cargo 1.100.0 locked the
  # newest itoa and printed nothing; cargo 1.99.0 locked the newest too and
  # printed "warning: ignoring `registry.min-publish-age` without
  # `-Zmin-publish-age`", so on 1.99 each routed build shows that line.
  # Cargo's own gate is CARGO_REGISTRY_GLOBAL_MIN_PUBLISH_AGE, from 1.100. See
  # the role's templates/cargo-wrapper.sh.j2 for the measurement.
  export CARGO_REGISTRY_MIN_PUBLISH_AGE="__RELEASE_AGE_HOURS__ hours"
  export COOLDOWN_INCOMPATIBLE_PUBLISH_AGE=__VIOLATION_ACTION__
  export COOLDOWN_LOCKFILE_BASELINE=floor
  export COOLDOWN_FALLBACK_ACCEPT=auto
  # The real clock and an empty skip list replace a repo cooldown.toml's
  # `now` / `skip_registries`.
  export COOLDOWN_NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  export COOLDOWN_SKIP_REGISTRIES=
  # cargo >= 1.100 has a NATIVE publish-age gate. When a config.toml sets it,
  # cargo applies it to cargo-cooldown's own internal resolves as well, and an
  # [[allow.exact]] pin then hard-fails inside cargo-cooldown's temporary
  # workspace while a loose requirement is silently cooled. MEASURED on cargo
  # 1.100.0 + cargo-cooldown 0.3.5. On this path cargo-cooldown IS the gate
  # (it still denies and cools with this set, measured), so the native resolver
  # is told to defer to it: MEASURED on cargo 1.100.0, a 365-day
  # CARGO_REGISTRY_GLOBAL_MIN_PUBLISH_AGE with this set locked the newest itoa,
  # silently. Only on 1.100+: cargo 1.99.0 gates nothing either way and prints
  # "warning: ignoring `resolver.incompatible-publish-age` without
  # `-Zmin-publish-age`" for it (MEASURED).
  if cargo_has_native_gate; then
    export CARGO_RESOLVER_INCOMPATIBLE_PUBLISH_AGE=allow
  fi
}

case "$subcmd" in
  build|b|check|c|test|t|run|r|bench|doc|d|rustc|rustdoc|tree|fetch|package|publish|clippy)
    KIND=RESOLVING ;;
  update|add|remove|rm|generate-lockfile|vendor)
    KIND=WRITER ;;
  install)
    KIND=INSTALL ;;
  ""|new|init|clean|fmt|search|login|logout|owner|yank|uninstall|locate-project|\
metadata|pkgid|read-manifest|verify-project|config|version|help|cooldown|binstall)
    KIND=QUIET ;;
  *)
    KIND=UNKNOWN ;;
esac

case "$KIND" in
  QUIET)
    run_real "$@"
    ;;

  UNKNOWN)
    # The subcommand set is open (any cargo-* on PATH, plus repo [alias]), so
    # enumerating it cannot converge. Say what is happening instead of
    # silently doing nothing — a silent pass-through and a protected build
    # are otherwise indistinguishable at the terminal.
    echo "[supply-chain-harden] note: 'cargo $subcmd' is not a recognised subcommand; no supply-chain controls applied to this invocation" >&2
    run_real "$@"
    ;;

  INSTALL)
    # `cargo install` takes the newest version by default and no workspace
    # lockfile applies. --locked makes it honour the lockfile the crate was
    # published with. It is NOT age-gated: an install-time crates.io check is
    # inert for binary-only crates, which is most of what this installs.
    # SCH_NET=1 so `cargo install` still routes through Socket Firewall like every
    # other network path (parity with the role wrapper; it was fully unfiltered).
    echo "[supply-chain-harden] note: 'cargo install' is not age-gated (it is routed through Socket Firewall); check the crate's publish date before installing" >&2
    if has_resolution_flag "$@"; then
      SCH_NET=1 run_real "$@"
    fi
    SCH_NET=1 exec_with "--locked" "$@"
    ;;

  WRITER)
    # These exist to change the lockfile, so --locked is contradictory.
    # `cargo update` is also the one resolution path --locked can never
    # cover, which is why the age gate matters most here.
    if cooldown_installed; then
      case "$subcmd" in
        update)
          use_cooldown
          sanitize_cooldown_env
          export SUPPLY_CHAIN_CARGO_WRAPPED=1
          SCH_NET=1 exec_sub cooldown update "$@" ;;
        *)
          # Parity with the role wrapper: add/remove/generate-lockfile/vendor
          # write Cargo.lock but cooldown has no verb for them, so warn instead
          # of falling through SILENTLY when cooldown IS installed — previously
          # only the cooldown-ABSENT branch warned, the inverted (dangerous) case.
          echo "[supply-chain-harden] warning: 'cargo $subcmd' writes Cargo.lock and is NOT age-gated; a freshly published version recorded here is trusted by later gated commands" >&2 ;;
      esac
    else
      echo "[supply-chain-harden] warning: cargo-cooldown not installed — 'cargo $subcmd' can write a lockfile entry for a freshly published crate with no age check" >&2
    fi
    SCH_NET=1 run_real "$@"
    ;;

  RESOLVING)
    if cooldown_installed; then
      case "$subcmd" in
        build|b) SUB=build ;;
        check|c) SUB=check ;;
        test|t)  SUB=test ;;
        run|r)   SUB=run ;;
        *)       SUB="" ;;
      esac
      if [ -n "$SUB" ]; then
        # The environment is pinned ONLY on the path that hands off to
        # cargo-cooldown. It used to be pinned for every resolving and writing
        # command whenever cargo-cooldown was installed, which on cargo 1.100+
        # STRIPPED a caller's native CARGO_REGISTRY_GLOBAL_MIN_PUBLISH_AGE from
        # commands cargo-cooldown never sees: MEASURED, generate-lockfile, tree
        # and fetch then resolved a version real cargo refused, and add wrote
        # it, while the note claimed this policy "applies instead".
        use_cooldown
        sanitize_cooldown_env
        export SUPPLY_CHAIN_CARGO_WRAPPED=1
        SCH_NET=1 exec_sub cooldown "$SUB" "$@"
      fi
    fi
    # No age gate available, or a subcommand cooldown has no verb for. Fall
    # back to --locked, and say so when nothing at all applies rather than
    # leaving an unprotected build indistinguishable from a gated one.
    if has_resolution_flag "$@"; then
      SCH_NET=1 run_real "$@"
    fi
    if has_lockfile; then
      locked_note
      SCH_NET=1 exec_with "--locked" "$@"
    fi
    echo "[supply-chain-harden] warning: no Cargo.lock found and this wrapper applies no publish-age gate to 'cargo $subcmd' — it will resolve the newest matching versions, checked only by cargo's own gate if you configured one" >&2
    SCH_NET=1 run_real "$@"
    ;;
esac
WRAPPER

  subst_inplace "$tmp_wrapper" "s|__REAL_CARGO__|$(sed_repl "$real_cargo")|; s|__COOLDOWN_EXE__|$(sed_repl "$cooldown_exe")|; s|__CARGO_SFW__|$(sed_repl "$CARGO_SOCKET_FIREWALL")|; s|__MIN_AGE_MIN__|$((RELEASE_AGE_HOURS * 60))|; s|__VIOLATION_ACTION__|$(sed_repl "$violation_action")|; s|__RELEASE_AGE_HOURS__|$RELEASE_AGE_HOURS|"
  $SUDO cp "$tmp_wrapper" "$wrapper_target"
  $SUDO chmod 755 "$wrapper_target"
  record_wrapper cargo
  rm -f "$tmp_wrapper"

  if [[ -n "$cooldown_bin" ]]; then
    log "cargo: wrapper at $wrapper_target (--locked injection + ${RELEASE_AGE_HOURS}h publish-age gate via cargo-cooldown)"
  else
    # Name the switch the way THIS caller sets it: the action input on GitHub,
    # the env var everywhere else (VM#14: plain mode was told to set an input
    # it does not have).
    local _cc_how="set INSTALL_CARGO_COOLDOWN=true in harden.sh's environment"
    [[ "$PLATFORM" == "github" ]] && _cc_how="set the action input install_cargo_cooldown: true"
    warn "cargo: the publish-age gate is written but NOT enforced — cargo-cooldown is not installed. --locked injection still applies. To enforce it, ${_cc_how}, or install cargo-cooldown in an earlier step."
    set_eco_status cargo PARTIAL "--locked injection active; publish-age gate written but no cargo-cooldown backend to enforce it"
    log "cargo: wrapper at $wrapper_target (--locked injection; age gate written but inert without cargo-cooldown)"
  fi
  end_section
}

harden_go() {
  section "go"

  # Go is the ONE ecosystem with no config file behind its settings — every
  # other harden_* here writes a dotfile that survives regardless of how the
  # CI propagates environment. If go were left env-var-only, its hardening
  # would silently evaporate on any platform without a step-to-step env
  # mechanism (Drone/Woodpecker per-step containers, Buildkite without the
  # hook, or a bare `harden.sh --emit=plain` whose env file nobody sources).
  #
  # `go env -w` is the file-backed equivalent: it writes os.UserConfigDir()/
  # go/env, which go reads on every invocation. Env vars still win over that
  # file, so both layers are written and they agree.
  write_env GOSUMDB     "sum.golang.org"
  write_env GOPROXY     "https://proxy.golang.org,direct"
  # GOFLAGS is NOT written (earlier versions wrote -mod=readonly). With no vendor/
  # directory that is Go's default already, and with one it makes Go IGNORE
  # vendor/: offline the build fails on a proxy.golang.org dial error that names
  # neither GOFLAGS nor this action; online it compiles the proxy copy instead
  # of the vendored one. MEASURED on go1.22.12 and go1.27.4 (defaults/main.yml,
  # goflags_mod, has the detail; the role no longer sets it either).
  write_env GOTOOLCHAIN "local"
  # Empty knobs — explicit setting means no module bypasses sumdb / proxy / HTTPS.
  write_env GOPRIVATE   ""
  write_env GONOPROXY   ""
  write_env GOINSECURE  ""
  # GONOSUMDB is REAL and is a sumdb bypass. MEASURED on go1.27.0:
  #   go env -w GONOSUMDB=example.com  -> rc 0, accepted
  #   go env -w GONOSUMCHECK=1         -> unknown go command variable
  # `go help environment` groups GOPRIVATE, GONOPROXY and GONOSUMDB as
  # prefixes 'not compared against the checksum database', and names
  # GONOSUMDB under GOINSECURE as a way to disable sumdb validation.
  # Omitted because tests/bats/10-go-adversarial.bats asserted it was not
  # a real variable - a wrong test comment is the documented reason a
  # recommended sweep (SOURCES.md:16) was dropped.
  write_env GONOSUMDB   ""

  local go_version
  go_version=$(detect_version go "go version")

  if command -v go >/dev/null 2>&1; then
    # `go env -w` validates keys and rejects unknown ones, so a failure here
    # means the host's go is too old for one of these. Non-fatal: the env
    # layer above still applies on platforms that propagate it.
    local gokey failed=""
    for gokey in \
      "GOSUMDB=sum.golang.org" \
      "GOPROXY=https://proxy.golang.org,direct" \
      "GOTOOLCHAIN=local" \
      "GOPRIVATE=" \
      "GONOPROXY=" \
      "GOINSECURE=" \
      "GONOSUMDB="
    do
      (cd / && go env -w "$gokey") 2>/dev/null || failed+="${gokey%%=*} "
    done
    # A runner hardened by an earlier version keeps GOFLAGS=-mod=readonly in its
    # go env file (self-hosted runners persist it). Remove exactly that value so
    # the host converges; any other GOFLAGS is the owner's and is left alone.
    if [[ "$(cd / && env -u GOFLAGS go env GOFLAGS 2>/dev/null)" == "-mod=readonly" ]]; then
      (cd / && go env -u GOFLAGS) 2>/dev/null \
        && log "go: removed GOFLAGS=-mod=readonly left in $(cd / && go env GOENV 2>/dev/null) by an earlier version (it made go ignore vendor/)"
    fi
    if [[ -n "$failed" ]]; then
      warn "go env -w rejected: ${failed% } — those settings rely on the env layer only on this host"
    else
      log "go: persisted to $(cd / && go env GOENV 2>/dev/null || echo "$HOME/.config/go/env") — survives without env propagation"
    fi
  else
    log "go not installed — env layer written, go env -w skipped"
    # Without go env -w the settings live only in the env layer, which does
    # not survive a step that fails to inherit it.
    set_eco_status go PARTIAL "env layer written; not persisted via go env -w because go was not installed"
  fi

  HARDENED+=("go")
  set_tool_version "go" "$go_version"
  log "go: GOSUMDB=sum.golang.org, GOPROXY=proxy.golang.org, GOTOOLCHAIN=local (GOFLAGS left to go: its default keeps go.mod/go.sum read-only and honours vendor/)"
  end_section
}

# bundler_implements_cooldown — the npm_implements() discriminator, for Ruby.
#
# `bundle config get cooldown` is NOT evidence. Measured on bundler 4.0.19: it
# echoes ANY key back, including `totally_fake_key`, exactly like
# `npm config get`. Asking bundler's own settings table is the discriminator —
# `cooldown` is registered in Bundler::Settings::NUMBER_KEYS alongside jobs,
# retry and timeout on a version that implements it, and absent on one that
# does not. That is a capability probe rather than a version guess, so it stays
# correct if the feature is backported or the version string is unusual.
bundler_implements_cooldown() {
  command -v ruby >/dev/null 2>&1 || return 1
  (cd / && ruby -e 'require "bundler"; exit(Bundler::Settings::NUMBER_KEYS.include?("cooldown") ? 0 : 1)') \
    >/dev/null 2>&1
}

harden_bundler() {
  section "bundler"
  mkdir -p "$HOME/.bundle"

  # THE AGE GATE IS THE POINT HERE, and it was missing entirely.
  #
  # Ruby is the ecosystem where install-time execution provably CANNOT be
  # blocked: RubyGems runs a native extension's extconf.rb during
  # `gem install`, before anything requires the gem, and there is no
  # --ignore-scripts equivalent. That is not theoretical — it is the live
  # vector. BufferZoneCorp (May 2026, already cited in SOURCES.md) harvested
  # env vars matching token/key/secret/aws/github and read SSH private keys
  # from extconf.rb; the StubMaker campaign published 16 typosquatted gems on
  # 2026-08-16 using the same hook to pull a 22MB loader.
  #
  # When execution cannot be blocked, refusing to RESOLVE the bad version is
  # the only lever left — which is this repo's own stated doctrine for cargo,
  # in exactly these words. Bundler grew the native control for it; we were
  # not using it.
  #
  # Units are DAYS, integer, non-negative — from bundler's own CLI banner:
  # "Only consider gem versions published at least N days ago. Use 0 to
  # disable", and dsl.rb raises InvalidOption on anything else. Same rounding
  # rule as npm: never round a sub-day window down to 0, which would silently
  # disable the gate for anyone asking for a short one.
  local bundle_age_days=$(( RELEASE_AGE_HOURS / 24 ))
  [ "$bundle_age_days" -lt 1 ] && bundle_age_days=1

  # WHAT IS DELIBERATELY NOT HERE.
  #
  # BUNDLE_DEPLOYMENT was removed. Per bundler's config reference it is
  # "equivalent to setting frozen to true AND path to vendor/bundle" — so it
  # is strictly redundant with the frozen line below, and its second half
  # silently redirects EVERY install on the host into ./vendor/bundle, for
  # every project, forever. Combined with frozen's "commands will be blocked
  # unless the lockfile can be installed exactly as written", a fresh clone
  # that gitignores its lockfile hard-fails with no advisory mode. That is the
  # self-disarming shape this repo already reasons about elsewhere: the
  # operator deletes ~/.bundle/config to unbreak their day and loses the real
  # protection with it. frozen alone gives the whole security benefit.
  #
  # BUNDLE_DISABLE_EXEC_LOAD was removed too. It changes `bundle exec` from
  # in-process `load` to Kernel.exec. Same gem code, same privileges, purely a
  # process-model knob — it was being counted as a security control and is not.
  #
  # "---" MUST be the first line. Bundler 4.1.0's YAML reader returns the
  # String "---" for a file that opens with a comment, and every bundle
  # command then dies in Settings#load_config (NoMethodError: undefined
  # method `inject' for String) -- the whole tool, not just the gate.
  # MEASURED: comment-first crashes 4.1.0; "---" then the comment reads
  # frozen/cooldown correctly on 2.4.20, 2.6.9, 4.0.13 and 4.1.0.
  {
    echo "---"
    echo "# Managed by supply-chain-harden"
    echo "BUNDLE_FROZEN: \"true\""
    echo "BUNDLE_COOLDOWN: \"$bundle_age_days\""
    # Pin the fail-safe side explicitly rather than relying on the default,
    # the same argument already made for DOTNET_NUGET_SIGNATURE_VERIFICATION:
    # a default we do not state is a default someone else can flip.
    echo "BUNDLE_DISABLE_CHECKSUM_VALIDATION: \"false\""
  } | put_user_cfg bundler "$HOME/.bundle/config"
  write_env BUNDLE_COOLDOWN "$bundle_age_days"

  HARDENED+=("bundler")
  local bundler_version
  bundler_version=$(detect_version bundler "bundler --version")
  set_tool_version "bundler" "$bundler_version"

  # Say it here when the gate cannot fire, rather than leaving it to a
  # verifier step nobody added — same rule as npm's min-release-age.
  if ! command -v bundle >/dev/null 2>&1 && ! command -v bundler >/dev/null 2>&1; then
    log "bundler: config written (frozen + ${bundle_age_days}d cooldown); bundler not installed, so nothing was probed"
    set_eco_status bundler PARTIAL "config written but bundler is not installed, so the cooldown gate could not be confirmed"
  elif bundler_implements_cooldown; then
    log "bundler: BUNDLE_FROZEN=true, BUNDLE_COOLDOWN=${bundle_age_days}d (implemented by this bundler)"
  else
    warn "bundler ${bundler_version:-<unknown>} does NOT implement BUNDLE_COOLDOWN — the age gate is written and NOT enforced. Ruby install-time execution (extconf.rb) cannot be blocked, so the age gate is the only control here. Upgrade bundler to make it effective."
    set_eco_status bundler INERT "cooldown written but this bundler does not implement it; extconf.rb execution is unblockable, so nothing is gating gem resolution"
    log "bundler: BUNDLE_FROZEN=true (cooldown written but INERT on bundler ${bundler_version:-<unknown>})"
  fi
  end_section
}

harden_deno() {
  section "deno"
  # Deno has no global config file; env vars are the only host-wide knob.
  # The role deploys a PATH wrapper that injects --minimum-dependency-age
  # — we mirror that here as the actual enforcement layer.
  HARDENED+=("deno")
  set_tool_version "deno" "$(detect_version deno "deno --version")"

  local real_deno
  real_deno=$(command -v deno 2>/dev/null || true)
  if [[ -z "$real_deno" ]]; then
    log "deno not installed — wrapper not deployed"
    # Deno has NO config file. The wrapper is the entire mechanism, so an
    # absent deno means nothing at all was applied.
    warn "deno: nothing was applied — deno has no config file and its only mechanism is a PATH wrapper, which needs deno present at hardening time"
    set_eco_status deno NONE "deno has no config file; the PATH wrapper is the entire mechanism and deno was not installed"
    end_section
    return 0
  fi

  # Wrap in place (deno installs to ~/.deno/bin/deno typically; we wrap
  # at the discovered path).
  # Gate BEFORE any filesystem mutation. On a host where deno lives in a
  # non-writable dir (system install, no root/sudo) the `mv` below would fail
  # under `set -e` and kill the whole run before the summary is written — the
  # exact "partial config, no verdict" defect this change set fixes everywhere
  # else, and it gated AFTER the mv here. deno has no config layer, so a blocked
  # wrap means NONE is enforced, not PARTIAL.
  local wrapper_path="${real_deno%-real}"
  require_privilege deno "$wrapper_path" NONE \
    "PATH wrapper not deployed (no root/sudo). deno has no config-file layer — the wrapper is its only age gate — so nothing gates deno on this host." \
    || { end_section; return 0; }

  if grep -q "supply-chain-harden" "$real_deno" 2>/dev/null; then
    if [[ -x "${real_deno}-real" ]]; then
      real_deno="${real_deno}-real"
    else
      warn "deno wrapper present but ${real_deno}-real missing; skipping re-wrap"
      end_section
      return 0
    fi
  else
    $SUDO mv "$real_deno" "${real_deno}-real"
    real_deno="${real_deno}-real"
  fi
  # Placeholders + sed rather than an interpolating heredoc — same reason as
  # the cargo wrapper: this text is dense with $ and the escaping is where
  # generated wrappers go wrong without failing loudly.
  local tmp_deno
  tmp_deno=$(mktemp)
  cat > "$tmp_deno" <<'DENOWRAP'
#!/bin/bash
# deno — supply-chain-harden wrapper
#
# Deno has no global config file, so a PATH wrapper injecting
# --minimum-dependency-age is the only host-wide age gate available.
#
# THE SUBCOMMAND IS THE FIRST NON-FLAG ARGUMENT.
#
# Reading $1 directly is wrong and was the bug here: `deno -A run app.ts` and
# `deno --quiet run app.ts` are the ordinary forms — -A especially — and with
# $1 as the subcommand they matched nothing, fell through to the pass-through
# arm, and ran with NO age gate at all. Silently: an ungated run and a gated
# one are identical at the terminal.
REAL_DENO='__REAL_DENO__'
# RUN-PROBE. Record that this wrapper actually executed.
#
# Costs nothing on a real invocation: SCH_WRAPPER_PROBE is unset, so this is
# one test. verify.sh sets it to a temp file, invokes the tool, and reads back
# which wrappers ran.
#
# It replaces inferring "did our wrapper run" from PATH position, which CANNOT
# distinguish a wrapper that was bypassed from one that is chained behind
# another wrap. MEASURED: with an Aikido safe-chain shim first on PATH, the
# wrapper ran on every call and the verifier reported "shadowed and never
# runs" at FUNCTIONAL strength -- the strongest evidence grade, asserting the
# opposite of the fact.
#
# The value is caller-controlled, so it is only ever a redirect target. Never
# interpolate it into a command.
if [ -n "${SCH_WRAPPER_PROBE:-}" ]; then
  printf '%s\n' "$0" >> "$SCH_WRAPPER_PROBE" 2>/dev/null || true
fi

if [ -z "$REAL_DENO" ] || [ ! -x "$REAL_DENO" ] || [ "$REAL_DENO" = "__WRAPPER_PATH__" ]; then
  echo "[supply-chain-harden] error: real deno not found at '$REAL_DENO'; refusing to recurse" >&2
  exit 127
fi

subcmd=""
skip_value=0
for arg in "$@"; do
  # Skip the VALUE of a value-taking global flag before the subcommand, or the
  # scan reads that value as the subcommand and misses the gate. MEASURED on
  # deno 2.9.8: `deno --log-level debug run app.ts` (and `-L debug`) are accepted
  # by deno, and without this the scan picked "debug" as the subcommand and
  # exec'd deno with NO --minimum-dependency-age. `--flag=value` is one token
  # starting with `-`, so `-*` already covers it; only separate-word values
  # matter. This mirrors the role wrapper (templates/deno-wrapper.sh.j2).
  if [ "$skip_value" = "1" ]; then skip_value=0; continue; fi
  case "$arg" in
    --config|-c|--import-map|--lock|--cert|--log-level|-L|--v8-flags|--seed)
      skip_value=1 ;;
    -*) ;;
    *) subcmd="$arg"; break ;;
  esac
done

# Only subcommands that FETCH REMOTE MODULES, and only ones that accept the
# flag. This list is deliberately narrow and matches the role's: deno ERRORS
# when given --minimum-dependency-age on a subcommand that does not take it,
# so a too-wide list does not weaken the gate, it breaks the command. `task`
# was in this list and is exactly that hazard — it is how most deno projects
# invoke everything. MEASURED on deno 2.9.5: `deno doc` parses the flag as a
# positional module path ("Module not found …/--minimum-dependency-age=…") and
# `deno publish` rejects it — both broke under the wrapper, so both are dropped.
# Version of the REAL deno, read at run time, for the two subcommands whose
# handling depends on it (a deno upgrade does not re-run the hardening). Pure
# bash, no `sort -V`: the action's copy of this wrapper also runs on macOS.
deno_ver_ge() { # <x.y.z>: is the real deno at least this version?
  local v IFS=.
  v=$("$REAL_DENO" --version 2>/dev/null | sed -n 's/^deno \([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -n 1)
  [ -n "$v" ] || return 1
  local -a have=($v) want=($1)
  local i
  for i in 0 1 2; do
    if [ "${have[$i]}" -gt "${want[$i]}" ]; then return 0; fi
    if [ "${have[$i]}" -lt "${want[$i]}" ]; then return 1; fi
  done
  return 0
}

# exec the real deno with EXTRA[@] placed directly after the subcommand.
exec_with_extra() {
  local new_args=() inserted=0 arg
  for arg in "$@"; do
    new_args+=("$arg")
    if [ "$inserted" = "0" ] && [ "$arg" = "$subcmd" ]; then
      new_args+=("${EXTRA[@]}")
      inserted=1
    fi
  done
  exec "$REAL_DENO" "${new_args[@]}"
}

case "$subcmd" in
  run|cache|install|test|compile|eval|bench)
    EXTRA=("--minimum-dependency-age=__MIN_AGE__")
    exec_with_extra "$@"
    ;;
  info)
    # `deno info` accepts the flag only from 2.8.3. MEASURED on 2.8.2: "error:
    # unexpected argument '--minimum-dependency-age' found", so injecting it
    # unconditionally broke `deno info` outright on older deno.
    if deno_ver_ge 2.8.3; then
      EXTRA=("--minimum-dependency-age=__MIN_AGE__")
      exec_with_extra "$@"
    fi
    exec "$REAL_DENO" "$@"
    ;;
  x)
    # `deno x` fetches and EXECUTES a package, and runs its npm lifecycle
    # scripts, and its dependencies', with no prompt. MEASURED on 2.7.14, 2.8.3,
    # 2.9.3 and 2.9.8 (also under a pseudo-terminal): postinstall markers
    # written, and neither ~/.npmrc ignore-scripts, NPM_CONFIG_IGNORE_SCRIPTS nor
    # this wrapper (which did not handle `x`) stopped it. `--ignore-scripts`
    # does, measured on 2.9.3 and 2.9.8. Below 2.9.3 that flag is unmeasured
    # for `x`, so refuse rather than run the scripts.
    if deno_ver_ge 2.9.3; then
      EXTRA=("--ignore-scripts")
      exec_with_extra "$@"
    fi
    echo "[supply-chain-harden] refusing 'deno x' on this deno (below 2.9.3): it runs the package's install scripts with no prompt, and only deno 2.9.3+ has a measured --ignore-scripts for it. Upgrade deno, or run the package with 'deno run npm:<pkg>'." >&2
    exit 1
    ;;
  *)
    exec "$REAL_DENO" "$@"
    ;;
esac
DENOWRAP
  subst_inplace "$tmp_deno" "s|__REAL_DENO__|$(sed_repl "$real_deno")|; s|__WRAPPER_PATH__|$(sed_repl "$wrapper_path")|; s|__MIN_AGE__|$DENO_AGE_ISO|"
  $SUDO cp "$tmp_deno" "$wrapper_path"
  rm -f "$tmp_deno"
  $SUDO chmod 755 "$wrapper_path"
  log "deno: wrapper deployed at $wrapper_path (injects --minimum-dependency-age=$DENO_AGE_ISO)"
  record_wrapper deno
  end_section
}

harden_maven() {
  section "maven"
  mkdir -p "$HOME/.m2"
  put_user_cfg maven "$HOME/.m2/settings.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!-- Managed by supply-chain-harden action -->
<settings xmlns="http://maven.apache.org/SETTINGS/1.0.0">
  <servers/>
  <mirrors>
    <!-- Force HTTPS Maven Central — refuses HTTP-only repos -->
    <mirror>
      <id>central-https-only</id>
      <mirrorOf>external:http:*</mirrorOf>
      <name>HTTPS-only mirror</name>
      <url>https://repo.maven.apache.org/maven2</url>
      <blocked>true</blocked>
    </mirror>
  </mirrors>
  <!-- Integrity: refuse an artifact whose content does not match its published
       checksum (Maven's default is 'warn', which installs anyway). This covers
       Central-sourced artifacts; the role additionally routes ALL repos through
       Central (mirrorOf=*), which the action does not, to avoid breaking a
       project's own HTTPS repositories.
       Maven keeps TWO repository lists, and the super POM declares 'central'
       in both: <repositories> for dependencies, <pluginRepositories> for
       plugins. Redefining it only under <repositories> left plugin jars, code
       that runs inside the build, on 'warn'. MEASURED (maven 3.9.11, a plugin
       jar served with a wrong .sha1): two checksum WARNINGs and BUILD SUCCESS,
       while a dependency jar with a wrong .sha1 failed the build.
       Both entries restore the super POM's <snapshots><enabled>false</enabled>
       too: without it the redefinition turned snapshot lookups on Central back
       on (MEASURED). The plugin entry keeps the super POM's updatePolicy=never. -->
  <profiles>
    <profile>
      <id>strict-checksums</id>
      <repositories>
        <repository>
          <id>central</id>
          <url>https://repo.maven.apache.org/maven2</url>
          <releases><checksumPolicy>fail</checksumPolicy></releases>
          <snapshots><enabled>false</enabled></snapshots>
        </repository>
      </repositories>
      <pluginRepositories>
        <pluginRepository>
          <id>central</id>
          <url>https://repo.maven.apache.org/maven2</url>
          <releases><updatePolicy>never</updatePolicy><checksumPolicy>fail</checksumPolicy></releases>
          <snapshots><enabled>false</enabled></snapshots>
        </pluginRepository>
      </pluginRepositories>
    </profile>
  </profiles>
  <activeProfiles>
    <activeProfile>strict-checksums</activeProfile>
  </activeProfiles>
</settings>
EOF
  HARDENED+=("maven")
  set_tool_version "maven" "$(detect_version maven "mvn --version")"
  log "maven: HTTPS-only mirror enforced; HTTP repos blocked; strict checksums (fail) on Central, for dependencies and plugins"
  end_section
}

harden_gradle() {
  section "gradle"

  # WHERE GRADLE ACTUALLY LOOKS.
  #
  # Gradle resolves its user home as $GRADLE_USER_HOME, and when that is unset
  # as <user.home>/.gradle — where user.home is a JVM system property that on
  # Linux comes from the PASSWD ENTRY, not from $HOME. MEASURED (gradle 8.14.3
  # on openjdk-21, linux-arm64): with HOME=/tmp/.../fakehome,
  # System.getProperty("user.home") was still /home/vscode and gradle loaded
  # NO init script from fakehome/.gradle.
  #
  # So the Axis-5 fix that is sufficient for uv/bun/cargo — resolve the tool's
  # own env var, `${GRADLE_USER_HOME:-$HOME/.gradle}` — is NOT sufficient here,
  # because the DEFAULT is passwd-derived rather than $HOME-derived. This
  # function used to write a bare $HOME/.gradle, so on every host where $HOME
  # diverges from the passwd home (docker run -u <uid>, OpenShift's arbitrary
  # uids, sudo -E, any runner that relocates HOME) the init script was written,
  # was correct, and was never read.
  #
  # BOTH halves of the fix are applied, because either alone leaves a hole:
  #   1. write into the home gradle will resolve on its own — the passwd home
  #      when GRADLE_USER_HOME is unset. This is the layer that survives a
  #      build which never sees our env layer at all (container CMD, systemd:
  #      Axis 2), which is why (2) alone is not enough.
  #   2. export GRADLE_USER_HOME at exactly the directory we wrote, so there is
  #      no ambiguity left for a later step to resolve differently — and so
  #      that a passwd home we could NOT write to (an arbitrary uid has no
  #      passwd entry at all, and $HOME is then the only writable home) is
  #      redirected to the home we did use. This is why (1) alone is not
  #      enough either.
  # Unlike the role, exporting here is safe: harden.sh's env layer is scoped to
  # one CI job running as one user, not a system-wide /etc/profile.d shared by
  # every account on a long-lived host.
  local gradle_home="" passwd_home="" uid
  if [[ -n "${GRADLE_USER_HOME:-}" ]]; then
    gradle_home="$GRADLE_USER_HOME"
  else
    # id -u, never $USER/$LOGNAME: those are env-derived and can lie in exactly
    # the relocated-HOME containers this resolution exists for. getent is
    # missing from some minimal images, so fall back to /etc/passwd directly.
    uid=$(id -u)
    passwd_home=$(getent passwd "$uid" 2>/dev/null | cut -d: -f6) || passwd_home=""
    if [[ -z "$passwd_home" ]]; then
      passwd_home=$(awk -F: -v u="$uid" '$3 == u { print $6; exit }' /etc/passwd 2>/dev/null) || passwd_home=""
    fi
    if [[ -n "$passwd_home" && -d "$passwd_home" && -w "$passwd_home" ]]; then
      gradle_home="$passwd_home/.gradle"
      if [[ "$passwd_home" != "${HOME:-}" ]]; then
        log "gradle: \$HOME is '${HOME:-<unset>}' but the passwd home is '$passwd_home' — writing the init script where the JVM will look, and pinning GRADLE_USER_HOME to it"
      fi
    else
      gradle_home="${HOME:-.}/.gradle"
      warn "gradle: no writable passwd home for uid $uid (passwd says '${passwd_home:-<none>}'), so the init script goes to '$gradle_home' and GRADLE_USER_HOME is exported to point gradle at it. A gradle build that does not inherit this job's environment will not load it."
    fi
  fi

  mkdir -p "$gradle_home"
  cat > "$gradle_home/init.gradle.kts" <<'EOF'
// Managed by supply-chain-harden action
// Enforce HTTPS-only repositories in EVERY scope gradle fetches from, and block
// dynamic versions. Not just project repositories: buildscript{} and the
// settings pluginManagement{} / dependencyResolutionManagement{} fetch and
// EXECUTE plugin / build-classpath code at configuration time — the
// install-time-admission threat this scopes itself to — and Ivy repos count
// alongside Maven. (ECH-171: the old script covered only project
// MavenArtifactRepository, so http in buildscript/pluginManagement/ivy passed.)
val rejectHttp: (org.gradle.api.artifacts.repositories.ArtifactRepository) -> Unit = { repo ->
  val url = when (repo) {
    is org.gradle.api.artifacts.repositories.MavenArtifactRepository -> repo.url.toString()
    is org.gradle.api.artifacts.repositories.IvyArtifactRepository -> repo.url.toString()
    else -> null
  }
  if (url != null && url.startsWith("http://")) {
    throw GradleException("supply-chain-harden: refusing HTTP repo: $url (use HTTPS)")
  }
}
// Refuse dynamic / changing version selectors (1.+, latest.release, -SNAPSHOT)
// in EVERY configuration gradle resolves code from (CMP 4.6). Plugins resolve
// into a SCRIPT classpath - a project's buildscript.configurations for its
// plugins{} / buildscript{}, the settings script's for the same blocks in
// settings.gradle - which allprojects{configurations} does not reach. MEASURED
// (gradle 8.14.3 and 9.1.0): with project configurations only, a 1.+ plugin in
// any of those four places resolved and its code RAN.
// When this fires gradle reports "Resolution strategy disallows usage of
// dynamic versions" (or "... of changing versions"); that refusal comes from
// this file.
val refuseDynamic: (org.gradle.api.artifacts.Configuration) -> Unit = { conf ->
  conf.resolutionStrategy.failOnDynamicVersions()
  conf.resolutionStrategy.failOnChangingVersions()
}
beforeSettings {
  pluginManagement.repositories.all { rejectHttp(this) }
  dependencyResolutionManagement.repositories.all { rejectHttp(this) }
  buildscript.configurations.all { refuseDynamic(this) }
}
allprojects {
  repositories.all { rejectHttp(this) }
  buildscript.repositories.all { rejectHttp(this) }
  configurations.all { refuseDynamic(this) }
  buildscript.configurations.all { refuseDynamic(this) }
}
EOF
  # Layer 2 of the fix above. Written AFTER the file exists so the value we
  # publish is always a directory we actually populated.
  write_env GRADLE_USER_HOME "$gradle_home"
  HARDENED+=("gradle")
  set_tool_version "gradle" "$(detect_version gradle "gradle --version")"
  log "gradle: HTTPS-only repos enforced, dynamic versions blocked for dependencies and plugin classpaths (init script at $gradle_home/init.gradle.kts; GRADLE_USER_HOME pinned to $gradle_home)"
  end_section
}

harden_nuget() {
  section "nuget"
  # The dotnet CLI reads ONLY <cli-home>/.nuget/NuGet/NuGet.Config. It does NOT
  # read $HOME/.config/NuGet/NuGet.Config, and XDG_CONFIG_HOME / XDG_DATA_HOME
  # do not move it. MEASURED on SDK 6.0.428, 8.0.424, 9.0.317 and 10.0.400
  # (linux-arm64) three ways: `dotnet nuget config paths` lists only the .nuget
  # path; a decoy source planted under ~/.config/NuGet never shows in
  # `dotnet nuget list source`; a fresh profile auto-creates the stock config at
  # the .nuget path. This wrote to ~/.config until ECH-157, which made the whole
  # CI-side nuget hardening — source allowlist, signatureValidationMode,
  # trustedSigners — inert. tasks/nuget.yml always used the correct path.
  # The cli home itself is NOT $HOME when DOTNET_CLI_HOME is set: MEASURED on
  # 9.0.317, `HOME=a DOTNET_CLI_HOME=b dotnet nuget config paths` reports
  # b/.nuget/NuGet/NuGet.Config. Resolve it the tool's way (Axis 5).
  local nuget_home="${DOTNET_CLI_HOME:-$HOME}/.nuget/NuGet"
  mkdir -p "$nuget_home"
  put_user_cfg nuget "$nuget_home/NuGet.Config" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<!-- Managed by supply-chain-harden action -->
<configuration>
  <packageSources>
    <clear />
    <add key="nuget.org" value="https://api.nuget.org/v3/index.json" protocolVersion="3" />
  </packageSources>
  <config>
    <add key="signatureValidationMode" value="require" />
  </config>
  <!-- nuget.org ROTATES this certificate. All three fingerprints must be listed or
       packages signed under a rotation we do not trust fail with NU3034 and the
       install is refused — signatureValidationMode=require makes that fatal.
       SOURCE OF TRUTH: nuget.org's repository-signatures index,
         https://api.nuget.org/v3-index/repository-signatures/5.0.0/index.json
       These three SHA-256 fingerprints match the three it lists, exactly (checked
       2026-11-19); the validity windows below are its notBefore / notAfter.
       THE CURRENT CERTIFICATE EXPIRES 2027-05-18. nuget.org has to rotate before
       then: add the new fingerprint as soon as that index lists it, or every
       package repository-signed after the rotation is refused.
       2024 rotation notice:
         https://devblogs.microsoft.com/dotnet/the-nuget-org-repository-signing-certificate-will-be-updated-as-soon-as-april-8th-2024/ -->
  <trustedSigners>
    <repository name="nuget.org" serviceIndex="https://api.nuget.org/v3/index.json">
      <!-- current: valid 2024-02-23 to 2027-05-18 -->
      <certificate fingerprint="1F4B311D9ACC115C8DC8018B5A49E00FCE6DA8E2855F9F014CA6F34570BC482D" hashAlgorithm="SHA256" allowUntrustedRoot="false" />
      <!-- previous: valid 2021-02-16 to 2024-05-15 -->
      <certificate fingerprint="5A2901D6ADA3D18260B9C6DFE2133C95D74B9EEF6AE0E5DC334C8454D1477DF4" hashAlgorithm="SHA256" allowUntrustedRoot="false" />
      <!-- original (not an intermediate): valid 2018-04-10 to 2021-04-14; kept for packages whose repository signature was made with it -->
      <certificate fingerprint="0E5F38F57DC1BCC806D8494F4F90FBCEDD988B46760709CBEEC6F4219AA6157D" hashAlgorithm="SHA256" allowUntrustedRoot="false" />
    </repository>
  </trustedSigners>
</configuration>
EOF
  # The env layer OVERRIDES the config file in both directions, on every SDK.
  # MEASURED: DOTNET_NUGET_SIGNATURE_VERIFICATION=false disables signature
  # enforcement on 6.0.428/8.0.424/9.0.317/10.0.400 regardless of
  # signatureValidationMode=require above — so an attacker-controlled or merely
  # careless env var silently disarms the file. Setting it =true pins the safe
  # side of that conflict AND buys real enforcement on the 6.x tier, where the
  # config key alone is accepted-and-inert: MEASURED, 6.0.428 parses
  # signatureValidationMode=require and restores an unsigned package anyway,
  # but refuses with NU3004 once this variable is true. 8.0.424+ enforce the
  # config key on their own; setting it true there is a no-op that keeps a
  # later `=false` from being the last word. (ECH-165, Axis 1.)
  write_env DOTNET_NUGET_SIGNATURE_VERIFICATION true
  HARDENED+=("nuget")
  set_tool_version "nuget" "$(detect_version nuget "dotnet nuget --version")"
  log "nuget: nuget.org only, signature validation required (config + DOTNET_NUGET_SIGNATURE_VERIFICATION=true)"
  end_section
}

# ---- Optional: Socket Firewall + npm wrapper ----

# _sch_realpath <path>: the file <path> names, every symlink followed.
# `readlink -f`, which macOS has only since 12.3.
_sch_realpath() {
  local p="$1" l d n=0
  while [[ -L "$p" ]]; do
    n=$((n + 1))
    [[ "$n" -le 40 ]] || return 1
    l=$(readlink "$p") || return 1
    case "$l" in
      /*) p="$l" ;;
      *)  p="${p%/*}/$l" ;;
    esac
  done
  d=$(cd -P -- "$(dirname -- "$p")" 2>/dev/null && pwd -P) || return 1
  printf '%s/%s\n' "${d%/}" "${p##*/}"
}

# sfw_seed_binary <sfw>: puts the pinned firewall binary in that sfw's cache.
# Prints why not, and returns 1, when it does not.
#
# sfw's npm package is a launcher: it asks the GitHub API which binary to
# download, with no credentials, and that quota (60 calls an hour per IP) is
# shared by every job on a hosted runner's address. MEASURED 2026-11-23: with
# api.github.com answering 403, sfw 2.0.6 exits 1 within 0.3 s and this script
# moved it aside, while the same binary still downloaded from its release URL;
# and sfw runs over a cache laid out by hand as it lays it out itself
# (.sfw-cache/<release>/<asset>, with .sfw-cache/latest a symlink to it), its
# update check due or not. The role does the same for a host's first install
# (tasks/sfw_seed.yml).
#
# Nothing unverified reaches the cache, which sfw runs without checking again,
# for root too. The download is this account's, in a directory of its own. The
# account that installed sfw (root, with sudo) copies it into a directory only
# it can enter, inside sfw's package directory, hashes THAT copy, and renames it
# into the cache. It refuses a package or cache directory another account could
# write, and never replaces a binary sfw has cached.
sfw_seed_binary() {
  local shim pkg plat asset want url tmp out rc=0 place
  shim=$(_sch_realpath "$1") || { echo "$1 could not be resolved"; return 1; }
  pkg=${shim%/*}; pkg=${pkg%/*}
  if ! grep -Eqs '"name": *"sfw"' "$pkg/package.json"; then
    echo "$1 is not the sfw npm package"; return 1
  fi
  if [[ -e "$pkg/.sfw-cache/latest" ]]; then
    echo "a binary is already cached"; return 1
  fi
  # The platform as sfw sees it (mapPlatform and mapArch in its dist/sfw.mjs):
  # the Node that runs sfw, which need not match the kernel.
  plat=$(cd / && node -p 'process.platform + "-" + process.arch' 2>/dev/null) || plat=""
  case "$plat" in
    linux-x64)    asset=sfw-free-linux-x86_64; want=$SFW_BINARY_SHA256_LINUX_X86_64 ;;
    linux-arm64)  asset=sfw-free-linux-arm64;  want=$SFW_BINARY_SHA256_LINUX_ARM64 ;;
    darwin-x64)   asset=sfw-free-macos-x86_64; want=$SFW_BINARY_SHA256_MACOS_X86_64 ;;
    darwin-arm64) asset=sfw-free-macos-arm64;  want=$SFW_BINARY_SHA256_MACOS_ARM64 ;;
    *) echo "no binary is pinned for ${plat:-an unknown platform}"; return 1 ;;
  esac
  url="https://github.com/SocketDev/sfw-free/releases/download/${SFW_BINARY_VERSION}/${asset}"
  tmp=$(mktemp -d) || { echo "no temporary directory for the download"; return 1; }
  if command -v curl >/dev/null 2>&1; then
    out=$(cd / && run_bounded 300 curl -fsSL --proto '=https' -o "$tmp/$asset" "$url" 2>&1) || rc=$?
  elif command -v wget >/dev/null 2>&1; then
    out=$(cd / && run_bounded 300 wget -q -O "$tmp/$asset" "$url" 2>&1) || rc=$?
  else
    rc=127; out="neither curl nor wget is installed"
  fi
  if [[ "$rc" -ne 0 ]]; then
    rm -rf -- "$tmp"
    out=$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)
    echo "downloading it failed (exit $rc${out:+: $out})"
    return 1
  fi
  # POSIX sh and BSD or GNU tools: macOS has shasum and no sha256sum, and its mv
  # has no -T. Not inside the $( ) below: bash 3.2 misreads a case pattern there.
  place='
    set -f
    umask 022
    src=$1 pkg=$2 rel=$3 asset=$4 want=$5
    cache=$pkg/.sfw-cache
    no() { echo "$1"; exit 1; }
    for d in "$pkg" "$cache" "$cache/$rel"; do
      if [ ! -e "$d" ] && [ ! -L "$d" ]; then continue; fi
      if [ -L "$d" ] || [ ! -d "$d" ]; then no "$d is not a directory"; fi
      set -- $(ls -ldn "$d")
      case "$1" in
        ?????w*|????????w*) no "$d can be written by other accounts ($1)" ;;
      esac
      [ "$3" = "$(id -u)" ] || no "$d belongs to uid $3, and sfw was installed by uid $(id -u)"
    done
    stage=$(mktemp -d "$pkg/.sfw-seed.XXXXXX") || no "no temporary directory could be made in $pkg"
    trap "rm -rf -- \"\$stage\"" 0
    trap "exit 1" 1 2 15
    cp "$src" "$stage/$asset" || no "the download could not be copied into $pkg"
    if command -v sha256sum >/dev/null 2>&1; then
      have=$(sha256sum < "$stage/$asset")
    else
      have=$(shasum -a 256 < "$stage/$asset")
    fi
    have=${have%% *}
    [ "$have" = "$want" ] || no "the download has sha256 ${have:-unknown}, not the pinned $want"
    if [ -e "$cache/latest" ]; then no "a binary is already cached"; fi
    chmod 0755 "$stage/$asset" \
      && mkdir -p "$cache/$rel" && chmod 0755 "$cache" "$cache/$rel" \
      && mv -f "$stage/$asset" "$cache/$rel/$asset" \
      && ln -s "$cache/$rel/$asset" "$stage/latest" \
      && mv -f "$stage/latest" "$cache/latest" \
      || no "it could not be put in $cache"
  '
  out=$(cd / && run_bounded 120 $SUDO sh -c "$place" sh "$tmp/$asset" "$pkg" "$SFW_BINARY_VERSION" "$asset" "$want" 2>&1) || rc=$?
  rm -rf -- "$tmp"
  if [[ "$rc" -ne 0 ]]; then
    echo "${out:-putting it in the cache failed (exit $rc)}" | tail -n 1
    return 1
  fi
}

install_sfw_and_wrap() {
  section "Socket Firewall"

  if ! command -v npm >/dev/null 2>&1; then
    log "npm not installed — skipping sfw"
    end_section
    return 0
  fi

  local node_major
  node_major=$(cd / && node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
  if [[ "$node_major" -lt 20 ]]; then
    warn "sfw requires Node >= 20 (host has $node_major); skipping"
    end_section
    return 0
  fi

  # Install with the npm we DISCOVERED, by absolute path. Bare `sudo npm`
  # resolves against root's secure_path, which on a setup-node runner does not
  # contain the toolcache npm at all — so this either failed outright or
  # installed sfw into a different node prefix than the one the job uses.
  #
  # Pinned and --ignore-scripts, like the role's own tool installs (ECH-185):
  # a floating `sfw@2` gave this enforcement tool no age gate at all.
  #
  # umask 022, as for the warm below: every account runs this package, and only
  # root may write it. MEASURED (6c77f4e, root under umask 0000):
  # /usr/local/lib/node_modules/sfw and dist/sfw.mjs were left 0777, so any
  # account could replace the code root runs on its next npm call. A caller's
  # 077, which sudo merges with its own umask, would instead make it unreadable
  # to everyone but root.
  local npm_bin
  npm_bin=$(command -v npm)
  #
  # An npm cache of its own for this one call. sudo keeps the caller's HOME on
  # macOS, so root's npm left root-owned files in ~/.npm, and every later npm
  # install of the caller failed: MEASURED on macos-15 and macos-15-intel,
  # "EACCES ... Your cache folder contains root-owned files".
  (cd / && $SUDO sh -c 'umask 022; npm_config_cache=$(mktemp -d) || exit 1; export npm_config_cache; trap "rm -rf -- \"\$npm_config_cache\"" 0; "$@"' sh "$npm_bin" install -g --ignore-scripts "sfw@${SFW_NPM_VERSION}") >/dev/null 2>&1 || {
    warn "sfw global install failed; skipping wrapper deployment"
    end_section
    return 0
  }

  # WARM IT HERE, AND REFUSE TO WRAP IF IT CANNOT RUN. Parity with the role's
  # "Warm the Socket Firewall binary cache" task (tasks/socket.yml).
  #
  # sfw's npm package is a shim: the firewall binary is downloaded from GitHub
  # on first use, through an UNAUTHENTICATED API call (60 requests/hour per IP,
  # shared by every job on a hosted runner's address). Left cold, that fetch
  # happened inside the user's first `npm install`, and when it failed the shim
  # exited 1 there. MEASURED on sfw 2.0.6 with api.github.com refused and with
  # a 403 rate-limit reply: `npm install` rc=1, "[sfw] Failed to prepare
  # firewall binary", while this script exited 0 and reported sfw installed.
  # The first successful use took 79 s and downloaded 137 MB.
  #
  # So sfw runs now, where a failure is visible. TWICE, because the cache is
  # inside sfw's own package directory, which the install above made
  # root-owned: a warm run as the user failed on a GitHub runner with "EACCES:
  # permission denied, mkdir '/usr/local/lib/node_modules/sfw/.sfw-cache'".
  #   1. warm with the install's privilege, so the download can land;
  #   2. run as THIS user, exactly as the npm/npx wrappers will: with
  #      SFW_SKIP_UPDATE_CHECK=1, so sfw never tries to write the root-owned
  #      cache (see the wrappers below). Only if that works is anything
  #      wrapped.
  # If the first fails, the pinned binary goes into the cache and it is tried
  # once more (sfw_seed_binary); a run whose own fetch works downloads nothing
  # else. If either still fails, sfw is MOVED ASIDE so `command -v sfw` fails
  # for the cargo wrapper too, no npm/npx wrapper is deployed, and sfw_installed
  # stays false: the job runs unfiltered, says so, and builds. The target is
  # whichever `true` exists: macOS has /usr/bin/true and no /bin/true.
  local sfw_bin sfw_out sfw_rc true_bin sfw_why=""
  sfw_bin=$(command -v sfw 2>/dev/null || true)
  if [[ -z "$sfw_bin" ]]; then
    warn "sfw installed but not on PATH; skipping wrapper deployment"
    end_section
    return 0
  fi
  true_bin=/usr/bin/true; [[ -x "$true_bin" ]] || true_bin=/bin/true
  sfw_rc=0
  # umask 022 for the root warm: sudo applies the union of the caller's umask
  # and its own, and a 077 caller would leave the binary in a 0700 directory
  # that the user check below (and every other account) cannot reach.
  sfw_out=$(cd / && run_bounded 180 $SUDO sh -c 'umask 022; exec "$@"' sh "$sfw_bin" "$true_bin" 2>&1) || sfw_rc=$?
  if [[ "$sfw_rc" -ne 0 ]]; then
    if sfw_why=$(sfw_seed_binary "$sfw_bin"); then
      log "sfw could not fetch its firewall binary (rc=$sfw_rc: $(printf '%s' "$sfw_out" | grep -v '^[[:space:]]*$' | tail -n 1)); the pinned $SFW_BINARY_VERSION, its SHA-256 checked, is in its cache instead"
      sfw_rc=0
      # Without the update check: it is the call that just failed.
      sfw_out=$(cd / && run_bounded 180 $SUDO sh -c 'umask 022; SFW_SKIP_UPDATE_CHECK=1; export SFW_SKIP_UPDATE_CHECK; exec "$@"' sh "$sfw_bin" "$true_bin" 2>&1) \
        || { sfw_rc=$?; sfw_why="its SHA-256 matched and it was put in sfw's cache, but it did not run"; }
    fi
  fi
  if [[ "$sfw_rc" -eq 0 ]]; then
    sfw_out=$(cd / && SFW_SKIP_UPDATE_CHECK=1 run_bounded 120 "$sfw_bin" "$true_bin" 2>&1) || sfw_rc=$?
  fi
  if [[ "$sfw_rc" -ne 0 ]]; then
    $SUDO mv -f "$sfw_bin" "${sfw_bin}.broken" 2>/dev/null || true
    warn "sfw could not prepare its firewall binary (rc=$sfw_rc: $(printf '%s' "$sfw_out" | grep -v '^[[:space:]]*$' | tail -n 1)); it was moved aside and NO npm/npx wrapper was deployed, so installs in this job are NOT threat-intel filtered. sfw downloads that binary from the GitHub API on first use; a 403 here is usually the shared runner's unauthenticated rate limit${sfw_why:+. The pinned $SFW_BINARY_VERSION was not used instead: $sfw_why}"
    end_section
    return 0
  fi

  # Wrap npm AT THE PATH IT ACTUALLY RESOLVES TO — same rule as the bun,
  # composer, deno and cargo wrappers.
  #
  # This used to write unconditionally to /usr/local/bin/npm while taking
  # `command -v npm` as the real binary. On any runner where npm is not there
  # — which is every runner using actions/setup-node, where npm comes from
  # /opt/hostedtoolcache and is PREPENDED to PATH, and every nvm/fnm host —
  # the wrapper was written to a path that PATH never reaches. sfw was
  # installed, the wrapper existed, sfw-installed reported true, and not one
  # npm install was ever routed through it. Exactly the shadowing the bun
  # wrapper documents; it just was not applied here.
  local real_npm wrapper_target
  real_npm=$(command -v npm)
  wrapper_target="$real_npm"
  require_privilege npm "$wrapper_target" || { end_section; return 0; }

  # Shared by the npm and npx wrappers below; the cargo wrapper carries the
  # same logic. Quoted here so nothing in it expands while harden writes it.
  local sfw_guard
  sfw_guard=$(cat <<'GUARD'
# sfw runs READ-ONLY. Its cache sits in its own package directory, which a
# root `npm install -g` makes root-owned, and by default it rewrites
# .sfw-cache/next-check there once the last update check is an hour old; a
# non-root caller cannot, and sfw treats that as fatal. MEASURED (sfw 2.0.6,
# this action at 8281a6b, a non-root user): one hour after hardening, every
# npm, npx and cargo call through sfw failed with "[sfw] Failed to prepare
# firewall binary: EACCES ... next-check". SFW_SKIP_UPDATE_CHECK=1 runs the
# cached binary without writing (MEASURED: no file under the cache changed).
SFW_SKIP_UPDATE_CHECK=1; export SFW_SKIP_UPDATE_CHECK
# A COLD cache still needs a download that only root can do (MEASURED:
# "EACCES ... mkdir .sfw-cache"), unless the caller can write the cache; a
# root reinstall of sfw leaves it cold. That warns and passes through, the way
# an absent sfw does, instead of failing.
sfw_ready() {
  local s p
  command -v sfw >/dev/null 2>&1 || return 1
  [ "$(id -u)" = 0 ] && return 0
  s=$(readlink -f "$(command -v sfw)" 2>/dev/null) || return 0
  p=${s%/*}; p=${p%/*}
  [ -f "$p/package.json" ] || return 0
  [ -e "$p/.sfw-cache/latest" ] && return 0
  if [ -e "$p/.sfw-cache" ]; then [ -w "$p/.sfw-cache" ] && return 0
  else [ -w "$p" ] && return 0; fi
  echo "[supply-chain-harden] warning: sfw has no firewall binary cached that this account can run ($p/.sfw-cache), and only root can fetch it; run  sudo sh -c 'umask 022; sfw true && chmod -R go+rX $p/.sfw-cache'  once, or re-run the hardening step. Call not filtered through threat intel" >&2
  return 1
}
GUARD
)

  if grep -q "supply-chain-harden" "$real_npm" 2>/dev/null; then
    # Already wrapped in a previous run within this job — re-wrap the original.
    if [[ -x "${real_npm}-real" ]]; then
      real_npm="${real_npm}-real"
    else
      warn "npm wrapper present at $wrapper_target but ${wrapper_target}-real missing; skipping re-wrap"
      end_section
      return 0
    fi
  else
    $SUDO mv "$real_npm" "${real_npm}-real"
    real_npm="${real_npm}-real"
  fi

  cat <<EOF | $SUDO tee "$wrapper_target" >/dev/null
#!/bin/bash
# Managed by supply-chain-harden action
REAL_NPM='$real_npm'
# RUN-PROBE. Record that this wrapper actually executed.
#
# Costs nothing on a real invocation: SCH_WRAPPER_PROBE is unset, so this is
# one test. verify.sh sets it to a temp file, invokes the tool, and reads back
# which wrappers ran.
#
# It replaces inferring "did our wrapper run" from PATH position, which CANNOT
# distinguish a wrapper that was bypassed from one that is chained behind
# another wrap. MEASURED: with an Aikido safe-chain shim first on PATH, the
# wrapper ran on every call and the verifier reported "shadowed and never
# runs" at FUNCTIONAL strength -- the strongest evidence grade, asserting the
# opposite of the fact.
#
# The value is caller-controlled, so it is only ever a redirect target. Never
# interpolate it into a command.
if [ -n "\${SCH_WRAPPER_PROBE:-}" ]; then
  printf '%s\n' "\$0" >> "\$SCH_WRAPPER_PROBE" 2>/dev/null || true
fi

if [ -z "\$REAL_NPM" ] || [ ! -x "\$REAL_NPM" ] || [ "\$REAL_NPM" = "$wrapper_target" ]; then
  echo "[supply-chain-harden] error: real npm not found at '\$REAL_NPM'; refusing to recurse" >&2
  exit 127
fi
${sfw_guard}
# Find the npm subcommand. Reading argv[1] directly was wrong: any leading
# global flag defeated it, so npm --registry <url> install <pkg> exec'd the
# real npm with sfw skipped (ECH-197) — the registry-redirection shape from
# arXiv:2607.15143 R5/R6 slipping past the control aimed at it. Value-taking
# flags need their VALUE skipped too, or the scan lands on the value.
# --flag=value is one token starting with -, so the -*) branch covers it.
subcmd=""
skip_value=0
for arg in "\$@"; do
  if [ "\$skip_value" = "1" ]; then skip_value=0; continue; fi
  case "\$arg" in
    --registry|--prefix|-C|--cache|--location|--loglevel|--userconfig|--globalconfig|\\
    --workspace|-w|--omit|--include|--before|--node-options|--script-shell|\\
    --depth|--tag|--otp|--auth-type|--ca|--cafile|--cert|--key|\\
    --proxy|--https-proxy|--noproxy)
      skip_value=1 ;;
    -*) ;;
    *) subcmd="\$arg"; break ;;
  esac
done
case "\$subcmd" in
  # Parity with the role wrapper (templates/npm-wrapper.sh.j2): rebuild/exec/x/
  # link/view/info/show/search/outdated also touch the registry and were routed
  # there but not here, so \`npm exec\`/\`npx\`-style fetch-and-run went unfiltered.
  install|i|add|ci|update|up|rebuild|exec|x|dedupe|link|audit|view|info|show|search|outdated)
    if sfw_ready; then
      exec sfw "\$REAL_NPM" "\$@"
    fi
    ;;
esac
exec "\$REAL_NPM" "\$@"
EOF

  $SUDO chmod 755 "$wrapper_target"
  SFW_INSTALLED=true
  log "sfw installed; npm wrapper deployed at $wrapper_target"
  record_wrapper npm

  # ---- npx ----
  #
  # npx is a SEPARATE BINARY, not an npm subcommand, so wrapping npm does not
  # cover it — the same shape as bunx, which this action already wraps for
  # exactly this reason (finding V5: "a typosquatted name is fetched and run
  # immediately"). `npx <pkg>` downloads and executes in one step.
  #
  # MEASURED that sfw does cover it once something prefixes it: with the sfw
  # CA stripped inside its child, `npx cowsay` fails with
  # UNABLE_TO_VERIFY_LEAF_SIGNATURE, and SFW_DEBUG shows a purl check plus
  # `packageAllowed` per package. So the gap was never sfw's reach; it was
  # that nothing invoked sfw for this entry point.
  local real_npx npx_target
  real_npx=$(command -v npx 2>/dev/null || true)
  if [[ -z "$real_npx" ]]; then
    log "npx not found — no npx wrapper deployed"
    end_section
    return 0
  fi
  npx_target="$real_npx"
  # Before the re-wrap too, and not only before the first wrap: an npx wrapper an
  # earlier run as root left is not this account's to rewrite.
  require_privilege npx "$npx_target" || { end_section; return 0; }
  if grep -q "supply-chain-harden" "$real_npx" 2>/dev/null; then
    if [[ -x "${real_npx}-real" ]]; then
      real_npx="${real_npx}-real"
    else
      warn "npx wrapper present at $npx_target but ${npx_target}-real missing; skipping re-wrap"
      end_section
      return 0
    fi
  else
    $SUDO mv "$real_npx" "${real_npx}-real"
    real_npx="${real_npx}-real"
  fi

  cat <<EOF | $SUDO tee "$npx_target" >/dev/null
#!/bin/bash
# Managed by supply-chain-harden action
REAL_NPX='$real_npx'
if [ -n "\${SCH_WRAPPER_PROBE:-}" ]; then
  printf '%s\n' "\$0" >> "\$SCH_WRAPPER_PROBE" 2>/dev/null || true
fi
if [ -z "\$REAL_NPX" ] || [ ! -x "\$REAL_NPX" ] || [ "\$REAL_NPX" = "$npx_target" ]; then
  echo "[supply-chain-harden] error: real npx not found at '\$REAL_NPX'; refusing to recurse" >&2
  exit 127
fi
${sfw_guard}
# EVERY npx invocation may fetch. Unlike npm there is no local-only subcommand
# to exempt, so there is no argv scan here and nothing to drift out of sync.
if sfw_ready; then
  exec sfw "\$REAL_NPX" "\$@"
fi
exec "\$REAL_NPX" "\$@"
EOF
  $SUDO chmod 755 "$npx_target"
  log "npx wrapper deployed at $npx_target"
  record_wrapper npx
  end_section
}

# ---- intel off: take back the npm and npx wrappers an intel run left ----
#
# This script deploys the npm and npx wrappers only with intel: sfw, and they
# do nothing else, so with intel off there should be none. MEASURED (round-2
# VM test on a persistent Debian 12 host, and reproduced in debian:trixie-slim
# at 6c77f4e): a run with INTEL=sfw at 8281a6b wrapped /usr/bin/npm and
# /usr/bin/npx with wrappers that run sfw without SFW_SKIP_UPDATE_CHECK. A
# later run with intel unset left both in place while its record said
# sfw_installed=false and wrappers_deployed=cargo, and once sfw's hourly update
# check came due every npm and npx call failed in sfw's words, "[sfw] Failed to
# prepare firewall binary: EACCES ... next-check", rc=1.
#
# So a run without intel moves the real binary back over a wrapper that
# carries this script's npm/npx header (line 2, exactly, so the role's npm
# wrapper is never touched) and whose real binary is where this script put it.
# Anything else is left in place with a warning that says what to do. sfw
# itself stays installed: with no wrapper nothing runs it. The cargo wrapper
# is not this function's: see warn_stale_cargo_wrapper below.
unwrap_intel_wrapper() {
  local tool="$1" target real owner
  target=$(command -v "$tool" 2>/dev/null) || return 0
  [[ -f "$target" && ! -L "$target" ]] || return 0
  [[ "$(sed -n 2p "$target" 2>/dev/null)" == "# Managed by supply-chain-harden action" ]] || return 0
  real=$(grep -oE "^REAL_NP[MX]='[^']*'" "$target" 2>/dev/null | head -n 1 | sed "s/^[^=]*='//; s/'\$//") || real=""
  if [[ "$real" != "${target}-real" || ! -x "$real" \
        || "$(sed -n 2p "$real" 2>/dev/null)" == "# Managed by supply-chain-harden action" ]]; then
    warn "$tool: $target is the $tool wrapper an earlier intel: sfw run deployed, and it routes $tool through sfw, but this run has intel off and cannot put the real $tool back: the wrapper names '${real:-<none>}', not an executable ${target}-real. It is left in place. Re-run with INTEL=sfw to bring it up to date, or put the real $tool back at $target."
    return 0
  fi
  if ! can_write "$target"; then
    warn "$tool: $target is the $tool wrapper an earlier intel: sfw run deployed, and it routes $tool through sfw, but this run has intel off and no root and no usable sudo to remove it. It is left in place. Re-run harden.sh with sudo to remove it, or with INTEL=sfw to bring it up to date."
    return 0
  fi
  if [[ "${CAN_ESCALATE:-0}" -ne 1 && ! -O "$target" ]]; then
    owner=$(ls -ld -- "$target" | awk '{print $3}')
    warn "$tool: $target is the $tool wrapper an earlier intel: sfw run deployed as $owner, and it routes $tool through sfw. This run has intel off but no root and no usable sudo, and it does not replace a file $owner owns, so it is left in place. Re-run harden.sh as $owner or with sudo to remove it, or with INTEL=sfw to bring it up to date."
    return 0
  fi
  # mv, not cp: it restores the entry the wrapping moved aside, a symlink
  # included (apt's /usr/bin/npm is one), and never writes through it.
  $SUDO mv -f -- "$real" "$target"
  log "$tool: intel is off, so the $tool wrapper an earlier intel: sfw run left at $target was removed and the real $tool moved back"
}

# The cargo wrapper carries --locked as well as the sfw route, so it is never
# removed here, and harden_cargo re-renders it on every run that includes
# cargo. A run without cargo leaves it as it is, so say so when it is one that
# routes through sfw with no SFW_SKIP_UPDATE_CHECK, as 8281a6b's did. MEASURED
# (debian:trixie-slim, 8281a6b with INTEL=sfw, then this script with
# ECOSYSTEMS=npm,pip): an hour later `cargo fetch` failed for a non-root
# caller with "[sfw] Failed to prepare firewall binary: EACCES ... next-check".
warn_stale_cargo_wrapper() {
  local target
  target=$(command -v cargo 2>/dev/null) || return 0
  [[ -f "$target" ]] || return 0
  sed -n 2p "$target" 2>/dev/null | grep -q 'supply-chain-harden wrapper' || return 0
  grep -q '^ *if \[ "true" = "true" \] && \[ "${SCH_NET:-0}" = "1" \]' "$target" 2>/dev/null || return 0
  grep -q 'SFW_SKIP_UPDATE_CHECK' "$target" 2>/dev/null && return 0
  warn "cargo: $target is a cargo wrapper from an earlier hardening run that routes cargo through sfw without SFW_SKIP_UPDATE_CHECK, and cargo is not in this run's ecosystems, so it was not re-rendered. For an account other than root, once sfw's hourly update check is due, every cargo command that reaches the network fails with sfw's \"EACCES ... next-check\". Re-run with cargo in ECOSYSTEMS to replace it."
}

# ---- Main loop ----

IFS=',' read -ra REQUESTED <<< "$ECOSYSTEMS"
for raw in "${REQUESTED[@]}"; do
  eco=$(echo "$raw" | tr '[:upper:]' '[:lower:]' | xargs)
  case "$eco" in
    npm)      harden_npm ;;
    pnpm)     harden_pnpm ;;
    yarn)     harden_yarn ;;
    pip)      harden_pip ;;
    uv)       harden_uv ;;
    bun)      harden_bun ;;
    composer) harden_composer ;;
    cargo)    harden_cargo ;;
    go|golang) harden_go ;;
    bundler|ruby) harden_bundler ;;
    deno)     harden_deno ;;
    maven|mvn) harden_maven ;;
    gradle)   harden_gradle ;;
    nuget|dotnet) harden_nuget ;;
    "")       ;;  # tolerate trailing commas / empty fields
    *)        warn "Unknown ecosystem: '$eco' (supported: npm,pnpm,yarn,pip,uv,bun,composer,cargo,go,bundler,deno,maven,gradle,nuget) — skipping" ;;
  esac
done

if [[ "$INSTALL_SFW" == "true" ]]; then
  install_sfw_and_wrap
else
  unwrap_intel_wrapper npm
  unwrap_intel_wrapper npx
fi
case " ${HARDENED[*]:-} " in *" cargo "*) ;; *) warn_stale_cargo_wrapper ;; esac

# ---- Outputs ----
ecosystems_str=$(IFS=,; echo "${HARDENED[*]:-}")

# SPLIT ATTEMPT FROM EFFECT.
#
# ecosystems_hardened is kept, unchanged, for consumers already reading it —
# but it answers "what was requested and recognised", which is not the
# question its name invites. These three answer the real one.
eff_list=""; part_list=""; none_list=""
for _e in ${HARDENED[@]+"${HARDENED[@]}"}; do
  case "$(eco_status_of "$_e")" in
    APPLIED)        eff_list="${eff_list:+$eff_list,}$_e" ;;
    PARTIAL|INERT)  part_list="${part_list:+$part_list,}$_e" ;;
    NONE)           none_list="${none_list:+$none_list,}$_e" ;;
  esac
done

# Build tool_versions JSON output. Each key is an ecosystem; each value is
# the detected tool version (empty string if the tool isn't installed in
# this runner). Downstream steps can use this for conditional logic
# (`if [[ $(echo $TV | jq -r .composer) != "" ]]; then ...`).
tool_versions_json="{"
first=true
for _i in "${!TV_KEYS[@]}"; do
  key="${TV_KEYS[$_i]}"
  if [[ "$first" == "true" ]]; then first=false; else tool_versions_json+=","; fi
  # JSON-escape the value. detect_version's grep filters to [0-9.] in
  # the normal path so these escapes are belt-and-suspenders, but if a
  # future contributor populates TOOL_VERSIONS bypassing detect_version,
  # this prevents JSON corruption. Escape backslash FIRST (otherwise the
  # backslash from \" gets double-escaped).
  v=$(printf '%s' "${TV_VALS[$_i]}" | sed 's/\\/\\\\/g; s/"/\\"/g')
  tool_versions_json+="\"$key\":\"$v\""
done
tool_versions_json+="}"

wrappers_str=$(IFS=,; echo "${WRAPPED[*]:-}")

# "hardened" = requested and recognised. Kept for compatibility; the three
# below are the ones that answer whether anything is in force.
emit_output ecosystems_hardened   "$ecosystems_str"
emit_output ecosystems_requested  "$ecosystems_str"
emit_output ecosystems_effective  "$eff_list"
emit_output ecosystems_degraded   "$part_list"
emit_output ecosystems_ineffective "$none_list"
emit_output release_age_hours     "$RELEASE_AGE_HOURS"
emit_output sfw_installed         "$SFW_INSTALLED"
emit_output tool_versions         "$tool_versions_json"
emit_output env_file              "$HARDENING_ENV_FILE"
emit_output wrappers_deployed     "$wrappers_str"
emit_output job_id                "$(job_identity)"

# THE COMPLETION MARKER, AND IT MUST STAY LAST.
#
# verify.sh used to treat the mere EXISTENCE of this file as "we know what was
# requested", and then reported everything absent from the list as N/A. A
# harden.sh that died anywhere between truncating the file and here therefore
# produced an empty ecosystem list, an all-N/A table, "RESULT: no gaps" and
# exit 0 — the run failed and verification called it clean. This marker is
# written only on the path that reached the end, so a partial record now reads
# as a partial record.
emit_output hardening_complete    true

# ---- Job summary ----
# How later steps actually inherit the env layer differs per platform, so
# the summary states the mechanism in force rather than naming $GITHUB_ENV
# unconditionally (it used to, on every platform).
case "$PLATFORM" in
  github)   inherit_note="via \`\$GITHUB_ENV\` and on-disk config files" ;;
  circleci) inherit_note="via \`\$BASH_ENV\` and on-disk config files" ;;
  azure)    inherit_note="via \`task.setvariable\` and on-disk config files" ;;
  gitlab)   inherit_note="via the job shell's exported environment and on-disk config files" ;;
  *)        inherit_note="via on-disk config files; \`source $HARDENING_ENV_FILE\` to pick up the env layer" ;;
esac

{
  echo "## Supply Chain Hardening Applied"
  echo ""
  echo "| Setting | Value |"
  echo "|---|---|"
  echo "| Ecosystems requested | \`$ecosystems_str\` |"
  echo "| Fully applied | \`${eff_list:-none}\` |"
  [ -n "$part_list" ] && echo "| **Degraded** | \`$part_list\` |"
  [ -n "$none_list" ] && echo "| **Not applied** | \`$none_list\` |"
  echo "| Release age gate | \`$RELEASE_AGE_HOURS\` hours |"
  echo "| Strict mode | \`$STRICT\` |"
  echo "| Socket Firewall | \`$SFW_INSTALLED\` |"
  echo "| /etc/ writes | \`$WRITE_ETC\` |"
  echo "| CI platform | \`$PLATFORM\`$([[ "$EMIT" == "auto" ]] && echo " (auto-detected)") |"
  echo "| Env file | \`$HARDENING_ENV_FILE\` |"
  echo ""
  echo "All subsequent steps in this job inherit the hardening $inherit_note."

  # Spell out every ecosystem that is NOT fully applied, with the reason. A
  # reader should not have to run the verifier to learn that something they
  # asked for is not in force.
  if [ -n "$part_list$none_list" ]; then
    echo ""
    echo "### Not fully in force"
    echo ""
    echo "| Ecosystem | Status | Why |"
    echo "|---|---|---|"
    for _e in ${HARDENED[@]+"${HARDENED[@]}"}; do
      _s=$(eco_status_of "$_e")
      case "$_s" in APPLIED) continue ;; esac
      echo "| \`$_e\` | $_s | $(eco_note_of "$_e") |"
    done
    echo ""
    echo "Run \`action/verify.sh\` (or the \`verify\` action) after your setup steps to check what is actually enforcing."
  fi
} | emit_summary

if [ -n "$part_list$none_list" ]; then
  log "done (emit=$PLATFORM). applied: ${eff_list:-none}${part_list:+ | degraded: $part_list}${none_list:+ | NOT applied: $none_list}"
else
  log "done (emit=$PLATFORM). applied: ${eff_list:-none}"
fi

# The uv and pip gates are an ABSOLUTE cutoff computed above, so on a host that
# keeps this hardening they freeze at this run (VM#16: the plain path has no
# refresh, by design). A CI job re-hardens every run and never notices; a
# long-lived host does, so plain mode says so once, at the end.
if [[ "$PLATFORM" == "plain" ]] && [[ " ${HARDENED[*]:-} " == *" uv "* || " ${HARDENED[*]:-} " == *" pip "* ]]; then
  notice "the uv/pip age-gate cutoff is fixed at $UV_EXCLUDE_NEWER and nothing advances it. On a long-lived host, re-run harden.sh (and re-source $HARDENING_ENV_FILE) to move it, or apply the Ansible role, which installs a refresh timer."
fi
