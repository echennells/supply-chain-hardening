#!/usr/bin/env bash
# What happens to a user's own config files. Run by the role on the target
# (tasks/user_config_file.yml, tasks/npm.yml, tasks/preflight.yml) with the
# script module. The marked block below is also in action/harden.sh, byte for
# byte (tests/ci/14-user-config.bats compares them), so the two surfaces judge
# and write a file the same way. bash 3.2, BSD, BusyBox and GNU tools.
#
#   user-config.sh path <kind>          where that kind's file is, or nothing; for
#                                       npm-global, "as user" or "as root" too
#   user-config.sh classify <kind>...   one line per file that is in the way
#   user-config.sh replace <kind>       write $SCH_UCF_BODY to $SCH_UCF_PATH, or to
#                                       the kind's own path; prints which
#   user-config.sh npmrc                merge $SCH_UCF_BODY into $SCH_UCF_PATH
#
# replace and npmrc take SCH_UCF_DRY=1 (report, write nothing) and, for a file
# with settings of the user's, SCH_UCF_FOREIGN=refuse|keep. SCH_UCF_ROOT=1 goes with
# every become: root then reads and writes only what no other account controls, with
# tools from the system's directories.
set -u
UCF_ROOT=${SCH_UCF_ROOT:-0}
if [ "$UCF_ROOT" = 1 ]; then
  PATH=/usr/sbin:/usr/bin:/sbin:/bin
  unset COMPOSER_HOME XDG_CONFIG_HOME
