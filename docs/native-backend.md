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

**Status: landed (behind the knob), reviewed, and hardened.** What it covers, as built:

- `runner/src/native/Backend.zig` is the job side: the fallback decision (`unsupported`), the
  machine's capability (`usable`, probed once, and again five minutes after a failure), the job's
  directory, slot, ids and network, the base, the container's env between steps, `execScript`, and
  the checkout. `runner/src/native/sandbox.zig` is one step's sandbox: the runner's own binary
  started as `zig-runner native-step`, reading the step's spec as one line of JSON on stdin (never
  on a command line: it holds the step's secrets), with stdin kept open as its lifeline.
  `runner/src/native/net.zig` is a job's network, over rtnetlink.
- The boundary in the shared code is three lines: `dagger.run` sends a job native can run to
  `runNative`; `runSteps` asks the native backend for the base instead of `baseContainerId`; and
  `Exec.execScript` hands each exec to `Backend.execScript`. The Dagger path is unchanged, and so
  are its tests.
- Covered: `run:` steps with any shell, `defaults.run`, step and job `env:`, expressions, `if:`,
  `continue-on-error`, `timeout-minutes` and cancellation (the same `Watch`; the helper kills the
  step's PID 1 when told), every file command, `::add-mask::` and the other workflow commands,
  problem matchers (read from the layers, relative to the working directory), step summaries,
  `id-token: write`, secrets in env, in scripts and in working directories, and the built-in
  checkout without submodules (git in the job's image, then the same step script Dagger's
  checkout runs).
- Falls back to Dagger, with "This job runs on Dagger: ..." in "Set up job": no rootfs
  configured, a job the runner does not vouch for (`trust.vouches`, for `--exec-job` too), a
  rootless runner unless `RUNNER_NATIVE_ROOTLESS=1`, `container:`, `services:`,
  `docker://` steps whose image is not in the native image store (P7), JavaScript and local
  actions (P7, `actions.preload`), a custom image, Dagger in
  steps (`RUNNER_DAGGER_NESTING`), `hashFiles()` anywhere in the job (it reads the container
  through Dagger), a checkout with submodules, and a
  machine whose probe fails (no user namespaces, `iptables` missing, no default route, the jobs'
  ids taken on the host, the jobs' subnet overlapping a route of the host's). A failed probe is
  tried again after five minutes, not kept for the process's life.
- Off on native, as caches: the step cache and output keys (P2), the package caches, uv's
  environment in its cache, and Zig's local cache and seed (P4). Results do not depend on them.
- "Set up job" says what the job got: "Native steps: ids 0-65535 are host ids N-N+65535, and the
  job's network is its own (10.211.1.x on zr0)", or the rootless warning.

#### Isolation: what P1 provides, and what it does not

On a root runner, each step runs:

- in a **user namespace of the job's own**, ids 0-65535 mapped to a range of host ids no host user
  has (`RUNNER_NATIVE_SUBID_BASE`, by default 1,900,000,000 plus 65,536 per slot). The default
  lies past systemd's container range (systemd-nspawn's private users and nsresourced's,
  524288-1879048191) and the last slot's ids (up to 1,916,383,999) stay below its foreign range
  (from 2,147,352,576) and below 2^31, which some tools take as signed. The probe refuses a base
  below 100,000, a range past 2^32, and a range that overlaps one in /etc/subuid or /etc/subgid
  or holds an id from /etc/passwd or /etc/group (users only a directory service knows are not
  seen; the 100,000 floor is above their usual ranges). The step's root and its uid 1001 are
  nobody on the host: a breakout, sudo or a setuid program gains no host privilege. A full range
  is mapped, so apt's `_apt`, `chown` and `tar` with owners work. The rootfs is seen through an
  idmapped mount (Linux 5.19), not copied per range.
- in a **network namespace of the job's own** (all its steps share it): its own `lo` and port space,
  a veth on the runner's bridge `zr0` (`RUNNER_NATIVE_SUBNET`, by default 10.211.0.0/16 with the
  bridge at 10.211.0.1 and slot n's job at 10.211.1.(n+2); not podman's 10.88.0.0/16 or Docker's
  ranges, and refused when it overlaps a route of the host's), a default route out through NAT. Two
  jobs can both listen on :5432. The job reaches nothing on the host: not its 127.0.0.1, and not a
  service on any of its addresses (the bridge's included), since `INPUT` drops whatever comes from
  `zr0` and is not a reply. Jobs cannot reach each other: each veth is an isolated bridge port
  (`IFLA_BRPORT_ISOLATED`), and `FORWARD` drops traffic from `zr0` back to `zr0`. IPv6 is off on the
  job's `eth0` and on the bridge, so no link-local address slips past those IPv4 rules (`lo` keeps
  its ::1). Ports below 1024 and ping work without capabilities on the host's
  (`ip_unprivileged_port_start=0`, `ping_group_range`, set in the job's namespace only). Its
  resolver is the host's upstream servers (`/run/systemd/resolve/resolv.conf`, or the host's
  resolv.conf when it names no loopback server), since systemd-resolved's 127.0.0.53 is the host's
  loopback; a resolver on one of the host's own addresses is out of reach too.
