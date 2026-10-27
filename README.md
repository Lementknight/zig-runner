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

Releases follow [semantic versioning](https://semver.org/) and are cut by CI, not by hand. Pull
requests merge on their own once their checks pass, and once a day (or when `version` is run by
hand) everything merged into `main` since the last release becomes one new version, its binaries
and its image, after the maintainer approves it. What it bumps comes from the branches' prefixes,
which CI checks; the largest bump among them wins:

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
[zizmor](https://docs.zizmor.sh) for security), the format, build and tests, and the database tests
against TimescaleDB. The GitHub client's tests run over real connections to a local server
(`src/github/testserver.zig`), so how it handles redirects and tokens is tested, not described. A merge into
`main` goes through the merge queue, which runs `ci` again on top of `main`; `automerge` turns on
auto-merge for every pull request from a branch of this repository, so it joins the queue once its
checks pass (Renovate does the same for its own). Once a day, `version` releases what merged since
the last release, if anything did: it waits for approval in the `prod` environment, commits and
tags the release, and the tag runs `release`: the binaries with [GoReleaser](https://goreleaser.com), the image after a
[Trivy](https://trivy.dev) scan, each with signed build provenance. `scorecard` grades the
repository weekly with [OpenSSF Scorecard](https://scorecard.dev).
`compare` runs the comparison tools weekly
(`.github/scripts/*-diff.sh`): the expression evaluator, YAML reader, `hashFiles()`, problem
matcher regular expressions, HPACK decoder and RS256 signing against the implementations they
follow, on fresh random cases.
`proofs` checks the [Lean proofs](proofs/README.md) (the step cache, the regex matcher's loops, and
the `hashFiles()` walk) and compares the walk's model with `runner/src/glob.zig` on random cases,
when either changes and weekly. The workflows are written to be hard to turn against the
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
  The binaries' release also carries their SBOM (`zig-runner.spdx.json`: tls.zig and Zig's
  standard library, the only code compiled in besides the runner's own), attested too, and both
  attestations' bundles for checking offline (`--bundle zig-runner.provenance.jsonl`). A release is
  published only once all of it is attached.
- **Scanned.** Trivy checks the Dockerfile and the image before a push; accepted findings are in
  `.trivyignore.yaml`, each with why. GitHub's secret scanning blocks pushes carrying credentials.
- **Checked.** actionlint and zizmor check the workflows, shellcheck every shell script
  (`.github/scripts/shellcheck.sh`), and CodeQL the workflows and the Go tools; every job has a time
  limit. The Database tests job runs every test under ThreadSanitizer
  (`zig build test -Dsanitize-thread` locally). Vulnerabilities are reported privately ([docs/SECURITY.md](docs/SECURITY.md)).
- **One secret, one step.** The deploy key that may push to `main` is the `prod` environment's,
  which deploys only from `main` and waits for approval; it is loaded only in the step that pushes,
  and pushes only to GitHub's pinned host key.
- **No pull request code with secrets.** Nothing runs on `pull_request_target`; the release starts
  from a push to `main`, which only takes reviewed merges.

### Git hooks

`.githooks` runs CI's pull-request checks before code leaves your machine. Turn them on once per
clone:

```sh
git config core.hooksPath .githooks
```

- **pre-commit** refuses a commit on `main`, and checks that what is staged is formatted (`zig fmt`,
  `gofmt`) and that staged workflows pass actionlint.
- **pre-push** runs, on exactly the commits being pushed (in a temporary worktree): the branch
  name's prefix, `zig fmt` over the project, GitHub's expression cases, and the build and tests
  (`.github/scripts/zig-test.sh`; the database tests too when `PG*` or `ZIG_TEST_PG_URL` point at
  one); actionlint and zizmor when workflows changed; `gofmt` and `go vet` for changed Go tools;
  the Lean proofs and the `hashFiles()` model against `glob.zig` when either changed. It takes
  about 20 s.

They need the project's Zig (`minimum_zig_version` in `runner/build.zig.zon`) first on `PATH`, or
`ZIG=/path/to/zig`; Go for actionlint; pipx or uv for zizmor when workflows change; and Lean
(`lake`, from [elan](https://github.com/leanprover/elan)) when the proofs or `glob.zig` change.
`--no-verify` skips them; CI checks the same things regardless.

## Environments

A pull request can change any workflow and name any runner in `runs-on`, so jobs are split by
trust, and the runner itself enforces it:

- **prod**, the runner on the maintainer's machine (`runs-on: [self-hosted, prod]`), runs only jobs
  from pushes to `main`, version tags and `workflow_dispatch` there, whose workflow file comes from
  one of those refs too (`RUNNER_TRUSTED_REFS`, `RUNNER_TRUSTED_EVENTS`; `src/trust.zig`). Any
  other job fails before a step runs, with the reason in its log. The `prod` GitHub environment
  holds the release's deploy key, deploys only from `main` and `v*` tags, and waits for the
  maintainer's approval.
- **pre-prod**, where pull requests and the merge queue run, is GitHub's `ubuntu-latest`, on
  purpose: a hosted runner starts cold every time, so every pull request builds and tests the
  project in the worst case, with no caches to hide a slow or broken first build. Nothing there is
  trusted or holds a secret.

Pushes to `main` run CI on prod, so every merge exercises the runner; the repository variable
`PROD_RUNNER` holds prod's `runs-on` labels as JSON (unset, GitHub's runner stands in):

```sh
gh variable set PROD_RUNNER --body '["self-hosted","prod"]'
```

Pull requests therefore do not exercise the runner itself, which is the price of the cold builds;
the release checks ("Binaries (check)" and "Image" in `release.yml`) still build it with `zig build`
on every pull request. A self-hosted pre-prod remains possible (`PREPROD_RUNNER`, and
`deploy/runner.preprod.env.example` for a runner with no trusted refs, no secrets and no access to
its Dagger engine from steps; the engine is built for `linux/amd64` and `linux/arm64` only), but
the project leaves it unset. The release still builds on GitHub's runners.

Workflows name `prod` (or `pre-prod`, should one exist), never just `zig`, which any of this project's
runners carries. Workflows from
outside contributors' pull requests also wait for approval before they run at all.

## Deploying releases

A release deploys itself to razorbill. Once its binaries and image are built, `release` records a
GitHub deployment of the version to the `razorbill` environment. On razorbill,
`zig-runner-deploy.timer` asks every minute; for a new deployment `deploy/zig-runner-deploy`:

1. downloads the release's binary, checks it against `SHA256SUMS`, and checks its provenance:
   built by `release.yml`, from that tag, on GitHub's own runners (`gh attestation verify`);
2. installs it and restarts every runner instance (`zig-runner.service` and `zig-runner@*.service`,
   or `UNITS`), each finishing its running jobs first;
3. reports success once each instance is listening for jobs again, or puts the previous binary
   back and reports failure.

The outcome shows under the repository's Environments, on the deployment. Nothing reaches into the
machine: it asks GitHub, with a token that can only read and report deployments. To set it up, on
the machine, with `gh` 2.68 or later from [cli.github.com](https://cli.github.com) (Debian's
package cannot verify provenance) and a fine-grained token for this repository with Deployments
read and write, Attestations and Contents read:

```sh
sudo install -m 0755 deploy/zig-runner-deploy /usr/local/bin/
sudo install -m 0600 deploy/zig-runner-deploy.env.example /etc/zig-runner-deploy.env   # GH_TOKEN
sudo cp deploy/zig-runner-deploy.service deploy/zig-runner-deploy.timer /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now zig-runner-deploy.timer
```

## Benchmarks

[BENCHMARKS.md](BENCHMARKS.md) has what was measured on the reference machine, a Raspberry Pi 5:
where a job's time goes (the engine, not the runner), what an engine restart does to its cache, what
installing Zig costs, and the earlier study's results with their verdicts.

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
