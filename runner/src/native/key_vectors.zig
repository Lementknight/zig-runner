//! The native step store's key against the Lean model's (proofs/Runner/Native.lean, P8).
//!
//! `testdata/step_keys.tsv` is written by the model (`keyoracle`, proofs/KeyOracle.lean) and checked
//! to be its output by .github/scripts/key-vectors.sh. Each line is two inputs, whether the model's
//! keys for them are equal, and for each the bytes the store must hash: `key` lines for a step's or
//! a base's key (`Store.KeyHasher.init(tag)`, `core`, then `Backend.keyFor`'s tail), `below` lines
//! for the digest below a base (`Backend.below`). Two checks:
//!
//! - the preimage: `Hasher` below spells keys as P2's `Store.KeyHasher` does, and must give the
//!   model's bytes;
//! - the relation: a key function must give equal keys exactly where the model does. This half
//!   holds of any sound spelling (`Native.native_key_iff`), so it applies to the store's key
//!   whatever bytes it hashes.
//!
//! P2's store (draft #268) is not on this branch, so both run against the reference here, which
//! follows P2's code at 8b54d2a line for line (`KeyHasher`, `stableEnv`, `keyFor`, `below`).
//! **When P2 merges:** point `stableEnv` at `Store.stableEnv`, and replace `Hasher` with
//! `Store.KeyHasher`, whose `bytes` writer gives the preimage: `referenceKey` and `referenceBelow`
//! become thin adapters over P2's, and the first test then checks P2's bytes.

