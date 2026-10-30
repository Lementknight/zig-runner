//! Runs a job's steps through Dagger (DESIGN §4, SPEC §6).
//!
//! One long-lived Dagger session hosts the whole job: the runner starts `dagger run`, which runs a
//! tiny child that prints the session's port and token and then waits. The runner then speaks
//! GraphQL to that session over HTTP (as the Dagger SDKs do), one query per step, threading the
//! container through by id. Container ids only live as long as the session, which is why this is
//! not one `dagger query` per step.
//!
//! Compared to a single query for the whole job this lets the runner decide what to run next from
//! earlier results (conditions, expressions, step outputs), and `withExec(expect: ANY)` returns the
//! real exit code and separate stdout/stderr, even for steps served from Dagger's cache.
//!
//! Live output comes from `dagger run`'s progress log on stderr, read by a reader task. Each step's
//! script brackets its output with marker lines so lines can be attributed to the step:
//!
//!     <marker>begin N <mark>      <marker>end N <mark>
//!
//! `<mark>` is the job's secret (`mark_env`), so a step cannot forge another step's markers by
//! printing text; see `scan`.
//!
//! Dagger's log frontend may repeat a span's header when it switches spans, so lines are attributed
//! to the step named in the most recent span header (a single line that contains the step's `begin`
//! marker text), not simply the last `begin`. A step served
//! from cache prints no log lines at all; its stdout/stderr from the query result are replayed.
const std = @import("std");
const job_mod = @import("job.zig");
const sink = @import("sink.zig");
const redact = @import("redact.zig");
const broker = @import("github/broker.zig");
const build_version = @import("version.zig");
const expr = @import("expr.zig");
const glob = @import("glob.zig");
const context = @import("context.zig");
const commands = @import("commands.zig");
const matcher = @import("matcher.zig");
const action = @import("action.zig");
const config = @import("config.zig");
const engine = @import("engine.zig");
const Query = @import("dagger/query.zig").Query;
const Raw = @import("dagger/query.zig").Raw;
const registryCredentials = @import("dagger/docker.zig").registryCredentials;
const registryAuth = @import("dagger/docker.zig").registryAuth;
const ServicePort = @import("dagger/services.zig").ServicePort;
const outputKeysKey = @import("dagger/output_keys.zig").outputKeysKey;
const Shared = @import("dagger/Shared.zig");
pub const Marker = @import("dagger/Shared.zig").Marker;
pub const Scan = @import("dagger/Shared.zig").Scan;
pub const scan = @import("dagger/Shared.zig").scan;
const readLogs = @import("dagger/Shared.zig").readLogs;
const SpanDemux = @import("dagger/Shared.zig").SpanDemux;
const awaitLiveOrReplay = @import("dagger/Shared.zig").awaitLiveOrReplay;
const awaitLive = @import("dagger/Shared.zig").awaitLive;
const servedFromCache = @import("dagger/Shared.zig").servedFromCache;
const replayNotLive = @import("dagger/Shared.zig").replayNotLive;
pub const reused_note = @import("dagger/Shared.zig").reused_note;
const noteReusedSteps = @import("dagger/Shared.zig").noteReusedSteps;
const Evaluator = @import("dagger/Evaluator.zig");
const StepCtx = @import("dagger/Evaluator.zig").StepCtx;
const isSha = @import("dagger/checkout.zig").isSha;
pub const checkoutQuery = @import("dagger/checkout.zig").checkoutQuery;
const looksLikeAuthFailure = @import("dagger/checkout.zig").looksLikeAuthFailure;
const fetchCheckout = @import("dagger/checkout.zig").fetchCheckout;
pub const stepScript = @import("dagger/scripts.zig").stepScript;
const fcPath = @import("dagger/scripts.zig").fcPath;
const stepScriptFc = @import("dagger/scripts.zig").stepScriptFc;
const stream_prologue = @import("dagger/scripts.zig").stream_prologue;
const writeMarkerEcho = @import("dagger/scripts.zig").writeMarkerEcho;
const writeCombinedFileCommands = @import("dagger/scripts.zig").writeCombinedFileCommands;
const fc_marker = @import("dagger/scripts.zig").fc_marker;
const shellLine = @import("dagger/scripts.zig").shellLine;
const secretAlias = @import("dagger/scripts.zig").secretAlias;
const FakeSession = @import("dagger/testing.zig").FakeSession;
const fake_child = @import("dagger/testing.zig").fake_child;
const base_answer = @import("dagger/testing.zig").base_answer;
const exec = @import("dagger/testing.zig").exec;
const execFc = @import("dagger/testing.zig").execFc;
const testStep = @import("dagger/testing.zig").testStep;
const testJob = @import("dagger/testing.zig").testJob;
const treeAnswer = @import("dagger/testing.zig").treeAnswer;
const fileAnswer = @import("dagger/testing.zig").fileAnswer;
const usesStep = @import("dagger/testing.zig").usesStep;
const braceBalanced = @import("dagger/testing.zig").braceBalanced;

const Allocator = std.mem.Allocator;

pub const default_image = "ubuntu:24.04";
/// Where a Docker action sees the job's workspace, as on GitHub.
pub const docker_workspace = "/github/workspace";
/// GitHub's runner works under /home/runner/work; a `container:` job sees it as /__w.
const work_root = "/home/runner/work";
const container_work_root = "/__w";

/// The job's workspace, where GitHub's runner puts it: `<work>/<repo>/<repo>` (checked next to
/// `ubuntu-latest`). Scripts and tools that record absolute paths then see the same ones.
pub fn jobWorkspace(arena: Allocator, job: job_mod.Job) ![]const u8 {
    const repo = job.github.repository;
    const name = if (std.mem.lastIndexOfScalar(
        u8,
        repo,
        '/',
    )) |i| repo[i + 1 ..] else if (repo.len > 0) repo else "workspace";
    return std.fmt.allocPrint(arena, "{s}/{s}/{s}", .{ jobWorkRoot(job), name, name });
}

/// RUNNER_TEMP: `<work>/_temp`, as on GitHub.
pub fn jobTemp(arena: Allocator, job: job_mod.Job) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/_temp", .{jobWorkRoot(job)});
}

fn jobWorkRoot(job: job_mod.Job) []const u8 {
    return if (job.container != null) container_work_root else work_root;
}
pub const marker = "::zig-step::";

/// What the default image (`ubuntu:24.04`) gets before a job: what workflows written for GitHub's
/// `ubuntu-latest` most often assume without a setup action. `sudo` (steps run as `runner_user`, as
/// on GitHub, and many call `sudo apt-get`), compilers and `make`, Python with pip and venv (and
/// `python`), `psql` for a Postgres service, archive and transfer tools, and what composite actions
/// often use (`jq`, `curl`). Installed once per engine: Dagger caches this exec, so only the first
/// job pays for it.
pub const provision_packages = [_][]const u8{
    "git",            "git-lfs",     "ca-certificates", "curl",              "wget",
    "xz-utils",       "bzip2",       "zstd",            "zip",               "unzip",
    "jq",             "sudo",        "gnupg",           "openssh-client",    "rsync",
    "file",           "lsb-release", "tzdata",          "build-essential",   "pkg-config",
    "python3",        "python3-pip", "python3-venv",    "python-is-python3", "postgresql-client",
    "netcat-openbsd", "procps",
};
pub const provision_script = "apt-get update -qq && DEBIAN_FRONTEND=noninteractive " ++
    "apt-get install -y -qq --no-install-recommends " ++ packageList() ++
    " >/dev/null && rm -rf /var/lib/apt/lists/*";

/// The user steps run as in the default image with `Options.step_user = .runner`, as on GitHub's
/// hosted runners: uid 1001, home /home/runner, passwordless sudo, and /github (the workspace, file
/// commands, the event) its own. Tests that expect file permissions to hold (writing a 0400 file
/// fails) behave as on GitHub; root ignores them.
const runner_user = "runner";
pub const runner_home = "/home/runner";
const chown_runner = " && chown -R " ++ runner_user ++ ":" ++ runner_user ++ " " ++ work_root;
const provision_runner_script = provision_script ++
    " && (id -u " ++ runner_user ++ " >/dev/null 2>&1 || " ++
    "useradd -m -u 1001 -s /bin/bash " ++ runner_user ++ ")" ++
    " && printf '%s\\n' '" ++ runner_user ++ " ALL=(ALL) NOPASSWD:ALL' > " ++
    "/etc/sudoers.d/" ++ runner_user ++ " && chmod 0440 /etc/sudoers.d/" ++ runner_user ++
    " && mkdir -p " ++ work_root ++ " " ++ docker_home ++ runnerCacheDirs() ++
    " && chown -R " ++ runner_user ++ ":" ++ runner_user ++ " /github " ++ runner_home;

/// The package caches' directories under the user's home, made in advance: Dagger creates a cache
/// mount's missing parents as root (`/home/runner/go` for `/home/runner/go/pkg/mod`), and then the
/// user could not create anything next to the mount (setup-go's `~/go/bin`).
fn runnerCacheDirs() []const u8 {
    comptime {
        var out: []const u8 = "";
        for (package_cache_dirs) |d| {
            if (std.mem.startsWith(u8, d.path, "/root/"))
                out = out ++ " " ++ runner_home ++ d.path["/root".len..];
        }
        return out ++ " " ++ runner_home ++ "/.cache/yarn";
    }
}

/// Where package cache `i` is mounted for steps that run as `runner_user`: its directory under the
/// user's home instead of root's.
fn runnerCachePath(arena: Allocator, i: usize) ![]const u8 {
    const p = package_cache_dirs[i].path;
    if (std.mem.startsWith(u8, p, "/root/"))
        return std.mem.concat(arena, u8, &.{ runner_home, p["/root".len..] });
    // Yarn's cache is under /usr/local/share for root, in the home directory for anyone else.
    if (std.mem.eql(u8, package_cache_dirs[i].name, "yarn")) return runner_home ++ "/.cache/yarn";
    return p;
}

/// Where Zig's local cache (`.zig-cache`) is mounted with `zig_local_cache`, instead of the workspace,
/// which goes with the job. The volume is per repository (and apart for forks' pull requests), and
/// Zig locks its cache entries, so jobs running at once share it safely.
fn zigLocalCacheDir(as_runner: bool) []const u8 {
    return if (as_runner) runner_home ++ "/.cache/zig-local" else "/root/.cache/zig-local";
}

/// Where uv's project environment goes with `uv_env_in_cache`: inside its own cache volume, the
/// only place a hardlink from that cache can reach (every mount is its own device, even two of one
/// volume). Keyed by the ref, so jobs on different branches do not reconcile one environment to
/// their own lockfiles in turn, and concurrent jobs on one branch want the same state anyway. Never
/// with step caching (see `uvEnvFor`).
fn uvEnvPath(arena: Allocator, cache_path: []const u8, ref: []const u8) ![]const u8 {
    var key: std.ArrayList(u8) = .empty;
    for (if (ref.len > 0) ref else "default") |c| {
        try key.append(
            arena,
            if (std.ascii.isAlphanumeric(c) or c == '.' or c == '-' or c == '_') c else '-',
        );
    }
    const trimmed = std.mem.trim(u8, key.items, "-");
    return std.fmt.allocPrint(
        arena,
        "{s}/zig-runner-envs/{s}",
        .{ cache_path, if (trimmed.len > 0) trimmed else "default" },
    );
}

fn packageList() []const u8 {
    comptime {
        var out: []const u8 = "";
        for (provision_packages, 0..) |p, n| out = out ++ (if (n == 0) "" else " ") ++ p;
        return out;
    }
}

pub fn shellQuote(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('\'');
    for (s) |c| {
        if (c == '\'') try w.writeAll("'\\''") else try w.writeByte(c);
    }
    try w.writeByte('\'');
}

/// Evaluates an `if:` condition. Null when v0 cannot evaluate it. `job_failed` is true once a step
/// failed without continue-on-error.
pub fn evalCondition(cond: []const u8, job_failed: bool) ?bool {
    const c = std.mem.trim(u8, cond, " ");
    if (std.mem.eql(u8, c, "success()")) return !job_failed;
    if (std.mem.eql(u8, c, "always()")) return true;
    if (std.mem.eql(u8, c, "failure()")) return job_failed;
    if (std.mem.eql(u8, c, "cancelled()")) return false;
    return null;
}

/// A checkout step after its repository was fetched, or failed to be.
pub const Fetched = struct {
    /// Dagger Directory id of the fetched tree, or why it could not be fetched.
    result: union(enum) { dir: []const u8, failed: []const u8 },
    repo: []const u8,
    /// What was checked out, for the log (a short sha or the requested ref).
    ref_label: []const u8,
    /// Absolute directory inside the container.
    mount: []const u8,
    /// The ref the checkout stands for (`refs/heads/main`, `refs/pull/7/merge`, a bare name from
    /// `with: ref:`), or null for a sha or a repository's default branch. See
    /// `checkoutRefCommands`.
    git_ref: ?[]const u8 = null,
    /// What was asked for, for the step's log: the URL, the ref or commit, the depth and tags.
    url: []const u8 = "",
    want: []const u8 = "",
    depth: u32 = 1,
    tags: bool = false,
};

/// A step with its expressions evaluated, ready to become a script.
pub const Resolved = union(enum) {
    run: struct {
        script: []const u8,
        /// `bash`, `sh`, or null for the default.
        shell: ?[]const u8,
        working_directory: ?[]const u8,
        env: []const job_mod.EnvVar,
        /// Names of env variables whose values are Dagger secrets. The `i`th arrives in the
        /// container as `ZIG_SECRET_<i>` and the script gives it its real name (any name works, see
        /// `secretAlias`).
        secret_env: []const []const u8 = &.{},
        /// Set for steps that must run every time (they use secrets or read run-specific values): a
        /// line with a per-run value, so the step never matches an earlier run's cache entry.
        always_run: ?[]const u8 = null,
        /// Write the event payload from the volatile ZIG_RUNNER_EVENT variable to
        /// GITHUB_EVENT_PATH.
        write_event: bool = false,
        /// Give this step `volatile_sentinel` in place of the run-specific values (see
        /// `Options.enforce_volatile`). Set for a step that is *not* always-run, where a real value
        /// would be one it could read without the runner knowing and be replayed with.
        withhold_volatile: bool = false,
    },
    checkout: Fetched,
};

/// GitHub's limit on composite actions inside composite actions.
const max_composite_depth = 9;

/// Where a Docker action's container gets its static busybox, and HOME (shared by the job's Docker
/// actions, as GitHub mounts one /github/home into each).
const busybox_image = "busybox:1.37.0-musl";
pub const busybox_path = "/github/_runtime/busybox";
pub const docker_home = "/github/home";

/// Inputs as INPUT_<NAME> (upper case, spaces as underscores, as `@actions/core` reads them).
pub fn inputEnv(arena: Allocator, inputs: []const expr.Value.Entry) ![]const job_mod.EnvVar {
    const out = try arena.alloc(job_mod.EnvVar, inputs.len);
    for (inputs, out) |in, *dst| {
        const name = try std.ascii.allocUpperString(
            arena,
            try std.mem.replaceOwned(u8, arena, in.key, " ", "_"),
        );
        dst.* = .{
            .name = try std.fmt.allocPrint(arena, "INPUT_{s}", .{name}),
            .value = in.value.string,
        };
    }
    return out;
}

/// The inputs an action gets, for the log as GitHub shows them: every one with a value (given or
/// defaulted), in the action's order, then any it does not declare.
pub fn shownInputs(arena: Allocator, inputs: []const expr.Value.Entry) ![]const job_mod.EnvVar {
    var out: std.ArrayList(job_mod.EnvVar) = .empty;
    for (inputs) |in| if (in.value == .string and in.value.string.len > 0) {
        try out.append(arena, .{ .name = in.key, .value = in.value.string });
    };
    return out.items;
}

/// The strings of a JSON array (an image's entrypoint or command); empty for anything else.
pub fn jsonStrings(arena: Allocator, v: ?std.json.Value) ![]const []const u8 {
    const arr = v orelse return &.{};
    if (arr != .array) return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    for (arr.array.items) |item| if (item == .string) try out.append(arena, item.string);
    return out.items;
}

pub const Outcome = enum { not_run, success, failure, skipped, cancelled };

pub const StepResult = struct {
    /// The step's display name with expressions evaluated; empty when it was never evaluated.
    name: []const u8 = "",
    /// Whether `continue-on-error` applied (evaluated), so a failure does not fail the job.
    continued: bool = false,
    outcome: Outcome = .not_run,
    exit_code: i32 = 0,
    started_ms: i64 = 0,
    completed_ms: i64 = 0,
};

pub const Result = struct {
    steps: []StepResult,
    /// Set when the engine itself failed (pull error, session lost): what Dagger said.
    engine_error: ?[]const u8,
    /// False if any step failed without continue-on-error, or the engine failed before running
    /// them.
    succeeded: bool,
    /// GitHub cancelled the job while it ran (a cancel in the UI, or the job's `timeout-minutes`).
    cancelled: bool = false,
    /// Actions' `pre` and `post` scripts that ran, as GitHub shows them: steps of their own.
    extra: []const ExtraStep = &.{},
    /// The first log step number not used (see `ExtraStep.log_step`); 0 means `steps.len + 1`.
    next_log_step: u32 = 0,
    /// The job's outputs, evaluated after its steps (see `job_mod.Job.outputs`), and what to log
    /// about them in "Complete job".
    outputs: []const job_mod.EnvVar = &.{},
    output_lines: []const []const u8 = &.{},
    annotations: []const Annotation = &.{},
    /// $GITHUB_STEP_SUMMARY per log step (index = log step - 1; empty when none was written).
    summaries: []const []const u8 = &.{},
    /// With output keys: how many always-run steps keyed the steps after them on their output, how
    /// many fell back, and why the last one did. For the runner's own log, so an operator sees how
    /// often they apply without turning on step debug.
    output_keys: struct {
        applied: u32 = 0,
        fell_back: u32 = 0,
        last_reason: []const u8 = "",
        ms: i64 = 0,
    } = .{},
    /// "Set up job" failed (an action could not be resolved), so no step ran.
    set_up_failed: bool = false,
};

/// An annotation and the log step it came from (mapped to GitHub's step number at completion).
pub const Annotation = struct { step: u32, an: commands.Annotation };

/// The largest step summary GitHub accepts (its `soft_size_limit`).
const max_summary_bytes = 1024 * 1024;

/// The largest answer to an exec's query read with its recorded output in it (`Exec.Recorded`): a
/// step served from the cache with more output than this is not replayed. The answer is held about
/// three times over while it is read and parsed, so this keeps a step's cost in the low tens of MB.
const max_recorded_bytes = 4 * 1024 * 1024;

/// A `pre` or `post` script that ran: a step of its own in GitHub's list ("Pre Run x@v1",
/// "Post Run x@v1"). Its lines are logged under `log_step`, a number after the job's own steps
/// (0 is "Set up job", 1..n the job's steps).
pub const ExtraKind = enum { pre, post, initialize, stop };

pub const ExtraStep = struct {
    /// `initialize` and `stop` are "Initialize containers" and "Stop containers", which GitHub
    /// lists with the pre and post steps but numbers apart from them (see `loop.shownSteps`).
    kind: ExtraKind,
    name: []const u8,
    log_step: u32,
    outcome: Outcome,
    started_ms: i64,
    completed_ms: i64,
};

/// Log step numbers a job can use: its steps, at most one `pre` and one `post` each, and
/// "Initialize containers" and "Stop containers" for its services.
pub fn logSteps(n: usize) usize {
    return n * 3 + 3;
}

/// Sends one GraphQL document to the Dagger session and returns the response body.
pub const Transport = struct {
    ptr: *anyopaque,
    /// The answer to `doc`, or `error.ResponseTooLarge` once it is past `limit` bytes.
    sendFn: *const fn (
        ptr: *anyopaque,
        arena: Allocator,
        doc: []const u8,
        limit: usize,
    ) anyerror![]const u8,
    /// Ends the document being sent, from another task, so `send` fails; false when none was in
    /// flight. Null when the transport cannot (the `dagger run` CLI): steps then run to their end.
    abortFn: ?*const fn (ptr: *anyopaque) bool = null,

    fn send(t: Transport, arena: Allocator, doc: []const u8, limit: usize) ![]const u8 {
        return t.sendFn(t.ptr, arena, doc, limit);
    }

    fn abort(t: Transport) bool {
        return if (t.abortFn) |f| f(t.ptr) else false;
    }
};

/// Set by the runner when the job is cancelled (GitHub's `JobCancellation` message, GitHub no
/// longer having the job, or the runner stopping), read by the job.
pub const Cancel = struct {
    requested: std.atomic.Value(bool) = .init(false),
    /// When whatever still runs is stopped too (the grace period GitHub gives after a cancel), in
    /// ms since the epoch; 0 for none.
    hard_deadline_ms: std.atomic.Value(i64) = .init(0),

    /// Cancels the job, with whatever still runs after it stopped at `hard_deadline_ms`. Called
    /// from the runner's tasks, possibly more than once (GitHub cancels, then the runner stops):
    /// the earliest deadline holds, so a later, longer grace period never extends a shorter one.
    pub fn request(c: *Cancel, hard_deadline_ms: i64) void {
        var cur = c.hard_deadline_ms.load(.acquire);
        while (cur == 0 or hard_deadline_ms < cur) {
            cur = c.hard_deadline_ms.cmpxchgWeak(cur, hard_deadline_ms, .acq_rel, .acquire) orelse
                break;
        }
        c.requested.store(true, .release);
    }
};

/// Stops a step that runs past its `timeout-minutes`, or that is running when the job is cancelled,
/// by aborting the step's query (the engine then cancels the exec). A task of its own checks every
/// 200 ms; `begin` and `end` bracket each step, so an interrupt meant for one step never reaches
/// the next.
const Watch = struct {
    io: std.Io,
    transport: Transport,
    cancel: ?*Cancel,
    mu: std.Io.Mutex = .init,
    in_step: bool = false,
    deadline_ms: i64 = 0,
    /// A cancel arrived while this step ran and its query is still to be aborted.
    cancel_pending: bool = false,
    cancel_seen: bool = false,
    interrupt: Interrupt = .none,
    done: std.atomic.Value(bool) = .init(false),

    const Interrupt = enum { none, timed_out, cancelled };

    fn begin(w: *Watch, deadline_ms: i64) void {
        w.mu.lockUncancelable(w.io);
        defer w.mu.unlock(w.io);
        w.in_step = true;
        w.deadline_ms = deadline_ms;
        w.interrupt = .none;
        w.cancel_pending = false;
    }

    /// How the step was interrupted, if it was.
    fn end(w: *Watch) Interrupt {
        w.mu.lockUncancelable(w.io);
        defer w.mu.unlock(w.io);
        w.in_step = false;
        w.deadline_ms = 0;
        w.cancel_pending = false;
        defer w.interrupt = .none;
        return w.interrupt;
    }

    fn run(w: *Watch) void {
        while (!w.done.load(.acquire)) {
            w.io.sleep(.fromMilliseconds(200), .awake) catch return;
            w.tick(std.Io.Clock.real.now(w.io).toMilliseconds());
        }
    }

    fn tick(w: *Watch, now: i64) void {
        w.mu.lockUncancelable(w.io);
        defer w.mu.unlock(w.io);
        if (w.cancel) |c| {
            if (!w.cancel_seen and c.requested.load(.acquire)) {
                w.cancel_seen = true;
                w.cancel_pending = w.in_step;
            }
            const hard = c.hard_deadline_ms.load(.acquire);
            // Past the grace period nothing runs on: whatever is in flight is ended.
            if (w.cancel_seen and hard > 0 and now > hard) w.cancel_pending = true;
        }
        if (w.cancel_pending and w.transport.abort()) {
            w.interrupt = .cancelled;
            w.cancel_pending = false;
            return;
        }
        if (w.in_step and w.deadline_ms > 0 and now > w.deadline_ms and w.transport.abort()) {
            w.interrupt = .timed_out;
            w.deadline_ms = 0;
        }
    }
};

/// Told when each step starts and finishes, so run state can be recorded at those transitions.
pub const Observer = struct {
    ptr: *anyopaque,
    startedFn: *const fn (ptr: *anyopaque, number: u32, name: []const u8, started_ms: i64) void,
    finishedFn: *const fn (ptr: *anyopaque, number: u32, result: StepResult) void,
    /// The steps the runner adds ("Pre ...", "Post ...", "Initialize containers", "Stop
    /// containers"), by log step (see `ExtraStep`); optional.
    extraStartedFn: ?*const fn (
        ptr: *anyopaque,
        kind: ExtraKind,
        log_step: u32,
        name: []const u8,
        started_ms: i64,
    ) void = null,
    extraFinishedFn: ?*const fn (ptr: *anyopaque, e: ExtraStep) void = null,
    /// Before the post steps: how many will run, and whether "Stop containers" follows (GitHub
    /// numbers them apart from the steps before, see `loop.shownSteps`).
    postsFn: ?*const fn (ptr: *anyopaque, posts: u32, stop: bool) void = null,

    fn started(o: Observer, number: u32, name: []const u8, started_ms: i64) void {
        o.startedFn(o.ptr, number, name, started_ms);
    }
    fn finished(o: Observer, number: u32, result: StepResult) void {
        o.finishedFn(o.ptr, number, result);
    }
};

pub const Options = struct {
    observer: ?Observer = null,
    /// The `dagger` command.
    dagger_cmd: []const u8 = "dagger",
    image: []const u8 = default_image,
    /// Installed into the image before the job (one cached exec). Used for the default image only,
    /// which has no git; a custom image is expected to bring what it needs.
    provision: bool = true,
    /// Key under which output lines are written to the sink.
    sink_job_id: u64 = 0,
    /// The name the runner registered under (`runner.name`, RUNNER_NAME).
    runner_name: []const u8 = "zig-runner",
    /// What runs JavaScript actions.
    js_runtime: config.JsRuntime = .bun,
    /// Steps may use the job's Dagger engine (`dagger call` inside a step):
    /// `experimentalPrivilegedNesting`.
    nesting: bool = true,
    /// Mount `package_cache_dirs` from persistent cache volumes, scoped to the repository. The
    /// runner turns this on (`RUNNER_PACKAGE_CACHES`, on by default).
    package_caches: bool = false,
    /// Give a step that did not name a run-specific value `volatile_sentinel` instead of the real
    /// one, and `withheld_event` instead of the event payload. On by default: without it, such a step is replayed with an
    /// earlier run's value, which proofs/Runner/Enforce.agda shows is the one hypothesis behind
    /// step caching that the runner can discharge rather than assume.
    /// `RUNNER_ENFORCE_VOLATILE=false` restores GitHub's behaviour for a workflow that needs it.
    enforce_volatile: bool = true,
    /// Reuse unchanged steps' results across runs (see `volatile_env`). The runner turns this on
    /// (`RUNNER_STEP_CACHE`, on by default).
    step_cache: bool = false,
    /// Who steps run as in the default image (provisioned; see `runner_user`).
    step_user: config.StepUser = .root,
    /// Experimental, with `step_cache`: a step that always runs (it uses secrets) no longer makes
    /// every later step run too. What it changed is stored by content digest in a cache volume (see
    /// `Exec.outputKeyed`), and the next step starts from the container before it plus a copy of
    /// that content, so its key depends on what the step produced, not on the step having run. The
    /// runner turns this on with `RUNNER_OUTPUT_KEYS`.
    output_keys: bool = false,
    /// `Config.uv_env_in_cache`: uv's project environment goes inside its cache volume, in jobs
    /// whose steps are not cached (see `uvEnvFor`).
    uv_env_in_cache: bool = true,
    /// `Config.zig_local_cache`: Zig's local cache goes in a cache volume of its own.
    zig_local_cache: bool = false,
    /// Stored outputs not produced again for this many days are removed
    /// (`RUNNER_OUTPUT_KEYS_DAYS`).
    output_keys_days: u32 = 7,
    /// Set by the runner when GitHub cancels the job.
    cancel: ?*Cancel = null,
    /// Talk to the Dagger engine directly (`engine.zig`) instead of through a `dagger run` child.
    engine: ?engine.Endpoint = null,
    /// Backs the direct session's long-lived buffers and tasks; must be thread-safe.
    gpa: Allocator = std.heap.smp_allocator,
    /// Tests only: replaces `dagger run ...` (it must print "<port> <token>" first) and the HTTP
    /// transport.
    test_session_argv: ?[]const []const u8 = null,
    test_transport: ?Transport = null,
    /// Tests: this job's `ran_env` value instead of a random one.
    test_ran_marker: ?[]const u8 = null,
    /// Tests: this job's `mark_env` value instead of a random one.
    test_step_mark: ?[]const u8 = null,
};

// --- the HTTP transport to the session ---

const HttpTransport = struct {
    io: std.Io,
    url: []const u8,
    auth: []const u8,

    fn send(ptr: *anyopaque, arena: Allocator, doc: []const u8, limit: usize) anyerror![]const u8 {
        const self: *HttpTransport = @ptrCast(@alignCast(ptr));
        var body: std.Io.Writer.Allocating = .init(arena);
        try body.writer.writeAll("{\"query\":");
        try std.json.Stringify.value(doc, .{}, &body.writer);
        try body.writer.writeByte('}');
        const r = try broker.request(arena, self.io, .POST, self.url, body.written(), .{
            .extra_headers = &.{.{ .name = "Authorization", .value = self.auth }},
            // A query runs as long as what it runs (a step's exec); the job's cancel ends it.
            .deadline = null,
            .max_body = limit,
        });
        // GraphQL errors can arrive with a non-2xx status; the body says what was wrong.
        if (r.status.class() != .success and r.body.len == 0) return error.DaggerSessionHttpError;
        return r.body;
    }
};

pub fn jsonFind(v: std.json.Value, key: []const u8) ?std.json.Value {
    if (v != .object) return null;
    var it = v.object.iterator();
    while (it.next()) |e| {
        if (std.mem.eql(u8, e.key_ptr.*, key)) return e.value_ptr.*;
        if (jsonFind(e.value_ptr.*, key)) |f| return f;
    }
    return null;
}

pub fn jsonFindString(v: std.json.Value, key: []const u8) ?[]const u8 {
    const f = jsonFind(v, key) orelse return null;
    return if (f == .string) f.string else null;
}

/// Runs a document and returns the parsed `data`, or the first GraphQL error message.
pub fn gql(arena: Allocator, t: Transport, doc: []const u8, err_msg: *[]const u8) !std.json.Value {
    return gqlAtMost(arena, t, doc, engine.no_limit, err_msg);
}

/// As `gql`, failing with `error.ResponseTooLarge` (and no `err_msg`) when the answer is past
/// `limit` bytes, before more than that is held.
fn gqlAtMost(
    arena: Allocator,
    t: Transport,
    doc: []const u8,
    limit: usize,
    err_msg: *[]const u8,
) !std.json.Value {
    const body = t.send(arena, doc, limit) catch |e| {
        if (e == error.ResponseTooLarge) return e;
        err_msg.* = try std.fmt.allocPrint(
            arena,
            "could not reach the Dagger session: {s}",
            .{@errorName(e)},
        );
        return error.DaggerQueryFailed;
    };
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch {
        err_msg.* = "Dagger returned a response that is not JSON";
        return error.DaggerQueryFailed;
    };
    if (root == .object) {
        if (root.object.get("errors")) |errs| if (errs == .array and errs.array.items.len > 0) {
            err_msg.* = jsonFindString(errs.array.items[0], "message") orelse
                "Dagger returned an error";
            return error.DaggerQueryFailed;
        };
        if (root.object.get("data")) |d| return d;
    }
    err_msg.* = "Dagger returned no data";
    return error.DaggerQueryFailed;
}

/// GitHub's error for an action it cannot resolve (verified next to `ubuntu-latest`): a missing
/// version names the action and the version, a repository it cannot see is "not found" by its
/// lower-case name. Dagger's message is kept for other failures (a network error).
fn unresolvedMessage(
    arena: Allocator,
    u: job_mod.Uses,
    msg: []const u8,
    own_repo: bool,
) ![]const u8 {
    if (std.mem.indexOf(u8, msg, "does not contain ref") != null)
        return std.fmt.allocPrint(
            arena,
            "Unable to resolve action `{s}/{s}@{s}`, unable to find version `{s}`",
            .{ u.owner, u.name, u.ref, u.ref },
        );
    if (looksLikeAuthFailure(msg)) {
        const repo = try std.ascii.allocLowerString(
            arena,
            try std.fmt.allocPrint(arena, "{s}/{s}", .{ u.owner, u.name }),
        );
        // GitHub can be given access to a private action elsewhere; this runner fetches it
        // anonymously.
        return std.fmt.allocPrint(
            arena,
            "Unable to resolve action {s}, repository not found{s}",
            .{ repo, if (own_repo) "" else " (or private: the job's GITHUB_TOKEN reads only " ++
                "the job's own repository)" },
        );
    }
    return std.fmt.allocPrint(
        arena,
        "Unable to resolve action `{s}/{s}@{s}`, {s}",
        .{ u.owner, u.name, u.ref, msg },
    );
}

// --- secrets in the environment ---

/// Whether a value contains a secret. Such env values reach the step through a Dagger secret
/// (`withSecretVariable`), so they are not written into the command (which Dagger would keep in its
/// cache metadata and print in its progress log). Very short secret values are ignored: they would
/// match unrelated text.
fn containsSecret(job: job_mod.Job, value: []const u8) bool {
    for (job.secrets) |sec|
        if (sec.len >= 3 and std.mem.indexOf(u8, value, sec) != null) return true;
    return false;
}

pub const SecretRef = struct { name: []const u8, id: []const u8 };

/// The Dagger secrets this job's session holds, by plaintext. A value is registered once per job,
/// however many steps use it (the job token reaches every action, a step's secret env every run of
/// it), and values first needed together are registered in one query.
pub const Secrets = struct {
    /// Secrets registered so far, for their names (`zig-secret-<n>`).
    counter: u32 = 0,
    ids: std.StringHashMapUnmanaged([]const u8) = .empty,

    /// The values in `plaintexts` not registered yet, each once.
    fn missing(s: *const Secrets, arena: Allocator, plaintexts: []const []const u8) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        for (plaintexts) |p| {
            if (s.ids.contains(p)) continue;
            for (out.items) |o| {
                if (std.mem.eql(u8, o, p)) break;
            } else try out.append(arena, p);
        }
        return out.items;
    }

    /// One `setSecret` per value in `pending` (from `missing`), aliased `zsec<i>`, as root fields of
    /// `q`, which must have nothing open.
    fn write(s: *const Secrets, arena: Allocator, q: *Query, pending: []const []const u8) !void {
        for (pending, 0..) |p, i| {
            const name = try std.fmt.allocPrint(arena, "zig-secret-{d}", .{s.counter + i + 1});
            const alias = try std.fmt.allocPrint(arena, "zsec{d}", .{i});
            try q.callAs(alias, "setSecret", .{ .name = name, .plaintext = p });
            try q.leaf("id");
            try q.close(1);
        }
    }

    /// The ids of `pending` from the answer to `write`'s fields. False when one is missing; none
    /// is kept then.
    fn read(s: *Secrets, arena: Allocator, data: std.json.Value, pending: []const []const u8) !bool {
        const ids = try arena.alloc([]const u8, pending.len);
        for (ids, 0..) |*id, i| {
            const f = jsonFind(data, try std.fmt.allocPrint(arena, "zsec{d}", .{i})) orelse
                return false;
            id.* = jsonFindString(f, "id") orelse return false;
        }
        for (pending, ids) |p, id| try s.ids.put(arena, p, id);
        s.counter += @intCast(pending.len);
        return true;
    }

    /// Registers the values not registered yet, in one query (none when there are none).
    fn register(
        s: *Secrets,
        arena: Allocator,
        t: Transport,
        plaintexts: []const []const u8,
        err_msg: *[]const u8,
    ) !void {
        const pending = try s.missing(arena, plaintexts);
        if (pending.len == 0) return;
        var q: Query = .init(arena);
        try s.write(arena, &q, pending);
        const data = try gql(arena, t, try q.finish(), err_msg);
        if (!try s.read(arena, data, pending)) {
            err_msg.* = "Dagger returned no secret id";
            return error.DaggerQueryFailed;
        }
    }
};

/// `plaintext` as a Dagger secret in this session: its id, registered if it is not yet.
pub fn newSecret(
    arena: Allocator,
    t: Transport,
    secrets: *Secrets,
    plaintext: []const u8,
    err_msg: *[]const u8,
) ![]const u8 {
    try secrets.register(arena, t, &.{plaintext}, err_msg);
    return secrets.ids.get(plaintext).?;
}

/// Splits env into plain variables and secret-bearing ones (registered as Dagger secrets, those
/// not registered yet in one query).
pub fn splitEnv(
    arena: Allocator,
    t: Transport,
    job: job_mod.Job,
    secrets: *Secrets,
    env: []const job_mod.EnvVar,
    plain: *std.ArrayList(job_mod.EnvVar),
    secret: *std.ArrayList(SecretRef),
    err_msg: *[]const u8,
) !void {
    var values: std.ArrayList([]const u8) = .empty;
    for (env) |e| if (containsSecret(job, e.value)) try values.append(arena, e.value);
    try secrets.register(arena, t, values.items, err_msg);
    for (env) |e| {
        if (containsSecret(job, e.value)) {
            try secret.append(arena, .{ .name = e.name, .id = secrets.ids.get(e.value).? });
        } else {
            try plain.append(arena, e);
        }
    }
}

fn writeEnvNodes(q: *Query, plain: []const job_mod.EnvVar, secret: []const SecretRef) !void {
    for (plain) |e| try q.call("withEnvVariable", .{ .name = e.name, .value = e.value });
    for (secret) |sr| try q.call("withSecretVariable", .{ .name = sr.name, .secret = sr.id });
}

// --- running a job ---

/// Prints the session's port and token for the runner, then waits for stdin to close.
const session_script = "printf '%s %s\\n' \"$DAGGER_SESSION_PORT\" \"$DAGGER_SESSION_TOKEN\"; " ++
    "cat >/dev/null";

fn base64Encode(arena: Allocator, s: []const u8) ![]const u8 {
    const enc = std.base64.standard.Encoder;
    const buf = try arena.alloc(u8, enc.calcSize(s.len));
    return enc.encode(buf, s);
}

