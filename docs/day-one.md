# Day one on a hardened host

Things a developer runs into in the first days, what each looks like, and the
way through. Most of these errors do not mention this role, so they are listed
here by what you see.

The routes below are for a **person** who has decided a specific package or
change is wanted. An agent that hits one of these stops and tells the user
([agents-on-a-hardened-host.md](agents-on-a-hardened-host.md)); it uses none of
them.

Unless a line says otherwise, every result here was MEASURED on 2026-11-19 in
containers set up with the role's config files and environment (and, for npm,
its wrapper). "The VM tests" means the 2026-11-19 run of the role on nine
Azure VMs.

## The escapes, and what each one drops

Every gate here has a way past it, because a person sometimes needs one. Take
the narrowest: a flag on one command, then one variable for one command, then
a file. What an escape drops depends on which it is:

| Escape | What it drops |
|---|---|
| `composer --no-cooldown` | Composer's age gate, for that command. |
| `bundle lock --cooldown 0` | Bundler's age gate, for that command. |
| `uv --no-config`, `uv --config-file <f>`, `UV_CONFIG_FILE=<f>` | Every setting in the `uv.toml` files: the age gate, `no-build`, the index order, all at once. `supply-chain-allow-build uv ...` lifts only `no-build`, for that command. |
| Unsetting or overriding a variable from the env layer (`NPM_CONFIG_IGNORE_SCRIPTS=false`, `BUNDLE_FROZEN=false bundle add x`, `GOTOOLCHAIN=auto`, ...) | That one setting, for that command, if nothing else sets it. |
| `composer-real`, `deno-real`, `bun-real`, `cargo-real`, or the binary a wrapper names | Everything the wrapper adds: `--no-scripts`, `--no-plugins`, the age gate, `--locked`, Socket Firewall. |
| Editing `~/.npmrc`, `~/.config/uv/uv.toml`, `~/.bundle/config`, `poetry.toml`, or the `policy` in `composer.json` | That setting, for every command from then on, until the next apply rewrites the file the role manages. |
| `supply-chain-allow-build <command>` | `no-build`, for that command, and it logs what was built. It is for a person, and the one escape that says what it did. |

The commands in the sections below are the narrow ones.

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

## npm: `EALLOWGIT` on a git dependency

```
npm error code EALLOWGIT
npm error Fetching packages of type "git" have been disabled
npm error Refusing to fetch "gitdep@git+file:///fx/gitdep.git"
```

That is `allow-git=none` (npm 11.9.0 and later), in the npmrc files and, as
`NPM_CONFIG_ALLOW_GIT=none`, in the env layer. It refuses direct and
transitive git dependencies, `npm ci` from a lockfile included. A project's
own `.npmrc` `allow-git=all` does not lift it while the variable is set,
which on GitHub Actions is every step after the action, so a CI job whose
git dependencies installed before now fails here. npm 12 refuses git
dependencies by default anyway.

For a git dependency you have vetted, allow it on that one command:

```
npm install --allow-git=root    # git dependencies of this project, not of its dependencies
npm install --allow-git=all     # git dependencies anywhere in the tree
```

The flag outranks the variable (MEASURED on npm 11.19.1, 2026-11-22); the
next command is refused again.

## uv: `uv sync` in your own project fails with "marked as `--no-build`"

```
error: Distribution `myproj==0.1.0 @ editable+.` can't be installed because it is marked as `--no-build` but has no binary distribution
```

On uv 0.12.5 and older, `uv sync` and `uv run` exit 2 like this in a project
that has its own `[build-system]`. The role sets `no-build = true`
(`uv_no_build`), as does `harden.sh`, and those uv versions apply it to the
project itself. From uv 0.12.6, uv builds your own project (its changelog:
"Allow explicit `uv build` and non-editable first-party workspace packages
when `no-build` is enabled"; a plain `uv sync`, which installs the project
editable, built it too). Measured on 2026-11-20: uv 0.8.17, 0.9.16, 0.9.17,
0.11.16 and 0.12.5 fail; 0.12.6, 0.12.7 and 0.13.9 build the project.

For a project whose source you trust:

- `supply-chain-allow-build uv sync` built it on uv 0.8.17 and 0.12.5. It
  lifts `no-build` for that one command and keeps the other uv settings. That
  also lets the command build any dependency that ships only an sdist, and
  the helper lists what it built. The role installs the helper; the action
  and `harden.sh` do not.
- Or upgrade uv to 0.12.6 or later.

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
