//! The Zig half of `.github/scripts/glob-lean-diff.sh`: generates hashFiles() cases (a tree under
//! the workspace `/w`, and patterns) and runs src/glob.zig's search on them, for comparing with the
//! Lean model in proofs/ (`globoracle`), whose walk is proved to yield exactly the files the
//! patterns match.
//!
//!     globleancorpus gen <n> <seed>     cases, one JSON object per line, on stdout
//!     globleancorpus run <cases.jsonl>  glob.zig's answer for each, one per line, on stdout
//!
//! A case is `{"id":1,"patterns":["**/*.txt","!a/*"],"tree":{"a":{"x.txt":null},"y.md":null}}`:
//! in the tree, an object is a directory and null anything else (a file, a link). An answer is
//! `{"id":1,"files":["/w/a/x.txt"]}`, or `{"id":1,"invalid":true}` for patterns GitHub refuses.
//!
//! The patterns keep to what the Lean model's segment matcher handles (names, `*`, `?`, `**`,
//! two-character classes, `!`, a trailing `/`, relative or under `/w`); segment matching in full
//! is compared with GitHub's own by hashfiles-diff.sh.
const std = @import("std");
const glob = @import("glob");

const Io = std.Io;
const Allocator = std.mem.Allocator;

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    var out_buf: [8192]u8 = undefined;
    var out_w: Io.File.Writer = .initStreaming(.stdout(), io, &out_buf);
    const out = &out_w.interface;
    defer out.flush() catch {};

    if (args.len == 4 and std.mem.eql(u8, args[1], "gen")) {
        const n = try std.fmt.parseInt(u32, args[2], 10);
        var prng: std.Random.DefaultPrng = .init(try std.fmt.parseInt(u64, args[3], 10));
        const r = prng.random();
        for (1..n + 1) |id| {
            try out.print("{{\"id\":{d},\"patterns\":[", .{id});
            for (0..r.intRangeAtMost(usize, 1, 3)) |i| {
                if (i > 0) try out.writeByte(',');
                try out.print("{f}", .{std.json.fmt(try pattern(arena, r), .{})});
            }
            try out.writeAll("],\"tree\":");
            try tree(out, r, 0);
            try out.writeAll("}\n");
        }
        return 0;
    }
    if (args.len == 3 and std.mem.eql(u8, args[1], "run")) {
        const text = try Io.Dir.cwd().readFileAlloc(io, args[2], arena, .limited(1 << 28));
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            var case_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
            defer case_arena.deinit();
            try run(case_arena.allocator(), out, line);
        }
        return 0;
    }
    std.debug.print("usage: globleancorpus gen <n> <seed> | run <cases.jsonl>\n", .{});
    return 2;
}

const names = [_][]const u8{ "a", "b", "c", "ab", "d.txt", "x.txt", "y.md", ".h" };
const segs = [_][]const u8{ "a", "b", "c", "ab", "x.txt", "d.txt", "y.md", ".h", "*", "?", "*.txt", "*.md", "a*", "*b", "**", "**", "[ab]", "[!a]*" };

fn pattern(arena: Allocator, r: std.Random) ![]const u8 {
    var p: std.ArrayList(u8) = .empty;
    if (r.uintLessThan(u8, 5) == 0) try p.append(arena, '!');
    if (r.uintLessThan(u8, 5) == 0) try p.appendSlice(arena, "/w/");
    // Often under `**`, so that most cases find something.
    const deep = r.uintLessThan(u8, 3) == 0;
    if (deep) try p.appendSlice(arena, "**/");
    for (0..r.intRangeAtMost(usize, 1, 3)) |i| {
        if (i > 0) try p.append(arena, '/');
        try p.appendSlice(arena, segs[r.uintLessThan(usize, segs.len)]);
    }
    if (r.uintLessThan(u8, 7) == 0) try p.append(arena, '/');
    return p.items;
}

fn tree(out: *Io.Writer, r: std.Random, depth: u32) !void {
    try out.writeByte('{');
    var used: [names.len]bool = @splat(false);
    var first = true;
    for (0..r.uintAtMost(usize, 6)) |_| {
        const i = r.uintLessThan(usize, names.len);
        if (used[i]) continue;
        used[i] = true;
        if (!first) try out.writeByte(',');
        first = false;
        try out.print("\"{s}\":", .{names[i]});
        if (depth < 3 and r.uintLessThan(u8, 5) < 2) try tree(out, r, depth + 1) else try out.writeAll("null");
    }
    try out.writeByte('}');
}

/// The case's tree, as paths: `/` holds `w`, the workspace.
const Mem = struct {
    kinds: std.StringHashMapUnmanaged(glob.Kind) = .empty,
    lists: std.StringHashMapUnmanaged([]const []const u8) = .empty,

    fn add(m: *Mem, arena: Allocator, path: []const u8, v: std.json.Value) !void {
        if (v != .object) return m.kinds.put(arena, path, .file);
        try m.kinds.put(arena, path, .directory);
        var children: std.ArrayList([]const u8) = .empty;
        var it = v.object.iterator();
        while (it.next()) |e| {
            try children.append(arena, e.key_ptr.*);
            try m.add(arena, try std.mem.concat(arena, u8, &.{ path, "/", e.key_ptr.* }), e.value_ptr.*);
        }
        try m.lists.put(arena, path, children.items);
    }

    fn fs(m: *Mem) glob.Fs {
        return .{ .ptr = m, .vtable = &.{ .stat = stat, .list = list, .realpath = null } };
    }
    fn stat(ptr: *anyopaque, arena: Allocator, paths: []const []const u8, _: bool) glob.Fs.Error![]const glob.Kind {
        const m: *Mem = @ptrCast(@alignCast(ptr));
        const out = try arena.alloc(glob.Kind, paths.len);
        for (paths, out) |p, *k| k.* = m.kinds.get(p) orelse .missing;
        return out;
    }
    fn list(ptr: *anyopaque, arena: Allocator, dirs: []const []const u8) glob.Fs.Error![]const []const []const u8 {
        const m: *Mem = @ptrCast(@alignCast(ptr));
        const out = try arena.alloc([]const []const u8, dirs.len);
        for (dirs, out) |d, *l| l.* = m.lists.get(d) orelse &.{};
        return out;
    }
};

fn run(arena: Allocator, out: *Io.Writer, line: []const u8) !void {
    const case = (try std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{})).object;
    const id = case.get("id").?.integer;
    var mem: Mem = .{};
    try mem.kinds.put(arena, "/", .directory);
    try mem.lists.put(arena, "/", &.{"w"});
    try mem.add(arena, "/w", case.get("tree").?);
    var patterns: std.ArrayList([]const u8) = .empty;
    for (case.get("patterns").?.array.items) |p| try patterns.append(arena, p.string);
    const parsed = switch (try glob.parse(arena, patterns.items, "/w", "/home/u")) {
        .ok => |ok| ok,
        .invalid => return out.print("{{\"id\":{d},\"invalid\":true}}\n", .{id}),
    };
    var why: []const u8 = "";
    const files = switch (try glob.walk(arena, mem.fs(), parsed.patterns, false, "/w", &why)) {
        .files => |f| f,
        .failed => |w| return out.print("{{\"id\":{d},\"failed\":{f}}}\n", .{ id, std.json.fmt(w, .{}) }),
    };
    try out.print("{{\"id\":{d},\"files\":{f}}}\n", .{ id, std.json.fmt(files, .{}) });
}
