# Sources

Research and references used to build this playbook.

## Primary sources

These directly influenced settings in the playbook.

| Source | Author | What we took |
|---|---|---|
| [claude-code-devcontainer](https://github.com/trailofbits/claude-code-devcontainer) | Trail of Bits | npm env vars (ignore-scripts, audit, save-exact, minimum-release-age), Python env vars (PYTHONDONTWRITEBYTECODE, PIP_DISABLE_PIP_VERSION_CHECK, UV_LINK_MODE) |
| [Supply chain hardening gist](https://gist.github.com/eapotapov/ae8c5eebf05776918f46a3f61c56cd43) | Evgeny Potapov (ApexData) | Release age configs for npm, pnpm, Yarn, Bun, uv, pip, Deno. Wheels-only enforcement for pip/uv. pip-dependency-cooldown script (credited to Seth Larson) |
| [npm-security-best-practices](https://github.com/lirantal/npm-security-best-practices) | Liran Tal | `allow-git=none`, lockfile-lint, npq integration, pnpm `blockExoticSubdeps`, Socket Firewall |
| [pypi-security-best-practices](https://github.com/lirantal/pypi-security-best-practices) | Liran Tal | uv `require-hashes` + `verify-hashes`, uv-secure, zizmor + pinact for GitHub Actions |
| [package-manager-hardening](https://github.com/jordanconway/package-manager-hardening) | Jordan Conway | uv hash verification, Bun `exact=true`, Go `GOTOOLCHAIN=local`, Yarn exact pinning (NOTE: upstream listed `lifecycleScripts=false` for Bun; we shipped that copy-paste for weeks before catching that the real bun key is `ignoreScripts` with inverted semantics — corrected 2026-05-28) |
| [BufferZoneCorp attack analysis](https://socket.dev/blog/malicious-ruby-gems-and-go-modules-steal-secrets-poison-ci) | Socket.dev | Go hardening: pin GOPROXY, clear GONOSUMCHECK/GONOSUMDB to prevent CI env poisoning |

## Secondary sources

These validated our approach or informed specific decisions.

| Source | Author | What we learned |
|---|---|---|
| [cooldowns.dev](https://cooldowns.dev) | Martin Prpic (Red Hat) | Cross-ecosystem age gate reference, confirmed configs, found cargo-cooldown crate |
| [Open Source Security at Astral](https://astral.sh/blog/open-source-security-at-astral) | Astral (uv/Ruff team) | Confirmed our uv settings match their own practices |
| [pip cooldown with crontab](https://sethmlarson.dev/pip-relative-dependency-cooling-with-crontab) | Seth Larson (PSF Security Dev-in-Residence) | pip `uploaded-prior-to` concept; we replaced his cron script with native uv `exclude-newer` |
| [npq](https://github.com/lirantal/npq) | Liran Tal | Pre-install reputation checks: typosquatting, provenance regression, dormant maintainers, expired domains |
| [Socket Firewall Free](https://github.com/SocketDev/sfw-free) | Socket.dev | Install-time malware blocking for npm/pip/cargo. PolyForm Shield License (free to use, non-compete) |

## Curated lists consulted

| List | Focus |
|---|---|
| [bureado/awesome-software-supply-chain-security](https://github.com/bureado/awesome-software-supply-chain-security) | Process-centric, covers the full domain |
| [meta-fun/awesome-software-supply-chain-security](https://github.com/meta-fun/awesome-software-supply-chain-security) | Tool-heavy (SCA, SBOM, signing, scanners) |
| [rezmoss/awesome-security-pipeline](https://github.com/rezmoss/awesome-security-pipeline) | Organized by CI/CD pipeline stage |
| [vishalgarg-sec/Software-Supply-Chain-Security](https://github.com/vishalgarg-sec/Software-Supply-Chain-Security) | Standards, regulations, books |
| [lirantal/awesome-nodejs-security](https://github.com/lirantal/awesome-nodejs-security) | Node.js security resources |

## Under-researched ecosystems

Composer (PHP), Maven (Java), Gradle (Java), NuGet (.NET), and Bundler (Ruby) have minimal community guidance on supply chain hardening compared to npm and Python. Our settings for these are based on official documentation rather than community best practices. Contributions welcome.
