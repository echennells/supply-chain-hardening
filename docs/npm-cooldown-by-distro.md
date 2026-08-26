# Getting a cooldown-capable npm, per distro

npm's install **cooldown** — `min-release-age`, the defense against installing a
*freshly-published, not-yet-flagged* compromised package version — requires
**npm ≥ 11.10.0** (shipped 2026‑02‑11). Most distros' default package predates
it, so this role writes the `min-release-age` config but `supply-chain-verify`
honestly reports the npm age gate as a **GAP** until the host's npm is new
enough.

**This role does not upgrade your toolchain** — installing/upgrading Node is
invasive and distro-specific, and the role's job is to harden what's present and
report honestly. This page is how to close the gap yourself.

Every result below was **verified behaviourally** in throwaway containers on
**2026‑08‑26**: each path was installed, then a 2021 package
(`lodash@4.17.21`) was installed under a ~million-year window and the refusal
observed (npm's `notarget … with a date before …` error). Package versions
drift; re-check if you're reading this much later.

## What to run, per distro

| Distro | Recommended path | npm you get | Cooldown |
|---|---|---|---|
| **Ubuntu** | `sudo snap install node --classic` — Canonical's recommendation, **not** apt | 11.17 | ✅ |
| **Debian** | `sudo apt install extrepo && sudo extrepo enable node_24.x && sudo apt update && sudo apt install nodejs` (or the NodeSource `setup_24.x` script) | 11.17 | ✅ |
| **Fedora** | `sudo dnf install nodejs24` | 11.16 | ✅ |
| **Arch** | `sudo pacman -S nodejs npm` | 12.0 | ✅ |
| **Alpine** | `apk add nodejs npm` | 11.12 | ✅ |
| **openSUSE** | `sudo zypper install nodejs24` | 11.16 | ✅ |
| **RHEL / Rocky / CentOS** | `sudo dnf module enable nodejs:22 && sudo dnf install nodejs npm && sudo npm install -g npm@latest` | 10.9 → 12.0 | ✅ |
| **Any (vendor-neutral)** | `fnm install 24` (or `nvm install 24`) | 11.17 | ✅ |

## Traps we hit, so you don't

- **Ubuntu apt is a dead end.** `apt install nodejs npm` gives npm **9.2.0**, and
  `npm install -g npm@latest` then **fails** — `npm ERR! notsup` — because 9.2.0
  is too old to install npm 12. It cannot self-upgrade. Use the **snap**, not an
  apt-then-upgrade. This was the *only* mainstream distro whose obvious path did
  not yield a working cooldown.
- **`npm install -g npm@latest` only works if the starting npm isn't ancient.**
  It succeeded from RHEL's 10.9; it failed from Ubuntu's 9.2. On RHEL/openSUSE
  the upgrade is a required second step and it works; on Ubuntu it doesn't.
- **corepack is broken on Ubuntu 26** for running a modern pnpm
  (`ERR_VM_DYNAMIC_IMPORT_CALLBACK_MISSING` — its patched loader chokes on
  pnpm's ESM entry). Install pnpm via `sudo npm install -g pnpm@latest` or
  `get.pnpm.io`, not `corepack enable`.

## Why the results fall out this way

Distros that package **npm separately from Node** (Fedora, Arch, Alpine,
openSUSE) ship a *current* npm regardless of what Node bundles → cooldown out of
the box. Paths that install **current Node** (Ubuntu snap, Debian NodeSource,
fnm) bundle npm ≥ 11.10. Only a **frozen distro npm** (Ubuntu/Debian apt) loses —
and Ubuntu's apt npm is old enough that it can't even upgrade itself.

## After you upgrade npm

The role already wrote the `min-release-age` config — a newer npm just starts
honouring it. **Re-apply the role** (`ansible-playbook site.yml --limit
localhost`) so the npm PATH wrapper re-discovers and re-wraps the new npm, then
confirm with `supply-chain-verify` — the *npm age gate* row should leave `GAP`.

Units reminder: npm's `min-release-age` is in **days** (integer); the role
derives it from `release_age_hours`. See the units note in the README.

## Or sidestep npm entirely: pnpm

**pnpm** has had the equivalent cooldown (`minimumReleaseAge`) since **10.16
(Sep 2025)** — five months ahead of npm — installs as a self-contained binary on
any distro, and this role already writes its config. `tests/acceptance/
pnpm-signoff.sh` proves it enforces (blocked ✅ on a current pnpm). If your
workflow can route installs through pnpm, it is the most portable path to a
working cooldown, and it does not depend on your distro's Node packaging at all.
