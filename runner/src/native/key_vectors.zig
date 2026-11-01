//! The native step store's key against the Lean model's (proofs/Runner/Native.lean, P8).
//!
//! `testdata/step_keys.tsv` is written by the model (`keyoracle`, proofs/KeyOracle.lean) and checked
//! to be its output by .github/scripts/key-vectors.sh. Each line is two inputs, whether the model's
//! keys for them are equal, and for each the bytes the store must hash: `key` lines for a step's or
//! a base's key (`Store.KeyHasher.init(tag)`, `core`, then `Backend.keyFor`'s tail), `below` lines
//! for the digest below a base (`Backend.below`). Two checks:
//!
//! - the preimage: a key's bytes as P2's `Store.KeyHasher` writes them, and the digest below a
//!   base's, must be the model's;
//! - the relation: a key function must give equal keys exactly where the model does. This half
//!   holds of any sound spelling (`Native.native_key_iff`), so it applies to the store's key
//!   whatever bytes it hashes.
//!
//! Keys go through P2's own `Store.KeyHasher` (`init`, `core`, its `bytes` writer) and
//! `Store.stableEnv`; `keyFor`'s tail, which needs a `Backend`, is written out here as `keyFor`
//! writes it. The digest below a base is still a reference (`belowPreimage`), following P2's
//! review fixes (feature/native-backend-p2 at ede9244: `Store.store_format` after the label), which
//! main does not have yet. **When they merge:** write `Backend.below`'s hashing as a function of
//! its inputs, call it from `storeBelow`, and drop the reference.

const std = @import("std");
const Store = @import("Store.zig");

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
    format: []const u8,
    fingerprint: []const u8,
    userns: []const u8,
    id_base: u64,
    binds: []const Bind,
};

pub const KeyFn = fn (Allocator, KeyInput) anyerror![32]u8;
pub const BelowFn = fn (Allocator, BelowInput) anyerror![32]u8;

/// A field and a number as `Store.KeyHasher` writes them, for the digest below a base.
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
};

/// A key's preimage, through P2's `Store.KeyHasher`: the tag, `core` (parent, script, the env
/// through `Store.stableEnv`), then `Backend.keyFor`'s tail: uid, gid, the working directory, the
/// count of kept files and each one's path, contents and mode.
pub fn keyPreimage(gpa: Allocator, in: KeyInput) ![]u8 {
    var w: std.Io.Writer.Allocating = .init(gpa);
    defer w.deinit();
    var h: Store.KeyHasher = .init(@fromBackingInt(@intCast(in.tag)));
    h.bytes = &w.writer;
    // `init` wrote the tag before `bytes` was set.
    var tag: [8]u8 = undefined;
    std.mem.writeInt(u64, &tag, in.tag, .little);
    try w.writer.writeAll(&tag);
    h.core(in.parent, in.script, in.env);
    h.int(in.uid);
    h.int(in.gid);
    h.field(in.workdir);
    h.int(in.files.len);
    for (in.files) |f| {
        h.field(f.path);
        h.field(f.contents);
        h.int(f.mode);
    }
    const key = h.final();
    const bytes = try w.toOwnedSlice();
    // The digest P2 computes is the digest of these bytes.
    var check: [32]u8 = undefined;
    Sha256.hash(bytes, &check, .{});
    std.debug.assert(std.mem.eql(u8, &check, &key));
    return bytes;
}

/// The digest below a base's preimage, as `Backend.below` builds it: untagged
/// (`KeyHasher.plain("below a base")`), then the store's format (`Store.store_format`), the rootfs's
/// fingerprint, the userns mode, the slot's first id, and the binds, counted.
pub fn belowPreimage(gpa: Allocator, in: BelowInput) ![]u8 {
    var h: Hasher = .{ .gpa = gpa };
    errdefer h.out.deinit(gpa);
    try h.field("below a base");
    try h.field(in.format);
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

/// The key P2 gives, through `Store.KeyHasher`.
pub fn storeKey(gpa: Allocator, in: KeyInput) ![32]u8 {
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
    const format = try unhex(arena, it.next().?);
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
        .in = .{ .format = format, .fingerprint = fingerprint, .userns = userns, .id_base = id_base, .binds = binds.items },
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
    try checkRelation(storeKey, referenceBelow);
    // When P2's review fixes merge: referenceBelow becomes storeBelow, over `Backend.below`'s hashing.
}
