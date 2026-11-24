#!/usr/bin/env bash
# What happens to a user's own config files. Run by the role on the target
# (tasks/user_config_file.yml, tasks/npm.yml, tasks/preflight.yml) with the
# script module. The marked block below is also in action/harden.sh, byte for
# byte (tests/ci/13-user-config.bats compares them), so the two surfaces judge
# and write a file the same way. bash 3.2, BSD, BusyBox and GNU tools.
#
#   user-config.sh classify <kind>...   one line per file that is in the way
#   user-config.sh replace <kind>       write $SCH_UCF_BODY to $SCH_UCF_PATH
#   user-config.sh npmrc                merge $SCH_UCF_BODY into $SCH_UCF_PATH
#
# replace and npmrc take SCH_UCF_DRY=1 (report, write nothing) and, for a file
# with settings of the user's, SCH_UCF_FOREIGN=refuse|keep.
set -u

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
#   pnpm's config.yaml and rc, .yarnrc.yml, pip.conf, uv.toml, bunfig and
#   ~/.bundle/config are still replaced whole, but only a file that is exactly
#   what was last written is replaced without a word. The marker line carries a
#   checksum of the rest of the file (ucf_sign), so a line added later shows.
#   Anything else is the user's: the role refuses to touch it, and harden.sh
#   copies it next to itself (0600) and says so.
#
# Nothing here prints a line from a user's file: paths, key names from this
# project's own list, and line numbers only.

UCF_KINDS="npmrc pnpm-yaml pnpm-rc yarn pip uv bun bundler"

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
  esac
}

# ucf_applies <kind>: whether the role would write that file on this host.
# maven and nuget have a tool gate (tasks/maven.yml: mvn, or a JDK a ./mvnw build
# would run on; tasks/nuget.yml); every other file is written ahead of its tool.
ucf_applies() {
  case "$1" in
    maven) command -v mvn >/dev/null 2>&1 || command -v java >/dev/null 2>&1 \
             || { [ -n "${JAVA_HOME:-}" ] && [ -x "${JAVA_HOME:-}/bin/java" ]; } ;;
    nuget) command -v dotnet >/dev/null 2>&1 ;;
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

# ucf_marker <file>: the number of its marker line (the first or second;
# ~/.bundle/config has to open with ---) and the checksum in it, if any.
ucf_marker() {
  local l n=0 re='^[#;] Managed by (ansible-supply-chain-security|supply-chain-harden|supply-chain-harden action)(; self-check ([a-z0-9]+:[0-9a-f-]+))?$'
  while [ "$n" -lt 2 ] && { IFS= read -r l || [ -n "$l" ]; }; do
    n=$((n + 1))
    if [[ "$l" =~ $re ]]; then printf '%s %s\n' "$n" "${BASH_REMATCH[3]:-}"; return 0; fi
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
    case "$l" in "# Managed by "*|"; Managed by "*) at=$n; break ;; esac
  done <<<"$body"
  [ "$at" -gt 0 ] || return 1
  sum=$(printf '%s\n' "$body" | ucf_body "$at" | ucf_sum)
  printf '%s\n' "$body" | sed "${at}s/\$/; self-check $sum/"
}

