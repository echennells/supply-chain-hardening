# Verifying what actually enforces

Writing a config file is not the same as a protection being in effect. Every
protection failure this project has shipped had the same shape — the file was
exactly what we intended, the tool ignored it, and the run reported success:

| | |
|---|---|
| yarn `npmMinimalAgeGate: "2d"` | read as 2 minutes on yarn 4.10; no warning |
| yarn `npmMinimalAgeGate` below yarn 4.10 | key does not exist; ignored in `~/.yarnrc.yml` without a word |
| npm `MINIMUM_RELEASE_AGE` | a key npm does not read |
| pnpm 11 | stopped reading `rc` / `npmrc` entirely |
| pnpm 10 `block-exotic-subdeps` | ignored below 10.26.0; from 10.26.0 honoured only in `rc` (a direct exotic dependency is allowed by design, so `pnpm add <tarball-url>` proves nothing either way) |
| bun `ignoreScripts` | bunfig not loaded for `bun run`; and inert in ANY bunfig below bun 1.2.0 |
| bun `minimumReleaseAge` | key does not exist below bun 1.3.0 — accepted and ignored |
| bun's whole bunfig | on bun 1.3.0 through 1.4.3, one bad value (a quoted `minimumReleaseAge`) makes bun reject the entire file, exit 1. bun 1.4.4 accepts a quoted duration, which the verifier reports as WEAK |
| npq on Node < 20.13 | passes through to npm and exits 0 |

Grepping our own files catches none of these. So the role ships a verifier that
asks the **tools** what they ended up believing, on the real host, against the
real installed versions:

```bash
supply-chain-verify           # what is actually enforcing right now (scannable, one line per row)
supply-chain-verify --verbose # the full rationale behind each row
supply-chain-verify --strict  # also fail on any WEAK row (PRESENT-only, or in effect with a stated caveat)
supply-chain-verify --json    # machine-readable; exit is non-zero on any GAP, so it doubles as a CI pre-install gate
```

```
STATUS EVIDENCE    PROTECTION                       DETAIL
OK     PARSED      npm lifecycle scripts blocked    npm reports ignore-scripts=true
GAP    PARSED      yarn age gate                    yarn 4.1.0 has no npmMinimalAgeGate (needs Yarn 4.10.0), so the...
GAP    FUNCTIONAL  npq reputation checks            installed but SUPPRESSED on Node v18.19.1
WEAK   PRESENT     npm PATH wrapper                 wrapper installed; callers bypassing PATH unaffected
```

Every row states **how** it was established, because that is the whole point:

- **FUNCTIONAL** — we ran the protection and observed its behavior. Strongest.
- **PARSED** — the tool reported the setting back to us. Proves it read the file,
  recognized the key, and accepted the value — which is what all six failures
  above violated.
- **PRESENT** — a file or binary exists and nothing more. This is the evidence
  level that produced every bug in the table, so these rows are reported as
  `WEAK` rather than counted as coverage.

`WEAK` is not only a PRESENT-only row. A protection the tool did report, or that
was observed working, is also `WEAK` when the row names a caveat: a cutoff weeks
old, a narrow exemption list, a value that is also the tool's default. The
footer gives both numbers: how many rows are `WEAK`, and how many of those were
verified only as PRESENT.

It runs at the end of every apply and is installed as a standalone command, so
you can re-check at any time — including long after the apply, when tool
versions have drifted underneath the config. That drift is how several of these
bugs arrived. Set `verify_fail_on_gap=true` to make a gap fail the play; use it
on CI images and any host where agents run untrusted installs. Exit status is 0
when there are no gaps, 1 otherwise, so it drops into a health check directly.

This is a different question from the end-of-run coverage summary, which reports
which *tasks skipped*. Five of the six failures above happened in tasks that
completed successfully.

## `--json`

`supply-chain-verify --json` and `action/verify.sh --json` print one JSON
document on stdout instead of the table. Warnings and annotations go to stderr.
The exit code is the same as without `--json`. A real one, from the test
container on Node 22: [verify-json-example.json](verify-json-example.json).

