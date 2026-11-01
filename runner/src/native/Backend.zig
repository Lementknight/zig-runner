//! The native backend for one job: its steps run in sandboxes of the runner's own (`sandbox.zig`)
//! instead of Dagger execs, each on an overlay of the layers the steps before it left
//! (docs/native-backend.md).
//!
//! It sits below the step script. Everything above it is the code the Dagger backend runs:
//! `dagger.runSteps` evaluates conditions, env, timeouts and `continue-on-error`,
//! `scripts.stepScriptFc` writes the same `sh -c` script, `JobLog` reads the same markers and
//! workflow commands, and `Exec.collect` applies the same file commands. What this file owns is
//! what the engine did: the base the steps start from, the container's environment between
//! steps, running one script, and reading its combined file commands back.

const Backend = @This();

const std = @import("std");
const job_mod = @import("../job.zig");
const engine = @import("../engine.zig");
const config = @import("../config.zig");
const dagger = @import("../dagger.zig");
const sandbox = @import("sandbox.zig");
const Exec = @import("../dagger/Exec.zig");
const Evaluator = @import("../dagger/Evaluator.zig");
const JobLog = @import("../dagger/JobLog.zig");
const SpanDemux = @import("../dagger/JobLog.zig").SpanDemux;
const checkout = @import("../dagger/checkout.zig");
const scripts = @import("../dagger/scripts.zig");

const Allocator = std.mem.Allocator;

arena: Allocator,
io: std.Io,
/// Backs each exec's log demultiplexer (`SpanDemux`), as for a direct Dagger session.
gpa: Allocator,
/// The job's directory under the store: its layers (`L<n>`), the overlay work directory and the
/// mount point. Removed when the job ends.
dir: []const u8,
rootfs: []const u8,
binds: []const sandbox.Spec.Bind,
/// Layer names in `dir`, oldest first.
layers: std.ArrayList([]const u8) = .empty,
/// The container's environment: what Dagger's container held between execs (the image's, the
/// runner's defaults, the job's `env:`, and what `GITHUB_ENV` and `GITHUB_PATH` added).
env: std.ArrayList(job_mod.EnvVar) = .empty,
/// Who steps run as, and where they start.
uid: u32 = 0,
gid: u32 = 0,
workdir: []const u8 = "/",
how: Launch,
running: sandbox.Running = .{},

/// What the runner configures (`RUNNER_BACKEND=native`).
pub const Config = struct {
    /// A directory holding the default image's filesystem, provisioned (`set_up.provision_script`,
    /// or `provision_runner_script` for the runner user); "" for none (`RUNNER_NATIVE_ROOTFS`).
    rootfs: []const u8 = "",
    /// Where jobs' layers live while they run (`RUNNER_NATIVE_STORE`).
    store: []const u8 = "",
    /// This binary, which runs each step's sandbox (`sandbox.command`).
    self_exe: []const u8 = "",
    /// The job came from a file on this machine (`--exec-job`), not from GitHub, so who wrote it
    /// is whoever runs the runner: the trust rule below does not apply.
    local: bool = false,
    /// Host directories mounted into every step. Tests bind the host's /usr into a rootfs of a
    /// few directories; phase 4's cache volumes will be these.
    binds: []const sandbox.Spec.Bind = &.{},
};

/// The native backend's settings from the runner's, or null when it runs steps on Dagger alone.
pub fn configFor(
    arena: Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    cfg: *const config.Config,
    local: bool,
) !?Config {
    if (cfg.backend != .native) return null;
    return .{
        .rootfs = cfg.native_rootfs,
        .store = try cfg.nativeStore(arena, environ),
        .self_exe = std.process.executablePathAlloc(io, arena) catch "",
        .local = local,
    };
}

/// How sandboxes are started on this machine (`launch`).
pub const Launch = struct {
    argv_prefix: []const []const u8,
    userns: sandbox.Userns,
};

/// The default image's own environment (`ubuntu:24.04`'s config): P3's pull reads it from the
/// image instead.
const image_path = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";
/// `runner_user`'s ids in the provisioned image (`set_up.provision_runner_script`).
const runner_uid = 1001;
/// Overlay takes at most 500 lower layers; flattening the stack is P2's.
const max_layers = 400;

/// Why this job cannot run natively yet, or null when it can: the first thing it uses that the
/// native backend does not do yet (docs/native-backend.md, "Phases"). Decided before anything
/// runs, for the whole job: native and Dagger never share one.
pub fn unsupported(io: std.Io, job: job_mod.Job, opts: dagger.Options, cfg: Config) ?[]const u8 {
    if (cfg.rootfs.len == 0) return "there is no native rootfs (RUNNER_NATIVE_ROOTFS; the " ++
        "native image pull is phase 3)";
    std.Io.Dir.accessAbsolute(io, cfg.rootfs, .{}) catch
        return "the native rootfs (RUNNER_NATIVE_ROOTFS) cannot be read";
    if (cfg.self_exe.len == 0 or cfg.store.len == 0) return "the native store is not set up";
    if (!opts.trusted and !cfg.local) return "native steps run only in jobs this runner vouches " ++
        "for, until their isolation lands (phase 5)";
    if (job.container != null) return "`container:` jobs are not native yet (phase 3)";
    if (job.services.len > 0) return "`services:` are not native yet (phase 6)";
    if (!std.mem.eql(u8, opts.image, dagger.default_image) or !opts.provision)
        return "only the default image is native yet (phase 3)";
    if (opts.nesting) return "steps that use the Dagger engine (RUNNER_DAGGER_NESTING) need Dagger";
    for (job.steps) |step| switch (step.action) {
        .uses => return "`uses:` actions are not native yet (phase 7)",
        .docker => return "`docker://` steps are not native yet (phase 7)",
        .checkout => |inputs| for (inputs) |in| {
            if (!std.mem.eql(u8, in.name, "submodules")) continue;
            const lit = switch (in.value) {
                .lit => |l| l,
                else => "true",
            };
            if (!std.mem.eql(u8, lit, "false")) return "a checkout with submodules is not " ++
                "native yet";
        },
        .script, .unsupported => {},
    };
    if (opts.step_user == .runner and usernsHere(io) != .none) return "steps run as the runner " ++
        "user need a range of user ids, which a rootless runner does not have: run the runner " ++
        "as root, or set RUNNER_STEP_USER=root (phase 5 maps subordinate ids)";
    return null;
}

