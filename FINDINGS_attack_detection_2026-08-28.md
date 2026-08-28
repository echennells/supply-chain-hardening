# Attack-detection research — 2026-08-28

Produced by an 11-agent research workflow (1.2M tokens, 421 tool calls) on branch
`feat/ci-hardening`. Four per-ecosystem behavioural-test designs, each put through
an adversarial reviewer whose job was to REFUTE it, plus two threat-landscape
analyses.

**The headline is not the tests.** The threat analysis found that several of our
defences are aimed at the wrong layer — a well-tested wrong defence is worse than
an untested right one. Those findings are in part 2 and are ranked at the end.

**Verified independently before publishing:** `BUNDLE_COOLDOWN` is real —
`cooldown` is in `Bundler::Settings::NUMBER_KEYS` on bundler 4.0.19, and appears
in cli.rb / dsl.rb / settings.rb / definition.rb. Note that `bundle config get
cooldown` is NOT evidence: it echoes any key, including `totally_fake_key`,
exactly like `npm config get`.

## Adversarial verdicts on the four test designs

| Ecosystem | Verdict | Would pass against BROKEN hardening? |
|---|---|---|
| go | NEEDS_FIXES | **No** — mutation-tested, genuinely differential |
| yarn | NEEDS_FIXES | **No** — differential |
| deno | NEEDS_FIXES | **YES — unsound as designed** |
| nuget | NEEDS_FIXES | **YES — unsound as designed** |

---

# Part 1 — Untested attack classes

## Scope of what exists today

Two suites, plus three sign-off workflows:

- **`.github/workflows/action-smoke.yml`** — 33 jobs, real runners, the only thing that exercises `action.yml` packaging. This is where FUNCTIONAL evidence lives.
- **`tests/ci/*.bats`** — 7 files, host-local, `env -i`, `WRITE_ETC=false` throughout, 10 of 14 ecosystems are stub binaries. Its own `helpers.bash` header states the limits: no `action.yml`, no `/etc` layer, "proves what the wrappers EMIT, never that the real tool accepts it."
- `ci-script.yml` (bats on ubuntu+macOS), `pnpm-signoff.yml`, `cargo-apt-signoff.yml`, `coverage-matrix.yml` (advisory, never fails).

Evidence strengths below use this repo's own vocabulary (`files/verify-probes.sh`): FUNCTIONAL = watched the tool act; PARSED = the tool reported its own setting back; PRESENT = the file we wrote contains the key.

Baseline for contrast — **install-time lifecycle execution is the one class tested properly**: `action-blocks-postinstall`, `action-blocks-real-npm-package` (bcrypt native bindings), `action-blocks-pnpm-project-script`, `action-blocks-composer-script`, `action-blocks-bun-auto-install`, `action-blocks-bunx`, `action-blocks-uv-sdist`, plus `05-behavioral.bats` with a negative control ("the same postinstall DOES run unhardened"). All FUNCTIONAL, all with a marker file. Nothing else in this repo is tested to that standard.

---

## 1. Build-time code execution that is not an install script — UNTESTED except Python

| Path | Coverage |
|---|---|
| Python sdist / `setup.py` | **FUNCTIONAL.** `action-blocks-uv-sdist`, `05-behavioral.bats:103`, plus `action-pip-only-binary-limitation` which documents the local-file gap honestly |
| cargo `build.rs` / proc-macro | **NONE action-side.** `harden.sh:1161` admits it cannot be blocked. The only `build.rs` test in the repo is `tests/bats/18-cargo-behavioral.bats` — role suite, container-only, and it `skip`s if the script doesn't fire. The action's cargo jobs (`action-cargo-config` PRESENT, `action-cargo-locked` FUNCTIONAL) test *resolution*, never *execution* |
| Gradle plugins / `buildscript` classpath | **NONE.** `init.gradle.kts` constrains `allprojects.repositories` URL scheme and dynamic versions only; `settings.gradle` `pluginManagement` is a different repository scope that block does not reach. A pinned-version malicious plugin executes at configuration time |
| Maven build plugins | **NONE.** `settings.xml` governs *where* artifacts come from, not that a plugin resolved over HTTPS executes during `mvn package` |
| MSBuild `.targets`/`.props` auto-imported from a restored NuGet package | **NONE.** Zero hits for `msbuild`/`.targets`/`.props` anywhere in the repo. `action-nuget-behavioral-cert-valid` runs `dotnet restore` and stops there — it never runs `dotnet build` |
| Ruby `extconf.rb` | **NONE action-side.** `tests/fixtures/ruby-extconf-gem` exists and is consumed only by `tests/bats/` |

Testable: yes, cheaply. Same shape as the existing fixtures — marker file dropped at *build* time, assert present/absent. For cargo/gradle/maven/nuget the honest outcome is "not blocked", so these belong as **documented-limit jobs** in the style of `action-pip-only-binary-limitation`: that converts an unstated hole into an asserted fact and catches the day the claim changes.

## 2. Dependency confusion / source substitution — UNTESTED end to end

- **uv** `index-strategy = "first-index"`: verifier row exists but is capped at WEAK/PARSED *by design* (`verify-probes.sh:1025` — "FirstIndex is ALSO uv's default… not evidence our config was read"). No smoke job at all.
- **nuget** `<clear/>` + single source: PRESENT only (`action-bundler-maven-gradle-nuget-configs` greps the XML). `NuGet.Config` merges up the directory tree, so a checked-in config beside the `.sln` re-adds sources over ours — untested. The one behavioral nuget job proves restore *succeeds*; there is no negative control proving an untrusted source or signature *fails*.
- **npm / pnpm / yarn / bun**: nothing is written and nothing is tested. No `registry=` pin, no `@scope:registry`. A repo-authored `.npmrc` pointing a scope at an attacker registry is unopposed.
- **go**: `GOPROXY`/`GOSUMDB` pinned and `GOPRIVATE`/`GONOPROXY`/`GOINSECURE` deliberately emptied; `action-go-persisted-without-env` proves the *values* survive (FUNCTIONAL for persistence) but never that a substitution attempt is refused.

Testable: this is the easiest class to test hermetically. A local index on `127.0.0.1` serving a higher version of a name that also exists upstream, assert the tool takes the pinned index. No external network.

## 3. Registry MITM and plain-HTTP — half the class tested, and it is the easy half

- **maven: FUNCTIONAL and genuinely good.** `action-maven-behavioral-https-only` declares an `http://` repo, forces resolution through it with a dependency that exists nowhere else, and asserts the blocked-mirror error.
- **gradle: PRESENT only.** The `throw` on `http://` is in the init script; the one gradle job (`action-gradle-behavioral-dynamic-version`) exercises only `failOnDynamicVersions`. `verify.sh` has a FUNCTIONAL "gradle HTTPS-only repos" row, but no job drives it. Side note: that job passes `--init-script "$HOME/.gradle/init.gradle.kts"` explicitly, so it does not prove auto-discovery from `GRADLE_USER_HOME` — the thing the long passwd-home comment in `harden_gradle` exists to get right.
- yarn `unsafeHttpWhitelist: []`, composer `secure-http`, uv `allow-insecure-host = []`: PRESENT only.
- npm / pip / bun / cargo: no plain-HTTP control written at all.
- **Actual MITM, as opposed to plain-HTTP: nothing, anywhere.** `grep -rn 'HTTPS_PROXY\|HTTP_PROXY\|NODE_TLS_REJECT\|NODE_EXTRA_CA\|CURL_CA\|trusted-host\|PIP_INDEX_URL\|GIT_SSL' action/ files/ tests/ .github/` returns **zero hits**. A later step exporting `HTTPS_PROXY` + `NODE_TLS_REJECT_UNAUTHORIZED=0` reroutes every npm fetch through an interceptor; `harden.sh` doesn't pin it, `verify.sh` doesn't report it, no test covers it.

Testable: the cheap first move is not a TLS fixture — it is making `verify.sh` fail when those env vars are set, then testing *that*.

## 4. Lockfile tampering and resolution drift — DRIFT tested twice, TAMPERING untested everywhere

- **Drift, FUNCTIONAL:** `action-cargo-locked` (stale `Cargo.lock` refused, with a check that it failed *for the lockfile reason*) and `action-bundler-behavioral-frozen` (out-of-sync `Gemfile.lock` refused). Eight argv-level tests in `04-wrappers.bats:204-273` for `--locked` placement.
- **Drift, PRESENT only:** pnpm `preferFrozenLockfile`, yarn `enableImmutableInstalls`/`enableImmutableCache`, bun `frozenLockfile`. **npm has no drift control at all** — nothing forces `npm ci`, and `save-exact` only affects writes.
- **Tampering — an edited `resolved` URL or `integrity` hash inside a committed lockfile — is untested for every ecosystem.** The controls exist on paper (yarn `checksumBehavior: throw`, pnpm `verifyStoreIntegrity`, nuget signature validation) and every one is PRESENT-strength.

Note the direction of risk: `--locked` / frozen / `preferFrozenLockfile` make a *poisoned* lockfile more authoritative. This is a class the hardening actively increases exposure to and does not test. Testable offline in one job per ecosystem: flip one integrity hash, assert the install fails.

## 5. The age gate bypassed by a caller flag — UNTESTED as a class

**(a) The action's own inputs that disarm it** are tested at PRESENT only. `action-pnpm-allowlist-input` greps the two files it just wrote; `composer_allow_plugins` is `03-config-files.bats:146` (grep) + `04-wrappers.bats:306` (argv). `SUPPLY_CHAIN_HARDEN_SKIP` is tested at the outputs level (`action-per-step-skip`, `02-validation.bats:50,57`); `release_age_hours=0` is properly refused (FUNCTIONAL).

A live instance this blind spot is hiding: with `pnpm_built_dependencies: esbuild`, `harden_pnpm` writes `ignoreScripts: false` **plus** `onlyBuiltDependencies:` into `~/.config/pnpm/config.yaml` — while `harden.sh`'s own comment 12 lines below says pnpm 11 **rejects** `onlyBuiltDependencies` from the global config. The role does the opposite deliberately: `tests/bats/37-pnpm-allowlist-hardening.bats:167` — *"config.yaml stays strict (pnpm 11 allowlists per-project)"* — asserts `ignoreScripts: true` in the allowlist branch. So on pnpm 11 this input plausibly turns blanket script blocking off with no allowlist replacing it, and the only test greps for the exact `ignoreScripts: false` line it emits, so it passes. `tests/ci/parity.py` compares key *names*, not values, so parity can't see it either.