const std = @import("std");
const dagger = @import("../dagger.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;
const Allocator = std.mem.Allocator;

const vectors = @embedFile("testdata/step_keys.tsv");

pub const Binding = struct { name: []const u8, value: []const u8 };
pub const File = struct { path: []const u8, contents: []const u8, mode: u64 };
pub const Bind = struct { host: []const u8, at: []const u8, read_only: bool, optional: bool };

/// What a key is given (`Backend.keyFor`): the tag (0 a base, 1 a step's exec or a checkout's
/// fetch), the parent's key (for a base, the digest below it), the script, the whole env in the
/// container's order, who runs it, where, and the files kept.
pub const KeyInput = struct {
    tag: u64,
    parent: [32]u8,
    script: []const u8,
    env: []const Binding,
    uid: u64,
    gid: u64,
    workdir: []const u8,
    files: []const File,
};

/// What the digest below a base is of (`Backend.below`).
pub const BelowInput = struct {
    fingerprint: []const u8,
    userns: []const u8,
    id_base: u64,
    binds: []const Bind,
};

pub const KeyFn = fn (Allocator, KeyInput) anyerror![32]u8;
pub const BelowFn = fn (Allocator, BelowInput) anyerror![32]u8;

/// `Store.stableEnv` at P2's 8b54d2a: not the volatile names, nor the runner's own per-job values,
/// nor the secret aliases.
fn stableEnv(name: []const u8) bool {
    if (dagger.isVolatile(name)) return false;
    for ([_][]const u8{ dagger.event_env, dagger.ran_env, dagger.mark_env }) |n|
        if (std.mem.eql(u8, name, n)) return false;
    return !std.mem.startsWith(u8, name, "ZIG_SECRET_");
}

/// `Store.KeyHasher` at P2's 8b54d2a, keeping the preimage.
const Hasher = struct {
    out: std.ArrayList(u8) = .empty,
    gpa: Allocator,

    fn int(k: *Hasher, v: u64) !void {
        var b: [8]u8 = undefined;
        std.mem.writeInt(u64, &b, v, .little);
        try k.out.appendSlice(k.gpa, &b);
    }

    fn field(k: *Hasher, b: []const u8) !void {
        try k.int(b.len);
        try k.out.appendSlice(k.gpa, b);
    }

    fn core(k: *Hasher, parent: [32]u8, script: []const u8, env: []const Binding) !void {
        try k.field(&parent);
        try k.field(script);
        var stable: u64 = 0;
        for (env) |e| stable += @intFromBool(stableEnv(e.name));
        try k.int(stable);
        for (env) |e| if (stableEnv(e.name)) {
            try k.field(e.name);
            try k.field(e.value);
        };
    }
};

/// A key's preimage, as `Backend.keyFor` builds it: the tag, the core, then uid, gid, the working
/// directory, the count of kept files and each one's path, contents and mode.
pub fn keyPreimage(gpa: Allocator, in: KeyInput) ![]u8 {
    var h: Hasher = .{ .gpa = gpa };
    errdefer h.out.deinit(gpa);
    try h.int(in.tag);
    try h.core(in.parent, in.script, in.env);
    try h.int(in.uid);
    try h.int(in.gid);
    try h.field(in.workdir);
    try h.int(in.files.len);
    for (in.files) |f| {
        try h.field(f.path);
        try h.field(f.contents);
        try h.int(f.mode);
    }
    return h.out.toOwnedSlice(gpa);
}

/// The digest below a base's preimage, as `Backend.below` builds it: untagged
/// (`KeyHasher.plain("below a base")`), then the rootfs's fingerprint, the userns mode, the slot's
/// first id, and the binds, counted.
pub fn belowPreimage(gpa: Allocator, in: BelowInput) ![]u8 {
    var h: Hasher = .{ .gpa = gpa };
    errdefer h.out.deinit(gpa);
    try h.field("below a base");
    try h.field(in.fingerprint);
    try h.field(in.userns);
    try h.int(in.id_base);
    try h.int(in.binds.len);
    for (in.binds) |b| {
        try h.field(b.host);
        try h.field(b.at);
        try h.int(@intFromBool(b.read_only));
        try h.int(@intFromBool(b.optional));
    }
    return h.out.toOwnedSlice(gpa);
}

fn sha(gpa: Allocator, bytes: []u8) [32]u8 {
    defer gpa.free(bytes);
    var key: [32]u8 = undefined;
    Sha256.hash(bytes, &key, .{});
    return key;
}

pub fn referenceKey(gpa: Allocator, in: KeyInput) ![32]u8 {
    return sha(gpa, try keyPreimage(gpa, in));
}

pub fn referenceBelow(gpa: Allocator, in: BelowInput) ![32]u8 {
    return sha(gpa, try belowPreimage(gpa, in));
}

// --- the vectors ---

const Side = union(enum) {
    key: struct { in: KeyInput, preimage: []const u8 },
    below: struct { in: BelowInput, preimage: []const u8 },
};

const Vector = struct { name: []const u8, equal: bool, a: Side, b: Side };

const Fields = std.mem.SplitIterator(u8, .scalar);

fn unhex(arena: Allocator, text: []const u8) ![]u8 {
    const out = try arena.alloc(u8, text.len / 2);
    return std.fmt.hexToBytes(out, text);
}

fn num(text: []const u8) !u64 {
    return std.fmt.parseInt(u64, text, 10);
}

/// A `-` or a `,`-joined list of `=`-joined parts.
fn items(arena: Allocator, text: []const u8, parts: usize) ![]const []const []const u8 {
    var out: std.ArrayList([]const []const u8) = .empty;
    if (std.mem.eql(u8, text, "-")) return out.items;
    var it = std.mem.splitScalar(u8, text, ',');
    while (it.next()) |item| {
        var ps: std.ArrayList([]const u8) = .empty;
        var p = std.mem.splitScalar(u8, item, '=');
        while (p.next()) |part| try ps.append(arena, part);
        try std.testing.expectEqual(parts, ps.items.len);
        try out.append(arena, ps.items);
    }
    return out.items;
}

fn keySide(arena: Allocator, it: *Fields) !Side {
    const tag = try num(it.next().?);
    const parent = try unhex(arena, it.next().?);
    try std.testing.expectEqual(32, parent.len);
    const script = try unhex(arena, it.next().?);
    var env: std.ArrayList(Binding) = .empty;
    for (try items(arena, it.next().?, 2)) |p|
        try env.append(arena, .{ .name = try unhex(arena, p[0]), .value = try unhex(arena, p[1]) });
    const uid = try num(it.next().?);
    const gid = try num(it.next().?);
    const workdir = try unhex(arena, it.next().?);
    var files: std.ArrayList(File) = .empty;
    for (try items(arena, it.next().?, 3)) |p| try files.append(arena, .{
        .path = try unhex(arena, p[0]),
        .contents = try unhex(arena, p[1]),
        .mode = try num(p[2]),
    });
    return .{ .key = .{
        .in = .{
            .tag = tag,
            .parent = parent[0..32].*,
            .script = script,
            .env = env.items,
            .uid = uid,
            .gid = gid,
            .workdir = workdir,
            .files = files.items,
        },
        .preimage = try unhex(arena, it.next().?),
    } };
}

fn belowSide(arena: Allocator, it: *Fields) !Side {
    const fingerprint = try unhex(arena, it.next().?);
    const userns = try unhex(arena, it.next().?);
    const id_base = try num(it.next().?);
    var binds: std.ArrayList(Bind) = .empty;
    for (try items(arena, it.next().?, 4)) |p| try binds.append(arena, .{
        .host = try unhex(arena, p[0]),
        .at = try unhex(arena, p[1]),
        .read_only = std.mem.eql(u8, p[2], "1"),
        .optional = std.mem.eql(u8, p[3], "1"),
    });
    return .{ .below = .{
        .in = .{ .fingerprint = fingerprint, .userns = userns, .id_base = id_base, .binds = binds.items },
        .preimage = try unhex(arena, it.next().?),
    } };
}

fn parse(arena: Allocator) ![]Vector {
    var out: std.ArrayList(Vector) = .empty;
    var lines = std.mem.splitScalar(u8, vectors, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var it = std.mem.splitScalar(u8, line, '\t');
        const kind = it.next().?;
        const name = it.next().?;
        const rel = it.next().?;
        const key = std.mem.eql(u8, kind, "key");
        try out.append(arena, .{
            .name = name,
            .equal = std.mem.eql(u8, rel, "equal"),
            .a = if (key) try keySide(arena, &it) else try belowSide(arena, &it),
            .b = if (key) try keySide(arena, &it) else try belowSide(arena, &it),
        });
        try std.testing.expect(it.next() == null);
    }
    return out.items;
}

/// Key functions give equal keys exactly for the pairs the model's keys are equal for.
pub fn checkRelation(comptime keyFn: KeyFn, comptime belowFn: BelowFn) !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const gpa = std.testing.allocator;
    for (try parse(arena)) |v| {
        const ka: [32]u8, const kb: [32]u8 = switch (v.a) {
            .key => |a| .{ try keyFn(gpa, a.in), try keyFn(gpa, v.b.key.in) },
            .below => |a| .{ try belowFn(gpa, a.in), try belowFn(gpa, v.b.below.in) },
        };
        std.testing.expectEqual(v.equal, std.mem.eql(u8, &ka, &kb)) catch |err| {
            std.debug.print("key vector {s}: the model says {s}\n", .{
                v.name,
                if (v.equal) "equal" else "differ",
            });
            return err;
        };
    }
}

test "the native key's preimage is the model's" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const vs = try parse(arena);
    try std.testing.expect(vs.len >= 20);
    for (vs) |v| for ([_]Side{ v.a, v.b }) |s| {
        const want: []const u8, const got: []const u8 = switch (s) {
            .key => |k| .{ k.preimage, try keyPreimage(arena, k.in) },
            .below => |b| .{ b.preimage, try belowPreimage(arena, b.in) },
        };
        std.testing.expectEqualSlices(u8, want, got) catch |err| {
            std.debug.print("key vector {s}: the preimage is not the model's\n", .{v.name});
            return err;
        };
    };
}

test "native keys are equal exactly where the model's are" {
    try checkRelation(referenceKey, referenceBelow);
    // When P2 merges: try checkRelation(<adapter over Store.KeyHasher>, <adapter over below>);
}