/// How to start a sandbox here: as root, the helper needs no user namespace; rootless, it makes
/// one itself, unless the kernel lets only allow-listed programs do that (Ubuntu's
/// `apparmor_restrict_unprivileged_userns`), where it is started under util-linux's `unshare`,
/// which is on that list. An AppArmor profile granting `userns` to the runner would do instead.
pub fn launch(arena: Allocator, io: std.Io, cfg: Config) !Launch {
    const self: []const []const u8 = try arena.dupe([]const u8, &.{cfg.self_exe});
    const userns = usernsHere(io);
    if (userns != .inherited) return .{ .argv_prefix = self, .userns = userns };
    const unshare = [_][]const u8{ "unshare", "--user", "--map-root-user", "--mount", "--" };
    return .{
        .argv_prefix = try std.mem.concat(arena, []const u8, &.{ &unshare, self }),
        .userns = .inherited,
    };
}

fn usernsHere(io: std.Io) sandbox.Userns {
    if (std.os.linux.geteuid() == 0) return .none;
    var buf: [8]u8 = undefined;
    const restricted = std.Io.Dir.cwd().readFile(
        io,
        "/proc/sys/kernel/apparmor_restrict_unprivileged_userns",
        &buf,
    ) catch "0";
    return if (std.mem.startsWith(u8, restricted, "1")) .inherited else .self;
}

/// A job's directory in the store, empty.
pub fn init(arena: Allocator, io: std.Io, gpa: Allocator, cfg: Config) !Backend {
    var raw: [8]u8 = undefined;
    io.random(&raw);
    const dir = try std.fmt.allocPrint(arena, "{s}/jobs/{s}", .{
        cfg.store,
        &std.fmt.bytesToHex(raw, .lower),
    });
    try std.Io.Dir.cwd().createDirPath(io, dir);
    for ([_][]const u8{ "W", "M" }) |d| try std.Io.Dir.cwd().createDirPath(
        io,
        try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, d }),
    );
    return .{
        .arena = arena,
        .io = io,
        .gpa = gpa,
        .dir = dir,
        .rootfs = cfg.rootfs,
        .binds = cfg.binds,
        .how = try launch(arena, io, cfg),
    };
}

/// Removes the job's layers. Overlay leaves its work directory's `work` with no permissions at
/// all (mode 0), which a rootless runner cannot descend into until it gives them back.
pub fn deinit(b: *Backend) void {
    if (std.fmt.allocPrintSentinel(b.arena, "{s}/W/work", .{b.dir}, 0)) |work| {
        _ = std.os.linux.chmod(work, 0o700);
    } else |_| {}
    std.Io.Dir.cwd().deleteTree(b.io, b.dir) catch {};
}

/// The base every step starts from, as `set_up.baseContainerId` builds Dagger's: the image's
/// env, the step user and its HOME, the job's workspace and RUNNER_TEMP, the event payload as a
/// file, the step markers' secret, GitHub's default variables and the job's `env:`. Package
/// caches, uv's environment in its cache and Zig's local cache are not mounted: they are caches,
/// and the native backend has no volumes before phase 4. On failure the reason is in `err_msg`.
pub fn base(
    b: *Backend,
    ev: *Evaluator,
    plan: anytype,
    err_msg: *[]const u8,
) !void {
    const arena = b.arena;
    try b.baseEnv(ev, plan);

    // The workspace and RUNNER_TEMP, made as Dagger's base makes them: by root, in the image,
    // owned by the step user when it is not root. The event payload goes in as `withNewFile` does.
    const chown = if (plan.as_runner) " && chown -R " ++ dagger.runner_user ++ ":" ++
        dagger.runner_user ++ " " ++ dagger.work_root else "";
    const mk = try std.fmt.allocPrint(arena, "mkdir -p {s} {s}{s}", .{
        ev.workspace,
        ev.temp,
        chown,
    });
    const files = [_]sandbox.Spec.File{.{
        .path = dagger.event_path,
        .contents = try ev.eventJson(),
        .mode = 0o644,
        .keep = true,
    }};
    var out: Captured = .{ .arena = arena };
    const ended = try b.exec(mk, try b.envStrings(&.{}), &files, 0, 0, out.output());
    if (ended.failure.len > 0 or ended.code != 0) {
        err_msg.* = try std.fmt.allocPrint(arena, "could not set up the job's base: {s}{s}", .{
            ended.failure,
            out.tail(),
        });
        return error.BaseContainerFailed;
    }
}

/// The base's environment, user and working directory (`base`), as `set_up.writeImage`,
/// `writeProvisionAndWorkspace`, `writeRunEnv` and `writeJobEnv` set them on Dagger's container.
/// What carries a secret is a plain variable here, as a Dagger secret variable is in the
/// process: there is no engine whose cache could keep it.
fn baseEnv(b: *Backend, ev: *Evaluator, plan: anytype) !void {
    try b.put("PATH", image_path);
    if (plan.as_runner) {
        b.uid = runner_uid;
        b.gid = runner_uid;
        try b.put("HOME", dagger.runner_home);
    }
    try b.put(dagger.mark_env, plan.mark);
    for (try ev.defaultEnv()) |e| try b.put(e.name, e.value);
    for (try ev.withoutReapplied(ev.job_env.items)) |e| try b.put(e.name, e.value);
    b.workdir = ev.workspace;
}

