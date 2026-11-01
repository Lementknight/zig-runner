//! One step in a sandbox of its own: a fresh overlay on the job's layers, private mount, PID, UTS
//! and IPC namespaces, a minimal /dev, chroot, and `sh -c <script>` (docs/native-backend.md, P1).
//!
//! The runner is multi-threaded, and a thread may not unshare a user namespace, so each step runs
//! in a helper process: the runner's own binary started as `zig-runner native-step` (`command`),
//! with the step's `Spec` as JSON on its stdin. `run` is the runner's side, `main` the helper's.
//! The helper's stdout is the step's stdout and stderr, which the runner streams into the job's
//! log as it reads it; the helper's own stderr carries only its failures, so anything there
//! means the sandbox, not the step, failed.
//!
//! What it replaces in Dagger: BuildKit's runc executor. runc did implicitly several things a
//! step relies on, each now explicit here: HOME from the image's /etc/passwd when the env has
//! none, the host's /etc/resolv.conf and /etc/hosts over the image's, a /dev of a few nodes
//! rather than the host's, /proc for the step's PID namespace, and killing every process of the
//! step when its first one ends.

const std = @import("std");
const linux = std.os.linux;

const Allocator = std.mem.Allocator;

/// The helper's subcommand (`main.zig` dispatches it before anything else runs).
pub const command = "native-step";

/// What the helper is told to run. Paths of layers are relative to `root` (the job's directory),
/// which keeps overlay's mount options short however many layers there are.
pub const Spec = struct {
    /// The job's directory: holds the layers, the work directory and the mount point.
    root: []const u8,
    /// Lower layers, top first; the last is the image's rootfs (absolute).
    lowers: []const []const u8,
    /// This step's layer, the overlay work directory and where the overlay is mounted.
    upper: []const u8,
    work: []const u8,
    merged: []const u8,
    /// The step's working directory inside.
    workdir: []const u8,
    /// Who the step runs as inside.
    uid: u32 = 0,
    gid: u32 = 0,
    argv: []const []const u8,
    /// `NAME=value`, the whole environment.
    env: []const []const u8,
    /// Files written into the overlay before the step and removed after it, as Dagger mounts a
    /// secret file for one exec (a script holding a secret, `Resolved.run.script_mounted`).
    files: []const File = &.{},
    /// Host directories mounted into the step (`Backend.Config.binds`).
    binds: []const Bind = &.{},
    /// How the helper gets the privilege to mount (`Userns`).
    userns: Userns,

    pub const Bind = struct { host: []const u8, at: []const u8, read_only: bool = true };

    pub const File = struct {
        path: []const u8,
        contents: []const u8,
        mode: u32 = 0o444,
        /// Left in the layer, as `withNewFile` leaves a file (the event payload).
        keep: bool = false,
    };
};

/// How the helper may mount. `self`: it makes a user namespace itself, mapping the runner's user
/// to root. `inherited`: it was started inside one already (under `unshare -r -m`, where an LSM
/// lets only allow-listed programs make user namespaces, as Ubuntu's AppArmor does). `none`: the
/// runner is root, so no user namespace is needed and steps may run as any user.
pub const Userns = enum { self, inherited, none };

/// What a step ended with: its exit code (128 + n for signal n, as a shell reports it), and the
/// helper's own failure, when the sandbox could not be made.
/// `killed`: it was stopped by `Running.kill`, so its end is not the step's own.
pub const Ended = struct { code: i32, failure: []const u8, killed: bool = false };

/// Starts the helper and streams the step's output to `out` (`Output.chunk`) as it arrives;
/// returns once the step and every process it started have ended. `Running` lets another task
/// stop it (`Running.kill`).
pub fn run(
    arena: Allocator,
    io: std.Io,
    argv_prefix: []const []const u8,
    spec: Spec,
    running: *Running,
    out: Output,
) !Ended {
    const argv = try std.mem.concat(arena, []const u8, &.{ argv_prefix, &.{command} });
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    running.begin(io, child.id.?);
    defer running.end(io);
    // The spec holds the step's secrets: through a pipe, never on disk or on a command line.
    var json: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(spec, .{}, &json.writer);
    child.stdin.?.writeStreamingAll(io, json.written()) catch {};
    child.stdin.?.close(io);
    child.stdin = null;

    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = child.stdout.?.readStreaming(io, &.{&buf}) catch break;
        if (n == 0) break;
        out.chunk(buf[0..n]);
    }
    var failure: std.ArrayList(u8) = .empty;
    while (failure.items.len < max_failure_bytes) {
        const n = child.stderr.?.readStreaming(io, &.{&buf}) catch break;
        if (n == 0) break;
        try failure.appendSlice(arena, buf[0..n]);
    }
    const term = try child.wait(io);
    const code: i32 = switch (term) {
        .exited => |c| c,
        .signal => |s| 128 + @as(i32, @intCast(@backingInt(s))),
        else => 128,
    };
    return .{
        .code = code,
        .failure = std.mem.trimEnd(u8, failure.items, "\n"),
        .killed = running.wasKilled(io),
    };
}

