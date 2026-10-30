//! The runner's main flow (DESIGN §6): register a JIT runner, open a broker session, wait for one
//! job, acquire it, execute it through Dagger, report the result, and start over with a new
//! registration (`serve`), or exit after one job with `--once`.
const std = @import("std");
const Config = @import("config.zig").Config;
const jitconfig = @import("github/jitconfig.zig");
const auth = @import("github/auth.zig");
const broker = @import("github/broker.zig");
const runservice = @import("github/runservice.zig");
const job_mod = @import("job.zig");
const trust = @import("trust.zig");
const dagger = @import("dagger.zig");
const engine = @import("engine.zig");
const db = @import("db.zig");
const sink = @import("sink.zig");
const redact = @import("redact.zig");
const timefmt = @import("timefmt.zig");
const Live = @import("live.zig").Live;
const admission = @import("admission.zig");
const CompleteStep = @import("loop/upload.zig").CompleteStep;
const Shown = @import("loop/upload.zig").Shown;
const shownSteps = @import("loop/upload.zig").shownSteps;
const liveConclusion = @import("loop/upload.zig").liveConclusion;
const uploadLogs = @import("loop/upload.zig").uploadLogs;
const keptBuffer = @import("loop/upload.zig").keptBuffer;
const StepLogs = @import("loop/upload.zig").StepLogs;
const annotationsJson = @import("loop/upload.zig").annotationsJson;
const stepResultsJson = @import("loop/upload.zig").stepResultsJson;

const Allocator = std.mem.Allocator;

/// SPEC §2 exit codes.
pub const Exit = enum(u8) { done = 0, config = 1, github = 2, db = 3 };

/// SIGTERM / SIGINT received so far (`main` installs the handlers). The first asks the runners to
/// stop: waiting ones stop at once, running jobs get `Config.stop_grace_secs` to finish and are
/// then cancelled (`StopDeadline`). The second exits immediately.
pub var stop_signals: std.atomic.Value(u32) = .init(0);

pub fn stopRequested() bool {
    return stop_signals.load(.acquire) > 0;
}

pub const Context = struct {
    /// Lives for one cycle (`serve` frees it after each job).
    arena: Allocator,
    /// Backs each cycle's arena.
    gpa: Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    cfg: *const Config,
    log: *sink.LogSink,
    err: *std.Io.Writer,
    /// Config secrets; the job's own secrets are appended once it is acquired.
    secrets: []const []const u8,
    /// The runner's registration name; `serve` gives each cycle a new one.
    name: []const u8,
    /// Where run state is written (SPEC §5.2); null when the runner has no database.
    store: ?*db.Store = null,
    /// Shared by the pool: repositories whose output-key work ran over the limit.
    slow_outputs: ?*SlowOutputs = null,
    /// Where `serve` keeps the previous cycle's ending, running in the background (`endCycle`);
    /// null ends a cycle in place, as tests and one-off commands do.
    ending: ?*?std.Io.Future(void) = null,
    /// Where `serve` keeps the next cycle's registration, started while this cycle's job finishes
    /// (`Registering`); null registers each cycle in its turn, as tests and `--once` do.
    next: ?*?*Registering = null,
    /// This runner's place at the memory gate (`admission.zig`); null takes jobs whatever the
    /// machine's memory, as tests and `RUNNER_ADMISSION=false` do.
    gate: ?*admission.Gate = null,
};

/// Output keys cost two walks of the job's filesystem whatever the step changed, so they are cheap
/// on a small checkout and not on a large one (25 s against 1 s, STUDY.md §3.6). When a job spends
/// more than `Config.output_keys_max_ms` on them, this remembers the repository and later jobs skip
/// them, until the runner restarts. Shared by every runner in the pool.
pub const SlowOutputs = struct {
    mu: std.Io.Mutex = .init,
    io: std.Io,
    gpa: Allocator,
    /// Repository to the milliseconds that put it here.
    repos: std.StringHashMapUnmanaged(i64) = .empty,

    /// The milliseconds a job spent, when this repository is already known to be slow.
    pub fn spent(so: *SlowOutputs, repo: []const u8) ?i64 {
        so.mu.lockUncancelable(so.io);
        defer so.mu.unlock(so.io);
        return so.repos.get(repo);
    }

    /// Remembers a repository whose job went over. True the first time, so the caller logs it once.
    pub fn record(so: *SlowOutputs, repo: []const u8, ms: i64) bool {
        so.mu.lockUncancelable(so.io);
        defer so.mu.unlock(so.io);
        if (so.repos.contains(repo)) return false;
        const key = so.gpa.dupe(u8, repo) catch return false;
        so.repos.put(so.gpa, key, ms) catch {
            so.gpa.free(key);
            return false;
        };
        return true;
    }
};

fn say(c: Context, comptime fmt: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(c.arena, fmt, args);
    try c.log.say(text);
}

/// Poll responses are 202 when idle. A fresh token is minted before the old one can expire.
const token_refresh_secs = 10 * 60;

/// What one cycle did.
pub const Cycle = union(enum) {
    /// A job ran and GitHub was told; whether it succeeded.
    job: bool,
    /// No job ran (or it could not be completed): the exit code, and whether trying again could
    /// help.
    failed: struct { exit: Exit, retry: bool = true },
    /// A stop was requested while the runner waited for a job.
    stopped,
    /// The machine was short of memory before a poll (`admission.zig`): the cycle ended, and with
    /// it the registration, so GitHub does not hand a job to a runner that is not asking for one.
    held,
};

/// Runs `n` runners in this process as concurrent tasks (`std.Io.Group`), each serving jobs one
/// after another (`serve`) with its own registrations, memory per job and Dagger session per job.
/// They share the configuration, the log sinks and the database connection (all safe to share).
/// Returns once every runner has stopped: the most severe exit code among them.
pub fn pool(c: Context, n: u32) !Exit {
    const slots = try c.arena.alloc(Slot, n);
    // One per process, so what one runner learns about a repository the others use too.
    const slow = try c.arena.create(SlowOutputs);
    slow.* = .{ .io = c.io, .gpa = c.gpa };
    // One per process too, so each runner counts the others' jobs before it takes one.
    const memory: ?*admission.Admission = if (c.cfg.admission) m: {
        const m = try c.arena.create(admission.Admission);
        m.* = .init(c.io, c.cfg.admission_limits, try c.arena.alloc(admission.Admission.Slot, n));
        const cgroup = c.cfg.engine_cgroup;
        m.engine.source = if (std.mem.eql(u8, cgroup, "none"))
            .off
        else if (cgroup.len > 0)
            .{ .cgroup = cgroup }
        else
            .{ .host = c.cfg.engine_host };
        break :m m;
    } else null;
    // Measures the jobs running, for what jobs of their names reserve next; ends with the pool.
    var sampling: ?std.Io.Future(void) = if (memory) |m|
        c.io.concurrent(admission.Admission.sample, .{m}) catch null
    else
        null;
    defer if (sampling) |*f| f.cancel(c.io);
    var group: std.Io.Group = .init;
    for (slots, 0..) |*s, i| {
        s.* = .{ .c = c };
        s.c.slow_outputs = slow;
        if (memory) |m| {
            s.gate = .{ .pool = m, .slot = i };
            s.c.gate = &s.gate;
        }
        group.concurrent(c.io, Slot.main, .{s}) catch |e| {
            try c.err.print("could not start {d} runners: {s}\n", .{ n, @errorName(e) });
            group.cancel(c.io);
            return .config;
        };
    }
    if (n > 1) try say(c, "started {d} runners", .{n});
    group.await(c.io) catch {};
    var worst: Exit = .done;
    for (slots) |s| if (@backingInt(s.exit) > @backingInt(worst)) {
        worst = s.exit;
    };
    return worst;
}

/// One runner of a pool. Its error messages go through its own buffer, flushed a cycle at a time,
/// so runners' messages do not interleave mid-line.
const Slot = struct {
    c: Context,
    exit: Exit = .done,
    gate: admission.Gate = undefined,
    err_buf: [4096]u8 = undefined,

    fn main(s: *Slot) void {
        var err_w: std.Io.File.Writer = .initStreaming(.stderr(), s.c.io, &s.err_buf);
        var c = s.c;
        c.err = &err_w.interface;
        s.exit = serve(c) catch |e| blk: {
            c.err.print("runner stopped: {s}\n", .{@errorName(e)}) catch {};
            break :blk .github;
        };
        err_w.interface.flush() catch {};
    }
};

/// Runs jobs one after another: each cycle registers a fresh JIT runner (GitHub gives a JIT runner
/// a single job), waits for a job, runs it, and frees everything the cycle allocated before the
/// next. A cycle that fails before running a job is retried with a growing delay (`backoffSecs`),
/// unless GitHub rejected the registration itself (bad token or scope), which retrying cannot fix.
/// With `--once`, returns after the first cycle: 0 if its job succeeded.
pub fn serve(c: Context) !Exit {
    var ending: ?std.Io.Future(void) = null;
    defer if (ending) |*f| f.await(c.io);
    var next: ?*Registering = null;
    // A registration made for a cycle that will not run is removed, as an idle one must be.
    defer if (next) |r| r.discard(c);
    var failures: u32 = 0;
    defer if (c.gate) |g| g.leave(false);
    // The name the next cycle registers under, chosen before the memory gate so that a held runner
    // logs its own name: `c.name` is the pool's, shared by every runner of it.
    var held_name_buf: [256]u8 = undefined;
    var held_name: ?[]const u8 = null;
    while (true) {
        // The memory gate (#126): register only once the machine has the memory for one more job.
        if (c.gate) |g| if (checkGate(c, g)) |hold| {
            // A registration made while the last job finished would sit idle: a runner GitHub can
            // hand a job to, that is not asking for one.
            if (next) |r| {
                next = null;
                r.discard(c);
            }
            held_name = try runnerNameBuf(&held_name_buf, c);
            var hc = c;
            hc.name = held_name.?;
            if (!try admit(hc, g, hold)) return .done;
        };
        var cycle_arena: std.heap.ArenaAllocator = .init(c.gpa);
        defer cycle_arena.deinit();
        var cc = c;
        cc.arena = cycle_arena.allocator();
        cc.ending = &ending;
        if (!c.cfg.once) cc.next = &next;
        cc.name = if (next) |r|
            try cc.arena.dupe(u8, r.name)
        else if (held_name) |n|
            try cc.arena.dupe(u8, n)
        else
            try runnerName(cc.arena, c);
        held_name = null;

        const r = try cycle(cc);
        c.err.flush() catch {};
        // Polling is over, and so is the job if there was one: the next cycle is let through, or
        // not, afresh, and a job that ended reserves nothing any more.
        if (c.gate) |g| {
            g.leave(false);
            _ = g.ended();
        }
        if (r == .held and !stopRequested()) continue;
        if (c.cfg.once) return switch (r) {
            .job => |ok| if (ok) .done else .github,
            .failed => |f| f.exit,
            .stopped, .held => .done,
        };
        if (r == .stopped or r == .held or stopRequested()) return .done;
        switch (r) {
            .job => failures = 0,
            .stopped, .held => unreachable,
            .failed => |f| {
                if (!f.retry) return f.exit;
                failures += 1;
                const wait = backoffSecs(failures);
                try c.err.print(
                    "trying again in {d}s ({d} failed attempt(s) in a row)\n",
                    .{ wait, failures },
                );
                try c.err.flush();
                // In steps, so a stop is not kept waiting.
                var waited: u32 = 0;
                while (waited < wait * 5 and !stopRequested()) : (waited += 1) {
                    c.io.sleep(.fromMilliseconds(200), .awake) catch {};
                }
                if (stopRequested()) return .done;
            },
        }
    }
}

/// Waits, held at the memory gate for `hold`, until the machine has the memory for one more job:
/// true then, false if a stop is requested first. The hold and its end are each logged once, not
/// at every look.
fn admit(c: Context, g: *admission.Gate, hold: admission.Hold) !bool {
    holdingBack(c, g, hold);
    while (true) {
        // In steps, so a stop is not kept waiting.
        var left = g.pool.recheck.toMilliseconds();
        while (left > 0) : (left -= @min(left, 200)) {
            if (stopRequested()) return false;
            c.io.sleep(.fromMilliseconds(@min(left, 200)), .awake) catch {};
        }
        if (stopRequested()) return false;
        if (checkGate(c, g) == null) break;
    }
    sayUnallocated(c, "'{s}': memory is back; taking jobs again", .{c.name});
    g.announced = false;
    return true;
}