/// `Exec.execScript` on this backend: one step's script, its output streamed into the job's log,
/// its file commands applied. `error.EngineFailed` (with `x.err_msg`) when the sandbox failed or
/// the step was stopped (`abort`).
pub fn execScript(
    b: *Backend,
    x: *Exec,
    num: u32,
    fc: u32,
    resolved_in: dagger.Resolved,
    action_name: []const u8,
    secret_env_in: []const dagger.SecretRef,
) !Exec.Out {
    const arena = b.arena;
    try b.applyPendingEnv(x);
    const step_run = try x.resolveRunStep(resolved_in, secret_env_in, null);
    const resolved = step_run.resolved;
    const script = try scripts.stepScriptFc(arena, num, fc, resolved, action_name);

    // Secret variables reach the script under their aliases (`scripts.secretAlias`), as Dagger's
    // `withSecretVariable` gives them: only the name is in the script, so the value is in no
    // command line (which any user on the host can read).
    var extra: std.ArrayList(job_mod.EnvVar) = .empty;
    for (step_run.secret_env, 0..) |s, i| try extra.append(arena, .{
        .name = try scripts.secretAlias(arena, i),
        .value = plaintext(x, s.id),
    });
    // A script holding a secret is a file the sandbox writes and removes, as Dagger mounts it.
    var files: std.ArrayList(sandbox.Spec.File) = .empty;
    if (step_run.script_secret != null) try files.append(arena, .{
        .path = try scripts.scriptPath(arena, fc, resolved.run.shell),
        .contents = resolved.run.script,
    });

    const step_env = switch (resolved) {
        .run => |r| r.env,
        .checkout => &.{},
    };
    x.sh.beginCommands(num, try dagger.envContext(arena, x.ev.job_env.items, step_env));
    x.beginExec(num);
    var demux: SpanDemux = .{ .sh = x.sh, .gpa = b.gpa };
    defer demux.deinit();
    var live: Live = .{ .demux = &demux };
    const ended = try b.exec(
        script,
        try b.envStrings(extra.items),
        files.items,
        b.uid,
        b.gid,
        live.output(),
    );
    // Every line is in: the pipe is closed only once every process of the step has ended.
    demux.flushPartial();
    x.sh.ended[num - 1].store(true, .release);
    x.sh.flush();
    if (ended.failure.len > 0) {
        x.err_msg = ended.failure;
        return error.EngineFailed;
    }
    if (ended.killed) {
        x.err_msg = "the step was stopped";
        return error.EngineFailed;
    }
    const all = try b.readLayerFile(
        b.layers.items[b.layers.items.len - 1],
        try scripts.fcPath(arena, "all", fc),
    );
    var answer: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(.{
        .exitCode = ended.code,
        .fc_all = if (all) |text| .{ .contents = text } else null,
    }, .{ .emit_null_optional_fields = false }, &answer.writer);
    const data = try std.json.parseFromSliceLeaky(std.json.Value, arena, answer.written(), .{});
    const out = try x.collect(num, data, .{ .doc = "", .at = 0 });
    x.loadPendingMatchers(num);
    return out;
}

/// The built-in checkout on this backend: the repository fetched by git in the job's image, as
/// actions/checkout fetches it, into the tree Dagger's `git` gives (`checkout.query`): the commit
/// checked out with its `.git` and no refs (the step's script adds them, `checkout.refCommands`)
/// and every file at `checkout.mtime`. Its output is not the step's, as Dagger's fetch is not:
/// on failure the step says why.
pub fn fetchCheckout(b: *Backend, x: *Exec, co: job_mod.Checkout) !dagger.Fetched {
    const arena = b.arena;
    var f = try checkout.describe(arena, x.job.*, co);
    f.fetched_with = "git in the job's image";
    if (f.repo.len == 0) {
        f.result = .{ .failed = "no repository to check out (the job has no github.repository)" };
        return f;
    }
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    try w.writeAll("set -e\nmkdir -p ");
    try dagger.shellQuote(w, f.mount);
    try w.writeAll(" && cd ");
    try dagger.shellQuote(w, f.mount);
    try w.writeAll("\ngit init -q\ngit remote add origin ");
    try dagger.shellQuote(w, try std.fmt.allocPrint(arena, "{s}.git", .{f.url}));
    try w.writeAll("\ngit -c protocol.version=2 fetch -q --no-tags");
    if (f.depth > 0) try w.print(" --depth={d}", .{f.depth});
    try w.writeAll(" origin ");
    try dagger.shellQuote(w, f.want);
    if (f.tags) try w.writeAll("\ngit fetch -q --tags origin");
    try w.print("\ngit checkout -q --detach FETCH_HEAD\nrm -f .git/FETCH_HEAD\n" ++
        "find . -exec touch -h -d @{d} {{}} +\n", .{checkout.mtime});

    // The job's token as GitHub expects it over HTTPS, in git's environment, never on its
    // command line.
    var extra: std.ArrayList(job_mod.EnvVar) = .empty;
    if (x.gitAuth()) |id| {
        const basic = try std.fmt.allocPrint(arena, "x-access-token:{s}", .{plaintext(x, id)});
        const enc = std.base64.standard.Encoder;
        const b64 = try arena.alloc(u8, enc.calcSize(basic.len));
        try extra.appendSlice(arena, &.{
            .{ .name = "GIT_CONFIG_COUNT", .value = "1" },
            .{
                .name = "GIT_CONFIG_KEY_0",
                .value = try std.fmt.allocPrint(arena, "http.{s}/.extraheader", .{
                    std.mem.trimEnd(u8, x.job.github.server_url, "/"),
                }),
            },
            .{
                .name = "GIT_CONFIG_VALUE_0",
                .value = try std.fmt.allocPrint(arena, "AUTHORIZATION: basic {s}", .{
                    enc.encode(b64, basic),
                }),
            },
        });
    }
    try extra.append(arena, .{ .name = "GIT_TERMINAL_PROMPT", .value = "0" });
    var out: Captured = .{ .arena = arena };
    const ended = try b.exec(
        aw.written(),
        try b.envStrings(extra.items),
        &.{},
        b.uid,
        b.gid,
        out.output(),
    );
    if (ended.code == 0 and ended.failure.len == 0) {
        f.result = .{ .dir = "native" };
        return f;
    }
    // The sandbox's own failure fails the step, as a fetch Dagger could not make does.
    const why = if (ended.failure.len > 0) ended.failure else out.tail();
    const msg = x.sh.redacted(arena, why) catch why;
    f.result = .{ .failed = try std.fmt.allocPrint(arena, "could not fetch {s}@{s}: {s}{s}", .{
        f.repo, f.ref_label, msg,
        if (checkout.looksLikeAuthFailure(msg)) " (the job's GITHUB_TOKEN reads only " ++
            "the job's own repository; another private one cannot be checked out)" else "",
    }) };
    return f;
}

