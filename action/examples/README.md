# Using the hardening outside GitHub Actions

`harden.sh` is CI-generic. These are worked examples per platform.

Read the portability section of [`../README.md`](../README.md) first — the
short version is that the config-file and PATH-wrapper layers work everywhere
with no help, and only the **env layer** needs the platform's own mechanism.
On `github`, `circleci` and `azure` that happens automatically. On `gitlab`,
`buildkite` and `plain` the job sources the env file, because `harden.sh` runs
as a subprocess and its own exports never reach the calling shell.

> Only the GitHub adapter is exercised by CI today. These are written against
> each platform's documented mechanism but are not yet covered by a passing
> pipeline — treat them as a starting point, and please report corrections.

| File | Platform |
|---|---|
| `gitlab-ci.yml` | GitLab CI |
| `circleci-config.yml` | CircleCI |
| `azure-pipelines.yml` | Azure Pipelines |
| `buildkite-hook.sh` | Buildkite (pre-command hook) |
| `drone.yml` | Drone / Woodpecker (per-step containers) |
| `Dockerfile` | Bake into an image; no CI adapter at all |

## Which to reach for

If your CI runs containers, the **Dockerfile** approach is the most portable
of all — the hardening is baked in, and no platform-specific env mechanism is
involved. It is the right answer when you control the image.

Otherwise pick your platform's file. All of them assume the repo is checked
out; adjust the path to `harden.sh` if you vendor it elsewhere.