- in **mount, PID, UTS and IPC namespaces** of its own, with the overlay as `/` by `pivot_root`
  and the host's root detached (no chroot to climb out of), a /dev of six nodes plus devpts, shm
  and mqueue, /proc with runc's masked paths (`kcore`, `keys`, `timer_list`, `sched_debug`,
  `interrupts`, ...) and read-only ones (`/proc/sys`, `sysrq-trigger`, `irq`, `bus`, `fs`),
  cloned from the step's own /proc with every mount under them, and /sys read-only with every
  mount under it. A mask or a read-only path the kernel has but that cannot be applied fails the
  step's set-up; only a path the kernel does not have is skipped.
- with **Docker's default capabilities** (the bounding set cut to them, ambient cleared),
  **no_new_privs** for root steps and rootless ones (not for the runner user on a root runner,
  whose sudo works as on GitHub and reaches only the job's own root, within the same capabilities
  and filter), and a **seccomp filter** that refuses Docker's default profile's dangerous
  calls (module loading, kexec, keyrings, bpf, perf, mount and the new mount API, namespaces,
  clone with namespace flags, the clock, swap, reboot, `open_by_handle_at`, and io_uring, as
  Docker has since moby 25), and allows `personality` only with Docker's values (Linux, 32-bit
  Linux, a 2.6 uname, and the query).
- with a script that holds a secret written to a **tmpfs of the step's own** and bound at its
  path over an empty file, so the secret never reaches the store's disk (the empty file goes
  when the step ends).
- with every path inside the overlay resolved inside it (`openat2(RESOLVE_IN_ROOT)`), by the
  helper and by the runner, so a symlink a step plants never leads them to the host's files.

What it does not provide yet:

- **Resource limits.** No cgroup per job and no pids limit: a fork bomb or a memory hog reaches
  the host's limits. Debt, recorded under phase 4 beside the gate's cgroup memory accounting.
- **The seccomp filter is Docker's deny list, not its allow list.** Calls Docker refuses by
  omission are allowed here.
- **Rootless runners.** Only one id is mapped and steps share the host's network: off unless
  `RUNNER_NATIVE_ROOTLESS=1`, for tests and the laptop. A rootless job network needs a userspace
  stack (a Zig port of the parts of pasta or slirp4netns it needs), and full ids need
  `newuidmap`.
- **Kernel attack surface.** Steps run on the host's kernel, as containers do; a kernel bug is a
  breakout.

#### Running it

```
RUNNER_BACKEND=native              # default dagger
RUNNER_NATIVE_ROOTFS=/var/lib/zig-runner/rootfs   # absolute; checked at startup
RUNNER_NATIVE_STORE=/var/lib/zig-runner/native    # default as root
RUNNER_NATIVE_SUBID_BASE=1900000000               # default; at least 100000
RUNNER_NATIVE_SUBNET=10.211.0.0/16                # default; a prefix of 8 to 23 bits
RUNNER_NATIVE_ROOTLESS=0                          # default; 1 for a rootless runner
RUNNER_NATIVE_IMAGES=/var/lib/zig-runner/images   # P7: Docker actions' images; default none
```

**The rootfs.** P1 takes a directory holding `ubuntu:24.04` with the runner's provisioning applied
(`set_up.provision_script`, or `provision_runner_script` when steps run as the runner user), owned
as the image has it (root's files root's). It is not yet exported by the runner through Dagger at
startup: the direct engine session (`engine.zig`) implements the client's side of file sync for
reads only, and an export needs its receiving side, which is as much work as P3's pull it would be
thrown away for. Until P3, an operator makes it once, for example with Docker on a machine that may
use it:

```
docker run --name zr-rootfs ubuntu:24.04 sh -c '<set_up.provision_runner_script>'
mkdir -p /var/lib/zig-runner/rootfs
docker export zr-rootfs | tar -x -C /var/lib/zig-runner/rootfs
```