# ucf_settings <kind>: every setting line any version of this project has
# written to that file, as one extended regex. With UCF_COMMENTS this is how a
# file from before the checksum is told from one with something added to it.
ucf_settings() {
  local b='(true|false)' pkg='"?@?[A-Za-z0-9_./-]+"?'
  case "$1" in
    pnpm-yaml) printf '%s' "(ignoreScripts|minimumReleaseAgeStrict|blockExoticSubdeps|verifyStoreIntegrity|preferFrozenLockfile): $b|minimumReleaseAge: [0-9]+|minimumReleaseAgeExclude:( \[\])?|onlyBuiltDependencies:|  - $pkg" ;;
    pnpm-rc)   printf '%s' "(minimum-release-age-strict|block-exotic-subdeps|verify-store-integrity|prefer-frozen-lockfile|ignore-scripts)=$b|minimum-release-age=[0-9]+|(minimum-release-age-exclude|only-built-dependencies)\[\]=$pkg" ;;
    yarn)      printf '%s' "npmMinimalAgeGate: \"?[0-9]+[a-z]?\"?|(enableScripts|enableTelemetry|enableImmutableInstalls|enableImmutableCache|enableHardenedMode): $b|defaultSemverRangePrefix: \"\"|checksumBehavior: [a-z]+|(unsafeHttpWhitelist|approvedGitRepositories):( \[\])?|  - \"[A-Za-z0-9*.:_-]+\"" ;;
    pip)       printf '%s' "\[(global|install)\]|disable-pip-version-check = $b|uploaded-prior-to = [0-9A-Z:.+-]+|only-binary = :all:|require-hashes = true" ;;
    uv)        printf '%s' "\[pip\]|index-strategy = \"[a-z-]+\"|allow-insecure-host = \[\]?|  \"[A-Za-z0-9*.:_-]+\",|\]|exclude-newer = \"[0-9A-Za-z:.+ -]+\"|no-build = true|(verify|require)-hashes = true" ;;
    bun)       printf '%s' "\[install(\.security)?\]|minimumReleaseAge = [0-9]+|(exact|ignoreScripts|lifecycleScripts|frozenLockfile|saveTextLockfile) = $b|auto = \"[a-z]+\"|scanner = \"[@A-Za-z0-9_./-]+\"" ;;
    bundler)   printf '%s' "---|BUNDLE_(FROZEN|DEPLOYMENT|DISABLE_EXEC_LOAD|DISABLE_CHECKSUM_VALIDATION): \"$b\"|BUNDLE_COOLDOWN: \"[0-9]+\"" ;;
  esac
}

