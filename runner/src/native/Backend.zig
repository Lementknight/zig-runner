//! The native backend for one job: its steps run in sandboxes of the runner's own (`sandbox.zig`)
//! instead of Dagger execs, each on an overlay of the layers the steps before it left
//! (docs/native-backend.md).
//!
//! It sits below the step script. Everything above it is the code the Dagger backend runs:
//! `dagger.runSteps` evaluates conditions, env, timeouts and `continue-on-error`,
//! `scripts.stepScriptFc` writes the same `sh -c` script, `JobLog` reads the same markers and
//! workflow commands, and `Exec.collect` applies the same file commands. What this file owns is
//! what the engine did: the base the steps start from, the container's environment between
//! steps, running one script, reading its combined file commands back, and on a root runner the
//! job's ids and network (`net.zig`).

const Backend = @This();

const std = @import("std");
const job_mod = @import("../job.zig");
const config = @import("../config.zig");
const dagger = @import("../dagger.zig");
const sandbox = @import("sandbox.zig");
const net = @import("net.zig");
const Store = @import("Store.zig");
const Exec = @import("../dagger/Exec.zig");
const Evaluator = @import("../dagger/Evaluator.zig");
const SpanDemux = @import("../dagger/JobLog.zig").SpanDemux;
const checkout = @import("../dagger/checkout.zig");
const scripts = @import("../dagger/scripts.zig");
const set_up = @import("../dagger/set_up.zig");

const Allocator = std.mem.Allocator;

arena: Allocator,
io: std.Io,
/// Backs each exec's log demultiplexer (`SpanDemux`), as for a direct Dagger session.
gpa: Allocator,
/// The job's directory under the store: its layers (`L<n>`, and `l<n>` linking to the store's,
/// `F<n>` flattened), the overlay work directory, the mount points, its lock and its network
/// namespace. Removed when the job ends.
dir: []const u8,
rootfs: []const u8,
binds: []const sandbox.Spec.Bind,
/// Held while the job runs (`lock`): a directory whose lock is free is stale (`sweep`).
lock: std.Io.File,
/// The overlay's layers above the rootfs, oldest first.
layers: std.ArrayList(Layer) = .empty,
/// The number in the next layer's name (`L<n>`, `l<n>`, `F<n>`): never reused in a job, as a
/// flattened stack restarts the list.
next_layer: u32 = 0,
/// The layer store, under step caching (`Options.step_cache`, decided in `base`); null otherwise,
/// and the job's layers stay its own.
store: ?Store = null,
/// The store's settings, for `base` to turn it on.
store_cfg: Store = .{ .root = "" },
/// `Config.vouched`, and the job's cache scope and repository from it (`base`): a vouched fork's
/// pull request keys its layers apart from its repository's own jobs, as its package caches are
/// (`set_up.packageCacheScope`).
vouched: bool = false,
scope: []const u8 = "untrusted",
repository: []const u8 = "",
/// The store's layers the job uses, held shared until it ends (`Store.Layer`).
held: std.ArrayList(std.Io.File) = .empty,
/// Past this many layers, the stack is merged into one (`flatten`).
flatten_at: usize = default_flatten_at,
/// `abort` while an exec waits for its key's lock (`Store.lockKey`): the wait ends.
waiting: std.atomic.Value(bool) = .init(false),
stop_wait: std.atomic.Value(bool) = .init(false),
/// The container's environment: what Dagger's container held between execs (the image's, the
/// runner's defaults, the job's `env:`, and what `GITHUB_ENV` and `GITHUB_PATH` added).
env: std.ArrayList(job_mod.EnvVar) = .empty,
/// Who steps run as, and where they start.
uid: u32 = 0,
gid: u32 = 0,
workdir: []const u8 = "/",
how: Launch,
/// On a root runner: the job's slot (its range of ids and its address), held by a lock, and its
/// network namespace's file.
slot: ?Slot = null,
netns: ?[]const u8 = null,
/// `Config.subid_base`: the job's ids start at it plus its slot's offset (`idBase`).
subid_base: u32 = default_subid_base,
/// `Config.subnet`: the job's address is its slot's in it.
subnet: net.Subnet = .default,
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
    /// The runner vouches for the job (`trust.vouches`): native steps run only in such jobs.
    vouched: bool = false,
    /// Rootless native steps (`RUNNER_NATIVE_ROOTLESS`): only root is mapped inside, so apt's
    /// `_apt`, `chown` to other users and `tar` with owners fail, and steps share the host's
    /// network. Off: a rootless runner sends every job to Dagger.
    rootless: bool = false,
    /// The first host id of the jobs' ranges on a root runner (`RUNNER_NATIVE_SUBID_BASE`): slot
    /// n's 65536 ids start at `subid_base + n * 65536`.
    subid_base: u32 = default_subid_base,
    /// The jobs' network on a root runner (`RUNNER_NATIVE_SUBNET`). The bridge is the host's, so
    /// every runner on a host must use the same one.
    subnet: net.Subnet = .default,
    /// Host paths mounted into every step. Tests bind the host's /usr into a rootfs of a few
    /// directories; phase 4's cache volumes will be these.
    binds: []const sandbox.Spec.Bind = &.{},
    /// Past this many bytes, the store's least recently used layers go
    /// (`RUNNER_NATIVE_STORE_MAX_MB`, `Store.collect`).
    store_max_bytes: u64 = Store.default_max_bytes,
    /// Tests: the stack of layers is flattened past this many (`flatten`).
    flatten_at: usize = default_flatten_at,
    /// Tests: `init` fails once the job's lock is the Backend's, as a failed network does.
    test_fail_after_lock: bool = false,
};

/// One layer of the job's overlay.
pub const Layer = struct {
    /// Its name in the job's directory, as overlay's `lowerdir=` takes it (`Spec.lowers`): short
    /// however long the store's path, so a hundred layers keep the mount's options under a page.
    name: []const u8,
    /// Where it is, for the runner's reads (`readFile`): in the job's directory, or the store's.
    path: []const u8,
    /// The key of the state the stack up to this layer is (`keyFor`), when it is in the store:
    /// replayed from it or published to it. Only a stored layer's key is a parent's.
    key: ?Store.Key = null,
};

/// Past systemd's ranges: its containers' (systemd-nspawn's private users and nsresourced's,
/// 524288 to 1879048191) end below it, and its foreign range (2147352576 onwards) starts above
/// the last slot's ids (1916383999), which stay below 2^31 for tools that take ids as signed.
pub const default_subid_base: u32 = 1_900_000_000;
/// Every id below it may be a host user's or group's (`useradd` gives up to 60000, and LDAP or
/// SSSD ranges commonly start at 10000 or 100000).
pub const min_subid_base: u32 = 100_000;
/// The ids each job has on a root runner: 0 to 65535, as an image expects.
pub const ids_per_slot: u32 = 65536;

/// The native backend's settings from the runner's, or null when it runs steps on Dagger alone.
pub fn configFor(
    arena: Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    cfg: *const config.Config,
    vouched: bool,
) !?Config {
    if (cfg.backend != .native) return null;
    return .{
        .rootfs = cfg.native_rootfs,
        .store = try cfg.nativeStore(arena, environ),
        .self_exe = std.process.executablePathAlloc(io, arena) catch "",
        .vouched = vouched,
        .rootless = cfg.native_rootless,
        .subid_base = cfg.native_subid_base,
        .subnet = try net.Subnet.parse(cfg.native_subnet),
        .store_max_bytes = cfg.native_store_max_mb * 1024 * 1024,
    };
}

/// How sandboxes are started on this machine (`launch`).
pub const Launch = struct {
    argv_prefix: []const []const u8,
    userns: sandbox.Userns,
};

/// A job's slot on a root runner: its number and the lock that holds it.
pub const Slot = struct { n: u32, lock: std.Io.File };

/// The default image's own environment (`ubuntu:24.04`'s config): P3's pull reads it from the
/// image instead.
const image_path = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";
/// `runner_user`'s ids in the provisioned image (`set_up.provision_runner_script`).
const runner_uid = 1001;
/// Overlay takes at most 500 lower layers, and its options one page: past this many, the stack
/// is merged into one layer (`flatten`), which costs directories and hard links.
pub const default_flatten_at = 100;

/// Why this job cannot run natively yet, or null when it can: the first thing it uses that the
/// native backend does not do yet (docs/native-backend.md, "Phases"). Decided before anything
/// runs, for the whole job: native and Dagger never share one. What this machine can do is
/// `usable`'s.
pub fn unsupported(io: std.Io, job: job_mod.Job, opts: dagger.Options, cfg: Config) ?[]const u8 {
    if (cfg.rootfs.len == 0) return "there is no native rootfs (RUNNER_NATIVE_ROOTFS; the " ++
        "native image pull is phase 3)";
    std.Io.Dir.accessAbsolute(io, cfg.rootfs, .{}) catch
        return "the native rootfs (RUNNER_NATIVE_ROOTFS) cannot be read";
    if (cfg.self_exe.len == 0 or cfg.store.len == 0) return "the native store is not set up";
    if (!cfg.vouched) return "native steps run only in jobs this runner vouches for " ++
        "(RUNNER_TRUSTED_REFS)";
    if (std.os.linux.geteuid() != 0 and !cfg.rootless) return "the runner is not root, and " ++
        "rootless native steps have only one id mapped (RUNNER_NATIVE_ROOTLESS=1 runs them " ++
        "anyway; subordinate ids are phase 5's)";
    if (job.container != null) return "`container:` jobs are not native yet (phase 3)";
    if (job.services.len > 0) return "`services:` are not native yet (phase 6)";
    // The pinned default image (`dagger.resolveImage`), which the rootfs must be made from.
    if (!std.mem.eql(u8, dagger.resolveImage(opts.image), dagger.default_image) or !opts.provision)
        return "only the default image is native yet (phase 3)";
    if (opts.nesting) return "steps that use the Dagger engine (RUNNER_DAGGER_NESTING) need Dagger";
    if (usesHashFiles(job)) return "`hashFiles()` reads the job's container through Dagger";
    const as_runner = opts.step_user == .runner;
    if (as_runner and std.os.linux.geteuid() != 0) return "steps run as the runner user need a " ++
        "range of ids, which a rootless runner does not have (RUNNER_STEP_USER=root, or a root " ++
        "runner)";
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
    return null;
}

/// Whether any expression of the job calls `hashFiles` (function names are not case-sensitive).
fn usesHashFiles(job: job_mod.Job) bool {
    const call = "hashfiles(";
    for (job.env) |e| if (std.ascii.findIgnoreCase(templateText(e.value), call) != null)
        return true;
    for (job.outputs) |o| if (std.ascii.findIgnoreCase(templateText(o.value), call) != null)
        return true;
    if (job.environment.url) |u| if (std.ascii.findIgnoreCase(templateText(u), call) != null)
        return true;
    for (job.steps) |step| {
        const texts = [_][]const u8{
            step.condition,
            step.name_expr orelse "",
            templateText(step.continue_on_error),
            if (step.timeout_minutes) |t| templateText(t) else "",
        };
        for (texts) |t| if (std.ascii.findIgnoreCase(t, call) != null) return true;
        for (step.env) |e| if (std.ascii.findIgnoreCase(templateText(e.value), call) != null)
            return true;
        switch (step.action) {
            .script => |sc| {
                const more = [_]?job_mod.Template{ sc.script, sc.shell, sc.working_directory };
                for (more) |m| if (m) |t|
                    if (std.ascii.findIgnoreCase(templateText(t), call) != null) return true;
            },
            .checkout => |inputs| for (inputs) |in| {
                if (std.ascii.findIgnoreCase(templateText(in.value), call) != null) return true;
            },
            else => {},
        }
    }
    return false;
}

fn templateText(t: job_mod.Template) []const u8 {
    return switch (t) {
        .lit, .expr => |s| s,
    };
}

/// Whether this machine can run native steps, found with one sandbox; null when it can, else
/// why not, and every native job then runs on Dagger. A success holds for the process's life; a
/// failure is tried again once `probe_backoff_ms` have passed, so a machine that was not ready
/// (iptables locked, a module not loaded yet) does not keep native off until a restart. On a root
/// runner, it also makes the network's NAT rules (`net.natRules`) and checks the jobs' ids and
/// subnet against the host's.
pub fn usable(arena: Allocator, io: std.Io, gpa: Allocator, cfg: Config) ?[]const u8 {
    probe_mu.lockUncancelable(io);
    defer probe_mu.unlock(io);
    const now = std.Io.Clock.awake.now(io).toMilliseconds();
    if (probe_cache.fresh(now)) return probe_cache.why();
    const why = probe(arena, io, gpa, cfg) catch |e| @errorName(e);
    return probe_cache.store(now, why);
}