/// The contents of `path` as the job's last step left it (a problem matcher's file); null when
/// it is not there.
pub fn readFile(b: *Backend, path: []const u8) ?[]const u8 {
    var i = b.layers.items.len;
    while (i > 0) {
        i -= 1;
        if (b.readLayerFile(b.layers.items[i], path) catch null) |text| return text;
    }
    const full = std.fmt.allocPrint(b.arena, "{s}/{s}", .{
        b.rootfs,
        std.mem.trimStart(u8, path, "/"),
    }) catch return null;
    return std.Io.Dir.cwd().readFileAlloc(b.io, full, b.arena, .limited(max_read)) catch null;
}

const max_read = 16 * 1024 * 1024;

fn readLayerFile(b: *Backend, layer: []const u8, path: []const u8) !?[]const u8 {
    const full = try std.fmt.allocPrint(b.arena, "{s}/{s}/{s}", .{
        b.dir,
        layer,
        std.mem.trimStart(u8, path, "/"),
    });
    return std.Io.Dir.cwd().readFileAlloc(b.io, full, b.arena, .limited(max_read)) catch |e|
        switch (e) {
            error.FileNotFound, error.NotDir, error.IsDir => null,
            else => e,
        };
}

/// `dagger.Transport` for the shared code: the native backend has no Dagger session, so a query
/// is a bug in what decided the job could run here (`unsupported`).
pub fn transport(b: *Backend) dagger.Transport {
    return .{ .ptr = b, .sendFn = send, .abortFn = abort };
}

fn send(ptr: *anyopaque, arena: Allocator, doc: []const u8, limit: usize) anyerror![]const u8 {
    _ = .{ ptr, arena, doc, limit };
    return error.NativeBackendHasNoDaggerSession;
}

/// Stops the running step (`dagger.Watch`, for a timeout or a cancel).
fn abort(ptr: *anyopaque) bool {
    const b: *Backend = @ptrCast(@alignCast(ptr));
    return b.running.kill(b.io);
}

/// Runs one script on a new layer over the others, which it joins when it ends.
fn exec(
    b: *Backend,
    script: []const u8,
    env: []const []const u8,
    files: []const sandbox.Spec.File,
    uid: u32,
    gid: u32,
    out: sandbox.Output,
) !sandbox.Ended {
    const arena = b.arena;
    if (b.layers.items.len >= max_layers) return .{
        .code = 1,
        .failure = "the job has more layers than overlay can stack (phase 2 flattens them)",
    };
    const upper = try std.fmt.allocPrint(arena, "L{d}", .{b.layers.items.len});
    try std.Io.Dir.cwd().createDirPath(b.io, try std.fmt.allocPrint(arena, "{s}/{s}", .{
        b.dir,
        upper,
    }));
    const lowers = try arena.alloc([]const u8, b.layers.items.len + 1);
    for (b.layers.items, 0..) |l, i| lowers[b.layers.items.len - 1 - i] = l;
    lowers[b.layers.items.len] = b.rootfs;
    const ended = try sandbox.run(arena, b.io, b.how.argv_prefix, .{
        .root = b.dir,
        .lowers = lowers,
        .upper = upper,
        .work = "W",
        .merged = "M",
        .workdir = b.workdir,
        .uid = uid,
        .gid = gid,
        .argv = &.{ "sh", "-c", script },
        .env = env,
        .files = files,
        .binds = b.binds,
        .userns = b.how.userns,
    }, &b.running, out);
    try b.layers.append(arena, upper);
    return ended;
}

fn put(b: *Backend, name: []const u8, value: []const u8) !void {
    try Evaluator.putEnv(b.arena, &b.env, name, value);
}

/// What `Exec.writePendingEnv` adds to Dagger's container before a step: the variables and PATH
/// entries the steps before it asked for (`GITHUB_ENV`, `GITHUB_PATH`), then forgotten. A PATH
/// set through GITHUB_ENV gets every GITHUB_PATH directory in front, as GitHub's runner puts
/// them; otherwise the new directories go in front of the container's PATH.
fn applyPendingEnv(b: *Backend, x: *Exec) !void {
    const ev = x.ev;
    var path_set = false;
    for (ev.pending_env.items) |e| {
        const path = std.mem.eql(u8, e.name, "PATH") and ev.path_prepend.items.len > 0;
        const value = if (path) try std.fmt.allocPrint(b.arena, "{s}:{s}", .{
            try Evaluator.prependPath(b.arena, ev.path_prepend.items),
            e.value,
        }) else e.value;
        path_set = path_set or path;
        try b.put(e.name, value);
    }
    if (ev.pending_path.items.len > 0 and !path_set) {
        const current = for (b.env.items) |e| {
            if (std.mem.eql(u8, e.name, "PATH")) break e.value;
        } else "";
        try b.put("PATH", try std.fmt.allocPrint(b.arena, "{s}:{s}", .{
            try Evaluator.prependPath(b.arena, ev.pending_path.items),
            current,
        }));
    }
    ev.pending_env.clearRetainingCapacity();
    ev.pending_path.clearRetainingCapacity();
}