fi

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
      case "$d" in /etc/npmrc|*[[:cntrl:]]*) ;; /*) printf '%s\n' "$d" ;; esac ;;
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

# ucf_same <file or - for stdin> <file>: the same bytes. Not with cmp, which is in
# diffutils: no image of Fedora, Arch, UBI, Rocky or Alma (minimal) has it (MEASURED).
ucf_same() {
  local a b
  if [ "$1" = - ]; then a=$(ucf_sum); else a=$( { ucf_sum < "$1"; } 2>/dev/null ); fi
  b=$( { ucf_sum < "$2"; } 2>/dev/null )
  [ -n "$a" ] && [ "$a" = "$b" ]
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
# ours need not stop anything: the write comes only if it has to change (a shared
# CARGO_HOME, where another account already wrote the same one). Only where that is
# still open, though. One from before the checksum is always written again (what is
# written now carries one), and so is one whose mode has to change, so either stops
# here like any other. MEASURED before this (tests/ci/14): the files v2.0.0 and v2.1.0
# wrote, in a directory the account could not write, all passed this, so both
# preflights cleared the host, and ucf_replace then stopped the run at that file,
# after the ones before it. Composer's file has no marker; what is written to it is
# the same as before.
ucf_stuck() {
  local why real
  why=$(ucf_blocked "$1" "$2")
  [ -n "$why" ] || return 0
  if [ "$1" != npmrc ] && [ -z "$(ucf_kept_out "$1" "$2")" ] && [ -f "$2" ] && [ -r "$2" ] \
     && [ "$(user_cfg_class "$1" "$2")" = ours ] && real=$(ucf_real "$2") \
     && [ "$(ucf_ls "$real" | cut -c1-10)" = "$(ucf_mode "$real" 644)" ]; then
    case "$1" in composer*) return 0 ;; esac
    case "$(ucf_marker "$2")" in *" "?*) return 0 ;; esac
  fi
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
  path="$1" content="$3" tmp="" bak="" own="" kept=1
  trap '[ -z "$tmp" ] || rm -f -- "$tmp"' EXIT
  trap 'exit 1' HUP INT TERM
  no() { printf 'error: %s: %s\n' "$path" "$1"; exit 1; }
  # A directory that is there keeps its mode, whatever it is.
  [ -d "$(dirname -- "$path")" ] || mkdir -p -- "$(dirname -- "$path")" 2>/dev/null || no "its directory cannot be made"
  real=$(ucf_real "$path") || no "it cannot be resolved"
  mode=$(ucf_mode "$real" "$2")
  if [ -e "$real" ]; then own=$(ucf_ls "$real"); own=${own#* }; fi
  tmp=$(ucf_temp "$real") || { tmp=""; no "no new file can be made in ${real%/*}"; }
  printf '%s' "$content" > "$tmp" 2>/dev/null || no "the new content could not be written (a full disk?)"
  if [ -n "$own" ] && [ "$(id -u)" = 0 ]; then
    # Root in a container need not be able to change owners (no CAP_CHOWN), nor have
    # this group in its user namespace. The owner has to stay; the group need not.
    if ! chown -h "${own% *}:${own#* }" "$tmp" 2>/dev/null; then
      kept=0
      chown -h "${own% *}" "$tmp" 2>/dev/null \
        || no "its owner (uid ${own% *}) cannot be kept, because this root cannot change a file's owner. Run this as that account"
    fi
  elif [ -n "$own" ]; then
    chgrp "${own#* }" "$tmp" 2>/dev/null || kept=0
  fi
  # A group that cannot be kept: no other group gets what it had, unless everyone has.
  if [ "$kept" = 0 ]; then
    case "$mode" in ???????r*) ;; *) mode="${mode:0:4}---${mode:7}" ;; esac
  fi
  ucf_chmod "$tmp" "$mode" || no "the mode of the new file cannot be set"
  if mv -f -- "$tmp" "$real" 2>/dev/null; then tmp=""; exit 0; fi
  [ -f "$real" ] && [ -w "$real" ] || no "it cannot be replaced or written"
  bak=$(ucf_copy_new "$real") || no "no copy of it could be made first"
  if cat -- "$tmp" > "$real" && ucf_same "$tmp" "$real" && ucf_chmod "$real" "$mode"; then rm -f -- "$bak"; exit 0; fi
  printf 'error: %s may be incomplete; as it was, it is at %s\n' "$path" "$bak"
  exit 1
)

# ucf_copy_new <path>: a 0600 copy next to it, named as ansible's backup names one
# (<file>.<pid>.<YYYY-MM-DD@HH:MM:SS>~); prints the name. Complete before it has
# that name, and never over anything already there.
ucf_copy_new() {
  local p="$1" b tmp own n=1
  tmp=$(ucf_temp "$p") || return 1
  if ! cat -- "$p" > "$tmp" 2>/dev/null || ! ucf_same "$p" "$tmp"; then rm -f -- "$tmp"; return 1; fi
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
  [ -f "$b~" ] && [ ! -L "$b~" ] && ucf_same "$p" "$b~" || return 1
  printf '%s\n' "$b~"
}

# ucf_copy <path>: the same, but a copy with the same bytes that is there already
# is reused: on a runner whose jobs put the same token back every time, that keeps
# one copy of it and not one per job.
ucf_copy() {
  local b
  for b in "$1".[0-9]*.[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]@*"~"; do
    if [ -f "$b" ] && [ ! -L "$b" ] && ucf_same "$1" "$b" && chmod 600 "$b" 2>/dev/null; then
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
    if [ "$cls" = ours ] && printf '%s\n' "$want" | ucf_same - "$path" \
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
    if ucf_unsafe "$v"; then v=$REPLY; fi
    if ! ours "$k"; then
      # in a file an older version wrote whole, a key this run leaves out (npm 11.2 to
      # 11.9 warn about one they do not know)
      case "$old:$arr:$k=$v" in
        :*|*:0:min-release-age=|*:0:min-release-age=*[!0-9]*) return 1 ;;
        *:0:min-release-age=*|*:0:allow-git=none) ;;
        *) return 1 ;;
      esac
      case "$seen" in *" $k "*) return 1 ;; esac
      seen="$seen$k "
      return 0
    fi
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

case "${1:-}" in
  path)
    p=$(ucf_path "${2:?}")
    if [ -n "$p" ]; then
      printf '%s\n' "$p"
      [ "$2" != npm-global ] || printf 'as %s\n' "$(ucf_global_by "$p")"
    fi ;;
  classify)
    shift
    rc=0
    for k in "$@"; do
      ucf_applies "$k" || continue
      p=${SCH_UCF_PATH:-$(ucf_path "$k")}
      why=$(ucf_stuck "$k" "$p")
      if [ -n "$why" ]; then printf 'blocked %s %s\n' "$p" "$why"; rc=42; continue; fi
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
    kind=${2:-$1}
    path=${SCH_UCF_PATH:-$(ucf_path "$kind")}
    body=${SCH_UCF_BODY:?}
    if [ "$kind" = composer-home ] && [ -z "$path" ]; then echo ok; exit 0; fi
    case "$kind" in composer*) body=${body#x} ;; esac
    printf 'path %s\n' "${path:?}"
    if [ "$kind" = npmrc ]; then
      ucf_npmrc "$path" <<<"$body"
    else
      ucf_replace "$kind" "$path" <<<"$body"
      rc=$?
      # The preflight refuses first; this is a run that skipped it, a file changed
      # since, or root's own file, which the role leaves alone and reports.
      [ "$rc" -ne 42 ] || echo "[supply-chain-hardening] $path is not exactly what this project last wrote, so it was left as it is. Move it aside and re-run, or set accept_user_config_overwrite=true to copy it next to itself and replace it." >&2
      exit "$rc"
    fi ;;
  *)
    echo "usage: user-config.sh classify <kind>... | replace <kind> | npmrc" >&2
    exit 2 ;;
esac
