# zig-runner

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
| `bugfix/*`, `hotfix/*`, `ci/*` | patch: `v1.2.3` → `v1.2.4` |
| `feature/*`, `feat/*`, `release/*`, `docs/*`, `perf/*`, `refactor/*` | minor: `v1.2.3` → `v1.3.0` |
| any of them, labelled `breaking` | major: `v1.2.3` → `v2.0.0` |

`feature/*` is for larger features, `feat/*` for small ones; neither breaks anything unless the
pull request carries the `breaking` label. A stack of pull requests releases once, when it reaches
`main`, with the largest bump in it. The release commits the version to `runner/build.zig.zon` and
the changelog on `main`, and tags that commit.

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