var probe_mu: std.Io.Mutex = .init;
var probe_cache: ProbeCache = .{};
pub const probe_backoff_ms = 5 * 60 * 1000;

/// The probe's last answer and when it was found (`usable`), kept in a buffer of its own since
/// the arena it came from is a job's.
const ProbeCache = struct {
    probed: bool = false,
    failed: bool = false,
    at_ms: i64 = 0,
    buf: [1024]u8 = undefined,
    len: usize = 0,

    /// Whether the last answer stands without probing again: a success always, a failure within
    /// its back-off.
    fn fresh(c: *const ProbeCache, now_ms: i64) bool {
        return c.probed and (!c.failed or now_ms - c.at_ms < probe_backoff_ms);
    }

    /// Null for "usable", else why not.
    fn why(c: *const ProbeCache) ?[]const u8 {
        return if (c.failed) c.buf[0..c.len] else null;
    }

    fn store(c: *ProbeCache, now_ms: i64, answer: ?[]const u8) ?[]const u8 {
        c.probed = true;
        c.failed = answer != null;
        c.at_ms = now_ms;
        const text: []const u8 = answer orelse "";
        c.len = @min(text.len, c.buf.len);
        @memcpy(c.buf[0..c.len], text[0..c.len]);
        return c.why();
    }
};

fn probe(arena: Allocator, io: std.Io, gpa: Allocator, cfg: Config) !?[]const u8 {
    if (std.os.linux.geteuid() == 0) {
        if (try idsClash(arena, io, cfg.subid_base, host_id_files)) |why| return why;
        if (try net.subnetClash(arena, io, cfg.subnet)) |why| return why;
        if (try natRulesFor(arena, io, cfg.subnet, true)) |why| return why;
    }
    var b = try init(arena, io, gpa, cfg);
    defer b.deinit();
    var out: Captured = .{ .arena = arena };
    const ended = try b.exec("true", &.{"PATH=/usr/bin:/bin"}, &.{}, 0, 0, out.output());
    if (ended.failure.len > 0 or ended.code != 0) return try std.fmt.allocPrint(
        arena,
        "this machine cannot make a native step's sandbox ({s}, exit {d})",
        .{ ended.failure, ended.code },
    );
    return null;
}

/// The NAT rules for the host's uplinks now, remembered so a job finds out cheaply whether the
/// uplinks changed since (a laptop moving from cable to Wi-Fi), and makes the new ones' rules
/// (`jobNetwork`). With no default route, the probe fails, and a job goes on without the rules:
/// it has no way out, as the host has none.
fn natRulesFor(arena: Allocator, io: std.Io, subnet: net.Subnet, probing: bool) !?[]const u8 {
    const ups = try net.uplinks(arena, io);
    if (ups.len == 0 and !probing) return null;
    const joined = try std.mem.join(arena, "\x00", ups);
    rules_mu.lockUncancelable(io);
    defer rules_mu.unlock(io);
    if (ups.len > 0 and std.mem.eql(u8, joined, rules_for[0..rules_len])) return null;
    if (try net.natRules(arena, io, subnet, ups)) |why| return why;
    // Too long to keep: the rules are checked again (`iptables -C`) next time.
    rules_len = if (joined.len <= rules_for.len) joined.len else 0;
    @memcpy(rules_for[0..rules_len], joined[0..rules_len]);
    return null;
}

var rules_mu: std.Io.Mutex = .init;
/// The uplinks the rules were made for, joined by zero bytes.
var rules_for: [256]u8 = undefined;
var rules_len: usize = 0;

/// The host's files that say which ids are taken (`idsClash`).
pub const IdFiles = struct {
    subuid: []const u8,
    subgid: []const u8,
    passwd: []const u8,
    group: []const u8,
};

pub const host_id_files: IdFiles = .{
    .subuid = "/etc/subuid",
    .subgid = "/etc/subgid",
    .passwd = "/etc/passwd",
    .group = "/etc/group",
};

/// Why the jobs' ranges of ids (`first` onwards, `ids_per_slot` per slot) cannot be used: below
/// `min_subid_base`, past 2^32, given to someone in /etc/subuid or /etc/subgid (a rootless
/// container runtime's range), or holding a user's or a group's id from /etc/passwd or
/// /etc/group. A job's root would then share host ids with them. Users only a directory service
/// knows (LDAP, SSSD) are not seen: `min_subid_base` is above their usual ranges. Null when none
/// of that is so.
pub fn idsClash(arena: Allocator, io: std.Io, first: u32, files: IdFiles) !?[]const u8 {
    if (first < min_subid_base) return try std.fmt.allocPrint(
        arena,
        "RUNNER_NATIVE_SUBID_BASE ({d}) is below {d}, where the host's own users and groups are",
        .{ first, min_subid_base },
    );
    const end = @as(u64, first) + @as(u64, ids_per_slot) * net.max_slots;
    if (end > std.math.maxInt(u32)) return "RUNNER_NATIVE_SUBID_BASE leaves no room for the " ++
        "jobs' ids below 2^32";
    const cwd = std.Io.Dir.cwd();
    const ranges = [_][]const u8{ files.subuid, files.subgid };
    for (ranges) |path| {
        const text = cwd.readFileAlloc(io, path, arena, .limited(1 << 20)) catch continue;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            var f = std.mem.splitScalar(u8, line, ':');
            const user = f.next() orelse continue;
            const start = std.fmt.parseInt(u64, f.next() orelse continue, 10) catch continue;
            const count = std.fmt.parseInt(u64, f.next() orelse continue, 10) catch continue;
            if (start < end and first < start + count) return try std.fmt.allocPrint(
                arena,
                "the jobs' ids ({d}-{d}, RUNNER_NATIVE_SUBID_BASE) overlap {s}'s in {s}",
                .{ first, end - 1, user, path },
            );
        }
    }
    const owners = [_][]const u8{ files.passwd, files.group };
    for (owners) |path| {
        const text = cwd.readFileAlloc(io, path, arena, .limited(16 << 20)) catch continue;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            var f = std.mem.splitScalar(u8, line, ':');
            const name = f.next() orelse continue;
            _ = f.next() orelse continue;
            const id = std.fmt.parseInt(u64, f.next() orelse continue, 10) catch continue;
            if (id >= first and id < end) return try std.fmt.allocPrint(arena, "the jobs' ids " ++
                "({d}-{d}, RUNNER_NATIVE_SUBID_BASE) hold {s}'s id {d} in {s}", .{
                first, end - 1, name, id, path,
            });
        }
    }
    return null;
}

/// How to start a sandbox here. As root, the helper maps the job's range itself. Rootless, it
/// makes a user namespace itself, unless the kernel lets only allow-listed programs do that
/// (Ubuntu's `apparmor_restrict_unprivileged_userns`), where it is started under util-linux's
/// `unshare`, which is on that list where its profile is installed.
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
    if (std.os.linux.geteuid() == 0) return .mapped;
    var buf: [8]u8 = undefined;
    const restricted = std.Io.Dir.cwd().readFile(
        io,
        "/proc/sys/kernel/apparmor_restrict_unprivileged_userns",
        &buf,
    ) catch "0";
    return if (std.mem.startsWith(u8, restricted, "1")) .inherited else .self;
}

/// A job's directory in the store, locked, and on a root runner its slot and network. Stale
/// directories (a runner that died) are removed first (`sweep`).
pub fn init(arena: Allocator, io: std.Io, gpa: Allocator, cfg: Config) !Backend {
    try Store.prepare(arena, io, cfg.store);
    sweep(arena, io, cfg.store);
    var raw: [8]u8 = undefined;
    io.random(&raw);
    const id = std.fmt.bytesToHex(raw, .lower);
    // Made under a name the sweep leaves alone, and renamed once it is locked.
    const new = try std.fmt.allocPrint(arena, "{s}/jobs/.new-{s}", .{ cfg.store, &id });
    const dir = try std.fmt.allocPrint(arena, "{s}/jobs/{s}", .{ cfg.store, &id });
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, new);
    // Until the lock is the Backend's, a failure removes the directory and closes the lock here;
    // from then on `deinit` does both, once.
    errdefer removeTree(arena, io, new);
    for ([_][]const u8{ "W", "M", sandbox.secrets_dir }) |d|
        try cwd.createDirPath(io, try std.fmt.allocPrint(arena, "{s}/{s}", .{ new, d }));
    const lock = try lockFile(arena, io, try std.fmt.allocPrint(arena, "{s}/lock", .{new}), true);
    const how = launch(arena, io, cfg) catch |e| {
        lock.close(io);
        return e;
    };
    cwd.rename(new, cwd, dir, io) catch |e| {
        lock.close(io);
        return e;
    };
    var b: Backend = .{
        .arena = arena,
        .io = io,
        .gpa = gpa,
        .dir = dir,
        .rootfs = cfg.rootfs,
        .binds = cfg.binds,
        .lock = lock,
        .how = how,
        .subid_base = cfg.subid_base,
        .subnet = cfg.subnet,
        .store_cfg = .{ .root = cfg.store, .max_bytes = cfg.store_max_bytes },
        .vouched = cfg.vouched,
        .flatten_at = @max(2, cfg.flatten_at),
    };
    errdefer b.deinit();
    if (cfg.test_fail_after_lock) return error.TestFailure;
    b.binds = try b.jobBinds(cfg);
    if (b.how.userns == .mapped) try b.jobNetwork(cfg);
    return b;
}

/// The host's resolver and hosts over the image's (over files the image has), and the
/// configured binds. On a root runner, the job's own network cannot reach a resolver on the
/// host's loopback (`net.resolvConf`).
fn jobBinds(b: *Backend, cfg: Config) ![]const sandbox.Spec.Bind {
    const resolv = if (b.how.userns == .mapped)
        net.resolvConf(b.arena, b.io) orelse return error.NoReachableResolver
    else
        "/etc/resolv.conf";
    return std.mem.concat(b.arena, sandbox.Spec.Bind, &.{ cfg.binds, &.{
        .{ .host = resolv, .at = "/etc/resolv.conf", .optional = true },
        .{ .host = "/etc/hosts", .at = "/etc/hosts", .optional = true },
    } });
}

/// A slot of its own (the first free one on the host, held by its lock, `net.slots_dir`), and
/// the job's network namespace on the runner's bridge (`net.zig`), made by a helper
/// (`net.command`), since a thread of the runner must not change its namespace.
fn jobNetwork(b: *Backend, cfg: Config) !void {
    const arena = b.arena;
    b.slot = try lockSlot(arena, b.io, net.slots_dir);
    const n = b.slot.?.n;
    // A veth of this slot is a dead job's: its runner let the lock go, by ending or dying. Only
    // the slot's holder removes it, so a live job's network is never touched.
    var sock = try net.Socket.open();
    sock.deleteVeth(n);
    sock.close();
    // The host's uplinks may have changed since the probe made their rules.
    if (try natRulesFor(arena, b.io, cfg.subnet, false)) |why| {
        std.log.warn("native: the jobs' NAT rules: {s}", .{why});
        return error.JobNetworkFailed;
    }
    const path = try std.fmt.allocPrint(arena, "{s}/netns", .{b.dir});
    const slot = try std.fmt.allocPrint(arena, "{d}", .{n});
    const subnet = try std.fmt.allocPrint(arena, "{f}", .{cfg.subnet});
    var child = try std.process.spawn(b.io, .{
        .argv = &.{ cfg.self_exe, net.command, path, slot, subnet },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .pipe,
    });
    var err: std.ArrayList(u8) = .empty;
    var buf: [4096]u8 = undefined;
    while (true) {
        const got = child.stderr.?.readStreaming(b.io, &.{&buf}) catch break;
        if (got == 0) break;
        try err.appendSlice(arena, buf[0..got]);
    }
    const term = try child.wait(b.io);
    b.netns = path;
    if (term != .exited or term.exited != 0) {
        std.log.warn("native: the job's network: {s}", .{std.mem.trim(u8, err.items, " \n")});
        return error.JobNetworkFailed;
    }
}