# The comment lines every version before the checksum wrote to these files, as
# the cksum of each with its numbers replaced by N. Taken from the full history
# of the templates, of the tasks that held file bodies, and of harden.sh, up to
# d738db8. A file written since is recognised by its checksum, so this list does
# not grow.
UCF_COMMENTS="
16525038 21871804 32150554 43907897 47931416 55973644 69316955 105001757 105892395 128665454
175274273 178849623 200300571 227981860 239698099 287077081 365023710 378289750 400057024
404142847 406588281 423346594 442000343 457662746 480185687 495546462 525078076 533827307
534359993 541135190 566593694 590162472 605195884 609895156 620068839 623983281 645071874
659341542 662095973 665169919 676397890 676452693 678903473 698746493 706861579 752989721
754514485 761418702 763897198 767642206 780035631 807176139 811096765 822283647 850984450
851995495 857513513 871339096 882036600 887840420 914394579 946961410 956752516 962375387
967119353 971991551 973005913 990068066 1010244358 1034315139 1086581569 1094282732 1130513908
1143484216 1171045470 1208393765 1218543117 1220014093 1223360892 1261714146 1263262543 1265749696
1279840774 1299265572 1317891570 1326837714 1353146482 1412089512 1415879662 1442417585 1443997311
1458290740 1460165626 1503295801 1503828058 1506383425 1528186005 1555761671 1590698284 1596979382
1602124173 1604734001 1615633999 1617717831 1624869757 1629313848 1665228443 1693356012 1702901289
1717377404 1731640410 1779340826 1804999554 1825130484 1848409489 1862209121 1876759700 1885420368
1886008490 1890543521 1926614231 1929107881 1933481240 1940260606 1951441247 1959004320 1974900389
1998983759 2001361852 2008011601 2013828265 2020712404 2036418807 2041416390 2059790614 2065949424
2071261798 2073041987 2097239662 2097937815 2107048927 2111733905 2151704586 2163831583 2164390978
2177254588 2205464476 2217588667 2231711062 2244097877 2244240049 2250113593 2257637074 2270544086
2282546424 2298240656 2302859127 2307443183 2344062860 2375681719 2380494202 2396691812 2405118425
2406300254 2418201151 2418603402 2423330056 2424955648 2437712885 2450664865 2462106124 2508979248
2520848859 2525961786 2530280945 2532656106 2589908363 2608169811 2623014578 2641150404 2646182193
2675788109 2676103573 2678035591 2692919221 2699926567 2735555215 2740590091 2803650760 2804934355
2806616818 2828038750 2829134946 2859044314 2862455256 2872993376 2875338965 2879118241 2890406335
2931523466 2941754597 2965115596 3011098759 3043122243 3059239056 3070869805 3082536336 3084694776
3088475917 3103206383 3109696787 3138848547 3174496324 3176005236 3181547447 3207794189 3220286758
3225303355 3240026043 3255040544 3267656043 3308486726 3310122909 3332470975 3359503045 3365361455
3371086111 3377219643 3405234329 3446823395 3447275383 3477144607 3501233636 3530917337 3534829072
3540864410 3559392846 3561851686 3570113122 3592020093 3600443778 3615099103 3616788605 3716039824
3774832778 3782170922 3789297986 3790384087 3794482279 3803650350 3811320475 3814041862 3854269605
3857682206 3879323867 3883983730 3894417574 3918509061 3943714449 3980610148 4013068897 4027145760
4081681318 4093752315 4121261445 4143239405 4144104894 4145960931 4147756996 4151822944 4152993966
4167262084 4173685148 4175278786 4177171127 4199336900 4211861283 4212708504 4217618386 4246611539
4264870084 4279237107
"
ucf_our_comment() { # <line>
  local c
  c=$(printf '%s\n' "$1" | LC_ALL=C sed 's/[0-9][0-9]*/N/g' | cksum) || return 1
  case "$UCF_COMMENTS" in *[[:space:]]"${c%% *}"[[:space:]]*) return 0 ;; esac
  return 1
}

# ucf_old_file <kind> <file>: a file from before the checksum that holds only
# lines this project has written. The role's ~/.bundle/config had no marker, so
# that one has to be the whole file it wrote.
ucf_old_file() {
  local l rest
  case "$1" in
    bundler)
      rest=$(sed 's/^\(BUNDLE_COOLDOWN: \)"[0-9][0-9]*"$/\1N/' "$2" | tr '\n' ' ')
      case "$rest" in
        '--- BUNDLE_FROZEN: "true" BUNDLE_DEPLOYMENT: "true" BUNDLE_DISABLE_EXEC_LOAD: "true" ') return 0 ;;
        '--- BUNDLE_FROZEN: "true" BUNDLE_COOLDOWN: N BUNDLE_DISABLE_CHECKSUM_VALIDATION: "false" ') return 0 ;;
      esac ;;
  esac
  [ -n "$(ucf_marker "$2")" ] || return 1
  rest=$(LC_ALL=C grep -vxE -e "$(ucf_settings "$1")|[#;] Managed by (ansible-supply-chain-security|supply-chain-harden|supply-chain-harden action)" "$2") || true
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    case "$l" in "#"*|";"*) ;; *) return 1 ;; esac
    ucf_our_comment "$l" || return 1
  done <<<"$rest"
  return 0
}

