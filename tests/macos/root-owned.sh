#!/bin/bash
# Root-owned files the hardening left in the user's home, where they break the
# user's own tools: root's npm once left some in ~/.npm, and every later npm
# install of the caller failed with EACCES (measured on macos-15 and -intel).
#
#   root-owned.sh before <file>   what was root's there already
#   root-owned.sh after  <file>   fails on anything new but one of our own wrappers,
#                                 which every account is meant to run and not write
set -u
MODE=${1:-} REC=${2:-}
list() { sudo find "$HOME" -xdev -user root 2>/dev/null | LC_ALL=C sort; }
case "$MODE" in
  before) list > "$REC"; echo "root-owned in $HOME before: $(wc -l < "$REC" | tr -d ' ')" ;;
  after)
    fail=0
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      case "$(sudo head -c 512 "$f" 2>/dev/null | LC_ALL=C tr -d '\000' | sed -n 2p)" in
        "# Managed by supply-chain-harden"*|"# cargo — supply-chain-harden wrapper"|"# deno — supply-chain-harden wrapper")
          echo "root-owned: $f is a wrapper this run deployed" ;;
        *) echo "::error title=Root-owned file left in HOME::$f ($(ls -ldn "$f" | cut -c1-10))"; fail=1 ;;
      esac
    done < <(list | LC_ALL=C comm -13 "$REC" -)
    [ $fail -eq 0 ] && echo "nothing else in $HOME became root's"
    exit $fail ;;
  *) echo "usage: root-owned.sh before|after <record>" >&2; exit 2 ;;
esac