/// The first slot whose lock in `dir` no process holds, locked. The directory is made only
/// root's, so no other user can take a slot's lock. A lock file removed and made again while it
/// was being taken is not trusted: the lock is taken only on the file the path names.
fn lockSlot(arena: Allocator, io: std.Io, dir: []const u8) !Slot {
    const linux = std.os.linux;
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, std.fs.path.dirname(dir) orelse "/");
    const d = try arena.dupeSentinel(u8, dir, 0);
    _ = linux.mkdir(d, 0o700);
    if (linux.errno(linux.chmod(d, 0o700)) != .SUCCESS) return error.SlotsDirectory;
    for (0..net.max_slots) |n| {
        const path = try std.fmt.allocPrint(arena, "{s}/{d}.lock", .{ dir, n });
        const lock = lockFile(arena, io, path, false) catch continue;
        if (!sameFile(arena, lock, path)) {
            lock.close(io);
            continue;
        }
        return .{ .n = @intCast(n), .lock = lock };
    }
    return error.NoFreeSlot;
}

const sameFile = Store.sameFile;

/// What "Set up job" says of the job's ids and network: a range of its own and a network of its
/// own on a root runner; only root, and the host's network, rootless.
pub fn idsNote(b: *const Backend, arena: Allocator) ![]const u8 {
    if (b.how.userns != .mapped) return "Native steps, rootless: only root is mapped inside " ++
        "(apt's _apt user, chown to other users and tar with owners fail), and steps share the " ++
        "host's network.";
    const addr = b.subnet.jobAddress(b.slot.?.n);
    return std.fmt.allocPrint(arena, "Native steps: ids 0-65535 are host ids {d}-{d}, and the " ++
        "job's network is its own ({d}.{d}.{d}.{d} on {s}).", .{
        b.idBase(),
        b.idBase() + ids_per_slot - 1,
        addr[0],
        addr[1],
        addr[2],
        addr[3],
        net.bridge,
    });
}

/// The first of the 65536 host ids the job's slot maps.
fn idBase(b: *const Backend) u32 {
    return b.subid_base + (if (b.slot) |s| s.n else 0) * ids_per_slot;
}

/// An exclusive lock on `path`: waited for (`wait`), or `error.Locked` at once.
fn lockFile(arena: Allocator, io: std.Io, path: []const u8, wait: bool) !std.Io.File {
    _ = arena;
    const f = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = false });
    const lock_ex: i32 = 2;
    const lock_nb: i32 = 4;
    const rc = std.os.linux.flock(f.handle, lock_ex | (if (wait) 0 else lock_nb));
    if (std.os.linux.errno(rc) != .SUCCESS) {
        f.close(io);
        return error.Locked;
    }
    return f;
}

/// The job's network taken down, its layers removed, its slot and lock let go.
pub fn deinit(b: *Backend) void {
    const arena = b.arena;
    if (b.slot) |s| {
        var sock = net.Socket.open() catch null;
        if (sock) |*so| {
            so.deleteVeth(s.n);
            so.close();
        }
    }
    if (b.netns) |p| detachNetns(arena, p);
    removeTree(arena, b.io, b.dir);
    for (b.held.items) |f| f.close(b.io);
    if (b.slot) |s| s.lock.close(b.io);
    b.lock.close(b.io);
    // The store kept under its cap, now that this job holds none of its layers.
    if (b.store) |s| s.collect(arena, b.io);
}

fn detachNetns(arena: Allocator, path: []const u8) void {
    const p = arena.dupeSentinel(u8, path, 0) catch return;
    _ = std.os.linux.umount2(p, std.os.linux.MNT.DETACH);
}

const removeTree = Store.removeTree;

/// Removes the job directories no runner holds (their runner died), and their network
/// namespaces' mounts. A directory still being made (`.new-`) is left alone.
fn sweep(arena: Allocator, io: std.Io, store: []const u8) void {
    const jobs = std.fmt.allocPrint(arena, "{s}/jobs", .{store}) catch return;
    var dir = std.Io.Dir.cwd().openDir(io, jobs, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind != .directory or std.mem.startsWith(u8, e.name, ".new-")) continue;
        const path = std.fmt.allocPrint(arena, "{s}/{s}", .{ jobs, e.name }) catch return;
        const lock = std.fmt.allocPrint(arena, "{s}/lock", .{path}) catch return;
        const held = lockFile(arena, io, lock, false) catch continue;
        defer held.close(io);
        detachNetns(arena, std.fmt.allocPrint(arena, "{s}/netns", .{path}) catch return);
        removeTree(arena, io, path);
    }
}

/// The base every step starts from, as `set_up.baseContainerId` builds Dagger's: the image's
/// env, the step user and its HOME, the job's workspace and RUNNER_TEMP, the event payload, the
/// step markers' secret, GitHub's default variables and the job's `env:`. Package caches, uv's
/// environment in its cache and Zig's local cache are not mounted: they are caches, and the
/// native backend has no volumes before phase 4. On failure the reason is in `err_msg`.
///
/// Under step caching the store is on for the job, and the base is a layer like a step's: under
/// a key (`keyFor`), replayed when the store has it. As `set_up.writeRunEnv` does, the event
/// payload is then a volatile variable that each step writes to the file, and the job's ran
/// marker one too, so the base is the same for every run.
pub fn base(
    b: *Backend,
    ev: *Evaluator,
    plan: anytype,
    err_msg: *[]const u8,
) !void {
    const arena = b.arena;
    try b.baseEnv(ev, plan);
    if (plan.step_cache) b.store = b.store_cfg;
    b.repository = ev.job.github.repository;
    b.scope = try set_up.packageCacheScope(arena, ev, b.repository, b.vouched);
    const event = try ev.eventJson();
    const event_in_env = plan.step_cache and event.len <= set_up.max_event_env;
    if (event_in_env) try b.put(dagger.event_env, event);
    if (plan.step_cache) try b.put(dagger.ran_env, plan.ran_marker);

    // The workspace and RUNNER_TEMP, made as Dagger's base makes them: by root, in the image,
    // owned by the step user when it is not root, from `/` (the workspace is not there yet). The
    // event payload goes in as `withNewFile` does.
    const chown = if (plan.as_runner) " && chown -R " ++ dagger.runner_user ++ ":" ++
        dagger.runner_user ++ " " ++ dagger.work_root else "";
    const mk = try std.fmt.allocPrint(arena, "mkdir -p {s} {s}{s}", .{
        ev.workspace,
        ev.temp,
        chown,
    });
    const event_file = [_]sandbox.Spec.File{.{
        .path = dagger.event_path,
        .contents = event,
        .mode = 0o644,
        .keep = true,
    }};
    const files: []const sandbox.Spec.File = if (event_in_env) &.{} else &event_file;
    var out: Captured = .{ .arena = arena };
    const workdir = b.workdir;
    b.workdir = "/";
    defer b.workdir = workdir;
    const key = try b.keyFor(.base, mk, files, 0, 0);
    // Nothing can stop the base: no step is running, so no cancel reaches it.
    const claim = b.claimKey(key) catch |e| {
        err_msg.* = @errorName(e);
        return error.BaseContainerFailed;
    };
    defer claim.release(b.io);
    if (claim.hit != null) return;
    const ended = try b.exec(mk, try b.envStrings(&.{}), files, 0, 0, out.output());
    if (ended.failure.len == 0 and ended.code == 0) {
        if (claim.key) |k| b.publishTop(k, .{ .log = "", .fc = "" });
    } else {
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
///
/// Under step caching, a step that does not always run (`Resolved.run.always_run`: no secret, no
/// OIDC, no run-specific value) after a step in the store has a key (`keyFor`). When the store has
/// it, nothing runs: its layer joins the stack, and its recorded output and file commands go
/// through `Exec.collect` as Dagger's replayed exec does, with the earlier job's ran marker, so
/// the log is the live one's by construction. Otherwise it runs, and is published when it exited
/// 0 and its file commands took (`publishTop`): a failure is never replayed (#69).
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
    const always_run = switch (resolved) {
        .run => |r| r.always_run != null,
        .checkout => false,
    };
    // A step with a secret file always runs already; the check keeps any such file out of a key.
    const key = if (always_run or files.items.len > 0)
        null
    else
        try b.keyFor(.step, script, &.{}, b.uid, b.gid);
    const claim = b.claimKey(key) catch |e| switch (e) {
        error.Stopped => {
            x.err_msg = "the step was stopped";
            return error.EngineFailed;
        },
        else => return e,
    };
    defer claim.release(b.io);
    if (claim.hit) |rec| return b.replay(x, num, rec);

    var demux: SpanDemux = .{ .sh = x.sh, .gpa = b.gpa };
    defer demux.deinit();
    var live: Live = .{
        .demux = &demux,
        .arena = arena,
        .record = if (claim.key != null) .empty else null,
    };
    const ended = try b.exec(
        script,
        try b.envStrings(extra.items),
        files.items,
        b.uid,
        b.gid,
        live.output(),
    );
    const layer = b.layers.items[b.layers.items.len - 1].path;
    // The helper removes it; when it was stopped before it could, the runner does, so no later
    // step's layers hold the secret.
    for (files.items) |f| sandbox.unlinkIn(arena, layer, f.path);
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
    const all_path = try scripts.fcPath(arena, "all", fc);
    const all = switch (try sandbox.readIn(arena, layer, all_path, max_read)) {
        .text => |t| t,
        .missing, .whiteout => null,
    };
    var answer: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(.{
        .exitCode = ended.code,
        .fc_all = if (all) |text| .{ .contents = text } else null,
    }, .{ .emit_null_optional_fields = false }, &answer.writer);
    const data = try std.json.parseFromSliceLeaky(std.json.Value, arena, answer.written(), .{});
    const out = try x.collect(num, data, .{ .doc = "", .at = 0 });
    x.loadPendingMatchers(num);
    if (claim.key) |k| if (ended.code == 0 and out.code == 0) if (live.record) |r|
        b.publishTop(k, .{ .log = r.items, .fc = all orelse "" });
    return out;
}

/// A stored step's record replayed (`execScript`): its exit code 0, its output and its file
/// commands as Dagger's answer for an exec served from its cache gives them. Its file commands'
/// ran marker is the earlier job's, so `Exec.collect` replays the output (`JobLog.replayNotLive`)
/// and the job's end notes the step as reused (`JobLog.native_reused_note`).
fn replay(b: *Backend, x: *Exec, num: u32, rec: Store.Record) !Exec.Out {
    const arena = b.arena;
    // Built as values, not JSON text: a log need not be UTF-8.
    var fc_all: std.json.ObjectMap = .empty;
    try fc_all.put(arena, "contents", .{ .string = rec.fc });
    var data: std.json.ObjectMap = .empty;
    try data.put(arena, "exitCode", .{ .integer = 0 });
    try data.put(arena, "stdout", .{ .string = rec.log });
    try data.put(arena, "stderr", .{ .string = "" });
    try data.put(arena, "fc_all", .{ .object = fc_all });
    const out = try x.collect(num, .{ .object = data }, .{ .doc = "", .at = 0 });
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
    // A commit fetched is the same tree every time, as Dagger's `git` keys it, so under step
    // caching it is a layer like a step's, keyed on its script (the URL and the commit), never
    // on the token in `extra`. A branch or tag moves, so its fetch always runs.
    const key = if (checkout.isSha(f.want))
        try b.keyFor(.step, aw.written(), &.{}, b.uid, b.gid)
    else
        null;
    const claim = b.claimKey(key) catch |e| switch (e) {
        error.Stopped => {
            f.result = .{ .failed = "the step was stopped" };
            return f;
        },
        else => return e,
    };
    defer claim.release(b.io);
    if (claim.hit != null) {
        f.result = .{ .dir = "native" };
        return f;
    }
    var out: Captured = .{ .arena = arena };
    const ended = try b.exec(
        aw.written(),
        try b.envStrings(extra.items),
        &.{},
        b.uid,
        b.gid,
        out.output(),
    );
    if (ended.code == 0 and ended.failure.len == 0 and !ended.killed) {
        if (claim.key) |k| b.publishTop(k, .{ .log = "", .fc = "" });
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

/// The contents of `path` as the job's last step left it (a problem matcher's file), relative
/// to the working directory unless absolute, as Dagger reads it from the container; null when
/// it is not there. Read layer by layer, newest first, each inside itself and through no
/// symlink (`sandbox.readIn`); a whiteout ends the search, as it hides the file below.
pub fn readFile(b: *Backend, path: []const u8) ?[]const u8 {
    const arena = b.arena;
    const full = if (std.fs.path.isAbsolutePosix(path))
        path
    else
        std.fmt.allocPrint(arena, "{s}/{s}", .{ b.workdir, path }) catch return null;
    var i = b.layers.items.len;
    while (i > 0) {
        i -= 1;
        switch (sandbox.readIn(arena, b.layers.items[i].path, full, max_read) catch return null) {
            .text => |t| return t,
            .whiteout => return null,
            .missing => {},
        }
    }
    return switch (sandbox.readIn(arena, b.rootfs, full, max_read) catch return null) {
        .text => |t| t,
        .missing, .whiteout => null,
    };
}

const max_read = 16 * 1024 * 1024;

/// `dagger.Transport` for the shared code: the native backend has no Dagger session, so a query
/// is a bug in what decided the job could run here (`unsupported`).
pub fn transport(b: *Backend) dagger.Transport {
    return .{ .ptr = b, .sendFn = send, .abortFn = abort };
}

fn send(ptr: *anyopaque, arena: Allocator, doc: []const u8, limit: usize) anyerror![]const u8 {
    _ = .{ ptr, arena, doc, limit };
    return error.NativeBackendHasNoDaggerSession;
}

/// Stops the running step (`dagger.Watch`, for a timeout or a cancel), or ends its wait for
/// another job running the same key (`claimKey`).
fn abort(ptr: *anyopaque) bool {
    const b: *Backend = @ptrCast(@alignCast(ptr));
    if (b.running.kill(b.io)) return true;
    if (!b.waiting.load(.acquire)) return false;
    b.stop_wait.store(true, .release);
    return true;
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
    if (b.layers.items.len >= b.flatten_at) b.flatten() catch |e| return .{
        .code = 1,
        .failure = try std.fmt.allocPrint(arena, "could not flatten the job's {d} layers " ++
            "into one: {s}", .{ b.layers.items.len, @errorName(e) }),
    };
    const upper = try b.layerName('L');
    const upper_path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ b.dir, upper });
    try std.Io.Dir.cwd().createDirPath(b.io, upper_path);
    const base_id = b.idBase();
    // The upper's root is the overlay's `/`: the job's root's, as the image's `/` is, so a step
    // as root can make files there. Rootless, the runner's own user is the job's root already.
    if (b.how.userns == .mapped) {
        const p = try arena.dupeSentinel(u8, upper_path, 0);
        _ = std.os.linux.chown(p, base_id, base_id);
        _ = std.os.linux.chmod(p, 0o755);
    }
    const lowers = try arena.alloc([]const u8, b.layers.items.len + 1);
    for (b.layers.items, 0..) |l, i| lowers[b.layers.items.len - 1 - i] = l.name;
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
        .id_base = base_id,
        .id_count = ids_per_slot,
        .netns = b.netns,
    }, &b.running, out);
    try b.layers.append(arena, .{ .name = upper, .path = upper_path });
    return ended;
}