/// The container's environment and `extra` as `NAME=value`, `extra` winning.
fn envStrings(b: *Backend, extra: []const job_mod.EnvVar) ![]const []const u8 {
    var all: std.ArrayList(job_mod.EnvVar) = .empty;
    try all.appendSlice(b.arena, b.env.items);
    for (extra) |e| try Evaluator.putEnv(b.arena, &all, e.name, e.value);
    const out = try b.arena.alloc([]const u8, all.items.len);
    for (all.items, out) |e, *o| o.* = try std.fmt.allocPrint(b.arena, "{s}={s}", .{
        e.name,
        e.value,
    });
    return out;
}

/// A secret's value from its id. On this backend `Secrets` registers values without a session
/// (`Secrets.local`), so the id is only a name for the value.
fn plaintext(x: *Exec, id: []const u8) []const u8 {
    var it = x.secrets.ids.iterator();
    while (it.next()) |e| if (std.mem.eql(u8, e.value_ptr.*, id)) return e.key_ptr.*;
    return "";
}

/// A step's output fed to the job's log as Dagger's log stream feeds it: one span per exec.
const Live = struct {
    demux: *SpanDemux,

    fn output(l: *Live) sandbox.Output {
        return .{ .ptr = l, .chunkFn = chunk };
    }

    fn chunk(ptr: *anyopaque, bytes: []const u8) void {
        const l: *Live = @ptrCast(@alignCast(ptr));
        SpanDemux.onRecord(l.demux, .{ .span = "native", .stream = 1, .text = bytes });
    }
};

/// The output of an exec that is not a step's (the base, a checkout's fetch), kept for the
/// reason when it fails: its last lines.
const Captured = struct {
    arena: Allocator,
    text: std.ArrayList(u8) = .empty,

    const keep = 4096;

    fn output(c: *Captured) sandbox.Output {
        return .{ .ptr = c, .chunkFn = chunk };
    }

    fn chunk(ptr: *anyopaque, bytes: []const u8) void {
        const c: *Captured = @ptrCast(@alignCast(ptr));
        c.text.appendSlice(c.arena, bytes) catch return;
        if (c.text.items.len > 2 * keep)
            c.text.replaceRangeAssumeCapacity(0, c.text.items.len - keep, &.{});
    }

    fn tail(c: *const Captured) []const u8 {
        const t = std.mem.trim(u8, c.text.items, " \n");
        const last = std.mem.lastIndexOfScalar(u8, t, '\n') orelse return t;
        return t[last + 1 ..];
    }
};

// --- tests ---

const sink = @import("../sink.zig");
const testStep = @import("../dagger/testing.zig").testStep;
const testJob = @import("../dagger/testing.zig").testJob;
const FakeSession = @import("../dagger/testing.zig").FakeSession;
const fake_child = @import("../dagger/testing.zig").fake_child;
const base_answer = @import("../dagger/testing.zig").base_answer;
const execAnswer = @import("../dagger/testing.zig").exec;

/// A native backend for tests, or `error.SkipZigTest` with the reason printed when this machine
/// cannot run one: a rootfs of a few directories with the host's /usr bound over it, in the
/// test's directory, and the runner binary the build copied for the tests (`ZIG_RUNNER_TEST_EXE`).
fn testConfig(arena: Allocator, tmp: *std.testing.TmpDir) !Config {
    const io = std.testing.io;
    var env = try std.testing.environ.createMap(arena);
    const exe_rel = env.get("ZIG_RUNNER_TEST_EXE") orelse
        return skip("ZIG_RUNNER_TEST_EXE is not set (`zig build test` sets it)");
    const exe = std.Io.Dir.cwd().realPathFileAlloc(io, exe_rel, arena) catch
        return skip("the runner binary for native steps is not built");
    const d = tmp.dir;
    const dirs = [_][]const u8{
        "rootfs/etc", "rootfs/usr",  "rootfs/tmp",  "rootfs/dev", "rootfs/proc",
        "rootfs/sys", "rootfs/root", "rootfs/home", "store",
    };
    for (dirs) |p| try d.createDirPath(io, p);
    const links = [_][2][]const u8{
        .{ "usr/bin", "bin" }, .{ "usr/sbin", "sbin" },
        .{ "usr/lib", "lib" }, .{ "usr/lib64", "lib64" },
    };
    for (links) |l|
        try d.symLink(io, l[0], try std.fmt.allocPrint(arena, "rootfs/{s}", .{l[1]}), .{});
    try d.writeFile(io, .{
        .sub_path = "rootfs/etc/passwd",
        .data = "root:x:0:0:root:/root:/bin/bash\n",
    });
    for ([_][]const u8{ "hosts", "resolv.conf", "ld.so.cache" }) |f| try d.writeFile(io, .{
        .sub_path = try std.fmt.allocPrint(arena, "rootfs/etc/{s}", .{f}),
        .data = "",
    });
    const root = try d.realPathFileAlloc(io, ".", arena);
    const cfg: Config = .{
        .rootfs = try std.fmt.allocPrint(arena, "{s}/rootfs", .{root}),
        .store = try std.fmt.allocPrint(arena, "{s}/store", .{root}),
        .self_exe = exe,
        .local = true,
        .binds = &.{
            .{ .host = "/usr", .at = "/usr" },
            .{ .host = "/etc/ld.so.cache", .at = "/etc/ld.so.cache" },
        },
    };
    // One sandbox, to see whether this machine lets us make them at all.
    var b = try init(arena, io, std.testing.allocator, cfg);
    defer b.deinit();
    var out: Captured = .{ .arena = arena };
    const ended = try b.exec("true", &.{"PATH=/usr/bin"}, &.{}, 0, 0, out.output());
    if (ended.failure.len > 0 or ended.code != 0)
        return skip(try std.fmt.allocPrint(arena, "this machine cannot make a native step's " ++
            "sandbox ({s}, exit {d})", .{ ended.failure, ended.code }));
    return cfg;
}

fn skip(why: []const u8) error{SkipZigTest} {
    std.debug.print("native backend test skipped: {s}\n", .{why});
    return error.SkipZigTest;
}

