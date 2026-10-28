//! Admission control (#126): a runner takes a new job only while the machine has the memory for
//! it. Four `zig build test` jobs taken at once on razorbill (a Raspberry Pi 5 with 8 GB, and 2 GB
//! of swap on an SD card) pushed the Dagger engine to its 4 GB cap and into swap, and the Pi
//! thrashed for hours. This is a soft gate: it decides whether to ask for the next job, and never
//! touches a job that is running.
//!
//! Three signals, each read from a file whose absence (another OS, a kernel without PSI) means
//! "no signal" rather than "hold":
//! - `MemAvailable` (/proc/meminfo), less a reservation for every job that may not show in it yet:
//!   one for each runner of the pool that is polling (it can be handed a job at any moment), one
//!   for each job started in the last `ramp_ms`, and one for the runner asking. Without the
//!   reservations, four idle runners all pass the check and are all handed a job in the same
//!   second, which is what happened.
//! - memory pressure (PSI, /proc/pressure/memory, `some avg10`): the share of the last 10 s in
//!   which some task waited on memory, reclaiming or reading back from swap. It sees what
//!   `MemAvailable` cannot: the engine's own cgroup swapping at its cap while the host still has
//!   memory to spare.
//! - swap growth (`SwapTotal - SwapFree`, as a rate): a machine writing to swap fast, for kernels
//!   without PSI. Swap in use is not a signal: pages stay there long after the burst that put them
//!   there, so it would hold a runner for days after one incident.
//!
//! `/proc/meminfo` and `/proc/pressure` are not namespaced: in a container they describe the whole
//! machine, which is what the gate needs, since the engine runs in a container next to the runner.
//!
//! The machine is not the only limit: the engine's container has its own memory cap (`Engine`).
//! Where the gate can find the engine's cgroup, it holds on that too, by the same reservations.
const std = @import("std");
const builtin = @import("builtin");

/// The thresholds (`RUNNER_MIN_MEM_AVAILABLE_MB` and the rest, see deploy/runner.env.example). 0
/// turns a check off.
pub const Limits = struct {
    /// `MemAvailable` that must be left once every job that may start has its `per_job_mb`.
    min_available_mb: u32 = 1536,
    /// Memory to reserve for a job that does not show in `MemAvailable` yet.
    per_job_mb: u32 = 1024,
    /// PSI `some avg10`, in percent, at or above which no runner takes a job.
    max_pressure: u32 = 10,
    /// Swap growth, in MB a minute, at or above which no runner takes a job: the machine's, and
    /// the engine cgroup's.
    max_swap_growth_mb: u32 = 64,
    /// Room that must be left under the engine's memory cap once every job that may start has its
    /// `per_job_mb` (`Engine`).
    min_engine_headroom_mb: u32 = 256,
};

/// Where the signals are read; tests point these at fixtures.
pub const Paths = struct {
    meminfo: []const u8 = "/proc/meminfo",
    pressure: []const u8 = "/proc/pressure/memory",
    /// Where the cgroup v2 hierarchy is mounted: the paths in `/proc/<pid>/cgroup` are under it.
    cgroup_root: []const u8 = "/sys/fs/cgroup",
};

/// How long a job's memory takes to show in `MemAvailable`: `zig build test` reached the engine's
/// cap about 90 s after four started at once on razorbill.
pub const ramp_ms = 120 * std.time.ms_per_s;

/// Once held, a runner resumes only with this much more memory than it needed to be let through,
/// and with pressure and swap growth under half their limits, so that a machine sitting at a
/// threshold does not hold and resume runners on alternate checks.
pub const resume_margin_mb = 256;

/// The pool's shared view of memory: one per process, used by every runner's `Gate`.
pub const Admission = struct {
    mu: std.Io.Mutex = .init,
    io: std.Io,
    limits: Limits,
    paths: Paths = .{},
    /// How often a held runner looks again.
    recheck: std.Io.Duration = .fromSeconds(5),
    /// Runners let through to poll for a job: each may be handed one at any moment.
    polling: u32 = 0,
    /// When each runner's job started (awake clock, ms), one entry per runner (`Gate.slot`): a
    /// runner runs one job at a time. Cleared when the job ends, so a job that is over reserves
    /// nothing, however soon it ended.
    started: []i64,
    swap: SwapGrowth = .{},
    engine: Engine = .{},

    /// `started` must have one entry for each runner in the pool, and each runner's `Gate.slot`
    /// a different index into it.
    pub fn init(io: std.Io, limits: Limits, started: []i64) Admission {
        @memset(started, std.math.minInt(i64));
        return .{ .io = io, .limits = limits, .started = started };
    }

    /// Jobs started less than `ramp_ms` ago.
    fn ramping(a: *const Admission, now_ms: i64) u32 {
        var n: u32 = 0;
        for (a.started) |t| {
            if (t > now_ms - ramp_ms) n += 1;
        }
        return n;
    }

    /// What the gate has learned about the engine's cgroup since this was last asked (found, or
    /// not found and why), written into `buf`; null if nothing new. Each change is told once, to
    /// whichever runner asks first.
    pub fn engineNews(a: *Admission, buf: []u8) ?[]const u8 {
        a.mu.lockUncancelable(a.io);
        defer a.mu.unlock(a.io);
        const e = &a.engine;
        if (e.told) return null;
        e.told = true;
        return switch (e.outcome) {
            .found => |cap_mb| std.fmt.bufPrint(
                buf,
                "the engine's cgroup is {s}, capped at {f}: the memory gate holds on it too",
                .{ e.dir.?, gb(cap_mb) },
            ),
            .missing => |err| std.fmt.bufPrint(
                buf,
                "the engine's cgroup was not found ({s}): the memory gate sees the machine's " ++
                    "memory only, and looks again every {d} s",
                .{ @errorName(err), Engine.retry_ms / std.time.ms_per_s },
            ),
        } catch null;
    }
};