# user_cfg_class <kind> <path> -> ours | stock | foreign
#
# Whether a per-user config file that is replaced whole is this project's.
#   pnpm, yarn, pip, uv, bun, bundler: ours is exactly what was last written, or
#     what a version from before the checksum wrote with nothing added.
#   cargo, maven, nuget: ours carries either project's marker, or is what the
#     role wrote before it had one; dotnet's own first-run NuGet.Config
#     (nuget.org and nothing else) is stock.
user_cfg_class() {
  local m s
  case "$1" in
    pnpm-yaml|pnpm-rc|yarn|pip|uv|bun|bundler)
      m=$(ucf_marker "$2") s=""
      case "$m" in *" "?*) s=${m#* } ;; esac
      if [ -n "$s" ]; then
        if [ "$(ucf_body "${m%% *}" < "$2" | ucf_sum "${s%%:*}")" = "$s" ]; then echo ours; else echo foreign; fi
      elif ucf_old_file "$1" "$2"; then
        echo ours
      else
        echo foreign
      fi
      return 0 ;;
  esac
  grep -qE 'Managed by (ansible-supply-chain-security|supply-chain-harden)' "$2" 2>/dev/null && { echo ours; return 0; }
  case "$1" in
    cargo)
      head -n 1 "$2" | grep -qx '# Cargo supply-chain hardening — system defaults.' \
        && { echo ours; return 0; } ;;
    maven)
      grep -q '<id>central-https</id>' "$2" \
        && grep -q '<activeProfile>strict-checksums</activeProfile>' "$2" \
        && { echo ours; return 0; } ;;
    nuget)
      grep -q 'key="signatureValidationMode" value="require"' "$2" \
        && grep -q '<repository name="nuget.org" serviceIndex="https://api.nuget.org/v3/index.json">' "$2" \
        && { echo ours; return 0; }
      # dotnet's first-run file, compared with the BOM, comments and whitespace
      # stripped (MEASURED, apt dotnet-sdk-8.0 8.0.134: the first `dotnet nuget
      # list source` in a fresh home writes it, opening with a UTF-8 byte-order
      # mark and with no trailing newline).
      if [ "$(tr -d '\r\n' < "$2" | LC_ALL=C sed "s/^$(printf '\357\273\277')//; s/<!--[^>]*-->//g" | tr -d ' \t')" = \
           '<?xmlversion="1.0"encoding="utf-8"?><configuration><packageSources><addkey="nuget.org"value="https://api.nuget.org/v3/index.json"protocolVersion="3"/></packageSources></configuration>' ]; then
        echo stock; return 0
      fi ;;
  esac
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

