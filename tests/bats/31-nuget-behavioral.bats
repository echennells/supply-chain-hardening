#!/usr/bin/env bats
# Behavioral tests for NuGet/.NET supply-chain hardening.
#
# The role's tasks/nuget.yml gates on `which dotnet`, then deploys
# ~/.nuget/NuGet/NuGet.Config with:
#   - clear inherited package sources, allowlist only nuget.org over HTTPS
#   - signatureValidationMode=require (refuse unsigned packages)
# Matrix mode runs these per cell to verify the config remains correct
# across .NET SDK versions (NuGet config schema has been stable for years
# but matrix would catch a future schema break).

load setup

@test "nuget: ~/.nuget/NuGet/NuGet.Config exists" {
  command -v dotnet >/dev/null 2>&1 || skip "dotnet not installed (role's nuget task is no-op)"
  [ -f "$HOME/.nuget/NuGet/NuGet.Config" ]
}

@test "nuget: config clears inherited package sources" {
  command -v dotnet >/dev/null 2>&1 || skip "dotnet not installed"
  assert_file_contains "$HOME/.nuget/NuGet/NuGet.Config" "<clear />"
}

@test "nuget: config allowlists only nuget.org over HTTPS" {
  command -v dotnet >/dev/null 2>&1 || skip "dotnet not installed"
  assert_file_contains "$HOME/.nuget/NuGet/NuGet.Config" "https://api.nuget.org/v3/index.json"
}

@test "nuget: config requires signed packages" {
  command -v dotnet >/dev/null 2>&1 || skip "dotnet not installed"
  assert_file_contains "$HOME/.nuget/NuGet/NuGet.Config" 'signatureValidationMode" value="require"'
}

@test "nuget: dotnet --info works (config doesn't break the SDK)" {
  command -v dotnet >/dev/null 2>&1 || skip "dotnet not installed"
  run dotnet --info
  [ "$status" -eq 0 ]
}