/// One runner's place at the gate. The runner is counted in `Admission.polling` from the check that
/// lets it through until it leaves: when it takes a job, or its cycle ends.
pub const Gate = struct {
    pool: *Admission,
    /// This runner's entry in `pool.started`.
    slot: usize = 0,
    /// Counted in `pool.polling`.
    claimed: bool = false,
    /// Held at the last check: the resume thresholds apply.
    holding: bool = false,
    /// The hold was logged, so its end is logged too, once each.
    announced: bool = false,

    /// Null when the runner may poll for a job (and it is then counted as polling); otherwise why
    /// not.
    pub fn check(g: *Gate) ?Hold {
        const a = g.pool;
        a.mu.lockUncancelable(a.io);
        defer a.mu.unlock(a.io);
        const now_ms = std.Io.Clock.awake.now(a.io).toMilliseconds();
        if (a.engine.dir == null) a.engine.find(a.io, a.paths, now_ms);
        const sample = read(a.io, a.paths, a.engine.dir);
        // Its files are gone: the engine's container was recreated, under a new cgroup.
        if (a.engine.dir != null and sample.engine == null) a.engine.lost();
        const jobs = a.polling + a.ramping(now_ms) + @intFromBool(!g.claimed);
        const swap_rate = if (sample.swap_used_mb) |u| a.swap.update(u, now_ms) else null;
        const engine_swap_rate = if (sample.engine_swap_mb) |u|
            a.engine.swap.update(u, now_ms)
        else
            null;
        const hold = decide(a.limits, .{
            .available_mb = sample.available_mb,
            .pressure = sample.pressure,
            .swap_growth_mb = swap_rate,
            .engine = sample.engine,
            .engine_swap_growth_mb = engine_swap_rate,
        }, jobs, g.holding);
        g.holding = hold != null;
        if (hold == null and !g.claimed) a.polling += 1;
        if (hold != null and g.claimed) a.polling -= 1;
        g.claimed = hold == null;
        return hold;
    }

    /// The runner stops polling; `took_job` when because it was handed a job, whose memory is then
    /// reserved for `ramp_ms`, or until the job ends (`ended`) if that is sooner.
    pub fn leave(g: *Gate, took_job: bool) void {
        const a = g.pool;
        a.mu.lockUncancelable(a.io);
        defer a.mu.unlock(a.io);
        if (g.claimed) a.polling -= 1;
        g.claimed = false;
        if (!took_job) return;
        a.started[g.slot] = std.Io.Clock.awake.now(a.io).toMilliseconds();
    }

    /// The runner's job is over: its memory is no longer reserved. Without this a job reserved its
    /// memory for the whole `ramp_ms` however short it was, so a burst of short jobs went through
    /// at most (available - floor) / per-job every two minutes: 1.5 jobs a minute on razorbill.
    pub fn ended(g: *Gate) void {
        const a = g.pool;
        a.mu.lockUncancelable(a.io);
        defer a.mu.unlock(a.io);
        a.started[g.slot] = std.math.minInt(i64);
    }
};

/// Why a runner may not take a job, for the log.
pub const Hold = union(enum) {
    memory: struct { available_mb: u64, jobs: u32, per_job_mb: u32, floor_mb: u32 },
    /// Hundredths of a percent.
    pressure: struct { now: u32, limit: u32 },
    /// MB a minute.
    swap: struct { now: u64, limit: u32 },
    engine: struct { used_mb: u64, cap_mb: u64, jobs: u32, per_job_mb: u32, floor_mb: u32 },
    /// MB a minute.
    engine_swap: struct { now: u64, limit: u32 },

    pub fn format(h: Hold, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (h) {
            .memory => |m| try w.print(
                "{d} MB of memory available; {d} job(s) at {d} MB would leave under {d} MB",
                .{ m.available_mb, m.jobs, m.per_job_mb, m.floor_mb },
            ),
            .engine => |e| try w.print(
                "engine {f} of {f} in use; {d} job(s) at {d} MB would leave under {d} MB of " ++
                    "its cap",
                .{ gb(e.used_mb), gb(e.cap_mb), e.jobs, e.per_job_mb, e.floor_mb },
            ),
            .engine_swap => |s| try w.print(
                "engine swapping {d} MB/min (its cgroup's memory.swap.current), limit {d} MB/min",
                .{ s.now, s.limit },
            ),
            .pressure => |p| try w.print(
                "memory pressure {d}.{d:0>2}% (PSI some avg10), limit {d}%",
                .{ p.now / 100, p.now % 100, p.limit },
            ),
            .swap => |s| try w.print("swap growing {d} MB/min, limit {d} MB/min", .{
                s.now,
                s.limit,
            }),
        }
    }
};

/// MB as GB with one decimal, for the log: "3.6 GB".
fn gb(mb: u64) Gb {
    return .{ .tenths = mb * 10 / 1024 };
}

const Gb = struct {
    tenths: u64,

    pub fn format(g: Gb, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d}.{d} GB", .{ g.tenths / 10, g.tenths % 10 });
    }
};

/// What the decision reads; null is "no signal".
pub const Signals = struct {
    available_mb: ?u64 = null,
    /// PSI `some avg10`, in hundredths of a percent.
    pressure: ?u32 = null,
    swap_growth_mb: ?u64 = null,
    engine: ?EngineMemory = null,
    engine_swap_growth_mb: ?u64 = null,
};