# ucf_blocked <kind> <path>: why that file cannot be written as it has to be;
# nothing when it can. Judged before anything is touched.
ucf_blocked() {
  local kind="$1" path="$2" real d u t
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

# ucf_mode <path> <600|644>: the mode string that file ends with: what it has,
# with anything that mode does not grant taken away. 600, or 644 less the umask,
# for a file that is not there yet.
ucf_mode() {
  local s r=- w=- g=- o=-
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

# ucf_put <path> <600|644> <content>: write it, atomically: a temporary file in the
# same directory, renamed over, so a run killed at any point leaves the old file or
# the new one. Through a symlink to the file it names, the owner kept, and the mode
# as ucf_mode says. Where the rename is impossible (a file bind-mounted into a
# container) it is written in place, with a copy of the old one kept until the new
# one is complete. A subshell, for its trap.
ucf_put() (
  path="$1" content="$3" tmp="" bak="" own=""
  trap '[ -z "$tmp" ] || rm -f -- "$tmp"' EXIT
  trap 'exit 1' HUP INT TERM
  real=$(ucf_real "$path") || exit 1
  mode=$(ucf_mode "$real" "$2")
  if [ -e "$real" ]; then own=$(ucf_ls "$real"); own=${own#* }; fi
  tmp=$(ucf_temp "$real") || { tmp=""; exit 1; }
  printf '%s' "$content" > "$tmp" 2>/dev/null || exit 1
  if [ -n "$own" ] && [ "$(id -u)" = 0 ]; then
    chown "${own% *}:${own#* }" "$tmp" 2>/dev/null || exit 1
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
    own=$(ls -ldnL -- "$p" | awk '{print $3 ":" $4}'); chown "$own" "$tmp" 2>/dev/null || true
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

# ucf_replace <kind> <path>: replace one of the seven with the body on stdin.
# Prints "ok" or "changed", "copy <file>" ("-" in a dry run) when the user's
# version is kept, and "error: <why>" with status 1. UCF_DRY=1 reports and writes
# nothing. With UCF_FOREIGN=refuse a file with the user's settings is left alone:
# "refused <path>", status 42.
ucf_replace() {
  local kind="$1" path="$2" want why bak cls=absent
  want=$(ucf_sign) || { echo "error: no marker line in the new $kind file"; return 1; }
  why=$(ucf_blocked "$kind" "$path")
  if [ -n "$why" ]; then printf 'error: %s %s; it was left as it is\n' "$path" "$why"; return 1; fi
  if [ -e "$path" ]; then
    cls=$(user_cfg_class "$kind" "$path")
    if [ "$cls" = ours ] && printf '%s\n' "$want" | cmp -s - "$path" \
       && [ "$(ucf_ls "$(ucf_real "$path")" | cut -c1-10)" = "$(ucf_mode "$(ucf_real "$path")" 644)" ]; then
      echo ok; return 0
    fi
  fi
  if [ "$cls" = foreign ]; then
    if [ "${UCF_FOREIGN:-keep}" = refuse ]; then printf 'refused %s\n' "$path"; return 42; fi
    bak=-
    if [ "${UCF_DRY:-0}" != 1 ]; then
      bak=$(ucf_copy "$path") || { printf 'error: could not copy %s next to itself before replacing it; it was left as it is\n' "$path"; return 1; }
    fi
    printf 'copy %s\n' "$bak"
  fi
  if [ "${UCF_DRY:-0}" != 1 ]; then
    ucf_put "$path" 644 "$want"$'\n' || { printf 'error: could not write %s\n' "$path"; return 1; }
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
# Goes through the file as npm would read it. Prints "removed <key>" and
# "unsure <what>" lines, a record separator, and the lines that stay, byte for
# byte, with an x after them so a command substitution keeps the last newline.
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
        ucf_our_comment "$seg"; return ;;
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

case "${1:-}" in
  classify)
    shift
    rc=0
    for k in "$@"; do
      ucf_applies "$k" || continue
      p=$(ucf_path "$k")
      case " $UCF_KINDS " in
        *" $k "*)
          why=$(ucf_blocked "$k" "$p")
          if [ -n "$why" ]; then printf 'blocked %s %s\n' "$p" "$why"; rc=42; continue; fi ;;
      esac
      [ -e "$p" ] && [ "$k" != npmrc ] || continue
      c=$(user_cfg_class "$k" "$p")
      [ "$c" = ours ] || printf '%s %s\n' "$c" "$p"
      [ "$c" != foreign ] || rc=42
    done
    exit "$rc" ;;
  replace|npmrc)
    # A new file is 0644 whatever the umask of the account the role connects as.
    umask 022
    UCF_DRY=${SCH_UCF_DRY:-0} UCF_FOREIGN=${SCH_UCF_FOREIGN:-refuse}
    if [ "$1" = npmrc ]; then
      ucf_npmrc "${SCH_UCF_PATH:?}" <<<"${SCH_UCF_BODY:?}"
    else
      ucf_replace "${2:?}" "${SCH_UCF_PATH:?}" <<<"${SCH_UCF_BODY:?}"
      rc=$?
      # The preflight refuses first; this is a run that skipped it, or a file
      # changed since.
      [ "$rc" -ne 42 ] || echo "[supply-chain-hardening] $SCH_UCF_PATH is not exactly what this project last wrote, so it was left as it is. Move it aside and re-run, or set accept_user_config_overwrite=true to copy it next to itself and replace it." >&2
      exit "$rc"
    fi ;;
  *)
    echo "usage: user-config.sh classify <kind>... | replace <kind> | npmrc" >&2
    exit 2 ;;
esac
