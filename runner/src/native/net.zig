//! A job's own network on a root runner (docs/native-backend.md, P1): a network namespace for all
//! of the job's steps, joined to a bridge of the runner's (`bridge`) by a veth pair, with an
//! address of its own and a default route through the bridge. So each job has its own `lo` and
//! port space, and no step reaches the host's 127.0.0.1. Dagger gives each exec the same through
//! BuildKit's CNI network.
//!
//! Links, addresses and routes are made over rtnetlink here, with no `ip`. The NAT that takes the
//! jobs' traffic out is made with `iptables` (`natRules`): debt, recorded in the plan.

const std = @import("std");
const linux = std.os.linux;

const Allocator = std.mem.Allocator;

/// The runner's bridge, its address, and the network the jobs' addresses come from.
pub const bridge = "zr0";
pub const gateway = [4]u8{ 10, 88, 0, 1 };
pub const subnet = "10.88.0.0/16";
const prefix_len = 16;
/// Slots beyond this have no address (`jobAddress`).
pub const max_slots = 250;

/// Slot `n`'s address in the jobs' network.
pub fn jobAddress(slot: u32) [4]u8 {
    std.debug.assert(slot < max_slots);
    return .{ 10, 88, 1, @intCast(slot + 2) };
}

/// The host's end of slot `n`'s veth pair; the job's end is named `eth0` inside its namespace.
pub fn hostLink(buf: *[16]u8, slot: u32) []const u8 {
    return std.fmt.bufPrint(buf, "zrh{d}", .{slot}) catch unreachable;
}

/// The helper's subcommand that makes a job's network (`main.zig` dispatches it):
/// `zig-runner native-net <namespace file> <slot>`.
pub const command = "native-net";

/// The helper's entry: the bridge (if it is not there), a new network namespace kept by
/// bind-mounting it over `path`, with what a step needs in it (`lo`, ports below 1024 and ping
/// without capabilities on the host's, since the namespace's owner is the host's root, not the
/// job's), then the slot's veth pair, its address and the default route. A helper, as a thread of
/// the runner must not change its namespace. Exits 0, or 1 with why on stderr.
pub fn upMain(arena: Allocator, path: []const u8, slot_text: []const u8) u8 {
    const slot = std.fmt.parseInt(u32, slot_text, 10) catch return fail("a slot number", .INVAL);
    if (slot >= max_slots) return fail("a slot number", .INVAL);
    var host = Socket.open() catch return fail("open rtnetlink", .ACCES);
    // A veth of this slot is a dead job's: the slot's lock was free.
    host.deleteVeth(slot);
    host.ensureBridge() catch return fail("make the bridge " ++ bridge, .INVAL);
    const unshared = linux.unshare(linux.CLONE.NEWNET);
    if (linux.errno(unshared) != .SUCCESS) return fail("unshare(net)", linux.errno(unshared));
    var job = Socket.open() catch return fail("open rtnetlink in the job's namespace", .ACCES);
    const sysctls = [_][2][]const u8{
        .{ "/proc/sys/net/ipv4/ip_unprivileged_port_start", "0" },
        .{ "/proc/sys/net/ipv4/ping_group_range", "0 2147483647" },
    };
    for (sysctls) |kv| {
        const fd = linux.open(z(arena, kv[0]), .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0);
        if (linux.errno(fd) != .SUCCESS) return fail("open a sysctl", linux.errno(fd));
        _ = linux.write(@intCast(fd), kv[1].ptr, kv[1].len);
        _ = linux.close(@intCast(fd));
    }
    const flags: linux.O = .{ .ACCMODE = .RDONLY, .CREAT = true, .CLOEXEC = true };
    const file = linux.open(z(arena, path), flags, 0o444);
    if (linux.errno(file) != .SUCCESS) return fail("make the namespace's file", linux.errno(file));
    _ = linux.close(@intCast(file));
    const kept = linux.mount("/proc/self/ns/net", z(arena, path), null, linux.MS.BIND, 0);
    if (linux.errno(kept) != .SUCCESS) return fail("keep the namespace", linux.errno(kept));
    const ns = linux.open("/proc/self/ns/net", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(ns) != .SUCCESS) return fail("open the namespace", linux.errno(ns));
    host.addVeth(slot, @intCast(ns)) catch return fail("make the veth pair", .INVAL);
    job.configureJob(slot) catch return fail("configure the job's network", .INVAL);
    return 0;
}