/// The next layer's name in the job's directory: `L<n>` for a step's upper, `l<n>` for a link to
/// a store's layer, `F<n>` for a flattened stack.
fn layerName(b: *Backend, kind: u8) ![]const u8 {
    defer b.next_layer += 1;
    return std.fmt.allocPrint(b.arena, "{c}{d}", .{ kind, b.next_layer });
}

/// The key of an exec of `script` on the stack as it is, in P8's format (`Store.KeyHasher`):
/// the model's `Key = parent · script · stable env` (proofs/Runner/Model.lean, `keyOf`). Null
/// without the store, or when the stack's top is not in it (a step that always runs, or failed,
/// or was not published): nothing after such a step is replayed or published, as under Dagger a
/// new parent makes every later key new. The env is the container's in its order, without the
/// volatile names (`Store.stableEnv`). After P8's core come what its model does not have yet: who
/// runs it and where, and the files written for it that stay (the event file, when it is not a
/// variable). A base has no parent: in its place, the digest of what every layer above it
/// depends on (`below`).
fn keyFor(
    b: *Backend,
    tag: Store.Tag,
    script: []const u8,
    files: []const sandbox.Spec.File,
    uid: u32,
    gid: u32,
) !?Store.Key {
    _ = b.store orelse return null;
    const parent = if (b.layers.items.len > 0)
        b.layers.items[b.layers.items.len - 1].key orelse return null
    else
        b.below() orelse return null;
    var h: Store.KeyHasher = .init(tag);
    h.core(parent, script, b.env.items);
    h.int(uid);
    h.int(gid);
    h.field(b.workdir);
    h.int(files.len);
    for (files) |f| {
        if (!f.keep) return null;
        h.field(f.path);
        h.field(f.contents);
        h.int(f.mode);
    }
    return h.final();
}

/// What a base's layer, and so every layer above it, depends on besides its own script: the
/// store's format (`Store.store_format`), the job's cache scope and repository (a vouched fork's
/// pull request never replays, or leaves, a layer its repository's own jobs use), the rootfs's
/// fingerprint, how ids are mapped and, on a root runner, the slot's first id (a layer's
/// files are owned by its job's range, so a layer is reused only by jobs with the same range: only
/// misses come of it), and the binds (where, not what: mounts' content is in no key). Null, and the
/// job uncached, when the rootfs cannot be read.
fn below(b: *Backend) ?Store.Key {
    const fp = Store.rootfsFingerprint(b.arena, b.io, b.rootfs) catch |e| {
        std.log.warn("native: the rootfs's fingerprint: {s}; the job's steps are not cached", .{
            @errorName(e),
        });
        b.store = null;
        return null;
    };
    var h: Store.KeyHasher = .plain("below a base");
    h.field(Store.store_format);
    h.field(b.scope);
    h.field(b.repository);
    h.field(&fp);
    h.field(@tagName(b.how.userns));
    h.int(if (b.how.userns == .mapped) b.idBase() else 0);
    h.int(b.binds.len);
    for (b.binds) |bd| {
        h.field(bd.host);
        h.field(bd.at);
        h.int(@intFromBool(bd.read_only));
        h.int(@intFromBool(bd.optional));
    }
    return h.final();
}

/// How the job's namespace sees host ids (`Store.Ids`), for a layer's digest.
fn ids(b: *const Backend) Store.Ids {
    return if (b.how.userns == .mapped)
        .{ .base = b.idBase(), .count = ids_per_slot }
    else
        .{ .base = std.os.linux.getuid(), .count = 1 };
}

/// The digest of the store's layer under `key` (`Store.layerDigest`): what output keys will key
/// on, computed when first asked for.
pub fn layerDigest(b: *Backend, key: Store.Key) !Store.Key {
    const s = b.store orelse return error.NoStore;
    return s.layerDigest(b.arena, b.io, key, b.ids());
}

/// An exec's key claimed (`Store.lockKey`, waited for while another job runs it), and its layer
/// when the store has it, on the stack already. Without a key, nothing is claimed. A store that
/// cannot be used now (its lock or its record unreadable) leaves the exec to run uncached.
const Claim = struct {
    key: ?Store.Key = null,
    lock: ?std.Io.File = null,
    hit: ?Store.Record = null,

    fn release(c: Claim, io: std.Io) void {
        if (c.lock) |l| l.close(io);
    }
};

fn claimKey(b: *Backend, key: ?Store.Key) error{ Stopped, OutOfMemory }!Claim {
    const k = key orelse return .{};
    const s = b.store.?;
    const arena = b.arena;
    b.stop_wait.store(false, .release);
    b.waiting.store(true, .release);
    const lock = s.lockKey(arena, b.io, k, &b.stop_wait) catch |e| {
        b.waiting.store(false, .release);
        if (e == error.Stopped) return error.Stopped;
        std.log.warn("native: the step store's lock: {s}", .{@errorName(e)});
        return .{};
    };
    b.waiting.store(false, .release);
    const layer = (s.open(arena, b.io, k) catch null) orelse return .{ .key = k, .lock = lock };
    const fail: ?[]const u8 = fail: {
        const rec = s.record(arena, b.io, k) catch |e| break :fail @errorName(e);
        const name = try b.layerName('l');
        const link = try std.fmt.allocPrint(arena, "{s}/{s}", .{ b.dir, name });
        std.Io.Dir.cwd().symLink(b.io, layer.fs, link, .{}) catch |e| break :fail @errorName(e);
        try b.held.append(arena, layer.lock);
        try b.layers.append(arena, .{ .name = name, .path = layer.fs, .key = k });
        return .{ .key = k, .lock = lock, .hit = rec };
    };
    std.log.warn("native: a stored layer cannot be replayed ({s}); the step runs", .{fail.?});
    layer.lock.close(b.io);
    lock.close(b.io);
    return .{};
}

/// The stack's top layer, which an exec under `key` just left, moved into the store
/// (`Store.publish`) with its record, and the job's stack then links to it. Its parent is in the
/// store (`keyFor`). A failure leaves the layer the job's own, and is logged: the job goes on,
/// uncached from here.
fn publishTop(b: *Backend, key: Store.Key, rec: Store.Record) void {
    const s = b.store orelse return;
    const arena = b.arena;
    if (rec.log.len > Store.max_record_bytes) return;
    const top = &b.layers.items[b.layers.items.len - 1];
    const name = b.layerName('l') catch return;
    const link = std.fmt.allocPrint(arena, "{s}/{s}", .{ b.dir, name }) catch return;
    const layer_fs = std.fmt.allocPrint(arena, "{s}/layers/{s}/fs", .{
        s.root,
        &Store.hex(key),
    }) catch return;
    // Made first, dangling until the layer is there: once it moved, the stack must reach it.
    const cwd = std.Io.Dir.cwd();
    cwd.symLink(b.io, layer_fs, link, .{}) catch |e| {
        std.log.warn("native: cannot link a layer into the store: {s}", .{@errorName(e)});
        return;
    };
    const layer = s.publish(arena, b.io, key, top.path, rec) catch |e| {
        std.log.warn("native: cannot publish a layer to the store: {s}", .{@errorName(e)});
        cwd.deleteFile(b.io, link) catch {};
        return;
    };
    b.held.append(arena, layer.lock) catch {
        layer.lock.close(b.io);
        return;
    };
    top.* = .{ .name = name, .path = layer.fs, .key = key };
}