/// Whether one more job may be taken when `jobs` jobs (this one included) may start without
/// showing in `available_mb` yet: null if so. `holding` applies the resume thresholds instead
/// (`resume_margin_mb`, half the pressure and swap limits).
pub fn decide(limits: Limits, s: Signals, jobs: u32, holding: bool) ?Hold {
    if (s.available_mb) |avail| {
        const margin: u64 = if (holding) resume_margin_mb else 0;
        const needed = @as(u64, limits.min_available_mb) + @as(u64, jobs) * limits.per_job_mb;
        if (needed > 0 and avail < needed + margin) return .{ .memory = .{
            .available_mb = avail,
            .jobs = jobs,
            .per_job_mb = limits.per_job_mb,
            .floor_mb = limits.min_available_mb,
        } };
    }
    // The same reservations against the engine's cap: every job taken runs in the engine.
    if (s.engine) |e| {
        const margin: u64 = if (holding) resume_margin_mb else 0;
        const needed = @as(u64, limits.min_engine_headroom_mb) + @as(u64, jobs) * limits.per_job_mb;
        if (needed > 0 and e.cap_mb -| e.used_mb < needed + margin) return .{ .engine = .{
            .used_mb = e.used_mb,
            .cap_mb = e.cap_mb,
            .jobs = jobs,
            .per_job_mb = limits.per_job_mb,
            .floor_mb = limits.min_engine_headroom_mb,
        } };
    }
    if (s.pressure) |p| if (limits.max_pressure > 0) {
        const limit = limits.max_pressure * 100;
        if (p >= if (holding) limit / 2 else limit)
            return .{ .pressure = .{ .now = p, .limit = limits.max_pressure } };
    };
    if (s.swap_growth_mb) |g| if (limits.max_swap_growth_mb > 0) {
        const limit = limits.max_swap_growth_mb;
        if (g >= if (holding) limit / 2 else limit)
            return .{ .swap = .{ .now = g, .limit = limit } };
    };
    if (s.engine_swap_growth_mb) |g| if (limits.max_swap_growth_mb > 0) {
        const limit = limits.max_swap_growth_mb;
        if (g >= if (holding) limit / 2 else limit)
            return .{ .engine_swap = .{ .now = g, .limit = limit } };
    };
    return null;
}

/// Swap growth as a rate over at least `window_ms`. Runners check at irregular times (before each
/// poll, about every 50 s, and every `Admission.recheck` while held), so the rate is measured
/// against a baseline at least that old, and kept between measurements.
pub const SwapGrowth = struct {
    base: ?struct { used_mb: u64, at_ms: i64 } = null,
    rate: ?u64 = null,

    pub const window_ms = 10 * std.time.ms_per_s;

    /// MB a minute, or null before there are two samples far enough apart. Swap that shrank is 0.
    pub fn update(s: *SwapGrowth, used_mb: u64, now_ms: i64) ?u64 {
        const base = s.base orelse {
            s.base = .{ .used_mb = used_mb, .at_ms = now_ms };
            return null;
        };
        const elapsed = now_ms - base.at_ms;
        if (elapsed < window_ms) return s.rate;
        s.rate = (used_mb -| base.used_mb) * std.time.ms_per_min / @as(u64, @intCast(elapsed));
        s.base = .{ .used_mb = used_mb, .at_ms = now_ms };
        return s.rate;
    }
};

/// The signals as the files give them now.
pub const Sample = struct {
    available_mb: ?u64 = null,
    swap_used_mb: ?u64 = null,
    /// PSI `some avg10`, in hundredths of a percent.
    pressure: ?u32 = null,
    engine: ?EngineMemory = null,
    engine_swap_mb: ?u64 = null,
};

/// Reads the machine's files, and those of the engine's cgroup `engine_dir`; one that cannot be
/// read, or reads as something else, gives no signal.
pub fn read(io: std.Io, paths: Paths, engine_dir: ?[]const u8) Sample {
    var s: Sample = .{};
    // /proc/meminfo is about 1.5 KB; the fields read are near the top.
    var mem_buf: [4096]u8 = undefined;
    if (std.Io.Dir.cwd().readFile(io, paths.meminfo, &mem_buf)) |text| {
        const m = parseMeminfo(text);
        s.available_mb = m.available_mb;
        s.swap_used_mb = m.swap_used_mb;
    } else |_| {}
    var psi_buf: [256]u8 = undefined;
    // PSI compiled in but off (`psi=0`) fails the read with EOPNOTSUPP: no signal either.
    if (std.Io.Dir.cwd().readFile(io, paths.pressure, &psi_buf)) |text| {
        s.pressure = parsePressure(text);
    } else |_| {}
    if (engine_dir) |dir| if (readEngine(io, dir)) |e| {
        s.engine = e;
        // Without swap accounting (`swapaccount=0`) the file is not there: no signal.
        if (readBytes(io, dir, "memory.swap.current")) |b| s.engine_swap_mb = b >> 20;
    };
    return s;
}

/// The engine's cap, and its working set: `memory.current` less `inactive_file`. The engine's cache
/// is file-backed and large (image layers, the step and package caches), and the kernel drops
/// inactive file pages first and cheaply as the cgroup nears its cap, so counting them would hold
/// runners for memory the engine gives up the moment a job needs it. Active file pages stay
/// counted: they are being read, and dropping them turns into reads from the SD card. This is the
/// working set `docker stats` shows, and the one the kubelet evicts on, so the log and
/// `docker stats` on the Pi agree. Null unless the cap is a number and usage is readable (a cap
/// removed is no longer a limit).
fn readEngine(io: std.Io, dir: []const u8) ?EngineMemory {
    const cap = readBytes(io, dir, "memory.max") orelse return null;
    const current = readBytes(io, dir, "memory.current") orelse return null;
    // memory.stat is about 2.5 KB (cgroup v2 on Linux 7.0); inactive_file is in its first half.
    var stat_buf: [8192]u8 = undefined;
    const inactive_file = if (readIn(io, dir, "memory.stat", &stat_buf)) |text|
        parseStat(text, "inactive_file") orelse 0
    else |_|
        0;
    return .{ .cap_mb = cap >> 20, .used_mb = (current -| inactive_file) >> 20 };
}

/// A cgroup file that holds one number of bytes; null for "max", or one that cannot be read.
fn readBytes(io: std.Io, dir: []const u8, name: []const u8) ?u64 {
    var buf: [32]u8 = undefined;
    const text = readIn(io, dir, name, &buf) catch return null;
    return std.fmt.parseInt(u64, std.mem.trim(u8, text, " \n"), 10) catch null;
}

fn readIn(io: std.Io, dir: []const u8, name: []const u8, buf: []u8) ![]u8 {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, name });
    return std.Io.Dir.cwd().readFile(io, path, buf);
}

/// One key of a cgroup's memory.stat ("inactive_file 65536"), in bytes.
pub fn parseStat(text: []const u8, key: []const u8) ?u64 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len <= key.len or line[key.len] != ' ') continue;
        if (!std.mem.startsWith(u8, line, key)) continue;
        return std.fmt.parseInt(u64, line[key.len + 1 ..], 10) catch null;
    }
    return null;
}

/// The engine's memory, in MB.
pub const EngineMemory = struct { cap_mb: u64, used_mb: u64 };