fn fail(what: []const u8, e: linux.E) u8 {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "native net: {s} failed ({s})\n", .{
        what,
        @tagName(e),
    }) catch
        "native net: failed\n";
    _ = linux.write(2, msg.ptr, msg.len);
    return 1;
}

fn z(arena: Allocator, s: []const u8) [*:0]const u8 {
    const out: [:0]const u8 = arena.dupeSentinel(u8, s, 0) catch "";
    return out.ptr;
}

/// An rtnetlink socket in the network namespace the calling thread was in when it was opened,
/// with a datagram socket of that namespace for looking links up by name (`index`). A socket stays
/// in the namespace it was made in, whichever the thread moves to: `upMain` holds one for the
/// host's and one for the job's.
pub const Socket = struct {
    fd: linux.fd_t,
    ioctl_fd: linux.fd_t,
    seq: u32 = 1,

    pub fn open() !Socket {
        const rc = linux.socket(linux.AF.NETLINK, linux.SOCK.RAW | linux.SOCK.CLOEXEC, 0);
        if (linux.errno(rc) != .SUCCESS) return error.NetlinkSocket;
        const dgram = linux.socket(linux.AF.INET, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0);
        if (linux.errno(dgram) != .SUCCESS) {
            _ = linux.close(@intCast(rc));
            return error.NetlinkSocket;
        }
        return .{ .fd = @intCast(rc), .ioctl_fd = @intCast(dgram) };
    }

    pub fn close(s: *Socket) void {
        _ = linux.close(s.fd);
        _ = linux.close(s.ioctl_fd);
    }

    /// Sends one request and reads its acknowledgement: the kernel's errno, `.SUCCESS` for none.
    fn request(s: *Socket, msg: *Message) linux.E {
        s.seq += 1;
        msg.finish(s.seq);
        const sent = linux.sendto(s.fd, msg.buf[0..msg.len].ptr, msg.len, 0, null, 0);
        if (linux.errno(sent) != .SUCCESS) return linux.errno(sent);
        var buf: [4096]u8 align(4) = undefined;
        while (true) {
            const n = linux.recvfrom(s.fd, &buf, buf.len, 0, null, null);
            if (linux.errno(n) == .INTR) continue;
            if (linux.errno(n) != .SUCCESS) return linux.errno(n);
            var off: usize = 0;
            while (off + @sizeOf(linux.nlmsghdr) <= n) {
                const h: *const linux.nlmsghdr = @ptrCast(@alignCast(&buf[off]));
                if (h.seq == s.seq and h.type == .ERROR) {
                    const at = off + @sizeOf(linux.nlmsghdr);
                    const code: *const i32 = @ptrCast(@alignCast(&buf[at]));
                    if (code.* == 0) return .SUCCESS;
                    return @fromBackingInt(@intCast(@as(u16, @intCast(-code.*))));
                }
                off += std.mem.alignForward(usize, h.len, 4);
                if (h.len == 0) break;
            }
        }
    }

    /// A link's index in the socket's namespace, or null when there is none of that name.
    pub fn index(s: *Socket, name: []const u8) ?i32 {
        var req: extern struct { name: [16]u8, index: i32, pad: [20]u8 } = .{
            .name = @splat(0),
            .index = 0,
            .pad = @splat(0),
        };
        @memcpy(req.name[0..name.len], name);
        const siocgifindex = 0x8933;
        if (linux.errno(linux.ioctl(s.ioctl_fd, siocgifindex, @intFromPtr(&req))) != .SUCCESS)
            return null;
        return req.index;
    }

    /// Makes the bridge, gives it the gateway's address and brings it up; none of it is an error
    /// when it is there already.
    pub fn ensureBridge(s: *Socket) !void {
        var m: Message = .init(.RTM_NEWLINK, linux.NLM_F_CREATE | linux.NLM_F_EXCL);
        m.ifinfo(0, 0);
        m.attrString(ifla_ifname, bridge);
        const info = m.begin(ifla_linkinfo);
        m.attrString(ifla_info_kind, "bridge");
        m.end(info);
        try expect(s.request(&m), true);
        const i = s.index(bridge) orelse return error.NoBridge;
        try s.addAddress(i, gateway);
        try s.up(i);
    }

    /// Makes the veth pair of slot `n`, its job's end in the namespace `netns` (a file
    /// descriptor) and named `eth0` there, its host's end on the bridge and up.
    pub fn addVeth(s: *Socket, slot: u32, netns: linux.fd_t) !void {
        var buf: [16]u8 = undefined;
        const host = hostLink(&buf, slot);
        var m: Message = .init(.RTM_NEWLINK, linux.NLM_F_CREATE | linux.NLM_F_EXCL);
        m.ifinfo(0, 0);
        m.attrString(ifla_ifname, host);
        const info = m.begin(ifla_linkinfo);
        m.attrString(ifla_info_kind, "veth");
        const data = m.begin(ifla_info_data);
        const peer = m.begin(veth_info_peer);
        m.ifinfo(0, 0);
        m.attrString(ifla_ifname, "eth0");
        m.attrU32(ifla_net_ns_fd, @intCast(netns));
        m.end(peer);
        m.end(data);
        m.end(info);
        try expect(s.request(&m), false);
        const i = s.index(host) orelse return error.NoVeth;
        const b = s.index(bridge) orelse return error.NoBridge;
        var master: Message = .init(.RTM_NEWLINK, 0);
        master.ifinfo(i, 0);
        master.attrU32(ifla_master, @intCast(b));
        try expect(s.request(&master), false);
        try s.up(i);
    }

    /// Removes slot `n`'s veth pair (both ends go with the host's); none there is no error.
    pub fn deleteVeth(s: *Socket, slot: u32) void {
        var buf: [16]u8 = undefined;
        const i = s.index(hostLink(&buf, slot)) orelse return;
        var m: Message = .init(.RTM_DELLINK, 0);
        m.ifinfo(i, 0);
        _ = s.request(&m);
    }

    /// Inside a job's namespace: `lo` and `eth0` up, `eth0` with slot `n`'s address, and the
    /// default route through the bridge.
    pub fn configureJob(s: *Socket, slot: u32) !void {
        try s.up(s.index("lo") orelse return error.NoLoopback);
        const eth = s.index("eth0") orelse return error.NoVeth;
        try s.addAddress(eth, jobAddress(slot));
        try s.up(eth);
        var m: Message = .init(.RTM_NEWROUTE, linux.NLM_F_CREATE | linux.NLM_F_EXCL);
        m.put(RtMsg, .{});
        m.attrBytes(rta_gateway, &gateway);
        try expect(s.request(&m), false);
    }

    fn addAddress(s: *Socket, i: i32, addr: [4]u8) !void {
        var m: Message = .init(.RTM_NEWADDR, linux.NLM_F_CREATE | linux.NLM_F_EXCL);
        m.put(IfAddrMsg, .{ .index = @intCast(i) });
        m.attrBytes(ifa_local, &addr);
        m.attrBytes(ifa_address, &addr);
        try expect(s.request(&m), true);
    }

    fn up(s: *Socket, i: i32) !void {
        var m: Message = .init(.RTM_NEWLINK, 0);
        m.ifinfo(i, iff_up);
        try expect(s.request(&m), false);
    }
};

