#!/usr/bin/env bash
# Switch active .NET SDK for a single matrix cell.
#
# Called by ../run.sh as:
#   switchers/nuget.sh <system_label> <nuget_version>
# e.g.:
#   switchers/nuget.sh system bundled
#
# .NET is installed by install-versions.yml via the official
# dotnet-install.sh script to /usr/share/dotnet (cross-distro
# consistent). NuGet itself is part of the dotnet CLI — no separate
# package to install or switch. v1 nuget matrix is essentially a
# smoke test: "does the role's NuGet.Config deploy correctly when
# dotnet is present, on every supported distro".
#
# Future expansion: multiple .NET SDK versions side-by-side, switcher
# manages global.json or DOTNET_ROOT to pin which is active. Not in v1.

set -euo pipefail

LANG_LABEL="${1:?usage: $0 <lang_label> <nuget_version>}"
NUGET_VERSION="${2:?usage: $0 <lang_label> <nuget_version>}"

[[ "$LANG_LABEL" = "system" ]] || {
  echo "switchers/nuget.sh: only 'system' lang is supported in v1 (got '$LANG_LABEL')" >&2
  exit 1
}

[[ "$NUGET_VERSION" = "bundled" ]] || {
  echo "switchers/nuget.sh: only 'bundled' nuget is supported in v1 (got '$NUGET_VERSION')" >&2
  exit 1
}

command -v dotnet >/dev/null 2>&1 || {
  echo "switchers/nuget.sh: dotnet not on PATH (install-versions.yml should have installed it)" >&2
  exit 1
}

echo "switchers/nuget.sh: dotnet=$(dotnet --version 2>/dev/null) active"
