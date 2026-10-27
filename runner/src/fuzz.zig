//! Fuzz tests for the parsers that read what jobs, workflows and servers hand the runner: workflow
//! commands, problem matchers and their regular expressions, YAML, expressions, hashFiles()
//! patterns and HPACK. A crash in any of them takes the whole runner down, every job on it
//! included, so each test holds the parser to returning, with an answer or an error, whatever the
//! input, plus what must hold of the answer.
//!
//! `zig build test` runs each over its seed corpus below (and empty input), as ordinary tests;
//! `zig build test --fuzz` runs them continuously, mutating the seeds (Zig's fuzzer, with a web UI
//! showing coverage). A crash it finds belongs in the corpus once fixed.
const std = @import("std");

const commands = @import("commands.zig");
const expr = @import("expr.zig");
const glob = @import("glob.zig");
const hpack = @import("hpack.zig");
const matcher = @import("matcher.zig");
const regex = @import("regex.zig");
const yaml = @import("yaml.zig");

const Smith = std.testing.Smith;

/// The next input string, at most `buf.len` bytes.
fn take(smith: *Smith, buf: []u8) []const u8 {
    return buf[0..smith.slice(buf)];
}

/// A corpus entry of strings, as `take` reads them: each a little-endian u32 length, then the bytes.
fn seed(comptime parts: []const []const u8) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (parts) |p| {
            var len: [4]u8 = undefined;
            std.mem.writeInt(u32, &len, p.len, .little);
            out = out ++ len ++ p;
        }
        const final = out[0..out.len].*;
        return &final;
    }
}

fn seeds(comptime list: []const []const []const u8) []const []const u8 {
    comptime {
        var out: [list.len][]const u8 = undefined;
        for (list, &out) |parts, *o| o.* = seed(parts);
        const final = out;
        return &final;
    }
}

test "fuzz: workflow commands" {
    try std.testing.fuzz({}, workflowCommands, .{ .corpus = comptime seeds(&.{
        &.{"::set-output name=x::1"},
        &.{"::error file=a.zig,line=3,col=7,title=T%0A::boom%25"},
        &.{"::add-mask::secret"},
        &.{"::stop-commands::tok"},
        &.{"::add-matcher::.github/m.json"},
        &.{"  ::warning ::  "},
        &.{"::debug::%0D%0A%3A%3A"},
        &.{"NAME<<EOF\nline\nEOF\nB=2\n"},
        &.{"/usr/bin\n\n/opt/x\n"},
    }) });
}

fn workflowCommands(_: void, smith: *Smith) !void {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    var buf: [4096]u8 = undefined;
    const text = take(smith, &buf);
    _ = try commands.parseWorkflow(a.allocator(), text, null);
    _ = try commands.parseWorkflow(a.allocator(), text, "tok");
    // The same text as a step's GITHUB_ENV / GITHUB_OUTPUT and GITHUB_PATH files.
    _ = try commands.parseKeyValues(a.allocator(), text);
    _ = try commands.parsePaths(a.allocator(), text);
}

test "fuzz: problem matchers" {
    try std.testing.fuzz({}, problemMatchers, .{ .corpus = comptime seeds(&.{
        &.{
            \\{"problemMatcher":[{"owner":"zig","pattern":[{"regexp":"^(.+):(\\d+):(\\d+): (error|warning): (.*)$","file":1,"line":2,"column":3,"severity":4,"message":5}]}]}
            ,
            "src/main.zig:3:7: error: expected type",
        },
        &.{
            \\{"problemMatcher":[{"owner":"eslint","severity":"warning","pattern":[{"regexp":"^([^\\s].*)$","file":1},{"regexp":"^\\s+(\\d+):(\\d+)\\s+(error|warning)\\s+(.*)$","line":1,"column":2,"severity":3,"message":4,"loop":true}]}]}
            ,
            "a.js\n  1:2  error  bad\n  3:4  warning  meh\n\n",
        },
        &.{
            \\{"problemMatcher":[{"owner":"x","pattern":[{"regexp":"(?<n>a)\\k<n>(?=b)(?<!c)","message":1}]}]}
            ,
            "aab",
        },
    }) });
}

fn problemMatchers(_: void, smith: *Smith) !void {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var jbuf: [4096]u8 = undefined;
    var lbuf: [4096]u8 = undefined;
    const json = take(smith, &jbuf);
    const lines = take(smith, &lbuf);
    const loaded = matcher.load(arena, json) catch |e| switch (e) {
        error.BadMatcher => return,
        else => return e,
    };
    var set: matcher.Set = .{};
    try set.add(arena, loaded.matchers);
    var it = std.mem.splitScalar(u8, lines, '\n');
    while (it.next()) |line| _ = set.feed(arena, line) catch |e| switch (e) {
        error.BadMatcher => {},
        else => return e,
    };
}