fn expect(e: linux.E, exist_ok: bool) !void {
    if (e == .SUCCESS or (exist_ok and e == .EXIST)) return;
    std.log.debug("rtnetlink: {s}", .{@tagName(e)});
    return error.Netlink;
}

const ifla_ifname = 3;
const ifla_master = 10;
const ifla_linkinfo = 18;
const ifla_net_ns_fd = 28;
const ifla_info_kind = 1;
const ifla_info_data = 2;
const veth_info_peer = 1;
const ifa_address = 1;
const ifa_local = 2;
const rta_gateway = 5;
const iff_up = 1;

const IfInfoMsg = extern struct {
    family: u8 = 0,
    pad: u8 = 0,
    type: u16 = 0,
    index: i32 = 0,
    flags: u32 = 0,
    change: u32 = 0,
};

const IfAddrMsg = extern struct {
    family: u8 = linux.AF.INET,
    prefixlen: u8 = prefix_len,
    flags: u8 = 0,
    scope: u8 = 0,
    index: u32,
};

/// A default route in the main table, as `ip route add default via ...` sends it.
const RtMsg = extern struct {
    family: u8 = linux.AF.INET,
    dst_len: u8 = 0,
    src_len: u8 = 0,
    tos: u8 = 0,
    table: u8 = 254,
    protocol: u8 = 3,
    scope: u8 = 0,
    type: u8 = 1,
    flags: u32 = 0,
};