/// The job's stack merged into one layer (`Store.flatten`), before overlay's limits on layers and
/// on its options' length are reached. The merged layer stands for the stack's top: its key is
/// the top's, so the steps after it are keyed and published as before.
fn flatten(b: *Backend) !void {
    const arena = b.arena;
    const paths = try arena.alloc([]const u8, b.layers.items.len);
    for (b.layers.items, paths) |l, *p| p.* = l.path;
    const name = try b.layerName('F');
    const out = try std.fmt.allocPrint(arena, "{s}/{s}", .{ b.dir, name });
    // Overlay's xattrs are `trusted.` when mounted as the host's root, `user.` under `userxattr`.
    const opaque_xattr = if (b.how.userns == .mapped)
        "trusted.overlay.opaque"
    else
        "user.overlay.opaque";
    try Store.flatten(arena, b.io, paths, out, opaque_xattr);
    const top_key = b.layers.items[b.layers.items.len - 1].key;
    b.layers.clearRetainingCapacity();
    try b.layers.append(arena, .{ .name = name, .path = out, .key = top_key });
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
    arena: Allocator,
    /// Under step caching, the output as printed, for the store (`Store.Record.log`); null past
    /// `Store.max_record_bytes`, and the step is then not published.
    record: ?std.ArrayList(u8),

    fn output(l: *Live) sandbox.Output {
        return .{ .ptr = l, .chunkFn = chunk };
    }

    fn chunk(ptr: *anyopaque, bytes: []const u8) void {
        const l: *Live = @ptrCast(@alignCast(ptr));
        SpanDemux.onRecord(l.demux, .{ .span = "native", .stream = 1, .text = bytes });
        if (l.record) |*r| {
            if (r.items.len + bytes.len > Store.max_record_bytes) {
                l.record = null;
            } else r.appendSlice(l.arena, bytes) catch {
                l.record = null;
            };
        }
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
/// cannot run one (a failure instead where `ZIG_RUNNER_REQUIRE_NATIVE=1`, as CI sets: there they
/// must run): a rootfs of a few directories with the host's /usr bound over it, in the
/// test's directory, and the runner binary the build copied for the tests (`ZIG_RUNNER_TEST_EXE`).
/// Rootless unless the tests run as root, where the job gets its range of ids and its network.
fn testConfig(arena: Allocator, tmp: *std.testing.TmpDir) !Config {
    const io = std.testing.io;
    var env = try std.testing.environ.createMap(arena);
    const required = std.mem.eql(u8, env.get("ZIG_RUNNER_REQUIRE_NATIVE") orelse "", "1");
    const exe_rel = env.get("ZIG_RUNNER_TEST_EXE") orelse
        return skip(required, "ZIG_RUNNER_TEST_EXE is not set (`zig build test` sets it)");
    const exe = std.Io.Dir.cwd().realPathFileAlloc(io, exe_rel, arena) catch
        return skip(required, "the runner binary for native steps is not built");
    const d = tmp.dir;
    const dirs = [_][]const u8{
        "rootfs/etc/ssl", "rootfs/usr",  "rootfs/tmp",  "rootfs/dev", "rootfs/proc",
        "rootfs/sys",     "rootfs/root", "rootfs/home", "store",
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
        .data = "root:x:0:0:root:/root:/bin/bash\nrunner:x:1001:1001::/home/runner:/bin/bash\n",
    });
    try d.writeFile(io, .{ .sub_path = "rootfs/etc/group", .data = "root:x:0:\nrunner:x:1001:\n" });
    for ([_][]const u8{ "hosts", "resolv.conf", "ld.so.cache" }) |f| try d.writeFile(io, .{
        .sub_path = try std.fmt.allocPrint(arena, "rootfs/etc/{s}", .{f}),
        .data = "",
    });
    const root = try d.realPathFileAlloc(io, ".", arena);
    const cfg: Config = .{
        .rootfs = try std.fmt.allocPrint(arena, "{s}/rootfs", .{root}),
        .store = try std.fmt.allocPrint(arena, "{s}/store", .{root}),
        .self_exe = exe,
        .vouched = true,
        .rootless = true,
        .binds = &.{
            .{ .host = "/usr", .at = "/usr" },
            .{ .host = "/etc/ld.so.cache", .at = "/etc/ld.so.cache" },
            // CA certificates, for the outbound test's HTTPS.
            .{ .host = "/etc/ssl", .at = "/etc/ssl" },
        },
    };
    // One sandbox, to see whether this machine lets us make them at all.
    var b = try init(arena, io, std.testing.allocator, cfg);
    defer b.deinit();
    var out: Captured = .{ .arena = arena };
    const ended = try b.exec("true", &.{"PATH=/usr/bin"}, &.{}, 0, 0, out.output());
    if (ended.failure.len > 0 or ended.code != 0)
        return skip(required, try std.fmt.allocPrint(arena, "this machine cannot make a " ++
            "native step's sandbox ({s}, exit {d})", .{ ended.failure, ended.code }));
    // What `dagger.run` asks before a job goes native: a refusal here would send the tests' jobs
    // to Dagger, which is not there.
    if (usable(arena, io, std.testing.allocator, cfg)) |why| return skip(required, why);
    return cfg;
}

fn skip(required: bool, why: []const u8) error{ SkipZigTest, NativeTestsRequired } {
    std.debug.print("native backend test {s}: {s}\n", .{
        if (required) "failed (ZIG_RUNNER_REQUIRE_NATIVE=1)" else "skipped",
        why,
    });
    return if (required) error.NativeTestsRequired else error.SkipZigTest;
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
        "echo '# summary' >> $GITHUB_STEP_SUMMARY; echo to stderr >&2; whoami; pwd\n" ++
        // A secret written into the script: its file is written by the sandbox, not by the
        // script's command, and removed after it (`Spec.files`), which step 2 checks.
        ": j0b-secret-value");
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
    var job = testJob(&.{ s1, s2, s3, s4, s5 });
    job.secrets = &.{"j0b-secret-value"};

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
        .vouched = true,
        .rootless = true,
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

    // A job the runner does not vouch for, from GitHub or a saved one (`--exec-job`).
    var remote = ok;
    remote.vouched = false;
    try expectReason("vouches", unsupported(io, run_only, root, remote));
    if (std.os.linux.geteuid() != 0) {
        var rootless = ok;
        rootless.rootless = false;
        try expectReason("RUNNER_NATIVE_ROOTLESS", unsupported(io, run_only, root, rootless));
    }

    // `hashFiles()` anywhere in the job's expressions, in any case.
    var hashed = testStep("true");
    hashed.env = &.{.{ .name = "K", .value = .{ .expr = "HASHFILES('**/go.sum')" } }};
    try expectReason("hashFiles", unsupported(io, testJob(&.{hashed}), root, ok));
    var hashed_if = testStep("true");
    hashed_if.condition = "hashFiles('x') != ''";
    try expectReason("hashFiles", unsupported(io, testJob(&.{hashed_if}), root, ok));

    var no_rootfs = ok;
    no_rootfs.rootfs = "";
    try expectReason("RUNNER_NATIVE_ROOTFS", unsupported(io, run_only, root, no_rootfs));
    no_rootfs.rootfs = "/nonexistent/rootfs";
    try expectReason("cannot be read", unsupported(io, run_only, root, no_rootfs));

    // Steps as the runner user need ids a rootless runner cannot map; on a root runner they may
    // call sudo.
    const as_runner: dagger.Options = .{ .step_user = .runner };
    const why = unsupported(io, run_only, as_runner, ok);
    if (std.os.linux.geteuid() == 0) {
        try std.testing.expect(why == null);
        const sudo = testJob(&.{testStep("sudo apt-get update")});
        try std.testing.expect(unsupported(io, sudo, as_runner, ok) == null);
    } else try expectReason("runner user", why);
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
        .native = .{ .vouched = true, .rootless = true },
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
            .lock = undefined,
            .how = .{ .argv_prefix = &.{}, .userns = .mapped },
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
        return skip(false, "git is not installed");
    if (made.term != .exited or made.term.exited != 0)
        return skip(false, "git could not make a repository");
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
    // On a root runner the repository made above is the host's root's, nobody in the job's
    // namespace, and git refuses to fetch from a repository someone else owns. A repository on
    // GitHub, fetched over HTTPS, has no owner to check.
    job.env = &.{.{ .name = "GIT_CONFIG_PARAMETERS", .value = .{ .lit = "'safe.directory=*'" } }};
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
        std.debug.print("checkout {s}, check {s}, engine {s}\n{s}\n", .{
            @tagName(res.steps[0].outcome),
            @tagName(res.steps[1].outcome),
            res.engine_error orelse "-",
            text,
        });
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

/// Runs `job` natively with `cfg` as `user`, and its log.
fn runNativeJob(
    arena: Allocator,
    cfg: Config,
    job: job_mod.Job,
    user: config.StepUser,
) !struct { res: dagger.Result, text: []const u8 } {
    var env: std.process.Environ.Map = .init(arena);
    var w: std.Io.Writer.Allocating = .init(arena);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w.writer } };
    const res = try dagger.run(arena, std.testing.io, &env, .{
        .native = cfg,
        .step_user = user,
        .gpa = std.testing.allocator,
    }, job, &log);
    return .{ .res = res, .text = w.written() };
}

fn expectLines(text: []const u8, expect: []const []const u8) !void {
    for (expect) |e| if (std.mem.indexOf(u8, text, e) == null) {
        std.debug.print("missing {s} in:\n{s}\n", .{ e, text });
        return error.TestUnexpectedResult;
    };
}

test "secrets reach native steps under their aliases, in scripts and in working directories" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cfg = try testConfig(arena, &tmp);
    var s1 = testStep("echo token-length=${#TOKEN}; mkdir -p /tmp/wd-s3cr3t-token");
    s1.env = &.{.{ .name = "TOKEN", .value = .{ .lit = "s3cr3t-token" } }};
    var s2 = testStep("pwd");
    s2.action.script.working_directory = .{ .lit = "/tmp/wd-s3cr3t-token" };
    // A script holding the secret: a file bound from a tmpfs of the step's own, never written
    // into the layer, which is on the store's disk.
    const s3 = testStep(": s3cr3t-token; stat -f -c script-fs=%T \"$0\"; " ++
        "python3 -c 'import sys\n" ++
        "for line in open(\"/proc/self/mountinfo\"):\n" ++
        "    f = line.split()\n" ++
        "    if f[4] == sys.argv[1]: print(\"script-mount\", f[f.index(\"-\") + 1])' \"$0\"");
    const s4 = testStep("ls /tmp/zig-runner-step-3* 2>/dev/null | wc -l | " ++
        "sed 's/^/scripts-left=/'");
    var job = testJob(&.{ s1, s2, s3, s4 });
    job.secrets = &.{"s3cr3t-token"};
    const r = try runNativeJob(arena, cfg, job, .root);
    for (r.res.steps) |st| if (st.outcome != .success) {
        std.debug.print("{s}\n", .{r.text});
        return error.TestUnexpectedResult;
    };
    // The value arrived (its length), and the working directory holding it was entered through
    // its alias. (Masking is the log sink's, which this test's does not do.)
    try expectLines(r.text, &.{
        "token-length=12",
        "stdout] /tmp/wd-s3cr3t-token",
        "script-fs=tmpfs",
        "script-mount tmpfs",
        "scripts-left=0",
    });
}

test "a native step is contained: pivot_root, masked /proc, Docker's capabilities, no_new_privs" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cfg = try testConfig(arena, &tmp);
    // A file on the host, outside the rootfs, that a step that got out would find.
    try tmp.dir.writeFile(io, .{ .sub_path = "host-marker", .data = "on the host" });
    const marker = try std.fmt.allocPrint(arena, "{s}/host-marker", .{
        try tmp.dir.realPathFileAlloc(io, ".", arena),
    });
    const script = try std.fmt.allocPrint(arena,
        \\echo h > /proc/sysrq-trigger 2>/dev/null && echo sysrq-written || echo sysrq-refused
        \\test -s /proc/kcore && echo kcore-visible || echo kcore-masked
        \\grep -E '^(CapEff|CapBnd|NoNewPrivs|Seccomp):' /proc/self/status
        \\python3 -c 'import ctypes
        \\print("mount", ctypes.CDLL(None).mount(b"none", b"/mnt", b"tmpfs", 0, None))'
        \\python3 -c '
        \\import os
        \\os.makedirs("/tmp/jail", exist_ok=True)
        \\try:
        \\    os.chroot("/tmp/jail")
        \\    for _ in range(64): os.chdir("..")
        \\    os.chroot(".")
        \\except OSError as e: print("chroot", e.errno)
        \\print("host", os.path.exists("{s}"))
        \\'
        \\test -e {s} && echo marker-visible || echo marker-hidden
        \\[ "$(wc -c < /proc/interrupts)" = 0 ] && echo interrupts-masked || echo interrupts-visible
        \\echo zr 2>/dev/null > /proc/sys/kernel/hostname && echo procsys-written ||
        \\  echo procsys-refused
        \\python3 -c '
        \\for line in open("/proc/self/mountinfo"):
        \\    f = line.split()
        \\    if f[4] in ("/proc/sys", "/proc/sysrq-trigger", "/proc/irq"):
        \\        print("ro-mount", f[4], f[5].split(",")[0])
        \\'
        \\python3 -c '
        \\import ctypes
        \\libc = ctypes.CDLL(None, use_errno=True)
        \\params = ctypes.create_string_buffer(120)
        \\r = libc.syscall(425, 1, params); print("io_uring_setup", r, ctypes.get_errno())
        \\for name, p in (("addr-no-randomize", 0x0040000), ("read-implies-exec", 0x0400000)):
        \\    ctypes.set_errno(0)
        \\    r = libc.personality(ctypes.c_ulong(p))
        \\    print("personality", name, r, ctypes.get_errno())
        \\print("personality query", libc.personality(ctypes.c_ulong(0xffffffff)))
        \\'
    , .{ marker, marker });
    const r = try runNativeJob(arena, cfg, testJob(&.{testStep(script)}), .root);
    if (r.res.steps[0].outcome != .success) {
        std.debug.print("{s}\n", .{r.text});
        return error.TestUnexpectedResult;
    }
    try expectLines(r.text, &.{
        "sysrq-refused",
        "kcore-masked",
        try std.fmt.allocPrint(arena, "CapEff:\t{x:0>16}", .{sandbox.docker_caps}),
        "NoNewPrivs:\t1",
        "Seccomp:\t2",
        "mount -1",
        "host False",
        "marker-hidden",
        // runc's masks and read-only paths, each applied or the step would not have run: from
        // the step's own /proc, with every mount under it, wherever the host has binfmt_misc
        // mounted under its /proc/sys (GitHub's runner does).
        "interrupts-masked",
        "procsys-refused",
        "ro-mount /proc/sys ro",
        "ro-mount /proc/sysrq-trigger ro",
        "ro-mount /proc/irq ro",
        // io_uring is refused, as moby 25 refuses it, and personality takes only Docker's values.
        "io_uring_setup -1 1",
        "personality addr-no-randomize -1 1",
        "personality read-implies-exec -1 1",
        "personality query 0",
    });
    const mounts = net.readProc(arena, io, "/proc/self/mountinfo") orelse "";
    if (std.mem.indexOf(u8, mounts, " /proc/sys/fs/binfmt_misc ") != null)
        std.debug.print("native backend test: the host's /proc/sys has binfmt_misc\n", .{});
}

