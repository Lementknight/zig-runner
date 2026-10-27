//! `hashFiles(patterns)`: which files the patterns select. The listing itself is Dagger's `glob`
//! in the job's container and the hashing `sha256sum` there (dagger.zig, `Exec.hashFiles`); this
//! is the part between, kept apart so that `.github/scripts/hashfiles-diff.sh` can compare it with
//! GitHub's own (actions/runner's hashFiles script, on @actions/glob).
const std = @import("std");

const Allocator = std.mem.Allocator;

/// One pattern as written: a glob relative to the workspace, whether it excludes, and whether it
/// matches directories only (written with a trailing `/`: `*/` is every file in a subdirectory,
/// not every file, as @actions/glob reads it).
pub const Pattern = struct { glob: []const u8, exclude: bool, dir_only: bool = false };

/// The patterns, or why GitHub would refuse them.
pub const Parsed = union(enum) {
    /// Nothing includes: the result is "" without a query.
    none,
    ok: []const Pattern,
    invalid: []const u8,
};

/// The patterns as GitHub reads them: one per argument or line, `#` lines and blanks skipped,
/// `!` excluding; absolute paths inside the workspace made relative, those outside it ignored.
/// A `.` or `..` segment (after a leading `./`) is refused, as @actions/glob refuses it.
pub fn patterns(
    arena: Allocator,
    ws: []const u8,
    args: []const []const u8,
) Allocator.Error!Parsed {
    var out: std.ArrayList(Pattern) = .empty;
    var any_include = false;
    for (args) |arg| {
        var lines = std.mem.splitScalar(u8, arg, '\n');
        while (lines.next()) |raw| {
            var p = std.mem.trim(u8, raw, " \t\r");
            if (p.len == 0 or p[0] == '#') continue;
            const exclude = p[0] == '!';
            if (exclude) p = std.mem.trimStart(u8, p[1..], " ");
            const in_ws = std.mem.startsWith(u8, p, ws) and
                std.mem.startsWith(u8, p[ws.len..], "/");
            // An absolute path outside the workspace: GitHub ignores those files.
            if (in_ws) p = p[ws.len + 1 ..] //
            else if (std.mem.eql(u8, p, ws)) p = "**" //
            else if (p.len > 0 and p[0] == '/') continue;
            while (std.mem.startsWith(u8, p, "./")) p = p[2..];
            var segments = std.mem.splitScalar(u8, p, '/');
            while (segments.next()) |seg| if (std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, "..")) {
                return .{ .invalid = try std.fmt.allocPrint(
                    arena,
                    "invalid pattern '{s}': '.' and '..' are not allowed in it",
                    .{std.mem.trim(u8, raw, " \t\r")},
                ) };
            };
            const dir_only = std.mem.endsWith(u8, p, "/");
            p = std.mem.trimEnd(u8, p, "/");
            if (p.len == 0) continue;
            if (!exclude) any_include = true;
            try out.append(arena, .{ .glob = p, .exclude = exclude, .dir_only = dir_only });
        }
    }
    if (!any_include) return .none;
    return .{ .ok = out.items };
}

/// The directories among what Dagger's glob listed for the patterns (entries ending in `/`), each
/// once. What they hold is listed apart, `directory(path: D).glob("**")`: globbing into them
/// (`P/**`) is what the runner did first, and Dagger's glob lists nothing for a literal directory,
/// `*`, then `**` (`src/*/**`), so `hashFiles('src/*')` missed everything in `src/util/`.
pub fn directories(arena: Allocator, as_given: []const []const []const u8) Allocator.Error![]const []const u8 {
    var dirs: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (as_given) |found| for (found) |path| {
        if (std.mem.endsWith(u8, path, "/")) try dirs.put(arena, path, {});
    };
    return dirs.keys();
}