/// The engine's own memory cap (#142). On razorbill the engine's container is capped at 4 GB of
/// the Pi's 8: four jobs' coinciding compiles pushed it to its cap and 1 GB into swap in 30 s,
/// while `MemAvailable` still showed 2 GB, and had shown 4.8 GB as each job was let through. The
/// machine's signals cannot see a cgroup's cap, so the gate reads the engine's cgroup too.
///
/// Found without Docker (the runner need not be in the docker group): the engine's unix socket is
/// connected to, and `SO_PEERCRED` names the process listening on it, in the runner's own PID
/// namespace. Its `/proc/<pid>/cgroup` names its cgroup, and the cap that binds is the nearest one
/// at or above it. `/proc/net/unix` cannot do this: the engine's socket is in its container's
/// network namespace, so the host's list does not show it. Where the engine's process is not
/// visible (the runner in a container of its own, as in deploy/compose.yaml), the PID comes back
/// 0, and the gate goes on with the machine's signals alone.
pub const Engine = struct {
    source: Source = .off,
    /// The cgroup whose cap binds, in `dir_buf`: null until found, and again once its files cannot
    /// be read (the engine's container was recreated, under a new cgroup).
    dir: ?[]const u8 = null,
    dir_buf: [std.Io.Dir.max_path_bytes]u8 = undefined,
    /// When `find` last failed (awake clock, ms): it is tried again `retry_ms` later. At boot the
    /// runner can start before Docker has started the engine.
    failed_ms: ?i64 = null,
    swap: SwapGrowth = .{},
    /// What `find` last concluded, told once (`Admission.engineNews`).
    outcome: union(enum) { found: u64, missing: anyerror } = .{ .missing = error.NotLookedFor },
    told: bool = true,

    pub const retry_ms = 60 * std.time.ms_per_s;

    /// Where the engine's cgroup is found (`RUNNER_ENGINE_CGROUP`, `RUNNER_ENGINE_HOST`).
    pub const Source = union(enum) {
        /// No engine signal, and nothing logged about it.
        off,
        /// A cgroup directory, given.
        cgroup: []const u8,
        /// The engine's address: a `unix://` one is followed to its listener's cgroup.
        host: []const u8,
    };

    fn find(e: *Engine, io: std.Io, paths: Paths, now_ms: i64) void {
        if (e.source == .off) return;
        if (e.failed_ms) |t| if (now_ms - t < retry_ms) return;
        if (locate(io, paths, e.source, &e.dir_buf)) |dir| {
            e.dir = dir;
            e.failed_ms = null;
            e.swap = .{};
            e.outcome = .{ .found = (readBytes(io, dir, "memory.max") orelse 0) >> 20 };
            e.told = false;
        } else |err| {
            e.failed_ms = now_ms;
            // Logged once, not at every minute's look.
            if (e.outcome == .missing and e.outcome.missing == err) return;
            e.outcome = .{ .missing = err };
            e.told = false;
        }
    }

    fn lost(e: *Engine) void {
        e.dir = null;
        e.failed_ms = null;
        e.outcome = .{ .missing = error.EngineCgroupGone };
        e.told = false;
    }
};

/// The engine's cgroup directory, written into `buf`: the nearest at or above the one `source`
/// names with a memory cap.
fn locate(io: std.Io, paths: Paths, source: Engine.Source, buf: []u8) ![]const u8 {
    var start_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const start = switch (source) {
        .off => unreachable,
        .cgroup => |dir| dir,
        .host => |host| s: {
            if (!std.mem.startsWith(u8, host, "unix://")) return error.EngineHostNotUnixSocket;
            const pid = try listenerPid(io, host["unix://".len..]);
            var proc_buf: [32]u8 = undefined;
            const proc = try std.fmt.bufPrint(&proc_buf, "/proc/{d}/cgroup", .{pid});
            var text_buf: [4096]u8 = undefined;
            const text = try std.Io.Dir.cwd().readFile(io, proc, &text_buf);
            const rel = parseProcCgroup(text) orelse return error.NoCgroupV2;
            break :s try std.fmt.bufPrint(&start_buf, "{s}{s}", .{ paths.cgroup_root, rel });
        },
    };
    return cappedAncestor(io, paths.cgroup_root, start, buf);
}

/// The process listening on the unix socket at `path`, as this process's PID namespace numbers
/// it. Connecting is enough: the listener's credentials are recorded when it calls listen().
fn listenerPid(io: std.Io, path: []const u8) !i32 {
    if (builtin.os.tag != .linux) return error.Unsupported;
    const linux = std.os.linux;
    const addr = try std.Io.net.UnixAddress.init(path);
    const stream = try addr.connect(io);
    defer stream.close(io);
    var cred: extern struct { pid: i32, uid: u32, gid: u32 } = undefined;
    var len: linux.socklen_t = @sizeOf(@TypeOf(cred));
    const rc = linux.getsockopt(
        stream.socket.handle,
        linux.SOL.SOCKET,
        linux.SO.PEERCRED,
        @ptrCast(&cred),
        &len,
    );
    if (linux.errno(rc) != .SUCCESS) return error.NoPeerCredentials;
    // 0: the listener is in a PID namespace this process cannot see into.
    if (cred.pid <= 0) return error.EngineProcessNotVisible;
    return cred.pid;
}

/// The cgroup v2 path in /proc/<pid>/cgroup ("0::/system.slice/docker-<id>.scope").
pub fn parseProcCgroup(text: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "0::/")) return line["0::".len..];
    }
    return null;
}

/// `start`, or the nearest cgroup above it, whose memory.max is a number, copied into `buf`. The
/// engine's own process can sit in a child of its container's cgroup, where the cap is not
/// (Docker-in-Docker style entrypoints move it into one to nest cgroups).
fn cappedAncestor(io: std.Io, root: []const u8, start: []const u8, buf: []u8) ![]const u8 {
    var dir = std.mem.trimEnd(u8, start, "/");
    var first = true;
    while (dir.len > root.len and std.mem.startsWith(u8, dir, root)) : (first = false) {
        var max_buf: [32]u8 = undefined;
        const text = readIn(io, dir, "memory.max", &max_buf) catch |err| switch (err) {
            // A cgroup given that is not there is worth saying so; past it, the root's lack.
            error.FileNotFound => if (first) return error.CgroupNotFound else break,
            else => return err,
        };
        if (std.fmt.parseInt(u64, std.mem.trim(u8, text, " \n"), 10)) |_| {
            if (dir.len > buf.len) return error.NameTooLong;
            @memcpy(buf[0..dir.len], dir);
            return buf[0..dir.len];
        } else |_| {}
        dir = std.fs.path.dirname(dir) orelse break;
    }
    return error.NoMemoryCap;
}