const max_failure_bytes = 16 * 1024;

/// Where `run` hands the step's output, in pieces as read (not lines).
pub const Output = struct {
    ptr: *anyopaque,
    chunkFn: *const fn (ptr: *anyopaque, bytes: []const u8) void,

    fn chunk(o: Output, bytes: []const u8) void {
        o.chunkFn(o.ptr, bytes);
    }
};

/// The helper running now, if any, for `kill` from another task (a timeout or a cancel, through
/// `dagger.Watch`). A pidfd, so a pid reused after the helper was reaped is never signalled.
pub const Running = struct {
    mu: std.Io.Mutex = .init,
    pidfd: ?linux.fd_t = null,
    killed: bool = false,

    fn begin(r: *Running, io: std.Io, pid: linux.pid_t) void {
        const rc = linux.pidfd_open(pid, 0);
        r.mu.lockUncancelable(io);
        defer r.mu.unlock(io);
        r.pidfd = if (linux.errno(rc) == .SUCCESS) @intCast(rc) else null;
        r.killed = false;
    }

    fn wasKilled(r: *Running, io: std.Io) bool {
        r.mu.lockUncancelable(io);
        defer r.mu.unlock(io);
        return r.killed;
    }

    fn end(r: *Running, io: std.Io) void {
        r.mu.lockUncancelable(io);
        defer r.mu.unlock(io);
        if (r.pidfd) |fd| _ = linux.close(fd);
        r.pidfd = null;
    }

    /// Kills the running helper; its step's PID 1 dies with it (`PR_SET_PDEATHSIG`), and with
    /// PID 1 every process in the step's namespace. False when none was running.
    pub fn kill(r: *Running, io: std.Io) bool {
        r.mu.lockUncancelable(io);
        defer r.mu.unlock(io);
        const fd = r.pidfd orelse return false;
        r.killed = linux.errno(linux.pidfd_send_signal(fd, .KILL, null, 0)) == .SUCCESS;
        return r.killed;
    }
};

// --- the helper ---

/// The helper's entry: reads the spec from stdin, runs the step, and exits with its code. Uses
/// only raw system calls once it has the spec, so nothing starts a thread before `unshare`.
pub fn main(arena: Allocator) u8 {
    const spec = readSpec(arena) catch |e| fatal("cannot read the step's spec", @intFromError(e));
    return runStep(arena, spec);
}

fn readSpec(arena: Allocator) !Spec {
    var data: std.ArrayList(u8) = .empty;
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const rc = linux.read(0, &buf, buf.len);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return error.ReadFailed,
        }
        if (rc == 0) break;
        try data.appendSlice(arena, buf[0..rc]);
    }
    return std.json.parseFromSliceLeaky(Spec, arena, data.items, .{ .allocate = .alloc_always });
}