| Field | Meaning |
|---|---|
| `surface` | `role` (`supply-chain-verify`) or `ci` (`action/verify.sh`). |
| `scope` | `on <hostname>` or `in this job`. |
| `generated` | When this run happened, UTC. |
| `declared_intent_recorded` | The day the role recorded what this host asked for (the date of the apply), so a GAP can be read against it. `null` on `ci`, which reads the record harden.sh wrote in the same job. |
| `min_age_hours` | The age window the host or job promised, in hours. `null` when nothing recorded one. |
| `result.gaps` | Rows whose status is `GAP`: a protection that was asked for and is not in effect. Non-zero means exit 1. |
| `result.weaks` | Rows whose status is `WEAK`: not counted as coverage. Either only `PRESENT` evidence, or in effect with a caveat the row states. `--strict` fails on these. |
| `result.ok` | Rows whose status is `OK`: verified at the row's evidence level. |
| `result.na_design` | `N/A` rows with evidence `BYDESIGN`: this host's configuration (or this job) never asked for it. |
| `result.na_absent` | The other `N/A` rows: nothing here to check, because the tool is not installed or the project config the row looks for is not here. Evidence `-` on `role`, `ABSENT` on `ci`. |
| `result.tools_seen` | The tools that at least one `OK`, `WEAK` or `GAP` row judged, in row order: the first word of the row's protection, with `Socket Firewall` as `sfw`. Rows about the run or the host are not tools: `env layer propagation`, `env JVM user home`, `hardening run record`, `ci id-token exposure`, the `<token> coverage` rows, and `python startup hooks`, a scan that runs wherever a system Python is. `npq` and `sfw`, whose absence is itself a `GAP` row on `role`, count only when they are installed. |
| `rows[]` | One object per table row, in table order: `status` (`OK`, `GAP`, `WEAK`, `N/A`), `evidence` (`FUNCTIONAL`, `PARSED`, `PRESENT`, or `-`, `ABSENT`, `BYDESIGN` on `N/A` rows), `protection`, and `detail` (the full rationale, as `--verbose` prints it). |

The counts are tallied from `rows`, so they always add up:
`gaps + weaks + ok + na_design + na_absent` is the number of rows.

**Read `tools_seen` before `gaps`.** An empty `tools_seen` means no package
manager was checked, whatever `gaps` says: a host with nothing installed has
`"gaps": 0` too. `ok` can be 1 there, from the `python startup hooks` scan. Then
compare `tools_seen` with the package managers the host or job is supposed to
have.

## Run it from the shell you want checked