/// `MemAvailable`, and swap in use, in MB.
pub fn parseMeminfo(text: []const u8) struct { available_mb: ?u64, swap_used_mb: ?u64 } {
    var available: ?u64 = null;
    var swap_total: ?u64 = null;
    var swap_free: ?u64 = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = line[0..colon];
        // "MemAvailable:    5632000 kB"
        var fields = std.mem.tokenizeScalar(u8, line[colon + 1 ..], ' ');
        const kb = std.fmt.parseInt(u64, fields.next() orelse continue, 10) catch continue;
        if (std.mem.eql(u8, key, "MemAvailable")) available = kb / 1024 //
        else if (std.mem.eql(u8, key, "SwapTotal")) swap_total = kb / 1024 //
        else if (std.mem.eql(u8, key, "SwapFree")) swap_free = kb / 1024;
    }
    const swap_used = if (swap_total != null and swap_free != null)
        swap_total.? -| swap_free.?
    else
        null;
    return .{ .available_mb = available, .swap_used_mb = swap_used };
}

/// `some avg10` from /proc/pressure/memory, in hundredths of a percent ("12.34" is 1234).
pub fn parsePressure(text: []const u8) ?u32 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "some ")) continue;
        var fields = std.mem.tokenizeScalar(u8, line["some ".len..], ' ');
        while (fields.next()) |field| {
            if (!std.mem.startsWith(u8, field, "avg10=")) continue;
            return hundredths(field["avg10=".len..]);
        }
    }
    return null;
}

/// "12.34" as 1234; the kernel prints two decimals.
fn hundredths(s: []const u8) ?u32 {
    const dot = std.mem.indexOfScalar(u8, s, '.') orelse s.len;
    const whole = std.fmt.parseInt(u32, s[0..dot], 10) catch return null;
    var frac: u32 = 0;
    if (dot < s.len) {
        const digits = s[dot + 1 ..];
        if (digits.len == 0 or digits.len > 2) return null;
        frac = std.fmt.parseInt(u32, digits, 10) catch return null;
        if (digits.len == 1) frac *= 10;
    }
    return whole * 100 + frac;
}

test "MemAvailable and swap in use from /proc/meminfo" {
    // Trimmed from razorbill at idle.
    const text = "MemTotal:        8245632 kB\n" ++
        "MemFree:          921344 kB\n" ++
        "MemAvailable:    5632000 kB\n" ++
        "Buffers:           12288 kB\n" ++
        "SwapCached:         4096 kB\n" ++
        "SwapTotal:       2097148 kB\n" ++
        "SwapFree:        1048572 kB\n" ++
        "Hugepagesize:       2048 kB\n";
    const m = parseMeminfo(text);
    try std.testing.expectEqual(@as(?u64, 5500), m.available_mb);
    try std.testing.expectEqual(@as(?u64, 1024), m.swap_used_mb);

    // A kernel without swap, and text that is not meminfo.
    const no_swap = parseMeminfo("MemAvailable: 1024 kB\n");
    try std.testing.expectEqual(@as(?u64, 1), no_swap.available_mb);
    try std.testing.expectEqual(@as(?u64, null), no_swap.swap_used_mb);
    const junk = parseMeminfo("MemAvailable: lots\nnonsense\n");
    try std.testing.expectEqual(@as(?u64, null), junk.available_mb);
}

test "PSI some avg10 from /proc/pressure/memory" {
    const text = "some avg10=12.34 avg60=3.10 avg300=0.80 total=123456789\n" ++
        "full avg10=9.00 avg60=2.00 avg300=0.50 total=98765432\n";
    try std.testing.expectEqual(@as(?u32, 1234), parsePressure(text));
    try std.testing.expectEqual(@as(?u32, 0), parsePressure(
        "some avg10=0.00 avg60=0.00 avg300=0.00 total=0\n",
    ));
    try std.testing.expectEqual(@as(?u32, 10000), parsePressure("some avg10=100.00 total=1\n"));
    try std.testing.expectEqual(@as(?u32, 50), parsePressure("some avg10=0.5\n"));
    // Only `full` (not a format the kernel writes), or nothing readable: no signal.
    try std.testing.expectEqual(@as(?u32, null), parsePressure("full avg10=9.00\n"));
    try std.testing.expectEqual(@as(?u32, null), parsePressure("some avg10=x\n"));
    try std.testing.expectEqual(@as(?u32, null), parsePressure(""));
}

test "missing files give no signal" {
    const s = read(
        std.testing.io,
        .{ .meminfo = "/nonexistent/m", .pressure = "/nonexistent/p" },
        "/nonexistent/engine",
    );
    try std.testing.expectEqual(Sample{}, s);
    try std.testing.expect(decide(.{}, .{}, 4, false) == null);
}

test "the defaults on razorbill: three jobs at once from idle, not four" {
    // Idle: about 5.5 GB available with the engine at 600 MB, no pressure.
    const idle: Signals = .{ .available_mb = 5500, .pressure = 0, .swap_growth_mb = 0 };
    try std.testing.expect(decide(.{}, idle, 3, false) == null);
    try std.testing.expect(decide(.{}, idle, 4, false).? == .memory);
    // Three heavy jobs in: about 1.1 GB each, the engine near its 4 GB cap.
    const busy: Signals = .{ .available_mb = 2200, .pressure = 0, .swap_growth_mb = 0 };
    try std.testing.expect(decide(.{}, busy, 1, false).? == .memory);
    // Three light jobs (200 MB each) past their ramp: a fourth is let through.
    const light: Signals = .{ .available_mb = 4900, .pressure = 0, .swap_growth_mb = 0 };
    try std.testing.expect(decide(.{}, light, 1, false) == null);
    // The incident: engine swapping at its cgroup cap while the host still has memory.
    const thrash: Signals = .{ .available_mb = 2100, .pressure = 4500, .swap_growth_mb = 400 };
    try std.testing.expect(decide(.{ .per_job_mb = 0 }, thrash, 1, false).? == .pressure);
    const thrash_no_psi: Signals = .{ .available_mb = 2100, .swap_growth_mb = 400 };
    try std.testing.expect(decide(.{ .per_job_mb = 0 }, thrash_no_psi, 1, false).? == .swap);
}