test "fuzz: regular expressions" {
    try std.testing.fuzz({}, regularExpressions, .{ .corpus = comptime seeds(&.{
        &.{ "^(.+):(\\d+):(\\d+): (error|warning): (.*)$", "src/a.zig:1:2: error: x" },
        &.{ "(a|ab)(c|bcd)(d*)", "abcd" },
        &.{ "(?:(a)|b)\\1", "aa ba" },
        &.{ "(?<=\\$)\\d+(?!\\.)", "$12.5 $30" },
        &.{ "[^\\]a-c-]+?x{2,3}\\b", "zzxxx yx" },
        &.{ "(a+)+$", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaab" },
        &.{ "\\101\\x41\\u0041\\cA[\\b]", "AAA\x01\x08" },
        &.{ "(?(1)a|b)(x)?", "bx" },
    }) });
}

fn regularExpressions(_: void, smith: *Smith) !void {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var pbuf: [256]u8 = undefined;
    var ibuf: [1024]u8 = undefined;
    const pattern = take(smith, &pbuf);
    const input = take(smith, &ibuf);
    const re = regex.Regex.compile(arena, pattern) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => return,
    };
    var from: usize = 0;
    while (from <= input.len) {
        const caps = (re.find(arena, input, from) catch |e| switch (e) {
            error.OutOfMemory => return e,
            else => return,
        }) orelse return;
        // Every group that took part lies within the input, in order.
        var n: usize = 0;
        while (n <= re.group_count) : (n += 1) {
            const g = caps.group(n) orelse continue;
            try std.testing.expect(g.start <= g.end and g.end <= input.len);
        }
        const whole = caps.group(0).?;
        try std.testing.expect(whole.start >= from);
        from = if (whole.end > whole.start) whole.end else whole.end + 1;
    }
}

test "fuzz: YAML" {
    try std.testing.fuzz({}, yamlDocuments, .{
        .corpus = comptime seeds(&.{
            &.{"on: push\njobs:\n  a:\n    runs-on: ubuntu-latest\n    steps:\n      - run: |\n          echo hi\n"},
            &.{"a: &x {b: [1, 2, {c: d}]}\ne: *x\nf: >-\n  folded\n  text\n"},
            &.{"- 'single ''quoted'''\n- \"double \\u00e9 \\n\"\n- ~\n- Null\n? complex\n: value\n"},
            &.{"key: [a, [b, [c, [d]]]]\n# comment\n---\n"},
            // Each once read an empty entry for ever, until memory ran out.
            &.{"a: [}]\n"},
            &.{"a: {]}\n"},
        }),
    });
}

fn yamlDocuments(_: void, smith: *Smith) !void {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    var buf: [8192]u8 = undefined;
    const source = take(smith, &buf);
    var diag: yaml.Diag = .{};
    _ = yaml.parse(a.allocator(), source, &diag) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => {},
    };
}

test "fuzz: expressions" {
    try std.testing.fuzz({}, expressions, .{ .corpus = comptime seeds(&.{
        &.{"github.event.pull_request.labels.*.name"},
        &.{"contains(fromJSON('[\"a\",\"b\"]'), matrix.os) && !cancelled()"},
        &.{"format('{0}-{1}', runner.os, hashFiles('**/x'))"},
        &.{"(1 < '2') == true || null >= 0 && 0x10 != 1e1"},
        &.{"toJSON(steps.*.outputs) == join(github.event.commits.*.id, ', ')"},
        &.{"startsWith(github.ref, 'refs/tags/') && endsWith(github.head_ref, 'x') || case(true, 1, 2)"},
    }) });
}

fn expressions(_: void, smith: *Smith) !void {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var buf: [2048]u8 = undefined;
    const text = take(smith, &buf);
    const contexts_json =
        \\{"github":{"ref":"refs/heads/main","head_ref":"","event":{"pull_request":{"labels":[{"name":"a"},{"name":"b"}]},"commits":[{"id":"1"},{"id":"2"}]}},
        \\ "matrix":{"os":"a"},"runner":{"os":"Linux"},"steps":{"s":{"outputs":{"o":"1"},"outcome":"success"}},
        \\ "env":{"A":"1"},"inputs":{"n":3.5,"b":true,"z":null}}
    ;
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, contexts_json, .{});
    const scope: expr.Scope = .{ .contexts = (try expr.fromJsonValue(arena, parsed)).object };
    _ = expr.evaluate(arena, text, scope) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => {},
    };
    _ = expr.interpolate(arena, text, scope) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => {},
    };
}