**(b) A later step's own CLI flag outranking what we set.** Every control here sits at a precedence level a command-line flag beats (npm: CLI > env > `~/.npmrc`), and the deno wrapper inserts `--minimum-dependency-age` immediately after the subcommand, so a user-supplied later occurrence wins on any last-wins parser. **Not one test in either suite passes a hostile flag to a hardened tool.** The cargo wrapper's `has_resolution_flag()` is the one place the code deliberately yields to a caller flag, and `04-wrappers.bats:241` asserts the yield happens — never that yielding is safe.

Testable: trivially. Re-run each existing FUNCTIONAL block job with the counter-flag appended; assert the marker still does not appear.

## 6. Post-hardening subversion — one narrow vector tested, the class is not

**Tested, FUNCTIONAL:** `action-verify-catches-post-hardening-shadowing` — harden, then `setup-node@v4` installs Node 20 in front of the wrapper, then `verify.sh` must not print `OK … npm PATH wrapper` and must say shadow/not-deployed. Unit mirrors at `07-verify.bats:41,54,65`.

**Untested, all of it:**

- A later step rewriting the **config layer**: `npm config set ignore-scripts false`, `echo ignore-scripts=false >> ~/.npmrc` — or `actions/setup-node` with `registry-url:`, which rewrites `~/.npmrc` as routine behaviour.
- A later step re-exporting a hardened var to a weak value. `DOTNET_NUGET_SIGNATURE_VERIFICATION=false` is the sharpest: `harden_nuget`'s comment says MEASURED that this single var disarms `signatureValidationMode=require` on every SDK, and it is pinned `true` *specifically* so a later `=false` is not the last word — and nothing tests a later `=false`.
- Deleting the wrapper, or restoring `<tool>-real` over it.
- `go env -w GOFLAGS=` undoing the file layer `action-go-persisted-without-env` proves.
- **Repo-local config outranking the `$HOME` layer**: `.npmrc`, `bunfig.toml`, `cooldown.toml`, `.cargo/config.toml`, `NuGet.Config`, `composer.json`, `.yarnrc.yml`, `pyproject.toml [tool.uv]`. `harden.sh` names the repo-local `cooldown.toml` as a bypass in its own comment ("treat a committed cooldown.toml in an untrusted repo as a hardening bypass"). `verify.sh` has exactly **one** probe for this whole family — `composer repo config override`, PARSED — and nothing anywhere constructs a hostile repo.

The asymmetry is the finding: the suite tests the one subversion vector that arrives *by accident* (a toolchain installer) and none of the ones an attacker would *choose*.

## 7. The env layer failing to propagate — WELL TESTED

Best-covered non-obvious class in the repo. FUNCTIONAL at four levels: `action-defaults` reads the vars in a separate later step; `action-go-env-set`; `action-go-persisted-without-env` strips every exported var with `env -u` and proves the `go env -w` file layer holds alone; `action-emit-plain` sources the env file under `env -i bash` and asserts round-trip through `printf %q`. Unit: `01-emit-targets.bats:130` ("config layer survives a step boundary with no env at all") and `:143`; `05-behavioral.bats:130`; both directions of the verifier's own propagation row at `07-verify.bats:18,25,35`. The residue — gitlab/circleci/azure/buildkite tested only at "wrote to the correct sink" — is a per-platform gap, not an untested class, and `action/README.md` already declares it.

---

## Three more whole classes the brief didn't name, also untested

- **Fetch-and-execute entry points other than `bunx`.** `bunx` got a wrapper and four tests only because finding V5 named it. `grep -rn 'npx\|dlx\|uvx\|pipx\|go run\|dotnet tool' action/ files/ .github/` returns **zero** hits outside a passing mention of npx in a comment. `npx` matters most: it fetches a package and executes its declared `bin`, which is not a lifecycle script, so `ignore-scripts=true` does not touch it. Same hole, same ecosystem family, no wrapper and no test.
- **Wrapper bypass by direct path.** Every wrapper leaves the real tool executable at `<tool>-real` in the same directory. The cargo wrapper's own header says cargo re-exports `$CARGO` as the resolved real path, so build scripts and third-party subcommands re-enter unwrapped. Nothing tests that this bypass exists (it does) or is bounded.
- **The `/etc` layer.** `write_etc: true` is the default; total coverage is `sudo grep -q ignore-scripts=true /etc/npmrc` (PRESENT). Its stated purpose is `sudo npm install`, and no test runs any package manager under sudo or as another user. `tests/ci/helpers.bash` forces `WRITE_ETC=false` and says so.

---

## Highest-value untested attack class

**Post-hardening subversion of the config and env layers — above all, attacker-controlled repo content outranking the `$HOME` layer.**

1. **It attacks the product's actual claim.** `action.yml` promises "Defenses apply to every step after this action runs." That guarantee is temporal, and exactly one accidental vector of the temporal class is tested. Every deliberate one is untested.
2. **It is the cheapest attack in the list.** No malicious package, no registry, no timing window — one line in a later workflow step, or one file in the PR branch. Compare with build.rs (needs a crate) or MITM (needs a proxy).
3. **The repo-local half sits on CI's real trust boundary.** This action runs on `pull_request`. A `.npmrc`, `bunfig.toml`, `cooldown.toml` or `NuGet.Config` in the branch is untrusted input that outranks everything `harden.sh` wrote — and `harden.sh` says so itself for cooldown.toml, then ships no test.
4. **It is the one place where the designed answer is untested.** `verify.sh` is the mitigation: run it late and it catches drift. Its wrapper-shadowing path has real adversarial coverage; its config-layer and repo-override paths have almost none — one PARSED composer row. Nothing proves `verify.sh` notices a rewritten `~/.npmrc`, a re-exported `DOTNET_NUGET_SIGNATURE_VERIFICATION=false`, or a hostile repo-local config. The failure mode is a silent false green from the tool whose entire job is to prevent silent false greens.
5. **It is the cheapest class to close.** Most tests need no new fixtures: harden → do the hostile thing in a later step → re-run an existing block fixture → assert still blocked, or assert `verify.sh` reports the GAP. The existing shadowing job is the template; it needs siblings, not invention.

Concrete first three jobs, in order: (i) harden, then `echo 'ignore-scripts=false' >> ~/.npmrc` in a later step, then run the `npm-postinstall-pkg` fixture — assert blocked, or assert `verify.sh` flags it; (ii) harden `nuget`, then export `DOTNET_NUGET_SIGNATURE_VERIFICATION=false`, assert `verify.sh` reports a GAP rather than reading its own config back; (iii) drop a `cooldown.toml` and a `.cargo/config.toml` into the checkout before `uses: ./action`, then assert the cargo gate and `verify.sh` both account for the repo-local override.

Relevant paths: `/workspace/action/harden.sh`, `/workspace/action/verify.sh`, `/workspace/files/verify-probes.sh`, `/workspace/.github/workflows/action-smoke.yml`, `/workspace/tests/ci/`, `/workspace/tests/fixtures/`, `/workspace/tests/ci/parity.py`, `/workspace/tests/bats/37-pnpm-allowlist-hardening.bats`.

---

# Part 2 — Under-researched ecosystems: what they face vs what we deploy

# Under-researched ecosystems: what they actually face vs. what we deploy

The headline: **three of the four are defending the wrong layer, and the fourth (Bundler) is defending nothing at all while breaking builds.** The pattern is consistent — we ported the *transport-integrity* controls from each ecosystem's official docs (HTTPS, checksums, signatures, source pinning) and skipped the *execution* and *resolution* controls, which is where every documented real-world attack in all four ecosystems actually lands. Meanwhile our own house doctrine — README.md:298-300, "attack the step before it: refuse to resolve the malicious version at all" — is applied to npm/pip/cargo/bun and to none of these four, even though one of them (Bundler) got a native cooldown three months ago.

---

## Bundler / RubyGems

**Documented attack class: compromised package + typosquatting, detonating via install-time script execution (`extconf.rb`).** This is not theoretical or historical — it is the most active of the four right now. The BufferZoneCorp campaign (May 2026, and already in our own SOURCES.md) embedded credential-harvesting in `extconf.rb`, which RubyGems runs during native-extension compilation on `gem install`, before the developer ever `require`s the gem; the payload filtered env vars for `token`, `key`, `secret`, `aws`, `github`, `api`, `auth` and read SSH private keys. The August 2026 StubMaker campaign published 16 typosquatted gems on a single day (2026-08-16), again using an `extconf.rb` hook, this time to pull a 22 MB Rust loader from a GitHub release. Before those, the August 2025 campaign was 60 gems / 275k downloads. Dependency confusion is essentially a non-issue here (flat namespace, single registry); registry MITM is a non-issue (rubygems.org is HTTPS-only and Bundler already validates RubyGems-supplied checksums by default).

**What we deploy defends none of it.** `tasks/bundler.yml:18-20` and `action/harden.sh:1569-1571` write exactly three keys, and per Bundler's own config reference:

- `BUNDLE_DEPLOYMENT: true` — "Equivalent to setting `frozen` to `true` and `path` to `vendor/bundle`."
- `BUNDLE_FROZEN: true` — strictly redundant with the line above it. `deployment` *is* `frozen`.
- `BUNDLE_DISABLE_EXEC_LOAD: true` — "Stop Bundler from using `load` to launch an executable in-process in `bundle exec`." This is a process-model/compatibility knob. It changes `load` to `Kernel.exec`. The same gem code runs either way, with the same privileges. **It is not a security control and should not be counted as one.**

So of three settings: one is redundant, one is security-irrelevant, and the remaining one (frozen/lockfile enforcement) defends only against silent dependency drift — real, but it does nothing about a poisoned version that is already pinned in the lockfile, and nothing about the install-time execution that is the entire attack.

