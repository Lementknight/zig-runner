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

## Environments

A pull request can change any workflow, and name any runner in `runs-on`; on a personal account's
repository GitHub has no runner groups to stop it. So jobs are split by trust, and the runner
enforces it:

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

The design, specification, deployment guide, measurements and proofs behind this runner are in
[Lementknight/zig-actions-runner](https://github.com/Lementknight/zig-actions-runner), where it
was developed.

Licence: see [LICENSE](LICENSE); the vendored third-party code is listed in
[THIRD_PARTY.md](THIRD_PARTY.md).