fn runStep(arena: Allocator, spec: Spec) u8 {
    // The step gets no stdin, as on GitHub.
    const devnull = linux.open("/dev/null", .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(devnull) == .SUCCESS) _ = linux.dup2(@intCast(devnull), 0);

    // 1. The privilege to mount: a user namespace mapping this user to root, unless we have it.
    switch (spec.userns) {
        .self => enterUserns(),
        .inherited => {},
        .none => check("unshare(mount)", linux.unshare(linux.CLONE.NEWNS)),
    }
    check("make / private", linux.mount(null, "/", null, linux.MS.REC | linux.MS.PRIVATE, 0));

    // 2. The overlay: this step's layer over every earlier one and the rootfs.
    const root = z(arena, spec.root);
    check("chdir to the job directory", linux.chdir(root));
    var opts: std.ArrayList(u8) = .empty;
    opts.appendSlice(arena, "lowerdir=") catch oom();
    for (spec.lowers, 0..) |l, i| {
        if (i > 0) opts.append(arena, ':') catch oom();
        opts.appendSlice(arena, l) catch oom();
    }
    opts.print(arena, ",upperdir={s},workdir={s}", .{ spec.upper, spec.work }) catch oom();
    // Unprivileged overlay keeps its own metadata in `user.` xattrs (Linux 5.11).
    if (spec.userns != .none) opts.appendSlice(arena, ",userxattr") catch oom();
    opts.append(arena, 0) catch oom();
    const merged = z(arena, spec.merged);
    check("mount the overlay", linux.mount(
        "overlay",
        merged,
        "overlay",
        0,
        @intFromPtr(opts.items.ptr),
    ));
    for (spec.binds) |bd| {
        const at = z(arena, joinRoot(arena, spec.merged, bd.at));
        check("bind a host directory", linux.mount(
            z(arena, bd.host),
            at,
            null,
            linux.MS.BIND | linux.MS.REC,
            0,
        ));
        if (bd.read_only) _ = linux.mount(
            null,
            at,
            null,
            linux.MS.REMOUNT | linux.MS.BIND | linux.MS.RDONLY,
            0,
        );
    }
    for (spec.files) |f| writeFile(arena, spec.merged, f);
    // The host's resolver and hosts, as BuildKit gives every exec (it shares the host's
    // network, so the host's resolver works).
    for ([_][]const u8{ "/etc/resolv.conf", "/etc/hosts" }) |p| bindFile(arena, spec.merged, p);

    // 3. The step's own namespaces; its first process is PID 1 of the new PID namespace.
    check("unshare(pid, uts, ipc)", linux.unshare(
        linux.CLONE.NEWPID | linux.CLONE.NEWUTS | linux.CLONE.NEWIPC,
    ));
    const argv = zList(arena, spec.argv);
    const envp = zList(arena, withHome(arena, spec));
    const workdir = z(arena, spec.workdir);
    const pid = linux.fork();
    check("fork", pid);
    if (pid == 0) stepInit(arena, merged, workdir, spec.uid, spec.gid, argv, envp);

    var status: i32 = 0;
    while (true) {
        const rc = linux.waitpid(@intCast(pid), &status, 0);
        if (linux.errno(rc) == .INTR) continue;
        check("wait for the step", rc);
        break;
    }
    for (spec.files) |f| if (!f.keep) {
        _ = linux.unlink(z(arena, joinRoot(arena, spec.merged, f.path)));
    };
    _ = linux.umount2(merged, linux.MNT.DETACH);
    const st: u32 = @bitCast(status);
    if (linux.W.IFEXITED(st)) return linux.W.EXITSTATUS(st);
    if (linux.W.IFSIGNALED(st)) return @truncate(128 + @backingInt(linux.W.TERMSIG(st)));
    return 128;
}

/// PID 1 of the step: its /dev, /proc and /sys, then chroot, its user, and the shell. Never
/// returns.
fn stepInit(
    arena: Allocator,
    merged: [*:0]const u8,
    workdir: [*:0]const u8,
    uid: u32,
    gid: u32,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
) noreturn {
    // Dies with the helper: the runner stops a step by killing the helper (`Running.kill`).
    _ = linux.prctl(@backingInt(linux.PR.SET_PDEATHSIG), @backingInt(linux.SIG.KILL), 0, 0, 0);
    const m = std.mem.span(merged);
    makeDev(arena, m);
    check("mount /proc", linux.mount(
        "proc",
        z(arena, joinRoot(arena, m, "/proc")),
        "proc",
        linux.MS.NOSUID | linux.MS.NODEV | linux.MS.NOEXEC,
        0,
    ));
    // The host's /sys, read-only, as BuildKit mounts sysfs read-only. A new sysfs needs a
    // network namespace of our own, which steps do not have (they share the host's, as in Dagger).
    const sys = z(arena, joinRoot(arena, m, "/sys"));
    if (linux.errno(linux.mount("/sys", sys, null, linux.MS.BIND | linux.MS.REC, 0)) == .SUCCESS)
        _ = linux.mount(null, sys, null, linux.MS.REMOUNT | linux.MS.BIND | linux.MS.RDONLY, 0);
    check("chroot", linux.chroot(merged));
    if (linux.errno(linux.chdir(workdir)) != .SUCCESS) check("chdir /", linux.chdir("/"));
    if (uid != 0 or gid != 0) {
        check("setgroups", linux.setgroups(0, @ptrFromInt(8)));
        check("setgid", linux.setgid(gid));
        check("setuid", linux.setuid(uid));
    }
    // From here the helper's failures would be the step's output; the step's stderr is its
    // stdout, as the script's `exec 2>&1` would make it anyway.
    _ = linux.dup2(1, 2);
    const rc = linux.execve("/bin/sh", argv, envp);
    fatal("exec /bin/sh", @backingInt(linux.errno(rc)));
}