test "a held runner resumes only past the margins, so it does not flap at a threshold" {
    const limits: Limits = .{ .min_available_mb = 1000, .per_job_mb = 500 };
    // Needs 1500 MB to start, 1756 to resume.
    try std.testing.expect(decide(limits, .{ .available_mb = 1600 }, 1, false) == null);
    try std.testing.expect(decide(limits, .{ .available_mb = 1499 }, 1, false) != null);
    try std.testing.expect(decide(limits, .{ .available_mb = 1600 }, 1, true) != null);
    try std.testing.expect(decide(limits, .{ .available_mb = 1756 }, 1, true) == null);
    // Pressure: holds at 10%, resumes under 5%.
    try std.testing.expect(decide(limits, .{ .pressure = 999 }, 1, false) == null);
    try std.testing.expect(decide(limits, .{ .pressure = 1000 }, 1, false).? == .pressure);
    try std.testing.expect(decide(limits, .{ .pressure = 700 }, 1, true) != null);
    try std.testing.expect(decide(limits, .{ .pressure = 499 }, 1, true) == null);
    // Swap growth: holds at 64 MB/min, resumes under 32.
    try std.testing.expect(decide(limits, .{ .swap_growth_mb = 64 }, 1, false).? == .swap);
    try std.testing.expect(decide(limits, .{ .swap_growth_mb = 40 }, 1, true) != null);
    try std.testing.expect(decide(limits, .{ .swap_growth_mb = 31 }, 1, true) == null);
    // Every check off.
    const off: Limits = .{
        .min_available_mb = 0,
        .per_job_mb = 0,
        .max_pressure = 0,
        .max_swap_growth_mb = 0,
    };
    const worst: Signals = .{ .available_mb = 0, .pressure = 10000, .swap_growth_mb = 9999 };
    try std.testing.expect(decide(off, worst, 4, true) == null);
}

test "swap growth is a rate over at least ten seconds" {
    var g: SwapGrowth = .{};
    try std.testing.expectEqual(@as(?u64, null), g.update(100, 0));
    // Too soon to measure: still nothing.
    try std.testing.expectEqual(@as(?u64, null), g.update(500, 5_000));
    // 200 MB in 20 s: 600 MB a minute.
    try std.testing.expectEqual(@as(?u64, 600), g.update(300, 20_000));
    // Kept until the next measurement; shrinking swap is no growth.
    try std.testing.expectEqual(@as(?u64, 600), g.update(900, 25_000));
    try std.testing.expectEqual(@as(?u64, 0), g.update(250, 30_000));
}

test "the pool reserves memory for runners polling and jobs just started" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "meminfo", .data = "MemAvailable: 5632000 kB\n" });
    var path_buf: [256]u8 = undefined;
    const meminfo = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/meminfo", .{tmp.sub_path});

    var started: [4]i64 = undefined;
    var pool: Admission = .init(io, .{}, &started);
    pool.paths = .{ .meminfo = meminfo, .pressure = "/nonexistent" };
    var gates: [4]Gate = undefined;
    for (&gates, 0..) |*g, i| g.* = .{ .pool = &pool, .slot = i };
    // 5500 MB: three runners may poll (1536 + 3 * 1024 = 4608), a fourth may not (5632).
    for (gates[0..3]) |*g| try std.testing.expect(g.check() == null);
    try std.testing.expectEqual(@as(u32, 3), pool.polling);
    try std.testing.expect(gates[3].check().? == .memory);
    // Looking again while counted does not count a runner twice.
    try std.testing.expect(gates[0].check() == null);
    try std.testing.expectEqual(@as(u32, 3), pool.polling);
    // A job taken stays reserved while it ramps up: the fourth is still held.
    gates[0].leave(true);
    try std.testing.expectEqual(@as(u32, 2), pool.polling);
    try std.testing.expect(gates[3].check() != null);
    // A cycle that ends without a job frees its place.
    gates[1].leave(false);
    gates[2].leave(false);
    try std.testing.expectEqual(@as(u32, 0), pool.polling);
    try std.testing.expect(gates[3].check() == null);
}

test "a job that is over reserves nothing, however soon it ended" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "meminfo", .data = "MemAvailable: 5632000 kB\n" });
    var path_buf: [256]u8 = undefined;
    const meminfo = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/meminfo", .{tmp.sub_path});

    var started: [4]i64 = undefined;
    var pool: Admission = .init(io, .{}, &started);
    pool.paths = .{ .meminfo = meminfo, .pressure = "/nonexistent" };
    var gates: [4]Gate = undefined;
    for (&gates, 0..) |*g, i| g.* = .{ .pool = &pool, .slot = i };
    // Three runners take a job each; while those ramp up, a fourth is held.
    for (gates[0..3]) |*g| {
        try std.testing.expect(g.check() == null);
        g.leave(true);
    }
    try std.testing.expect(gates[3].check() != null);
    // The jobs end at once (short jobs): their reservations go with them, well within ramp_ms.
    for (gates[0..3]) |*g| g.ended();
    try std.testing.expect(gates[3].check() == null);
    // A runner's next job takes its own entry again, not another runner's.
    gates[3].leave(true);
    gates[3].ended();
    try std.testing.expectEqual(std.math.minInt(i64), started[3]);
}