test "a run-only job on the native backend: file commands, masks, exit codes and conditions" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cfg = try testConfig(arena, &tmp);

    var s1 = testStep("echo hello; echo FOO=bar >> $GITHUB_ENV; echo out=42 >> $GITHUB_OUTPUT\n" ++
        "echo /opt/x >> $GITHUB_PATH; echo ::add-mask::s3cr3t-value; echo the s3cr3t-value\n" ++
        "echo '# summary' >> $GITHUB_STEP_SUMMARY; echo to stderr >&2; whoami; pwd");
    s1.context_name = "first";
    var s2 = testStep("echo FOO=$FOO; echo PATH=$PATH; echo OUT=$OUT; " ++
        "test -e /tmp/zig-runner-step-1.sh && echo leftover || echo no script left; exit 3");
    s2.env = &.{.{ .name = "OUT", .value = .{ .expr = "steps.first.outputs.out" } }};
    var s3 = testStep("echo not reached");
    s3.name = "skipped";
    var s4 = testStep("echo always; echo HOME=$HOME");
    s4.condition = "always()";
    var s5 = testStep("exit 1");
    s5.condition = "always()";
    s5.continue_on_error = .{ .lit = "true" };
    const job = testJob(&.{ s1, s2, s3, s4, s5 });

    var env: std.process.Environ.Map = .init(arena);
    var w: std.Io.Writer.Allocating = .init(arena);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w.writer } };
    const res = try dagger.run(arena, std.testing.io, &env, .{
        .native = cfg,
        .step_user = .root,
        .gpa = std.testing.allocator,
    }, job, &log);
    const text = w.written();

    try std.testing.expectEqual(dagger.Outcome.success, res.steps[0].outcome);
    try std.testing.expectEqual(dagger.Outcome.failure, res.steps[1].outcome);
    try std.testing.expectEqual(@as(i32, 3), res.steps[1].exit_code);
    try std.testing.expectEqual(dagger.Outcome.skipped, res.steps[2].outcome);
    try std.testing.expectEqual(dagger.Outcome.success, res.steps[3].outcome);
    try std.testing.expectEqual(dagger.Outcome.failure, res.steps[4].outcome);
    try std.testing.expect(res.steps[4].continued);
    try std.testing.expect(!res.succeeded);
    const expect = [_][]const u8{
        "Engine: native",
        "hello",
        // The mask applies from the line after it, as on Dagger.
        "the ***",
        // stderr is the step's stdout (`scripts.stream_prologue`).
        "to stderr",
        "root",
        "/home/runner/work/r/r",
        "FOO=bar",
        "PATH=/opt/x:/usr/local/sbin:",
        "OUT=42",
        "no script left",
        "##[error]Process completed with exit code 3.",
        "always",
        "HOME=/root",
    };
    for (expect) |e| if (std.mem.indexOf(u8, text, e) == null) {
        std.debug.print("missing {s} in:\n{s}\n", .{ e, text });
        return error.TestUnexpectedResult;
    };
    // The script's own text, logged before the mask, has it; its output does not.
    try std.testing.expect(std.mem.indexOf(u8, text, "stdout] the s3cr3t-value") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "not reached") == null);
    try std.testing.expectEqualStrings("# summary\n", res.summaries[0]);
    // The job's layers went with it.
    const jobs_path = try std.fmt.allocPrint(arena, "{s}/jobs", .{cfg.store});
    var jobs = try std.Io.Dir.cwd().openDir(std.testing.io, jobs_path, .{ .iterate = true });
    defer jobs.close(std.testing.io);
    var it = jobs.iterate();
    try std.testing.expect(try it.next(std.testing.io) == null);
}

test "a cancel stops a native step at once, and every process it started" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cfg = try testConfig(arena, &tmp);

    var s1 = testStep("sleep 60 & sleep 60");
    s1.name = "long";
    var s2 = testStep("echo after");
    s2.condition = "always()";
    const job = testJob(&.{ s1, s2 });
    var cancel: dagger.Cancel = .{};
    var env: std.process.Environ.Map = .init(arena);
    var w: std.Io.Writer.Allocating = .init(arena);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w.writer } };
    const io = std.testing.io;
    var canceller = try io.concurrent(cancelSoon, .{ io, &cancel });
    defer canceller.cancel(io);
    const started = std.Io.Clock.awake.now(io).toMilliseconds();
    const res = try dagger.run(arena, io, &env, .{
        .native = cfg,
        .step_user = .root,
        .gpa = std.testing.allocator,
        .cancel = &cancel,
    }, job, &log);
    const took = std.Io.Clock.awake.now(io).toMilliseconds() - started;
    try std.testing.expectEqual(dagger.Outcome.cancelled, res.steps[0].outcome);
    try std.testing.expectEqual(dagger.Outcome.success, res.steps[1].outcome);
    try std.testing.expect(res.cancelled);
    // The backgrounded `sleep 60` went with the step: its pipe closed, so the job went on.
    try std.testing.expect(took < 10_000);
}

fn cancelSoon(io: std.Io, cancel: *dagger.Cancel) void {
    io.sleep(.fromMilliseconds(500), .awake) catch return;
    cancel.request(std.Io.Clock.real.now(io).toMilliseconds() + 60_000);
}