**What the runner needs.** As root (the supported mode): `CAP_SYS_ADMIN` (namespaces, mounts,
idmapped mounts, `pivot_root`), `CAP_NET_ADMIN` (the bridge, veths, addresses, routes, NAT),
`CAP_SETUID`/`CAP_SETGID` (writing the job's id maps), Linux 5.19 or later (idmapped overlay
layers), `iptables` on the host (the rules, below), a default route, a free
`RUNNER_NATIVE_SUBNET`, and a writable `/run/zig-runner`. The runner makes `zr0` and its rules
itself on its first native job, and removes each job's namespace when the job ends, or at the
next start after a crash (`sweep`, by the jobs' locks).

What it changes on the host, which is shared by every runner on it:

- **Slots.** A job's slot names the veth `zrh<n>`, its address and its range of ids, all of them
  the host's, so slots are locked host-wide: an flock on `/run/zig-runner/slots/<n>.lock`, in a
  directory only root may enter, never under a runner's store. Two runners with different
  `RUNNER_NATIVE_STORE`s on one host take different slots, and a slot's veth is removed (a dead
  job's) only by the runner that now holds its lock. Every runner on a host must use the same
  `RUNNER_NATIVE_SUBNET`, since `zr0` is one bridge.
- **IPv4 forwarding** (`net.ipv4.ip_forward`) is turned on if it is off, and stays on: other
  runners' jobs need it, and turning it off under them would cut their network. The runner logs
  a warning when it turns it on, and another when the FORWARD policy is ACCEPT, since the host
  would then route for any neighbour; set that policy to DROP (Docker does).
- **iptables rules**, each added once at the head of its chain: `nat POSTROUTING` masquerades
  the subnet; `filter INPUT` drops what comes from `zr0` and is not a reply; `filter FORWARD`, and
  `DOCKER-USER` on a Docker host, drop `zr0` to `zr0`, accept `zr0` out through each uplink (the
  interfaces of the default routes; a job adds the rules for a new one, a laptop moving from
  cable to Wi-Fi), and accept replies back to `zr0`. Nothing else from `zr0` is accepted, so
  Docker's containers and other bridges stay closed to jobs and ufw's forward policy decides the
  rest. The rules stay when the runner stops.

- Under `deploy/compose.yaml` (not changed by P1): the runner image is `FROM scratch` and runs as
  root. It needs `privileged: true` (as the engine service has), or `cap_add: [SYS_ADMIN,
  NET_ADMIN]` with `security_opt: [seccomp=unconfined, apparmor=unconfined,
  systempaths=unconfined]`, and `network_mode: host` for the bridge to be the host's. The store
  must be a volume, not the container's own overlay filesystem (overlayfs cannot take an upper
  directory on overlayfs), and the rootfs another volume. The slots' locks must be the host's:
  bind `/run/zig-runner:/run/zig-runner` from the host into every runner container (the
  container's own /run would give each its own slot 0 on the shared bridge). The image has no
  `iptables`, so P1's NAT needs the host's rules made outside it, or P5's netlink rules.
- Under `deploy/zig-runner.service` on razorbill (not changed by P1): the unit runs as root with
  `ProtectSystem=strict`, which makes the store's default and `/run` read-only. It needs
  `StateDirectory=zig-runner` (or `ReadWritePaths=/var/lib/zig-runner`) for the store, and
  `RuntimeDirectory=zig-runner` with `RuntimeDirectoryPreserve=yes` for the slots' locks.
  Preserve matters when several units share the directory: without it, systemd removes
  `/run/zig-runner` when any one of them stops, the others' locks go with their files, and the
  next runner would take a slot a live job holds. `NoNewPrivileges` and `PrivateTmp` are
  compatible; a `RestrictNamespaces=`, a capability bounding set without `CAP_SYS_ADMIN` and
  `CAP_NET_ADMIN`, or `PrivateNetwork=` would not be.
- Rootless (tests, the laptop): a user namespace mapping the runner's user to root, with overlay's
  `userxattr` (Linux 5.11). Where AppArmor restricts unprivileged user namespaces
  (`kernel.apparmor_restrict_unprivileged_userns=1`), the sandbox is started under util-linux's
  `unshare` where its profile allows it (the laptop), and needs the restriction lifted where it
  does not (GitHub's hosted runner).

#### Measured (laptop "cowbird", balanced profile, 2026-10-31, another agent benchmarking)

The runner binary built `ReleaseSafe`, `--exec-job` on a run-only job of 50 trivial steps (`true`)
and on a job of one, rootless (under `unshare`), the rootfs plain `ubuntu:24.04`. Per step is
(50-step job − 1-step job) / 49, which leaves out process start and "Set up job".

| | native | Dagger |
|---|---|---|
| cold trivial step, first cut (chroot, no hardening), median of 7 | 18.1 ms | ~224 ms |
| cold trivial step, hardened, median of 5 | **32.7 ms** | ~224 ms |
| 1-step job, whole, hardened (with the once-per-process probe) | 58–80 ms | |

That is the whole runner path, not the backend alone. The hardened figure was taken under more
load (3.2 against 2.4) and pays, per step, a second mount namespace and about 20 mounts (/dev and
its nodes, /proc and its masks, /sys's tree, the binds, `pivot_root`), besides the 6 ms of making a
user namespace that the first cut already paid. Both are per step only because the helper is: P2's
per-job helper makes the namespaces and the static mounts once.

### P2: the layer store, cache, replay and GC

- First, from P1: one sandbox helper per job instead of per step. The helper makes the namespaces,
  /dev, /proc and its masks once and takes steps over a pipe: about 15 ms a step on the laptop.
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
- **Debt from P1, paid here:** P1 has no per-job cgroup and no pids limit, so one native job's
  fork bomb or memory hog reaches the host's limits and every other job's. The same cgroup that
  gives the gate its accounting gives each job its `pids.max` and `memory.max`.
- Exit: a runaway job is OOM-killed in its own cgroup without touching its neighbours. Measure:
  gate accuracy against the engine-wide reading.

### P5: isolation for untrusted jobs

P1 already gives each job on a root runner its own ids, its own network, pivot_root, masked
/proc, Docker's capabilities, no_new_privs and a seccomp deny list ("Isolation" under P1). What
remains before native steps may run jobs the runner does not vouch for:

- Resource limits come with phase 4's cgroups; until then, no untrusted job.
- Seccomp as Docker's allow list rather than its deny list.
- The NAT and forwarding rules over nftables netlink instead of `iptables` (P1's debt).
- Rootless: a userspace network stack for the job's network (the parts of pasta or slirp4netns it
  needs, ported) and subordinate ids through `newuidmap`.
- `trust.zig` is unchanged: it decides before any step. Until P5 lands, native runs only jobs the
  runner vouches for (`trust.vouches`); others fall back.
- Exit: the hostile-job tests (fork bomb, memory hog, mount escape attempts, network to the host's
  services, a kernel-interface sweep) are contained.

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

**Status: `docker://` steps landed (behind the knob); `uses:` Docker actions still go to
Dagger.** What it covers, as built:

- `runner/src/native/docker_action.zig` runs a `docker://` step as a sandbox in its image:
  `sandbox.Spec.Container` gives the helper a second overlay (the image's filesystem, idmapped on
  a root runner as the job's rootfs is, under a layer of the container's own that goes when the
  step ends, as `docker run --rm`), and binds into it, from the job's overlay, the four
  directories GitHub binds (`ContainerActionHandler.cs`): the workspace at `/github/workspace`,
  and `/github/home`, `/github/file_commands` and `/github/workflow`. The job's overlay gets a
  new layer as for any step, so what the action writes in the workspace, deletions included, is
  in the job's next step without a copy. The command is started as `docker run` starts it (the
  action's or the image's entrypoint, then its args or the image's command,
  `Exec.containerArgv`, looked up in the image's PATH; 127 with Docker's message when it is not
  there), in `/github/workspace`, as root, in the job's network, with the same capabilities,
  seccomp filter and `no_new_privs` as a root step.
- Everything the action is given is the Dagger path's, shared: `runImageStep` (inputs, `with:
  args` split as a command line, `with: entrypoint`), the log group with its `image:` line,
  `Exec.containerEnv` (the job's env without what GitHub sets again, the step's and the action's
  env, INPUT_*, `HOME=/github/home`, the runtime's variables and the OIDC token), and
  `Exec.collect` for the file commands. On top of the image's own `ENV`, as the container Dagger
  starts from has it. The shared code changed in two lines: `runContainer` hands the run to
  `docker_action.run` after the log group, and `dagger.run` asks `docker_action.unsupported`.
- `runner/src/native/images.zig` is the narrowest image interface the actions need: for a
  reference, its rootfs and the parts of its OCI config an action starts from (entrypoint, command,
  env, user). Until P3, it reads a directory the operator fills (`RUNNER_NATIVE_IMAGES`), one image
  per reference, keyed by the normalised reference with every byte outside `[A-Za-z0-9._-]`
  percent-encoded (`alpine:3.22` is `docker.io%2Flibrary%2Falpine%3A3.22`):

  ```
  k='docker.io%2Flibrary%2Falpine%3A3.22'
  mkdir -p "/var/lib/zig-runner/images/$k/rootfs"
  docker create --name zr-img alpine:3.22 && docker export zr-img |
    tar -x -C "/var/lib/zig-runner/images/$k/rootfs" && docker rm zr-img
  docker image inspect --format '{"config":{{json .Config}}}' alpine:3.22 \
    > "/var/lib/zig-runner/images/$k/config.json"
  ```

- Falls back to Dagger, with "This job runs on Dagger: ..." in "Set up job": a `docker://` image
  that is not in the store (or no store), and an image whose `USER` is not root (GitHub's
  documentation requires root for Docker actions; Dagger's path gives another user the
  directories it writes, which here needs an idmapped share, below). For `uses:` actions, see
  "The action loader" below.
- Parity kept explicitly: on a root runner with steps as the runner user, what the action made or
  changed in the workspace is given to the runner user afterwards (the files in the step's layer
  under the workspace, through no symlink), as Dagger copies the workspace back owned by it; a
  later step can change what the action wrote. The runner's markers and the event variable are
  not in the action's env, as the script's `env -u` leaves them out.

What it does not do yet, and who pays:

- **Local actions built from a Dockerfile.** Their tree is only in the workspace, spread over
  the job's layers, where the builder needs one host directory. They send the job to Dagger;
  debt of P7 (a build context read from the layers).
- **A local action that differs at run time from the job's commit** (a step rewrote it): the
  pre-flight judged the commit's. With every kind of action native, the only way that bites is an
  image the commit's version did not need and the store lacks: the step fails saying so, where
  Dagger would have pulled it. Gone with P3's pull.
- **Images with a non-root `USER`, and a `RUN` as one.** They need the shares idmapped so the
  image's user owns them, as Dagger's `owner:` does. Debt of P7.
- **The pull.** Images come from the operator's directory until P3's store replaces
  `images.lookup`.
- **Small differences from Dagger's path**, none visible to an action that follows GitHub's
  documentation: `/github/home` is in the job's filesystem (Dagger keeps it beside the job's
  container), `/github/file_commands` holds the earlier steps' files (Dagger's is empty per
  action, as is GitHub's per step), and a command that cannot be found prints Docker's message
  where busybox's `env` printed its own; both exit 127.
- **A secret in `with: args`** is in the action's own command line, readable by the host's users
  through `/proc/<pid>/cmdline`, as under Dagger (where busybox expands it into the command) and
  on GitHub (`docker run`). Nothing the runner does can hide a program's own arguments; secrets
  belong in `env:`.

**The Dockerfile builder** (`runner/src/native/dockerfile.zig`). `parse` reads a Dockerfile as Docker's parser
does (comments, parser directives, `\` continuations, either case, JSON and shell forms); `plan`
evaluates `FROM`, `RUN`, `COPY`, `ADD`, `ENV`, `WORKDIR`, `ENTRYPOINT`, `CMD`, `ARG`, `USER` and
`LABEL` into the image's config and one key per instruction, chained from the base's:
`sha256(parent key, instruction as evaluated, what it reads)`, where a `RUN` reads the env and
build arguments it sees and a `COPY` the content of its sources (`contextDigest`: a sorted walk
of paths, kinds, modes, link targets and contents, through no symlink). A config-only
instruction gets a key and no layer, so the `RUN` after it is keyed on it. `build` takes each
layer from the store by its key, or makes it (`COPY`/`ADD` by the runner, as Docker places
sources; `RUN` through a `Runner`, the sandbox) and publishes it (`layers.zig`, the stand-in for
P2's store: "the layer under K, or store this directory under K", by rename). It refuses, with
the line and why: multi-stage builds, `COPY --from`, wildcards, `ADD` of a URL or an archive,
`SHELL`, `ONBUILD`, heredocs, sources outside the context, and `--chown` by name.

The `Runner` is the sandbox (`docker_action.BuildRunner`): a `RUN` runs as a container whose
lowers are the image's layers so far, each idmapped on a root runner, and whose upper is the
build's new layer in the store (`Backend.execBuild`: the job gets no layer). What it writes has
the job's host ids; they are shifted back to the image's own afterwards (`unshift`), so a stored
layer is the same whichever job's range built it and can be idmapped into any job, as the
`COPY` layers the runner writes are. The built image runs as a `docker://` one does, with its
layers as the container's lowers. Layers live under `RUNNER_NATIVE_STORE/layers`.

**The action loader** (`runner/src/native/actions.zig`). The backend stays chosen per job, never
per step (a switch would need the native layers exported into Dagger). What a `uses:` action is
is in its `action.yml`, so before "Set up job", with nothing logged, `preload` fetches every
remote action of the job, composite actions' nested ones too, by git in the job's image into
the job's layers at the path Dagger mounts them (`/github/_actions/<owner>/<repo>/<ref>`): only
the commit, the job's token for its own repository and none for others, as Dagger's `git` does.
If one is something native cannot run yet (below), the job goes to Dagger with the reason, and
Dagger fetches again; otherwise "Set up job" takes them from the Backend (`Exec.loadAction`) and
logs "Download action repository ... (SHA:...)" as on Dagger. An action that cannot be fetched
is not a reason: native "Set up job" fails with it, as Dagger's does. Native runs Docker actions
(a `docker://` image, or built from the Dockerfile in the fetched tree, the context opened
through no symlink) and composite actions (their steps are the shared code's: scripts, nested
`uses:`, nested checkouts through `Backend.fetchCheckout`, `docker://` steps). In a container,
the job's binds go only where the image has the path.

**JavaScript actions.** The Dagger path's own code runs them (`js.zig`: `runJs`, `runJsScript`,
`jsEnv`, pre, main, post and `post-if`, `STATE_*`, the node, npx and npm shims, Node when Bun
refuses an action). What changed is where the runtime comes from: `js.runtimeFiles` answers the
runtime's files from the native image store (`oven/bun:1.4.3`'s or `node:24-bookworm-slim`'s
rootfs, as `js.runtimes` names them) as `host:<path>` ids, and the native backend now applies
Dagger's mounts (`Backend.applyMounts`): a new file (a shim) written into the step's layer, a
host file or directory bound read-only into that step and every later one, as Dagger's copy
stays in the container. A job whose JavaScript action's runtime is not in the store goes to
Dagger (`actions.preload`).

