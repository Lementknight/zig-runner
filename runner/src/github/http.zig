//! The process's HTTP client. One client loads the CA bundle once and keeps connections alive; a
//! client per request (what the runner did before) loaded the bundle every time, into memory that a
//! waiting runner only frees after its next job, so idle runners grew by hundreds of KB per poll.
const std = @import("std");
const builtin = @import("builtin");

/// Set by `main` for the runner (its allocator must be thread-safe: runners share it). Unset in
/// tests and one-off commands, where each request gets its own client. `renew` replaces it.
pub var shared: std.atomic.Value(?*std.http.Client) = .init(null);

/// The shared client, or `local` (owned by the caller) when there is none.
pub fn client(local: *std.http.Client) *std.http.Client {
    return shared.load(.acquire) orelse local;
}

/// Replaces the shared client with a new one, unless that already happened since `stale` was taken.
/// A client checks certificates against the time of its first HTTPS request (`Client.now`, which
/// std never moves and cannot safely move while it is in use), so after a process has run for a
/// while, a certificate issued since it started is "not yet valid" and every new connection to that
/// host fails. A new client takes the time again and rescans the system's root certificates. The
/// old one is never freed: a job's live feed holds one of its connections for as long as the job
/// runs.
pub fn renew(stale: *std.http.Client) void {
    const gpa = stale.allocator;
    const fresh = gpa.create(std.http.Client) catch return;
    fresh.* = .{ .allocator = gpa, .io = stale.io, .write_buffer_size = stale.write_buffer_size };
    if (shared.cmpxchgStrong(stale, fresh, .acq_rel, .acquire) != null) gpa.destroy(fresh);
}

/// Whether `err` is a certificate judged by a client's stale clock (see `renew`).
pub fn staleClock(err: anyerror) bool {
    return err == error.CertificateNotYetValid or err == error.CertificateExpired;
}

/// `client.fetch`, tried again while a kept-alive connection turns out to be closed (no byte came
/// back, so nothing was processed or written; see `broker.request`).
pub fn fetch(
    c: *std.http.Client,
    options: std.http.Client.FetchOptions,
) !std.http.Client.FetchResult {
    var attempt: u32 = 0;
    var cl = c;
    var renewed = false;
    while (true) : (attempt += 1) {
        return cl.fetch(options) catch |err| switch (err) {
            error.HttpConnectionClosing => if (attempt < 8) continue else err,
            else => if (!renewed and staleClock(err) and shared.load(.acquire) == cl) {
                renew(cl);
                cl = shared.load(.acquire).?;
                renewed = true;
                continue;
            } else err,
        };
    }
}

/// Seconds idle before a connection is probed, between probes, and probes unanswered before it is
/// given up: a peer that went away (the machine slept, the network dropped) is noticed within about
/// 90 s even by a request that is only waiting to read, which nothing else would ever interrupt.
pub const keepalive_idle_secs = 60;
pub const keepalive_interval_secs = 10;
pub const keepalive_probes = 3;

/// Turns on TCP keepalive for a connection's socket. Best effort: a socket that refuses keeps
/// working as before.
pub fn keepAlive(fd: std.posix.socket_t) void {
    if (builtin.os.tag != .linux) return;
    const linux = std.os.linux;
    const on: c_int = 1;
    const idle: c_int = keepalive_idle_secs;
    const interval: c_int = keepalive_interval_secs;
    const probes: c_int = keepalive_probes;
    const P = std.posix;
    P.setsockopt(fd, linux.SOL.SOCKET, linux.SO.KEEPALIVE, std.mem.asBytes(&on)) catch return;
    P.setsockopt(fd, linux.IPPROTO.TCP, linux.TCP.KEEPIDLE, std.mem.asBytes(&idle)) catch {};
    P.setsockopt(fd, linux.IPPROTO.TCP, linux.TCP.KEEPINTVL, std.mem.asBytes(&interval)) catch {};
    P.setsockopt(fd, linux.IPPROTO.TCP, linux.TCP.KEEPCNT, std.mem.asBytes(&probes)) catch {};
}

test "keepAlive turns TCP keepalive on, with its timings" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const io = std.testing.io;
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var listener = try addr.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);
    const stream = try listener.socket.address.connect(io, .{ .mode = .stream });
    defer stream.close(io);
    const fd = stream.socket.handle;

    keepAlive(fd);
    const linux = std.os.linux;
    const Opt = struct { level: i32, name: u32, want: c_int };
    for ([_]Opt{
        .{ .level = linux.SOL.SOCKET, .name = linux.SO.KEEPALIVE, .want = 1 },
        .{ .level = linux.IPPROTO.TCP, .name = linux.TCP.KEEPIDLE, .want = keepalive_idle_secs },
        .{
            .level = linux.IPPROTO.TCP,
            .name = linux.TCP.KEEPINTVL,
            .want = keepalive_interval_secs,
        },
        .{ .level = linux.IPPROTO.TCP, .name = linux.TCP.KEEPCNT, .want = keepalive_probes },
    }) |o| {
        var got: c_int = 0;
        var len: linux.socklen_t = @sizeOf(c_int);
        const rc = linux.getsockopt(fd, o.level, o.name, std.mem.asBytes(&got), &len);
        try std.testing.expectEqual(@as(usize, 0), rc);
        try std.testing.expectEqual(o.want, got);
    }
}

test "renew replaces the shared client once, however many saw it go stale" {
    const gpa = std.testing.allocator;
    var first: std.http.Client = .{ .allocator = gpa, .io = std.testing.io };
    defer first.deinit();
    shared.store(&first, .release);
    defer shared.store(null, .release);

    renew(&first);
    const second = shared.load(.acquire).?;
    defer gpa.destroy(second);
    defer second.deinit();
    try std.testing.expect(second != &first);
    try std.testing.expect(second.now == null); // takes the time again on its first request
    // A second runner that saw the same stale client finds it already replaced.
    renew(&first);
    try std.testing.expectEqual(second, shared.load(.acquire).?);
}
