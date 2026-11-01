//! The native step store's key against the Lean model's (proofs/Runner/Native.lean, P8).
//!
//! `testdata/step_keys.tsv` is written by the model (`keyoracle`, proofs/KeyOracle.lean) and checked
//! to be its output by .github/scripts/key-vectors.sh. Each line is two step inputs, whether the
//! model's keys for them are equal, and for each the bytes the store must hash. Two checks:
//!
//! - the preimage: `preimage` below spells a key as P8 specifies it (docs/native-backend.md, P2's
//!   key format), and must give the model's bytes;
//! - the relation: a key function must give equal keys exactly where the model does. This half
//!   holds of any sound spelling (`Native.native_key_iff`), so it applies to the store's key
//!   whatever bytes it hashes.
//!
//! Until P2's store lands, both run against `referenceKey`, the specification as code. **When P2
//! lands:** add `try checkRelation(store.stepKey)` (or an adapter of that shape) to the second
//! test, and, if the store spells keys as `preimage` does, make `referenceKey` call it, or delete
//! `preimage` and check the store's bytes in the first test. If P2 spells keys another way, change
//! `Native.encState` and `stepPreimage` to match, keep `Format.Sound` proved, and regenerate the
//! file (`key-vectors.sh --write`).

const std = @import("std");
const dagger = @import("../dagger.zig");

const vectors = @embedFile("testdata/step_keys.tsv");

pub const Binding = struct { name: []const u8, value: []const u8 };

/// What P2's key function must look like for `checkRelation`: a step's key from its parent's key,
/// its script's text and its whole environment in the container's order. It leaves out the names in
/// `dagger.volatile_env` itself; the mounts and the event payload are no argument of it.
pub const StepKey = fn (std.mem.Allocator, [32]u8, []const u8, []const Binding) anyerror![32]u8;

fn word(out: *std.ArrayList(u8), gpa: std.mem.Allocator, n: usize) !void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, n, .little);
    try out.appendSlice(gpa, &buf);
}

fn field(out: *std.ArrayList(u8), gpa: std.mem.Allocator, bytes: []const u8) !void {
    try word(out, gpa, bytes.len);
    try out.appendSlice(gpa, bytes);
}

/// The bytes a step's key hashes (`Native.stepPreimage`): the tag 1 (a step's container; 0 is a
/// base, 2 an output-keyed container), the parent's key, the script's text, then the count of
/// stable bindings and each name and value, every field length-prefixed with a u64 little-endian.
pub fn preimage(gpa: std.mem.Allocator, parent: [32]u8, script: []const u8, env: []const Binding) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try word(&out, gpa, 1);
    try field(&out, gpa, &parent);
    try field(&out, gpa, script);
    var stable: usize = 0;
    for (env) |b| stable += @intFromBool(!dagger.isVolatile(b.name));
    try word(&out, gpa, stable);
    for (env) |b| if (!dagger.isVolatile(b.name)) {
        try field(&out, gpa, b.name);
        try field(&out, gpa, b.value);
    };
    return out.toOwnedSlice(gpa);
}

/// The key as P8 specifies it: sha256 of `preimage`. Stands in for P2's until it lands.
pub fn referenceKey(gpa: std.mem.Allocator, parent: [32]u8, script: []const u8, env: []const Binding) ![32]u8 {
    const bytes = try preimage(gpa, parent, script, env);
    defer gpa.free(bytes);
    var key: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &key, .{});
    return key;
}

/// One side of a vector, decoded into `arena`.
const Side = struct {
    parent: [32]u8,
    script: []const u8,
    env: []const Binding,
    preimage: []const u8,
};

fn unhex(arena: std.mem.Allocator, text: []const u8) ![]u8 {
    const out = try arena.alloc(u8, text.len / 2);
    return std.fmt.hexToBytes(out, text);
}

fn side(arena: std.mem.Allocator, it: *std.mem.SplitIterator(u8, .scalar)) !Side {
    var s: Side = undefined;
    const parent = try unhex(arena, it.next().?);
    try std.testing.expectEqual(32, parent.len);
    @memcpy(&s.parent, parent);
    s.script = try unhex(arena, it.next().?);
    const env_text = it.next().?;
    var env: std.ArrayList(Binding) = .empty;
    if (!std.mem.eql(u8, env_text, "-")) {
        var pairs = std.mem.splitScalar(u8, env_text, ',');
        while (pairs.next()) |pair| {
            const eq = std.mem.indexOfScalar(u8, pair, '=').?;
            try env.append(arena, .{
                .name = try unhex(arena, pair[0..eq]),
                .value = try unhex(arena, pair[eq + 1 ..]),
            });
        }
    }
    s.env = env.items;
    s.preimage = try unhex(arena, it.next().?);
    return s;
}

const Vector = struct { name: []const u8, equal: bool, a: Side, b: Side };

fn parse(arena: std.mem.Allocator) ![]Vector {
    var out: std.ArrayList(Vector) = .empty;
    var lines = std.mem.splitScalar(u8, vectors, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var it = std.mem.splitScalar(u8, line, '\t');
        const name = it.next().?;
        const rel = it.next().?;
        try out.append(arena, .{
            .name = name,
            .equal = std.mem.eql(u8, rel, "equal"),
            .a = try side(arena, &it),
            .b = try side(arena, &it),
        });
        try std.testing.expect(it.next() == null);
    }
    return out.items;
}

/// A key function gives equal keys exactly for the pairs the model's keys are equal for.
pub fn checkRelation(comptime stepKey: StepKey) !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for (try parse(arena)) |v| {
        const ka = try stepKey(std.testing.allocator, v.a.parent, v.a.script, v.a.env);
        const kb = try stepKey(std.testing.allocator, v.b.parent, v.b.script, v.b.env);
        std.testing.expectEqual(v.equal, std.mem.eql(u8, &ka, &kb)) catch |err| {
            std.debug.print("key vector {s}: the model says {s}\n", .{ v.name, if (v.equal) "equal" else "differ" });
            return err;
        };
    }
}

test "the native key's preimage is the model's" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const vs = try parse(arena);
    try std.testing.expect(vs.len >= 10);
    for (vs) |v| for ([_]Side{ v.a, v.b }) |s| {
        const bytes = try preimage(arena, s.parent, s.script, s.env);
        std.testing.expectEqualSlices(u8, s.preimage, bytes) catch |err| {
            std.debug.print("key vector {s}: the preimage is not the model's\n", .{v.name});
            return err;
        };
    };
}

test "native keys are equal exactly where the model's are" {
    try checkRelation(referenceKey);
    // P2: try checkRelation(store.stepKey);
}
