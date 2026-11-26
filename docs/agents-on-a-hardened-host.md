# Agents on a hardened host

For an AI agent that is working in some project on a host this role hardened.
Give it this file, or the rules in it; nothing installs or loads it for you.

## What the hardening is

The package managers on this host treat a package differently before it runs. Where the
tool supports it, releases newer than the age window are refused, install scripts are
skipped, and pip and uv refuse source builds from an index. Not every tool: Go, Maven, Gradle and NuGet
have no age gate here, and Cargo's and Ruby's build scripts still run. It is not a sandbox. You run as the same user and could undo every setting,
which is why the rules below ask you not to. If your user asks what it protects against
and what it does not, the honest answer is in [threat-model.md](threat-model.md).

## What a refusal looks like

Package managers on this host refuse some installs on purpose: releases newer
than the age window (48 hours by default), source builds, npm git dependencies,
and, for Yarn, Bundler and cargo, an install that would change the lockfile.
Install scripts are skipped silently. A refusal usually does not mention this
project. It looks like one of these:

- npm `ETARGET ... with a date before` or `EALLOWGIT`; a native module that
  installs and then fails when it is loaded (`Could not locate the bindings file`)
- uv `marked as --no-build`; pip `Could not find a version that satisfies the
  requirement ... (from versions: none)`
- Yarn `YN0028`, Bundler `Frozen mode is set`
- a Composer plugin or script that did not run (a missing autoload entry), or a
  Composer or Cargo release refused because it was published too recently
- Go `requires go >= ...` with `GOTOOLCHAIN=local`
- any message starting `[supply-chain-hardening]`

[day-one.md](day-one.md) explains each one, for the person who decides.

## What to do

**Stop. Show the user the message. Wait.** Say which package and version was
refused, and that this host is set up to refuse it. Let the user decide.

**Never work around it.** The task is no longer "make the install succeed". Do not:

- weaken or switch off a gate, with any flag, config key or variable
- call a `-real` binary, or the real binary behind a wrapper
- unset, clear or override the environment these tools were given
- edit a file this project manages (`~/.npmrc`, `uv.toml`, `.bundle/config`,
  `pnpm` config, the policy in `composer.json`, and the rest)
- reach for `supply-chain-allow-build`: it exists so a person can vouch for a
  build they trust, and you are not that person

Retrying the same install in a different way is the same thing. Installing an
older release that is outside the window, or waiting, are not workarounds, but
they change what the user asked for: offer them, don't choose them.
