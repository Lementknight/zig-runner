# The native step backend

The plan for running a job's steps in the runner itself, with Linux namespaces, overlayfs and
chroot, in place of the Dagger engine (BuildKit). It is a living document: each phase updates its
section when it lands and adds what it taught to "Learnings" at the end.

## Goal and decision

Today every step is a `withExec` in a Dagger session (`dagger.zig`, `dagger/`). The engine costs
about 240 ms of wall time and 290 ms of CPU per cold trivial step, and about 95 ms per step
replayed from its cache. A prototype that runs steps itself (runner-bench
`tools/native/nstep.c`, with its design note `DESIGN.md`) measured 12 ms per cold trivial step and
0.04 ms per replay on the laptop.

**Decision: build the full native backend, with a hybrid as the fallback.** "Full" means native
covers everything Dagger does for this runner today: run steps, checkout, the step cache and
replay, images, cache volumes, trust scopes, the memory gate, services and Docker actions, with
Dagger retired at the end. "Hybrid" is where we stop if the measurements say the rest is not worth
it: native for the jobs it covers, Dagger for the others, chosen per job.

The project rule holds throughout: native ports, not dependencies. The OCI pull, the layer store
and the sandbox are Zig in this repository. No runc, containerd, skopeo or fuse-overlayfs at
runtime. External tools may serve as test oracles only, as Node and .NET do elsewhere.

## Architecture

### The Backend boundary

The runner has two halves that today live together in `dagger.zig`:

- **Job orchestration**: evaluating expressions, conditions, `continue-on-error` and timeouts
  (`Evaluator`, `runStep`); the job log, markers, masking and workflow commands (`JobLog`,
  `redact`); file commands and outputs (`Exec.collect`); results and the observer.
- **Step execution**: building the base container (`set_up.zig`), running one script in it with
  its env and mounts (`Exec.execScript`), and reading back the exit code and the step's combined
  file-command file.

The boundary goes between them. A backend is asked for two things:

1. **The job's base**: the filesystem every step starts from (the provisioned image, the workspace,
   the step user, the event file) and its environment (the image's, the runner's `GITHUB_*`
   defaults, the job's `env:`).
2. **One exec**: run the `sh -c` script that `scripts.stepScriptFc` builds, on top of what the
   previous exec left, with the env the previous steps' `GITHUB_ENV` and `GITHUB_PATH` produced;
   stream its output lines into `JobLog` as they are printed; return the exit code and the
   contents of `/github/file_commands/all_<n>`.

Everything above that, including the script text itself, stays shared. Both backends run the same
script, so the markers, the file commands, `exec 2>&1`, the shells and their arguments, the script
file and the `env -u ...` command are byte-identical across them. The Dagger implementation is what
`dagger.zig` does today, unchanged. The native implementation lives in `runner/src/native/`.

### The knob

`RUNNER_BACKEND=dagger|native`, default `dagger`.

With `native`, each job is checked before it starts (`native.supports`). A job that uses something
the native backend cannot do yet runs on Dagger, and "Set up job" says so in one line, naming the
first reason: "This job runs on Dagger: native steps do not support `services:` yet". So the
migration is a hybrid by construction, and each phase shrinks the list of reasons. The choice is
per job, never per step: switching mid-job would mean exporting native layers into Dagger at each
switch and splitting the step cache's key chain across two stores (DESIGN.md, "Per job").

## Phases

Each phase lands behind the knob with the default unchanged, its tests green, its measurements in
the pull request, and its learnings below. "Exit" is what must be true to call the phase done.

### P1: run-only jobs

Jobs whose steps are all `run:` scripts (and the built-in checkout, if it is small to port), on the
default image, with no `container:`, `services:`, `uses:` actions, output keys or cache volumes.

- Rootfs: the provisioned default image, exported to a host directory once by the existing Dagger
  path until P3's native pull.
- Per step: an overlay on the previous step's layer, fresh mount, PID, UTS and IPC namespaces,
  chroot, the step's env and shell as the Dagger path builds them.
- File commands, masking, live log streaming with timestamps, exit codes, `continue-on-error`,
  `if:`, cancellation and timeouts through the shared code.
- Rootless through a user namespace when the runner is not root.
- Exit: a parity test runs the same run-only job through both backends and compares results and
  log lines; existing tests pass unchanged.
- Measure: wall time per cold trivial step, against Dagger's ~224 ms on the laptop.

**Status: landed (behind the knob).** What it covers, as built:

- `runner/src/native/Backend.zig` is the job side: the fallback decision (`unsupported`), the
  base, the container's env between steps, `execScript`, the checkout.
  `runner/src/native/sandbox.zig` is one step's sandbox: the runner's own binary started as `zig-runner native-step`, reading the
  step's spec as JSON on stdin (never on a command line: it holds the step's secrets).