**Actively counterproductive: `BUNDLE_DEPLOYMENT: true` in a global `~/.bundle/config`.** Deployment mode is a deploy-time flag; we are setting it as a machine-wide default, unconditionally (tasks/bundler.yml:3, "Config deployed unconditionally"). Two consequences the code comments don't mention:

1. Frozen means, verbatim from the docs, "Bundler commands will be blocked unless the lockfile can be installed exactly as written." So `bundle install` in any project without an up-to-date `Gemfile.lock` — a fresh clone that gitignores it, a scaffolded project, anything mid-`bundle add` — hard-fails on this host. There is no advisory mode.
2. The `path` half is the quiet one. Every `bundle install` on the host now vendors into `./vendor/bundle` instead of `GEM_HOME`, for every project, forever. That is an unannounced change to where gems live, and it will surprise someone's CI cache.

The predictable outcome is that an operator deletes `~/.bundle/config` to unbreak their day, which removes the frozen protection too. This is the classic self-disarming config — the same failure mode the repo already reasons carefully about for `UV_NO_SYSTEM_CONFIG` in templates/supply-chain-env.sh.j2:17-26.

**What's missing — and this is the single highest-value change in this whole review: Bundler now has a native cooldown.** Bundler 4.0.13 shipped it on 2026-06-03. It is exactly the control we apply to npm, pnpm, yarn, bun, deno, uv, pip and cargo, and it is exactly the control the README's own cargo reasoning argues for on this precise threat model ("registry compromises of this class are caught and yanked within hours"). Ruby is the ecosystem where execution genuinely cannot be blocked — README.md:296 already says so — which makes refusing to *resolve* the bad version the only lever that exists.

```yaml
# tasks/bundler.yml  — derive from release_age_hours like every other ecosystem
BUNDLE_COOLDOWN: "{{ (release_age_hours / 24) | round(0, 'ceil') | int }}"   # days
BUNDLE_FROZEN: "true"
BUNDLE_DISABLE_CHECKSUM_VALIDATION: "false"   # pin the safe side, see below
# drop BUNDLE_DEPLOYMENT and BUNDLE_DISABLE_EXEC_LOAD
```

Units are **days**, integer — add it to the units table at README.md:112, since that table is the repo's defence against exactly this class of mistake. It needs a version tier: cooldown does not exist below Bundler 4.0.13, and the key is silently ignored there, which is the same accepted-and-inert trap the repo already handles for npm `min-release-age` (harden.sh:485-491) and `COMPOSER_SKIP_SCRIPTS`. `bundle lock`/`bundle cache` only learned `--cooldown` in 4.0.18, so a lock-then-install flow on 4.0.13–4.0.17 is only half-gated.

Three other real gaps:

- **`BUNDLE_DISABLE_CHECKSUM_VALIDATION` is unpinned.** It defaults to `false` (validation on), but it is the exact shape of variable the repo pins elsewhere: a single inherited `true` from a CI image silently disables checksum validation, and nothing in our config denies it the last word. This is the identical argument used for `DOTNET_NUGET_SIGNATURE_VERIFICATION` in templates/supply-chain-env.sh.j2:66-78, applied to a variable we currently ignore.
- **Lockfile checksums are never enabled.** Bundler 2.6 (Dec 2024) added a `CHECKSUMS` section to `Gemfile.lock` via `bundle lock --add-checksums`, which pins the SHA of every gem and refuses an install whose `.gem` doesn't match. It is per-project, so a global config can't turn it on — but it belongs in the README's Bundler guidance as the CI step to add, and it is the only integrity baseline Ruby has.
- **`gem install` is entirely unhardened.** Everything above lives in `~/.bundle/config`, which `gem` does not read. We deploy nothing to `~/.gemrc`. The README notes the sudo gap for Bundler (README.md:288) but not the much more common `gem` vs `bundle` gap — and StubMaker-style typosquats are installed by `gem install` at least as often as by Bundler.

---

## NuGet / .NET

**Documented attack class: typosquatting delivering build-time code execution through MSBuild integration.** This is the well-documented .NET campaign class — ReversingLabs' "IAmReboot" work and the earlier NuGet/MSBuild inline-task campaign. The mechanism: when a package ships a `build/` (or `buildMultiTargeting/`, `buildTransitive/`) folder, NuGet automatically injects an MSBuild `<Import>` for `<package_id>.targets`/`.props`, and that file can carry an inline `<Code>` task that runs on `dotnet build`. Reported behaviour: download a remote executable and run it in a new process. Distribution was typosquatting plus inflated download counts and stolen icons. Dependency confusion is the other documented class (NuGet was in Birsan's original 2021 research; `ConfusedDotnet` exists as tooling for it).

**Your framing in the prompt is correct, and worth stating precisely: NuGet's `install.ps1` is *not* the npm-postinstall equivalent — MSBuild `build/*.targets` is.** `install.ps1`/`uninstall.ps1` are `packages.config`-only and were dropped for PackageReference; `init.ps1` runs only under Visual Studio tooling. On a Linux CI host there is effectively **zero** PowerShell script surface. Which makes README.md:14 wrong in both directions: the table claims "Install script blocking ✗→x" for NuGet, but (a) nothing in `harden_nuget` or `tasks/nuget.yml` blocks any script, and (b) the thing worth blocking isn't a script at all. That row should be removed and replaced with an honest gap.

**What we do deploy, and what it actually defends:**

- **`<clear/>` + single nuget.org source (tasks/nuget.yml:37-40, harden.sh:1818-1821) does not defend dependency confusion the way the comment implies.** Per Microsoft's config-precedence docs, `<packageSources>` is a *collection* element: NuGet loads computer → user → then every directory from drive root down to the solution, and **combines** collections across all of them. `<clear/>` only discards what was found *earlier*. A `nuget.config` in the repo being built is loaded *after* ours and adds its sources on top — Microsoft's own worked example (File A user-level + File D project-level) ends with "both nuget.org and https://MyPrivateRepo/DQ/nuget are available as sources." So what our `<clear/>` actually buys is **sanitising the ambient/CI-runner-inherited source list**, which is genuinely worth having, but it is not a dependency-confusion control. The log line at harden.sh:1856 ("nuget.org only") overstates it.
- **`signatureValidationMode=require` + `trustedSigners` + `DOTNET_NUGET_SIGNATURE_VERIFICATION=true` is the strongest thing in this file, partly by accident.** Because the env var overrides the config in both directions (measured, 6.0.428/8.0.424/9.0.317/10.0.400), it also survives a hostile repo-level `nuget.config` setting `signatureValidationMode=accept` — a `<config>` single-item element that would otherwise win by proximity. Worth noting explicitly in the comment at harden.sh:1843-1852, because it's a bigger win than the one the comment claims. The residual hole: `<trustedSigners>` is a *collection*, so a repo-level config can **add** an `<author>` entry with the attacker's fingerprint and pass validation. Signature validation proves nuget.org origin, not benignity — a compromised-maintainer upload is repo-signed and passes cleanly.
- **Certificate-rotation handling (three fingerprints, tasks/nuget.yml:60-69) is correct and well-commented.** No notes.

**What's missing:**

1. **`<packageSourceMapping>` — Microsoft's actual named defence for dependency confusion**, added in NuGet 6.0, and the thing their security-best-practices page recommends alongside `<clear/>`. Their own recommended user-level shape is:

   ```xml
   <packageSourceMapping>
     <clear />
   </packageSourceMapping>
   ```

   That clear-only form is what belongs in *our* config: it wipes inherited mappings without imposing a pattern set we can't know. The mapping-with-patterns form has to be per-repo, because once you define any `packageSourceMapping`, every package including transitives must match a pattern or restore fails — so it can't be deployed host-wide. Worth adding the clear, and documenting the per-repo pattern block in the README.

2. **Nothing addresses build-time MSBuild execution.** There is no NuGet.Config knob for it; the levers are MSBuild-side. The honest options are `<ExcludeAssets>build;buildMultiTargeting;buildTransitive;analyzers</ExcludeAssets>` per `PackageReference` (breaks any package whose function depends on build logic — most source generators, most analyzers, gRPC tooling), or the global `ImportProjectExtensionProps=false` sledgehammer. Neither is safe to impose host-wide, which means the right deliverable is a Limitations entry saying so plainly: *NuGet packages execute arbitrary MSBuild on `dotnet build`, this role does not and cannot block it, and it is the vector in the documented campaigns.* That is more useful than a table row claiming coverage.

3. **No lockfile enforcement.** `RestorePackagesWithLockFile=true` + `RestoreLockedMode=true` (`dotnet restore --locked-mode`) are the NuGet equivalents of `--frozen-lockfile`, and MSBuild reads environment variables as properties, so `write_env RestoreLockedMode true` is at least a partial CI-side layer (a project property still wins). Worth measuring before shipping — and note it fails hard if no `packages.lock.json` exists, so it likely belongs behind an opt-in input rather than on by default.

4. **No age gate, and none is possible.** cooldowns.dev confirms NuGet has no native cooldown; there's an open feature request. This is a legitimate "cannot", and the README table's blank cell is correct.

---

## Maven

**Documented attack class: typosquatting on coordinates, plus the historical HTTP-repository MITM.** 2025's concrete cases: a package impersonating `scribejava-core` that sat on Maven Central since January 2024 exfiltrating OAuth credentials on the 15th of each month (Socket, March 2025); and `org.fasterxml.jackson.core:jackson-databind` — a **groupId** typosquat of the real `com.fasterxml.jackson.core`, shipping Cobalt Strike beacons. Note the shape: not `jackson-databnid`, but a plausible-looking *namespace* swap, which defeats name-similarity heuristics. There's also the Shai-Hulud v2 spillover (Nov 2025), where `org.mvnpm:posthog-node:4.18.1` carried the npm worm payload into Maven Central via automated npm→Maven rebuilds — a reminder that "Java ecosystem" isn't a hermetic boundary. Classic dependency confusion is comparatively weak here because Sonatype now requires domain-verified groupId ownership.

**Two things about our Maven config, and the second is the serious one.**

