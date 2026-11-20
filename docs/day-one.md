# Day one on a hardened host

Things a developer runs into in the first days, what each looks like, and the
way through. Most of these errors do not mention this role, so they are listed
here by what you see.

The routes below are for a **person** who has decided a specific package or
change is wanted. An agent that hits one of these stops and tells the user
([AGENTS.md](../AGENTS.md)).

Unless a line says otherwise, every result here was MEASURED on 2026-11-19 in
containers set up with the role's config files and environment (and, for npm,
its wrapper). "The VM tests" means the 2026-11-19 run of the role on nine
Azure VMs.

## npm: a native module installs, then fails when it is loaded

`npm install sqlite3@5.1.7` exits 0, and the first `require('sqlite3')` fails
with `Could not locate the bindings file`. Packages that fetch or build their
native binding in an install script all do this; the VM tests also hit it with
sharp 0.32 and bcrypt 5. `ignore-scripts=true` skipped that script, and npm
says nothing when it skips one. Packages that arrive with prebuilt binaries
were unaffected on the VM tests: esbuild, better-sqlite3 and bcrypt 6.

A plain `npm rebuild sqlite3` prints `rebuilt dependencies successfully` and
runs nothing, because `ignore-scripts` still applies.

For a package you have vetted, run its scripts once:

| npm | Route |
|---|---|
| 11.x | `npm rebuild sqlite3 --ignore-scripts=false` |
| 12.x | `npm install-scripts approve sqlite3`, then `npm rebuild sqlite3 --ignore-scripts=false` |

npm 12 blocks dependency scripts that `allowScripts` in `package.json` does
not cover, even with `--ignore-scripts=false`; `approve` adds the entry.
Measured on npm 11.19.1 (sqlite3 then loads and runs a query) and npm 12.2.3
(a fixture package's install script ran only after `approve`). The flag
applies to that one command: `ignore-scripts` still reads `true` afterwards,
so every other package stays blocked.

## npm: `ETARGET` on an exact version

```
npm error code ETARGET
npm error notarget No matching version found for electron-to-chromium@1.5.491 with a date before 11/17/2026, 5:26:31 PM.
```

The version exists. `with a date before` is the age gate (`min-release-age`,
npm 11.10.0 and later): it was published less than `min-release-age` days
ago. The role sets that window in whole days, to
`npm_minimum_release_age_days`: `release_age_hours` divided by 24, rounded
down, and at least 1 (2 at the 48-hour default). Pick an older version or
wait until it ages past the window.

Without an exact pin there is no error at all: npm quietly installs the newest
version that is old enough. Set `SCV_AGE_NOTICE=1` to have the npm wrapper say
when that happened, for the packages you name on the command line:

```
[supply-chain-hardening] age gate: electron-to-chromium@1.5.491 (0.6d old) skipped as < 2d; installed 1.5.487
```

It is opt-in and per command. It covers successful non-interactive installs
through the role's npm wrapper, and needs `NPM_CONFIG_MIN_RELEASE_AGE` in the
environment, which the role's env layer sets. It compares each named
package's `latest` with what was installed, so a transitive dependency that
the gate held back is not reported. It does not explain an `ETARGET`.

## Yarn (Berry): `YN0028` in a project with no `yarn.lock`

```
➤ YN0028: · The lockfile would have been created by this install, which is explicitly forbidden.
```

`yarn install` in a project without a lockfile fails this way (measured on
Yarn 4.10.3 and 4.18.1), and so does `yarn init` after it has written
`package.json` (its install step ran Yarn 4.18.0). The role sets `enableImmutableInstalls: true`
(`yarn_enable_immutable_installs`), which refuses any install that would
change the lockfile, including creating it.

Create the lockfile once, then commit it:

- `yarn install --no-immutable`
- `YARN_ENABLE_IMMUTABLE_INSTALLS=false yarn init`

After that, a plain `yarn install` passes. `yarn add` creates a lockfile
without either.

## Bundler: `bundle add` in a project with no `Gemfile.lock`

The role sets `BUNDLE_FROZEN: "true"` in `~/.bundle/config`. `bundle init`
still works, but `bundle add rack` then fails with
`Frozen mode is set, but there's no lockfile` (exit 16, measured on Bundler
2.5.22, 2.6.7 and 4.0.24). On Bundler 2.4.20 the VM tests saw a different
message, ending `remove the Gemfile freeze by running bundle config set frozen
false`, and the gem line was left in the `Gemfile`.

Don't follow that hint. `bundle config set frozen false` (or
`bundle config unset frozen`) rewrites `~/.bundle/config` and turns frozen
mode off for every project you have.

For one command instead:

- `BUNDLE_FROZEN=false bundle add rack`. The environment outranks
  `~/.bundle/config` for that command only, and the global setting stays
  frozen.
- Or add the line to the `Gemfile` yourself and run `bundle lock`, which
  frozen mode allows.

Either way, a later `bundle install` runs frozen against the new
`Gemfile.lock` (measured on 2.6.7 and 4.0.24).

## Go: `golang.org/x/...@latest` on a distro Go older than 1.26

```
go: golang.org/x/net@latest: golang.org/x/net@v0.63.0 requires go >= 1.26.0 (running go 1.24.4; GOTOOLCHAIN=local)
```

The latest `golang.org/x` modules need Go 1.26 (x/net, x/text and x/tools were
checked), and `GOTOOLCHAIN=local` stops
`go` from downloading a newer toolchain to build them. Measured with Debian
13's golang-go 1.24.4; the VM tests saw the same with Ubuntu 24.04's 1.22.2.

Pin a release your Go can build. On go1.24.4,
`go get golang.org/x/net@v0.50.0` worked: it is the newest release whose
`go.mod` says `go 1.24`. To check a candidate, list the releases with
`go list -m -versions golang.org/x/net` and read the `go` line of its
`go.mod` (`go mod download -json golang.org/x/net@vX.Y.Z` prints its path).
`go get golang.org/x/net go@1.24.4` does not do this for you; it fails the
same way. The other route is to install a newer Go.

## A wrapper disappears after a package upgrade

Some wrappers replace a binary at a path a system package owns, for example
apt's `/usr/bin/composer` or `/usr/bin/cargo`. Reinstalling or upgrading that
package unpacks the real binary over the wrapper. On the VM tests an apt
reinstall of composer did exactly that; `supply-chain-verify` reported it, and
re-applying the role restored the wrapper.

Re-apply the role after installing, reinstalling or upgrading a package
manager, and run `supply-chain-verify` afterwards.