/// `Gate.check`, and what it learned about the engine's cgroup when that changed: found at start,
/// or not and why, which tells an operator whether the engine's cap is being watched.
fn checkGate(c: Context, g: *admission.Gate) ?admission.Hold {
    const hold = g.check();
    var buf: [512]u8 = undefined;
    if (g.pool.engineNews(&buf)) |news| sayUnallocated(c, "{s}", .{news});
    return hold;
}

/// Logs a hold, unless this one already was (`listen` finds it, `admit` waits it out).
fn holdingBack(c: Context, g: *admission.Gate, hold: admission.Hold) void {
    if (g.announced) return;
    sayUnallocated(c, "'{s}' holding back from new jobs: {f}", .{ c.name, hold });
    g.announced = true;
}

/// As `say`, on the stack: `serve`'s context has the process's arena, which a line for every hold
/// would grow for as long as the runner runs.
fn sayUnallocated(c: Context, comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
    c.log.say(text) catch {};
}

/// A new registration name: the prefix and a random suffix.
fn runnerName(arena: Allocator, c: Context) ![]const u8 {
    var buf: [256]u8 = undefined;
    return arena.dupe(u8, try runnerNameBuf(&buf, c));
}

fn runnerNameBuf(buf: []u8, c: Context) ![]const u8 {
    var suffix: [4]u8 = undefined;
    c.io.random(&suffix);
    return std.fmt.bufPrint(buf, "{s}-{x}", .{ c.cfg.name_prefix, suffix });
}

/// The next cycle's JIT registration, made in the background while this cycle's job finishes
/// (completing it with GitHub, uploading its logs), so the next cycle can listen at once instead
/// of first waiting for GitHub to register it (about 0.7 s) and then for a token and a broker
/// session (about 0.2 s more). It is started only once a job's steps are done, so it is never left
/// waiting through a long job, and it outlives the cycle whose arena `serve` frees, so it has
/// memory of its own.
///
/// The session is the new runner's own, so it never meets the session of the runner finishing its
/// job (each JIT registration is a runner of its own, with its own agent id). A session that could
/// not be opened here is opened by the cycle, which reports why if it fails again. Whoever ends up
/// with the session deletes it exactly once: the cycle (through its `Ending`) once it took it over,
/// or `discard` when no cycle does (the runner stopping).
pub const Registering = struct {
    arena: std.heap.ArenaAllocator,
    c: Context,
    name: []const u8,
    future: std.Io.Future(void) = undefined,
    /// GitHub's calls, replaced in tests.
    calls: Calls = .{},
    result: union(enum) {
        pending,
        ok: jitconfig.Jit,
        failed: struct { err: anyerror, status: std.http.Status, message: []const u8 },
    } = .pending,
    /// The registered runner's broker session, when it could be opened.
    session: ?Session = null,

    const Calls = struct {
        generate: *const @TypeOf(jitconfig.generate) = jitconfig.generate,
        remove: *const fn (Context, u64, []const u8) void = removeRegistration,
        open: *const fn (Context, jitconfig.Jit) ?Session = openSession,
        delete: *const fn (Context, []const u8, []const u8, []const u8) void = deleteSession,
    };

    /// What the next cycle takes over: copied into its arena.
    const Taken = struct { result: @FieldType(Registering, "result"), session: ?Session };

    fn start(c: Context) !*Registering {
        return startWith(c, .{});
    }

    fn startWith(c: Context, calls: Calls) !*Registering {
        const r = try c.gpa.create(Registering);
        errdefer c.gpa.destroy(r);
        r.* = .{ .arena = .init(c.gpa), .c = c, .name = undefined, .calls = calls };
        errdefer r.arena.deinit();
        const a = r.arena.allocator();
        r.name = try runnerName(a, c);
        r.c.arena = a;
        r.c.name = r.name;
        r.c.ending = null;
        r.c.next = null;
        r.future = try c.io.concurrent(run, .{r});
        return r;
    }

    fn run(r: *Registering) void {
        var status: std.http.Status = .ok;
        var message: []const u8 = "";
        r.result = if (r.calls.generate(r.c.arena, r.c.io, r.c.cfg, r.name, &status, &message)) |jit|
            .{ .ok = jit }
        else |e|
            .{ .failed = .{ .err = e, .status = status, .message = message } };
        // A runner that is stopping takes nothing over: no session to open, only to delete.
        if (r.result == .ok and !stopRequested()) r.session = r.calls.open(r.c, r.result.ok);
    }

    /// The registration and its session, copied into `arena` (the cycle's); this is freed. When
    /// they cannot be copied, they are removed rather than left behind.
    fn take(r: *Registering, arena: Allocator) !Taken {
        r.future.await(r.c.io);
        defer r.free();
        errdefer r.end();
        return .{
            .result = switch (r.result) {
                .pending => unreachable,
                .ok => |jit| .{ .ok = try copyJit(arena, jit) },
                .failed => |f| .{ .failed = .{
                    .err = f.err,
                    .status = f.status,
                    .message = try arena.dupe(u8, f.message),
                } },
            },
            .session = if (r.session) |s| try s.copy(arena) else null,
        };
    }

    /// Never used: waited for, and its session and registration removed.
    fn discard(r: *Registering, c: Context) void {
        r.future.await(c.io);
        r.end();
        r.free();
    }

    /// Deletes the session, then the registration, as a cycle's `Ending` does.
    fn end(r: *Registering) void {
        if (r.session) |s| r.calls.delete(r.c, s.base, s.sid, s.token);
        if (r.result == .ok) r.calls.remove(r.c, r.result.ok.runner_id, r.result.ok.runner_name);
    }

    fn free(r: *Registering) void {
        const gpa = r.c.gpa;
        r.arena.deinit();
        gpa.destroy(r);
    }
};

/// A runner's broker session, open, with the token it was opened with.
const Session = struct {
    /// The broker's URL, with a trailing slash.
    base: []const u8,
    sid: []const u8,
    token: []const u8,
    /// When `token` was minted, in seconds (see `token_refresh_secs`).
    token_at: i64,

    fn copy(s: Session, arena: Allocator) !Session {
        return .{
            .base = try arena.dupe(u8, s.base),
            .sid = try arena.dupe(u8, s.sid),
            .token = try arena.dupe(u8, s.token),
            .token_at = s.token_at,
        };
    }
};

/// Opens a session for a registered runner, as `cycle` does, for `Registering`; null when any step
/// fails (the cycle then tries again and reports what went wrong).
fn openSession(c: Context, jit: jitconfig.Jit) ?Session {
    const creds = auth.parseCredentials(c.arena, jit.files) catch return null;
    const settings = broker.parseSettings(c.arena, jit.files) catch return null;
    var status: std.http.Status = .ok;
    const token = mintToken(c, creds, &status) catch return null;
    const token_at = std.Io.Clock.real.now(c.io).toSeconds();
    const base = withSlash(c.arena, settings.broker_url) catch return null;
    const url = std.fmt.allocPrint(c.arena, "{s}session", .{base}) catch return null;
    const body = broker.sessionBody(c.arena, settings, "zig-runner") catch return null;
    const created = broker.call(c.arena, c.io, .POST, url, token, body) catch return null;
    if (created.status.class() != .success) return null;
    const sid = jsonString(c.arena, created.body, "sessionId") orelse return null;
    return .{ .base = base, .sid = sid, .token = token, .token_at = token_at };
}

fn copyJit(arena: Allocator, jit: jitconfig.Jit) !jitconfig.Jit {
    const files = try arena.alloc(jitconfig.File, jit.files.len);
    for (jit.files, files) |f, *o| o.* = .{ .name = try arena.dupe(u8, f.name), .content = try arena.dupe(u8, f.content) };
    return .{ .runner_id = jit.runner_id, .runner_name = try arena.dupe(u8, jit.runner_name), .files = files };
}

/// Seconds to wait after `failures` failed cycles in a row: 5, 10, 20, ... up to 5 minutes.
pub fn backoffSecs(failures: u32) u32 {
    if (failures == 0) return 0;
    const shift: u5 = @intCast(@min(failures - 1, 6));
    return @min(@as(u32, 5) << shift, 300);
}

const Polled = union(enum) { poll: anyerror!broker.Response, stop: void, timeout: void };

/// How long a poll may go unanswered. The broker answers within about 50 s, with a message or
/// without one; a connection that died under the poll is never answered at all. A laptop that slept
/// for 40 minutes woke with every runner waiting on such a connection, listening as far as it knew
/// and offline as far as GitHub knew, until the runner was restarted.
pub const poll_timeout: std.Io.Duration = .fromSeconds(90);

/// One long poll for a message (it can take about 50 s), given up as soon as a stop is requested or
/// `timeout` passes: the poll runs next to a watcher and a timer, and whichever ends first cancels
/// the others (a blocked read is interrupted, and its connection is not reused). The cycle's
/// cleanup then deletes the session and the registration.
fn poll(c: Context, url: []const u8, token: []const u8, timeout: std.Io.Duration) !Polled {
    var buf: [3]Polled = undefined;
    var sel: std.Io.Select(Polled) = .init(c.io, &buf);
    // A task that could not start must not leave the ones that did running on `buf`.
    errdefer while (sel.cancel()) |_| {};
    try sel.concurrent(.poll, pollOnce, .{ c.arena, c.io, url, token });
    try sel.concurrent(.stop, waitForStop, .{c});
    try sel.concurrent(.timeout, waitFor, .{ c.io, timeout });
    const first = sel.await() catch Polled{ .stop = {} };
    while (sel.cancel()) |_| {}
    return first;
}

fn waitFor(io: std.Io, timeout: std.Io.Duration) void {
    io.sleep(timeout, .awake) catch {};
}

fn pollOnce(
    arena: Allocator,
    io: std.Io,
    url: []const u8,
    token: []const u8,
) anyerror!broker.Response {
    // No deadline of its own: `poll`'s timer is it.
    return broker.request(arena, io, .GET, url, null, .{ .token = token, .deadline = null });
}

var stop_announced: std.atomic.Value(bool) = .init(false);

fn waitForStop(c: Context) void {
    while (!stopRequested()) c.io.sleep(.fromMilliseconds(200), .awake) catch return;
    if (stop_announced.swap(true, .acq_rel)) return;
    // On the stack. (The cycle's arena would do even with the poll using it at the same time: std's
    // ArenaAllocator is thread-safe over a thread-safe gpa.)
    sayUnallocated(
        c,
        "stopping: waiting runners stop now, running jobs get {d} s to finish before they are " ++
            "cancelled (a second signal exits at once)",
        .{c.cfg.stop_grace_secs},
    );
}

/// Deletes the cycle's runner registration, trying again (after 1 s, then 2 s) when GitHub refuses
/// for now (422 right after a job, 5xx) or the request fails; a registration still left is reported
/// instead of being dropped silently. 404: already gone.
fn removeRegistration(c: Context, id: u64, name: []const u8) void {
    var last: []const u8 = "";
    for (0..3) |attempt| {
        if (attempt > 0)
            c.io.sleep(.fromMilliseconds(@as(i64, @intCast(attempt)) * 1000), .awake) catch {};
        if (jitconfig.deleteRunner(c.arena, c.io, c.cfg, id)) |status| {
            const code = @backingInt(status);
            if (status.class() == .success or code == 404) return;
            last = std.fmt.allocPrint(c.arena, "HTTP {d}", .{code}) catch "HTTP error";
            if (code != 422 and status.class() != .server_error) break;
        } else |e| last = @errorName(e);
    }
    // Through the log, not `c.err`: this can run in the background while the runner's next cycle
    // writes to its own buffer.
    say(
        c,
        "could not remove runner registration '{s}' (id {d}): {s}; " ++
            "delete it in the repository's runner settings",
        .{ name, id, last },
    ) catch {};
}

/// What a cycle leaves behind: its registration and, once it had one, its broker session.
const Ending = struct {
    id: u64,
    name: []const u8,
    session: ?struct { base: []const u8, sid: []const u8 } = null,
    token: []const u8 = "",

    fn now(e: Ending, c: Context) void {
        if (e.session) |s| deleteSession(c, s.base, s.sid, e.token);
        removeRegistration(c, e.id, e.name);
    }
};

/// Ends a cycle: deletes its session, then its registration (GitHub removes an ephemeral runner
/// once its job completes; an idle one must be removed). In a pool this runs in the background, so
/// the next cycle registers at once instead of after both answer (0.65 s between jobs). The previous
/// cycle's ending, long finished by then, is awaited first, and `serve` awaits the last.
fn endCycle(c: Context, e: Ending) void {
    const slot = c.ending orelse return e.now(c);
    if (slot.*) |*f| f.await(c.io);
    slot.* = null;
    slot.* = EndingTask.start(c, e) catch return e.now(c);
}