test "a native step cannot follow a symlink it planted out to the host's files" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cfg = try testConfig(arena, &tmp);
    try tmp.dir.createDirPath(io, "host-dir");
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const host_dir = try std.fmt.allocPrint(arena, "{s}/host-dir", .{root});
    // A problem matcher on the host the runner must not read for a step.
    try tmp.dir.writeFile(io, .{
        .sub_path = "host-dir/matcher.json",
        .data = "{\"problemMatcher\":[]}",
    });
    // Step 1 turns /tmp into a symlink to a host directory and plants a matcher link; step 2
    // holds a secret, so the sandbox writes its script into /tmp, inside the overlay.
    const plant = try std.fmt.allocPrint(arena, "ln -s {s}/matcher.json /m.json; " ++
        "rm -rf /tmp; ln -s {s} /tmp; echo ::add-matcher::/m.json", .{ host_dir, host_dir });
    const s2 = testStep("echo s3cr3t-in-script > /dev/null; echo second");
    var job = testJob(&.{ testStep(plant), s2 });
    job.secrets = &.{"s3cr3t-in-script"};
    const r = try runNativeJob(arena, cfg, job, .root);
    try expectLines(r.text, &.{ "Could not read the problem matcher '/m.json'", "second" });
    var dir = try tmp.dir.openDir(io, "host-dir", .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |e| try std.testing.expectEqualStrings("matcher.json", e.name);
}

/// Skips a test that needs the runner to be root (its ids and network): CI runs the native tests
/// a second time under sudo for them.
fn requireRoot() !void {
    if (std.os.linux.geteuid() != 0) {
        std.debug.print("native backend test skipped: it needs root\n", .{});
        return error.SkipZigTest;
    }
}

test "root runner: a job's own ids, its runner user, and sudo gaining nothing" {
    try requireRoot();
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cfg = try testConfig(arena, &tmp);
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);
    // What `set_up.provision_runner_script` gives the runner user (/tmp for all, /github and its
    // home its own), a sudo the job's root owns, as the provisioned image has (the host's, in the
    // bound /usr, is owned by an id the job does not map), with its sudoers and PAM
    // configuration; and a file only the host's root may read, bound in.
    const setup = try std.fmt.allocPrint(arena,
        \\set -e
        \\cd '{s}'
        \\mkdir -p rootfs/opt rootfs/run rootfs/var/lib rootfs/etc/sudoers.d
        \\chmod 1777 rootfs/tmp
        \\mkdir -p rootfs/github rootfs/home/runner
        \\chown 1001:1001 rootfs/github rootfs/home/runner
        \\cp /usr/bin/sudo rootfs/opt/sudo && chmod 4755 rootfs/opt/sudo
        \\mkdir -p rootfs/opt/sudo-plugins
        \\cp /usr/libexec/sudo/sudoers.so rootfs/opt/sudo-plugins/
        \\cp -a /etc/pam.d rootfs/etc/
        \\for f in /etc/security /etc/login.defs /etc/nsswitch.conf; do
        \\  [ -e "$f" ] && cp -a "$f" rootfs/etc/ || true
        \\done
        \\for p in sudoers_policy sudoers_io sudoers_audit; do
        \\  echo "Plugin $p /opt/sudo-plugins/sudoers.so"
        \\done > rootfs/etc/sudo.conf
        \\printf 'root ALL=(ALL:ALL) ALL\nrunner ALL=(ALL) NOPASSWD:ALL\n' > rootfs/etc/sudoers
        \\chmod 0440 rootfs/etc/sudoers
        \\printf 'root:*:19000:0:99999:7:::\nrunner:*:19000:0:99999:7:::\n' > rootfs/etc/shadow
        \\chmod 0640 rootfs/etc/shadow
        \\echo host-only > host-secret && chmod 0600 host-secret
        \\: > rootfs/opt/host-secret
    , .{root});
    const made = try std.process.run(arena, io, .{ .argv = &.{ "sh", "-c", setup } });
    try std.testing.expect(made.term == .exited and made.term.exited == 0);
    cfg.binds = try std.mem.concat(arena, sandbox.Spec.Bind, &.{ cfg.binds, &.{.{
        .host = try std.fmt.allocPrint(arena, "{s}/host-secret", .{root}),
        .at = "/opt/host-secret",
    }} });

    const script = "id -u; echo HOME=$HOME; cat /proc/self/uid_map; " ++
        "touch \"$GITHUB_WORKSPACE/mine\" && stat -c owner=%u \"$GITHUB_WORKSPACE/mine\"\n" ++
        "echo sudo-uid=$(/opt/sudo -n id -u)\n" ++
        "/opt/sudo -n cat /opt/host-secret 2>/dev/null && echo host-file-read || " ++
        "echo host-file-refused\n" ++
        "/opt/sudo -n grep -E '^CapEff' /proc/self/status\n" ++
        "/opt/sudo -n cat /proc/self/uid_map | sed 's/^/sudo-map /'";
    const r = try runNativeJob(arena, cfg, testJob(&.{testStep(script)}), .runner);
    if (r.res.steps[0].outcome != .success) {
        std.debug.print("step {s}, engine {s}\n{s}\n", .{
            @tagName(r.res.steps[0].outcome),
            r.res.engine_error orelse "-",
            r.text,
        });
        return error.TestUnexpectedResult;
    }
    try expectLines(r.text, &.{
        "stdout] 1001",
        "HOME=/home/runner",
        "owner=1001",
        // sudo works: the runner user becomes the job's root...
        "sudo-uid=0",
        // ...and that root is nobody on the host: not the host's root's file, no more than
        // Docker's capabilities, and the same range of host ids.
        "host-file-refused",
        try std.fmt.allocPrint(arena, "CapEff:\t{x:0>16}", .{sandbox.docker_caps}),
        "sudo-map ",
        "Native steps: ids 0-65535 are host ids",
    });
    const map = try std.fmt.allocPrint(arena, "0 {d}", .{default_subid_base});
    var lines = std.mem.splitScalar(u8, r.text, '\n');
    var maps: u32 = 0;
    while (lines.next()) |l| {
        if (std.mem.indexOf(u8, l, "sudo-map") == null and std.mem.indexOf(u8, l, "65536") == null)
            continue;
        const words = try std.mem.join(arena, " ", try collectWords(arena, l));
        if (std.mem.indexOf(u8, words, map) != null) maps += 1;
    }
    // The step's map and sudo's: both the job's range.
    try std.testing.expect(maps >= 2);
}

fn collectWords(arena: Allocator, line: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, line, " \t");
    while (it.next()) |w| try out.append(arena, w);
    return out.items;
}

test "root runner: a job's own network, out of reach of the host's services and other jobs" {
    try requireRoot();
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cfg = try testConfig(arena, &tmp);

    // Listeners on the host's 127.0.0.1 and on all its addresses (the bridge's among them), which
    // a step must not reach.
    const loopback = try listen(47123, 0x7f000001);
    defer _ = std.os.linux.close(loopback);
    const any = try listen(47124, 0);
    defer _ = std.os.linux.close(any);

    // Two jobs at once, both serving on :5432 and on their own lo, neither reaching the host's
    // listeners, and neither reaching the other's :5432 (bridge ports isolated, and the host
    // routes nothing between jobs).
    const gw = cfg.subnet.gateway();
    const first = cfg.subnet.jobAddress(0);
    const script = try std.fmt.allocPrint(arena,
        \\python3 - <<'EOF'
        \\import socket, time
        \\s = socket.socket(); s.bind(("0.0.0.0", 5432)); s.listen(); print("bound 5432")
        \\c = socket.create_connection(("127.0.0.1", 5432), 2); print("own lo works")
        \\u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); u.connect(("192.0.2.1", 9))
        \\me = u.getsockname()[0]
        \\def reach(host, port):
        \\    try:
        \\        socket.create_connection((host, port), 2).close(); return True
        \\    except OSError: return False
        \\print("host loopback", "reached" if reach("127.0.0.1", 47123) else "unreachable")
        \\print("host via bridge", "reached" if reach("{d}.{d}.{d}.{d}", 47124) else "unreachable")
        \\time.sleep(2)
        \\base = "{d}.{d}.{d}."
        \\peers = [base + str(i) for i in range({d}, {d} + 4) if base + str(i) != me]
        \\print("peers", "reached" if any(reach(p, 5432) for p in peers) else "unreachable")
        \\time.sleep(8)
        \\EOF
    , .{ gw[0], gw[1], gw[2], gw[3], first[0], first[1], first[2], first[3], first[3] });
    const Run = struct {
        fn one(
            arena_: Allocator,
            cfg_: Config,
            script_: []const u8,
            out: *[]const u8,
            ok: *bool,
        ) void {
            const r = runNativeJob(arena_, cfg_, testJob(&.{testStep(script_)}), .root) catch {
                ok.* = false;
                return;
            };
            out.* = r.text;
            ok.* = r.res.steps[0].outcome == .success;
        }
    };
    var texts: [2][]const u8 = .{ "", "" };
    var oks: [2]bool = .{ false, false };
    var arenas: [2]std.heap.ArenaAllocator = .{
        .init(std.testing.allocator),
        .init(std.testing.allocator),
    };
    defer for (&arenas) |*x| x.deinit();
    const args = .{ arenas[0].allocator(), cfg, script, &texts[0], &oks[0] };
    var other = try io.concurrent(Run.one, args);
    Run.one(arenas[1].allocator(), cfg, script, &texts[1], &oks[1]);
    other.await(io);
    for (texts, oks) |t, ok| {
        if (!ok) std.debug.print("{s}\n", .{t});
        try std.testing.expect(ok);
        try expectLines(t, &.{
            "bound 5432",
            "own lo works",
            "host loopback unreachable",
            "host via bridge unreachable",
            "peers unreachable",
        });
    }

    // Out to the world, when the host itself gets there: DNS through the job's resolver, HTTP
    // through the NAT.
    const resolve: []const []const u8 = &.{ "getent", "hosts", "github.com" };
    const host = std.process.run(arena, io, .{ .argv = resolve }) catch null;
    if (host == null or host.?.term != .exited or host.?.term.exited != 0) {
        std.debug.print("native backend test: outbound part skipped, the host cannot " ++
            "resolve github.com\n", .{});
        return;
    }
    const out = testStep("getent hosts github.com >/dev/null && echo dns-ok; " ++
        "python3 -c 'import urllib.request; print(\"http\", " ++
        "urllib.request.urlopen(\"https://github.com\", timeout=20).status)'");
    const r = try runNativeJob(arena, cfg, testJob(&.{out}), .root);
    try expectLines(r.text, &.{ "dns-ok", "http 200" });
}