/// A /dev of the nodes a step needs, bound from the host's, as runc builds one: not the host's
/// whole /dev, which would hand a root step its disks.
fn makeDev(arena: Allocator, m: []const u8) void {
    const dev = joinRoot(arena, m, "/dev");
    check("mount /dev", linux.mount(
        "tmpfs",
        z(arena, dev),
        "tmpfs",
        linux.MS.NOSUID | linux.MS.NOEXEC,
        @intFromPtr("mode=755,size=65536k"),
    ));
    for ([_][]const u8{ "null", "zero", "full", "random", "urandom", "tty" }) |name| {
        const host = z(arena, std.fmt.allocPrint(arena, "/dev/{s}", .{name}) catch oom());
        const at = z(arena, std.fmt.allocPrint(arena, "{s}/{s}", .{ dev, name }) catch oom());
        const fd = linux.open(at, .{ .ACCMODE = .WRONLY, .CREAT = true }, 0o666);
        if (linux.errno(fd) == .SUCCESS) _ = linux.close(@intCast(fd));
        check("bind a /dev node", linux.mount(host, at, null, linux.MS.BIND, 0));
    }
    for ([_][]const u8{ "pts", "shm", "mqueue" }) |d| {
        const sub = std.fmt.allocPrint(arena, "{s}/{s}", .{ dev, d }) catch oom();
        _ = linux.mkdir(z(arena, sub), 0o755);
    }
    check("mount /dev/pts", linux.mount(
        "devpts",
        z(arena, std.fmt.allocPrint(arena, "{s}/pts", .{dev}) catch oom()),
        "devpts",
        linux.MS.NOSUID | linux.MS.NOEXEC,
        @intFromPtr("newinstance,ptmxmode=0666,mode=0620"),
    ));
    check("mount /dev/shm", linux.mount(
        "shm",
        z(arena, std.fmt.allocPrint(arena, "{s}/shm", .{dev}) catch oom()),
        "tmpfs",
        linux.MS.NOSUID | linux.MS.NODEV | linux.MS.NOEXEC,
        @intFromPtr("mode=1777,size=65536k"),
    ));
    const links = [_][2][]const u8{
        .{ "pts/ptmx", "ptmx" },
        .{ "/proc/self/fd", "fd" },
        .{ "/proc/self/fd/0", "stdin" },
        .{ "/proc/self/fd/1", "stdout" },
        .{ "/proc/self/fd/2", "stderr" },
    };
    for (links) |l| _ = linux.symlink(
        z(arena, l[0]),
        z(arena, std.fmt.allocPrint(arena, "{s}/{s}", .{ dev, l[1] }) catch oom()),
    );
}

fn enterUserns() void {
    const uid = linux.getuid();
    const gid = linux.getgid();
    check("unshare(user, mount)", linux.unshare(linux.CLONE.NEWUSER | linux.CLONE.NEWNS));
    var buf: [64]u8 = undefined;
    writeProc("/proc/self/setgroups", "deny");
    writeProc("/proc/self/uid_map", std.fmt.bufPrint(&buf, "0 {d} 1", .{uid}) catch unreachable);
    writeProc("/proc/self/gid_map", std.fmt.bufPrint(&buf, "0 {d} 1", .{gid}) catch unreachable);
}

fn writeProc(path: [*:0]const u8, text: []const u8) void {
    const fd = linux.open(path, .{ .ACCMODE = .WRONLY }, 0);
    check("open a user namespace map", fd);
    defer _ = linux.close(@intCast(fd));
    check("write a user namespace map", linux.write(@intCast(fd), text.ptr, text.len));
}

/// The env, with HOME from the image's /etc/passwd when it has none: runc sets it so, and every
/// step under Dagger saw it.
fn withHome(arena: Allocator, spec: Spec) []const []const u8 {
    for (spec.env) |e| if (std.mem.startsWith(u8, e, "HOME=")) return spec.env;
    const home = passwdHome(arena, spec, spec.uid) orelse "/";
    const extra = std.fmt.allocPrint(arena, "HOME={s}", .{home}) catch oom();
    return std.mem.concat(arena, []const u8, &.{ spec.env, &.{extra} }) catch oom();
}

