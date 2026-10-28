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
//!   /unavailable/...  503
//!   /broker/message?...  200, a `RunnerJobRequest` whose run service is /nowhere (so acquirejob
//!                answers 404); each one counted in `Server.polls`
//!   /silent      never answered: the connection stays open, as one to a peer that went away
//!                without a word does (written to, never read from)
//!   /silent-once/...  never answered the first time (of all such paths), 200 "ok" after that
//!   /keep        200 "kept", and the connection kept alive; the next request on it is never
//!                answered, as on a kept-alive connection GitHub dropped silently while idle
//!   /keep-close  200 "kept", the connection kept alive as far as the client knows, then closed
//!   anything else 404
//!
//! Every connection accepted is counted in `Server.accepts`.
const std = @import("std");
const Io = std.Io;

pub const Server = struct {
    listener: Io.net.Server,
    port: u16,
    thread: std.Thread,
    /// Requests to /broker/message so far.
    polls: std.atomic.Value(u32),
    /// Connections accepted so far.
    accepts: std.atomic.Value(u32),
    /// Requests to /silent-once/... so far.
    silent_once: u32,
    /// Connections left unanswered (/silent, /keep), closed by `stop`; used by the thread only.
    held: [8]Io.net.Stream,
    held_len: usize,

    /// Listens and serves on a thread of its own until `stop`.
    pub fn start(s: *Server) !void {
        const io = std.testing.io;
        const addr = try Io.net.IpAddress.parse("127.0.0.1", 0);
        s.listener = try addr.listen(io, .{ .reuse_address = true });
        s.port = s.listener.socket.address.getPort();
        s.polls = .init(0);
        s.accepts = .init(0);
        s.silent_once = 0;
        s.held_len = 0;
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
        for (s.held[0..s.held_len]) |conn| conn.close(io);
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
            _ = s.accepts.fetchAdd(1, .acq_rel);
            switch (answer(s, conn)) {
                .close => conn.close(std.testing.io),
                .hold => if (s.held_len < s.held.len) {
                    s.held[s.held_len] = conn;
                    s.held_len += 1;
                } else conn.close(std.testing.io),
                .quit => {
                    conn.close(std.testing.io);
                    return;
                },
            }
        }
    }
};

/// What becomes of a connection once its request is answered (or not).
const Outcome = enum { close, hold, quit };

fn connect(port: u16) !Io.net.Stream {
    const addr = try Io.net.IpAddress.parse("127.0.0.1", port);
    return addr.connect(std.testing.io, .{ .mode = .stream });
}

/// One request on `conn`, answered or not, and what becomes of the connection.
fn answer(s: *Server, conn: Io.net.Stream) Outcome {
    const io = std.testing.io;
    const port = s.port;
    var rb: [4096]u8 = undefined;
    var r = conn.reader(io, &rb);
    const first = r.interface.takeDelimiterInclusive('\n') catch return .close;
    var parts = std.mem.tokenizeAny(u8, first, " \r\n");
    var method_buf: [16]u8 = undefined;
    const method = copy(&method_buf, parts.next() orelse return .close);
    var path_buf: [256]u8 = undefined;
    const path = copy(&path_buf, parts.next() orelse return .close);

    var auth_buf: [512]u8 = undefined;
    var auth: []const u8 = "-";
    var body_len: usize = 0;
    while (true) {
        const line = r.interface.takeDelimiterInclusive('\n') catch return .close;
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
    if (std.mem.eql(u8, path, "/quit")) return .quit;
    if (std.mem.eql(u8, path, "/silent")) return .hold;
    if (std.mem.startsWith(u8, path, "/silent-once/")) {
        s.silent_once += 1;
        if (s.silent_once == 1) return .hold;
    }

    var wb: [1024]u8 = undefined;
    var w = conn.writer(io, &wb);
    const out = &w.interface;
    var loc_buf: [128]u8 = undefined;
    if (std.mem.eql(u8, path, "/echo")) {
        var body_buf: [600]u8 = undefined;
        const body = std.fmt.bufPrint(&body_buf, "{s} {s}", .{ method, auth }) catch return .close;
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
    } else if (std.mem.startsWith(u8, path, "/unavailable/")) {
        respond(out, "503 Service Unavailable", null, "");
    } else if (std.mem.startsWith(u8, path, "/broker/message?")) {
        _ = s.polls.fetchAdd(1, .acq_rel);
        var body_buf: [256]u8 = undefined;
        const body = std.fmt.bufPrint(
            &body_buf,
            "{{\"messageType\":\"RunnerJobRequest\",\"body\":\"{{\\\"runner_request_id\\\":" ++
                "\\\"r\\\",\\\"run_service_url\\\":\\\"http://127.0.0.1:{d}/nowhere\\\"}}\"}}",
            .{port},
        ) catch return .close;
        respond(out, "200 OK", null, body);
    } else if (std.mem.startsWith(u8, path, "/silent-once/")) {
        respond(out, "200 OK", null, "ok");
    } else if (std.mem.eql(u8, path, "/keep") or std.mem.eql(u8, path, "/keep-close")) {
        out.writeAll("HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nkept") catch {};
        out.flush() catch {};
        return if (std.mem.eql(u8, path, "/keep")) .hold else .close;
    } else {
        respond(out, "404 Not Found", null, "");
    }
    out.flush() catch {};
    return .close;
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