/// The files selected, in path order. `as_given[i]` is what Dagger's glob listed for `pats[i]`;
/// `contents` holds, for each of `directories(as_given)`, what is in it (relative to it). A
/// pattern selects the files it matches and everything in the directories it matches; a
/// directories-only pattern, only the latter. The last pattern that matches a file decides.
pub fn select(
    arena: Allocator,
    pats: []const Pattern,
    as_given: []const []const []const u8,
    contents: *const std.StringHashMapUnmanaged([]const []const u8),
) Allocator.Error![]const []const u8 {
    const sets = try arena.alloc(std.StringHashMapUnmanaged(void), pats.len);
    var candidates: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (pats, sets, as_given) |p, *set, found| {
        set.* = .empty;
        for (found) |path| {
            if (std.mem.endsWith(u8, path, "/")) {
                for (contents.get(path) orelse &.{}) |entry| {
                    if (std.mem.endsWith(u8, entry, "/")) continue; // a directory inside
                    const file = try std.mem.concat(arena, u8, &.{ path, entry });
                    try set.put(arena, file, {});
                    if (!p.exclude) try candidates.put(arena, file, {});
                }
            } else if (!p.dir_only) {
                try set.put(arena, path, {});
                if (!p.exclude) try candidates.put(arena, path, {});
            }
        }
    }
    var files: std.ArrayList([]const u8) = .empty;
    for (candidates.keys()) |path| {
        var included = false;
        for (pats, sets) |p, set| if (set.contains(path)) {
            included = !p.exclude;
        };
        if (included) try files.append(arena, path);
    }
    std.mem.sort([]const u8, files.items, {}, struct {
        fn lt(_: void, l: []const u8, r: []const u8) bool {
            return std.mem.lessThan(u8, l, r);
        }
    }.lt);
    return files.items;
}

test "patterns: lines, comments, exclusions, the workspace, trailing slashes, and . or .." {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    const ws = "/w";
    const got = (try patterns(ar, ws, &.{ "**/*.go\n# note\n\n!vendor/**", "/w/go.sum", "./src/", "/elsewhere" })).ok;
    try std.testing.expectEqual(@as(usize, 4), got.len);
    try std.testing.expectEqualStrings("**/*.go", got[0].glob);
    try std.testing.expect(got[1].exclude and std.mem.eql(u8, got[1].glob, "vendor/**"));
    try std.testing.expectEqualStrings("go.sum", got[2].glob);
    try std.testing.expect(got[3].dir_only and std.mem.eql(u8, got[3].glob, "src"));
    try std.testing.expect(try patterns(ar, ws, &.{ "!x", "/elsewhere" }) == .none);
    try std.testing.expect(try patterns(ar, ws, &.{"src/./main.go"}) == .invalid);
    try std.testing.expect(try patterns(ar, ws, &.{"../w/go.sum"}) == .invalid);
}

test "select: a matched directory brings what is in it, `*/` only that, and the last match decides" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    // What Dagger listed for `src/*`, `!src/*_test.go` and `*/`, and what is in `src/util/`.
    const as_given: []const []const []const u8 = &.{
        &.{ "src/main.go", "src/main_test.go", "src/util/" },
        &.{"src/main_test.go"},
        &.{ "src/", "top.txt" },
    };
    try std.testing.expectEqualDeep(@as([]const []const u8, &.{"src/util/"}), try directories(ar, as_given[0..1]));
    var contents: std.StringHashMapUnmanaged([]const []const u8) = .empty;
    try contents.put(ar, "src/util/", &.{ "util.go", "deeper/", "deeper/x.go" });
    try contents.put(ar, "src/", &.{ "main.go", "main_test.go", "util/", "util/util.go" });
    const pats: []const Pattern = &.{
        .{ .glob = "src/*", .exclude = false },
        .{ .glob = "src/*_test.go", .exclude = true },
    };
    try std.testing.expectEqualDeep(
        @as([]const []const u8, &.{ "src/main.go", "src/util/deeper/x.go", "src/util/util.go" }),
        try select(ar, pats, as_given[0..2], &contents),
    );
    // `*/`: what is in the directories it matches, not top.txt.
    try std.testing.expectEqualDeep(
        @as([]const []const u8, &.{ "src/main.go", "src/main_test.go", "src/util/util.go" }),
        try select(ar, &.{.{ .glob = "*", .exclude = false, .dir_only = true }}, as_given[2..3], &contents),
    );
}