/// One netlink request being built: a header, a fixed part, then attributes, nested ones with
/// `begin` and `end`.
const Message = struct {
    buf: [1024]u8 align(4) = undefined,
    len: usize = @sizeOf(linux.nlmsghdr),
    type: linux.NetlinkMessageType,
    flags: u16,

    fn init(t: linux.NetlinkMessageType, flags: u16) Message {
        return .{ .type = t, .flags = linux.NLM_F_REQUEST | linux.NLM_F_ACK | flags };
    }

    fn put(m: *Message, comptime T: type, v: T) void {
        const bytes = std.mem.asBytes(&v);
        @memcpy(m.buf[m.len..][0..bytes.len], bytes);
        m.len = std.mem.alignForward(usize, m.len + bytes.len, 4);
    }

    fn ifinfo(m: *Message, i: i32, flags: u32) void {
        m.put(IfInfoMsg, .{ .index = i, .flags = flags, .change = if (flags != 0) flags else 0 });
    }

    fn attrBytes(m: *Message, t: u16, data: []const u8) void {
        const hdr: linux.rtattr = .{
            .len = @intCast(@sizeOf(linux.rtattr) + data.len),
            .type = .{ .link = @fromBackingInt(@intCast(t)) },
        };
        @memcpy(m.buf[m.len..][0..@sizeOf(linux.rtattr)], std.mem.asBytes(&hdr));
        @memcpy(m.buf[m.len + @sizeOf(linux.rtattr) ..][0..data.len], data);
        m.len = std.mem.alignForward(usize, m.len + hdr.len, 4);
    }

    fn attrString(m: *Message, t: u16, s: []const u8) void {
        var term: [32]u8 = @splat(0);
        @memcpy(term[0..s.len], s);
        m.attrBytes(t, term[0 .. s.len + 1]);
    }

    fn attrU32(m: *Message, t: u16, v: u32) void {
        m.attrBytes(t, std.mem.asBytes(&v));
    }

    fn begin(m: *Message, t: u16) usize {
        const at = m.len;
        m.attrBytes(t, &.{});
        return at;
    }

    fn end(m: *Message, at: usize) void {
        const len: u16 = @intCast(m.len - at);
        @memcpy(m.buf[at..][0..2], std.mem.asBytes(&len));
    }

    fn finish(m: *Message, seq: u32) void {
        const h: linux.nlmsghdr = .{
            .len = @intCast(m.len),
            .type = m.type,
            .flags = m.flags,
            .seq = seq,
            .pid = 0,
        };
        @memcpy(m.buf[0..@sizeOf(linux.nlmsghdr)], std.mem.asBytes(&h));
    }
};

/// What the runner needs from the host for its jobs' traffic to leave: forwarding on, the jobs'
/// addresses masqueraded on their way out, and forwarding to and from the bridge accepted, in
/// `FORWARD` and, on a Docker host, in `DOCKER-USER`, the chain Docker leaves for others' rules
/// (its FORWARD policy drops the rest). Made with `iptables`, which every Docker host has and
/// which puts them in the same tables as Docker's (debt: phase 5 makes them over netlink). Each
/// rule is added once. On failure, what went wrong.
pub fn natRules(arena: Allocator, io: std.Io) !?[]const u8 {
    const fwd = std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = "/proc/sys/net/ipv4/ip_forward",
        .data = "1",
    });
    fwd catch |e| return try std.fmt.allocPrint(arena, "cannot turn on IPv4 forwarding: {s}", .{
        @errorName(e),
    });
    const established = [_][]const u8{ "-m", "conntrack", "--ctstate", "RELATED,ESTABLISHED" };
    const rules = [_]struct { table: []const u8, chain: []const u8, rule: []const []const u8 }{
        .{
            .table = "nat",
            .chain = "POSTROUTING",
            .rule = &.{ "-s", subnet, "!", "-o", bridge, "-j", "MASQUERADE" },
        },
        .{ .table = "filter", .chain = "FORWARD", .rule = &.{ "-i", bridge, "-j", "ACCEPT" } },
        .{
            .table = "filter",
            .chain = "FORWARD",
            .rule = &(.{ "-o", bridge } ++ established ++ .{ "-j", "ACCEPT" }),
        },
    };
    for (rules) |r| if (try ensureRule(arena, io, r.table, r.chain, r.rule)) |why| return why;
    // Docker's own chain, when this is a Docker host.
    if (try iptables(arena, io, &.{ "-t", "filter", "-n", "-L", "DOCKER-USER" }) == null) {
        const docker = [_][]const []const u8{
            &.{ "-i", bridge, "-j", "ACCEPT" },
            &(.{ "-o", bridge } ++ established ++ .{ "-j", "ACCEPT" }),
        };
        for (docker) |rule| if (try ensureRule(arena, io, "filter", "DOCKER-USER", rule)) |why|
            return why;
    }
    return null;
}