pub fn run(
    arena: Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    opts: Options,
    job: job_mod.Job,
    log: *sink.LogSink,
) !Result {
    var env = try environ.clone(arena);
    try env.put("NO_COLOR", "1");
    try env.put("DAGGER_NO_NAG", "1");
    try env.put("GIT_TERMINAL_PROMPT", "0");

    const results = try arena.alloc(StepResult, job.steps.len);
    @memset(results, .{});
    var sh = try sharedFor(arena, io, opts, job, log);

    if (opts.engine) |ep|
        if (opts.test_transport == null) return runDirect(arena, io, opts, job, &sh, results, ep);

    const argv: []const []const u8 = opts.test_session_argv orelse
        &.{ opts.dagger_cmd, "run", "--progress=logs", "sh", "-c", session_script };
    var child = try std.process.spawn(
        io,
        .{ .argv = argv, .environ_map = &env, .stdin = .pipe, .stdout = .pipe, .stderr = .pipe },
    );
    // The reader must run while we wait on queries. It owns stderr: `wait` closes the pipes the
    // child still holds, and closing this one under the reader let it read whatever file next got
    // the descriptor (ThreadSanitizer, `zig build test -Dsanitize-thread`).
    const stderr = child.stderr.?;
    child.stderr = null;
    var reader = io.concurrent(readLogs, .{ io, &sh, stderr }) catch |e| {
        stderr.close(io);
        child.kill(io);
        return e;
    };
    // Order matters: closing stdin ends the session child and `dagger run`, which gives the reader
    // EOF. Only then has every live line arrived, so only then can reused steps be told apart.
    defer {
        if (child.stdin) |f| f.close(io);
        child.stdin = null;
        reader.await(io);
        stderr.close(io);
        _ = child.wait(io) catch {};
        noteReusedSteps(&sh);
        sh.flush();
    }

    var http = switch (try sessionTransport(arena, io, &child, &sh, results)) {
        .failed => |result| return result,
        .transport => |t| t,
    };
    const transport: Transport = opts.test_transport orelse
        .{ .ptr = &http, .sendFn = HttpTransport.send };
    return runSteps(arena, io, opts, job, &sh, results, transport);
}

/// What every task of a job shares: the log, and one slot per log step — the job's steps, then
/// their `pre` and `post` scripts (see `ExtraStep`) — for live lines, endings, commands, replays
/// and counts, plus a buffer per service for its output.
fn sharedFor(
    arena: Allocator,
    io: std.Io,
    opts: Options,
    job: job_mod.Job,
    log: *sink.LogSink,
) !Shared {
    const n = logSteps(job.steps.len);
    const live = try arena.alloc(std.atomic.Value(u32), n);
    const ended = try arena.alloc(std.atomic.Value(bool), n);
    for (live, ended) |*l, *e| {
        l.* = .init(0);
        e.* = .init(false);
    }
    const replayed_steps = try arena.alloc(bool, n);
    @memset(replayed_steps, false);
    const step_commands = try arena.alloc(Shared.StepCommands, n);
    @memset(step_commands, .{});
    const line_counts = try arena.alloc(u32, n);
    @memset(line_counts, 0);
    const service_logs = try arena.alloc(std.ArrayList([]const u8), job.services.len);
    @memset(service_logs, .empty);
    const service_dropped = try arena.alloc(u32, job.services.len);
    @memset(service_dropped, 0);
    const mark = opts.test_step_mark orelse mark: {
        var raw: [12]u8 = undefined;
        io.random(&raw);
        break :mark try arena.dupe(u8, &std.fmt.bytesToHex(raw, .lower));
    };
    return .{
        .io = io,
        .arena = arena,
        .log = log,
        .sink_job_id = opts.sink_job_id,
        .live_lines = live,
        .ended = ended,
        .mark = mark,
        .commands = step_commands,
        .replayed_steps = replayed_steps,
        .line_counts = line_counts,
        .service_logs = service_logs,
        .service_dropped = service_dropped,
        .step_debug = stepDebug(arena, job),
        .workspace = try jobWorkspace(arena, job),
    };
}

/// The session's HTTP endpoint, or the failed Result the job ends with when the session never
/// reported one.
const SessionStart = union(enum) { transport: HttpTransport, failed: Result };

/// From the first line of `dagger run`'s child: "<port> <token>".
fn sessionTransport(
    arena: Allocator,
    io: std.Io,
    child: *std.process.Child,
    sh: *Shared,
    results: []StepResult,
) !SessionStart {
    var first: [512]u8 = undefined;
    var out_reader = child.stdout.?.readerStreaming(io, &first);
    const line = (out_reader.interface.takeDelimiter('\n') catch null) orelse {
        const why = "could not start a Dagger session (is the Docker daemon running?)";
        return .{ .failed = try fail(sh, results, why) };
    };
    var parts = std.mem.tokenizeScalar(u8, line, ' ');
    const port = parts.next() orelse
        return .{ .failed = try fail(sh, results, "Dagger session did not report a port") };
    const token = parts.next() orelse
        return .{ .failed = try fail(sh, results, "Dagger session did not report a token") };
    const basic = try std.fmt.allocPrint(arena, "{s}:", .{token});
    return .{ .transport = .{
        .io = io,
        .url = try std.fmt.allocPrint(arena, "http://127.0.0.1:{s}/query", .{port}),
        .auth = try std.fmt.allocPrint(arena, "Basic {s}", .{try base64Encode(arena, basic)}),
    } };
}

/// A job's session held by this process (`engine.zig`), with no `dagger run` child: queries go over
/// the session, and live output comes from its log stream, routed to steps by span (`SpanDemux`).
fn runDirect(
    arena: Allocator,
    io: std.Io,
    opts: Options,
    job: job_mod.Job,
    sh: *Shared,
    results: []StepResult,
    ep: engine.Endpoint,
) !Result {
    var demux: SpanDemux = .{ .sh = sh, .gpa = opts.gpa };
    defer demux.deinit();
    var sess: engine.Session = undefined;
    // An engine that is starting (just restarted, or updated) refuses connections, or has no socket
    // yet, for up to a minute or so: wait for it, as GitHub's runner waits for Docker, rather than
    // fail the job.
    const started = std.Io.Clock.awake.now(io).toMilliseconds();
    var waiting = false;
    while (true) {
        if (openSession(
            &sess,
            opts,
            io,
            ep,
            .{ .ptr = &demux, .onRecord = SpanDemux.onRecord },
        )) |_| {
            if (waiting) sh.append(0, try engineAcceptedNote(arena, io, started));
            break;
        } else |e| {
            const starting = switch (e) {
                error.ConnectionRefused, error.FileNotFound => true,
                error.ConnectionResetByPeer, error.EngineUnreachable => true,
                else => false,
            };
            const cancelled = if (opts.cancel) |c| c.requested.load(.acquire) else false;
            if (!starting or cancelled or
                std.Io.Clock.awake.now(io).toMilliseconds() - started > engine_wait_ms)
                return fail(sh, results, try engineOpenError(arena, e, ep));
            if (!waiting) sh.append(
                0,
                try std.fmt.allocPrint(arena, "Waiting for the Dagger engine to accept " ++
                    "connections ({s}): it may be starting", .{@errorName(e)}),
            );
            waiting = true;
            io.sleep(.fromSeconds(2), .awake) catch
                return fail(sh, results, try engineOpenError(arena, e, ep));
        }
    }
    // Closing the session ends its log stream; only then has every live line arrived.
    defer {
        sess.close();
        demux.flushPartial();
        noteReusedSteps(sh);
        sh.flush();
    }
    var st: SessionTransport = .{ .s = &sess };
    return runSteps(
        arena,
        io,
        opts,
        job,
        sh,
        results,
        .{ .ptr = &st, .sendFn = SessionTransport.send, .abortFn = SessionTransport.abort },
    );
}

/// How long the engine took to accept the session, once it did after a wait.
fn engineAcceptedNote(arena: Allocator, io: std.Io, started: i64) ![]const u8 {
    const secs = @divTrunc(std.Io.Clock.awake.now(io).toMilliseconds() - started, 1000);
    return std.fmt.allocPrint(arena, "The Dagger engine accepted the session after {d} s.", .{
        secs,
    });
}

/// Opens a session, starting the engine container first if it exists but is stopped, and having the
/// `dagger` CLI create it (`dagger core version`) if it does not exist, as `dagger run` would.
/// How long a job waits for an engine that refuses connections (see `runDirect`).
const engine_wait_ms = 3 * 60 * 1000;

fn openSession(
    sess: *engine.Session,
    opts: Options,
    io: std.Io,
    ep: engine.Endpoint,
    h: engine.LogHandler,
) !void {
    sess.open(opts.gpa, io, ep, h) catch |e| switch (e) {
        error.EngineContainerNotRunning => {
            try engine.startContainer(opts.gpa, io, ep);
            return sess.open(opts.gpa, io, ep, h);
        },
        error.EngineContainerNotFound => {
            var child = std.process.spawn(
                io,
                .{
                    .argv = &.{ opts.dagger_cmd, "core", "version" },
                    .stdin = .ignore,
                    .stdout = .ignore,
                    .stderr = .ignore,
                },
            ) catch return e;
            _ = child.wait(io) catch return e;
            return sess.open(opts.gpa, io, ep, h);
        },
        else => return e,
    };
}

fn engineOpenError(arena: Allocator, e: anyerror, ep: engine.Endpoint) ![]const u8 {
    if (ep.host.len > 0) return std.fmt.allocPrint(
        arena,
        "could not start a Dagger session on the engine at {s}: {s}",
        .{ ep.host, @errorName(e) },
    );
    return switch (e) {
        error.EngineContainerNotFound => std.fmt.allocPrint(
            arena,
            "the Dagger engine container '{s}' does not exist and `dagger core version` did " ++
                "not create it (set RUNNER_ENGINE=cli to use the dagger CLI instead)",
            .{ep.container},
        ),
        error.FileNotFound, error.ConnectionRefused => std.fmt.allocPrint(
            arena,
            "could not reach the Docker API at {s} (is Docker running? DOCKER_HOST sets " ++
                "another socket)",
            .{ep.docker_socket},
        ),
        else => std.fmt.allocPrint(
            arena,
            "could not start a Dagger session on '{s}': {s}",
            .{ ep.container, @errorName(e) },
        ),
    };
}

/// actions/checkout's inputs and defaults, in its order, for the step's log header (the token is
/// the job's GITHUB_TOKEN, a secret; `repository` is the job's).
const checkout_defaults = [_][2][]const u8{
    .{
        "repository",
        "",
    },
    .{ "token", "***" },
    .{ "ssh-strict", "true" },
    .{
        "ssh-user",
        "git",
    },
    .{ "persist-credentials", "true" },
    .{ "clean", "true" },
    .{
        "sparse-checkout-cone-mode",
        "true",
    },
    .{ "fetch-depth", "1" },
    .{ "fetch-tags", "false" },
    .{
        "show-progress",
        "true",
    },
    .{ "lfs", "false" },
    .{ "submodules", "false" },
    .{ "set-safe-directory", "true" },
};

/// Opens a `run:` step's log as GitHub's runner does: the command folded away with its shell and
/// the env it gets (workflow, job and step `env:`, and GITHUB_ENV; secret values are masked by the
/// log).
fn logRunHeader(
    arena: Allocator,
    sh: *Shared,
    num: u32,
    script: []const u8,
    shell: ?[]const u8,
    env: []const job_mod.EnvVar,
) !void {
    sh.append(num, try std.fmt.allocPrint(arena, "##[group]Run {s}", .{firstLine(script)}));
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, script, "\n"), '\n');
    while (lines.next()) |l| sh.append(num, l);
    sh.append(num, try shellLine(arena, shell));
    if (env.len > 0) {
        sh.append(num, "env:");
        for (env) |e| sh.append(
            num,
            try std.fmt.allocPrint(arena, "  {s}: {s}", .{ e.name, firstLine(e.value) }),
        );
    }
    sh.append(num, "##[endgroup]");
}

/// What GitHub's runner logs when a script exits non-zero.
fn logExitCode(sh: *Shared, num: u32, code: i32) void {
    sh.errorLine(
        num,
        std.fmt.allocPrint(sh.arena, "Process completed with exit code {d}.", .{code}) catch return,
    );
}

/// The `env` context a step sees: the job's (workflow, job, GITHUB_ENV), then the step's own.
fn envContext(
    arena: Allocator,
    job_env: []const job_mod.EnvVar,
    step_env: []const job_mod.EnvVar,
) ![]const job_mod.EnvVar {
    var out: std.ArrayList(job_mod.EnvVar) = .empty;
    try out.appendSlice(arena, job_env);
    for (step_env) |e| try Evaluator.putEnv(arena, &out, e.name, e.value);
    return out.items;
}

/// Sends GraphQL over a direct session.
const SessionTransport = struct {
    s: *engine.Session,

    fn send(ptr: *anyopaque, arena: Allocator, doc: []const u8, limit: usize) anyerror![]const u8 {
        const t: *SessionTransport = @ptrCast(@alignCast(ptr));
        return t.s.query(arena, doc, limit);
    }

    fn abort(ptr: *anyopaque) bool {
        const t: *SessionTransport = @ptrCast(@alignCast(ptr));
        return t.s.abort();
    }
};

/// Runs the job's steps once a session is up (through `dagger run` or directly).
/// What the base container is built from, decided before any query is sent.
const BasePlan = struct {
    job_image: []const u8,
    provision: bool,
    as_runner: bool,
    step_cache: bool,
    uv_env: ?[]const u8,
    cache_ids: []const []const u8,
    /// The volume for Zig's local cache, with `zig_local_cache`.
    zig_local: ?[]const u8 = null,
    /// The output-key store (`Exec.outputs_volume`), when the job setup's query asked for it.
    outputs_volume: ?[]const u8 = null,
    ran_marker: []const u8,
    /// The job's `mark_env` value (`Shared.mark`).
    mark: []const u8,
};

/// The container every step starts from, as one query: the job image behind its registry auth and
/// its own env, the provisioning exec, the workspace and user, the cache mounts, the event payload
/// and the job's environment. Each writer adds its calls to the query; `finish` closes them. On
/// failure the message is in `err_msg` and the caller fails the job with it.
fn baseContainerId(
    arena: Allocator,
    transport: Transport,
    ev: *Evaluator,
    job: job_mod.Job,
    plan: BasePlan,
    secrets: *Secrets,
    err_msg: *[]const u8,
) ![]const u8 {
    var q: Query = .init(arena);
    try q.open("container");
    try writeImage(&q, arena, transport, ev, job, plan, secrets, err_msg);
    try writeProvisionAndWorkspace(&q, arena, ev, plan);
    try writeCacheMounts(&q, arena, plan);
    try writeRunEnv(&q, ev, plan);
    try writeJobEnv(&q, arena, transport, ev, job, secrets, err_msg);
    try q.leaf("id");
    const data = gql(arena, transport, try q.finish(), err_msg) catch
        return error.BaseContainerFailed;
    return jsonFindString(data, "id") orelse {
        err_msg.* = "Dagger returned no container";
        return error.BaseContainerFailed;
    };
}

/// `from` the job image, behind a private registry's credentials when there are any, with a
/// container job's cache variables and its own `env:` set on it.
fn writeImage(
    q: *Query,
    arena: Allocator,
    transport: Transport,
    ev: *Evaluator,
    job: job_mod.Job,
    plan: BasePlan,
    secrets: *Secrets,
    err_msg: *[]const u8,
) !void {
    if (job.container) |jc| {
        // A private image: its registry's credentials.
        if (try registryAuth(
            arena,
            ev,
            transport,
            secrets,
            jc,
            plan.job_image,
            err_msg,
        )) |auth| {
            try q.call("withRegistryAuth", auth);
        } else if (err_msg.len > 0) return error.BaseContainerFailed;
    }
    try q.call("from", .{ .address = plan.job_image });
    // Before the container's env too, so its value (or the workflow's) wins.
    if (plan.zig_local != null) try q.call(
        "withEnvVariable",
        .{ .name = "ZIG_LOCAL_CACHE_DIR", .value = zigLocalCacheDir(plan.as_runner) },
    );
    if (job.container != null) for (plan.cache_ids, 0..) |_, i| {
        // Before the container's env, so its own value wins.
        if (package_cache_dirs[i].env.len == 0) continue;
        try q.call(
            "withEnvVariable",
            .{ .name = package_cache_dirs[i].env, .value = package_cache_dirs[i].path },
        );
    };
    if (job.container) |jc| {
        // The container's env, as `docker create -e` sets it: every step sees it.
        const env = ev.renderEnv(jc.env, try ev.scope(&.{})) catch {
            err_msg.* = try std.fmt.allocPrint(
                arena,
                "could not evaluate the container's env: {s}",
                .{ev.diag},
            );
            return error.BaseContainerFailed;
        };
        for (env) |e| try q.call("withEnvVariable", .{ .name = e.name, .value = e.value });
    }
}

/// Provisioning in the default image, the workspace and RUNNER_TEMP, the step user, and the
/// workdir.
fn writeProvisionAndWorkspace(q: *Query, arena: Allocator, ev: *Evaluator, plan: BasePlan) !void {
    if (plan.provision) {
        const script = if (plan.as_runner) provision_runner_script else provision_script;
        try q.call("withExec", .{ .args = &[_][]const u8{ "sh", "-c", script } });
    }
    // The job's workspace and RUNNER_TEMP, the step user's in the default image (cached per
    // repository). A job container's user may be unable to make them; its steps then report
    // that themselves.
    // With `uv_env_in_cache`, `.venv` in the workspace is a symlink to the environment in the
    // cache, so `uv run`, `.venv/bin/...` and `activate` all keep working. The link is made
    // here, before the checkout, which merges the repository over it and leaves it.
    const link = if (plan.uv_env) |e| try std.fmt.allocPrint(
        arena,
        " && ln -sfn {s} {s}/.venv",
        .{ e, ev.workspace },
    ) else "";
    const chown = if (plan.as_runner) chown_runner else "";
    const mk = if (plan.provision)
        try std.fmt.allocPrint(
            arena,
            "mkdir -p {s} {s}{s}{s}",
            .{ ev.workspace, ev.temp, link, chown },
        )
    else
        try std.fmt.allocPrint(
            arena,
            "mkdir -p {s} {s}{s} 2>/dev/null || true",
            .{ ev.workspace, ev.temp, link },
        );
    try q.call("withExec", .{ .args = &[_][]const u8{ "sh", "-c", mk } });
    if (plan.as_runner) {
        try q.call("withUser", .{ .name = runner_user });
        try q.call("withEnvVariable", .{ .name = "HOME", .value = runner_home });
    }
    try q.call("withWorkdir", .{ .path = ev.workspace });
}

/// One cache volume mount per package manager, owned by the step user when steps run as it.
fn writeCacheMounts(q: *Query, arena: Allocator, plan: BasePlan) !void {
    for (plan.cache_ids, 0..) |id, i| {
        const path = if (plan.as_runner) try runnerCachePath(
            arena,
            i,
        ) else package_cache_dirs[i].path;
        const owner: ?[]const u8 = if (plan.as_runner) runner_user else null;
        try q.call("withMountedCache", .{ .path = path, .cache = id, .owner = owner });
    }
    if (plan.zig_local) |id| try q.call("withMountedCache", .{
        .path = zigLocalCacheDir(plan.as_runner),
        .cache = id,
        .owner = if (plan.as_runner) runner_user else null,
    });
}

/// Run-specific values do not take part in exec cache keys under step caching, so unchanged steps
/// are reused: they travel in a volatile variable rather than an ordinary one.
pub fn envVarNode(is_volatile: bool) []const u8 {
    return if (is_volatile) "withVolatileVariable" else "withEnvVariable";
}

/// The values that identify this run: the event payload, the ran marker, uv's environment, and the
/// default variables — volatile under step caching, so they do not reach exec cache keys.
fn writeRunEnv(q: *Query, ev: *Evaluator, plan: BasePlan) !void {
    // The event payload, as on GitHub (actions read it through GITHUB_EVENT_PATH). It differs on
    // every run, so with step caching it travels in a volatile variable that each step writes to
    // the file; a payload too large for one variable is written into the container instead.
    const event = try ev.eventJson();
    if (plan.step_cache and event.len <= max_event_env) {
        try q.call("withVolatileVariable", .{ .name = event_env, .value = event });
    } else {
        try q.call("withNewFile", .{ .path = event_path, .contents = event });
    }
    if (plan.step_cache)
        try q.call("withVolatileVariable", .{ .name = ran_env, .value = plan.ran_marker });
    // Every step's markers carry it, with step caching or without (`mark_env`).
    try q.call(envVarNode(plan.step_cache), .{ .name = mark_env, .value = plan.mark });
    if (plan.uv_env) |e| {
        try q.call("withEnvVariable", .{ .name = "UV_PROJECT_ENVIRONMENT", .value = e });
        // The environment outlives the job, and `uv venv` refuses to replace one that exists
        // ("A virtual environment already exists at ..."), where on a hosted runner the
        // workspace is new every job and it always succeeds. This keeps `uv venv` meaning
        // "make me a fresh environment"; `uv sync` still reconciles the one that is there.
        try q.call("withEnvVariable", .{ .name = "UV_VENV_CLEAR", .value = "1" });
    }
    for (try ev.defaultEnv()) |e| {
        // Run-specific values do not take part in exec cache keys, so unchanged steps are reused.
        const node = envVarNode(plan.step_cache and isVolatile(e.name));
        try q.call(node, .{ .name = e.name, .value = e.value });
    }
}

/// Workflow- and job-level env is part of every step's environment; what carries a secret goes in
/// as a Dagger secret.
fn writeJobEnv(
    q: *Query,
    arena: Allocator,
    transport: Transport,
    ev: *Evaluator,
    job: job_mod.Job,
    secrets: *Secrets,
    err_msg: *[]const u8,
) !void {
    var plain: std.ArrayList(job_mod.EnvVar) = .empty;
    var secret: std.ArrayList(SecretRef) = .empty;
    splitEnv(
        arena,
        transport,
        job,
        secrets,
        ev.job_env.items,
        &plain,
        &secret,
        err_msg,
    ) catch
        return error.BaseContainerFailed;
    try writeEnvNodes(q, plain.items, secret.items);
}

/// A `run:` step's script, shell and working directory, evaluated, with its header logged as GitHub
/// logs it. Null when evaluation failed: the step has been failed and recorded, and the loop moves
/// on.
fn prepareScript(
    x: *Exec,
    step: job_mod.Step,
    res: *StepResult,
    num: u32,
    coe: bool,
    sc1: expr.Scope,
    step_env: []const job_mod.EnvVar,
    plain_step_env: []const job_mod.EnvVar,
    sc: @FieldType(job_mod.Action, "script"),
) !?Resolved {
    const arena = x.arena;
    const ev = x.ev;
    const script = ev.render(sc.script, sc1) catch {
        const msg = try std.fmt.allocPrint(arena, "could not evaluate the script: {s}", .{ev.diag});
        try failStep(ev, x.sh, x.observer, step, res, num, msg, coe);
        return null;
    };
    const shell: ?[]const u8 = if (sc.shell) |t| (ev.render(t, sc1) catch null) else null;
    if (shell) |sh_name| if (!job_mod.validShell(sh_name)) {
        try failStep(
            ev,
            x.sh,
            x.observer,
            step,
            res,
            num,
            try job_mod.unsupportedShell(arena, sh_name),
            coe,
        );
        return null;
    };
    const wd: ?[]const u8 = if (sc.working_directory) |t| (ev.render(t, sc1) catch null) else null;
    try logRunHeader(
        arena,
        x.sh,
        num,
        script,
        shell,
        try envContext(arena, ev.job_env.items, step_env),
    );
    return .{ .run = .{
        .script = script,
        .shell = shell,
        .working_directory = wd,
        .env = plain_step_env,
    } };
}

/// The built-in checkout: its inputs evaluated and logged as GitHub logs an action's, then the
/// repository fetched. Null when the inputs could not be evaluated, were unsupported, or the fetch
/// failed: the step has been failed and recorded, and the loop moves on.
fn prepareCheckout(
    x: *Exec,
    step: job_mod.Step,
    res: *StepResult,
    num: u32,
    coe: bool,
    sc1: expr.Scope,
    step_env: []const job_mod.EnvVar,
    inputs: []const job_mod.Input,
) !?Fetched {
    const arena = x.arena;
    const ev = x.ev;
    const sh = x.sh;
    const rendered = ev.renderEnv(inputs, sc1) catch {
        const msg = try std.fmt.allocPrint(
            arena,
            "could not evaluate the checkout inputs: {s}",
            .{ev.diag},
        );
        try failStep(ev, sh, x.observer, step, res, num, msg, coe);
        return null;
    };
    try logCheckoutHeader(x, num, step, rendered, step_env);
    const co = switch (try job_mod.checkoutFromInputs(arena, rendered)) {
        .ok => |c| c,
        .unsupported => |why| {
            try failStep(ev, sh, x.observer, step, res, num, why, coe);
            return null;
        },
    };
    const f = try fetchCheckout(arena, x.transport, x.job.*, co, x.gitAuth());
    if (f.result == .failed) {
        try failStep(ev, sh, x.observer, step, res, num, f.result.failed, coe);
        return null;
    }
    return f;
}

/// As GitHub opens an action's log: the action, the inputs the workflow gave it, then
/// actions/checkout's defaults (the same in v4 to v6), then the env.
fn logCheckoutHeader(
    x: *Exec,
    num: u32,
    step: job_mod.Step,
    rendered: []const job_mod.EnvVar,
    step_env: []const job_mod.EnvVar,
) !void {
    const arena = x.arena;
    const sh = x.sh;
    const uses = if (step.uses.len > 0) step.uses else "actions/checkout";
    sh.append(num, try std.fmt.allocPrint(arena, "##[group]Run {s}", .{uses}));
    sh.append(num, "with:");
    for (rendered) |in| sh.append(
        num,
        try std.fmt.allocPrint(arena, "  {s}: {s}", .{ in.name, firstLine(in.value) }),
    );
    for (checkout_defaults) |d| {
        const given = for (rendered) |in| (if (std.mem.eql(
            u8,
            in.name,
            d[0],
        )) break true) else false;
        if (given) continue;
        const value = if (std.mem.eql(u8, d[0], "repository")) x.job.github.repository else d[1];
        sh.append(num, try std.fmt.allocPrint(arena, "  {s}: {s}", .{ d[0], value }));
    }
    const co_env = try envContext(arena, x.ev.job_env.items, step_env);
    if (co_env.len > 0) {
        sh.append(num, "env:");
        for (co_env) |e| sh.append(
            num,
            try std.fmt.allocPrint(arena, "  {s}: {s}", .{ e.name, firstLine(e.value) }),
        );
    }
    sh.append(num, "##[endgroup]");
}

/// One step of the job: its condition, env and timeout evaluated, then run as a script, a checkout,
/// an action or an image, and recorded. Null means the loop moves to the next step — the step ran,
/// was skipped, or was failed and recorded; a Result means the engine failed and the job is over.
fn runStep(
    x: *Exec,
    watch: *Watch,
    cancel: ?*Cancel,
    results: []StepResult,
    step: job_mod.Step,
    res: *StepResult,
    num: u32,
) !?Result {
    const ev = x.ev;
    const arena = x.arena;
    res.name = step.name;
    if (cancel) |c| if (c.requested.load(.acquire)) {
        ev.cancelled = true;
    };
    // 1. The condition, with the job env visible.
    const sc0 = try stepCondition(x, step, res, num) orelse return null;

    // 2. Step env and continue-on-error, then the step's own inputs.
    const step_env = ev.renderEnv(step.env, sc0) catch {
        const msg = try std.fmt.allocPrint(arena, "could not evaluate env: {s}", .{ev.diag});
        // Still the step's failure, so its continue-on-error holds, read without its env: the
        // job went on to fail, and skipped the steps after one that hit the expression memory
        // limit on purpose.
        const coe = std.mem.eql(u8, ev.render(step.continue_on_error, sc0) catch "false", "true");
        try failStep(ev, x.sh, x.observer, step, res, num, msg, coe);
        return null;
    };
    const sc1 = try ev.scope(step_env);
    const coe = std.mem.eql(u8, ev.render(step.continue_on_error, sc1) catch "false", "true");
    res.continued = coe;
    const limit: ?[]const u8 = if (step.timeout_minutes) |t| ev.render(t, sc1) catch null else null;
    const timeout_ms = timeoutMs(limit);

    // Env that carries a secret goes in as a Dagger secret, the rest in the script.
    var plain: std.ArrayList(job_mod.EnvVar) = .empty;
    var secret: std.ArrayList(SecretRef) = .empty;
    x.splitStepEnv(step_env, &plain, &secret) catch {
        const msg = try std.fmt.allocPrint(arena, "Dagger could not register a secret: {s}", .{
            x.err_msg,
        });
        try failStep(ev, x.sh, x.observer, step, res, num, msg, coe);
        return null;
    };

    const how: StepRun = .{ .coe = coe, .timeout = limit, .timeout_ms = timeout_ms, .scope = sc1 };
    var resolved: Resolved = undefined;
    var mount_buf: [1]Mount = undefined;
    var mounts: []const Mount = &.{};
    switch (step.action) {
        .unsupported => |why| {
            try failStep(ev, x.sh, x.observer, step, res, num, why, coe);
            return null;
        },
        .script => |sc| {
            const env = plain.items;
            resolved = try prepareScript(x, step, res, num, coe, sc1, step_env, env, sc) orelse
                return null;
        },
        .checkout => |inputs| {
            const f = try prepareCheckout(x, step, res, num, coe, sc1, step_env, inputs) orelse
                return null;
            resolved = .{ .checkout = f };
            const dir = f.result.dir;
            mount_buf[0] = .{ .dir = .{ .path = f.mount, .id = dir, .owner = x.dir_owner } };
            mounts = &mount_buf;
        },
        .uses, .docker => {
            return runActionStep(x, watch, results, step, res, num, how, plain.items, secret.items);
        },
    }
    return runResolvedStep(x, watch, results, step, res, num, how, resolved, mounts, secret.items);
}

/// What a step runs under once its env is evaluated: continue-on-error, its timeout as written and
/// in milliseconds (0 for none), and the scope its expressions see.
const StepRun = struct {
    coe: bool,
    timeout: ?[]const u8,
    timeout_ms: i64,
    scope: expr.Scope,
};

/// `timeout-minutes` as written, in milliseconds; 0 when absent, unparsable or not positive. At
/// most a year: a larger number (`1e300`, `inf`) would not fit, and converting it panics.
fn timeoutMs(timeout: ?[]const u8) i64 {
    const t = timeout orelse return 0;
    const minutes = std.fmt.parseFloat(f64, std.mem.trim(u8, t, " ")) catch return 0;
    if (!(minutes > 0)) return 0;
    return @intFromFloat(@min(minutes, 366 * 24 * 60) * 60_000);
}

test "timeoutMs reads timeout-minutes, and a number too large to hold is a year" {
    try std.testing.expectEqual(@as(i64, 0), timeoutMs(null));
    try std.testing.expectEqual(@as(i64, 90_000), timeoutMs(" 1.5 "));
    try std.testing.expectEqual(@as(i64, 0), timeoutMs("-1"));
    try std.testing.expectEqual(@as(i64, 0), timeoutMs("nan"));
    const year: i64 = 366 * 24 * 60 * 60_000;
    try std.testing.expectEqual(year, timeoutMs("1e300"));
    try std.testing.expectEqual(year, timeoutMs("inf"));
}

/// The step's name and condition, evaluated with the job env visible. Returns the scope the rest of
/// the step is evaluated in, or null when the step was skipped or could not be evaluated — in both
/// cases it has been recorded and the loop moves on.
fn stepCondition(x: *Exec, step: job_mod.Step, res: *StepResult, num: u32) !?expr.Scope {
    const ev = x.ev;
    const arena = x.arena;
    ev.diag = "";
    const sc0 = try ev.scope(&.{});
    // Evaluated with `secrets` in scope, and shown on GitHub, in the live view and in the database.
    if (step.name_expr) |ne| res.name = try x.sh.redacted(arena, expr.evalString(arena, ne, sc0) catch step.name);
    const should_run = expr.evalCondition(arena, step.condition, sc0) catch {
        const msg = try std.fmt.allocPrint(
            arena,
            "could not evaluate the condition '{s}': {s}",
            .{ step.condition, ev.diag },
        );
        try failStep(ev, x.sh, x.observer, step, res, num, msg, false);
        return null;
    };
    if (!should_run) {
        res.outcome = .skipped;
        try ev.record(step, .skipped, false, &.{});
        if (x.observer) |o| o.finished(num, res.*);
        return null;
    }
    return sc0;
}

/// A `uses:` action or a `docker://` image step: timed, watched for its timeout, and recorded.
fn runActionStep(
    x: *Exec,
    watch: *Watch,
    results: []StepResult,
    step: job_mod.Step,
    res: *StepResult,
    num: u32,
    how: StepRun,
    plain: []const job_mod.EnvVar,
    secret: []const SecretRef,
) !?Result {
    res.started_ms = std.Io.Clock.real.now(x.io).toMilliseconds();
    if (x.observer) |o| o.started(num, res.name, res.started_ms);
    watch.begin(if (how.timeout_ms > 0) res.started_ms + how.timeout_ms else 0);
    const ran = switch (step.action) {
        .uses => |u| x.runAction(num, u, how.scope, plain, secret, false),
        .docker => |d| x.runImageStep(num, d, how.scope, plain, secret),
        else => unreachable,
    };
    const intr = watch.end();
    const out = ran catch |e| switch (e) {
        error.EngineFailed => if (intr != .none) {
            try stepInterrupted(
                x.ev,
                x.sh,
                x.observer,
                step,
                res,
                num,
                how.coe,
                intr,
                how.timeout orelse "",
            );
            return null;
        } else return try engineFailed(x, x.observer, res, num, how.coe, results),
        else => return e,
    };
    try recordOutcome(
        x,
        step,
        res,
        num,
        how.coe,
        if (out.failed) .failure else .success,
        out.exit_code,
        out.outputs,
    );
    return null;
}

/// A script or a checkout, resolved, run through `execScript`: timed, watched for its timeout, and
/// recorded. A checkout also queues its post step, as actions/checkout has one.
fn runResolvedStep(
    x: *Exec,
    watch: *Watch,
    results: []StepResult,
    step: job_mod.Step,
    res: *StepResult,
    num: u32,
    how: StepRun,
    resolved: Resolved,
    mounts: []const Mount,
    secret: []const SecretRef,
) !?Result {
    res.started_ms = std.Io.Clock.real.now(x.io).toMilliseconds();
    if (x.observer) |o| o.started(num, res.name, res.started_ms);
    watch.begin(if (how.timeout_ms > 0) res.started_ms + how.timeout_ms else 0);
    const name = if (step.context_name.len > 0) step.context_name else step.id;
    const ran = x.execScript(num, num, resolved, name, secret, mounts);
    const intr = watch.end();
    const out = ran catch |e| switch (e) {
        error.EngineFailed => if (intr != .none) {
            try stepInterrupted(
                x.ev,
                x.sh,
                x.observer,
                step,
                res,
                num,
                how.coe,
                intr,
                how.timeout orelse "",
            );
            return null;
        } else return try engineFailed(x, x.observer, res, num, how.coe, results),
        else => return e,
    };
    if (resolved == .run and out.code != 0) logExitCode(x.sh, num, out.code);
    // As actions/checkout, a post step once the checkout ran (see `Post.checkout`).
    if (resolved == .checkout) try appendCheckoutPost(x, num, res.name);
    try recordOutcome(
        x,
        step,
        res,
        num,
        how.coe,
        if (out.code == 0) .success else .failure,
        out.code,
        out.outputs,
    );
    return null;
}

/// What every step ends with: its times and outcome on the result, the evaluator told, the job
/// marked failed unless the step continues on error, and the observer told it finished.
/// A composite action's step whose condition was false, as `steps.<id>` sees it.
/// `s` with its expressions evaluated, itself when there is none or they fail, null for null.
/// A JavaScript action's script as a `run:` step: no shell, no working directory.
pub fn scriptRun(script: []const u8, env: []const job_mod.EnvVar) Resolved {
    return .{ .run = .{ .script = script, .shell = null, .working_directory = null, .env = env } };
}

fn interpolateOptional(arena: Allocator, s: ?[]const u8, sc: expr.Scope) ?[]const u8 {
    const d = s orelse return null;
    return expr.interpolate(arena, d, sc) catch d;
}

fn skippedStep(id: []const u8) StepCtx {
    return .{ .id = id, .outcome = "skipped", .conclusion = "skipped", .outputs = &.{} };
}

fn recordOutcome(
    x: *Exec,
    step: job_mod.Step,
    res: *StepResult,
    num: u32,
    coe: bool,
    outcome: Outcome,
    exit_code: i32,
    outputs: []const job_mod.EnvVar,
) !void {
    res.completed_ms = std.Io.Clock.real.now(x.io).toMilliseconds();
    res.outcome = outcome;
    res.exit_code = exit_code;
    try x.ev.record(step, res.outcome, coe, outputs);
    if (res.outcome == .failure and !coe) x.ev.job_failed = true;
    if (x.observer) |o| o.finished(num, res.*);
}

fn appendCheckoutPost(x: *Exec, num: u32, name: []const u8) !void {
    try x.posts.append(x.arena, .{
        .num = num,
        .name = try std.fmt.allocPrint(x.arena, "Post {s}", .{name}),
        .act = undefined,
        .u = undefined,
        .script = "",
        .condition = "always()",
        .inputs = &.{},
        .step_env = &.{},
        .step_secret = &.{},
        .state = &.{},
        .checkout = true,
    });
}

fn runSteps(
    arena: Allocator,
    io: std.Io,
    opts: Options,
    job: job_mod.Job,
    sh: *Shared,
    results: []StepResult,
    transport: Transport,
) !Result {
    var ev = try Evaluator.init(arena, &job);
    ev.runner_name = opts.runner_name;
    ev.runner_debug = sh.step_debug;
    var err_msg: []const u8 = "";
    // Services hold state a cached step would not have changed (a migration replayed from cache
    // leaves a fresh database empty), so a job with services runs every step.
    const no_services = job.services.len == 0;
    const step_cache = opts.step_cache and !optsOutOfStepCache(ev.job_env.items) and no_services;
    var secrets: Secrets = .{};
    const plan = basePlan(
        arena,
        io,
        transport,
        &ev,
        job,
        opts,
        step_cache,
        sh.mark,
        &secrets,
        &err_msg,
    ) catch |e| switch (e) {
        error.BaseContainerFailed => return fail(sh, results, err_msg),
        else => return e,
    };
    const base = baseContainerId(arena, transport, &ev, job, plan, &secrets, &err_msg) catch |e|
        switch (e) {
            error.BaseContainerFailed => return fail(sh, results, err_msg),
            else => return e,
        };
    var x = try execFor(arena, io, transport, sh, &ev, &job, opts, plan, base, secrets, step_cache);
    ev.hash_files = .{ .ptr = &x, .hashFn = Exec.hashFiles };

    var watch: Watch = .{ .io = io, .transport = transport, .cancel = opts.cancel };
    var watching: ?std.Io.Future(void) = null;
    if (transport.abortFn != null) watching = io.concurrent(Watch.run, .{&watch}) catch null;
    defer if (watching) |*f| {
        watch.done.store(true, .release);
        f.cancel(io);
    };

    if (try setUpJob(&x, opts, results)) |failed| return failed;

    if (job.container != null or !no_services) {
        if (!try x.startServices()) return servicesFailed(&x, arena, sh, results);
    }
    if (try runPres(&x, arena, sh, results, job)) |failed| return failed;
    for (job.steps, results, 1..) |step, *res, n| {
        const num: u32 = @intCast(n);
        if (try runStep(&x, &watch, opts.cancel, results, step, res, num)) |finished|
            return finished;
    }
    return finishJob(&x, opts, results);
}