/// An `Ending` run in a task of its own. It outlives the cycle, whose arena `serve` frees, so it
/// keeps copies of what it needs in memory of its own, freed when it is done.
const EndingTask = struct {
    arena: std.heap.ArenaAllocator,
    c: Context,
    e: Ending,

    fn start(c: Context, e: Ending) !std.Io.Future(void) {
        const t = try c.gpa.create(EndingTask);
        errdefer c.gpa.destroy(t);
        t.arena = .init(c.gpa);
        errdefer t.arena.deinit();
        const a = t.arena.allocator();
        t.e = .{
            .id = e.id,
            .name = try a.dupe(u8, e.name),
            .token = try a.dupe(u8, e.token),
            .session = if (e.session) |s|
                .{ .base = try a.dupe(u8, s.base), .sid = try a.dupe(u8, s.sid) }
            else
                null,
        };
        t.c = c;
        t.c.arena = a;
        t.c.name = t.e.name;
        t.c.ending = null;
        return c.io.concurrent(run, .{t});
    }

    fn run(t: *EndingTask) void {
        const gpa = t.c.gpa;
        t.e.now(t.c);
        t.arena.deinit();
        gpa.destroy(t);
    }
};

/// One registration and at most one job.
pub fn cycle(c: Context) !Cycle {
    var status: std.http.Status = .ok;
    var message: []const u8 = "";
    // Made while the previous job finished, when there was one (`Registering`).
    const early: ?*Registering = if (c.next) |slot| slot.* else null;
    if (c.next) |slot| slot.* = null;
    // Its session too, when it could open one.
    var opened: ?Session = null;
    const jit = if (early) |r| taken: {
        const t = try r.take(c.arena);
        opened = t.session;
        break :taken switch (t.result) {
            .pending => unreachable,
            .ok => |j| j,
            .failed => |f| return registrationFailed(c, f.err, f.status, f.message),
        };
    } else jitconfig.generate(c.arena, c.io, c.cfg, c.name, &status, &message) catch |e|
        return registrationFailed(c, e, status, message);
    // Read when the cycle ends: the session once there is one, and the latest token. A session
    // taken over is the cycle's from here on, whatever happens next.
    var token: []const u8 = if (opened) |o| o.token else "";
    var session: @FieldType(Ending, "session") =
        if (opened) |o| .{ .base = o.base, .sid = o.sid } else null;
    defer endCycle(c, .{
        .id = jit.runner_id,
        .name = jit.runner_name,
        .session = session,
        .token = token,
    });
    try say(c, "registered runner '{s}' (id {d})", .{ jit.runner_name, jit.runner_id });

    const creds = auth.parseCredentials(c.arena, jit.files) catch |e|
        return fail(c, "credentials", e);
    var token_at: i64 = undefined;
    var base: []const u8 = undefined;
    var sid: []const u8 = undefined;
    if (opened) |o| {
        token_at = o.token_at;
        base = o.base;
        sid = o.sid;
    } else {
        const settings = broker.parseSettings(c.arena, jit.files) catch |e|
            return fail(c, "runner settings", e);
        token = mintToken(c, creds, &status) catch |e|
            return failHttp(c, "oauth token", e, status);
        token_at = std.Io.Clock.real.now(c.io).toSeconds();

        base = try withSlash(c.arena, settings.broker_url);
        const session_url = try std.fmt.allocPrint(c.arena, "{s}session", .{base});
        const session_body = try broker.sessionBody(c.arena, settings, "zig-runner");
        const created = broker.call(c.arena, c.io, .POST, session_url, token, session_body) catch |e|
            return fail(c, "create session", e);
        if (created.status.class() != .success) return failBody(c, "create session", created);
        sid = jsonString(c.arena, created.body, "sessionId") orelse
            return fail(c, "create session", error.BadResponse);
        session = .{ .base = base, .sid = sid };
    }
    try say(c, "'{s}' listening for jobs (labels: {s})", .{ c.name, c.cfg.labels });
    return listen(c, creds, base, sid, &token, &token_at);
}

/// Polls the session until a job comes, and runs it. Before each poll the runner checks that the
/// machine still has the memory for a job (`admission.zig`); when it does not, the cycle ends
/// rather than sit registered and silent, and `serve` waits for memory before registering again.
/// `token` is kept fresh for the cycle's end, which deletes the session with it.
fn listen(
    c: Context,
    creds: auth.Credentials,
    base: []const u8,
    sid: []const u8,
    token: *[]const u8,
    token_at: *i64,
) !Cycle {
    var status: std.http.Status = .ok;
    while (true) {
        if (stopRequested()) return .stopped;
        if (c.gate) |g| if (checkGate(c, g)) |hold| {
            holdingBack(c, g, hold);
            return .held;
        };
        const now = std.Io.Clock.real.now(c.io).toSeconds();
        if (now - token_at.* > token_refresh_secs) {
            token.* = mintToken(c, creds, &status) catch |e|
                return failHttp(c, "oauth token refresh", e, status);
            token_at.* = now;
        }
        const url = try broker.messageUrl(c.arena, base, sid, "Online");
        const m = switch (try poll(c, url, token.*, poll_timeout)) {
            .stop => return .stopped,
            .timeout => {
                // Not a failure: the next poll goes out on a new connection. If the session did
                // not survive what killed this one, that poll fails and the cycle starts afresh.
                try say(c, "'{s}': no answer to a poll in {d} s; polling again", .{
                    c.name,
                    @divTrunc(poll_timeout.nanoseconds, std.time.ns_per_s),
                });
                continue;
            },
            .poll => |r| r catch |e| return fail(c, "poll", e),
        };
        if (m.status == .accepted or (m.status.class() == .success and m.body.len == 0)) continue;
        if (m.status.class() != .success) return failBody(c, "poll", m);

        const mtype = jsonString(c.arena, m.body, "messageType") orelse "";
        if (!std.mem.eql(u8, mtype, "RunnerJobRequest")) {
            try say(c, "ignoring message of type '{s}'", .{mtype});
            continue;
        }
        const inner = jsonString(c.arena, m.body, "body") orelse
            return fail(c, "job request", error.BadResponse);
        // Its memory is reserved in the other runners' checks while it ramps up.
        if (c.gate) |g| g.leave(true);
        return handleJob(c, .{
            .creds = creds,
            .token = token.*,
            .token_at = token_at.*,
            .url = try broker.messageUrl(c.arena, base, sid, "Busy"),
        }, inner);
    }
}

/// Why the runner could not be registered, with what the token must allow when GitHub refused it.
/// Rejected credentials or scope will be rejected again; anything else may be transient.
fn registrationFailed(
    c: Context,
    e: anyerror,
    status: std.http.Status,
    message: []const u8,
) !Cycle {
    try c.err.writeAll("github error: ");
    try redact.write(c.err, @errorName(e), c.secrets);
    try c.err.print(" (HTTP {d})", .{@backingInt(status)});
    if (message.len > 0) {
        try c.err.writeAll(": ");
        try redact.write(c.err, message, c.secrets);
    }
    if (@backingInt(status) == 403 or @backingInt(status) == 404)
        try c.err.writeAll("\n  GH_TOKEN must be able to manage self-hosted runners of " ++
            "GH_SCOPE: a fine-grained token with \"Administration: read and write\" " ++
            "on the repository (\"Self-hosted runners: read and write\" for an organization), " ++
            "or a classic token with repo (admin:org)");
    try c.err.writeByte('\n');
    const fatal = switch (@backingInt(status)) {
        401, 403, 404, 422 => true,
        else => false,
    };
    return .{ .failed = .{ .exit = .github, .retry = !fatal } };
}

/// `url` with one trailing slash, so paths can be appended to it.
fn withSlash(arena: Allocator, url: []const u8) ![]const u8 {
    if (std.mem.endsWith(u8, url, "/")) return url;
    return std.fmt.allocPrint(arena, "{s}/", .{url});
}

/// Ends the broker session; best effort, on the way out.
fn deleteSession(c: Context, base: []const u8, sid: []const u8, token: []const u8) void {
    const url = std.fmt.allocPrint(c.arena, "{s}session?sessionId={s}", .{ base, sid }) catch "";
    _ = broker.call(c.arena, c.io, .DELETE, url, token, null) catch {};
}

/// Writes run state at the transitions SPEC §5.2 names: job start, step start, step end, job end.
/// Database errors are counted and reported at the end; they never fail the job.
const Reporter = struct {
    store: *db.Store,
    arena: Allocator,
    io: std.Io,
    job_id: u64,
    run_id: u64,
    /// A write that fails is not reported where it is made (`catch {}` below): the store counts
    /// it, since with its writer a row fails after the call that queued it has returned, and
    /// `finishReporter` reports how many failed since this count, taken when the job started.
    failed_before: u64 = 0,

    fn observer(r: *Reporter) dagger.Observer {
        return .{ .ptr = r, .startedFn = stepStartedFn, .finishedFn = stepFinishedFn };
    }

    fn iso(r: *Reporter, ms: i64) ?[]const u8 {
        if (ms <= 0) return null;
        return timefmt.isoTime(r.arena, ms) catch null;
    }

    /// Writes that failed since the job started (any runner's: they share the database).
    fn failures(r: *Reporter) u64 {
        return r.store.failed.load(.monotonic) -| r.failed_before;
    }

    fn stepStartedFn(ptr: *anyopaque, number: u32, name: []const u8, started_ms: i64) void {
        const r: *Reporter = @ptrCast(@alignCast(ptr));
        r.store.upsertStep(.{
            .job_id = r.job_id,
            .number = number,
            .name = name,
            .status = "in_progress",
            .started_at = r.iso(started_ms),
        }) catch {};
    }

    fn stepFinishedFn(ptr: *anyopaque, number: u32, res: dagger.StepResult) void {
        const r: *Reporter = @ptrCast(@alignCast(ptr));
        r.store.upsertStep(.{
            .job_id = r.job_id,
            .number = number,
            .name = res.name,
            .status = "completed",
            .conclusion = stepConclusion(res),
            .started_at = r.iso(res.started_ms),
            .completed_at = r.iso(res.completed_ms),
        }) catch {};
    }

    fn jobStarted(r: *Reporter, job: job_mod.Job, runner_name: []const u8, now_ms: i64) void {
        const g = job.github;
        r.store.upsertRun(.{
            .id = r.run_id,
            .repo = g.repository,
            .workflow = if (g.workflow.len > 0) g.workflow else "(unknown)",
            .event = nonEmpty(g.event_name),
            .branch = nonEmpty(g.ref_name),
            .sha = nonEmpty(g.sha),
            .status = "in_progress",
        }) catch {};
        r.store.upsertJob(.{
            .id = r.job_id,
            .run_id = r.run_id,
            .name = jobName(job),
            .runner_name = runner_name,
            .status = "in_progress",
            .started_at = r.iso(now_ms),
        }) catch {};
        // Step 0 is "Set up job" (db/migrations/001_init.sql): registration, acquiring and parsing.
        r.store.upsertStep(.{
            .job_id = r.job_id,
            .number = 0,
            .name = "Set up job",
            .status = "completed",
            .conclusion = "success",
            .started_at = r.iso(now_ms),
            .completed_at = r.iso(now_ms),
        }) catch {};
    }

    /// "Set up job" failed after all: the job failed before its steps (refused, unsupported, or an
    /// action that could not be resolved). `jobStarted` recorded it as a success, as it is for
    /// every job that reaches its steps; GitHub shows it failed, and so must the database.
    fn setUpFailed(r: *Reporter, started_ms: i64, now_ms: i64) void {
        r.store.upsertStep(.{
            .job_id = r.job_id,
            .number = 0,
            .name = "Set up job",
            .status = "completed",
            .conclusion = "failure",
            .started_at = r.iso(started_ms),
            .completed_at = r.iso(now_ms),
        }) catch {};
    }

    fn jobFinished(
        r: *Reporter,
        job: job_mod.Job,
        runner_name: []const u8,
        conclusion: []const u8,
        started_ms: i64,
        now_ms: i64,
    ) void {
        r.store.upsertJob(.{
            .id = r.job_id,
            .run_id = r.run_id,
            .name = jobName(job),
            .runner_name = runner_name,
            .status = "completed",
            .conclusion = conclusion,
            .started_at = r.iso(started_ms),
            .completed_at = r.iso(now_ms),
        }) catch {};
        // One runner handles one job, so the run's state follows this job (SPEC §5.2).
        const g = job.github;
        r.store.upsertRun(.{
            .id = r.run_id,
            .repo = g.repository,
            .workflow = if (g.workflow.len > 0) g.workflow else "(unknown)",
            .event = nonEmpty(g.event_name),
            .branch = nonEmpty(g.ref_name),
            .sha = nonEmpty(g.sha),
            .status = "completed",
            .conclusion = conclusion,
            .completed_at = r.iso(now_ms),
        }) catch {};
    }
};