First, **`harden.sh`'s mirror (lines 1690-1699) duplicates a Maven default that has been on since April 2021.** Maven 3.8.1 ships `maven-default-http-blocker` in `conf/settings.xml` with precisely `<mirrorOf>external:http:*</mirrorOf>` and `<blocked>true</blocked>` — the same pattern, the same blocked flag. It is not wrong, it is just not new protection on any Maven from the last five years. It's a `checksumPolicy` short of what the role deploys.

Second, **`tasks/maven.yml:28-34` uses `<mirrorOf>*</mirrorOf>` pointed at Maven Central, and that is actively counterproductive.** Three distinct problems:

1. `*` mirrors *everything*, including internal corporate repositories. On a host with an internal Nexus/Artifactory, every request for a private artifact is redirected to `repo.maven.apache.org`. That is an information leak of internal artifact coordinates to a public host — which is precisely the reconnaissance step of a dependency-confusion attack — and if anyone ever registers those coordinates on Central, the redirect delivers them.
2. It doesn't *block* anything. Where the action refuses an HTTP repo, the role silently resolves it from somewhere else. Silent redirection is worse than a hard failure: the build goes green having resolved artifacts from a place nobody declared.
3. Mirror selection returns the **first matching declaration**, and user settings are merged ahead of the global `conf/settings.xml`. A `*` mirror in `~/.m2/settings.xml` is positioned to preempt `maven-default-http-blocker` — meaning our "hardening" file would *downgrade* a protection Maven turns on by itself. **This is the one claim here I have not measured**, and it deserves a `mvn -X` check before it goes in a changelog; but the pattern is wrong on points 1 and 2 regardless of how the ordering resolves. Fix is to adopt the action's shape:

   ```xml
   <mirror>
     <id>central-https-only</id>
     <mirrorOf>external:http:*</mirrorOf>
     <url>https://repo.maven.apache.org/maven2</url>
     <blocked>true</blocked>
   </mirror>
   ```

**Neither surface deploys the union of what the two of them know.** The role has `<checksumPolicy>fail</checksumPolicy>` (tasks/maven.yml:42-49) and no HTTP block; the action has the HTTP block and no checksum policy. Both halves are correct and both should be in both files. Also a parity nit: the role declares the `SETTINGS/1.2.0` namespace, the action `1.0.0`.

**Honest read on `checksumPolicy=fail`:** it's a real improvement over the `warn` default for releases, but it compares the artifact against a `.sha1` served by *the same repository over the same connection*. It catches truncation and partial corruption. It does not catch an attacker who controls the repo or the transport, and it says nothing about a typosquatted coordinate — the Jackson attack's artifacts had perfectly valid checksums.

**What's missing:**

- **Nothing verifies PGP signatures.** Maven Central *requires* publishers to sign, and the Maven client *never checks*. That asymmetry is Maven's biggest structural weakness and it isn't mentioned anywhere in the repo. There's no settings.xml lever — the tooling is `pgpverify-maven-plugin` (per-project). It belongs in Limitations.
- **No defence against version ranges or `LATEST`/`RELEASE`.** Maven has no lockfile at all, so resolution is not reproducible by default. Gradle gets `failOnDynamicVersions()` from us; Maven gets nothing equivalent, and can't from settings.xml — the control is `maven-enforcer-plugin`'s `banDynamicVersions`/`requireReleaseDeps`, per-project.
- **Maven plugins and `<build><extensions>`/`.mvn/extensions.xml` are arbitrary code executed during the build**, and core extensions load before anything else. This is Maven's postinstall equivalent, and it is unaddressed. Same as NuGet: state it in Limitations rather than pretend.
- **No age gate is possible** — cooldowns.dev lists Maven/Gradle as having no native implementation and no filed feature request. Correct blank cell.
- **`~/.m2` is resolved from `$HOME` — the exact bug tasks/gradle.yml was fixed for.** `tasks/maven.yml:13` uses `ansible_env.HOME`, and `harden.sh:1685` uses `$HOME/.m2`. Maven resolves its user config as `${user.home}/.m2/settings.xml`, and `user.home` is the same passwd-derived JVM property that the long comment at tasks/gradle.yml:11-47 correctly identifies as *not* `$HOME`. Every scenario listed there — `docker run -u <uid>`, OpenShift arbitrary uids, `sudo -E`, a connection plugin with its own HOME — silently strands the Maven settings file too. Both surfaces fixed this for Gradle and neither noticed the identical bug in the neighbouring function, in the same JVM, for the same reason. Maven has no `MAVEN_USER_HOME` env var, so the fix is the `ansible_user_dir` half of the gradle resolution (plus `mvn -s <path>` if the action wants belt-and-braces). **This is a found bug, not a research finding, and it invalidates any prior "maven hardening verified" result on a relocated-HOME host.**

---

## Gradle

**Documented attack class: malicious `gradle-wrapper.jar` committed via pull request.** This is the one with a confirmed, named incident: on 2023-01-11 the Gradle team was contacted by MinecraftOnline about two suspicious wrapper JARs added by a new contributor; the JARs' SHA-256s matched no official release, and on invocations beginning with `publish` or `magic` they downloaded and ran a second malicious JAR. The delivery vector was a friendly-looking "Updated to Gradle x.y" PR — a binary blob nobody reviews in a diff. Gradle's response was `gradle/actions/wrapper-validation`, which also hashes homoglyph variants of the filename. Beyond the wrapper, Gradle's structural exposure is that build scripts, `buildSrc`, init scripts, settings plugins and project plugins are all *arbitrary code executed at configuration time*.

**Our init script (tasks/gradle.yml:61-100, harden.sh:1770-1790) checks the wrong repository containers.** `allprojects { repositories { ... } }` covers `project.repositories` — the container for *library* dependencies. It does not cover:

- **`buildscript { repositories { … } }`**, a separate container (`project.buildscript.repositories`) that supplies the plugin classpath. Code from there is *executed*, not just linked.
- **`pluginManagement { repositories { … } }` in `settings.gradle`.** This is evaluated during Settings evaluation, before any `Project` object exists — so an `allprojects` hook is structurally too late. A malicious `settings.gradle` declaring an HTTP plugin repo fetches and executes plugin code with our init script never having had a say.

So the HTTP refusal covers the container where a compromised artifact is *linked*, and misses both containers where it is *run*. Fixes, both available:

```groovy
// covers the plugin classpath
allprojects { buildscript.repositories.all { /* same check */ } }

// covers settings-level plugin resolution; beforeSettings requires Gradle 6.0+
beforeSettings { s ->
    s.pluginManagement.repositories.all { /* same check */ }
}
```

`beforeSettings` is the documented hook for this and is specifically the one that runs early enough — `settingsEvaluated` is too late for `pluginManagement`. Given the repo's `respondsTo()` house rule at tasks/gradle.yml:80-89, guard it the same way.

Two smaller holes in the same check: it tests `repo instanceof MavenArtifactRepository`, so **an `ivy { url 'http://…' }` repository passes straight through** — Gradle supports Ivy repos and they fetch artifacts identically. And both implementations are case-sensitive (`repo.url.scheme == 'http'` / `startsWith("http://")`), so `HTTP://` slips past; `URI.getScheme()` preserves the case as written.

**`failOnDynamicVersions()` / `failOnChangingVersions()` are defensible but will bite.** `failOnChangingVersions` fails any build resolving a `-SNAPSHOT`, which is *normal* for internal multi-repo Java shops. Deployed host-wide and unconditionally, this is the Bundler-deployment problem again: the operator's cheapest fix is `rm ~/.gradle/init.d/supply-chain-security.gradle`, which takes the HTTPS enforcement with it. Worth an input to disable independently, and worth a README note that it is expected to break SNAPSHOT workflows. (Also a parity gap: the role guards both calls with `respondsTo()` for exactly the "an init script is CODE" reason argued at tasks/gradle.yml:80-89; harden.sh:1783-1784 calls them unguarded.)

**What's missing:**

1. **Gradle dependency verification — and this is the sharpest omission across all four ecosystems, because Gradle is the *only* one of the four with a real built-in integrity mechanism and we don't touch it.** `gradle/verification-metadata.xml` records SHA-256 checksums and/or PGP signatures, `strict` is the default mode, and per Gradle's docs it verifies "any artifact downloaded via its dependency management engine, including… **Plugins (both project and settings plugins)**" — i.e. it covers exactly the buildscript/pluginManagement surface our HTTP check misses. Generated with `./gradlew --write-verification-metadata sha256,pgp`. The catch: the file must live at `$PROJECT_ROOT/gradle/verification-metadata.xml` and is strictly per-project, so an init script cannot supply it. But an init script *can* refuse to build without it, and that's a legitimate host-level control:

   ```groovy
   // in beforeSettings, once the root dir is known
   if (!new File(s.rootDir, "gradle/verification-metadata.xml").exists()) {
       throw new GradleException("supply-chain-harden: no gradle/verification-metadata.xml — " +
           "run ./gradlew --write-verification-metadata sha256,pgp")
   }
   ```

   Ship it behind an input, default off, and document the generation step. Even just documenting it is worth more than the dynamic-version check.

2. **Nothing validates the wrapper**, which is the one attack with a confirmed incident. `gradle/actions/wrapper-validation` exists and is a two-line workflow step. This repo already ships GitHub Actions hardening as a documented detection-only tag (zizmor + pinact, README.md:210-217) — wrapper validation belongs in exactly that bucket, same install-and-document treatment.

3. **`distributionUrl` in `gradle-wrapper.properties` is unchecked.** `./gradlew` downloads and executes whatever that URL points at, before any init script exists to have an opinion. Gradle supports `distributionSha256Sum` in the same file. Also per-project, also worth documenting.

4. **No dependency locking.** Gradle has `dependencyLocking { lockAllConfigurations() }`, and unlike verification metadata it *can* be switched on from an init script — though it needs `gradle.lockfile` present to be anything but advisory.

---

## Priority ordering

Ranked by expected reduction in real risk per unit of work, with the two "we are making things worse" items pulled up:

1. **Add `BUNDLE_COOLDOWN` to the Bundler config** (tasks/bundler.yml + harden.sh:1567-1572), derived from `release_age_hours`, with a 4.0.13 version tier and an inert-below warning matching the npm `min-release-age` pattern. Ruby has the most active current attack campaigns, its attack executes at install time and provably cannot be blocked, the age gate is the repo's own stated answer to exactly this, and the control now exists natively. One line, largest delta.
2. **Drop `BUNDLE_DEPLOYMENT` (and `BUNDLE_DISABLE_EXEC_LOAD`).** Deployment silently redirects every install on the host to `./vendor/bundle` and hard-fails any project without a current lockfile; `frozen` alone gives the entire security benefit. Currently a live foot-gun that pressures operators into deleting the file — which will matter much more once #1 is in it.
3. **Fix `tasks/maven.yml`'s `<mirrorOf>*</mirrorOf>`** → `external:http:*` + `<blocked>true</blocked>`. It leaks internal coordinates to Maven Central, silently redirects instead of refusing, and is positioned to shadow Maven's own default HTTP blocker. Measure the shadowing claim, fix the pattern regardless.
4. **Fix Maven's `~/.m2` home resolution** in both tasks/maven.yml:13 and harden.sh:1685, using the `ansible_user_dir` reasoning already written out at tasks/gradle.yml:11-47. Same JVM, same passwd-derived `user.home`, same bug, un-fixed one file over. Silently strands the whole Maven config on relocated-HOME hosts.
5. **Correct the README claims for NuGet.** Remove the "Install script blocking" x at README.md:14 — nothing blocks scripts and there are no scripts to block on Linux — and replace it with a Limitations entry naming MSBuild `build/*.targets` execution as the real, documented, unmitigated vector. Soften the "nuget.org only" log line at harden.sh:1856 and the `<clear/>` comments to say what `<clear/>` actually does (sanitises inherited sources; project-level configs still add).
6. **Extend the Gradle init script to `buildscript.repositories` and `beforeSettings { pluginManagement.repositories }`**, plus `IvyArtifactRepository` and case-insensitive scheme matching. Currently we guard where code is linked and not where it is run.
7. **Add `<packageSourceMapping><clear /></packageSourceMapping>`** to both NuGet configs — Microsoft's own recommended user-level form — and document the per-repo pattern block.
8. **Give Gradle dependency verification a home**: an opt-in init-script check that `gradle/verification-metadata.xml` exists, plus README guidance on `--write-verification-metadata sha256,pgp`. It is the only mechanism in these four ecosystems that covers the plugin/buildscript classpath, and we currently ignore it entirely.
9. **Pin `BUNDLE_DISABLE_CHECKSUM_VALIDATION: "false"`** — same fail-safe-pinning argument already made for `DOTNET_NUGET_SIGNATURE_VERIFICATION`.
10. **Parity and honesty sweep**: Maven checksum policy into the action / HTTP block into the role; `respondsTo()` guards on harden.sh:1783-1784; and Limitations entries for the three "cannot fix from a config file" truths — Maven plugin/extension execution, NuGet MSBuild execution, Gradle wrapper JAR trust. Also add wrapper validation to the existing detection-only `github` tag.

One cross-cutting note for SOURCES.md: the "under-researched" label is accurate for the *community-guidance* claim, but the gap it produced is narrower and more specific than "we used official docs." Official docs are exactly where `<packageSourceMapping>`, `packages.lock.json`, Gradle dependency verification, Bundler cooldown and `bundle lock --add-checksums` are all documented. What actually happened is that we took the transport-security section of each doc and stopped before the resolution and execution sections.