/// The job, failed at "Initialize containers": every step not run, the service steps shown.
fn servicesFailed(x: *Exec, arena: Allocator, sh: *Shared, results: []StepResult) !Result {
    var failed = try finish(arena, sh, results, "");
    failed.succeeded = false;
    failed.engine_error = null;
    failed.extra = x.extra.items;
    failed.next_log_step = x.next_log_step;
    return failed;
}

/// JavaScript actions' `pre` scripts, before any step, as on GitHub. The job's result when the
/// engine failed on one; null to go on.
fn runPres(
    x: *Exec,
    arena: Allocator,
    sh: *Shared,
    results: []StepResult,
    job: job_mod.Job,
) !?Result {
    for (job.steps, 1..) |step, n| if (step.action == .uses) {
        x.runPre(@intCast(n), step) catch |e| switch (e) {
            error.EngineFailed => return try finish(arena, sh, results, x.err_msg),
            else => return e,
        };
    };
    return null;
}

/// The job's name as GitHub shows it: its display name, else its key in the workflow, else "job".
fn jobLabel(job: job_mod.Job) []const u8 {
    if (job.display_name.len > 0) return job.display_name;
    return if (job.github.job.len > 0) job.github.job else "job";
}

/// What the job runs in, decided before any step: the image, whether it is provisioned and steps
/// run as the runner user, uv's environment, the package cache volumes, and this job's run marker.
/// On failure the message is in `err_msg` and the caller fails the job with it.
fn basePlan(
    arena: Allocator,
    io: std.Io,
    transport: Transport,
    ev: *Evaluator,
    job: job_mod.Job,
    opts: Options,
    step_cache: bool,
    mark: []const u8,
    secrets: *Secrets,
    err_msg: *[]const u8,
) !BasePlan {
    // `container:` replaces the image every step runs in.
    const job_image: []const u8 = if (job.container) |jc| (ev.render(
        jc.image,
        try ev.scope(&.{}),
    ) catch "") else opts.image;
    if (job_image.len == 0) {
        err_msg.* = try std.fmt.allocPrint(arena, "container: has no image: {s}", .{ev.diag});
        return error.BaseContainerFailed;
    }
    const provision = opts.provision and std.mem.eql(u8, job_image, default_image);
    const as_runner = provision and opts.step_user == .runner;
    const ran_marker = opts.test_ran_marker orelse ran: {
        var raw: [12]u8 = undefined;
        io.random(&raw);
        break :ran try arena.dupe(u8, &std.fmt.bytesToHex(raw, .lower));
    };
    const volumes = try cacheVolumeIds(
        arena,
        transport,
        ev,
        job,
        opts,
        job_image,
        as_runner,
        step_cache,
        secrets,
        err_msg,
    );
    return .{
        .job_image = job_image,
        .provision = provision,
        .as_runner = as_runner,
        .step_cache = step_cache,
        .uv_env = try uvEnvFor(arena, opts, job, as_runner, step_cache),
        .cache_ids = volumes.ids,
        .zig_local = volumes.zig_local,
        .outputs_volume = volumes.outputs,
        .ran_marker = ran_marker,
        .mark = mark,
    };
}

/// uv's project environment, inside its cache volume so uv can hardlink into it (see `uvEnvPath`).
/// Null when there is no cache volume to put it in, and when the job's steps are cached: a cache
/// volume's content is not part of a step's key and a replayed step's writes into one are not made
/// again, so a replayed `uv sync` would leave the environment another commit's job synced there,
/// and later steps would run against its dependencies (#70). Left in the workspace, the environment
/// is part of the container each step produces, and a replay restores it exactly; uv's download
/// and wheel cache stays in its volume, content-addressed and safe to share.
fn uvEnvFor(
    arena: Allocator,
    opts: Options,
    job: job_mod.Job,
    as_runner: bool,
    step_cache: bool,
) !?[]const u8 {
    if (!opts.uv_env_in_cache or !opts.package_caches or job.github.repository.len == 0)
        return null;
    if (step_cache) return null;
    const i = for (
        package_cache_dirs,
        0..,
    ) |d, n| (if (std.mem.eql(u8, d.name, "uv")) break n) else return null;
    const path = if (job.container != null)
        package_cache_dirs[i].path
    else if (as_runner)
        try runnerCachePath(arena, i)
    else
        package_cache_dirs[i].path;
    return try uvEnvPath(arena, path, job.github.ref);
}

const CacheVolumes = struct {
    ids: []const []const u8 = &.{},
    zig_local: ?[]const u8 = null,
    outputs: ?[]const u8 = null,
};

/// Package managers' caches persist across jobs in Dagger cache volumes (see `package_cache_dirs`):
/// one query asks for every volume's id, and for Zig's local cache's with `zig_local_cache`. None
/// when caches are off or there is no repository to key them by.
///
/// The same query registers the secrets the base container needs (`baseSecrets`) and, being sent
/// anyway, those the job's steps will (`stepSecrets`), and asks for the output-key store: one round
/// trip where each was one of its own. Without caches the secrets the base needs go in it alone;
/// with neither, nothing is sent. Should the query fail with secrets in it, it is sent again
/// without them, which are then registered when first needed, failing as they always did.
fn cacheVolumeIds(
    arena: Allocator,
    transport: Transport,
    ev: *Evaluator,
    job: job_mod.Job,
    opts: Options,
    job_image: []const u8,
    as_runner: bool,
    step_cache: bool,
    secrets: *Secrets,
    err_msg: *[]const u8,
) !CacheVolumes {
    const caches = opts.package_caches and job.github.repository.len > 0;
    const needed = try baseSecrets(arena, ev, job);
    if (!caches and (try secrets.missing(arena, needed)).len == 0) return .{};
    const ahead = try std.mem.concat(arena, []const u8, &.{ needed, try stepSecrets(arena, job) });
    const pending = try secrets.missing(arena, ahead);
    const set_up: SetUpQuery = .{
        .ev = ev,
        .job = job,
        .opts = opts,
        .job_image = job_image,
        .as_runner = as_runner,
        .caches = caches,
        .outputs_key = try outputKeysKey(arena, ev, job, opts, step_cache),
    };
    var msg: []const u8 = "";
    if (try set_up.send(arena, transport, secrets, pending, &msg)) |v| return v;
    if (!caches) return .{};
    if (pending.len == 0) {
        err_msg.* = msg;
        return error.BaseContainerFailed;
    }
    return try set_up.send(arena, transport, secrets, &.{}, err_msg) orelse
        error.BaseContainerFailed;
}

/// `cacheVolumeIds`' query: the cache volumes with `caches`, the output-key store with
/// `outputs_key`, and the secrets asked for.
const SetUpQuery = struct {
    ev: *Evaluator,
    job: job_mod.Job,
    opts: Options,
    job_image: []const u8,
    as_runner: bool,
    caches: bool,
    outputs_key: ?[]const u8,

    /// Sends the query with `pending` registered. Null, with the reason in `err_msg`, when it
    /// failed or lacked an answer.
    fn send(
        u: SetUpQuery,
        arena: Allocator,
        transport: Transport,
        secrets: *Secrets,
        pending: []const []const u8,
        err_msg: *[]const u8,
    ) !?CacheVolumes {
        var q: Query = .init(arena);
        try secrets.write(arena, &q, pending);
        if (u.outputs_key) |key| {
            try q.callAs("cout", "cacheVolume", .{ .key = key });
            try q.leaf("id");
            try q.close(1);
        }
        if (u.caches) try writeCacheVolumes(&q, arena, u.ev, u.job, u.opts, u.job_image, u.as_runner);
        const data = gql(arena, transport, try q.finish(), err_msg) catch return null;
        if (!try secrets.read(arena, data, pending)) {
            err_msg.* = "Dagger returned no secret id";
            return null;
        }
        var out: CacheVolumes = .{};
        if (u.outputs_key != null)
            out.outputs = if (jsonFind(data, "cout")) |v| jsonFindString(v, "id") else null;
        if (!u.caches) return out;
        const no_volume = "Dagger returned no cache volume";
        const ids = try arena.alloc([]const u8, package_cache_dirs.len);
        for (ids, 0..) |*id, i| {
            const v = jsonFind(data, try std.fmt.allocPrint(arena, "c{d}", .{i})) orelse {
                err_msg.* = no_volume;
                return null;
            };
            id.* = jsonFindString(v, "id") orelse {
                err_msg.* = no_volume;
                return null;
            };
        }
        out.ids = ids;
        if (u.opts.zig_local_cache) {
            const v = jsonFind(data, "czl") orelse {
                err_msg.* = no_volume;
                return null;
            };
            out.zig_local = jsonFindString(v, "id") orelse {
                err_msg.* = no_volume;
                return null;
            };
        }
        return out;
    }
};

/// One `cacheVolume` per package manager (`c<i>`), and Zig's local cache's (`czl`).
fn writeCacheVolumes(
    q: *Query,
    arena: Allocator,
    ev: *Evaluator,
    job: job_mod.Job,
    opts: Options,
    job_image: []const u8,
    as_runner: bool,
) !void {
    const scope = try packageCacheScope(arena, ev, job.github.repository);
    // Its own volume, so the engine can collect it (it only grows) without the global cache.
    if (opts.zig_local_cache) {
        const key = try std.fmt.allocPrint(
            arena,
            "zig-runner/{s}/{s}/zig-local{s}",
            .{ job.github.repository, scope, if (as_runner) "/" ++ runner_user else "" },
        );
        try q.callAs("czl", "cacheVolume", .{ .key = key });
        try q.leaf("id");
        try q.close(1);
    }
    for (package_cache_dirs, 0..) |d, i| {
        // The tool cache holds binaries built for one image (glibc or musl, its libraries), so
        // each image has its own.
        const key = if (std.mem.eql(u8, d.name, "toolcache"))
            try std.fmt.allocPrint(
                arena,
                "zig-runner/{s}/{s}/{s}/{s}",
                .{ job.github.repository, scope, d.name, job_image },
            )
        else
            try std.fmt.allocPrint(
                arena,
                "zig-runner/{s}/{s}/{s}",
                .{ job.github.repository, scope, d.name },
            );
        // Volumes root filled hold files `runner_user` cannot write: steps that run as it get
        // their own.
        const user_key = if (as_runner) try std.mem.concat(
            arena,
            u8,
            &.{ key, "/", runner_user },
        ) else key;
        try q.callAs(
            try std.fmt.allocPrint(arena, "c{d}", .{i}),
            "cacheVolume",
            .{ .key = user_key },
        );
        try q.leaf("id");
        try q.close(1);
    }
}

/// The secrets the base container is made with: a private job image's registry password, and
/// job-level env that carries one.
fn baseSecrets(arena: Allocator, ev: *Evaluator, job: job_mod.Job) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (job.container) |jc| if (try registryCredentials(ev, jc)) |c| try out.append(arena, c.pass);
    for (ev.job_env.items) |e| if (containsSecret(job, e.value)) try out.append(arena, e.value);
    return out.items;
}

/// Secrets the job's steps will register if nothing else does: the job token, which every action
/// gets (ACTIONS_RUNTIME_TOKEN) and OIDC requests use, and GITHUB_TOKEN, which fetches checkouts
/// and the job's own repository's actions. One costs only its field in a query sent anyway.
fn stepSecrets(arena: Allocator, job: job_mod.Job) ![]const []const u8 {
    var actions = false;
    var fetches = false;
    for (job.steps) |st| switch (st.action) {
        .uses => {
            actions = true;
            fetches = true;
        },
        .docker => actions = true,
        .checkout => fetches = true,
        else => {},
    };
    var out: std.ArrayList([]const u8) = .empty;
    if ((actions or job.runtime.id_token_url.len > 0) and containsSecret(job, job.job_token))
        try out.append(arena, job.job_token);
    if (fetches) for (job.secret_vars) |sv| {
        if (std.mem.eql(u8, sv.name, "GITHUB_TOKEN") and sv.value.len > 0)
            try out.append(arena, sv.value);
    };
    return out.items;
}

/// The Exec a job's steps run through, from everything decided before the first step.
fn execFor(
    arena: Allocator,
    io: std.Io,
    transport: Transport,
    sh: *Shared,
    ev: *Evaluator,
    job: *const job_mod.Job,
    opts: Options,
    plan: BasePlan,
    container_id: []const u8,
    secrets: Secrets,
    step_cache: bool,
) !Exec {
    return .{
        .arena = arena,
        .io = io,
        .transport = transport,
        .sh = sh,
        .ev = ev,
        .job = job,
        .container_id = container_id,
        .secrets = secrets,
        .next_fc = @intCast(job.steps.len + 1),
        .js_runtime = opts.js_runtime,
        .nesting = opts.nesting,
        .step_cache = step_cache,
        .enforce_volatile = step_cache and opts.enforce_volatile,
        .output_keys = try outputKeysKey(arena, ev, job.*, opts, step_cache),
        .outputs_volume = plan.outputs_volume,
        .outputs_days = opts.output_keys_days,
        .event_from_env = step_cache and (try ev.eventJson()).len <= max_event_env,
        .job_secret_env = jobEnvHasSecret(job.*, ev.job_env.items),
        // Per job, not per run: a run's matrix jobs share its id and attempt, and a step that must
        // run in each of them would otherwise be replayed from the first one's result.
        .run_nonce = try std.fmt.allocPrint(
            arena,
            "{s}, job {s}",
            .{ try runNonce(arena, io, ev), plan.ran_marker },
        ),
        .ran_marker = plan.ran_marker,
        .dir_owner = if (plan.as_runner) runner_user else null,
        .execs = try zeroed(arena, u32, logSteps(job.steps.len)),
        .next_log_step = @intCast(job.steps.len + 1),
        .loaded = try nulls(arena, Exec.LoadResult, job.steps.len),
        .pre_state = try emptySlices(arena, job_mod.EnvVar, job.steps.len),
        .summaries = try emptySlices(arena, u8, logSteps(job.steps.len)),
        .job_image = plan.job_image,
        .observer = opts.observer,
    };
}

/// "Set up job": what GitHub's runner logs before the first step, including fetching every action.
/// As on GitHub, an action that cannot be resolved (even one whose step would be skipped) fails
/// "Set up job" with one error naming them all, and no step runs: that is the Result returned.
fn setUpJob(x: *Exec, opts: Options, results: []StepResult) !?Result {
    const arena = x.arena;
    try x.logSetUp(opts);
    var downloaded: std.StringHashMapUnmanaged(void) = .empty;
    var unresolved: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (x.job.steps, 1..) |step, n| if (step.action == .uses and !step.action.uses.local) {
        const lr = try x.loadFor(@intCast(n), step.action.uses);
        if (lr == .unresolved) try unresolved.put(arena, lr.unresolved, {});
        if (lr != .ok) continue;
        const u = step.action.uses;
        const label = try std.fmt.allocPrint(arena, "{s}/{s}@{s}", .{ u.owner, u.name, u.ref });
        if ((try downloaded.getOrPut(arena, label)).found_existing) continue;
        x.setUpLine(if (lr.ok.sha.len > 0)
            try std.fmt.allocPrint(
                arena,
                "Download action repository '{s}' (SHA:{s})",
                .{ label, lr.ok.sha },
            )
        else
            try std.fmt.allocPrint(arena, "Download action repository '{s}'", .{label}));
    };
    if (unresolved.count() > 0) {
        x.sh.errorLine(0, try std.mem.join(arena, ". ", unresolved.keys()));
        var failed = try finish(arena, x.sh, results, "");
        failed.succeeded = false;
        failed.engine_error = null;
        failed.set_up_failed = true;
        return failed;
    }
    const job = x.job;
    x.setUpLine(try std.fmt.allocPrint(arena, "Complete job name: {s}", .{jobLabel(job.*)}));
    return null;
}

/// After the last step: the `post` scripts, last first, then the services, then the job's result
/// and outputs.
fn finishJob(x: *Exec, opts: Options, results: []StepResult) !Result {
    const arena = x.arena;
    const job = x.job;
    const stopping = job.services.len > 0 or job.container != null;
    if (x.posts.items.len > 0 or stopping)
        if (opts.observer) |o| if (o.postsFn) |f| f(o.ptr, @intCast(x.posts.items.len), stopping);
    x.runPosts() catch |e| switch (e) {
        error.EngineFailed => return finish(arena, x.sh, results, x.err_msg),
        else => return e,
    };
    try x.stopServices();
    var result = try finish(arena, x.sh, results, "");
    if (x.hook_failed) result.succeeded = false;
    if (opts.cancel) |c| if (c.requested.load(.acquire)) {
        x.ev.cancelled = true;
    };
    if (x.ev.cancelled) {
        result.cancelled = true;
        result.succeeded = false;
    }
    result.extra = x.extra.items;
    result.output_keys = .{
        .applied = x.outputs_applied,
        .fell_back = x.outputs_fell_back,
        .last_reason = x.outputs_last_reason,
        .ms = x.outputs_ms,
    };
    result.next_log_step = x.next_log_step;
    result.summaries = x.summaries;
    try jobOutputs(arena, x.ev, x.sh, job.*, &result);
    return result;
}

/// Evaluates the job's outputs as GitHub's runner does when it finishes a job: against the final
/// contexts (the steps' outputs and outcomes), each output a string. One that would carry a secret
/// is dropped with GitHub's warning (later jobs could read it); one that cannot be evaluated is
/// dropped with the reason.
fn jobOutputs(arena: Allocator, ev: *Evaluator, sh: *Shared, job: job_mod.Job, result: *Result) !void {
    if (job.outputs.len == 0) return;
    var outs: std.ArrayList(job_mod.EnvVar) = .empty;
    var lines: std.ArrayList([]const u8) = .empty;
    try lines.append(arena, "Evaluate and set job outputs");
    for (job.outputs) |o| {
        ev.diag = "";
        const sc = try ev.scope(&.{});
        const value = ev.render(o.value, sc) catch {
            try lines.append(
                arena,
                try std.fmt.allocPrint(arena, "##[warning]Could not evaluate output " ++
                    "'{s}': {s}", .{ o.name, ev.diag }),
            );
            continue;
        };
        // Against every secret and mask, in every form (`::add-mask::` values too: an OIDC-minted
        // token is one), as GitHub's runner checks job outputs.
        if (containsSecret(job, value) or sh.holdsSecret(value)) {
            try lines.append(
                arena,
                try std.fmt.allocPrint(arena, "##[warning]Skip output '{s}' since it may " ++
                    "contain secret.", .{o.name}),
            );
            continue;
        }
        try outs.append(arena, .{ .name = o.name, .value = value });
        try lines.append(arena, try std.fmt.allocPrint(arena, "Set output '{s}'", .{o.name}));
    }
    result.outputs = outs.items;
    result.output_lines = lines.items;
}

fn zeroed(arena: Allocator, comptime T: type, n: usize) ![]T {
    const s = try arena.alloc(T, n);
    @memset(s, 0);
    return s;
}

fn nulls(arena: Allocator, comptime T: type, n: usize) ![]?T {
    const s = try arena.alloc(?T, n);
    @memset(s, null);
    return s;
}

fn emptySlices(arena: Allocator, comptime T: type, n: usize) ![][]const T {
    const s = try arena.alloc([]const T, n);
    @memset(s, &.{});
    return s;
}

/// A directory mounted into the container for one exec.
pub const Mount = union(enum) {
    /// `owner`: who owns the copy (`Exec.dir_owner`), so steps that do not run as root can write
    /// it.
    dir: struct { path: []const u8, id: []const u8, owner: ?[]const u8 = null },
    file: struct { path: []const u8, id: []const u8, permissions: u32 },
    new_file: struct { path: []const u8, contents: []const u8, permissions: u32 },
};

