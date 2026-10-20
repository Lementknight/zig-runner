//! A small HTTP/1.1 server for tests, on 127.0.0.1 and an ephemeral port, answering each request by
//! its path. The client's handling of redirects and tokens is then tested over real connections:
//! a unit test that only described the request once passed while every request had lost its token
//! (`broker.request`). "localhost" reaches the same server under another host name, which is what a
//! redirect to another host needs.
//!
//!   /echo        200, body "<method> <Authorization header, or ->"
//!   /same        302 to http://127.0.0.1:<port>/echo
//!   /other       302 to http://localhost:<port>/echo
//!   /relative    302 to /echo
//!   /see-other   303 to /echo
//!   /loop        302 to /loop
//!   anything else 404
const std = @import("std");
const Io = std.Io;

pub const Server = struct {
    listener: Io.net.Server,
    port: u16,
    thread: std.Thread,

    /// Listens and serves on a thread of its own until `stop`.
    pub fn start(s: *Server) !void {
        const io = std.testing.io;
        const addr = try Io.net.IpAddress.parse("127.0.0.1", 0);
        s.listener = try addr.listen(io, .{ .reuse_address = true });
        s.port = s.listener.socket.address.getPort();
        s.thread = try std.Thread.spawn(.{}, serve, .{s});
    }

    /// A last request tells the thread to stop (closing the listener does not wake a blocked
    /// accept everywhere), then it is joined.
    pub fn stop(s: *Server) void {
        const io = std.testing.io;
        if (connect(s.port)) |conn| {
            var wb: [64]u8 = undefined;
            var w = conn.writer(io, &wb);
            w.interface.writeAll("GET /quit HTTP/1.1\r\nHost: x\r\n\r\n") catch {};
            w.interface.flush() catch {};
            conn.close(io);
        } else |_| {}
        s.thread.join();
        s.listener.deinit(io);
    }

    /// `http://<host>:<port><path>` on `buf`.
    pub fn url(s: *const Server, buf: []u8, host: []const u8, path: []const u8) []const u8 {
        const port = s.port;
        return std.fmt.bufPrint(buf, "http://{s}:{d}{s}", .{ host, port, path }) catch unreachable;
    }

    fn serve(s: *Server) void {
        while (true) {
            const conn = s.listener.accept(std.testing.io) catch return;
            defer conn.close(std.testing.io);
            if (!answer(s.port, conn)) return;
        }
    }
};

fn connect(port: u16) !Io.net.Stream {
    const addr = try Io.net.IpAddress.parse("127.0.0.1", port);
    return addr.connect(std.testing.io, .{ .mode = .stream });
}

/// One request on `conn`, answered and the connection closed. False for /quit.
fn answer(port: u16, conn: Io.net.Stream) bool {
    const io = std.testing.io;
    var rb: [4096]u8 = undefined;
    var r = conn.reader(io, &rb);
    const first = r.interface.takeDelimiterInclusive('\n') catch return true;
    var parts = std.mem.tokenizeAny(u8, first, " \r\n");
    var method_buf: [16]u8 = undefined;
    const method = copy(&method_buf, parts.next() orelse return true);
    var path_buf: [256]u8 = undefined;
    const path = copy(&path_buf, parts.next() orelse return true);

    var auth_buf: [512]u8 = undefined;
    var auth: []const u8 = "-";
    var body_len: usize = 0;
    while (true) {
        const line = r.interface.takeDelimiterInclusive('\n') catch return true;
        const header = std.mem.trimEnd(u8, line, "\r\n");
        if (header.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, header, ':') orelse continue;
        const name = header[0..colon];
        const value = std.mem.trim(u8, header[colon + 1 ..], " ");
        if (std.ascii.eqlIgnoreCase(name, "authorization")) auth = copy(&auth_buf, value);
        if (std.ascii.eqlIgnoreCase(name, "content-length"))
            body_len = std.fmt.parseInt(usize, value, 10) catch 0;
    }
    r.interface.discardAll(body_len) catch {};
    if (std.mem.eql(u8, path, "/quit")) return false;

    var wb: [1024]u8 = undefined;
    var w = conn.writer(io, &wb);
    const out = &w.interface;
    var loc_buf: [128]u8 = undefined;
    if (std.mem.eql(u8, path, "/echo")) {
        var body_buf: [600]u8 = undefined;
        const body = std.fmt.bufPrint(&body_buf, "{s} {s}", .{ method, auth }) catch return true;
        respond(out, "200 OK", null, body);
    } else if (std.mem.eql(u8, path, "/same")) {
        respond(out, "302 Found", fmtLoc(&loc_buf, "127.0.0.1", port), "");
    } else if (std.mem.eql(u8, path, "/other")) {
        respond(out, "302 Found", fmtLoc(&loc_buf, "localhost", port), "");
    } else if (std.mem.eql(u8, path, "/relative")) {
        respond(out, "302 Found", "/echo", "");
    } else if (std.mem.eql(u8, path, "/see-other")) {
        respond(out, "303 See Other", "/echo", "");
    } else if (std.mem.eql(u8, path, "/loop")) {
        respond(out, "302 Found", "/loop", "");
    } else {
        respond(out, "404 Not Found", null, "");
    }
    out.flush() catch {};
    return true;
}

fn respond(out: *Io.Writer, status: []const u8, location: ?[]const u8, body: []const u8) void {
    out.print("HTTP/1.1 {s}\r\nContent-Length: {d}\r\nConnection: close\r\n", .{
        status,
        body.len,
    }) catch return;
    if (location) |l| out.print("Location: {s}\r\n", .{l}) catch return;
    out.print("\r\n{s}", .{body}) catch return;
}

fn fmtLoc(buf: []u8, host: []const u8, port: u16) []const u8 {
    return std.fmt.bufPrint(buf, "http://{s}:{d}/echo", .{ host, port }) catch unreachable;
}

fn copy(buf: []u8, s: []const u8) []const u8 {
    const n = @min(buf.len, s.len);
    @memcpy(buf[0..n], s[0..n]);
    return buf[0..n];
}