test "fuzz: hashFiles patterns" {
    try std.testing.fuzz({}, hashFilesPatterns, .{ .corpus = comptime seeds(&.{
        &.{"**/*.txt\n!a/skip.txt"},
        &.{"--follow-symbolic-links\n~/x/**"},
        &.{"[ab]?/**/[!x]*\n# comment\n/w/../w/./b.txt"},
        &.{"a/**/b/**\n!**/b"},
    }) });
}

const fuzz_tree = struct {
    const Kind = glob.Kind;
    const kinds = [_]struct { []const u8, Kind }{
        .{ "/w", .directory },     .{ "/w/a", .directory },  .{ "/w/a/x.txt", .file },
        .{ "/w/a/b", .directory }, .{ "/w/a/b/y", .file },   .{ "/w/b.txt", .file },
        .{ "/w/.h", .file },       .{ "/w/link", .symlink },
    };
    const lists = [_]struct { []const u8, []const []const u8 }{
        .{ "/w", &.{ "a", "b.txt", ".h", "link" } },
        .{ "/w/a", &.{ "x.txt", "b" } },
        .{ "/w/a/b", &.{"y"} },
    };
    fn fs() glob.Fs {
        return .{ .ptr = undefined, .vtable = &.{ .stat = stat, .list = list, .realpath = null } };
    }
    fn stat(_: *anyopaque, arena: std.mem.Allocator, paths: []const []const u8, _: bool) glob.Fs.Error![]const Kind {
        const out = try arena.alloc(Kind, paths.len);
        for (paths, out) |p, *k| {
            k.* = .missing;
            for (kinds) |e| if (std.mem.eql(u8, e[0], p)) {
                k.* = e[1];
            };
        }
        return out;
    }
    fn list(_: *anyopaque, arena: std.mem.Allocator, dirs: []const []const u8) glob.Fs.Error![]const []const []const u8 {
        const out = try arena.alloc([]const []const u8, dirs.len);
        for (dirs, out) |d, *l| {
            l.* = &.{};
            for (lists) |e| if (std.mem.eql(u8, e[0], d)) {
                l.* = e[1];
            };
        }
        return out;
    }
};

fn hashFilesPatterns(_: void, smith: *Smith) !void {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var buf: [1024]u8 = undefined;
    const text = take(smith, &buf);
    // Arguments one per line, as hashFiles('a', 'b') passes them; a first `--` one is an option.
    var args: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |arg| try args.append(arena, arg);
    const parsed = switch (try glob.parse(arena, args.items, "/w", "/home/u")) {
        .ok => |ok| ok,
        .invalid => return,
    };
    var why: []const u8 = "";
    switch (try glob.walk(arena, fuzz_tree.fs(), parsed.patterns, false, "/w", &why)) {
        // Only files of the tree, within the workspace, each once.
        .files => |files| for (files, 0..) |f, i| {
            try std.testing.expect(std.mem.startsWith(u8, f, "/w/"));
            for (files[0..i]) |g| try std.testing.expect(!std.mem.eql(u8, f, g));
            var known = false;
            for (fuzz_tree.kinds) |e| known = known or std.mem.eql(u8, e[0], f);
            try std.testing.expect(known);
        },
        .failed => {},
    }
}

test "fuzz: HPACK" {
    try std.testing.fuzz({}, hpackBlocks, .{
        .corpus = comptime seeds(&.{
            // :status 200, then a literal with incremental indexing and its dynamic-table reference.
            &.{ "\x88\x40\x0acustom-key\x0dcustom-header\xbe", "\x8c\x82" },
            // A Huffman-coded literal (www.example.com) and a table size update.
            &.{ "\x41\x8c\xf1\xe3\xc2\xe5\xf2\x3a\x6b\xa0\xab\x90\xf4\xff", "\x3f\xe1\x1f\x82" },
        }),
    });
}

fn hpackBlocks(_: void, smith: *Smith) !void {
    var d: hpack.Decoder = .{ .gpa = std.testing.allocator };
    defer d.deinit();
    var buf: [2048]u8 = undefined;
    const Sum = struct {
        fn on(n: *usize, name: []const u8, value: []const u8) void {
            n.* += name.len + value.len;
        }
    };
    var seen: usize = 0;
    // Blocks in turn, as one connection's: the dynamic table carries over.
    while (!smith.eos()) {
        d.decode(take(smith, &buf), &seen, Sum.on) catch |e| switch (e) {
            error.OutOfMemory => return e,
            else => return,
        };
        try std.testing.expect(d.size <= d.max_size);
    }
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    _ = hpack.huffmanDecode(a.allocator(), take(smith, &buf)) catch {};
}
