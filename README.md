# zig-runner

[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/Open-Blue/zig-runner/badge)](https://scorecard.dev/viewer/?uri=github.com/Open-Blue/zig-runner)

A self-hosted GitHub Actions runner in Zig. One small process runs many runners; each job's
steps run in a [Dagger](https://dagger.io) engine, which caches them across runs.

This repository holds only what the runner needs to be built, run and deployed:

- `runner/`: the source, `build.zig`, and the `Dockerfile` for the runner image
- `deploy/`: a systemd unit, a Docker Compose file, the engine's configuration, an example env file
- `db/migrations/`: the schema for the optional Postgres mode (run state and logs)

Build and run, with Zig 0.17 and Docker on the machine:

```sh
cd runner
zig build -Doptimize=ReleaseSafe
cp deploy/runner.env.example /etc/zig-runner.env   # then fill in GH_TOKEN and GH_SCOPE
zig-out/bin/runner
```

Or install `deploy/zig-runner.service` and run it under systemd, or `docker compose -f deploy/compose.yaml up`.

## Versioning

Releases follow [semantic versioning](https://semver.org/) and are cut by CI, not by hand: every
pull request merged into `main` releases a new version, its binaries and its image. What it bumps
comes from the branch's prefix, which CI checks:

| Branch | Bumps |
| --- | --- |
| `bugfix/*`, `hotfix/*`, `ci/*`, and Renovate's `renovate/*` | patch: `v1.2.3` → `v1.2.4` |
| `feature/*`, `feat/*`, `release/*`, `docs/*`, `perf/*`, `refactor/*` | minor: `v1.2.3` → `v1.3.0` |
| any of them, labelled `breaking` | major: `v1.2.3` → `v2.0.0` |

`feature/*` is for larger features, `feat/*` for small ones; neither breaks anything unless the
pull request carries the `breaking` label. In a stack, each pull request merged into `main`
releases its own version; one merged into another's branch instead counts toward that one's bump
when it reaches `main`. The release commits the version to `runner/build.zig.zon`
and the changelog on `main`, and tags that commit.

[semantic-release](https://github.com/semantic-release/semantic-release) and
[release-please](https://github.com/googleapis/release-please) do this job from
[Conventional Commits](https://www.conventionalcommits.org) in commit messages instead (`feat:`,
`fix:`, `feat!:`). They are not used here: the version comes from the branch, and either would
decide the version, write the changelog and tag the release alongside this, disagreeing with it.

## Pipeline

`ci` checks every pull request: the branch name, the workflows (actionlint, and
[zizmor](https://docs.zizmor.sh) for security), and the format, build and tests. A merge into
`main` goes through the merge queue, which runs `ci` again on top of `main`; the merge then runs
`version`, which waits for approval in the `prod` environment, commits and tags the release, and
the tag runs `release`: the binaries with [GoReleaser](https://goreleaser.com), the image after a
[Trivy](https://trivy.dev) scan, each with signed build provenance. `scorecard` grades the
repository weekly with [OpenSSF Scorecard](https://scorecard.dev). The workflows are written to be hard to turn against the
repository:

- **Least privilege.** Each workflow grants nothing by default; each job asks for only what it
  needs, with a comment saying why. Checkouts keep no credentials for later steps.
- **Pinned inputs.** Actions are pinned by commit and images by digest, not by tag, which their
  owner (or whoever takes their repository) can move; [Renovate](https://docs.renovatebot.com)
  proposes updates a week after their release. Zig and changie are checked against pinned checksums
  before they run; a Renovate pull request for a new one fails until its checksums are updated.
- **Verifiable releases.** Every binary and image has a signed provenance attestation saying which
  workflow built it from which commit:
  `gh attestation verify zig-runner-linux-x86_64 --repo Open-Blue/zig-runner`, or
  `gh attestation verify oci://ghcr.io/open-blue/zig-runner:<tag> --repo Open-Blue/zig-runner`.
- **Scanned.** Trivy checks the Dockerfile and the image before a push; accepted findings are in
  `.trivyignore.yaml`, each with why. GitHub's secret scanning blocks pushes carrying credentials.
- **One secret, one step.** The deploy key that may push to `main` is the `prod` environment's,
  which deploys only from `main` and waits for approval; it is loaded only in the step that pushes,
  and pushes only to GitHub's pinned host key.
- **No pull request code with secrets.** Nothing runs on `pull_request_target`; the release starts
  from a push to `main`, which only takes reviewed merges.

## Environments

A pull request can change any workflow and name any runner in `runs-on`, so jobs are split by
trust, and the runner itself enforces it:

- **prod**, the runner on the maintainer's machine (`runs-on: [self-hosted, prod]`), runs only jobs
  from pushes to `main`, version tags and `workflow_dispatch` there, whose workflow file comes from
  one of those refs too (`RUNNER_TRUSTED_REFS`, `RUNNER_TRUSTED_EVENTS`; `src/trust.zig`). Any
  other job fails before a step runs, with the reason in its log. The `prod` GitHub environment
  holds the release's deploy key, deploys only from `main` and `v*` tags, and waits for the
  maintainer's approval.
- **pre-prod**, a runner on a machine of its own with nothing worth reaching
  (`runs-on: [self-hosted, pre-prod]`), runs pull requests and anything else: no trusted refs, no
  secrets, and no access to its Dagger engine from steps (`deploy/runner.preprod.env.example`).

Workflows name `prod` or `pre-prod`, never just `zig`, which both runners carry. Workflows from
outside contributors' pull requests also wait for approval before they run at all.

## Changelog

[CHANGELOG.md](CHANGELOG.md) is kept with [changie](https://changie.dev): each change is a file
under `.changes/unreleased/`, written with `changie new` in the pull request that makes it. The
release batches them into the version's notes (`changie batch <version> && changie merge`), which
are also its GitHub release's notes.

## Origin

The runner was developed in
[Lementknight/zig-actions-runner](https://github.com/Lementknight/zig-actions-runner), together
with a read API and a frontend by [@philgutowski](https://github.com/philgutowski), the Tiger Data
schema by [@rafayet-git](https://github.com/rafayet-git), and the design documents, specification,
deployment guide, measurements and Agda proofs. Releases v0.1.0 and v0.2.0 were made there. This
repository carries the runner's history from that work and continues it with only what the runner
needs to build, run and deploy; the rest stays in the original repository.

Licence: see [LICENSE](LICENSE); the vendored third-party code is listed in
[THIRD_PARTY.md](THIRD_PARTY.md).