/// What running steps needs, shared by the job's own steps and the steps of composite actions.
pub const Exec = struct {
    arena: Allocator,
    io: std.Io,
    transport: Transport,
    sh: *Shared,
    ev: *Evaluator,
    job: *const job_mod.Job,
    /// The container after the last exec; each exec starts from it.
    container_id: []const u8,
    /// What Dagger said when a query failed.
    err_msg: []const u8 = "",
    /// The secrets registered in the session (see `Secrets`).
    secrets: Secrets,
    /// File-command ids for the steps of composite actions, after the job's own step numbers.
    next_fc: u32,
    js_runtime: config.JsRuntime,
    /// Whether the JavaScript runtime is in the container yet (it is added by the first JS action).
    js_mounted: bool = false,
    /// Whether Node, for actions Bun cannot load, is in the container yet (see `nodeFallback`).
    node_fallback_mounted: bool = false,
    /// Per log step (index = step - 1, see `ExtraStep`): execs so far.
    execs: []u32,
    /// The next log step number for a `pre` or `post` script, and the scripts that ran.
    next_log_step: u32,
    extra: std.ArrayList(ExtraStep) = .empty,
    /// Per job step (index = step - 1): the action loaded for it, the state its `pre` saved.
    loaded: []?LoadResult,
    pre_state: [][]const job_mod.EnvVar,
    /// What each log step wrote to $GITHUB_STEP_SUMMARY (index = log step - 1), uploaded with the
    /// logs so GitHub shows it on the run's summary page.
    summaries: [][]const u8,
    /// Action directories already mounted (by path), so a later phase sees what an earlier one
    /// left.
    mounted_actions: std.StringHashMapUnmanaged(void) = .empty,
    /// Remote actions loaded so far, by `owner/name/path@ref` (see `loadAction`).
    actions: std.StringHashMapUnmanaged(LoadResult) = .empty,
    /// JavaScript actions' `post` scripts, run after the job's steps in reverse order.
    posts: std.ArrayList(Post) = .empty,
    /// A `pre` or `post` script failed: the job fails, whatever its steps' results.
    hook_failed: bool = false,
    /// Steps may use the job's Dagger engine (see `Options.nesting`).
    nesting: bool,
    /// Unchanged steps may be reused across runs (see `Options.step_cache`).
    step_cache: bool,
    /// See `Options.enforce_volatile`.
    enforce_volatile: bool,
    /// With `Options.output_keys`: the key of the cache volume that stores steps' changes by digest
    /// (scoped like the package caches), and the volume once created.
    output_keys: ?[]const u8,
    outputs_volume: ?[]const u8 = null,
    /// See `Options.output_keys_days`.
    outputs_days: u32,
    /// Always-run steps whose output keyed the next steps, and those that fell back to their own
    /// container (see `Result.output_keys`); why the last one fell back, and the reason, if any,
    /// given during the current attempt.
    outputs_applied: u32 = 0,
    outputs_fell_back: u32 = 0,
    outputs_last_reason: []const u8 = "",
    outputs_reason: ?[]const u8 = null,
    /// Milliseconds spent on output keys in this job (diff, digest, store, copy).
    outputs_ms: i64 = 0,
    /// The event payload is in ZIG_RUNNER_EVENT; each step writes it to GITHUB_EVENT_PATH.
    event_from_env: bool,
    /// Workflow- or job-level env carries a secret, so every step uses secrets.
    job_secret_env: bool,
    /// Differs for every job (the run, its attempt, and `ran_marker`): makes steps that use secrets
    /// run every time, in every job.
    run_nonce: []const u8,
    /// This job's value of `ran_env`.
    ran_marker: []const u8,
    /// Who owns what the runner copies into the job's container (checkouts, actions, the workspace
    /// a Docker action leaves): `runner_user` when steps run as it, else root (null).
    dir_owner: ?[]const u8 = null,
    /// The job token as a Dagger secret, for ACTIONS_ID_TOKEN_REQUEST_TOKEN (registered on first
    /// use).
    id_token_secret: ?[]const u8 = null,
    /// The job's GITHUB_TOKEN as a Dagger secret, for git fetches (see `gitAuth`).
    git_auth: ?union(enum) { none, id: []const u8 } = null,
    /// Docker actions: the static busybox that starts their command, their images (pulled or built
    /// once per job, by `DockerRun.Image` key), and /github/home, which they share, as on GitHub.
    busybox_id: ?[]const u8 = null,
    /// How deep composite actions are nested right now (see `max_composite_depth`).
    depth: u32 = 0,
    /// An empty Directory, for the directories a Docker action's container needs.
    empty_dir: []const u8 = "",
    images: std.StringHashMapUnmanaged(ImageInfo) = .empty,
    docker_home: ?[]const u8 = null,
    /// Told when the runner's own steps start and finish (see `Observer`).
    observer: ?Observer = null,
    /// The image the steps run in: `container:`'s, or the runner's.
    job_image: []const u8 = default_image,
    /// The job's image uses musl (Alpine): JavaScript actions get the runtime's musl build.
    musl: bool = false,
    /// The job's `services:`, running for the whole job (see `startServices`).
    services: std.ArrayList(RunningService) = .empty,
    /// Shell lines at the start of every step that forward `localhost:<port>` to the services, as
    /// a job on GitHub's runner reaches them through ports published on its host.
    forward_prelude: []const u8 = "",

    pub const RunningService = struct {
        name: []const u8,
        id: []const u8,
        ports: []const ServicePort,
    };

    const Post = struct {
        num: u32,
        /// "Post Run x@v1": the step's name for the step's own action, the action for a nested one.
        name: []const u8,
        act: Loaded,
        u: job_mod.Uses,
        script: []const u8,
        condition: []const u8,
        inputs: []const expr.Value.Entry,
        step_env: []const job_mod.EnvVar,
        step_secret: []const SecretRef,
        state: []const job_mod.EnvVar,
        /// A Docker action's `post-entrypoint` (`script` is then the entrypoint).
        docker: ?DockerRun = null,
        /// The built-in checkout's: actions/checkout has a post step (it removes the credentials it
        /// stored); this checkout stores none, so it only takes its place in the job's steps.
        checkout: bool = false,
    };

    /// A Docker action to run: its image and how it is started (see `runContainer`).
    pub const DockerRun = struct {
        image: Image,
        /// Replaces the image's entrypoint, and then its command too, as `docker run --entrypoint`
        /// does.
        entrypoint: ?[]const u8 = null,
        /// Null: the image's command.
        args: ?[]const []const u8 = null,
        /// The step's env, INPUT_<NAME>, the action's `env:`.
        env: []const job_mod.EnvVar,
        secret: []const SecretRef,
        /// `owner/repo@ref` or `docker://<image>`, for the log and messages.
        label: []const u8,
        /// GITHUB_ACTION_REPOSITORY and GITHUB_ACTION_REF; empty for a `docker://` step.
        repository: []const u8 = "",
        ref: []const u8 = "",
        /// The `with:` inputs the workflow gave, for the log.
        shown: []const job_mod.EnvVar = &.{},
        /// The step's own env (also in `env` and `secret`), shown in the log.
        step_env: []const job_mod.EnvVar = &.{},
        step_secret: []const SecretRef = &.{},

        pub const Image = union(enum) {
            pull: []const u8,
            /// Built from `dockerfile` with `context` as the build context, both paths in the
            /// Directory `dir`.
            build: struct { dir: []const u8, context: []const u8, dockerfile: []const u8 },
        };
    };

    /// `user` is the image's USER ("" for root): the action runs as it, so it gets the directories
    /// it writes.
    pub const ImageInfo = struct {
        id: []const u8,
        entrypoint: []const []const u8,
        cmd: []const []const u8,
        user: []const u8,
    };

    pub const Phase = enum {
        pre,
        main,
        post,
        fn label(p: Phase) []const u8 {
            return switch (p) {
                .pre => "Pre",
                .main => "Run",
                .post => "Post",
            };
        }
    };

    pub const ExecOut = struct {
        code: i32,
        outputs: []const job_mod.EnvVar,
        /// From GITHUB_STATE and `::save-state`; a JavaScript action's later phases get it as
        /// STATE_*.
        state: []const job_mod.EnvVar = &.{},
        /// Bun refused to load the program (see `bun_load_errors`): nothing of it ran.
        bun_refused: bool = false,
    };

    /// Runs one script in the job's container, logging as step `num`, and applies its file
    /// commands. `error.EngineFailed` (with `err_msg`) when Dagger itself failed.
    pub fn execScript(
        x: *Exec,
        num: u32,
        fc: u32,
        resolved_in: Resolved,
        action_name: []const u8,
        secret_env_in: []const SecretRef,
        mounts: []const Mount,
    ) !ExecOut {
        const arena = x.arena;
        // What the runner adds for the step, apart from its secrets: the variables earlier steps
        // set, which the container before this step lacks, and the mounts. `outputKeyed` reuses
        // it. Built once: writePendingEnv hands the exports on and forgets them, and a step run
        // again (below) needs them as much as the first try did.
        var env: Query = .initFragment(arena);
        try x.writePendingEnv(&env);
        var mount_nodes: Query = .initFragment(arena);
        try writeMounts(&mount_nodes, mounts);
        // Set when the cache answered with a failure: the step runs again, for real (below).
        var rerun: ?[]const u8 = null;
        while (true) {
            const step_run = try x.resolveRunStep(resolved_in, secret_env_in, rerun);
            const resolved = step_run.resolved;
            const secret_env = step_run.secret_env;
            const script = try std.mem.concat(
                arena,
                u8,
                &.{ x.forward_prelude, try stepScriptFc(arena, num, fc, resolved, action_name) },
            );
            const before = x.container_id;
            var pre: Query = .initFragment(arena);
            try pre.splice(env.fragment());
            try pre.splice(mount_nodes.fragment());

            var q: Query = .init(arena);
            try q.call("loadContainerFromID", .{ .id = x.container_id });
            try q.splice(env.fragment());
            try writeActionSecrets(arena, &q, secret_env);
            try q.splice(mount_nodes.fragment());
            const output_at = try x.writeScriptExec(&q, script, fc, secret_env);
            // A step whose output may key the next steps: what `outputKeyed` needs of the container
            // before it comes in the same query, as a field of its own (nothing is run for it).
            const keyed = x.output_keys != null and resolved == .run and
                resolved.run.always_run != null;
            if (keyed) {
                try q.close(q.depth);
                try writeOlder(&q, before, pre.fragment());
            }

            x.beginExec(num);
            const doc = try q.finish();
            const answer = gql(arena, x.transport, doc, &x.err_msg) catch return error.EngineFailed;
            // The exec's own answer; with `keyed`, the container before it is beside it.
            const data = if (keyed and answer == .object)
                answer.object.get("loadContainerFromID") orelse answer
            else
                answer;
            // A failure the cache kept from an earlier run is not this run's: the step may have
            // failed for a reason that has passed (a network blip, a runner out of memory), and
            // replaying it would fail every re-run the same way until an input changed (#69). So
            // it runs again, marked to run every time, which no earlier run's result can match.
            // Its replayed output is never shown and its file commands never applied.
            if (rerun == null and exitCode(data) != 0 and x.ranThisRun(data) == false) {
                rerun = "its earlier run failed, and a failure is not replayed";
                continue;
            }
            if (jsonFindString(data, "id")) |id| x.container_id = id;
            const out = try x.collect(num, data, .{ .doc = doc, .at = output_at });
            // Any `::add-matcher::` this step emitted: read the files from the container it just
            // produced, which is where the paths it printed are valid.
            x.loadPendingMatchers(num);
            if (keyed and out.code == 0) {
                const started = std.Io.Clock.awake.now(x.io).toMilliseconds();
                const older: ?std.json.Value = if (answer == .object)
                    answer.object.get("zig_older")
                else
                    null;
                if (x.countOutputKeyed(
                    num,
                    started,
                    try x.outputKeyed(num, older, x.container_id),
                )) |id| x.container_id = id;
            }
            return out;
        }
    }

    /// A step as it will run: the script's secret aliases and OIDC token set, and under step
    /// caching its always-run reason or its volatile withholding decided.
    const ScriptRun = struct { resolved: Resolved, secret_env: []const SecretRef };

    /// Secret variables are for scripts only; they reach them through aliases (`secretAlias`). With
    /// `id-token: write`, every step can request OIDC tokens, as on GitHub (`curl
    /// "$ACTIONS_ID_TOKEN_REQUEST_URL"` in a script, `core.getIDToken()` in an action).
    fn resolveRunStep(
        x: *Exec,
        resolved_in: Resolved,
        secret_env_in: []const SecretRef,
        /// Why the step must run again, if the cache answered with a failure (`execScript`).
        rerun: ?[]const u8,
    ) !ScriptRun {
        const arena = x.arena;
        var resolved = resolved_in;
        if (resolved != .run) return .{ .resolved = resolved, .secret_env = &.{} };
        var secret_env: []const SecretRef = secret_env_in;
        const uses_secrets = secret_env.len > 0 or x.job_secret_env or containsSecret(
            x.job.*,
            resolved.run.script,
        );
        const oidc = try x.idToken();
        if (oidc) |t| {
            resolved.run.env = try std.mem.concat(
                arena,
                job_mod.EnvVar,
                &.{ resolved.run.env, &.{t.url} },
            );
            secret_env = try std.mem.concat(arena, SecretRef, &.{ secret_env, &.{t.token} });
        }
        const names = try arena.alloc([]const u8, secret_env.len);
        for (secret_env, names) |s, *n| n.* = s.name;
        resolved.run.secret_env = names;
        resolved.run.write_event = x.event_from_env;
        // A step that uses secrets (a deploy, a publish) must not be skipped because an earlier run
        // had the same inputs, and one that reads run-specific values must not replay an earlier
        // run's; every step after it then runs too. One that can get OIDC tokens may publish or
        // deploy without any secret (npm's trusted publishing, cloud logins), so it runs too.
        if (x.step_cache) {
            const reason: ?[]const u8 = if (uses_secrets)
                "it uses secrets"
            else if (oidc != null)
                "it can request OIDC tokens (id-token: write)"
            else if (readsRunSpecific(resolved.run.script))
                "it reads run- or commit-specific values"
            else
                rerun;
            if (reason) |r| resolved.run.always_run = try std.fmt.allocPrint(
                arena,
                "zig-runner runs this step every time: {s} (run {s})",
                .{ r, x.run_nonce },
            )
                // A step that is replayable must not be given a value that differs between runs,
                // because it can read one without the runner being able to tell
                // (`volatile_sentinel`).
            else resolved.run.withhold_volatile = x.enforce_volatile;
        }
        return .{ .resolved = resolved, .secret_env = secret_env };
    }

    /// Variables and PATH entries the previous steps asked for through $GITHUB_ENV / $GITHUB_PATH,
    /// written and then forgotten: the container after this step has them.
    fn writePendingEnv(x: *Exec, q: *Query) !void {
        const arena = x.arena;
        const ev = x.ev;
        for (ev.pending_env.items) |e|
            try q.call("withEnvVariable", .{ .name = e.name, .value = e.value });
        if (ev.pending_path.items.len > 0) {
            const joined = try std.mem.join(arena, ":", ev.pending_path.items);
            const value = try std.fmt.allocPrint(arena, "{s}:$PATH", .{joined});
            try q.call("withEnvVariable", .{ .name = "PATH", .value = value, .expand = true });
        }
        ev.pending_env.clearRetainingCapacity();
        ev.pending_path.clearRetainingCapacity();
    }

    /// Each mount as its call.
    fn writeMounts(q: *Query, mounts: []const Mount) !void {
        for (mounts) |m| switch (m) {
            .dir => |d| try q.call(
                "withDirectory",
                .{ .path = d.path, .source = d.id, .owner = d.owner },
            ),
            .file => |f| try q.call(
                "withFile",
                .{ .path = f.path, .source = f.id, .permissions = f.permissions },
            ),
            .new_file => |f| try q.call("withNewFile", .{
                .path = f.path,
                .contents = f.contents,
                .permissions = f.permissions,
            }),
        };
    }

    /// The exec itself and what is read back: exit code, the combined file commands, and the
    /// container id — taken after the step's secrets are removed, so the next step starts without
    /// them. Nesting gives the step's `dagger` CLI a session on this engine, sharing its cache.
    /// Returns where its recorded output would be asked for (`Recorded`).
    fn writeScriptExec(
        x: *Exec,
        q: *Query,
        script: []const u8,
        fc: u32,
        secret_env: []const SecretRef,
    ) !usize {
        const arena = x.arena;
        const nesting: ?bool = if (x.nesting) true else null;
        try q.call("withExec", .{
            .args = &[_][]const u8{ "sh", "-c", script },
            .expect = Raw{ .text = "ANY" },
            .experimentalPrivilegedNesting = nesting,
        });
        try q.leaf("exitCode");
        const output_at = Recorded.position(q);
        try q.callAs("fc_all", "file", .{ .path = try fcPath(arena, "all", fc) });
        try q.leaf("contents");
        try q.close(1);
        for (secret_env, 0..) |_, i|
            try q.call("withoutSecretVariable", .{ .name = try secretAlias(arena, i) });
        try q.leaf("id");
        return output_at;
    }

    /// An exec's recorded output (`stdout`, `stderr`), asked for only when it is needed: when none
    /// of the step's lines arrived live, because the engine served the exec from its cache. Asked
    /// for with every exec, a 200 MB log came back in the answer, and the engine repeated it on the
    /// log stream as well (a `stdout` field's value is logged, marked verbose): the runner grew by
    /// 1.8 GB. The exec's document is sent again with the fields put in, which the engine answers
    /// from its cache without running the exec again, and an answer past `max_recorded_bytes` is
    /// not read.
    pub const Recorded = struct {
        /// The exec's document, and where in it the fields go (`position`).
        doc: []const u8,
        at: usize,

        /// Where the fields would go: the current position, in the exec's selection.
        pub fn position(q: *Query) usize {
            // The document has begun (the exec was called), so this is an offset into what
            // `finish` returns.
            std.debug.assert(q.began);
            return q.out.written().len;
        }

        const Output = struct { stdout: []const u8, stderr: []const u8 };

        /// The output, or why it could not be had.
        fn read(r: Recorded, x: *Exec) union(enum) { ok: Output, failed: []const u8 } {
            const arena = x.arena;
            const doc = std.mem.concat(arena, u8, &.{
                r.doc[0..r.at],
                "stdout stderr ",
                r.doc[r.at..],
            }) catch return .{ .failed = "out of memory" };
            var err_msg: []const u8 = "";
            const data = gqlAtMost(arena, x.transport, doc, max_recorded_bytes, &err_msg) catch |e|
                return .{ .failed = if (e == error.ResponseTooLarge)
                    std.fmt.comptimePrint("it is over the {d} MiB that is replayed", .{
                        max_recorded_bytes / (1024 * 1024),
                    })
                else if (err_msg.len > 0) err_msg else @errorName(e) };
            return .{ .ok = .{
                .stdout = jsonFindString(data, "stdout") orelse "",
                .stderr = jsonFindString(data, "stderr") orelse "",
            } };
        }
    };

    /// Reads the matcher files a step asked for, and registers what they define.
    ///
    /// The paths come from the step's own output, so they are absolute in *its* container — the one
    /// this has just finished building, which is why the read happens here rather than in the log
    /// path. A file that cannot be read, or holds nothing this engine can compile, warns in the
    /// step's log and is otherwise ignored: an action that ships an exotic pattern should lose its
    /// annotations, not its job.
    fn warnMatcher(x: *Exec, num: u32, comptime fmt: []const u8, args: anytype) void {
        const text = std.fmt.allocPrint(x.arena, "##[warning]" ++ fmt, args) catch return;
        x.sh.warnUnlocked(num, text);
    }

    fn loadPendingMatchers(x: *Exec, num: u32) void {
        const pending = x.sh.takePendingMatchers();
        if (pending.len == 0) return;
        // All the files in one query. One that cannot be read fails it all; each is then read on
        // its own, so the others still load and the warning names the one that failed.
        const all = x.readMatcherFiles(pending);
        for (pending, 0..) |path, i| {
            const text = (if (all) |texts| texts[i] else x.readMatcherFile(path)) orelse {
                x.warnMatcher(num, "Could not read the problem matcher '{s}'", .{path});
                continue;
            };
            const loaded = matcher.load(x.arena, text) catch {
                x.warnMatcher(num, "'{s}' is not a problem matcher file", .{path});
                continue;
            };
            for (loaded.refused) |r|
                x.warnMatcher(
                    num,
                    "Problem matcher '{s}' is ignored: its pattern needs {s} ({s})",
                    .{ r.owner, r.why, r.pattern },
                );
            x.sh.addMatchers(loaded.matchers);
        }
    }

    /// The contents of each of `paths` in the job's container, in one query; null when that
    /// failed, and for a single path (`readMatcherFile` reads it).
    fn readMatcherFiles(x: *Exec, paths: []const []const u8) ?[]const []const u8 {
        if (paths.len < 2) return null;
        const arena = x.arena;
        var q: Query = .init(arena);
        q.call("loadContainerFromID", .{ .id = x.container_id }) catch return null;
        for (paths, 0..) |path, i| {
            const alias = std.fmt.allocPrint(arena, "m{d}", .{i}) catch return null;
            q.callAs(alias, "file", .{ .path = path }) catch return null;
            q.leaf("contents") catch return null;
            q.close(1) catch return null;
        }
        const doc = q.finish() catch return null;
        var msg: []const u8 = "";
        const data = gql(arena, x.transport, doc, &msg) catch return null;
        const texts = arena.alloc([]const u8, paths.len) catch return null;
        for (texts, 0..) |*t, i| {
            const alias = std.fmt.allocPrint(arena, "m{d}", .{i}) catch return null;
            const f = jsonFind(data, alias) orelse return null;
            t.* = jsonFindString(f, "contents") orelse return null;
        }
        return texts;
    }

    /// The contents of `path` in the job's container; null when it could not be read.
    fn readMatcherFile(x: *Exec, path: []const u8) ?[]const u8 {
        var q: Query = .init(x.arena);
        q.call("loadContainerFromID", .{ .id = x.container_id }) catch return null;
        q.call("file", .{ .path = path }) catch return null;
        q.leaf("contents") catch return null;
        const doc = q.finish() catch return null;
        var msg: []const u8 = "";
        const data = gql(x.arena, x.transport, doc, &msg) catch return null;
        return jsonFindString(data, "contents");
    }

    // output_keys.zig
    pub const writeOlder = @import("dagger/output_keys.zig").writeOlder;
    pub const outputKeyed = @import("dagger/output_keys.zig").outputKeyed;
    pub const outputsPhase = @import("dagger/output_keys.zig").outputsPhase;
    pub const outputsFallback = @import("dagger/output_keys.zig").outputsFallback;
    pub const countOutputKeyed = @import("dagger/output_keys.zig").countOutputKeyed;
    pub const outputKeyedWorkspace = @import("dagger/output_keys.zig").outputKeyedWorkspace;
    pub const storeAndApply = @import("dagger/output_keys.zig").storeAndApply;
    pub const outputsVolume = @import("dagger/output_keys.zig").outputsVolume;
    pub const storeOutput = @import("dagger/output_keys.zig").storeOutput;
    pub const applyScript = @import("dagger/output_keys.zig").applyScript;
    pub const applyOutput = @import("dagger/output_keys.zig").applyOutput;
    pub const debugApplied = @import("dagger/output_keys.zig").debugApplied;

    /// Several execs can log as one step (a composite action's steps, a JavaScript action's pre,
    /// main and post): after the first, count each one's live lines afresh, so a cached one is
    /// replayed.
    pub fn beginExec(x: *Exec, num: u32) void {
        if (x.execs[num - 1] > 0) {
            x.sh.live_lines[num - 1].store(0, .monotonic);
            x.sh.ended[num - 1].store(false, .release);
        }
        x.sh.bun_refused.store(0, .release);
        x.execs[num - 1] += 1;
    }

    /// An exec's result (`exitCode fc_<kind> { contents }`): its output, replayed if it was cached
    /// (`Recorded`), and its file commands applied.
    pub fn collect(x: *Exec, num: u32, data: std.json.Value, recorded: Recorded) !ExecOut {
        const arena = x.arena;
        const ev = x.ev;
        var code = exitCode(data);
        // A cached step prints no log lines. Wait briefly for a live stream, then replay the
        // recorded output. Without step caching nothing is replayed from an earlier job:
        // run-specific values are part of every key.
        var output: Recorded.Output = .{ .stdout = "", .stderr = "" };
        if (!awaitLive(x.io, x.sh, num)) {
            const ran = x.ranThisRun(data);
            // An answer that has it already (a test's) is not asked again; a step that ran here
            // and printed nothing has nothing to show.
            if (jsonFind(data, "stdout") != null) output = .{
                .stdout = jsonFindString(data, "stdout") orelse "",
                .stderr = jsonFindString(data, "stderr") orelse "",
            } else if (servedFromCache(x.sh, num, ran)) switch (recorded.read(x)) {
                .ok => |o| output = o,
                .failed => |why| x.sh.append(num, try std.fmt.allocPrint(
                    arena,
                    "##[warning]This step's output cannot be shown: its recorded output " ++
                        "could not be read back ({s}).",
                    .{why},
                )),
            };
            _ = replayNotLive(x.sh, num, output.stdout, output.stderr, ran);
        }
        const stdout = output.stdout;
        const stderr = output.stderr;

        // File commands: outputs for `steps.<id>.outputs`, env and PATH for the steps that follow.
        var outputs: []const job_mod.EnvVar = &.{};
        var cmd_error: ?[]const u8 = null;
        const fc_output = fileCommand(data, "fc_output");
        if (fc_output) |text| switch (try commands.parseKeyValues(arena, text)) {
            .ok => |kv| outputs = kv,
            .invalid => |why| cmd_error = try std.fmt.allocPrint(arena, "Unable to process " ++
                "the GITHUB_OUTPUT file command: {s}", .{why}),
        };
        if (fileCommand(data, "fc_env")) |text| switch (try commands.parseKeyValues(arena, text)) {
            .ok => |kv| for (kv) |e| {
                if (commands.isProtectedEnvName(e.name)) {
                    x.sh.append(num, try std.fmt.allocPrint(arena, "Warning: ignored " ++
                        "GITHUB_ENV entry '{s}' (reserved name)", .{e.name}));
                    continue;
                }
                try Evaluator.putEnv(arena, &ev.job_env, e.name, e.value);
                try ev.pending_env.append(arena, e);
            },
            .invalid => |why| cmd_error = try std.fmt.allocPrint(arena, "Unable to process " ++
                "the GITHUB_ENV file command: {s}", .{why}),
        };
        if (fileCommand(data, "fc_path")) |text| {
            for (try commands.parsePaths(arena, text)) |dir| try ev.pending_path.append(arena, dir);
        }
        if (fileCommand(data, "fc_step_summary")) |text| try x.appendSummary(num, text);
        if (cmd_error) |msg| {
            x.sh.append(num, msg);
            if (code == 0) code = 1;
        }
        // Outputs set with the deprecated `::set-output` come after GITHUB_OUTPUT's, which win.
        const legacy = x.sh.takeOutputs(num);
        if (legacy.len > 0)
            outputs = try std.mem.concat(arena, job_mod.EnvVar, &.{ outputs, legacy });
        var state: []const job_mod.EnvVar = x.sh.takeState(num);
        const fc_state = fileCommand(data, "fc_state");
        if (fc_state) |text| switch (try commands.parseKeyValues(arena, text)) {
            .ok => |kv| state = try std.mem.concat(arena, job_mod.EnvVar, &.{ state, kv }),
            .invalid => |why| x.sh.append(num, try std.fmt.allocPrint(arena, "Unable to " ++
                "process the GITHUB_STATE file command: {s}", .{why})),
        };
        // Bun's message is on stderr, which the step's script sends to its stdout
        // (`stream_prologue`): in a line that arrived live, or in the recorded output replayed.
        const refused = code != 0 and (x.sh.bun_refused.load(.acquire) == num or
            for (bun_load_errors) |e| {
                const in_out = std.mem.indexOf(u8, stdout, e) != null;
                if (in_out or std.mem.indexOf(u8, stderr, e) != null) break true;
            } else false);
        return .{ .code = code, .outputs = outputs, .state = state, .bun_refused = refused };
    }

    /// Whether the step ran in this job (true), was replayed from an earlier run (false), or did
    /// not say (null): under step caching the exec writes the run's marker to a file command.
    fn ranThisRun(x: *Exec, data: std.json.Value) ?bool {
        if (!x.step_cache) return true;
        const m = fileCommand(data, "fc_ran") orelse return null;
        return std.mem.eql(u8, std.mem.trim(u8, m, " \n"), x.ran_marker);
    }

    /// Text a step added to $GITHUB_STEP_SUMMARY; past the size limit the summary is dropped, in
    /// GitHub's runner's words.
    fn appendSummary(x: *Exec, num: u32, text: []const u8) !void {
        if (text.len == 0 or num > x.summaries.len) return;
        const so_far = x.summaries[num - 1];
        if (so_far.len + text.len > max_summary_bytes) {
            x.sh.append(num, try std.fmt.allocPrint(
                x.arena,
                "##[error]$GITHUB_STEP_SUMMARY upload aborted, supports content up to a size of " ++
                    "{d}k, got {d}k. For more information see: https://docs.github.com/actions/" ++
                    "using-workflows/workflow-commands-for-github-actions" ++
                    "#adding-a-markdown-summary",
                .{ max_summary_bytes / 1024, (so_far.len + text.len) / 1024 },
            ));
            return;
        }
        x.summaries[num - 1] = try std.mem.concat(x.arena, u8, &.{ so_far, text });
    }

    pub const ActionOut = struct {
        failed: bool,
        exit_code: i32 = 0,
        outputs: []const job_mod.EnvVar = &.{},
    };

    /// Why a Docker action's exec always runs under step caching: it has the job token
    /// (ACTIONS_RUNTIME_TOKEN). Null without step caching.
    pub fn alwaysRunNote(x: *Exec) !?[]const u8 {
        if (!x.step_cache) return null;
        return try std.fmt.allocPrint(x.arena, "zig-runner runs this step every time: " ++
            "it uses secrets (run {s})", .{x.run_nonce});
    }

    /// `splitEnv` with this Exec's session, job and secret counter; the message in `x.err_msg`.
    fn splitStepEnv(
        x: *Exec,
        env: []const job_mod.EnvVar,
        plain: *std.ArrayList(job_mod.EnvVar),
        secret: *std.ArrayList(SecretRef),
    ) !void {
        const counter = &x.secrets;
        return splitEnv(x.arena, x.transport, x.job.*, counter, env, plain, secret, &x.err_msg);
    }

    pub fn actionFailed(x: *Exec, num: u32, comptime fmt: []const u8, args: anytype) !ActionOut {
        x.sh.append(num, try std.fmt.allocPrint(x.arena, fmt, args));
        return .{ .failed = true, .exit_code = 1 };
    }

    /// Runs a `uses:` step: reads the action's metadata and, for a composite action, runs its steps
    /// as part of step `num`. `caller` is the scope of the `uses:` step (for `with:` and defaults);
    /// `step_env` and `step_secret` are its evaluated `env:`, which its steps inherit. `nested`: a
    /// step of a composite action (loaded here, not with the job's own steps). Recursive through
    /// composite actions' `uses:` steps, hence `anyerror`.
    fn runAction(
        x: *Exec,
        num: u32,
        u: job_mod.Uses,
        caller: expr.Scope,
        step_env: []const job_mod.EnvVar,
        step_secret: []const SecretRef,
        nested: bool,
    ) anyerror!ActionOut {
        const arena = x.arena;
        const ev = x.ev;
        const loaded = try x.loadUses(num, u, nested);
        const act = switch (loaded) {
            .failed, .unresolved => |msg| return x.actionFailed(num, "{s}", .{msg}),
            .ok => |a| a,
        };

        const inputs = switch (try x.resolveInputs(num, act, u, caller, true)) {
            .failed => |out| return out,
            .ok => |in| in,
        };

        const steps = switch (act.meta.runs) {
            .composite => |st| st,
            .node => |nd| return x.runJs(num, act, u, nd, inputs, step_env, step_secret),
            .docker => |dk| return x.runDocker(num, act, u, dk, inputs, step_env, step_secret),
        };

        // GitHub allows composite actions nested 9 deep.
        if (x.depth >= max_composite_depth) return x.actionFailed(
            num,
            "{s}: composite actions can be nested at most {d} levels deep",
            .{ act.ref_label, max_composite_depth },
        );
        x.depth += 1;
        defer x.depth -= 1;

        // The action's steps see its own `inputs` and `steps`, and `github.action_path`; the job's
        // come back afterwards. GITHUB_ENV and GITHUB_PATH changes outlive the action, as on
        // GitHub.
        const saved_steps = ev.steps;
        const saved_inputs = ev.inputs;
        const saved_github = ev.github;
        const saved_failed = ev.job_failed;
        defer {
            ev.steps = saved_steps;
            ev.inputs = saved_inputs;
            ev.github = saved_github;
            ev.job_failed = saved_failed;
        }
        try x.enterAction(act, inputs);

        var outcome: CompositeOutcome = .{};
        const comp = CompositeRun{ .act = act, .step_env = step_env, .step_secret = step_secret };
        for (steps, 1..) |st, i| try x.runCompositeStep(num, comp, st, i, &outcome);

        // The action's outputs, evaluated against its own steps.
        const sc_out = try ev.scope(step_env);
        const outputs = try arena.alloc(job_mod.EnvVar, act.meta.outputs.len);
        for (act.meta.outputs, outputs) |o, *dst| dst.* = .{
            .name = o.name,
            .value = expr.interpolate(arena, o.value, sc_out) catch "",
        };
        return .{ .failed = outcome.failed, .exit_code = outcome.exit_code, .outputs = outputs };
    }

    /// Points the evaluator at a composite action: its `inputs`, an empty `steps`, and the
    /// `github.action_*` entries. The caller saves and restores what this replaces.
    /// A `uses:` step's action: a nested one is read without a "Set up job" line (the job's own
    /// steps were listed there), a local one from the workspace.
    fn loadUses(x: *Exec, num: u32, u: job_mod.Uses, nested: bool) !LoadResult {
        if (!nested) return x.loadFor(num, u);
        return if (u.local) x.loadLocal(u) else x.loadAction(u);
    }

    fn enterAction(x: *Exec, act: Loaded, inputs: []const expr.Value.Entry) !void {
        const ev = x.ev;
        ev.steps = .empty;
        ev.inputs = .{ .object = inputs };
        ev.github = try withEntries(x.arena, ev.github, &.{
            .{ .key = "action_path", .value = .{ .string = act.path } },
            .{ .key = "action_repository", .value = .{ .string = act.repository } },
            .{ .key = "action_ref", .value = .{ .string = act.ref } },
        });
        ev.job_failed = false;
    }

    /// What a composite action's steps run under: the action, and the `uses:` step's evaluated env,
    /// which they inherit.
    const CompositeRun = struct {
        act: Loaded,
        step_env: []const job_mod.EnvVar,
        step_secret: []const SecretRef,
    };

    /// Whether any step of a composite action failed without `continue-on-error`, and the first
    /// non-zero exit code — what the action reports as its own.
    const CompositeOutcome = struct {
        failed: bool = false,
        exit_code: i32 = 0,

        /// A step's result: recorded in the action's `steps` context, and in the outcome unless the
        /// step continues on error.
        fn record(
            o: *CompositeOutcome,
            ev: *Evaluator,
            arena: Allocator,
            ctx_id: []const u8,
            ok: bool,
            coe: bool,
            outputs: []const job_mod.EnvVar,
            code: i32,
        ) !void {
            try ev.steps.append(arena, .{
                .id = ctx_id,
                .outcome = if (ok) "success" else "failure",
                .conclusion = if (ok or coe) "success" else "failure",
                .outputs = outputs,
            });
            if (!ok and !coe) {
                o.failed = true;
                ev.job_failed = true;
                if (o.exit_code == 0) o.exit_code = code;
            }
        }
    };

    /// One step of a composite action, as part of step `num`: its env and condition evaluated in
    /// the action's scope, then run as a nested `uses:` or as a script.
    fn runCompositeStep(
        x: *Exec,
        num: u32,
        comp: CompositeRun,
        st: action.Step,
        i: usize,
        outcome: *CompositeOutcome,
    ) !void {
        const arena = x.arena;
        const ev = x.ev;
        const ctx_id = st.id orelse try std.fmt.allocPrint(arena, "__{d}", .{i});
        ev.diag = "";
        // The step's env is evaluated with the `uses:` step's env visible, then added to it.
        const sc_env = try ev.scope(comp.step_env);
        var nested_env: std.ArrayList(job_mod.EnvVar) = .empty;
        var env_error: ?[]const u8 = null;
        for (st.env) |e| {
            const v = expr.interpolate(arena, e.value, sc_env) catch {
                env_error = try std.fmt.allocPrint(arena, "could not evaluate env '{s}': {s}", .{
                    e.name,
                    ev.diag,
                });
                break;
            };
            try nested_env.append(arena, .{ .name = e.name, .value = v });
        }
        const all_env = try std.mem.concat(arena, job_mod.EnvVar, &.{
            comp.step_env,
            nested_env.items,
        });
        const sc = try ev.scope(all_env);
        const display = if (st.name) |nm|
            (expr.interpolate(arena, nm, sc) catch nm)
        else if (st.run) |r|
            firstLine(r)
        else
            st.uses orelse "";
        if (env_error) |msg| return x.nestedFailed(num, ctx_id, display, msg, outcome);

        const cond = st.condition orelse "success()";
        const go = expr.evalCondition(arena, cond, sc) catch {
            const msg = try std.fmt.allocPrint(arena, "could not evaluate the condition " ++
                "'{s}': {s}", .{ cond, ev.diag });
            return x.nestedFailed(num, ctx_id, display, msg, outcome);
        };
        if (!go) {
            try ev.steps.append(arena, skippedStep(ctx_id));
            return;
        }
        const coe = if (st.continue_on_error) |c|
            std.mem.eql(u8, expr.interpolate(arena, c, sc) catch "false", "true")
        else
            false;
        const step = NestedStep{
            .ctx_id = ctx_id,
            .display = display,
            .sc = sc,
            .all_env = all_env,
            .nested_env = nested_env.items,
            .coe = coe,
        };
        if (st.run) |run_text| {
            try x.runNestedScript(num, comp, st, step, run_text, outcome);
        } else {
            try x.runNestedUses(num, comp, st, step, outcome);
        }
    }

    /// A composite step once its env and condition are settled: its id in the `steps` context, how
    /// it is shown, the scope it is evaluated in, its env, and whether it continues on error.
    const NestedStep = struct {
        ctx_id: []const u8,
        display: []const u8,
        sc: expr.Scope,
        all_env: []const job_mod.EnvVar,
        nested_env: []const job_mod.EnvVar,
        coe: bool,
    };

    /// The `uses:` step's env, split into plain variables and Dagger secrets, on top of the
    /// composite step's own.
    fn nestedEnv(
        x: *Exec,
        comp: CompositeRun,
        nested_env: []const job_mod.EnvVar,
        plain: *std.ArrayList(job_mod.EnvVar),
        secret: *std.ArrayList(SecretRef),
    ) !void {
        const arena = x.arena;
        try plain.appendSlice(arena, comp.step_env);
        try secret.appendSlice(arena, comp.step_secret);
        splitEnv(
            arena,
            x.transport,
            x.job.*,
            &x.secrets,
            nested_env,
            plain,
            secret,
            &x.err_msg,
        ) catch return error.EngineFailed;
    }

    /// A composite action's `uses:` step: its `with:` is evaluated here, in the action's scope; it
    /// inherits the env.
    fn runNestedUses(
        x: *Exec,
        num: u32,
        comp: CompositeRun,
        st: action.Step,
        step: NestedStep,
        outcome: *CompositeOutcome,
    ) !void {
        const arena = x.arena;
        const ev = x.ev;
        var with: std.ArrayList(job_mod.Input) = .empty;
        for (st.with) |kv| {
            const v = expr.interpolate(arena, kv.value, step.sc) catch {
                const msg = try std.fmt.allocPrint(
                    arena,
                    "could not evaluate input '{s}': {s}",
                    .{ kv.name, ev.diag },
                );
                return x.nestedFailed(num, step.ctx_id, step.display, msg, outcome);
            };
            try with.append(arena, .{ .name = kv.name, .value = .{ .lit = v } });
        }
        var plain: std.ArrayList(job_mod.EnvVar) = .empty;
        var secret: std.ArrayList(SecretRef) = .empty;
        try x.nestedEnv(comp, step.nested_env, &plain, &secret);
        const out = try x.runNested(
            num,
            step.ctx_id,
            st.uses.?,
            with.items,
            step.sc,
            plain.items,
            secret.items,
        );
        const code: i32 = if (out.exit_code != 0) out.exit_code else 1;
        try outcome.record(ev, arena, step.ctx_id, !out.failed, step.coe, out.outputs, code);
    }

    /// A composite action's `run:` step: the script, shell and working directory evaluated, its
    /// header logged as the official runner logs it, then run with the action's files mounted.
    fn runNestedScript(
        x: *Exec,
        num: u32,
        comp: CompositeRun,
        st: action.Step,
        step: NestedStep,
        run_text: []const u8,
        outcome: *CompositeOutcome,
    ) !void {
        const arena = x.arena;
        const ev = x.ev;
        const act = comp.act;
        const script = expr.interpolate(arena, run_text, step.sc) catch {
            const msg = try std.fmt.allocPrint(arena, "could not evaluate the script: {s}", .{
                ev.diag,
            });
            return x.nestedFailed(num, step.ctx_id, step.display, msg, outcome);
        };
        // Without a name, the step is shown by its command as it will run.
        const display = if (st.name == null) firstLine(script) else step.display;
        const shell = expr.interpolate(arena, st.shell.?, step.sc) catch st.shell.?;
        if (!job_mod.validShell(shell)) {
            const msg = try job_mod.unsupportedShell(arena, shell);
            return x.nestedFailed(num, step.ctx_id, display, msg, outcome);
        }
        const wd = interpolateOptional(arena, st.working_directory, step.sc);

        // Env that carries a secret goes in as a Dagger secret, the rest in the script.
        var plain: std.ArrayList(job_mod.EnvVar) = .empty;
        var secret: std.ArrayList(SecretRef) = .empty;
        try x.nestedEnv(comp, step.nested_env, &plain, &secret);
        try plain.appendSlice(arena, &[_]job_mod.EnvVar{
            .{ .name = "GITHUB_ACTION_PATH", .value = act.path },
            .{ .name = "GITHUB_ACTION_REPOSITORY", .value = act.repository },
            .{ .name = "GITHUB_ACTION_REF", .value = act.ref },
        });
        try x.logNestedRunHeader(num, display, script, shell, step.all_env);

        // The action's files are mounted once per job; its steps may change them, as on GitHub.
        const mounted = x.mounted_actions.contains(act.mount);
        const m = [_]Mount{.{ .dir = .{ .path = act.mount, .id = act.dir, .owner = x.dir_owner } }};
        const fc = x.next_fc;
        x.next_fc += 1;
        const resolved: Resolved = .{
            .run = .{
                .script = script,
                .shell = shell,
                .working_directory = wd,
                .env = plain.items,
            },
        };
        const mounts: []const Mount = if (mounted) &.{} else &m;
        const out = try x.execScript(num, fc, resolved, step.ctx_id, secret.items, mounts);
        try x.mounted_actions.put(arena, act.mount, {});
        if (out.code != 0) logExitCode(x.sh, num, out.code);
        try outcome.record(ev, arena, step.ctx_id, out.code == 0, step.coe, out.outputs, out.code);
    }

    /// As the official runner does: the command, folded away, then its shell and env.
    fn logNestedRunHeader(
        x: *Exec,
        num: u32,
        display: []const u8,
        script: []const u8,
        shell: []const u8,
        all_env: []const job_mod.EnvVar,
    ) !void {
        const arena = x.arena;
        x.sh.append(num, try std.fmt.allocPrint(arena, "##[group]Run {s}", .{display}));
        var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, script, "\n"), '\n');
        while (lines.next()) |l| x.sh.append(num, l);
        x.sh.append(num, try shellLine(arena, shell));
        const shown_env = try envContext(arena, x.ev.job_env.items, all_env);
        if (shown_env.len > 0) {
            x.sh.append(num, "env:");
            for (shown_env) |e| x.sh.append(
                num,
                try std.fmt.allocPrint(arena, "  {s}: {s}", .{ e.name, firstLine(e.value) }),
            );
        }
        x.sh.append(num, "##[endgroup]");
    }

    /// A composite action's `uses:` step, run as part of step `num` like a step of the job: the
    /// built-in checkout for actions/checkout, a `docker://` image, or a local or remote action
    /// (which may be composite again). Nested actions' `pre` scripts do not run; their `post`
    /// scripts do, at the end.
    fn runNested(
        x: *Exec,
        num: u32,
        ctx_id: []const u8,
        uses_text: []const u8,
        with: []const job_mod.Input,
        caller: expr.Scope,
        step_env: []const job_mod.EnvVar,
        step_secret: []const SecretRef,
    ) anyerror!ActionOut {
        const parsed = action.parseUses(uses_text) orelse
            return x.actionFailed(num, "uses: {s} is not a valid action reference", .{uses_text});
        switch (parsed) {
            .docker => |image| return x.runImageStep(
                num,
                .{ .image = image, .inputs = with },
                caller,
                step_env,
                step_secret,
            ),
            .local => |raw| {
                const dir = job_mod.localActionPath(raw) orelse return x.actionFailed(
                    num,
                    "uses: {s}: a local action must be inside the workspace",
                    .{raw},
                );
                return x.runAction(
                    num,
                    .{
                        .owner = "",
                        .name = "",
                        .path = dir,
                        .ref = "",
                        .inputs = with,
                        .local = true,
                    },
                    caller,
                    step_env,
                    step_secret,
                    true,
                );
            },
            .repo => |r| {
                const is_checkout = std.ascii.eqlIgnoreCase(r.owner, "actions") and
                    std.ascii.eqlIgnoreCase(r.name, "checkout") and r.path.len == 0;
                if (is_checkout) return x.runNestedCheckout(num, ctx_id, with);
                return x.runAction(
                    num,
                    .{
                        .owner = r.owner,
                        .name = r.name,
                        .path = r.path,
                        .ref = r.ref,
                        .inputs = with,
                    },
                    caller,
                    step_env,
                    step_secret,
                    true,
                );
            },
        }
    }

    /// actions/checkout inside a composite action: the runner's built-in checkout, as for the job's
    /// steps.
    fn runNestedCheckout(
        x: *Exec,
        num: u32,
        ctx_id: []const u8,
        with: []const job_mod.Input,
    ) !ActionOut {
        const arena = x.arena;
        const kv = try arena.alloc(job_mod.EnvVar, with.len);
        for (with, kv) |in, *dst| dst.* = .{ .name = in.name, .value = in.value.lit };
        const co = switch (try job_mod.checkoutFromInputs(arena, kv)) {
            .ok => |c| c,
            .unsupported => |why| return x.actionFailed(num, "{s}", .{why}),
        };
        const f = try fetchCheckout(arena, x.transport, x.job.*, co, x.gitAuth());
        if (f.result == .failed) return x.actionFailed(num, "{s}", .{f.result.failed});
        const m = [_]Mount{.{ .dir = .{
            .path = f.mount,
            .id = f.result.dir,
            .owner = x.dir_owner,
        } }};
        const fc = x.next_fc;
        x.next_fc += 1;
        const out = try x.execScript(num, fc, .{ .checkout = f }, ctx_id, &.{}, &m);
        return .{ .failed = out.code != 0, .exit_code = out.code, .outputs = out.outputs };
    }

    /// `unresolved`: the action's repository or ref could not be fetched, which GitHub reports in
    /// "Set up job", before any step runs.
    const LoadResult = union(enum) { ok: Loaded, failed: []const u8, unresolved: []const u8 };

    /// The action's repository, loaded once per step, whether it loads or not: the `pre` pass at
    /// the start of the job (as GitHub downloads every action in "Set up job") and the step itself
    /// share it.
    fn loadFor(x: *Exec, num: u32, u: job_mod.Uses) !LoadResult {
        if (x.loaded[num - 1]) |l| return l;
        const lr = if (u.local) try x.loadLocal(u) else try x.loadAction(u);
        x.loaded[num - 1] = lr;
        return lr;
    }

    /// Inputs: the step's `with:` values, else the defaults, evaluated where the `uses:` step is.
    /// `warn`: log GitHub's warning about undeclared inputs (once, for the step itself).
    fn resolveInputs(
        x: *Exec,
        num: u32,
        act: Loaded,
        u: job_mod.Uses,
        caller: expr.Scope,
        warn: bool,
    ) !union(enum) { ok: []const expr.Value.Entry, failed: ActionOut } {
        const arena = x.arena;
        const ev = x.ev;
        var inputs: std.ArrayList(expr.Value.Entry) = .empty;
        for (act.meta.inputs) |def| {
            var val: []const u8 = "";
            if (findInput(u.inputs, def.name)) |t| {
                ev.diag = "";
                val = ev.render(t, caller) catch return .{
                    .failed = try x.actionFailed(num, "could not evaluate input '{s}': {s}", .{
                        def.name,
                        ev.diag,
                    }),
                };
            } else if (def.default) |d| {
                ev.diag = "";
                val = expr.interpolate(arena, d, caller) catch return .{
                    .failed = try x.actionFailed(num, "could not evaluate the default of " ++
                        "input '{s}': {s}", .{ def.name, ev.diag }),
                };
            }
            try inputs.append(arena, .{ .key = def.name, .value = .{ .string = val } });
        }
        // Like GitHub: warn about inputs the action does not declare, and pass them on anyway.
        var unexpected: std.ArrayList([]const u8) = .empty;
        for (u.inputs) |in| if (act.meta.input(in.name) == null) {
            try unexpected.append(arena, in.name);
            const val = ev.render(in.value, caller) catch "";
            try inputs.append(arena, .{ .key = in.name, .value = .{ .string = val } });
        };
        if (warn and unexpected.items.len > 0) {
            var valid: std.ArrayList([]const u8) = .empty;
            for (act.meta.inputs) |def| try valid.append(arena, def.name);
            x.sh.append(num, try std.fmt.allocPrint(arena, "Warning: Unexpected input(s) " ++
                "'{s}', valid inputs are ['{s}']", .{
                try std.mem.join(
                    arena,
                    "', '",
                    unexpected.items,
                ),
                try std.mem.join(arena, "', '", valid.items),
            }));
        }
        return .{ .ok = inputs.items };
    }

    /// Runs a JavaScript action's `pre` script before the job's steps, when it has one and its
    /// `pre-if` (default `always()`) holds. A failing `pre` fails the job, so later steps see
    /// failure(). An action that cannot be loaded or evaluated here is left to its step, which
    /// reports why.
    fn runPre(x: *Exec, num: u32, step: job_mod.Step) !void {
        const u = step.action.uses;
        // A local action is read when its step runs, after the checkout; GitHub runs no `pre` for
        // it.
        if (u.local) return;
        const act = switch (try x.loadFor(num, u)) {
            .failed, .unresolved => return,
            .ok => |a| a,
        };
        const pre: []const u8, const pre_if: ?[]const u8 = switch (act.meta.runs) {
            .node => |nd| .{ nd.pre orelse return, nd.pre_if },
            .docker => |dk| .{ dk.pre_entrypoint orelse return, dk.pre_if },
            .composite => return,
        };
        const ev = x.ev;
        ev.diag = "";
        const sc0 = try ev.scope(&.{});
        const step_env = ev.renderEnv(step.env, sc0) catch return;
        const sc1 = try ev.scope(step_env);
        if (!(expr.evalCondition(x.arena, pre_if orelse "always()", sc1) catch false)) return;
        const inputs = switch (try x.resolveInputs(num, act, u, sc1, false)) {
            .failed => return,
            .ok => |in| in,
        };
        var plain: std.ArrayList(job_mod.EnvVar) = .empty;
        var secret: std.ArrayList(SecretRef) = .empty;
        x.splitStepEnv(step_env, &plain, &secret) catch return error.EngineFailed;
        // A step of its own, "Pre Run x@v1", logged under the next log step.
        const ls = x.next_log_step;
        x.next_log_step += 1;
        const started = std.Io.Clock.real.now(x.io).toMilliseconds();
        const pre_name = x.extraName("Pre", num, act) catch "Pre";
        x.startExtra(.pre, ls, pre_name, started);
        const env = plain.items;
        const sec = secret.items;
        const pre_out = switch (act.meta.runs) {
            .docker => |dk| blk: {
                const dr = try x.dockerRunFor(ls, act, u, dk, inputs, env, sec, pre) orelse
                    break :blk null;
                break :blk try x.runContainer(ls, .pre, dr, &.{});
            },
            else => try x.runJsScript(ls, .pre, act, u, pre, inputs, env, sec, &.{}),
        };
        var ok = false;
        defer x.addExtra(.{
            .kind = .pre,
            .name = pre_name,
            .log_step = ls,
            .outcome = if (ok) .success else .failure,
            .started_ms = started,
            .completed_ms = std.Io.Clock.real.now(x.io).toMilliseconds(),
        }) catch {};
        const out = pre_out orelse {
            ev.job_failed = true;
            x.hook_failed = true;
            return;
        };
        x.pre_state[num - 1] = out.state;
        if (out.code != 0) {
            logExitCode(x.sh, ls, out.code);
            ev.job_failed = true;
            x.hook_failed = true;
        } else ok = true;
    }

    /// The name GitHub gives a `pre` or `post` step: the prefix and the step's name for the step's
    /// own action ("Post Run actions/cache@v4"), or "<prefix> Run <action>" for an action nested in
    /// a composite one (`depth` > 0 while a composite action's steps run).
    pub fn extraName(x: *Exec, prefix: []const u8, num: u32, act: Loaded) ![]const u8 {
        if (x.depth == 0)
            return std.fmt.allocPrint(x.arena, "{s} {s}", .{ prefix, x.job.steps[num - 1].name });
        return std.fmt.allocPrint(x.arena, "{s} Run {s}", .{ prefix, act.ref_label });
    }

    /// Runs the registered `post` scripts, last first, each when its `post-if` (default `always()`)
    /// holds. A failing one fails the job; the steps' own results stay as they were.
    fn runPosts(x: *Exec) !void {
        // Only posts follow a post, and they always run: keying them on its output gains nothing.
        x.output_keys = null;
        var i = x.posts.items.len;
        while (i > 0) {
            i -= 1;
            const p = x.posts.items[i];
            x.ev.diag = "";
            const sc = try x.ev.scope(&.{});
            if (!(expr.evalCondition(x.arena, p.condition, sc) catch true)) continue;
            // A step of its own, "Post Run x@v1", logged under the next log step.
            const ls = x.next_log_step;
            x.next_log_step += 1;
            const started = std.Io.Clock.real.now(x.io).toMilliseconds();
            x.startExtra(.post, ls, p.name, started);
            x.sh.append(ls, "Post job cleanup.");
            if (p.checkout) {
                try x.addExtra(.{
                    .kind = .post,
                    .name = p.name,
                    .log_step = ls,
                    .outcome = .success,
                    .started_ms = started,
                    .completed_ms = std.Io.Clock.real.now(x.io).toMilliseconds(),
                });
                continue;
            }
            const post_out = if (p.docker) |dr|
                try x.runContainer(ls, .post, dr, p.state)
            else
                try x.runJsScript(
                    ls,
                    .post,
                    p.act,
                    p.u,
                    p.script,
                    p.inputs,
                    p.step_env,
                    p.step_secret,
                    p.state,
                );
            const ok = if (post_out) |out| out.code == 0 else false;
            try x.addExtra(.{
                .kind = .post,
                .name = p.name,
                .log_step = ls,
                .outcome = if (ok) .success else .failure,
                .started_ms = started,
                .completed_ms = std.Io.Clock.real.now(x.io).toMilliseconds(),
            });
            const out = post_out orelse {
                x.hook_failed = true;
                continue;
            };
            if (out.code != 0) {
                logExitCode(x.sh, ls, out.code);
                x.hook_failed = true;
                x.ev.job_failed = true;
            }
        }
    }

    // js.zig
    pub const runJs = @import("dagger/js.zig").runJs;
    pub const runJsScript = @import("dagger/js.zig").runJsScript;
    pub const jsEnv = @import("dagger/js.zig").jsEnv;
    pub const appendJsRuntimeMounts = @import("dagger/js.zig").appendJsRuntimeMounts;
    pub const nodeFallback = @import("dagger/js.zig").nodeFallback;

    // hash_files.zig
    pub const hashFiles = @import("dagger/hash_files.zig").hashFiles;
    pub const hashListed = @import("dagger/hash_files.zig").hashListed;

    /// A line of the job's "Set up job" log (step 0).
    fn setUpLine(x: *Exec, line: []const u8) void {
        x.sh.append(0, line);
    }

    /// The start of "Set up job", in the form GitHub's runner uses for a self-hosted runner: the
    /// runner, then (for this runner) the image and engine, the GITHUB_TOKEN's permissions, where
    /// secrets come from, and the preparation steps.
    fn logSetUp(x: *Exec, opts: Options) !void {
        const arena = x.arena;
        // GitHub's own line, with this runner's build after it: the protocol version is what GitHub
        // validates and says nothing about which binary is running, which is the question a job's
        // log is asked when a machine behaves unexpectedly.
        x.setUpLine(try std.fmt.allocPrint(
            arena,
            "Current runner version: '{s}' (zig-runner {s})",
            .{ broker.version, build_version.string },
        ));
        x.setUpLine(try std.fmt.allocPrint(arena, "Runner name: '{s}'", .{opts.runner_name}));
        if (x.job.runner_group.len > 0) x.setUpLine(try std.fmt.allocPrint(
            arena,
            "Runner group name: '{s}'",
            .{x.job.runner_group},
        ));
        var host_buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
        if (std.posix.gethostname(&host_buf)) |host| {
            x.setUpLine(try std.fmt.allocPrint(arena, "Machine name: '{s}'", .{host}));
        } else |_| {}
        x.setUpLine("##[group]Runner Image");
        x.setUpLine(try std.fmt.allocPrint(arena, "Image: {s}", .{x.job_image}));
        x.setUpLine(if (opts.engine) |ep|
            try std.fmt.allocPrint(
                arena,
                "Engine: Dagger {s}, direct session ({s})",
                .{ engine.client_version, if (ep.host.len > 0) ep.host else ep.container },
            )
        else
            "Engine: Dagger, through `dagger run`");
        x.setUpLine("##[endgroup]");
        if (x.job.token_permissions.len > 0) {
            const perms = std.json.parseFromSliceLeaky(
                std.json.Value,
                arena,
                x.job.token_permissions,
                .{},
            ) catch null;
            if (perms) |p| if (p == .object) {
                x.setUpLine("##[group]GITHUB_TOKEN Permissions");
                var it = p.object.iterator();
                while (it.next()) |e| if (e.value_ptr.* == .string) {
                    x.setUpLine(try std.fmt.allocPrint(
                        arena,
                        "{s}: {s}",
                        .{ e.key_ptr.*, e.value_ptr.string },
                    ));
                };
                x.setUpLine("##[endgroup]");
            };
        }
        x.setUpLine(if (std.mem.eql(
            u8,
            x.ev.githubString("actor"),
            "dependabot[bot]",
        )) "Secret source: Dependabot" else "Secret source: Actions");
        x.setUpLine("Prepare workflow directory");
        x.setUpLine("Prepare all required actions");
        x.setUpLine("Getting action download info");
    }

    /// The job's GITHUB_TOKEN as a Dagger secret, registered on first use: what checkouts (and
    /// fetches of actions in the job's own repository) authenticate with. Null when the job has
    /// none or it could not be registered (the fetch then goes without, as for a public
    /// repository).
    fn gitAuth(x: *Exec) ?[]const u8 {
        if (x.git_auth) |g| return switch (g) {
            .none => null,
            .id => |id| id,
        };
        x.git_auth = .none;
        for (x.job.secret_vars) |sv|
            if (std.mem.eql(u8, sv.name, "GITHUB_TOKEN") and sv.value.len > 0) {
                const id = newSecret(
                    x.arena,
                    x.transport,
                    &x.secrets,
                    sv.value,
                    &x.err_msg,
                ) catch return null;
                x.git_auth = .{ .id = id };
                return id;
            };
        return null;
    }

    /// With `id-token: write` (GitHub then sends GenerateIdTokenUrl), the variables every step
    /// requests OIDC tokens with: the URL, and the job token as a Dagger secret (registered once
    /// per job).
    pub fn idToken(x: *Exec) !?struct { url: job_mod.EnvVar, token: SecretRef } {
        if (x.job.runtime.id_token_url.len == 0) return null;
        const id = x.id_token_secret orelse id: {
            const id = newSecret(
                x.arena,
                x.transport,
                &x.secrets,
                x.job.job_token,
                &x.err_msg,
            ) catch return error.EngineFailed;
            x.id_token_secret = id;
            break :id id;
        };
        return .{
            .url = .{ .name = "ACTIONS_ID_TOKEN_REQUEST_URL", .value = x.job.runtime.id_token_url },
            .token = .{ .name = "ACTIONS_ID_TOKEN_REQUEST_TOKEN", .id = id },
        };
    }

    /// What GitHub's runner gives actions besides their inputs: the services actions/cache and
    /// artifact actions talk to, and what earlier phases saved (`core.saveState`) as STATE_<name>.
    pub fn runtimeEnv(
        x: *Exec,
        env: *std.ArrayList(job_mod.EnvVar),
        state: []const job_mod.EnvVar,
    ) !void {
        const rt = x.job.runtime;
        const vars = [_]job_mod.EnvVar{
            .{ .name = "ACTIONS_RUNTIME_URL", .value = rt.pipelines_url },
            .{ .name = "ACTIONS_RUNTIME_TOKEN", .value = x.job.job_token },
            .{ .name = "ACTIONS_CACHE_URL", .value = rt.cache_url },
            .{ .name = "ACTIONS_RESULTS_URL", .value = rt.results_url },
            .{ .name = "ACTIONS_CACHE_SERVICE_V2", .value = if (rt.cache_v2) "True" else "" },
        };
        for (vars) |v| if (v.value.len > 0) try env.append(x.arena, v);
        for (state) |st| {
            const name = try std.fmt.allocPrint(x.arena, "STATE_{s}", .{st.name});
            try env.append(x.arena, .{ .name = name, .value = st.value });
        }
    }

    /// As GitHub shows an action: `##[group]Run <action>`, its inputs, the env it gets (the job's
    /// and the step's; secret-backed variables as ***), `##[endgroup]`.
    pub fn logGroup(
        x: *Exec,
        num: u32,
        phase: Phase,
        label: []const u8,
        shown: []const job_mod.EnvVar,
        step_env: []const job_mod.EnvVar,
        step_secret: []const SecretRef,
        extra: []const []const u8,
    ) !void {
        const arena = x.arena;
        x.sh.append(
            num,
            try std.fmt.allocPrint(arena, "##[group]{s} {s}", .{ phase.label(), label }),
        );
        if (shown.len > 0) {
            x.sh.append(num, "with:");
            for (shown) |in| x.sh.append(
                num,
                try std.fmt.allocPrint(arena, "  {s}: {s}", .{ in.name, firstLine(in.value) }),
            );
        }
        var env = try envContext(arena, x.ev.job_env.items, step_env);
        for (step_secret) |sr|
            env = try envContext(arena, env, &.{.{ .name = sr.name, .value = "***" }});
        if (env.len > 0) {
            x.sh.append(num, "env:");
            for (env) |e| x.sh.append(
                num,
                try std.fmt.allocPrint(arena, "  {s}: {s}", .{ e.name, firstLine(e.value) }),
            );
        }
        for (extra) |l| x.sh.append(num, l);
        x.sh.append(num, "##[endgroup]");
    }

    // docker.zig
    pub const ContainerEnv = @import("dagger/docker.zig").ContainerEnv;
    pub const runDocker = @import("dagger/docker.zig").runDocker;
    pub const dockerEnv = @import("dagger/docker.zig").dockerEnv;
    pub const dockerRunFor = @import("dagger/docker.zig").dockerRunFor;
    pub const runImageStep = @import("dagger/docker.zig").runImageStep;
    pub const logContainerStart = @import("dagger/docker.zig").logContainerStart;
    pub const containerScriptFor = @import("dagger/docker.zig").containerScriptFor;
    pub const runContainer = @import("dagger/docker.zig").runContainer;
    pub const containerArgv = @import("dagger/docker.zig").containerArgv;
    pub const workspaceDirId = @import("dagger/docker.zig").workspaceDirId;
    pub const containerEnv = @import("dagger/docker.zig").containerEnv;
    pub const writeActionDirs = @import("dagger/docker.zig").writeActionDirs;
    pub const writeActionEnv = @import("dagger/docker.zig").writeActionEnv;
    pub const writeActionSecrets = @import("dagger/docker.zig").writeActionSecrets;
    pub const takeWorkspaceBack = @import("dagger/docker.zig").takeWorkspaceBack;

    /// The static busybox that starts Docker actions' commands (taken from its image once per job).
    pub fn startExtra(
        x: *Exec,
        kind: ExtraKind,
        log_step: u32,
        name: []const u8,
        started_ms: i64,
    ) void {
        if (x.observer) |o| if (o.extraStartedFn) |f| f(o.ptr, kind, log_step, name, started_ms);
    }

    pub fn addExtra(x: *Exec, e: ExtraStep) !void {
        try x.extra.append(x.arena, e);
        if (x.observer) |o| if (o.extraFinishedFn) |f| f(o.ptr, e);
    }

    // services.zig
    pub const startServices = @import("dagger/services.zig").startServices;
    pub const pullJobContainer = @import("dagger/services.zig").pullJobContainer;
    pub const startService = @import("dagger/services.zig").startService;
    pub const serviceSpec = @import("dagger/services.zig").serviceSpec;
    pub const serviceHead = @import("dagger/services.zig").serviceHead;
    pub const pullServiceConfig = @import("dagger/services.zig").pullServiceConfig;
    pub const startServiceContainer = @import("dagger/services.zig").startServiceContainer;
    pub const bindServicesToJob = @import("dagger/services.zig").bindServicesToJob;
    pub const writeServiceBindings = @import("dagger/services.zig").writeServiceBindings;
    pub const stopServices = @import("dagger/services.zig").stopServices;

    pub fn busyboxFile(x: *Exec, num: u32) !?[]const u8 {
        return x.busyboxFileFor(num, false);
    }

    /// `busyboxFile`; with `outputs`, the output-key store too when it is not known yet, in the
    /// same query (see `outputsVolume`).
    pub fn busyboxFileFor(x: *Exec, num: u32, outputs: bool) !?[]const u8 {
        if (x.busybox_id) |id| return id;
        var msg: []const u8 = "";
        var q: Query = .init(x.arena);
        try q.callAs("bb", "container", .{});
        try q.call("from", .{ .address = busybox_image });
        try q.call("file", .{ .path = "/bin/busybox" });
        try q.leaf("id");
        try q.close(3);
        try q.callAs("empty", "directory", .{});
        try q.leaf("id");
        const store = outputs and x.outputs_volume == null and x.output_keys != null;
        if (store) {
            try q.close(1);
            try q.callAs("cout", "cacheVolume", .{ .key = x.output_keys.? });
            try q.leaf("id");
        }
        const data = gql(x.arena, x.transport, try q.finish(), &msg) catch {
            _ = try x.actionFailed(
                num,
                "could not get busybox from {s}: {s}",
                .{ busybox_image, msg },
            );
            return null;
        };
        const id = idOf(data, "bb") orelse {
            _ = try x.actionFailed(num, "could not get busybox from {s}", .{busybox_image});
            return null;
        };
        x.empty_dir = idOf(data, "empty") orelse {
            _ = try x.actionFailed(num, "Dagger returned no directory", .{});
            return null;
        };
        if (store) x.outputs_volume = idOf(data, "cout");
        x.busybox_id = id;
        return id;
    }

    /// A Docker action's image, pulled or built once per job, with its entrypoint and command.
    pub fn imageInfo(x: *Exec, num: u32, image: DockerRun.Image, label: []const u8) !?ImageInfo {
        const arena = x.arena;
        const key = switch (image) {
            .pull => |ref| try std.fmt.allocPrint(arena, "pull {s}", .{ref}),
            .build => |b| try std.fmt.allocPrint(
                arena,
                "build {s} {s} {s}",
                .{ b.dir, b.context, b.dockerfile },
            ),
        };
        if (x.images.get(key)) |info| return info;
        var q: Query = .init(arena);
        switch (image) {
            .pull => |ref| {
                try q.open("container");
                try q.call("from", .{ .address = ref });
            },
            .build => |b| {
                try q.call("loadDirectoryFromID", .{ .id = b.dir });
                try q.call("directory", .{ .path = b.context });
                try q.call("dockerBuild", .{ .dockerfile = b.dockerfile });
            },
        }
        for ([_][]const u8{ "id", "entrypoint", "defaultArgs", "user" }) |f| try q.leaf(f);
        var msg: []const u8 = "";
        const data = gql(arena, x.transport, try q.finish(), &msg) catch {
            switch (image) {
                .pull => |ref| _ = try x.actionFailed(
                    num,
                    "could not pull {s} for {s}: {s}",
                    .{ ref, label, msg },
                ),
                .build => |b| _ = try x.actionFailed(
                    num,
                    "could not build {s} of {s}: {s}",
                    .{ b.dockerfile, label, msg },
                ),
            }
            return null;
        };
        const info: ImageInfo = .{
            .id = jsonFindString(data, "id") orelse {
                _ = try x.actionFailed(num, "could not get the image of {s}", .{label});
                return null;
            },
            .entrypoint = try jsonStrings(arena, jsonFind(data, "entrypoint")),
            .cmd = try jsonStrings(arena, jsonFind(data, "defaultArgs")),
            .user = jsonFindString(data, "user") orelse "",
        };
        try x.images.put(arena, key, info);
        return info;
    }

    /// Logs why one of a composite action's steps could not run, and fails the action.
    fn nestedFailed(
        x: *Exec,
        num: u32,
        ctx_id: []const u8,
        display: []const u8,
        msg: []const u8,
        outcome: *CompositeOutcome,
    ) !void {
        x.sh.errorLine(num, try std.fmt.allocPrint(x.arena, "{s}: {s}", .{ display, msg }));
        try x.ev.steps.append(
            x.arena,
            .{ .id = ctx_id, .outcome = "failure", .conclusion = "failure", .outputs = &.{} },
        );
        outcome.failed = true;
        x.ev.job_failed = true;
        if (outcome.exit_code == 0) outcome.exit_code = 1;
    }

    pub const Loaded = struct {
        meta: action.Metadata,
        /// Dagger Directory id of the action's repository (of the action's own directory, for a
        /// local action).
        dir: []const u8,
        /// Where the repository is mounted, and the action's own directory inside it.
        mount: []const u8,
        path: []const u8,
        /// The action's directory inside `dir` ("" for its root).
        sub: []const u8 = "",
        /// `owner/repo[/path]@ref` or `./path`, for messages.
        ref_label: []const u8,
        /// The commit the action's ref resolved to ("" when not known), for the "Set up job" log.
        sha: []const u8 = "",
        /// `github.action_repository` / `action_ref` (GITHUB_ACTION_REPOSITORY / _REF):
        /// `owner/repo` and the ref, or empty for a local action, as on GitHub.
        repository: []const u8 = "",
        ref: []const u8 = "",
    };

    /// A remote action, fetched once per job however many steps (or composite actions) use it, as
    /// GitHub downloads each action once in "Set up job".
    fn loadAction(x: *Exec, u: job_mod.Uses) !LoadResult {
        const key = try std.fmt.allocPrint(x.arena, "{s}/{s}/{s}@{s}", .{ u.owner, u.name, u.path, u.ref });
        if (x.actions.get(key)) |lr| return lr;
        const lr = try x.fetchAction(u);
        try x.actions.put(x.arena, key, lr);
        return lr;
    }

    /// Fetches the action's repository (Dagger's git support, cached by the engine) and reads its
    /// `action.yml` or `action.yaml`.
    fn fetchAction(x: *Exec, u: job_mod.Uses) !LoadResult {
        const arena = x.arena;
        const repository = try std.fmt.allocPrint(arena, "{s}/{s}", .{ u.owner, u.name });
        const sub = if (u.path.len > 0) try std.fmt.allocPrint(arena, "/{s}", .{u.path}) else "";
        const ref_label = try std.fmt.allocPrint(arena, "{s}{s}@{s}", .{ repository, sub, u.ref });
        // GITHUB_TOKEN reads only the job's own repository; other actions are fetched anonymously.
        const own_repo = std.mem.eql(u8, repository, x.job.github.repository);
        var msg: []const u8 = "";
        const tree_query = try x.actionTreeQuery(u, repository, own_repo);
        const data = gql(arena, x.transport, tree_query, &msg) catch
            return .{ .unresolved = try unresolvedMessage(arena, u, msg, own_repo) };
        const dir = jsonFindString(data, "id") orelse
            return loadFailed(arena, "could not fetch {s}: Dagger returned no tree", .{ref_label});
        const name = actionFileName(data) orelse
            return loadFailed(arena, "{s} has no action.yml or action.yaml", .{ref_label});

        const file_path = try joinPath(arena, u.path, name);
        var fq: Query = .init(arena);
        try fq.call("loadDirectoryFromID", .{ .id = dir });
        try fq.call("file", .{ .path = file_path });
        try fq.leaf("contents");
        const fdata = gql(arena, x.transport, try fq.finish(), &msg) catch
            return loadFailed(arena, "could not read {s} of {s}: {s}", .{ name, ref_label, msg });
        const text = jsonFindString(fdata, "contents") orelse
            return loadFailed(arena, "could not read {s} of {s}", .{ name, ref_label });

        const meta = switch (try action.parse(arena, text)) {
            .ok => |m| m,
            .invalid => |why| return loadFailed(arena, "{s} of {s} {s}", .{ name, ref_label, why }),
        };
        const mount = try std.fmt.allocPrint(arena, "/github/_actions/{s}/{s}", .{
            repository,
            u.ref,
        });
        return .{ .ok = .{
            .meta = meta,
            .dir = dir,
            .mount = mount,
            .path = try joinPath(arena, mount, u.path),
            .sub = u.path,
            .ref_label = ref_label,
            .sha = jsonFindString(data, "sha") orelse "",
            .repository = repository,
            .ref = u.ref,
        } };
    }

    /// The action's repository at its ref: the tree's id, the entries of the action's directory
    /// (to find its metadata file), and the commit it resolved to. The job's token only for its
    /// own repository.
    fn actionTreeQuery(
        x: *Exec,
        u: job_mod.Uses,
        repository: []const u8,
        own_repo: bool,
    ) ![]const u8 {
        const arena = x.arena;
        const server = std.mem.trimEnd(u8, x.job.github.server_url, "/");
        const url = try std.fmt.allocPrint(arena, "{s}/{s}.git", .{ server, repository });
        const auth: ?[]const u8 = if (own_repo) x.gitAuth() else null;
        const auth_user: ?[]const u8 = if (auth != null) "x-access-token" else null;
        var q: Query = .init(arena);
        try q.call("git", .{ .url = url, .httpAuthUsername = auth_user, .httpAuthToken = auth });
        if (isSha(u.ref)) {
            try q.call("commit", .{ .id = u.ref });
        } else {
            try q.call("ref", .{ .name = u.ref });
        }
        try q.call("tree", .{ .depth = @as(u32, 1) });
        try q.leaf("id");
        try q.leafArgs(null, "entries", .{ .path = if (u.path.len > 0) u.path else "." });
        try q.close(1);
        try q.leafAs("sha", "commit");
        return q.finish();
    }

    /// Reads a local action (`uses: ./path`) from the workspace as the job's container has it now,
    /// so the repository must have been checked out first (GitHub says the same). Nothing is
    /// mounted: the action's files are already there.
    fn loadLocal(x: *Exec, u: job_mod.Uses) !LoadResult {
        const arena = x.arena;
        const abs = if (u.path.len > 0) try std.fmt.allocPrint(
            arena,
            "{s}/{s}",
            .{ x.ev.workspace, u.path },
        ) else x.ev.workspace;
        const label = try std.fmt.allocPrint(arena, "./{s}", .{u.path});
        const missing = try std.fmt.allocPrint(
            arena,
            "Can't find 'action.yml' or 'action.yaml' under '{s}'. Did you forget to run " ++
                "actions/checkout before running your local action?",
            .{abs},
        );
        var q: Query = .init(arena);
        try q.call("loadContainerFromID", .{ .id = x.container_id });
        try q.call("directory", .{ .path = abs });
        try q.leaf("id");
        try q.leaf("entries");
        const doc = try q.finish();
        var msg: []const u8 = "";
        const data = gql(arena, x.transport, doc, &msg) catch return .{ .failed = missing };
        const dir = jsonFindString(data, "id") orelse return .{ .failed = missing };
        var file_name: ?[]const u8 = null;
        if (jsonFind(data, "entries")) |entries|
            if (entries == .array) for (entries.array.items) |e| {
                if (e != .string) continue;
                if (std.mem.eql(u8, e.string, "action.yml") or (file_name == null and
                    std.mem.eql(u8, e.string, "action.yaml"))) file_name = e.string;
            };
        const name = file_name orelse return .{ .failed = missing };
        var fq: Query = .init(arena);
        try fq.call("loadDirectoryFromID", .{ .id = dir });
        try fq.call("file", .{ .path = name });
        try fq.leaf("contents");
        const fdoc = try fq.finish();
        const fdata = gql(arena, x.transport, fdoc, &msg) catch
            return .{ .failed = try std.fmt.allocPrint(
                arena,
                "could not read {s} of {s}: {s}",
                .{ name, label, msg },
            ) };
        const text = jsonFindString(fdata, "contents") orelse
            return loadFailed(arena, "could not read {s} of {s}", .{ name, label });
        const meta = switch (try action.parse(arena, text)) {
            .ok => |m| m,
            .invalid => |why| return .{ .failed = try std.fmt.allocPrint(
                arena,
                "{s} of {s} {s}",
                .{ name, label, why },
            ) },
        };
        try x.mounted_actions.put(arena, abs, {});
        return .{ .ok = .{
            .meta = meta,
            .dir = dir,
            .mount = abs,
            .path = abs,
            .ref_label = label,
        } };
    }
};

