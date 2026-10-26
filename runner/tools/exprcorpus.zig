//! Runs GitHub's expression test cases (actions/languageservices, expressions/testdata) through
//! the runner's evaluator (src/expr.zig) and prints each case where they disagree, then a count
//! per file. With `--failing`, only the names of the cases that disagree, one per line.
//! `.github/scripts/expr-conformance.sh` fetches the cases and builds and runs this.
//!
//!     exprcorpus <testdata dir> [--failing]
//!
//! A case passes when the value matches (kind and value), or when GitHub reports an error and so
//! does the runner: a lexing or parsing error as error.ParseError, an evaluation error as
//! error.EvalError. The error messages are not compared.
const std = @import("std");
const expr = @import("expr");

const Value = expr.Value;

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) {
        std.debug.print("usage: exprcorpus <testdata dir> [--failing]\n", .{});
        return 2;
    }
    const names_only = args.len > 2 and std.mem.eql(u8, args[2], "--failing");

    var out_buf: [8192]u8 = undefined;
    var out_w: std.Io.File.Writer = .initStreaming(.stdout(), io, &out_buf);
    const out = &out_w.interface;
    defer out.flush() catch {};

    var dir = try std.Io.Dir.cwd().openDir(io, args[1], .{ .iterate = true });
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (e.kind == .file and std.mem.endsWith(u8, e.name, ".json"))
            try names.append(arena, try arena.dupe(u8, e.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    var totals: Counts = .{};
    for (names.items) |name| {
        const text = try dir.readFileAlloc(io, name, arena, .limited(16 << 20));
        const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
        var counts: Counts = .{};
        var suites = root.object.iterator();
        while (suites.next()) |suite| {
            for (suite.value_ptr.array.items, 0..) |case, i| {
                const verdict = try runCase(arena, case.object);
                counts.add(verdict.kind);
                if (verdict.kind != .pass and names_only) {
                    try out.print("{s}/{s}/{d}\n", .{ name[0 .. name.len - 5], suite.key_ptr.*, i });
                } else if (verdict.kind != .pass) {
                    try out.print("{s}/{s}/{d}  [{s}]  {s}\n    expected {s}\n    got      {s}\n", .{
                        name[0 .. name.len - 5], suite.key_ptr.*,                  i,
                        @tagName(verdict.kind),  case.object.get("expr").?.string, verdict.expected,
                        verdict.got,
                    });
                }
            }
        }
        if (!names_only) try out.print("{s}: {d}/{d} pass\n", .{ name, counts.pass, counts.total() });
        totals.addAll(counts);
    }
    if (!names_only) try out.print(
        "\ntotal: {d}/{d} pass; {d} wrong value, {d} error where GitHub has a value, " ++
            "{d} value where GitHub errs, {d} other error kind, {d} unsupported\n",
        .{
            totals.pass,          totals.total(),    totals.wrong_value, totals.unexpected_error,
            totals.missing_error, totals.error_kind, totals.unsupported,
        },
    );
    return if (names_only or totals.pass == totals.total()) 0 else 1;
}

const Kind = enum { pass, wrong_value, unexpected_error, missing_error, error_kind, unsupported };

const Counts = struct {
    pass: usize = 0,
    wrong_value: usize = 0,
    unexpected_error: usize = 0,
    missing_error: usize = 0,
    error_kind: usize = 0,
    unsupported: usize = 0,

    fn add(c: *Counts, k: Kind) void {
        switch (k) {
            inline else => |t| @field(c, @tagName(t)) += 1,
        }
    }
    fn addAll(c: *Counts, o: Counts) void {
        inline for (comptime std.meta.fieldNames(Counts)) |f| @field(c, f) += @field(o, f);
    }
    fn total(c: Counts) usize {
        var n: usize = 0;
        inline for (comptime std.meta.fieldNames(Counts)) |f| n += @field(c, f);
        return n;
    }
};

const Verdict = struct { kind: Kind, expected: []const u8 = "", got: []const u8 = "" };

fn runCase(arena: std.mem.Allocator, case: std.json.ObjectMap) !Verdict {
    var contexts: []const Value.Entry = &.{};
    if (case.get("contexts")) |c| contexts = (try expr.fromJsonValue(arena, c)).object;
    var diag: []const u8 = "";
    const scope: expr.Scope = .{ .contexts = contexts, .diag = &diag };
    const result = expr.evaluate(arena, case.get("expr").?.string, scope);

    if (case.get("err")) |want| {
        const kind = want.object.get("kind").?.string;
        const expected = try std.fmt.allocPrint(arena, "{s} error: {s}", .{
            kind, want.object.get("value").?.string,
        });
        const v = result catch |e| {
            const parse = std.mem.eql(u8, kind, "lexing") or std.mem.eql(u8, kind, "parsing");
            const same = if (parse) e == error.ParseError else e == error.EvalError;
            const got = try std.fmt.allocPrint(arena, "{s}: {s}", .{ @errorName(e), diag });
            return .{ .kind = if (same) .pass else .error_kind, .expected = expected, .got = got };
        };
        return .{ .kind = .missing_error, .expected = expected, .got = try show(arena, v) };
    }

    const want = case.get("result").?.object;
    const expected_value = try expectedValue(arena, want);
    const expected = try show(arena, expected_value);
    const v = result catch |e| {
        const got = try std.fmt.allocPrint(arena, "{s}: {s}", .{ @errorName(e), diag });
        return .{
            .kind = if (e == error.Unsupported) .unsupported else .unexpected_error,
            .expected = expected,
            .got = got,
        };
    };
    if (equal(v, expected_value)) return .{ .kind = .pass };
    return .{ .kind = .wrong_value, .expected = expected, .got = try show(arena, v) };
}

/// The expected value, typed by `kind`: the corpus writes Infinity and NaN results as strings.
fn expectedValue(arena: std.mem.Allocator, want: std.json.ObjectMap) !Value {
    const kind = want.get("kind").?.string;
    const value = want.get("value") orelse return .null;
    if (std.mem.eql(u8, kind, "Number") and value == .string)
        return .{ .number = std.fmt.parseFloat(f64, value.string) catch std.math.nan(f64) };
    return expr.fromJsonValue(arena, value);
}

fn equal(a: Value, b: Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .null => true,
        .boolean => |x| x == b.boolean,
        .number => |x| x == b.number or (std.math.isNan(x) and std.math.isNan(b.number)),
        .string => |x| std.mem.eql(u8, x, b.string),
        .array => |x| blk: {
            if (x.len != b.array.len) break :blk false;
            for (x, b.array) |p, q| if (!equal(p, q)) break :blk false;
            break :blk true;
        },
        .object => |x| blk: {
            if (x.len != b.object.len) break :blk false;
            outer: for (x) |e| {
                for (b.object) |f| if (std.mem.eql(u8, e.key, f.key)) {
                    if (!equal(e.value, f.value)) break :blk false;
                    continue :outer;
                };
                break :blk false;
            }
            break :blk true;
        },
    };
}

fn show(arena: std.mem.Allocator, v: Value) ![]const u8 {
    return switch (v) {
        .null => "null",
        .boolean => |b| if (b) "true" else "false",
        .number => |n| std.fmt.allocPrint(arena, "number {d}", .{n}),
        .string => |s| std.fmt.allocPrint(arena, "'{s}'", .{s}),
        .array => |a| blk: {
            var list: std.ArrayList(u8) = .empty;
            try list.append(arena, '[');
            for (a, 0..) |e, i| {
                if (i > 0) try list.appendSlice(arena, ", ");
                try list.appendSlice(arena, try show(arena, e));
            }
            try list.append(arena, ']');
            break :blk list.items;
        },
        .object => |o| blk: {
            var list: std.ArrayList(u8) = .empty;
            try list.append(arena, '{');
            for (o, 0..) |e, i| {
                if (i > 0) try list.appendSlice(arena, ", ");
                try list.print(arena, "{s}: {s}", .{ e.key, try show(arena, e.value) });
            }
            try list.append(arena, '}');
            break :blk list.items;
        },
    };
}