**Local actions.** `preload` judges a local action (top level or nested) from the job's own
repository at the job's commit, which is what a checkout of it gives: a blobless fetch of that
one commit by git in the job's image (the job's token, as the checkout's), and only its
`action.yml` read (`git cat-file`), then removed. One that is not there (made by a step, another
repository checked out there) sends the job to Dagger. At run time the step reads the workspace,
as on Dagger (`actions.loadLocal`, through `Backend.readFile`).

**For P3 and P2, what to swap when they land:**

- P3's pull also serves the JavaScript runtimes: `js.runtimeFiles` calls `images.lookup` for
  `js.runtimes`' images; with the pull it gets them on a miss, and `preload`'s runtime check goes.
- P3's image store replaces `images.lookup(arena, io, dir, ref)`: return `Image{ rootfs, entrypoint,
  cmd, env, user }` for the reference, pulled when missing. `docker_action.unsupported` then needs
  no store check (an image is pulled, not refused) but keeps the `USER` check until the idmapped
  shares; `Config.images` and `RUNNER_NATIVE_IMAGES` go.
- P2's per-job helper: `sandbox.Spec.Container` is a field of the step's spec; the per-job helper
  takes it with the step and mounts the container's overlay in the step's own namespace (the
  job's overlay and its layer as for any step). Its layer store: the action's step always runs
  (it has the job token) and is never keyed or replayed, as on Dagger; its layer is the job's
  next one as any step's. The Dockerfile builder stores each instruction's layer under its key
  there: `layers.Store.get`, `begin` and `publish` become the store's lookup, a directory to
  build in under the key's flock, and the atomic publish.

**Measured** (laptop "cowbird", balanced profile, 2026-11-01, load about 3, rootless under
`unshare`, the runner built `ReleaseSafe`, `--exec-job`, plain `ubuntu:24.04` as the rootfs and
`alpine:3.22` in the image store, per step = (20-step job − 1-step job) / 19, median of 7):

| | native | Dagger |
|---|---|---|
| `docker://alpine:3.22` with `entrypoint: true` | **11.3 ms** a step (1-step job 32 ms) | not measured here, see below |
| `run: true`, same machine and load, for scale | 21.3 ms a step (1-step job 41 ms) | ~224 ms (P1) |