/// Adds `rule` at the head of `chain` unless it is there (`iptables -C`).
fn ensureRule(
    arena: Allocator,
    io: std.Io,
    table: []const u8,
    chain: []const u8,
    rule: []const []const u8,
) !?[]const u8 {
    const check = try std.mem.concat(arena, []const u8, &.{ &.{ "-t", table, "-C", chain }, rule });
    if (try iptables(arena, io, check) == null) return null;
    const head: []const []const u8 = &.{ "-t", table, "-I", chain };
    const insert = try std.mem.concat(arena, []const u8, &.{ head, rule });
    return iptables(arena, io, insert);
}

/// Runs `iptables` with `args` (waiting for its lock, as Docker may hold it); null when it
/// succeeded, else why not.
fn iptables(arena: Allocator, io: std.Io, args: []const []const u8) !?[]const u8 {
    const argv = try std.mem.concat(arena, []const u8, &.{ &.{ "iptables", "-w" }, args });
    const r = std.process.run(arena, io, .{ .argv = argv }) catch |e|
        return try std.fmt.allocPrint(arena, "cannot run iptables: {s}", .{@errorName(e)});
    if (r.term == .exited and r.term.exited == 0) return null;
    return try std.fmt.allocPrint(arena, "iptables {s} failed: {s}", .{
        try std.mem.join(arena, " ", args),
        std.mem.trim(u8, r.stderr, " \n"),
    });
}

/// The resolver a job's steps get: its own namespace cannot reach a resolver on the host's
/// loopback (systemd-resolved's 127.0.0.53), so the upstream servers systemd-resolved lists, or
/// the host's /etc/resolv.conf when it names no loopback server. Null when neither will do.
pub fn resolvConf(arena: Allocator, io: std.Io) ?[]const u8 {
    for ([_][]const u8{ "/run/systemd/resolve/resolv.conf", "/etc/resolv.conf" }) |p| {
        const text = std.Io.Dir.cwd().readFileAlloc(io, p, arena, .limited(64 * 1024)) catch
            continue;
        if (namesOnlyReachable(text)) return p;
    }
    return null;
}

/// Whether a resolv.conf names at least one nameserver, and none on the loopback.
pub fn namesOnlyReachable(text: []const u8) bool {
    var any = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        var words = std.mem.tokenizeAny(u8, raw, " \t");
        const key = words.next() orelse continue;
        if (!std.mem.eql(u8, key, "nameserver")) continue;
        const addr = words.next() orelse continue;
        if (std.mem.startsWith(u8, addr, "127.") or std.mem.eql(u8, addr, "::1")) return false;
        any = true;
    }
    return any;
}

test "a resolv.conf for a job's namespace names no loopback server" {
    try std.testing.expect(!namesOnlyReachable("nameserver 127.0.0.53\noptions edns0\n"));
    try std.testing.expect(namesOnlyReachable("# upstream\nnameserver 1.1.1.1\n" ++
        "nameserver 8.8.8.8\n"));
    try std.testing.expect(!namesOnlyReachable("search example.com\n"));
    try std.testing.expect(!namesOnlyReachable("nameserver 10.0.0.2\nnameserver ::1\n"));
}

test "slots' addresses and links" {
    try std.testing.expectEqual([4]u8{ 10, 88, 1, 2 }, jobAddress(0));
    try std.testing.expectEqual([4]u8{ 10, 88, 1, 251 }, jobAddress(249));
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("zrh7", hostLink(&buf, 7));
}