/// A TCP listener of the test's on the host, on `port` at `addr` (host order; 0 for every
/// address).
fn listen(port: u16, addr: u32) !std.os.linux.fd_t {
    const linux = std.os.linux;
    const sock = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(sock) != .SUCCESS) return error.Socket;
    const fd: linux.fd_t = @intCast(sock);
    errdefer _ = linux.close(fd);
    const one: i32 = 1;
    const reuse = linux.SO.REUSEADDR;
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, reuse, std.mem.asBytes(&one), @sizeOf(i32));
    var sa: linux.sockaddr.in = .{
        .port = std.mem.nativeToBig(u16, port),
        .addr = std.mem.nativeToBig(u32, addr),
    };
    if (linux.errno(linux.bind(fd, @ptrCast(&sa), @sizeOf(linux.sockaddr.in))) != .SUCCESS)
        return error.Bind;
    if (linux.errno(linux.listen(fd, 4)) != .SUCCESS) return error.Listen;
    return fd;
}

test "the jobs' ids: each range the host already uses, or may, is refused" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const Case = struct { file: []const u8, text: []const u8, reason: []const u8 };
    const first: u32 = 2_000_000;
    const end = first + ids_per_slot * net.max_slots;
    const cases = [_]Case{
        .{
            .file = "subuid",
            .text = "lement:100000:65536\npodman:1999000:2000\n",
            .reason = "podman's in",
        },
        .{
            .file = "subgid",
            .text = "lement:100000:65536\nbuilder:16000000:1\n",
            .reason = "builder's in",
        },
        .{
            .file = "passwd",
            .text = "root:x:0:0::/root:/bin/sh\nldap-user:x:2000000:100::/:/bin/sh\n",
            .reason = "ldap-user's id 2000000",
        },
        .{
            .file = "group",
            .text = try std.fmt.allocPrint(arena, "root:x:0:\nlast:x:{d}:\n", .{end - 1}),
            .reason = "last's id",
        },
    };
    const files: IdFiles = .{
        .subuid = try std.fmt.allocPrint(arena, "{s}/subuid", .{root}),
        .subgid = try std.fmt.allocPrint(arena, "{s}/subgid", .{root}),
        .passwd = try std.fmt.allocPrint(arena, "{s}/passwd", .{root}),
        .group = try std.fmt.allocPrint(arena, "{s}/group", .{root}),
    };
    // Nothing there, and files that name only others' ids: usable.
    try std.testing.expect(try idsClash(arena, io, first, files) == null);
    for (cases) |c| try tmp.dir.writeFile(io, .{ .sub_path = c.file, .data = "x:1000:1000\n" });
    try std.testing.expect(try idsClash(arena, io, first, files) == null);
    for (cases) |c| {
        try tmp.dir.writeFile(io, .{ .sub_path = c.file, .data = c.text });
        try expectReason(c.reason, try idsClash(arena, io, first, files));
        try tmp.dir.writeFile(io, .{ .sub_path = c.file, .data = "x:1000:1000\n" });
    }
    // The id just past the last slot's range is someone else's to have.
    try tmp.dir.writeFile(io, .{
        .sub_path = "passwd",
        .data = try std.fmt.allocPrint(arena, "next:x:{d}:1::/:/bin/sh\n", .{end}),
    });
    try std.testing.expect(try idsClash(arena, io, first, files) == null);
    try expectReason("below 100000", try idsClash(arena, io, 99_999, files));
    try expectReason("2^32", try idsClash(arena, io, std.math.maxInt(u32) - ids_per_slot, files));
    // The default range clears systemd's container and foreign ranges, below 2^31.
    try std.testing.expect(default_subid_base > 1_879_048_191);
    try std.testing.expect(default_subid_base + ids_per_slot * net.max_slots <= 2_147_352_576);
}

test "a failed probe is tried again after its back-off; a success holds" {
    var c: ProbeCache = .{};
    try std.testing.expect(!c.fresh(0));
    try std.testing.expectEqualStrings("iptables is locked", c.store(1000, "iptables is locked").?);
    try std.testing.expect(c.fresh(1000 + probe_backoff_ms - 1));
    try std.testing.expectEqualStrings("iptables is locked", c.why().?);
    try std.testing.expect(!c.fresh(1000 + probe_backoff_ms));
    try std.testing.expect(c.store(1000 + probe_backoff_ms, null) == null);
    try std.testing.expect(c.fresh(std.math.maxInt(i64)));
}

test "root runner: slots are the host's, so two runners with different stores never share one" {
    try requireRoot();
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cfg = try testConfig(arena, &tmp);
    var other = cfg;
    try tmp.dir.createDirPath(io, "store-2");
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);
    other.store = try std.fmt.allocPrint(arena, "{s}/store-2", .{root});
    var first = try init(arena, io, std.testing.allocator, cfg);
    defer first.deinit();
    var second = try init(arena, io, std.testing.allocator, other);
    defer second.deinit();
    try std.testing.expect(first.slot.?.n != second.slot.?.n);
    try std.testing.expect(first.idBase() != second.idBase());
    // The second job's set-up left the first's veth alone, and both are on the bridge.
    var sock = try net.Socket.open();
    defer sock.close();
    var buf: [16]u8 = undefined;
    try std.testing.expect(sock.index(net.hostLink(&buf, first.slot.?.n)) != null);
    try std.testing.expect(sock.index(net.hostLink(&buf, second.slot.?.n)) != null);
}

test "a job's directory and lock are let go once, when its set-up fails after the lock is taken" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "store");
    try tmp.dir.createDirPath(io, "rootfs");
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);
    var cfg: Config = .{
        .rootfs = try std.fmt.allocPrint(arena, "{s}/rootfs", .{root}),
        .store = try std.fmt.allocPrint(arena, "{s}/store", .{root}),
        .self_exe = "/bin/true",
        .test_fail_after_lock = true,
    };
    // Closing an fd twice would panic here (Zig's own check for a file closed twice).
    try std.testing.expectError(error.TestFailure, init(arena, io, std.testing.allocator, cfg));
    var jobs = try tmp.dir.openDir(io, "store/jobs", .{ .iterate = true });
    defer jobs.close(io);
    var it = jobs.iterate();
    try std.testing.expect(try it.next(io) == null);
    // Nothing is left holding a lock: the next job's set-up goes through.
    cfg.test_fail_after_lock = false;
    var b = try init(arena, io, std.testing.allocator, cfg);
    b.deinit();
}

// --- the step cache (the layer store) ---

/// `testConfig`, with a host directory every step sees at `/shared`, writable: steps count their
/// runs there, since a mount's content is in no key.
fn cachedConfig(arena: Allocator, tmp: *std.testing.TmpDir) !struct { cfg: Config, shared: []const u8 } {
    var cfg = try testConfig(arena, tmp);
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "shared");
    try tmp.dir.createDirPath(io, "rootfs/shared");
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const shared = try std.fmt.allocPrint(arena, "{s}/shared", .{root});
    // On a root runner the job's root is nobody on the host.
    _ = std.os.linux.chmod(try arena.dupeSentinel(u8, shared, 0), 0o777);
    cfg.binds = try std.mem.concat(arena, sandbox.Spec.Bind, &.{
        cfg.binds,
        &.{.{ .host = shared, .at = "/shared", .read_only = false }},
    });
    return .{ .cfg = cfg, .shared = shared };
}

/// Runs `job` natively under step caching as the job whose ran marker is `ran`, and its log.
fn runCached(
    arena: Allocator,
    cfg: Config,
    job: job_mod.Job,
    ran: []const u8,
) !struct { res: dagger.Result, text: []const u8 } {
    var env: std.process.Environ.Map = .init(arena);
    var w: std.Io.Writer.Allocating = .init(arena);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w.writer } };
    const res = try dagger.run(arena, std.testing.io, &env, .{
        .native = cfg,
        .step_user = .root,
        .step_cache = true,
        .test_ran_marker = ran,
        .gpa = std.testing.allocator,
    }, job, &log);
    return .{ .res = res, .text = w.written() };
}

/// How many times a step counted itself in `shared/name`.
fn runs(arena: Allocator, shared: []const u8, name: []const u8) usize {
    const p = std.fmt.allocPrint(arena, "{s}/{s}", .{ shared, name }) catch return 0;
    const text = std.Io.Dir.cwd().readFileAlloc(std.testing.io, p, arena, .limited(1 << 16)) catch
        return 0;
    return std.mem.count(u8, text, "\n");
}

fn expectSucceeded(r: anytype) !void {
    for (r.res.steps) |st| if (st.outcome != .success) {
        std.debug.print("engine {s}\n{s}\n", .{ r.res.engine_error orelse "-", r.text });
        return error.TestUnexpectedResult;
    };
}

/// The step lines of a log, without the note a replayed step ends with.
fn replayableLines(arena: Allocator, text: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (try stepLines(arena, text)) |l| {
        if (std.mem.indexOf(u8, l, dagger.native_reused_note) != null) continue;
        try out.append(arena, l);
    }
    return out.items;
}

fn storeLayers(arena: Allocator, store: []const u8) !usize {
    const p = try std.fmt.allocPrint(arena, "{s}/layers", .{store});
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, p, .{ .iterate = true });
    defer dir.close(std.testing.io);
    var n: usize = 0;
    var it = dir.iterate();
    while (try it.next(std.testing.io)) |_| n += 1;
    return n;
}

test "native step cache: a job run again is replayed, its log byte for byte, its file commands applied" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const c = try cachedConfig(arena, &tmp);

    var s1 = testStep("echo x >> /shared/s1; echo hello; printf 'no newline'; echo; echo\n" ++
        "echo FOO=bar >> $GITHUB_ENV; echo out=42 >> $GITHUB_OUTPUT; echo /opt/x >> $GITHUB_PATH\n" ++
        "echo '# sum' >> $GITHUB_STEP_SUMMARY; echo ::add-mask::m4sked-value; " ++
        "echo the m4sked-value; echo to stderr >&2; mkdir -p /tmp/kept && echo layer > /tmp/kept/f");
    s1.context_name = "first";
    var s2 = testStep("echo x >> /shared/s2; echo FOO=$FOO OUT=$OUT; cat /tmp/kept/f; " ++
        "echo \"$PATH\" | cut -d: -f1; echo '::warning::careful'");
    s2.env = &.{.{ .name = "OUT", .value = .{ .expr = "steps.first.outputs.out" } }};
    const job = testJob(&.{ s1, s2 });
    const first = try runCached(arena, c.cfg, job, "j1");
    try expectSucceeded(first);
    // Another commit: the commit is run-specific, in no key.
    var again = job;
    again.github.sha = "fedcba9876fedcba9876fedcba9876fedcba9876";
    const second = try runCached(arena, c.cfg, again, "j2");
    try expectSucceeded(second);

    // The second job ran nothing: both steps, and its base, came from the store.
    try std.testing.expectEqual(@as(usize, 1), runs(arena, c.shared, "s1"));
    try std.testing.expectEqual(@as(usize, 1), runs(arena, c.shared, "s2"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, first.text, dagger.native_reused_note));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, second.text, dagger.native_reused_note));
    try std.testing.expectEqual(@as(usize, 3), try storeLayers(arena, c.cfg.store));
    // The replayed log is the live one, line for line: blank lines, a last line without a
    // newline, stderr, masks and workflow commands.
    const live = try replayableLines(arena, first.text);
    const replayed = try replayableLines(arena, second.text);
    if (live.len != replayed.len) {
        std.debug.print("live:\n{s}\nreplayed:\n{s}\n", .{ first.text, second.text });
        return error.TestUnexpectedResult;
    }
    for (live, replayed) |l, r| try std.testing.expectEqualStrings(l, r);
    try expectLines(second.text, &.{ "FOO=bar OUT=42", "stdout] layer", "/opt/x", "the ***" });
    // The step's file commands were applied again: its summary and its outputs.
    try std.testing.expectEqualStrings("# sum\n", second.res.summaries[0]);
    // The store is no host user's to read.
    var st: std.os.linux.Statx = undefined;
    const store_z = try arena.dupeSentinel(u8, c.cfg.store, 0);
    _ = std.os.linux.statx(std.os.linux.AT.FDCWD, store_z, 0, .{ .MODE = true }, &st);
    try std.testing.expectEqual(@as(u32, 0o700), st.mode & 0o777);
}