fn nonEmpty(s: []const u8) ?[]const u8 {
    return if (s.len == 0) null else s;
}

fn jobName(job: job_mod.Job) []const u8 {
    if (job.display_name.len > 0) return job.display_name;
    if (job.github.job.len > 0) return job.github.job;
    return "job";
}

/// Same vocabulary as the DB's `steps.conclusion`: success | failure | cancelled | skipped.
fn stepConclusion(res: dagger.StepResult) []const u8 {
    return switch (res.outcome) {
        .success => "success",
        .failure => if (res.continued) "success" else "failure",
        .cancelled => "cancelled",
        .skipped, .not_run => "skipped",
    };
}

/// The runner's session, kept listening while a job runs (see `CancelWatch`).
const Listening = struct {
    creds: auth.Credentials,
    token: []const u8,
    token_at: i64,
    /// The broker's message URL, with the runner `Busy`.
    url: []const u8,
};

/// Whether `repo`'s jobs have spent too long on output keys lately (see `SlowOutputs`).
fn slowOutputs(c: Context, repo: []const u8) bool {
    const so = c.slow_outputs orelse return false;
    return so.spent(repo) != null;
}

/// Waits before each further acquire, in milliseconds: 15.5 s in all.
const acquire_retry_ms = [_]i64{ 500, 1000, 2000, 4000, 8000 };

/// Acquires the job, trying again while the request fails or GitHub answers 5xx. A job whose
/// acquire failed stays assigned to this runner until GitHub gives it to another, about 70 s later:
/// three jobs whose acquires failed at once with HostUnreachable started 72 s after the rest.
fn acquire(
    c: Context,
    jr: runservice.JobRequest,
    token: []const u8,
    retry_ms: []const i64,
) !broker.Response {
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        const last = attempt == retry_ms.len or stopRequested();
        if (runservice.acquire(c.arena, c.io, jr, token)) |r| {
            if (last or r.status.class() != .server_error) return r;
            try say(c, "'{s}': acquirejob answered HTTP {d}; trying again", .{
                c.name,
                @backingInt(r.status),
            });
        } else |e| {
            if (last or e == error.OutOfMemory) return e;
            try say(c, "'{s}': acquirejob failed ({s}); trying again", .{ c.name, @errorName(e) });
        }
        c.io.sleep(.fromMilliseconds(retry_ms[attempt]), .awake) catch {};
    }
}

fn handleJob(c: Context, session: Listening, body: []const u8) !Cycle {
    const runner_token = session.token;
    const jr = runservice.parseJobRequest(c.arena, body) catch |e| return fail(c, "job request", e);
    const acq = acquire(c, jr, runner_token, &acquire_retry_ms) catch |e|
        return fail(c, "acquirejob", e);
    if (acq.status.class() != .success) return failBody(c, "acquirejob", acq);

    // The definition holds secrets; it is parsed but never printed.
    const job = job_mod.parse(c.arena, acq.body) catch |e| return fail(c, "parse job", e);
    // Known by name now: it reserves what jobs of its name took (`admission.Learned`), and what it
    // takes is learned when it ends.
    const job_name = if (job.display_name.len > 0) job.display_name else job.github.job;
    const g = job.github;
    if (c.gate) |gate| gate.assigned(admission.jobKey(g.repository, g.workflow_ref, job_name));
    defer if (c.gate) |gate| if (gate.ended()) |learned| sayUnallocated(
        c,
        "job '{s}' raised the engine's memory by {f} at most ({s}); reserving {f} for it while " ++
            "it starts",
        .{
            job_name,
            admission.gb(learned.seen_mb),
            if (learned.alone) "alone" else "beside other jobs",
            admission.gb(learned.estimate_mb),
        },
    );

    // GitHub cancels a job (in its UI, or at the job's timeout-minutes) through the runner's
    // session.
    var cancel: dagger.Cancel = .{};
    // Keep the hold on the job while it runs, as GitHub's runner does (see `Renewer`).
    var renewer = Renewer.init(c, job, jr, &cancel);
    var renewing: ?std.Io.Future(void) = c.io.concurrent(Renewer.run, .{&renewer}) catch null;
    // Cancelled rather than waited for: it sleeps in 50 ms steps, and the job's end (and the
    // runner's next session) waited out the rest of one, 25 ms a job on average.
    defer if (renewing) |*f| {
        renewer.stop.store(true, .release);
        f.cancel(c.io);
    };
    var watcher = CancelWatch.init(c, session, job, &cancel);
    var watching: ?std.Io.Future(void) = c.io.concurrent(CancelWatch.run, .{&watcher}) catch null;
    defer if (watching) |*f| {
        watcher.stop.store(true, .release);
        f.cancel(c.io);
    };
    // The runner stopping cancels the job too, once it has had its time to finish.
    var deadline: StopDeadline = .{ .c = c, .cancel = &cancel, .log_job = job.check_run_id };
    var stopping: ?std.Io.Future(void) = c.io.concurrent(StopDeadline.run, .{&deadline}) catch
        null;
    defer if (stopping) |*f| {
        deadline.stop.store(true, .release);
        f.cancel(c.io);
    };
    // Everything the job logs is also kept (redacted, timestamped) so it can be uploaded to GitHub.
    var collect: sink.LogSink = .{ .collect = .{ .arena = c.arena, .io = c.io, .inner = c.log } };
    // Each secret in every form it can take in output (redact.forms): a multi-line one line by line.
    collect.setSecrets(try redact.expand(c.arena, try std.mem.concat(c.arena, []const u8, &.{ c.secrets, job.secrets })));
    const log = &collect;
    const spool = try openSpool(c, job, &collect);
    defer if (spool) |sp| sp.close(c.io);
    // The job, live in GitHub's UI: its steps as they run and their lines as they are logged.
    var live = try Live.init(c.gpa, c.arena, c.io, &job, c.log);
    collect.collect.listener = live.listener();
    live.start(std.Io.Clock.real.now(c.io).toMilliseconds());
    var live_done = false;
    defer if (!live_done) {
        collect.collect.listener = null;
        live.finish(&.{});
    };
    // Each step's log goes up as the step finishes; lines and step events go on to the live view.
    var step_logs = try StepLogs.init(c.gpa, c.io, &job, live.ids, live.listener(), live.observer());
    collect.collect.listener = step_logs.listener();
    defer {
        collect.collect.listener = null;
        step_logs.deinit();
    }
    // For the runner's own console and database only: the job's log starts as GitHub's does.
    try sayJob(c.log, c.arena, job, "job acquired: {d} steps", .{job.steps.len});

    const job_started_ms = std.Io.Clock.real.now(c.io).toMilliseconds();
    var reporter = try startReporter(c, job, job_started_ms);
    const result = try runJobSteps(c, job, log, &cancel, &live, &step_logs, if (reporter) |*r| r else null);
    // The steps are done: register the next runner, and open its session, while this job is
    // wrapped up.
    if (c.next) |slot| if (slot.* == null and !stopRequested()) {
        slot.* = Registering.start(c) catch null;
    };

    const completion = try logCompleteJob(c, job, log, &live, result, job_started_ms);
    if (reporter) |*r| {
        try finishReporter(c, r, job, result, job_started_ms);
    }
    try reportCacheAndKeys(c, job, log, result);
    const shown = try shownSteps(c.arena, live.ids, job, result, job_started_ms, completion);
    const kept = log.collect.kept();
    {
        // The live view ends with the steps as completejob reports them, while the logs go up:
        // its last requests (the lines left, the final step list) and the uploads are
        // independent, as GitHub's runner sends its timeline and its logs from queues of their
        // own, and both are done before completejob. One after the other, the job's end waited
        // for both.
        const finals = try liveFinals(c.arena, shown);
        live_done = true;
        collect.collect.listener = null;
        var finishing: ?std.Io.Future(void) = c.io.concurrent(Live.finish, .{ &live, finals }) catch
            null;
        defer if (finishing) |*f| f.await(c.io);
        if (finishing == null) live.finish(finals);
        try uploadLogs(c, job, shown, &kept, result.summaries, log.currentSecrets(), &step_logs, .{});
    }

    const conclusion = jobConclusion(result);
    if (try completeJobWithRetry(c, jr, job, conclusion, shown, result, log.currentSecrets())) |failed| return failed;
    try sayJob(log, c.arena, job, "job {s}", .{@tagName(conclusion)});
    return .{ .job = result.succeeded };
}

/// A line in the job's log, under its "Set up job" step, as `std.fmt` writes it.
fn sayJob(
    log: *sink.LogSink,
    arena: Allocator,
    job: job_mod.Job,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    try log.append(job.check_run_id, 0, .stdout, try std.fmt.allocPrint(arena, fmt, args));
}

/// The run-state rows at the job's end, and a note when any of its writes failed.
fn finishReporter(
    c: Context,
    r: *Reporter,
    job: job_mod.Job,
    result: dagger.Result,
    job_started_ms: i64,
) !void {
    const ended_ms = std.Io.Clock.real.now(c.io).toMilliseconds();
    recordFinished(r, job, c.name, result, job_started_ms, ended_ms);
    const failed = r.failures();
    if (failed > 0) try c.err.print(
        "run state: {d} database write(s) failed while this job ran (last: {s})\n",
        .{ failed, r.store.lastError(c.arena) },
    );
}

/// The job's end in the run-state database: its conclusion, and "Set up job" failed when the job
/// failed before its steps.
fn recordFinished(
    r: *Reporter,
    job: job_mod.Job,
    runner_name: []const u8,
    result: dagger.Result,
    started_ms: i64,
    ended_ms: i64,
) void {
    if (result.set_up_failed) r.setUpFailed(started_ms, ended_ms);
    r.jobFinished(job, runner_name, reporterConclusion(result), started_ms, ended_ms);
}

test "integration: a job failed before its steps is recorded with Set up job failed" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var sc = try @import("dbtest.zig").Scratch.create(arena);
    defer sc.destroy();
    var store = try db.Store.open(std.testing.allocator, std.testing.io, sc.cfg, sc.schema);
    defer store.close();

    const job: job_mod.Job = .{
        .plan_id = "p",
        .job_id = "j",
        .job_token = "t",
        .check_run_id = 7,
        .secrets = &.{},
        .steps = &.{},
        .github = .{ .repository = "o/r", .run_id = "42", .workflow = "ci", .event_name = "pull_request" },
    };
    var r: Reporter = .{ .store = &store, .arena = arena, .io = std.testing.io, .job_id = 7, .run_id = 42 };
    const started: i64 = 1_760_000_000_000;
    r.jobStarted(job, "zig-1", started);
    // Recorded as a success when the job starts, as for every job that reaches its steps.
    try std.testing.expectEqualStrings("success", try sc.scalar("select conclusion from steps where job_id = 7 and number = 0"));

    recordFinished(&r, job, "zig-1", try failedInSetUp(arena, 0), started, started + 500);
    try std.testing.expectEqual(@as(u64, 0), r.failures());
    try std.testing.expectEqualStrings("failure", try sc.scalar("select conclusion from steps where job_id = 7 and number = 0"));
    try std.testing.expectEqualStrings("completed/failure", try sc.scalar("select status || '/' || conclusion from jobs where id = 7"));
}

/// What completejob is told: cancelled first, then whether every step that had to succeed did.
fn jobConclusion(result: dagger.Result) runservice.Conclusion {
    if (result.cancelled) return .canceled;
    if (result.succeeded) return .succeeded;
    return .failed;
}

/// The job's log on disk while it runs, rather than in memory until it ends: it is then bounded by
/// the spool and survives the process (see `sink.Spool`). Best effort — a directory the runner
/// cannot write to is said once and the lines stay in memory, because logging must not fail a job.
/// Null when no spool directory is configured or the file could not be made. It lives on the
/// cycle's arena so the collector can be pointed at it here, where it cannot be forgotten: the
/// first extraction of handleJob dropped that one line, and only an unused-parameter error caught
/// it.
const JobSpool = struct {
    spool: sink.Spool,
    path: []const u8,

    fn close(sp: *JobSpool, io: std.Io) void {
        sp.spool.file.close(io);
        std.Io.Dir.cwd().deleteFile(io, sp.path) catch {};
    }
};

