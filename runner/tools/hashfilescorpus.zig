//! The Zig half of `.github/scripts/hashfiles-diff.sh`: runs src/hashfiles.zig, the runner's own
//! choice of files for hashFiles(), on what Dagger's glob listed, and compares it with GitHub's.
//!
//!     hashfilescorpus plan <cases.json> <workspace>
//!         the globs the runner would ask Dagger for, as a JSON array
//!     hashfilescorpus dirs <cases.json> <workspace> <globs.json>
//!         the directories among what they listed, whose contents it asks for next
//!     hashfilescorpus check <cases.json> <workspace> <globs.json> <contents.json> <reference.jsonl>
//!         every case where the files differ, then counts; fails if any do
//!
//! Like the runner, a case's patterns are hashFiles()'s arguments; GitHub joins them with newlines.
const std = @import("std");
const hashfiles = @import("hashfiles");

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    const usage = "usage: hashfilescorpus plan <cases> <ws> | dirs <cases> <ws> <globs> |" ++
        " check <cases> <ws> <globs> <contents> <reference>\n";
    if (args.len < 4) {
        std.debug.print(usage, .{});
        return 2;
    }
    var out_buf: [8192]u8 = undefined;
    var out_w: std.Io.File.Writer = .initStreaming(.stdout(), io, &out_buf);
    const out = &out_w.interface;
    defer out.flush() catch {};

    const cwd = std.Io.Dir.cwd();
    const ws = args[3];
    const cases = (try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        try cwd.readFileAlloc(io, args[2], arena, .limited(1 << 28)),
        .{},
    )).array.items;

    if (std.mem.eql(u8, args[1], "plan")) {
        var globs: std.StringArrayHashMapUnmanaged(void) = .empty;
        for (cases) |c| {
            const pats = switch (try hashfiles.patterns(arena, ws, try strings(arena, c))) {
                .ok => |p| p,
                else => continue,
            };
            for (pats) |p| try globs.put(arena, p.glob, {});
        }
        try std.json.Stringify.value(globs.keys(), .{}, out);
        try out.writeByte('\n');
        return 0;
    }
    if (args.len < 5) {
        std.debug.print(usage, .{});
        return 2;
    }
    const globbed = (try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        try cwd.readFileAlloc(io, args[4], arena, .limited(1 << 28)),
        .{},
    )).object;
    if (std.mem.eql(u8, args[1], "dirs")) {
        var all: std.ArrayList([]const []const u8) = .empty;
        for (cases) |c| {
            const pats = switch (try hashfiles.patterns(arena, ws, try strings(arena, c))) {
                .ok => |p| p,
                else => continue,
            };
            for (pats) |p| try all.append(arena, try listed(arena, globbed, p.glob));
        }
        try std.json.Stringify.value(try hashfiles.directories(arena, all.items), .{}, out);
        try out.writeByte('\n');
        return 0;
    }
    if (!std.mem.eql(u8, args[1], "check") or args.len != 7) {
        std.debug.print(usage, .{});
        return 2;
    }
    var contents: std.StringHashMapUnmanaged([]const []const u8) = .empty;
    const inside = (try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        try cwd.readFileAlloc(io, args[5], arena, .limited(1 << 28)),
        .{},
    )).object;
    var it = inside.iterator();
    while (it.next()) |e| try contents.put(arena, e.key_ptr.*, try listed(arena, inside, e.key_ptr.*));
    // Names that are directories once links are followed (hashfilesdiff's "//followed"): the
    // runner's hash step skips them, as GitHub's script does.
    var followed: std.StringHashMapUnmanaged(void) = .empty;
    for ([_]std.json.ObjectMap{ globbed, inside }) |o| if (o.get("//followed")) |f|
        for (f.array.items) |p| try followed.put(arena, p.string, {});
    var reference: std.AutoHashMapUnmanaged(i64, std.json.ObjectMap) = .empty;
    var lines = std.mem.splitScalar(u8, try cwd.readFileAlloc(io, args[6], arena, .limited(1 << 28)), '\n');
    while (lines.next()) |l| {
        // @actions/glob prints `::debug::` lines of its own on stdout.
        if (!std.mem.startsWith(u8, l, "{\"id\"")) continue;
        const o = (try std.json.parseFromSliceLeaky(std.json.Value, arena, l, .{})).object;
        try reference.put(arena, o.get("id").?.integer, o);
    }

    var same: usize = 0;
    var differ: usize = 0;
    var github_failed: usize = 0;
    for (cases) |c| {
        const id = c.object.get("id").?.integer;
        const pattern_args = try strings(arena, c);
        const want = reference.get(id).?;
        const shown = try std.mem.join(arena, " | ", pattern_args);
        const parsed = try hashfiles.patterns(arena, ws, pattern_args);
        if (want.get("error")) |e| {
            // The runner refuses the same patterns; a file GitHub cannot read (a broken symbolic
            // link) fails the runner's sha256sum, which this does not run.
            github_failed += 1;
            const runner = if (parsed == .invalid) "refused too" else "runner reads the patterns";
            try out.print("GitHub fails  [{s}]: {s} ({s})\n", .{ shown, e.string, runner });
            continue;
        }
        if (parsed == .invalid) {
            differ += 1;
            try out.print("DIFFERS  [{s}]: the runner refuses the patterns: {s}\n", .{ shown, parsed.invalid });
            continue;
        }
        var got: []const []const u8 = &.{};
        if (parsed == .ok) {
            const pats = parsed.ok;
            const as_given = try arena.alloc([]const []const u8, pats.len);
            for (pats, as_given) |p, *found| found.* = try listed(arena, globbed, p.glob);
            var hashed: std.ArrayList([]const u8) = .empty;
            for (try hashfiles.select(arena, pats, as_given, &contents)) |f|
                if (!followed.contains(f)) try hashed.append(arena, f);
            got = hashed.items;
        }
        const expected = want.get("files").?.array.items;
        if (sameFiles(got, expected)) {
            same += 1;
            continue;
        }
        differ += 1;
        try out.print("DIFFERS  [{s}]\n", .{shown});
        for (expected) |e| if (!contains(got, e.string)) try out.print("    only GitHub: {s}\n", .{e.string});
        for (got) |g| if (!containsJson(expected, g)) try out.print("    only runner: {s}\n", .{g});
    }
    try out.print("\n{d} cases select the same files, {d} differ, {d} fail on GitHub\n", .{ same, differ, github_failed });
    return if (differ == 0) 0 else 1;
}

/// What Dagger listed under `key` (a glob, or a directory's contents).
fn listed(arena: std.mem.Allocator, globbed: std.json.ObjectMap, key: []const u8) ![]const []const u8 {
    const items = globbed.get(key).?.array.items;
    const out = try arena.alloc([]const u8, items.len);
    for (items, out) |i, *o| o.* = i.string;
    return out;
}

fn strings(arena: std.mem.Allocator, c: std.json.Value) ![]const []const u8 {
    const items = c.object.get("patterns").?.array.items;
    const out = try arena.alloc([]const u8, items.len);
    for (items, out) |i, *o| o.* = i.string;
    return out;
}

fn sameFiles(got: []const []const u8, want: []const std.json.Value) bool {
    if (got.len != want.len) return false;
    for (got) |g| if (!containsJson(want, g)) return false;
    return true;
}

fn contains(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

fn containsJson(list: []const std.json.Value, s: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x.string, s)) return true;
    return false;
}
