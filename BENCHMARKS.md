# Benchmarks

Everything here was measured on the reference machine, **razorbill**:

- a Raspberry Pi 5 with 8 GB of memory and a 117 GB SD card, which also runs other home services
- the Dagger engine v0.21.10 in Docker, capped at 3 CPUs and 4 GB, with its cache capped at 20 GB
  ([`deploy/engine.json`](deploy/engine.json))

If a fast machine were the yardstick, a slow design could pass. Measuring on a Pi keeps the fixed
costs visible.

## Where a job's time goes

*2026-10-25, zig-runner v0.4.1.* The `test` job of this repository's CI (checkout, Install Zig,
`zig fmt --check`, `zig build test`), first run after a reboot. CPU time and disk I/O come from the
cgroups of the runner's systemd unit and of the engine's container, sampled every second; step times
come from GitHub's API.

| Phase | Wall | Runner CPU | Engine CPU | Engine writes |
| --- | --- | --- | --- | --- |
| Set up job | 40 s | 0.03 s | 23.0 s | 622 MB |
| Install Zig | 20 s | 0.01 s | 6.3 s | 421 MB |
| Format check | 1 s | 0.00 s | 0.4 s | 5 MB |
| Test | 185 s | 0.03 s | 175.8 s | 295 MB |
| **Whole job** | **249 s** | **0.11 s** | **205.8 s** | **1,344 MB** |

The runner process accounts for 0.05% of the job's CPU. With no jobs, both runner pools on the
machine together used 21 s of CPU in almost 12 hours, under 0.05% of one core, in 5-10 MB of memory
each (14 MB peak).

**So rewriting the runner, in Rust or anything else, cannot speed a job up:** it could save at most
the 0.11 s. Jobs are made faster by the engine doing less, by its caches surviving, and by the disk.

## Restarting the engine keeps its cache, if it is allowed to stop

*2026-10-25.* After razorbill rebooted, the engine logged `dagql persistence store marked unclean;
wiping and cold-starting`, and its cache went from 21.4 GB to 0. Docker kills a container 10 s
after asking it to stop, but the engine needs longer to stop.

| The same `test` job | Result |
| --- | --- |
| Before the reboot, new commit, cache warm | 56 s |
| After the reboot (engine killed at 10 s) | cache wiped; 249 s |
| Re-run straight after, same commit | 1 s: every step answered from the step cache |
| `docker stop -t 300` | clean stop in 21.6 s, no wipe on start; re-run 3 s from cache |
| Engine recreated with `--stop-timeout 80` | no wipe; re-run 3 s from cache |

The engine now gets 80 s (`stop_grace_period` in [`deploy/compose.yaml`](deploy/compose.yaml)). The
limit is 90 s, the point at which systemd kills Docker itself during a shutdown. This corrects E4.5
below: on v0.21.10 the step cache survives a restart, unless the stop was cut short.

## Installing Zig

*2026-10-25.* CI used to unpack Zig into each job's temporary directory. It now keeps the unpacked
tree in the tool cache and checks it against a pinned digest of all its files
([`.github/scripts/install-zig.sh`](.github/scripts/install-zig.sh)). Times are taken inside the
script, and the engine's disk I/O is sampled every second.

| | Time | Engine CPU | Read | Written |
| --- | --- | --- | --- | --- |
| Before: unpack every job | 9-16 s | 5.6 s | 37 MB | 214 MB (588 MB once flushed) |
| After: page cache cold | 9-10 s | 1.7 s | 309 MB | 0 |
| After: jobs back to back | 2-5 s | 0.6-1.0 s | 36-141 MB | 0 |

Hashing the tree's 19,505 files takes 0.3-0.9 s when they are in memory. When they are not, the
check is limited by reading 309 MB from the SD card, so the gain depends on how recently the last
job ran. The check stays: without it the script would trust a tree that another job may have
changed.

## Earlier measurements

These come from the study in
[zig-actions-runner](https://github.com/Lementknight/zig-actions-runner/tree/7641a69/docs), where
the runner was developed. The IDs and verdicts are those of its claim registry,
[CLAIMS.md](https://github.com/Lementknight/zig-actions-runner/blob/7641a69/docs/CLAIMS.md). There,
*verified* means the claim was repeated, with a control, and *under-powered* means it is a real
reading taken too few times to rule out noise.

| ID | Finding | Verdict |
| --- | --- | --- |
| E4.1 | An empty job takes 2-4 s and 0.1 s of engine CPU | verified |
| E7.3 | A job's floor is GitHub's protocol, not the engine: 2-4 s a job against 0.6 s a session | verified |
| E7.1 | Overhead per step: raw overlayfs 17 ms, Dagger 60-62 ms | under-powered |
| E7.5 | 100 steps grow the engine's heap by 279 MB, mostly garbage; the live set is a few hundred MB | verified |
| E7.7 | `GOGC=400` saves about 15% of engine CPU on a job of 40 steps (0.90 s of 5.93 s) | verified |
| E4.3 | Uncapped, the cache grew to 67 GB in 17,000 snapshots and its inode cache crowded out the page cache | under-powered |
| E4.4 | A fresh engine did the same work about 15× faster: chi job 5 s against 23-55 s | under-powered |
| E4.5 | Every engine restart empties the step cache | verified then; corrected above |
| E4.7 | A restart keeps every cache volume: toolchains, Go modules, uv's cache | verified |
| E6.1 | Each cache volume is its own filesystem, so no hardlink can cross into it | verified |
| E6.2 | A warm `uv sync` takes 27.0 s from a cache volume against 0.2 s on the workspace's filesystem | under-powered |
| E6.3 | With uv's environment in its cache volume, `uv sync` on a new ref drops from 28.6 s to 9.2 s | under-powered |
| E6.6 | hugo against a hosted runner with its cache on: 9 s against 151 s on a new branch | under-powered |
| W.5 | "sqlalchemy installs faster here than on a hosted runner": the hosted runner is faster, 2.2 s against 3.1 s | refuted |
| E6.4 | "A warm `uv sync` is faster than GitHub's": the hosted runner is faster, 0.011 s against 0.015 s | refuted |
| S.4 | CI here is I/O-bound end to end: CPU 85-97% idle-waiting, at most 3 runnable while 26 were blocked | verified |
| S.2 | A forced-copy install takes 2.7× longer with three at once: 24.6 s alone against 66.6 s | verified |
| S.3 | flask's tests take 1.45× longer with three at once: 4.36 s against 6.30 s | verified |
| S.5 | No I/O scheduler is measurably better on this card | no effect found |
| S.6 | The SD card intermittently drops to a quarter of its write throughput, with 135 ms stalls | under-powered |

Together they explain the numbers above. The runner is cheap. The engine's fixed cost per step is
small next to real work. What decides a job's time on this machine is whether the engine's caches
survive and how fast the SD card is.