/// The home directory of `uid` in /etc/passwd as the step sees it.
fn passwdHome(arena: Allocator, spec: Spec, uid: u32) ?[]const u8 {
    const path = z(arena, joinRoot(arena, spec.merged, "/etc/passwd"));
    const fd = linux.open(path, .{ .ACCMODE = .RDONLY }, 0);
    if (linux.errno(fd) != .SUCCESS) return null;
    defer _ = linux.close(@intCast(fd));
    var buf: [64 * 1024]u8 = undefined;
    const n = linux.read(@intCast(fd), &buf, buf.len);
    if (linux.errno(n) != .SUCCESS) return null;
    return homeOf(buf[0..n], uid);
}

/// `uid`'s home directory in the text of an /etc/passwd.
pub fn homeOf(passwd: []const u8, uid: u32) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, passwd, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, ':');
        var f: [7][]const u8 = undefined;
        var i: usize = 0;
        while (fields.next()) |v| : (i += 1) {
            if (i == f.len) break;
            f[i] = v;
        }
        if (i < 6) continue;
        const id = std.fmt.parseInt(u32, f[2], 10) catch continue;
        if (id == uid) return f[5];
    }
    return null;
}

/// Writes `f` into the overlay, its missing parents made as `withNewFile` makes them (root's,
/// 0755).
fn writeFile(arena: Allocator, merged: []const u8, f: Spec.File) void {
    const full = joinRoot(arena, merged, f.path);
    var i: usize = merged.len + 1;
    while (std.mem.indexOfScalarPos(u8, full, i, '/')) |slash| : (i = slash + 1)
        _ = linux.mkdir(z(arena, full[0..slash]), 0o755);
    const path = z(arena, full);
    const fd = linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, f.mode);
    check("write a file for the step", fd);
    defer _ = linux.close(@intCast(fd));
    var done: usize = 0;
    while (done < f.contents.len) {
        const rc = linux.write(@intCast(fd), f.contents[done..].ptr, f.contents.len - done);
        check("write a file for the step", rc);
        done += rc;
    }
}

/// Binds the host's file over the image's, when the image has one to bind onto: creating it
/// would put a file in the step's layer, which Dagger's exec does not.
fn bindFile(arena: Allocator, merged: []const u8, path: []const u8) void {
    const at = z(arena, joinRoot(arena, merged, path));
    if (linux.errno(linux.access(at, linux.F_OK)) != .SUCCESS) return;
    _ = linux.mount(z(arena, path), at, null, linux.MS.BIND, 0);
}

fn joinRoot(arena: Allocator, root: []const u8, path: []const u8) []const u8 {
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ root, std.mem.trimStart(u8, path, "/") }) catch
        oom();
}

fn z(arena: Allocator, s: []const u8) [*:0]const u8 {
    return (arena.dupeSentinel(u8, s, 0) catch oom()).ptr;
}

fn zList(arena: Allocator, items: []const []const u8) [*:null]const ?[*:0]const u8 {
    const out = arena.allocSentinel(?[*:0]const u8, items.len, null) catch oom();
    for (items, out) |s, *o| o.* = z(arena, s);
    return out.ptr;
}

/// A failed system call ends the helper with the reason on its stderr, which the runner reports
/// as the sandbox's failure, not the step's.
fn check(what: []const u8, rc: usize) void {
    const e = linux.errno(rc);
    if (e != .SUCCESS) fatal(what, @backingInt(e));
}

fn fatal(what: []const u8, code: anytype) noreturn {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "native step: {s} failed (errno {d})\n", .{
        what,
        code,
    }) catch "native step: failed\n";
    _ = linux.write(2, msg.ptr, msg.len);
    linux.exit_group(125);
}

fn oom() noreturn {
    fatal("allocate", @as(u32, 12));
}

test "homeOf reads the home directory of a uid from /etc/passwd" {
    const passwd = "root:x:0:0:root:/root:/bin/bash\n" ++
        "daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin\n" ++
        "runner:x:1001:1001::/home/runner:/bin/bash\n";
    try std.testing.expectEqualStrings("/root", homeOf(passwd, 0).?);
    try std.testing.expectEqualStrings("/home/runner", homeOf(passwd, 1001).?);
    try std.testing.expect(homeOf(passwd, 7) == null);
    try std.testing.expect(homeOf("garbage", 0) == null);
}