/// A cgroup directory under `tmp` with memory.max, memory.current, memory.stat and, if given,
/// memory.swap.current, in bytes.
fn writeCgroup(
    tmp: std.Io.Dir,
    sub: []const u8,
    max: []const u8,
    current: u64,
    inactive_file: u64,
    swap: ?u64,
) !void {
    const io = std.testing.io;
    try tmp.createDirPath(io, sub);
    var dir = try tmp.openDir(io, sub, .{});
    defer dir.close(io);
    var buf: [512]u8 = undefined;
    try dir.writeFile(io, .{
        .sub_path = "memory.max",
        .data = try std.fmt.bufPrint(&buf, "{s}\n", .{max}),
    });
    try dir.writeFile(io, .{
        .sub_path = "memory.current",
        .data = try std.fmt.bufPrint(&buf, "{d}\n", .{current}),
    });
    // Trimmed from a `docker run --memory 512m` container's memory.stat (Linux 7.0).
    try dir.writeFile(io, .{
        .sub_path = "memory.stat",
        .data = try std.fmt.bufPrint(&buf, "anon 53248\nfile 1216512\nkernel 352256\n" ++
            "shmem 0\nfile_mapped 847872\ninactive_anon 0\nactive_anon 53248\n" ++
            "inactive_file {d}\nactive_file 1150976\nslab 258312\n", .{inactive_file}),
    });
    if (swap) |s| try dir.writeFile(io, .{
        .sub_path = "memory.swap.current",
        .data = try std.fmt.bufPrint(&buf, "{d}\n", .{s}),
    });
}

const mib = 1 << 20;

test "the engine's cgroup: its cap, its use less inactive file cache, its swap" {
    const stat = "anon 1\ninactive_file 65536\n";
    try std.testing.expectEqual(@as(?u64, 65536), parseStat(stat, "inactive_file"));
    // A key that only starts with the one asked for is another key.
    try std.testing.expectEqual(@as(?u64, null), parseStat("inactive_filex 3\n", "inactive_file"));
    try std.testing.expectEqual(@as(?u64, null), parseStat("", "inactive_file"));
    try std.testing.expectEqualStrings(
        "/system.slice/docker-ab12.scope",
        parseProcCgroup("0::/system.slice/docker-ab12.scope\n").?,
    );
    // A cgroup v1 machine names no unified hierarchy.
    try std.testing.expectEqual(@as(?[]const u8, null), parseProcCgroup("12:memory:/docker/a\n"));

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const none: Paths = .{ .meminfo = "/nonexistent", .pressure = "/nonexistent" };
    // razorbill's engine mid-soak: 3.9 GB charged, 300 MB of it inactive cache, and swapping.
    try writeCgroup(tmp.dir, "engine", "4294967296", 3900 * mib, 300 * mib, 512 * mib);
    var path_buf: [256]u8 = undefined;
    const dir = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/engine", .{tmp.sub_path});
    const s = read(io, none, dir);
    try std.testing.expectEqual(EngineMemory{ .cap_mb = 4096, .used_mb = 3600 }, s.engine.?);
    try std.testing.expectEqual(@as(?u64, 512), s.engine_swap_mb);

    // No cap ("max"): no engine signal.
    try writeCgroup(tmp.dir, "uncapped", "max", 3900 * mib, 0, null);
    const uncapped = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/uncapped", .{
        tmp.sub_path,
    });
    try std.testing.expectEqual(@as(?EngineMemory, null), read(io, none, uncapped).engine);
}

test "the engine's cap holds a runner the machine's memory would let through" {
    // The incident (#142): the machine shows 4.8 GB available and lets a job through; the
    // engine, 3.5 of its 4 GB in use, does not.
    const incident: Signals = .{
        .available_mb = 4800,
        .pressure = 0,
        .swap_growth_mb = 0,
        .engine = .{ .cap_mb = 4096, .used_mb = 3600 },
    };
    try std.testing.expect(decide(.{}, .{ .available_mb = 4800 }, 1, false) == null);
    const hold = decide(.{}, incident, 1, false).?;
    try std.testing.expect(hold == .engine);
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "engine 3.5 GB of 4.0 GB in use; 1 job(s) at 1024 MB would leave under 256 MB of its cap",
        try std.fmt.bufPrint(&buf, "{f}", .{hold}),
    );
    // The engine at idle (600 MB): three jobs fit under its cap, as under the machine's; four not.
    const idle: Signals = .{ .engine = .{ .cap_mb = 4096, .used_mb = 600 } };
    try std.testing.expect(decide(.{}, idle, 3, false) == null);
    try std.testing.expect(decide(.{}, idle, 4, false).? == .engine);
    // Held, it resumes only with `resume_margin_mb` more: 1280 MB needed, 1536 to resume.
    const tight: Signals = .{ .engine = .{ .cap_mb = 4096, .used_mb = 4096 - 1400 } };
    try std.testing.expect(decide(.{}, tight, 1, false) == null);
    try std.testing.expect(decide(.{}, tight, 1, true).? == .engine);
    const freed: Signals = .{ .engine = .{ .cap_mb = 4096, .used_mb = 4096 - 1536 } };
    try std.testing.expect(decide(.{}, freed, 1, true) == null);
    // Over its cap (memory.current can pass memory.max for a moment): held, not an overflow.
    const over: Signals = .{ .engine = .{ .cap_mb = 4096, .used_mb = 4200 } };
    try std.testing.expect(decide(.{}, over, 1, false).? == .engine);
    // The engine swapping: held at 64 MB/min, resumed under 32, as for the machine's swap.
    const swapping: Signals = .{ .engine_swap_growth_mb = 64 };
    try std.testing.expect(decide(.{}, swapping, 1, false).? == .engine_swap);
    try std.testing.expect(decide(.{}, .{ .engine_swap_growth_mb = 40 }, 1, true) != null);
    try std.testing.expect(decide(.{}, .{ .engine_swap_growth_mb = 31 }, 1, true) == null);
}