- The boundary in the shared code is three lines: `dagger.run` sends a job native can run to
  `runNative`; `runSteps` asks the native backend for the base instead of `baseContainerId`; and
  `Exec.execScript` hands each exec to `Backend.execScript`. The Dagger path is unchanged, and so
  are its tests.
- Covered: `run:` steps with any shell, `defaults.run`, step and job `env:`, expressions, `if:`,
  `continue-on-error`, `timeout-minutes` and cancellation (the same `Watch`, which kills the step's
  sandbox), every file command, `::add-mask::` and the other workflow commands, problem matchers
  (read from the layers), step summaries, `id-token: write`, secrets in env, in scripts and in
  working directories, and the built-in checkout without submodules (git in the job's image, then
  the same step script Dagger's checkout runs).
- Falls back to Dagger, with "This job runs on Dagger: ..." in "Set up job": no rootfs configured,
  a job the runner does not vouch for (until P5), `container:`, `services:`, `uses:` actions,
  `docker://` steps, a custom image, Dagger in steps (`RUNNER_DAGGER_NESTING`), a checkout with
  submodules, and steps as the runner user on a rootless runner.
- Off on native, as caches: the step cache and output keys (P2), the package caches, uv's
  environment in its cache, and Zig's local cache and seed (P4). Results do not depend on them.
- Not done in P1: the export of the rootfs from Dagger at startup (below), supplementary groups
  for the step user, and a per-job helper (see P1's learnings).

#### Running it

```
RUNNER_BACKEND=native              # default dagger
RUNNER_NATIVE_ROOTFS=/var/lib/zig-runner/rootfs
RUNNER_NATIVE_STORE=/var/lib/zig-runner/native   # default; ~/.cache/zig-runner/native rootless
```

**The rootfs.** P1 takes a directory holding `ubuntu:24.04` with the runner's provisioning applied
(`set_up.provision_script`, or `provision_runner_script` when steps run as the runner user). It is
not yet exported by the runner through Dagger at startup: the direct engine session
(`engine.zig`) implements the client's side of file sync for reads only, and an export needs its
receiving side, which is as much work as P3's pull it would be thrown away for. Until P3, an
operator makes it once, for example with Docker on a machine that may use it:

```
docker run --name zr-rootfs ubuntu:24.04 sh -c '<set_up.provision_runner_script>'
mkdir -p /var/lib/zig-runner/rootfs
docker export zr-rootfs | tar -x -C /var/lib/zig-runner/rootfs
```

Rootless, extract it inside a user namespace (`unshare -r tar -x ...`) so its files are owned by
the runner's user, which is root inside the steps' namespace.

**Privileges.** The runner picks how to make a sandbox (`Backend.launch`):

- As root: a private mount namespace only, no user namespace; steps may run as any user, so
  `RUNNER_STEP_USER=runner` (the default) works.
- Rootless: a user namespace mapping the runner's user to root, with kernel overlayfs's
  `userxattr` (Linux 5.11 or later). Only root exists inside, so `RUNNER_STEP_USER=root` is
  needed; a job with the runner user falls back. Where AppArmor restricts unprivileged user
  namespaces (`kernel.apparmor_restrict_unprivileged_userns=1`, Ubuntu 24.04 and later), the
  sandbox is started under util-linux's `unshare`, which the stock profiles allow; an AppArmor
  profile granting `userns` to `/usr/local/bin/zig-runner` would let it make its own.
- Under `deploy/compose.yaml` (not changed by P1): the runner image is `FROM scratch` and runs as
  root, so it takes the root path, which needs `CAP_SYS_ADMIN` and the right to mount `proc` and
  `devpts` inside the container: `privileged: true` (as the engine service has), or
  `cap_add: [SYS_ADMIN]` with
  `security_opt: [seccomp=unconfined, apparmor=unconfined, systempaths=unconfined]`.
  The store must be a volume, not the container's own overlay filesystem (overlayfs cannot take an
  upper directory on overlayfs), and the rootfs another volume (read-only is enough).
- Under `deploy/zig-runner.service` on razorbill (not changed by P1): the unit runs as root with
  `ProtectSystem=strict`, which makes the store's default, `/var/lib/zig-runner/native`, read-only.
  It needs `StateDirectory=zig-runner` (or `ReadWritePaths=/var/lib/zig-runner`). `NoNewPrivileges`
  and `PrivateTmp` are compatible; a `RestrictNamespaces=` or a capability bounding set without
  `CAP_SYS_ADMIN` would not be.

#### Measured (laptop "cowbird", balanced profile, 2026-10-31, another agent benchmarking)

The runner binary built `ReleaseSafe`, `--exec-job` on a run-only job of 50 trivial steps (`true`)
and on a job of one, 7 rounds each, rootless (under `unshare`), the rootfs plain `ubuntu:24.04`.
Per step is (50-step job − 1-step job) / 49, which leaves out process start and "Set up job".

| | native | Dagger |
|---|---|---|
| cold trivial step, wall, median of 7 | **18.1 ms** (job of 50: 895–937 ms) | ~224 ms |
| 1-step job, whole | 29–34 ms | |

That is the whole runner path, not the backend alone: evaluating the step, its log header, the
JSON spec, starting the sandbox, streaming its output through `JobLog`, and reading its file
commands. Of the 18 ms, about 6 ms is making a user namespace and a mount namespace per step
(`unshare -r -m true` alone: 6.3 ms here), which the prototype paid once per job; the runner
binary's start (2.7 ms alone) overlaps most of the rest.

### P2: the layer store, cache, replay and GC

- First, from P1: one sandbox helper per job instead of per step. The helper makes the user and
  mount namespaces once and takes steps over a pipe, saving about 6 ms a step rootless.
- A content-addressed layer store: key `sha256(parent key, script, stable env)`, the model's
  `Key = parent · script · stable env`, without `volatile_env`.
- Replay of stored logs and file commands, so a replayed step costs well under a millisecond.
  Failures are not replayed (#69), which the model allows.
- Deterministic layer digests (a sorted walk of paths, modes, xattrs and content), standing in for
  `changes(from:).layer.digest`, which output keys need.
- Atomic publish by rename, a flock per key so pool runners sharing the store do not run one key
  twice, flattening past ~100 lowers, and LRU eviction under a byte cap.
- Exit: the step-cache tests that run through `dagger.run` pass on native too; replays are
  byte-identical to the live log. Measure: replay per step against ~95 ms; store size over 50 jobs.

### P3: the OCI image pull, a native port

- Registry protocol with token auth and private-registry credentials, manifest lists and the
  platform pick (amd64, arm64 for the Pi), gzip and zstd layers, the `.wh.` whiteout conversion,
  and content-addressed blobs.
- Provisioning becomes a native step of its own, keyed like any other.
- `container:` jobs move to native.
- Exit: no Dagger session is needed to make the rootfs. Measure: cold pull of `ubuntu:24.04`
  against Dagger's.

### P4: cache volumes, trust scopes and cgroup memory accounting

- Package cache volumes as host directories bound in, never part of a key (`Input.mounts`). The
  `repo` and `untrusted` scopes of `packageCacheScope` become separate directory trees. Dagger's
  sharing modes are reimplemented with flock; the default stays shared.
- Zig's local cache generations and the cache seed move over.
- A cgroup v2 per job: `memory.max`, `memory.peak`, `memory.events`, `pids.max`. The admission
  gate (`admission.zig`) reads per-job working sets instead of the engine's cgroup. Rootless, this
  needs systemd delegation (`Delegate=yes`, or `systemd-run --user --scope`).
- Exit: a runaway job is OOM-killed in its own cgroup without touching its neighbours. Measure:
  gate accuracy against the engine-wide reading.

### P5: isolation for untrusted jobs

- Decisions to make and record: subuid mapping through `newuidmap` versus a privileged runner;
  a network namespace per job with a userspace stack (a Zig port of the needed parts of pasta or
  slirp4netns, or a veth pair when root); `no_new_privs`, dropped capabilities, and a seccomp
  filter (which syscalls, and whether Docker's default profile is the reference).
- `trust.zig` is unchanged: it decides before any step. What changes is the blast radius: native
  steps run on the host kernel in the runner's namespaces, not inside the engine's container.
- Until P5 lands, native runs only jobs the runner vouches for (`trust.vouches`); others fall back.
- Exit: the hostile-job tests (fork bomb, mount escape attempts, network to the host's services)
  are contained.

### P6: services

- A job network namespace shared by steps and service containers, services as long-running
  namespace processes from the image store, health checks, `/etc/hosts` aliases, port mapping for
  host-mode jobs, and teardown with `cgroup.kill`.
- Exit: the services tests pass on native. Measure: "Initialize containers" time.

### P7: Docker actions

- Image-based actions as a run in their image with an entrypoint, on the P3 image store.
- Dockerfile actions need a builder. Options to weigh then: a native Dockerfile interpreter for the
  common subset (`FROM`, `RUN`, `COPY`, `ENV`, `WORKDIR`, `ENTRYPOINT`) on the layer store, or
  keeping Dagger for that case alone.
- JavaScript actions move over here too, since they are scripts plus a runtime mount.
- Exit: the actions tests pass on native.

### P8: remapping the Lean proofs

- The theorems keep their shape; the code they cite changes. The "a container *is* its recipe"
  row points at the native key chain instead of Dagger's lazy container id, and the runner now owns
  the obligation BuildKit discharged: the key is computed from exactly what the model says.
- `Output.digest` becomes the native layer digest; `OutputKeys.lean` needs it deterministic.
- `Logs.lean`'s hypothesis that the engine records stdout and stderr apart no longer applies if
  the native store records the interleaved stream; `exec 2>&1` may become optional.
- `Input.mounts` absent from the key holds by construction.
- Exit: `proofs/README.md` and the Lean files name native functions where they named Dagger's.

### P9: Pi validation, then the decision

- Run the full pool on the Pi (aarch64) and the laptop on native for a soak period: real workloads,
  hostile-job tests, cache growth, memory gate behaviour.
- Then decide: retire Dagger, or keep the hybrid. The revert criterion below makes that call
  mechanical.

## Revert criterion

We stop at the hybrid (native for what it covers, Dagger for the rest, nothing further ported) if,
after P2 and measured on real workloads on the laptop and the Pi:

- the median job's wall time improves by less than 10% against Dagger, and the replayed job by
  less than 50%; or
- runner CPU per job (engine plus runner) improves by less than 20% on the Pi; or
- native shows a correctness gap against Dagger that cannot be closed without reimplementing a
  BuildKit behaviour we cannot test (a parity failure with no clear fix), or a containment gap
  under P5's hostile-job tests.

We also stop porting any single phase whose cost, in the estimate it is given when it starts,
exceeds twice that estimate before it is half done; the jobs it would have covered stay on Dagger.

## Learnings

A running log. Each phase appends what Dagger did implicitly that had to be made explicit, what
surprised us, and the measured gains against Dagger.

### P0: the plan

- What the engine does for the runner is narrower than its API: one base container, one exec per
  step, and a file read per step. The runner already builds every step as a self-contained
  `sh -c` script (`scripts.stepScriptFc`) that brings its own markers and file commands, and reads
  the result back as one combined file. That is why the boundary can sit below the script: a
  native backend runs the same bytes and the shared code cannot tell the difference.
- The engine's cache key covers the script text, so the script builder was already written as if
  it were a public format (its comment says changing a byte re-keys every step). The native store
  inherits that discipline for free.
- Dagger's secrets (`setSecret`, `withSecretVariable`) exist to keep plaintext out of the engine's
  cache metadata (#101, #102). Natively there is no engine to leak into, but the step cache of P2
  will be: the same rule (secret-bearing values never in a key or a stored log) has to be kept
  explicitly by the native store.

### P1: run-only jobs

What Dagger (BuildKit and runc under it) did implicitly, now explicit in `native/`:

- **HOME.** runc sets HOME from the image's `/etc/passwd` when the env has none, so every root step
  under Dagger had `HOME=/root` without the runner ever setting it. The sandbox now reads it
  (`sandbox.homeOf`).
- **The resolver.** BuildKit puts the host's `/etc/resolv.conf` and `/etc/hosts` into every exec.
  Without them a step in the image's filesystem has no DNS. The sandbox binds them, only over
  files the image already has, since making the file would put it in the step's layer.
- **/dev, /proc, /sys.** runc builds a `/dev` of a few nodes, mounts `/proc` for the exec's PID
  namespace and `/sys` read-only. Binding the host's `/dev` (as the prototype did) would hand a
  root step the host's disks; the sandbox builds the small one.
- **Killing a step.** A BuildKit exec's processes die with it. Natively that comes from the step's
  first process being PID 1 of its own PID namespace, with `PR_SET_PDEATHSIG` tying it to the
  helper: killing the helper (through a pidfd, so a reused pid is never hit) takes everything the
  step started with it, background processes included, and closes the output pipe. The cancel test
  checks this with a backgrounded `sleep 60`.
- **Secrets out of command lines.** Under Dagger the reason for `withSecretVariable` and secret
  mounts was the engine's cache metadata. Natively the same discipline matters for another reason:
  `/proc/<pid>/cmdline` is readable by every user on the host. Keeping the identical script
  (aliases in `$ZIG_SECRET_<n>`, a script holding a secret written as a file, the spec over a pipe)
  keeps secrets out of every command line.
- **The container's env between steps.** Dagger's container carried `GITHUB_ENV` and `GITHUB_PATH`
  forward, with `$PATH` expanded by the engine (`withEnvVariable(expand: true)`). That state is
  now the backend's (`applyPendingEnv`), and the parity test checks the base env against Dagger's
  base query, variable by variable.
- **Overlay's work directory.** Overlay leaves `work/work` with mode 0; rootless, nothing can
  delete it until the runner gives the permissions back. Every leftover job directory in the first
  runs was this.

Surprises:

- The boundary was smaller than planned: three call sites in the shared code, plus `Secrets.local`
  (secrets named without a session) and an optional field on `Fetched` for the checkout's log line.
  No Dagger code path changed behaviour, and no existing test changed.
- Making a user namespace is the cost that matters. `unshare -r -m true` costs 6.3 ms on the
  laptop, a third of a native step. The prototype paid it once per job by re-executing itself under
  `unshare`; P1 pays it per step. P2 starts by keeping one helper per job.
- Ubuntu's AppArmor restriction on unprivileged user namespaces means a rootless runner cannot make
  a usable one itself: the namespace is created, but writing its uid and gid maps is refused
  (EPERM, checked on the laptop), so the runner's user never becomes root inside and owns none of
  the image's files. Borrowing `unshare` works because of the stock profiles; a profile of our own
  is the clean answer and a deploy decision.
- Tests needed the runner binary, because the sandbox is the runner started as a helper, and Zig's
  test runner refuses arguments of ours. The build copies the binary to a fixed place for the tests
  (`ZIG_RUNNER_TEST_EXE`), and the tests build a rootfs of a few directories with the host's `/usr`
  bound in, so CI needs no image.
- The engine's direct session cannot export a container's filesystem: it implements file sync for
  reads only. That is why P1's rootfs is made by the operator, and it is a reason to move P3 (the
  native pull) before the cache-volume work.

Measured against Dagger: a cold trivial step 18.1 ms against ~224 ms, about 12 times faster, about
206 ms saved per step, through the whole runner. Replays come in P2.