test "unsupported: what sends a job to Dagger, and the first reason given" {
    const io = std.testing.io;
    const ok: Config = .{
        .rootfs = "/",
        .store = "/tmp/x",
        .self_exe = "/bin/true",
        .local = true,
    };
    const root: dagger.Options = .{ .step_user = .root };
    const run_only = testJob(&.{testStep("true")});
    try std.testing.expect(unsupported(io, run_only, root, ok) == null);

    var co = testStep("");
    co.action = .{ .checkout = &.{} };
    try std.testing.expect(unsupported(io, testJob(&.{co}), root, ok) == null);
    co.action = .{ .checkout = &.{.{ .name = "submodules", .value = .{ .lit = "true" } }} };
    try expectReason("submodules", unsupported(io, testJob(&.{co}), root, ok));

    var uses = testStep("");
    uses.action = .{ .uses = .{ .owner = "actions", .name = "setup-node", .ref = "v4" } };
    try expectReason("`uses:`", unsupported(io, testJob(&.{uses}), root, ok));

    var services = run_only;
    services.services = &.{.{ .name = "pg", .image = .{ .lit = "postgres" } }};
    try expectReason("`services:`", unsupported(io, services, root, ok));
    var container = run_only;
    container.container = .{ .name = "", .image = .{ .lit = "node:22" } };
    try expectReason("`container:`", unsupported(io, container, root, ok));

    var custom = root;
    custom.image = "alpine:3";
    try expectReason("default image", unsupported(io, run_only, custom, ok));
    var nesting = root;
    nesting.nesting = true;
    try expectReason("Dagger engine", unsupported(io, run_only, nesting, ok));

    var remote = ok;
    remote.local = false;
    try expectReason("vouches", unsupported(io, run_only, root, remote));
    var trusted = root;
    trusted.trusted = true;
    try std.testing.expect(unsupported(io, run_only, trusted, remote) == null);

    var no_rootfs = ok;
    no_rootfs.rootfs = "";
    try expectReason("RUNNER_NATIVE_ROOTFS", unsupported(io, run_only, root, no_rootfs));
    no_rootfs.rootfs = "/nonexistent/rootfs";
    try expectReason("cannot be read", unsupported(io, run_only, root, no_rootfs));

    // Steps as the runner user need ids a rootless runner cannot map.
    const as_runner: dagger.Options = .{ .step_user = .runner };
    const why = unsupported(io, run_only, as_runner, ok);
    if (std.os.linux.geteuid() == 0)
        try std.testing.expect(why == null)
    else
        try expectReason("runner user", why);
}

fn expectReason(part: []const u8, why: ?[]const u8) !void {
    const w = why orelse return error.TestExpectedReason;
    if (std.mem.indexOf(u8, w, part) == null) {
        std.debug.print("expected {s} in: {s}\n", .{ part, w });
        return error.TestUnexpectedResult;
    }
}

test "a job that cannot be native runs on Dagger, and Set up job says why" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);
    const answers = [_][]const u8{ base_answer, try execAnswer(arena, "C1", 0, "hi\\n") };
    var fake: FakeSession = .{ .answers = &answers, .arena = arena };
    var w: std.Io.Writer.Allocating = .init(arena);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w.writer } };
    const res = try dagger.run(arena, std.testing.io, &env, .{
        .test_session_argv = &.{ "sh", "-c", fake_child },
        .test_transport = fake.transport(),
        .native = .{ .local = true },
    }, testJob(&.{testStep("echo hi")}), &log);
    try std.testing.expectEqual(dagger.Outcome.success, res.steps[0].outcome);
    try std.testing.expect(std.mem.indexOf(u8, w.written(), "This job runs on Dagger: there " ++
        "is no native rootfs") != null);
    try std.testing.expect(std.mem.indexOf(u8, w.written(), "Engine: Dagger") != null);
}

test "parity: a native job's base has the environment of Dagger's base container" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var job = testJob(&.{testStep("true")});
    job.env = &.{
        .{ .name = "WORKFLOW_VAR", .value = .{ .lit = "w" } },
        .{ .name = "CI", .value = .{ .lit = "overridden" } },
    };
    var env: std.process.Environ.Map = .init(arena);
    var w: std.Io.Writer.Discarding = .init(&.{});
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w.writer } };
    for ([_]config.StepUser{ .root, .runner }) |user| {
        // Dagger's base container, the job's first query, with what `runNative` turns off off.
        const answers = [_][]const u8{ base_answer, try execAnswer(arena, "C1", 0, "") };
        var fake: FakeSession = .{ .answers = &answers, .arena = arena };
        _ = try dagger.run(arena, std.testing.io, &env, .{
            .test_session_argv = &.{ "sh", "-c", fake_child },
            .test_transport = fake.transport(),
            .test_step_mark = "m4rk",
            .step_user = user,
            .step_cache = false,
            .package_caches = false,
        }, job, &log);
        const doc = fake.seen.items[0];

        var ev = try Evaluator.init(arena, &job);
        var b: Backend = .{
            .arena = arena,
            .io = std.testing.io,
            .gpa = std.testing.allocator,
            .dir = "",
            .rootfs = "",
            .binds = &.{},
            .how = .{ .argv_prefix = &.{}, .userns = .none },
        };
        try b.baseEnv(&ev, .{ .as_runner = user == .runner, .mark = "m4rk" });
        // Every variable Dagger sets is set natively, to the same value...
        var dagger_names: std.StringHashMapUnmanaged(void) = .empty;
        var rest: []const u8 = doc;
        const call = "withEnvVariable(name:\"";
        while (std.mem.indexOf(u8, rest, call)) |i| {
            rest = rest[i + call.len ..];
            const name = rest[0..std.mem.indexOfScalar(u8, rest, '"').?];
            try dagger_names.put(arena, name, {});
            const native = for (b.env.items) |e| {
                if (std.mem.eql(u8, e.name, name)) break e.value;
            } else {
                std.debug.print("{s} is in Dagger's base, not the native one\n", .{name});
                return error.TestUnexpectedResult;
            };
            const both = try std.fmt.allocPrint(arena, call ++ "{s}\",value:\"{s}\"", .{
                name,
                native,
            });
            if (std.mem.indexOf(u8, doc, both) == null) {
                std.debug.print("{s} is {s} natively, not Dagger's value\n", .{ name, native });
                return error.TestUnexpectedResult;
            }
        }
        // ...and nothing more but the image's PATH, which Dagger's container has from the image.
        try std.testing.expectEqual(dagger_names.count() + 1, b.env.items.len);
        try std.testing.expectEqualStrings("PATH", b.env.items[0].name);
        try std.testing.expectEqualStrings(ev.workspace, b.workdir);
        try std.testing.expectEqual(@as(u32, if (user == .runner) runner_uid else 0), b.uid);
    }
}

