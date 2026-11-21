#!/usr/bin/env bash
# Shared verifier probe body — concatenated by BOTH surfaces after their own
# context preamble. Assembled mechanically from the reviewed probe designs.
#
# Requires from the calling surface: row(), have(), run_bounded() (the block
# fenced by `# >>> run_bounded` in both preambles), and (CI only) requested().
#
# KNOWN: 5 helper functions are defined more than once (identical bodies;
# each probe carries its ecosystem's preamble so it can be read standalone).
# Bash takes the last definition and they are byte-identical, so this is
# cosmetic. Do NOT dedupe with a brace-counting script — several probes embed
# heredocs containing Groovy/XML and a naive parser corrupts them.

# A gap no configuration can close: the installed tool cannot do this at any
# setting. action/verify.sh classes these so --fail-on=config does not fail a job
# for the toolchain it was handed; a plain row() there counts as a config gap.
# The role preamble has no classes, so there it is an ordinary GAP. `unavail`
# must stay behind this test: a bare call aborts the role verifier at line 1.
scv_toolchain_gap() { # id evidence protection detail
  if type unavail >/dev/null 2>&1; then unavail "$@"; else shift; row GAP "$@"; fi
}

# How THIS surface puts a deployed setting back. The body is shared, so a
# remediation that names one delivery path is wrong on the other. MEASURED
# (VM#14, a host hardened with action/harden.sh --emit=plain): the frozen-cutoff
# rows told the user to re-apply a role they never ran and to check a systemd
# timer that path never installs. SCV_SURFACE is declared by both preambles.
scv_reapply() { # -> an imperative phrase, lower case
  case "${SCV_SURFACE:-role}" in
    ci) printf 're-run action/harden.sh' ;;
    *)  printf 're-apply the role' ;;
  esac
}
scv_cutoff_fix() { # -> the remedy for a frozen absolute uv/pip cutoff
  case "${SCV_SURFACE:-role}" in
    ci) printf '%s' "Re-run action/harden.sh to advance it, and re-source its env file in any shell that sourced the old one. harden.sh ships no refresh timer: a CI job re-hardens on every run, but a long-lived host hardened this way keeps the cutoff of its last harden.sh run until something runs it again (the Ansible role installs supply-chain-age-gate-refresh.timer for this)" ;;
    *)  printf '%s' "Re-apply the role to advance it; on a systemd host the role's supply-chain-age-gate-refresh.timer should be doing that, so check \`systemctl status supply-chain-age-gate-refresh.timer\` and its journal" ;;
  esac
}

# The window this surface promised, in hours; empty when nothing recorded one.
# The role renders it into its preamble, the action records it in OUTPUT_FILE.
scv_want_hours() {
  if [ -n "${SCV_MIN_AGE_HOURS:-}" ]; then printf '%s' "$SCV_MIN_AGE_HOURS"; return 0; fi
  [ -f "${OUTPUT_FILE:-}" ] && grep '^release_age_hours=' "${OUTPUT_FILE:-}" 2>/dev/null | head -1 | cut -d= -f2-
  return 0
}

# cq() quotes a value for a row detail. It is a pass-through; the comment at the
# composer section says why it stays. Defined HERE, before its first caller: the
# poetry rows call it, and they run before the composer section. When it was
# defined only down there, bash had not seen it yet, every poetry detail that
# named a value or a directory printed blank fields, and stderr said
# "cq: command not found" (MEASURED, action/verify.sh with a poetry exclude list).
cq() { printf '%s' "$1"; }

# A doc a row points at, as a URL. A repo-relative path such as
# docs/composer-bundler-cooldown-by-distro.md exists neither on a hardened host
# (the role deploys no docs) nor in a CI log, so the reader had nothing to open.
# Each preamble sets SCV_DOCS_URL: the action pins it to the ref the job used
# when GitHub reports one; the role has no record of its release, so it points
# at main.
scv_doc() { printf '%s/%s' "${SCV_DOCS_URL:-https://github.com/echennells/supply-chain-hardening/blob/main}" "$1"; }


# ======================================================================
# HOST TOOL DISCOVERY  (ECH-189, generalised)
# ======================================================================
#
# `have <tool>` resolves against the VERIFIER's PATH, not the host's.
# tasks/verify.yml invokes the verifier through `ansible.builtin.command`, a
# NON-LOGIN shell whose PATH is only
#     /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# so every tool whose official installer targets a per-user directory is
# invisible to the audit, and the N/A branch then reports "<tool> not
# installed" about a host that has it installed AND hardened.
#
# MEASURED 2026-10-22 on an applied Ubuntu 24.04 host. uv exists only at
# ~/.local/bin/uv, which ~/.profile:25-26 adds for LOGIN shells only. The
# apply's own final audit emitted a single
#     N/A  -  uv  "uv not installed"
# while a login shell on the same host emitted five real uv verdicts, the age
# gate among them. The protections were live the whole time: the pip wrapper
# resolves uv by its baked-in absolute path (ECH-191) and worked correctly in
# that same non-login shell. So this is the AUDITOR going blind, not the host
# regressing — design-principles.md Axis 4, "absent signal read as a passing
# signal". A green that comes from blindness is the failure this role exists
# to prevent, one level up.
#
# ECH-189 fixed precisely this for cargo. A survey on 2026-10-22 found cargo
# was the ONLY tool that had it: there was no discovery for uv, bun, bunx,
# deno, go, pnpm or composer, every one of which has a documented default
# install directory outside the non-login PATH. This block is that fix for the
# whole class, resolved ONCE here so every probe below inherits it.
#
# DELIBERATELY NOT A LOGIN SHELL. Running the audit under `bash -lc` would
# source ~/.profile and ~/.bashrc, making a security verification depend on
# user-editable files and vary between hosts for reasons unrelated to
# hardening. Discovery stays hermetic: a fixed list of documented locations,
# each honouring its tool's own override variable.
discover() { # discover <tool> <dir>... -> prepend the first dir that holds it
  _d_tool="$1"; shift
  have "$_d_tool" && return 0
  for _d_dir in "$@"; do
    [ -n "$_d_dir" ] || continue
    if [ -x "$_d_dir/$_d_tool" ]; then
      case ":$PATH:" in
        *":$_d_dir:"*) ;;
        *) PATH="$_d_dir:$PATH"; export PATH ;;
      esac
      return 0
    fi
  done
  return 1
}

# FIXED PATHS ONLY. An earlier cut of this block led each list with the tool's
# own override variable -- XDG_BIN_HOME, BUN_INSTALL, DENO_INSTALL, PNPM_HOME --
# which let a caller choose which binary the AUDIT executes. MEASURED and
# removed for that reason:
#
#   $ mkdir -p /tmp/evil && cat > /tmp/evil/uv   # prints forged --show-settings
#   $ env -i PATH=$STOCK_NONLOGIN_PATH HOME=$HOME \
#         XDG_BIN_HOME=/tmp/evil supply-chain-verify
#     OK  FUNCTIONAL  uv config in effect        uv 99.9.9 started ...
#     OK  PARSED      uv sdist builds blocked    uv reports no_build=All ...
#     OK  PARSED      uv age gate                uv reports exclude-newer cutoff ...
#
# PATH was byte-identical to the honest run; only the env var differed. So the
# variable turned "control PATH" into the strictly weaker "control one env
# var", in the one component whose entire job is to be trustworthy evidence --
# and sudoers env_keep or `sudo -E` can preserve those vars where secure_path
# already protects PATH. The convenience was not worth it: a tool installed to
# a custom prefix is one its own installer tells you to put on PATH anyway, so
# these lists lose almost nothing by ignoring the overrides.
#
# $HOME is still honoured, deliberately: the audit is ABOUT this user's config
# and reads $HOME pervasively already, and tasks/preflight.yml's become-guard
# is what refuses a mis-targeted HOME. That is the pre-existing trust model,
# not new surface. Do NOT "improve" this by adding the override vars back.
discover uv       "$HOME/.local/bin" "$HOME/.cargo/bin"                           || true
discover bun      "$HOME/.bun/bin"                                               || true
discover bunx     "$HOME/.bun/bin"                                               || true
discover deno     "$HOME/.deno/bin"                                              || true
discover go       /usr/local/go/bin "$HOME/go/bin"                                || true
discover pnpm     "$HOME/.local/share/pnpm"                                      || true
discover composer "$HOME/.config/composer/vendor/bin" "$HOME/.composer/vendor/bin" || true
discover poetry  "$HOME/.local/bin" "${POETRY_HOME:-$HOME/.local/share/pypoetry}/venv/bin" || true

# ======================================================================
# yarn
# ======================================================================

# --- yarn age gate, yarn lifecycle scripts  [PARSED] ---
# ---------------------------------------------------------------- yarn -------
# One probe for both surfaces. It lived in the role's preamble only; the CI
# surface grepped ~/.yarnrc.yml for the key and graded that WEAK PRESENT, which
# cannot tell a yarn that implements npmMinimalAgeGate from one that does not.
# MEASURED (VM#10, apt yarnpkg 4.1.0 on Ubuntu 26.04 and Debian 13): harden.sh
# said "Fully applied", a release 13 hours old installed, and that row stayed
# WEAK PRESENT.
#
# BRANCH ON THE EXIT CODE, NOT ON THE TEXT. Below Yarn 4.10.0 the key does not
# exist: `yarn config get npmMinimalAgeGate` prints a usage error ("Couldn't
# find a configuration settings named ...") on STDOUT and exits 1 (MEASURED,
# 4.1.0 and 4.9.4). Read as a value, that became "non-integer
# npmMinimalAgeGate='UsageError:...' (this is the NaN failure)": the wrong
# diagnosis, for a gap only an upgrade closes. In the HOME ~/.yarnrc.yml those
# versions ignore the key without a word and run the install (MEASURED).
#
# DURATION STRINGS. `yarn config get` prints the number yarn will use, so a
# value is judged by that number. MEASURED 2026-11-19: yarn 4.10.3 reads "2d"
# (quoted or not) as its leading integer, 2 MINUTES, and "36500d" as 36500;
# yarn 4.11.0 parses durations ("2d" = 2880). So on 4.10.x a duration string is
# a gate of a few minutes, which the window comparison below reports. Integer
# minutes mean the same on every version that has the key, which is what both
# writers emit.
#
# Yarn 1.x (classic) never reads .yarnrc.yml: `yarn config get` answers
# "undefined" for both keys with exit 0 (MEASURED, 1.22.22), so it is
# recognised by its version first.
if ! have yarn; then
  row "N/A" - "yarn" "yarn not installed"
elif command -v requested >/dev/null 2>&1 && ! requested yarn; then
  row "N/A" - "yarn" "yarn installed but not in the requested ecosystems"
else
  yv=$(yarn --version 2>/dev/null | head -1 | tr -d '\r')
  # A yarn that cannot name its version (a corepack shim that cannot resolve
  # one, a broken yarnPath) must not be reported as one too old for the gate.
  case "$yv" in [0-9]*) ;; *) yv="" ;; esac
  case "$yv" in
    1.*)
      scv_toolchain_gap yarn.classic FUNCTIONAL "yarn hardening" \
        "yarn $yv is classic and ignores .yarnrc.yml entirely: no age gate, and none of the yarn settings this project writes apply. Only Yarn 4.10 or later honours them" ;;
    *)
      yout=$(yarn config get npmMinimalAgeGate 2>/dev/null); yrc=$?
      v=$(printf '%s\n' "$yout" | head -1 | tr -d '\r' | tr -d ' ')
      ywant=$(scv_want_hours)
      ysaid=$(printf '%s\n' "$yout" | head -1 | tr -d '\r' | cut -c1-90)
      if [ "$yrc" -ne 0 ] && [ -z "$yv" ]; then
        scv_toolchain_gap yarn.age-gate PARSED "yarn age gate" \
          "yarn could not report its version (\`yarn --version\` printed none) and \`yarn config get npmMinimalAgeGate\` exited $yrc: ${ysaid:-<no output>}. Whether any age gate is in effect is unknown. Run \`yarn --version\` in this directory to see why it printed none"
      elif [ "$yrc" -ne 0 ]; then
        scv_toolchain_gap yarn.age-gate PARSED "yarn age gate" \
          "yarn $yv has no npmMinimalAgeGate (needs Yarn 4.10.0), so the age gate written to .yarnrc.yml is inert and a release minutes old installs. yarn config get exited $yrc: $ysaid. Only a yarn upgrade closes this"
      else
        yv="${yv:-(version unknown)}"
        case "$v" in
          ''|undefined|null)
            row GAP PARSED "yarn age gate" "yarn $yv reports no npmMinimalAgeGate value, so no age gate is in effect" ;;
          *[!0-9]*)
            row GAP PARSED "yarn age gate" "yarn $yv reports npmMinimalAgeGate='$v', which is not a whole number of minutes, so the gate cannot be confirmed" ;;
          0)
            row GAP PARSED "yarn age gate" "yarn $yv reports npmMinimalAgeGate=0, which disables the gate" ;;
          *)
            if [ -n "$ywant" ] && [ "$v" -lt "$((ywant * 60))" ] 2>/dev/null; then
              row WEAK PARSED "yarn age gate" "yarn $yv reports npmMinimalAgeGate=$v minutes, below the ${ywant}h promised here. Yarn 4.10.x reads a duration string such as \"2d\" as 2 minutes; write integer minutes"
            else
              row OK PARSED "yarn age gate" "yarn $yv reports npmMinimalAgeGate=$v minutes"
            fi ;;
        esac
      fi
      v=$(yarn config get enableScripts 2>/dev/null | head -1 | tr -d '\r' | tr -d ' ')
      if [ "$v" = "false" ]; then
        row OK PARSED "yarn lifecycle scripts blocked" "yarn reports enableScripts=false"
      else
        row GAP PARSED "yarn lifecycle scripts blocked" "yarn reports enableScripts=${v:-<unset>}"
      fi
      ;;
  esac
fi

# ======================================================================
# bun
# ======================================================================

# --- bun install scripts blocked  [FUNCTIONAL] ---
# ---------------------------------------------------- bun: install scripts ---
# bun's global bunfig is NOT consulted for `bun run`, and bun accepts unknown
# bunfig keys silently, so nothing here reads a config file as evidence: the
# probe runs real `bun install`s and watches whether a lifecycle script fires.
#
# THREE ARMS, because a single "empty HOME" control cannot ATTRIBUTE the
# blocking to our bunfig. MEASURED (bun 1.4.0): `~/.npmrc` containing
# `ignore-scripts=true` — which this project deploys by default
# (templates/npmrc.j2, action/harden.sh) — blocks bun's root preinstall with
# NO bunfig present at all. An empty-HOME control strips the npmrc and the
# bunfig together, so it moves as one variable and reports OK on a host whose
# bunfig layer is entirely unread.
#   ISO-OFF   synthetic HOME, our bunfig with ignoreScripts flipped to false
#             -> the preinstall MUST run. This is the fixture control AND the
#                proof that nothing else in that environment blocks.
#   ISO-ON    same synthetic HOME, our bunfig verbatim
#             -> attributes blocking to THIS FILE'S CONTENT, one key apart.
#   EFFECTIVE the user's real environment, untouched
#             -> is the protection actually live for this user.
# OK requires all three. Blocking without attribution is capped at WEAK.
# WHERE IS OUR WRAPPER FOR THIS TOOL?
#
# `command -v <tool>` answers "what runs FIRST", which stops being the same
# question the moment a front-runner delegates -- a version-manager shim
# (asdf, mise, volta, nodenv, pyenv) or another vendor's security wrap.
# MEASURED with an Aikido safe-chain shim in front: our wrapper ran on every
# invocation (the shim strips its own directory from PATH and execs the next
# match, which is us) while every row resolving through `command -v` reported
# it as an unwrapped binary and skipped its behavioural probes entirely.
#
# So ask the wrapper instead of reasoning about its position: it appends its
# own path when SCH_WRAPPER_PROBE is set. Falls back to PATH resolution so a
# wrapper deployed before the probe existed still resolves; callers fall back
# again to `command -v` so the "not ours" branch can still name what did win.
scv_our_wrapper() { # $1 = tool name; prints our wrapper path, or returns 1
  # No result memo: every caller invokes this inside a $(...) command
  # substitution, so any `SCV_WRAP_CACHE_*` write is trapped in the subshell and
  # never reaches the parent — a cache here would be pure dead code (and a trap
  # for anyone who later assumed it worked). Re-probing costs one bounded
  # `--version` per call; that is the honest cost.
  scv__wt="$1"
  scv__wh=""
  # --no-plugins for composer: MEASURED on 2.11.2, an UNWRAPPED `composer
  # --version` run inside a checkout activated the plugin the checkout's
  # allow-plugins enables. The wrapper adds the flag itself; this covers the
  # case the probe exists to find, where something else answers first.
  # --no-interaction, COMPOSER_ALLOW_SUPERUSER=1 and COMPOSER (a file that cannot
  # exist) for the reasons given at the composer version probe: an unwrapped
  # composer run as root on a terminal otherwise waits at a hidden prompt, and a
  # version probe must not boot the checkout it is standing in. Only composer
  # reads those two variables.
  scv__wa=""; case "${scv__wt##*/}" in composer) scv__wa="--no-plugins --no-interaction" ;; esac
  if scv__wp=$(mktemp 2>/dev/null); then
    # Bound the probe like the sibling verifiers (30 s): a hanging tool or a
    # hanging front-runner shim must not hang the whole verify. run_bounded
    # keeps the bound where there is no timeout(1) (stock macOS), where this
    # used to run unbounded, and the variables set on the call reach the tool.
    COMPOSER=/dev/null/composer.json COMPOSER_ALLOW_SUPERUSER=1 RUSTUP_AUTO_INSTALL=0 SCH_WRAPPER_PROBE="$scv__wp" run_bounded 30 "$scv__wt" --version $scv__wa >/dev/null 2>&1 || true
    while IFS= read -r scv__wl; do
      [ -n "$scv__wl" ] || continue
      if [ -f "$scv__wl" ] && grep -q 'supply-chain-harden' "$scv__wl" 2>/dev/null; then
        scv__wh="$scv__wl"; break
      fi
    done < "$scv__wp"
    rm -f "$scv__wp"
  fi
  if [ -z "$scv__wh" ]; then
    scv__wh=$(command -v "$scv__wt" 2>/dev/null)
    grep -q 'supply-chain-harden' "$scv__wh" 2>/dev/null || scv__wh=""
  fi
  [ -n "$scv__wh" ] || return 1
  printf '%s\n' "$scv__wh"
}

scv_epoch() { # $1 = RFC 3339 UTC instant; prints epoch seconds, or nothing
  # GNU date parses with -d. BSD date (macOS, which both surfaces support)
  # has no -d and needs -j -f, and its %S takes no fraction, so drop one.
  # Both failing is reported as an EMPTY result, never as 0: the staleness
  # rows used to fall back to 0 and print "0 day(s) old" for any age.
  scv__ei=$(printf '%s' "$1" | sed 's/\.[0-9]*Z$/Z/')
  date -u -d "$scv__ei" +%s 2>/dev/null \
    || date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$scv__ei" +%s 2>/dev/null
}

bun_global_bunfig() {
  if [ -n "${XDG_CONFIG_HOME:-}" ]; then
    printf '%s\n' "${XDG_CONFIG_HOME}/.bunfig.toml"
  else
    printf '%s\n' "${HOME:-}/.bunfig.toml"
  fi
}

# Which mode does this entry point run in? bun chooses between bun and bunx
# from argv[0]. `bun --help` prints "Usage: bun <command> ...", the same binary
# invoked as bunx prints "Usage: bunx [flags] <package>...". --help is in the
# pass-through list of both wrappers, so this reaches the real bun with argv[0]
# intact, resolves nothing and executes nothing.
bun_entrypoint_mode() { # $1 = path to the entry point
  case "$("$1" --help 2>&1 | grep -m1 '^Usage:')" in
    'Usage: bunx'*) printf 'bunx\n' ;;
    'Usage: bun'*)  printf 'bun\n' ;;
    *)              printf 'unknown\n' ;;
  esac
}

# One arm. $1 = synthetic HOME, or "-" to keep the caller's real environment.
# Each arm gets its OWN fresh project dir, so no arm ever runs a second install
# over the node_modules a previous arm created.
# Prints: ran | blocked | failed   (nothing, rc 1, if the dir could not be made)
bun_scripts_arm() {
  local home="$1" proj rc
  proj=$(mktemp -d 2>/dev/null) || return 1
  printf '{"name":"sch-probe","version":"1.0.0","scripts":{"preinstall":"echo ran > preinstall-ran"}}\n' \
    > "$proj/package.json" || { rm -rf "$proj"; return 1; }
  if [ "$home" = "-" ]; then
    ( cd "$proj" && bun install ) >/dev/null 2>&1
  else
    # Isolated arms: ONLY the bunfig under test may speak. bun 1.4.4 also reads
    # NPM_CONFIG_IGNORE_SCRIPTS / npm_config_ignore_scripts from the environment
    # (MEASURED: =true blocks, =false runs; 1.4.3 and 1.3.14 ignore it), and the
    # hardening exports it, so on a hardened host the ignoreScripts=false arm
    # could never run the fixture and this row was stuck at WEAK "attribution
    # control failed". The npmrc pointers go too, for the same reason.
    ( cd "$proj" && env -u XDG_CONFIG_HOME -u NPM_CONFIG_IGNORE_SCRIPTS -u npm_config_ignore_scripts \
        -u NPM_CONFIG_USERCONFIG -u npm_config_userconfig HOME="$home" bun install ) >/dev/null 2>&1
  fi
  rc=$?
  if   [ -f "$proj/preinstall-ran" ]; then printf 'ran\n'
  elif [ "$rc" -ne 0 ];               then printf 'failed\n'
  else                                     printf 'blocked\n'
  fi
  rm -rf "$proj"
}

if have bun; then
  bver=$(bun --version 2>/dev/null | head -1 | tr -d '\r')
  bpath=$(scv_our_wrapper bun 2>/dev/null) || bpath=$(command -v bun 2>/dev/null)
  bcfg=$(bun_global_bunfig)
  bhint=""
  [ -n "${XDG_CONFIG_HOME:-}" ] && [ ! -f "$bcfg" ] && [ -f "${HOME:-}/.bunfig.toml" ] && \
    bhint=" — XDG_CONFIG_HOME is set, so bun reads $bcfg and IGNORES the ~/.bunfig.toml we deployed"
  # Mode check FIRST. If bun's path holds the bunx wrapper, `bun install` execs
  # whatever `install` is on PATH — MEASURED, it ran /usr/bin/install — and the
  # fixture would report a plausible-looking wrong answer.
  bmode=$(bun_entrypoint_mode "$bpath")
  if [ "$bmode" != "bun" ]; then
    # Do not even run the fixture in this state: in bunx mode `bun install`
    # execs whatever `install` is on PATH.
    row GAP FUNCTIONAL "bun install scripts blocked" "the bun entry point at $bpath does not run in bun mode (\`bun --help\` reported '$bmode'), so \`bun install\` never reaches bun's installer and no bunfig key is enforced — see the runtime row"
  else
    b_eff=$(bun_scripts_arm -)
    if [ -z "$b_eff" ]; then
      row WEAK PRESENT "bun install scripts blocked" "probe infrastructure failed (mktemp); nothing was measured"
    elif [ "$b_eff" = "failed" ]; then
      row GAP FUNCTIONAL "bun install scripts blocked" "\`bun install\` exits non-zero in your environment, so nothing installs at all — bun refuses a bunfig it cannot parse WHOLE and every key in it goes inert. Check $bcfg"
    elif [ ! -f "$bcfg" ]; then
      if [ "$b_eff" = "ran" ]; then
       row GAP FUNCTIONAL "bun install scripts blocked" "bun $bver RAN a project's preinstall, and there is no bunfig at $bcfg — the path this bun actually reads$bhint"
      else
       row WEAK FUNCTIONAL "bun install scripts blocked" "bun $bver did not run the preinstall, but there is NO bunfig at $bcfg$bhint, so this is not our bunfig doing it — some other layer is (this project also deploys ~/.npmrc ignore-scripts=true, which bun honors: MEASURED). The bunfig layer is unreachable here, so every key only it can carry (minimumReleaseAge, frozenLockfile, auto) is inert"
      fi
    else
      b_on=""; b_off=""; b_noflip=0
      iso_on=$(mktemp -d 2>/dev/null); iso_off=$(mktemp -d 2>/dev/null)
      if [ -n "$iso_on" ] && [ -n "$iso_off" ] && cp "$bcfg" "$iso_on/.bunfig.toml" 2>/dev/null; then
       # ISO-OFF is the same file with ONE key changed. If the deployed file has
       # no ignoreScripts line at all there is nothing to flip and no control.
       if grep -qE '^[[:space:]]*ignoreScripts[[:space:]]*=' "$bcfg" 2>/dev/null; then
         sed 's/^\([[:space:]]*ignoreScripts[[:space:]]*=\).*$/\1 false/' "$bcfg" > "$iso_off/.bunfig.toml" 2>/dev/null
       else
         b_noflip=1
       fi
       b_on=$(bun_scripts_arm "$iso_on")
       [ "$b_noflip" -eq 0 ] && b_off=$(bun_scripts_arm "$iso_off")
      fi
      rm -rf "$iso_on" "$iso_off"
      if   [ "$b_noflip" -eq 1 ]; then
       if [ "$b_eff" = "ran" ]; then
         row GAP  FUNCTIONAL "bun install scripts blocked" "$bcfg sets no ignoreScripts key and bun $bver RAN a project's preinstall"
       else
         row WEAK FUNCTIONAL "bun install scripts blocked" "bun $bver did not run the preinstall, but $bcfg sets no ignoreScripts key, so the blocking cannot be attributed to it (this project also deploys ~/.npmrc ignore-scripts=true, which bun honors: MEASURED)"
       fi
      elif [ -z "$b_on" ] || [ -z "$b_off" ]; then
       row WEAK PRESENT    "bun install scripts blocked" "probe infrastructure failed (temp dirs unavailable); the isolation arms did not run"
      elif [ "$b_off" != "ran" ]; then
       row WEAK FUNCTIONAL "bun install scripts blocked" "attribution control failed: with an isolated HOME holding only $bcfg and ignoreScripts flipped to FALSE, bun $bver still reported '$b_off' instead of running the preinstall — either the fixture is dead on this bun or something outside that file and the npm env variables this probe clears (a system npmrc, another env var) is blocking. Enforcement cannot be attributed to our config"
      elif [ "$b_on" = "ran" ]; then
       row GAP  FUNCTIONAL "bun install scripts blocked" "bun $bver RAN a project's preinstall with $bcfg as its ONLY config — this bun does not honor ignoreScripts from a global bunfig. MEASURED inert on bun 1.1.38; honored 1.2.0+. Neither writer version-tiers this key"
      elif [ "$b_eff" = "ran" ]; then
       row GAP  FUNCTIONAL "bun install scripts blocked" "the content of $bcfg DOES block scripts in isolation, but in your real environment bun $bver RAN the preinstall — the file is not reaching this bun$bhint"
      else
       row OK   FUNCTIONAL "bun install scripts blocked" "bun $bver ran the preinstall with $bcfg's ignoreScripts flipped to false, refused it with the file verbatim, and refuses it in your real environment too — enforcement attributed to $bcfg, one key apart"
      fi
    fi
  fi
else
  row "N/A" - "bun install scripts blocked" "bun not installed"
fi

# --- bun install age gate  [PRESENT] ---
# --------------------------------------------------------- bun: age gate -----
# Same helpers as the scripts probe; harmless to define twice.
bun_global_bunfig() {
  if [ -n "${XDG_CONFIG_HOME:-}" ]; then
    printf '%s\n' "${XDG_CONFIG_HOME}/.bunfig.toml"
  else
    printf '%s\n' "${HOME:-}/.bunfig.toml"
  fi
}
bun_entrypoint_mode() { # $1 = path to the entry point
  case "$("$1" --help 2>&1 | grep -m1 '^Usage:')" in
    'Usage: bunx'*) printf 'bunx\n' ;;
    'Usage: bun'*)  printf 'bun\n' ;;
    *)              printf 'unknown\n' ;;
  esac
}

# The bun analogue of npm_implements(), and the reason no bun row trusts a file.
#
# bun has no `bun config get`, and it accepts unknown bunfig keys SILENTLY —
# MEASURED on 1.1.38/1.2.0/1.2.10/1.2.20/1.2.22/1.2.23/1.3.0/1.4.0. A key
# sitting in our file proves nothing about this binary.
#
# What bun DOES do is type-check the keys it implements. Give an implemented
# key a value of the wrong type and bun refuses to load the bunfig and NAMES
# the key on its own error line ("error: Expected number of seconds for
# minimumReleaseAge"); give an unimplemented key the same value and bun is
# silent. The sentinel goes into a LOCAL bunfig.toml in a throwaway directory —
# bun reads ./bunfig.toml from the cwd only — with HOME and XDG_CONFIG_HOME
# stripped, so the only file that can produce that error is the one we wrote.
# Nothing of the user's is read or written.
#
# The grep is anchored to 'error:.*<key>' on purpose: bun echoes OUR offending
# source line back above the message ('2 | minimumReleaseAge = "SCH-..."'), so
# an unanchored grep for the key would match text we wrote — self-evidence.
#
# Three outcomes, three exit codes, because "the probe could not run" is not a
# fact about bun:
#   0 = bun implements the key
#   1 = bun does not implement it (both arms silent — the real negative)
#   2 = not measurable (no temp dir, or this bun rejects unknown keys too, so
#       the sentinel no longer discriminates). The caller must NOT turn this
#       into a claim about bun's version.
#
# LIMIT: only keys with a strict typed parser can be probed this way —
# minimumReleaseAge (number) and auto (enum). The boolean keys (ignoreScripts,
# exact, frozenLockfile, saveTextLockfile) accept a string, a number or an
# array without complaint (MEASURED: bunfig_implements ignoreScripts returns
# "not implemented" on 1.4.0, which implements it), so no discriminator exists
# for them; that is why ignoreScripts is verified by behaviour instead.
bunfig_implements() {
  local key="$1" tmp real bogus
  tmp=$(mktemp -d 2>/dev/null) || return 2
  printf '{"name":"sch-probe","version":"1.0.0"}\n' > "$tmp/package.json" || { rm -rf "$tmp"; return 2; }
  printf '[install]\n%s = "SCH-PROBE-SENTINEL"\n' "$key" > "$tmp/bunfig.toml"
  real=$( cd "$tmp" && env -u XDG_CONFIG_HOME HOME="$tmp" bun pm bin 2>&1 )
  printf '[install]\nschProbeNoSuchKey = "SCH-PROBE-SENTINEL"\n' > "$tmp/bunfig.toml"
  bogus=$( cd "$tmp" && env -u XDG_CONFIG_HOME HOME="$tmp" bun pm bin 2>&1 )
  rm -rf "$tmp"
  # Control: an unknown key MUST be accepted silently, or arm one no longer
  # discriminates. Turn the probe OFF rather than call it a missing key.
  printf '%s' "$bogus" | grep -q 'schProbeNoSuchKey' && return 2
  printf '%s' "$real" | grep -q "error:.*$key" && return 0
  return 1
}

if have bun; then
  bver=$(bun --version 2>/dev/null | head -1 | tr -d '\r')
  bpath=$(scv_our_wrapper bun 2>/dev/null) || bpath=$(command -v bun 2>/dev/null)
  bcfg=$(bun_global_bunfig)
  bhint=""
  [ -n "${XDG_CONFIG_HOME:-}" ] && [ ! -f "$bcfg" ] && [ -f "${HOME:-}/.bunfig.toml" ] && \
    bhint=" — XDG_CONFIG_HOME is set, so bun reads $bcfg and IGNORES the ~/.bunfig.toml we deployed"
  bmode=$(bun_entrypoint_mode "$bpath")
  if [ "$bmode" != "bun" ]; then
    row GAP FUNCTIONAL "bun install age gate" "not measurable as deployed: the bun entry point at $bpath does not run in bun mode (\`bun --help\` reported '$bmode'), so bun's own installer is unreachable — see the runtime row"
  else
    bunfig_implements minimumReleaseAge; bi_rc=$?
    if [ "$bi_rc" -eq 2 ]; then
      row WEAK PRESENT "bun install age gate" "not measurable: the bunfig type-check discriminator did not run against bun $bver (no temp dir, or this bun now rejects unknown bunfig keys generically so the sentinel no longer discriminates). NO claim is made here about whether bun implements minimumReleaseAge"
    elif [ "$bi_rc" -ne 0 ]; then
      row GAP FUNCTIONAL "bun install age gate" "bun $bver does not implement the minimumReleaseAge bunfig key — it accepts the key and ignores it. MEASURED absent on 1.1.38/1.2.0/1.2.10/1.2.20/1.2.22/1.2.23, present on 1.3.0+; neither writer version-tiers this key"
    else
      # Do NOT strip quotes here: a QUOTED number is exactly the failure this
      # branch exists to catch. MEASURED bun 1.3.0/1.4.0 with
      # minimumReleaseAge = "259200": 'error: Expected number of seconds' +
      # 'Invalid Bunfig: failed to load bunfig' — the whole file is refused and
      # ignoreScripts/frozenLockfile/auto die with it. Trailing TOML comments
      # ARE legal (MEASURED: `minimumReleaseAge = 259200 # 3 days` loads fine),
      # so strip a comment before testing for non-digits.
      braw=$(grep -E '^[[:space:]]*minimumReleaseAge[[:space:]]*=' "$bcfg" 2>/dev/null \
             | head -1 | sed 's/^[^=]*=[[:space:]]*//' | sed 's/[[:space:]]*#.*$//' \
             | tr -d '\r' | sed 's/[[:space:]]*$//')
      # bun 1.4.4 also accepts a quoted DURATION ("2d", "48h"). MEASURED: 1.4.4
      # loaded and enforced "2d", "48h" and "3650d"; 1.4.3 and 1.3.14 refused the
      # whole file. So a quoted duration is only a GAP below 1.4.4.
      b_dur_ok=0
      case "$braw" in
        \"[0-9]*[smhdw]\"|\'[0-9]*[smhdw]\')
          [ -n "$bver" ] && [ "$(printf '1.4.4\n%s\n' "$bver" | sort -V | head -1)" = "1.4.4" ] && b_dur_ok=1 ;;
      esac
      case "$b_dur_ok:$braw" in
        1:*)       row WEAK PRESENT "bun install age gate" "bun $bver implements the key and accepts the duration string $braw that $bcfg sets (bun 1.4.4+; older bun refuses the whole bunfig on a string) — but the value is read from OUR file, not from bun: bun has no config readback and the gate only fires against a registry, which a read-only verifier must not exercise" ;;
        0:)        row GAP  PRESENT "bun install age gate" "bun $bver implements minimumReleaseAge but $bcfg does not set it$bhint" ;;
        0:\"*|0:\'*) row GAP  PRESENT "bun install age gate" "minimumReleaseAge in $bcfg is QUOTED ($braw) — bun wants a bare number of seconds, refuses the WHOLE bunfig on a string, and takes ignoreScripts/frozenLockfile/auto down with it. MEASURED on bun 1.3.0/1.4.0: 'Invalid Bunfig: failed to load bunfig'" ;;
        0:*[!0-9]*) row GAP  PRESENT "bun install age gate" "minimumReleaseAge=$braw in $bcfg is not a number of seconds — bun rejects the WHOLE bunfig on a bad value, taking every other key down with it" ;;
        0:0)       row GAP  PRESENT "bun install age gate" "minimumReleaseAge=0 in $bcfg disables the gate" ;;
        *)         row WEAK PRESENT "bun install age gate" "bun $bver implements the key (measured by the type-check discriminator) and $bcfg sets ${braw}s — but the number is read from OUR file, not from bun: bun has no config readback and the gate only fires against a registry, which a read-only verifier must not exercise" ;;
      esac
    fi
  fi
else
  row "N/A" - "bun install age gate" "bun not installed"
fi

# --- bun runtime auto-install blocked  [FUNCTIONAL] ---
# ------------------------------------------------ bun: runtime auto-install --
# `bun run app.js` silently downloads and executes an import it cannot resolve.
# MEASURED on 1.4.0 in a directory with no package.json: `require("is-positive")`
# fetched the package from npm and ran it in 0.18s. The global bunfig CANNOT
# close this — bun does not consult it for `bun run` — so the whole protection
# is the injected --no-install, and the only honest evidence is the argv the
# deployed wrapper actually produces.
bun_entrypoint_mode() { # $1 = path to the entry point
  case "$("$1" --help 2>&1 | grep -m1 '^Usage:')" in
    'Usage: bunx'*) printf 'bunx\n' ;;
    'Usage: bun'*)  printf 'bun\n' ;;
    *)              printf 'unknown\n' ;;
  esac
}

# Ask the DEPLOYED wrapper what argv it hands the real bun, with a stub standing
# in for the binary: no network, no install, no side effects. Same construction
# as cargo_wrapper_dispatch(). Both surfaces embed REAL_BUN='<path>' on a line
# of its own and both carry the marker "supply-chain-harden" (the role writes
# "supply-chain-hardening", which contains it).
bun_wrapper_dispatch() { # $1 = bun|bunx, rest = the argv to test
  local name w tmp
  name="$1"; shift
  # OURS, not whatever resolves first: a delegating front-runner makes those
  # different files, and this probe must dissect ours.
  w=$(scv_our_wrapper "$name" 2>/dev/null) || return 1
  tmp=$(mktemp -d 2>/dev/null) || return 1
  printf '#!/bin/sh\nfor a in "$@"; do printf "%%s\\n" "$a"; done\n' > "$tmp/real"
  chmod +x "$tmp/real" 2>/dev/null
  sed "s|^REAL_BUN=.*|REAL_BUN='$tmp/real'|" "$w" > "$tmp/$name" 2>/dev/null
  chmod +x "$tmp/$name" 2>/dev/null
  ( cd "$tmp" && "./$name" "$@" 2>/dev/null )
  rm -rf "$tmp"
}

if have bun; then
  bver=$(bun --version 2>/dev/null | head -1 | tr -d '\r')
  bpath=$(scv_our_wrapper bun 2>/dev/null) || bpath=$(command -v bun 2>/dev/null)
  if ! grep -q 'supply-chain-harden' "$bpath" 2>/dev/null; then
    row GAP PRESENT    "bun runtime auto-install blocked" "bun resolves to an unwrapped binary at $bpath; \`bun run\` downloads and executes missing imports, and the global bunfig is not consulted for \`bun run\` at all"
  elif [ "$(bun_entrypoint_mode "$bpath")" != "bun" ]; then
    # MUST precede the --help flag grep. A wrapper whose REAL_BUN is missing
    # exits 127 from the recursion guard, so `bun --help` prints only the
    # guard's message and `bun --version` is EMPTY — MEASURED: with the check
    # in the other order the row read "bun  does not list that flag", blaming
    # bun's feature set for a broken wrapper.
    row GAP FUNCTIONAL "bun runtime auto-install blocked" "the entry point at $bpath does not run in bun mode (\`bun --help\` did not print bun usage): either the bunx wrapper was written over the bun wrapper through the bunx symlink — MEASURED, \`bun install\` then execs whatever \`install\` is on PATH — or the embedded REAL_BUN is gone and the guard exits 127 (MEASURED: '[supply-chain-hardening] error: real bun not found at ...; refusing to recurse')"
  elif ! bun --help 2>&1 | grep -q -- '--no-install'; then
    row GAP FUNCTIONAL "bun runtime auto-install blocked" "the wrapper at $bpath injects --no-install but bun ${bver:-<version unavailable>} does not list that flag in its own --help — the injection is inert"
  else
    brun=$(bun_wrapper_dispatch bun run app.js)
    binst=$(bun_wrapper_dispatch bun install)
    if [ -z "$brun" ]; then
      row GAP FUNCTIONAL "bun runtime auto-install blocked" "the wrapper at $bpath produced no argv for \`bun run app.js\` — it refuses to run, or its REAL_BUN assignment is no longer at the start of a line for the probe to rewrite"
    elif [ "$(printf '%s\n' "$brun" | head -1)" != "--no-install" ]; then
      row GAP FUNCTIONAL "bun runtime auto-install blocked" "the wrapper at $bpath does not put --no-install FIRST for \`bun run app.js\` (observed argv began '$(printf '%s\n' "$brun" | head -1)'); bun consumes the flag only before the runtime target, so runtime auto-install is live"
    elif printf '%s\n' "$binst" | grep -qx -- '--no-install'; then
      row GAP FUNCTIONAL "bun runtime auto-install blocked" "the wrapper at $bpath injects --no-install into \`bun install\` as well — that is the bunx wrapper sitting at bun's path; package management is broken"
    else
      row OK  FUNCTIONAL "bun runtime auto-install blocked" "the deployed wrapper hands real bun \`--no-install run app.js\` and leaves \`bun install\` untouched (observed argv); bun $bver's own --help still lists --no-install — help-text evidence, since bun accepts unknown flags SILENTLY (MEASURED: \`bun --no-such-flag -e 'console.log(1)'\` printed 1, rc 0), so acceptance alone would prove nothing"
    fi
  fi
else
  row "N/A" - "bun runtime auto-install blocked" "bun not installed"
fi

# --- bunx fetch-and-execute blocked  [FUNCTIONAL] ---
# ------------------------------------------------------------- bunx ----------
# `bunx <pkg>` fetches and executes in one step. It is a SEPARATE entry point:
# the global bunfig does not apply to it, so minimumReleaseAge / ignoreScripts /
# frozenLockfile never reach this path and the wrapper is the entire control.
bun_entrypoint_mode() { # $1 = path to the entry point
  case "$("$1" --help 2>&1 | grep -m1 '^Usage:')" in
    'Usage: bunx'*) printf 'bunx\n' ;;
    'Usage: bun'*)  printf 'bun\n' ;;
    *)              printf 'unknown\n' ;;
  esac
}
bun_wrapper_dispatch() { # $1 = bun|bunx, rest = the argv to test
  local name w tmp
  name="$1"; shift
  # OURS, not whatever resolves first: a delegating front-runner makes those
  # different files, and this probe must dissect ours.
  w=$(scv_our_wrapper "$name" 2>/dev/null) || return 1
  tmp=$(mktemp -d 2>/dev/null) || return 1
  printf '#!/bin/sh\nfor a in "$@"; do printf "%%s\\n" "$a"; done\n' > "$tmp/real"
  chmod +x "$tmp/real" 2>/dev/null
  sed "s|^REAL_BUN=.*|REAL_BUN='$tmp/real'|" "$w" > "$tmp/$name" 2>/dev/null
  chmod +x "$tmp/$name" 2>/dev/null
  ( cd "$tmp" && "./$name" "$@" 2>/dev/null )
  rm -rf "$tmp"
}

# `bun --version x <pkg>`: MEASURED on bun 1.4.4, real bun ignores a leading
# metadata flag when more follows and fetch-and-executes the package. A bun
# wrapper that passes any leading metadata flag through (the Action's did,
# keying off $1 alone) hands it over without --no-install.
bmeta_bad=""
if have bun && bmw=$(scv_our_wrapper bun 2>/dev/null); then
  bmo=$(bun_wrapper_dispatch bun --version x some-cli)
  if [ -n "$bmo" ] && [ "$(printf '%s\n' "$bmo" | head -1)" != "--no-install" ]; then
    bmeta_bad="the bun wrapper at $bmw hands \`bun --version x some-cli\` to real bun WITHOUT --no-install first (observed argv began '$(printf '%s\n' "$bmo" | head -1)'); bun ignores the metadata flag when more follows and fetch-and-executes the package"
  fi
fi

if ! have bun && ! have bunx; then
  row "N/A" - "bunx fetch-and-execute blocked" "bun not installed"
elif ! have bunx; then
  # `bun x` is a DIFFERENT argv shape from `bun run`, which is all the runtime
  # row dispatches, so do not assert that row covers it — measure it.
  # `create` and `init` are already in the wrapper's pass-through list; if `x`
  # ever joined them this entry point would be unhardened while the runtime row
  # still reported OK.
  bpath=$(scv_our_wrapper bun 2>/dev/null) || bpath=$(command -v bun 2>/dev/null)
  bxo=$(bun_wrapper_dispatch bun x some-cli)
  if ! grep -q 'supply-chain-harden' "$bpath" 2>/dev/null; then
    row GAP PRESENT    "bunx fetch-and-execute blocked" "bunx is not on PATH and bun at $bpath is unwrapped, so \`bun x <pkg>\` fetches and executes with no age gate and no script blocking"
  elif [ "$(bun_entrypoint_mode "$bpath")" != "bun" ]; then
    row GAP FUNCTIONAL "bunx fetch-and-execute blocked" "bunx is not on PATH and the bun entry point at $bpath does not run in bun mode (\`bun --help\` reported '$(bun_entrypoint_mode "$bpath")') — the surviving fetch-and-execute path cannot be exercised; see the runtime row"
  elif [ "$(printf '%s\n' "$bxo" | head -1)" != "--no-install" ]; then
    row GAP FUNCTIONAL "bunx fetch-and-execute blocked" "bunx is not on PATH and the bun wrapper at $bpath does not put --no-install first for \`bun x some-cli\` (observed argv began '$(printf '%s\n' "$bxo" | head -1)') — the remaining fetch-and-execute entry point is live"
  elif [ -n "$bmeta_bad" ]; then
    row GAP FUNCTIONAL "bunx fetch-and-execute blocked" "bunx is not on PATH, and $bmeta_bad"
  else
    row OK  FUNCTIONAL "bunx fetch-and-execute blocked" "bunx is not on PATH; the deployed bun wrapper hands real bun \`--no-install x some-cli\` (observed argv), so the surviving fetch-and-execute entry point is covered"
  fi
else
  bxpath=$(scv_our_wrapper bunx 2>/dev/null) || bxpath=$(command -v bunx 2>/dev/null)
  bxmode=$(bun_entrypoint_mode "$bxpath")
  if ! grep -q 'supply-chain-harden' "$bxpath" 2>/dev/null; then
    row GAP PRESENT    "bunx fetch-and-execute blocked" "bunx resolves to an unwrapped binary at $bxpath; \`bunx <pkg>\` fetches and executes in one step with no age gate and no script blocking"
  elif [ "$bxmode" != "bunx" ]; then
    row GAP FUNCTIONAL "bunx fetch-and-execute blocked" "the wrapper at $bxpath does not reach a working bun in bunx mode (\`bunx --help\` reported '$bxmode') — argv[0] is lost, or the embedded REAL_BUN is missing and the guard exits 127; either way every bunx call has changed meaning"
  else
    bxout=$(bun_wrapper_dispatch bunx some-cli)
    # A metadata flag IN FRONT of a package is its own argv shape. MEASURED on
    # bun 1.4.3 and 1.4.4: unwrapped, `bunx --version cowsay hi` ignores the
    # flag's metadata meaning and fetch-and-executes cowsay. The wrapper once
    # passed any leading metadata flag through untouched, so prepending one flag
    # was a complete bypass while `bunx some-cli` above still looked hardened.
    # The bun entry point has the same shape one token later (`bun --version x
    # <pkg>`), which is why bmeta is checked below as well.
    bxmeta=$(bun_wrapper_dispatch bunx --version some-cli)
    if [ -z "$bxout" ]; then
      row GAP FUNCTIONAL "bunx fetch-and-execute blocked" "the wrapper at $bxpath produced no argv for \`bunx some-cli\` — it refuses to run, or its REAL_BUN assignment is no longer at the start of a line for the probe to rewrite"
    elif [ "$(printf '%s\n' "$bxout" | head -1)" != "--no-install" ]; then
      row GAP FUNCTIONAL "bunx fetch-and-execute blocked" "the wrapper at $bxpath does not put --no-install FIRST for \`bunx some-cli\` (observed argv began '$(printf '%s\n' "$bxout" | head -1)'); anywhere else bun hands the flag to the fetched CLI instead of consuming it, and a typosquatted name is still fetched and executed"
    elif [ "$(printf '%s\n' "$bxmeta" | head -1)" != "--no-install" ]; then
      row GAP FUNCTIONAL "bunx fetch-and-execute blocked" "the wrapper at $bxpath hands \`bunx --version some-cli\` to real bun WITHOUT --no-install first (observed argv began '$(printf '%s\n' "$bxmeta" | head -1)'); with a package name after it bunx ignores the metadata flag and fetch-and-executes the package, so prepending one flag bypasses the wrapper"
    elif [ -n "$bmeta_bad" ]; then
      row GAP FUNCTIONAL "bunx fetch-and-execute blocked" "bunx is wrapped, but $bmeta_bad"
    else
      row OK  FUNCTIONAL "bunx fetch-and-execute blocked" "the deployed wrapper hands real bun \`--no-install\` as the FIRST argument for both \`bunx some-cli\` and \`bunx --version some-cli\`, and keeps bunx mode (observed argv, and \`bunx --help\` still prints bunx usage)"
    fi
  fi
fi

# ======================================================================
# deno
# ======================================================================

# --- deno publish-age gate  [FUNCTIONAL] ---
# ------------------------------------------------------------------ deno ------
# Deno has NO global config file (deno.json/deno.jsonc are per-project), so the
# entire age gate is the injected --minimum-dependency-age flag and nothing
# else. There is no file to read back and no `deno config get`. That gives the
# probe two independent jobs, and BOTH must pass before this row can be OK:
#
#   1. WHAT THE WRAPPER DOES — run the DEPLOYED wrapper against an argv-echoing
#      stub and read the argv it actually produces.
#   2. WHAT DENO BELIEVES — ask the real deno binary whether it implements the
#      flag at all, and whether it accepts the VALUE we inject.
#
# Job 1 alone is self-evidence: it observes our own bash `case` producing argv.
# It proves the wrapper dispatches, never that anything is enforced. An earlier
# draft of this probe made job 2 optional and shipped OK on a deno that rejects
# the flag outright — the wrapper had broken every `deno run` on the host and
# the verifier called it covered. Job 2 is now a hard precondition of OK.
#
# WHY THE FLAG-PREFIXED FORMS ARE PROBED SEPARATELY (commit 0b1954a).
# `deno -A run app.ts` is the ordinary invocation. The pre-0b1954a wrapper read
# the subcommand from $1, matched nothing, fell through the pass-through arm and
# ran with NO age gate. An ungated run and a gated one are identical at the
# terminal, and a verifier that probes only `deno run app.ts` certifies the one
# form that works. Same bug class as the cargo argv[1] defect. The SEP form
# (`deno --log-level debug run app.ts`) is the same bug one step out: the current
# wrapper takes the first NON-FLAG argument as the subcommand, so a global flag
# whose value is a separate word donates that value as the subcommand and the
# call passes through ungated. That hole is still open in both surfaces.
#
# WHY A NON-FETCHING FORM IS PROBED TOO.
# deno ERRORS when handed --minimum-dependency-age on a subcommand that does not
# accept it, so a too-wide injection list does not weaken the gate, it BREAKS the
# command. `deno task` is how most Deno projects invoke everything; it was in the
# action's list. Over-injection must read as a GAP, not as coverage. fmt/task are
# only the negative half of that test — the positive half (does deno accept the
# flag on each of the ten subcommands the wrapper DOES inject into?) is asked of
# deno's own per-subcommand --help below.

deno_real_binary() {
  # The deno to interrogate about flag support. If deno resolves to our wrapper,
  # asking IT would re-inject the flag and we would be testing the wrapper, not
  # deno. Read the target the wrapper actually execs instead.
  local p t
  p=$(command -v deno 2>/dev/null) || return 1
  [ -n "$p" ] || return 1
  if grep -q 'supply-chain-harden' "$p" 2>/dev/null; then
    t=$(grep -oE "^REAL_DENO='[^']*'" "$p" 2>/dev/null | head -1 | sed "s/^[^=]*='//; s/'\$//")
    [ -n "$t" ] && [ -x "$t" ] || return 1
    printf '%s\n' "$t"; return 0
  fi
  printf '%s\n' "$p"
}

deno_wrapper_on_path() {
  # A shadowed wrapper is by definition NOT on the resolved path, so looking
  # only where deno resolves reports it as "never deployed" -- wrong diagnosis,
  # wrong fix. Search every PATH entry.
  local d hit old_ifs
  old_ifs="$IFS"; IFS=:; set -f
  for d in $PATH; do
    [ -n "$d" ] || continue
    if [ -z "${hit:-}" ] && [ -f "$d/deno" ] && grep -q "supply-chain-harden" "$d/deno" 2>/dev/null; then
      hit="$d/deno"
    fi
  done
  set +f; IFS="$old_ifs"
  [ -n "${hit:-}" ] || return 1
  printf '%s\n' "$hit"
}

# Does THIS deno IMPLEMENT --minimum-dependency-age, or does it treat it exactly
# like a flag we invented? This is the npm_implements() analogue.
#
# It must NOT be done by string-matching deno's error prose. clap 3 (deno 1.x)
# says "Found argument 'X' which wasn't expected"; clap 4 (deno 2.x) says
# "unexpected argument 'X' found". A verifier that knows only one of those
# wordings reports "did not reject" for a deno that rejected — MEASURED: the
# wording-glob draft of this probe emitted OK FUNCTIONAL against a simulated
# deno 1.46.3 that rejects the flag, on a host where the wrapper had broken
# every `deno run`. Wording globs fail toward green, which is the one direction
# that is not allowed.
#
# So ask the SAME question twice: once with our flag, once with a flag deno
# cannot possibly implement. Normalise BOTH flag names out of BOTH answers.
#   identical  -> our flag is exactly as unknown to this parser as the invented
#                 one  -> rejects
#   different  -> the parser consumed ours and went on to complain about
#                 something else (the missing <SCRIPT_ARG>)  -> implements
# Nothing is fetched, executed or cached either way: both runs die in argument
# parsing before deno touches a registry.
deno_flag_status() {   # <real-deno> <subcommand> -> implements|rejects|inconclusive
  local drb="$1" sub="$2" ours ctl ctlrc
  ours=$("$drb" "$sub" --minimum-dependency-age=P2D 2>&1 </dev/null | head -20)
  ctl=$("$drb" "$sub" --sch-probe-not-a-real-flag=P2D 2>&1 </dev/null)
  ctlrc=$?
  ctl=$(printf '%s\n' "$ctl" | head -20)
  # The control must actually be REFUSED and must name the invented flag. A
  # binary that swallows unknown flags and exits 0 (a stub, a shim, a shell
  # function) tells us nothing about the parser, and comparing against its
  # non-answer would report "implements" for anything. Inconclusive, not OK.
  [ "$ctlrc" -ne 0 ] || { printf 'inconclusive\n'; return 0; }
  case "$ctl" in *sch-probe-not-a-real-flag*) ;; *) printf 'inconclusive\n'; return 0 ;; esac
  # Cross-normalise: replace BOTH names in BOTH strings. clap emits
  # "tip: a similar argument exists: '--minimum-dependency-age'" only for flags
  # it defines, so that tip appearing in the control's answer is itself proof of
  # implementation; normalising it away in both directions keeps the comparison
  # about SHAPE rather than about which name got mentioned.
  ours=$(printf '%s' "$ours" | sed 's/--minimum-dependency-age/SCHFLAG/g; s/--sch-probe-not-a-real-flag/SCHFLAG/g')
  ctl=$(printf '%s' "$ctl"   | sed 's/--minimum-dependency-age/SCHFLAG/g; s/--sch-probe-not-a-real-flag/SCHFLAG/g')
  if [ "$ours" = "$ctl" ]; then printf 'rejects\n'; else printf 'implements\n'; fi
}

# Does this deno accept the VALUE the wrapper actually injects?
# deno_minimum_dependency_age is operator-settable (defaults/main.yml:54), and a
# flag that is implemented but handed an unparseable duration fails the command
# just as hard as an unknown flag — the uv `exclude_newer = "48 hours"` shape,
# where a "looks right" value broke the tool outright. Same control trick, one
# axis over: compare our value against a value that CANNOT be a valid duration.
#   identical after normalising the values out -> ours is refused like garbage
#   different                                  -> ours got further than garbage
# If the garbage control is NOT refused, this deno does not validate the value
# at parse time (or we are talking to a stub) and the answer is inconclusive —
# never a GAP on the strength of a probe that established nothing.
deno_value_status() {   # <real-deno> <subcommand> <value> -> accepted|rejected|inconclusive
  local drb="$1" sub="$2" val="$3" garbage='sch~not~a~duration' ours ctl ctlrc
  [ -n "$val" ] || { printf 'inconclusive\n'; return 0; }
  ours=$("$drb" "$sub" "--minimum-dependency-age=$val" 2>&1 </dev/null | head -20)
  ctl=$("$drb" "$sub" "--minimum-dependency-age=$garbage" 2>&1 </dev/null)
  ctlrc=$?
  ctl=$(printf '%s\n' "$ctl" | head -20)
  [ "$ctlrc" -ne 0 ] || { printf 'inconclusive\n'; return 0; }
  case "$ctl" in *"$garbage"*) ;; *) printf 'inconclusive\n'; return 0 ;; esac
  # Literal substitution via bash pattern-quoting, not sed: $val comes out of
  # observed argv and may contain characters sed would read as syntax.
  ours=${ours//"$val"/SCHVAL}
  ctl=${ctl//"$garbage"/SCHVAL}
  if [ "$ours" = "$ctl" ]; then printf 'rejected\n'; else printf 'accepted\n'; fi
}

# Is the separate-word-value bypass REACHABLE on this deno?
# The wrapper mis-dispatches `deno --log-level debug run app.ts` no matter what
# deno thinks — that is measured argv. But calling it a GAP is only fair if deno
# itself accepts a global flag whose value is a separate word BEFORE the
# subcommand. Same control trick, third axis: ask with the real flag and with an
# invented one in the same position.
#   different answers -> deno consumed `--log-level debug` and went on to
#                        complain about the missing script  -> reachable
#   identical answers -> deno rejects both  -> not reachable in this spelling
# Nothing is fetched: no script positional, so both runs die in arg parsing.
deno_presub_reachable() {   # <real-deno> -> yes|no|inconclusive
  local drb="$1" ours ctl ctlrc
  ours=$("$drb" --log-level debug run 2>&1 </dev/null | head -20)
  ctl=$("$drb" --sch-probe-not-a-real-flag debug run 2>&1 </dev/null)
  ctlrc=$?
  ctl=$(printf '%s\n' "$ctl" | head -20)
  [ "$ctlrc" -ne 0 ] || { printf 'inconclusive\n'; return 0; }
  case "$ctl" in *sch-probe-not-a-real-flag*) ;; *) printf 'inconclusive\n'; return 0 ;; esac
  ours=$(printf '%s' "$ours" | sed 's/--log-level/SCHFLAG/g; s/--sch-probe-not-a-real-flag/SCHFLAG/g')
  ctl=$(printf '%s' "$ctl"   | sed 's/--log-level/SCHFLAG/g; s/--sch-probe-not-a-real-flag/SCHFLAG/g')
  if [ "$ours" = "$ctl" ]; then printf 'no\n'; else printf 'yes\n'; fi
}

# The subcommands the DEPLOYED wrapper injects into, read off its own case arm.
# This reads our own artifact, and that is all it is for: it decides which
# QUESTIONS to ask deno. Every answer comes from deno's own --help table.
# Empty output is possible (the case arm was reordered or rewritten) and must
# not be mistaken for "nothing to check" — the caller refuses to claim
# per-subcommand coverage it never computed.
deno_injected_subs() {
  grep -oE '^[[:space:]]*[a-z]+(\|[a-z]+)+\)' "$1" 2>/dev/null | head -1 \
    | tr -d ' )' | tr '|' ' '
}

deno_wrapper_probe() {
  # Runs the DEPLOYED wrapper against an argv-echoing stub and prints five
  # tagged lines. No network, no compile, no deno, no side effects: the stub is
  # the only thing that ever executes.
  #   BARE|<argv>   deno run app.ts                      -- the canonical form
  #   FLAG|<argv>   deno -A run app.ts                   -- the common form, 0b1954a
  #   SEP|<argv>    deno --log-level debug run app.ts    -- separate-word value
  #   FMT|<argv>    deno fmt                             -- must NOT be injected into
  #   TASK|<argv>   deno task build                      -- must NOT be injected into
  local w tmp
  w=$(command -v deno 2>/dev/null) || return 1
  [ -n "$w" ] || return 1
  grep -q 'supply-chain-harden' "$w" 2>/dev/null || return 1
  # A noexec TMPDIR makes the rewritten copy unrunnable; output comes back empty
  # and the caller reports WEAK "could not be exercised", never a false GAP.
  tmp=$(mktemp -d 2>/dev/null) || return 1
  printf '#!/bin/sh\necho "$*"\n' > "$tmp/real"
  chmod +x "$tmp/real" 2>/dev/null
  # Repoint the wrapper's real-deno at the stub. Both surfaces assign it on its
  # own line as REAL_DENO='<path>'.
  sed "s|^REAL_DENO=.*|REAL_DENO='$tmp/real'|" "$w" > "$tmp/deno" 2>/dev/null
  # PROVE the substitution landed before running anything. If it did not, the
  # copy still points at the GENUINE deno and this probe would really execute
  # `deno -A run app.ts` and `deno task build` in the verifier's cwd — network
  # fetch, full permissions, arbitrary task execution — breaking the script's
  # own read-only promise. The recursion guard does NOT save us there: REAL_DENO
  # is still executable and still not equal to $0, so the wrapper would exec it
  # happily. (An earlier draft claimed the guard would fire. It would not.)
  grep -qF "REAL_DENO='$tmp/real'" "$tmp/deno" 2>/dev/null || { rm -rf "$tmp"; return 1; }
  chmod +x "$tmp/deno" 2>/dev/null
  printf 'BARE|%s\n' "$( "$tmp/deno" run app.ts 2>/dev/null )"
  printf 'FLAG|%s\n' "$( "$tmp/deno" -A run app.ts 2>/dev/null )"
  printf 'SEP|%s\n'  "$( "$tmp/deno" --log-level debug run app.ts 2>/dev/null )"
  printf 'FMT|%s\n'  "$( "$tmp/deno" fmt 2>/dev/null )"
  printf 'TASK|%s\n' "$( "$tmp/deno" task build 2>/dev/null )"
  rm -rf "$tmp"
}

deno_field() { printf '%s\n' "$1" | grep "^$2|" | head -1 | sed "s/^$2|//"; }

# deno >= 2.8 reads npm's min-release-age from ~/.npmrc, and >= 2.9 also from
# NPM_CONFIG_MIN_RELEASE_AGE. MEASURED: 2.7.14 honoured neither; 2.8.x the file;
# 2.9.3 and 2.9.8 both. That gates npm: specifiers only, so an UNWRAPPED deno
# with it set is partly gated, not ungated. The rows below used to say "deno
# has no config file to fall back on", which is no longer true.
deno_npm_fallback() { # prints the min-release-age value deno would read, or fails
  [ -n "$dver" ] || return 1
  [ "$(printf '2.8.0\n%s\n' "$dver" | sort -V | head -1)" = "2.8.0" ] || return 1
  _dnf=""
  if [ "$(printf '2.9.0\n%s\n' "$dver" | sort -V | head -1)" = "2.9.0" ]; then
    _dnf="${NPM_CONFIG_MIN_RELEASE_AGE:-${npm_config_min_release_age:-}}"
  fi
  [ -n "$_dnf" ] || _dnf=$(sed -n 's/^[[:space:]]*min-release-age[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$HOME/.npmrc" 2>/dev/null | tail -1)
  [ -n "$_dnf" ] && printf '%s' "$_dnf"
}

deno_unwrapped_row() { # <why it is not wrapped>
  if _dnr=$(deno_npm_fallback); then
    row WEAK PARSED "deno publish-age gate" \
      "$1. deno $dver does read npm's min-release-age ($_dnr day(s)), so npm: specifiers are age-gated; jsr: and https: imports are not. To restore the wrapper, $(scv_reapply)"
  else
    row GAP PRESENT "deno publish-age gate" \
      "$1, so no invocation is age-gated${dver:+ (deno $dver reads no npm min-release-age here)}"
  fi
}

if ! have deno; then
  row "N/A" - "deno publish-age gate" "deno not installed"
  row "N/A" - "deno age-gate flag support (precondition)" "deno not installed"
elif ! requested deno; then
  row "N/A" - "deno publish-age gate" "deno installed but not in the requested ecosystems"
  row "N/A" - "deno age-gate flag support (precondition)" "deno installed but not in the requested ecosystems"
else
  dp=$(scv_our_wrapper deno 2>/dev/null) || dp=$(command -v deno 2>/dev/null)
  dwrapped=0
  grep -q 'supply-chain-harden' "$dp" 2>/dev/null && dwrapped=1

  # ---- interrogate the TOOL (row 2 prints at the bottom of this block) -------
  drb=$(deno_real_binary)
  dver=""; dvout=""; dvrc=0; dlive=0; dhelp=0; dstat=inconclusive
  dbadsubs=""; dsubs=""; dsubscope=""; dloglevel=0; dsepreach=inconclusive
  if [ -n "$drb" ]; then
    # LIVENESS FIRST, BY RUNNING IT. `[ -x ]` is a file mode bit, not a run.
    # cargo-cooldown shipped 0755, on PATH, and died in ld.so with
    # GLIBC_2.39-not-found (design-principles.md, "Present but not runnable").
    # A dead deno answers every probe below with silence, and silence read as
    # "did not reject" is exactly how the first draft of this design emitted OK
    # FUNCTIONAL on a host where every `deno run` exits 127 — MEASURED. Worse,
    # the dispatch probe substitutes a stub for the real deno, so the argv trace
    # is flawless precisely when the real binary cannot run. Nothing below runs
    # unless deno runs, and "deno ran" means rc 0 AND a first line that is
    # actually deno's version banner — not merely non-empty output, which any
    # loader error also produces.
    dvout=$("$drb" --version 2>&1 </dev/null); dvrc=$?
    # Keep the first line only, and drop the calling shell's own
    # "<script>: line N: " prefix so the row quotes the loader's message
    # rather than the verifier's stack frame.
    dvout=$(printf '%s\n' "$dvout" | head -1 | sed 's|^[^ ]*: line [0-9]*: ||')
    case "$dvrc:$dvout" in
      0:deno\ *) dlive=1; dver=$(printf '%s\n' "$dvout" | awk '{print $2}') ;;
    esac
  fi
  if [ "$dlive" = 1 ]; then
    # deno's own compiled-in clap argument table. There is no file we could
    # plant to make a flag appear here, which is what makes it the npm_implements
    # equivalent — but a help entry is deno's argument list, not evidence of
    # enforcement, so on its own it caps at WEAK/PARSED.
    # From deno 2.9.6 the help lists only the short name --min-dep-age; the long
    # name the wrapper injects is a hidden alias, still accepted and enforced
    # (MEASURED on 2.9.6 and 2.9.8). Matching only the long name made both deno
    # rows WEAK on every current deno.
    "$drb" run --help 2>/dev/null </dev/null | grep -qE -- '--(minimum-dependency-age|min-dep-age)' && dhelp=1
    dstat=$(deno_flag_status "$drb" run)
    # Is the separate-word-value bypass actually REACHABLE on this deno?
    # Two signals, and the GAP requires the stronger one: deno's own top-level
    # help table (PARSED-class) and the parser itself (FUNCTIONAL-class).
    "$drb" --help 2>/dev/null </dev/null | grep -q -- '--log-level' && dloglevel=1
    dsepreach=$(deno_presub_reachable "$drb")
    # PER-SUBCOMMAND ACCEPTANCE. The wrapper injects into ten subcommands; deno
    # ERRORS when handed the flag on one that does not take it, so an injection
    # list wider than deno's support does not weaken the gate, it BREAKS those
    # commands. Probing `run` alone certifies one tenth of the blast radius.
    if [ "$dhelp" = 1 ] && [ "$dwrapped" = 1 ]; then
      dsubs=$(deno_injected_subs "$dp")
      if [ -n "$dsubs" ]; then
        dsubscope=" of every subcommand the wrapper injects into"
        for dsub in $dsubs; do
          [ "$dsub" = run ] && continue
          "$drb" "$dsub" --help 2>/dev/null </dev/null | grep -qE -- '--(minimum-dependency-age|min-dep-age)' \
            || dbadsubs="$dbadsubs $dsub"
        done
      fi
      # dsubs empty => the case arm could not be read => dsubscope stays empty
      # and no per-subcommand claim is made. Silence is not coverage.
    fi
  fi

  # ---- row 1: is the gate actually injected, on the forms people really use --
  if [ "$dwrapped" = 0 ]; then
    # Not wrapped. Four distinct reasons, four different fixes, and every one of
    # them looks identical to anything that only stats a file. Evidence is
    # PRESENT, not FUNCTIONAL: a marker grep and a file test were all that
    # established these — nothing was executed to reach the conclusion. Matches
    # templates/verify.sh.j2:257-266, which already uses GAP PRESENT here.
    if dshadow=$(deno_wrapper_on_path); then
      row GAP PRESENT "deno publish-age gate" \
        "wrapper is at $dshadow but deno resolves to $dp — the wrapper is shadowed and never runs, so no invocation is age-gated"
    elif [ -x "${dp}-real" ]; then
      row GAP PRESENT "deno publish-age gate" \
        "$dp is an unwrapped binary but ${dp}-real is beside it — a deno upgrade or a re-run of the official installer overwrote the wrapper; $(scv_reapply)"
    elif [ -f /etc/profile.d/deno-cooldown.sh ] && grep -q 'minimum-dependency-age' /etc/profile.d/deno-cooldown.sh 2>/dev/null; then
      deno_unwrapped_row "no wrapper at $dp; only the /etc/profile.d/deno-cooldown.sh alias, which fires in interactive login shells ONLY — scripts, agents, CI and cron are not wrapped"
    else
      deno_unwrapped_row "no wrapper and no alias; deno at $dp is not wrapped"
    fi
  else
    # Wrapped. Check the real target BEFORE the dispatch probe: the probe
    # repoints REAL_DENO at a stub, so an orphaned wrapper would dispatch
    # perfectly under the probe while exiting 127 on every real call.
    dtarget=$(grep -oE "^REAL_DENO='[^']*'" "$dp" 2>/dev/null | head -1 | sed "s/^[^=]*='//; s/'\$//")
    if [ -z "$dtarget" ] || [ ! -x "$dtarget" ]; then
      row GAP PRESENT "deno publish-age gate" \
        "wrapper at $dp but its real target '${dtarget:-<none>}' is missing or not executable — the recursion guard makes every deno call exit 127"
    else
      dprobe=$(deno_wrapper_probe)
      dbare=$(deno_field "$dprobe" BARE)
      dflag=$(deno_field "$dprobe" FLAG)
      dsep=$(deno_field "$dprobe" SEP)
      dfmt=$(deno_field "$dprobe" FMT)
      dtask=$(deno_field "$dprobe" TASK)
      dage=$(printf '%s\n' "$dbare" | sed -n 's/.*--minimum-dependency-age=\([^ ]*\).*/\1/p')
      dvalstat=inconclusive
      [ "$dlive" = 1 ] && [ -n "$dage" ] && dvalstat=$(deno_value_status "$drb" run "$dage")
      case "$dbare" in
        "run --minimum-dependency-age="*" app.ts") dbare_ok=1 ;;
        *) dbare_ok=0 ;;
      esac
      case "$dflag" in
        "-A run --minimum-dependency-age="*" app.ts") dflag_ok=1 ;;
        *) dflag_ok=0 ;;
      esac
      case "$dsep" in
        "--log-level debug run --minimum-dependency-age="*" app.ts") dsep_ok=1 ;;
        *) dsep_ok=0 ;;
      esac
      if [ -z "$dprobe" ] || [ -z "$dbare" ]; then
        row WEAK PRESENT "deno publish-age gate" \
          "a wrapper is deployed at $dp and its target $dtarget is executable, but the dispatch probe produced no argv — the wrapper could not be exercised (noexec TMPDIR, or REAL_DENO no longer written on its own line), so what it injects is unverified"
      elif [ "$dbare_ok" = 0 ]; then
        case "$dbare" in
          *--minimum-dependency-age=*)
            row GAP FUNCTIONAL "deno publish-age gate" \
              "\`deno run app.ts\` becomes \`deno $dbare\` — the flag is not immediately after the subcommand, so deno passes it to the script instead of parsing it" ;;
          *)
            row GAP FUNCTIONAL "deno publish-age gate" \
              "the wrapper at $dp passes \`deno run app.ts\` through UNGATED (argv seen by real deno: $dbare)" ;;
        esac
      elif [ "$dflag_ok" = 0 ]; then
        row GAP FUNCTIONAL "deno publish-age gate" \
          "\`deno run app.ts\` is gated but \`deno -A run app.ts\` is NOT (argv: $dflag) — the wrapper reads the subcommand from argv[1], so any leading flag disables the gate silently; -A is the form in most Deno READMEs"
      elif [ "$dsep_ok" = 0 ] && [ "$dsepreach" = yes ]; then
        row GAP FUNCTIONAL "deno publish-age gate" \
          "\`deno --log-level debug run app.ts\` is passed through UNGATED (argv: $dsep) — the wrapper takes the first NON-FLAG argument as the subcommand, so the separate-word value of a global flag lands in the subcommand slot and the gate never fires. MEASURED reachable on this host: deno ${dver:-<unknown>} consumes \`--log-level debug\` before the subcommand exactly as it consumes any implemented flag, and differently from an invented one (help-listed=$dloglevel). Same class as 0b1954a; still open in BOTH surfaces — templates/deno-wrapper.sh.j2 and the DENOWRAP heredoc in action/harden.sh"
      elif [ "$dsep_ok" = 0 ]; then
        row WEAK FUNCTIONAL "deno publish-age gate" \
          "\`deno --log-level debug run app.ts\` is passed through UNGATED (argv: $dsep) — the wrapper takes the first NON-FLAG argument as the subcommand, so a global flag's separate-word value steals the subcommand slot. Capped at WEAK rather than GAP because this deno did not demonstrably accept \`--log-level debug\` before the subcommand (parser-discriminator=$dsepreach, help-listed=$dloglevel), so whether the bypass is reachable HERE was not established. It is still a latent hole: any pre-subcommand flag taking a separate-word value steals the subcommand slot"
      elif [ "$dfmt" != "fmt" ] || [ "$dtask" != "task build" ]; then
        row GAP FUNCTIONAL "deno publish-age gate" \
          "the wrapper injects into non-fetching subcommands (fmt -> '$dfmt', task -> '$dtask') — deno ERRORS on --minimum-dependency-age there, so this breaks \`deno task\`, the way most Deno projects invoke everything"
      elif [ "$dage" = "P0D" ] || [ "$dage" = "PT0S" ] || [ "$dage" = "P0Y" ]; then
        row GAP FUNCTIONAL "deno publish-age gate" \
          "the flag is injected correctly but the window is $dage — a zero-length age gate admits a package published one second ago. neither writer produces P0D (both floor a sub-24h release_age_hours to P1D), so this came from a manual deno_minimum_dependency_age override"
      elif [ "$dlive" = 0 ]; then
        row GAP FUNCTIONAL "deno publish-age gate" \
          "the wrapper at $dp injects --minimum-dependency-age=$dage correctly, but the binary it execs does not run: \`$dtarget --version\` exited $dvrc (${dvout:-<no output>}). Present but not runnable — every deno call on this host fails, nothing is gated because nothing executes, and the dispatch probe looks perfect only because it substitutes a stub"
      elif [ "$dstat" = rejects ] && [ "$dhelp" != 1 ]; then
        row GAP FUNCTIONAL "deno publish-age gate" \
          "the wrapper injects --minimum-dependency-age=$dage correctly, but deno ${dver:-<unknown>} answers that flag exactly as it answers one we invented, and does not list it in \`deno run --help\` — so nothing is gated AND every gated subcommand now fails outright. Upgrade deno or set deno_path_wrapper=false"
      elif [ "$dvalstat" = rejected ]; then
        row GAP FUNCTIONAL "deno publish-age gate" \
          "deno ${dver:-<unknown>} implements --minimum-dependency-age but REFUSES the value the wrapper injects: '$dage' is rejected exactly as a deliberately invalid duration is. Every gated subcommand fails and nothing is age-gated — check deno_minimum_dependency_age"
      elif [ -n "$dbadsubs" ]; then
        row GAP FUNCTIONAL "deno publish-age gate" \
          "the wrapper injects --minimum-dependency-age into subcommands whose own \`--help\` does not list it:$dbadsubs — deno errors on the flag there, so the wrapper BREAKS those commands while \`deno run\` is gated"
      elif [ "$dhelp" != 1 ] || [ "$dstat" != implements ]; then
        row WEAK FUNCTIONAL "deno publish-age gate" \
          "the wrapper injects --minimum-dependency-age=$dage after the subcommand on \`deno run\`, \`deno -A run\` and \`deno --log-level debug run\`, but this deno (${dver:-<unknown>}) could not be shown to IMPLEMENT the flag (help-listed=$dhelp, parser-discriminator=$dstat) — injection is not enforcement, so this is unverified, not covered"
      else
        row OK FUNCTIONAL "deno publish-age gate" \
          "wrapper at $dp injects --minimum-dependency-age=$dage after the subcommand on \`deno run\`, \`deno -A run\` and \`deno --log-level debug run\`, and leaves fmt/task alone; deno ${dver:-<unknown>} lists the flag in its own --help${dsubscope}, its parser distinguishes it from an invented flag, and it accepts the value $dage. NOT proof it refuses a too-new dependency — that needs a registry fetch this probe deliberately does not make. Callers invoking $dtarget directly, or bypassing PATH, are unaffected"
      fi
    fi
  fi

  # <<< the "deno age-gate flag support (precondition)" probe body goes HERE,
  # <<< inside this else, and the block is closed by the `fi` that probe carries.

# --- deno age-gate flag support (precondition)  [FUNCTIONAL] ---
  # ---- row 2: does THIS deno implement the flag at all ----------------------
  # Paste this immediately after row 1, inside the same `else` branch of
  # `if ! have deno`. It consumes dp / dwrapped / drb / dver / dvout / dvrc /
  # dlive / dhelp / dstat / dbadsubs / dsubscope, which the row-1 block computes
  # above it, and it carries the closing `fi`.
  #
  # THIS ROW IS A PRECONDITION, NOT A PROTECTION. design-principles.md ("Things
  # that are in scope but are not protections") puts version tiering in the
  # coverage-honesty bucket and says explicitly it must not be counted in the
  # capability matrix — inflating the protection count is how the role starts
  # believing its own marketing. Two consequences, both deliberate:
  #   - the label says "(precondition)" so a reader of the matrix cannot mistake
  #     a green row here for an ecosystem being covered;
  #   - on a host with NO wrapper it emits N/A, never OK. The first draft
  #     printed OK FUNCTIONAL here on a completely unhardened host — MEASURED —
  #     which is a green row for a protection that does not exist. The version
  #     information is still reported, in the N/A detail, because an operator
  #     debugging the GAP above needs it.
  #
  # This is also the version tier, done by CAPABILITY rather than by a hardcoded
  # threshold — see notes: the introduction version could not be verified
  # offline, and asserting an unverified "requires deno >= X" would be the same
  # cargo-culting Axis 5 warns about. The running version is printed in every
  # detail, so an operator gets the number without the probe betting on it.
  if [ "$dwrapped" = 0 ]; then
    row "N/A" - "deno age-gate flag support (precondition)" \
      "no wrapper deployed, so there is nothing to be a precondition for (see the gate row). Recorded for diagnosis only, not counted as coverage: deno ${dver:-<unrunnable/unknown>} help-listed=$dhelp parser-discriminator=$dstat"
  elif [ -z "$drb" ]; then
    row WEAK PRESENT "deno age-gate flag support (precondition)" \
      "could not resolve a real deno binary to interrogate (deno at $dp is a wrapper whose REAL_DENO is missing) — flag support unverified"
  elif [ "$dlive" = 0 ]; then
    row GAP FUNCTIONAL "deno age-gate flag support (precondition)" \
      "the deno at $drb exists and is executable but DOES NOT RUN: \`$drb --version\` exited $dvrc (${dvout:-<no output>}). Nothing was interrogated, so silence from the help and parser probes is absence of signal, not acceptance — and every call through the wrapper fails"
  elif [ "$dstat" = rejects ] && [ "$dhelp" = 1 ]; then
    # Contradiction guard. deno's own compiled help table defines the flag, yet
    # the parser answered it like an invented one. Both signals cannot be right;
    # refusing to call that a GAP is the cheap insurance that keeps a failing CI
    # run off a working host. (The wording-glob draft had no such guard and
    # turned a value-validation error into a GAP on a healthy deno.)
    row WEAK PARSED "deno age-gate flag support (precondition)" \
      "deno $dver LISTS --minimum-dependency-age (shown as --min-dep-age from 2.9.6) in its own \`deno run --help\` yet its parser answered the flag exactly as it answered an invented one — the two signals contradict, so neither is trusted. Not called a GAP on a build whose own argument table defines the flag"
  elif [ "$dstat" = rejects ]; then
    row GAP FUNCTIONAL "deno age-gate flag support (precondition)" \
      "deno $dver answers --minimum-dependency-age exactly as it answers a flag we invented, and does not list it in \`deno run --help\` — it does NOT implement it. The wrapper injects it anyway, so every gated subcommand (run/cache/install/test/compile/...) now FAILS. Upgrade deno or set deno_path_wrapper=false"
  elif [ "$dhelp" = 1 ] && [ "$dstat" = implements ]; then
    if [ -n "$dbadsubs" ]; then
      row WEAK FUNCTIONAL "deno age-gate flag support (precondition)" \
        "deno $dver implements --minimum-dependency-age on \`run\` (help-listed, and its parser distinguishes it from an invented flag) but its own --help does NOT list it on:$dbadsubs, which the wrapper injects into anyway — see the gate row"
    else
      row OK FUNCTIONAL "deno age-gate flag support (precondition)" \
        "deno $dver lists --minimum-dependency-age (shown as --min-dep-age from 2.9.6) in the --help${dsubscope:- of \`deno run\`}, and its parser distinguishes it from an invented flag. NOT proof the gate rejects a too-new dependency — that needs a registry fetch this probe deliberately does not make"
    fi
  elif [ "$dhelp" = 1 ]; then
    row WEAK PARSED "deno age-gate flag support (precondition)" \
      "deno $dver lists --minimum-dependency-age (shown as --min-dep-age from 2.9.6) in its own \`deno run --help\` output, but the parser discriminator was inconclusive ($dstat) — the control flag was not refused, or its refusal did not name it, so there was nothing to compare against. Capped at WEAK: help text is deno's argument table, not evidence it enforces"
  elif [ "$dstat" = implements ]; then
    row WEAK PARSED "deno age-gate flag support (precondition)" \
      "deno $dver's parser treats --minimum-dependency-age differently from an invented flag, but it is absent from \`deno run --help\` — it may be hidden/unstable, or the help layout changed. Capped at WEAK: parser acceptance without a help entry is not proof it is implemented"
  else
    row WEAK PRESENT "deno age-gate flag support (precondition)" \
      "deno $dver could not be interrogated (the help probe found nothing and the parser discriminator was inconclusive) — flag support unverified"
  fi
fi

# ======================================================================
# uv
# ======================================================================

# --- uv config in effect  [FUNCTIONAL] ---
# =================================================================== uv =======
# uv needs no npm_implements()-style trick, because uv supplies a stronger
# property itself. Both MEASURED on uv 0.10.9:
#
#   1. uv REFUSES TO START on a uv.toml it cannot fully deserialize. An unknown
#      key is fatal: `bogus-invented-key = "x"` -> exit 2, "TOML parse error ...
#      unknown field". So "the tool accepted our key and ignored it" - the pnpm
#      block-exotic-subdeps / yarn npmMinimalAgeGate failure mode - cannot
#      happen here. Any key that survives is a key THIS uv build implements,
#      which is also why no version threshold is hardcoded below.
#
#   2. `uv <cmd> --show-settings` prints the fully merged Settings struct uv is
#      about to act on, then exits before doing any work. No network, no Python
#      interpreter required (verified with env -i and no python on PATH), no
#      writes. That is the tool reporting the setting back = PARSED. We never
#      grep the uv.toml we wrote and we never name a config path: which source
#      uv chose is uv's business and we only consume its answer.
#
# Anchor keys are chosen for having a NON-default value: no_build and
# exclude_newer both default to None, so All / Some(...) can only come from a
# config uv actually read. index_strategy is NOT such a key (FirstIndex is uv's
# own default) and is capped at WEAK for exactly that reason.
#
# ATTRIBUTION IS NOT CLAIMED BY ANY ROW. uv never reports which file it loaded
# (checked: -v, -vv, RUST_LOG=trace, with and without --show-settings), so no
# row can say "our file is in effect" - only "a config uv reads sets this".

# ---- exclude-newer as uv prints it, for row 6 --------------------------------
# uv 0.13.9 (MEASURED) prints the setting as one struct with a GLOBAL cutoff and
# a PER-PACKAGE map, the map holding what exclude-newer-package sets:
#     exclude_newer: ExcludeNewer {
#         global: Some( Absolute( 2026-11-18T00:00:00Z ) ),      or
#         global: Some( Relative( ExcludeNewerSpan( 30d ) ) ),
#         package: ExcludeNewerPackage( {
#             PackageName( "boto3" ): Disabled,                   (= false)
#             PackageName( "botocore" ): Enabled( Absolute( 2099-01-01T00:00:00Z ) ),
#         } ),
#     },
# (one token per line in the real dump). A map entry decides for that package
# whatever the global says: with the global at 2026-11-18, botocore = false,
# = "2099-01-01T00:00:00Z" and = "1 second" each let botocore 1.44.7 resolve,
# the same as no gate at all, where the host config alone gave 1.44.5.
#
# scv_uv_en_block: the exclude_newer field on one line, from its own line to the
# next field at the same depth. An older one-line form (exclude_newer: None, or
# a flat Some(<ts>)) is just that line.
scv_uv_en_block() { # uv --show-settings dump on stdin
  awk '
    on { match($0, /^[[:space:]]*/); if (RLENGTH <= ind) exit; print; next }
    /^[[:space:]]*exclude_newer:/ { match($0, /^[[:space:]]*/); ind = RLENGTH; on = 1; print }
  ' | tr '\n' ' ' | tr -s ' '
}
# scv_uv_en_global / scv_uv_en_pkgs: the two halves of that block. A block with
# no `global:` (older uv) is all global, and has no map.
scv_uv_en_global() { # block
  case "$1" in
    *global:*) printf '%s' "${1#*global:}" | sed 's/package:.*//' ;;
    *)         printf '%s' "$1" ;;
  esac
}
scv_uv_en_pkgs() { # block -> one "name<TAB>value" line per map entry
  case "$1" in *package:*) ;; *) return 0 ;; esac
  printf '%s\n' "${1#*package:}" | awk '{
    n = split($0, a, /PackageName\(/)
    for (i = 2; i <= n; i++) {
      if (!match(a[i], /"[^"]*"/)) continue
      name = substr(a[i], RSTART + 1, RLENGTH - 2); v = substr(a[i], RSTART + RLENGTH)
      sub(/^[^:]*:/, "", v); print name "\t" v
    }
  }'
}
# scv_uv_span_secs: a span as uv prints it (jiff's friendly form: 1s, 90m, 30d,
# 1w 2d 3h, 1500ms) in seconds; nothing for a unit it does not know. uv refuses
# months and years in exclude-newer ("use days instead"), so every unit it can
# print is a fixed length. A negative span prints as "1d ago"; MEASURED, uv
# then resolved botocore exactly as far back as it does for "1 day" (1.44.6), so
# "ago" is read as the same span, not as a cutoff in the future.
scv_uv_span_secs() { # span
  printf '%s\n' "$1" | awk '{
    s = $0; sub(/[[:space:]]*ago[[:space:]]*$/, "", s); gsub(/[[:space:],]+/, "", s)
    if (s == "") exit 1
    tot = 0
    while (s != "") {
      if (!match(s, /^[0-9]+(\.[0-9]+)?/)) exit 1
      v = substr(s, 1, RLENGTH) + 0; s = substr(s, RLENGTH + 1)
      match(s, /^[^0-9.]+/); u = substr(s, 1, RLENGTH); s = substr(s, RLENGTH + 1)
      if (u == "w") f = 604800; else if (u == "d") f = 86400; else if (u == "h") f = 3600
      else if (u == "m") f = 60; else if (u == "s") f = 1; else if (u == "ms") f = 0.001
      else if (u == "us" || u == "\302\265s") f = 0.000001; else if (u == "ns") f = 0.000000001
      else exit 1
      tot += v * f
    }
    printf "%d\n", tot
  }'
}
# scv_uv_cutoff: one exclude-newer value -> the cutoff as epoch seconds, "off"
# when it gates nothing (Disabled, or no global at all), "?" when it cannot be
# read. A span is resolved the way uv resolves it, against now. When a value
# carries both an instant and a span (uv 0.10.x printed the resolved instant
# beside the span) the instant wins, as in rows 1-3.
scv_uv_cutoff() { # value text, now (epoch seconds)
  local t="$1" ts sp secs e
  case "$t" in *Disabled*) printf 'off'; return 0 ;; esac
  ts=$(printf '%s' "$t" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]*Z' | head -1)
  if [ -n "$ts" ]; then
    e=$(scv_epoch "$ts"); printf '%s' "${e:-?}"; return 0
  fi
  case "$t" in
    *ExcludeNewerSpan\(*)
      sp=$(printf '%s' "$t" | sed 's/.*ExcludeNewerSpan([[:space:]]*//; s/[,)].*//; s/[[:space:]]*$//')
      secs=$(scv_uv_span_secs "$sp")
      if [ -n "$secs" ]; then printf '%s' "$(( $2 - secs ))"; else printf '?'; fi
      return 0 ;;
  esac
  case "$t" in
    *None*|'') printf 'off' ;;
    *[!\ ,]*)  printf '?' ;;
    *)         printf 'off' ;;
  esac
}
# scv_uv_when: a cutoff for a row detail.
scv_uv_when() { # epoch | off | ?
  case "$1" in
    off) printf 'no cutoff' ;;
    '?') printf 'an unreadable value' ;;
    *)   date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -r "$1" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || printf '%s' "$1" ;;
  esac
}

if have uv; then
  # The CI verifier scopes rows to the ecosystems harden.sh recorded; the host
  # verifier has no such record and reports on whatever it finds. One body for
  # both: honor requested() only where it is defined.
  if command -v requested >/dev/null 2>&1 && ! requested uv; then
    row "N/A" - "uv" "uv installed but not in the requested ecosystems"
  else
    uvver=$(uv --version 2>/dev/null | head -1 | awk '{print $2}')
    [ -n "$uvver" ] || uvver="?"

    # ---- probe cwd, and why it is "/" --------------------------------------
    # MEASURED on uv 0.10.9: uv discovers config by walking the ANCESTOR
    # directories of the cwd. A `uv.toml`, or a `pyproject.toml` carrying
    # [tool.uv], in ANY ancestor answers, and it OUTRANKS the per-user config.
    # Probing from `mktemp -d` therefore does the opposite of what it looks
    # like: mktemp lands under /tmp, which is mode 1777, so any local user can
    # plant /tmp/uv.toml and answer for the host. MEASURED - with /tmp/uv.toml
    # planted and no uv config anywhere, three GAP rows became three OK rows,
    # including row 5 asserting "the /etc/uv layer is live" with no /etc/uv on
    # disk. The inverse (a bogus key in /tmp/uv.toml) forced 5 GAPs on a
    # healthy host: denial-of-verification.
    #
    # "/" has exactly one ancestor - itself - and it is root-owned 0755, so
    # forging the probe's config source now needs the root this threat model
    # already excludes. MEASURED: probing from "/", a planted /tmp/uv.toml is
    # ignored (no_build stays None). "/" is traversable by every user, needs no
    # write access, and --show-settings writes nothing.
    #
    # RESIDUAL, uncloseable from inside a verifier: uv offers no way to disable
    # ancestor discovery short of --no-config, which would also discard the
    # host config we are trying to observe. If root has placed /uv.toml or
    # /pyproject.toml[tool.uv], we cap every row at WEAK rather than attribute
    # uv's answer. That check is a read of a file this project did NOT write and
    # can only DOWNGRADE a row, never inflate one.
    uvforeign=""
    if [ -e /uv.toml ]; then
      uvforeign="/uv.toml"
    elif [ -e /pyproject.toml ] && grep -q '^[[:space:]]*\[tool\.uv' /pyproject.toml 2>/dev/null; then
      uvforeign="/pyproject.toml"
    fi

    if [ -n "$uvforeign" ]; then
      for uvpr in "uv config in effect" "uv sdist builds blocked" "uv age gate" \
                  "uv dependency-confusion gate" "uv system config (sudo/other users)"; do
        row WEAK PRESENT "$uvpr" \
          "$uvforeign sits above the probe directory and outranks the host config; uv's answer cannot be attributed"
      done
    else
      uvdump=$( (cd / && uv pip list --show-settings) 2>&1 ); uvrc=$?

      # uvmode: ok | noflag | nofields | badcfg | noconfig
      if [ "$uvrc" -eq 0 ]; then
        uvmode=ok
        case "${UV_NO_CONFIG:-}" in ''|0|false) : ;; *) uvmode=noconfig ;; esac
      elif printf '%s' "$uvdump" | grep -qi 'unexpected argument'; then
        # --show-settings not on this build. Degrade to a parse-only gate: uv
        # cache dir touches no Python and no network but still fully parses config.
        # If THAT also fails, the config is genuinely broken - and the detail must
        # quote the cache-dir error, not the "unexpected argument" complaint about
        # our own probe flag, which says nothing about the config.
        uvcd=$( (cd / && uv cache dir) 2>&1 )
        if [ $? -eq 0 ]; then uvmode=noflag; else uvmode=badcfg; uvdump="$uvcd"; fi
      else
        uvmode=badcfg
      fi
      # Guard against a future uv renaming the fields or changing the Debug
      # format: no anchor field at all must degrade to WEAK, never to a false GAP.
      if [ "$uvmode" = ok ] && ! printf '%s' "$uvdump" | grep -q 'exclude_newer:'; then
        uvmode=nofields
      fi
      uvwhy=$(printf '%s' "$uvdump" | grep -i 'failed to parse\|^error:' | head -1 | cut -c1-150)

      # ---- anchor extraction, HOISTED ABOVE ROW 1 ---------------------------
      # Row 1 needs these: "uv started" alone is not evidence that any config is
      # in effect. MEASURED - on a host with an empty HOME and no uv.toml
      # anywhere, uv exits 0 and the un-hoisted row 1 printed OK for a
      # protection named "uv config in effect" while no config was in effect.
      # That is the Axis-4 "absent signal read as a passing signal" pattern.
      uvnb=$(printf '%s\n' "$uvdump" | grep 'no_build:' | head -1 | sed 's/.*no_build:[ ]*//; s/,.*//')
      # uv 0.12 turned exclude_newer.global into an ENUM: Absolute(<ts>) or
      # Relative(ExcludeNewerSpan(<span>)). MEASURED on the real release
      # binaries: 0.10.x resolved a relative span into a concrete `timestamp:`
      # field inside this dump, and 0.12+ does NOT — so a LIVE relative gate
      # parses as absent unless the span is matched too, and the row below
      # under-reported it as GAP. The window is 11 lines, not 7, because
      # ExcludeNewerSpan( sits deeper in the pretty-printed enum than the
      # absolute timestamp did.
      uvwin=$(printf '%s\n' "$uvdump" | grep -A10 'exclude_newer:' | head -11)
      case "$uvwin" in
        *Some*) uvcut=$(printf '%s\n' "$uvwin" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]*Z' | head -1) ;;
        *)      uvcut="" ;;
      esac
      # On 0.10.x a relative span yields BOTH a timestamp and a span, so uvcut
      # still wins there and the absolute path stays correct.
      case "$uvwin" in
        *ExcludeNewerSpan\(*)
          # uv's pretty-printer puts the span VALUE on the line AFTER the
          # `ExcludeNewerSpan(` opener:
          #     ExcludeNewerSpan(
          #         48h,
          #     ),
          # so a same-line sed returns the empty string and the span row below
          # becomes unreachable (MEASURED: the first cut of this fix did exactly
          # that and still reported GAP on a live relative gate). Take the next
          # line, with a same-line fallback in case the shape ever tightens.
          uvspan=$(printf '%s\n' "$uvwin" \
                   | sed -n 's/.*ExcludeNewerSpan([[:space:]]*\([^[:space:],)][^,)]*\).*/\1/p' | head -1)
          if [ -z "$uvspan" ]; then
            uvspan=$(printf '%s\n' "$uvwin" \
                     | sed -n '/ExcludeNewerSpan(/{n;s/^[[:space:]]*//;s/[[:space:],)]*$//;p;}' | head -1)
          fi ;;
        *) uvspan="" ;;
      esac
      uvnow=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

      # ---- row 1: is a config uv reads actually in effect? -------------------
      # FUNCTIONAL: we ran uv and watched it live or die, then checked whether
      # anything it reported is off its built-in default. This is the row that
      # catches the exclude-newer = "48 hours" class - a uv.toml uv rejects
      # turns off every uv protection at once and breaks every uv command on the
      # host. uv names the offending file in its error, so the detail is
      # actionable without the verifier guessing a path.
      case "$uvmode" in
        ok)
          if [ "$uvnb" = "All" ] || [ -n "$uvcut" ]; then
            row OK FUNCTIONAL "uv config in effect" \
              "uv $uvver started and reports non-default settings, so a config uv reads is live"
          else
            row GAP FUNCTIONAL "uv config in effect" \
              "uv $uvver runs, but every anchor this verifier can read is at its built-in default - no config uv reads is setting them"
          fi ;;
        noflag) row WEAK FUNCTIONAL "uv config in effect" \
                  "uv $uvver parses its config but has no --show-settings; no value can be read back" ;;
        noconfig) row GAP FUNCTIONAL "uv config in effect" \
                  "UV_NO_CONFIG is set in this environment - uv reads NO config file at all" ;;
        nofields) row WEAK FUNCTIONAL "uv config in effect" \
                  "uv $uvver ran but its --show-settings output has none of the expected fields; the dump format changed" ;;
        badcfg) row GAP  FUNCTIONAL "uv config in effect" \
                  "uv $uvver refuses to run: ${uvwhy:-exit $uvrc}. Every uv protection is off." ;;
      esac

# --- uv sdist builds blocked  [PARSED] ---
      # ---- row 2: no-build, the setup.py admission control -------------------
      # Default is None; only a config source uv actually READ can make it All.
      # This is the load-bearing row for the threat model (install-time setup.py).
      if [ "$uvmode" = noflag ] || [ "$uvmode" = nofields ]; then
        row WEAK PRESENT "uv sdist builds blocked" \
          "uv $uvver does not report its settings back; no-build is unverifiable on this version"
      elif [ "$uvmode" = badcfg ]; then
        row GAP FUNCTIONAL "uv sdist builds blocked" \
          "uv rejects its own config, so no-build is not in effect; sdists would build"
      else
        case "$uvnb" in
          All) row OK  PARSED "uv sdist builds blocked" \
                 "uv reports no_build=All - wheels only, setup.py from an sdist cannot execute" ;;
          None|'') row GAP PARSED "uv sdist builds blocked" \
                 "uv reports no_build=${uvnb:-<absent>} - no config uv READS sets no-build; sdists execute setup.py" ;;
          *) row WEAK PARSED "uv sdist builds blocked" \
                 "uv reports no_build=$uvnb - per-package only, not a blanket sdist block" ;;
        esac
      fi

# --- uv age gate  [PARSED] ---
      # ---- row 3: exclude-newer, the age gate --------------------------------
      # Default None. Some(...) proves a config source uv READ supplied it. The
      # Some-gated window handles both the uv 0.10.x nested ExcludeNewer struct
      # and the older flat `exclude_newer: Some(<ts>)` form without hardcoding
      # either, and stops a timestamp from an unrelated later field being picked
      # up when the value is genuinely None.
      if [ "$uvmode" = noflag ] || [ "$uvmode" = nofields ]; then
        row WEAK PRESENT "uv age gate" \
          "uv $uvver does not report its settings back; exclude-newer is unverifiable on this version"
      elif [ "$uvmode" = badcfg ]; then
        row GAP FUNCTIONAL "uv age gate" \
          "uv rejects its own config, so exclude-newer is not in effect"
      elif [ -z "$uvcut" ] && [ -n "$uvspan" ]; then
        # WEAK, deliberately not OK. The verifier cannot resolve a span to an
        # instant, so it cannot tell a live 48h gate from a zero-width
        # `exclude-newer = "0 seconds"` one — MEASURED, both render identically
        # here. Reporting OK on this would be a false OK on a disabled gate.
        row WEAK PARSED "uv age gate" \
          "uv reports a RELATIVE exclude-newer span of $uvspan - a gate is set, but the verifier cannot resolve a span to an instant and so cannot confirm the window (a '0 seconds' span is indistinguishable here). The role deploys an absolute RFC 3339 instant for this reason"
      elif [ -z "$uvcut" ]; then
        row GAP PARSED "uv age gate" \
          "uv reports no exclude-newer - a release published minutes ago is installable"
      elif [ "$uvcut" \> "$uvnow" ]; then
        row GAP PARSED "uv age gate" \
          "uv reports exclude-newer=$uvcut, in the FUTURE (now $uvnow) - the gate admits everything"
      else
        # STALENESS. exclude-newer is an ABSOLUTE instant frozen at apply time
        # (ECH-193), so on a host nobody re-applies, a "48h cooldown" silently
        # becomes a months-deep FREEZE. External review 2026-10-22 reported real
        # hosts sitting at 2026-08-29 and 2026-08-25 -- eight weeks back -- and an
        # emergency certifi fix that needed a manual override because of it. The
        # row said OK throughout. That is design-principles.md Axis 4 again:
        # absent signal read as a passing signal. So age it. The role now
        # advances the instant with supply-chain-age-gate-refresh.timer on
        # systemd hosts; this row is what notices when that is not happening.
        #
        # Only uv and pip freeze: npm, pnpm, bun, deno and cargo all take a
        # RELATIVE window and refresh themselves. The threshold is 7 days rather
        # than release_age_hours because this file is shared by both surfaces and
        # does not know that variable -- 7 days is already 3.5x the default
        # window, so anything past it is unambiguously drift, not tuning.
        _scn=$(date -u +%s 2>/dev/null)
        _scc=$(scv_epoch "$uvcut")
        _scd=""
        [ -n "$_scc" ] && [ -n "$_scn" ] && _scd=$(( (_scn - _scc) / 86400 ))
        if [ -z "$_scd" ]; then
          row WEAK PARSED "uv age gate" \
            "uv reports exclude-newer cutoff $uvcut, but this host's date cannot parse it, so its age is unknown - the instant is fixed at apply time, and a months-old freeze cannot be told from a fresh 48h gate here"
        elif [ "$_scd" -gt 7 ]; then
          row WEAK PARSED "uv age gate" \
            "uv reports exclude-newer cutoff $uvcut, which is $_scd days old - that is a FREEZE, not a rolling cooldown: the instant is fixed at apply time, so every release since then is refused and a security fix cannot be installed without an override. $(scv_cutoff_fix)"
        else
          row OK PARSED "uv age gate" \
            "uv reports exclude-newer cutoff $uvcut ($_scd day(s) old) - anything published after it is refused"
        fi
      fi

# --- uv dependency-confusion gate  [PARSED] ---
      # ---- row 4: index-strategy ---------------------------------------------
      # HONEST CAP, the pnpm precedent. FirstIndex is ALSO uv's built-in default
      # (MEASURED: reported with no uv.toml anywhere), so a matching readback is
      # not evidence our config was read - it can only catch a REGRESSION to
      # unsafe-best-match. Never OK on that basis.
      uvix=$(printf '%s\n' "$uvdump" | grep 'index_strategy:' | head -1 | sed 's/.*index_strategy:[ ]*//; s/,.*//')
      if [ "$uvmode" = badcfg ]; then
        row GAP FUNCTIONAL "uv dependency-confusion gate" \
          "uv rejects its own config, so index-strategy is not in effect"
      elif [ "$uvmode" = noflag ] || [ "$uvmode" = nofields ]; then
        row WEAK PRESENT "uv dependency-confusion gate" \
          "uv $uvver does not report its settings back; index-strategy is unverifiable on this version"
      else
        case "$uvix" in
          FirstIndex) row WEAK PARSED "uv dependency-confusion gate" \
                "uv reports index_strategy=FirstIndex; correct, but it is also uv's default so this is not proof our config was read" ;;
          '')   row WEAK PARSED "uv dependency-confusion gate" \
                "uv $uvver did not report index_strategy" ;;
          *)    row GAP PARSED "uv dependency-confusion gate" \
                "uv reports index_strategy=$uvix - a secondary index can shadow a primary package name" ;;
        esac
      fi

# --- uv system config (sudo/other users)  [PARSED] ---
      # ---- row 5: /etc/uv/uv.toml, the sudo / other-user fallback ------------
      # Ask uv again with an isolated empty HOME and XDG_CONFIG_HOME /
      # UV_CONFIG_FILE / the value-supplying UV_* vars removed, so no per-user
      # file and no env var can answer. Anything non-default that still comes
      # back can only have come from the system layer. Same shape as the env -i
      # in npm_implements(): strip the source you are not testing.
      #
      # UV_NO_CONFIG and UV_NO_SYSTEM_CONFIG are deliberately NOT stripped. Both
      # are switches whose whole meaning is "this layer is off"; stripping
      # either would let the row report OK for an /etc file that uv will not
      # read in this environment. Not stripping them can only cost a false GAP,
      # and row 1 already names UV_NO_CONFIG when it is the cause. (The original
      # design stripped UV_NO_CONFIG here - that was a false-OK path.)
      #
      # The isolated HOME is a fresh mktemp -d used ONLY as $HOME, never as cwd,
      # so the world-writable-ancestor problem does not apply to it: uv looks at
      # $HOME/.config/uv/uv.toml, inside a 0700 directory we just created. cwd
      # stays "/". If mktemp fails, only this row degrades - rows 1-4 need no
      # temp directory at all.
      uvtmp=$(mktemp -d 2>/dev/null)
      if [ -z "${uvtmp:-}" ] || [ ! -d "$uvtmp" ]; then
        row WEAK PRESENT "uv system config (sudo/other users)" \
          "cannot create an isolated HOME (mktemp failed); the /etc/uv layer was not probed"
      else
        uvsysdump=$( (cd / && env -u XDG_CONFIG_HOME -u XDG_CACHE_HOME -u UV_CONFIG_FILE \
                      -u UV_EXCLUDE_NEWER -u UV_INDEX_STRATEGY \
                      HOME="$uvtmp" uv pip list --show-settings) 2>&1 ); uvsysrc=$?
        uvsnb=$(printf '%s\n' "$uvsysdump" | grep 'no_build:' | head -1 | sed 's/.*no_build:[ ]*//; s/,.*//')
        uvsyswin=$(printf '%s\n' "$uvsysdump" | grep -A6 'exclude_newer:' | head -7)
        case "$uvsyswin" in
          *Some*) uvscut=$(printf '%s\n' "$uvsyswin" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]*Z' | head -1) ;;
          *)      uvscut="" ;;
        esac
        # uv's own error names the offending file. Never guess a path here: the
        # original design asserted "/etc/uv/uv.toml is malformed" in this branch
        # having established no such thing - MEASURED, it said that when the
        # offending file was /tmp/uv.toml and /etc/uv did not exist.
        uvsyswhy=$(printf '%s' "$uvsysdump" | grep -i 'failed to parse\|^error:' | head -1 | cut -c1-150)
        if [ "$uvsysrc" -eq 0 ] && ! printf '%s' "$uvsysdump" | grep -q 'exclude_newer:'; then
          row WEAK PRESENT "uv system config (sudo/other users)" \
            "uv $uvver does not report its settings back; the system config layer cannot be read back"
        elif [ "$uvsysrc" -ne 0 ] && printf '%s' "$uvsysdump" | grep -qi 'unexpected argument'; then
          row WEAK PRESENT "uv system config (sudo/other users)" \
            "uv $uvver has no --show-settings; the system config layer cannot be read back"
        elif [ "$uvsysrc" -ne 0 ]; then
          row GAP FUNCTIONAL "uv system config (sudo/other users)" \
            "with no per-user config uv STILL refuses to run: ${uvsyswhy:-exit $uvsysrc} - that file breaks sudo uv and every other user"
        elif [ "$uvsnb" = "All" ] && [ -n "$uvscut" ]; then
          row OK PARSED "uv system config (sudo/other users)" \
            "with the per-user config removed uv still reports no_build=All and cutoff $uvscut - a system-wide layer is live"
        elif [ "$uvsnb" = "All" ] || [ -n "$uvscut" ]; then
          row WEAK PARSED "uv system config (sudo/other users)" \
            "system layer partial: no_build=${uvsnb:-<absent>}, exclude-newer=${uvscut:-<absent>}"
        else
          row GAP PARSED "uv system config (sudo/other users)" \
            "with the per-user config removed uv reports neither no-build nor exclude-newer - sudo uv and other users on this host are unprotected (needs /etc/uv/uv.toml; write_etc / become)"
        fi
        rm -rf "$uvtmp"
      fi
    fi

# --- uv repo config override  [PARSED] ---
    # ---- row 6: does a config HERE weaken what rows 1-5 saw? ----------------
    # Rows 1-5 ask uv from "/" on purpose (see "probe cwd" above), which makes
    # them blind to the override AGENTS.md tells people to look for when it
    # says to run the verifier from the project. MEASURED (uv 0.13.9, role
    # applied): in a directory whose uv.toml says no-build = false, uv reported
    # no_build: None there and `uv pip install ./x.tar.gz` ran its setup.py,
    # while row 2 printed OK; an exclude-newer in 2099 there left row 3 OK too.
    # So ask once more, from the working directory, and compare the anchors.
    # This row can only LOWER the verdict - OK when nothing here weakens rows
    # 1-5, GAP when something does, WEAK when it cannot tell - and never
    # upgrades a host row, so a uv.toml planted in a world-writable ancestor of
    # $PWD still cannot forge an OK: it can only describe, truthfully, what uv
    # does in this directory.
    uvcand=""
    uvd=$PWD
    while [ -n "$uvd" ] && [ "$uvd" != / ]; do
      if [ -f "$uvd/uv.toml" ]; then uvcand="$uvd/uv.toml"; break; fi
      if [ -f "$uvd/pyproject.toml" ] && grep -qE '^[[:space:]]*(\[tool\.uv|tool\.uv\.)' "$uvd/pyproject.toml" 2>/dev/null; then
        uvcand="$uvd/pyproject.toml"; break
      fi
      uvd=${uvd%/*}
    done
    if [ "$PWD" = / ]; then
      row "N/A" - "uv repo config override" \
        "the verifier ran from /, where rows 1-5 already asked uv - run it from a project to check that project's uv config"
    elif [ -n "$uvforeign" ] || [ "${uvmode:-}" != ok ]; then
      if [ -n "$uvcand" ]; then
        row WEAK PRESENT "uv repo config override" \
          "$uvcand may override the host config, but the host probe above could not read uv's settings, so there is nothing to compare it with"
      else
        row "N/A" - "uv repo config override" "no uv.toml or pyproject.toml uv config at or above $PWD"
      fi
    else
      uvcdump=$(uv pip list --show-settings 2>&1); uvcrc=$?
      if [ "$uvcrc" -ne 0 ]; then
        uvcwhy=$(printf '%s' "$uvcdump" | grep -i 'failed to parse\|^error:' | head -1 | cut -c1-150)
        row WEAK FUNCTIONAL "uv repo config override" \
          "uv refuses to run in $PWD (${uvcwhy:-exit $uvcrc}) - nothing installs here, but whatever config uv found here could not be compared with the host's"
      else
        uvcnb=$(printf '%s\n' "$uvcdump" | grep 'no_build:' | head -1 | sed 's/.*no_build:[ ]*//; s/,.*//')
        uvcix=$(printf '%s\n' "$uvcdump" | grep 'index_strategy:' | head -1 | sed 's/.*index_strategy:[ ]*//; s/,.*//')
        uvweak=""; uvodd=""; uvnote=""
        if [ "$uvnb" = All ] && [ "$uvcnb" != All ]; then
          uvweak="no-build: All -> ${uvcnb:-<absent>} (sdists build and run setup.py)"
        fi
        # exclude-newer: the global cutoff AND every exclude-newer-package entry,
        # each resolved to an instant (a span against now, as uv does) and set
        # against what uv reported from "/". This row used to compare the global
        # alone, so `exclude-newer-package = { botocore = false }` here printed
        # OK while botocore resolved as if there were no gate (MEASURED, see
        # scv_uv_en_block), and any span was WEAK "cannot order" - "1 second",
        # which gates nothing, as much as a stricter "30 days".
        #
        # A cutoff later than the host's is not counted as weaker while it is
        # still at least the window this surface promised (scv_want_hours): the
        # host's own instant lags behind now by up to a refresh interval, so a
        # project that pins exclude-newer = "2 days" on a 48h host resolves what
        # the host resolves (MEASURED: botocore 1.44.5 both ways) and is not a
        # weakening. Without a recorded window, any later cutoff counts.
        uvnows=$(date -u +%s)
        uvwant=""; uvwh=$(scv_want_hours)
        case "$uvwh" in ''|*[!0-9]*) ;; *) uvwant=$(( uvnows - uvwh * 3600 )) ;; esac
        uvhb=$(printf '%s\n' "$uvdump" | scv_uv_en_block)
        uvcb=$(printf '%s\n' "$uvcdump" | scv_uv_en_block)
        uvhp=$(scv_uv_en_pkgs "$uvhb"); uvcp=$(scv_uv_en_pkgs "$uvcb")
        uvhgv=$(scv_uv_en_global "$uvhb"); uvcgv=$(scv_uv_en_global "$uvcb")
        # One line per thing to compare: "<name, empty for the global>|<host
        # value>|<value here>". A package either side does not name takes that
        # side's global, which is what uv does with it. `|` and not a tab: read
        # treats a tab in IFS as whitespace and would swallow the empty name.
        uvcmp=$(
          printf '|%s|%s\n' "$uvhgv" "$uvcgv"
          printf '%s\n%s\n' "$uvhp" "$uvcp" | cut -f1 | grep -v '^$' | sort -u | while IFS= read -r uvpn; do
            uvph=$(printf '%s\n' "$uvhp" | awk -F'\t' -v n="$uvpn" '$1 == n { print $2; exit }')
            uvpc=$(printf '%s\n' "$uvcp" | awk -F'\t' -v n="$uvpn" '$1 == n { print $2; exit }')
            printf '%s|%s|%s\n' "$uvpn" "${uvph:-$uvhgv}" "${uvpc:-$uvcgv}"
          done
        )
        while IFS='|' read -r uvpn uvph uvpc; do
          [ "$uvph" = "$uvpc" ] && continue
          uvh=$(scv_uv_cutoff "$uvph" "$uvnows"); uvc=$(scv_uv_cutoff "$uvpc" "$uvnows")
          [ "$uvh" = off ] && continue
          if [ -n "$uvpn" ]; then uvwhat="exclude-newer-package $uvpn"; else uvwhat="exclude-newer"; fi
          uvsp=""
          case "$uvpc" in *ExcludeNewerSpan\(*)
            uvsp=$(printf '%s' "$uvpc" | sed 's/.*ExcludeNewerSpan([[:space:]]*//; s/[,)].*//; s/[[:space:]]*$//')
            case "$uvsp" in
              *ago) uvsp=" (span \"$uvsp\", which uv resolves like ${uvsp% ago} before now)" ;;
              *)    uvsp=" (span $uvsp before now)" ;;
            esac ;;
          esac
          if [ "$uvc" = off ]; then
            case "$uvpc" in *Disabled*) uvoff=1 ;; *) uvoff="" ;; esac
            if [ -n "$uvoff" ]; then
              uvweak="${uvweak:+$uvweak; }$uvwhat: $(scv_uv_when "$uvh") -> false ($uvpn skips the age gate entirely; a release of it published minutes ago resolves)"
            else
              uvweak="${uvweak:+$uvweak; }$uvwhat: $(scv_uv_when "$uvh") -> removed (a release published minutes ago resolves)"
            fi
          elif [ "$uvh" = '?' ] || [ "$uvc" = '?' ]; then
            uvodd="${uvodd:+$uvodd; }$uvwhat: $(printf '%s' "$uvph" | tr -s ' ') -> $(printf '%s' "$uvpc" | tr -s ' ')"
          elif [ "$uvc" -le "$uvh" ]; then
            :
          elif [ -n "$uvwant" ] && [ "$uvc" -le "$uvwant" ]; then
            uvnote="${uvnote:+$uvnote; }$uvwhat here is $(scv_uv_when "$uvc")$uvsp, later than the host's $(scv_uv_when "$uvh") but still at least the ${uvwh}h this host promised"
          else
            uvweak="${uvweak:+$uvweak; }$uvwhat: $(scv_uv_when "$uvh") -> $(scv_uv_when "$uvc")$uvsp (later, so newer releases${uvpn:+ of $uvpn} resolve)"
          fi
        done <<EOF_UVCMP
$uvcmp
EOF_UVCMP
        if [ "${uvix:-}" = FirstIndex ] && [ -n "$uvcix" ] && [ "$uvcix" != FirstIndex ]; then
          uvweak="${uvweak:+$uvweak; }index-strategy: FirstIndex -> $uvcix (a secondary index can shadow a package name)"
        fi
        if [ -n "$uvweak" ]; then
          row GAP PARSED "uv repo config override" \
            "in $PWD uv reports weaker settings than the host probe: $uvweak. A uv.toml or pyproject.toml [tool.uv] at or above this directory${uvcand:+ (nearest: $uvcand)} outranks the host config, so every uv command run here, and pip through the wrapper, uses it"
        elif [ -n "$uvodd" ]; then
          row WEAK PARSED "uv repo config override" \
            "in $PWD uv reports a setting this verifier cannot order against the host's: $uvodd${uvcand:+ (nearest uv config: $uvcand)}"
        elif [ -n "$uvcand" ]; then
          row OK PARSED "uv repo config override" \
            "in $PWD uv reports no-build, exclude-newer (global and per package) and index-strategy no weaker than the host probe${uvnote:+ ($uvnote)} - $uvcand does not weaken them"
        else
          row "N/A" - "uv repo config override" \
            "no uv.toml or pyproject.toml uv config at or above $PWD, and uv reports the same settings here as from /"
        fi
      fi
    fi
  fi
else
  row "N/A" - "uv" "uv not installed"
fi

# ======================================================================
# pip (native age gate)
# ======================================================================

# --- pip native age gate  [PARSED] ---
# A DIFFERENT AXIS from the uv rows above, and deliberately NOT nested
# inside any `have pip || have pip3` gate: the whole point of this row is the
# `python3 -m pip` caller, which invokes the MODULE directly and so bypasses
# both /usr/local/bin/pip and uv's exclude-newer. That caller exists on hosts
# with no pip BINARY at all. See docs/limitations.md.
#
# The support discriminator is the HELP TEXT and it runs BEFORE any readback,
# because `pip config list` echoes the key back on EVERY pip version -- including
# the ten pre-26 pips measured to ignore it entirely. A readback alone is a
# false-OK trap of exactly the shape npm_implements() exists to prevent.
#
# There is deliberately NO behavioural probe here. pip's age-gate refusal text
# ("Could not find a version that satisfies the requirement") is BYTE-IDENTICAL
# to a dead index, an empty mirror and PIP_NO_INDEX, so grepping it would report
# OK on a host that simply cannot reach an index. OK PARSED is the honest ceiling.
#
# Scoped like every other shared row. Without it, an action job that hardened
# only npm on a stock runner (pip 24.0) failed verify on a pip GAP it never
# asked about.
if have python3 && python3 -m pip --version >/dev/null 2>&1 \
   && command -v requested >/dev/null 2>&1 && ! requested pip; then
  row "N/A" - "pip native age gate" "python3 -m pip present but pip is not in the requested ecosystems"
elif have python3 && python3 -m pip --version >/dev/null 2>&1; then
  pipver=$(python3 -m pip --version 2>/dev/null | awk '{print $2}')
  if ! python3 -m pip install --help 2>/dev/null | grep -q -- '--uploaded-prior-to'; then
    # Toolchain, not config: no re-run of the hardening teaches pip 24 the flag.
    # As a plain row() it was counted "fixable by re-running the hardening", so
    # --fail-on=config failed every stock-runner job that hardened pip.
    scv_toolchain_gap pip.native-age-gate PARSED "pip native age gate" \
      "pip $pipver does NOT implement --uploaded-prior-to (added in pip 26.0) - the key is deployed but inert, so \`python3 -m pip install\` is not age-gated on this interpreter"
  else
    # pip prints `config list` in override-order groups, so the LAST match is
    # the effective value (env beats file). Strip optional surrounding quotes.
    pipcut=$(python3 -m pip config list 2>/dev/null \
      | sed -n "s/^.*\.uploaded-prior-to=['\"]\{0,1\}\([^'\"]*\)['\"]\{0,1\}[[:space:]]*$/\1/p" \
      | tail -1)
    case "$pipcut" in
      '')
        row GAP PARSED "pip native age gate" \
          "pip $pipver implements --uploaded-prior-to but reports no value - a release published minutes ago is installable via \`python3 -m pip\`" ;;
      P*D|P*)
        row WEAK PARSED "pip native age gate" \
          "pip $pipver reports a RELATIVE uploaded-prior-to='$pipcut' - the P<n>D form needs pip 26.1+ and is a hard error on 26.0; the role deploys an absolute instant for that reason" ;;
      *Z)
        # Same freeze as uv above, and for the same reason: pip's
        # uploaded-prior-to takes an absolute instant. The relative P<n>D form
        # would self-refresh but is pip 26.1+ and a HARD rc=2 ERROR on 26.0
        # (MEASURED), and /etc/pip.conf is read by EVERY interpreter on the
        # host -- so emitting it would brick any 26.0 interpreter present.
        _spn=$(date -u +%s 2>/dev/null)
        _spc=$(scv_epoch "$pipcut")
        _spd=""
        [ -n "$_spc" ] && [ -n "$_spn" ] && _spd=$(( (_spn - _spc) / 86400 ))
        if [ -n "$_spc" ] && [ -n "$_spn" ] && [ "$_spc" -gt "$_spn" ]; then
          # Same guard as the uv row: a cutoff in the future admits everything
          # published up to it. Compared in seconds, not days, because a cutoff
          # an hour ahead truncates to "0 days old".
          row GAP PARSED "pip native age gate" \
            "pip $pipver reports uploaded-prior-to=$pipcut, in the FUTURE - the gate admits everything published before then, which is everything so far"
        elif [ -z "$_spd" ]; then
          row WEAK PARSED "pip native age gate" \
            "pip $pipver reports uploaded-prior-to=$pipcut, but this host's date cannot parse it, so its age is unknown - the instant is fixed at apply time, and a months-old freeze cannot be told from a fresh 48h gate here"
        elif [ "$_spd" -gt 7 ]; then
          row WEAK PARSED "pip native age gate" \
            "pip $pipver reports uploaded-prior-to=$pipcut, which is $_spd days old - a FREEZE, not a rolling cooldown, so a security fix published since then cannot be installed without --uploaded-prior-to on the command line. $(scv_cutoff_fix)"
        else
          row OK PARSED "pip native age gate" \
            "pip $pipver reports uploaded-prior-to=$pipcut ($_spd day(s) old) - anything published after it is refused, pinned or not (silently open for --find-links, direct path/URL installs, and indexes without PEP 700 upload-time metadata)"
        fi ;;
      *)
        row WEAK PARSED "pip native age gate" \
          "pip $pipver reports uploaded-prior-to='$pipcut' with no trailing Z - pip reads a naive value in the HOST's LOCAL time, so the real cutoff moves with \$TZ" ;;
    esac
  fi
else
  row "N/A" - "pip native age gate" "no python3 with an importable pip module"
fi

# --- pip venv age gate  [PARSED] ---
# The row above judges python3's own pip. A venv does not inherit that: it gets the
# pip bundled in ensurepip, which can be older. MEASURED on uv-managed CPython
# 3.13.12: `python3 -m pip` is 26.0.1, `python3 -m venv` seeds 25.3, and 25.3 took
# the newest release under a cutoff 26.3 honoured. WEAK, not GAP: the host's pip is
# fine and upgrading pip inside the venv closes it, but an activated venv also
# shadows the pip wrapper, so nothing else gates it.
if have python3 && { ! command -v requested >/dev/null 2>&1 || requested pip; }; then
  pvseed=$(python3 -I -c 'import ensurepip; print(ensurepip.version())' 2>/dev/null)
  if [ -z "$pvseed" ]; then
    row "N/A" - "pip venv age gate" "this python3 has no ensurepip, so python3 -m venv cannot seed a pip here"
  elif [ "$(printf '26.0\n%s\n' "$pvseed" | sort -V | head -1)" = "26.0" ]; then
    row OK PARSED "pip venv age gate" "python3 -m venv seeds pip $pvseed, which implements uploaded-prior-to"
  else
    row WEAK PARSED "pip venv age gate" \
      "python3 -m venv seeds pip $pvseed from ensurepip, below the 26.0 that added uploaded-prior-to - a venv made that way is not age-gated until pip is upgraded inside it. uv venv --seed and uv pip are"
  fi
fi

# --- poetry publish-age gate  [PARSED] ---
# Poetry has its own resolver and reads neither pip.conf nor uv.toml, so the rows
# above say nothing about it. solver.min-release-age landed in 2.4.0 (MEASURED:
# ignored on 2.3.4, enforced on 2.4.0 and 2.5.1). Unlike npm, composer and bundler,
# poetry refuses to echo a key it does not know, and its readback includes the env
# var and a repo's poetry.toml, so from 2.4.0 this one reading is the effective value.
# Scoped to pip: the writers deploy this as part of it.
if have poetry && { ! command -v requested >/dev/null 2>&1 || requested pip; }; then
  pov=$(poetry --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  powanth=$(scv_want_hours); powant=""
  case "$powanth" in
    ''|*[!0-9]*) ;;
    *) powant=$((powanth / 24)); [ "$powant" -lt 1 ] && powant=1 ;;
  esac
  if [ -z "$pov" ]; then
    row WEAK PRESENT "poetry publish-age gate" "could not read a version from poetry; the gate was not checked"
  elif [ "$(printf '2.4.0\n%s\n' "$pov" | sort -V | head -1)" != "2.4.0" ]; then
    scv_toolchain_gap pip.poetry-age-gate PARSED "poetry publish-age gate" \
      "poetry $pov has no solver.min-release-age (added in 2.4.0), and it reads neither pip.conf nor uv.toml, so a release published minutes ago still resolves"
  else
    pod=$(poetry config solver.min-release-age 2>/dev/null | tail -1)
    pox=$(poetry config solver.min-release-age-exclude 2>/dev/null | tail -1)
    # exclude-SOURCE exempts whole package sources. MEASURED on Poetry 2.5.x with
    # a 36500-day gate: ["pypi"] (repo poetry.toml, `poetry config --local`, or
    # POETRY_SOLVER_MIN_RELEASE_AGE_EXCLUDE_SOURCE=pypi) and the PyPI simple URL
    # each installed `six` anyway, while this row printed OK because it never
    # read the key. A bare string ("pypi", not a list) had no effect, and reads
    # back without brackets.
    poxs=$(poetry config solver.min-release-age-exclude-source 2>/dev/null | tail -1)
    poxs_pypi=0; poxs_list=0
    case "$poxs" in
      \[\]|'') ;;
      \[*) poxs_list=1
            case "$(printf '%s' "$poxs" | tr '[:upper:]' '[:lower:]')" in
              *'"pypi"'*|*"'pypi'"*|*pypi.org*) poxs_pypi=1 ;;
            esac ;;
    esac
    case "$pod" in
      ''|*[!0-9]*)
        row GAP PARSED "poetry publish-age gate" "poetry $pov reports min-release-age=$(cq "${pod:-<unset>}")" ;;
      0)
        row GAP PARSED "poetry publish-age gate" \
          "poetry $pov reports min-release-age=0 in $(cq "$PWD"), which disables the gate - a repo's poetry.toml outranks the global config, though not POETRY_SOLVER_MIN_RELEASE_AGE" ;;
      *)
        if [ "$poxs_pypi" -eq 1 ]; then
          row GAP PARSED "poetry publish-age gate" \
            "poetry $pov reports ${pod}d but exempts the PyPI source in $(cq "$PWD") (min-release-age-exclude-source=$(cq "$poxs")) - every package from PyPI skips the gate. An exported empty POETRY_SOLVER_MIN_RELEASE_AGE_EXCLUDE_SOURCE= outranks a repo's list"
        elif [ "$poxs_list" -eq 1 ]; then
          row WEAK PARSED "poetry publish-age gate" \
            "poetry $pov enforces ${pod}d but exempts the source(s) $(cq "$poxs") in $(cq "$PWD")"
        elif [ -n "$pox" ] && [ "$pox" != "null" ] && [ "$pox" != "[]" ]; then
          row WEAK PARSED "poetry publish-age gate" \
            "poetry $pov enforces ${pod}d but exempts $(cq "$pox") in $(cq "$PWD") - an exported empty POETRY_SOLVER_MIN_RELEASE_AGE_EXCLUDE= outranks a repo's exclude list (measured)"
        elif [ -n "$powant" ] && [ "$pod" -lt "$powant" ]; then
          row WEAK PARSED "poetry publish-age gate" \
            "poetry $pov reports ${pod}d, below the ${powant}d this host declared - something shortened the window"
        else
          row OK PARSED "poetry publish-age gate" "poetry $pov implements min-release-age and reports ${pod}d"
        fi ;;
    esac
  fi
fi

# ======================================================================
# go (checksum database, toolchain switching)
# ======================================================================

# --- go checksum verification  [PARSED] ---
# --- go toolchain switching  [PARSED] ---
# SHARED by both surfaces. The role used to check only GOPRIVATE, so GOSUMDB=off
# and GONOSUMDB='*' both read OK, and the action did not check the checksum
# database at all. `go env` is Go's own merged answer (environment > the per-user
# `go env -w` file > $GOROOT/go.env), so these rows are PARSED. Asked from "/":
# with GOTOOLCHAIN=auto, a go.mod in the working directory that names a newer
# toolchain makes even `go env` download and run it.
#
# MEASURED on go1.24.2 and go1.27.4, fetching rsc.io/quote with a checksum
# database that refuses connections (a lookup fails the fetch, so a fetch that
# succeeds proves the lookup was skipped):
#   GOSUMDB=off             fetched, no lookup
#   GONOSUMDB='*'           fetched, no lookup
#   GOPRIVATE='*'           fetched, no lookup (GONOSUMDB defaults to GOPRIVATE,
#                           and `go env GONOSUMDB` reports that default)
#   GOINSECURE='*'          lookup made, fetch failed: NOT a sumdb bypass
#   GONOSUMDB=example.com   lookup made for rsc.io: a narrow list exempts only
#                           what it matches
# And the layer trap, same versions: after `go env -w GONOSUMDB='*'`, an EXPORTED
# EMPTY GONOSUMDB (what the role's profile.d exports) still reads back '*' and
# the lookup is still skipped. Go treats an empty variable as unset and falls
# back to its env file, so the env layer's blanks cannot clear a `go env -w`
# value. Each detail says where a value came from for exactly that reason.
#
# GOTOOLCHAIN=local for every read but GOTOOLCHAIN's own. Under an exported
# toolchain NAME go switches before it runs any subcommand, `go env` included:
# MEASURED on go1.24.2 with GOPROXY=off, GOTOOLCHAIN=go1.23.0 made
# `go env GOTOOLCHAIN GOVERSION` print "go: downloading go1.23.0" and fail, so
# with a network the verifier would have fetched and run that toolchain, and
# read its version back as "the installed" one. Forced local, go answers for
# the installed toolchain and switches to nothing. GOTOOLCHAIN itself is the
# exported value when there is one (the environment wins); otherwise go reads
# it from its env file or go.env, and then `go env` did not switch (MEASURED:
# after `go env -w GOTOOLCHAIN=go1.23.0` it printed go1.23.0, no download).
scv_go_env() {
  if [ "$1" = GOTOOLCHAIN ] && [ -n "${GOTOOLCHAIN:-}" ]; then
    printf '%s\n' "$GOTOOLCHAIN"; return 0
  fi
  if [ "$1" = GOTOOLCHAIN ]; then
    (cd / && go env "$1") 2>/dev/null | head -1 | tr -d '\r'
  else
    (cd / && GOTOOLCHAIN=local go env "$1") 2>/dev/null | head -1 | tr -d '\r'
  fi
}
scv_go_src() { # KEY -> where Go got its value, in words; empty when unknown
  local k="$1" gf gr
  if [ -n "${!k:-}" ]; then
    printf 'from the %s environment variable' "$k"; return 0
  fi
  gf=$(scv_go_env GOENV)
  if [ -n "$gf" ] && [ -f "$gf" ] && grep -q "^$k=." "$gf" 2>/dev/null; then
    if [ "${!k+set}" = set ]; then
      printf 'from %s, written by `go env -w` - the EMPTY %s exported here does not override it, because Go treats an empty variable as unset (MEASURED); `go env -u %s` removes it' "$gf" "$k" "$k"
    else
      printf 'from %s, written by `go env -w` (`go env -u %s` removes it)' "$gf" "$k"
    fi
    return 0
  fi
  gr=$(scv_go_env GOROOT)
  if [ -n "$gr" ] && grep -q "^$k=." "$gr/go.env" 2>/dev/null; then
    printf "from %s/go.env, the Go distribution's own default" "$gr"; return 0
  fi
  if [ "$k" = GONOSUMDB ] && [ -n "$(scv_go_env GOPRIVATE)" ]; then
    printf '(GONOSUMDB is unset, so Go uses GOPRIVATE='"'"'%s'"'"' %s)' "$(scv_go_env GOPRIVATE)" "$(scv_go_src GOPRIVATE)"
  fi
  return 0
}
if ! have go; then
  row "N/A" - "go checksum verification" "go not installed"
  row "N/A" - "go toolchain switching"   "go not installed"
elif command -v requested >/dev/null 2>&1 && ! requested go; then
  row "N/A" - "go checksum verification" "go installed but not in the requested ecosystems"
  row "N/A" - "go toolchain switching"   "go installed but not in the requested ecosystems"
else
  gosdb=$(scv_go_env GOSUMDB)
  # The EFFECTIVE exemption list: go env reports GONOSUMDB with its GOPRIVATE
  # default already applied (MEASURED), so GOPRIVATE needs no separate test.
  gonos=$(scv_go_env GONOSUMDB)
  if [ "$gosdb" = off ]; then
    row GAP PARSED "go checksum verification" \
      "go reports GOSUMDB=off $(scv_go_src GOSUMDB) - no module download is checked against the checksum database"
  elif [ -n "$gonos" ]; then
    # Go matches each comma-separated glob against module path PREFIXES, so a
    # '*' element covers every first path element, which is every module.
    case ",$gonos," in
      *",*,"*)
        row GAP PARSED "go checksum verification" \
          "go reports GONOSUMDB='$gonos' $(scv_go_src GONOSUMDB) - the '*' matches every module path, so EVERY module skips the checksum database" ;;
      *)
        row GAP PARSED "go checksum verification" \
          "go reports GONOSUMDB='$gonos' $(scv_go_src GONOSUMDB) - modules matching it skip the checksum database" ;;
    esac
  else
    case "$gosdb" in
      sum.golang.org|sum.golang.org+*|"sum.golang.org "*|sum.golang.google.cn|sum.golang.google.cn+*|"sum.golang.google.cn "*)
        row OK PARSED "go checksum verification" \
          "go reports GOSUMDB='$gosdb' and no GONOSUMDB/GOPRIVATE exemption - every module download is checked against the checksum database" ;;
      '')
        row WEAK PARSED "go checksum verification" "go did not report a GOSUMDB value" ;;
      *)
        row WEAK PARSED "go checksum verification" \
          "go reports GOSUMDB='$gosdb' $(scv_go_src GOSUMDB) - a checksum database other than sum.golang.org, which this verifier cannot vouch for" ;;
    esac
  fi

  # GOTOOLCHAIN (go1.21+). Unset, it comes from $GOROOT/go.env, which says `auto`
  # in the go.dev tarballs AND in Ubuntu 24.04's golang-1.22 package (both
  # MEASURED): go then downloads and runs whatever toolchain a go.mod or go.work
  # names. `local` refuses instead. `path` and `+path` switch only to a toolchain
  # already on PATH and never download.
  #
  # A plain toolchain NAME (go1.24.2, no +auto/+path) never follows go.mod
  # either. MEASURED on go1.24.2 with GOPROXY=off, in a module whose go.mod
  # says go 1.99.0: GOTOOLCHAIN=go1.24.2 printed "go.mod requires go >= 1.99.0
  # (running go 1.24.2; GOTOOLCHAIN=go1.24.2)", exactly as local does, while
  # go1.24.2+auto and auto printed "downloading go1.99.0". A name other than
  # the installed version is still a toolchain fetched at build time
  # (GOTOOLCHAIN=go1.23.0: "downloading go1.23.0" for any command), so only a
  # name equal to the installed version is OK. It used to fall through to the
  # GAP below, which said go downloads what a go.mod names.
  gotc=$(scv_go_env GOTOOLCHAIN)
  gov=$(scv_go_env GOVERSION)
  [ -n "$gov" ] || gov=$( (cd / && go version) 2>/dev/null | awk '{print $3}')
  gonum=${gov#go}
  gotcname=""
  case "$gotc" in go[0-9]*) case "$gotc" in *+*) ;; *) gotcname=$gotc ;; esac ;; esac
  if [ -n "$gonum" ] && [ "$(printf '1.21\n%s\n' "$gonum" | sort -V | head -1)" != "1.21" ]; then
    row OK PARSED "go toolchain switching" \
      "$gov predates toolchain switching (GOTOOLCHAIN, added in go1.21), so it never downloads a toolchain a go.mod asks for"
  elif [ -n "$gotcname" ] && [ "$gotcname" = "$gov" ]; then
    row OK PARSED "go toolchain switching" \
      "go reports GOTOOLCHAIN=$gotc $(scv_go_src GOTOOLCHAIN), the installed version - a plain toolchain name never follows a go.mod or go.work (only name+auto does), so one that asks for a newer toolchain is refused, not downloaded and run"
  elif [ -n "$gotcname" ]; then
    row WEAK PARSED "go toolchain switching" \
      "go reports GOTOOLCHAIN=$gotc $(scv_go_src GOTOOLCHAIN), not the installed $gov - go runs $gotc for every command, downloading it through GOPROXY when this host does not have it. A go.mod or go.work cannot choose a different toolchain (a plain name never follows them; only name+auto does), but this one is fetched at build time rather than installed"
  else
    case "$gotc" in
      local)
        row OK PARSED "go toolchain switching" \
          "go reports GOTOOLCHAIN=local - a go.mod that asks for a newer toolchain is refused, not downloaded and run" ;;
      path|*+path)
        row WEAK PARSED "go toolchain switching" \
          "go reports GOTOOLCHAIN=$gotc $(scv_go_src GOTOOLCHAIN) - go switches to a newer toolchain it finds on PATH when a go.mod asks for one; it never downloads one" ;;
      *)
        if [ -z "${GOTOOLCHAIN:-}" ] && grep -qs '^[^#]*GOTOOLCHAIN=local' /etc/environment /etc/profile.d/*.sh 2>/dev/null; then
          # Same shape as the role's GOFLAGS row: the env layer reaches only
          # PAM-launched and login shells, so THIS process may just not have it.
          # Only when nothing in this environment set it: an exported
          # GOTOOLCHAIN=auto is an override, not a missing env layer.
          row WEAK PRESENT "go toolchain switching" \
            "GOTOOLCHAIN is '${gotc:-<empty>}' in THIS process $(scv_go_src GOTOOLCHAIN), but GOTOOLCHAIN=local is in /etc/environment or /etc/profile.d - non-PAM contexts (docker exec, systemd, cron, a container CMD) do not load it, and there go downloads and runs whatever toolchain a go.mod asks for. Verify from a login shell"
        else
          row GAP PARSED "go toolchain switching" \
            "go reports GOTOOLCHAIN='${gotc:-<empty>}' $(scv_go_src GOTOOLCHAIN) - go downloads and runs the toolchain a go.mod or go.work names, a binary fetched at build time"
        fi ;;
    esac
  fi
fi

# ======================================================================
# composer
# ======================================================================

# --- composer config in effect  [PARSED] ---
# ============================================================ composer =======
#
# Does composer IMPLEMENT a key, or merely echo our file back?
#
# Exactly the npm trap. MEASURED on 2.7.1, 2.8.12, 2.9.0, 2.10.3:
#
#   $ composer config --global totally-made-up-key    # our config.json says "hello"
#   hello
#
# So a value coming back proves composer READ a file, not that composer honors
# the key. Two discriminators, both measured across composer 2.0.14 - 2.10.3:
#
#   composer_implements()  asks composer with an empty, isolated COMPOSER_HOME
#     and the environment stripped. A key composer implements has a built-in
#     default and still answers; a key it does not know exits 1 with
#     "<key> is not defined". Same trick as npm_implements().
#     LIMIT: audit.block-insecure / audit.block-abandoned have NO built-in
#     default even on 2.10.3, which DOES implement them. This discriminator
#     would report a false GAP for them, so they are version-tiered instead -
#     never run composer_implements on those two.
#
#   composer config --list --source     (composer >= 2.2)
#     prints, per key, the value AND the file it came from:
#       [secure-http] true (/home/u/.config/composer/config.json)
#       [home] /home/u/.config/composer (default)
#     This is the only thing in this ecosystem that separates "our file is in
#     effect" from "composer is reporting its own built-in default" - and that
#     distinction is the whole ballgame here, because secure-http, lock and
#     preferred-install=dist ARE composer's defaults. Reading them back proves
#     nothing on its own; reading them back WITH our path as the source does.
#
# Composer resolves its home as COMPOSER_HOME -> $XDG_CONFIG_HOME/composer ->
# ~/.config/composer, and uses a legacy ~/.composer when only that one exists
# (MEASURED on 2.2.6 and 2.10.3). harden.sh hardcodes $HOME/.config/composer,
# so the file can land somewhere composer never reads. Never stat that path as
# evidence - ask composer where it reads from and compare.
#
# It runs from an empty directory with --no-plugins. MEASURED on composer 2.11.2
# before that: `composer config --global <key>` run inside a checkout loaded the
# checkout's composer.json, activated the plugin its allow-plugins enables
# (committed to vendor/) and ran its root "pre-command-run" script, once per key.
# --global does not stop composer from booting the project it is standing in.
composer_implements() {
  ci_key="$1"; ci_tmp=$(mktemp -d 2>/dev/null) || return 1
  [ -n "$ci_tmp" ] && [ -d "$ci_tmp" ] || return 1
  mkdir -p "$ci_tmp/h" "$ci_tmp/ch" "$ci_tmp/cwd"
  ( cd "$ci_tmp/cwd" && env -i PATH="$PATH" HOME="$ci_tmp/h" COMPOSER_HOME="$ci_tmp/ch" \
      COMPOSER_CACHE_DIR="$ci_tmp/c" COMPOSER_DATA_DIR="$ci_tmp/d" \
      COMPOSER_ALLOW_SUPERUSER=1 COMPOSER_NO_INTERACTION=1 \
      composer config --global --no-plugins --no-ansi "$ci_key" ) >/dev/null 2>&1
  ci_rc=$?
  rm -rf "$ci_tmp"
  [ "$ci_rc" -eq 0 ]
}
# value ($1=dump $2=key) and source file of one key in a --list --source dump
composer_val() { printf '%s\n' "$1" | sed -n "s|^\[$2\] \(.*\) (\(.*\))\$|\1|p" | head -1; }
composer_src() { printf '%s\n' "$1" | sed -n "s|^\[$2\] \(.*\) (\(.*\))\$|\2|p" | head -1; }
# every plugin a dump marks as allowed, space separated
composer_allowed_plugins() { printf '%s\n' "$1" | sed -n 's|^\[allow-plugins\.\([^]]*\)\] true .*$|\1|p' | tr '\n' ' ' | sed 's/ *$//'; }
# Is composer's policy layer (cooldown, advisory and malware blocking) switched
# off? Prints the reason and succeeds if so. $1 = effective --list dump.
#   [policy] false (./composer.json)  a checkout's "config":{"policy":false}.
#     MEASURED on 2.11.2: it turns off the cooldown AND advisory blocking (a
#     phpmailer 5.2.21 with a known advisory installed) and beats the exported
#     COMPOSER_POLICY_COOLDOWN_PERIOD, while every composer row printed OK.
#     An exported COMPOSER_POLICY=1 beats it again (measured: refused).
#   COMPOSER_POLICY=0, COMPOSER_NO_BLOCKING, COMPOSER_NO_SECURITY_BLOCKING:
#     the env forms. In 2.11.2 source either NO_* variable sets the same
#     $noBlocking switch (src/Composer/Command/BaseCommand.php:485-486).
composer_bool_env() { # <value>: 0 true, 1 false, 2 unset/unknown
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on) return 0 ;;
    0|false|no|off) return 1 ;;
    *) return 2 ;;
  esac
}
composer_policy_off() {
  _cpe=0; composer_bool_env "${COMPOSER_POLICY:-}" || _cpe=$?
  if [ "$_cpe" -eq 1 ]; then
    printf 'COMPOSER_POLICY=%s is exported' "$(cq "$COMPOSER_POLICY")"; return 0
  fi
  for _cpv in COMPOSER_NO_BLOCKING COMPOSER_NO_SECURITY_BLOCKING; do
    if composer_bool_env "$(printenv "$_cpv" 2>/dev/null)"; then
      printf '%s is exported (it turns composer'"'"'s blocking off)' "$_cpv"; return 0
    fi
  done
  if [ "$(composer_val "$1" policy)" = "false" ] && [ "$_cpe" -ne 0 ]; then
    printf '%s sets "policy": false (from %s), which turns off the cooldown and advisory/malware blocking and outranks COMPOSER_POLICY_COOLDOWN_*; only an exported COMPOSER_POLICY=1 beats it' \
      "$escope" "$(cq "$(composer_src "$1" policy)")"
    return 0
  fi
  return 1
}
# Every cooldown ignore rule that exempts a package from BLOCKING, one per line
# as "<pattern> <c>", <c> = 1 when a version constraint narrows it to some
# versions. $1 is the JSON `composer config policy.cooldown.ignore` prints.
# --list is not enough: it flattens a rule with no fields to no line at all, so
# {"*": {}}, {"*/*": {}} and {"*": []} listed nothing while they exempt every
# package (MEASURED on 2.11.2 with the role applied: `composer require
# aws/aws-sdk-php --dry-run` was offered a release the baseline withholds as
# "still in the cooldown period", and both rows read OK). The shapes follow
# composer's own parser (Composer\Policy\IgnorePackageRule::parseIgnoreMap,
# 2.11.2): a list of names; or a map of name to null, a reason string, a rule
# object or a list of rule objects, where a missing field means every version
# and "on-block": true. A rule with "on-block": false only affects the audit
# report: MEASURED, {"*": {"on-block": false}} still withheld that release. A
# constraint of "*" is every version: MEASURED, {"*": {"constraint": "*"}} let
# it through (it read WEAK, "for the versions its constraint names").
# Returns 2, printing nothing, when $1 cannot be read (no php, or not JSON);
# php is what runs composer itself, and it only decodes the string here.
composer_ignore_rules() {
  command -v php >/dev/null 2>&1 || return 2
  printf '%s' "$1" | php -r '
    $s = trim((string) stream_get_contents(STDIN));
    if ($s === "null") exit(0);
    $j = json_decode($s, true);
    if (!is_array($j)) exit(2);
    $out = function ($p, $c) { echo strtr((string) $p, " \t\r\n", "____"), " ", $c, "\n"; };
    $rule = function ($p, $r) use ($out) {
      if (array_key_exists("on-block", $r) && $r["on-block"] === false) return;
      $out($p, (isset($r["constraint"]) && trim((string) $r["constraint"]) !== "*") ? 1 : 0);
    };
    foreach ($j as $k => $v) {
      if ($v === null || (is_string($v) && !is_int($k))) { $out($k, 0); continue; }
      if (is_int($k) && is_string($v)) { $out($v, 0); continue; }
      if (is_array($v) && !is_int($k) && isset($v[0])) {
        foreach ($v as $r) { if (is_array($r)) $rule($k, $r); }
        continue;
      }
      if (is_array($v) && !is_int($k)) $rule($k, $v);
    }' 2>/dev/null
}
# The same lines from whichever reading works: the single-key JSON ($1 = its exit
# status, $2 = its output) when composer answered and php could decode it, else
# the --list dump $3 (composer without that key, or no php).
composer_ignore_lines() {
  if [ "$1" -eq 0 ] && _cil=$(composer_ignore_rules "$2"); then
    [ -z "$_cil" ] || printf '%s\n' "$_cil"
    return 0
  fi
  composer_ignore_entries "$3"
}
# Every cooldown ignore entry in a --list dump, one per line as "<pattern> <c>",
# <c> = 1 when the entry carries a version constraint (it then exempts only the
# versions that match it). The list form prints one line,
#   [policy.cooldown.ignore] [*/*, acme/*] (./composer.json)
# and the map form prints one line per key, and per field of a rule object:
#   [policy.cooldown.ignore.psr/log] trusted (./composer.json)
#   [policy.cooldown.ignore.*.constraint] <1.0 (./composer.json)
#   [policy.cooldown.ignore.*.0.reason] x (./composer.json)   (a list of rules)
# (MEASURED on 2.11.2.)
composer_ignore_entries() {
  printf '%s\n' "$1" | sed -n 's|^\[policy\.cooldown\.ignore\] \[\(.*\)\] (.*)$|\1|p' \
    | tr ',' '\n' | sed 's/^ *//; s/ *$//; /^$/d; s/$/ 0/'
  printf '%s\n' "$1" | sed -n 's|^\[policy\.cooldown\.ignore\.\([^]]*\)\] .*$|\1|p' \
    | awk '{ n = $0; c = 0
             if (match(n, /(\.[0-9]+)?\.(reason|constraint|on-block|on-audit)$/)) {
               if (substr(n, RSTART) ~ /constraint$/) c = 1
               n = substr(n, 1, RSTART - 1)
             }
             if (!(n in seen)) order[++k] = n
             if (c || !(n in seen)) seen[n] = c }
           END { for (i = 1; i <= k; i++) print order[i], seen[order[i]] }'
}
# Does a cooldown ignore pattern exempt EVERY package? Composer turns the pattern
# into a regex in which only * is a wildcard, anchored and case-insensitive
# (BasePackage::packageNameToRegexp). Every package is vendor/name, and "a/b" and
# "x/y" share no character but the slash, so a pattern that matches both can
# only be made of * and that one slash: it matches every name. A literal "*"
# test missed "*/*" (MEASURED on 2.11.2: ["*/*"] read WEAK while `composer
# require` resolved a release inside the window).
composer_ignore_all() {
  _cia=$(printf '%s' "$1" | sed 's/[][?\\]/\\&/g')
  # shellcheck disable=SC2254  # the pattern is meant to glob; only * is left special
  case a/b in $_cia) ;; *) return 1 ;; esac
  # shellcheck disable=SC2254
  case x/y in $_cia) return 0 ;; esac
  return 1
}
# PRINTF-FORMAT SAFETY. verify.sh's render() does `printf "$ROWS"` (line 420),
# so ROWS is a FORMAT string: a bare % in any interpolated path silently
# rewrites the row (MEASURED: a job in `/tmp/build 100%s/x` reported
# `/tmp/build 100/x` - a verifier altering the path it reports).
#
# RESOLVED 2026-08-28: both surfaces now render with `printf '%b' "$ROWS"`,
# which passes % through untouched, so escaping here would double it. cq() is
# kept as a PASS-THROUGH rather than deleted so its 24 call sites stay valid
# and the intent stays greppable. If a renderer is ever reverted to using
# $ROWS as a format string, restore the sed and revert BOTH renderers with it.
# (cq() itself is defined at the top of this file, before the poetry rows use it.)
# first useful line of a composer failure. The first line of composer's output
# is often NOT the cause: MEASURED, a wrapper injecting a bogus flag leads with
# "Composer could not detect the root package (a/b) version, defaulting to
# '1.0.0'" and 2.0.14 leads with a symfony/console PHP Deprecated notice, both
# of which send the reader after the wrong bug. Drop the known-noise lines.
composer_err() {
  printf '%s\n' "$1" | grep -v '^[[:space:]]*$' | grep -v 'Exception\]' \
    | grep -v '^In .* line [0-9]*:' | grep -vi 'deprecated:' \
    | grep -v 'could not detect the root package' \
    | head -1 | cut -c1-90 | tr -d '%\\'
}

# config.policy.cooldown.period -> seconds; empty when it cannot be read. Composer
# takes an integer of seconds or "<n> <unit>", units singular or plural, any case.
composer_period_seconds() {
  case "$1" in ''|*[!0-9]*) ;; *) printf '%s' "$1"; return 0 ;; esac
  _cpl=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
  _cpn=$(printf '%s' "$_cpl" | sed -nE 's/^ *([0-9]+) *(second|minute|hour|day|week)s? *$/\1/p')
  _cpu=$(printf '%s' "$_cpl" | sed -nE 's/^ *([0-9]+) *(second|minute|hour|day|week)s? *$/\2/p')
  [ -n "$_cpn" ] || return 0
  case "$_cpu" in
    second) printf '%s' "$_cpn" ;;
    minute) printf '%s' "$((_cpn * 60))" ;;
    hour)   printf '%s' "$((_cpn * 3600))" ;;
    day)    printf '%s' "$((_cpn * 86400))" ;;
    week)   printf '%s' "$((_cpn * 604800))" ;;
  esac
}

if have composer; then
  if ! requested composer; then
    row "N/A" - "composer" "composer installed but not in the requested ecosystems"
  else
  # Composer 2.2.x prints "Composer version 2.2.6 <date>" and some builds print
  # "Composer 2.2.6 <date>". Requiring the word "version" silently failed to
  # parse exactly the OLDEST composer - the one with the largest gap - and
  # reported "could not parse" where the answer should have been "no audit
  # blocking at all". Keep the optional group. (from templates/verify.sh.j2:274)
  #
  # EVERY composer probe in this section runs with COMPOSER_ALLOW_SUPERUSER=1 and
  # --no-interaction. A root run on a terminal (`sudo supply-chain-verify`) of a
  # composer that is not our wrapper (the wrapper sets the variable itself)
  # otherwise stops at composer's "Continue as root/super user [yes]?" prompt,
  # written to stderr, which these probes discard: MEASURED on 2.2.6 with the
  # wrapper reverted, the verifier was still waiting when a 45 s timeout killed
  # it, both under `su - root` and under sudo. -n alone answers that prompt but
  # still makes composer run `sudo -K` against the invoking user's sudo
  # timestamp. The variable only lifts composer's root guard; plugins stay off
  # because every probe also passes --no-plugins.
  #
  # The version probe gives composer no project: COMPOSER names a file that
  # cannot exist (/dev/null is not a directory). Reading a version needs none,
  # and a posture probe must never boot the checkout it is standing in. Unlike
  # changing to an empty directory, it keeps the caller's working directory, so a
  # relative PATH entry still resolves the composer the caller would get.
  cv=$(COMPOSER=/dev/null/composer.json COMPOSER_ALLOW_SUPERUSER=1 \
        composer --version --no-ansi --no-plugins --no-interaction 2>/dev/null \
        | sed -nE 's/.*[Cc]omposer( version)? ([0-9]+\.[0-9]+\.[0-9]+).*/\2/p' | head -1)
  cmaj=${cv%%.*}; crest=${cv#*.}; cmin=${crest%%.*}; cpat=${cv##*.}
  case "$cmaj$cmin" in *[!0-9]*|'') cmaj=""; cmin="" ;; esac

  # ---- 1. is OUR config the config composer is reading? --------------------
  # cwrote is where harden.sh writes (action/harden.sh:644). It is NOT
  # authoritative - composer resolves its own home - but the verifier has to
  # know the writer's path in order to report the two disagreeing.
  cwrote="$HOME/.config/composer/config.json"
  # The --global reads run from an empty directory: from inside a checkout,
  # composer boots that project even for --global and dispatches pre-command-run
  # to its root scripts (MEASURED, 2.2.6 -> 2.11.2, whenever COMPOSER_SKIP_SCRIPTS
  # is not honoured: composer < 2.8.6, or no PAM env). -n stops the parent-dir walk.
  cnone=$(mktemp -d 2>/dev/null) || cnone=/
  CDUMP=$(cd "$cnone" && COMPOSER_ALLOW_SUPERUSER=1 composer config --global --list --source --no-ansi --no-plugins --no-interaction 2>&1); crc=$?
  clist=1
  if [ "$crc" -ne 0 ]; then
    (cd "$cnone" && COMPOSER_ALLOW_SUPERUSER=1 composer config --global --list --no-ansi --no-plugins --no-interaction) >/dev/null 2>&1 && clist=0
  fi
  # The cooldown ignore list as JSON (see composer_ignore_rules): exits 1 when the
  # key is not set.
  CGIGN=$(cd "$cnone" && COMPOSER_ALLOW_SUPERUSER=1 composer config --global policy.cooldown.ignore --no-ansi --no-plugins --no-interaction 2>/dev/null); cgirc=$?
  CGIGN=$(printf '%s\n' "$CGIGN" | sed '/^[[:space:]]*$/d' | tail -1)
  [ "$cnone" = / ] || rmdir "$cnone" 2>/dev/null
  if [ "$crc" -ne 0 ] && [ "$clist" -eq 0 ]; then
    # --list works, --list --source does not: composer < 2.2 has no --source.
    row WEAK PARSED "composer config in effect" \
      "composer ${cv:-?} has no 'config --list --source' (needs >= 2.2); it reports values but not which file they came from, so nothing here proves our file is the one being read"
  elif [ "$crc" -ne 0 ]; then
    hint=""
    if [ -n "$cmaj" ] && [ "$cmaj" -eq 2 ] && [ "$cmin" -eq 2 ] && [ "${cpat:-99}" -lt 15 ] 2>/dev/null; then
      hint=' — composer < 2.2.15 dies with a PHP TypeError on "allow-plugins": false in any config file it reads (this hardening writes {} for that reason)'
    fi
    row GAP FUNCTIONAL "composer config in effect" \
      "composer ${cv:-?} exits $crc on 'composer config --global --list': $(composer_err "$CDUMP") — every composer command here is broken$hint"
  else
    csrc=$(composer_src "$CDUMP" secure-http)
    chome=$(composer_val "$CDUMP" home)
    case "$csrc" in
      '')
        row WEAK PARSED "composer config in effect" \
          "composer ${cv:-?} accepted --source but reported no source for secure-http; cannot prove which file is in effect" ;;
      default)
        row GAP PARSED "composer config in effect" \
          "composer resolved its home to $(cq "${chome:-?}") and reports every value as a built-in default — the config we wrote at $(cq "$cwrote") is never read" ;;
      "$cwrote")
        row OK PARSED "composer config in effect" \
          "composer reports $(cq "$csrc") as the source of its config (home $(cq "${chome:-?}"))" ;;
      *)
        # Both writers also deploy to the home composer really reads, so identical
        # bytes there are ours. Anything else is a file we did not write.
        if [ -f "$csrc" ] && cmp -s "$cwrote" "$csrc" 2>/dev/null; then
          row OK PARSED "composer config in effect" \
            "composer reports $(cq "$csrc") as the source of its config, identical to what we wrote"
        else
          row GAP PARSED "composer config in effect" \
            "composer reads $(cq "$csrc") but this action wrote $(cq "$cwrote") (composer home $(cq "${chome:-?}")) — COMPOSER_HOME, XDG_CONFIG_HOME and a legacy ~/.composer all move it; our hardening is not the config in effect"
        fi ;;
    esac
  fi

  # ---- 1b. the EFFECTIVE config for THIS working directory -----------------
  # MEASURED (2.2.6, 2.7.1, 2.8.12, 2.10.3): composer merges the "config"
  # object of the composer.json in the working directory OVER the global
  # config. Every row below therefore has to read the EFFECTIVE dump, not the
  # --global one. A checkout carrying
  #     "config": {"audit": {"block-insecure": false, "block-abandoned": false}}
  # leaves the global dump untouched, so global-only rows report OK while
  # composer will not block a single advisory for this repo - MEASURED, the
  # whole block printed GAPS=0 on exactly that checkout before this fix.
  # `config --list` without --global needs a composer.json in the working
  # directory (MEASURED: exits non-zero without one), so fall back to the
  # global dump when there is none.
  EDUMP="$CDUMP"; escope="global config"; prc=0; phas=0; PDUMP=""
  if [ -f composer.json ]; then
    phas=1
    # --no-plugins is REQUIRED here, not cosmetic: this reads the EFFECTIVE
    # config of an untrusted checkout, and `composer config` activates any
    # plugin the merged allow-plugins permits (plugin activate() = arbitrary
    # PHP) unless --no-plugins is passed. A posture check must never run a
    # checkout's code. MEASURED (composer 2.11.1): without this flag a committed
    # vendor/ plugin runs; with it the identical config is reported and nothing
    # runs. --no-plugins is a global option on every composer 2.x. --no-scripts
    # is needed too: without it the checkout's root "pre-command-run" script runs
    # (MEASURED, 2.2.6 -> 2.11.2, outside the reach of COMPOSER_SKIP_SCRIPTS).
    # `composer config` rejects --no-scripts on 2.0/2.1, but those have no
    # --source either, so this call fails there with or without it. See
    # tests/bats/51-verifier-composer-plugin-safety.bats.
    PDUMP=$(COMPOSER_ALLOW_SUPERUSER=1 composer config --list --source --no-ansi --no-plugins --no-scripts --no-interaction 2>/dev/null); prc=$?
    if [ "$prc" -eq 0 ]; then EDUMP="$PDUMP"; escope="effective config for $(cq "$PWD")"; fi
  fi
  # The cooldown ignore list in effect here, as JSON: the checkout's when it can be
  # read, else the global one.
  CIGN="$CGIGN"; cignrc=$cgirc
  if [ "$phas" -eq 1 ] && [ "$prc" -eq 0 ]; then
    CIGN=$(COMPOSER_ALLOW_SUPERUSER=1 composer config policy.cooldown.ignore --no-ansi --no-plugins --no-scripts --no-interaction 2>/dev/null); cignrc=$?
    CIGN=$(printf '%s\n' "$CIGN" | sed '/^[[:space:]]*$/d' | tail -1)
  fi
  # A checkout we could not read is a checkout that may be overriding us; that
  # caps the two config rows below at WEAK instead of OK.
  eqal=""; estat=OK
  if [ "$phas" -eq 1 ] && [ "$prc" -ne 0 ]; then
    eqal=" — NOTE: the composer.json in $(cq "$PWD") could not be read, so this is the global config only and the checkout may override it"
    estat=WEAK
  fi

# --- composer plugin execution blocked  [PARSED] ---
  # ---- 2. plugins ----------------------------------------------------------
  # secure-http has a built-in default in every composer 2.x, so a composer
  # that cannot answer for THAT is a composer that cannot answer at all - a
  # broken wrapper, a missing -real target, an unusable phar. Without this
  # first branch that failure reads as "allow-plugins is not implemented",
  # which sends the reader after the wrong bug.
  if ! composer_implements secure-http; then
    row GAP FUNCTIONAL "composer plugin execution blocked" \
      "composer ${cv:-?} cannot answer 'composer config <key>' at all (see the composer config in effect row) — allow-plugins is unverifiable"
  elif ! composer_implements allow-plugins; then
    row GAP FUNCTIONAL "composer plugin execution blocked" \
      "composer ${cv:-?} does not implement allow-plugins (added in 2.2.0); plugins declared by a checkout execute"
  elif [ "$crc" -ne 0 ]; then
    row GAP PARSED "composer plugin execution blocked" \
      "composer cannot report its config (see the composer config in effect row), so allow-plugins is unverifiable"
  else
    # What the writers put there is the EMPTY allowlist, "allow-plugins": {},
    # never `false` (a hard fatal below 2.2.15, see the config row). Composer
    # flattens an empty map to no line at all, and {} is also its built-in
    # default (MEASURED on 2.2.6, 2.7.1, 2.11.2: no [allow-plugins] line for {};
    # `[allow-plugins] false` for false), so "no line and no allowed plugin" IS
    # the hardened state. It used to read WEAK on every host, blaming a
    # `false` nothing writes. Under {} an unlisted plugin is refused with an
    # error in a non-interactive run, and prompted for in an interactive one.
    ap=$(composer_val "$EDUMP" allow-plugins)
    case "$ap" in
      false) row "$estat" PARSED "composer plugin execution blocked" \
               "composer's $escope reports allow-plugins=false from $(cq "$(composer_src "$EDUMP" allow-plugins)"), which refuses every plugin$eqal" ;;
      true)  row GAP PARSED "composer plugin execution blocked" \
               "composer's $escope reports allow-plugins=true from $(cq "$(composer_src "$EDUMP" allow-plugins)") — every plugin a checkout declares runs" ;;
      '')
        allowed=$(composer_allowed_plugins "$EDUMP")
        if [ -n "$allowed" ]; then
          row GAP PARSED "composer plugin execution blocked" \
            "composer's $escope allows these plugins: $(cq "$allowed") — they run whenever composer does, unless --no-plugins is passed"
        else
          row "$estat" PARSED "composer plugin execution blocked" \
            "composer's $escope allows no plugin: allow-plugins is the empty allowlist {} (what this hardening writes, and composer's default), so an unlisted plugin is refused in a non-interactive run and prompted for in an interactive one$eqal"
        fi ;;
      *) row GAP PARSED "composer plugin execution blocked" "composer's $escope reports allow-plugins=$(cq "$ap")" ;;
    esac
  fi

# --- composer audit blocking  [PARSED] ---
  # ---- 3. audit blocking (version-tiered) ----------------------------------
  # audit.block-insecure / block-abandoned landed in composer 2.9.0 (MEASURED:
  # absent from the 2.8.12 phar, present in 2.9.0) and have NO built-in
  # default, so composer_implements() cannot see them - the VERSION IS THE
  # ONLY CAPABILITY EVIDENCE in this row. The readback is NOT a second
  # signal: MEASURED on 2.7.1, 2.8.12 and 2.10.3, composer echoes ANY audit
  # subkey verbatim with our file named as the source, including an invented
  # `audit.block-totally-fake`. Do not drop the version tier on the strength
  # of the readback looking good - that is the pnpm situation exactly.
  # audit.abandoned alone (2.7-2.8) only annotates; it does not refuse.
  # Evidence is PARSED, never FUNCTIONAL: nothing here runs an audit, and the
  # version-tier branches are a readback of `composer --version`. The role's
  # row (templates/verify.sh.j2:268-291) calls that FUNCTIONAL, which is the
  # evidence-class drift this file exists to catch.
  if [ -z "$cmaj" ] || [ -z "$cmin" ]; then
    row WEAK PRESENT "composer audit blocking" "could not parse a version out of 'composer --version'"
  elif [ "$cmaj" -lt 2 ] || { [ "$cmaj" -eq 2 ] && [ "$cmin" -lt 7 ]; }; then
    scv_toolchain_gap composer.audit-blocking PARSED "composer audit blocking" \
      "composer $cv is below 2.7 — no audit blocking of any kind is available"
  elif [ "$cmaj" -eq 2 ] && [ "$cmin" -lt 9 ]; then
    scv_toolchain_gap composer.audit-blocking PARSED "composer audit blocking" \
      "composer $cv supports audit.abandoned but NOT block-insecure/block-abandoned (needs >= 2.9); advisories do not refuse installs"
  elif [ "$crc" -ne 0 ]; then
    row GAP PARSED "composer audit blocking" \
      "composer $cv supports audit blocking but cannot report its config (see the composer config in effect row)"
  else
    bi=$(composer_val "$EDUMP" audit.block-insecure); ba=$(composer_val "$EDUMP" audit.block-abandoned)
    if cpoff=$(composer_policy_off "$EDUMP"); then
      row GAP PARSED "composer audit blocking" \
        "composer $cv: $cpoff - packages with known advisories install"
    elif [ "$bi" = "true" ] && [ "$ba" = "true" ]; then
      row "$estat" PARSED "composer audit blocking" \
        "composer $cv: $escope reports audit.block-insecure=true and block-abandoned=true from $(cq "$(composer_src "$EDUMP" audit.block-insecure)") — note this readback is an ECHO (composer prints ANY audit subkey verbatim with our file as the source, MEASURED on 2.7.1/2.8.12/2.10.3); the >= 2.9.0 version tier is what makes this a capability claim$eqal"
    else
      row GAP PARSED "composer audit blocking" \
        "composer $cv supports audit blocking but $escope reports block-insecure=$(cq "${bi:-<unset>}") block-abandoned=$(cq "${ba:-<unset>}")"
    fi
  fi

# --- composer publish-age gate  [PARSED] ---
  # config.policy.cooldown landed in 2.11.0. The version check has to come first:
  # MEASURED, `composer config --list` echoes the key on 2.7.1, which ignores it,
  # so a value coming back proves nothing. Composer's readback also does NOT show
  # COMPOSER_POLICY_COOLDOWN_PERIOD, which outranks every file, so that is read
  # from the environment here. PARSED is the ceiling: the gate only fires against
  # a registry, and a read-only verifier must not exercise one.
  cwanth=$(scv_want_hours); cwantsec=""
  case "$cwanth" in ''|*[!0-9]*) ;; *) cwantsec=$((cwanth * 3600)) ;; esac
  if [ -z "$cmaj" ] || [ -z "$cmin" ]; then
    row WEAK PRESENT "composer publish-age gate" "could not parse a version out of 'composer --version'"
  elif [ "$cmaj" -lt 2 ] || { [ "$cmaj" -eq 2 ] && [ "$cmin" -lt 11 ]; }; then
    scv_toolchain_gap composer.age-gate PARSED "composer publish-age gate" \
      "composer $cv does NOT implement config.policy.cooldown (added in 2.11.0) - the key is written and ignored, and composer echoes it back anyway, so a release published minutes ago still resolves. See $(scv_doc docs/composer-bundler-cooldown-by-distro.md)"
  elif [ "$crc" -ne 0 ]; then
    row GAP PARSED "composer publish-age gate" \
      "composer $cv implements the cooldown but cannot report its config (see the composer config in effect row)"
  else
    cper=$(composer_val "$EDUMP" policy.cooldown.period)
    cblk=$(composer_val "$EDUMP" policy.cooldown.block)
    cpsrc=$(composer_src "$EDUMP" policy.cooldown.period)
    if [ -n "${COMPOSER_POLICY_COOLDOWN_PERIOD:-}" ]; then
      cper=$COMPOSER_POLICY_COOLDOWN_PERIOD; cpsrc="COMPOSER_POLICY_COOLDOWN_PERIOD"
    fi
    case "${COMPOSER_POLICY_COOLDOWN_BLOCK:-}" in
      '') ;;
      0|false|no|off) cblk=false ;;
      *) cblk=true ;;
    esac
    csec=$(composer_period_seconds "$cper")
    cisrc=$(composer_src "$EDUMP" policy.cooldown.ignore)
    [ -n "$cisrc" ] || cisrc=$(printf '%s\n' "$EDUMP" | sed -n 's|^\[policy\.cooldown\.ignore\.[^]]*\] .* (\(.*\))$|\1|p' | head -1)
    # A rule with no fields has no --list line, so no source either.
    if [ -z "$cisrc" ]; then
      if [ "$escope" = "global config" ]; then cisrc="the global config"; else cisrc="./composer.json"; fi
    fi
    # cign: every pattern, for the text. cignall: one of them exempts every
    # package at every version. cignpart: matches every package but only the
    # versions its constraint names.
    cign=""; cignall=0; cignpart=""
    while read -r _cip _cic; do
      [ -n "$_cip" ] || continue
      cign="${cign:+$cign, }$_cip"
      if composer_ignore_all "$_cip"; then
        if [ "$_cic" = 1 ]; then cignpart="${cignpart:+$cignpart, }$_cip"; else cignall=1; fi
      fi
    done <<CIGN
$(composer_ignore_lines "$cignrc" "$CIGN" "$EDUMP")
CIGN
    if cpoff=$(composer_policy_off "$EDUMP"); then
      row GAP PARSED "composer publish-age gate" \
        "composer $cv: $cpoff - a release published minutes ago resolves"
    elif [ -z "$cper" ] || [ "$cper" = "null" ]; then
      row GAP PARSED "composer publish-age gate" \
        "composer $cv implements the cooldown but $escope sets no period - new releases resolve immediately"
    elif [ -z "$csec" ]; then
      row WEAK PARSED "composer publish-age gate" \
        "composer $cv reports a cooldown period of $(cq "$cper") from $(cq "$cpsrc"), which this verifier cannot read as a duration"
    elif [ "$csec" -eq 0 ]; then
      row GAP PARSED "composer publish-age gate" \
        "$escope sets a cooldown period of 0 from $(cq "$cpsrc") - that disables the gate"
    elif [ "$cblk" = "false" ]; then
      row GAP PARSED "composer publish-age gate" \
        "$escope sets policy.cooldown.block=false - versions inside the window install anyway"
    elif [ "$cignall" -eq 1 ]; then
      row GAP PARSED "composer publish-age gate" \
        "$escope sets policy.cooldown.ignore=$(cq "$cign") from $(cq "$cisrc") - a pattern there matches every vendor/name, so every package skips the gate, and no env var outranks a repo's ignore list"
    elif [ -n "$cign" ]; then
      cpartnote=""
      [ -n "$cignpart" ] && cpartnote="; $(cq "$cignpart") matches every package, for the versions its constraint names"
      row WEAK PARSED "composer publish-age gate" \
        "composer $cv enforces $(cq "$cper") but $escope exempts $(cq "$cign") from $(cq "$cisrc")$cpartnote"
    elif [ -n "$cwantsec" ] && [ "$csec" -lt "$cwantsec" ]; then
      row WEAK PARSED "composer publish-age gate" \
        "composer $cv enforces ${csec}s from $(cq "$cpsrc"), below the ${cwanth}h this host declared - something shortened the window"
    else
      row OK PARSED "composer publish-age gate" \
        "composer $cv implements the cooldown and reports ${csec}s from $(cq "$cpsrc") - applies to update and require, not to installing an existing lockfile"
    fi
  fi

# --- composer repo config override  [PARSED] ---
  # ---- 4. a checked-out repo can override all of the above ------------------
  # Composer merges the "config" object of the composer.json in the working
  # directory OVER the global config and names it as the source:
  #   [secure-http] false (./composer.json)
  #   [allow-plugins.evil/plugin] true (./composer.json)
  # Our global file is not authoritative inside an untrusted checkout and no
  # amount of hardening $HOME closes that.
  #
  # TWO things have to be true for OK here, and they fail independently:
  #   (a) the checkout does not weaken any key we harden. An allowlist of two
  #       keys (secure-http, allow-plugins) MISSED audit.block-insecure=false,
  #       which turns audit blocking off for the whole repo while leaving every
  #       global row green - so this diffs composer's own global answer against
  #       composer's own effective answer over EVERY key harden.sh writes.
  #   (b) some hardening of ours is actually in effect. The diff alone is
  #       satisfied by a job with NO hardening at all (MEASURED: global and
  #       effective dumps are then identical, both all-defaults, and the row
  #       printed a byte-identical OK to the fully-hardened run). So the
  #       source of secure-http must be a FILE, not composer's `default`.
  if [ "$phas" -eq 0 ]; then
    row "N/A" - "composer repo config override" \
      "no composer.json in $(cq "$PWD") — nothing here overrides the global config"
  elif [ "$prc" -ne 0 ] || [ "$crc" -ne 0 ]; then
    row WEAK PARSED "composer repo config override" \
      "composer exits $prc reading the effective config for $(cq "$PWD") (global dump rc=$crc); cannot tell whether this checkout overrides our settings"
  else
    povr=""; penv=""
    # `policy` and the cooldown keys: a checkout's "policy": false switched off
    # the cooldown and advisory blocking while this row said "matches the global
    # config on every key we harden" (MEASURED, 2.11.2).
    #
    # Three of these keys have an env form that outranks the checkout, and the
    # dump does not say so. MEASURED on 2.11.2: with COMPOSER_POLICY=1 exported,
    # a checkout's "policy": false is listed as `[policy] true (./composer.json)`
    # (the env value, credited to the repo), and a checkout's "period": null /
    # "block": false are listed as-is although COMPOSER_POLICY_COOLDOWN_PERIOD /
    # _BLOCK replace them (CooldownPolicyConfig, PolicyConfig). A difference
    # on a key whose env form is exported is the env's doing, not an override
    # in effect, so it goes in penv instead.
    for pk in secure-http lock preferred-install allow-plugins \
              audit.abandoned audit.block-insecure audit.block-abandoned \
              policy policy.cooldown.period policy.cooldown.block; do
      pg=$(composer_val "$CDUMP" "$pk"); pe=$(composer_val "$PDUMP" "$pk")
      [ "$pg" = "$pe" ] && continue
      pev=""
      case "$pk" in
        policy) composer_bool_env "${COMPOSER_POLICY:-}" && pev="COMPOSER_POLICY=${COMPOSER_POLICY}" ;;
        policy.cooldown.period) [ -n "${COMPOSER_POLICY_COOLDOWN_PERIOD:-}" ] && pev="COMPOSER_POLICY_COOLDOWN_PERIOD=${COMPOSER_POLICY_COOLDOWN_PERIOD}" ;;
        policy.cooldown.block) _pbe=0; composer_bool_env "${COMPOSER_POLICY_COOLDOWN_BLOCK:-}" || _pbe=$?
                               [ "$_pbe" -ne 2 ] && pev="COMPOSER_POLICY_COOLDOWN_BLOCK=${COMPOSER_POLICY_COOLDOWN_BLOCK}" ;;
      esac
      if [ -n "$pev" ]; then
        penv="${penv:+$penv, }$pk (outranked by the exported $pev)"
      else
        povr="${povr:+$povr, }$pk: ${pg:-<unset>} -> ${pe:-<unset>}"
      fi
    done
    # The cooldown ignore list, compared as the rules composer applies when it
    # blocks: a map-form entry is one --list line per field, which composer_val
    # never matched ({"*": "x"} switched the gate off while this row said
    # "matches the global config", VM run, 2.11.2), and a rule with no fields is
    # no line at all ({"*": {}}, MEASURED on 2.11.2). A rule narrowed by a
    # constraint is shown as "<pattern> (some versions)".
    pig=$(composer_ignore_lines "$cgirc" "$CGIGN" "$CDUMP" | sort -u | sed 's/ 1$/ (some versions)/; s/ 0$//' | tr '\n' ',' | sed 's/,$//; s/,/, /g')
    pie=$(composer_ignore_lines "$cignrc" "$CIGN" "$PDUMP" | sort -u | sed 's/ 1$/ (some versions)/; s/ 0$//' | tr '\n' ',' | sed 's/,$//; s/,/, /g')
    [ "$pig" != "$pie" ] && povr="${povr:+$povr, }policy.cooldown.ignore entries: ${pig:-<none>} -> ${pie:-<none>}"
    plg=$(composer_allowed_plugins "$CDUMP"); ple=$(composer_allowed_plugins "$PDUMP")
    [ "$plg" != "$ple" ] && povr="${povr:+$povr, }plugins the checkout allows: ${ple:-<none>}"
    penvnote=""
    [ -n "$penv" ] && penvnote=" (it also sets $(cq "$penv"), so those stay ours)"
    psrc=$(composer_src "$PDUMP" secure-http)
    if [ -z "$psrc" ]; then
      row WEAK PARSED "composer repo config override" \
        "composer returned no usable [secure-http] line for $(cq "$PWD"); cannot tell whether this checkout overrides our settings"
    elif [ -n "$povr" ]; then
      row GAP PARSED "composer repo config override" \
        "the composer.json in $(cq "$PWD") overrides our hardening (global -> effective): $(cq "$povr") — composer uses the repo's value, not ours$penvnote"
    elif [ "$psrc" = "default" ]; then
      row WEAK PARSED "composer repo config override" \
        "the composer.json in $(cq "$PWD") weakens no key we harden — but composer names its OWN default as the source of secure-http here, so no hardening of ours is in effect either (see the composer config in effect row)"
    elif [ -n "$penv" ]; then
      row OK PARSED "composer repo config override" \
        "composer's effective config for $(cq "$PWD") takes secure-http from $(cq "$psrc"); the checkout sets $(cq "$penv"), and on every other key we harden it matches the global config"
    else
      row OK PARSED "composer repo config override" \
        "composer's effective config for $(cq "$PWD") takes secure-http from $(cq "$psrc") and matches the global config on every key we harden"
    fi
  fi

# --- composer lifecycle scripts blocked  [FUNCTIONAL] ---
  # ---- 5. lifecycle scripts (FUNCTIONAL) -----------------------------------
  # Composer has NO config-file key that disables scripts - "scripts-are-
  # disabled" and COMPOSER_NO_SCRIPTS were both invented and both ignored.
  # The only real primitives are the --no-scripts CLI flag (which the wrapper
  # injects) and COMPOSER_SKIP_SCRIPTS=<event,list>. MEASURED with this
  # fixture: the variable is silently ignored on 2.8.0, 2.8.2, 2.8.4 and
  # 2.8.5 and honored from 2.8.6 (grep -ac on the phars: 0 through 2.8.5, 2
  # from 2.8.6). It is NOT 2.9 as harden.sh:650 and tasks/composer.yml:11
  # both say. No branch here depends on that number - this row is behavioral -
  # but the writers' version gate does.
  #
  # `composer dump-autoload` fires pre/post-autoload-dump with no network, no
  # dependencies and no vendor dir: the one lifecycle event reachable offline.
  # Do NOT use an empty-require `install` - composer skips dispatch entirely
  # on those, which is the tautological fixture this repo already shipped once.
  #
  # TWO INDEPENDENT SIGNALS, because "no marker file" is an ABSENT signal and
  # a script that RAN and whose own write failed leaves exactly that absence.
  # MEASURED: file_put_contents() to an unwritable path warns, composer still
  # exits 0 and still writes vendor/autoload.php - so the original one-signal
  # probe reported OK on a run where the script executed. Composer echoes the
  # script command line when it DISPATCHES it, and prints nothing of the sort
  # under --no-scripts or COMPOSER_SKIP_SCRIPTS (MEASURED 2.2.6, 2.7.1,
  # 2.8.12, stable). The echoed line contains the literal string SCH_MARK;
  # nothing else in composer's output does.
  #
  # FIXTURE CONTROL: the same fixture runs against the real binary with
  # COMPOSER_SKIP_SCRIPTS stripped. If the control does not fire, the fixture
  # is dead and the row is WEAK - never OK.
  # INFRASTRUCTURE GUARD: the live run must produce vendor/autoload.php. A
  # composer that never ran leaves no marker either, and scoring that as
  # "blocked" is the exit-code-as-proof bug.
  ctmp=$(mktemp -d 2>/dev/null)
  if [ -z "$ctmp" ] || [ ! -d "$ctmp" ]; then
    row WEAK PRESENT "composer lifecycle scripts blocked" "mktemp failed; could not run the script-execution probe"
  else
    mkdir -p "$ctmp/p"
    cat > "$ctmp/p/composer.json" <<'CJSON'
{
  "name": "supply-chain/verify-probe",
  "description": "read-only probe fixture",
  "scripts": { "post-autoload-dump": ["@php -r \"file_put_contents(getenv('SCH_MARK'), '1');\""] }
}
CJSON
    cpath=$(scv_our_wrapper composer 2>/dev/null) || cpath=$(command -v composer 2>/dev/null)
    creal="$cpath"; cwrapped=0
    if [ -n "$cpath" ] && grep -q "supply-chain-harden" "$cpath" 2>/dev/null; then
      cwrapped=1
      ctarget=$(grep -oE "^REAL_COMPOSER='[^']*'" "$cpath" 2>/dev/null | head -1 | sed "s/^[^=]*='//; s/'\$//")
      [ -n "$ctarget" ] && [ -x "$ctarget" ] && creal="$ctarget"
    fi
    # control: prove the fixture actually fires
    ctrl=$( cd "$ctmp/p" && env -u COMPOSER_SKIP_SCRIPTS SCH_MARK="$ctmp/control" \
        COMPOSER_CACHE_DIR="$ctmp/cache" COMPOSER_DATA_DIR="$ctmp/data" \
        COMPOSER_ALLOW_SUPERUSER=1 COMPOSER_NO_INTERACTION=1 \
        "$creal" dump-autoload --no-ansi 2>&1 )
    rm -rf "$ctmp/p/vendor"
    # live: the path callers in this job actually hit, with this job's env
    live=$( cd "$ctmp/p" && env SCH_MARK="$ctmp/live" \
        COMPOSER_CACHE_DIR="$ctmp/cache" COMPOSER_DATA_DIR="$ctmp/data" \
        COMPOSER_ALLOW_SUPERUSER=1 COMPOSER_NO_INTERACTION=1 \
        composer dump-autoload --no-ansi 2>&1 ); lrc=$?
    ctrl_disp=0; printf '%s\n' "$ctrl" | grep -q 'SCH_MARK' && ctrl_disp=1
    live_disp=0; printf '%s\n' "$live" | grep -q 'SCH_MARK' && live_disp=1
    if [ ! -f "$ctmp/control" ] || [ "$ctrl_disp" -eq 0 ]; then
      cdead=""
      [ "$cwrapped" -eq 1 ] && [ "$creal" = "$cpath" ] && cdead="; the wrapper at $(cq "$cpath") is on the resolved path but its real target could not be read, so the control ran through the wrapper too"
      row WEAK FUNCTIONAL "composer lifecycle scripts blocked" \
        "fixture control did not fire ($(cq "$creal") neither echoed nor ran a post-autoload-dump script$cdead) — cannot distinguish blocked from broken, so this is NOT evidence"
    elif [ ! -f "$ctmp/p/vendor/autoload.php" ]; then
      row GAP FUNCTIONAL "composer lifecycle scripts blocked" \
        "'composer dump-autoload' through $(cq "$cpath") exits $lrc without running: $(composer_err "$live") — the probe cannot run and neither can callers"
    elif [ -f "$ctmp/live" ]; then
      row GAP FUNCTIONAL "composer lifecycle scripts blocked" \
        "a post-autoload-dump script EXECUTED through $(cq "$cpath") — composer scripts are not blocked in this job"
    elif [ "$live_disp" -eq 1 ]; then
      row GAP FUNCTIONAL "composer lifecycle scripts blocked" \
        "composer DISPATCHED the post-autoload-dump script through $(cq "$cpath") (it echoed the command) though the marker never appeared — the script ran and merely failed to write; scripts are not blocked"
    else
      # Name the mechanism from what is OBSERVABLE. creal = cpath means "no
      # wrapper, or a wrapper whose real target we could not read" - it does
      # NOT mean COMPOSER_SKIP_SCRIPTS is set.
      cwhy="mechanism unclear — no supply-chain wrapper on the resolved path and COMPOSER_SKIP_SCRIPTS is unset; find out what blocked it before relying on it"
      [ -n "${COMPOSER_SKIP_SCRIPTS:-}" ] && cwhy="COMPOSER_SKIP_SCRIPTS is in the environment"
      [ "$cwrapped" -eq 1 ] && cwhy="the wrapper at $(cq "$cpath") injects --no-scripts"
      row OK FUNCTIONAL "composer lifecycle scripts blocked" \
        "ran a package whose post-autoload-dump writes a file; composer neither echoed nor executed it through $(cq "$cpath") ($cwhy)"
    fi
    rm -rf "$ctmp"
  fi
  fi
else
  row "N/A" - "composer" "composer not installed"
fi

# ======================================================================
# cargo
# ======================================================================

# --- cargo publish-age gate  [FUNCTIONAL] ---
# ============================================================ cargo ==========
#
# Cargo is the one ecosystem where the config layer cannot help at all: build.rs
# and proc macros execute at COMPILE time with the caller's full privileges and
# cargo has no --ignore-scripts. The only control that PREVENTS execution is
# refusing to RESOLVE a too-new version, and that lives entirely in the wrapper
# plus the cargo-cooldown backend.
#
# NO ROW HERE CAN REACH "OK" ON ENFORCEMENT, AND THAT IS THE POINT.
# `cargo config get` is nightly-only and cargo-cooldown has no documented
# "do you implement this key" surface, so there is no cargo equivalent of
# npm_implements(): nothing can make either tool report our window back, let
# alone prove it honours it. What CAN be observed is the wrapper's ROUTING,
# and that is what the FUNCTIONAL rows below are about. The enforcement row is
# capped at WEAK for the same reason the pnpm age gate is.

cargo_wrapper_path() {
  # ASK THE WRAPPER; DO NOT INFER FROM PATH POSITION. This was `command -v cargo`
  # plus a marker grep -- "what runs FIRST", which is exactly the inference the
  # SCH_WRAPPER_PROBE run-probe exists to replace and which scv_our_wrapper()
  # already replaced for bun, bunx, deno and composer. cargo was never migrated,
  # so with a DELEGATING shim first on PATH (the mise/asdf/volta shape) one run
  # reported both of these about the same fact:
  #   OK   FUNCTIONAL  cargo PATH wrapper       observed running ... chained behind
  #   GAP  PRESENT     cargo publish-age gate   cargo is not wrapped
  # Not a weakening: scv_our_wrapper falls back to `command -v` + the same
  # marker grep (prefix "supply-chain-harden", which matches both the action's
  # "supply-chain-harden" and the role's "supply-chain-hardening"), so a
  # genuinely unwrapped cargo still returns 1 and the GAP branch still fires.
  #
  # RUSTUP_AUTO_INSTALL=0: the probe runs `cargo --version`, and through a rustup
  # proxy in a directory whose rust-toolchain.toml names a toolchain that is not
  # installed, rustup would otherwise go and download it inside an audit.
  RUSTUP_AUTO_INSTALL=0 scv_our_wrapper cargo
}

# Prints the argv the deployed wrapper hands the real cargo for the invocation
# in "$@", in a directory that either has a lockfile or provably does not.
# Runs the REAL wrapper with a stub standing in for cargo: no network, no
# compile, no side effects, everything inside a temp dir.
#   rc 2 = the temp dir is noexec, so NOTHING was observed (never a GAP)
#   rc 1 = this wrapper shape cannot be safely substituted into
cargo_wrapper_dispatch() { # <lock|nolock> <args...>
  local lock="$1"; shift
  local w tmp d
  w=$(cargo_wrapper_path) || return 1
  tmp=$(mktemp -d 2>/dev/null) || return 1
  # sed delimiter safety: a temp path containing | or \ or & would corrupt the
  # substitution below and leave REAL_CARGO pointing at the REAL cargo.
  case "$tmp" in *[\|\\\&]*) rm -rf "$tmp"; return 1 ;; esac
  # With SCV_STUB_ENV set (cargo_wrapper_env_pin only) the stub ALSO reports the
  # two policy variables it was handed, prefixed with "=" so they can never be
  # mistaken for an argv line. Unset, its output is byte-identical to before, so
  # no other consumer of this function changes.
  cat > "$tmp/real" <<'SCVSTUB'
#!/bin/sh
if [ -n "${SCV_STUB_ENV:-}" ]; then
  printf '=COOLDOWN_MINUTES=%s\n' "${COOLDOWN_MINUTES-<unset>}"
  printf '=COOLDOWN_INCOMPATIBLE_PUBLISH_AGE=%s\n' "${COOLDOWN_INCOMPATIBLE_PUBLISH_AGE-<unset>}"
fi
for a in "$@"; do printf '%s\n' "$a"; done
SCVSTUB
  # Neutralise sfw for THIS probe with a pass-through stub first on PATH. The
  # role's wrapper prefixes network commands with sfw, and sfw execs the child
  # itself, so a broken or absent sfw would swallow the probe's output and make
  # this report "cargo is not wrapped" - a false GAP on the age-gate row caused
  # by an unrelated component. sfw's own health is a separate row below.
  printf '#!/bin/sh\nexec "$@"\n' > "$tmp/sfw"
  chmod +x "$tmp/real" "$tmp/sfw" 2>/dev/null
  # NOEXEC CANARY. A runner that mounts TMPDIR/RUNNER_TEMP noexec makes every
  # dispatch empty, which the caller would otherwise read as "the wrapper never
  # reaches cargo" and label FUNCTIONAL. An observation that could not run is
  # not evidence of anything.
  [ "$(SCV_STUB_ENV='' "$tmp/real" canary 2>/dev/null)" = "canary" ] || { rm -rf "$tmp"; return 2; }
  sed "s|^REAL_CARGO=.*|REAL_CARGO='$tmp/real'|" "$w" > "$tmp/cargo" 2>/dev/null
  # NEVER run the copy unless the substitution demonstrably took. If a future
  # wrapper shape has no REAL_CARGO line the sed no-ops, and running it would
  # execute a REAL `cargo build` - network, compile, side effects. Fail the
  # probe closed instead.
  # -F, not a BRE: mktemp's default template is /tmp/tmp.XXXXXXXXXX and a `[`
  # anywhere in TMPDIR makes an interpolated BRE error out. MEASURED: with
  # TMPDIR=/tmp/x[y], the anchored BRE returns 1 on a file that does contain
  # the line, which failed this probe closed and printed "no dispatch" - a
  # false GAP on an ordinary runner. The path is random and unique, so a
  # fixed-string match can only come from our own substitution.
  grep -Fq "REAL_CARGO='$tmp/real'" "$tmp/cargo" 2>/dev/null || { rm -rf "$tmp"; return 1; }
  chmod +x "$tmp/cargo" 2>/dev/null
  # THE LOCKFILE IS A PARAMETER, NOT A FIXTURE. Planting one unconditionally
  # manufactured the very precondition the --locked half depends on: MEASURED,
  # in a tree with no Cargo.lock the deployed wrapper applies NOTHING and warns
  # "will resolve the newest matching versions unchecked", while a probe that
  # always planted a lockfile reported "wrapper injects --locked".
  if [ "$lock" = lock ]; then
    : > "$tmp/Cargo.lock"
  else
    # has_lockfile walks up to /, so `nolock` is only faithful if no Cargo.lock
    # exists anywhere above $tmp. Check rather than assume.
    d="$tmp"
    while [ -n "$d" ] && [ "$d" != "/" ]; do
      [ -f "$d/Cargo.lock" ] && { rm -rf "$tmp"; return 1; }
      d=$(dirname "$d")
    done
    [ -f /Cargo.lock ] && { rm -rf "$tmp"; return 1; }
  fi
  # SCV_DISPATCH_STDERR=1 returns the wrapper's stderr instead of the argv, for
  # cargo_wrapper_refusal. Unset, the output is exactly the argv, as before.
  if [ -n "${SCV_DISPATCH_STDERR:-}" ]; then
    ( cd "$tmp" && unset SUPPLY_CHAIN_CARGO_WRAPPED && PATH="$tmp:$PATH" ./cargo "$@" 2>&1 >/dev/null )
  else
    ( cd "$tmp" && unset SUPPLY_CHAIN_CARGO_WRAPPED && PATH="$tmp:$PATH" ./cargo "$@" 2>/dev/null )
  fi
  rm -rf "$tmp"
}

# DOES THE WRAPPER REFUSE ITS OWN GATE BACKEND FOR THIS ACCOUNT? The wrapper runs
# cargo-cooldown only when the caller owns it or root owns it with nothing
# above it writable by anyone else (VM#2: a system-wide wrapper used to run the
# deploying user's binaries as root). A refusal exits 126 before any argv
# reaches cargo, so cargo_wrapper_dispatch sees nothing; this reads the
# wrapper's own error line instead of reporting "no dispatch".
cargo_wrapper_refusal() {
  SCV_DISPATCH_STDERR=1 cargo_wrapper_dispatch lock build 2>/dev/null \
    | grep -m1 'refusing to run the cargo publish-age gate backend'
}

# WHAT DOES THE BACKEND ACTUALLY RECEIVE WHEN THE CALLER TRIES TO TURN IT OFF?
#
# cargo-cooldown ranks the environment above every cooldown.toml, so the
# window and violation action in force are whatever reaches it in COOLDOWN_*,
# not what our file says. MEASURED before the wrapper pinned that layer: any of
# ten caller-exported variables, or relocating CARGO_HOME, switched the gate off
# while these rows still read "window 48 hours" and "deny". This observation
# replaces the old decline ("guessing cargo-cooldown's variable name would be
# the made-up-key bug") -- the names are no longer guesses, they are read from
# the shipped source (src/config.rs, apply_env).
#
# Runs the REAL deployed wrapper through the same stub harness as
# cargo_wrapper_dispatch, with the caller exporting COOLDOWN_MINUTES=0 and
# COOLDOWN_INCOMPATIBLE_PUBLISH_AGE=allow. Prints two lines, minutes then
# action, exactly as the backend would receive them:
#   0 / allow                      the caller wins: no environment pin
#   <positive> / deny|fallback     the wrapper pins it: the values are ours
#   <unset>                        cleared without pinning: the FILE decides
#   (nothing)                      not observed (noexec tmp, unsubstitutable)
cargo_wrapper_env_pin() {
  ( export SCV_STUB_ENV=1 COOLDOWN_MINUTES=0 COOLDOWN_INCOMPATIBLE_PUBLISH_AGE=allow
    cargo_wrapper_dispatch lock build ) 2>/dev/null \
    | sed -n 's/^=COOLDOWN_MINUTES=//p; s/^=COOLDOWN_INCOMPATIBLE_PUBLISH_AGE=//p'
}

# Probe a FLAG-PREFIXED invocation as well as the bare one. An earlier wrapper
# read the subcommand from argv[1], so `cargo -q build` matched no case and fell
# through with no controls and no warning - while a verifier that probed only
# the bare form reported OK. `-q`, `--color always` and `+stable` are ordinary
# Makefile and CI forms. MEASURED on the shipping wrapper: all of `-q`,
# `--color always`, `+stable` and `--config foo=1` strip to the same dispatch
# as the bare form, so this fires only on a real regression.
cargo_dispatch_differs() {
  local bare flagged
  bare=$(cargo_wrapper_dispatch lock build) || return 1
  flagged=$(cargo_wrapper_dispatch lock -q build) || return 1
  [ -z "$bare" ] && return 1
  flagged=$(printf '%s\n' "$flagged" | grep -vx -- '-q')
  [ "$bare" != "$flagged" ]
}

# THE STATE WRITERS. `cargo add`, `generate-lockfile`, `vendor` and `remove`
# WRITE Cargo.lock, and the cooldown.toml this project deploys sets
# lockfile-baseline = "floor", whose own comment says versions already pinned
# in an existing lockfile are accepted as a baseline. An ungated writer
# therefore switches the gate off for every build after it. This is
# design-principles.md Axis 3, "Gated the entry points, missed the state
# writers" - a bug this project has already shipped once.
#
# MEASURED against both shipping wrappers with the backend installed:
#   cargo build             -> cooldown build       (gated)
#   cargo update            -> cooldown update      (gated)
#   cargo add serde         -> add serde            (UNGATED)
#   cargo generate-lockfile -> generate-lockfile    (UNGATED)
#   cargo vendor / remove   -> likewise
# These were once SILENT too, because the wrapper's "not age-gated" warning
# lived only in the branch taken when cargo-cooldown is ABSENT. Both wrappers
# now warn in the backend-present branch as well ("'cargo add' writes
# Cargo.lock and is NOT age-gated"), but a warning is not a gate, and
# cargo-cooldown has no subcommand to route them through.
cargo_ungated_writers() {
  local sub wd list=""
  for sub in update add generate-lockfile vendor remove; do
    wd=$(cargo_wrapper_dispatch lock "$sub" supply-chain-probe) || return 1
    printf '%s\n' "$wd" | grep -qx 'cooldown' || list="$list $sub"
  done
  printf '%s' "${list# }"
}

# The sfw hop cannot be read out of cargo_wrapper_dispatch: when sfw is in play
# IT execs the stub, so the stub's own output never mentions it. Plant an sfw
# stub first on PATH and watch whether the wrapper calls it. Note this answers
# "would this wrapper route through sfw if sfw existed", independently of
# whether this host has sfw - which is exactly why it must be consulted BEFORE
# `have sfw`.
cargo_wrapper_uses_sfw() {
  local w tmp out
  w=$(cargo_wrapper_path) || return 1
  tmp=$(mktemp -d 2>/dev/null) || return 1
  case "$tmp" in *[\|\\\&]*) rm -rf "$tmp"; return 1 ;; esac
  printf '#!/bin/sh\necho SFW-INVOKED\nexit 0\n' > "$tmp/sfw"
  printf '#!/bin/sh\nexit 0\n' > "$tmp/real"
  chmod +x "$tmp/sfw" "$tmp/real" 2>/dev/null
  [ "$("$tmp/sfw" 2>/dev/null)" = "SFW-INVOKED" ] || { rm -rf "$tmp"; return 1; }
  sed "s|^REAL_CARGO=.*|REAL_CARGO='$tmp/real'|" "$w" > "$tmp/cargo" 2>/dev/null
  grep -Fq "REAL_CARGO='$tmp/real'" "$tmp/cargo" 2>/dev/null || { rm -rf "$tmp"; return 1; }
  chmod +x "$tmp/cargo" 2>/dev/null
  : > "$tmp/Cargo.lock"
  # Probe BOTH the RESOLVING path (build) and the INSTALL path. `cargo install`
  # is the most network-heavy subcommand yet routed sfw for neither SCH_NET nor a
  # gate, so a build-only probe reported OK while install ran unfiltered. Both
  # must route through sfw, or the wrapper is not actually filtering downloads.
  local out_build out_install
  out_build=$(   cd "$tmp" && unset SUPPLY_CHAIN_CARGO_WRAPPED && PATH="$tmp:$PATH" ./cargo build          2>/dev/null )
  out_install=$( cd "$tmp" && unset SUPPLY_CHAIN_CARGO_WRAPPED && PATH="$tmp:$PATH" ./cargo install ripgrep 2>/dev/null )
  rm -rf "$tmp"
  printf '%s\n' "$out_build"   | grep -q 'SFW-INVOKED' || return 1
  printf '%s\n' "$out_install" | grep -q 'SFW-INVOKED'
}

# Read a single-quoted assignment the wrapper embeds (REAL_CARGO, COOLDOWN_EXE,
# or the COOLDOWN_BIN of a wrapper rendered before the backend had a fixed path).
cargo_embedded() { # <VAR> <wrapper>
  grep -oE "^$1='[^']*'" "$2" 2>/dev/null | head -1 | sed "s/^[^=]*='//; s/'\$//"
}

# Is directory $1 this caller's own, or root's? find(1), not stat(1): portable.
cargo_dir_callers_or_roots() {
  [ -O "$1" ] || [ -n "$(find "$1" -maxdepth 0 -user 0 2>/dev/null)" ]
}

cargo_positive_int() {
  case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
  [ "$1" -gt 0 ] 2>/dev/null
}

# macOS runners have no `timeout`. Never let its absence turn a probe into a
# hang or a false GAP: run_bounded keeps the bound there. (Until it did, the
# fallback here was an unbounded run, which is exactly a hang.)
cargo_run_ok() {
  RUSTUP_AUTO_INSTALL=0 run_bounded 20 "$@" >/dev/null 2>&1
}

# The cargo wrapper's sfw_ready test, run for the caller: prints sfw's cache
# directory when the caller is not root, sfw is the npm shim, nothing is
# cached and the caller cannot fill the cache. The wrapper then runs cargo
# WITHOUT sfw and says so, so it is not the same state as an sfw that cannot
# execute. MEASURED in the role and the action with the cache removed: a
# non-root `cargo fetch` downloaded its crate, exit 0, with the wrapper's
# "sfw has no firewall binary cached" warning, while this row said every
# cargo build was failing.
sfw_cold_cache_for_caller() {
  local s p
  [ "$(id -u)" = 0 ] && return 1
  s=$(command -v sfw 2>/dev/null) || return 1
  s=$(readlink -f "$s" 2>/dev/null) || return 1
  p=${s%/*}; p=${p%/*}
  [ -f "$p/package.json" ] || return 1
  [ -e "$p/.sfw-cache/latest" ] && return 1
  if [ -e "$p/.sfw-cache" ]; then [ -w "$p/.sfw-cache" ] && return 1
  else [ -w "$p" ] && return 1; fi
  printf '%s/.sfw-cache\n' "$p"
}

# `exec -a` is a bash builtin, so it must run INSIDE bash -c for the bound to
# apply to it. This is the invocation that actually dispatches into rustup AS
# cargo - i.e. the one that could trigger a toolchain download - so it is the
# one that needs RUSTUP_AUTO_INSTALL=0 and the bound, not the call that fails
# fast under its own name.
cargo_run_ok_as_cargo() { # <delegate> <args...>
  local p="$1"; shift
  RUSTUP_AUTO_INSTALL=0 run_bounded 20 bash -c 'exec -a cargo "$0" "$@"' "$p" "$@" >/dev/null 2>&1
}

cargo_delegate_err() { # <delegate>
  { RUSTUP_AUTO_INSTALL=0 run_bounded 20 "$1" --version; } 2>&1 | head -1
}

# VERSION TIER. cargo-cooldown 0.3.5 (what the role AND the action pin) has MSRV
# rustc 1.91.1; Ubuntu 24.04's distro rust is 1.75.0. Below the MSRV
# `cargo install cargo-cooldown` cannot build, so "set install_cargo_cooldown:
# true" is advice that cannot work and the row must say so instead.
CARGO_RUSTC_V=""
rustc_below_cooldown_msrv() {
  local v maj rest min pat
  have rustc || return 1
  # RUSTUP_AUTO_INSTALL=0 for the same reason as the cargo probes above: rustc is
  # a rustup proxy too, and this call was the one left unguarded.
  v=$(RUSTUP_AUTO_INSTALL=0 rustc --version 2>/dev/null | awk '{print $2}' | head -1)
  v=${v%%-*}
  CARGO_RUSTC_V="$v"
  case "$v" in ''|*[!0-9.]*) return 1 ;; esac
  maj=${v%%.*}; rest=${v#*.}; min=${rest%%.*}
  case "$rest" in *.*) pat=${rest#*.} ;; *) pat=0 ;; esac
  case "$min" in ''|*[!0-9]*) return 1 ;; esac
  case "$pat" in ''|*[!0-9]*) pat=0 ;; esac
  [ "$maj" -lt 1 ] 2>/dev/null && return 0
  [ "$maj" -gt 1 ] 2>/dev/null && return 1
  [ "$min" -lt 91 ] 2>/dev/null && return 0
  [ "$min" -gt 91 ] 2>/dev/null && return 1
  [ "$pat" -lt 1 ] 2>/dev/null && return 0
  return 1
}

# Every branch below emits EXACTLY FOUR ROWS - gate, violation action, writers,
# threat-intel - including the N/A branches. A row that simply vanishes from a table whose
# summary line is "no gaps" is design-principles.md Axis 4, "absent signal read
# as a passing signal"; the previous block also emitted its N/A row AND fell
# through, double-reporting.

# ECH-189. `have cargo` probed only the verifier's non-interactive PATH, which
# lacks ~/.cargo/bin — so a rustup cargo (the common case, and what a gateway's
# systemd unit actually runs) was reported "cargo not installed", turning a real
# GAP into a false N/A pass — the opposite of the npm false-OK, same root cause:
# reporting on the verifier's own PATH, not the host's. Resolve cargo the way
# the host does and prepend its dir to PATH so the wrapper/dispatch probes below
# find it too. Only a genuinely absent cargo now reaches the N/A branch.
if ! have cargo; then
  for _cbin in "${CARGO_HOME:-$HOME/.cargo}/bin" "$HOME/.cargo/bin"; do
    if [ -x "$_cbin/cargo" ]; then PATH="$_cbin:$PATH"; export PATH; break; fi
  done
fi
if ! have cargo; then
  row "N/A" - "cargo publish-age gate"        "cargo not installed"
  row "N/A" - "cargo age-gate refuses"        "cargo not installed"
  row "N/A" - "cargo lockfile writers routed" "cargo not installed"
  row "N/A" - "cargo threat-intel filtering"  "cargo not installed"
elif ! requested cargo; then
  row "N/A" - "cargo publish-age gate"        "cargo installed but not in the requested ecosystems"
  row "N/A" - "cargo age-gate refuses"        "cargo installed but not in the requested ecosystems"
  row "N/A" - "cargo lockfile writers routed" "cargo installed but not in the requested ecosystems"
  row "N/A" - "cargo threat-intel filtering"  "cargo installed but not in the requested ecosystems"
else
  cw=$(cargo_wrapper_path) || cw=""
  cdisp=""; crc=0; cdisp_nolock=""
  if [ -n "$cw" ]; then
    cdisp=$(cargo_wrapper_dispatch lock build); crc=$?
    cdisp_nolock=$(cargo_wrapper_dispatch nolock build) || cdisp_nolock="<unprobed>"
  fi
  # Environment-layer observation; only meaningful when builds route to cooldown.
  cpin=""; cpact=""
  if [ -n "$cw" ] && printf '%s\n' "$cdisp" | grep -qx 'cooldown'; then
    cpinraw=$(cargo_wrapper_env_pin)
    cpin=$(printf '%s\n' "$cpinraw" | sed -n '1p')
    cpact=$(printf '%s\n' "$cpinraw" | sed -n '2p')
  fi
  # Pinned = the wrapper overwrote the caller's 0 with a positive window. Only
  # then is the window in force independent of which cooldown.toml is found.
  cpinned=0
  cargo_positive_int "${cpin:-x}" && cpinned=1

  # RESOLVE THE CONFIG HOME FROM THE ENVIRONMENT, NEVER ~/.cargo. The official
  # rust images set CARGO_HOME=/usr/local/cargo and runners point it at a cache
  # volume; a cooldown.toml written to ~/.cargo on such a host is present,
  # correct and never read. This is also why the check is done HERE and not at
  # harden time: harden.sh resolved CARGO_HOME in ITS step, and a later
  # setup-rust/cache step can move it before the build runs.
  ch="${CARGO_HOME:-$HOME/.cargo}"
  cage=$(grep -m1 'global-min-publish-age' "$ch/cooldown.toml" 2>/dev/null | sed 's/.*= *//; s/"//g')
  cagen=${cage%% *}
  # THE FAIL-OPEN SWITCH, read from the line above the one we were already
  # grepping. harden.sh writes "deny" only when strict=true and "fallback"
  # otherwise, and its own comment (action/harden.sh) calls fallback "a
  # fail-open posture". A probe that cannot tell "the tool refuses" from "the
  # tool warns and proceeds" is not reporting on the protection.
  cviol=$(grep -m1 'incompatible-publish-age' "$ch/cooldown.toml" 2>/dev/null | sed 's/.*= *//; s/"//g; s/[[:space:]]*$//')
  # LOOK WHERE THE TOOL LOOKS, NOT ONLY WHERE WE WROTE. cargo-cooldown's
  # precedence chain is env > member > workspace > CARGO_HOME and this project
  # writes the WEAKEST level on purpose; harden.sh's own comment calls a
  # committed cooldown.toml in an untrusted repo a hardening bypass. An
  # environment override is NOT checked here because guessing cargo-cooldown's
  # variable name would be the made-up-key bug (Axis 3) in the verifier itself.
  # BOUND THE WALK BY CARGO'S OWN NOTION OF A CONFIG DIRECTORY. cargo-cooldown's
  # "member" and "workspace" levels are cargo MANIFEST directories, so a
  # cooldown.toml only counts as an override if it sits next to a Cargo.toml
  # (or is in $PWD itself, which cargo treats as the invocation directory).
  # Accepting any ancestor would let an unrelated ~/cooldown.toml or /tmp
  # leftover report a bypass that is not in the chain - a false GAP. Climbing
  # THROUGH manifest-less directories is still required: crates/<name> under a
  # workspace root is the ordinary layout, and stopping at the first dir with
  # no Cargo.toml would miss the workspace root entirely (MEASURED - an earlier
  # bound did exactly that and reported no override on a real workspace).
  coverride=""; cdir="$PWD"; cfirst=1
  while [ -z "$coverride" ] && [ -n "$cdir" ] && [ "$cdir" != "/" ]; do
    if [ -f "$cdir/cooldown.toml" ] && [ "$cdir" != "$ch" ] \
       && { [ "$cfirst" = 1 ] || [ -f "$cdir/Cargo.toml" ]; }; then
      coverride="$cdir/cooldown.toml"
    fi
    cfirst=0
    cdir=$(dirname "$cdir")
  done
  # What THIS job's harden step asked for, from its own outputs record. A
  # mismatch means the cooldown.toml at $ch was written by a different run.
  cwant=""
  # ${OUTPUT_FILE:-} NOT $OUTPUT_FILE. This file is shared by both surfaces and
  # runs under `set -u`. OUTPUT_FILE is defined only by the CI preamble
  # (action/verify.sh); the role preamble has no such concept, so a bare
  # reference aborted /usr/local/bin/supply-chain-verify at line 1 of its
  # first use and the role verifier did not run AT ALL. `bash -n` cannot
  # see an unbound variable, so validate: passed it through.
  # Any variable read here must come from the body or be :--guarded.
  [ -f "${OUTPUT_FILE:-}" ] && cwant=$(grep '^release_age_hours=' "${OUTPUT_FILE:-}" 2>/dev/null | head -1 | cut -d= -f2-)

  creal=""; [ -n "$cw" ] && creal=$(cargo_embedded REAL_CARGO "$cw")

  # ---------------------------------------------------------------- gate ----
  # CEILING: WEAK. Never OK. Everything this row can observe is either the
  # behaviour of OUR OWN wrapper or a re-read of the file WE wrote; nothing in
  # it came from cargo or cargo-cooldown. pnpm's age gate is capped at WEAK on
  # strictly stronger evidence (pnpm at least echoes the value back), so an OK
  # here would be the weakest evidence in the file carrying the strongest
  # verdict. See notes for what would earn it.
  if [ "$crc" = 2 ]; then
    row WEAK PRESENT "cargo publish-age gate" \
      "CANNOT VERIFY: ${TMPDIR:-/tmp} will not execute the probe's own stub (a noexec mount, or a filesystem that drops the exec bit), so the wrapper-dispatch probe could not run at all. Nothing was observed here, so nothing is claimed - this is not evidence of a gap either"
  elif [ -z "$cw" ]; then
    cshadow=""
    # BOTH SURFACES' NAME FOR THE SAME HELPER: action/verify.sh calls it
    # find_wrapper_on_path, templates/verify.sh.j2 calls it locate_wrapper.
    # Guarding on one name meant the role surface never named a shadow and
    # printed "cargo is not wrapped" -- the wrong diagnosis with the wrong fix --
    # about a wrapper that was deployed but bypassed.
    for scv__lw in find_wrapper_on_path locate_wrapper; do
      type "$scv__lw" >/dev/null 2>&1 || continue
      cshadow=$("$scv__lw" cargo 2>/dev/null) || cshadow=""
      [ -n "$cshadow" ] && break
    done
    if [ -n "$cshadow" ]; then
      row GAP PRESENT "cargo publish-age gate" \
        "the cargo wrapper is deployed at $cshadow but SHADOWED - PATH resolves cargo to $(command -v cargo 2>/dev/null) first, so no caller reaches it. The fix is PATH order, not redeploying the wrapper"
    else
      row GAP PRESENT "cargo publish-age gate" \
        "cargo is not wrapped - \`cargo build\` executes build.rs from whatever version the resolver picks, including one published minutes ago. cargo resolves to $(command -v cargo 2>/dev/null)"
    fi
  elif [ -n "$creal" ] && [ ! -x "$creal" ]; then
    # HOISTED ABOVE THE ROUTING BRANCHES ON PURPOSE. The dispatch probe
    # substitutes its own stub for REAL_CARGO, so an orphaned wrapper still
    # dispatches perfectly. MEASURED: with the delegate deleted, a probe that
    # checked this only inside the cooldown arm printed the same WEAK
    # "--locked" row as the healthy no-backend case, while the deployed
    # wrapper exits 127 on every invocation.
    row GAP FUNCTIONAL "cargo publish-age gate" \
      "the wrapper's real cargo '$creal' is missing or not executable - the recursion guard makes every \`cargo build\` exit 127. Nothing builds, so nothing is gated"
  elif [ -n "$creal" ] && ! cargo_run_ok "$creal" --version; then
    # ARGV[0] ASYMMETRY. The closest thing cargo has to npm_implements(): ask
    # the delegate under conditions our own machinery is not propping up.
    # rustup's cargo is a proxy that dispatches on argv[0]; harden.sh renames
    # it with a plain `sudo mv`, and rustup rejects `cargo-real` outright. The
    # wrapper's own call survives via `exec -a cargo`, so nothing else in this
    # verifier can see the breakage.
    cerr=$(cargo_delegate_err "$creal")
    if cargo_run_ok_as_cargo "$creal" --version; then
      row GAP FUNCTIONAL "cargo publish-age gate" \
        "the wrapper's delegate '$creal' runs when invoked as \`cargo\` but FAILS under its own name: ${cerr}. It is rustup's argv[0]-dispatching proxy, renamed by a plain mv. The wrapper's own call is fixed up with exec -a, but re-entry is not: cargo hands subcommands its own path via \$CARGO. This probe measures the asymmetry only; that cargo-cooldown then dies on re-entry is recorded in $(scv_doc docs/design-principles.md#assumed-canonical-paths), not observed here"
    else
      row GAP FUNCTIONAL "cargo publish-age gate" \
        "the wrapper's delegate '$creal' does not execute at all (${cerr}) - \`cargo build\` is broken, not gated"
    fi
  elif [ -n "$cw" ] && cprep=$(cargo_embedded COOLDOWN_BIN "$cw") && [ -n "$cprep" ] && [ -d "$cprep" ] \
       && ! cargo_dir_callers_or_roots "$cprep"; then
    # A WRAPPER FROM BEFORE THE BACKEND HAD A FIXED PATH, reached by an account
    # that does not own the directory it prepends. MEASURED (VM#2, reproduced
    # on Ubuntu 26.04 with apt cargo 1.93.1): such a /usr/bin/cargo made
    # `sudo -H cargo build` and a second account's build run the deploying
    # user's cargo-cooldown and ~/.cargo/bin/cargo. The dispatch probe below
    # would still see `cooldown build` and credit the gate. The role re-renders
    # these on apply; this row is for a host where that has not happened.
    row GAP FUNCTIONAL "cargo publish-age gate" \
      "the wrapper at $cw was rendered before the gate backend had a fixed path: it PREPENDS $cprep to PATH, a directory owned by $(ls -ld "$cprep" 2>/dev/null | awk '{print $3}'), not by $( [ "$(id -u)" = 0 ] && echo root || echo "$(id -un 2>/dev/null) or root"), so this account's \`cargo build\` runs that account's cargo-cooldown, and any cargo or rustc there, ahead of its own. Re-apply the role (or re-run harden.sh) to re-render it with a root-owned backend"
  elif [ -z "$cdisp" ] && crefuse=$(cargo_wrapper_refusal) && [ -n "$crefuse" ]; then
    row GAP FUNCTIONAL "cargo publish-age gate" \
      "the wrapper at $cw REFUSES its gate backend for this account ($(id -un 2>/dev/null)), so \`cargo build\` fails here rather than run a binary another account could replace. Its message: ${crefuse#*error: }"
  elif [ -z "$cdisp" ]; then
    row GAP FUNCTIONAL "cargo publish-age gate" \
      "the wrapper at $cw produced no dispatch for \`cargo build\` - either it never reaches the real cargo, or it is not a shape this probe can safely substitute into. Nothing here is verified, so nothing here is credited"
  elif cargo_dispatch_differs; then
    row GAP FUNCTIONAL "cargo publish-age gate" \
      "the wrapper treats \`cargo build\` and \`cargo -q build\` DIFFERENTLY - a global flag before the subcommand bypasses the controls. Ordinary Makefile and CI invocations are ungated"
  elif printf '%s\n' "$cdisp" | grep -qx 'cooldown'; then
    cexe=$(cargo_embedded COOLDOWN_EXE "$cw")
    cbin=$(cargo_embedded COOLDOWN_BIN "$cw")
    cool=""
    # Resolve cargo-cooldown EXACTLY the way the deployed wrapper does at runtime:
    # its embedded COOLDOWN_EXE (an absolute path), else the ambient PATH. A
    # wrapper rendered before that had COOLDOWN_BIN, a directory it PREPENDED to
    # PATH; it is still read here so such a wrapper is judged by what it does. A
    # prior version also tried "$ch/bin/cargo-cooldown", but that let the
    # verifier find a backend the WRAPPER cannot - #376: when COOLDOWN_BIN
    # rendered EMPTY the prepend was a no-op, yet $ch/bin still resolved, so the
    # row reported OK while the gate was inert on the host. Match the wrapper or
    # lie.
    for cand in "$cexe" "${cbin:+$cbin/cargo-cooldown}" "$(command -v cargo-cooldown 2>/dev/null)"; do
      [ -n "$cand" ] && [ -x "$cand" ] && { cool="$cand"; break; }
    done
    if [ -z "$cool" ] && [ -z "$cexe" ] && [ -z "$cbin" ] && grep -q "^COOLDOWN_BIN=''" "$cw" 2>/dev/null; then
      row GAP FUNCTIONAL "cargo publish-age gate" \
        "the wrapper's COOLDOWN_BIN is EMPTY (#376), so its \$CARGO_HOME/bin PATH prepend is a no-op and cargo-cooldown - which lives in ~/.cargo/bin, off PATH on apt-cargo hosts - is never reached at runtime. The route dead-ends; \`cargo build\` is BROKEN, not gated. Re-apply with cargo_home resolved."
    elif [ -z "$cool" ]; then
      row GAP FUNCTIONAL "cargo publish-age gate" \
        "the wrapper routes builds through \`cargo cooldown\` but cargo-cooldown is not installed where the wrapper looks (${cexe:-${cbin:-PATH}}). The route dead-ends, so \`cargo build\` is BROKEN, not gated"
    elif ! cargo_run_ok "$cool" --version; then
      row GAP FUNCTIONAL "cargo publish-age gate" \
        "cargo-cooldown is installed ($cool) but CANNOT EXECUTE - usually a prebuilt binary needing newer glibc than this image ships. The wrapper routes builds into it, so \`cargo build\` is BROKEN, not gated"
    elif [ "$cpin" = "0" ] || [ "$cpact" = "allow" ]; then
      row GAP FUNCTIONAL "cargo publish-age gate" \
        "routing verified, but the caller's environment reaches cargo-cooldown UNCHANGED: with COOLDOWN_MINUTES=0 and COOLDOWN_INCOMPATIBLE_PUBLISH_AGE=allow exported, the backend received window=${cpin:-?} action=${cpact:-?}. cargo-cooldown ranks the environment above every cooldown.toml, so one exported variable switches this gate off - ten different variables do, and so does relocating CARGO_HOME. This wrapper predates environment pinning: re-apply"
    elif [ -n "$coverride" ] && [ "$cpinned" = 1 ]; then
      # GAP, not WEAK, even though the pin is OBSERVED. The pin beats a repo file
      # only for settings that have an environment form; [allow.global] minutes,
      # [[allow.package]], [[allow.exact]] and [registries.<alt>] windows have
      # none, and MEASURED (cargo-cooldown 0.3.5) `[allow.global] minutes = 0`
      # in a repo cooldown.toml built a crate published hours earlier through a
      # pinned wrapper. This row reads presence, not content, so it cannot tell
      # a harmless file from that one.
      row GAP FUNCTIONAL "cargo publish-age gate" \
        "routing verified and the wrapper pins the environment (OBSERVED handing the backend COOLDOWN_MINUTES=$cpin over a caller's 0), which beats $coverride for the global and crates.io windows, now and skip_registries. It does NOT beat that file's [allow.global] minutes, [[allow.package]], [[allow.exact]] or [registries.<alt>] windows, which have no environment form, so a cooldown.toml committed to an untrusted repo can still loosen this gate"
    elif [ -n "$coverride" ]; then
      row GAP FUNCTIONAL "cargo publish-age gate" \
        "routing verified, but $coverride sits ABOVE $ch/cooldown.toml in cargo-cooldown's precedence chain (env > member > workspace > CARGO_HOME) and this wrapper does not pin the environment, so our ${cage:-<unset>} window is not the one in force. A committed cooldown.toml in an untrusted repo is a hardening bypass on this wrapper"
    elif [ ! -f "$ch/cooldown.toml" ] && [ "$cpinned" = 1 ]; then
      row WEAK FUNCTIONAL "cargo publish-age gate" \
        "no cooldown.toml at the CARGO_HOME this step resolves ($ch), but the window does not depend on it: the wrapper pins the environment layer - OBSERVED handing the backend COOLDOWN_MINUTES=$cpin ($(( cpin / 60 ))h) over a caller's 0. Only per-crate [[allow.exact]] exceptions from that file are missing here"
    elif [ ! -f "$ch/cooldown.toml" ]; then
      row GAP FUNCTIONAL "cargo publish-age gate" \
        "the wrapper routes through a working cargo-cooldown, but there is no cooldown.toml at the CARGO_HOME THIS step resolves ($ch), and the wrapper does not pin the environment. harden.sh wrote it to whatever CARGO_HOME was set in its own step; a later toolchain or cache step moved it"
    elif ! cargo_positive_int "$cagen"; then
      # Kept even when the environment is pinned: cargo-cooldown still PARSES this
      # file, and a value it cannot parse aborts every routed build. A value that
      # parses but is not positive (e.g. "0 hours") would be overridden by the pin
      # and this is then conservative - reachable only by editing our file.
      row GAP FUNCTIONAL "cargo publish-age gate" \
        "the route works but $ch/cooldown.toml carries global-min-publish-age='${cage:-<unset>}' - not a positive number of hours, so no window is in force"
    else
      # The window in force: the pinned environment value when observed, else the
      # file. Compared against what this job's harden step asked for.
      if [ "$cpinned" = 1 ]; then cwin=$(( cpin / 60 )); else cwin="$cagen"; fi
      if [ -n "$cwant" ] && [ "$cwin" != "$cwant" ]; then
        row GAP FUNCTIONAL "cargo publish-age gate" \
          "routing verified, but the window in force is ${cwin}h while this job's harden step recorded release_age_hours=$cwant. Written by a DIFFERENT run - a restored CARGO_HOME cache, or CARGO_HOME moved between steps. Something may be gating; it is not what this job asked for"
      elif [ "$cpinned" = 1 ]; then
        row WEAK FUNCTIONAL "cargo publish-age gate" \
          "\`cargo build\` is ROUTED through \`cargo cooldown\`, the backend at $cool answers --version, and the wrapper pins the window in the environment - OBSERVED handing it COOLDOWN_MINUTES=$cpin (${cwin}h) when the caller had exported 0, so no cooldown.toml anywhere can widen it. CAPPED AT WEAK ON PURPOSE: these are observations of OUR wrapper; cargo-cooldown never reported the window back and nothing here watched it refuse a crate - the same honest cap as the pnpm age-gate row"
      else
        row WEAK FUNCTIONAL "cargo publish-age gate" \
          "\`cargo build\` is ROUTED through \`cargo cooldown\` and the backend at $cool answers --version; window ${cage} at $ch/cooldown.toml (what it does on a violation is its own row). CAPPED AT WEAK ON PURPOSE: every fact about the window comes from re-reading the file we wrote. cargo has no config readback (\`cargo config get\` is nightly-only) and cargo-cooldown never reported the value back, so nothing here observed the gate refusing anything - the same honest cap as the pnpm age-gate row"
      fi
    fi
  elif printf '%s\n' "$cdisp" | grep -qx -- '--locked'; then
    # THE LOCKFILE IS THE PRECONDITION, SO REPORT IT AS ONE. MEASURED: with no
    # backend and no Cargo.lock the wrapper applies NOTHING and says so on
    # stderr. A probe that plants its own lockfile and then reports "wrapper
    # injects --locked" is describing a state it created.
    if ! printf '%s\n' "$cdisp_nolock" | grep -qx -- '--locked' && [ "$cdisp_nolock" != "<unprobed>" ]; then
      clockmsg="and there IS no Cargo.lock at or above $PWD, so this invocation gets NO control at all"
      [ -f "$PWD/Cargo.lock" ] && clockmsg="and a Cargo.lock is present at $PWD, so a committed lockfile is honoured; a fresh checkout without one gets NO control"
    else
      clockmsg="lockfile state at $PWD could not be established"
    fi
    if ! printf '%s\n' "$cdisp_nolock" | grep -qx -- '--locked' && [ "$cdisp_nolock" != "<unprobed>" ] && [ ! -f "$PWD/Cargo.lock" ]; then
      row GAP FUNCTIONAL "cargo publish-age gate" \
        "no publish-age backend, and the wrapper's fallback (--locked) applies ONLY when a lockfile exists - $clockmsg. \`cargo build\` here resolves the newest matching versions unchecked and runs their build.rs"
    elif rustc_below_cooldown_msrv; then
      row WEAK FUNCTIONAL "cargo publish-age gate" \
        "wrapper injects --locked but there is no publish-age backend - it protects a committed lockfile and does nothing for \`cargo update\` or a fresh checkout ($clockmsg). install_cargo_cooldown: true will NOT help here: rustc ${CARGO_RUSTC_V:-?} is below cargo-cooldown's MSRV 1.91.1, so the build from source fails. Use a rustup toolchain >= 1.91.1"
    else
      row WEAK FUNCTIONAL "cargo publish-age gate" \
        "wrapper injects --locked but cargo-cooldown is absent - it protects a committed lockfile and does nothing for \`cargo update\` or a fresh checkout ($clockmsg). Set install_cargo_cooldown: true to enforce the ${cwant:-configured} hour window"
    fi
  else
    row GAP FUNCTIONAL "cargo publish-age gate" \
      "cargo is wrapped but for \`cargo build\` the wrapper applied neither the cooldown route nor --locked - the dispatch was: $(printf '%s' "$cdisp" | tr '\n' ' ')"
  fi

# --- cargo age-gate refuses (violation action)  [PRESENT] ---
  # ------------------------------------------------- violation action -------
  # ITS OWN ROW, BECAUSE IT IS ITS OWN STATE. A gate that DOWNGRADES-AND-WARNS
  # and a gate that REFUSES are materially different postures, and harden.sh
  # picks between them from a single input: violation_action="deny" when
  # strict=true, "fallback" otherwise. Folded into the gate row's detail these
  # two produce the same STATUS on the same EVIDENCE, differing only in prose -
  # which is the defect this whole file exists to avoid. Given the gate row is
  # capped at WEAK, a caveat inside it cannot lower anything, so the caveat
  # needs a status of its own.
  #
  # EVIDENCE IS "PRESENT", NOT PARSED OR FUNCTIONAL, AND DELIBERATELY SO. This
  # is a re-read of the file we wrote. cargo-cooldown never reported the key
  # back and no probe here saw it refuse anything. The MEANING of "fallback" is
  # quoted from harden.sh's own comment ("only downgrades and warns - a
  # fail-open posture"); it was NOT measured against cargo-cooldown, and the
  # detail says so rather than asserting a semantic this probe cannot see.
  if [ "$crc" = 2 ] || [ -z "$cw" ] || [ -z "$cdisp" ]; then
    row "N/A" - "cargo age-gate refuses" \
      "no verified cargo-cooldown route - see the publish-age gate row"
  elif ! printf '%s\n' "$cdisp" | grep -qx 'cooldown'; then
    row "N/A" - "cargo age-gate refuses" \
      "no publish-age backend is routed, so there is no violation action to take - see the publish-age gate row"
  elif [ "$cpact" = "allow" ]; then
    row GAP FUNCTIONAL "cargo age-gate refuses" \
      "a caller-exported COOLDOWN_INCOMPATIBLE_PUBLISH_AGE=allow reaches cargo-cooldown unchanged, so any caller turns a refusal into a silent accept, whatever any cooldown.toml says - see the publish-age gate row"
  elif [ "$cpinned" = 1 ] && [ "$cpact" = "deny" ]; then
    # FUNCTIONAL now, not PRESENT: this is the value OBSERVED being handed to the
    # backend over a caller's "allow", not a re-read of our file. Still WEAK:
    # cargo-cooldown never reported it back and nothing here watched a refusal.
    row WEAK FUNCTIONAL "cargo age-gate refuses" \
      "the wrapper pins incompatible-publish-age='deny' in the environment - OBSERVED handed to cargo-cooldown over a caller's 'allow' - which outranks every cooldown.toml, a repo's own included. deny is documented (harden.sh, the role's cooldown.toml) as failing the command and restoring the original Cargo.lock; that semantic is quoted, not measured here"
  elif [ "$cpinned" = 1 ]; then
    row GAP FUNCTIONAL "cargo age-gate refuses" \
      "the wrapper pins incompatible-publish-age='${cpact:-<unset>}', not 'deny' (OBSERVED in the environment it hands cargo-cooldown). The action writes 'fallback' when strict=false and its own comment calls that 'a fail-open posture - only downgrades and warns'; on the role it is cargo_cooldown_violation_action. So the gate is configured NOT to refuse"
  elif [ ! -f "$ch/cooldown.toml" ]; then
    row "N/A" - "cargo age-gate refuses" \
      "no cooldown.toml at $ch - see the publish-age gate row"
  elif [ -n "$coverride" ]; then
    # A higher-precedence file is in force, so the violation action OUR file
    # sets is not the one that applies. Reading ours here would report on a
    # setting nothing uses.
    row "N/A" - "cargo age-gate refuses" \
      "$coverride overrides $ch/cooldown.toml, so the violation action in force is not ours - see the publish-age gate row"
  elif [ "$cviol" = "deny" ]; then
    row WEAK PRESENT "cargo age-gate refuses" \
      "$ch/cooldown.toml sets incompatible-publish-age='deny', which harden.sh documents as failing the command and restoring the original Cargo.lock. PRESENT-grade: this is a re-read of the file we wrote, cargo-cooldown never reported the key back, and no probe here observed a refusal"
  else
    row GAP PRESENT "cargo age-gate refuses" \
      "$ch/cooldown.toml sets incompatible-publish-age='${cviol:-<unset>}', not 'deny'. harden.sh writes 'deny' only when strict=true and its own comment calls this value 'a fail-open posture - only downgrades and warns'. So the gate is configured NOT to refuse; re-run with strict: true. That semantic is quoted from harden.sh, not measured against cargo-cooldown"
  fi

# --- cargo lockfile writers routed  [FUNCTIONAL] ---
  # ------------------------------------------------------------- writers ----
  # Separate row, and the ONE row in this section that can legitimately reach
  # OK - because its claim is exactly what it observes: "these subcommands are
  # handed to \`cargo cooldown\`". It says nothing about enforcement; the gate
  # row above carries that caveat. Merging the two would hide which half is
  # missing, which is the same reason the sfw row is separate.
  if [ "$crc" = 2 ]; then
    row WEAK PRESENT "cargo lockfile writers routed" \
      "CANNOT VERIFY: ${TMPDIR:-/tmp} will not execute the probe's stub, the dispatch probe could not run"
  elif [ -z "$cw" ] || [ -z "$cdisp" ]; then
    row "N/A" - "cargo lockfile writers routed" \
      "no working cargo wrapper to route through - see the publish-age gate row"
  elif ! printf '%s\n' "$cdisp" | grep -qx 'cooldown'; then
    row "N/A" - "cargo lockfile writers routed" \
      "no publish-age backend is routed for \`cargo build\` either, so there is no gate for a writer to bypass - see the publish-age gate row"
  else
    cungated=$(cargo_ungated_writers); cuw_rc=$?
    if [ "$cuw_rc" != 0 ]; then
      row WEAK PRESENT "cargo lockfile writers routed" \
        "could not dispatch-probe the writer subcommands - unverified, not credited"
    elif [ -n "$cungated" ]; then
      # A TOOL LIMIT, NOT A CONFIG GAP. cargo-cooldown has no subcommand for
      # these writers (both wrappers say so), so no re-run of the hardening
      # routes them: as a plain row() the action counted this "fixable by
      # re-running", and `fail-on: config` failed every job that installed
      # cargo-cooldown, permanently. Classed like a toolchain gap instead. The
      # role has no classes, so there it is an ordinary GAP.
      # The old detail said this state was SILENT. It is not: both wrappers
      # print "'cargo <writer>' writes Cargo.lock and is NOT age-gated" on every
      # such call with the backend installed (MEASURED: `cargo add` on the role
      # wrapper). A warning is not a gate, so it stays a GAP.
      scv_toolchain_gap cargo.lockfile-writers FUNCTIONAL "cargo lockfile writers routed" \
        "\`cargo build\` is routed through the age gate but these lockfile WRITERS are not: ${cungated}. cooldown.toml sets lockfile-baseline='floor', so every later gated build ACCEPTS whatever they pinned - one \`cargo ${cungated%% *}\` switches the gate off for every build after it. The wrapper prints a 'writes Cargo.lock and is NOT age-gated' warning for each of them, but a warning is not a gate. No configuration closes this: cargo-cooldown has no subcommand for these writers. See $(scv_doc docs/design-principles.md#gated-the-entry-points-missed-the-state-writers)"
    else
      row OK FUNCTIONAL "cargo lockfile writers routed" \
        "update, add, generate-lockfile, vendor and remove all dispatch through \`cargo cooldown\` - no ungated path writes the lockfile the gated builds then trust. (Routing only; whether cooldown refuses is the gate row's caveat)"
    fi
  fi

# --- cargo threat-intel filtering  [FUNCTIONAL] ---
  # -------------------------------------------------------- threat intel ----
  # Different axis from the age gate: cooldown blocks by publish time and only
  # at resolution; sfw blocks by intel at download time and therefore also
  # covers a lockfile written elsewhere. Neither subsumes the other.
  #
  # ORDER MATTERS. cargo_wrapper_uses_sfw plants its own sfw stub FIRST on
  # PATH, so it answers "would this wrapper route through sfw if sfw existed",
  # independently of whether this host has sfw. Testing `have sfw` before it
  # turns any wrapper that merely MENTIONS sfw in a COMMENT into a GAP.
  # MEASURED: rendering templates/cargo-wrapper.sh.j2 with
  # cargo_socket_firewall: false still leaves two `sfw` COMMENTS (lines 25 and
  # 98 of the rendered file) outside the {% if %} block, so a role-hardened
  # self-hosted runner with the feature deliberately OFF failed strict CI both
  # when sfw was absent (GAP PRESENT) and when it was present (GAP FUNCTIONAL).
  if [ "$crc" = 2 ]; then
    row WEAK PRESENT "cargo threat-intel filtering" \
      "CANNOT VERIFY: ${TMPDIR:-/tmp} will not execute the probe's stub, the dispatch probe could not run"
  elif [ -z "$cw" ] || [ -z "$cdisp" ]; then
    row "N/A" - "cargo threat-intel filtering" \
      "no working cargo wrapper to route through - see the publish-age gate row"
  elif ! grep -q 'sfw' "$cw" 2>/dev/null || ! cargo_wrapper_uses_sfw; then
    # Not a GAP: the wrapper was rendered without the sfw route, which is a
    # choice, not a misconfiguration. Both surfaces render it only when
    # cargo_socket_firewall is true; harden.sh defaults that to follow
    # `intel`, so the default intel: none lands here. Emitting GAP for it
    # would fail every strict run for a feature the job did not ask for - the
    # thing the `requested()` comment already warns against.
    row "N/A" - "cargo threat-intel filtering" \
      "this wrapper does not route cargo through sfw (sfw $(have sfw && echo 'is installed but not wired into the cargo wrapper' || echo 'not installed')) - crate downloads are not threat-intel filtered, so a lockfile pinning a known-malicious crate is fetched normally. The action routes cargo through sfw with intel: sfw (or cargo_socket_firewall: true); the Ansible role with cargo_socket_firewall: true"
  elif ! have sfw; then
    row GAP PRESENT "cargo threat-intel filtering" \
      "the wrapper routes cargo through sfw but sfw is not on PATH - crate downloads are unfiltered"
  elif grep -q 'sfw_ready' "$cw" 2>/dev/null && scold=$(sfw_cold_cache_for_caller); then
    # Before the run test below, which fails here too (sfw cannot create its
    # cache) and would blame sfw for builds that are running. A wrapper from
    # before sfw_ready existed does run sfw, and does fail, so it falls through.
    row GAP FUNCTIONAL "cargo threat-intel filtering" \
      "sfw has no firewall binary cached that this account can run (${scold}), and only root can fetch it, so the wrapper runs cargo WITHOUT sfw and warns - builds work, crate downloads are unfiltered. Re-apply the role or re-run the hardening step, or run 'sudo sfw true' once"
  elif ! cargo_run_ok env SFW_SKIP_UPDATE_CHECK=1 sfw --version \
       && ! cargo_run_ok env SFW_SKIP_UPDATE_CHECK=1 sfw --help; then
    # SFW_SKIP_UPDATE_CHECK=1: the wrappers run sfw that way, so a non-root
    # caller never writes its root-owned cache. Probing without it reported
    # this GAP from one hour after hardening for wrappers that were working.
    row GAP FUNCTIONAL "cargo threat-intel filtering" \
      "sfw is present but CANNOT EXECUTE, and the wrapper prefixes cargo with it - EVERY cargo build in this job is failing. sfw downloads its firewall binary from GitHub on first use; this state usually means that fetch never succeeded"
  else
    # Deliberately WEAK, no OK branch: sfw checks only what is DOWNLOADED, so
    # a crate already in the local cache builds unchecked. An earlier note here
    # said sfw fails open when it cannot reach Socket. MEASURED with sfw-free
    # 1.16.0 (2026-11-19), it does not: with Socket's API refused or
    # blackholed, `cargo fetch` exited 101 and the download never happened.
    row WEAK FUNCTIONAL "cargo threat-intel filtering" \
      "wrapper routes cargo through sfw; it checks only crates that are downloaded, so one already in the local cache builds unchecked, and an unreachable Socket API fails the build rather than letting it through"
  fi
fi

# ======================================================================
# bundler
# ======================================================================

# --- bundler lockfile pinning  [FUNCTIONAL] ---
# ------------------------------------------------------------- bundler -------
# SCOPE, stated first because it bounds the row below: Ruby has NO install-time
# script blocking. extconf.rb runs on every native-extension gem, always, and no
# bundler setting changes that. What frozen/deployment buy is ADMISSION PINNING:
# bundler refuses to resolve anything the committed Gemfile.lock does not
# already name, so a newly-published malicious version cannot enter through a
# routine `bundle install`. That is what this row measures.
#
# frozen and deployment share ONE row because they are one protection. They are
# NOT interchangeable, though: MEASURED, hardened file + BUNDLE_FROZEN=false in
# the environment -> 2.4.19/4.0.19 stop refusing, 2.2.33 still refuses because
# its deployment implementation is independent. So the probe never assumes
# `frozen` speaks for `deployment`; it reads whichever key bundler NAMES.
#
# LAYER SCOPE: this measures the USER-level config layer (whatever bundler
# resolves as its config home). BUNDLE_APP_CONFIG is redirected to an empty
# temp path, so a checked-out project's own .bundle/config is deliberately
# excluded — bundler gives that layer higher precedence and this row cannot
# speak for it. The "bundler local config override" row below does.

bundler_bin=""
for bcand in bundle bundler; do
  if have "$bcand"; then bundler_bin="$bcand"; break; fi
done

# bundler_implements() — the bundler analogue of npm_implements(), used ONLY as
# a last resort when the behavioural fixture below produced no verdict.
# `bundle config get <key>` echoes ANY key back, invented ones included
# (MEASURED: BUNDLE_TOTALLY_INVENTED_KEY round-trips with rc 0), so a value
# coming back proves only that bundler read our file. The discriminator is the
# QUOTING: bundler type-coerces keys in its own BOOL_KEYS/NUMBER_KEYS lists
# (lib/bundler/settings.rb, a per-version literal list) and prints them bare —
# `true` — while an unrecognised key stays a String and prints inspected —
# `"true"`. We plant BOTH the real key and a sentinel invented key at the
# identical value in a throwaway HOME: the real key must come back bare AND the
# sentinel must come back quoted. Requiring the sentinel to be quoted is what
# makes this non-tautological — it proves this bundler still distinguishes the
# two classes, so a future bundler that stopped quoting cannot yield a silent
# false OK.
# Valid for BOOLEAN keys only: `path` (string) and `retry` (number) report
# not-implemented despite being real. We only ever pass `frozen`.
# Returns 0 = implemented, 1 = NOT implemented, 2 = COULD NOT INTERROGATE.
# 2 exists because a bundler that crashed tells us nothing about the key, and
# reporting "the key is not implemented" there would be fabricated evidence
# (design-principles.md Axis 4: exit status is not proof of a mechanism).
bundler_implements() {
  local bi_key="$1" bi_up bi_d bi_out bi_real bi_sent
  bi_up=$(echo "$bi_key" | tr '[:lower:]' '[:upper:]' | tr '-' '_')
  bi_d=$(mktemp -d 2>/dev/null) || return 2
  [ -n "$bi_d" ] && [ -d "$bi_d" ] || return 2
  mkdir -p "$bi_d/.bundle" 2>/dev/null || { rm -rf "$bi_d"; return 2; }
  printf -- '---\nBUNDLE_%s: "true"\nBUNDLE_SCH_PROBE_SENTINEL: "true"\n' "$bi_up" > "$bi_d/.bundle/config"
  bi_out=$(cd "$bi_d" && env -u BUNDLE_USER_CONFIG -u BUNDLE_USER_HOME \
                             -u BUNDLE_APP_CONFIG -u BUNDLE_GEMFILE \
                             -u "BUNDLE_$bi_up" -u BUNDLE_SCH_PROBE_SENTINEL \
                             HOME="$bi_d" "$bundler_bin" config get "$bi_key" 2>/dev/null)
  # LIVENESS. Bundler prints this header on every successful `config get`
  # (MEASURED on 2.2.33/2.4.19/4.0.19). Without it the binary did not run and
  # we know nothing — never "not implemented".
  case "$bi_out" in
    *"Settings for"*) : ;;
    *) rm -rf "$bi_d"; return 2 ;;
  esac
  bi_real=$(printf '%s\n' "$bi_out" | grep -E 'Set for the current user' | head -1 | sed 's/.*): *//' | tr -d '\r')
  bi_sent=$(cd "$bi_d" && env -u BUNDLE_USER_CONFIG -u BUNDLE_USER_HOME \
                              -u BUNDLE_APP_CONFIG -u BUNDLE_GEMFILE \
                              -u BUNDLE_SCH_PROBE_SENTINEL \
                              HOME="$bi_d" "$bundler_bin" config get sch_probe_sentinel 2>/dev/null \
            | grep -E 'Set for the current user' | head -1 | sed 's/.*): *//' | tr -d '\r')
  rm -rf "$bi_d"
  [ "$bi_real" = "true" ] && [ "$bi_sent" = '"true"' ]
}

# ADMISSION fixture: a Gemfile.lock that EXISTS but does not name the gem, so
# this measures the protection actually claimed — "bundler will not resolve
# what the lockfile does not already name" — rather than the weaker "bundler
# refuses when a lockfile is missing". No BUNDLED WITH stanza (2.2.33 emits a
# lockfile-version warning if present).
bundler_fixture() {
  printf 'source "https://rubygems.invalid"\ngem "sch-verify-probe-nonexistent-gem"\n' > "$1/Gemfile" 2>/dev/null || return 1
  printf 'GEM\n  remote: https://rubygems.invalid/\n  specs:\n\nPLATFORMS\n  ruby\n\nDEPENDENCIES\n' > "$1/Gemfile.lock" 2>/dev/null || return 1
}

if [ -z "$bundler_bin" ]; then
  # The common case on ubuntu-24.04 runners, which ship no ruby at all. Both
  # writers create ~/.bundle/config unconditionally, so the file is very often
  # present with nothing on the host that will ever read it. N/A, not OK.
  row "N/A" - "bundler lockfile pinning" "bundler not installed"
elif type requested >/dev/null 2>&1 && ! requested bundler; then
  row "N/A" - "bundler lockfile pinning" "bundler installed but not in the requested ecosystems"
else
  bver=$("$bundler_bin" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+[^ ]*' | head -1)
  bmaj=${bver%%.*}

  # Is `bundle config get` safe to run against the REAL config home?
  # It is a bundler 2.x subcommand. On bundler 1.x `config get frozen` parses
  # as `config <name=get> <value=frozen>` and WRITES `BUNDLE_GET: "frozen"`
  # into $HOME/.bundle/config — the very file the role manages (MEASURED on
  # 1.17.3 + ruby 3.2). A verifier must never mutate what it verifies, and a
  # spurious key would also drive the next Ansible apply to `changed`.
  # Fail closed: an unparseable version (1.17.3 crashes on `--version` under
  # ruby 3.2, so bver is empty) leaves this 0.
  bcfgsafe=0
  if [ -n "$bmaj" ] && [ "$bmaj" -ge 2 ] 2>/dev/null; then bcfgsafe=1; fi

  btmp=$(mktemp -d 2>/dev/null)
  btmp2=$(mktemp -d 2>/dev/null)
  if [ -z "$btmp" ] || [ ! -d "$btmp" ] || [ -z "$btmp2" ] || [ ! -d "$btmp2" ] \
     || ! bundler_fixture "$btmp" || ! bundler_fixture "$btmp2"; then
    rm -rf "$btmp" "$btmp2" 2>/dev/null
    row WEAK PRESENT "bundler lockfile pinning" \
      "could not build a temp fixture to probe bundler ${bver:-unknown}; enforcement not verified"
  else
    # RUN 1 — ambient environment, exactly as this host/job is configured.
    # BUNDLE_GEMFILE pins the fixture so an inherited BUNDLE_GEMFILE cannot
    # redirect us at a real project. BUNDLE_APP_CONFIG is aimed inside the temp
    # dir so the app-local layer cannot contribute AND so bundler 1.x, which
    # persists frozen into the app config during `install` (MEASURED), writes
    # only inside the fixture. --local forbids all network access, so both
    # branches are offline and the rubygems.invalid source is never contacted.
    # `|| true` is correct here and is NOT the Axis-4 anti-pattern: a refusal
    # legitimately exits non-zero (16 on 4.0.19), we never read $? afterwards,
    # and the row is decided on bundler's own message — "assert the security
    # property, not the exit code". It also keeps the block safe if either
    # verifier ever adds `set -e`.
    bout=$(cd "$btmp" && env BUNDLE_GEMFILE="$btmp/Gemfile" \
                             BUNDLE_APP_CONFIG="$btmp/app-config" \
                             BUNDLE_PATH="$btmp/vendor" \
                             BUNDLE_RETRY=0 \
                             "$bundler_bin" install --local 2>&1) || true

    # RUN 2 — the SAME fixture with only the two protection env vars stripped,
    # in a SEPARATE directory (run 1 can leave an app-local config behind on
    # bundler 1.x, which would make run 2 credit our own leftovers).
    # This is the attribution test, and it is FUNCTIONAL rather than parsed:
    # if bundler still refuses with BUNDLE_FROZEN/BUNDLE_DEPLOYMENT out of the
    # environment, a persistent config file is what is enforcing. If it stops
    # refusing, the protection was process-scoped env only — which covers
    # neither cron, nor systemd ExecStart, nor another shell (Axis 2), and must
    # not be reported as deployed hardening. Same shape as the `go env -w` row.
    bstrip=$(cd "$btmp2" && env -u BUNDLE_FROZEN -u BUNDLE_DEPLOYMENT \
                                BUNDLE_GEMFILE="$btmp2/Gemfile" \
                                BUNDLE_APP_CONFIG="$btmp2/app-config" \
                                BUNDLE_PATH="$btmp2/vendor" \
                                BUNDLE_RETRY=0 \
                                "$bundler_bin" install --local 2>&1) || true

    # MEASURED refusal texts, all four tiers, hardened:
    #   4.0.19 / 2.4.19  "...lockfile can't be updated because frozen mode is set"
    #   2.2.33           "You are trying to install in deployment mode after changing"
    #   (lockfile-absent variants, kept for robustness: "The frozen setting
    #    requires a lockfile" / "The deployment setting requires a Gemfile.lock")
    # MEASURED control texts, same fixture, clean HOME, same second:
    #   "Could not find gem '...' in locally installed gems."       (4.0.19)
    #   "Could not find gem '...' in cached gems or installed locally." (2.x)
    # Neither control matches the refusal regex on any tier — that is the
    # FIXTURE CONTROL from design-principles.md Axis 4.
    brx='(frozen|deployment) (setting requires|mode is set|mode after changing)'

    # Which key did bundler NAME? cli/install.rb picks "frozen" when frozen is
    # set and "deployment" otherwise, and which one wins is version-dependent.
    # Asking about the wrong key returns NO source at all, which would strip the
    # path off a correct row.
    bnamed=""
    case "$bout" in
      *"frozen mode is set"*|*"frozen setting requires"*)         bnamed="frozen" ;;
      *"deployment mode after changing"*|*"deployment setting requires"*|*"deployment mode is set"*) bnamed="deployment" ;;
    esac

    # WHICH FILE? Decoration only — the OK/WEAK decision above is made by the
    # two-run control, never by this. ASK BUNDLER rather than assuming
    # ~/.bundle/config: BUNDLE_USER_CONFIG and BUNDLE_USER_HOME both relocate
    # the config home while both writers hardcode $HOME/.bundle/config
    # (design-principles.md, "assumed canonical config homes").
    bpath=""
    if [ "$bcfgsafe" -eq 1 ]; then
      for bk in $bnamed frozen deployment; do
        bsrc=$(cd "$btmp" && env BUNDLE_GEMFILE="$btmp/Gemfile" \
                                 BUNDLE_APP_CONFIG="$btmp/app-config" \
                                 "$bundler_bin" config get "$bk" 2>/dev/null \
               | grep -E 'Set for the current user' | head -1)
        if [ -n "$bsrc" ]; then
          bpath=$(printf '%s\n' "$bsrc" | sed -n 's/.*(\(.*\)).*/\1/p')
          [ -n "$bpath" ] && break
        fi
      done
    fi
    if [ -n "$bpath" ]; then
      bwhere="read from $bpath"
      [ "$bpath" = "$HOME/.bundle/config" ] || \
        bwhere="$bwhere — NOT the \$HOME/.bundle/config both writers deploy to, so the role's own file is dead weight on this host"
    elif [ "$bcfgsafe" -eq 1 ]; then
      bwhere="source file not named by bundler"
    else
      bwhere="source file not named (bundler ${bver:-unknown} has no read-only 'config get'; asking would WRITE BUNDLE_GET into the config file this row exists to verify)"
    fi

    # Which env var was in play, for the env-only row. Read directly rather
    # than via `config get`, so it works on every tier.
    benv=""
    [ -n "${BUNDLE_FROZEN:-}" ]     && benv="BUNDLE_FROZEN"
    [ -n "${BUNDLE_DEPLOYMENT:-}" ] && benv="${benv:+$benv and }BUNDLE_DEPLOYMENT"

    if echo "$bout" | grep -qE "$brx"; then
      if echo "$bstrip" | grep -qE "$brx"; then
        row OK FUNCTIONAL "bundler lockfile pinning" \
          "bundler $bver refused to admit a gem the lockfile does not name, and still refused with BUNDLE_FROZEN/BUNDLE_DEPLOYMENT stripped from the environment, so a config file is enforcing (${bnamed:-frozen/deployment}, $bwhere); Ruby still runs extconf.rb on every native gem"
      elif echo "$bstrip" | grep -qiE 'could not find gem'; then
        row WEAK FUNCTIONAL "bundler lockfile pinning" \
          "bundler $bver refused, but stopped refusing once ${benv:-BUNDLE_FROZEN/BUNDLE_DEPLOYMENT} was stripped from the environment — the protection is process-scoped env only and covers neither cron, systemd ExecStart nor another shell; no config file is enforcing it"
      else
        row WEAK FUNCTIONAL "bundler lockfile pinning" \
          "bundler $bver refused, but the env-stripped control run produced no verdict, so the refusal cannot be attributed to a config file rather than to ${benv:-the environment}: $(echo "$bstrip" | grep -viE 'deprecat|didyoumean|warning:' | head -1 | tr '\t' ' ' | cut -c1-160)"
      fi
    elif echo "$bout" | grep -qiE 'could not find gem'; then
      row GAP FUNCTIONAL "bundler lockfile pinning" \
        "bundler $bver resolved past a lockfile that does not name the gem instead of refusing — frozen/deployment NOT in effect here ($bwhere)"
    else
      # Neither branch fired: bundler did not run the fixture. Establish
      # whether it can be interrogated at all BEFORE blaming the key.
      bi_rc=2
      if [ "$bcfgsafe" -eq 1 ]; then
        if bundler_implements frozen; then bi_rc=0; else bi_rc=$?; fi
      fi
      case "$bi_rc" in
        0) row WEAK PARSED "bundler lockfile pinning" \
             "bundler $bver implements 'frozen' and $bwhere, but the enforcement fixture returned neither a refusal nor a resolution, so enforcement is unproven: $(echo "$bout" | grep -viE 'deprecat|didyoumean|warning:' | head -1 | tr '\t' ' ' | cut -c1-160)" ;;
        1) row GAP PARSED "bundler lockfile pinning" \
             "bundler $bver does not implement the 'frozen' key (echoed our string back verbatim instead of coercing it); upgrade to bundler 2.x or newer" ;;
        *) row WEAK PRESENT "bundler lockfile pinning" \
             "bundler ${bver:-unknown} could not be interrogated — the install fixture produced no verdict and 'config get' is unavailable or unsafe on this version. Infrastructure failure, NOT a finding about frozen: $(echo "$bout" | grep -viE 'deprecat|untaint is deprecated' | head -1 | tr '\t' ' ' | cut -c1-160)" ;;
      esac
    fi
    rm -rf "$btmp" "$btmp2"
  fi

  # --- bundler local config override  [FUNCTIONAL] ---
  # The row above points BUNDLE_APP_CONFIG at an empty temp dir, so it measures
  # the user layer only (its LAYER SCOPE note). Bundler's LOCAL layer -
  # <project>/.bundle/config, or $BUNDLE_APP_CONFIG/config - outranks the
  # environment and ~/.bundle/config. MEASURED (bundler 2.4.20, role applied):
  # in a project whose .bundle/config says BUNDLE_FROZEN: "false",
  # `bundle install --local` resolved past a lockfile that does not name the
  # gem, while the row above printed OK FUNCTIONAL from inside that project.
  # So find the local config bundler would read from $PWD, and rerun the same
  # admission fixture with it in force. Only its BUNDLE_FROZEN and
  # BUNDLE_DEPLOYMENT lines are copied: a project config can also name a
  # gemfile, bundler EVALUATES a Gemfile, and a verifier judging a checkout must
  # not run that checkout's code. This row can only lower the verdict: OK when
  # the local config leaves pinning on, GAP when it switches it off.
  blgf=""; blcfg=""
  if [ -n "${BUNDLE_GEMFILE:-}" ]; then
    case "$BUNDLE_GEMFILE" in /*) blgf=$BUNDLE_GEMFILE ;; *) blgf="$PWD/$BUNDLE_GEMFILE" ;; esac
  else
    # Bundler searches up from the working directory, gems.rb then Gemfile in
    # each directory (Bundler::SharedHelpers#find_gemfile).
    bld=$PWD
    while [ -n "$bld" ]; do
      if [ -f "$bld/gems.rb" ]; then blgf="$bld/gems.rb"; break; fi
      if [ -f "$bld/Gemfile" ]; then blgf="$bld/Gemfile"; break; fi
      [ "$bld" = / ] && break
      bld=${bld%/*}; [ -n "$bld" ] || bld=/
    done
  fi
  blroot=""
  if [ -n "$blgf" ]; then blroot=${blgf%/*}; [ -n "$blroot" ] || blroot=/; fi
  if [ -n "${BUNDLE_APP_CONFIG:-}" ]; then
    case "$BUNDLE_APP_CONFIG" in
      /*) blcfg="$BUNDLE_APP_CONFIG/config" ;;
      *)  [ -n "$blroot" ] && blcfg="$blroot/$BUNDLE_APP_CONFIG/config" ;;
    esac
  elif [ -n "$blroot" ]; then
    blcfg="$blroot/.bundle/config"
  fi
  blhost=0
  [ -n "${bout:-}" ] && [ -n "${brx:-}" ] && printf '%s\n' "$bout" | grep -qE "$brx" && blhost=1
  if [ -z "$blcfg" ]; then
    row "N/A" - "bundler local config override" \
      "no Gemfile or gems.rb at or above $(cq "$PWD") and no BUNDLE_APP_CONFIG - bundler reads no local config here"
  elif [ ! -f "$blcfg" ]; then
    row "N/A" - "bundler local config override" \
      "no local config at $(cq "$blcfg") - nothing here overrides the user config"
  else
    blkeys=$(grep -E "^[\"']?BUNDLE_(FROZEN|DEPLOYMENT)[\"']?[[:space:]]*:" "$blcfg" 2>/dev/null)
    blshow=$(printf '%s' "$blkeys" | tr '\n\t' '  ' | cut -c1-120)
    if [ -z "$blkeys" ]; then
      row "N/A" - "bundler local config override" \
        "$(cq "$blcfg") sets neither BUNDLE_FROZEN nor BUNDLE_DEPLOYMENT, so it cannot switch lockfile pinning off"
    elif [ "$blhost" -ne 1 ]; then
      row "N/A" - "bundler local config override" \
        "lockfile pinning was not shown in effect at the user level either (see bundler lockfile pinning), so there is nothing for $(cq "$blcfg") to switch off"
    else
      bl3=$(mktemp -d 2>/dev/null)
      if [ -z "$bl3" ] || [ ! -d "$bl3" ] || ! bundler_fixture "$bl3" || ! mkdir -p "$bl3/app-config" \
         || ! printf -- '---\n%s\n' "$blkeys" > "$bl3/app-config/config"; then
        row WEAK PRESENT "bundler local config override" \
          "$(cq "$blcfg") sets $(cq "$blshow"), but the probe fixture could not be built, so its effect was not measured"
      else
        blout=$(cd "$bl3" && env BUNDLE_GEMFILE="$bl3/Gemfile" \
                                 BUNDLE_APP_CONFIG="$bl3/app-config" \
                                 BUNDLE_PATH="$bl3/vendor" \
                                 BUNDLE_RETRY=0 \
                                 "$bundler_bin" install --local 2>&1) || true
        if printf '%s\n' "$blout" | grep -qE "$brx"; then
          row OK FUNCTIONAL "bundler local config override" \
            "the local config at $(cq "$blcfg") ($(cq "$blshow")) leaves pinning on: with those lines in force bundler $bver still refused a gem the lockfile does not name"
        elif printf '%s\n' "$blout" | grep -qiE 'could not find gem'; then
          row GAP FUNCTIONAL "bundler local config override" \
            "the local config at $(cq "$blcfg") switches lockfile pinning off ($(cq "$blshow")): with those lines in force bundler $bver resolved past a lockfile that does not name the gem. Bundler's local config outranks BUNDLE_FROZEN in the environment and ~/.bundle/config, so \`bundle install\` and \`bundle add\` in this project are not pinned"
        else
          row WEAK FUNCTIONAL "bundler local config override" \
            "$(cq "$blcfg") sets $(cq "$blshow"), and the fixture run with those lines produced neither a refusal nor a resolution: $(printf '%s\n' "$blout" | grep -viE 'deprecat|didyoumean|warning:' | head -1 | tr '\t' ' ' | cut -c1-160)"
        fi
      fi
      rm -rf "$bl3" 2>/dev/null
    fi
  fi

  # --- bundler publish-age gate  [PARSED] ---
  # cooldown landed in 4.0.13, and needs ruby >= 3.2. The version check has to
  # come first: MEASURED, `bundle config get cooldown` echoes the value on 2.4.20,
  # which ignores it. Asked from $PWD on purpose, because a repo's .bundle/config
  # outranks the environment and the global file (MEASURED on 4.0.24: "0" there
  # disabled the gate with BUNDLE_COOLDOWN set), and this readback does show it.
  # Compared in days the way both writers derive it, floored at 1.
  bwanth=$(scv_want_hours); bwant=""
  case "$bwanth" in
    ''|*[!0-9]*) ;;
    *) bwant=$((bwanth / 24)); [ "$bwant" -lt 1 ] && bwant=1 ;;
  esac
  if [ -z "$bver" ]; then
    row WEAK PRESENT "bundler publish-age gate" "could not read a version from bundler; the gate was not checked"
  elif [ "$(printf '4.0.13\n%s\n' "$bver" | sort -V | head -1)" != "4.0.13" ]; then
    scv_toolchain_gap bundler.age-gate PARSED "bundler publish-age gate" \
      "bundler $bver does NOT implement cooldown (added in 4.0.13, which needs ruby >= 3.2) - the key is written and ignored, and bundler echoes it back anyway. See $(scv_doc docs/composer-bundler-cooldown-by-distro.md)"
  else
    bcd=$("$bundler_bin" config get cooldown --parseable 2>/dev/null | sed -n 's/^cooldown=//p' | head -1)
    # Bundler 4.1 RAISES the configured window to RubyGems' gemrc `:cooldown:`,
    # and --parseable does not show that. MEASURED (4.1.0): with only ~/.gemrc
    # `:cooldown: 3650` this row printed "none is set" while `bundle install`
    # still resolved the older version, and with a repo "0" plus the gemrc it
    # printed "cooldown=0 disables" while the gemrc value applied. Ask bundler
    # for the window it will apply, pinned to the version `bundle` reported;
    # bundler < 4.1 has no cooldown_for and keeps the --parseable answer.
    bcd_src="reports"
    bcd_eff=$(ruby -e 'begin; gem "bundler", ARGV[0]; require "bundler"; s = Bundler.settings; print(s.respond_to?(:cooldown_for) ? s.cooldown_for.to_s : ""); rescue Exception; end' "$bver" 2>/dev/null)
    case "$bcd_eff" in
      ''|*[!0-9]*) ;;
      *) [ "$bcd_eff" != "${bcd:-}" ] && bcd_src="applies (raised by RubyGems' :cooldown:)"
         bcd=$bcd_eff ;;
    esac
    # Does `gem install` share the window? RubyGems 4.1.0 added a cooldown that
    # reads BUNDLE_COOLDOWN, ~/.bundle/config and gemrc `:cooldown:`, taking the
    # larger. MEASURED: it installs an older version inside the window and
    # refuses an exact pin to a too-new one.
    bgv=$(gem --version 2>/dev/null | head -1 | tr -d '\r')
    if [ -n "$bgv" ] && [ "$(printf '4.1.0\n%s\n' "$bgv" | sort -V | head -1)" = "4.1.0" ]; then
      bgem="RubyGems $bgv applies the same window to \`gem install\`/\`gem update\` (it installs an older version; an exact pin to a newer one is refused)"
    else
      bgem="RubyGems ${bgv:-<unknown>} has no cooldown (added in 4.1.0), so \`gem install\` is not age-gated"
    fi
    case "$bcd" in
      '')
        row GAP PARSED "bundler publish-age gate" \
          "bundler $bver implements cooldown but none is set in $(cq "$PWD") - new releases resolve immediately" ;;
      *[!0-9]*)
        row GAP PARSED "bundler publish-age gate" "bundler $bver reports a non-numeric cooldown=$(cq "$bcd")" ;;
      0)
        row GAP PARSED "bundler publish-age gate" \
          "bundler $bver reports cooldown=0 in $(cq "$PWD"), which disables the gate - a repo's .bundle/config outranks BUNDLE_COOLDOWN" ;;
      *)
        if [ -n "$bwant" ] && [ "$bcd" -lt "$bwant" ]; then
          row WEAK PARSED "bundler publish-age gate" \
            "bundler $bver $bcd_src cooldown=${bcd}d, below the ${bwant}d this host declared - something shortened the window"
        else
          row OK PARSED "bundler publish-age gate" \
            "bundler $bver implements cooldown and $bcd_src ${bcd}d - $bgem"
        fi ;;
    esac
  fi
fi

# ======================================================================
# maven
# ======================================================================

# --- maven settings honored  [FUNCTIONAL] ---
# ---------------------------------------------------------------- maven ------
# Maven is asked what IT resolved; nothing here greps a path we picked. One
# offline, hermetic `mvn -X` run in a throwaway project yields the signals:
#   "Reading user settings from <p>"    the file maven ACTUALLY reads - honours
#                                       -s, MAVEN_ARGS and the JVM's user.home,
#                                       none of which $HOME can tell us about
#   "Non-parseable settings"            maven refused the file outright
#   "Using mirror <id> (<url>) for ..." maven overrode a repository we planted
# The probe project declares an http-only repository ON PURPOSE. Commit 474b165
# shipped a maven fixture with no <dependencies>: nothing consulted the mirror
# and the assertion passed against nothing. The difference that makes THIS
# probe safe: that test needed a *resolution* to observe a block, while mirror
# INJECTION happens for every declared repository at project-build time - so
# this needs no dependency, no downloading goal and no network.
MVN_RUN=0; MVN_RC=0; MVN_OUT=""; MVN_SETTINGS=""; MVN_SETTINGS_RAW=""; MVN_VER=""
MVN_MIRROR_LINE=""; MVN_MIRROR_ID=""; MVN_MIRROR_URL=""; MVN_STARTED=0
MVN_PROBE_ID="schv-http-probe"
MVN_EXTRACT_CTL=unknown   # unknown | works | drifted
MVN_INJECT_CTL=unknown    # unknown | logs  | silent

maven_probe_pom() { # $1 = dir
  cat > "$1/pom.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>supply.chain.verify</groupId>
  <artifactId>mirror-probe</artifactId>
  <version>0</version>
  <packaging>pom</packaging>
  <repositories>
    <repository>
      <id>schv-http-probe</id>
      <url>http://repo.invalid.supply-chain-verify/maven2</url>
    </repository>
  </repositories>
</project>
XML
}

# Anything interpolated into a row detail is printed through `printf "$ROWS"`,
# which treats it as a FORMAT string in both verifiers. Maven echoes paths and
# urls we do not control, so strip what corrupts the table.
mvn_safe() { printf '%s' "$1" | tr -d '%\\' | tr '\t' ' ' | cut -c1-200; }

# A hung JVM must not hang the whole verifier, on stock macOS (no timeout(1))
# either: run_bounded.
mvn_run() {
  run_bounded 120 mvn "$@"
}

# The path maven named, with ONE layer of decoration removed. A reformatted
# debug line ('path' or path.) must not turn into "that file does not exist"
# and a red row on a correctly hardened host.
mvn_extract_settings() { # $1 = mvn -X output
  mvn_p=$(printf '%s\n' "$1" | sed -n 's/.*Reading user settings from *//p' | head -1 | tr -d '\r')
  mvn_p=$(printf '%s' "$mvn_p" | sed 's/[[:space:]]*$//')
  # Peel decoration ONLY while that is what makes the path resolve. A path that
  # legitimately ends in a quote or a period is therefore never corrupted, and
  # a wording we cannot peel stays raw and lands in the WEAK drift branch
  # instead of becoming a confident "that file does not exist".
  mvn_c="$mvn_p"
  mvn_i=0
  while [ -n "$mvn_c" ] && [ ! -f "$mvn_c" ] && [ "$mvn_i" -lt 4 ]; do
    mvn_i=$((mvn_i + 1))
    case "$mvn_c" in
      *.) mvn_c=${mvn_c%.} ;;
      [\'\"\`]*) mvn_c=${mvn_c#?} ;;
      *[\'\"\`]) mvn_c=${mvn_c%?} ;;
      *) break ;;
    esac
  done
  [ -n "$mvn_c" ] && [ -f "$mvn_c" ] && mvn_p="$mvn_c"
  printf '%s' "$mvn_p"
}

mvn_path_is_plausible() {
  case "$1" in /*) ;; [A-Za-z]:[/\\]*) ;; *) return 1 ;; esac
  case "$1" in *[\'\"\<\>]*) return 1 ;; esac
  return 0
}

# DISCRIMINATOR 1 - does OUR EXTRACTOR work on THIS maven? Same shape as
# npm_implements(): ask the tool a question whose answer we already know. Hand
# maven a settings file we just wrote, with -s, and see whether the extractor
# recovers a path that resolves to THAT file (matched by a marker inside it, so
# a canonicalised /private/var on macOS still counts). If it cannot round-trip
# a path maven certainly read, then "the file maven named does not exist" is a
# finding about our sed, not about the host - and the row must not go red.
mvn_extraction_works() {
  case "$MVN_EXTRACT_CTL" in works) return 0 ;; drifted) return 1 ;; esac
  MVN_EXTRACT_CTL=drifted
  ptmp=$(mktemp -d 2>/dev/null) || return 1
  maven_probe_pom "$ptmp"
  { echo '<!-- schv-extract-probe -->'
    echo '<settings xmlns="http://maven.apache.org/SETTINGS/1.0.0"/>'; } > "$ptmp/settings.xml"
  pout=$(cd "$ptmp" && mvn_run -X -B -o -s "$ptmp/settings.xml" \
           -Dmaven.repo.local="$ptmp/repo" validate 2>&1)
  pgot=$(mvn_extract_settings "$pout")
  if [ -n "$pgot" ] && [ -f "$pgot" ] && grep -q 'schv-extract-probe' "$pgot" 2>/dev/null; then
    MVN_EXTRACT_CTL=works
  fi
  rm -rf "$ptmp"
  [ "$MVN_EXTRACT_CTL" = works ]
}

# ONE detection predicate. The control below must exercise the IDENTICAL
# matcher, or it only proves that the control's own pattern works. The probe id
# is matched space-delimited and -F: an empty or unanchored pattern would match
# the "for central" line maven emits for mirrorOf=* on every run, which says
# nothing about the repository we planted.
mvn_mirror_line() { # $1 = mvn output, $2 = repository id
  [ -n "${2:-}" ] || return 0
  printf '%s\n' "$1" | grep -i 'using mirror ' | grep -F " $2 " | head -1
}

# Is the mirror maven ACTUALLY APPLIED the blocked one? A file-level grep for
# <blocked> answers a different question and green-lights a plain-http mirror
# sitting beside a blocked one. 0 = blocked, 1 = not blocked, 2 = undetermined.
mvn_mirror_is_blocked() { # $1 = settings file, $2 = mirror id
  [ -f "${1:-}" ] || return 2
  [ -n "${2:-}" ] || return 2
  tr -d '\r\n\t ' < "$1" | awk -v id="<id>$2</id>" '
    { s = $0
      while ((i = index(s, "</mirror>")) > 0) {
        m = substr(s, 1, i - 1); s = substr(s, i + 9)
        if ((j = index(m, "<mirror>")) > 0) m = substr(m, j)
        if (index(m, id) > 0 && index(m, "<blocked>true") > 0) found = 1
      } }
    END { exit(found ? 0 : 1) }'
}

mvn_mirror_declared() { # $1 = settings file, $2 = mirror id
  [ -f "${1:-}" ] && [ -n "${2:-}" ] || return 1
  tr -d '\r\n\t ' < "$1" | awk -v id="<id>$2</id>" '
    { s = $0
      while ((i = index(s, "</mirror>")) > 0) {
        m = substr(s, 1, i - 1); s = substr(s, i + 9)
        if ((j = index(m, "<mirror>")) > 0) m = substr(m, j)
        if (index(m, id) > 0) found = 1
      } }
    END { exit(found ? 0 : 1) }'
}

# File-level, and used ONLY to choose which control to run - never to decide a
# status. Whether the applied mirror is blocked is mvn_mirror_is_blocked's job.
mvn_file_has_blocked() {
  [ -f "${1:-}" ] || return 1
  tr -d '\r\n\t ' < "$1" | grep -q '<blocked>true'
}

# Is the file maven NAMED one this project deploys? Anchored, so a corporate
# "central-https-proxy" or "central-https-legacy" mirror cannot pass as ours.
# This is a grep, but of a path MAVEN chose, not one we assumed.
mvn_settings_is_ours() {
  [ -f "${1:-}" ] || return 1
  mvn_mirror_declared "$1" central-https && return 0
  mvn_mirror_declared "$1" central-https-only && return 0
  grep -q 'ansible-supply-chain-security' "$1" 2>/dev/null && return 0
  grep -q 'supply-chain-harden action' "$1" 2>/dev/null && return 0
  return 1
}

# DISCRIMINATOR 2 - a missing "Using mirror" line has two causes: maven applied
# no mirror to our repository (a real GAP) or this build does not log mirror
# injection at all (log drift -> a FALSE gap). Settle it by re-running the same
# project under a synthetic settings file whose <mirrorOf>*</mirrorOf> MUST
# match, through the SAME mvn_mirror_line() predicate. $1="blocked" replicates
# <blocked> so a blocked mirror logged on a different path cannot be scored as
# a gap.
maven_logs_mirror_injection() {
  case "$MVN_INJECT_CTL" in logs) return 0 ;; silent) return 1 ;; esac
  MVN_INJECT_CTL=silent
  ctl=$(mktemp -d 2>/dev/null) || return 1
  maven_probe_pom "$ctl"
  { echo '<settings xmlns="http://maven.apache.org/SETTINGS/1.0.0">'
    echo '  <mirrors>'
    echo '    <mirror>'
    echo '      <id>schv-control-mirror</id>'
    echo '      <url>https://control.invalid.supply-chain-verify/maven2</url>'
    echo '      <mirrorOf>*</mirrorOf>'
    [ "${1:-}" = blocked ] && echo '      <blocked>true</blocked>'
    echo '    </mirror>'
    echo '  </mirrors>'
    echo '</settings>'; } > "$ctl/settings.xml"
  ctlout=$(cd "$ctl" && mvn_run -X -B -o -s "$ctl/settings.xml" \
             -Dmaven.repo.local="$ctl/repo" validate 2>&1)
  ctlline=$(mvn_mirror_line "$ctlout" "$MVN_PROBE_ID")
  if [ -n "$ctlline" ] && printf '%s\n' "$ctlline" | grep -Fq 'schv-control-mirror'; then
    MVN_INJECT_CTL=logs
  fi
  rm -rf "$ctl"
  [ "$MVN_INJECT_CTL" = logs ]
}

maven_probe() {
  [ "$MVN_RUN" -eq 1 ] && return 0
  MVN_RUN=1
  mtmp=$(mktemp -d 2>/dev/null) || return 1
  maven_probe_pom "$mtmp"
  # -B batch, -o offline (cannot touch the network), -X debug (the only way
  # maven names its settings file and its mirroring), isolated local repo so
  # nothing is written into the user's ~/.m2/repository. `validate` on
  # packaging=pom binds no plugin goals, so nothing is resolved. No -ntp: that
  # flag is 3.6.1+ and older maven aborts on it.
  # THE EXIT CODE IS CAPTURED. It is the one signal that separates "maven
  # aborted on its settings" from "maven warned about them and ran anyway".
  MVN_OUT=$(cd "$mtmp" && mvn_run -X -B -o -Dmaven.repo.local="$mtmp/repo" validate 2>&1); MVN_RC=$?
  rm -rf "$mtmp"
  MVN_SETTINGS_RAW=$(printf '%s\n' "$MVN_OUT" \
    | sed -n 's/.*Reading user settings from *//p' | head -1 | tr -d '\r')
  MVN_SETTINGS=$(mvn_extract_settings "$MVN_OUT")
  # -X prints the version banner first; only start a second JVM if it did not.
  MVN_VER=$(printf '%s\n' "$MVN_OUT" | sed -n 's/.*Apache Maven \([0-9][0-9.]*\).*/\1/p' | head -1)
  [ -n "$MVN_VER" ] || MVN_VER=$(mvn -v 2>/dev/null | sed -n 's/.*Apache Maven \([0-9][0-9.]*\).*/\1/p' | head -1)
  # Did maven get as far as running at all? A broken JVM breaks the control
  # runs too, so every downstream row must degrade instead of reading their
  # silence as a finding about this host.
  printf '%s\n' "$MVN_OUT" | grep -q "Apache Maven \|Reading user settings from" && MVN_STARTED=1
  MVN_MIRROR_LINE=$(mvn_mirror_line "$MVN_OUT" "$MVN_PROBE_ID")
  MVN_MIRROR_ID=$(printf '%s\n' "$MVN_MIRROR_LINE"  | sed -n 's/.*[Uu]sing mirror \([^ ][^ ]*\) .*/\1/p' | head -1)
  MVN_MIRROR_URL=$(printf '%s\n' "$MVN_MIRROR_LINE" | sed -n 's/.*[Uu]sing mirror [^(]*(\([^)]*\)).*/\1/p' | head -1)
  return 0
}

if have mvn && ! requested maven; then
  row "N/A" - "maven" "maven installed but not in the requested ecosystems"
elif have mvn; then
  maven_probe
  # ok | fatal | wrongfile | unknown - rows 2 and 3 consume this verdict so
  # each of them stays honest instead of re-deriving it from our own file.
  mvn_verdict=unknown
  mvn_disp=$(mvn_safe "$MVN_SETTINGS")
  # SEVERITY MATTERS. The bare phrase also appears in maven's WARNING header,
  # which maven prints while APPLYING the file. Context, never a verdict.
  mvn_warn=""
  printf '%s\n' "$MVN_OUT" | grep -qi "problems were encountered while building the effective settings" \
    && mvn_warn=" (maven also reported non-fatal problems with this settings file; at least one element was dropped)"

  # ---- row 1: does maven read, and accept, the file we hardened? ----------
  if [ -z "$MVN_OUT" ]; then
    row WEAK PRESENT "maven settings honored" \
      "mvn is on PATH but produced no output at all - nothing about maven's config could be observed"
  elif [ -z "$MVN_SETTINGS" ] && printf '%s\n' "$MVN_OUT" | grep -q "JAVA_HOME"; then
    row WEAK PRESENT "maven settings honored" \
      "mvn is on PATH but cannot start a JVM (it printed a JAVA_HOME error); nothing about maven's config could be observed"
  elif printf '%s\n' "$MVN_OUT" | grep -qi "non-parseable settings"; then
    mvn_verdict=fatal
    why=$(mvn_safe "$(printf '%s\n' "$MVN_OUT" | grep -i 'non-parseable settings' | head -1)")
    hint=""
    printf '%s\n' "$why" | grep -qi "blocked" && \
      hint=" <blocked> needs maven >= 3.8.0; maven ${MVN_VER:-?} treats it as an unrecognised tag and rejects the whole file."
    row GAP FUNCTIONAL "maven settings honored" \
      "maven ${MVN_VER:-?} REFUSES its settings file, so no maven hardening applies and every mvn run on this host fails: ${why}${hint}"
  elif printf '%s\n' "$MVN_OUT" | grep -Eqi '^\[(FATAL|ERROR)\].*(effective settings|processing the settings)'; then
    mvn_verdict=fatal
    row GAP FUNCTIONAL "maven settings honored" \
      "maven ${MVN_VER:-?} failed at ERROR level building the effective settings - the hardened settings.xml is not being applied"
  elif [ -n "$mvn_warn" ] && [ "$MVN_RC" -ne 0 ] && [ -z "$MVN_MIRROR_LINE" ]; then
    mvn_verdict=fatal
    row GAP FUNCTIONAL "maven settings honored" \
      "maven ${MVN_VER:-?} exited $MVN_RC after reporting problems building the effective settings, and applied no mirror - the hardened settings.xml is not being applied"
  elif [ -z "$MVN_SETTINGS" ]; then
    row WEAK PRESENT "maven settings honored" \
      "maven ${MVN_VER:-(version unknown)} did not log 'Reading user settings from' under -X; which settings file it reads cannot be confirmed${mvn_warn}"
  elif [ ! -f "$MVN_SETTINGS" ]; then
    if mvn_path_is_plausible "$MVN_SETTINGS" && mvn_extraction_works; then
      mvn_verdict=wrongfile
      row GAP FUNCTIONAL "maven settings honored" \
        "maven ${MVN_VER:-?} resolves user settings to $mvn_disp, which does not exist - the hardened file is somewhere maven never looks${mvn_warn}"
    else
      row WEAK PRESENT "maven settings honored" \
        "maven ${MVN_VER:-?} logged a settings location this probe could not turn back into a file ('$(mvn_safe "$MVN_SETTINGS_RAW")'), and a control run with -s shows this build's wording is not one we parse - log-format drift, not a proven gap"
    fi
  elif ! mvn_settings_is_ours "$MVN_SETTINGS"; then
    mvn_verdict=wrongfile
    row GAP FUNCTIONAL "maven settings honored" \
      "maven ${MVN_VER:-?} reads user settings from $mvn_disp, which carries none of the mirror ids or markers this project deploys - our settings.xml is not the file maven uses${mvn_warn}"
  elif [ -n "$MVN_MIRROR_ID" ] && mvn_mirror_declared "$MVN_SETTINGS" "$MVN_MIRROR_ID"; then
    # STRONGEST FORM. maven naming a mirror id in the act of applying it to a
    # repository it resolved is maven reporting our file's CONTENT back - not
    # a key echoed at us, and not the absence of an error message.
    mvn_verdict=ok
    row OK FUNCTIONAL "maven settings honored" \
      "maven ${MVN_VER:-?} resolved user settings to $mvn_disp, that file is one this project deploys, and maven applied mirror '$(mvn_safe "$MVN_MIRROR_ID")' declared in it to a planted repository${mvn_warn}"
  else
    # Identity established (maven named the path; that file carries a mirror id
    # or marker this project deploys) but no observed effect: PARSED, not
    # FUNCTIONAL. Acceptance rests on maven's strict settings parser having
    # raised no error, which is weaker than watching maven act.
    mvn_verdict=ok
    row OK PARSED "maven settings honored" \
      "maven ${MVN_VER:-?} resolved user settings to $mvn_disp and that file is one this project deploys; maven raised no settings error, but it named no mirror of its own for the planted repository, so acceptance rests on maven's parser rather than on observed behaviour (see the mirroring row)${mvn_warn}"
  fi
else
  row "N/A" - "maven" "mvn not installed"
fi

# --- maven http repo mirroring  [FUNCTIONAL] ---
if have mvn && ! requested maven; then
  row "N/A" - "maven http repo mirroring" "maven installed but not in the requested ecosystems"
elif have mvn; then
  # ---- row 2: is a planted http:// repository actually overridden? --------
  # Requires the maven preamble from the "maven settings honored" probe above;
  # every shared reference is :- guarded so a partial paste degrades instead of
  # dying under set -u. There is NO file-level <blocked> grep here: whether the
  # mirror maven applied is blocked is asked of THAT mirror by id.
  mvn_lt38=0
  case "${MVN_VER:-}" in
    *.*) mvn_v=${MVN_VER}; mvn_maj=${mvn_v%%.*}; mvn_rest=${mvn_v#*.}; mvn_min=${mvn_rest%%.*}
         case "$mvn_maj$mvn_min" in
           ''|*[!0-9]*) ;;
           *) if [ "$mvn_maj" -lt 3 ] || { [ "$mvn_maj" -eq 3 ] && [ "$mvn_min" -lt 8 ]; }; then mvn_lt38=1; fi ;;
         esac ;;
  esac
  # Two 3.8.0-era features live in these files and fail DIFFERENTLY on older
  # maven: <blocked> is a TAG, so a strict parser rejects the whole file and
  # says so; external:http:* is a VALUE, which the parser cannot reject - older
  # maven compares it as a literal repository id and it silently matches
  # nothing. The second is why this hint is attached to the silence branches.
  mvn_tier_hint=""
  if [ "$mvn_lt38" -eq 1 ] && [ -f "${MVN_SETTINGS:-}" ] \
     && tr -d '\r\n\t ' < "${MVN_SETTINGS}" 2>/dev/null | grep -Fq -e '<blocked>true' -e '<mirrorOf>external:http:*'; then
    mvn_tier_hint=" NOTE: that settings file uses <blocked> and/or mirrorOf external:http:*, both maven >= 3.8.0; on maven ${MVN_VER:-?} <blocked> is an unrecognised tag and external:http:* is compared as a literal repository id, matching nothing."
  fi

  if [ -z "${MVN_OUT:-}" ] || [ "${MVN_STARTED:-0}" -eq 0 ]; then
    row WEAK PRESENT "maven http repo mirroring" \
      "maven never started (no JVM, or it died before reading its settings), so neither the probe nor its control could exercise a mirror"
  elif [ "${mvn_verdict:-unknown}" = fatal ]; then
    row GAP FUNCTIONAL "maven http repo mirroring" \
      "maven does not accept its settings file at all (see the settings row), so no mirror from it applies to anything and an attacker-declared http:// repository is fetched as written${mvn_tier_hint}"
  elif [ -n "${MVN_MIRROR_LINE:-}" ] && { [ -z "${MVN_MIRROR_ID:-}" ] || [ -z "${MVN_MIRROR_URL:-}" ]; }; then
    row WEAK PRESENT "maven http repo mirroring" \
      "maven ${MVN_VER:-} named a mirror for the planted http:// repository but this build's wording does not yield an id and a url ('$(mvn_safe "${MVN_MIRROR_LINE}")'), so the replacement cannot be inspected"
  elif [ -n "${MVN_MIRROR_LINE:-}" ]; then
    # The mirror maven CHOSE, by id, checked against the file maven NAMED.
    mvn_mirror_is_blocked "${MVN_SETTINGS:-}" "${MVN_MIRROR_ID}"; mvn_bl=$?
    mvn_src=""
    [ "${mvn_verdict:-unknown}" != ok ] && mvn_src=" NOTE: this mirror is NOT attributable to a settings file this project deploys - maven resolved its user settings to ${mvn_disp:-a location this probe could not identify} (see the settings row), so the mirror may come from a corporate file or from the global \${maven.home}/conf/settings.xml"
    case "${MVN_MIRROR_URL}" in
      https://*|file:*)
        if [ "$mvn_bl" -eq 0 ]; then
          row OK FUNCTIONAL "maven http repo mirroring" \
            "maven ${MVN_VER:-} applied mirror '$(mvn_safe "$MVN_MIRROR_ID")' to a planted http:// repository, and THAT mirror carries <blocked>true in the file maven read, so the http url is never fetched. The refusal itself is not exercised here - this run resolves nothing; .github/workflows/action-smoke.yml does observe it${mvn_src}"
        else
          row OK FUNCTIONAL "maven http repo mirroring" \
            "maven ${MVN_VER:-} redirected a planted http:// repository to $(mvn_safe "$MVN_MIRROR_URL") via mirror '$(mvn_safe "$MVN_MIRROR_ID")' - the http url is never fetched${mvn_src}"
        fi ;;
      http://*)
        if [ "$mvn_bl" -eq 0 ]; then
          row WEAK PRESENT "maven http repo mirroring" \
            "maven ${MVN_VER:-} applied mirror '$(mvn_safe "$MVN_MIRROR_ID")' to the planted http:// repository; that mirror is <blocked> so its own plain-http url $(mvn_safe "$MVN_MIRROR_URL") should never be fetched, but this probe resolves nothing and cannot confirm the refusal${mvn_src}"
        else
          row GAP FUNCTIONAL "maven http repo mirroring" \
            "maven ${MVN_VER:-} mirrors the planted http:// repository to $(mvn_safe "$MVN_MIRROR_URL") via '$(mvn_safe "$MVN_MIRROR_ID")', itself plain http and not <blocked> - traffic is redirected, not secured${mvn_src}"
        fi ;;
      *)
        row WEAK PRESENT "maven http repo mirroring" \
          "maven ${MVN_VER:-} applied mirror '$(mvn_safe "$MVN_MIRROR_ID")' to the planted http:// repository but its url ('$(mvn_safe "$MVN_MIRROR_URL")') is neither http nor https, so the replacement cannot be confirmed${mvn_src}" ;;
    esac
  elif maven_logs_mirror_injection "$(mvn_file_has_blocked "${MVN_SETTINGS:-}" && echo blocked)"; then
    row GAP FUNCTIONAL "maven http repo mirroring" \
      "maven ${MVN_VER:-} applied NO mirror to a planted external http:// repository, and a control settings file whose mirror MUST match proves this build does log mirror injection - an attacker-declared http repo is fetched as written${mvn_tier_hint}"
  else
    row WEAK PRESENT "maven http repo mirroring" \
      "maven ${MVN_VER:-} never names mirror injection in its -X output, not even for a control mirror that cannot fail to match, so 'no mirror applied' cannot be told apart from 'not logged'${mvn_tier_hint}"
  fi
fi

# --- maven strict checksums  [PARSED] ---
if have mvn && ! requested maven; then
  row "N/A" - "maven strict checksums" "maven installed but not in the requested ecosystems"
elif have mvn; then
  # ---- row 3: strict checksums (both surfaces write them) -----------------
  # Requires the maven preamble from the "maven settings honored" probe.
  # Which profile ids actually carry <checksumPolicy>fail. A file-level grep
  # would green-light a policy sitting in a profile that never activates.
  mvn_fail_profiles() { # $1 = settings file
    [ -f "${1:-}" ] || return 1
    tr -d '\r\n\t ' < "$1" | awk '
      { s = $0
        while ((i = index(s, "</profile>")) > 0) {
          m = substr(s, 1, i - 1); s = substr(s, i + 10)
          if ((j = index(m, "<profile>")) > 0) m = substr(m, j)
          if (index(m, "<checksumPolicy>fail") > 0) {
            k = index(m, "<id>")
            if (k > 0) { r = substr(m, k + 4); e = index(r, "</id>"); if (e > 0) print substr(r, 1, e - 1) }
          }
        } }'
  }
  # Does any <pluginRepository> in this text carry <checksumPolicy>fail? Maven
  # keeps TWO repository lists and the super POM declares central in both, so a
  # policy under <repositories> alone leaves plugin jars - code that runs inside
  # the build - on the default warn. MEASURED (maven 3.9.11): a plugin jar
  # served under a wrong .sha1 was installed with two WARNINGs while a
  # dependency jar under the same settings failed the build. $1 = file, or - for stdin
  mvn_plugin_fail() {
    if [ "${1:-}" = - ]; then cat; else [ -f "${1:-}" ] && cat "$1"; fi 2>/dev/null \
      | tr -d '\r\n\t ' | awk '
      { s = $0
        while ((i = index(s, "</pluginRepository>")) > 0) {
          m = substr(s, 1, i - 1); s = substr(s, i + 19)
          if ((j = index(m, "<pluginRepository>")) > 0) m = substr(m, j)
          if (index(m, "<checksumPolicy>fail") > 0) found = 1
        } }
      END { exit(found ? 0 : 1) }'
  }

  if [ "${MVN_STARTED:-0}" -eq 0 ]; then
    row WEAK PRESENT "maven strict checksums" \
      "maven never started, so nothing about its checksum policy could be observed"
  elif [ "${mvn_verdict:-unknown}" = fatal ]; then
    row GAP FUNCTIONAL "maven strict checksums" \
      "maven does not accept the settings file it read (see the settings row), so any <checksumPolicy> in it is inert; maven falls back to its default, warn"
  elif [ "${mvn_verdict:-unknown}" = unknown ]; then
    row WEAK PRESENT "maven strict checksums" \
      "the settings file maven reads could not be identified, so its checksum policy is unknown"
  elif [ ! -f "${MVN_SETTINGS:-}" ] \
    || ! tr -d '\r\n\t ' < "${MVN_SETTINGS}" 2>/dev/null | grep -Fq '<checksumPolicy>fail'; then
    row GAP FUNCTIONAL "maven strict checksums" \
      "the settings file maven reads (${mvn_disp:-?}) sets no <checksumPolicy>fail; maven's default is warn, so a checksum mismatch prints a warning and the build continues"
  else
    # Upgrade attempt. maven-help-plugin re-serialises maven's OWN merged
    # settings model, so a value in its output round-tripped through that model
    # instead of being read out of our file. Offline: it can only succeed from
    # an already-cached plugin and can never reach the network. It deliberately
    # uses the REAL local repository - that is where a cached plugin lives.
    mvn_prof_fail=$(mvn_fail_profiles "${MVN_SETTINGS}" | tr '\n' ' ' | sed 's/ *$//')
    eff=""; erc=1; act=""; arc=1
    etmp=$(mktemp -d 2>/dev/null) && {
      maven_probe_pom "$etmp"
      eff=$(cd "$etmp" && mvn_run -B -o help:effective-settings 2>&1); erc=$?
      case "$eff" in
        *"<checksumPolicy>"*) act=$(cd "$etmp" && mvn_run -B -o help:active-profiles 2>&1); arc=$? ;;
      esac
      rm -rf "$etmp"
    }
    mvn_eff_fail=0
    printf '%s\n' "$eff" | tr -d ' \t' | grep -Fq '<checksumPolicy>fail' && mvn_eff_fail=1
    mvn_prof_active=""
    if [ "$arc" -eq 0 ]; then
      # Exact id match on maven's own list ("  - <id> (source: ...)"), never a
      # substring: a profile called "central" would otherwise match half the
      # output. A wording change makes this fail closed - WEAK, not a green row.
      for mvn_pf in $mvn_prof_fail; do
        if printf '%s\n' "$act" | awk -v want="$mvn_pf" \
             '{ sub(/^[[:space:]]*-[[:space:]]*/, ""); if ($1 == want) found = 1 }
              END { exit(found ? 0 : 1) }'; then
          mvn_prof_active="$mvn_pf"; break
        fi
      done
    fi
    mvn_plug_note=""
    mvn_plugin_fail "${MVN_SETTINGS}" \
      || mvn_plug_note="; that file also sets no <checksumPolicy>fail on any <pluginRepository>, so plugin jars - code that runs inside the build - keep maven's default warn"
    if [ "$erc" -ne 0 ]; then
      row WEAK PRESENT "maven strict checksums" \
        "<checksumPolicy>fail is in the file maven reads and maven parsed that file, but maven-help-plugin could not run offline (exit $erc), so nothing reports the EFFECTIVE policy, and no read-only probe can stage a checksum mismatch${mvn_plug_note}"
    elif [ "$mvn_eff_fail" -eq 0 ]; then
      row GAP FUNCTIONAL "maven strict checksums" \
        "maven's own merged settings model, read back with help:effective-settings, carries no <checksumPolicy>fail even though ${mvn_disp:-the file maven reads} declares one - the policy did not survive maven's settings merge"
    elif [ -z "$mvn_prof_fail" ]; then
      row WEAK PRESENT "maven strict checksums" \
        "maven reports checksumPolicy=fail out of its merged settings model, but this probe could not tell which profile carries it, so it could not confirm that profile is active"
    elif [ -n "$mvn_prof_active" ] && ! printf '%s\n' "$eff" | mvn_plugin_fail -; then
      row WEAK PARSED "maven strict checksums" \
        "DEPENDENCIES ONLY: maven reports checksumPolicy=fail out of its merged settings model and help:active-profiles names '$(mvn_safe "$mvn_prof_active")' active, but no <pluginRepository> in that model carries it - plugin jars, code that runs inside the build, keep maven's default warn and are installed despite a checksum mismatch"
    elif [ -n "$mvn_prof_active" ]; then
      row OK PARSED "maven strict checksums" \
        "maven reports checksumPolicy=fail for repositories AND plugin repositories out of its own merged settings model, and help:active-profiles names '$(mvn_safe "$mvn_prof_active")' active - SCOPE: this binds only the repository ids that profile declares (central). A repository a project declares itself keeps maven's default warn, and under a catch-all mirror (mirrorOf=*) maven merges it with central and keeps the WEAKER policy, so one extra project repository puts central back on warn (MEASURED, maven 3.9.11). Nothing here observes a checksum mismatch aborting a build"
    else
      row WEAK PRESENT "maven strict checksums" \
        "maven reports a checksumPolicy=fail in its merged settings, but help:effective-settings prints INACTIVE profiles too and maven did not confirm profile(s) '$(mvn_safe "$mvn_prof_fail")' active (help:active-profiles exit $arc), so the policy may bind nothing"
    fi
  fi
fi

# ======================================================================
# gradle
# ======================================================================

# --- gradle HTTPS-only repos  [FUNCTIONAL] ---
# ---------------------------------------------------------------- gradle -----
# Gradle's hardening is an init SCRIPT, not a key/value file: the role writes
# $GRADLE_USER_HOME/init.d/supply-chain-security.gradle (Groovy) and harden.sh
# writes $GRADLE_USER_HOME/init.gradle.kts (Kotlin). Both refuse an http://
# repository in all four repository containers (ECH-171), and both call
# failOnDynamicVersions()/failOnChangingVersions() on project configurations AND
# on the buildscript / settings script classpaths that plugins resolve into
# (CMP 4.6); the role's script guards those calls with respondsTo(), the
# action's does not (tasks/gradle.yml, action/harden.sh harden_gradle).
#
# Three things follow, and they shape the whole probe.
#
# 1. There is no `gradle config get` -- but there is also no accepted-and-
#    ignored failure mode, because the config is CODE: a method gradle does not
#    implement is a hard evaluation error that fails EVERY build on the host.
#    MEASURED. So npm_implements() has no analogue here and needs none; its
#    inverse is the risk, and the probe has a branch for it.
# 2. `gradle dependencies` REPORTS an unresolved graph and exits 0 (474b165).
#    The only honest evidence is a real resolve(). This probe forces one from a
#    file:// repo it writes itself, so it stays entirely offline.
# 3. Gradle has FOUR http-capable repository containers: project
#    repositories, buildscript{} (the plugin classpath), and the settings
#    pluginManagement{} and dependencyResolutionManagement{}. Until ECH-171
#    (bb5446d) both writers hooked only project.repositories, and only maven
#    repos, so this probe measured the other three, and ivy, as ADDED on gradle
#    8.14.3. Both writers now hook all four, maven and ivy alike (ECH-171,
#    verified per scope on 8.14.3), with one difference: the role's settings
#    hook sits behind respondsTo('beforeSettings') (tasks/gradle.yml), so on a
#    gradle without beforeSettings (older than 6) the role covers project and
#    buildscript repositories only; the action's Kotlin init script calls
#    beforeSettings unguarded. The probe still baits all four, because
#    "HTTPS-only repos" is what the row is NAMED, and a plugin jar fetched over
#    http from buildscript{} executes at configuration time.
#
# CAVEATS this probe cannot remove, documented rather than papered over:
#   - Running gradle at all populates $GRADLE_USER_HOME/{caches,native,daemon}.
#     That is unavoidable: gradle's DISCOVERY of the init script from the home
#     IT resolves is half of what is under test, so -g cannot be used. If an
#     operator runs /usr/local/bin/supply-chain-verify under sudo -E with a
#     shared GRADLE_USER_HOME (a CI cache volume), those entries land root-
#     owned and can break the next user build. Plain `sudo` is safe: HOME=/root
#     makes gradle use root's own home.
#   - `timeout` bounds the JVM where it exists; macOS often ships none, so on
#     such a host a hostile/unreachable host init script can still hang the
#     verifier, which tasks/verify.yml runs synchronously.
#
# --- shared gradle probe machinery (this identical block appears in both -----
# --- gradle sections; redefining the functions is harmless, and -------------
# --- gradle_probe_once() guarantees the JVM starts at most ONCE per run) ----
GRADLE_OUT="${GRADLE_OUT:-}"
GRADLE_RC="${GRADLE_RC:-1}"
GRADLE_DONE="${GRADLE_DONE:-0}"
GRADLE_VER="${GRADLE_VER:-}"
GRADLE_VER_DONE="${GRADLE_VER_DONE:-0}"

gradle_probe() {
  # Builds a throwaway gradle project in a temp dir and asks GRADLE for the
  # facts, in gradle's own words. Fully offline: every repository container is
  # CLEARED before resolution and the only repo resolved from is a file:// repo
  # it just wrote. Prints marker lines.
  local tmp r rc
  tmp=$(mktemp -d 2>/dev/null) || return 1
  mkdir -p "$tmp/repo/com/example/probe/1.0" 2>/dev/null || { rm -rf "$tmp"; return 1; }
  r="$tmp/repo/com/example/probe"
  cat > "$r/maven-metadata.xml" <<'SCEOF'
<?xml version="1.0" encoding="UTF-8"?>
<metadata>
  <groupId>com.example</groupId>
  <artifactId>probe</artifactId>
  <versioning>
    <latest>1.0</latest><release>1.0</release>
    <versions><version>1.0</version></versions>
    <lastUpdated>20200101000000</lastUpdated>
  </versioning>
</metadata>
SCEOF
  cat > "$r/1.0/probe-1.0.pom" <<'SCEOF'
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>com.example</groupId>
  <artifactId>probe</artifactId>
  <version>1.0</version>
  <packaging>jar</packaging>
</project>
SCEOF
  # A valid empty zip: EOCD is exactly 22 bytes (PK\005\006 + 18 zero bytes).
  printf 'PK\005\006\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000' \
    > "$r/1.0/probe-1.0.jar"
  cat > "$tmp/settings.gradle" <<'SCEOF'
rootProject.name = 'sc-probe'
// Baits #1 and #2: the two SETTINGS-level repository containers. Before
// ECH-171 (bb5446d) neither writer hooked them (MEASURED on 8.14.3 with each
// writer's file: ADDED); both now do, through beforeSettings.
// The property form (not the pluginManagement{} block) is used deliberately:
// it is legal after rootProject.name, and a throw from the hook is CAUGHT
// here rather than aborting settings evaluation. MEASURED both ways.
gradle.ext.scPm = 'ADDED'
try { pluginManagement.repositories.maven { url = uri('http://127.0.0.1:9/sc-pm-http') } }
catch (Throwable t) { gradle.ext.scPm = 'BLOCKED' }
try { pluginManagement.repositories.clear() } catch (Throwable t) { }
gradle.ext.scDm = 'ADDED'
try { dependencyResolutionManagement.repositories.maven { url = uri('http://127.0.0.1:9/sc-dm-http') } }
catch (Throwable t) { gradle.ext.scDm = 'BLOCKED' }
try { dependencyResolutionManagement.repositories.clear() } catch (Throwable t) { }
println "SCP_PMREPO=${gradle.ext.scPm}"
println "SCP_DMREPO=${gradle.ext.scDm}"
SCEOF
  cat > "$tmp/build.gradle" <<'SCEOF'
def sc = [:]
// Bait #3: an http:// MAVEN repo in project.repositories -- the one container
// both writers hooked before ECH-171. MEASURED: with no init script gradle ACCEPTS it here
// (gradle's own insecure-protocol refusal fires later, at RESOLUTION), so a
// BLOCKED verdict cannot be manufactured by gradle's built-in behaviour.
sc.http = 'ADDED'
sc.httpmsg = ''
try { repositories { maven { url = uri('http://127.0.0.1:9/sc-probe-http') } } }
catch (Throwable t) { sc.http = 'BLOCKED'; sc.httpmsg = String.valueOf(t.message) }
// Bait #4: an http:// IVY repo in the SAME container. Before ECH-171 both
// writers tested only `instanceof MavenArtifactRepository`, so ivy slipped
// past (MEASURED ADDED); both now test IvyArtifactRepository too.
sc.ivy = 'ADDED'
try { repositories { ivy { url = uri('http://127.0.0.1:9/sc-ivy-http') } } }
catch (Throwable t) { sc.ivy = 'BLOCKED' }
// Bait #5: buildscript.repositories -- the PLUGIN CLASSPATH container, where
// gradle fetches jars it then EXECUTES at configuration time. A different
// container from project.repositories; neither writer hooked it before ECH-171
// (MEASURED ADDED); both now do.
sc.bs = 'ADDED'
try { buildscript { repositories { maven { url = uri('http://127.0.0.1:9/sc-bs-http') } } } }
catch (Throwable t) { sc.bs = 'BLOCKED' }
// Clear both containers outright: no bait can be contacted, and no repository
// a host init script injected can drag resolution onto the network either.
try { buildscript.repositories.clear() } catch (Throwable t) { }
repositories.clear()
repositories { maven { url = uri(new File(rootDir, 'repo').toURI().toString()) } }
configurations { scStatic; scDyn }
dependencies {
    scStatic 'com.example:probe:1.0'
    scDyn    'com.example:probe:1.+'
}
def flat = { s -> String.valueOf(s).replaceAll('[\\r\\n\\t]+', ' ') }
def chain = { Throwable t ->
    def sb = new StringBuilder(); def c = t
    while (c != null) { sb.append(' | ').append(String.valueOf(c.message)); c = c.cause }
    sb.toString()
}
sc.dynflag = 'UNKNOWN'; sc.chgflag = 'UNKNOWN'; sc.bsdynflag = 'UNKNOWN'
try { sc.dynflag = String.valueOf(configurations.scDyn.resolutionStrategy.failingOnDynamicVersions) } catch (Throwable t) { }
try { sc.chgflag = String.valueOf(configurations.scDyn.resolutionStrategy.failingOnChangingVersions) } catch (Throwable t) { }
try { sc.bsdynflag = String.valueOf(buildscript.configurations.classpath.resolutionStrategy.failingOnDynamicVersions) } catch (Throwable t) { }
// FIXTURE CONTROL: the STATIC coordinate must resolve from the same repo. If
// it does not, the fixture is broken and no refusal below is enforcement.
sc.stat = 'FAIL'; sc.statmsg = ''
try { configurations.scStatic.resolve(); sc.stat = 'OK' } catch (Throwable t) { sc.statmsg = chain(t) }
// BEHAVIOURAL half, project configurations: a real resolve().
sc.dyn = 'RESOLVED'; sc.dynmsg = ''
try { configurations.scDyn.resolve() } catch (Throwable t) { sc.dyn = 'REFUSED'; sc.dynmsg = chain(t) }
// BEHAVIOURAL half, PLUGIN CLASSPATH: the same dynamic selector on
// buildscript.configurations.classpath -- a dynamic plugin version is remote
// code chosen at build time. Its own successful resolve is its fixture control.
// Gradle 9 may not run this half. With an init script that configures
// buildscript.configurations (both writers do, since CMP 4.6), 9.1.0 refuses
// the mutation: "Cannot mutate the dependencies of configuration 'classpath'
// after the configuration was resolved"; creating a fresh configuration in
// the container is refused too. With the 8281a6b scripts, which leave the
// script classpath alone, 9.1.0 allowed it and RESOLVED 1.+. MEASURED both.
// That throw is NOT a refusal of the dynamic selector; the row tells the two
// apart by the message and falls back to the flag readback.
sc.bsdyn = 'RESOLVED'; sc.bsdynmsg = ''
try {
    buildscript.repositories { maven { url = uri(new File(rootDir, 'repo').toURI().toString()) } }
    buildscript.dependencies.add('classpath', 'com.example:probe:1.+')
    buildscript.configurations.classpath.resolve()
} catch (Throwable t) { sc.bsdyn = 'REFUSED'; sc.bsdynmsg = chain(t) }
println "SCP_VER=${gradle.gradleVersion}"
println "SCP_GUH=${gradle.gradleUserHomeDir}"
println "SCP_UHOME=${System.getProperty('user.home')}"
println "SCP_INIT=${gradle.startParameter.allInitScripts.collect{ it.toString() }.join(' ; ')}"
println "SCP_HTTP=${sc.http}"
println "SCP_HTTPMSG=${flat(sc.httpmsg)}"
println "SCP_IVY=${sc.ivy}"
println "SCP_BS=${sc.bs}"
println "SCP_DYNFLAG=${sc.dynflag}"
println "SCP_CHGFLAG=${sc.chgflag}"
println "SCP_BSDYNFLAG=${sc.bsdynflag}"
println "SCP_STATIC=${sc.stat}"
println "SCP_STATICMSG=${flat(sc.statmsg)}"
println "SCP_DYN=${sc.dyn}"
println "SCP_DYNMSG=${flat(sc.dynmsg)}"
println "SCP_BSDYN=${sc.bsdyn}"
println "SCP_BSDYNMSG=${flat(sc.bsdynmsg)}"
println "SCP_END=1"
tasks.register('scProbe') { doLast { } }
SCEOF
  # No --init-script and no -g: gradle discovering our file from the
  # GRADLE_USER_HOME IT resolves is half of what is under test. (The smoke test
  # at action-smoke.yml:687 passes --init-script explicitly and therefore does
  # NOT test discovery.)
  # Bounded (run_bounded, timeout(1) or not): a host init script that resolves
  # plugins from an unreachable network must not hang the verifier. A stop
  # comes back as 124, which the caller reports as a timeout.
  ( cd "$tmp" && run_bounded 180 gradle --no-daemon -q --console=plain scProbe 2>&1 )
  rc=$?
  rm -rf "$tmp"
  return "$rc"
}

# Memoised on a RAN flag, not on output-emptiness: a gradle that dies printing
# nothing would otherwise be probed once per block.
gradle_probe_once() {
  [ "$GRADLE_DONE" -eq 1 ] && return 0
  GRADLE_OUT=$(gradle_probe)
  GRADLE_RC=$?
  GRADLE_DONE=1
  return 0
}

gradle_field() { printf '%s\n' "$GRADLE_OUT" | grep "^$1=" | head -1 | sed "s/^$1=//"; }

# Tool text ends up in a row detail. ROWS is TAB-delimited and the renderer
# passes it to printf as a FORMAT string, so strip % and \ and tabs.
gradle_san() { printf '%s' "$1" | tr -d '%\\' | tr '\t' ' ' | cut -c1-160; }

gradle_facts() {
  gend=$(gradle_field SCP_END)
  gver=$(gradle_field SCP_VER)
  if [ -z "$gver" ]; then
    # `gradle --version` does not evaluate init scripts, so it still answers
    # when a broken init script is failing every real build. Cached so it too
    # runs at most once per verifier run.
    if [ "$GRADLE_VER_DONE" -eq 0 ]; then
      GRADLE_VER=$(gradle --version 2>/dev/null | sed -n 's/^Gradle \([0-9][0-9.]*\).*/\1/p' | head -1)
      GRADLE_VER_DONE=1
    fi
    gver="$GRADLE_VER"
  fi
  gver="${gver:-unknown}"
  gguh=$(gradle_field SCP_GUH)
  ginit=$(gradle_field SCP_INIT)
  ghttp=$(gradle_field SCP_HTTP)
  ghmsg=$(gradle_field SCP_HTTPMSG)
  gdyn=$(gradle_field SCP_DYN)
  gdmsg=$(gradle_field SCP_DYNMSG)
  gdflag=$(gradle_field SCP_DYNFLAG)
  gstat=$(gradle_field SCP_STATIC)
  gerr=$(printf '%s\n' "$GRADLE_OUT" | grep -v '^[[:space:]]*$' | head -3 | tr '\n' ' ')
  # Which of the FOUR http-capable repository containers accepted the bait.
  gopen=""
  [ "$(gradle_field SCP_BS)" = "ADDED" ]     && gopen="$gopen buildscript{} plugin classpath,"
  [ "$(gradle_field SCP_PMREPO)" = "ADDED" ] && gopen="$gopen settings pluginManagement,"
  [ "$(gradle_field SCP_DMREPO)" = "ADDED" ] && gopen="$gopen settings dependencyResolutionManagement,"
  [ "$(gradle_field SCP_IVY)" = "ADDED" ]    && gopen="$gopen ivy{} repositories,"
  # ATTRIBUTION, from gradle's own discovery report. Sound direction: any init
  # script that is NOT one of ours forces a downgrade, so a third-party script
  # can never be credited to this project. Never used to manufacture an OK.
  gforeign=$(printf '%s\n' "$ginit" | tr ';' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
             | grep -v '^$' | grep -v '/supply-chain-security\.gradle$' \
             | grep -v '/init\.gradle\.kts$' | tr '\n' ' ')
  gours=no
  printf '%s\n' "$ginit" | grep -q -e '/supply-chain-security\.gradle' -e '/init\.gradle\.kts' && gours=yes
  # Did a script of OURS actually EXECUTE this run? Behavioural, not a path
  # test: only our init scripts throw with these exact strings.
  gmine=no
  case "$ghmsg" in
    *"Insecure HTTP repository blocked"*|*"supply-chain-harden: refusing HTTP repo"*) gmine=yes ;;
  esac
  # Where the two WRITERS put the file, versus the home gradle actually read.
  # MEASURED: on Linux the JVM takes user.home from the passwd entry, not from
  # $HOME, so gradle's default GRADLE_USER_HOME can differ from $HOME/.gradle.
  gwrite="${GRADLE_USER_HOME:-$HOME/.gradle}"
  ghome=""
  [ -n "$gguh" ] && [ "$gguh" != "$gwrite" ] && ghome=" - NOTE: gradle reads init scripts from '$(gradle_san "$gguh")', this role and harden.sh write to '$(gradle_san "$gwrite")'"
  return 0
}

# True when an init script of ours is on disk even though `gradle` is not on
# PATH: ./gradlew still reads $GRADLE_USER_HOME, so the script IS in force.
gradle_script_deployed() {
  gwrite="${GRADLE_USER_HOME:-$HOME/.gradle}"
  [ -f "$gwrite/init.gradle.kts" ] && return 0
  [ -f "$gwrite/init.gradle" ] && return 0
  [ -n "$(ls "$gwrite"/init.d/*.gradle 2>/dev/null | head -1)" ] && return 0
  return 1
}

if have gradle && ! requested gradle; then
  row "N/A" - "gradle HTTPS-only repos" "gradle installed but not in the requested ecosystems"
elif have gradle; then
  gradle_probe_once
  gradle_facts
  if [ -z "$gend" ]; then
    if printf '%s\n' "$GRADLE_OUT" | grep -q 'Initialization script'; then
      row GAP FUNCTIONAL "gradle HTTPS-only repos" "an init script fails to evaluate, so it enforces nothing AND every gradle build on this host fails: $(gradle_san "$(printf '%s\n' "$GRADLE_OUT" | grep -o "Initialization script '[^']*'" | head -1) $gerr")"
    elif printf '%s\n' "$GRADLE_OUT" | grep -qE 'JAVA_HOME|Could not determine java|Unsupported class file'; then
      row WEAK PRESENT "gradle HTTPS-only repos" "gradle $gver is on PATH but cannot start (no usable JVM), so nothing could be observed: $(gradle_san "$gerr")"
    elif [ "$GRADLE_RC" = "124" ]; then
      row WEAK PRESENT "gradle HTTPS-only repos" "the probe timed out after 180s - a host init script is probably resolving from an unreachable network; unproven in both directions"
    else
      row WEAK PRESENT "gradle HTTPS-only repos" "probe did not complete (rc=$GRADLE_RC); the protection is unproven in both directions: $(gradle_san "$gerr")"
    fi
  else
    case "$ghttp" in
      BLOCKED)
        case "$ghmsg" in
          *"Insecure HTTP repository blocked"*|*"supply-chain-harden: refusing HTTP repo"*)
            if [ -z "$gopen" ]; then
              row OK FUNCTIONAL "gradle HTTPS-only repos" "gradle $gver refused an http:// repository as it was declared, with our init script's own message, in ALL FOUR containers (project maven, project ivy, buildscript, settings). Loaded init scripts: $(gradle_san "$ginit")$ghome"
            else
              row WEAK FUNCTIONAL "gradle HTTPS-only repos" "PROJECT MAVEN REPOS ONLY: gradle $gver refused http:// there with our message, but ACCEPTED http:// in${gopen%,} - a plugin jar fetched over http still EXECUTES at configuration time. Loaded init scripts: $(gradle_san "$ginit")$ghome"
            fi ;;
          *)
            row WEAK FUNCTIONAL "gradle HTTPS-only repos" "an http:// repo WAS refused, but not with our message, so the refusal is not attributable to this role: $(gradle_san "$ghmsg")$ghome" ;;
        esac ;;
      ADDED)
        row GAP FUNCTIONAL "gradle HTTPS-only repos" "gradle $gver accepted an http:// repository in every container tried - no init script is refusing it. Loaded init scripts: $(gradle_san "${ginit:-<none>}")$ghome" ;;
      *)
        row WEAK PRESENT "gradle HTTPS-only repos" "the probe returned no verdict for the http:// repository$ghome" ;;
    esac
  fi
elif gradle_script_deployed; then
  row WEAK PRESENT "gradle HTTPS-only repos" "no 'gradle' on PATH, but an init script IS deployed under $(gradle_san "$gwrite") - it applies to every ./gradlew build, and nothing here could exercise it. File existence only; NOT evidence of enforcement"
else
  row "N/A" - "gradle HTTPS-only repos" "gradle not installed and no init script deployed"
fi

# --- gradle dynamic-version refusal  [FUNCTIONAL] ---
# ---------------------------------------------- gradle: dynamic versions -----
# Both writers call failOnDynamicVersions() and failOnChangingVersions() on
# every configuration: action/harden.sh (harden_gradle) unconditionally, and
# tasks/gradle.yml behind respondsTo(), so an older gradle skips them instead of
# failing every build. (This comment used to call it CI-only: the role's script
# once deployed no resolutionStrategy at all.) Gradle added both methods in 6.1
# (@since 6.1 in ResolutionStrategy.java; absent from the 6.0 source).
#
# The evidence is a real resolve() from a file:// repo built in a temp dir.
# `gradle dependencies` REPORTS an unresolved graph and exits 0 (474b165): it
# would score a working init script as a failure and a broken one identically.
# A STATIC coordinate is resolved from the same repo first as the FIXTURE
# CONTROL - if that cannot resolve, no refusal here counts as enforcement.
# The SAME selector is also resolved on buildscript.configurations.classpath:
# allprojects{configurations.all} does not reach the PLUGIN classpath, and a
# dynamic plugin version is remote code chosen at build time. MEASURED with
# both writers' scripts at 8281a6b on gradle 8.14.3: project REFUSED, plugin
# classpath RESOLVED -> WEAK (gradle 9.1.0 the same). With the current
# scripts gradle 9.1.0 refuses that in-process resolve as a mutation of an
# already-resolved classpath, so there the plugin half is the classpath's own
# failingOnDynamicVersions readback - PARSED, and leaning on the project half
# having just shown this gradle enforces the same flag. The real refusal on
# gradle 9 (plugins{}, buildscript{}, settings) was measured outside the
# verifier: "Resolution strategy disallows usage of dynamic versions".
#
# --- shared gradle probe machinery (this identical block appears in both -----
# --- gradle sections; redefining the functions is harmless, and -------------
# --- gradle_probe_once() guarantees the JVM starts at most ONCE per run) ----
GRADLE_OUT="${GRADLE_OUT:-}"
GRADLE_RC="${GRADLE_RC:-1}"
GRADLE_DONE="${GRADLE_DONE:-0}"
GRADLE_VER="${GRADLE_VER:-}"
GRADLE_VER_DONE="${GRADLE_VER_DONE:-0}"

gradle_probe() {
  # Builds a throwaway gradle project in a temp dir and asks GRADLE for the
  # facts, in gradle's own words. Fully offline: every repository container is
  # CLEARED before resolution and the only repo resolved from is a file:// repo
  # it just wrote. Prints marker lines.
  local tmp r rc
  tmp=$(mktemp -d 2>/dev/null) || return 1
  mkdir -p "$tmp/repo/com/example/probe/1.0" 2>/dev/null || { rm -rf "$tmp"; return 1; }
  r="$tmp/repo/com/example/probe"
  cat > "$r/maven-metadata.xml" <<'SCEOF'
<?xml version="1.0" encoding="UTF-8"?>
<metadata>
  <groupId>com.example</groupId>
  <artifactId>probe</artifactId>
  <versioning>
    <latest>1.0</latest><release>1.0</release>
    <versions><version>1.0</version></versions>
    <lastUpdated>20200101000000</lastUpdated>
  </versioning>
</metadata>
SCEOF
  cat > "$r/1.0/probe-1.0.pom" <<'SCEOF'
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>com.example</groupId>
  <artifactId>probe</artifactId>
  <version>1.0</version>
  <packaging>jar</packaging>
</project>
SCEOF
  # A valid empty zip: EOCD is exactly 22 bytes (PK\005\006 + 18 zero bytes).
  printf 'PK\005\006\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000' \
    > "$r/1.0/probe-1.0.jar"
  cat > "$tmp/settings.gradle" <<'SCEOF'
rootProject.name = 'sc-probe'
// Baits #1 and #2: the two SETTINGS-level repository containers. Before
// ECH-171 (bb5446d) neither writer hooked them (MEASURED on 8.14.3 with each
// writer's file: ADDED); both now do, through beforeSettings.
// The property form (not the pluginManagement{} block) is used deliberately:
// it is legal after rootProject.name, and a throw from the hook is CAUGHT
// here rather than aborting settings evaluation. MEASURED both ways.
gradle.ext.scPm = 'ADDED'
try { pluginManagement.repositories.maven { url = uri('http://127.0.0.1:9/sc-pm-http') } }
catch (Throwable t) { gradle.ext.scPm = 'BLOCKED' }
try { pluginManagement.repositories.clear() } catch (Throwable t) { }
gradle.ext.scDm = 'ADDED'
try { dependencyResolutionManagement.repositories.maven { url = uri('http://127.0.0.1:9/sc-dm-http') } }
catch (Throwable t) { gradle.ext.scDm = 'BLOCKED' }
try { dependencyResolutionManagement.repositories.clear() } catch (Throwable t) { }
println "SCP_PMREPO=${gradle.ext.scPm}"
println "SCP_DMREPO=${gradle.ext.scDm}"
SCEOF
  cat > "$tmp/build.gradle" <<'SCEOF'
def sc = [:]
// Bait #3: an http:// MAVEN repo in project.repositories -- the one container
// both writers hooked before ECH-171. MEASURED: with no init script gradle ACCEPTS it here
// (gradle's own insecure-protocol refusal fires later, at RESOLUTION), so a
// BLOCKED verdict cannot be manufactured by gradle's built-in behaviour.
sc.http = 'ADDED'
sc.httpmsg = ''
try { repositories { maven { url = uri('http://127.0.0.1:9/sc-probe-http') } } }
catch (Throwable t) { sc.http = 'BLOCKED'; sc.httpmsg = String.valueOf(t.message) }
// Bait #4: an http:// IVY repo in the SAME container. Before ECH-171 both
// writers tested only `instanceof MavenArtifactRepository`, so ivy slipped
// past (MEASURED ADDED); both now test IvyArtifactRepository too.
sc.ivy = 'ADDED'
try { repositories { ivy { url = uri('http://127.0.0.1:9/sc-ivy-http') } } }
catch (Throwable t) { sc.ivy = 'BLOCKED' }
// Bait #5: buildscript.repositories -- the PLUGIN CLASSPATH container, where
// gradle fetches jars it then EXECUTES at configuration time. A different
# Both writers call failOnDynamicVersions() and failOnChangingVersions() on
# project configurations and on the buildscript / settings script classpaths:
# action/harden.sh (harden_gradle) unconditionally, and tasks/gradle.yml behind
# respondsTo(), so an older gradle skips them instead of failing every build.
# (This comment used to call it CI-only: the role's script once deployed no
# resolutionStrategy at all.) Gradle added both methods in 6.1 (@since 6.1 in
# ResolutionStrategy.java; absent from the 6.0 source).
sc.bs = 'ADDED'
try { buildscript { repositories { maven { url = uri('http://127.0.0.1:9/sc-bs-http') } } } }
catch (Throwable t) { sc.bs = 'BLOCKED' }
// Clear both containers outright: no bait can be contacted, and no repository
// a host init script injected can drag resolution onto the network either.
try { buildscript.repositories.clear() } catch (Throwable t) { }
repositories.clear()
repositories { maven { url = uri(new File(rootDir, 'repo').toURI().toString()) } }
configurations { scStatic; scDyn }
dependencies {
    scStatic 'com.example:probe:1.0'
    scDyn    'com.example:probe:1.+'
}
def flat = { s -> String.valueOf(s).replaceAll('[\\r\\n\\t]+', ' ') }
def chain = { Throwable t ->
    def sb = new StringBuilder(); def c = t
    while (c != null) { sb.append(' | ').append(String.valueOf(c.message)); c = c.cause }
    sb.toString()
}
sc.dynflag = 'UNKNOWN'; sc.chgflag = 'UNKNOWN'; sc.bsdynflag = 'UNKNOWN'
try { sc.dynflag = String.valueOf(configurations.scDyn.resolutionStrategy.failingOnDynamicVersions) } catch (Throwable t) { }
try { sc.chgflag = String.valueOf(configurations.scDyn.resolutionStrategy.failingOnChangingVersions) } catch (Throwable t) { }
try { sc.bsdynflag = String.valueOf(buildscript.configurations.classpath.resolutionStrategy.failingOnDynamicVersions) } catch (Throwable t) { }
// FIXTURE CONTROL: the STATIC coordinate must resolve from the same repo. If
// it does not, the fixture is broken and no refusal below is enforcement.
sc.stat = 'FAIL'; sc.statmsg = ''
try { configurations.scStatic.resolve(); sc.stat = 'OK' } catch (Throwable t) { sc.statmsg = chain(t) }
// BEHAVIOURAL half, project configurations: a real resolve().
sc.dyn = 'RESOLVED'; sc.dynmsg = ''
try { configurations.scDyn.resolve() } catch (Throwable t) { sc.dyn = 'REFUSED'; sc.dynmsg = chain(t) }
// BEHAVIOURAL half, PLUGIN CLASSPATH: the same dynamic selector on
// buildscript.configurations.classpath -- a dynamic plugin version is remote
// code chosen at build time. Its own successful resolve is its fixture control.
// Gradle 9 may not run this half. With an init script that configures
// buildscript.configurations (both writers do, since CMP 4.6), 9.1.0 refuses
// the mutation: "Cannot mutate the dependencies of configuration 'classpath'
// after the configuration was resolved"; creating a fresh configuration in
// the container is refused too. With the 8281a6b scripts, which leave the
// script classpath alone, 9.1.0 allowed it and RESOLVED 1.+. MEASURED both.
// That throw is NOT a refusal of the dynamic selector; the row tells the two
// apart by the message and falls back to the flag readback.
sc.bsdyn = 'RESOLVED'; sc.bsdynmsg = ''
try {
    buildscript.repositories { maven { url = uri(new File(rootDir, 'repo').toURI().toString()) } }
    buildscript.dependencies.add('classpath', 'com.example:probe:1.+')
    buildscript.configurations.classpath.resolve()
} catch (Throwable t) { sc.bsdyn = 'REFUSED'; sc.bsdynmsg = chain(t) }
println "SCP_VER=${gradle.gradleVersion}"
println "SCP_GUH=${gradle.gradleUserHomeDir}"
println "SCP_UHOME=${System.getProperty('user.home')}"
println "SCP_INIT=${gradle.startParameter.allInitScripts.collect{ it.toString() }.join(' ; ')}"
println "SCP_HTTP=${sc.http}"
println "SCP_HTTPMSG=${flat(sc.httpmsg)}"
println "SCP_IVY=${sc.ivy}"
println "SCP_BS=${sc.bs}"
println "SCP_DYNFLAG=${sc.dynflag}"
println "SCP_CHGFLAG=${sc.chgflag}"
println "SCP_BSDYNFLAG=${sc.bsdynflag}"
println "SCP_STATIC=${sc.stat}"
println "SCP_STATICMSG=${flat(sc.statmsg)}"
println "SCP_DYN=${sc.dyn}"
println "SCP_DYNMSG=${flat(sc.dynmsg)}"
println "SCP_BSDYN=${sc.bsdyn}"
println "SCP_BSDYNMSG=${flat(sc.bsdynmsg)}"
println "SCP_END=1"
tasks.register('scProbe') { doLast { } }
SCEOF
  # No --init-script and no -g: gradle discovering our file from the
  # GRADLE_USER_HOME IT resolves is half of what is under test.
  # Bounded (run_bounded, timeout(1) or not): a host init script that resolves
  # plugins from an unreachable network must not hang the verifier. A stop
  # comes back as 124, which the caller reports as a timeout.
  ( cd "$tmp" && run_bounded 180 gradle --no-daemon -q --console=plain scProbe 2>&1 )
  rc=$?
  rm -rf "$tmp"
  return "$rc"
}

# Memoised on a RAN flag, not on output-emptiness: a gradle that dies printing
# nothing would otherwise be probed once per block.
gradle_probe_once() {
  [ "$GRADLE_DONE" -eq 1 ] && return 0
  GRADLE_OUT=$(gradle_probe)
  GRADLE_RC=$?
  GRADLE_DONE=1
  return 0
}

gradle_field() { printf '%s\n' "$GRADLE_OUT" | grep "^$1=" | head -1 | sed "s/^$1=//"; }

# Tool text ends up in a row detail. ROWS is TAB-delimited and the renderer
# passes it to printf as a FORMAT string, so strip % and \ and tabs.
gradle_san() { printf '%s' "$1" | tr -d '%\\' | tr '\t' ' ' | cut -c1-160; }

gradle_facts() {
  gend=$(gradle_field SCP_END)
  gver=$(gradle_field SCP_VER)
  if [ -z "$gver" ]; then
    # `gradle --version` does not evaluate init scripts, so it still answers
    # when a broken init script is failing every real build. Cached so it too
    # runs at most once per verifier run.
    if [ "$GRADLE_VER_DONE" -eq 0 ]; then
      GRADLE_VER=$(gradle --version 2>/dev/null | sed -n 's/^Gradle \([0-9][0-9.]*\).*/\1/p' | head -1)
      GRADLE_VER_DONE=1
    fi
    gver="$GRADLE_VER"
  fi
  gver="${gver:-unknown}"
  gguh=$(gradle_field SCP_GUH)
  ginit=$(gradle_field SCP_INIT)
  ghttp=$(gradle_field SCP_HTTP)
  ghmsg=$(gradle_field SCP_HTTPMSG)
  gdyn=$(gradle_field SCP_DYN)
  gdmsg=$(gradle_field SCP_DYNMSG)
  gdflag=$(gradle_field SCP_DYNFLAG)
  gstat=$(gradle_field SCP_STATIC)
  gerr=$(printf '%s\n' "$GRADLE_OUT" | grep -v '^[[:space:]]*$' | head -3 | tr '\n' ' ')
  # Which of the FOUR http-capable repository containers accepted the bait.
  gopen=""
  [ "$(gradle_field SCP_BS)" = "ADDED" ]     && gopen="$gopen buildscript{} plugin classpath,"
  [ "$(gradle_field SCP_PMREPO)" = "ADDED" ] && gopen="$gopen settings pluginManagement,"
  [ "$(gradle_field SCP_DMREPO)" = "ADDED" ] && gopen="$gopen settings dependencyResolutionManagement,"
  [ "$(gradle_field SCP_IVY)" = "ADDED" ]    && gopen="$gopen ivy{} repositories,"
  # ATTRIBUTION, from gradle's own discovery report. Sound direction: any init
  # script that is NOT one of ours forces a downgrade, so a third-party script
  # can never be credited to this project. Never used to manufacture an OK.
  gforeign=$(printf '%s\n' "$ginit" | tr ';' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
             | grep -v '^$' | grep -v '/supply-chain-security\.gradle$' \
             | grep -v '/init\.gradle\.kts$' | tr '\n' ' ')
  gours=no
  printf '%s\n' "$ginit" | grep -q -e '/supply-chain-security\.gradle' -e '/init\.gradle\.kts' && gours=yes
  # Did a script of OURS actually EXECUTE this run? Behavioural, not a path
  # test: only our init scripts throw with these exact strings.
  gmine=no
  case "$ghmsg" in
    *"Insecure HTTP repository blocked"*|*"supply-chain-harden: refusing HTTP repo"*) gmine=yes ;;
  esac
  # Where the two WRITERS put the file, versus the home gradle actually read.
  # MEASURED: on Linux the JVM takes user.home from the passwd entry, not from
  # $HOME, so gradle's default GRADLE_USER_HOME can differ from $HOME/.gradle.
  gwrite="${GRADLE_USER_HOME:-$HOME/.gradle}"
  ghome=""
  [ -n "$gguh" ] && [ "$gguh" != "$gwrite" ] && ghome=" - NOTE: gradle reads init scripts from '$(gradle_san "$gguh")', this role and harden.sh write to '$(gradle_san "$gwrite")'"
  return 0
}

# True when an init script of ours is on disk even though `gradle` is not on
# PATH: ./gradlew still reads $GRADLE_USER_HOME, so the script IS in force.
gradle_script_deployed() {
  gwrite="${GRADLE_USER_HOME:-$HOME/.gradle}"
  [ -f "$gwrite/init.gradle.kts" ] && return 0
  [ -f "$gwrite/init.gradle" ] && return 0
  [ -n "$(ls "$gwrite"/init.d/*.gradle 2>/dev/null | head -1)" ] && return 0
  return 1
}

if have gradle && ! requested gradle; then
  row "N/A" - "gradle dynamic-version refusal" "gradle installed but not in the requested ecosystems"
elif have gradle; then
  gradle_probe_once
  gradle_facts
  gbsdyn=$(gradle_field SCP_BSDYN)
  gbsflag=$(gradle_field SCP_BSDYNFLAG)
  if [ -z "$gend" ]; then
    if printf '%s\n' "$GRADLE_OUT" | grep -q 'Initialization script'; then
      row GAP FUNCTIONAL "gradle dynamic-version refusal" "an init script fails to evaluate on gradle $gver, so it enforces nothing and every gradle build here fails. failOnDynamicVersions()/failOnChangingVersions() need gradle >= 6.1; the role guards each call with respondsTo() but harden.sh's Kotlin script calls them directly, so on older gradle the METHOD IS MISSING and the build dies, rather than the key lapsing quietly"
    elif printf '%s\n' "$GRADLE_OUT" | grep -qE 'JAVA_HOME|Could not determine java|Unsupported class file'; then
      row WEAK PRESENT "gradle dynamic-version refusal" "not observed - gradle $gver is on PATH but cannot start (no usable JVM): $(gradle_san "$gerr")"
    elif [ "$GRADLE_RC" = "124" ]; then
      row WEAK PRESENT "gradle dynamic-version refusal" "the probe timed out after 180s; unproven in both directions"
    else
      row WEAK PRESENT "gradle dynamic-version refusal" "probe did not complete (rc=$GRADLE_RC); the protection is unproven in both directions: $(gradle_san "$gerr")"
    fi
  elif [ "$gstat" != "OK" ]; then
    row WEAK PRESENT "gradle dynamic-version refusal" "FIXTURE CONTROL failed - the probe's own STATIC coordinate did not resolve from its file:// repo, so nothing here can be read as enforcement: $(gradle_san "$(gradle_field SCP_STATICMSG)")"
  elif [ "$gdyn" = "REFUSED" ]; then
    if ! printf '%s\n' "$gdmsg" | grep -qi 'dynamic version'; then
      row WEAK FUNCTIONAL "gradle dynamic-version refusal" "the dynamic selector failed to resolve, but NOT with the dynamic-version refusal - an unrelated failure is not enforcement: $(gradle_san "$gdmsg")$ghome"
    elif [ -n "$gforeign" ]; then
      row WEAK FUNCTIONAL "gradle dynamic-version refusal" "dynamic versions ARE refused here, but gradle also loaded an init script that is not ours ($(gradle_san "$gforeign")) - the refusal is not attributable to this project$ghome"
    elif [ "$gours" != "yes" ] || [ "$gmine" != "yes" ]; then
      row WEAK FUNCTIONAL "gradle dynamic-version refusal" "dynamic versions ARE refused here, but no init script of ours was observed EXECUTING in this run (loaded: $(gradle_san "${ginit:-<none>}"); our http:// refusal message was not seen) - the refusal is not attributable to this project$ghome"
    elif [ "$gbsdyn" != "REFUSED" ]; then
      row WEAK FUNCTIONAL "gradle dynamic-version refusal" "PROJECT CONFIGURATIONS ONLY: gradle $gver refused com.example:probe:1.+ (failingOnDynamicVersions=$gdflag), but RESOLVED the same selector on buildscript.configurations.classpath (failingOnDynamicVersions=$gbsflag) - a dynamic PLUGIN version still resolves and executes$ghome"
    elif ! printf '%s\n' "$(gradle_field SCP_BSDYNMSG)" | grep -qi 'dynamic version'; then
      # The plugin-classpath resolve threw for another reason - gradle 9.1.0
      # refuses to mutate a classpath our hook has configured. Not a refusal.
      if [ "$gbsflag" = "true" ]; then
        row OK PARSED "gradle dynamic-version refusal" "gradle $gver refused com.example:probe:1.+ on project configurations (a real resolve; its STATIC coordinate resolved in the same run), and reports failingOnDynamicVersions=true on buildscript.configurations.classpath. The plugin half is a READBACK: this gradle would not let the probe resolve the plugin classpath in-process ($(gradle_san "$(gradle_field SCP_BSDYNMSG)")); only our init scripts were loaded$ghome"
      else
        row WEAK PARSED "gradle dynamic-version refusal" "PROJECT CONFIGURATIONS ONLY: gradle $gver refused com.example:probe:1.+ on project configurations, but reports failingOnDynamicVersions=$gbsflag on buildscript.configurations.classpath - a dynamic PLUGIN version is not refused (readback; this gradle would not let the probe resolve the plugin classpath in-process)$ghome"
      fi
    else
      row OK FUNCTIONAL "gradle dynamic-version refusal" "gradle $gver refused com.example:probe:1.+ from a local repo that HAS 1.0 (its STATIC coordinate resolved in the same run), on project configurations AND on the buildscript classpath; only our init scripts were loaded. failingOnChangingVersions=$(gradle_field SCP_CHGFLAG) is a READBACK only - changing versions were not exercised$ghome"
    fi
  elif [ "$gdflag" = "true" ]; then
    row GAP FUNCTIONAL "gradle dynamic-version refusal" "gradle $gver reports failingOnDynamicVersions=true yet RESOLVED com.example:probe:1.+ - the setting is accepted and NOT enforced on this version"
  else
    row GAP FUNCTIONAL "gradle dynamic-version refusal" "gradle $gver resolved com.example:probe:1.+; failingOnDynamicVersions=$gdflag. The role's init script IS deployed and calls failOnDynamicVersions()/failOnChangingVersions(), guarded by respondsTo() - so this is NOT 'the role deploys nothing'. But those methods need gradle >= 6.1 (@since 6.1 in gradle's ResolutionStrategy), and on an older gradle the guard correctly SKIPS them (rather than bricking the build with a missing-method error), leaving this gradle with no dynamic-version control. Upgrade to gradle >= 6.1.$ghome"
  fi
elif gradle_script_deployed; then
  row WEAK PRESENT "gradle dynamic-version refusal" "no 'gradle' on PATH, but an init script IS deployed under $(gradle_san "$gwrite") and will run for ./gradlew builds - including failOnDynamicVersions(), which the role's script skips on gradle < 6.1 and the action's script calls unguarded, a hard evaluation error there. Unexercised in both directions"
else
  row "N/A" - "gradle dynamic-version refusal" "gradle not installed and no init script deployed"
fi

# ======================================================================
# nuget
# ======================================================================

# --- nuget config read by dotnet  [PARSED] ---
# ---------------------------------------------------------------------------
# nuget / .NET
#
# Deployed by the role (tasks/nuget.yml) and the action (harden_nuget):
#   <packageSources><clear /><add key="nuget.org" .../></packageSources>
#   <config><add key="signatureValidationMode" value="require" /></config>
#
# Four independent ways that becomes decoration, one row each:
#   1. written where NuGet never looks.  MEASURED on 6.0.428/8.0.424/9.0.317/
#      10.0.400 linux-arm64: the dotnet CLI merges <cli-home>/.nuget/NuGet/
#      NuGet.Config and never $HOME/.config/NuGet/NuGet.Config (which is what
#      action/harden.sh writes).  XDG_CONFIG_HOME does not move it; but
#      DOTNET_CLI_HOME DOES (MEASURED) and both writers hardcode $HOME.
#   2. a repo-local NuGet.Config lower in the tree <add>s a source back, or
#      overrides signatureValidationMode with "accept"; a user-level file does
#      not reach files below it.  MEASURED, nearest-wins.
#   3. signatureValidationMode accepted-and-inert.  MEASURED: SDK 6.0.428
#      parses it and restores an unsigned package anyway; 8.0.424+ enforce it;
#      DOTNET_NUGET_SIGNATURE_VERIFICATION=false disables it on every version.
#   4. require with no usable trusted signer refuses EVERY package, so the
#      operator deletes the key.
#
# There is NO npm_implements() equivalent: `dotnet nuget config get` returns
# any key we invented and wrote (MEASURED), and returns "Key not found" for
# real keys that have built-in defaults.  It is an echo of the merged files,
# so it can prove WHICH FILE the tool read, never that a key is implemented.
# Hence row 3 is behavioural end-to-end and rows 1/2/4 claim only what a
# tool-resolved readback proves.
# ---------------------------------------------------------------------------

# Run dotnet without first-run side effects.  A never-yet-run SDK otherwise
# prints a banner and generates an ASP.NET dev certificate into the user's
# profile; a verifier must not do that.  DOTNET_CLI_UI_LANGUAGE=en is pinned
# because two probes match the tool's own English strings and MEASURED with
# DOTNET_CLI_UI_LANGUAGE=ja the success line is "復元しました", which silently
# turned the fixture control into a false "control failed".
# DOTNET_NUGET_SIGNATURE_VERIFICATION is deliberately NOT set here: the probe
# must observe the ambient value.
nuget_dotnet() {
  DOTNET_NOLOGO=1 DOTNET_CLI_TELEMETRY_OPTOUT=1 \
  DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1 DOTNET_GENERATE_ASPNET_CERTIFICATE=false \
  DOTNET_CLI_UI_LANGUAGE=en \
  dotnet "$@"
}

# Keep a detail field short and printf-safe.  The shared renderers pass ROWS
# through printf as a FORMAT string, so a stray % in a path would corrupt the
# table; strip it here rather than depend on a renderer fix.
nuget_clip() { printf '%s' "$1" | tr '\n' ' ' | tr -d '%\\' | cut -c1-160; }

# Minimal unsigned .nupkg (709 bytes), embedded because neither zip(1) nor
# python3 is guaranteed on an Ubuntu 22.04 container or a macOS runner.
nuget_fixture_b64() {
  cat <<'B64'
UEsDBBQAAAAIADSQG12L1Z+XpwAAAPMAAAAZAAAAU2NoLlByb2JlLlVuc2lnbmVkLm51c3BlY02OWwrCMBBFt1LybyYqgsg03YIg
LiAmYxs0DzKpdPlGVPRv7uVc5uCwhHv3oMI+xV6spRIdRZucj2Mv5npd7cWgMRt7MyN1DY7ci6nWfABgO1EwLIO3JXG6VmlTgDfb
9rBR6y2oHcSZM1m5sBMaA1XjTDUavdMnO8ljSReS58h+jOQQWo0fId18pEL4RjRznVJhnRG+JzpiW3yuL6D1/xHh9+3jRfoJUEsD
BBQAAAAIADSQG13X6zw9ngAAAOgAAAATAAAAW0NvbnRlbnRfVHlwZXNdLnhtbG2Oyw6CQAxFf2XSPRRdGGMYXKh/4N5ManlE6EyY
YvDvHWBnXLb33Ed5nofevHmMnRcLu7wAw0L+2UljYdI6O8K5Ku+fwNEkVKKFVjWcECO1PLiY+8CSlNqPg9N0jg0GRy/XMO6L4oDk
RVk00yUDqvLKtZt6Nbc5vbdamWJgAnPZ0KXNgvKsmILB4F/T44d3IfQdOU0ielLW1Yjr9OoLUEsDBBQAAAAIADSQG10AAAAAAgAA
AAAAAAAWAAAAbGliL25ldHN0YW5kYXJkMi4wL18uXwMAUEsBAhQDFAAAAAgANJAbXYvVn5enAAAA8wAAABkAAAAAAAAAAAAAAIAB
AAAAAFNjaC5Qcm9iZS5VbnNpZ25lZC5udXNwZWNQSwECFAMUAAAACAA0kBtd1+s8PZ4AAADoAAAAEwAAAAAAAAAAAAAAgAHeAAAA
W0NvbnRlbnRfVHlwZXNdLnhtbFBLAQIUAxQAAAAIADSQG10AAAAAAgAAAAAAAAAWAAAAAAAAAAAAAACAAa0BAABsaWIvbmV0c3Rh
bmRhcmQyLjAvXy5fUEsFBgAAAAADAAMAzAAAAOMBAAAAAA==
B64
}

# Decode the fixture to $1.  GNU coreutils (-d), BSD/macOS (-D), then openssl.
nuget_write_fixture() {
  _ngout=$1
  nuget_fixture_b64 | tr -d '\n' | base64 -d  > "$_ngout" 2>/dev/null
  [ -s "$_ngout" ] && [ "$(head -c 2 "$_ngout" 2>/dev/null)" = "PK" ] && return 0
  nuget_fixture_b64 | tr -d '\n' | base64 -D  > "$_ngout" 2>/dev/null
  [ -s "$_ngout" ] && [ "$(head -c 2 "$_ngout" 2>/dev/null)" = "PK" ] && return 0
  nuget_fixture_b64 | tr -d '\n' | openssl base64 -d -A > "$_ngout" 2>/dev/null
  [ -s "$_ngout" ] && [ "$(head -c 2 "$_ngout" 2>/dev/null)" = "PK" ] && return 0
  return 1
}

# NuGet's user config home follows DOTNET_CLI_HOME when it is set, NOT $HOME.
# MEASURED on 9.0.317: `HOME=a DOTNET_CLI_HOME=b dotnet nuget config paths`
# reports b/.nuget/NuGet/NuGet.Config and `config get --show-path` returns b's
# value.  (XDG_CONFIG_HOME does NOT move it.)  Both writers hardcode $HOME, so
# this is a second way the hardening lands where NuGet never looks — Axis 5,
# the CARGO_HOME shape.  Resolve it the tool's way for both the candidate list
# and the profile-restore below.
ngdh="${DOTNET_CLI_HOME:-$HOME}"

# MEASURED: on a profile that has never run dotnet, `dotnet nuget config paths`
# and `list source` materialise NuGet's stock user config (nuget.org only).
# Note whether it was there first so the probe can put the profile back; the
# .dotnet first-use sentinels dotnet writes for itself are unavoidable on any
# invocation and are left alone.
nuget_precfg=0
[ -f "$ngdh/.nuget/NuGet/NuGet.Config" ] && nuget_precfg=1

# Ecosystem gate.  action/verify.sh defines requested(); the role template does
# not (tasks/main.yml always includes nuget.yml), so this line is a no-op there
# and the gate applies only in the action, where a GitHub-hosted image ships the
# .NET SDK and a job that asked for `npm` must not be failed by a nuget GAP.
# `command -v` prints a bare name for a shell function and a path for a binary.
nuget_gate=1
case "$(command -v requested 2>/dev/null)" in
  requested) requested nuget || nuget_gate=0 ;;
esac

if [ "$nuget_gate" -eq 0 ]; then
  for ngp in "nuget config read by dotnet" "nuget source allowlist" \
             "nuget signature enforcement" "nuget trusted signers"; do
    row "N/A" - "$ngp" "nuget is not in the ecosystems this job requested"
  done
elif ! have dotnet; then
  for ngp in "nuget config read by dotnet" "nuget source allowlist" \
             "nuget signature enforcement" "nuget trusted signers"; do
    row "N/A" - "$ngp" "dotnet not installed"
  done
elif ! nuget_dotnet --list-sdks 2>/dev/null | grep -q '^[0-9]'; then
  for ngp in "nuget config read by dotnet" "nuget source allowlist" \
             "nuget signature enforcement" "nuget trusted signers"; do
    row "N/A" - "$ngp" "dotnet runtime present but no SDK (dotnet --list-sdks is empty) — nothing on this host restores packages"
  done
else
  nsdk=$(nuget_dotnet --version 2>/dev/null | tr -d ' \r'); [ -n "$nsdk" ] || nsdk="unknown"
  nmaj=$(printf '%s' "$nsdk" | cut -d. -f1)
  case "$nmaj" in ''|*[!0-9]*) nmaj=0 ;; esac

  # ---- 1. is what we wrote in the set dotnet actually merges? -------------
  # The tool is the authority: `dotnet nuget config paths` lists every config
  # file merged for this working directory.  SDK 6 has no `config` subcommand
  # and prints its usage banner to STDOUT, so keep only lines that are real
  # absolute file paths.  The candidate paths below are used ONLY to spot a
  # hardening file stranded outside that set; none is assumed correct.
  napplied=$(nuget_dotnet nuget config paths 2>/dev/null | while IFS= read -r ngl; do
    case "$ngl" in (/*) [ -f "$ngl" ] && printf '%s\n' "$ngl" ;; esac
  done)

  # Is this file OURS?  A file merely mentioning signatureValidationMode is NOT
  # ours: MEASURED, a pre-existing site config setting it to `accept` matched
  # that test and produced an OK row on a host where this project had deployed
  # nothing.  Require a managed-by marker, or failing that the full hardening
  # SHAPE (a <clear/> AND require).
  nuget_is_ours() {
    grep -q 'Managed by ansible-supply-chain-security' "$1" 2>/dev/null && return 0
    grep -q 'Managed by supply-chain-harden action' "$1" 2>/dev/null && return 0
    grep -q '<clear' "$1" 2>/dev/null && grep -q 'signatureValidationMode[^>]*require' "$1" 2>/dev/null
  }

  norphan=""; ninset=""
  # Only meaningful when the tool told us what it merges.
  [ -n "$napplied" ] && for ncand in "$ngdh/.nuget/NuGet/NuGet.Config" \
                                     "$HOME/.nuget/NuGet/NuGet.Config" \
                                     "$HOME/.config/NuGet/NuGet.Config"; do
    [ -f "$ncand" ] || continue
    nuget_is_ours "$ncand" || continue
    case ":$ninset:$norphan:" in *":$ncand:"*) continue ;; esac
    if printf '%s\n' "$napplied" | grep -Fqx "$ncand"; then
      [ -n "$ninset" ] || ninset="$ncand"
    else
      norphan="${norphan}${norphan:+, }$ncand"
    fi
  done

  # What the TOOL says the merged value is, and which file won.  Only `require`
  # and `accept` are real NuGet values; anything else (including the
  # "error: Key ... not found." that `config get` prints on stdout) is "not set".
  nsvm=$(nuget_dotnet nuget config get signatureValidationMode --show-path 2>/dev/null | head -1)
  nsvm_val=$(printf '%s' "$nsvm" | cut -f1)
  nsvm_src=$(printf '%s' "$nsvm" | sed -n 's/.*file: //p')
  case "$nsvm_val" in require|accept) : ;; *) nsvm_val=""; nsvm_src="" ;; esac
  # The winning value, but only when it came from a file we deployed.  Probe 3
  # uses this so it can never inherit somebody else's `require`.
  nsvm_ours=""
  [ -n "$ninset" ] && [ "$nsvm_src" = "$ninset" ] && nsvm_ours="$nsvm_val"

  # Fallback for SDKs with no `config` subcommand: a grep of the candidate
  # files.  This is PRESENT-strength only and any row resting on it is capped.
  nsvm_grep=""
  if [ -z "$napplied" ]; then
    for ncand in "$ngdh/.nuget/NuGet/NuGet.Config" "$HOME/.nuget/NuGet/NuGet.Config" \
                 "$HOME/.config/NuGet/NuGet.Config"; do
      [ -f "$ncand" ] || continue
      grep -q 'signatureValidationMode[^>]*require' "$ncand" 2>/dev/null && nsvm_grep=yes
    done
  fi

  if [ -z "$napplied" ]; then
    row "WEAK" "PRESENT" "nuget config read by dotnet" \
      "SDK $nsdk has no 'dotnet nuget config' subcommand (needs SDK 9.0+; measured absent on 8.0.424); the tool cannot be asked which files it merges, so a config written to an unread path is undetectable here"
  elif [ -n "$norphan" ] && [ -z "$ninset" ]; then
    row "GAP" "PARSED" "nuget config read by dotnet" \
      "hardening config at $(nuget_clip "$norphan") is NOT among the files dotnet merges ($(nuget_clip "$napplied")) — never read"
  elif [ -z "$ninset" ]; then
    # No file WE deployed is in the merged set.  A signatureValidationMode
    # coming back here belongs to somebody else's config (commonly a repo-local
    # NuGet.Config) and is not our coverage.
    row "GAP" "PARSED" "nuget config read by dotnet" \
      "no deployed supply-chain NuGet.Config among the files dotnet merges ($(nuget_clip "$napplied"))${nsvm_val:+; the merged signatureValidationMode=$nsvm_val comes from $(nuget_clip "$nsvm_src"), which this project did not deploy}"
  elif [ -n "$norphan" ]; then
    row "WEAK" "PARSED" "nuget config read by dotnet" \
      "dotnet merges our $(nuget_clip "$ninset"), but an unread duplicate exists at $(nuget_clip "$norphan") — the two can drift silently"
  elif [ -n "$nsvm_val" ] && [ "$nsvm_src" != "$ninset" ]; then
    row "GAP" "PARSED" "nuget config read by dotnet" \
      "dotnet merges our $(nuget_clip "$ninset"), but the winning signatureValidationMode=$nsvm_val comes from $(nuget_clip "$nsvm_src") — a higher-precedence config overrides ours here"
  elif [ "$nsvm_ours" = "require" ]; then
    row "OK" "PARSED" "nuget config read by dotnet" \
      "dotnet reports signatureValidationMode=require read from our file $(nuget_clip "$ninset")"
  else
    # Our file is in the merged set and no other file outranks it.  The row's
    # scope is file RESOLUTION only; whether the value enforces is row 3.
    row "OK" "PARSED" "nuget config read by dotnet" \
      "dotnet merges our hardening config $(nuget_clip "$ninset")${nsvm_ours:+ and reports signatureValidationMode=$nsvm_ours from it}"
  fi

# --- nuget source allowlist  [PARSED] ---
  # ---- 2. effective source list ------------------------------------------
  # NuGet's own post-merge resolution for the CURRENT working directory, so a
  # repo-local NuGet.Config that re-adds a feed is visible here.  --format
  # short prints "E <url>" / "D <url>" and exists on every SDK 6..10 (MEASURED).
  nsrcrc=0
  nsrc=$(nuget_dotnet nuget list source --format short 2>/dev/null) || nsrcrc=1
  nenabled=$(printf '%s\n' "$nsrc" | sed -n 's/^E //p' | sed 's/[[:space:]]*$//')
  ncount=$(printf '%s\n' "$nenabled" | grep -c '[^[:space:]]')
  nextra=$(printf '%s\n' "$nenabled" | grep '[^[:space:]]' | grep -vx 'https://api\.nuget\.org/v3/index\.json')
  if [ "$nsrcrc" -ne 0 ]; then
    row "WEAK" "PRESENT" "nuget source allowlist" \
      "'dotnet nuget list source' failed on SDK $nsdk — the effective source list could not be read from the tool"
  elif [ "$ncount" -eq 0 ]; then
    row "WEAK" "PARSED" "nuget source allowlist" \
      "dotnet resolves zero enabled package sources here — nothing can restore, so this is a broken config rather than a working allowlist"
  elif [ -n "$nextra" ]; then
    row "GAP" "PARSED" "nuget source allowlist" \
      "dotnet resolves $ncount enabled source(s) in $(nuget_clip "$(pwd)"); not official nuget.org: $(nuget_clip "$nextra")"
  elif [ -z "$napplied" ]; then
    # SDK < 8: no `config paths`, so the merged set is unknowable and the state
    # cannot be attributed to anything we deployed.
    row "WEAK" "PARSED" "nuget source allowlist" \
      "dotnet resolves $ncount enabled source(s) in $(nuget_clip "$(pwd)"), all official nuget.org — but SDK $nsdk cannot be asked which config files it merges, so nothing attributes this state to our allowlist rather than to NuGet's stock default"
  elif [ -z "$ninset" ]; then
    # MEASURED: on a host with nothing deployed, and on the CI host whose config
    # sits at an unread path, this output is byte-identical to the hardened case,
    # because NuGet's stock default IS one enabled nuget.org source.  Reporting
    # OK there is a green row for a protection that does not exist.
    row "WEAK" "PARSED" "nuget source allowlist" \
      "dotnet resolves $ncount enabled source(s) in $(nuget_clip "$(pwd)"), all official nuget.org — but that is byte-for-byte NuGet's stock default and no config we deployed is in the merged set, so nothing attributes this state to our allowlist"
  else
    row "OK" "PARSED" "nuget source allowlist" \
      "dotnet resolves $ncount enabled source(s) in $(nuget_clip "$(pwd)"), all official nuget.org, with our $(nuget_clip "$ninset") in the merged set"
  fi

# --- nuget signature enforcement  [FUNCTIONAL] ---
  # ---- 3. does the DEPLOYED config refuse an unsigned package, right now? --
  # Config readback cannot answer this (see the header: config get is an echo).
  # So make the tool act, TWICE:
  #   (a) AMBIENT/end-to-end — no project NuGet.Config at all, the host's real
  #       config home, `-s <local folder>` so it stays offline.  Whatever dotnet
  #       does here is what the DEPLOYED configuration does.  Control: the same
  #       restore with DOTNET_NUGET_SIGNATURE_VERIFICATION=false (MEASURED to
  #       disable enforcement on every SDK), so an unrelated restore failure
  #       cannot be scored as enforcement.
  #   (b) CAPABILITY — the probe supplies signatureValidationMode itself under
  #       a throwaway HOME.  This proves nothing about the host's config; it is
  #       what tells the reader WHY (a) admitted the package: inert SDK tier vs
  #       key unset vs env kill-switch.
  # Both are scored on the ARTIFACT (was the package extracted?), not on a
  # message: MEASURED, under DOTNET_CLI_UI_LANGUAGE=ja the success string is
  # localized, and "printed a refusal but installed it anyway" must not score
  # as enforcement (Axis 4).
  nsigstate="unknown"; ncap="unknown"; ncap_why=""; nact="inconclusive"
  ntmp=$(mktemp -d 2>/dev/null || echo "")
  if [ -z "$ntmp" ] || [ ! -d "$ntmp" ]; then
    row "WEAK" "PRESENT" "nuget signature enforcement" "mktemp -d failed; the unsigned-package probe could not run"
  elif [ "$nmaj" -lt 5 ]; then
    rm -rf "$ntmp"
    row "WEAK" "PRESENT" "nuget signature enforcement" "could not parse an SDK major version from '$nsdk'; refusing to guess a target framework for the restore probe"
  elif ! { mkdir -p "$ntmp/feed" "$ntmp/proj" && nuget_write_fixture "$ntmp/feed/sch.probe.unsigned.1.0.0.nupkg"; }; then
    rm -rf "$ntmp"
    row "WEAK" "PRESENT" "nuget signature enforcement" "no usable base64 decoder (tried base64 -d, base64 -D, openssl base64 -d); could not materialise the unsigned-package fixture"
  else
    cat > "$ntmp/proj/p.csproj" <<NGEOF
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net${nmaj}.0</TargetFramework>
    <EnableDefaultItems>false</EnableDefaultItems>
  </PropertyGroup>
  <ItemGroup><PackageReference Include="Sch.Probe.Unsigned" Version="1.0.0" /></ItemGroup>
</Project>
NGEOF
    # Did the package actually land on disk?  Locale-proof, and the only signal
    # that distinguishes "refused" from "complained and installed it anyway".
    nuget_pkg_installed() { [ -d "$ntmp/pkgs/sch.probe.unsigned/1.0.0" ]; }

    # (a) end-to-end against the host's own config.  $1=off runs the control.
    nuget_restore_ambient() {
      rm -f "$ntmp/proj/NuGet.Config"
      rm -rf "$ntmp/pkgs" "$ntmp/proj/obj"
      ( cd "$ntmp/proj" || exit 1
        [ "${1:-}" = "off" ] && { DOTNET_NUGET_SIGNATURE_VERIFICATION=false; export DOTNET_NUGET_SIGNATURE_VERIFICATION; }
        NUGET_PACKAGES="$ntmp/pkgs" MSBUILDDISABLENODEREUSE=1 \
        nuget_dotnet restore --source "$ntmp/feed" --packages "$ntmp/pkgs" 2>&1 )
    }
    nactl=$(nuget_restore_ambient off)
    if nuget_pkg_installed; then
      nlive=$(nuget_restore_ambient)
      if nuget_pkg_installed; then
        nact="restored"
      elif printf '%s' "$nlive" | grep -q 'NU3004'; then
        nact="refused"
      else
        nact="inconclusive"
        ncap_why="with the host's own config the unsigned fixture failed to restore without NU3004 ($(printf '%s' "$nlive" | grep -oE 'NU[0-9]{4}' | head -1)) — a refusal we cannot attribute to signature validation"
      fi
    else
      ncap_why="fixture control did not install the package on SDK $nsdk even with signature verification disabled ($(printf '%s' "$nactl" | grep -oE 'NU[0-9]{4}' | head -1)); a refusal under the host config would not distinguish enforcement from an unrelated restore failure"
    fi

    # (b) capability, under a throwaway HOME, to explain (a).
    nuget_restore_synth() {
      cat > "$ntmp/proj/NuGet.Config" <<NGEOF
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources><clear /><add key="probe" value="$ntmp/feed" /></packageSources>
  <config>$1</config>
</configuration>
NGEOF
      rm -rf "$ntmp/pkgs" "$ntmp/proj/obj"
      ( cd "$ntmp/proj" || exit 1
        HOME="$ntmp" DOTNET_CLI_HOME="$ntmp" NUGET_PACKAGES="$ntmp/pkgs" \
        MSBUILDDISABLENODEREUSE=1 \
        nuget_dotnet restore --packages "$ntmp/pkgs" 2>&1 )
    }
    nctl=$(nuget_restore_synth "")
    if ! nuget_pkg_installed; then
      ncap="inconclusive"
    else
      nreq=$(nuget_restore_synth '<add key="signatureValidationMode" value="require" />')
      if nuget_pkg_installed; then ncap="inert"
      elif printf '%s' "$nreq" | grep -q 'NU3004'; then ncap="enforces"
      else ncap="inconclusive"; fi
    fi
    rm -rf "$ntmp"

    # Why did the host's config admit the package?  Env kill-switch beats
    # everything, then an inert SDK tier, then the key simply not being set.
    nwhy="the merged config does not enforce it (dotnet reports signatureValidationMode=${nsvm_val:-<unset>})"
    [ "$ncap" = "inert" ] && nwhy="the key is accepted and inert on SDK $nsdk (enforcement needs SDK 8.0+ on Linux/macOS; measured inert on 6.0.428)"
    case "${DOTNET_NUGET_SIGNATURE_VERIFICATION:-}" in
      [Ff][Aa][Ll][Ss][Ee]|0) nwhy="DOTNET_NUGET_SIGNATURE_VERIFICATION=$DOTNET_NUGET_SIGNATURE_VERIFICATION in this environment disables verification regardless of any config" ;;
    esac

    if [ "$nact" = "refused" ]; then
      nsigstate="enforcing"
      row "OK" "FUNCTIONAL" "nuget signature enforcement" \
        "with the host's own NuGet config and no overrides, SDK $nsdk refused an UNSIGNED package with NU3004 and did not extract it; the same restore with DOTNET_NUGET_SIGNATURE_VERIFICATION=false installed it (measured for the user-level config, from a temp dir — a repo-local override is what row 1 covers)"
    elif [ "$nact" = "restored" ]; then
      row "GAP" "FUNCTIONAL" "nuget signature enforcement" \
        "the host's own NuGet config admitted an UNSIGNED package: $nwhy"
    elif [ "$ncap" = "inert" ]; then
      row "GAP" "FUNCTIONAL" "nuget signature enforcement" \
        "SDK $nsdk parses signatureValidationMode=require and restores an unsigned package anyway: $nwhy"
    elif [ "$ncap" = "enforces" ] && [ "$nsvm_val" != "require" ]; then
      # The end-to-end run was inconclusive, but two independently measured
      # facts already settle it: this SDK DOES enforce the key, and the tool
      # reports the merged value is not require.  Weaker evidence class, same
      # conclusion.  Deliberately keyed on the WINNING value, not on ours: a
      # foreign merged file supplying require means the host is enforcing (not
      # our doing — that is row 1's GAP), so this must not fire there.
      row "GAP" "PARSED" "nuget signature enforcement" \
        "SDK $nsdk does enforce signatureValidationMode, but dotnet reports the merged value is '${nsvm_val:-<unset>}' — unsigned packages are admitted (the end-to-end run was inconclusive: ${ncap_why:-no reason recorded})"
    else
      row "WEAK" "PRESENT" "nuget signature enforcement" \
        "${ncap_why:-the unsigned-package probe was inconclusive on SDK $nsdk}${nsvm_grep:+; a deployed NuGet.Config does contain require, but this SDK cannot be asked which files it merges}"
    fi
  fi

# --- nuget trusted signers  [PARSED] ---
  # ---- 4. is there anything for `require` to trust? ------------------------
  # MEASURED on 10.0.400: require + no <trustedSigners> rejects every real
  # nuget.org package with NU3034 "signed but not by a trusted signer" — a
  # total restore failure, not selective admission.  `config get all` reports
  # the merged trustedSigners section but NOT certificate fingerprints
  # (MEASURED: entries print as `\trepository name="..." serviceIndex="..."`,
  # the <certificate> children are not printed at all), so a present entry can
  # only ever be WEAK.  (MEASURED back when action/harden.sh pinned only the
  # 2018 certificate, 0E5F38F5...: packages repository-signed with a later one,
  # 5A2901D6..., failed NU3034 with that as the only pin.  Both writers now pin
  # all three certificates nuget.org's repository-signatures index lists; the
  # current one expires 2027-05-18 — see tasks/nuget.yml.)
  if [ "$nsigstate" != "enforcing" ]; then
    row "N/A" - "nuget trusted signers" \
      "signature validation is not proven to be enforcing on this host; trusted signers cannot change that outcome"
  elif ! nuget_dotnet nuget config get all >/dev/null 2>&1; then
    row "WEAK" "PRESENT" "nuget trusted signers" \
      "SDK $nsdk cannot report merged trustedSigners ('dotnet nuget config' needs SDK 9.0+)"
  else
    # MEASURED: `config get all` prints sections in FILE order, not a fixed
    # order.  An unbounded '/^trustedSigners:/,$p' range swallowed whatever
    # section followed, and a `repositoryPath` config key was counted as a
    # signer — an EMPTY <trustedSigners /> reported "1 entry" WEAK instead of
    # the GAP.  End the section at the first non-indented line and match the
    # entry keyword as its own field.
    nts=$(nuget_dotnet nuget config get all 2>/dev/null | awk '
      /^trustedSigners:/ { ints=1; next }
      /^[^ \t]/          { ints=0 }
      ints && ($1=="repository" || $1=="author") { n++ }
      END { print n+0 }')
    case "$nts" in ''|*[!0-9]*) nts=0 ;; esac
    if [ "$nts" -eq 0 ]; then
      row "GAP" "PARSED" "nuget trusted signers" \
        "require is enforcing with zero trusted signers merged — MEASURED on SDK 10.0.400 dotnet then refuses EVERY nuget.org package with NU3034, so nothing is admitted and the key gets deleted on first use rather than protecting anything"
    else
      row "WEAK" "PARSED" "nuget trusted signers" \
        "$nts trusted signer entr(y/ies) merged, but 'config get all' does not report fingerprints, so we cannot prove the pinned certificate matches nuget.org's current repository certificate"
    fi
  fi

  # Leave the profile as we found it.  Only removes a file this probe caused to
  # appear, and only while it is still the stock default (no hardening markers),
  # so a config deployed by the role or a concurrent writer is never touched.
  if [ "$nuget_precfg" -eq 0 ] && [ -f "$ngdh/.nuget/NuGet/NuGet.Config" ] &&
     ! grep -q 'signatureValidationMode\|<clear' "$ngdh/.nuget/NuGet/NuGet.Config" 2>/dev/null; then
    rm -f "$ngdh/.nuget/NuGet/NuGet.Config"
  fi
fi