test "native step cache: a failure is not replayed, and the steps before it are" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const c = try cachedConfig(arena, &tmp);
    const s1 = testStep("echo x >> /shared/s1; echo MODE=ci >> $GITHUB_ENV");
    const s2 = testStep("echo x >> /shared/s2; echo MODE=$MODE; test -e /shared/pass");
    const job = testJob(&.{ s1, s2 });

    const first = try runCached(arena, c.cfg, job, "j1");
    try std.testing.expectEqual(dagger.Outcome.failure, first.res.steps[1].outcome);
    // #69: the failure was not kept, so it runs again, on the step before it replayed (with
    // its export), and passes this time.
    try tmp.dir.writeFile(io, .{ .sub_path = "shared/pass", .data = "" });
    const second = try runCached(arena, c.cfg, job, "j2");
    try expectSucceeded(second);
    try std.testing.expectEqual(@as(usize, 1), runs(arena, c.shared, "s1"));
    try std.testing.expectEqual(@as(usize, 2), runs(arena, c.shared, "s2"));
    try expectLines(second.text, &.{"MODE=ci"});
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, second.text, dagger.native_reused_note));
    // Now it passed, it is kept.
    const third = try runCached(arena, c.cfg, job, "j3");
    try expectSucceeded(third);
    try std.testing.expectEqual(@as(usize, 2), runs(arena, c.shared, "s2"));
}

test "native step cache: steps with secrets or run-specific values always run, and nothing after them is kept" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const c = try cachedConfig(arena, &tmp);
    const s0 = testStep("echo x >> /shared/s0");
    const s1 = testStep("echo x >> /shared/s1; echo sha=$GITHUB_SHA");
    const s2 = testStep("echo x >> /shared/s2");
    var secret = testStep("echo x >> /shared/secret; echo the token is $TOKEN; " ++
        "echo $TOKEN > /tmp/token-file");
    secret.env = &.{.{ .name = "TOKEN", .value = .{ .lit = "s3cr3t-token-value" } }};
    var job = testJob(&.{ s0, s1, s2, secret });
    job.secrets = &.{"s3cr3t-token-value"};
    for ([_][]const u8{ "j1", "j2" }) |ran| try expectSucceeded(try runCached(arena, c.cfg, job, ran));
    try std.testing.expectEqual(@as(usize, 1), runs(arena, c.shared, "s0"));
    try std.testing.expectEqual(@as(usize, 2), runs(arena, c.shared, "s1"));
    try std.testing.expectEqual(@as(usize, 2), runs(arena, c.shared, "s2"));
    try std.testing.expectEqual(@as(usize, 2), runs(arena, c.shared, "secret"));
    // Only the base and the first step were kept: no layer or log holds the secret.
    try std.testing.expectEqual(@as(usize, 2), try storeLayers(arena, c.cfg.store));
    var store = try std.Io.Dir.cwd().openDir(io, c.cfg.store, .{ .iterate = true });
    defer store.close(io);
    var walker = try store.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |e| {
        if (e.kind != .file) continue;
        const text = e.dir.readFileAlloc(io, e.basename, arena, .limited(1 << 20)) catch continue;
        try std.testing.expect(std.mem.indexOf(u8, text, "s3cr3t") == null);
    }

    // A workflow that opts out runs everything every time.
    var out = testJob(&.{testStep("echo x >> /shared/opted-out")});
    out.env = &.{.{ .name = "ZIG_RUNNER_STEP_CACHE", .value = .{ .lit = "false" } }};
    for ([_][]const u8{ "j3", "j4" }) |ran| try expectSucceeded(try runCached(arena, c.cfg, out, ran));
    try std.testing.expectEqual(@as(usize, 2), runs(arena, c.shared, "opted-out"));
}

test "native step cache: two jobs with one key at once run it once; the other replays it" {
    // On a root runner two jobs at once have two slots, two ranges of ids, so two keys (a layer
    // is reused only by jobs with the same range): each runs its own.
    const shared_key = std.os.linux.geteuid() != 0;
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const c = try cachedConfig(arena, &tmp);
    // A file of its own each time: the other job's root may be another host id.
    const job = testJob(&.{testStep("sleep 1; mktemp /shared/slow.XXXXXX")});
    const Other = struct {
        fn run(cfg: Config, j: job_mod.Job, text: *[]const u8, ok: *bool) void {
            var b: std.heap.ArenaAllocator = .init(std.testing.allocator);
            const r = runCached(b.allocator(), cfg, j, "j2") catch {
                b.deinit();
                return;
            };
            ok.* = r.res.succeeded;
            text.* = std.testing.allocator.dupe(u8, r.text) catch "";
            b.deinit();
        }
    };
    var other_text: []const u8 = "";
    var other_ok = false;
    var other = try io.concurrent(Other.run, .{ c.cfg, job, &other_text, &other_ok });
    const mine = try runCached(arena, c.cfg, job, "j1");
    other.await(io);
    defer std.testing.allocator.free(other_text);
    try expectSucceeded(mine);
    try std.testing.expect(other_ok);
    var made: usize = 0;
    var dir = try std.Io.Dir.cwd().openDir(io, c.shared, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |e| made += @intFromBool(std.mem.startsWith(u8, e.name, "slow."));
    try std.testing.expectEqual(@as(usize, if (shared_key) 1 else 2), made);
    const notes = std.mem.count(u8, mine.text, dagger.native_reused_note) +
        std.mem.count(u8, other_text, dagger.native_reused_note);
    try std.testing.expectEqual(@as(usize, if (shared_key) 1 else 0), notes);
}

test "native step cache: a long job's layers are flattened, files, deletions and replays intact" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var c = try cachedConfig(arena, &tmp);
    // The base and two steps, then a merge; and again two steps later.
    c.cfg.flatten_at = 3;
    const job = testJob(&.{
        testStep("mkdir -p /w/d && echo 1 > /w/a && echo 1 > /w/d/x && echo 1 > /w/gone"),
        testStep("echo 2 > /w/a && rm /w/gone"),
        // A directory removed and made again: opaque in its layer.
        testStep("rm -rf /w/d && mkdir /w/d && echo 3 > /w/d/y"),
        testStep("echo 4 > /w/b"),
        testStep("echo x >> /shared/last; ls /w /w/d | tr '\\n' ' '; echo; cat /w/a /w/b /w/d/y; " ++
            "test ! -e /w/gone && test ! -e /w/d/x && echo state-ok"),
    });
    // Without the store, with it, and replayed from it over links to its layers.
    var uncached = c.cfg;
    uncached.store = try std.fmt.allocPrint(arena, "{s}-uncached", .{c.cfg.store});
    const plain = try runNativeJob(arena, uncached, job, .root);
    try expectSucceeded(plain);
    for ([_][]const u8{ "j1", "j2" }) |ran| {
        const r = try runCached(arena, c.cfg, job, ran);
        try expectSucceeded(r);
        try expectLines(r.text, &.{ "stdout] 2", "stdout] 4", "stdout] 3", "state-ok" });
    }
    try std.testing.expectEqual(@as(usize, 2), runs(arena, c.shared, "last"));
    try expectLines(plain.text, &.{"state-ok"});
}

test "native step cache: past its cap the store lets go of every layer no job holds" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var c = try cachedConfig(arena, &tmp);
    c.cfg.store_max_bytes = 0;
    const job = testJob(&.{testStep("echo x >> /shared/s")});
    for ([_][]const u8{ "j1", "j2" }) |ran| try expectSucceeded(try runCached(arena, c.cfg, job, ran));
    try std.testing.expectEqual(@as(usize, 2), runs(arena, c.shared, "s"));
    try std.testing.expectEqual(@as(usize, 0), try storeLayers(arena, c.cfg.store));
}

test "native step cache: measured, replay per step and the store's size over 50 jobs" {
    // A measurement, not a check: ZIG_RUNNER_NATIVE_BENCH=1 runs it (docs/native-backend.md, P2's
    // numbers), best under `-Doptimize=ReleaseSafe`.
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const io = std.testing.io;
    var env = try std.testing.environ.createMap(arena);
    if (!std.mem.eql(u8, env.get("ZIG_RUNNER_NATIVE_BENCH") orelse "", "1"))
        return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const c = try cachedConfig(arena, &tmp);
    const now = struct {
        fn ms() i64 {
            return std.Io.Clock.awake.now(std.testing.io).toMilliseconds();
        }
    }.ms;
    // Per step: (50-step job - 1-step job) / 49, cold (run and published) and replayed.
    var steps: [50]job_mod.Step = undefined;
    for (&steps, 0..) |*s, i| s.* = testStep(try std.fmt.allocPrint(arena, "true {d}", .{i}));
    var t: [2][2]i64 = undefined; // [cold, replayed][1 step, 50 steps]
    for ([_]usize{ 1, 50 }, 0..) |n, col| {
        const job = testJob(steps[0..n]);
        for (0..2) |row| {
            const ran = try std.fmt.allocPrint(arena, "b{d}{d}", .{ n, row });
            const started = now();
            try expectSucceeded(try runCached(arena, c.cfg, job, ran));
            t[row][col] = now() - started;
        }
    }
    std.debug.print("native bench: cold job 1 step {d} ms, 50 steps {d} ms, per step {d:.1} ms\n", .{
        t[0][0], t[0][1], @as(f64, @floatFromInt(t[0][1] - t[0][0])) / 49.0,
    });
    std.debug.print("native bench: replayed job 1 step {d} ms, 50 steps {d} ms, per step {d:.2} ms\n", .{
        t[1][0], t[1][1], @as(f64, @floatFromInt(t[1][1] - t[1][0])) / 49.0,
    });

    // 50 jobs of one workflow, as 50 commits: five steps that never change (one of them writes
    // 1 MiB), one that does every time, and four after it, which are new with it.
    const layers = try std.fmt.allocPrint(arena, "{s}/layers", .{c.cfg.store});
    var job_steps: [10]job_mod.Step = undefined;
    for (0..50) |j| {
        for (&job_steps, 0..) |*s, i| s.* = testStep(switch (i) {
            0 => "head -c 1048576 /dev/zero > /tmp/setup.bin",
            5 => try std.fmt.allocPrint(arena, "echo commit {d} > /tmp/commit", .{j}),
            else => try std.fmt.allocPrint(arena, "echo step {d} > /tmp/s{d}", .{ i, i }),
        });
        const ran = try std.fmt.allocPrint(arena, "s{d}", .{j});
        try expectSucceeded(try runCached(arena, c.cfg, testJob(&job_steps), ran));
    }
    std.debug.print("native bench: store after 50 jobs: {d} layers, {d} KiB\n", .{
        try storeLayers(arena, c.cfg.store),
        Store.treeBytes(arena, io, layers) / 1024,
    });
}

test "native step cache: a fork's pull request keys its layers apart from its repository's jobs" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const c = try cachedConfig(arena, &tmp);
    // Two pull requests, alike but for the head's repository: the repository's own, and a fork's.
    const pr = struct {
        fn job(ar: Allocator, head: []const u8) !job_mod.Job {
            // The steps in the arena: a literal's would not outlive this call.
            const steps = try ar.dupe(job_mod.Step, &.{testStep("echo x >> /shared/s")});
            var j = testJob(steps);
            j.context_data = try std.json.parseFromSliceLeaky(
                std.json.Value,
                ar,
                try std.fmt.allocPrint(ar, "{{\"github\":{{\"t\":2,\"d\":[" ++
                    "{{\"k\":\"repository\",\"v\":\"o/r\"}},{{\"k\":\"event\",\"v\":{{\"t\":2,\"d\":[" ++
                    "{{\"k\":\"pull_request\",\"v\":{{\"t\":2,\"d\":[{{\"k\":\"head\",\"v\":{{\"t\":2," ++
                    "\"d\":[{{\"k\":\"repo\",\"v\":{{\"t\":2,\"d\":[{{\"k\":\"full_name\",\"v\":" ++
                    "\"{s}\"}}]}}}}]}}}}]}}}}]}}}}]}}}}", .{head}),
                .{},
            );
            return j;
        }
    }.job;
    const own = try pr(arena, "o/r");
    const fork = try pr(arena, "fork/r");
    try expectSucceeded(try runCached(arena, c.cfg, own, "j1"));
    try expectSucceeded(try runCached(arena, c.cfg, own, "j2"));
    try std.testing.expectEqual(@as(usize, 1), runs(arena, c.shared, "s"));
    // The fork's does not replay the repository's layer, but replays its own.
    try expectSucceeded(try runCached(arena, c.cfg, fork, "j3"));
    try std.testing.expectEqual(@as(usize, 2), runs(arena, c.shared, "s"));
    try expectSucceeded(try runCached(arena, c.cfg, fork, "j4"));
    try std.testing.expectEqual(@as(usize, 2), runs(arena, c.shared, "s"));
}