A Docker action costs less than a `run:` step natively: no bash and no step script, and the
image is a single small layer. On Dagger the same step is three queries (the workspace's
directory, the exec with the busybox script, the copy back) besides the image's `from`, so it is
at least the cold `run:` step's ~224 ms. Dagger could not be timed for this pull request: the
laptop's engine for this runner's Dagger version was stopped, and starting one was not done
without the user (the PR says how to take the figure).

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

### P1, after review: what the first cut got wrong, and the hardening

An independent review of the first cut found two merge blockers and a dozen smaller faults; the
user then pulled the job's ids, its network and the sandbox hardening into P1. What it taught:

- **The kernel clears the parent-death signal on a change of credentials.** The first cut set
  `PR_SET_PDEATHSIG` in the step's PID 1 and then called `setuid`: on a root runner with the runner
  user, a timeout killed the helper and left the step running on the host, holding the log pipe,
  so the job hung. The fix is not to depend on it: the helper itself kills PID 1 when its lifeline
  (stdin) closes, which also covers the runner dying (M6), and PID 1 re-arms the signal after
  `setuid` and checks, through a pipe, that the helper is still there. Lesson: a death signal is a
  backstop, never the mechanism.
- **Root on the host is the wrong default for a step.** Running steps as host root (in a chroot)
  or as host uid 1001 made every escape a host privilege. A dedicated range per job, as Docker's
  userns-remap does, makes the step's root nobody outside; the cost was learning that only a
  process outside a user namespace may write a map wider than its own id (a child unshares, the
  parent maps it, the namespace is kept by its file descriptor).