fn openSpool(c: Context, job: job_mod.Job, collect: *sink.LogSink) !?*JobSpool {
    if (c.cfg.log_spool_dir.len == 0) return null;
    const path = std.fmt.allocPrint(
        c.arena,
        "{s}/zig-runner-job-{d}.log",
        .{ c.cfg.log_spool_dir, job.check_run_id },
    ) catch return null;
    const file = std.Io.Dir.cwd().createFile(c.io, path, .{ .read = true }) catch |e| {
        try c.err.print(
            "job {d}: no log spool in {s} ({s}); the job's log is kept in memory\n",
            .{ job.check_run_id, c.cfg.log_spool_dir, @errorName(e) },
        );
        return null;
    };
    const js = try c.arena.create(JobSpool);
    js.* = .{ .spool = .{ .file = file, .io = c.io }, .path = path };
    collect.collect.spool = &js.spool;
    return js;
}

/// The job's conclusion as the run-state database records it.
fn reporterConclusion(result: dagger.Result) []const u8 {
    if (result.cancelled) return "cancelled";
    return if (result.succeeded) "success" else "failure";
}

/// Run state in the database, when there is one and the job can be identified. The reporter is
/// returned by value and the caller keeps it, because the spool pointer into `collect` is set here.
fn startReporter(c: Context, job: job_mod.Job, job_started_ms: i64) !?Reporter {
    const st = c.store orelse return null;
    const run_id = std.fmt.parseInt(u64, job.github.run_id, 10) catch 0;
    if (run_id == 0 or job.check_run_id == 0) {
        try c.err.writeAll("run state not recorded: the job has no run id or job id\n");
        return null;
    }
    var reporter: Reporter = .{
        .store = st,
        .arena = c.arena,
        .io = c.io,
        .job_id = job.check_run_id,
        .run_id = run_id,
        .failed_before = st.failed.load(.monotonic),
    };
    reporter.jobStarted(job, c.name, job_started_ms);
    return reporter;
}

/// The steps, through Dagger — or failed up front: a job this runner does not trust
/// (`trust.zig`), or one whose `container:` or `services:` it does not support, rather than run
/// in ways that would fail confusingly without them.
fn runJobSteps(
    c: Context,
    job: job_mod.Job,
    log: *sink.LogSink,
    cancel: *dagger.Cancel,
    live: *Live,
    /// Told of the steps first; passes them on to `live`.
    step_logs: *StepLogs,
    reporter: ?*Reporter,
) !dagger.Result {
    const cfg = c.cfg;
    const refused = try trust.refusal(c.arena, cfg.trusted_refs, cfg.trusted_events, job.github);
    if (refused) |why| try c.err.print("job refused: {s}\n", .{why});
    const unsupported: ?[]const u8 = refused orelse job.container_error orelse job.services_error;
    if (unsupported) |why| {
        try log.append(job.check_run_id, 0, .stderr, why);
        return failedInSetUp(c.arena, job.steps.len);
    }
    var result = try dagger.run(c.arena, c.io, c.environ, .{
        .dagger_cmd = c.cfg.dagger_cmd,
        .image = c.cfg.image,
        .js_runtime = c.cfg.js_runtime,
        .engine = c.cfg.engineEndpoint(),
        .gpa = c.gpa,
        .nesting = c.cfg.dagger_nesting,
        .package_caches = c.cfg.package_caches,
        .uv_env_in_cache = c.cfg.uv_env_in_cache,
        .zig_local_cache = c.cfg.zig_local_cache,
        .step_cache = c.cfg.step_cache,
        .step_user = c.cfg.step_user,
        // Skipped for a repository whose jobs spend too long on them (see `SlowOutputs`).
        .output_keys = c.cfg.output_keys and !slowOutputs(c, job.github.repository),
        .output_keys_days = c.cfg.output_keys_days,
        .cancel = cancel,
        .observer = observer: {
            live.next = if (reporter) |r| r.observer() else null;
            break :observer step_logs.observer();
        },
        .sink_job_id = job.check_run_id,
        .runner_name = c.name,
    }, job, log);
    // A cancel can also end the job through a query it cut short (past the grace period).
    if (cancel.requested.load(.acquire)) {
        result.cancelled = true;
        result.succeeded = false;
    }
    if (result.engine_error) |msg| if (!result.cancelled) {
        try log.append(job.check_run_id, 0, .stderr, "dagger failed before running the steps:");
        try log.append(job.check_run_id, 0, .stderr, msg);
    };
    return result;
}

/// A job failed before any of its steps: "Set up job" failed, as GitHub's runner shows it, and the
/// steps keep their numbers without running (so "Complete job" does not take the first one's).
fn failedInSetUp(arena: std.mem.Allocator, steps: usize) !dagger.Result {
    const step_results = try arena.alloc(dagger.StepResult, steps);
    @memset(step_results, .{});
    return .{
        .steps = step_results,
        .engine_error = null,
        .succeeded = false,
        .set_up_failed = true,
    };
}

test "a job failed before its steps fails in Set up job" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const r = try failedInSetUp(a.allocator(), 2);
    try std.testing.expect(r.set_up_failed and !r.succeeded);
    try std.testing.expectEqual(@as(usize, 2), r.steps.len);
}

/// "Complete job", as GitHub's runner ends a job (the job's containers went with its session).
/// Returns where that step sits, for `shownSteps`.
fn logCompleteJob(
    c: Context,
    job: job_mod.Job,
    log: *sink.LogSink,
    live: *Live,
    result: dagger.Result,
    job_started_ms: i64,
) !CompleteStep {
    const complete_started = std.Io.Clock.real.now(c.io).toMilliseconds();
    const after_last: u32 = @intCast(job.steps.len + 1);
    const complete_step: u32 = if (result.next_log_step > 0) result.next_log_step else after_last;
    if (result.set_up_failed) {
        // GitHub keeps a step's first conclusion and number: say "Set up job" failed before
        // "Complete job" starts (which would end it as a success), and number the steps that did
        // not run.
        live.end(0, "Set up job", .failure, job_started_ms, complete_started);
        live.skipNumbers(@intCast(job.steps.len));
    }
    live.begin(complete_step, "Complete job", complete_started);
    for (result.output_lines) |l| try log.append(job.check_run_id, complete_step, .stdout, l);
    try log.append(job.check_run_id, complete_step, .stdout, "Cleaning up orphan processes");
    try log.flush();
    return .{
        .log_step = complete_step,
        .started_ms = complete_started,
        .completed_ms = std.Io.Clock.real.now(c.io).toMilliseconds(),
    };
}

/// On the runner's own console: how many steps the engine served from cache, as the step logs say
/// (`dagger.reused_note`) — what step caching saved this job, next to what output keys cost it. A
/// job with a step replayed is not learned from by the memory gate (`admission.Gate.replayed`).
fn reportCacheAndKeys(
    c: Context,
    job: job_mod.Job,
    log: *sink.LogSink,
    result: dagger.Result,
) !void {
    if (c.cfg.step_cache and job.steps.len > 0) {
        var replayed: usize = 0;
        // Read a line at a time, not held: the log can be the 64 MiB it keeps.
        const kept = log.collect.kept();
        var it = kept.iterate(c.io, try keptBuffer(c));
        while (it.next() catch null) |l| {
            if (l.step >= 1 and l.step <= job.steps.len and
                (it.textIs(dagger.reused_note) catch false)) replayed += 1;
        }
        if (replayed > 0) if (c.gate) |gate| gate.replayed();
        try c.err.print(
            "job {d}: {d} of {d} steps replayed from the cache\n",
            .{ job.check_run_id, replayed, job.steps.len },
        );
    }
    const ok = result.output_keys;
    if (ok.applied + ok.fell_back == 0) return;
    try c.err.print(
        "job {d}: output keys: {d} of {d} always-run steps applied",
        .{ job.check_run_id, ok.applied, ok.applied + ok.fell_back },
    );
    const ms: u64 = @intCast(@max(ok.ms, 0));
    try c.err.print(" in {d}.{d} s", .{ ms / 1000, ms % 1000 / 100 });
    if (ok.fell_back > 0)
        try c.err.print("; {d} fell back (last: {s})", .{ ok.fell_back, ok.last_reason });
    try c.err.writeAll("\n");
    // Over the limit: the rest of this repository's jobs do without them (see `SlowOutputs`).
    const cap = c.cfg.output_keys_max_ms;
    if (cap > 0 and ok.ms > cap and job.github.repository.len > 0) if (c.slow_outputs) |so| {
        if (so.record(job.github.repository, ok.ms))
            try c.err.print(
                "job {d}: output keys: {d}.{d} s is over the {d}.{d} s limit, so {s}'s later " ++
                    "jobs skip them (RUNNER_OUTPUT_KEYS_MAX_MS)\n",
                .{
                    job.check_run_id,
                    ms / 1000,
                    ms % 1000 / 100,
                    cap / 1000,
                    cap % 1000 / 100,
                    job.github.repository,
                },
            );
    };
}

/// The steps as completejob reports them, for the live view's last update.
fn liveFinals(arena: std.mem.Allocator, shown: []const Shown) ![]const Live.Final {
    const finals = try arena.alloc(Live.Final, shown.len);
    for (shown, finals) |sh, *f| f.* = .{
        .id = sh.id,
        .number = sh.number,
        .name = sh.name,
        .conclusion = liveConclusion(sh.conclusion),
        .started_ms = sh.started_ms,
        .completed_ms = sh.completed_ms,
    };
    return finals;
}

/// completejob with the step results and annotations, and once more without them if GitHub refuses:
/// a held job blocks the run for minutes, so it is always finished. Returns the failed Cycle when
/// even that did not succeed.
fn completeJobWithRetry(
    c: Context,
    jr: runservice.JobRequest,
    job: job_mod.Job,
    conclusion: runservice.Conclusion,
    shown: []const Shown,
    result: dagger.Result,
    /// The job's secrets and masks, which annotations are redacted with.
    secrets: []const []const u8,
) !?Cycle {
    const step_json = try stepResultsJson(c.arena, shown);
    const annotations_json = try annotationsJson(c.arena, shown, result.annotations, secrets);
    var done = completeJob(
        c,
        jr,
        job,
        conclusion,
        step_json,
        result.outputs,
        annotations_json,
    ) catch |e|
        return try fail(c, "completejob", e);
    if (done.status.class() != .success) {
        try c.err.print(
            "completejob with step results and annotations failed (HTTP {d}: {s}); retrying " ++
                "without them\n",
            .{ @backingInt(done.status), done.body[0..@min(done.body.len, 200)] },
        );
        done = completeJob(c, jr, job, conclusion, "[]", result.outputs, "[]") catch |e|
            return try fail(c, "completejob", e);
        if (done.status.class() != .success) return try failBody(c, "completejob", done);
    }
    return null;
}

/// completejob, tried again (after 2, 5 and 10 s) when the request fails or GitHub answers 5xx:
/// a job not completed stays held, and once its hold runs out GitHub fails it ("lost
/// communication") whatever its steps did. The hold is still being renewed meanwhile.
fn completeJob(
    c: Context,
    jr: runservice.JobRequest,
    job: job_mod.Job,
    conclusion: runservice.Conclusion,
    step_json: []const u8,
    outputs: []const job_mod.EnvVar,
    annotations_json: []const u8,
) !broker.Response {
    const delays = [_]i64{ 2, 5, 10 };
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        const r = runservice.complete(
            c.arena,
            c.io,
            jr,
            job.job_token,
            job.plan_id,
            job.job_id,
            conclusion,
            step_json,
            outputs,
            annotations_json,
        );
        const retry = if (r) |resp| resp.status.class() == .server_error else |_| true;
        if (!retry or attempt == delays.len) return r;
        if (r) |resp| {
            try c.err.print(
                "completejob: HTTP {d}; trying again in {d}s\n",
                .{ @backingInt(resp.status), delays[attempt] },
            );
        } else |e| try c.err.print(
            "completejob: {s}; trying again in {d}s\n",
            .{ @errorName(e), delays[attempt] },
        );
        c.io.sleep(.fromSeconds(delays[attempt]), .awake) catch {};
    }
}