test "the engine's cgroup is the nearest capped one at or above its process's" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var root_buf: [128]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}/cg", .{tmp.sub_path});
    // The scope Docker made, capped, and a child its entrypoint moved the engine into, not.
    try writeCgroup(tmp.dir, "cg/system.slice/docker-e.scope", "4294967296", 0, 0, null);
    try writeCgroup(tmp.dir, "cg/system.slice/docker-e.scope/init", "max", 0, 0, null);
    try writeCgroup(tmp.dir, "cg/system.slice", "max", 0, 0, null);
    var start_buf: [256]u8 = undefined;
    var buf: [256]u8 = undefined;
    const start = try std.fmt.bufPrint(&start_buf, "{s}/system.slice/docker-e.scope/init", .{root});
    const found = try cappedAncestor(io, root, start, &buf);
    try std.testing.expect(std.mem.endsWith(u8, found, "cg/system.slice/docker-e.scope"));
    // Nothing capped up to the root, or a cgroup that is not there.
    const slice = try std.fmt.bufPrint(&start_buf, "{s}/system.slice", .{root});
    try std.testing.expectError(error.NoMemoryCap, cappedAncestor(io, root, slice, &buf));
    const gone = try std.fmt.bufPrint(&start_buf, "{s}/system.slice/docker-x.scope", .{root});
    try std.testing.expectError(error.CgroupNotFound, cappedAncestor(io, root, gone, &buf));
}

test "the engine's cgroup is found through its socket's listener, or not, saying why once" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    // This test process stands in for the engine: its own cgroup, under a fixture root.
    var self_buf: [4096]u8 = undefined;
    const self = std.Io.Dir.cwd().readFile(io, "/proc/self/cgroup", &self_buf) catch
        return error.SkipZigTest;
    const own = parseProcCgroup(self) orelse return error.SkipZigTest;
    if (own.len < 2) return error.SkipZigTest;
    var sub_buf: [512]u8 = undefined;
    const sub = try std.fmt.bufPrint(&sub_buf, "cg{s}", .{own});
    try writeCgroup(tmp.dir, sub, "536870912", 0, 0, null);
    var root_buf: [128]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}/cg", .{tmp.sub_path});
    // Relative: an absolute path into a worktree can pass a socket address's 108 bytes.
    var sock_buf: [128]u8 = undefined;
    const sock = try std.fmt.bufPrint(&sock_buf, ".zig-cache/tmp/{s}/e.sock", .{tmp.sub_path});
    const addr = try std.Io.net.UnixAddress.init(sock);
    var server = try addr.listen(io, .{});
    defer server.deinit(io);
    var host_buf: [160]u8 = undefined;
    const host = try std.fmt.bufPrint(&host_buf, "unix://{s}", .{sock});

    var started: [1]i64 = undefined;
    var pool: Admission = .init(io, .{}, &started);
    const paths: Paths = .{
        .meminfo = "/nonexistent",
        .pressure = "/nonexistent",
        .cgroup_root = root,
    };
    pool.paths = paths;
    pool.engine.source = .{ .host = host };
    var gate: Gate = .{ .pool = &pool };
    _ = gate.check();
    try std.testing.expect(std.mem.endsWith(u8, pool.engine.dir.?, own));
    var buf: [512]u8 = undefined;
    const news = pool.engineNews(&buf).?;
    try std.testing.expect(std.mem.indexOf(u8, news, "capped at 0.5 GB") != null);
    try std.testing.expectEqual(@as(?[]const u8, null), pool.engineNews(&buf));

    // No engine there: said once with why, and not looked for again for a minute.
    var none: Admission = .init(io, .{}, &started);
    none.paths = paths;
    none.engine.source = .{ .host = "unix:///nonexistent/engine.sock" };
    var g2: Gate = .{ .pool = &none };
    try std.testing.expect(g2.check() == null);
    try std.testing.expectEqual(@as(?[]const u8, null), none.engine.dir);
    try std.testing.expect(std.mem.indexOf(u8, none.engineNews(&buf).?, "FileNotFound") != null);
    _ = g2.check();
    try std.testing.expectEqual(@as(?[]const u8, null), none.engineNews(&buf));
    // An engine reached over TCP, or through Docker, has no socket to follow.
    var tcp: Admission = .init(io, .{}, &started);
    tcp.paths = paths;
    tcp.engine.source = .{ .host = "tcp://127.0.0.1:1234" };
    var g3: Gate = .{ .pool = &tcp };
    _ = g3.check();
    const why = tcp.engineNews(&buf).?;
    try std.testing.expect(std.mem.indexOf(u8, why, "EngineHostNotUnixSocket") != null);
    // Off: nothing looked for, nothing said.
    var off: Admission = .init(io, .{}, &started);
    off.paths = paths;
    var g4: Gate = .{ .pool = &off };
    _ = g4.check();
    try std.testing.expectEqual(@as(?[]const u8, null), off.engineNews(&buf));
}

test "an engine container recreated is looked for again" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try writeCgroup(tmp.dir, "cg/docker-a.scope", "4294967296", 1024 * mib, 0, null);
    var root_buf: [128]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, ".zig-cache/tmp/{s}/cg", .{tmp.sub_path});
    var dir_buf: [160]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "{s}/docker-a.scope", .{root});
    var started: [1]i64 = undefined;
    var pool: Admission = .init(io, .{}, &started);
    pool.paths = .{ .meminfo = "/nonexistent", .pressure = "/nonexistent", .cgroup_root = root };
    pool.engine.source = .{ .cgroup = dir };
    var gate: Gate = .{ .pool = &pool };
    try std.testing.expect(gate.check() == null);
    try std.testing.expect(pool.engine.dir != null);
    var buf: [512]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, pool.engineNews(&buf).?, "capped at 4.0") != null);
    // Gone: forgotten and said, and looked for again at the next check, not a minute later.
    try tmp.dir.deleteTree(io, "cg/docker-a.scope");
    try std.testing.expect(gate.check() == null);
    try std.testing.expectEqual(@as(?[]const u8, null), pool.engine.dir);
    const gone = pool.engineNews(&buf).?;
    try std.testing.expect(std.mem.indexOf(u8, gone, "not found (EngineCgroupGone)") != null);
    try std.testing.expect(gate.check() == null);
    const news = pool.engineNews(&buf).?;
    try std.testing.expect(std.mem.indexOf(u8, news, "not found (CgroupNotFound)") != null);
    // Back, under the same name (`docker restart` keeps the container's ID).
    try writeCgroup(tmp.dir, "cg/docker-a.scope", "4294967296", 1024 * mib, 0, null);
    pool.engine.failed_ms = null;
    try std.testing.expect(gate.check() == null);
    try std.testing.expect(pool.engine.dir != null);
}
