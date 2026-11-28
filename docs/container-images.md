# Container images

Hardening baked into an image reaches every container started from it, with no CI
adapter and no per-host apply. It also freezes what it decided at build time, and it
covers the user and the `HOME` it was built with more fully than any other. This page
says what to watch. A worked recipe is
[`action/examples/Dockerfile`](../action/examples/Dockerfile).

## Pick a tool

**The Ansible role is the default** for a container image, as for any Linux host
([AGENTS.md](../AGENTS.md#pick-a-path)). CI applies it inside an image twice: as root in
[`tests/Dockerfile`](../tests/Dockerfile), and as a non-root user with sudo in
[`tests/Dockerfile.nonroot`](../tests/Dockerfile.nonroot), whose apply runs the verifier
during the build.

**`action/harden.sh --emit=plain` is lighter**: no Ansible, and narrower than the role
([AGENTS.md](../AGENTS.md#apply-without-ansible) says how). The example Dockerfile uses
it, and CI builds that file as it is shipped and runs the verifier in the image it makes
(`ci-script.yml`, job `agent-shells`, cell `image-recipe`, driven by
[`tests/ci/agent-shell/run.sh`](../tests/ci/agent-shell/run.sh)).

## Install the toolchains first, harden last

Both hardeners write most config files whether or not the tool is there yet
([how it works](how-it-works.md#config-files-deployed-unconditionally)), but some
settings depend on the version they find, and a wrapper is written only in place of a
binary they find. So install every package manager first and harden after it, and harden
again after any layer that installs, upgrades or self-updates one: `npm install -g npm`,
`composer self-update` and the like can replace a wrapped binary
([AGENTS.md](../AGENTS.md#apply-with-ansible),
[design principles](design-principles.md#self-update-overwrites-wrapper)).

## Build as the user the image runs as, with its HOME

Most of what the hardening writes is a per-user file, read only through the `HOME` it
was written in. Build as the user and with the `HOME` the containers will have. An image
built as root and run with `-u 1000`, or with a `HOME` the platform sets, keeps only the
part that does not depend on `HOME`:

| Read whatever the user and HOME | Read only with the HOME it was written for |
|---|---|
| `/etc/pip.conf`, `/etc/uv/uv.toml` and `/etc/npmrc`, from the role or from `harden.sh` with `WRITE_ETC=true`. Debian's, Ubuntu's and RHEL's own npm read `/etc/npmrc`; the role also writes the global config other npms read, and pnpm reads none of the three ([how it works](how-it-works.md#config-files-deployed-unconditionally)) | `~/.npmrc` and every other per-user file ([AGENTS.md](../AGENTS.md#before-you-apply) lists them), for pnpm, Yarn and bun among others. Yarn reads no `/etc/yarnrc.yml` |
| The PATH wrappers written in place of a binary (bun, bunx, composer, deno and cargo, from `harden.sh`) | Maven's `settings.xml` and Gradle's init script, which go to the passwd home of the uid, not to `HOME` |

The example builds as root with `WRITE_ETC=true`, and on its base image no tool reads
the `/etc` files: its npm reads `/usr/local/etc/npmrc`, not `/etc/npmrc`, and there is
no pip or uv. So a user other than root gets the env layer, through the entrypoint, and
nothing more. MEASURED (podman 5.7.0, 2026-11-27): as uid `node` with
`--entrypoint ""`, `npm config get ignore-scripts` printed `false`; through the
entrypoint, `true`.

**Gradle and Maven read the passwd home.** The JVM takes `user.home` from the passwd entry
of the uid, not from `HOME`, so both writers put Maven's file and Gradle's init script in
that home, and say so when it is not `HOME`
([design principles](design-principles.md#assumed-canonical-config-homes),
[action/README.md](../action/README.md#portability-github-is-the-first-adapter-not-the-only-target)).
A uid with no passwd entry (`docker run -u 4242`) has no such home. `harden.sh` then
writes Maven's file under `HOME` with a warning and exports `GRADLE_USER_HOME`, which only
a shell that loads the env layer gets; `--home-only` writes neither, and CI checks that
it writes nothing outside `HOME` there (cell `uid-without-passwd`). When it hardens
Gradle, the env file `harden.sh` leaves also pins `GRADLE_USER_HOME` to the directory it
wrote, so sourcing it as another user points Gradle at the build user's.

## Load the env layer with an entrypoint

A container's `CMD` loads no env layer: nothing sources `/etc/profile.d` or the env file
for it ([how it works](how-it-works.md#system-wide-environment-variables)). The config
files hold without it; the env layer is the second line. To have it in every command,
use an entrypoint that sources the env file, option B in the example, which is on there.
MEASURED with the `image-recipe` cell (podman 5.7.0, 2026-11-27): through the entrypoint
the verifier found all 12 variables of the env file; the same command with
`--entrypoint ""` found none, a GAP. A login shell gets it from option A
(`/etc/profile.d`); so does a runner that saves its state from `bash -ilc`, as one agent
runner does, as the state stood when the session began
([design principles](design-principles.md#agent-runners); cell `replayed-state`).

## The uv and pip cutoffs freeze at build time

npm's, pnpm's, Yarn's and bun's windows are durations, and move with the clock. uv's
`exclude-newer` and pip's `uploaded-prior-to` are instants computed when the hardening
runs ([limitations](limitations.md)), and the env file carries the same
`PIP_UPLOADED_PRIOR_TO`, which outranks `pip.conf`
([action/README.md](../action/README.md#portability-github-is-the-first-adapter-not-the-only-target)).
The role's refresh timer, which advances them, needs a running systemd
(`tasks/age_gate_refresh.yml`); `harden.sh` has none. The verifier calls a cutoff older
than 7 days a freeze. So **rebuild the image at least every 7 days**, or pin the cutoffs
on purpose with the role's `uv_exclude_newer` and `pip_uploaded_prior_to`
([configuration](configuration.md#commonly-tuned-variables)).

A rebuild alone moves nothing: the build cache keeps the layer that hardened, cutoffs
and all, while nothing above it changes. The example declares `ARG HARDEN_STAMP` and
its hardening `RUN` names it, so a new value runs that step and every one after it
again; pass `--build-arg HARDEN_STAMP="$(date -u +%F)"`, or build with
`--pull --no-cache`. MEASURED with the `image-recipe` cell (podman 5.7.0, 2026-11-27):
rebuilt with nothing changed, the image kept its cutoffs; with a new stamp it got new
ones; with the same stamp again the cache served the same.

## Fail the build on a GAP

Run the verifier in the build, after the hardening, and let a GAP fail it:

- **The role:** `-e verify_fail_on_gap=true` ([README.md](../README.md),
  [verify.md](verify.md)).
- **`harden.sh`:** a `RUN` of `action/verify.sh` with the env layer loaded (without it,
  the env layer's own row is a GAP, as above), and with
  `HARDENING_ENV_FILE` and `HARDENING_OUTPUT_FILE` set to where `harden.sh` wrote them:
  the verifier does not find a path you chose on its own
  ([action/README.md](../action/README.md#verifying-it-actually-applied)). Keep both
  files root's, as the example does: `verify.sh` reads only a record that its caller or
  root owns. `--fail-on=any` fails on every GAP; `--fail-on=config` only on those a new
  run of the hardening would close, not on a tool too old for a setting
  ([the policies](../action/README.md#verifying-it-actually-applied)).

**The example's build passes with npm's age gate off.** It uses `--fail-on=config`
because `node:22-bookworm` ships two tools no configuration can gate: npm 10.9.9, which
has no age gate (npm 11.10.0 added it), and Yarn 1.22.22, which reads no `.yarnrc.yml`.
With `--fail-on=any` its build fails on those two GAPs; with `config` it passes and
prints them (MEASURED, same run as above). For an image whose builds must not pass
without an age gate, install npm 11.10.0 or later (and Yarn 4.10 or later, or no Yarn)
above the hardening, in the same image, and use `any`.

**Pin the base image by digest** (`FROM node:22-bookworm@sha256:...`), as for any image
pull ([AGENTS.md](../AGENTS.md#what-this-does-not-cover)). A tag moves, and with it
the npm and Yarn the image brings and what the verifier finds. The example uses the tag
so that CI builds it against what the tag gives today.

A `HEALTHCHECK` runs its command with neither the entrypoint nor a login shell, so it
loads the env layer itself:
`HEALTHCHECK CMD . /etc/supply-chain-hardening.env && /usr/local/lib/supply-chain-hardening/action/verify.sh --emit=plain --fail-on=config --quiet`.
The default policy, `any`, would report the example image unhealthy for its two
toolchain GAPs. MEASURED (podman 5.7.0, 2026-11-27, `podman run --health-cmd` on the
example image): healthy with that command, and unhealthy without the `. ` part, from
the env layer's GAP.

## Take build-time sudo out

The role, applied as a non-root user, needs sudo
([AGENTS.md](../AGENTS.md#apply-with-ansible)); `tests/Dockerfile.nonroot` grants it with
a `NOPASSWD` sudoers entry. Remove that entry in a later layer.
Anything that can still become root in the container can rewrite those files, and the
hardening is not a sandbox against code running as the user it protects
([threat model](threat-model.md)).

## Agent platforms with a read-only image

Some agent platforms build the image themselves and give the agent only its `HOME`
([AGENTS.md](../AGENTS.md#an-agents-vm---home-only)). There, everything outside `HOME`
can only come from the image: the `/etc` files, a wrapper for a tool outside `HOME`, and
a newer npm or pip where the image's copy is read-only. MEASURED with the `vm-a` cell
(podman 5.7.0, 2026-11-27), set up like one such VM, with npm 10.9.4 and bun 1.4.4 in a
read-only `/opt/hatch-image`: `harden.sh --home-only` as root changed nothing outside
`HOME` and nothing in the image directory, gave bun no wrapper, and the verifier, run
from the same shell, reported npm's age gate as a GAP at
`/opt/hatch-image/bin/npm: read-only (image-owned?)`, pip 24.0's age gate as a GAP, and
bun's runtime auto-install and bunx as GAPs, unwrapped in the image directory. Those
four are GAPs that a re-run of `--home-only` cannot close, and uv's system config,
which only `/etc` can hold, is `N/A BYDESIGN`, so `verify.sh --fail-on=config` exits 0
there. Before the verifier classed them so, it exited 1 there, counting the bun, bunx
and uv system config rows as "fixable by re-running the hardening".

So if you build the image an agent platform runs, harden it there, as on this page.
Otherwise run `./action/harden.sh --home-only` at the start of every session, and the
verifier from the agent's own shell.