/// Renews the runner's hold on its job every 60 s while the job runs, as GitHub's runner does
/// (`renewjob`). Without it GitHub fails the job 10 minutes after it was acquired ("The self-hosted
/// runner lost communication with the server"), even while its steps still run (SPEC §3). Like
/// completejob it takes the job's own token; the runner's gets 401. Runs next to the job, so it
/// has memory of its own and reports through the runner's shared (locked) sink, not the job's log.
const Renewer = struct {
    fn init(
        c: Context,
        job: job_mod.Job,
        jr: runservice.JobRequest,
        cancel: *dagger.Cancel,
    ) Renewer {
        return .{
            .c = c,
            .token = job.job_token,
            .jr = jr,
            .plan_id = job.plan_id,
            .job_id = job.job_id,
            .log_job = job.check_run_id,
            .cancel = cancel,
        };
    }

    c: Context,
    token: []const u8,
    jr: runservice.JobRequest,
    plan_id: []const u8,
    job_id: []const u8,
    log_job: u64,
    /// Set when GitHub no longer has the job (404): it ended it, so nothing of it runs on.
    cancel: *dagger.Cancel,
    stop: std.atomic.Value(bool) = .init(false),

    pub const interval_secs = 60;

    fn run(r: *Renewer) void {
        var reported = false;
        while (true) {
            // In short steps: the job's end waits for this to see `stop`.
            var waited: u32 = 0;
            while (waited < interval_secs * 20 and !r.stop.load(.acquire)) : (waited += 1) {
                r.c.io.sleep(.fromMilliseconds(50), .awake) catch return;
            }
            if (r.stop.load(.acquire)) return;
            var call: std.heap.ArenaAllocator = .init(r.c.gpa);
            defer call.deinit();
            const arena = call.allocator();
            const resp = runservice.renew(
                arena,
                r.c.io,
                r.jr,
                r.token,
                r.plan_id,
                r.job_id,
            ) catch |e| {
                // Cut short at the job's end (see handleJob): nothing failed.
                if (e == error.Canceled or r.stop.load(.acquire)) return;
                r.say(arena, "renewjob failed: {s}", .{@errorName(e)});
                continue;
            };
            if (resp.status == .not_found) {
                // Seen when a cancelled job's grace period ran out: GitHub closed the job itself.
                r.say(arena, "GitHub no longer has the job (renewjob: HTTP 404); stopping it", .{});
                r.cancel.request(std.Io.Clock.real.now(r.c.io).toMilliseconds());
                return;
            }
            if (resp.status.class() != .success) {
                r.say(
                    arena,
                    "renewjob failed: HTTP {d}: {s}",
                    .{ @backingInt(resp.status), resp.body[0..@min(resp.body.len, 200)] },
                );
            } else if (!reported) {
                reported = true;
                r.say(
                    arena,
                    "job hold renewed (locked until {s})",
                    .{jsonString(arena, resp.body, "lockedUntil") orelse "?"},
                );
            }
        }
    }

    fn say(r: *Renewer, arena: Allocator, comptime fmt: []const u8, args: anytype) void {
        const text = std.fmt.allocPrint(arena, "job {d}: " ++ fmt, .{r.log_job} ++ args) catch
            return;
        r.c.log.say(text) catch {};
    }
};

/// Listens on the runner's session while its job runs, as GitHub's runner does, for a
/// `JobCancellation` message: `{"jobId": ..., "timeout": "0.00:05:00.0000"}`, sent when the run is
/// cancelled and when the job reaches its `timeout-minutes` (GitHub enforces that limit itself; the
/// job definition does not carry it). The timeout is the grace period for what still runs after the
/// cancel (`if: always()` steps, post scripts); past it, the job's queries are ended too.
const CancelWatch = struct {
    fn init(c: Context, session: Listening, job: job_mod.Job, cancel: *dagger.Cancel) CancelWatch {
        return .{
            .c = c,
            .session = session,
            .job_id = job.job_id,
            .log_job = job.check_run_id,
            .cancel = cancel,
        };
    }

    c: Context,
    session: Listening,
    job_id: []const u8,
    log_job: u64,
    cancel: *dagger.Cancel,
    stop: std.atomic.Value(bool) = .init(false),

    fn run(w: *CancelWatch) void {
        var state: std.heap.ArenaAllocator = .init(w.c.gpa);
        defer state.deinit();
        var token = w.session.token;
        var token_at = w.session.token_at;
        while (!w.stop.load(.acquire)) {
            var call: std.heap.ArenaAllocator = .init(w.c.gpa);
            defer call.deinit();
            var cc = w.c;
            cc.arena = call.allocator();
            const now = std.Io.Clock.real.now(cc.io).toSeconds();
            if (now - token_at > token_refresh_secs) {
                var status: std.http.Status = .ok;
                if (mintToken(cc, w.session.creds, &status)) |t| {
                    token = state.allocator().dupe(u8, t) catch token;
                    token_at = now;
                } else |_| {}
            }
            // Stopped at the job's end by cancelling this poll, which the HTTP client can report as
            // an error other than Canceled. Without the `stop` check the watch then slept 5 s that
            // nothing interrupted, and the job's end waited it out: 5.1 s between every two jobs.
            // A long poll, so a request's usual deadline would end every one (`poll_timeout`).
            const m = broker.request(cc.arena, cc.io, .GET, w.session.url, null, .{
                .token = token,
                .deadline = poll_timeout,
            }) catch |e| {
                if (e == error.Canceled or w.stop.load(.acquire)) return;
                cc.io.sleep(.fromSeconds(5), .awake) catch return;
                continue;
            };
            if (w.stop.load(.acquire)) return;
            if (m.status.class() != .success or m.body.len == 0) {
                if (m.status != .accepted and m.status.class() != .success)
                    cc.io.sleep(.fromSeconds(5), .awake) catch return;
                continue;
            }
            const mtype = jsonString(cc.arena, m.body, "messageType") orelse "";
            if (!std.mem.eql(u8, mtype, "JobCancellation")) continue;
            const inner = jsonString(cc.arena, m.body, "body") orelse continue;
            const id = jsonString(cc.arena, inner, "jobId") orelse continue;
            if (!std.mem.eql(u8, id, w.job_id)) continue;
            const grace_ms = timeSpanMs(jsonString(cc.arena, inner, "timeout") orelse "") orelse
                default_grace_ms;
            w.cancel.request(std.Io.Clock.real.now(cc.io).toMilliseconds() + grace_ms);
            const text = std.fmt.allocPrint(
                cc.arena,
                "job {d}: cancelled by GitHub; stopping the running step ({d} s for what still " ++
                    "runs)",
                .{ w.log_job, @divTrunc(grace_ms, 1000) },
            ) catch return;
            w.c.log.say(text) catch {};
            return;
        }
    }

    /// GitHub's default `cancel-timeout-minutes`.
    const default_grace_ms = 5 * 60 * 1000;
};

/// Cancels the job once the runner has been asked to stop (SIGTERM from systemd, Docker or a
/// deploy) and the job has had `Config.stop_grace_secs` to finish on its own. Before, a stop
/// waited for a running job however long it took: a stuck one held `systemctl stop` until the
/// unit's `TimeoutStopSec`, and the engine ran its step all that time (#127). The cancel is
/// GitHub's: the running step is stopped, `if: always()` steps and post scripts get
/// `stop_cancel_ms`, and the job is reported cancelled.
const StopDeadline = struct {
    c: Context,
    cancel: *dagger.Cancel,
    log_job: u64,
    stop: std.atomic.Value(bool) = .init(false),

    fn run(s: *StopDeadline) void {
        // In short steps, as `waitForStop` does: the job's end waits for this to see `stop`.
        while (!stopRequested()) {
            if (s.stop.load(.acquire)) return;
            s.c.io.sleep(.fromMilliseconds(200), .awake) catch return;
        }
        const grace_ms = @as(i64, s.c.cfg.stop_grace_secs) * std.time.ms_per_s;
        const stopping_at = std.Io.Clock.awake.now(s.c.io).toMilliseconds();
        while (std.Io.Clock.awake.now(s.c.io).toMilliseconds() - stopping_at < grace_ms) {
            if (s.stop.load(.acquire)) return;
            s.c.io.sleep(.fromMilliseconds(200), .awake) catch return;
        }
        if (s.stop.load(.acquire)) return;
        s.cancel.request(std.Io.Clock.real.now(s.c.io).toMilliseconds() + stop_cancel_ms);
        sayUnallocated(
            s.c,
            "job {d}: the runner is stopping and the job did not finish within {d} s; " ++
                "cancelling it ({d} s for what still runs)",
            .{ s.log_job, s.c.cfg.stop_grace_secs, @divTrunc(stop_cancel_ms, 1000) },
        );
    }
};

/// What a job cancelled by the runner's stop still gets for `if: always()` steps and post scripts,
/// before whatever runs is stopped too: GitHub gives a cancelled job 5 minutes
/// (`CancelWatch.default_grace_ms`), but a stop is bounded by the unit's `TimeoutStopSec`.
const stop_cancel_ms = 60 * std.time.ms_per_s;

/// A .NET TimeSpan as GitHub writes one (`[d.]hh:mm:ss[.fffffff]`) in milliseconds; null when it
/// is not one.
pub fn timeSpanMs(text: []const u8) ?i64 {
    var rest = text;
    var days: i64 = 0;
    const colon = std.mem.indexOfScalar(u8, rest, ':') orelse return null;
    if (std.mem.lastIndexOfScalar(u8, rest[0..colon], '.')) |dot| {
        days = std.fmt.parseInt(i64, rest[0..dot], 10) catch return null;
        rest = rest[dot + 1 ..];
    }
    var parts = std.mem.splitScalar(u8, rest, ':');
    const h = std.fmt.parseInt(i64, parts.next() orelse return null, 10) catch return null;
    const m = std.fmt.parseInt(i64, parts.next() orelse return null, 10) catch return null;
    const sec = std.fmt.parseFloat(f64, parts.next() orelse return null) catch return null;
    if (parts.next() != null) return null;
    // Out of range is not a time span, and would overflow (or, for `inf`, panic in the conversion).
    if (days < 0 or days > 1_000_000 or h < 0 or h >= 24 or m < 0 or m >= 60) return null;
    if (!(sec >= 0 and sec < 60)) return null;
    return ((days * 24 + h) * 60 + m) * 60_000 + @as(i64, @intFromFloat(sec * 1000));
}

test "the job's log is spooled, and the spool file goes when the job ends" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fs.path.join(arena, &.{ ".zig-cache", "tmp", &tmp.sub_path });

    var out_buf: [1024]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var inner: sink.LogSink = .{ .stdout = .{ .writer = &out } };
    var err_buf: [1024]u8 = undefined;
    var err: std.Io.Writer = .fixed(&err_buf);
    var cfg: Config = .{ .gh_token = "", .scope = undefined, .log_spool_dir = dir };
    const c: Context = .{
        .arena = arena,
        .gpa = std.testing.allocator,
        .io = io,
        .environ = undefined,
        .cfg = &cfg,
        .log = &inner,
        .err = &err,
        .secrets = &.{},
        .name = "t",
    };
    const job: job_mod.Job = .{
        .plan_id = "p",
        .job_id = "j",
        .job_token = "t",
        .check_run_id = 7,
        .secrets = &.{},
        .steps = &.{},
    };

    // Opening the spool points the collector at it; handleJob has nothing to remember.
    var collect: sink.LogSink = .{ .collect = .{ .arena = arena, .io = io, .inner = &inner } };
    const spool = try openSpool(c, job, &collect);
    try std.testing.expect(spool != null);
    try std.testing.expect(collect.collect.spool == &spool.?.spool);
    const path = spool.?.path;
    try std.testing.expect(std.mem.endsWith(u8, path, "/zig-runner-job-7.log"));

    // A logged line is on disk, not in memory, and comes back from the file.
    try collect.append(7, 1, .stdout, "spooled");
    try std.testing.expectEqual(@as(usize, 0), collect.collect.lines.items.len);
    const back = collect.collect.collected(arena);
    try std.testing.expectEqual(@as(usize, 1), back.len);
    try std.testing.expectEqualStrings("spooled", back[0].text);

    // Closing deletes the file: a finished job leaves nothing in the spool directory.
    spool.?.close(io);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openFile(io, path, .{}));

    // No spool directory configured: no spool, nothing said.
    cfg.log_spool_dir = "";
    try std.testing.expect((try openSpool(c, job, &collect)) == null);
    try std.testing.expectEqual(@as(usize, 0), err.buffered().len);

    // A directory the runner cannot write to: said once, and the job carries on without a spool.
    cfg.log_spool_dir = try std.fs.path.join(arena, &.{ dir, "not-a-directory" });
    try std.testing.expect((try openSpool(c, job, &collect)) == null);
    try std.testing.expect(std.mem.indexOf(u8, err.buffered(), "no log spool in") != null);
    try std.testing.expect(std.mem.indexOf(u8, err.buffered(), "kept in memory") != null);
}

test "timeSpanMs reads GitHub's cancel timeout" {
    try std.testing.expectEqual(@as(?i64, 300_000), timeSpanMs("0.00:05:00.0000"));
    try std.testing.expectEqual(@as(?i64, 90_500), timeSpanMs("00:01:30.5"));
    try std.testing.expectEqual(@as(?i64, 86_400_000 + 60_000), timeSpanMs("1.00:01:00"));
    try std.testing.expectEqual(@as(?i64, null), timeSpanMs("soon"));
    try std.testing.expectEqual(@as(?i64, null), timeSpanMs("00:00:inf"));
    try std.testing.expectEqual(@as(?i64, null), timeSpanMs("9223372036854775807.00:00:00"));
}