- **Idmapped mounts beat a copy per range.** Each slot's range needs the rootfs owned by that
  range. A shifted copy would be 600 MB per slot; an idmapped mount of the rootfs (Linux 5.19 lets
  overlay take one as a layer) costs nothing, with the overlay mounted as the host's root and the
  helper entering the job's namespace afterwards. Mounting the overlay inside the namespace instead
  would have needed the files owned by the range.
- **Locked mounts.** In a user namespace, a read-only remount must keep the flags a more
  privileged namespace set (nosuid, nodev, noexec, the atime ones), or it is refused; and a bind
  of a mount without its submounts is refused, since it would uncover what they hide. /sys is
  therefore cloned whole (`open_tree`) and made read-only in one recursive `mount_setattr`.
  Neither shows up until the remount's result is checked, which the first cut did not do.
- **Every host path a step can influence must be resolved inside the step's root.** The runner,
  as root, read file commands and matcher files from the layers by plain path, and the helper wrote
  the event file and secret scripts the same way: a symlink a step planted could point them at the
  host's files. `openat2(RESOLVE_IN_ROOT | RESOLVE_NO_MAGICLINKS)`, with mounts aimed at
  `/proc/self/fd/N` of the opened target, closes that for the helper; the runner also refuses
  symlinks outright and respects whiteouts (a character device in an upper hides the layers
  below).
- **What a namespace's owner decides.** The job's network namespace is made by the host's root, so
  the job's root has no `CAP_NET_BIND_SERVICE` there: ports below 1024 and ping need the
  namespace's own sysctls (`ip_unprivileged_port_start`, `ping_group_range`). Owning the namespace
  from the job's user namespace would avoid that, at the price of a namespace made per job inside
  it.
- **The resolver Dagger got for free.** BuildKit's CNI network hands each exec a working
  resolv.conf. A job's own namespace cannot reach systemd-resolved on the host's 127.0.0.53; the
  runner binds the upstream list systemd-resolved keeps (`/run/systemd/resolve/resolv.conf`).
