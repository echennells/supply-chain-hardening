#!/bin/bash
# issue 48 item 2 on hosted macOS: is pnpm's hardening read?
set +e; L=$1
echo "PROBE pnpm $L | XDG_CONFIG_HOME=${XDG_CONFIG_HOME:-unset} pnpm=$(pnpm --version) ignoreScripts=$(cd /; pnpm config get ignoreScripts 2>/dev/null | tail -1) ignore-scripts=$(cd /; pnpm config get ignore-scripts 2>/dev/null | tail -1) minimumReleaseAge=$(cd /; pnpm config get minimumReleaseAge 2>/dev/null | tail -1)"
for mode in with-env clean; do
W=$(mktemp -d); cd "$W"; printf '{"name":"p","version":"1.0.0","scripts":{"postinstall":"touch %s/RAN"}}\n' "$W" > package.json
if [ $mode = clean ]; then env -i PATH="$PATH" HOME="$HOME" pnpm install >o 2>&1; else pnpm install >o 2>&1; fi; echo "PROBE pnpm $L | $mode: project postinstall $([ -e RAN ] && echo RAN || echo blocked) rc=$?"; done
ls -la "$HOME/.config/pnpm" "$HOME/Library/Preferences/pnpm" 2>&1 | sed "s/^/PROBE pnpm $L | ls /" | grep -vE 'total|\.$' | cut -c1-120