fn mintToken(c: Context, creds: auth.Credentials, status: *std.http.Status) !([]const u8) {
    var jti: [8]u8 = undefined;
    c.io.random(&jti);
    const now = std.Io.Clock.real.now(c.io).toSeconds();
    const jwt = try auth.buildJwt(
        c.arena,
        creds,
        now,
        try std.fmt.allocPrint(c.arena, "{x}", .{jti}),
    );
    return auth.fetchAccessToken(c.arena, c.io, creds, jwt, status);
}

fn jsonString(arena: Allocator, body: []const u8, key: []const u8) ?[]const u8 {
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return null;
    if (v != .object) return null;
    const s = v.object.get(key) orelse return null;
    return if (s == .string) s.string else null;
}

const github_failure: Cycle = .{ .failed = .{ .exit = .github } };

fn fail(c: Context, what: []const u8, e: anyerror) !Cycle {
    try c.err.print("error during {s}: ", .{what});
    try redact.write(c.err, @errorName(e), c.secrets);
    try c.err.writeByte('\n');
    return github_failure;
}

fn failHttp(c: Context, what: []const u8, e: anyerror, status: std.http.Status) !Cycle {
    try c.err.print(
        "error during {s}: {s} (HTTP {d})\n",
        .{ what, @errorName(e), @backingInt(status) },
    );
    return github_failure;
}

fn failBody(c: Context, what: []const u8, r: broker.Response) !Cycle {
    // Error bodies are short JSON documents without credentials.
    try c.err.print(
        "error during {s}: HTTP {d}: {s}\n",
        .{ what, @backingInt(r.status), r.body[0..@min(r.body.len, 400)] },
    );
    return github_failure;
}

test "a job's cancel watch stops at once when the job ends, mid-poll" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const io = std.testing.io;
    // Connections complete in the listener's backlog and are never answered, so the watch is in
    // the middle of its poll when the job ends, as it always is.
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    const url = try std.fmt.allocPrint(
        arena,
        "http://127.0.0.1:{d}/message",
        .{listener.socket.address.getPort()},
    );

    var out_buf: [1024]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &out } };
    var err_buf: [1024]u8 = undefined;
    var err: std.Io.Writer = .fixed(&err_buf);
    var cfg: Config = .{ .gh_token = "", .scope = undefined };
    const c: Context = .{
        .arena = arena,
        .gpa = std.testing.allocator,
        .io = io,
        .environ = undefined,
        .cfg = &cfg,
        .log = &log,
        .err = &err,
        .secrets = &.{},
        .name = "t",
    };
    const job: job_mod.Job = .{
        .plan_id = "p",
        .job_id = "j",
        .job_token = "t",
        .check_run_id = 7,
        .secrets = &.{},
        .steps = &.{},
    };
    var cancel: dagger.Cancel = .{};
    // No token refresh is due, so the credentials are never read.
    var watcher = CancelWatch.init(c, .{
        .creds = undefined,
        .token = "token",
        .token_at = std.Io.Clock.real.now(io).toSeconds(),
        .url = url,
    }, job, &cancel);
    var watching = try io.concurrent(CancelWatch.run, .{&watcher});
    try io.sleep(.fromMilliseconds(200), .awake);

    // As handleJob ends it: stop, then cancel the poll.
    const started = std.Io.Clock.awake.now(io).toMilliseconds();
    watcher.stop.store(true, .release);
    watching.cancel(io);
    const took = std.Io.Clock.awake.now(io).toMilliseconds() - started;
    try std.testing.expect(took < 1000);
    try std.testing.expect(!cancel.requested.load(.acquire));
}

test "a stop cancels a running job once its grace has passed, and not a job that ended first" {
    const io = std.testing.io;
    var out_buf: [1024]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &out } };
    var cfg: Config = .{ .gh_token = "", .scope = undefined, .stop_grace_secs = 0 };
    const c: Context = .{
        .arena = undefined,
        .gpa = std.testing.allocator,
        .io = io,
        .environ = undefined,
        .cfg = &cfg,
        .log = &log,
        .err = undefined,
        .secrets = &.{},
        .name = "t",
    };
    stop_signals.store(1, .release);
    defer stop_signals.store(0, .release);

    // Past its grace: cancelled, with a minute for what still runs.
    var cancel: dagger.Cancel = .{};
    var deadline: StopDeadline = .{ .c = c, .cancel = &cancel, .log_job = 7 };
    const before = std.Io.Clock.real.now(io).toMilliseconds();
    var running = try io.concurrent(StopDeadline.run, .{&deadline});
    running.await(io);
    try std.testing.expect(cancel.requested.load(.acquire));
    const hard = cancel.hard_deadline_ms.load(.acquire);
    try std.testing.expect(hard >= before + stop_cancel_ms);
    try std.testing.expect(hard <= std.Io.Clock.real.now(io).toMilliseconds() + stop_cancel_ms);
    try std.testing.expect(std.mem.indexOf(u8, out.buffered(), "job 7: the runner is stopping") !=
        null);

    // A job that ends within its grace is left alone, and its end is not kept waiting.
    cfg.stop_grace_secs = 60;
    var left: dagger.Cancel = .{};
    var ending: StopDeadline = .{ .c = c, .cancel = &left, .log_job = 8 };
    var waiting = try io.concurrent(StopDeadline.run, .{&ending});
    try io.sleep(.fromMilliseconds(300), .awake);
    const started = std.Io.Clock.awake.now(io).toMilliseconds();
    // As handleJob ends it.
    ending.stop.store(true, .release);
    waiting.cancel(io);
    try std.testing.expect(std.Io.Clock.awake.now(io).toMilliseconds() - started < 1000);
    try std.testing.expect(!left.requested.load(.acquire));
}

test "backoffSecs doubles from 5s up to 5 minutes" {
    try std.testing.expectEqual(@as(u32, 5), backoffSecs(1));
    try std.testing.expectEqual(@as(u32, 10), backoffSecs(2));
    try std.testing.expectEqual(@as(u32, 160), backoffSecs(6));
    try std.testing.expectEqual(@as(u32, 300), backoffSecs(7));
    try std.testing.expectEqual(@as(u32, 300), backoffSecs(1000));
}

/// A context for tests that make requests but run no job: its log lines go to `log`.
pub fn testContext(arena: Allocator, log: *sink.LogSink, err: *std.Io.Writer, cfg: *Config) Context {
    return .{
        .arena = arena,
        .gpa = std.testing.allocator,
        .io = std.testing.io,
        .environ = undefined,
        .cfg = cfg,
        .log = log,
        .err = err,
        .secrets = &.{},
        .name = "t",
    };
}

const FakeGitHub = struct {
    var removed: ?u64 = null;

    fn generate(arena: Allocator, _: std.Io, _: *const Config, name: []const u8, _: *std.http.Status, _: *[]const u8) jitconfig.Error!jitconfig.Jit {
        const files = try arena.alloc(jitconfig.File, 1);
        files[0] = .{ .name = ".runner", .content = try arena.dupe(u8, "{\"agentId\": 7}") };
        return .{ .runner_id = 7, .runner_name = try arena.dupe(u8, name), .files = files };
    }

    fn refuse(_: Allocator, _: std.Io, _: *const Config, _: []const u8, status: *std.http.Status, message: *[]const u8) jitconfig.Error!jitconfig.Jit {
        status.* = .forbidden;
        message.* = "no";
        return error.GithubRejected;
    }

    fn remove(_: Context, id: u64, _: []const u8) void {
        removed = id;
        removes += 1;
    }

    // Sessions: opened in the background (`open`), or not (`noSession`); each deletion counted.
    var opens: u32 = 0;
    var removes: u32 = 0;
    var deletes: u32 = 0;
    var deleted_sid: [16]u8 = undefined;
    var deleted_len: usize = 0;

    fn reset() void {
        removed = null;
        opens = 0;
        removes = 0;
        deletes = 0;
        deleted_len = 0;
    }

    fn open(c: Context, jit: jitconfig.Jit) ?Session {
        opens += 1;
        const sid = std.fmt.allocPrint(c.arena, "s-{d}", .{jit.runner_id}) catch return null;
        return .{ .base = "https://broker.test/", .sid = sid, .token = "tok", .token_at = 42 };
    }

    fn noSession(_: Context, _: jitconfig.Jit) ?Session {
        opens += 1;
        return null;
    }

    fn delete(_: Context, _: []const u8, sid: []const u8, _: []const u8) void {
        deletes += 1;
        deleted_len = @min(sid.len, deleted_sid.len);
        @memcpy(deleted_sid[0..deleted_len], sid[0..deleted_len]);
    }

    const calls: Registering.Calls = .{ .generate = generate, .remove = remove, .open = open, .delete = delete };
};

test "the next registration, made while a job finishes, is taken over, or removed when unused" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    var cfg: Config = .{ .gh_token = "", .scope = undefined, .name_prefix = "r" };
    const c = testContext(a.allocator(), &log, &w, &cfg);

    // Taken over: copied into the cycle's arena, and the background task's memory freed (the
    // testing allocator would report it otherwise). Its session too, which is the cycle's to
    // delete from then on: nothing is deleted or removed here.
    FakeGitHub.reset();
    const r = try Registering.startWith(c, FakeGitHub.calls);
    const name = try a.allocator().dupe(u8, r.name);
    const taken = try r.take(a.allocator());
    const got = taken.result.ok;
    try std.testing.expectEqual(@as(u64, 7), got.runner_id);
    try std.testing.expectEqualStrings(name, got.runner_name);
    try std.testing.expect(std.mem.startsWith(u8, got.runner_name, "r-"));
    try std.testing.expectEqualStrings("{\"agentId\": 7}", got.files[0].content);
    const s = taken.session.?;
    try std.testing.expectEqualStrings("s-7", s.sid);
    try std.testing.expectEqualStrings("https://broker.test/", s.base);
    try std.testing.expectEqualStrings("tok", s.token);
    try std.testing.expectEqual(@as(i64, 42), s.token_at);
    try std.testing.expectEqual(@as(u32, 0), FakeGitHub.deletes);
    try std.testing.expectEqual(@as(u32, 0), FakeGitHub.removes);

    // Never used (the runner stopped): its session deleted, then its registration removed, once
    // each, as an idle registration must be.
    FakeGitHub.reset();
    const unused = try Registering.startWith(c, FakeGitHub.calls);
    unused.discard(c);
    try std.testing.expectEqual(@as(u32, 1), FakeGitHub.deletes);
    try std.testing.expectEqualStrings("s-7", FakeGitHub.deleted_sid[0..FakeGitHub.deleted_len]);
    try std.testing.expectEqual(@as(u32, 1), FakeGitHub.removes);
    try std.testing.expectEqual(@as(?u64, 7), FakeGitHub.removed);

    // Refused: the cycle gets GitHub's answer, as if it had registered itself; no session is
    // opened for a runner that does not exist.
    FakeGitHub.reset();
    var refusing = FakeGitHub.calls;
    refusing.generate = FakeGitHub.refuse;
    const refused = try Registering.startWith(c, refusing);
    const f = (try refused.take(a.allocator())).result.failed;
    try std.testing.expectEqual(error.GithubRejected, f.err);
    try std.testing.expectEqual(std.http.Status.forbidden, f.status);
    try std.testing.expectEqualStrings("no", f.message);
    try std.testing.expectEqual(@as(u32, 0), FakeGitHub.opens);
    try std.testing.expectEqual(@as(u32, 0), FakeGitHub.deletes + FakeGitHub.removes);
}

test "a session the next registration could not open is left to the cycle, and never deleted" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    var cfg: Config = .{ .gh_token = "", .scope = undefined, .name_prefix = "r" };
    const c = testContext(a.allocator(), &log, &w, &cfg);
    var calls = FakeGitHub.calls;
    calls.open = FakeGitHub.noSession;

    // Taken over without one: the cycle opens it itself, as it did before.
    FakeGitHub.reset();
    const r = try Registering.startWith(c, calls);
    const taken = try r.take(a.allocator());
    try std.testing.expect(taken.result == .ok);
    try std.testing.expect(taken.session == null);
    try std.testing.expectEqual(@as(u32, 1), FakeGitHub.opens);

    // Unused: only the registration is removed; there is no session to delete.
    FakeGitHub.reset();
    const unused = try Registering.startWith(c, calls);
    unused.discard(c);
    try std.testing.expectEqual(@as(u32, 0), FakeGitHub.deletes);
    try std.testing.expectEqual(@as(u32, 1), FakeGitHub.removes);
}