/// Where a job's event payload is written.
pub const event_dir = "/github/workflow";
pub const event_path = event_dir ++ "/event.json";
/// The volatile variable that carries the event payload when step caching is on.
pub const event_env = "ZIG_RUNNER_EVENT";
/// A value new for every job, in a volatile variable (not part of exec cache keys). Each step
/// writes it with its file commands, so the runner knows for certain whether a step ran in this job
/// or its result was replayed from Dagger's cache, instead of guessing from whether its log lines
/// arrived in time.
pub const ran_env = "ZIG_RUNNER_RAN";
/// The job's secret that its step markers carry (`writeMarkerEcho`): a value new for every job,
/// which a step's own program does not see (`env -u`, as `ran_env`), so a step cannot print another
/// step's `begin` or `end` and have its lines counted as that step's (issue #71). Not `ran_env`'s
/// value: that one is written to the step's file commands, where later steps can read it.
///
/// It is volatile under step caching (not part of exec cache keys); the scripts name the variable,
/// not its value. A replayed exec's recorded output carries an earlier job's value, which
/// `replayRecorded` learns from the recorded `begin` marker, the first line the script prints.
///
/// It keeps out text, not a determined step: one running as the same user can read the value
/// from its parent shell's /proc/<pid>/environ, and steps have sudo anyway.
pub const mark_env = "ZIG_RUNNER_MARK";
/// Linux limits one environment string to 128 KiB; larger payloads are written as a file instead.
const max_event_env = 100 * 1024;

/// Default variables that identify the run rather than its inputs. With step caching they are
/// volatile: they reach every step but do not take part in exec cache keys.
/// RUNNER_NAME belongs here too: a pool registers every job under a new name, so as an input it
/// would make every job's keys new and no step would ever be reused.
/// So do the commit and the refs: as inputs they made every step of a new commit miss, even steps
/// before the checkout. A step whose script names one of these still runs every time
/// (`readsRunSpecific`), and a step that reads the commit some other way still sees a new workspace
/// (`.git` included) after a checkout, so its key changes with the commit anyway.
pub const volatile_env = [_][]const u8{
    "GITHUB_RUN_ID",           "GITHUB_RUN_NUMBER",   "GITHUB_RUN_ATTEMPT",  "GITHUB_ACTOR",
    "GITHUB_TRIGGERING_ACTOR", "RUNNER_NAME",         "GITHUB_SHA",          "GITHUB_REF",
    "GITHUB_REF_NAME",         "GITHUB_REF_TYPE",     "GITHUB_BASE_REF",     "GITHUB_HEAD_REF",
    "GITHUB_ACTOR_ID",         "GITHUB_WORKFLOW_REF", "GITHUB_WORKFLOW_SHA", "GITHUB_REF_PROTECTED",
};

/// What a step that did not name a run-specific value is given instead of one.
///
/// `readsRunSpecific` below is a syntactic test — it looks for the name in the script text — and it
/// cannot be made sound: a script reaches the value through a file it sources, a program that reads
/// the environment, or a name built from pieces. Such a step is then replayed with an earlier run's
/// value, which is wrong rather than merely stale (docs/STUDY.md experiment 2, and the B1 check in
/// properties/). So a step that did not name one does not get one. The value is a constant, so the
/// step's cache key is unaffected; it is in the script's own `env` prefix, so it is part of that
/// key and cannot vary; and it is visible, so a step that prints it says so in its log.
///
/// This is a deliberate divergence from GitHub's runner, which always sets the real values. See
/// docs/SPEC.md "Where this runner differs from GitHub's" and proofs/Runner/Enforce.agda, which is
/// why it is sound: an unmarked step's input becomes a function of its cache key.
pub const volatile_sentinel = "zig-runner-withheld";

/// What a replayable step finds at GITHUB_EVENT_PATH instead of the event payload: the payload
/// differs on every run and is not part of the cache key, so a step that read it without naming it
/// would be replayed with an earlier run's (issue #68: a `workflow_dispatch` input read by a script
/// in a file). It is `volatile_sentinel` as a JSON string, so a parser reads it and anything that
/// looks inside fails (`jq .inputs.version`: cannot index string) instead of quietly getting
/// another run's answer. A step that names GITHUB_EVENT_PATH or the file runs every time, and gets
/// the real one.
pub const withheld_event = "\"" ++ volatile_sentinel ++ "\"";

/// Whether a script names a variable whose value differs between runs while the cache key does not
/// (the volatile ones, and the event payload: its variable or its file). Scripts the step runs from
/// files are not looked into; such a step is given `volatile_sentinel` and `withheld_event` instead.
pub fn readsRunSpecific(script: []const u8) bool {
    for (volatile_env) |v| if (std.mem.indexOf(u8, script, v) != null) return true;
    return std.mem.indexOf(u8, script, "GITHUB_EVENT_PATH") != null or
        std.mem.indexOf(u8, script, event_path) != null;
}

pub fn isVolatile(name: []const u8) bool {
    for (volatile_env) |v| if (std.mem.eql(u8, v, name)) return true;
    return false;
}

/// `ZIG_RUNNER_STEP_CACHE: false` in the workflow's or job's env turns step caching off for the
/// job.
fn optsOutOfStepCache(job_env: []const job_mod.EnvVar) bool {
    for (job_env) |e| if (std.mem.eql(u8, e.name, "ZIG_RUNNER_STEP_CACHE"))
        return std.ascii.eqlIgnoreCase(e.value, "false") or std.mem.eql(u8, e.value, "0");
    return false;
}

fn jobEnvHasSecret(job: job_mod.Job, job_env: []const job_mod.EnvVar) bool {
    for (job_env) |e| if (containsSecret(job, e.value)) return true;
    return false;
}

/// `<run_id>.<run_attempt>`, or the time when the job has no run id (`--exec-job`).
fn runNonce(arena: Allocator, io: std.Io, ev: *const Evaluator) ![]const u8 {
    const id = ev.githubString("run_id");
    if (id.len > 0)
        return std.fmt.allocPrint(arena, "{s}.{s}", .{ id, ev.githubString("run_attempt") });
    return std.fmt.allocPrint(arena, "t{d}", .{std.Io.Clock.real.now(io).toMilliseconds()});
}

/// `dir/name`; one of them alone when the other is empty.
fn joinPath(arena: Allocator, dir: []const u8, name: []const u8) ![]const u8 {
    if (dir.len == 0) return name;
    if (name.len == 0) return dir;
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, name });
}

/// `action.yml` when the directory has one, else `action.yaml`, else null.
fn actionFileName(data: std.json.Value) ?[]const u8 {
    const entries = jsonFind(data, "entries") orelse return null;
    if (entries != .array) return null;
    var found: ?[]const u8 = null;
    for (entries.array.items) |e| {
        if (e != .string) continue;
        if (std.mem.eql(u8, e.string, "action.yml")) return e.string;
        if (found == null and std.mem.eql(u8, e.string, "action.yaml")) found = e.string;
    }
    return found;
}

/// A `uses:` step that cannot run, with why, in the "Set up job" log.
fn loadFailed(arena: Allocator, comptime fmt: []const u8, args: anytype) !Exec.LoadResult {
    return .{ .failed = try std.fmt.allocPrint(arena, fmt, args) };
}

/// The `id` under alias `key` of a query result, or null.
pub fn idOf(data: std.json.Value, key: []const u8) ?[]const u8 {
    const v = jsonFind(data, key) orelse return null;
    return jsonFindString(v, "id");
}

/// What Bun prints when it refuses a program before running any of it, so the program can be run
/// again with Node. actions/setup-python v7's bundle mixes an ES `import` with CommonJS `exports`,
/// which Node accepts.
pub const bun_load_errors = [_][]const u8{"error: Cannot use import statement with CommonJS-only " ++
    "features"};

/// Package managers' cache directories (for root, the default images' user), each mounted from its
/// own cache volume. Their contents are caches the tools validate themselves, so sharing them
/// between jobs is safe; they are keyed by repository (see `packageCacheScope`).
///
/// A `container:` image may put them elsewhere (the golang image's GOPATH is /go), so in a
/// container job a tool with a variable naming its cache directory gets the variable pointing at
/// the volume. The paths stay the default image's: Go keys compiled packages on their source
/// directory, so a module cache at one path everywhere lets every image share the build cache. The
/// container's or the workflow's own value wins (and the tool then works without the volume).
const package_cache_dirs = [_]struct { name: []const u8, path: []const u8, env: []const u8 = "" }{
    // RUNNER_TOOL_CACHE: what setup-node, setup-python, setup-go and the like download and unpack,
    // found again by the next job instead of fetched (GitHub's images come with it filled).
    .{ .name = "toolcache", .path = "/opt/hostedtoolcache" },
    .{ .name = "npm", .path = "/root/.npm", .env = "npm_config_cache" },
    .{ .name = "pnpm", .path = "/root/.local/share/pnpm/store" },
    .{ .name = "yarn", .path = "/usr/local/share/.cache/yarn" },
    .{ .name = "pip", .path = "/root/.cache/pip", .env = "PIP_CACHE_DIR" },
    .{ .name = "uv", .path = "/root/.cache/uv", .env = "UV_CACHE_DIR" },
    .{ .name = "go-mod", .path = "/root/go/pkg/mod", .env = "GOMODCACHE" },
    .{ .name = "go-build", .path = "/root/.cache/go-build", .env = "GOCACHE" },
    .{ .name = "cargo-registry", .path = "/root/.cargo/registry" },
    .{ .name = "cargo-git", .path = "/root/.cargo/git" },
    .{ .name = "bun", .path = "/root/.bun/install/cache", .env = "BUN_INSTALL_CACHE_DIR" },
    .{ .name = "zig", .path = "/root/.cache/zig", .env = "ZIG_GLOBAL_CACHE_DIR" },
    .{ .name = "gradle", .path = "/root/.gradle/caches" },
    .{ .name = "maven", .path = "/root/.m2/repository" },
    // Not package caches, but state tools rewrite on every run, kept out of the container's
    // filesystem so that what a step leaves there is what it produced (see `Options.output_keys`).
    // Node's compile cache: V8 code npm and Node write and Node validates, which also lets them
    // start faster. No variable: NODE_COMPILE_CACHE would turn it on for every Node program; this
    // is where Node puts it when a program turns it on. And Go's local telemetry counters.
    .{ .name = "node-compile-cache", .path = "/tmp/node-compile-cache" },
    .{ .name = "go-telemetry", .path = "/root/.config/go/telemetry" },
};

/// Pull requests from forks get their own volumes, so untrusted code cannot plant content in the
/// caches the repository's own branches use (GitHub scopes its cache by branch for the same
/// reason).
pub fn packageCacheScope(arena: Allocator, ev: *Evaluator, repository: []const u8) ![]const u8 {
    const ctxs = [_]expr.Value.Entry{.{ .key = "github", .value = ev.github }};
    const head = expr.evalString(
        arena,
        "github.event.pull_request.head.repo.full_name",
        .{ .contexts = &ctxs },
    ) catch "";
    return if (head.len > 0 and !std.ascii.eqlIgnoreCase(head, repository)) "fork-pr" else "repo";
}

/// `ACTIONS_STEP_DEBUG` set to true, as a secret or a repository variable, shows `::debug::` lines.
fn stepDebug(arena: Allocator, job: job_mod.Job) bool {
    for (job.secret_vars) |sv| {
        if (!std.mem.eql(u8, sv.name, "ACTIONS_STEP_DEBUG")) continue;
        return std.ascii.eqlIgnoreCase(sv.value, "true");
    }
    if (job.context_data == .object) if (job.context_data.object.get("vars")) |vars| {
        const v = context.fromContextData(arena, vars) catch return false;
        if (v == .object) for (v.object) |e| if (std.mem.eql(u8, e.key, "ACTIONS_STEP_DEBUG")) {
            return e.value == .string and std.ascii.eqlIgnoreCase(e.value.string, "true");
        };
    };
    return false;
}

pub fn hasKey(v: expr.Value, key: []const u8) bool {
    if (v != .object) return false;
    for (v.object) |e| if (std.ascii.eqlIgnoreCase(e.key, key)) return true;
    return false;
}

fn findInput(inputs: []const job_mod.Input, name: []const u8) ?job_mod.Template {
    for (inputs) |in| if (std.ascii.eqlIgnoreCase(in.name, name)) return in.value;
    return null;
}

/// `base` (an object, or null) with `extra` entries added or replaced.
pub fn withEntries(arena: Allocator, base: expr.Value, extra: []const expr.Value.Entry) !expr.Value {
    var list: std.ArrayList(expr.Value.Entry) = .empty;
    if (base == .object) for (base.object) |e| {
        var replaced = false;
        for (extra) |x| if (std.ascii.eqlIgnoreCase(x.key, e.key)) {
            replaced = true;
        };
        if (!replaced) try list.append(arena, e);
    };
    try list.appendSlice(arena, extra);
    return .{ .object = list.items };
}

fn firstLine(s: []const u8) []const u8 {
    const t = std.mem.trim(u8, s, " \n\r\t");
    return t[0 .. std.mem.indexOfScalar(u8, t, '\n') orelse t.len];
}

/// Dagger itself failed during a step: the step and the job fail with what Dagger said.
/// A step its timeout or the job's cancellation stopped, logged as GitHub's runner logs it. A timed
/// out step failed (continue-on-error applies); a cancelled one is `cancelled`, and so is the job.
fn stepInterrupted(
    ev: *Evaluator,
    sh: *Shared,
    observer: ?Observer,
    step: job_mod.Step,
    res: *StepResult,
    num: u32,
    coe: bool,
    intr: Watch.Interrupt,
    timeout: []const u8,
) !void {
    res.completed_ms = std.Io.Clock.real.now(sh.io).toMilliseconds();
    res.exit_code = 1;
    switch (intr) {
        .timed_out => {
            sh.errorLine(
                num,
                try std.fmt.allocPrint(ev.arena, "The action '{s}' has timed out after {s} " ++
                    "minutes.", .{ res.name, std.mem.trim(u8, timeout, " ") }),
            );
            res.outcome = .failure;
            if (!coe) ev.job_failed = true;
        },
        .cancelled, .none => {
            sh.errorLine(num, "The operation was canceled.");
            res.outcome = .cancelled;
            ev.cancelled = true;
        },
    }
    try ev.record(step, res.outcome, coe, &.{});
    if (observer) |o| o.finished(num, res.*);
}

fn engineFailed(
    x: *Exec,
    observer: ?Observer,
    res: *StepResult,
    num: u32,
    coe: bool,
    results: []StepResult,
) !Result {
    res.* = .{
        .name = res.name,
        .continued = coe,
        .outcome = .failure,
        .exit_code = 1,
        .started_ms = res.started_ms,
        .completed_ms = std.Io.Clock.real.now(x.io).toMilliseconds(),
    };
    x.sh.append(num, try std.fmt.allocPrint(x.arena, "Dagger error: {s}", .{x.err_msg}));
    if (observer) |o| o.finished(num, res.*);
    return finish(x.arena, x.sh, results, x.err_msg);
}

/// The contents of a file command read by the step's query ("" when the field is absent).
/// The exec's exit code; 1 when the result lacks one.
fn exitCode(data: std.json.Value) i32 {
    const c = jsonFind(data, "exitCode") orelse return 1;
    return if (c == .integer) @intCast(c.integer) else 1;
}

fn fileCommand(data: std.json.Value, alias: []const u8) ?[]const u8 {
    if (jsonFind(data, "fc_all")) |all| {
        const text = combinedFileCommand(
            jsonFindString(all, "contents") orelse return null,
            alias["fc_".len..],
        ) orelse return null;
        return if (text.len == 0) null else text;
    }
    const f = jsonFind(data, alias) orelse return null;
    const text = jsonFindString(f, "contents") orelse return null;
    return if (text.len == 0) null else text;
}

/// One kind's contents in a combined file (see `writeCombinedFileCommands`).
fn combinedFileCommand(all: []const u8, kind: []const u8) ?[]const u8 {
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, all, start, fc_marker)) |i| {
        const line_end = std.mem.indexOfScalarPos(u8, all, i, '\n') orelse return null;
        const body = line_end + 1;
        // The next marker starts a line; the newline before it is the one added after the contents.
        const next = std.mem.indexOfPos(u8, all, body, "\n" ++ fc_marker) orelse all.len;
        if (std.mem.eql(u8, all[i + fc_marker.len .. line_end], kind)) {
            const at_end = next == all.len;
            const trailing_newline = at_end and all.len > body and all[all.len - 1] == '\n';
            const end = if (trailing_newline) all.len - 1 else next;
            return all[body..@max(body, end)];
        }
        start = if (next == all.len) all.len else next + 1;
    }
    return null;
}

test "file commands come back from one combined file" {
    const all = "::zig-file-command::output\nversion=1\nnotes<<EOF\na\nEOF\n\n::zig-file-command::env\n\n::zig-file-command::path\n/opt/x/bin\n\n::zig-file-command::step_summary\nno newline at end\n::zig-file-command::state\n\n";
    try std.testing.expectEqualStrings("version=1\nnotes<<EOF\na\nEOF\n", combinedFileCommand(all, "output").?);
    try std.testing.expectEqualStrings("", combinedFileCommand(all, "env").?);
    try std.testing.expectEqualStrings("/opt/x/bin\n", combinedFileCommand(all, "path").?);
    try std.testing.expectEqualStrings("no newline at end", combinedFileCommand(all, "step_summary").?);
    try std.testing.expectEqualStrings("", combinedFileCommand(all, "state").?);
    try std.testing.expect(combinedFileCommand(all, "missing") == null);
}

