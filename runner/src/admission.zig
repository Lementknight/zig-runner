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
const std = @import("std");

/// The thresholds (`RUNNER_MIN_MEM_AVAILABLE_MB` and the rest, see deploy/runner.env.example). 0
/// turns a check off.
pub const Limits = struct {
    /// `MemAvailable` that must be left once every job that may start has its `per_job_mb`.
    min_available_mb: u32 = 1536,
    /// Memory to reserve for a job that does not show in `MemAvailable` yet.
    per_job_mb: u32 = 1024,
    /// PSI `some avg10`, in percent, at or above which no runner takes a job.
    max_pressure: u32 = 10,
    /// Swap growth, in MB a minute, at or above which no runner takes a job.
    max_swap_growth_mb: u32 = 64,
};

/// Where the signals are read; tests point these at fixtures.
pub const Paths = struct {
    meminfo: []const u8 = "/proc/meminfo",
    pressure: []const u8 = "/proc/pressure/memory",
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
        const sample = read(a.io, a.paths);
        const jobs = a.polling + a.ramping(now_ms) + @intFromBool(!g.claimed);
        const swap_rate = if (sample.swap_used_mb) |u| a.swap.update(u, now_ms) else null;
        const hold = decide(a.limits, .{
            .available_mb = sample.available_mb,
            .pressure = sample.pressure,
            .swap_growth_mb = swap_rate,
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

    pub fn format(h: Hold, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (h) {
            .memory => |m| try w.print(
                "{d} MB of memory available; {d} job(s) at {d} MB would leave under {d} MB",
                .{ m.available_mb, m.jobs, m.per_job_mb, m.floor_mb },
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

/// What the decision reads; null is "no signal".
pub const Signals = struct {
    available_mb: ?u64 = null,
    /// PSI `some avg10`, in hundredths of a percent.
    pressure: ?u32 = null,
    swap_growth_mb: ?u64 = null,
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
};

/// Reads both files; one that cannot be read, or reads as something else, gives no signal.
pub fn read(io: std.Io, paths: Paths) Sample {
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
    return s;
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
    const s = read(std.testing.io, .{ .meminfo = "/nonexistent/m", .pressure = "/nonexistent/p" });
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