- **NAT on a Docker host.** Docker sets the FORWARD policy to drop; a rule in another table cannot
  overturn it, only `DOCKER-USER` can. P1 makes its NAT and forwarding rules with `iptables` (debt:
  links, addresses and routes are rtnetlink already; nftables over netlink is phase 5's), not
  `nft`: the hosted runner has no `nft`, and `iptables` writes into the same tables as Docker's
  own rules, whichever backend the host uses.
- **Smaller ones.** `hashFiles()` reads the container through Dagger, so it routes a job to Dagger
  until it is native. `--exec-job` bypassed the trusted refs; it no longer does. Overlay's
  work directory and a step's `chmod 000` both defeat a plain recursive delete, so removal gives
  directories their permissions back and logs what still fails, and a sweep at each job's start
  removes the directories of runners that died (each job holds a lock on its own). A step killed
  before the helper removed a secret script's file left it in the layer for later steps; the runner
  removes it too. BuildKit makes a missing working directory, so the sandbox does; the helper's
  environment is empty, not the runner's; files get umask 022.
- **Tests that cannot run are not coverage.** The first CI run skipped every native test (the
  test runner was never told where the runner binary was), and nothing failed. CI now sets
  `ZIG_RUNNER_REQUIRE_NATIVE=1`, which turns a native test's skip into a failure. GitHub's hosted
  runner, unlike the laptop, refuses even util-linux's `unshare` a user namespace's id maps, so CI
  lifts AppArmor's restriction on its throwaway VM.

Measured: hardened, a cold trivial step costs 32.7 ms on the laptop (rootless, busier than for the
first cut's 18.1 ms), still about 7 times faster than Dagger's ~224 ms. The difference is per-step
setup that P2's per-job helper does once.
- **no_new_privs and sudo, decided.** With no_new_privs on, sudo as the runner user did nothing,
  and jobs that call it (most that install packages) had to go to Dagger. Once each job has its
  own range of ids, sudo can only become the job's own root, which is nobody on the host and is
  still held to Docker's capabilities and the seccomp filter: the user dropped no_new_privs for
  the runner user on a root runner, and kept it for root steps and rootless ones. The catch was
  ordering: without no_new_privs, installing a seccomp filter takes CAP_SYS_ADMIN, so the filter
  now goes in while PID 1 is still the namespace's root, before `setuid`. The root test checks
  that sudo gives uid 0 inside and nothing outside: a host-only file stays unreadable, the
  capabilities stay Docker's, and the uid map stays the job's.
- **The root pass's first runs, one kernel rule each.** Four bugs no rootless run could show:
  a link looked up by name through a socket opened after `unshare(NEWNET)` was looked up in the
  job's namespace, not the host's (a socket stays in the namespace it was made in, so each
  netlink socket now keeps its own lookup socket); joining a user namespace with `setns` changes
  no ids, so the helper was still the host's root, unmapped there, and what it made belonged to no
  one (EOVERFLOW: it now becomes the namespace's root, as runc does); the overlay, mounted in the
  host's root's mount namespace, is locked in the job's, and `pivot_root` refuses a locked new
  root (EINVAL: it is bound onto itself first, as runc does); and the hosted runner has no `nft`.
  Also a file descriptor closed twice on `init`'s error path, which Zig's I/O caught.

### P1, after the re-review: what is the host's, what the firewall already says, what fails quietly

An independent re-review of the hardened P1 found one major fault and several gaps. What it
taught:

- **A resource named on the host must be locked on the host.** The slots were locked under the
  runner's store, but what a slot names is the host's: the veth `zrh<n>`, the address, the range
  of ids. Two runners with different `RUNNER_NATIVE_STORE`s both took slot 0, and the second's
  set-up deleted the first's veth as a dead job's, cutting a running job's network; both jobs
  also got one address and one range of ids. The locks now live at a fixed host path
  (`/run/zig-runner/slots`), and only the slot's holder removes its veth. The rule for every
  later phase: before keying anything by the store (the layer store, cache volumes, cgroups),
  ask whether the kernel object it names is per store or per host. It also reaches the deploy:
  systemd's `RuntimeDirectory=` removes the directory when any unit sharing it stops unless
  `RuntimeDirectoryPreserve=yes`, which would quietly free a live job's slot, and a container
  needs the host's `/run/zig-runner` bound in, not its own.
- **iptables rules land among others'.** An `ACCEPT` for "anything from `zr0`" at the head of
  `FORWARD` and `DOCKER-USER` got the jobs out, and also opened Docker's unpublished container ports
  and every other network the host routes to, and overrode ufw's forward policy: the first matching
  rule wins whoever wrote it. The rules now say exactly the traffic they are for (from `zr0` out
  through an uplink, replies back) and leave the rest to the host's policy. `INPUT` was never
  considered: a job had its own loopback, but the host's services on the bridge's address (and every
  other address of the host's) were one hop away. Isolation between jobs needed two layers, since
  one does not imply the other: the bridge forwards between ports unless they are isolated, and the
  host routes between jobs through the gateway unless `FORWARD` drops it. IPv6 link-local addresses
  come up on every interface by themselves and pass every IPv4 rule; IPv6 is now off on the bridge
  and on the jobs' `eth0`. Host-wide sysctls (`ip_forward`) cannot be restored by one runner of
  several, so they are checked, logged and documented instead.
- **A mount that fails quietly is a hole with a passing test.** `/proc/sys` was made read-only by
  binding the helper's `/proc/sys` (the host's, with `binfmt_misc` mounted under it on GitHub's
  runner and many hosts) without its submounts, which a user namespace refuses; the call's result
  was ignored, so steps ran with `/proc/sys` writable and nothing said so. The masks had the same
  shape. Now each read-only path is cloned from the step's own /proc with its submounts and made
  read-only in one `mount_setattr`, as /sys already was, and a mask or read-only path the kernel
  has but cannot apply fails the set-up. The tests check the result from inside the step (a write
  refused, `ro` in mountinfo), not the call. Same lesson as the remounts in the first review:
  check every mount's result, and test what the step sees.
- **Smaller ones.** A script holding a secret was written into the step's layer, on the store's
  disk, and unlinked afterwards, which leaves it in free blocks: it is now on a tmpfs of the
  step's own, bound at its path. io_uring bypasses seccomp for the calls it runs and Docker has
  refused it since moby 25; `personality` can turn off ASLR (`ADDR_NO_RANDOMIZE`) and Docker
  allows only four values. The default id range sat inside systemd-nspawn's private-users range,
  and the checks read /etc/subuid only, not /etc/subgid or the host's own users and groups. The
  default subnet was podman's. A failed capability probe turned native off until the runner
  restarted; it is now tried again after five minutes. And one the root pass found at once: /proc
  reports its files' sizes as 0, so a read sized by `stat` (Zig's `readFileAlloc`) returns
  nothing, and `/proc/net/route` looked like a host with no default route; /proc files are now
  read to their end (`net.readProc`).

### P7: Docker actions (`docker://` steps)

- **The script was the busybox's, not the action's.** Dagger's path starts a Docker action's
  command under a static busybox it copies into the image, because the step script (markers, file
  commands, the event, `env -u`) needs a shell and the image may have none. Natively the runner is
  already outside the container with the output pipe in hand, so it writes the markers into the
  log itself and makes and reads the file-command files from the job's layer; the action's own
  command is PID 1's exec. It is also what GitHub's runner does: it binds host files in and reads
  them afterwards, and runs no shell in the image.
- **A bind is the copy back, for free.** Dagger copies the workspace into the action's container
  and the result back over the job's (`withoutDirectory` + `withDirectory`). Mounting the job's
  overlay with a new layer and binding its workspace into the container makes the action's writes,
  deletions included, the job's next layer directly, as GitHub's `docker run -v` does.
- **Two overlays in one helper.** On a root runner the job's overlay and the image's are both
  mounted by the host's root before the helper enters the job's user namespace (the image's
  filesystem idmapped like the rootfs), and the shares are bound in the step's own mount
  namespace, recursively: a non-recursive bind of part of a mount made in a more privileged
  namespace is refused.
- **Ownership was Dagger's implicit gift.** `withDirectory(owner:)` gave the runner user every
  file a root action wrote in the workspace; GitHub leaves them root's (a known annoyance). The
  native path keeps Dagger's behaviour by walking only the step's layer under the workspace,
  which holds exactly what the action changed, rather than the whole workspace.
- **Deciding per job limits what can move.** `docker://` steps name their image in the job, so
  the decision can be made before the job starts; a `uses:` action's kind is in its `action.yml`.
  Moving `uses:` actions (Docker and JavaScript alike) needs their metadata fetched before the
  choice, which is why the loader is the next piece, not the builder.
- **`GITHUB_ACTION`, exit codes and logs follow Dagger's path, not GitHub's.** Dagger's path sets
  `GITHUB_ACTION` to the step's label (`docker://alpine:3.22`) and logs no "Process completed with
  exit code" for a Docker action; the native path does the same, so a job's results do not depend
  on the backend.

Measured: 11.3 ms a `docker://` step natively on the laptop (rootless), against a cold `run:` step
at 21.3 ms on the same machine and Dagger's ~224 ms for the latter.

### P7: the action loader and the builder's runner

- **Per job, still.** The request was to choose the backend per step where needed. A step that
  switched would start from layers the other backend does not have, so the choice stays per job,
  and what needed per step was only the knowledge: fetching the actions before the choice gives
  it. The fetch is not wasted when native runs: the trees are in the job's layers already, where
  composite steps and Dockerfile contexts read them.
- **Stored layers must not carry a job's ids.** On a root runner what a sandbox writes has the
  job's host range; a layer stored that way would be another job's nobody. Overlay cannot idmap
  its upper, so a build's `RUN` layer is shifted back to the image's ids when it ends and every
  stored layer is idmapped when mounted, as the rootfs is.
- **The job's binds are for the job's image.** Binding them into a Docker action's image, where
  the target may not exist, failed the build's first `RUN` (a test bind at `/srv/git`); GitHub
  gives an action's container none of the host's paths but the four it documents.
- **Testing a fetch without a network.** The job's `server_url` can be a `file://` URL inside
  the sandbox, with the test's bare repositories bound there, so the loader's tests run the real
  git fetch in both native passes and never reach Dagger.

### P7: JavaScript and local actions

- **Mounts were the whole difference.** Dagger's JavaScript path is a script plus mounts: the
  runtime's binary, its shims and npm, and the action's directory. Once the native backend
  applied mounts (binds for host files, files written for new ones, nothing for trees already in
  the layers) the shared code ran pre, main and post unchanged. The one fault was the native
  backend's own: it removed every file it wrote after a step, which was right for a script holding
  a secret and wrong for a shim that must outlive it.
- **Judging a local action needs one blob, not the repository.** A blobless fetch of the job's
  commit and `git cat-file` of one path costs a commit and its trees, and leaves nothing in the
  job but an empty layer; the checkout still does its own fetch.