/// Logs why a step could not run and marks it failed (the job too, unless continue-on-error).
fn failStep(
    ev: *Evaluator,
    sh: *Shared,
    observer: ?Observer,
    step: job_mod.Step,
    res: *StepResult,
    num: u32,
    msg: []const u8,
    coe: bool,
) !void {
    sh.append(num, msg);
    const name = res.name;
    res.* = .{ .name = name, .continued = coe, .outcome = .failure, .exit_code = 1 };
    try ev.record(step, .failure, coe, &.{});
    if (!coe) ev.job_failed = true;
    if (observer) |o| o.finished(num, res.*);
}

fn fail(sh: *Shared, results: []StepResult, msg: []const u8) !Result {
    sh.flush();
    return .{ .steps = results, .engine_error = msg, .succeeded = false };
}

fn finish(arena: Allocator, sh: *Shared, results: []StepResult, engine_msg: []const u8) !Result {
    sh.flush();
    var any_failed = false;
    var any_not_run = false;
    for (results) |res| {
        if (res.outcome == .failure and !res.continued) any_failed = true;
        if (res.outcome == .not_run) any_not_run = true;
    }
    var engine_error: ?[]const u8 = null;
    if ((any_not_run and !any_failed) or engine_msg.len > 0) {
        sh.mu.lockUncancelable(sh.io);
        defer sh.mu.unlock(sh.io);
        const tail = try std.mem.join(arena, "\n", sh.tail[0..sh.tail_len]);
        engine_error = if (engine_msg.len > 0)
            try std.fmt.allocPrint(
                arena,
                "{s}{s}{s}",
                .{ engine_msg, if (tail.len > 0) "\n" else "", tail },
            )
        else
            tail;
    }
    return .{
        .steps = results,
        .engine_error = engine_error,
        .succeeded = !any_failed and engine_error == null,
        .annotations = sh.annotations.items,
    };
}

// --- tests ---

const FakeAbort = struct {
    in_flight: bool = false,
    aborted: u32 = 0,

    fn send(_: *anyopaque, _: Allocator, _: []const u8, _: usize) anyerror![]const u8 {
        return "";
    }
    fn abort(ptr: *anyopaque) bool {
        const f: *FakeAbort = @ptrCast(@alignCast(ptr));
        if (!f.in_flight) return false;
        f.aborted += 1;
        f.in_flight = false;
        return true;
    }
    fn transport(f: *FakeAbort) Transport {
        return .{ .ptr = f, .sendFn = send, .abortFn = abort };
    }
};

test "a step past its timeout is stopped, and only that step" {
    var f: FakeAbort = .{};
    var w: Watch = .{ .io = std.testing.io, .transport = f.transport(), .cancel = null };
    w.begin(1_000);
    f.in_flight = true;
    w.tick(999);
    try std.testing.expectEqual(@as(u32, 0), f.aborted);
    w.tick(1_001);
    try std.testing.expectEqual(@as(u32, 1), f.aborted);
    try std.testing.expectEqual(Watch.Interrupt.timed_out, w.end());
    // The next step has no timeout: nothing reaches it.
    w.begin(0);
    f.in_flight = true;
    w.tick(5_000);
    try std.testing.expectEqual(@as(u32, 1), f.aborted);
    try std.testing.expectEqual(Watch.Interrupt.none, w.end());
}

test "a deadline passed between a step's queries stops its next query" {
    var f: FakeAbort = .{};
    var w: Watch = .{ .io = std.testing.io, .transport = f.transport(), .cancel = null };
    w.begin(1_000);
    w.tick(2_000); // no query in flight
    f.in_flight = true;
    w.tick(2_200);
    try std.testing.expectEqual(Watch.Interrupt.timed_out, w.end());
}

test "a cancel stops the running step, not the always() steps after it, until the grace period ends" {
    var f: FakeAbort = .{};
    var c: Cancel = .{};
    var w: Watch = .{ .io = std.testing.io, .transport = f.transport(), .cancel = &c };
    w.begin(0);
    f.in_flight = true;
    c.hard_deadline_ms.store(10_000, .release);
    c.requested.store(true, .release);
    w.tick(1_000);
    try std.testing.expectEqual(Watch.Interrupt.cancelled, w.end());
    // An `if: always()` step after it runs.
    w.begin(0);
    f.in_flight = true;
    w.tick(2_000);
    try std.testing.expectEqual(@as(u32, 1), f.aborted);
    try std.testing.expectEqual(Watch.Interrupt.none, w.end());
    // Past the grace period, whatever runs is stopped.
    w.begin(0);
    f.in_flight = true;
    w.tick(10_001);
    try std.testing.expectEqual(@as(u32, 2), f.aborted);
    try std.testing.expectEqual(Watch.Interrupt.cancelled, w.end());
}

test "a second cancel can shorten the grace period, never lengthen it" {
    var c: Cancel = .{};
    c.request(10_000);
    try std.testing.expect(c.requested.load(.acquire));
    try std.testing.expectEqual(@as(i64, 10_000), c.hard_deadline_ms.load(.acquire));
    c.request(50_000); // GitHub's 5 minutes, after the runner's stop cancelled the job
    try std.testing.expectEqual(@as(i64, 10_000), c.hard_deadline_ms.load(.acquire));
    c.request(2_000); // GitHub no longer has the job: nothing runs on
    try std.testing.expectEqual(@as(i64, 2_000), c.hard_deadline_ms.load(.acquire));
}

test "a cancel between steps does not stop the next step" {
    var f: FakeAbort = .{};
    var c: Cancel = .{};
    var w: Watch = .{ .io = std.testing.io, .transport = f.transport(), .cancel = &c };
    c.requested.store(true, .release);
    w.tick(1_000);
    w.begin(0);
    f.in_flight = true;
    w.tick(1_200);
    try std.testing.expectEqual(@as(u32, 0), f.aborted);
    try std.testing.expectEqual(Watch.Interrupt.none, w.end());
}

test "evalCondition" {
    try std.testing.expectEqual(@as(?bool, true), evalCondition("success()", false));
    try std.testing.expectEqual(@as(?bool, false), evalCondition("success()", true));
    try std.testing.expectEqual(@as(?bool, true), evalCondition("failure()", true));
    try std.testing.expectEqual(@as(?bool, true), evalCondition(" always() ", true));
    try std.testing.expectEqual(@as(?bool, null), evalCondition("github.ref == 'x'", false));
}

/// An exec's answer that says whether it ran in the job marked `ran` (`Exec.ranThisRun`).
fn execRan(arena: Allocator, id: []const u8, code: i32, out: []const u8, ran: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        arena,
        "{{\"data\":{{\"loadContainerFromID\":{{\"withExec\":{{\"id\":\"{s}\"," ++
            "\"exitCode\":{d},\"stdout\":\"{s}\",\"stderr\":\"\",\"fc_ran\":{{\"contents\":\"{s}\"}}}}}}}}}}",
        .{ id, code, out, ran },
    );
}

test "step caching: a step run again after a replayed failure keeps the exports of the step before" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);
    const steps = [_]job_mod.Step{ testStep("setup"), testStep("./test.sh") };
    // The step before exports MODE (GITHUB_ENV); the step's first answer is an earlier job's
    // failure, so it runs again, and that second try must start from MODE too, as must what
    // follows (the audit of #80 found the second try without it).
    const answers = [_][]const u8{
        base_answer,
        "{\"data\":{\"loadContainerFromID\":{\"withExec\":{\"id\":\"C1\",\"exitCode\":0,\"stdout\":\"\",\"stderr\":\"\"," ++
            "\"fc_ran\":{\"contents\":\"j1\"},\"fc_env\":{\"contents\":\"MODE=ci\\n\"}}}}}",
        try execRan(arena, "C2", 1, "failed", "earlier-job"),
        try execRan(arena, "C3", 0, "passed", "j1"),
    };
    var fake: FakeSession = .{ .answers = &answers, .arena = arena };
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    const res = try run(arena, std.testing.io, &env, .{ .step_cache = true, .test_ran_marker = "j1", .test_session_argv = &.{ "sh", "-c", fake_child }, .test_transport = fake.transport() }, testJob(&steps), &log);
    try std.testing.expect(res.succeeded);
    const seen = fake.seen.items;
    try std.testing.expectEqual(@as(usize, 4), seen.len);
    const mode = "withEnvVariable(name:\"MODE\",value:\"ci\")";
    try std.testing.expect(std.mem.indexOf(u8, seen[2], mode) != null);
    try std.testing.expect(std.mem.indexOf(u8, seen[3], "its earlier run failed") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen[3], mode) != null);
}

test "step caching: a failure the cache kept from an earlier run is not replayed, the step runs again" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);
    const steps = [_]job_mod.Step{testStep("npm test")};
    // #69: the first answer is an earlier job's failure (its ran marker is not this job's); the
    // step runs again, stamped, and this time passes. Then: a failure in this very job stands.
    for ([_]bool{ true, false }) |replayed| {
        const answers = [_][]const u8{
            base_answer,
            try execRan(arena, "C1", 137, "killed", if (replayed) "earlier-job" else "j1"),
            try execRan(arena, "C2", 0, "passed", "j1"),
        };
        var fake: FakeSession = .{ .answers = &answers, .arena = arena };
        var buf: [4096]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
        const res = try run(arena, std.testing.io, &env, .{ .step_cache = true, .test_ran_marker = "j1", .test_session_argv = &.{ "sh", "-c", fake_child }, .test_transport = fake.transport() }, testJob(&steps), &log);
        const seen = fake.seen.items;
        const got = w.buffered();
        if (replayed) {
            try std.testing.expect(res.succeeded);
            try std.testing.expectEqual(@as(usize, 3), seen.len);
            try std.testing.expect(std.mem.indexOf(u8, seen[1], "runs this step every time") == null);
            try std.testing.expect(std.mem.indexOf(u8, seen[2], "zig-runner runs this step every time: its earlier run failed, and a failure is not replayed (run ") != null);
            // The earlier job's output is never shown; this run's is.
            try std.testing.expect(std.mem.indexOf(u8, got, "killed") == null);
            try std.testing.expect(std.mem.indexOf(u8, got, "passed") != null);
        } else {
            try std.testing.expect(!res.succeeded);
            try std.testing.expectEqual(@as(usize, 2), seen.len);
        }
    }
}

test "run threads the container through steps, applies conditions, and replays cached output" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);

    var s3 = testStep("c");
    s3.condition = "always()";
    var s4 = testStep("d");
    s4.condition = "success()";
    const steps = [_]job_mod.Step{ testStep("a"), testStep("b"), s3, s4 };
    const answers = [_][]const u8{
        base_answer,
        try exec(arena, "C1", 0, "from-a\\n"),
        try exec(arena, "C2", 3, "from-b\\n"),
        try exec(arena, "C3", 0, "from-c\\n"),
    };
    var fake: FakeSession = .{ .answers = &answers, .arena = arena };

    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    const res = try run(arena, std.testing.io, &env, .{ .test_session_argv = &.{ "sh", "-c", fake_child }, .test_transport = fake.transport() }, testJob(&steps), &log);

    try std.testing.expectEqual(Outcome.success, res.steps[0].outcome);
    try std.testing.expectEqual(Outcome.failure, res.steps[1].outcome);
    try std.testing.expectEqual(@as(i32, 3), res.steps[1].exit_code);
    try std.testing.expectEqual(Outcome.success, res.steps[2].outcome); // always()
    try std.testing.expectEqual(Outcome.skipped, res.steps[3].outcome); // success() after a failure
    try std.testing.expect(!res.succeeded);
    // Every document is well-formed GraphQL (balanced braces outside of strings).
    for (fake.seen.items) |d| try std.testing.expect(braceBalanced(d));
    // Each step started from the previous step's container.
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[1], "id:\"C0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[2], "id:\"C1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[3], "id:\"C2\"") != null);
    try std.testing.expectEqual(@as(usize, 4), fake.seen.items.len); // the skipped step sends nothing
    // No live lines were streamed, so the recorded stdout was replayed.
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "[job 0 step 1 stdout] from-a\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "[job 0 step 2 stdout] from-b\n") != null);
}

test "run streams live lines from the session's log and does not replay them" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);
    const steps = [_]job_mod.Step{testStep("a")};
    const answers = [_][]const u8{ base_answer, try exec(arena, "C1", 0, "live-line\\n") };
    var fake: FakeSession = .{ .answers = &answers, .arena = arena };

    // The fake child also prints Dagger-style log output: noise, a span header, then the step's lines.
    const child =
        \\printf '0 tok\n'
        \\{ echo "connecting"; printf '\342\226\274 withExec sh -c '\''echo '\\\\'\''::zig-step::begin 1'\\\\'\''\\\\nexit $rc\\\\n'\'' (expect: ANY)\n'
        \\  echo "::zig-step::begin 1 m-job"; echo "live-line"; echo "::zig-step::end 1 m-job"; } >&2
        \\cat >/dev/null
    ;
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    const res = try run(arena, std.testing.io, &env, .{ .test_step_mark = "m-job", .test_session_argv = &.{ "sh", "-c", child }, .test_transport = fake.transport() }, testJob(&steps), &log);
    try std.testing.expect(res.succeeded);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, w.buffered(), "live-line\n"));
    // The markers carry the job's secret, so they are markers, not output.
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), marker) == null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "withExec") == null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "connecting") == null);
}

test "run reports an engine error when the session cannot start" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);
    const steps = [_]job_mod.Step{testStep("a")};
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    const res = try run(arena, std.testing.io, &env, .{ .test_session_argv = &.{ "sh", "-c", "echo 'cannot connect to docker' >&2; exit 1" } }, testJob(&steps), &log);
    try std.testing.expect(!res.succeeded);
    try std.testing.expect(res.engine_error != null);
    try std.testing.expectEqual(Outcome.not_run, res.steps[0].outcome);
}

test "run evaluates expressions in conditions, names, env, scripts and the steps context" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);

    const json =
        \\{"plan":{"planId":"p"},"jobId":"j","resources":{"endpoints":[{"authorization":{"parameters":{"AccessToken":"t"}}}]},
        \\ "variables":{"TOKEN":{"value":"s3cr3t-value","isSecret":true}},
        \\ "environmentVariables":[{"type":2,"map":[{"Key":{"lit":"JOB_ENV"},"Value":{"type":3,"expr":"format('{0}-job', github.ref_name)"}},{"Key":{"lit":"JOB_SECRET"},"Value":{"type":3,"expr":"secrets.TOKEN"}}]}],
        \\ "contextData":{"matrix":null,"github":{"t":2,"d":[{"k":"ref","v":"refs/heads/main"},{"k":"ref_name","v":"main"},{"k":"sha","v":"abc123"},{"k":"repository","v":"o/r"}]}},
        \\ "steps":[
        \\  {"type":"action","reference":{"type":"script"},"id":"s1","contextName":"first","name":"first","condition":"success()",
        \\   "displayNameToken":{"type":3,"expr":"format('Build {0}', github.ref_name)"},
        \\   "environment":{"type":2,"map":[{"Key":{"lit":"STEP_ENV"},"Value":{"type":3,"expr":"github.sha"}}]},
        \\   "inputs":{"type":2,"map":[{"Key":{"lit":"script"},"Value":{"type":3,"expr":"format('echo {0} $STEP_ENV {1}', github.sha, env.JOB_ENV)"}}]}},
        \\  {"type":"action","reference":{"type":"script"},"id":"s2","contextName":"__run","name":"__run","condition":"success() && (github.ref == 'refs/heads/main')",
        \\   "inputs":{"type":2,"map":[{"Key":{"lit":"script"},"Value":{"lit":"echo on-main"}}]}},
        \\  {"type":"action","reference":{"type":"script"},"id":"s3","contextName":"__run_2","name":"__run_2","condition":"success() && (github.ref == 'refs/heads/other')",
        \\   "inputs":{"type":2,"map":[{"Key":{"lit":"script"},"Value":{"lit":"echo never"}}]}},
        \\  {"type":"action","reference":{"type":"script"},"id":"s4","contextName":"__run_3","name":"__run_3","condition":"success()",
        \\   "inputs":{"type":2,"map":[{"Key":{"lit":"script"},"Value":{"type":3,"expr":"format('echo outcome={0} skipped={1}', steps.first.outcome, steps.__run_2.outcome)"}}]}},
        \\  {"type":"action","reference":{"type":"script"},"id":"s5","contextName":"__run_4","name":"__run_4","condition":"success()",
        \\   "environment":{"type":2,"map":[{"Key":{"lit":"DB_PASSWORD"},"Value":{"type":3,"expr":"secrets.TOKEN"}},{"Key":{"lit":"WITH_SECRET"},"Value":{"type":3,"expr":"format('user:{0}@host', secrets.TOKEN)"}}]},
        \\   "inputs":{"type":2,"map":[{"Key":{"lit":"script"},"Value":{"lit":"echo uses-secret-env"}}]}},
        \\  {"type":"action","reference":{"type":"script"},"id":"s6","contextName":"__run_5","name":"__run_5","condition":"always()",
        \\   "inputs":{"type":2,"map":[{"Key":{"lit":"script"},"Value":{"lit":"echo cleanup"}}]}}
        \\ ]}
    ;
    const job = try job_mod.parse(arena, json);
    const answers = [_][]const u8{
        "{\"data\":{\"zsec0\":{\"id\":\"SEC_JOB\"}}}", // JOB_SECRET (job-level env), before the base container
        base_answer,
        try exec(arena, "C1", 0, "ok\\n"),
        try exec(arena, "C2", 0, "ok\\n"),
        try exec(arena, "C3", 0, "ok\\n"),
        // WITH_SECRET; DB_PASSWORD has JOB_SECRET's value, which is registered already.
        "{\"data\":{\"zsec0\":{\"id\":\"SEC_B\"}}}",
        try exec(arena, "C4", 0, "ok\\n"),
        try exec(arena, "C5", 0, "ok\\n"),
    };
    var fake: FakeSession = .{ .answers = &answers, .arena = arena };
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    const res = try run(arena, std.testing.io, &env, .{ .test_session_argv = &.{ "sh", "-c", fake_child }, .test_transport = fake.transport() }, job, &log);

    // Names and outcomes.
    try std.testing.expectEqualStrings("Build main", res.steps[0].name);
    try std.testing.expectEqual(Outcome.success, res.steps[0].outcome);
    try std.testing.expectEqual(Outcome.success, res.steps[1].outcome);
    try std.testing.expectEqual(Outcome.skipped, res.steps[2].outcome); // condition false
    try std.testing.expectEqual(Outcome.success, res.steps[3].outcome);
    try std.testing.expectEqual(Outcome.success, res.steps[4].outcome);
    try std.testing.expectEqual(Outcome.success, res.steps[5].outcome);
    try std.testing.expect(res.succeeded);
    for (fake.seen.items) |d| try std.testing.expect(braceBalanced(d));
    // seen: 0 setSecret(job), 1 base, 2 s1, 3 s2, 4 s4, 5 setSecret, 6 s5, 7 s6
    try std.testing.expectEqual(@as(usize, 8), fake.seen.items.len);
    // Evaluated scripts reached Dagger: sha, step env, job env (from an expression), steps.* outcomes.
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[2], "echo abc123 $STEP_ENV main-job") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[2], "STEP_ENV=abc123") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[4], "echo outcome=success skipped=skipped") != null);
    // Job-level env is part of the base container: the plain value inline, the secret as a Dagger secret.
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[1], "withEnvVariable(name:\"JOB_ENV\",value:\"main-job\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[1], "withSecretVariable(name:\"JOB_SECRET\",secret:\"SEC_JOB\")") != null);
    // Secret-bearing step env is passed as Dagger secrets under aliases, given its name by the script,
    // removed again after the step, and appears nowhere in a command.
    const s5 = fake.seen.items[6];
    try std.testing.expect(std.mem.indexOf(u8, s5, "withSecretVariable(name:\"ZIG_SECRET_0\",secret:\"SEC_JOB\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, s5, "withSecretVariable(name:\"ZIG_SECRET_1\",secret:\"SEC_B\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, s5, "env -u ZIG_SECRET_0 -u ZIG_SECRET_1 ") != null);
    try std.testing.expect(std.mem.indexOf(u8, s5, "'DB_PASSWORD='\\\"$ZIG_SECRET_0\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, s5, "withoutSecretVariable(name:\"ZIG_SECRET_0\") { withoutSecretVariable(name:\"ZIG_SECRET_1\") { id } }") != null);
    // The next step does not get them.
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[7], "ZIG_SECRET") == null);
    for (fake.seen.items, 0..) |d, i| {
        const is_set_secret = std.mem.indexOf(u8, d, "setSecret") != null;
        try std.testing.expectEqual(is_set_secret, std.mem.indexOf(u8, d, "s3cr3t-value") != null);
        _ = i;
    }
}

test "file commands: outputs feed steps.<id>.outputs, GITHUB_ENV and GITHUB_PATH reach later steps" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);
    const json =
        \\{"plan":{"planId":"p"},"jobId":"j","resources":{"endpoints":[{"authorization":{"parameters":{"AccessToken":"t"}}}]},
        \\ "contextData":{"github":{"t":2,"d":[{"k":"sha","v":"abc"},{"k":"repository","v":"o/r"},{"k":"ref_name","v":"main"}]}},
        \\ "steps":[
        \\  {"type":"action","reference":{"type":"script"},"id":"s1","contextName":"build","name":"build","condition":"success()",
        \\   "inputs":{"type":2,"map":[{"Key":{"lit":"script"},"Value":{"lit":"echo producing"}}]}},
        \\  {"type":"action","reference":{"type":"script"},"id":"s2","contextName":"use","name":"use","condition":"success()",
        \\   "inputs":{"type":2,"map":[{"Key":{"lit":"script"},"Value":{"type":3,"expr":"format('echo version={0} multi={1} env=$FROM_ENV', steps.build.outputs.version, steps.build.outputs.notes)"}}]}},
        \\  {"type":"action","reference":{"type":"script"},"id":"s3","contextName":"bad","name":"bad","condition":"success()",
        \\   "inputs":{"type":2,"map":[{"Key":{"lit":"script"},"Value":{"lit":"echo writes garbage"}}]}},
        \\  {"type":"action","reference":{"type":"script"},"id":"s4","contextName":"after","name":"after","condition":"always()",
        \\   "inputs":{"type":2,"map":[{"Key":{"lit":"script"},"Value":{"lit":"echo done"}}]}}
        \\ ]}
    ;
    const job = try job_mod.parse(arena, json);
    const answers = [_][]const u8{
        base_answer,
        try execFc(arena, "C1", "producing\\n", "version=1.2.3\\nnotes<<EOF\\nline a\\nline b\\nEOF\\n", "FROM_ENV=hello\\nGITHUB_SHA=evil\\n", "/opt/tool/bin\\n"),
        try execFc(arena, "C2", "x\\n", "", "", ""),
        try execFc(arena, "C3", "y\\n", "this is not valid\\n", "", ""),
        try execFc(arena, "C4", "z\\n", "", "", ""),
    };
    var fake: FakeSession = .{ .answers = &answers, .arena = arena };
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    const res = try run(arena, std.testing.io, &env, .{ .test_session_argv = &.{ "sh", "-c", fake_child }, .test_transport = fake.transport() }, job, &log);

    for (fake.seen.items) |d| try std.testing.expect(braceBalanced(d));
    // Default environment is set once on the base container.
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[0], "withEnvVariable(name:\"GITHUB_SHA\",value:\"abc\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[0], "name:\"CI\",value:\"true\"") != null);
    // Step 1's query reads the file commands.
    // One read for all of a step's file commands, combined by its script.
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[1], "fc_all: file(path:\"/github/file_commands/all_1\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[1], "fc_output: file(") == null);
    // Outputs (including a multi-line one) were evaluated into step 2's script.
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[2], "echo version=1.2.3 multi=line a\\nline b env=$FROM_ENV") != null);
    // GITHUB_ENV and GITHUB_PATH apply to the next step's container; reserved names are refused.
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[2], "withEnvVariable(name:\"FROM_ENV\",value:\"hello\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[2], "withEnvVariable(name:\"PATH\",value:\"/opt/tool/bin:$PATH\",expand:true)") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[2], "name:\"GITHUB_SHA\",value:\"evil\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "ignored GITHUB_ENV entry 'GITHUB_SHA'") != null);
    // ...and only once: step 3 no longer re-applies them.
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[3], "withEnvVariable") == null);
    // A malformed GITHUB_OUTPUT fails the step that wrote it; always() still runs.
    try std.testing.expectEqual(Outcome.failure, res.steps[2].outcome);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "Unable to process the GITHUB_OUTPUT file command: invalid format 'this is not valid' on line 1") != null);
    try std.testing.expectEqual(Outcome.success, res.steps[3].outcome);
}

test "the default image is provisioned with git; a custom image is left alone" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);
    const steps = [_]job_mod.Step{testStep("true")};
    for ([_]struct { image: []const u8, expect_provision: bool }{
        .{ .image = default_image, .expect_provision = true },
        .{ .image = "custom/image:1", .expect_provision = false },
    }) |case| {
        const answers = [_][]const u8{ base_answer, try exec(arena, "C1", 0, "") };
        var fake: FakeSession = .{ .answers = &answers, .arena = arena };
        var buf: [512]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
        _ = try run(arena, std.testing.io, &env, .{ .image = case.image, .test_session_argv = &.{ "sh", "-c", fake_child }, .test_transport = fake.transport() }, testJob(&steps), &log);
        const base = fake.seen.items[0];
        try std.testing.expect(braceBalanced(base));
        try std.testing.expectEqual(case.expect_provision, std.mem.indexOf(u8, base, "apt-get install") != null);
        try std.testing.expect(std.mem.indexOf(u8, base, case.image) != null);
    }
}

const Recorder = struct {
    events: std.ArrayList([]const u8) = .empty,
    arena: Allocator,

    fn started(ptr: *anyopaque, number: u32, name: []const u8, started_ms: i64) void {
        const self: *Recorder = @ptrCast(@alignCast(ptr));
        const msg = std.fmt.allocPrint(
            self.arena,
            "start {d} {s} {s}",
            .{ number, name, if (started_ms > 0) "t" else "-" },
        ) catch return;
        self.events.append(self.arena, msg) catch {};
    }

    fn finished(ptr: *anyopaque, number: u32, r: StepResult) void {
        const self: *Recorder = @ptrCast(@alignCast(ptr));
        const msg = std.fmt.allocPrint(
            self.arena,
            "finish {d} {s} {s}",
            .{ number, r.name, @tagName(r.outcome) },
        ) catch return;
        self.events.append(self.arena, msg) catch {};
    }
};

test "the observer sees each step start and finish, including skipped and failed-to-evaluate steps" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);
    var s2 = testStep("never");
    s2.condition = "failure()";
    var s3 = testStep("x");
    s3.action = .{ .unsupported = "not supported here" };
    const steps = [_]job_mod.Step{ testStep("ok"), s2, s3, testStep("bad") };
    const answers = [_][]const u8{ base_answer, try exec(arena, "C1", 0, "a\\n"), try exec(arena, "C2", 1, "b\\n") };
    var fake: FakeSession = .{ .answers = &answers, .arena = arena };
    var rec: Recorder = .{ .arena = arena };
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    // step 3 is unsupported (fails without running); step 4 is skipped by success() afterwards.
    _ = try run(arena, std.testing.io, &env, .{
        .test_session_argv = &.{ "sh", "-c", fake_child },
        .test_transport = fake.transport(),
        .observer = .{ .ptr = &rec, .startedFn = Recorder.started, .finishedFn = Recorder.finished },
    }, testJob(&steps), &log);

    const want = [_][]const u8{
        "start 1 n t", // the step has begun, with a start time
        "finish 1 n success",
        "finish 2 n skipped", // failure() was false: reported once, never "started"
        "finish 3 n failure", // unsupported: reported once, never "started"
        "finish 4 n skipped", // success() after a failure
    };
    try std.testing.expectEqual(want.len, rec.events.items.len);
    for (want, rec.events.items) |expected, got| try std.testing.expectEqualStrings(expected, got);
}

// --- composite actions ---

test "a composite action runs its steps with its inputs, and its outputs reach later steps" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);

    const action_yml =
        \\inputs:
        \\  version:
        \\    default: latest
        \\  verb:
        \\    default: call
        \\outputs:
        \\  out:
        \\    value: ${{ steps.second.outputs.result }}-${{ inputs.version }}
        \\runs:
        \\  using: composite
        \\  steps:
        \\    - shell: bash
        \\      run: echo v=${{ inputs.version }} verb=${{ inputs.verb }} path=${{ github.action_path }}
        \\    - id: skipped
        \\      if: inputs.verb == 'nope'
        \\      shell: bash
        \\      run: echo never
        \\    - id: second
        \\      shell: sh
        \\      env:
        \\        X: ${{ inputs.version }}
        \\      run: echo "result=ok" >> "$GITHUB_OUTPUT"
    ;
    const inputs = [_]job_mod.Input{ .{ .name = "version", .value = .{ .lit = "0.21.10" } }, .{ .name = "bogus", .value = .{ .lit = "1" } } };
    var after = testStep("");
    after.action.script.script = .{ .expr = "format('echo {0}', steps.dag.outputs.out)" };
    const steps = [_]job_mod.Step{ usesStep("dag", "o", "act", "v1", &inputs), after };
    const answers = [_][]const u8{
        base_answer,
        try treeAnswer(arena, "D1", &.{ "README.md", "action.yml" }),
        try fileAnswer(arena, action_yml),
        try exec(arena, "C1", 0, ""),
        try execFc(arena, "C2", "", "result=ok\\n", "", ""),
        try exec(arena, "C3", 0, ""),
    };
    var fake: FakeSession = .{ .answers = &answers, .arena = arena };
    var buf: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    const res = try run(arena, std.testing.io, &env, .{ .test_session_argv = &.{ "sh", "-c", fake_child }, .test_transport = fake.transport() }, testJob(&steps), &log);

    try std.testing.expect(res.succeeded);
    try std.testing.expectEqual(Outcome.success, res.steps[0].outcome);
    const seen = fake.seen.items;
    try std.testing.expectEqual(@as(usize, 6), seen.len); // the skipped step never runs
    for (seen) |d| try std.testing.expect(braceBalanced(d));
    try std.testing.expect(std.mem.indexOf(u8, seen[1], "git(url:\"https://github.com/o/act.git\") { ref(name:\"v1\") { tree(depth:1) { id entries(path:\".\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen[2], "loadDirectoryFromID(id:\"D1\") { file(path:\"action.yml\")") != null);
    // First step: interpolated inputs (given and default) and action path; the action is mounted once.
    try std.testing.expect(std.mem.indexOf(u8, seen[3], "echo v=0.21.10 verb=call path=/github/_actions/o/act/v1") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen[3], "withDirectory(path:\"/github/_actions/o/act/v1\",source:\"D1\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen[3], "/github/file_commands/output_3") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen[4], "withDirectory") == null);
    try std.testing.expect(std.mem.indexOf(u8, seen[4], "'X=0.21.10'") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen[4], "'GITHUB_ACTION_PATH=/github/_actions/o/act/v1'") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen[4], "/github/file_commands/output_4") != null);
    // The action's output, built from its own step's output and input, reaches the next job step.
    try std.testing.expect(std.mem.indexOf(u8, seen[5], "echo ok-0.21.10") != null);
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "Warning: Unexpected input(s) 'bogus', valid inputs are ['version', 'verb']") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "##[group]Run echo v=0.21.10") != null);
}

test "action failures: an image that cannot be pulled, a missing action.yml, and a failing step with failure() cleanup" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);

    const failing_yml =
        \\runs:
        \\  using: composite
        \\  steps:
        \\    - shell: bash
        \\      run: exit 3
        \\    - if: failure()
        \\      shell: bash
        \\      run: echo cleanup
        \\    - shell: bash
        \\      run: echo not after a failure
    ;
    var s2 = usesStep("missing", "o", "none", "v1", &.{});
    s2.condition = "always()";
    var s3 = usesStep("fails", "o", "act2", "0123456789012345678901234567890123456789", &.{});
    s3.condition = "always()";
    const steps = [_]job_mod.Step{ usesStep("dock", "o", "dock", "v1", &.{}), s2, s3 };
    const answers = [_][]const u8{
        base_answer,
        try treeAnswer(arena, "D1", &.{"action.yml"}),
        try fileAnswer(arena, "runs:\n  using: docker\n  image: docker://nope:1\n"),
        try treeAnswer(arena, "D2", &.{"README.md"}),
        try treeAnswer(arena, "D3", &.{"action.yaml"}),
        try fileAnswer(arena, failing_yml),
        "{\"data\":{\"bb\":{\"from\":{\"file\":{\"id\":\"BB\"}}},\"empty\":{\"id\":\"EMPTY\"}}}",
        "{\"errors\":[{\"message\":\"pull access denied for nope\"}]}",
        try exec(arena, "C1", 3, ""),
        try exec(arena, "C2", 0, ""),
    };
    var fake: FakeSession = .{ .answers = &answers, .arena = arena };
    var buf: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    const res = try run(arena, std.testing.io, &env, .{ .test_session_argv = &.{ "sh", "-c", fake_child }, .test_transport = fake.transport() }, testJob(&steps), &log);

    try std.testing.expect(!res.succeeded);
    try std.testing.expectEqual(Outcome.failure, res.steps[0].outcome);
    try std.testing.expectEqual(Outcome.failure, res.steps[1].outcome);
    try std.testing.expectEqual(Outcome.failure, res.steps[2].outcome);
    try std.testing.expectEqual(@as(i32, 3), res.steps[2].exit_code);
    const seen = fake.seen.items;
    try std.testing.expectEqual(@as(usize, 10), seen.len); // the step after the failure is skipped
    try std.testing.expect(std.mem.indexOf(u8, seen[4], "commit(id:\"0123456789012345678901234567890123456789\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen[5], "file(path:\"action.yaml\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen[9], "echo cleanup") != null);
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "could not pull nope:1 for o/dock@v1: pull access denied for nope") != null);
    // As GitHub's runner logs a script that exits non-zero.
    try std.testing.expect(std.mem.indexOf(u8, out, "##[error]Process completed with exit code 3.") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "o/none@v1 has no action.yml or action.yaml") != null);
}

test "a replay logs what the live run logged: one stream, in order, blank lines and masks too" {
    // The step's output as its script wrote it, stdout and stderr in one stream
    // (`stream_prologue`): a stderr line before the mask, a blank line, the secret after it, a
    // stopped command, a line without a trailing newline before the end marker, and marker text
    // of the step's own.
    const body = [_][]const u8{
        "out: starting",
        "err: password hunter2 leaked early",
        "",
        "::add-mask::hunter2",
        "err: hunter2 again",
        "",
        "::stop-commands::tok",
        "::group::not a group",
        "::tok::",
        marker ++ "end 1 another-jobs-secret",
        marker ++ "begin 2",
    };
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const ar = a.allocator();

    const logOf = struct {
        fn f(arena: Allocator, mark: []const u8, comptime replay: bool, lines: []const []const u8, tail: []const u8) ![]const u8 {
            var aw: std.Io.Writer.Allocating = .init(arena);
            var log: sink.LogSink = .{ .stdout = .{ .writer = &aw.writer } };
            var live = [_]std.atomic.Value(u32){ .init(0), .init(0) };
            var ended = [_]std.atomic.Value(bool){ .init(false), .init(false) };
            var replayed = [_]bool{ false, false };
            var cmds = [_]Shared.StepCommands{ .{}, .{} };
            var line_counts = [_]u32{ 0, 0, 0 };
            var sh: Shared = .{ .io = std.testing.io, .arena = arena, .log = &log, .sink_job_id = 0, .live_lines = &live, .ended = &ended, .replayed_steps = &replayed, .commands = &cmds, .line_counts = &line_counts, .mark = "this-job" };
            const begin = try std.fmt.allocPrint(arena, marker ++ "begin 1 {s}", .{mark});
            const end = try std.fmt.allocPrint(arena, "{s}" ++ marker ++ "end 1 {s}", .{ tail, mark });
            if (replay) {
                // The exec's recorded stdout, from an earlier job (another secret).
                var rec: std.ArrayList(u8) = .empty;
                try rec.appendSlice(arena, begin);
                try rec.append(arena, '\n');
                for (lines) |l| {
                    try rec.appendSlice(arena, l);
                    try rec.append(arena, '\n');
                }
                try rec.appendSlice(arena, end);
                try rec.append(arena, '\n');
                try std.testing.expect(awaitLiveOrReplay(std.testing.io, &sh, 1, rec.items, "", false));
            } else {
                var sd: SpanDemux = .{ .sh = &sh, .gpa = std.testing.allocator };
                defer sd.deinit();
                var span: SpanDemux.Span = .{};
                sd.line(&span, begin);
                for (lines) |l| sd.line(&span, l);
                sd.line(&span, end);
                try std.testing.expect(ended[0].load(.acquire));
            }
            try log.flush();
            return aw.written();
        }
    }.f;
    const live_log = try logOf(ar, "this-job", false, &body, "no newline");
    const replay_log = try logOf(ar, "earlier-job", true, &body, "no newline");
    try std.testing.expectEqualStrings(live_log, replay_log);
    // And what that log is: masked from the mask on, blank lines kept, commands stopped.
    try std.testing.expectEqualStrings(
        "[job 0 step 1 stdout] out: starting\n" ++
            "[job 0 step 1 stdout] err: password hunter2 leaked early\n" ++
            "[job 0 step 1 stdout] \n" ++
            "[job 0 step 1 stdout] err: *** again\n" ++
            "[job 0 step 1 stdout] \n" ++
            "[job 0 step 1 stdout] ::group::not a group\n" ++
            "[job 0 step 1 stdout] " ++ marker ++ "end 1 another-jobs-secret\n" ++
            "[job 0 step 1 stdout] " ++ marker ++ "begin 2\n" ++
            "[job 0 step 1 stdout] no newline\n",
        live_log,
    );
}

