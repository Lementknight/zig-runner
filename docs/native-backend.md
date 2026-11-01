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
  rootless runner unless `RUNNER_NATIVE_ROOTLESS=1`, `container:`, `services:`, `uses:` actions,
  `docker://` steps, a custom image, Dagger in steps (`RUNNER_DAGGER_NESTING`), `hashFiles()`
  anywhere in the job (it reads the container through Dagger), a checkout with submodules, and a
  machine whose probe fails (no user namespaces, `iptables` missing, no default route, the jobs'
  ids taken on the host, the jobs' subnet overlapping a route of the host's). A failed probe is
  tried again after five minutes, not kept for the process's life.
- Off on native, as caches: output keys, the package caches, uv's environment in its cache, and
  Zig's local cache and seed (P4). Results do not depend on them. (The step cache was off in P1;
  P2's layer store gives it.)
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
RUNNER_NATIVE_STORE_MAX_MB=10240                  # default; the layer store's cap (P2)
RUNNER_NATIVE_ROOTLESS=0                          # default; 1 for a rootless runner
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
touch /var/lib/zig-runner/rootfs/.zig-runner-provisioned
```

To provision it again, make a new directory and rename it over the old one between jobs, or, if
it is changed in place, touch `.zig-runner-provisioned` in it afterwards. The step store's layers
were made over the old rootfs: every job checks the rootfs's root and that stamp before it trusts
the fingerprint it found once (`Store.rootfsFingerprint`), and a change neither shows (an
in-place change, the stamp not touched) is found when the runner restarts, by the walk's ctimes.

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

- ~~First, from P1: one sandbox helper per job instead of per step.~~ **Deferred, by the user's
  decision, to a follow-up of its own**: the store is built on P1's per-step sandbox, whose
  in-namespace code P2 does not change. The per-job helper (namespaces, /dev, /proc and its masks
  made once, steps over a pipe, about 15 ms a step on the laptop) is a speed-up of cold steps
  only; replays never start a sandbox.
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

**Status: the store, replay and GC landed (behind the knob); the per-job helper is deferred.**
What it covers, as built:

- `runner/src/native/Store.zig` is the store, under `RUNNER_NATIVE_STORE` (mode 0700):
  `layers/<key>/{fs,log,fc,meta,lock,digest}`, `keys/<key>.lock`, and the running jobs' `jobs/`.
  `meta` holds the store's format, the entry's kind (base, step, fetch), its bytes on disk, and
  its log's and file commands' lengths and sha256s.
  `Backend.zig` keys each exec (`keyFor`), claims the key (`claimKey`), replays a hit (`replay`)
  and publishes a success (`publishTop`).
- **Keys** are P8's preimage format (proofs/Runner/Native.lean, `stepPreimage`): a u64 tag (0 a
  base, 1 a step's container, 2 output-keyed), the parent's key, the script, the count of stable
  bindings and each name and value in the container's order, every field length-prefixed as a
  u64 little-endian (`Store.KeyHasher.core`). Stable means not in `volatile_env`, not the event,
  the ran marker or the markers' secret (volatile under Dagger too), and no secret alias
  (`Store.stableEnv`). After the core come what P8's model does not have yet: the step's uid,
  gid and working directory, and the files written for it that stay (the event file when it is
  not a variable). A base has no parent; in its place goes a digest of what every layer depends
  on (`Backend.below`): the store's format (`Store.store_format`), the job's cache scope and
  repository, the rootfs's fingerprint (a walk of its metadata, ctimes and inodes among it, kept
  per process and checked again for every job against the root's and the provisioning stamp's
  identity and ctime), how ids are mapped, on a root runner the slot's first id (a layer's files are owned by its job's
  range, so it is reused only by jobs with the same range: only misses come of it), and the binds'
  places (never their content). Under step caching the event payload is a variable each step
  writes to the file, as `set_up.writeRunEnv` gives it, so the base is the same for every run.
- **The store's format** (`Store.store_format`) is bumped with any change to what a layer or its
  record means: the sandbox's trees, the record's files and how they replay, the key's extras.
  A runner upgraded across a bump finds none of the older runner's layers; they age out under
  the cap.
- **Forks**: a fork's pull request that `trust.vouches` accepts still runs natively, with caching,
  in a key space of its own: the scope is `set_up.packageCacheScope`'s (`untrusted` when the
  pull request's head repository is another), the same test that keeps its package cache volumes
  apart on Dagger. It never replays or leaves a layer its repository's own jobs use. It does
  share the store's disk and its cap.
- **Publish**: only a step that exited 0 with its file commands taken, that does not always run
  (no secret, no OIDC token, no run-specific value) and whose parent is in the store. So a failure
  is never replayed (#69), nothing after an always-run step is kept (its parent is not stored, as
  under Dagger its new parent makes every later key new), and no layer or log holds a secret. A
  step that printed more than `dagger.max_recorded_bytes` is not kept, nor a record its kind may
  not have (a step's file commands without their ran marker, a base's or a fetch's not empty),
  nor a layer whose size cannot be counted whole (a directory it cannot read). A commit's checkout
  (a fetch of a full SHA) is a layer like a step's, keyed on its script and never on the token;
  a branch or tag moves, so its fetch always runs. The upper is moved under `layers/.tmp-<key>-<n>`
  with its record, held, written to disk (`syncfs`), and published by one
  `renameat2(RENAME_NOREPLACE)`. An upper that cannot be put back after a failure is left there
  and logged, never deleted.
- **Replay**: the stored raw output (markers and all) and combined file commands go through
  `Exec.collect` as Dagger's answer for a cached exec does, with the earlier job's ran marker, so
  the log is `JobLog.replayNotLive`'s, byte-identical by construction, and outputs, env, PATH,
  summaries and state are applied again. The step's log ends with "Reused from the native step
  store", which the runner counts as it counts Dagger's note. Every hit is checked whole first
  (`meta`'s lengths and sha256s, and the record its kind may have): one that is not is evicted
  under its exclusive lock and is a miss, so the step runs and is published again; its last use
  is touched only once it passed.
- **Locks**: one flock per key while its exec runs (polled, so a cancel or a timeout ends the
  wait), so two jobs sharing the store do not run one key at once: the second replays the
  first's. On a root runner two jobs at once take two slots, so their keys differ anyway. A job
  holds a shared flock on each store layer it uses until it ends.
- **GC** (`Store.collect`, after each job): past `RUNNER_NATIVE_STORE_MAX_MB` (default 10240),
  the layers no job holds go, least recently used first (the lock file's mtime is the last use),
  each renamed away under its lock taken exclusively, then deleted. Half-built and half-evicted
  entries of dead runners, idle key locks, and entries that are not whole (by `meta` and their
  files' lengths, without reading them) go too.
- **Flattening**: before a step on a stack of 100 layers (`default_flatten_at`), the stack is
  merged into one (`Store.flatten`): later entries win, whiteouts are kept (they hide the
  rootfs), opaque directories stay opaque, files are hard links and directories are made with
  their owner, mode, xattrs and times. The merged layer stands for the top: its key is the top's.
  Overlay's redirects and metacopy, off by default and never turned on here, are refused.
- **Digests** (`Store.treeDigest`, `layerDigest`, kept beside the layer once computed): sha256 over
  a walk in byte order of each entry's path, type, mode, owner as the job's namespace sees it
  (other host ids as the overflow id), the xattrs that say what it is (overlay's bookkeeping left
  out), and its content (a file's bytes, a link's target, a device's numbers, so whiteouts too).
  No times, inodes, link counts or host ids. Nothing asks for them yet: output keys stay off on
  native.

#### Measured (laptop "cowbird", balanced profile, 2026-11-01, load about 5.5)

`ZIG_RUNNER_NATIVE_BENCH=1 zig build test -Doptimize=ReleaseSafe` (the test "native step cache:
measured"), rootless, on the tests' rootfs (a few directories with the host's `/usr` bound in).
Per step is (50-step job − 1-step job) / 49.

| | native | Dagger |
|---|---|---|
| replayed trivial step | **0.37 ms** | ~95 ms |
| replayed 50-step job, whole (base, 50 replays, log) | 20 ms | |
| cold trivial step, with its layer published | 68 ms | ~224 ms |

The cold figure is P1's per-step sandbox (32.7 ms on a quieter laptop) plus publishing, under
twice P1's load; the per-job helper is what would cut it.

Store size over 50 jobs of one workflow, as 50 commits: ten steps, five that never change (one
writes 1 MiB), one that changes every job and four after it. 306 layers (with the benchmark's
own) in 15.1 MiB: the 1 MiB file once, and about 48 KiB per small layer, which is the
directories and the step's file-command files at a 4 KiB block each.

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

### P8: remapping the Lean proofs

- The theorems keep their shape; the code they cite changes. The "a container *is* its recipe"
  row points at the native key chain instead of Dagger's lazy container id, and the runner now owns
  the obligation BuildKit discharged: the key is computed from exactly what the model says.
- `Output.digest` becomes the native layer digest; `OutputKeys.lean` needs it deterministic.
- `Logs.lean`'s hypothesis that the engine records stdout and stderr apart no longer applies if
  the native store records the interleaved stream; `exec 2>&1` may become optional.
- `Input.mounts` absent from the key holds by construction.
- Exit: `proofs/README.md` and the Lean files name native functions where they named Dagger's.

**Status: proved of P2's key format as P2 builds it (#268, with its review fixes in #272 at `28a9dd1`); the
Zig check runs P2's own code: `Store.KeyHasher` and `Store.stableEnv` for keys, `Backend.belowKey`
for the digest below a base, and `Store.treeDigestTo` on fixture trees for layer digests.**
`proofs/Runner/Native.lean` is the native backend's refinement of the model, beside Dagger's rather
than replacing it, since both backends ship (proofs/README.md, "On the native backend"):

- **The key.** A key is sha256 of `keyPreimage`, as P2's `Store.KeyHasher` and `Backend.keyFor`
  build it: a u64 tag (1 for a step's exec or a checkout's fetch, 0 for a base, 2 for an
  output-keyed container), the parent's key, the script's text, the count and bindings of the stable
  environment in the container's order (`Store.stableEnv`: the volatile names, `ZIG_RUNNER_EVENT`,
  `ZIG_RUNNER_RAN`, `ZIG_RUNNER_MARK` and `ZIG_SECRET_*` dropped), then the uid, gid, working
  directory and kept files, each field prefixed with its length as a u64 little-endian. A base has
  no parent: in its place is the untagged digest below it (`Backend.below`: the store's format
  `Store.store_format`, the trust scope, the repository, the rootfs's fingerprint, the userns mode,
  the slot's first id, the binds). `fork_keys_apart`: a fork's pull request (scope `untrusted`) and
  the repository's own jobs (`repo`) never ask the same key, so neither replays what the other
  stored.
  The extras are not new inputs: a step's are its job's, fixed with the base (`Format.stepExtra`), and a base's are part of what the
  model's base is (`BaseSpec`). `encState_injective`, `belowPreimage_inj`, `encKey_injective` and
  `native_key_iff`: the format keeps exactly what the model's key keeps, so P2 and P3 hold of it;
  mounts and the event payload are no argument of it. `Ambiguous` is what plain concatenation would
  cost.
- **Replay.** The store records a success of an unmarked step and nothing else. Then every hit is
  honest, succeeded and unmarked by construction, and `native_replay_eq_run` is P1 under
  `Disciplined` alone: no `Numbered`, no `Ahead`, whatever other runners publish or evict between
  steps, and whichever reads fail. `native_eq_dagger`: the two backends give the same answers.
- **Concurrency.** Whole-entry operations in any order keep the store honest (`ops_keep_honest`);
  which of two racing writers wins does not matter (`race_irrelevant`), so the flock per key is
  about cost; an entry is read whole or is a miss (`readWhole_agrees`, `Torn`).
- **Layer digests.** A sorted walk of what a later step can see, nothing that differs between runs:
  `digest_deterministic` and `digest_injective`, which are what output keys need. `walk_injective`
  proves it of P2's walk as written (`Store.treeDigest`: paths, modes, owners, xattrs, a file's
  sha256, a link's target, a device's numbers, `..` after a directory), given one change P8 made
  to it: the xattrs are now counted, since without the count the last xattr and the content after
  it could not be told apart.
- **Logs.** A store that records the one pipe the step writes to replays the run without
  `exec 2>&1` (`Logs.native_replay`). The scripts keep it: one script for both backends.
- **The tie to the code.** `keyoracle` (`proofs/KeyOracle.lean`) writes
  `runner/src/native/testdata/step_keys.tsv`, `.github/scripts/key-vectors.sh` checks in the proofs
  workflow that it is the model's, and `runner/src/native/key_vectors.zig` checks the preimages
  (29 key vectors: steps, bases, the digest below a base; 4 layer vectors: modes, an xattr and a
  symlink, an opaque directory, a whiteout) and the equal/differ relation against it.

**What is left**: if P2's format changes, change `Native.encState` (and `keyPreimage`,
`belowPreimage`, `walkPreimage`) and `KeyOracle.lean` to match, keep `Format.Sound` proved, and
regenerate the vectors (`key-vectors.sh --write`). A format that sorts the environment, or drops a
length, a count or a tag, fails the vectors on purpose.

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

### P2: the layer store, replay and GC

What BuildKit's cache did implicitly, now explicit in `native/Store.zig`:

- **The key is the runner's to get right.** BuildKit keyed an exec on its recipe; natively the
  runner computes it, so the model's `Key` is now code (`KeyHasher.core`, in P8's format) and what
  the model does not have (uid, working directory, kept files, the rootfs, the id range, the
  binds' places) is listed beside it for P8 to add. The ran marker, the markers' secret and the
  event were volatile variables under Dagger; natively they are plain variables, so the key must
  leave them out by name, or every job would miss.
- **A layer belongs to an id range.** On a root runner a layer's files are owned by its job's
  host ids. Unlike the rootfs, which an idmapped mount shifts per slot, a stored layer is not
  shifted: it is keyed by the slot's first id, which costs misses across slots (a pool's
  concurrent jobs do not share layers) and keeps a job's files from appearing under another
  range. An idmapped mount per stored layer would lift that; it is the helper's work.
- **Masks are secrets for the cache.** A step that names a value an earlier step masked always
  runs (`holdsSecret` counts masks), on native as on Dagger; the first replay test tripped on it.
- **Publish must never replace, and a reader must never trust a half.** `RENAME_NOREPLACE` keeps a
  concurrent or broken entry; an entry missing a part, or whose file commands lack their ran
  marker, is a miss. Holding the new layer's shared lock before it is visible keeps an eviction
  from taking it between the rename and the job's use.
- **The store's mode is a security boundary.** Its layers hold job-written files owned by the
  jobs' ids, setuid ones among them: at 0755 a host user could run one as the job's root's host id.
  The store is 0700 (P1's job directories, under it, were exposed the same way).
- **What the review found (after merge, fixed in a follow-up).** A fingerprint kept per process
  by path missed a rootfs provisioned again in place: `tar -x` restores mtimes, so size and mtime
  match; ctimes do not, and every job now checks the root and a stamp. Layers outlived runner
  upgrades that change their meaning: the store's format is now in every key. A record that
  could not be replayed was still published and then shadowed its key forever, every lookup
  keeping it fresh: records are now checked at publish and on every hit, with sha256s in a
  `meta`, and a broken entry is evicted. Nothing was synced before the rename that publishes,
  so a crash could leave a whole-looking empty entry: `syncfs` first. A vouched fork's pull
  request shared the trusted jobs' key space: its cache scope is now in the key. And walks that
  stopped at depth 256 or skipped unreadable directories undercounted a layer: they now have no
  depth limit and fail closed. Lesson: an entry in a cache shared between jobs is input the next
  job trusts, so every way it can be partial, stale or someone else's has to be in its key or
  checked on read.
- **Dagger's replay limit is not ours.** Dagger replays a step past 4 MiB of output with a warning
  instead of its log; natively such a step is not published and runs again.

Surprises:

- The boundary held: replay is one `Exec.collect` call with an answer built as values (a log need
  not be UTF-8, so no JSON round trip), and the shared code cannot tell it from Dagger's.
- `lgetxattr` on `/proc/self/fd/N` reads the magic link's xattrs, not the directory's; through
  `/proc/self/fd/N/.` it reads the directory's.
- Flattening needs no copies and no `mknod`: whiteouts are hard-linked from the layer that has
  them, which also works rootless.

Measured against Dagger: a replayed step 0.37 ms against ~95 ms, about 250 times faster.

### P8: remapping the proofs

Written against P2's specification while P2 was being built, so what it taught is about the
specification:

- **What BuildKit discharged is three obligations, not one.** "The key is computed from exactly
  what the model says" splits into: the preimage is unambiguous (every field length-prefixed, a
  count before the environment, a tag per kind of container), the environment keeps the order the
  step sees, and the script text tells apart the scripts the model does. The last was always
  assumed under Dagger too, and unstated; the first is new, and plain concatenation fails it with a
  four-byte example (`Ambiguous`: script `x` with `Y=1`, and script `xY=1` with nothing).
- **Not storing what cannot be replayed removes the model's bookkeeping.** `Build` needs `Numbered`
  and `Ahead` because the engine records marked steps and failures, and the proof has to show
  nothing ever finds them. A store that publishes only successes of unmarked steps never holds
  them, so native P1 needs `Disciplined` and nothing else. It also keeps a marked step's log, which
  may hold a secret, off the store's disk, which P0 asked for.
- **The flock is for cost, not correctness.** Two honest entries for one unmarked key are equal
  under `Disciplined`, so which racing writer wins does not matter. What correctness needs is that
  the store changes by whole entries (one rename) and that a reader treats a missing or short part
  as a miss: either one alone closes torn reads, and an eviction part-way is the same case as a
  write part-way.
- **Comparing the walk byte for byte found an ambiguity.** P2's layer walk wrote an entry's xattrs
  with no count before them, so where the last xattr ends and the content begins was not in the
  bytes: a symlink's target is a field just as an xattr's name is. The proof of `walk_injective`
  could not go through without it, and two different layers could have shared a digest, which output
  keys would have taken for early cutoff. The fix was one count. Nothing asked for a layer digest
  yet, so no stored digest changed meaning; the rootfs's fingerprint, the same walk, changed once,
  which costs one round of misses.
- **What P2 hashes beyond the model added no input to it.** P2's key carries the uid, gid, working
  directory and kept files, and the digest below a base (store format, rootfs, id mapping, slot,
  binds). Each is
  either part of what the model's base is or fixed with it for every step of the job, so the proof
  needed a richer `Format`, not a richer model: the base became a `BaseSpec` and a step's extras its
  base's (`stepExtra`). One consequence worth knowing: when the event payload is too large for a
  variable, P2 writes it as a kept file of the base, so the base and every key above it are per run.
  That costs only misses. The store's format, which P2 put below every base after review, is the
  format version P8 asked for: it makes every key new when what a layer means changes, and the
  rootfs's fingerprint is an opaque atom to the model however P2 computes it.
- **The stable environment is a predicate, and the model never needed it to be `volatile_env`.**
  P2 also drops the runner's own per-job variables and the secret aliases (`Store.stableEnv`); the
  model's `vol` is any predicate, so nothing changed but the vectors.
- **Some entries no one can ask for.** With output keys off for a marked step, every step after it
  starts from a container whose key names the job, so its entry, though honest, can only ever be
  found by that job. Publishing it is safe and useless; P2 may skip it.
- **A miss is always safe, and the proof says why in one line**: every invariant is "every entry
  that is there is honest", which removing entries or failing a read cannot break. LRU eviction and
  a read cut short need no argument of their own.
- **The layer digest must hash namespace ids, not host ids.** P1 gives each slot its own range of
  host ids, so the same layer written in two slots has different owners on the host. Hashing those
  would make the digest, which is part of a step's output, differ between runs: no early cutoff,
  and `Disciplined` false in letter. The same holds of times and inodes, and of the order readdir
  returns. Whiteouts must be in the walk, or a layer that deletes a file has the digest of one that
  does not.
- **`exec 2>&1` is now Dagger's need only.** The native helper already gives the step one pipe for
  both streams (`dup2(1, 2)` before `execve` in `sandbox.zig`), so a store that records that pipe
  replays the run without merging. The script keeps the line because both backends run the same
  script, and its text is in the key.