**Sources:**
- [Malicious NuGet packages abuse MSBuild to install malware — BleepingComputer](https://www.bleepingcomputer.com/news/security/malicious-nuget-packages-abuse-msbuild-to-install-malware/)
- [IAmReboot: Malicious NuGet packages exploit loophole in MSBuild integrations — ReversingLabs](https://www.reversinglabs.com/blog/iamreboot-malicious-nuget-packages-exploit-msbuild-loophole)
- [Package Source Mapping — Microsoft Learn](https://learn.microsoft.com/en-us/nuget/consume-packages/package-source-mapping)
- [Best practices for a secure software supply chain — Microsoft Learn](https://learn.microsoft.com/en-us/nuget/concepts/security-best-practices)
- [Common NuGet configurations (config precedence and `<clear/>`) — Microsoft Learn](https://learn.microsoft.com/en-us/nuget/consume-packages/configuring-nuget-behavior)
- [MSBuild props and targets in a package — Microsoft Learn](https://learn.microsoft.com/en-us/nuget/concepts/msbuild-props-and-targets)
- [VS 2017 doesn't execute install.ps1 with PackageReference — NuGet/Home#6330](https://github.com/NuGet/Home/issues/6330)
- [Enable repeatable package restores using a lock file — .NET Blog](https://devblogs.microsoft.com/dotnet/enable-repeatable-package-restores-using-a-lock-file/)
- [Tick Tock, Your Credentials Are Gone: the Maven package with a monthly theft schedule — Socket](https://socket.dev/blog/malicious-maven-package-exfiltrates-oauth-credentials)
- [Maven Central Malware: Jackson typosquatting delivers Cobalt Strike — Aikido](https://www.aikido.dev/blog/maven-central-jackson-typosquatting-malware)
- [Shai-Hulud v2 spreads from npm to Maven — The Hacker News](https://thehackernews.com/2025/11/shai-hulud-v2-campaign-spreads-from-npm.html)
- [Maven 3.8.1 release notes (maven-default-http-blocker)](https://maven.apache.org/docs/3.8.1/release-notes.html)
- [Using Mirrors for Repositories — Apache Maven](https://maven.apache.org/guides/mini/guide-mirror-settings.html)
- [Gradle Wrapper Attack Report — Gradle Blog](https://blog.gradle.org/wrapper-attack-report)
- [Gradle Wrapper Validation — Gradle Community](https://community.gradle.org/github-actions/docs/wrapper-validation/)
- [Dependency Verification — Gradle User Guide](https://docs.gradle.org/current/userguide/dependency_verification.html)
- [Initialization Scripts — Gradle User Guide](https://docs.gradle.org/current/userguide/init_scripts.html)
- [Malicious Ruby gems and Go modules steal secrets, poison CI — Socket](https://socket.dev/blog/malicious-ruby-gems-and-go-modules-steal-secrets-poison-ci)
- [16 typosquatted RubyGems packages steal browser credentials and crypto wallets — The Hacker News](https://thehackernews.com/2026/08/16-typosquatted-rubygems-packages-steal.html)
- [Cool down before you install — RubyGems Blog](https://blog.rubygems.org/2026/06/03/cooldown-let-new-gems-be-vetted.html)
- [bundle config settings reference — RubyGems Guides](https://guides.rubygems.org/command-reference/bundle-config/)
- [Bundler v2.6: lockfile checksums are finally there — RubyGems Blog](https://blog.rubygems.org/2024/12/19/bundler-v2-6.html)
- [cooldowns.dev — cross-ecosystem cooldown reference](https://cooldowns.dev)

---

# Part 3 — Integrated implementation plan

# Implementation plan — behavioral attack tests for the CI action

## 0. Read this first: I received one verdict, not four

The `ADVERSARIAL VERDICTS` array contained **exactly one element (go, NEEDS_FIXES)**. Both threat analyses are truncated mid-sentence, and no verdict for a second, third, or fourth ecosystem is present in my input. I cannot tell you whether the reviewer confirmed the bundler/nuget/gradle/maven designs fail against broken hardening, because **I never saw those designs or those verdicts.**

So this plan has one certified item and three uncertified ones. I did not manufacture the missing three — I derived them from the threat analyses and labelled them as designs, not as reviewed tests. If the orchestrator has the other three verdicts, re-run this step with them; item 1 is shippable regardless.

What I *did* do instead of guessing: I re-ran the go mutation matrix myself, from scratch, and I went and read Bundler 4.0.19's source. Both changed the answer in ways that matter (§1.1, §4.1).

---

## 1. Ordered implementation list

### 1.1 — go: attacker-supplied toolchain hijack — **SHIP FIRST, CERTIFIED**

**What it proves.** `go build` in a module whose `go.mod` says `toolchain go1.99.0` will, under stock Go, find `go1.99.0` on `$PATH` and **exec it as the compiler**. `GOTOOLCHAIN=local` returns from `Select()` before the PATH-vs-download branch, so proving the PATH branch dead proves the download branch dead too. The job proves this at three separate points: both layers together, the exported-env layer alone, and the `go env -w` file layer alone.

**Reviewer verdict: `would_pass_against_broken_hardening: false` (measured, not inferred), `tests_the_tool_or_our_own_file: tool-behavior`, verdict NEEDS_FIXES.** All six required fixes are applied below.

**I independently re-measured the whole thing today** (go1.27.0 linux/arm64, real `harden.sh` under a simulated `$GITHUB_ENV`, then three surgical mutations of `/workspace/action/harden.sh`):

| Mutation | step 04 guard | step 05 both-layers | step 06 env-alone | step 07 file-alone | step 08 neg-control |
|---|---|---|---|---|---|
| none (real hardening) | pass | pass | pass | pass | fires |
| delete `write_env GOTOOLCHAIN "local"` (h.sh:1520) | pass | pass | **RED** | pass | fires |
| delete `"GOTOOLCHAIN=local"` from the `go env -w` loop (h.sh:1538) | pass | pass | pass | **RED** | fires |
| delete both | pass | **RED** | **RED** | **RED** | fires |

Two things fall out of that table that are worth stating plainly:

- **The reviewer's blind-spot finding is real and I reproduced it.** Delete only the env layer and the *original* proposal was entirely green, because the `~/.config/go/env` file blocks the hijack by itself. Step 06 is the only thing in the job that catches it — and the env layer is the only layer that exists on a host where go isn't installed at hardening time, which is the exact case `harden_go`'s own comment says the two layers are for.
- **The `ecosystems-effective` guard is a precondition, not a detector.** `ecosystems_effective=go` in *all three* mutations. Keep it (it catches an ecosystem silently landing in `degraded`/`ineffective`), but do not let anyone believe it covers a deleted setting.

Also independently re-verified today: sha256 `675c26c449cbb18fc24b74650de1eabbae6e16f64326fd85a283fb3b58280685` for `go1.27.0.linux-amd64.tar.gz`, straight from `https://go.dev/dl/?mode=json&include=all`. go1.27.0 released 2026-08-18.

**Final corrected YAML** — append to `/workspace/.github/workflows/action-smoke.yml`. Parses as YAML; every `run` block was extracted and executed verbatim in the matrix above.

```yaml
  action-go-behavioral-toolchain-hijack:
    name: 'Action: GOTOOLCHAIN=local blocks an attacker-supplied toolchain (both layers)'
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09 # v5.1.0

      # A pinned toolchain, not the image's, so the job measures a known Go.
      # sha256 from https://go.dev/dl/?mode=json (re-verified 2026-08-28).
      # Do NOT swap this for `apt-get install golang-go`: distro packages are
      # reported to patch the GOTOOLCHAIN default, which would turn the whole
      # job into a tautology. The precondition step below is what catches that.
      - name: Install pinned Go 1.27.0
        run: |
          set -euo pipefail
          cd /tmp
          curl -fsSLO https://go.dev/dl/go1.27.0.linux-amd64.tar.gz
          echo "675c26c449cbb18fc24b74650de1eabbae6e16f64326fd85a283fb3b58280685  go1.27.0.linux-amd64.tar.gz" | sha256sum -c -
          sudo rm -rf /usr/local/go
          sudo tar -C /usr/local -xzf go1.27.0.linux-amd64.tar.gz
          # The job is worthless if a later edit installs Go somewhere the PATH
          # does not reach and we silently measure the image's Go instead.
          command -v go
          go version
          go version | grep -q 'go1\.27\.0'

      # PRECONDITION, PROVEN NOT ASSERTED. `go env GOTOOLCHAIN` == auto only
      # says the runner LOOKS vulnerable. Run the attack for real, first.
      - name: Plant the fixture and prove it fires BEFORE hardening
        run: |
          set -euo pipefail
          rm -f /tmp/go-toolchain-executed
          : > /tmp/empty-go-env

          mkdir -p /tmp/evil-bin
          cat > /tmp/evil-bin/go1.99.0 <<'EOF'
          #!/bin/sh
          : > /tmp/go-toolchain-executed
          echo "attacker-supplied toolchain is running as the compiler"
          exit 0
          EOF
          chmod +x /tmp/evil-bin/go1.99.0

          mkdir -p /tmp/go-victim
          cat > /tmp/go-victim/go.mod <<'EOF'
          module victim

          go 1.27.0

          toolchain go1.99.0
          EOF
          cat > /tmp/go-victim/main.go <<'EOF'
          package main

          import "os"

          func main() { os.Stderr.WriteString("legitimate build ok\n") }
          EOF

          # Read the stock setting from OUTSIDE the module: inside it, this very
          # command can trigger the toolchain switch we are about to test.
          stock=$(cd / && go env GOTOOLCHAIN)
          echo "stock GOTOOLCHAIN=$stock"
          if [ "$stock" != "auto" ]; then
            echo "::error::runner GOTOOLCHAIN is '$stock', not 'auto' — this job cannot attribute a block to us"
            exit 1
          fi

          export PATH="/tmp/evil-bin:$PATH"
          set +e
          out=$(cd /tmp/go-victim && go build -o /tmp/go-victim/bin-pre . 2>&1); rc=$?
          set -e
          echo "rc=$rc"; echo "$out"
          if [ ! -e /tmp/go-toolchain-executed ]; then
            echo "::error::the fixture did NOT hijack an UNHARDENED build — the rest of this job would prove nothing"
            exit 1
          fi
          echo "✓ unhardened: attacker toolchain executed (this is the thing we must stop)"
          rm -f /tmp/go-toolchain-executed /tmp/go-victim/bin-pre

      - id: harden
        uses: ./action
        with:
          ecosystems: go

      # Gate on the POSITIVE. A degraded-only check waves through an ecosystem
      # that landed in ecosystems_ineffective (harden.sh emits three lists).
      # NOTE: this is a PRECONDITION, not a detector — measured, all three
      # GOTOOLCHAIN mutations still report ecosystems_effective=go.
      - name: go must be in ecosystems-effective
        env:
          EFFECTIVE: ${{ steps.harden.outputs.ecosystems-effective }}
          DEGRADED: ${{ steps.harden.outputs.ecosystems-degraded }}
          INEFFECTIVE: ${{ steps.harden.outputs.ecosystems-ineffective }}
        run: |
          set -euo pipefail
          echo "effective=[$EFFECTIVE] degraded=[$DEGRADED] ineffective=[$INEFFECTIVE]"
          case ",$EFFECTIVE," in
            *,go,*) ;;
            *) echo "::error::go is not in ecosystems-effective"; exit 1 ;;
          esac
          case ",$DEGRADED,$INEFFECTIVE," in
            *,go,*) echo "::error::go reported degraded/ineffective"; exit 1 ;;
          esac

      # LAYER 1 + 2 TOGETHER: the shape a real job runs in.
      - name: Both layers — the hijack must not happen
        run: |
          set -euo pipefail
          rm -f /tmp/go-toolchain-executed
          export PATH="/tmp/evil-bin:$PATH"
          set +e
          out=$(cd /tmp/go-victim && go build -o /tmp/go-victim/bin-main . 2>&1); rc=$?
          set -e
          echo "rc=$rc"; echo "$out"
          if [ -e /tmp/go-toolchain-executed ]; then
            echo "::error::HIJACK DETECTED — attacker toolchain ran with hardening applied"
            exit 1
          fi
          # The fixture binary writes to STDERR on purpose; without 2>&1 this
          # grep fails for a reason that has nothing to do with hardening.
          test -x /tmp/go-victim/bin-main
          /tmp/go-victim/bin-main 2>&1 | grep -q 'legitimate build ok'
          echo "✓ blocked, and the real build still works"

      # LAYER 1 ALONE (exported env). Neutralise the go env -w file so a
      # regression that deletes ONLY `write_env GOTOOLCHAIN local` is visible.
      # MEASURED: without this step that mutation passes every other assertion.
      - name: Exported-env layer alone must block it
        run: |
          set -euo pipefail
          rm -f /tmp/go-toolchain-executed
          : > /tmp/empty-go-env
          export PATH="/tmp/evil-bin:$PATH"
          # Prove the isolation is real before trusting the result.
          iso=$(cd / && GOENV=/tmp/empty-go-env env -u GOTOOLCHAIN go env GOTOOLCHAIN)
          echo "isolation self-check (file layer removed, env unset): $iso"
          if [ "$iso" != "auto" ]; then
            echo "::error::GOENV isolation is not working — this step is not testing the env layer"
            exit 1
          fi
          set +e
          out=$(cd /tmp/go-victim && GOENV=/tmp/empty-go-env go build -o /tmp/go-victim/bin-env . 2>&1); rc=$?
          set -e
          echo "rc=$rc"; echo "$out"
          if [ -e /tmp/go-toolchain-executed ]; then
            echo "::error::HIJACK DETECTED with only the exported env layer — GOTOOLCHAIN is not in the env"
            exit 1
          fi
          /tmp/go-victim/bin-env 2>&1 | grep -q 'legitimate build ok'
          echo "✓ exported env layer blocks it on its own"

      # LAYER 2 ALONE (go env -w file). The layer that survives a step which
      # does not inherit this job's environment.
      - name: Persisted layer alone must block it
        run: |
          set -euo pipefail
          rm -f /tmp/go-toolchain-executed
          export PATH="/tmp/evil-bin:$PATH"
          # From / — inside the module this read itself triggers the switch and
          # prints the attacker's stdout instead of a value.
          persisted=$(cd / && env -u GOTOOLCHAIN go env GOTOOLCHAIN)
          echo "persisted GOTOOLCHAIN=$persisted (GOENV=$(cd / && env -u GOTOOLCHAIN go env GOENV))"
          if [ "$persisted" != "local" ]; then
            echo "::error::go env -w did not persist GOTOOLCHAIN=local (got '$persisted')"
            exit 1
          fi
          set +e
          out=$(cd /tmp/go-victim && env -u GOTOOLCHAIN go build -o /tmp/go-victim/bin-file . 2>&1); rc=$?
          set -e
          echo "rc=$rc"; echo "$out"
          if [ -e /tmp/go-toolchain-executed ]; then
            echo "::error::HIJACK DETECTED with the env layer stripped — the persisted layer is not holding"
            exit 1
          fi
          /tmp/go-victim/bin-file 2>&1 | grep -q 'legitimate build ok'
          echo "✓ persisted layer blocks it on its own"

      # NEGATIVE CONTROL, LAST. If this stops firing, every green above is
      # meaningless. Toolchain selection precedes any build-cache lookup, so
      # the three successful builds above cannot disarm it.
      - name: Negative control — the fixture still hijacks when nothing blocks it
        run: |
          set -euo pipefail
          rm -f /tmp/go-toolchain-executed
          export PATH="/tmp/evil-bin:$PATH"
          set +e
          out=$(cd /tmp/go-victim && GOENV=/tmp/empty-go-env GOTOOLCHAIN=auto go build -o /tmp/go-victim/bin-neg . 2>&1); rc=$?
          set -e
          echo "rc=$rc"; echo "$out"
          if [ ! -e /tmp/go-toolchain-executed ]; then
            echo "::error::negative control did NOT fire — the fixture is dead and this job proves nothing"
            exit 1
          fi
          rm -f /tmp/go-toolchain-executed
          echo "✓ negative control fired"
```

**Residual risks, carried forward from the verdict and not resolved:**
- Everything was measured on **linux/arm64 in a dev container**, never on a real `ubuntu-24.04` amd64 runner. The toolchain-switch logic is arch-independent and the PATH lookup is an explicit branch in `cmd/go`, but the job has still never run for real.
- The `apt golang-go` GOTOOLCHAIN-default claim in the comment is **UNVERIFIED** — neither the reviewer nor I could test it. The precondition step is the only thing preventing that from becoming a tautology, so it must never be weakened. This is the same apt-layout trap `681a709`/`e6a3f56` already paid for in cargo.
- `go1.27.0` is a frozen pin: the job stops speaking about the current toolchain as Go advances. Bump deliberately.
- One ~67MB network download from `go.dev/dl`. A failure there fails the step loudly; it cannot degrade an assertion into a free pass.

---

### 1.2 — bundler: `extconf.rb` executes at install time — **DESIGN ONLY, NOT REVIEWED**

**What it would prove.** That Ruby native-extension compilation runs attacker code and **we do not stop it** — the honest outcome, in the style of `action-pip-only-binary-limitation`. `tests/fixtures/ruby-extconf-gem` already exists and is consumed only by `tests/bats/`, so the fixture cost is near zero.

**Adversarial confirmation: NONE. I did not receive a verdict for this.** Do not merge it as reviewed. Specifically unresolved: whether the fixture actually detonates through `bundle install` on the apt Ruby the existing bundler job installs, and whether the `sudo gem install bundler` in that job yields a Bundler that reads `~/.bundle/config` for the user the step runs as.

**Sequenced second only because of §4.1**: this job is the thing that makes the bundler defense change in §4.1 legible. Land the defense change and this job in the same PR, and the job's assertion flips from "the marker appears, and nothing we ship prevents it" to "the marker appears, and the cooldown is what we rely on instead."

### 1.3 — nuget: MSBuild `build/*.targets` auto-import executes on `dotnet build` — **DESIGN ONLY, NOT REVIEWED**

**What it would prove.** That a restored package's `build/<id>.targets` is auto-imported and its inline `<Code>` task runs on `dotnet build`, and that **nothing we ship stops it** — again a documented-limit job.

**Verified in the repo today:** `grep -rniE 'msbuild|\.targets|buildTransitive'` returns exactly two hits, both `MSBUILDDISABLENODEREUSE=1` in `files/verify-probes.sh`. Zero coverage, zero defense, zero mention. And `action-nuget-behavioral-cert-valid` runs `dotnet restore` and stops — it never runs `dotnet build`.

**Adversarial confirmation: NONE.** Also unresolved: whether signature validation (`signatureValidationMode=require` + `DOTNET_NUGET_SIGNATURE_VERIFICATION=true`) refuses to *restore* a locally-built unsigned `.nupkg` in the first place, which would make the fixture unreachable and the job vacuous. That has to be measured before this design is worth anything.

### 1.4 — gradle: plugin classpath is outside the init script's reach — **DESIGN ONLY, NOT REVIEWED**

**What it would prove.** That `allprojects { repositories.all { … } }` in `harden_gradle`'s `init.gradle.kts` (harden.sh:1767-1790) does **not** reach `buildscript.configurations.classpath` or `settings.gradle`'s `pluginManagement { repositories }` — so a dynamic or HTTP-sourced *plugin* version is remote code chosen at build time and we don't touch it.

**This one is already measured, just not by CI.** `files/verify-probes.sh:3037` says verbatim: *"allprojects{configurations.all} does not reach the PLUGIN classpath, and a dynamic plugin version is remote code chosen at build time. MEASURED with harden.sh's script: project REFUSED, plugin classpath RESOLVED -> WEAK."* The verifier knows. No smoke job drives it. Turning that comment into a red-or-green job is cheap and the outcome is already known, which is the best possible position to write a test from.

**Adversarial confirmation: NONE.**

---

## 2. Designs marked UNSOUND

**None of the verdicts I received was UNSOUND** — the one I got was NEEDS_FIXES, and the fixes are applied. I am not going to invent UNSOUND findings for designs I never saw.

But the ask ("a test that cannot fail is worse than no test") applies to what's already merged, and there are live examples:

**`action-nuget-behavioral-cert-valid` (action-smoke.yml:708) cannot fail against broken hardening.** It asserts `dotnet restore` **succeeds** under require-mode with the pinned cert. Stock, unhardened NuGet also restores nuget.org packages successfully. Delete `harden_nuget` entirely and this job stays green. It is a config-doesn't-brick-restore smoke test — genuinely useful, it catches the cert-rotation bricking risk the config comment warns about — but it is filed and named as behavioral security evidence and it is not that. **What's needed instead:** a negative control. Build an unsigned `.nupkg` into a local folder source and require `dotnet restore` to **refuse** it with NU3004/NU3034. Under broken hardening that restore succeeds. Unmeasured caveat: `<clear/>` plus a single source may make the local feed unreachable before signature checking ever runs, in which case the job proves source-pinning rather than signature enforcement — measure which failure you actually get, and name the job after that.

**`action-gradle-behavioral-dynamic-version` (action-smoke.yml:654) is half-sound.** It passes `--init-script "$HOME/.gradle/init.gradle.kts"` explicitly, so it proves the script's *content* works and proves nothing about **auto-discovery from `GRADLE_USER_HOME`** — which is precisely what the long passwd-home resolution block in `harden_gradle` (harden.sh:1744-1765) exists to get right. Drop the `--init-script` flag and it becomes a real test of both halves.

**`action-go-env-set` (action-smoke.yml:450) is PARSED-strength and must not be counted as behavioral.** It does fail if we stop emitting the vars, so it is a valid regression test on our own emission. But six of the seven values restate Go's own defaults, so it is not evidence that anything is *protected*. `GOTOOLCHAIN` is the only one of the seven that changes Go's behavior — which is exactly why §1.1 exists.

**`uv index-strategy` is capped WEAK/PARSED by design** (`verify-probes.sh:1025`: "FirstIndex is ALSO uv's default… not evidence our config was read"). Correctly labelled. Do not let a future smoke job launder it into FUNCTIONAL.

**And, from my own measurement today: the `ecosystems-effective` guard is not a detector.** All three GOTOOLCHAIN mutations still emitted `ecosystems_effective=go`. Any test that gates only on that output is testing that harden.sh ran, not that hardening holds.

---

## 3. Highest-value untested attack class beyond these four

**The hardening is silently overridden at a layer we neither pin nor inspect: resolution source and transport.**

Verified against the repo today, not quoted from the analysis:
- `grep -rn 'registry=' action/harden.sh templates/` → **zero hits.** We write no registry pin for npm, pnpm, yarn, or bun.
- `grep -rnE 'HTTPS_PROXY|HTTP_PROXY|NODE_TLS_REJECT|NODE_EXTRA_CA|CURL_CA|trusted-host|PIP_INDEX_URL|GIT_SSL' action/ files/ tests/ .github/ templates/` → **zero hits.** `harden.sh` doesn't pin them, `verify.sh` doesn't report them, no test covers them.

Why this beats the other candidates: **it neutralizes the flagship control.** The age gate assumes the registry's publish timestamps are honest. Point resolution at an attacker's registry and `min-release-age` means nothing — the attacker sets the timestamps. A one-line repo-local `.npmrc` (`registry=` or `@scope:registry=`) does it, no env manipulation, no code execution needed, and it survives PR review as a plausible-looking config change. Every remaining control (`ignore-scripts`, frozen lockfile, `save-exact`) then faithfully protects you while installing the attacker's bytes.

**Concrete proposal, in the cheap-first order the threat analysis recommends:**

*Step 1 — a detector, before any defense.* Add a `verify.sh` probe, "resolution source and transport," that exits non-zero when any of these is true: `HTTP_PROXY`/`HTTPS_PROXY` set; `NODE_TLS_REJECT_UNAUTHORIZED=0`; `NODE_EXTRA_CA_CERTS` set; `PIP_INDEX_URL`/`PIP_EXTRA_INDEX_URL`/`PIP_TRUSTED_HOST` set; `CARGO_REGISTRIES_*` set; `GOPROXY`/`GOSUMDB` differing from what we wrote; or a `.npmrc`/`.yarnrc.yml`/`bunfig.toml` in the working tree carrying `registry=`, `:registry=`, `npmRegistryServer`, or `registry =`. This is FUNCTIONAL-by-inspection, needs no network, and is a control the repo can actually enforce today.

*Step 2 — a smoke job that tests the detector.* Plant each poison one at a time after `uses: ./action`, assert `verify.sh` exits non-zero and names the offending key. That job fails the day someone weakens the probe. Add the negative control: clean environment → `verify.sh` exits 0.

*Step 3 — the FUNCTIONAL resolution test, hermetic.* Serve a packument from a trivial HTTP server on `127.0.0.1` whose access log is the marker file. Plant a repo-local `.npmrc` pointing at it, run `npm install <name>`, and assert **zero hits** on the local server. Under broken hardening the server gets a hit. Marker-file shape, identical to `05-behavioral.bats`.

**Honest limitation, and it is a big one:** step 3 requires a defense that does not currently exist, and the obvious fix is incomplete. `NPM_CONFIG_REGISTRY` outranks a project `.npmrc` `registry=`, but `@scope:registry=` is a *different key* — you cannot enumerate every scope, so scope-level redirection stays open even after you pin the default. That means the honest deliverable for npm may be a **documented-limit job plus the step-1 detector**, not a block. Say so in the README rather than shipping a registry pin and implying the class is closed. A registry pin also breaks private-registry users, so it needs an input, not an unconditional default.

---

## 4. Where our defenses are wrong, not merely untested

This is the section with content, and it is the one that should change what ships this week.

### 4.1 Bundler: one real control out of three, and the control that matters exists and isn't deployed

`action/harden.sh:1563-1576` and `tasks/bundler.yml:12-20` write exactly three keys. I read Bundler 4.0.19's own source and man page to check each (downloaded `bundler-4.0.19.gem` from rubygems.org):

- `BUNDLE_FROZEN: "true"` — real. *"Disallow any automatic changes to Gemfile.lock."* Defends drift. Does nothing about a poisoned version already pinned in the lockfile, and nothing about install-time execution.
- `BUNDLE_DEPLOYMENT: "true"` — **redundant and actively harmful.** `bundle-config.1.ronn:175`, verbatim: *"Equivalent to setting `frozen` to `true` and `path` to `vendor/bundle`."* The frozen half duplicates the line above it. The `path` half is an unannounced, machine-wide relocation of where every `bundle install` on the host puts gems, set unconditionally in a global `~/.bundle/config`. That is the self-disarming shape the repo already reasons carefully about for `UV_NO_SYSTEM_CONFIG`: the operator whose fresh clone hard-fails deletes `~/.bundle/config`, and takes `frozen` with it.
- `BUNDLE_DISABLE_EXEC_LOAD: "true"` — **not a security control.** `bundle-config.1.ronn:179`: *"Stop Bundler from using `load` to launch an executable in-process in `bundle exec`."* Same gem code, same privileges, different process model. It should not be counted as hardening and it should not be in the log line.

**And the control that actually addresses the threat exists.** `cooldown` / `BUNDLE_COOLDOWN` is a real settings key, *"Number of days a published gem version must age before bundler will resolve to it."* I measured the tier boundaries from the gem sources rather than trusting the analysis:

| Bundler | `cooldown` in `settings.rb` NUMBER_KEYS | `--cooldown` CLI commands |
|---|---|---|
| 4.0.12 | absent | 0 |
| 4.0.13 (2026-06-03) | present | 4 (install, update, add, outdated) |
| 4.0.17 | present | 4 |
| 4.0.18 (2026-08-05) | present | 6 (+ cache, lock) |
| 4.0.19 (2026-08-20, current) | present | 6 |

**Correction to the threat analysis, which matters for our deployment vector:** it claims a lock-then-install flow on 4.0.13–4.0.17 is "only half-gated." That conflates the CLI flag with the setting. `Source::Rubygems::Remote#effective_cooldown` reads `Bundler.settings[:cooldown]` in the *Remote constructor* (`lib/bundler/source/rubygems/remote.rb:24`), not in any CLI command — so a `BUNDLE_COOLDOWN` in `~/.bundle/config`, which is our only deployment vector, applies to **every** command that builds a rubygems Remote, including `lock` and `cache`, from 4.0.13 on. The version tier is 4.0.13, full stop.

**Two more real gaps, both confirmed in 4.0.19's config docs:**
- `disable_checksum_validation` (`BUNDLE_DISABLE_CHECKSUM_VALIDATION`) — *"Allow installing gems even if they do not match the checksum provided by RubyGems."* Unpinned. One inherited `true` from a CI image silently disables checksum validation and nothing we write denies it the last word. Identical argument to `DOTNET_NUGET_SIGNATURE_VERIFICATION`.
- `lockfile_checksums` (`BUNDLE_LOCKFILE_CHECKSUMS`) — **another correction to the analysis**, which says lockfile checksums are per-project and "a global config can't turn it on." In Bundler 4.0.19 it is a global BOOL settings key that *defaults to true*. Same pin-the-safe-side argument.

**Recommended replacement** (`harden.sh:1566-1572` and `tasks/bundler.yml`), with `release_age_hours=48` → `2` days:

```yaml
---
BUNDLE_FROZEN: "true"
BUNDLE_COOLDOWN: "2"                        # DAYS, integer. Bundler 4.0.13+.
BUNDLE_DISABLE_CHECKSUM_VALIDATION: "false"
BUNDLE_LOCKFILE_CHECKSUMS: "true"
# dropped: BUNDLE_DEPLOYMENT (== frozen + path:vendor/bundle — redundant, and
#          the path half relocates every gem install on the host)
# dropped: BUNDLE_DISABLE_EXEC_LOAD (process-model knob, not a security control)
```

Four things must ship with it, or it becomes the next accepted-and-inert trap:
1. **Add `BUNDLE_COOLDOWN` to the units table at README.md:112** — days, integer, `ceil(release_age_hours / 24)`. That table is this repo's own defense against exactly this mistake.
2. **Version tier + `set_eco_status bundler PARTIAL`** below 4.0.13 (same shape as npm `min-release-age` at harden.sh:485-491). apt's `ruby-full` on ubuntu-24.04 gives Bundler 2.x, where the key is silently ignored.
3. **Refuse `0`.** In Ruby `0` is truthy, so `effective_cooldown` returns it and `BUNDLE_COOLDOWN=0` overrides per-source Gemfile cooldowns to nothing. The action already refuses `release_age_hours=0`; make sure that refusal reaches this derivation.
4. **Document the fail-open, verbatim from Bundler's own docs:** *"Cooldown filtering depends on the gem server providing a per-version `created_at` timestamp in the v2 compact-index format. Versions without that metadata — older gem servers, historical entries that predate the v2 cutover on rubygems.org, or private registries that still emit the v1 format — are treated as outside the cooldown window and remain resolvable."* Against a private registry emitting v1, this control silently permits everything. Also note the precedence: CLI `--cooldown N` beats our config, same "CLI flags beat config" caveat already documented for pip and npm.

**Not verified — must measure before merging:** whether writing `BUNDLE_COOLDOWN` into `~/.bundle/config` is silently ignored (expected) or *errors* on Bundler 2.x. No Ruby runtime available here. Given this repo's history with npm 11.10.0 and Composer 2.8.0, measure it on the apt tier before shipping.

### 4.2 Go: `GONOSUMDB` is a live sumdb bypass we never clear, and a wrong test comment is the reason

Measured on go1.27.0 today:

```
$ go env -w GONOSUMDB=example.com   # rc=0, accepted
$ go env GONOSUMDB                  # example.com
$ go env -w GONOSUMCHECK=1          # go: unknown go command variable GONOSUMCHECK
$ go env -w GOBOGUSKEY=1            # go: unknown go command variable GOBOGUSKEY
```

`go help environment` documents it under `GOPRIVATE, GONOPROXY, GONOSUMDB` as *"module path prefixes that should always be fetched directly or that should not be compared against the checksum database"* — and again under GOINSECURE: *"GOINSECURE does not disable checksum database validation. GOPRIVATE or GONOSUMDB may be used to achieve that."*

`harden_go` clears `GOPRIVATE=`, `GONOPROXY=`, `GOINSECURE=` and **not** `GONOSUMDB` (confirmed in the emitted `$GITHUB_ENV`). Meanwhile `tests/bats/10-go-adversarial.bats:6-9` states that GONOSUMCHECK and GONOSUMDB are *"neither is a real Go env var"* — half wrong — and `SOURCES.md:16` cites the BufferZoneCorp analysis as recommending we *"clear GONOSUMCHECK/GONOSUMDB to prevent CI env poisoning."* So a wrong test comment is the documented reason a real, recommended sumdb-bypass sweep was dropped. Add `"GONOSUMDB="` to the `go env -w` loop and the `write_env` set, and correct the bats comment (GONOSUMCHECK really is fake; GONOSUMDB is not).

### 4.3 NuGet: we model the wrong execution vector

`install.ps1`/`uninstall.ps1` are `packages.config`-only and gone under PackageReference; `init.ps1` is Visual Studio-only. On a Linux CI host the .NET build-time execution vector is **MSBuild `build/`, `buildMultiTargeting/`, `buildTransitive/` `.targets`/`.props` auto-import** — the "IAmReboot"-class campaign. We ship source pinning and signature enforcement (both real, both worth keeping) against a *distribution* threat, and nothing at all against the *execution* threat. Repo grep confirms zero mentions. There may be no config-layer fix, in which case the correct output is a README limitation plus §1.3's documented-limit job — the same honest treatment `build.rs` and `extconf.rb` already get at README.md:298.

### 4.4 Gradle: the defense our own verifier reports as WEAK

`init.gradle.kts` hooks `allprojects { repositories }` only. `verify-probes.sh:3037` already records the measurement: *"project REFUSED, plugin classpath RESOLVED -> WEAK"*, and `verify-probes.sh:2948` enumerates `settings pluginManagement` and `buildscript{} plugin classpath` as containers that accepted the bait. We ship an HTTPS-only + no-dynamic-versions control whose own verifier says it does not reach the classpath where build-time code execution lives. Either extend the init script to `settingsEvaluated { pluginManagement.repositories … }` and `buildscript.configurations.classpath`, or state the scope limit in the README. Right now the README implies whole-build coverage.

### 4.5 `--locked` / frozen increases exposure to a poisoned lockfile, and we say nothing about it

`cargo --locked`, `BUNDLE_FROZEN`, `preferFrozenLockfile`, `enableImmutableInstalls` all make a *committed* lockfile more authoritative. That is correct against drift and it is the right trade, but it means a lockfile with a tampered `resolved` URL or `integrity` hash gets *more* trust under our hardening than without it. Lockfile tampering is untested for every ecosystem and unmentioned in the README's limitations. The `--locked` paragraph at README.md:300-303 is careful about what `--locked` does not cover; it should also say what it makes worse. Testable offline in one job per ecosystem: flip one integrity hash, assert the install fails.

---

## 5. What I could not verify, stated plainly

- **Three of the four adversarial verdicts.** Not received. §1.2, §1.3, §1.4 carry no adversarial confirmation and must not be merged as reviewed.
- **Both threat analyses are truncated** mid-sentence in my input (the NuGet section cuts at *"On a Linux CI host there is effectively **zero**"*, and the untested-classes analysis cuts inside section 5). Anything downstream of those cuts I never saw. Where I could check a claim against the repo or against upstream sources I did, and I have flagged the two places the analysis turned out to be wrong (§4.1: the 4.0.13–4.0.17 "half-gated" claim, and the "global config can't turn on lockfile checksums" claim).
- **The go job has never run on a real ubuntu-24.04 amd64 runner** — only my arm64 dev-container reproduction of it.
- **Bundler on the apt 2.x tier.** No Ruby here; whether `BUNDLE_COOLDOWN` is ignored or errors on Bundler 2.x is unmeasured, and it gates §4.1.
- **The apt `golang-go` GOTOOLCHAIN-default claim** in the go job's comment. Unverified by both the reviewer and me.

Working files (all under `/tmp/claude-1000/-workspace/8673b519-c865-49d2-bc50-507a116214f3/scratchpad/`): `go-job.yml` (the final YAML above), `steps/*.sh` (its extracted run blocks), `runjob.sh` + `runharden.sh` + `assert.sh` (the mutation harness), `harden-{env,file,both}.sh` (the three mutants). `/tmp/bdl/` holds the unpacked Bundler 4.0.12/4.0.13/4.0.17/4.0.18/4.0.19 gems the §4.1 measurements came from.