test "a local action is read from the workspace when its step runs, and is not mounted" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);
    const action_yml =
        \\inputs:
        \\  who:
        \\    default: nobody
        \\runs:
        \\  using: composite
        \\  steps:
        \\    - shell: bash
        \\      run: echo "hi ${{ inputs.who }} from $GITHUB_ACTION_PATH (${{ github.action_repository }})"
    ;
    const inputs = [_]job_mod.Input{.{ .name = "who", .value = .{ .lit = "you" } }};
    var greet = usesStep("greet", "", "", "", &inputs);
    greet.action.uses.path = ".github/actions/greet";
    greet.action.uses.local = true;
    var missing = usesStep("missing", "", "", "", &.{});
    missing.action.uses.path = "nope";
    missing.action.uses.local = true;
    missing.condition = "always()";
    const steps = [_]job_mod.Step{ testStep("echo checkout"), greet, missing };
    const answers = [_][]const u8{
        base_answer,
        try exec(arena, "C1", 0, ""),
        "{\"data\":{\"loadContainerFromID\":{\"directory\":{\"id\":\"LD\",\"entries\":[\"action.yml\"]}}}}",
        try fileAnswer(arena, action_yml),
        try exec(arena, "C2", 0, ""),
        "{\"errors\":[{\"message\":\"lstat /home/runner/work/r/r/nope: no such file or directory\"}]}",
    };
    var fake: FakeSession = .{ .answers = &answers, .arena = arena };
    var buf: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    const res = try run(arena, std.testing.io, &env, .{ .test_session_argv = &.{ "sh", "-c", fake_child }, .test_transport = fake.transport() }, testJob(&steps), &log);
    const seen = fake.seen.items;
    try std.testing.expectEqual(@as(usize, 6), seen.len);
    for (seen) |d| try std.testing.expect(braceBalanced(d));
    // Read after the earlier step, from the container that step left; nothing is fetched up front.
    try std.testing.expect(std.mem.indexOf(u8, seen[2], "loadContainerFromID(id:\"C1\") { directory(path:\"/home/runner/work/r/r/.github/actions/greet\") { id entries } }") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen[3], "loadDirectoryFromID(id:\"LD\") { file(path:\"action.yml\")") != null);
    const run1 = seen[4];
    try std.testing.expect(std.mem.indexOf(u8, run1, "withDirectory") == null);
    try std.testing.expect(std.mem.indexOf(u8, run1, "hi you from $GITHUB_ACTION_PATH ()") != null);
    try std.testing.expect(std.mem.indexOf(u8, run1, "'GITHUB_ACTION_PATH=/home/runner/work/r/r/.github/actions/greet'") != null);
    try std.testing.expect(std.mem.indexOf(u8, run1, "'GITHUB_ACTION_REPOSITORY='") != null);
    try std.testing.expectEqual(Outcome.success, res.steps[1].outcome);
    try std.testing.expectEqual(Outcome.failure, res.steps[2].outcome);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "Can't find 'action.yml' or 'action.yaml' under '/home/runner/work/r/r/nope'. Did you forget to run actions/checkout") != null);
}

test "a composite action's uses: steps: nested actions, the built-in checkout, outputs, and the nesting limit" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);
    const outer_yml =
        \\inputs:
        \\  who:
        \\    default: nobody
        \\outputs:
        \\  greeting:
        \\    value: ${{ steps.inner.outputs.greeting }}
        \\runs:
        \\  using: composite
        \\  steps:
        \\    - id: inner
        \\      uses: o/inner@v1
        \\      with:
        \\        name: ${{ inputs.who }}
        \\    - uses: actions/checkout@v4
        \\      with:
        \\        path: sub
        \\    - shell: bash
        \\      run: echo "inner said ${{ steps.inner.outputs.greeting }}"
    ;
    const inner_yml =
        \\inputs:
        \\  name:
        \\    required: true
        \\outputs:
        \\  greeting:
        \\    value: ${{ steps.g.outputs.text }}
        \\runs:
        \\  using: composite
        \\  steps:
        \\    - id: g
        \\      shell: bash
        \\      run: echo "text=hello ${{ inputs.name }}" >> "$GITHUB_OUTPUT"
    ;
    const inputs = [_]job_mod.Input{.{ .name = "who", .value = .{ .lit = "zig" } }};
    var after = testStep("");
    after.action.script.script = .{ .expr = "format('echo {0}', steps.outer.outputs.greeting)" };
    const steps = [_]job_mod.Step{ usesStep("outer", "o", "outer", "v1", &inputs), after };
    const answers = [_][]const u8{
        base_answer,
        try treeAnswer(arena, "D1", &.{"action.yml"}),
        try fileAnswer(arena, outer_yml),
        // the nested action, loaded when its step runs
        try treeAnswer(arena, "D2", &.{"action.yml"}),
        try fileAnswer(arena, inner_yml),
        "{\"data\":{\"loadContainerFromID\":{\"withExec\":{\"id\":\"C1\",\"exitCode\":0,\"stdout\":\"\",\"stderr\":\"\",\"fc_output\":{\"contents\":\"text=hello zig\\n\"}}}}}",
        // the checkout
        "{\"data\":{\"git\":{\"commit\":{\"tree\":{\"id\":\"TREE1\"}}}}}",
        try exec(arena, "C2", 0, ""),
        try exec(arena, "C3", 0, ""),
        try exec(arena, "C4", 0, ""),
    };
    var fake: FakeSession = .{ .answers = &answers, .arena = arena };
    var buf: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    const res = try run(arena, std.testing.io, &env, .{ .test_session_argv = &.{ "sh", "-c", fake_child }, .test_transport = fake.transport() }, testJob(&steps), &log);
    try std.testing.expect(res.succeeded);
    const seen = fake.seen.items;
    try std.testing.expectEqual(@as(usize, 10), seen.len);
    for (seen) |d| try std.testing.expect(braceBalanced(d));
    try std.testing.expect(std.mem.indexOf(u8, seen[3], "git(url:\"https://github.com/o/inner.git\")") != null);
    // The nested action gets the outer action's input, and its own directory.
    try std.testing.expect(std.mem.indexOf(u8, seen[5], "withDirectory(path:\"/github/_actions/o/inner/v1\",source:\"D2\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen[5], "echo \\\"text=hello zig\\\"") != null);
    // actions/checkout is the built-in checkout, at its path.
    try std.testing.expect(std.mem.indexOf(u8, seen[7], "withDirectory(path:\"/home/runner/work/r/r/sub\",source:\"TREE1\")") != null);
    // Its outputs reach the outer action's steps and outputs, and the job's next step.
    try std.testing.expect(std.mem.indexOf(u8, seen[8], "inner said hello zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen[9], "echo hello zig") != null);

    // An action that uses itself stops at GitHub's limit of 9 levels; it is fetched once.
    const loop_yml = "runs:\n  using: composite\n  steps:\n    - uses: o/loop@v1\n";
    const loop_answers = [_][]const u8{
        base_answer,
        try treeAnswer(arena, "DL", &.{"action.yml"}),
        try fileAnswer(arena, loop_yml),
    };
    const loop_steps = [_]job_mod.Step{usesStep("loop", "o", "loop", "v1", &.{})};
    var fake2: FakeSession = .{ .answers = &loop_answers, .arena = arena };
    var buf2: [8192]u8 = undefined;
    var w2: std.Io.Writer = .fixed(&buf2);
    var log2: sink.LogSink = .{ .stdout = .{ .writer = &w2 } };
    const res2 = try run(arena, std.testing.io, &env, .{ .test_session_argv = &.{ "sh", "-c", fake_child }, .test_transport = fake2.transport() }, testJob(&loop_steps), &log2);
    try std.testing.expect(!res2.succeeded);
    try std.testing.expectEqual(@as(usize, 3), fake2.seen.items.len);
    try std.testing.expect(std.mem.indexOf(u8, w2.buffered(), "o/loop@v1: composite actions can be nested at most 9 levels deep") != null);
}

test "steps see the name the runner registered under" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);
    var st = testStep("");
    st.action.script.script = .{ .expr = "format('echo {0}', runner.name)" };
    const steps = [_]job_mod.Step{st};
    const answers = [_][]const u8{ base_answer, try exec(arena, "C1", 0, "") };
    var fake: FakeSession = .{ .answers = &answers, .arena = arena };
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    _ = try run(arena, std.testing.io, &env, .{ .runner_name = "zig-1a2b3c4d", .test_session_argv = &.{ "sh", "-c", fake_child }, .test_transport = fake.transport() }, testJob(&steps), &log);
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[0], "withEnvVariable(name:\"RUNNER_NAME\",value:\"zig-1a2b3c4d\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[1], "echo zig-1a2b3c4d") != null);
}

test "the workspace is where GitHub's runner puts it, /__w in a container job" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var job = testJob(&.{});
    job.github.repository = "Lementknight/zig-actions-runner";
    try std.testing.expectEqualStrings("/home/runner/work/zig-actions-runner/zig-actions-runner", try jobWorkspace(arena, job));
    try std.testing.expectEqualStrings("/home/runner/work/_temp", try jobTemp(arena, job));
    job.container = .{ .name = "", .image = .{ .lit = "golang:1.26" } };
    try std.testing.expectEqualStrings("/__w/zig-actions-runner/zig-actions-runner", try jobWorkspace(arena, job));
    try std.testing.expectEqualStrings("/__w/_temp", try jobTemp(arena, job));
}

test "an action that cannot be resolved: GitHub's message" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const u: job_mod.Uses = .{ .owner = "astral-sh", .name = "setup-uv", .ref = "v10" };
    try std.testing.expectEqualStrings("Unable to resolve action `astral-sh/setup-uv@v10`, unable to find version `v10`", try unresolvedMessage(arena, u, "git error: repository does not contain ref \"v10\"", false));
    const missing: job_mod.Uses = .{ .owner = "Lementknight", .name = "No-Such", .ref = "v1" };
    try std.testing.expectEqualStrings("Unable to resolve action lementknight/no-such, repository not found (or private: the job's GITHUB_TOKEN reads only the job's own repository)", try unresolvedMessage(arena, missing, "git error: git authentication failed", false));
    try std.testing.expectEqualStrings("Unable to resolve action lementknight/no-such, repository not found", try unresolvedMessage(arena, missing, "git error: git authentication failed", true));
    try std.testing.expectEqualStrings("Unable to resolve action `astral-sh/setup-uv@v10`, dial tcp: i/o timeout", try unresolvedMessage(arena, u, "dial tcp: i/o timeout", false));
}

test "an action that cannot be resolved fails Set up job, and no step runs" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);
    // The second action's step would be skipped; GitHub resolves it anyway.
    var skipped = usesStep("gone", "Someone", "Gone", "v1", &.{});
    skipped.condition = "failure()";
    const steps = [_]job_mod.Step{ testStep("echo before"), usesStep("uv", "astral-sh", "setup-uv", "v10", &.{}), skipped };
    const job = testJob(&steps);
    const answers = [_][]const u8{
        base_answer,
        "{\"errors\":[{\"message\":\"git error: repository does not contain ref \\\"v10\\\"\"}]}",
        "{\"errors\":[{\"message\":\"git error: git authentication failed\"}]}",
    };
    var fake: FakeSession = .{ .answers = &answers, .arena = arena };
    var buf: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    const res = try run(arena, std.testing.io, &env, .{ .test_session_argv = &.{ "sh", "-c", fake_child }, .test_transport = fake.transport() }, job, &log);
    try std.testing.expect(!res.succeeded and res.set_up_failed);
    try std.testing.expect(res.engine_error == null);
    for (res.steps) |r| try std.testing.expectEqual(Outcome.not_run, r.outcome);
    // Nothing ran: the base container and the two fetches were the only queries.
    try std.testing.expectEqual(@as(usize, 3), fake.seen.items.len);
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "[job 0 step 0 stdout] ##[error]Unable to resolve action `astral-sh/setup-uv@v10`, unable to find version `v10`. Unable to resolve action someone/gone, repository not found") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Complete job name") == null);
    try std.testing.expectEqual(@as(usize, 1), res.annotations.len);
}

test "logs read like GitHub's: Set up job, then each step's header with its shell, env or inputs" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);
    var run_step = testStep("echo one\necho two");
    run_step.env = &.{
        .{ .name = "GREETING", .value = .{ .lit = "hi" } },
        .{ .name = "TOKEN", .value = .{ .lit = "s3cr3t-value" } },
    };
    var co = testStep("x");
    co.action = .{ .checkout = &.{.{ .name = "fetch-depth", .value = .{ .lit = "0" } }} };
    co.uses = "actions/checkout@v4";
    const action_yml = "runs:\n  using: composite\n  steps:\n    - shell: sh\n      run: echo from-the-action\n";
    const steps = [_]job_mod.Step{ co, usesStep("act", "o", "act", "v1", &.{}), run_step };
    var job = testJob(&steps);
    job.secrets = &.{"s3cr3t-value"};
    job.display_name = "build (linux)";
    job.runner_group = "Default";
    job.token_permissions = "{\"Contents\":\"read\",\"PullRequests\":\"write\"}";
    job.env = &.{.{ .name = "FROM_JOB", .value = .{ .lit = "j" } }};
    const answers = [_][]const u8{
        base_answer,
        "{\"data\":{\"git\":{\"ref\":{\"tree\":{\"id\":\"D1\",\"entries\":[\"action.yml\"]},\"sha\":\"0123456789abcdef0123456789abcdef01234567\"}}}}",
        try fileAnswer(arena, action_yml),
        "{\"data\":{\"git\":{\"commit\":{\"tree\":{\"id\":\"TREE1\"}}}}}",
        try exec(arena, "C1", 0, ""),
        try exec(arena, "C2", 0, ""),
        "{\"data\":{\"zsec0\":{\"id\":\"SEC\"}}}",
        try exec(arena, "C3", 0, ""),
    };
    var fake: FakeSession = .{ .answers = &answers, .arena = arena };
    var buf: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w, .secrets = &.{"s3cr3t-value"} } };
    const res = try run(arena, std.testing.io, &env, .{ .runner_name = "zig-1a2b3c4d", .test_session_argv = &.{ "sh", "-c", fake_child }, .test_transport = fake.transport() }, job, &log);
    try std.testing.expect(res.succeeded);
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[1], "tree(depth:1) { id entries(path:\".\") } sha: commit") != null);
    const out = w.buffered();
    const want_in_order = [_][]const u8{
        // GitHub's protocol version, then this build's own, which is the line a job's log is read
        // for when a machine is behaving unexpectedly.
        "[job 0 step 0 stdout] Current runner version: '" ++ broker.version ++ "' (zig-runner " ++ build_version.string ++ ")",
        "[job 0 step 0 stdout] Runner name: 'zig-1a2b3c4d'",
        "[job 0 step 0 stdout] Runner group name: 'Default'",
        "[job 0 step 0 stdout] ##[group]Runner Image",
        "[job 0 step 0 stdout] Image: ubuntu:24.04",
        "[job 0 step 0 stdout] ##[group]GITHUB_TOKEN Permissions",
        "[job 0 step 0 stdout] Contents: read",
        "[job 0 step 0 stdout] PullRequests: write",
        "[job 0 step 0 stdout] Secret source: Actions",
        "[job 0 step 0 stdout] Prepare workflow directory",
        "[job 0 step 0 stdout] Prepare all required actions",
        "[job 0 step 0 stdout] Getting action download info",
        "[job 0 step 0 stdout] Download action repository 'o/act@v1' (SHA:0123456789abcdef0123456789abcdef01234567)",
        "[job 0 step 0 stdout] Complete job name: build (linux)",
        "[job 0 step 1 stdout] ##[group]Run actions/checkout@v4",
        "[job 0 step 1 stdout] with:",
        "[job 0 step 1 stdout]   fetch-depth: 0",
        "[job 0 step 1 stdout] ##[endgroup]",
        "[job 0 step 2 stdout] ##[group]Run echo from-the-action",
        "[job 0 step 2 stdout] shell: /usr/bin/sh -e {0}",
        "[job 0 step 3 stdout] ##[group]Run echo one",
        "[job 0 step 3 stdout] echo one",
        "[job 0 step 3 stdout] echo two",
        "[job 0 step 3 stdout] shell: /usr/bin/bash -e {0}",
        "[job 0 step 3 stdout] env:",
        "[job 0 step 3 stdout]   FROM_JOB: j",
        "[job 0 step 3 stdout]   GREETING: hi",
        "[job 0 step 3 stdout]   TOKEN: ***",
        "[job 0 step 3 stdout] ##[endgroup]",
    };
    var at: usize = 0;
    for (want_in_order) |want| {
        const i = std.mem.indexOfPos(u8, out, at, want) orelse {
            std.debug.print("missing (in order): {s}\nlog:\n{s}\n", .{ want, out });
            return error.TestUnexpectedResult;
        };
        at = i + want.len;
    }
    // The default shell is GitHub's `bash -e` (no pipefail); an explicit `sh` stays `sh -e`.
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[7], "printf '%s' 'echo one\\necho two' > /tmp/zig-runner-step-3.sh") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[7], "\\\"$zig_shell\\\" '-e' '/tmp/zig-runner-step-3.sh'") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[5], "'sh' '-e' '/tmp/zig-runner-step-") != null);
}

test "masks a step sets, and the job's secrets, keep a job output and a step's name from leaving unmasked" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);
    // The step's name names a secret; the step masks an OIDC-style token and outputs it (#96).
    var st = testStep("mint");
    st.context_name = "m";
    st.name_expr = "format('Deploy with {0}', 'hunter2-secret')";
    const steps = [_]job_mod.Step{st};
    var job = testJob(&steps);
    job.secrets = &.{"hunter2-secret"};
    job.outputs = &.{
        .{ .name = "token", .value = .{ .expr = "steps.m.outputs.token" } },
        .{ .name = "fine", .value = .{ .lit = "ok" } },
    };
    const answers = [_][]const u8{
        base_answer,
        "{\"data\":{\"loadContainerFromID\":{\"withExec\":{\"id\":\"C1\",\"exitCode\":0,\"stdout\":\"::add-mask::minted-token-123\\n\",\"stderr\":\"\",\"fc_output\":{\"contents\":\"token=minted-token-123\\n\"}}}}}",
    };
    var fake: FakeSession = .{ .answers = &answers, .arena = arena };
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    // As loop.zig sets the job's secrets before its steps run.
    log.setSecrets(try redact.expand(arena, job.secrets));
    const res = try run(arena, std.testing.io, &env, .{ .test_session_argv = &.{ "sh", "-c", fake_child }, .test_transport = fake.transport() }, job, &log);
    try std.testing.expect(res.succeeded);
    try std.testing.expectEqualStrings("Deploy with ***", res.steps[0].name);
    try std.testing.expectEqual(@as(usize, 1), res.outputs.len);
    try std.testing.expectEqualStrings("fine", res.outputs[0].name);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "minted-token-123") == null);
}

test "job outputs are evaluated after the steps; one carrying a secret is skipped" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);
    var st = testStep("echo version=1.2.3 >> $GITHUB_OUTPUT");
    st.context_name = "v";
    const steps = [_]job_mod.Step{st};
    var job = testJob(&steps);
    job.secrets = &.{"s3cr3t-value"};
    job.outputs = &.{
        .{ .name = "version", .value = .{ .expr = "steps.v.outputs.version" } },
        .{ .name = "literal", .value = .{ .lit = "fixed" } },
        .{ .name = "combined", .value = .{ .expr = "format('v={0}', steps.v.outputs.version)" } },
        .{ .name = "leak", .value = .{ .lit = "token s3cr3t-value" } },
    };
    const answers = [_][]const u8{
        base_answer,
        "{\"data\":{\"loadContainerFromID\":{\"withExec\":{\"id\":\"C1\",\"exitCode\":0,\"stdout\":\"\",\"stderr\":\"\",\"fc_output\":{\"contents\":\"version=1.2.3\\n\"}}}}}",
    };
    var fake: FakeSession = .{ .answers = &answers, .arena = arena };
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    const res = try run(arena, std.testing.io, &env, .{ .test_session_argv = &.{ "sh", "-c", fake_child }, .test_transport = fake.transport() }, job, &log);
    try std.testing.expect(res.succeeded);
    try std.testing.expectEqual(@as(usize, 3), res.outputs.len);
    try std.testing.expectEqualStrings("version", res.outputs[0].name);
    try std.testing.expectEqualStrings("1.2.3", res.outputs[0].value);
    try std.testing.expectEqualStrings("fixed", res.outputs[1].value);
    try std.testing.expectEqualStrings("v=1.2.3", res.outputs[2].value);
    const want = [_][]const u8{ "Evaluate and set job outputs", "Set output 'version'", "Set output 'literal'", "Set output 'combined'", "##[warning]Skip output 'leak' since it may contain secret." };
    try std.testing.expectEqual(want.len, res.output_lines.len);
    for (want, res.output_lines) |wnt, got| try std.testing.expectEqualStrings(wnt, got);
}

test "steps get the engine (privileged nesting) unless it is turned off" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);
    const steps = [_]job_mod.Step{testStep("dagger call ci")};
    for ([_]bool{ true, false }) |nesting| {
        const answers = [_][]const u8{ base_answer, try exec(arena, "C1", 0, "") };
        var fake: FakeSession = .{ .answers = &answers, .arena = arena };
        var buf: [1024]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
        _ = try run(arena, std.testing.io, &env, .{ .nesting = nesting, .test_session_argv = &.{ "sh", "-c", fake_child }, .test_transport = fake.transport() }, testJob(&steps), &log);
        // The setup query (and its provisioning exec) never gets it; the step does when enabled.
        try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[0], "experimentalPrivilegedNesting") == null);
        try std.testing.expectEqual(nesting, std.mem.indexOf(u8, fake.seen.items[1], ",expect:ANY,experimentalPrivilegedNesting:true)") != null);
        try std.testing.expect(braceBalanced(fake.seen.items[1]));
    }
}

test "workflow commands in a step's output: masks, groups, annotations, debug, set-output, stop-commands" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);
    var after = testStep("");
    after.action.script.script = .{ .expr = "format('echo got={0}', steps.cmds.outputs.legacy)" };
    var first = testStep("x");
    first.context_name = "cmds";
    const steps = [_]job_mod.Step{ first, after };
    const out1 =
        "before s3cr3t-token\\n::add-mask::s3cr3t-token\\nafter s3cr3t-token\\n" ++
        "::group::Install%25\\ninside\\n::endgroup::\\n" ++
        "::error file=a.js,line=1::bad%0Asecond line\\n::warning::careful\\n::debug::hidden\\n" ++
        "::set-output name=legacy::42\\n::set-env name=X::1\\n" ++
        "::stop-commands::tok\\n::group::not a group\\n::add-mask::not-masked\\n::tok::\\n::notice::back\\n";
    const answers = [_][]const u8{ base_answer, try exec(arena, "C1", 0, out1), try exec(arena, "C2", 0, "s3cr3t-token in step 2\\n") };
    var fake: FakeSession = .{ .answers = &answers, .arena = arena };
    var buf: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    const res = try run(arena, std.testing.io, &env, .{ .test_session_argv = &.{ "sh", "-c", fake_child }, .test_transport = fake.transport() }, testJob(&steps), &log);
    try std.testing.expect(res.succeeded);
    const want =
        \\[job 0 step 1 stdout] before s3cr3t-token
        \\[job 0 step 1 stdout] after ***
        \\[job 0 step 1 stdout] ##[group]Install%
        \\[job 0 step 1 stdout] inside
        \\[job 0 step 1 stdout] ##[endgroup]
        \\[job 0 step 1 stdout] ##[error]bad
        \\[job 0 step 1 stdout] second line
        \\[job 0 step 1 stdout] ##[warning]careful
        \\[job 0 step 1 stdout] ##[error]The `set-env` command is disabled.
    ;
    const got = w.buffered();
    var it = std.mem.splitScalar(u8, want, '\n');
    var pos: usize = 0;
    while (it.next()) |line| {
        const i = std.mem.indexOfPos(u8, got, pos, line) orelse {
            std.debug.print("missing, in order: {s}\n--- log:\n{s}\n", .{ line, got });
            return error.TestUnexpectedResult;
        };
        pos = i + line.len;
    }
    // Lines that must not be logged: the mask command, debug (ACTIONS_STEP_DEBUG is off), stop/resume.
    for ([_][]const u8{ "add-mask::s3cr3t", "hidden", "::stop-commands", "::tok::", "::set-output" }) |no| try std.testing.expect(std.mem.indexOf(u8, got, no) == null);
    // While stopped, commands are plain text; afterwards they work again.
    try std.testing.expect(std.mem.indexOf(u8, got, "] ::group::not a group") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "] ::add-mask::not-masked") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "##[notice]back") != null);
    // The mask holds for later steps, and set-output reached steps.<id>.outputs.
    try std.testing.expect(std.mem.indexOf(u8, got, "[job 0 step 2 stdout] *** in step 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[2], "echo got=42") != null);
    // Annotations for completejob: the error points to its file; the others, to their line in the
    // step's log.
    try std.testing.expectEqual(@as(usize, 4), res.annotations.len);
    const err = res.annotations[0];
    try std.testing.expectEqual(@as(u32, 1), err.step);
    try std.testing.expectEqualStrings("a.js", err.an.file.?);
    try std.testing.expectEqualStrings("1", err.an.line.?);
    try std.testing.expectEqualStrings("bad\nsecond line", err.an.message);
    var n: u32 = 0;
    var lines = std.mem.splitScalar(u8, got, '\n');
    while (lines.next()) |l| {
        if (!std.mem.startsWith(u8, l, "[job 0 step 1 stdout] ")) continue;
        n += 1;
        if (std.mem.endsWith(u8, l, "##[warning]careful")) break;
    }
    try std.testing.expectEqualStrings("warning", res.annotations[1].an.level);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(arena, "{d}", .{n}), res.annotations[1].an.line.?);
    try std.testing.expect(std.mem.startsWith(u8, res.annotations[2].an.message, "The `set-env` command is disabled."));
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(arena, "{d}", .{n + 1}), res.annotations[2].an.line.?);
    try std.testing.expectEqualStrings("notice", res.annotations[3].an.level);
}

test "ACTIONS_STEP_DEBUG shows ::debug:: lines" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);
    const steps = [_]job_mod.Step{testStep("x")};
    var job = testJob(&steps);
    job.secret_vars = &.{.{ .name = "ACTIONS_STEP_DEBUG", .value = "true" }};
    const answers = [_][]const u8{ base_answer, try exec(arena, "C1", 0, "::debug::shown%0Anow\\n") };
    var fake: FakeSession = .{ .answers = &answers, .arena = arena };
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    _ = try run(arena, std.testing.io, &env, .{ .test_session_argv = &.{ "sh", "-c", fake_child }, .test_transport = fake.transport() }, job, &log);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "##[debug]shown\nnow") != null);
}

test "what a step writes to GITHUB_STEP_SUMMARY is kept for upload" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);
    const steps = [_]job_mod.Step{ testStep("x"), testStep("y") };
    const with_summary = "{\"data\":{\"loadContainerFromID\":{\"withExec\":{\"id\":\"C1\",\"exitCode\":0,\"stdout\":\"\",\"stderr\":\"\",\"fc_step_summary\":{\"contents\":\"# Results\\n| a | b |\\n\"}}}}}";
    const answers = [_][]const u8{ base_answer, with_summary, try exec(arena, "C2", 0, "") };
    var fake: FakeSession = .{ .answers = &answers, .arena = arena };
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    const res = try run(arena, std.testing.io, &env, .{ .test_session_argv = &.{ "sh", "-c", fake_child }, .test_transport = fake.transport() }, testJob(&steps), &log);
    try std.testing.expectEqualStrings("# Results\n| a | b |\n", res.summaries[0]);
    try std.testing.expectEqualStrings("", res.summaries[1]);
    // The query reads the file back.
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[1], "fc_all: file(path:") != null);
}

test "uv's environment goes in its cache, with a .venv symlink to it" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    // Keyed by the ref, with anything else in a path turned into a dash.
    try std.testing.expectEqualStrings("/home/runner/.cache/uv/zig-runner-envs/refs-heads-main", try uvEnvPath(arena, "/home/runner/.cache/uv", "refs/heads/main"));
    try std.testing.expectEqualStrings("/c/zig-runner-envs/refs-pull-7-merge", try uvEnvPath(arena, "/c", "refs/pull/7/merge"));
    try std.testing.expectEqualStrings("/c/zig-runner-envs/default", try uvEnvPath(arena, "/c", ""));

    var env: std.process.Environ.Map = .init(arena);
    const steps = [_]job_mod.Step{testStep("uv sync")};
    var job = testJob(&steps);
    job.github.ref = "refs/heads/main";
    const vols = "{\"data\":{\"c0\":{\"id\":\"V\"},\"c1\":{\"id\":\"V\"},\"c2\":{\"id\":\"V\"},\"c3\":{\"id\":\"V\"},\"c4\":{\"id\":\"V\"},\"c5\":{\"id\":\"V\"},\"c6\":{\"id\":\"V\"},\"c7\":{\"id\":\"V\"},\"c8\":{\"id\":\"V\"},\"c9\":{\"id\":\"V\"},\"c10\":{\"id\":\"V\"},\"c11\":{\"id\":\"V\"},\"c12\":{\"id\":\"V\"},\"c13\":{\"id\":\"V\"},\"c14\":{\"id\":\"V\"},\"c15\":{\"id\":\"V\"},\"c16\":{\"id\":\"V\"}}}";
    const answers = [_][]const u8{ vols, base_answer, try exec(arena, "C1", 0, "") };
    var fake: FakeSession = .{ .answers = &answers, .arena = arena };
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    const res = try run(arena, std.testing.io, &env, .{ .step_user = .runner, .package_caches = true, .test_session_argv = &.{ "sh", "-c", fake_child }, .test_transport = fake.transport() }, job, &log);
    try std.testing.expect(res.succeeded);
    const base = fake.seen.items[1];
    const path = "/home/runner/.cache/uv/zig-runner-envs/refs-heads-main";
    try std.testing.expect(std.mem.indexOf(u8, base, "withEnvVariable(name:\"UV_PROJECT_ENVIRONMENT\",value:\"" ++ path ++ "\")") != null);
    // `uv venv` would otherwise fail on the second job for a ref, the environment being there already.
    try std.testing.expect(std.mem.indexOf(u8, base, "withEnvVariable(name:\"UV_VENV_CLEAR\",value:\"1\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, base, "ln -sfn " ++ path ++ " /home/runner/work/r/r/.venv") != null);

    // Off: no variable, no link.
    var fake2: FakeSession = .{ .answers = &answers, .arena = arena };
    var w2: std.Io.Writer = .fixed(&buf);
    var log2: sink.LogSink = .{ .stdout = .{ .writer = &w2 } };
    _ = try run(arena, std.testing.io, &env, .{ .step_user = .runner, .package_caches = true, .uv_env_in_cache = false, .test_session_argv = &.{ "sh", "-c", fake_child }, .test_transport = fake2.transport() }, job, &log2);
    try std.testing.expect(std.mem.indexOf(u8, fake2.seen.items[1], "UV_PROJECT_ENVIRONMENT") == null);
    try std.testing.expect(std.mem.indexOf(u8, fake2.seen.items[1], "ln -sfn") == null);

    // With step caching, the environment stays in the workspace, where a replayed `uv sync`
    // restores it with the rest of the container, not in a volume another commit's job synced
    // (#70). uv's own cache is still mounted from its volume.
    var fake3: FakeSession = .{ .answers = &answers, .arena = arena };
    var w3: std.Io.Writer = .fixed(&buf);
    var log3: sink.LogSink = .{ .stdout = .{ .writer = &w3 } };
    const res3 = try run(arena, std.testing.io, &env, .{ .step_user = .runner, .package_caches = true, .step_cache = true, .test_session_argv = &.{ "sh", "-c", fake_child }, .test_transport = fake3.transport() }, job, &log3);
    try std.testing.expect(res3.succeeded);
    const cached = fake3.seen.items[1];
    try std.testing.expect(std.mem.indexOf(u8, cached, "UV_PROJECT_ENVIRONMENT") == null);
    try std.testing.expect(std.mem.indexOf(u8, cached, "UV_VENV_CLEAR") == null);
    try std.testing.expect(std.mem.indexOf(u8, cached, "ln -sfn") == null);
    try std.testing.expect(std.mem.indexOf(u8, cached, "zig-runner-envs") == null);
    try std.testing.expect(std.mem.indexOf(u8, cached, "withMountedCache(path:\"/home/runner/.cache/uv\"") != null);
    // The step's own query does not point uv at the volume either.
    try std.testing.expect(std.mem.indexOf(u8, fake3.seen.items[2], "UV_PROJECT_ENVIRONMENT") == null);
}

test "package caches: one volume per tool, keyed by repository, separate for fork pull requests" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);
    const steps = [_]job_mod.Step{testStep("npm ci")};
    const fork_ctx =
        \\{"github":{"t":2,"d":[{"k":"repository","v":"o/r"},{"k":"event","v":{"t":2,"d":[{"k":"pull_request","v":{"t":2,"d":[{"k":"head","v":{"t":2,"d":[{"k":"repo","v":{"t":2,"d":[{"k":"full_name","v":"someone/r"}]}}]}}]}}]}}]}}
    ;
    for ([_]bool{ false, true }) |fork| {
        var job = testJob(&steps);
        if (fork) job.context_data = try std.json.parseFromSliceLeaky(std.json.Value, arena, fork_ctx, .{});
        var vols: std.Io.Writer.Allocating = .init(arena);
        try vols.writer.writeAll("{\"data\":{");
        for (package_cache_dirs, 0..) |_, i| try vols.writer.print("{s}\"c{d}\":{{\"id\":\"V{d}\"}}", .{ if (i == 0) "" else ",", i, i });
        try vols.writer.writeAll("}}");
        const answers = [_][]const u8{ vols.written(), base_answer, try exec(arena, "C1", 0, "") };
        var fake: FakeSession = .{ .answers = &answers, .arena = arena };
        var buf: [1024]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
        const res = try run(arena, std.testing.io, &env, .{ .package_caches = true, .test_session_argv = &.{ "sh", "-c", fake_child }, .test_transport = fake.transport() }, job, &log);
        try std.testing.expect(res.succeeded);
        const scope = if (fork) "fork-pr" else "repo";
        try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[0], try std.fmt.allocPrint(arena, "c1: cacheVolume(key:\"zig-runner/o/r/{s}/npm\")", .{scope})) != null);
        // The tool cache is also keyed by the job's image (its binaries are built for it).
        try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[0], try std.fmt.allocPrint(arena, "c0: cacheVolume(key:\"zig-runner/o/r/{s}/toolcache/ubuntu:24.04\")", .{scope})) != null);
        try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[0], try std.fmt.allocPrint(arena, "cacheVolume(key:\"zig-runner/o/r/{s}/zig\")", .{scope})) != null);
        // Mounted on the base container, so every step has them.
        try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[1], "withMountedCache(path:\"/opt/hostedtoolcache\",cache:\"V0\")") != null);
        try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[1], "withMountedCache(path:\"/root/.npm\",cache:\"V1\")") != null);
        try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[1], "withMountedCache(path:\"/root/.cache/zig\",cache:\"V11\")") != null);
        // Zig's local cache stays in the workspace unless `zig_local_cache` is on.
        try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[0], "zig-local") == null);
        try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[1], "ZIG_LOCAL_CACHE_DIR") == null);
        // State tools rewrite on every run stays out of the container's filesystem.
        try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[1], "withMountedCache(path:\"/tmp/node-compile-cache\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[1], "withMountedCache(path:\"/root/.config/go/telemetry\"") != null);
        try std.testing.expect(braceBalanced(fake.seen.items[1]));
    }
}