The verifier reports what the shell it runs in gets, and an agent's shell can
get less than a login. MEASURED on two agent VMs (2026-11-26): one runner
started every command as `bash --norc --noprofile -c`, as root with
`HOME=/home/hatch` (root's passwd home is `/root`) and no home directory on
`PATH`; the other replayed a shell state saved once per session
([Agent runners](design-principles.md#agent-runners)). So run it the way the
agent runs its commands, and read these rows:

| Row | What it says |
|---|---|
| `env layer propagation` | On `role`: whether the variables `/etc/profile.d/supply-chain-hardening.sh` exports are set here. `OK` all, `WEAK` some (a shell that got `/etc/environment` only, or a shell state saved before the last apply), `GAP` none: this shell loaded no startup file. The config files still apply; the variables do not. On `ci`: the variables in harden.sh's env file, as before, and `N/A BYDESIGN` after `harden.sh --home-only`, which writes no env file. |
| `env JVM user home` | `WEAK` when gradle (with `GRADLE_USER_HOME` unset) or maven is installed and `HOME` is not the passwd home of this uid. The JVM takes `user.home` from the passwd entry, so they read that home, not files under `HOME` (measured for gradle; inferred for maven). No row otherwise. |
| `<tool> on this shell's PATH` | `WEAK` when the rows for a tool grade a binary a bare call here does not run: the verifier also looks in a few fixed places (`~/.local/bin`, `~/.bun/bin`, `/usr/local/go/bin`, ...), and found it only there, or a copy there now comes first. No row when `PATH` finds the same file. |

A tool too old for a setting is a `GAP` as before (npm, pip, yarn, pnpm, poetry);
its detail now also says where the tool is when this account cannot change it:
`read-only (image-owned?)` for root, or the account that owns the directory.

A uv `exclude-newer` span (`"48 hours"`) is `OK` when it covers the window and
every uv on this `PATH` is 0.9.17 or newer: older ones reject the whole file. A
pip `uploaded-prior-to` duration (`P2D`) is `OK` on pip 26.1 or newer, and
`WEAK` below that, as before.

The role's own run at the end of an apply is ansible's process, not anyone's
shell, so it sets `SCV_APPLY_RUN=1`: the env layer row is `N/A` there and the
`PATH` rows are left out. After `harden.sh --home-only`, the fixes the rows give
say to re-run it in that mode.

## Don't run it on a host you suspect is compromised

The verifier starts `python3` and `pip`, and a malicious wheel's `.pth` or
`sitecustomize.py` hook runs on every interpreter start. Microsoft and JFrog both warn
against starting Python in an environment suspected of the LiteLLM compromise. If you
think a host is already affected, inspect it with tools that don't start that
interpreter, from a known-clean machine where possible, and rebuild rather than verify.

Before its first normal Python start, the verifier reads the site-packages directories
of the interpreters it is about to run, as plain files, and warns on stderr about any
startup hook that nothing vouches for. The same finding is a WEAK `python startup hooks`
row. Hooks it recognises are listed in an OK row instead: files unchanged from a Debian
package, and `.pth` lines that match what setuptools, virtualenv/uv or an editable
install generate. Matching a line says nothing about the module it imports, so read
that list too. To find an interpreter's directories it asks the interpreter with
`-I -S`, which skips `site` and so runs no hook. None of this shows the host is clean,
and the checks after it still start Python.

## It never runs code a checkout supplies

Run it from inside a project and it reports what that project's own config
changes. It does that without running the project's code, so it is safe to run
in a repo you have not reviewed. The rule: **each tool is asked about itself
from `/`, and what a project changes is read from its files** (or through an
option that names the directory, such as `dotnet nuget config
--working-directory`). A tool still runs in the project only where it was
measured to read nothing there but settings.

This matters because tools read files from the working directory and every
directory above it, and several of those files name code that runs on any
command, `--version` included. MEASURED, each with a marker file the checkout
writes:

| Tool | What in a checkout runs | Now |
|---|---|---|
| yarn 1.22.22, 4.1.0 to 4.19.0 | a `.yarnrc.yml` `yarnPath` or `plugins:` in any directory above (and classic's `.yarnrc` `yarn-path`), on `yarn --version` and `yarn config get` | asked from `/`; the `yarn repo config override` row reads the files |
| corepack 0.36.0 (Node 24) | a project `.corepack.env` pointing `COREPACK_NPM_REGISTRY` at any server, or allowing a `packageManager` URL: the yarn it served ran on `yarn --version` | `COREPACK_ENV_FILE=0` for everything the verifier starts |
| pnpm 10.34.9, 11.0.0, 11.28.13 | `.pnpmfile.cjs` and `configDependencies`, on `pnpm config get` | asked from `/`; the `pnpm repo config override` row reads the file |
| rustup 1.29.3 | a `rust-toolchain.toml` `path =`, on `cargo --version` and `rustc --version`, even for the proxy called by its full path (the path has to be absolute, which a CI checkout's predictable location allows) | asked from `/` |
| maven 3.10.0 | `.mvn/jvm.config` in any directory above (a `-javaagent`), on `mvn -v` | asked from `/` |
| .NET SDK 10.0.404 | a `global.json` sdk `"paths"` entry: the checkout's own SDK ran on `dotnet --version` and `dotnet nuget config paths` | dotnet runs from `/`; NuGet is told the project with `--working-directory` |
| pip 25.1.1 (Python 3.13) | a `pip.py` or `pip/` beside it, on `python3 -m pip --version` | asked from `/`; pip reads no settings from the working directory |
| go1.24.10 | a `go.mod` `toolchain` line: go fetched and ran go1.25.4 for `go env` | asked from `/` |
| Poetry 2.5.2 | the project's `.poetry/plugins` (what `poetry install` makes from `[tool.poetry.requires-plugins]`), on `poetry --version` and `poetry config` | `--no-plugins`; still reads the project's `poetry.toml` |

Measured to read only settings in a project, so still asked there: npm 9.2.0,
10.9.4, 11.19.1 and 12.2.3 (`config get`; `onload-script` is gone, `node-options`
does not apply to npm itself), uv 0.13.9 (`pip list --show-settings` never
starts the project's `.venv` interpreter, which a plain `uv pip list` does),
Bundler 4.1.0 (`config get` and `--version` do not evaluate the `Gemfile`, which
`bundle check` does), and composer with `--no-plugins` and no project file.
`gradle --version` (8.14.3, 9.2.1) reads neither `org.gradle.jvmargs` nor
`org.gradle.java.home`, and deno 2.9.8's `--version` and argument checks read no
`deno.json`; both are asked from `/` anyway.

**yarn.** The `yarn repo config override` row reads every `.yarnrc.yml` from the
working directory up to `/` (the nearest winning, as yarn merges them) and judges
`npmMinimalAgeGate`, `enableScripts` and `npmPreapprovedPackages` the way the yarn
that runs there reads them: 4.10.x takes a value's leading integer (`"2d"` is 2
minutes), 4.11+ reads a duration and refuses anything it cannot parse. A
`yarnPath`, `plugins:`, or classic's `yarn-path` is the checkout's own yarn code,
which runs on every yarn command there, `yarn install` included; the row says so,
and grades that yarn by the version string inside the file (below 4.10 it has no
age gate: `GAP`). Through a corepack shim, the yarn graded is the one corepack
runs: `packageManager` read as JSON, from the nearest `package.json` that has one,
or else `devEngines`. A version it cannot pin down is `WEAK`. The values come from
files, so the evidence is `PRESENT`. Where the yarn that runs in the project is
not the host's, the host rows say so, and a classic host yarn, which hands such a
project to its `yarnPath`, is `N/A` there rather than a `GAP`.

**pnpm on this host.** `pnpm lifecycle scripts blocked` and `pnpm age gate` are what
pnpm itself reports, asked from `/` with the variables the hardening exports set
aside, so the value came from a file pnpm read. A file pnpm does not read is a `GAP`,
whatever is in it: MEASURED on GitHub's macos-15, where pnpm reads
`~/Library/Preferences/pnpm` and the hardening wrote `~/.config/pnpm`. The age gate
below pnpm 10.16.0 is a `GAP` too, because those versions print the key back and
enforce nothing (10.15.1 installed, 10.16.0 refused).

**pnpm in a project.** The `pnpm repo config override` row reads the `pnpm-workspace.yaml` pnpm
would use (and, for pnpm 10, a project `.npmrc`) and judges `minimumReleaseAge`,
`minimumReleaseAgeExclude` and `minimumReleaseAgeStrict`.

**A file it does not follow is "not judged", never "sets nothing".** The files
belong to the checkout, and the tools accept spellings a simple reader misses:
MEASURED, an escaped, tagged or aliased key, an indented top level, `--- {key: v}`,
a byte-order mark and a lone CR are all honoured (pnpm 11.29.0, Yarn 4.18.1; not
every form on both). With PyYAML these are parsed. Without it, a plain-key reader
refuses any top-level line it does not follow, and the row is `WEAK`. So is a file
with a U+0085, U+2028 or U+2029 line separator, which YAML 1.1 and 1.2 read
differently, a `.yarnrc.yml` marked `# yarn lockfile v1`, which Yarn parses by
Yarn 1's rules, and an escaped key in a project `.npmrc` or `.yarnrc`. `--strict`
fails on a `WEAK` row.

**Scratch directories.** The probes that build throwaway projects used to run in
`mktemp -d` under `/tmp`, which every account can write. A file planted there sits
above all of them, and was read: MEASURED, `/tmp/.mvn/jvm.config` ran in the maven
probes, `/tmp/rust-toolchain.toml` in a `cargo --version` there,
`/tmp/Directory.Build.props` in the nuget restore probe, and a `/tmp/package.json`
workspace root's install scripts in the bun probe (bun 1.3.0; 1.4.5 did not). Now
the scratch directory comes from a base that only root and you can write, all the
way up to `/` (`TMPDIR`, `RUNNER_TEMP`, `~/.cache/supply-chain-hardening`, macOS's
per-user temp dir from `getconf DARWIN_USER_TEMP_DIR`, then `XDG_RUNTIME_DIR`),
never one inside the working directory. `TMPDIR` points into it for every tool the
verifier starts, and the probes name it in their `mktemp` template, because
Apple's `mktemp` with no template uses the per-user temp dir and ignores `TMPDIR`.
With no such base, as when `HOME` itself is under `/tmp` on Linux, the probes run
under `TMPDIR` as before and stderr says so; point `TMPDIR` at a directory of your
own. A Mac always has one.

`action/harden.sh` follows the same rule: the action runs it in the job's
checkout, and it asks each tool its version from `/`. `harden.sh --suggest`
only reads files.

## Related

- [how-it-works.md](how-it-works.md) — the layers the verifier is checking.
- [limitations.md](limitations.md) — the gaps it will report and why they exist.
- [design-principles.md](design-principles.md) — Axis 4, "File-content tests vs behavioral tests": why PRESENT-only evidence is counted as WEAK.
- [../TESTS.md](../TESTS.md) — the test suite that exercises the verifier itself.