test "the native checkout: the commit, its .git, and the checkout's fixed time" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cfg = try testConfig(arena, &tmp);
    // A repository to fetch, at a file:// URL the steps see at the same path.
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const make = try std.fmt.allocPrint(arena, "set -e; cd '{s}'; git init -q --bare o/r.git; " ++
        "git init -q src; cd src; echo from-the-repo > file; git add file; " ++
        "git -c user.name=t -c user.email=t@t commit -q -m first; " ++
        "git push -q ../o/r.git HEAD:refs/heads/main", .{root});
    const made = std.process.run(arena, io, .{ .argv = &.{ "sh", "-c", make } }) catch
        return skip("git is not installed");
    if (made.term != .exited or made.term.exited != 0)
        return skip("git could not make a repository");
    try tmp.dir.createDirPath(io, try std.fmt.allocPrint(arena, "rootfs/{s}", .{root}));
    cfg.binds = try std.mem.concat(arena, sandbox.Spec.Bind, &.{
        cfg.binds,
        &.{.{ .host = root, .at = root }},
    });

    var co = testStep("");
    co.name = "checkout";
    co.action = .{ .checkout = &.{.{ .name = "ref", .value = .{ .lit = "main" } }} };
    const check = testStep("cat file; stat -c %Y file; git log -1 --format=%s; " ++
        "git rev-parse --abbrev-ref HEAD; git config remote.origin.url");
    var job = testJob(&.{ co, check });
    job.github.server_url = try std.fmt.allocPrint(arena, "file://{s}", .{root});
    var env: std.process.Environ.Map = .init(arena);
    var w: std.Io.Writer.Allocating = .init(arena);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w.writer } };
    const res = try dagger.run(arena, io, &env, .{
        .native = cfg,
        .step_user = .root,
        .gpa = std.testing.allocator,
    }, job, &log);
    const text = w.written();
    if (res.steps[0].outcome != .success or res.steps[1].outcome != .success) {
        std.debug.print("{s}\n", .{text});
        return error.TestUnexpectedResult;
    }
    const expect = [_][]const u8{
        "with git in the job's image",
        "Ref: main",
        "HEAD is detached at origin/main",
        "from-the-repo",
        "946684800",
        "first",
        // `checkout.refCommands` gave it the ref, as Dagger's checkout does.
        "HEAD",
        "/o/r.git",
    };
    for (expect) |e| if (std.mem.indexOf(u8, text, e) == null) {
        std.debug.print("missing {s} in:\n{s}\n", .{ e, text });
        return error.TestUnexpectedResult;
    };
}

test "a native checkout that cannot fetch fails its step with why" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cfg = try testConfig(arena, &tmp);
    var co = testStep("");
    co.action = .{ .checkout = &.{} };
    var job = testJob(&.{co});
    job.github.server_url = "file:///nonexistent";
    var env: std.process.Environ.Map = .init(arena);
    var w: std.Io.Writer.Allocating = .init(arena);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w.writer } };
    const res = try dagger.run(arena, std.testing.io, &env, .{
        .native = cfg,
        .step_user = .root,
        .gpa = std.testing.allocator,
    }, job, &log);
    try std.testing.expectEqual(dagger.Outcome.failure, res.steps[0].outcome);
    try std.testing.expect(std.mem.indexOf(u8, w.written(), "could not fetch o/r@0123456") != null);
}

test "parity: a run-only job gives the same results and step output on Dagger and native" {
    // Needs a Dagger engine (`dagger` on PATH) and a provisioned rootfs, so it runs only when
    // asked for: ZIG_RUNNER_PARITY_ROOTFS=<dir>. Not on CI, which has neither.
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const io = std.testing.io;
    var env = try std.testing.environ.createMap(arena);
    const rootfs = env.get("ZIG_RUNNER_PARITY_ROOTFS") orelse return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cfg = try testConfig(arena, &tmp);
    cfg.rootfs = rootfs;
    cfg.binds = &.{};

    var s1 = testStep("echo a; echo K=v >> $GITHUB_ENV; echo o=1 >> $GITHUB_OUTPUT; " ++
        "echo /opt/p >> $GITHUB_PATH; echo ::add-mask::hidden-value; echo hidden-value; " ++
        "id -u; echo HOME=$HOME; pwd; ls /github; echo e >&2");
    s1.context_name = "one";
    var s2 = testStep("echo K=$K PATH=$PATH O=$O; env | grep -c ^GITHUB_ ; exit 2");
    s2.env = &.{.{ .name = "O", .value = .{ .expr = "steps.one.outputs.o" } }};
    var s3 = testStep("echo always");
    s3.condition = "always()";
    const job = testJob(&.{ s1, s2, s3 });
    const common: dagger.Options = .{
        .step_user = .root,
        .step_cache = false,
        .package_caches = false,
        .gpa = std.testing.allocator,
        .test_step_mark = "parity",
    };
    var outs: [2][]const []const u8 = undefined;
    var results: [2]dagger.Result = undefined;
    for (0..2) |i| {
        var opts = common;
        if (i == 1) opts.native = cfg;
        var w: std.Io.Writer.Allocating = .init(arena);
        var log: sink.LogSink = .{ .stdout = .{ .writer = &w.writer } };
        results[i] = try dagger.run(arena, io, &env, opts, job, &log);
        outs[i] = try stepLines(arena, w.written());
    }
    for (results[0].steps, results[1].steps) |d, n| {
        try std.testing.expectEqual(d.outcome, n.outcome);
        try std.testing.expectEqual(d.exit_code, n.exit_code);
    }
    try std.testing.expectEqual(outs[0].len, outs[1].len);
    for (outs[0], outs[1]) |d, n| try std.testing.expectEqualStrings(d, n);
}

/// The lines logged under the job's steps (not "Set up job"), as the console sink writes them.
fn stepLines(arena: Allocator, text: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |l| {
        if (std.mem.indexOf(u8, l, " step 0 ") != null) continue;
        try out.append(arena, l);
    }
    return out.items;
}