test "with zig_local_cache, Zig's local cache gets a volume of its own, outside the workspace" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);
    const steps = [_]job_mod.Step{testStep("zig build test")};
    const job = testJob(&steps);
    var vols: std.Io.Writer.Allocating = .init(arena);
    try vols.writer.writeAll("{\"data\":{\"czl\":{\"id\":\"VZL\"}");
    for (package_cache_dirs, 0..) |_, i| try vols.writer.print(",\"c{d}\":{{\"id\":\"V{d}\"}}", .{ i, i });
    try vols.writer.writeAll("}}");
    const answers = [_][]const u8{ vols.written(), base_answer, try exec(arena, "C1", 0, "") };
    var fake: FakeSession = .{ .answers = &answers, .arena = arena };
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    const res = try run(arena, std.testing.io, &env, .{
        .package_caches = true,
        .zig_local_cache = true,
        .step_user = .runner,
        .test_session_argv = &.{ "sh", "-c", fake_child },
        .test_transport = fake.transport(),
    }, job, &log);
    try std.testing.expect(res.succeeded);
    const keys = fake.seen.items[0];
    const base = fake.seen.items[1];
    try std.testing.expect(braceBalanced(base));
    // Apart from the global cache's volume, so the engine can collect it alone.
    try std.testing.expect(std.mem.indexOf(u8, keys, "czl: cacheVolume(key:\"zig-runner/o/r/repo/zig-local/runner\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, base, "withEnvVariable(name:\"ZIG_LOCAL_CACHE_DIR\",value:\"/home/runner/.cache/zig-local\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, base, "withMountedCache(path:\"/home/runner/.cache/zig-local\",cache:\"VZL\",owner:\"runner\")") != null);
}

test "steps run as runner in the default image, as on GitHub, with their own package caches" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);
    const steps = [_]job_mod.Step{testStep("go test ./...")};
    const job = testJob(&steps);
    var vols: std.Io.Writer.Allocating = .init(arena);
    try vols.writer.writeAll("{\"data\":{");
    for (package_cache_dirs, 0..) |_, i| try vols.writer.print("{s}\"c{d}\":{{\"id\":\"V{d}\"}}", .{ if (i == 0) "" else ",", i, i });
    try vols.writer.writeAll("}}");
    const answers = [_][]const u8{ vols.written(), base_answer, try exec(arena, "C1", 0, "") };
    var fake: FakeSession = .{ .answers = &answers, .arena = arena };
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    const res = try run(arena, std.testing.io, &env, .{ .package_caches = true, .step_user = .runner, .test_session_argv = &.{ "sh", "-c", fake_child }, .test_transport = fake.transport() }, job, &log);
    try std.testing.expect(res.succeeded);
    const keys = fake.seen.items[0];
    const base = fake.seen.items[1];
    try std.testing.expect(braceBalanced(base));
    // Volumes of their own: root's hold files the user cannot write.
    try std.testing.expect(std.mem.indexOf(u8, keys, "cacheVolume(key:\"zig-runner/o/r/repo/npm/runner\")") != null);
    // Provisioned with the user (uid 1001, passwordless sudo, /github its own), then run as it.
    try std.testing.expect(std.mem.indexOf(u8, base, "useradd -m -u 1001 -s /bin/bash runner") != null);
    try std.testing.expect(std.mem.indexOf(u8, base, "runner ALL=(ALL) NOPASSWD:ALL") != null);
    // The caches' directories exist and are its own before they are mounted (Dagger would make the
    // parents of a mount as root).
    try std.testing.expect(std.mem.indexOf(u8, base, " /home/runner/go/pkg/mod ") != null);
    try std.testing.expect(std.mem.indexOf(u8, base, "chown -R runner:runner /github /home/runner") != null);
    try std.testing.expect(std.mem.indexOf(u8, base, "withUser(name:\"runner\") { withEnvVariable(name:\"HOME\",value:\"/home/runner\")") != null);
    // Caches under its home, owned by it; the tool cache stays where actions look for it.
    try std.testing.expect(std.mem.indexOf(u8, base, "withMountedCache(path:\"/home/runner/go/pkg/mod\",cache:\"V6\",owner:\"runner\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, base, "withMountedCache(path:\"/home/runner/.cache/yarn\",cache:\"V3\",owner:\"runner\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, base, "withMountedCache(path:\"/opt/hostedtoolcache\",cache:\"V0\",owner:\"runner\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, base, "/root/") == null);
}

test "package caches in a container job: variables point the tools at the volumes, the image's own value winning" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);
    const steps = [_]job_mod.Step{testStep("go test ./...")};
    var job = testJob(&steps);
    job.container = .{ .name = "", .image = .{ .lit = "golang:1.25" }, .env = &.{.{ .name = "GOCACHE", .value = .{ .lit = "/tmp/gocache" } }} };
    var vols: std.Io.Writer.Allocating = .init(arena);
    try vols.writer.writeAll("{\"data\":{");
    for (package_cache_dirs, 0..) |_, i| try vols.writer.print("{s}\"c{d}\":{{\"id\":\"V{d}\"}}", .{ if (i == 0) "" else ",", i, i });
    try vols.writer.writeAll("}}");
    // Only the base container matters here: the job stops when the answers run out.
    const answers = [_][]const u8{ vols.written(), base_answer };
    var fake: FakeSession = .{ .answers = &answers, .arena = arena };
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    _ = try run(arena, std.testing.io, &env, .{ .package_caches = true, .test_session_argv = &.{ "sh", "-c", fake_child }, .test_transport = fake.transport() }, job, &log);
    const base = fake.seen.items[1];
    // The golang image's GOPATH is /go, not /root/go: the variable says where the volume is.
    try std.testing.expect(std.mem.indexOf(u8, base, "withEnvVariable(name:\"GOMODCACHE\",value:\"/root/go/pkg/mod\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, base, "withMountedCache(path:\"/root/go/pkg/mod\"") != null);
    // A tool without such a variable gets none.
    try std.testing.expect(std.mem.indexOf(u8, base, "CARGO_HOME") == null);
    // The container's env comes after, so its GOCACHE is the one the steps see.
    const ours = std.mem.indexOf(u8, base, "withEnvVariable(name:\"GOCACHE\",value:\"/root/.cache/go-build\")").?;
    const theirs = std.mem.indexOf(u8, base, "withEnvVariable(name:\"GOCACHE\",value:\"/tmp/gocache\")").?;
    try std.testing.expect(ours < theirs);
    try std.testing.expect(braceBalanced(base));
}

test "step caching: run-specific values are volatile, steps with secrets always run, workflows can opt out" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);
    const ctx_json =
        \\{"github":{"t":2,"d":[{"k":"repository","v":"o/r"},{"k":"sha","v":"abc"},{"k":"run_id","v":"123"},{"k":"run_attempt","v":"2"},
        \\  {"k":"event","v":{"t":2,"d":[{"k":"ref","v":"refs/heads/x"}]}}]}}
    ;
    var with_secret = testStep("deploy");
    with_secret.env = &.{.{ .name = "TOKEN", .value = .{ .lit = "s3cr3t-value" } }};
    const steps = [_]job_mod.Step{ testStep("build"), with_secret };
    for ([_]bool{ false, true }) |opt_out| {
        var job = testJob(&steps);
        job.context_data = try std.json.parseFromSliceLeaky(std.json.Value, arena, ctx_json, .{});
        job.secrets = &.{"s3cr3t-value"};
        if (opt_out) job.env = &.{.{ .name = "ZIG_RUNNER_STEP_CACHE", .value = .{ .lit = "false" } }};
        const answers = [_][]const u8{
            base_answer,
            try exec(arena, "C1", 0, "built\\n"), // no live lines in this fake session: replayed, so "reused"
            "{\"data\":{\"zsec0\":{\"id\":\"SEC\"}}}",
            try exec(arena, "C2", 0, ""),
        };
        var fake: FakeSession = .{ .answers = &answers, .arena = arena };
        var buf: [4096]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
        const res = try run(arena, std.testing.io, &env, .{ .step_cache = true, .runner_name = "zig-pi-1a2b3c4d", .test_ran_marker = "j1", .test_session_argv = &.{ "sh", "-c", fake_child }, .test_transport = fake.transport() }, job, &log);
        try std.testing.expect(res.succeeded);
        const base = fake.seen.items[0];
        const build = fake.seen.items[1];
        const deploy = fake.seen.items[3];
        for (fake.seen.items) |d| try std.testing.expect(braceBalanced(d));
        // The commit is volatile with step caching (a new commit is not by itself a new key); without
        // it, it is an ordinary variable.
        try std.testing.expect(std.mem.indexOf(u8, base, if (opt_out) "withEnvVariable(name:\"GITHUB_SHA\",value:\"abc\")" else "withVolatileVariable(name:\"GITHUB_SHA\",value:\"abc\")") != null);
        if (!opt_out) {
            try std.testing.expect(std.mem.indexOf(u8, base, "withVolatileVariable(name:\"GITHUB_RUN_ID\",value:\"123\")") != null);
            // A pool names every job's runner anew: as an input it would make every key new.
            try std.testing.expect(std.mem.indexOf(u8, base, "withVolatileVariable(name:\"RUNNER_NAME\",value:\"zig-pi-1a2b3c4d\")") != null);
            try std.testing.expect(std.mem.indexOf(u8, base, "withVolatileVariable(name:\"ZIG_RUNNER_EVENT\",value:") != null);
            try std.testing.expect(std.mem.indexOf(u8, base, "withNewFile") == null);
            // A step that always runs writes the event file from the volatile variable; a replayable
            // one writes the withheld payload (#68). Both hide the variable.
            try std.testing.expect(std.mem.indexOf(u8, deploy, "printf '%s' \\\"$ZIG_RUNNER_EVENT\\\" > /github/workflow/event.json") != null);
            try std.testing.expect(std.mem.indexOf(u8, build, "printf '%s' '\\\"zig-runner-withheld\\\"' > /github/workflow/event.json") != null);
            try std.testing.expect(std.mem.indexOf(u8, build, "$ZIG_RUNNER_EVENT") == null);
            try std.testing.expect(std.mem.indexOf(u8, build, "-u ZIG_RUNNER_EVENT ") != null);
            // Only the step with a secret is forced to run, with a value new for every job (a run's
            // matrix jobs share its id).
            try std.testing.expect(std.mem.indexOf(u8, build, "runs this step every time") == null);
            try std.testing.expect(std.mem.indexOf(u8, deploy, ": 'zig-runner runs this step every time: it uses secrets (run 123.2, job j1)'") != null);
        } else {
            try std.testing.expect(std.mem.indexOf(u8, base, "withEnvVariable(name:\"GITHUB_RUN_ID\",value:\"123\")") != null);
            try std.testing.expect(std.mem.indexOf(u8, base, "withNewFile(path:\"/github/workflow/event.json\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, base, "withVolatileVariable") == null);
            try std.testing.expect(std.mem.indexOf(u8, deploy, "runs this step every time") == null);
        }
        const got = w.buffered();
        try std.testing.expect(std.mem.indexOf(u8, got, "[job 0 step 1 stdout] built") != null);
        if (opt_out) {
            // Without step caching nothing is replayed from an earlier job: the output is the step's
            // own, though no line of it streamed.
            try std.testing.expect(std.mem.indexOf(u8, got, "Reused from Dagger's cache") == null);
        } else {
            // The note follows the replayed output, at the end of the job.
            const note = std.mem.indexOf(u8, got, "[job 0 step 1 stdout] Reused from Dagger's cache") orelse return error.TestUnexpectedResult;
            try std.testing.expect(std.mem.indexOf(u8, got, "[job 0 step 1 stdout] built").? < note);
        }
    }
}

test "with id-token: write, every step can request OIDC tokens, and so always runs" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);
    const steps = [_]job_mod.Step{ testStep("one"), testStep("two") };
    for ([_]bool{ true, false }) |granted| {
        var job = testJob(&steps);
        job.secrets = &.{"ghs_jobtoken"};
        job.job_token = "ghs_jobtoken";
        if (granted) job.runtime.id_token_url = "https://token.test/idtoken?api-version=2.0";
        const answers = [_][]const u8{
            base_answer,
            "{\"data\":{\"zsec0\":{\"id\":\"SEC_ID\"}}}", // registered once for the job
            try exec(arena, "C1", 0, ""),
            try exec(arena, "C2", 0, ""),
        };
        var fake: FakeSession = .{ .answers = if (granted) &answers else &.{ answers[0], answers[2], answers[3] }, .arena = arena };
        var buf: [4096]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
        const res = try run(arena, std.testing.io, &env, .{ .step_cache = true, .test_session_argv = &.{ "sh", "-c", fake_child }, .test_transport = fake.transport() }, job, &log);
        try std.testing.expect(res.succeeded);
        const seen = fake.seen.items;
        for (seen) |d| try std.testing.expect(braceBalanced(d));
        if (!granted) {
            try std.testing.expectEqual(@as(usize, 3), seen.len);
            for (seen) |d| try std.testing.expect(std.mem.indexOf(u8, d, "ACTIONS_ID_TOKEN") == null);
            continue;
        }
        try std.testing.expectEqual(@as(usize, 4), seen.len);
        try std.testing.expect(std.mem.indexOf(u8, seen[1], "setSecret") != null);
        for ([_][]const u8{ seen[2], seen[3] }) |d| {
            try std.testing.expect(std.mem.indexOf(u8, d, "'ACTIONS_ID_TOKEN_REQUEST_URL=https://token.test/idtoken?api-version=2.0'") != null);
            try std.testing.expect(std.mem.indexOf(u8, d, "withSecretVariable(name:\"ZIG_SECRET_0\",secret:\"SEC_ID\")") != null);
            try std.testing.expect(std.mem.indexOf(u8, d, "'ACTIONS_ID_TOKEN_REQUEST_TOKEN='\\\"$ZIG_SECRET_0\\\"") != null);
            try std.testing.expect(std.mem.indexOf(u8, d, "runs this step every time: it can request OIDC tokens (id-token: write)") != null);
            try std.testing.expect(std.mem.indexOf(u8, d, "ghs_") == null);
        }
    }
}

test "with step caching, each step's marker says whether it ran in this job or was replayed" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);
    const steps = [_]job_mod.Step{ testStep("fast"), testStep("cached") };
    const job = testJob(&steps);
    const answer = struct {
        fn f(ar: Allocator, id: []const u8, out: []const u8, ran_value: []const u8) ![]const u8 {
            return std.fmt.allocPrint(ar, "{{\"data\":{{\"loadContainerFromID\":{{\"withExec\":{{\"id\":\"{s}\",\"exitCode\":0,\"stdout\":\"{s}\",\"stderr\":\"\",\"fc_all\":{{\"contents\":\"::zig-file-command::ran\\n{s}\\n\"}}}}}}}}}}", .{ id, out, ran_value });
        }
    }.f;
    const answers = [_][]const u8{
        base_answer,
        // Ran in this job, though none of its lines streamed (they came late).
        try answer(arena, "C1", "fast\\n", "m-this-job"),
        // Replayed: an earlier job's marker.
        try answer(arena, "C2", "cached\\n", "m-earlier-job"),
    };
    var fake: FakeSession = .{ .answers = &answers, .arena = arena };
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    const res = try run(arena, std.testing.io, &env, .{ .step_cache = true, .test_ran_marker = "m-this-job", .test_session_argv = &.{ "sh", "-c", fake_child }, .test_transport = fake.transport() }, job, &log);
    try std.testing.expect(res.succeeded);
    // The marker is volatile: not part of any step's cache key.
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[0], "withVolatileVariable(name:\"ZIG_RUNNER_RAN\",value:\"m-this-job\")") != null);
    // Each step writes it with its file commands, and its own program does not see it.
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[1], "::zig-file-command::ran' \\\"${ZIG_RUNNER_RAN-}\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[1], "-u ZIG_RUNNER_RAN ") != null);
    // The markers' secret is volatile too, and hidden from the step's program.
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[0], "withVolatileVariable(name:\"ZIG_RUNNER_MARK\",value:\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[1], "-u ZIG_RUNNER_MARK ") != null);
    const got = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, got, "[job 0 step 1 stdout] fast") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "[job 0 step 1 stdout] Reused") == null);
    try std.testing.expect(std.mem.indexOf(u8, got, "[job 0 step 2 stdout] cached") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "[job 0 step 2 stdout] Reused from Dagger's cache") != null);
}

test "a script that names the commit or a ref runs every time; one that does not can be replayed" {
    try std.testing.expect(readsRunSpecific("go build -ldflags \"-X main.commit=$GITHUB_SHA\" ./..."));
    try std.testing.expect(readsRunSpecific("if [ \"$GITHUB_REF\" = refs/heads/main ]; then ./deploy.sh; fi"));
    try std.testing.expect(readsRunSpecific("echo ${GITHUB_HEAD_REF}"));
    try std.testing.expect(!readsRunSpecific("go test ./..."));
    try std.testing.expect(isVolatile("GITHUB_SHA") and isVolatile("GITHUB_REF_NAME") and !isVolatile("GITHUB_REPOSITORY"));
}

test "JavaScript pre and post: pre runs first and hands its state on, post-if is honoured, a failing pre fails the job" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);
    const action_yml =
        \\runs:
        \\  using: node24
        \\  pre: dist/pre.js
        \\  main: dist/main.js
        \\  post: dist/post.js
        \\  post-if: success()
    ;
    const pre_with_state = "{\"data\":{\"loadContainerFromID\":{\"withExec\":{\"id\":\"C1\",\"exitCode\":0,\"stdout\":\"\",\"stderr\":\"\",\"fc_state\":{\"contents\":\"fromPre=1\\n\"}}}}}";
    for ([_]bool{ false, true }) |pre_fails| {
        const steps = [_]job_mod.Step{ usesStep("act", "o", "act", "v1", &.{}), testStep("exit 1") };
        var job = testJob(&steps);
        job.secrets = &.{"ghs_jobtoken"};
        job.job_token = "ghs_jobtoken";
        var answers: std.ArrayList([]const u8) = .empty;
        try answers.appendSlice(arena, &.{
            base_answer,
            try treeAnswer(arena, "D1", &.{ "action.yml", "dist" }),
            try fileAnswer(arena, action_yml),
            "{\"data\":{\"container\":{\"from\":{\"bin\":{\"id\":\"BUN\"}}}}}",
            "{\"data\":{\"zsec0\":{\"id\":\"S1\"}}}",
        });
        if (pre_fails) {
            try answers.append(arena, try exec(arena, "C1", 1, ""));
        } else {
            try answers.appendSlice(arena, &.{
                pre_with_state,
                // main: the job token registered for pre is used again
                try exec(arena, "C2", 0, ""),
                try exec(arena, "C3", 1, ""), // the failing step: success() is false for the post
            });
        }
        var fake: FakeSession = .{ .answers = answers.items, .arena = arena };
        var buf: [4096]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
        const res = try run(arena, std.testing.io, &env, .{ .test_session_argv = &.{ "sh", "-c", fake_child }, .test_transport = fake.transport() }, job, &log);
        const seen = fake.seen.items;
        for (seen) |d| try std.testing.expect(braceBalanced(d));
        try std.testing.expect(!res.succeeded);
        try std.testing.expect(std.mem.indexOf(u8, seen[5], "/github/_actions/o/act/v1/dist/pre.js") != null);
        // The pre is a step of its own, logged after the job's two steps.
        try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "##[group]Pre") == null);
        try std.testing.expectEqual(@as(usize, 1), res.extra.len);
        try std.testing.expectEqual(@as(u32, 3), res.extra[0].log_step);
        try std.testing.expect(std.mem.startsWith(u8, res.extra[0].name, "Pre "));
        try std.testing.expectEqual(@as(u32, 4), res.next_log_step);
        if (pre_fails) {
            try std.testing.expectEqual(@as(usize, 6), seen.len);
            try std.testing.expectEqual(Outcome.failure, res.extra[0].outcome);
            try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "[job 0 step 3 stdout] ##[error]Process completed with exit code 1.") != null);
            try std.testing.expectEqual(Outcome.skipped, res.steps[0].outcome);
            try std.testing.expectEqual(Outcome.skipped, res.steps[1].outcome);
        } else {
            // main gets pre's state; no post after the failing step (post-if: success()).
            try std.testing.expectEqual(@as(usize, 8), seen.len);
            try std.testing.expect(std.mem.indexOf(u8, seen[6], "dist/main.js") != null);
            try std.testing.expect(std.mem.indexOf(u8, seen[6], "'STATE_fromPre=1'") != null);
            try std.testing.expect(std.mem.indexOf(u8, seen[6], "secret:\"S1\"") != null);
            try std.testing.expectEqual(Outcome.success, res.steps[0].outcome);
            try std.testing.expectEqual(Outcome.failure, res.steps[1].outcome);
            try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "Post o/act") == null);
            try std.testing.expectEqual(Outcome.success, res.extra[0].outcome);
        }
    }
}

// --- round trips per step ---

/// A stand-in for the Dagger session that answers any document with data of the shape it selects
/// (ids unique, exit codes 0, outputs empty, files from `files`), and records every document. The
/// request counts below do not depend on the order queries are sent in, only on how many there are.
const AutoSession = struct {
    arena: Allocator,
    seen: std.ArrayList([]const u8) = .empty,
    /// `file(path:)` contents by path; others are "".
    files: []const [2][]const u8 = &.{},
    /// An exec whose document contains [0] prints [1].
    stdout: []const [2][]const u8 = &.{},
    ids: u32 = 0,

    fn send(ptr: *anyopaque, arena: Allocator, doc: []const u8, _: usize) anyerror![]const u8 {
        const self: *AutoSession = @ptrCast(@alignCast(ptr));
        try self.seen.append(self.arena, try self.arena.dupe(u8, doc));
        var p: Answer = .{ .s = doc, .self = self, .arena = arena };
        try p.out.appendSlice(arena, "{\"data\":");
        p.ws();
        try p.selection(null);
        try p.out.append(arena, '}');
        return p.out.items;
    }

    fn transport(self: *AutoSession) Transport {
        return .{ .ptr = self, .sendFn = send };
    }

    /// Documents that contain `needle`.
    fn count(self: *AutoSession, needle: []const u8) usize {
        var n: usize = 0;
        for (self.seen.items) |d| {
            if (std.mem.indexOf(u8, d, needle) != null) n += 1;
        }
        return n;
    }

    const Answer = struct {
        s: []const u8,
        i: usize = 0,
        self: *AutoSession,
        arena: Allocator,
        out: std.ArrayList(u8) = .empty,

        fn ws(p: *Answer) void {
            while (p.i < p.s.len and p.s[p.i] == ' ') p.i += 1;
        }

        fn name(p: *Answer) []const u8 {
            const start = p.i;
            while (p.i < p.s.len and (std.ascii.isAlphanumeric(p.s[p.i]) or p.s[p.i] == '_'))
                p.i += 1;
            return p.s[start..p.i];
        }

        /// Skips `(...)`, strings and lists included; returns what was inside.
        fn args(p: *Answer) []const u8 {
            const start = p.i + 1;
            var depth: usize = 0;
            var in_str = false;
            while (p.i < p.s.len) : (p.i += 1) {
                const c = p.s[p.i];
                if (in_str) {
                    if (c == '\\') p.i += 1 else if (c == '"') in_str = false;
                    continue;
                }
                switch (c) {
                    '"' => in_str = true,
                    '(', '[' => depth += 1,
                    ')', ']' => {
                        depth -= 1;
                        if (depth == 0) {
                            p.i += 1;
                            return p.s[start .. p.i - 1];
                        }
                    },
                    else => {},
                }
            }
            return p.s[start..];
        }

        fn pathArg(a: []const u8) ?[]const u8 {
            const k = std.mem.indexOf(u8, a, "path:\"") orelse return null;
            const rest = a[k + 6 ..];
            const end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
            return rest[0..end];
        }

        fn selection(p: *Answer, file: ?[]const u8) anyerror!void {
            p.i += 1; // {
            try p.out.append(p.arena, '{');
            var first = true;
            while (true) {
                p.ws();
                if (p.s[p.i] == '}') {
                    p.i += 1;
                    break;
                }
                const key = p.name();
                var field = key;
                p.ws();
                if (p.s[p.i] == ':') {
                    p.i += 1;
                    p.ws();
                    field = p.name();
                    p.ws();
                }
                var a: []const u8 = "";
                if (p.s[p.i] == '(') {
                    a = p.args();
                    p.ws();
                }
                if (!first) try p.out.append(p.arena, ',');
                first = false;
                try p.out.print(p.arena, "\"{s}\":", .{key});
                if (p.s[p.i] == '{') {
                    try p.selection(if (std.mem.eql(u8, field, "file")) pathArg(a) else file);
                } else try p.leaf(field, file);
            }
            try p.out.append(p.arena, '}');
        }

        fn leaf(p: *Answer, field: []const u8, file: ?[]const u8) !void {
            const w = p.arena;
            const eql = std.mem.eql;
            if (eql(u8, field, "id")) {
                p.self.ids += 1;
                return p.out.print(w, "\"ID{d}\"", .{p.self.ids});
            }
            if (eql(u8, field, "exitCode")) {
                try p.out.appendSlice(w, "0");
                // An exec's output comes with it, asked for or not, as in the scripted answers:
                // it stands in for the live stream these tests have none of, which would
                // otherwise send every step's document again for its output (`Exec.Recorded`).
                const rest = p.s[p.i..];
                const selected = rest[0 .. std.mem.indexOfScalar(u8, rest, '}') orelse rest.len];
                if (std.mem.indexOf(u8, selected, "stdout") != null) return;
                try p.out.appendSlice(w, ",\"stdout\":");
                try p.leaf("stdout", file);
                return p.out.appendSlice(w, ",\"stderr\":\"\"");
            }
            if (eql(u8, field, "entries")) return p.out.appendSlice(w, "[\"action.yml\"]");
            if (eql(u8, field, "digest")) return p.out.appendSlice(w, "\"sha256:0123abcd\"");
            if (eql(u8, field, "removedPaths") or eql(u8, field, "entrypoint"))
                return p.out.appendSlice(w, "[]");
            if (eql(u8, field, "defaultArgs")) return p.out.appendSlice(w, "[\"/bin/sh\"]");
            var text: []const u8 = "";
            if (eql(u8, field, "contents")) {
                if (file) |f| for (p.self.files) |kv| {
                    if (eql(u8, kv[0], f)) text = kv[1];
                };
            } else if (eql(u8, field, "stdout")) {
                for (p.self.stdout) |r| if (std.mem.indexOf(u8, p.s, r[0]) != null) {
                    text = r[1];
                };
            }
            var aw: std.Io.Writer.Allocating = .init(w);
            try std.json.Stringify.value(text, .{}, &aw.writer);
            try p.out.appendSlice(w, aw.written());
        }
    };
};

/// Runs `job` against `auto` and returns how many documents it sent.
fn roundTrips(arena: Allocator, auto: *AutoSession, opts_in: Options, job: job_mod.Job) !usize {
    var env: std.process.Environ.Map = .init(arena);
    const buf = try arena.alloc(u8, 1 << 16);
    var w: std.Io.Writer = .fixed(buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    var opts = opts_in;
    opts.test_session_argv = &.{ "sh", "-c", fake_child };
    opts.test_transport = auto.transport();
    const res = try run(arena, std.testing.io, &env, opts, job, &log);
    if (!res.succeeded) {
        std.debug.print("job failed: {s}\n", .{w.buffered()});
        return error.JobFailed;
    }
    for (auto.seen.items) |d| try std.testing.expect(braceBalanced(d));
    return auto.seen.items.len;
}

test "round trips: documents sent per step kind, before and after" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const ctx = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"github":{"t":2,"d":[{"k":"repository","v":"o/r"},{"k":"run_id","v":"9"},{"k":"run_attempt","v":"1"}]}}
    , .{});
    const js_yml =
        \\inputs:
        \\  github-token:
        \\    default: ${{ github.token }}
        \\runs:
        \\  using: node24
        \\  main: dist/index.js
        \\  post: dist/post.js
    ;
    const composite_yml =
        \\runs:
        \\  using: composite
        \\  steps:
        \\    - shell: bash
        \\      run: echo one
        \\    - shell: bash
        \\      run: echo two
    ;
    const secret = "s3cr3t-value";
    var with_secret = testStep("deploy");
    with_secret.env = &.{.{ .name = "TOKEN", .value = .{ .lit = secret } }};
    const checkout: job_mod.Step = .{ .id = "co", .name = "co", .condition = "success()", .action = .{ .checkout = &.{} } };
    const matcher_json = "{\"problemMatcher\":[]}";
    var docker = testStep("");
    docker.action = .{ .docker = .{ .image = "alpine:3.22", .inputs = &.{} } };
    // Every job here has the job token and GITHUB_TOKEN among its secrets, as on GitHub. `was` is
    // what the runner sent before secrets were registered once per job and in batches, actions
    // loaded once per job, the job setup's queries merged, matcher files read together, and output
    // keys' reads folded into the step's own query; `docs` is what it sends now, `secret_docs` how
    // many of those register secrets.
    const Case = struct {
        name: []const u8,
        steps: []const job_mod.Step,
        opts: Options = .{},
        job_env_secret: bool = false,
        files: []const [2][]const u8 = &.{},
        stdout: []const [2][]const u8 = &.{},
        was: usize,
        docs: usize,
        secret_docs: usize,
    };
    const runs3 = [_]job_mod.Step{ testStep("a"), testStep("b"), testStep("c") };
    const js2 = [_]job_mod.Step{ usesStep("j1", "o", "js", "v1", &.{}), usesStep("j2", "o", "js", "v1", &.{}) };
    const js_files = [_][2][]const u8{.{ "action.yml", js_yml }};
    const keyed = Options{ .step_cache = true, .output_keys = true };
    const cases = [_]Case{
        // Set up job (the base container), then one query per step: nothing to save.
        .{ .name = "3 run steps", .steps = &runs3, .was = 4, .docs = 4, .secret_docs = 0 },
        .{ .name = "3 run steps, step cache", .steps = &runs3, .opts = .{ .step_cache = true }, .was = 4, .docs = 4, .secret_docs = 0 },
        .{ .name = "3 run steps, package caches", .steps = &runs3, .opts = .{ .package_caches = true }, .was = 5, .docs = 5, .secret_docs = 0 },
        // The step's secret is registered once, not once per step.
        .{ .name = "3 run steps with the same secret env", .steps = &.{ with_secret, with_secret, with_secret }, .was = 7, .docs = 5, .secret_docs = 1 },
        // The job env's secret is registered in the cache volumes' query.
        .{ .name = "run step, job env secret, package caches", .steps = &.{testStep("a")}, .opts = .{ .package_caches = true }, .job_env_secret = true, .was = 4, .docs = 3, .secret_docs = 1 },
        .{ .name = "checkout + run step", .steps = &.{ checkout, testStep("a") }, .was = 5, .docs = 5, .secret_docs = 1 },
        .{ .name = "checkout + run step, package caches", .steps = &.{ checkout, testStep("a") }, .opts = .{ .package_caches = true }, .was = 6, .docs = 5, .secret_docs = 1 },
        // The action fetched once; its two tokens registered once, together.
        .{ .name = "JS action in 2 steps, main + post each", .steps = &js2, .files = &js_files, .was = 18, .docs = 9, .secret_docs = 1 },
        .{ .name = "JS action in 2 steps, package caches", .steps = &js2, .files = &js_files, .opts = .{ .package_caches = true }, .was = 19, .docs = 9, .secret_docs = 1 },
        .{ .name = "composite action with 2 run steps", .steps = &.{usesStep("c1", "o", "comp", "v1", &.{})}, .files = &.{.{ "action.yml", composite_yml }}, .was = 5, .docs = 5, .secret_docs = 0 },
        .{ .name = "docker:// step twice", .steps = &.{ docker, docker }, .was = 11, .docs = 10, .secret_docs = 1 },
        // Both matcher files in one query.
        .{ .name = "run step adding 2 matchers + run step", .steps = &.{ testStep("matchers"), testStep("b") }, .stdout = &.{.{ "matchers", "::add-matcher::/m1.json\n::add-matcher::/m2.json\n" }}, .files = &.{ .{ "/m1.json", matcher_json }, .{ "/m2.json", matcher_json } }, .was = 5, .docs = 4, .secret_docs = 0 },
        // The container before the step read with its exec; the store asked for with busybox, or
        // in the cache volumes' query.
        .{ .name = "output keys: always-run step + run step", .steps = &.{ with_secret, testStep("b") }, .opts = keyed, .was = 10, .docs = 8, .secret_docs = 1 },
        .{ .name = "output keys: 2 always-run steps + run step", .steps = &.{ with_secret, with_secret, testStep("b") }, .opts = keyed, .was = 16, .docs = 12, .secret_docs = 1 },
        .{ .name = "output keys: always-run + run step, package caches", .steps = &.{ with_secret, testStep("b") }, .opts = .{ .step_cache = true, .output_keys = true, .package_caches = true }, .was = 11, .docs = 9, .secret_docs = 1 },
    };
    for (cases) |c| {
        var job = testJob(c.steps);
        job.context_data = ctx;
        job.secrets = &.{ secret, "ghs_jobtoken", "ghs_token" };
        job.job_token = "ghs_jobtoken";
        job.secret_vars = &.{.{ .name = "GITHUB_TOKEN", .value = "ghs_token" }};
        if (c.job_env_secret) job.env = &.{.{ .name = "JOB_SECRET", .value = .{ .lit = secret } }};
        var auto: AutoSession = .{ .arena = arena, .files = c.files, .stdout = c.stdout };
        const n = try roundTrips(arena, &auto, c.opts, job);
        if (n != c.docs or auto.count("setSecret") != c.secret_docs) {
            std.debug.print("{s}: {d} documents ({d} with setSecret), want {d} ({d}); was {d}\n", .{
                c.name, n, auto.count("setSecret"), c.docs, c.secret_docs, c.was,
            });
            return error.TestUnexpectedResult;
        }
        try std.testing.expect(c.docs <= c.was);
    }
}

test "round trips: a matcher file that cannot be read is read alone, and the others still load" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);
    const steps = [_]job_mod.Step{ testStep("matchers"), testStep("b") };
    const answers = [_][]const u8{
        base_answer,
        try exec(arena, "C1", 0, "::add-matcher::/m1.json\\n::add-matcher::/missing.json\\n"),
        "{\"errors\":[{\"message\":\"/missing.json: no such file or directory\"}]}",
        "{\"data\":{\"loadContainerFromID\":{\"file\":{\"contents\":\"{\\\"problemMatcher\\\":[]}\"}}}}",
        "{\"errors\":[{\"message\":\"/missing.json: no such file or directory\"}]}",
        try exec(arena, "C2", 0, ""),
    };
    var fake: FakeSession = .{ .answers = &answers, .arena = arena };
    var buf: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    const res = try run(arena, std.testing.io, &env, .{ .test_session_argv = &.{ "sh", "-c", fake_child }, .test_transport = fake.transport() }, testJob(&steps), &log);
    try std.testing.expect(res.succeeded);
    const seen = fake.seen.items;
    try std.testing.expectEqual(@as(usize, 6), seen.len);
    try std.testing.expect(std.mem.indexOf(u8, seen[2], "loadContainerFromID(id:\"C1\") { m0: file(path:\"/m1.json\") { contents } m1: file(path:\"/missing.json\") { contents } }") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen[3], "file(path:\"/m1.json\") { contents }") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen[4], "file(path:\"/missing.json\") { contents }") != null);
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "Could not read the problem matcher '/missing.json'") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Could not read the problem matcher '/m1.json'") == null);
}

test "an exec's recorded output is asked for only to replay it, and never past max_recorded_bytes" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);
    const steps = [_]job_mod.Step{ testStep("biglog"), testStep("b") };
    // Answers without the output, which the exec's document no longer asks for.
    const lean = "{{\"data\":{{\"loadContainerFromID\":{{\"withExec\":" ++
        "{{\"id\":\"C{d}\",\"exitCode\":0}}}}}}}}";
    // Step 1 printed more than is read back: the transport stops at the limit.
    const big = try arena.alloc(u8, max_recorded_bytes);
    @memset(big, 'x');
    const answers = [_][]const u8{
        base_answer,
        try std.fmt.allocPrint(arena, lean, .{1}),
        try exec(arena, "C1", 0, big),
        try std.fmt.allocPrint(arena, lean, .{2}),
        try exec(arena, "C2", 0, "replayed line"),
    };
    var fake: FakeSession = .{ .answers = &answers, .arena = arena };
    var buf: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    const res = try run(arena, std.testing.io, &env, .{
        .test_session_argv = &.{ "sh", "-c", fake_child },
        .test_transport = fake.transport(),
        .step_cache = true,
    }, testJob(&steps), &log);
    try std.testing.expect(res.succeeded);
    const seen = fake.seen.items;
    try std.testing.expectEqual(@as(usize, 5), seen.len);
    // The exec asks for no output: asking made the engine log all of it again (verbose).
    try std.testing.expect(std.mem.indexOf(u8, seen[1], "stdout") == null);
    // None of its lines arrived live (there is no stream here) and nothing says it ran, so it was
    // served from the cache and its output is asked for: the same document, which the engine
    // answers from its cache, with the fields put in.
    const fields = "stdout stderr ";
    try std.testing.expectEqual(seen[1].len + fields.len, seen[2].len);
    const at = std.mem.indexOf(u8, seen[2], "exitCode " ++ fields).? + "exitCode ".len;
    try std.testing.expectEqualStrings(seen[1][0..at], seen[2][0..at]);
    try std.testing.expectEqualStrings(seen[1][at..], seen[2][at + fields.len ..]);
    // Past the limit it is not read on, and the log says why the step shows nothing.
    const note = "could not be read back (it is over the 4 MiB that is replayed)";
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), note) != null);
    // The next step continues from the exec's container; its output, small, is replayed.
    try std.testing.expect(std.mem.indexOf(u8, seen[3], "loadContainerFromID(id:\"C1\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen[4], fields) != null);
    const replayed = "step 2 stdout] replayed line";
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), replayed) != null);
}

test "a step that ran and printed nothing does not ask for its output" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);
    const steps = [_]job_mod.Step{ testStep("true"), testStep("true") };
    // Without step caching every step runs in this job: one with no line live printed none.
    const answers = [_][]const u8{
        base_answer,
        "{\"data\":{\"loadContainerFromID\":{\"withExec\":{\"id\":\"C1\",\"exitCode\":0}}}}",
        "{\"data\":{\"loadContainerFromID\":{\"withExec\":{\"id\":\"C2\",\"exitCode\":0}}}}",
    };
    var fake: FakeSession = .{ .answers = &answers, .arena = arena };
    var buf: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    const res = try run(arena, std.testing.io, &env, .{
        .test_session_argv = &.{ "sh", "-c", fake_child },
        .test_transport = fake.transport(),
    }, testJob(&steps), &log);
    try std.testing.expect(res.succeeded);
    try std.testing.expectEqual(@as(usize, 3), fake.seen.items.len);
    for (fake.seen.items) |d| try std.testing.expect(std.mem.indexOf(u8, d, "stdout") == null);
}

test "a step whose env fails to evaluate keeps its continue-on-error" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);
    // 20 characters, 8^5 times: past GitHub's 1 MiB expression memory.
    const f8 = "format('{0}{0}{0}{0}{0}{0}{0}{0}', ";
    var huge = testStep("huge");
    huge.env = &.{.{
        .name = "HUGE",
        .value = .{ .expr = f8 ++ f8 ++ f8 ++ f8 ++ f8 ++ "'xxxxxxxxxxxxxxxxxxxx')))))" },
    }};
    huge.continue_on_error = .{ .lit = "true" };
    const steps = [_]job_mod.Step{ huge, testStep("b") };
    const answers = [_][]const u8{ base_answer, try exec(arena, "C2", 0, "") };
    var fake: FakeSession = .{ .answers = &answers, .arena = arena };
    var buf: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    const res = try run(arena, std.testing.io, &env, .{
        .test_session_argv = &.{ "sh", "-c", fake_child },
        .test_transport = fake.transport(),
    }, testJob(&steps), &log);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "could not evaluate env: the " ++
        "expression needs more than the 1048576 bytes") != null);
    // The step failed and the job went on: the next step ran, and the job succeeded.
    try std.testing.expect(res.succeeded);
    try std.testing.expectEqual(@as(usize, 2), fake.seen.items.len);
    try std.testing.expectEqual(Outcome.failure, res.steps[0].outcome);
    try std.testing.expect(res.steps[0].continued);
}

test "round trips: the job setup's query is sent again without the secrets when it fails with them" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);
    const steps = [_]job_mod.Step{testStep("a")};
    var job = testJob(&steps);
    job.secrets = &.{"s3cr3t-value"};
    job.env = &.{.{ .name = "JOB_SECRET", .value = .{ .lit = "s3cr3t-value" } }};
    var volumes: std.Io.Writer.Allocating = .init(arena);
    try volumes.writer.writeAll("{\"data\":{");
    for (package_cache_dirs, 0..) |_, i| try volumes.writer.print("{s}\"c{d}\":{{\"id\":\"V{d}\"}}", .{ if (i > 0) "," else "", i, i });
    try volumes.writer.writeAll("}}");
    const answers = [_][]const u8{
        "{\"errors\":[{\"message\":\"secret store unavailable\"}]}",
        volumes.written(),
        "{\"data\":{\"zsec0\":{\"id\":\"SEC_JOB\"}}}",
        base_answer,
        try exec(arena, "C1", 0, ""),
    };
    var fake: FakeSession = .{ .answers = &answers, .arena = arena };
    var buf: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    const res = try run(arena, std.testing.io, &env, .{ .package_caches = true, .test_session_argv = &.{ "sh", "-c", fake_child }, .test_transport = fake.transport() }, job, &log);
    try std.testing.expect(res.succeeded);
    const seen = fake.seen.items;
    try std.testing.expectEqual(@as(usize, 5), seen.len);
    try std.testing.expect(std.mem.indexOf(u8, seen[0], "zsec0: setSecret(") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen[0], "c0: cacheVolume(") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen[1], "setSecret") == null);
    try std.testing.expect(std.mem.indexOf(u8, seen[1], "c0: cacheVolume(") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen[2], "zsec0: setSecret(") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen[3], "withSecretVariable(name:\"JOB_SECRET\",secret:\"SEC_JOB\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen[3], "withMountedCache(path:") != null);
}