test "a registration made as the runner stops opens no session, and is removed once" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    var cfg: Config = .{ .gh_token = "", .scope = undefined, .name_prefix = "r" };
    const c = testContext(a.allocator(), &log, &w, &cfg);

    FakeGitHub.reset();
    stop_signals.store(1, .release);
    defer stop_signals.store(0, .release);
    const r = try Registering.startWith(c, FakeGitHub.calls);
    // As `serve` ends on a stop: what no cycle took is discarded.
    r.discard(c);
    try std.testing.expectEqual(@as(u32, 0), FakeGitHub.opens);
    try std.testing.expectEqual(@as(u32, 0), FakeGitHub.deletes);
    try std.testing.expectEqual(@as(u32, 1), FakeGitHub.removes);
}

test "a runner short of memory stops asking for jobs, and asks again once memory is back" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const io = std.testing.io;
    // The broker: every poll is handed a job, whose acquirejob then answers 404.
    var server: @import("github/testserver.zig").Server = undefined;
    try server.start();
    defer server.stop();
    var url_buf: [64]u8 = undefined;
    const base = try arena.dupe(u8, server.url(&url_buf, "127.0.0.1", "/broker/"));

    // The machine: plenty of memory, but under pressure (PSI) until the test says otherwise.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fs.path.join(arena, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    const thrashing = "some avg10=50.00 avg60=20.00 avg300=5.00 total=900\n";
    const calm = "some avg10=0.00 avg60=0.00 avg300=0.00 total=900\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "meminfo", .data = "MemAvailable: 8388608 kB\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "pressure", .data = thrashing });
    var slots: [1]admission.Admission.Slot = undefined;
    var memory: admission.Admission = .init(io, .{}, &slots);
    memory.paths = .{
        .meminfo = try std.fs.path.join(arena, &.{ dir, "meminfo" }),
        .pressure = try std.fs.path.join(arena, &.{ dir, "pressure" }),
    };
    memory.recheck = .fromMilliseconds(10);
    var gate: admission.Gate = .{ .pool = &memory };

    var out_buf: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &out } };
    var err_buf: [1024]u8 = undefined;
    var err: std.Io.Writer = .fixed(&err_buf);
    var cfg: Config = .{ .gh_token = "", .scope = undefined };
    var c = testContext(arena, &log, &err, &cfg);
    c.gate = &gate;
    // A token minted now is not refreshed, so the credentials are never read.
    const creds: auth.Credentials = undefined;
    var token: []const u8 = "tok";
    var token_at = std.Io.Clock.real.now(io).toSeconds();

    // Under pressure the cycle ends before its first poll: nothing asked, nothing counted.
    try std.testing.expectEqual(Cycle.held, try listen(c, creds, base, "s", &token, &token_at));
    try std.testing.expectEqual(@as(u32, 0), server.polls.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), memory.polling);

    // `serve` then waits, looking again every 10 ms, and still asks for nothing.
    const Waiter = struct {
        done: std.atomic.Value(bool) = .init(false),
        fn run(w: *@This(), cc: Context, g: *admission.Gate, h: admission.Hold) anyerror!bool {
            defer w.done.store(true, .release);
            return admit(cc, g, h);
        }
    };
    var waiter: Waiter = .{};
    var waiting = try io.concurrent(Waiter.run, .{ &waiter, c, &gate, gate.check().? });
    io.sleep(.fromMilliseconds(150), .awake) catch {};
    try std.testing.expect(!waiter.done.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), server.polls.load(.acquire));

    // The pressure goes: the runner is let through and takes the job it is handed.
    try tmp.dir.writeFile(io, .{ .sub_path = "pressure", .data = calm });
    try std.testing.expect(try waiting.await(io));
    try std.testing.expectEqual(@as(u32, 1), memory.polling);
    const r = try listen(c, creds, base, "s", &token, &token_at);
    try std.testing.expect(r == .failed);
    try std.testing.expectEqual(@as(u32, 1), server.polls.load(.acquire));
    try std.testing.expect(std.mem.indexOf(u8, err.buffered(), "acquirejob") != null);
    // No longer polling, and its job reserved while it ramps up.
    try std.testing.expectEqual(@as(u32, 0), memory.polling);
    try std.testing.expect(slots[0].started_ms > std.math.minInt(i64));

    // The hold and its end were each said once, though the gate was looked at many times.
    const said = out.buffered();
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, said, "holding back"));
    try std.testing.expect(std.mem.indexOf(u8, said, "memory pressure 50.00%") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, said, "taking jobs again"));

    // A runner held when a stop comes stops at once.
    try tmp.dir.writeFile(io, .{ .sub_path = "pressure", .data = thrashing });
    stop_signals.store(1, .release);
    defer stop_signals.store(0, .release);
    const hold = gate.check().?;
    try std.testing.expect(!try admit(c, &gate, hold));
}

test "a runner holds while the engine is near its own cap, though the machine has memory" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const io = std.testing.io;
    var server: @import("github/testserver.zig").Server = undefined;
    try server.start();
    defer server.stop();
    var url_buf: [64]u8 = undefined;
    const base = try arena.dupe(u8, server.url(&url_buf, "127.0.0.1", "/broker/"));

    // The machine: 8 GB available, calm. The engine (#142): 3.6 of its 4 GB in use.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fs.path.join(arena, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    try tmp.dir.writeFile(io, .{ .sub_path = "meminfo", .data = "MemAvailable: 8388608 kB\n" });
    try tmp.dir.createDirPath(io, "cg/docker-e.scope");
    var scope = try tmp.dir.openDir(io, "cg/docker-e.scope", .{});
    defer scope.close(io);
    try scope.writeFile(io, .{ .sub_path = "memory.max", .data = "4294967296\n" });
    try scope.writeFile(io, .{ .sub_path = "memory.current", .data = "3774873600\n" });
    try scope.writeFile(io, .{ .sub_path = "memory.stat", .data = "inactive_file 0\n" });
    var slots: [1]admission.Admission.Slot = undefined;
    var memory: admission.Admission = .init(io, .{}, &slots);
    memory.paths = .{
        .meminfo = try std.fs.path.join(arena, &.{ dir, "meminfo" }),
        .pressure = "/nonexistent",
        .cgroup_root = try std.fs.path.join(arena, &.{ dir, "cg" }),
    };
    const cgroup = try std.fs.path.join(arena, &.{ dir, "cg", "docker-e.scope" });
    memory.engine.source = .{ .cgroup = cgroup };
    memory.recheck = .fromMilliseconds(10);
    var gate: admission.Gate = .{ .pool = &memory };

    var out_buf: [4096]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &out } };
    var err_buf: [1024]u8 = undefined;
    var err: std.Io.Writer = .fixed(&err_buf);
    var cfg: Config = .{ .gh_token = "", .scope = undefined };
    var c = testContext(arena, &log, &err, &cfg);
    c.gate = &gate;
    const creds: auth.Credentials = undefined;
    var token: []const u8 = "tok";
    var token_at = std.Io.Clock.real.now(io).toSeconds();

    try std.testing.expectEqual(Cycle.held, try listen(c, creds, base, "s", &token, &token_at));
    try std.testing.expectEqual(@as(u32, 0), server.polls.load(.acquire));
    const hold = gate.check().?;
    try std.testing.expect(hold == .engine);
    // A job's compiles end: the engine is back to 1 GB, and the runner takes jobs again.
    try scope.writeFile(io, .{ .sub_path = "memory.current", .data = "1073741824\n" });
    try std.testing.expect(try admit(c, &gate, hold));
    const said = out.buffered();
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, said, "the engine's cgroup is"));
    try std.testing.expect(std.mem.indexOf(u8, said, "capped at 4.0 GB") != null);
    try std.testing.expect(std.mem.indexOf(u8, said, "engine 3.5 GB of 4.0 GB in use") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, said, "taking jobs again"));
    try std.testing.expectEqual(@as(u32, 1), memory.polling);
}

test "a poll that is never answered is given up after its timeout" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const io = std.testing.io;
    // Connections complete in the listener's backlog and are never accepted, so a request is sent
    // and nothing ever comes back: a connection that died under the poll.
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    const url = try std.fmt.allocPrint(
        a.allocator(),
        "http://127.0.0.1:{d}/message",
        .{listener.socket.address.getPort()},
    );

    var out_buf: [1024]u8 = undefined;
    var out: std.Io.Writer = .fixed(&out_buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &out } };
    var err_buf: [1024]u8 = undefined;
    var err: std.Io.Writer = .fixed(&err_buf);
    var cfg: Config = .{ .gh_token = "", .scope = undefined };
    const c = testContext(a.allocator(), &log, &err, &cfg);

    const started = std.Io.Clock.awake.now(io).toMilliseconds();
    const r = try poll(c, url, "token", .fromMilliseconds(300));
    const took = std.Io.Clock.awake.now(io).toMilliseconds() - started;
    try std.testing.expect(r == .timeout);
    try std.testing.expect(took >= 300 and took < 5000);
}

test "acquirejob is tried again after a 5xx or a failed connection, not after a 4xx" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const io = std.testing.io;
    var server: @import("github/testserver.zig").Server = undefined;
    try server.start();
    defer server.stop();
    var url_buf: [64]u8 = undefined;

    var cfg: Config = .{ .gh_token = "", .scope = undefined };
    var err_buf: [1024]u8 = undefined;
    var err: std.Io.Writer = .fixed(&err_buf);
    const retry_ms = [_]i64{ 1, 1 };

    // 503 on every attempt: tried three times, and the last answer is returned.
    {
        var out_buf: [4096]u8 = undefined;
        var out: std.Io.Writer = .fixed(&out_buf);
        var log: sink.LogSink = .{ .stdout = .{ .writer = &out } };
        const c = testContext(arena, &log, &err, &cfg);
        const jr: runservice.JobRequest = .{
            .runner_request_id = "r",
            .run_service_url = try arena.dupe(
                u8,
                server.url(&url_buf, "127.0.0.1", "/unavailable"),
            ),
        };
        const r = try acquire(c, jr, "token", &retry_ms);
        try std.testing.expectEqual(std.http.Status.service_unavailable, r.status);
        try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, out.buffered(), "HTTP 503"));
    }
    // 404 is an answer, not a failure: returned at once.
    {
        var out_buf: [4096]u8 = undefined;
        var out: std.Io.Writer = .fixed(&out_buf);
        var log: sink.LogSink = .{ .stdout = .{ .writer = &out } };
        const c = testContext(arena, &log, &err, &cfg);
        const jr: runservice.JobRequest = .{
            .runner_request_id = "r",
            .run_service_url = try arena.dupe(u8, server.url(&url_buf, "127.0.0.1", "/nowhere")),
        };
        const r = try acquire(c, jr, "token", &retry_ms);
        try std.testing.expectEqual(std.http.Status.not_found, r.status);
        const retries = std.mem.count(u8, out.buffered(), "trying again");
        try std.testing.expectEqual(@as(usize, 0), retries);
    }
    // Nothing listening: tried three times, then the error.
    {
        const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        var closed = try addr.listen(io, .{ .reuse_address = true });
        const port = closed.socket.address.getPort();
        closed.deinit(io);

        var out_buf: [4096]u8 = undefined;
        var out: std.Io.Writer = .fixed(&out_buf);
        var log: sink.LogSink = .{ .stdout = .{ .writer = &out } };
        const c = testContext(arena, &log, &err, &cfg);
        const jr: runservice.JobRequest = .{
            .runner_request_id = "r",
            .run_service_url = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{port}),
        };
        if (acquire(c, jr, "token", &retry_ms)) |_| return error.TestUnexpectedResult else |_| {}
        const retries = std.mem.count(u8, out.buffered(), "trying again");
        try std.testing.expectEqual(@as(usize, 2), retries);
    }
}

test "a repository whose output keys run over the limit is remembered once" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    var so: SlowOutputs = .{ .io = std.testing.io, .gpa = std.testing.allocator };
    defer {
        var it = so.repos.keyIterator();
        while (it.next()) |k| std.testing.allocator.free(k.*);
        so.repos.deinit(std.testing.allocator);
    }
    try std.testing.expect(so.spent("o/r") == null);
    try std.testing.expect(so.record("o/r", 25_600)); // the first job over the limit says so
    try std.testing.expect(!so.record("o/r", 30_000)); // later ones stay quiet
    try std.testing.expectEqual(@as(?i64, 25_600), so.spent("o/r"));
    // Another repository is unaffected: the cost follows the checkout's size, not the runner's.
    try std.testing.expect(so.spent("o/small") == null);
}
