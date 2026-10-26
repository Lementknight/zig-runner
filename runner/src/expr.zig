//! GitHub Actions expressions (`${{ ... }}` and `if:` conditions).
//!
//! A small tokenizer, parser and evaluator following GitHub's documented semantics: literals,
//! context lookups (`github.sha`, `env.X`, `steps.id.outputs.y`, `matrix['os']`), the operators
//! `! < <= > >= == != && ||` with GitHub's loose type coercion (string comparison is case
//! insensitive, `&&`/`||` return an operand), and the functions contains, startsWith, endsWith,
//! format, join, toJSON, fromJSON, success/always/cancelled/failure, and hashFiles when the scope
//! can read files (`Scope.hash_files`). The `*` object filter is not supported and reports so,
//! instead of evaluating wrongly.
const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Value = union(enum) {
    null,
    boolean: bool,
    number: f64,
    string: []const u8,
    array: []const Value,
    /// Property names are matched case-insensitively, as GitHub does.
    object: []const Entry,

    pub const Entry = struct { key: []const u8, value: Value };

    pub fn str(s: []const u8) Value {
        return .{ .string = s };
    }
};

pub const Error = error{ ParseError, EvalError, Unsupported, OutOfMemory };

/// Computes `hashFiles(patterns)` where the job's files are (the caller supplies it).
pub const HashFiles = struct {
    ptr: *anyopaque,
    hashFn: *const fn (
        ptr: *anyopaque,
        arena: Allocator,
        patterns: []const []const u8,
    ) Allocator.Error!Result,

    /// The hex hash ("" when no file matched), or why it could not be computed.
    pub const Result = union(enum) { ok: []const u8, failed: []const u8 };
};

/// What an expression can see.
pub const Scope = struct {
    /// Top-level contexts: `github`, `env`, `steps`, `job`, `runner`, `secrets`, `vars`, ...
    contexts: []const Value.Entry = &.{},
    /// True once a step failed without continue-on-error (drives `success()` / `failure()`).
    job_failed: bool = false,
    cancelled: bool = false,
    /// Contexts that exist in GitHub but that this runner cannot provide yet (for example
    /// `secrets`). Referencing one is an error instead of silently evaluating to an empty value.
    unsupported_contexts: []const []const u8 = &.{},
    /// Receives a human-readable reason when an error is returned. Optional.
    diag: ?*[]const u8 = null,
    /// What `hashFiles()` reads files with; without it, `hashFiles()` is unsupported.
    hash_files: ?HashFiles = null,
    /// Bytes the functions that build strings have made so far; `evaluate` sets it.
    memory: ?*usize = null,

    fn fail(s: Scope, comptime fmt: []const u8, args: anytype, arena: Allocator) Error {
        if (s.diag) |d| d.* = std.fmt.allocPrint(arena, fmt, args) catch "expression error";
        return error.EvalError;
    }

    /// Counts `n` more bytes against the evaluation's memory limit (`max_memory`).
    fn charge(s: Scope, n: usize, arena: Allocator) Error!void {
        const used = s.memory orelse return;
        used.* += n;
        if (used.* > max_memory) return s.fail(
            "the expression needs more than {d} MiB of memory",
            .{max_memory >> 20},
            arena,
        );
    }
};

/// What one evaluation's string-building functions (`format`, `join`, `toJSON`, `fromJSON`) may
/// make in all. GitHub refuses at about 1 MB, counted its own way; this is looser, to never refuse
/// what GitHub runs, and is here so that `format('{0}{0}{0}{0}', format('{0}{0}{0}{0}', ...))`
/// fails instead of growing until the runner runs out of memory.
const max_memory = 10 << 20;

/// How deeply `fromJSON` input may nest. Its result is converted (and compared, and written back)
/// recursively, so `fromJSON('[[[[...]]]]')` would otherwise overflow the stack.
const max_json_nesting = 1000;

// --- tokens ---

const Tok = union(enum) {
    number: f64,
    string: []const u8,
    ident: []const u8,
    lparen,
    rparen,
    lbracket,
    rbracket,
    dot,
    comma,
    star,
    not,
    and_and,
    or_or,
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
    eof,
};

/// A character that continues a number token at `i`: letters, digits and points (`0x1F`, `0o17`,
/// `1.5`, `Infinity`), and a sign right after an exponent's `e`. What the token means is up to
/// `jsNumber`; this only says where it ends.
fn isNumberChar(src: []const u8, i: usize) bool {
    const c = src[i];
    if (std.ascii.isAlphanumeric(c) or c == '_' or c == '.') return true;
    return (c == '+' or c == '-') and (src[i - 1] == 'e' or src[i - 1] == 'E') and
        !std.mem.startsWith(u8, std.mem.trimStart(u8, src[0..i], "+-"), "0x");
}

/// What JavaScript's `Number()` makes of a string, which is what GitHub's expressions follow, both
/// for number literals and for a string compared with a number: whitespace around it ignored, ""
/// is 0, a decimal with an optional sign, point and exponent (`-.5`, `1E+2`), `Infinity` with an
/// optional sign, and unsigned `0x`, `0o` and `0b` integers. Anything else is NaN. Stricter than
/// `std.fmt.parseFloat`, which also takes `inf`, `nan`, underscores and hex floats.
pub fn jsNumber(text: []const u8) f64 {
    const t = std.mem.trim(u8, text, " \t\r\n\x0b\x0c");
    if (t.len == 0) return 0;
    const nan = std.math.nan(f64);
    if (t.len > 2 and t[0] == '0') {
        const radix: ?u8 = switch (t[1]) {
            'x', 'X' => 16,
            'o', 'O' => 8,
            'b', 'B' => 2,
            else => null,
        };
        if (radix) |r| {
            var v: f64 = 0;
            for (t[2..]) |c| {
                const d = std.fmt.charToDigit(c, r) catch return nan;
                v = v * @as(f64, @floatFromInt(r)) + @as(f64, @floatFromInt(d));
            }
            return v;
        }
    }
    const neg = t[0] == '-';
    const body = if (t[0] == '-' or t[0] == '+') t[1..] else t;
    if (std.mem.eql(u8, body, "Infinity")) return if (neg) -std.math.inf(f64) else std.math.inf(f64);
    // digits [. digits] [e [sign] digits], with a digit somewhere before the exponent.
    var i: usize = 0;
    var digits: usize = 0;
    while (i < body.len and std.ascii.isDigit(body[i])) : (i += 1) digits += 1;
    if (i < body.len and body[i] == '.') {
        i += 1;
        while (i < body.len and std.ascii.isDigit(body[i])) : (i += 1) digits += 1;
    }
    if (digits == 0) return nan;
    if (i < body.len and (body[i] == 'e' or body[i] == 'E')) {
        i += 1;
        if (i < body.len and (body[i] == '+' or body[i] == '-')) i += 1;
        const start = i;
        while (i < body.len and std.ascii.isDigit(body[i])) i += 1;
        if (i == start) return nan;
    }
    if (i != body.len) return nan;
    const v = std.fmt.parseFloat(f64, body) catch return nan;
    return if (neg) -v else v;
}

const Lexer = struct {
    src: []const u8,
    i: usize = 0,
    arena: Allocator,
    diag: ?*[]const u8,

    fn bad(l: *Lexer, comptime fmt: []const u8, args: anytype) Error {
        if (l.diag) |d| d.* = std.fmt.allocPrint(
            l.arena,
            fmt ++ " (in expression: {s})",
            args ++ .{l.src},
        ) catch "invalid expression";
        return error.ParseError;
    }

    fn next(l: *Lexer, prev_is_value: bool) Error!Tok {
        while (l.i < l.src.len and std.ascii.isWhitespace(l.src[l.i])) l.i += 1;
        if (l.i >= l.src.len) return .eof;
        const c = l.src[l.i];
        const two: []const u8 = if (l.i + 1 < l.src.len) l.src[l.i .. l.i + 2] else "";
        if (std.mem.eql(u8, two, "&&")) return l.adv(2, .and_and);
        if (std.mem.eql(u8, two, "||")) return l.adv(2, .or_or);
        if (std.mem.eql(u8, two, "==")) return l.adv(2, .eq);
        if (std.mem.eql(u8, two, "!=")) return l.adv(2, .ne);
        if (std.mem.eql(u8, two, "<=")) return l.adv(2, .le);
        if (std.mem.eql(u8, two, ">=")) return l.adv(2, .ge);
        switch (c) {
            '(' => return l.adv(1, .lparen),
            ')' => return l.adv(1, .rparen),
            '[' => return l.adv(1, .lbracket),
            ']' => return l.adv(1, .rbracket),
            // `.5` is a number; any other point is a property access (`foo.*.bar`).
            '.' => if (prev_is_value or l.i + 1 >= l.src.len or !std.ascii.isDigit(l.src[l.i + 1]))
                return l.adv(1, .dot),
            ',' => return l.adv(1, .comma),
            '*' => return l.adv(1, .star),
            '!' => return l.adv(1, .not),
            '<' => return l.adv(1, .lt),
            '>' => return l.adv(1, .gt),
            '\'' => return l.string(),
            else => {},
        }
        // A sign or a point starts a number only where a value can start: after a value, `.` is a
        // property access.
        if (std.ascii.isDigit(c) or (!prev_is_value and (c == '-' or c == '+' or c == '.')))
            return l.number();
        if (std.ascii.isAlphabetic(c) or c == '_') {
            const start = l.i;
            while (l.i < l.src.len and (std.ascii.isAlphanumeric(l.src[l.i]) or l.src[l.i] == '_' or
                l.src[l.i] == '-')) l.i += 1;
            return .{ .ident = l.src[start..l.i] };
        }
        return l.bad("unexpected character '{c}'", .{c});
    }

    fn adv(l: *Lexer, n: usize, t: Tok) Tok {
        l.i += n;
        return t;
    }

    fn string(l: *Lexer) Error!Tok {
        l.i += 1; // opening quote
        var out: std.ArrayList(u8) = .empty;
        while (l.i < l.src.len) {
            const c = l.src[l.i];
            if (c == '\'') {
                if (l.i + 1 < l.src.len and l.src[l.i + 1] == '\'') {
                    try out.append(l.arena, '\'');
                    l.i += 2;
                    continue;
                }
                l.i += 1;
                return .{ .string = out.items };
            }
            try out.append(l.arena, c);
            l.i += 1;
        }
        return l.bad("unterminated string", .{});
    }

    fn number(l: *Lexer) Error!Tok {
        const start = l.i;
        l.i += 1;
        while (l.i < l.src.len and isNumberChar(l.src, l.i)) l.i += 1;
        const text = l.src[start..l.i];
        const v = jsNumber(text);
        if (std.math.isNan(v)) return l.bad("invalid number '{s}'", .{text});
        return .{ .number = v };
    }
};

// --- AST and parser ---

const BinOp = enum { and_, or_, eq, ne, lt, le, gt, ge };

const Node = union(enum) {
    literal: Value,
    ident: []const u8,
    prop: struct { obj: *Node, name: []const u8 },
    index: struct { obj: *Node, idx: *Node },
    star: *Node,
    call: struct { name: []const u8, args: []*Node },
    not: *Node,
    bin: struct { op: BinOp, l: *Node, r: *Node },
};

/// The functions there are, with how many arguments each takes.
const functions = [_]struct { name: []const u8, min: usize, max: usize }{
    .{ .name = "contains", .min = 2, .max = 2 },
    .{ .name = "startsWith", .min = 2, .max = 2 },
    .{ .name = "endsWith", .min = 2, .max = 2 },
    .{ .name = "format", .min = 1, .max = std.math.maxInt(usize) },
    .{ .name = "join", .min = 1, .max = 2 },
    .{ .name = "toJSON", .min = 1, .max = 1 },
    .{ .name = "fromJSON", .min = 1, .max = 1 },
    .{ .name = "hashFiles", .min = 1, .max = std.math.maxInt(usize) },
    .{ .name = "case", .min = 3, .max = std.math.maxInt(usize) },
    .{ .name = "success", .min = 0, .max = 0 },
    .{ .name = "always", .min = 0, .max = 0 },
    .{ .name = "cancelled", .min = 0, .max = 0 },
    .{ .name = "failure", .min = 0, .max = 0 },
};

/// GitHub refuses an expression nested deeper than this ("Exceeded max expression depth 50"). It
/// also keeps the parser's and the evaluator's recursion bounded: `action.yml` files are read as
/// written, with no check of GitHub's in between, and 100000 nested `!` overflowed the stack.
const max_depth = 50;

/// Every node is allocated with the depth of the tree under it, so the parser can refuse what is
/// too deep as it builds it.
const Slot = struct { node: Node, depth: u32 };

fn depthOf(n: *const Node) u32 {
    const slot: *const Slot = @fieldParentPtr("node", n);
    return slot.depth;
}

const Parser = struct {
    lex: Lexer,
    cur: Tok,
    prev_value: bool = false,
    /// How deep the parser itself has recursed (`!`, parentheses, arguments, indexes): `!!!...`
    /// recurses before it makes a single node.
    nesting: u32 = 0,

    fn init(arena: Allocator, src: []const u8, diag: ?*[]const u8) Error!Parser {
        var p: Parser = .{ .lex = .{ .src = src, .arena = arena, .diag = diag }, .cur = .eof };
        p.cur = try p.lex.next(false);
        return p;
    }

    fn advance(p: *Parser) Error!void {
        p.prev_value = switch (p.cur) {
            .number, .string, .ident, .rparen, .rbracket => true,
            else => false,
        };
        p.cur = try p.lex.next(p.prev_value);
    }

    fn node(p: *Parser, n: Node) Error!*Node {
        const below: u32 = switch (n) {
            .literal, .ident => 0,
            .prop => |x| depthOf(x.obj),
            .index => |x| @max(depthOf(x.obj), depthOf(x.idx)),
            .star, .not => |x| depthOf(x),
            .call => |c| blk: {
                var d: u32 = 0;
                for (c.args) |a| d = @max(d, depthOf(a));
                break :blk d;
            },
            // GitHub's `&&` and `||` take any number of operands: a chain of one of them is one
            // node, as deep as its deepest operand plus one, however long it is.
            .bin => |b| if ((b.op == .and_ or b.op == .or_) and b.l.* == .bin and b.l.bin.op == b.op)
                return p.slot(n, @max(depthOf(b.l), depthOf(b.r) + 1))
            else
                @max(depthOf(b.l), depthOf(b.r)),
        };
        return p.slot(n, below + 1);
    }

    fn slot(p: *Parser, n: Node, depth: u32) Error!*Node {
        if (depth > max_depth) return p.tooDeep();
        const s = try p.lex.arena.create(Slot);
        s.* = .{ .node = n, .depth = depth };
        return &s.node;
    }

    fn tooDeep(p: *Parser) Error {
        return p.lex.bad("the expression is nested more than {d} deep", .{max_depth});
    }

    /// GitHub refuses an unknown function, or one given the wrong number of arguments, when it
    /// parses the expression, so even where it would never be called (`false && nope()`).
    fn checkCall(p: *Parser, name: []const u8, n: usize) Error!void {
        for (functions) |f| if (std.ascii.eqlIgnoreCase(f.name, name)) {
            if (n < f.min) return p.lex.bad("too few arguments to {s}()", .{name});
            if (n > f.max) return p.lex.bad("too many arguments to {s}()", .{name});
            if (std.ascii.eqlIgnoreCase(name, "case") and n % 2 == 0)
                return p.lex.bad("case() takes an odd number of arguments", .{});
            return;
        };
        return p.lex.bad("unknown function '{s}'", .{name});
    }

    fn enter(p: *Parser) Error!void {
        p.nesting += 1;
        if (p.nesting > max_depth) return p.tooDeep();
    }

    fn expectEnd(p: *Parser) Error!void {
        if (p.cur != .eof)
            return p.lex.bad("unexpected token after the end of the expression", .{});
    }

    fn parseOr(p: *Parser) Error!*Node {
        var l = try p.parseAnd();
        while (p.cur == .or_or) {
            try p.advance();
            l = try p.node(.{ .bin = .{ .op = .or_, .l = l, .r = try p.parseAnd() } });
        }
        return l;
    }

    fn parseAnd(p: *Parser) Error!*Node {
        var l = try p.parseEq();
        while (p.cur == .and_and) {
            try p.advance();
            l = try p.node(.{ .bin = .{ .op = .and_, .l = l, .r = try p.parseEq() } });
        }
        return l;
    }

    fn parseEq(p: *Parser) Error!*Node {
        var l = try p.parseRel();
        while (p.cur == .eq or p.cur == .ne) {
            const op: BinOp = if (p.cur == .eq) .eq else .ne;
            try p.advance();
            l = try p.node(.{ .bin = .{ .op = op, .l = l, .r = try p.parseRel() } });
        }
        return l;
    }

    fn parseRel(p: *Parser) Error!*Node {
        var l = try p.parseUnary();
        while (p.cur == .lt or p.cur == .le or p.cur == .gt or p.cur == .ge) {
            const op: BinOp = switch (p.cur) {
                .lt => .lt,
                .le => .le,
                .gt => .gt,
                else => .ge,
            };
            try p.advance();
            l = try p.node(.{ .bin = .{ .op = op, .l = l, .r = try p.parseUnary() } });
        }
        return l;
    }

    fn parseUnary(p: *Parser) Error!*Node {
        if (p.cur == .not) {
            try p.advance();
            try p.enter();
            defer p.nesting -= 1;
            return p.node(.{ .not = try p.parseUnary() });
        }
        return p.parsePostfix();
    }

    fn parsePostfix(p: *Parser) Error!*Node {
        var n = try p.parsePrimary();
        while (true) {
            switch (p.cur) {
                .dot => {
                    try p.advance();
                    switch (p.cur) {
                        .ident => |name| {
                            try p.advance();
                            n = try p.node(.{ .prop = .{ .obj = n, .name = name } });
                        },
                        .star => {
                            try p.advance();
                            n = try p.node(.{ .star = n });
                        },
                        else => return p.lex.bad("expected a property name after '.'", .{}),
                    }
                },
                .lbracket => {
                    try p.advance();
                    try p.enter();
                    defer p.nesting -= 1;
                    const idx = try p.parseOr();
                    if (p.cur != .rbracket) return p.lex.bad("expected ']'", .{});
                    try p.advance();
                    n = try p.node(.{ .index = .{ .obj = n, .idx = idx } });
                },
                else => return n,
            }
        }
    }

    fn parsePrimary(p: *Parser) Error!*Node {
        switch (p.cur) {
            .number => |v| {
                try p.advance();
                return p.node(.{ .literal = .{ .number = v } });
            },
            .string => |s| {
                try p.advance();
                return p.node(.{ .literal = .{ .string = s } });
            },
            .lparen => {
                try p.advance();
                try p.enter();
                defer p.nesting -= 1;
                const inner = try p.parseOr();
                if (p.cur != .rparen) return p.lex.bad("expected ')'", .{});
                try p.advance();
                return inner;
            },
            .ident => |name| {
                try p.advance();
                if (p.cur == .lparen) {
                    try p.advance();
                    try p.enter();
                    defer p.nesting -= 1;
                    var args: std.ArrayList(*Node) = .empty;
                    if (p.cur != .rparen) {
                        while (true) {
                            try args.append(p.lex.arena, try p.parseOr());
                            if (p.cur == .comma) {
                                try p.advance();
                                continue;
                            }
                            break;
                        }
                    }
                    if (p.cur != .rparen)
                        return p.lex.bad("expected ')' after the arguments of {s}()", .{name});
                    try p.advance();
                    try p.checkCall(name, args.items.len);
                    return p.node(.{ .call = .{ .name = name, .args = args.items } });
                }
                if (std.ascii.eqlIgnoreCase(name, "true"))
                    return p.node(.{ .literal = .{ .boolean = true } });
                if (std.ascii.eqlIgnoreCase(name, "false"))
                    return p.node(.{ .literal = .{ .boolean = false } });
                if (std.ascii.eqlIgnoreCase(name, "null")) return p.node(.{ .literal = .null });
                if (std.ascii.eqlIgnoreCase(name, "nan"))
                    return p.node(.{ .literal = .{ .number = std.math.nan(f64) } });
                if (std.ascii.eqlIgnoreCase(name, "infinity"))
                    return p.node(.{ .literal = .{ .number = std.math.inf(f64) } });
                return p.node(.{ .ident = name });
            },
            else => return p.lex.bad("unexpected token", .{}),
        }
    }
};

fn parse(arena: Allocator, src: []const u8, diag: ?*[]const u8) Error!*Node {
    var p = try Parser.init(arena, src, diag);
    const n = try p.parseOr();
    try p.expectEnd();
    return n;
}

// --- coercion ---

pub fn toBool(v: Value) bool {
    return switch (v) {
        .null => false,
        .boolean => |b| b,
        .number => |n| n != 0 and !std.math.isNan(n),
        .string => |s| s.len > 0,
        .array, .object => true,
    };
}

pub fn toNumber(v: Value) f64 {
    return switch (v) {
        .null => 0,
        .boolean => |b| if (b) 1 else 0,
        .number => |n| n,
        .string => |s| jsNumber(s),
        .array, .object => std.math.nan(f64),
    };
}

pub fn toStr(arena: Allocator, v: Value) Allocator.Error![]const u8 {
    return switch (v) {
        .null => "",
        .boolean => |b| if (b) "true" else "false",
        .number => |n| numberToString(arena, n),
        .string => |s| s,
        .array => "Array",
        .object => "Object",
    };
}

fn numberToString(arena: Allocator, n: f64) Allocator.Error![]const u8 {
    if (std.math.isNan(n)) return "NaN";
    if (std.math.isInf(n)) return if (n > 0) "Infinity" else "-Infinity";
    if (@floor(n) == n and @abs(n) < 1e15)
        return std.fmt.allocPrint(arena, "{d}", .{@as(i64, @intFromFloat(n))});
    // 15 significant digits, as GitHub prints them: 0.84551240822557006 is "0.84551240822557".
    var buf: [64]u8 = undefined;
    const rounded = std.fmt.parseFloat(f64, std.fmt.bufPrint(&buf, "{e:.14}", .{n}) catch
        unreachable) catch n;
    return std.fmt.allocPrint(arena, "{d}", .{rounded});
}

fn sameKind(a: Value, b: Value) bool {
    return std.meta.activeTag(a) == std.meta.activeTag(b);
}

// --- case-insensitive strings ---
//
// GitHub compares strings as their upper-case forms, code point by code point: 'ü' == 'Ü', all
// three Greek sigmas are equal, and 'a' < '[' (because 'A' < '['). Zig's std has no Unicode case
// mapping, so `upperRune` maps the letters of Latin-1, Latin Extended-A, Greek and Cyrillic; other
// scripts compare as written.

/// The upper-case form of `c`, for the scripts listed above. Only letters that pair one to one:
/// GitHub keeps the dotless ı apart from I, and İ apart from i.
fn upperRune(c: u21) u21 {
    return switch (c) {
        'a'...'z' => c - 32,
        0xE0...0xF6, 0xF8...0xFE => c - 0x20,
        0xFF => 0x178,
        // Latin Extended-A: pairs, upper case first...
        0x100...0x12F, 0x132...0x137, 0x14A...0x177 => c & ~@as(u21, 1),
        // ...or upper case second.
        0x139...0x148, 0x179...0x17E => if (c % 2 == 0) c - 1 else c,
        0x3AC => 0x386,
        0x3AD...0x3AF => c - 37,
        0x3CC => 0x38C,
        0x3CD, 0x3CE => c - 63,
        0x3B1...0x3C1, 0x3C3...0x3CB => c - 0x20,
        0x3C2 => 0x3A3, // final sigma
        0x430...0x44F => c - 0x20,
        0x450...0x45F => c - 0x50,
        0x460...0x481, 0x48A...0x4BF, 0x4D0...0x52F => c & ~@as(u21, 1),
        0x4C1...0x4CE => if (c % 2 == 0) c - 1 else c,
        0x4CF => 0x4C0,
        else => c,
    };
}

/// The code point at `s[i.*]`, upper-cased, advancing `i`. A byte that does not start valid UTF-8
/// stands for itself, above every code point, so that it compares equal only to the same byte.
fn nextUpper(s: []const u8, i: *usize) u32 {
    const len = std.unicode.utf8ByteSequenceLength(s[i.*]) catch 0;
    if (len > 0 and i.* + len <= s.len) {
        if (std.unicode.utf8Decode(s[i.* .. i.* + len])) |c| {
            i.* += len;
            return upperRune(c);
        } else |_| {}
    }
    i.* += 1;
    return 0x110000 + @as(u32, s[i.* - 1]);
}

fn orderFold(a: []const u8, b: []const u8) std.math.Order {
    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len and j < b.len) {
        const x = nextUpper(a, &i);
        const y = nextUpper(b, &j);
        if (x != y) return std.math.order(x, y);
    }
    return std.math.order(a.len - i, b.len - j);
}

fn eqlFold(a: []const u8, b: []const u8) bool {
    return orderFold(a, b) == .eq;
}

/// `s` upper-cased, for searching it case-insensitively.
fn upperAlloc(arena: Allocator, s: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = try .initCapacity(arena, s.len);
    var i: usize = 0;
    while (i < s.len) {
        const start = i;
        const c = nextUpper(s, &i);
        if (c >= 0x110000) {
            try out.append(arena, s[start]);
            continue;
        }
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(@intCast(c), &buf) catch unreachable;
        try out.appendSlice(arena, buf[0..n]);
    }
    return out.items;
}

fn looseEquals(a: Value, b: Value) bool {
    if (sameKind(a, b)) return switch (a) {
        .null => true,
        .boolean => |x| x == b.boolean,
        .number => |x| x == b.number,
        .string => |x| eqlFold(x, b.string),
        // Arrays and objects only equal themselves.
        .array => |x| x.ptr == b.array.ptr and x.len == b.array.len,
        .object => |x| x.ptr == b.object.ptr and x.len == b.object.len,
    };
    const x = toNumber(a);
    const y = toNumber(b);
    return x == y; // NaN never equals anything
}

fn compare(a: Value, b: Value) ?std.math.Order {
    if (a == .string and b == .string) return orderFold(a.string, b.string);
    const x = toNumber(a);
    const y = toNumber(b);
    if (std.math.isNan(x) or std.math.isNan(y)) return null;
    return std.math.order(x, y);
}

// --- evaluation ---

fn lookupEntry(entries: []const Value.Entry, name: []const u8) ?Value {
    for (entries) |e| if (std.ascii.eqlIgnoreCase(e.key, name)) return e.value;
    return null;
}

fn deref(v: Value, key: Value, arena: Allocator) Allocator.Error!Value {
    switch (v) {
        .object => |o| {
            const k = try toStr(arena, key);
            return lookupEntry(o, k) orelse .null;
        },
        .array => |a| {
            if (key != .number and key != .string) return .null;
            const n = toNumber(key);
            // Bounded before the conversion, which panics on a number no usize holds (`foo[1e30]`,
            // `foo[Infinity]`) and would take the whole runner down with it.
            const len: f64 = @floatFromInt(a.len);
            if (std.math.isNan(n) or n < 0 or @floor(n) != n or n >= len) return .null;
            return a[@intFromFloat(n)];
        },
        else => return .null,
    }
}

/// What a `*` object filter selects: an array's elements, or an object's values. GitHub gives an
/// array either way, and anything else selects nothing.
fn starValues(arena: Allocator, v: Value) Error![]const Value {
    switch (v) {
        .array => |a| return a,
        .object => |o| {
            const out = try arena.alloc(Value, o.len);
            for (o, 0..) |e, i| out[i] = e.value;
            return out;
        },
        else => return &.{},
    }
}

/// The values selected by `n`, when `n` is a `*` filter or a property reached through one.
///
/// This is what makes `labels.*.name` an array of names while `labels.name` stays null: the filter
/// is recognised from the shape of the expression rather than from the shape of the value, so
/// property access maps over a filtered collection and dereferences anything else. It recurses, so
/// `a.*.b.c` filters at both levels. Indexing needs nothing here — `a.*.b[0]` evaluates the filter
/// to an array and then indexes it like any other.
fn filteredValues(arena: Allocator, n: *const Node, scope: Scope) Error!?[]const Value {
    switch (n.*) {
        .star => |inner| return try starValues(arena, try eval(arena, inner, scope)),
        .prop => |p| {
            const items = (try filteredValues(arena, p.obj, scope)) orelse return null;
            var out: std.ArrayList(Value) = .empty;
            for (items) |it| {
                const got = try deref(it, .{ .string = p.name }, arena);
                // An element without the property contributes nothing, rather than a null: this is
                // what makes `contains(labels.*.name, 'bug')` safe on a mixed array.
                if (got != .null) try out.append(arena, got);
            }
            return out.items;
        },
        else => return null,
    }
}

/// A chain of `&&` (or of `||`), operand by operand from the left, without recursing down it: a
/// chain of any length is depth 2 to GitHub, but `a || b || c` is parsed as `(a || b) || c`.
/// `&&` returns the first falsy operand or the last; `||` the first truthy one or the last.
fn evalChain(arena: Allocator, n: *const Node, scope: Scope) Error!Value {
    const op = n.bin.op;
    var rights: std.ArrayList(*const Node) = .empty;
    var left = n;
    while (left.* == .bin and left.bin.op == op) : (left = left.bin.l)
        try rights.append(arena, left.bin.r);
    var v = try eval(arena, left, scope);
    var i = rights.items.len;
    while (i > 0) {
        if (toBool(v) == (op == .or_)) return v;
        i -= 1;
        v = try eval(arena, rights.items[i], scope);
    }
    return v;
}

fn eval(arena: Allocator, n: *const Node, scope: Scope) Error!Value {
    switch (n.*) {
        .literal => |v| return v,
        .ident => |name| {
            for (scope.unsupported_contexts) |u| if (std.ascii.eqlIgnoreCase(u, name)) {
                if (scope.diag) |d| d.* = std.fmt.allocPrint(
                    arena,
                    "the '{s}' context is not supported yet",
                    .{name},
                ) catch "unsupported context";
                return error.Unsupported;
            };
            return lookupEntry(scope.contexts, name) orelse .null;
        },
        .prop => |p| {
            // `n`, not `p.obj`: `filteredValues` applies this property to the filtered collection,
            // and returns null when the chain is not a filter at all so that ordinary property
            // access still goes through `deref`.
            if (try filteredValues(arena, n, scope)) |items| return .{ .array = items };
            return deref(try eval(arena, p.obj, scope), .{ .string = p.name }, arena);
        },
        .index => |ix| {
            const o = try eval(arena, ix.obj, scope);
            return deref(o, try eval(arena, ix.idx, scope), arena);
        },
        .star => |inner| return .{ .array = try starValues(arena, try eval(arena, inner, scope)) },
        .not => |inner| return .{ .boolean = !toBool(try eval(arena, inner, scope)) },
        .bin => |b| {
            if (b.op == .and_ or b.op == .or_) return evalChain(arena, n, scope);
            const l = try eval(arena, b.l, scope);
            const r = try eval(arena, b.r, scope);
            return .{ .boolean = switch (b.op) {
                .eq => looseEquals(l, r),
                .ne => !looseEquals(l, r),
                .lt => if (compare(l, r)) |o| o == .lt else false,
                .le => if (compare(l, r)) |o| o != .gt else false,
                .gt => if (compare(l, r)) |o| o == .gt else false,
                .ge => if (compare(l, r)) |o| o != .lt else false,
                else => unreachable,
            } };
        },
        .call => |c| return callFunction(arena, c.name, c.args, scope),
    }
}

fn callFunction(arena: Allocator, name: []const u8, arg_nodes: []*Node, scope: Scope) Error!Value {
    const eql = std.ascii.eqlIgnoreCase;
    if (statusFunction(name, scope)) |v| return v;
    if (eql(name, "case")) return callCase(arena, arg_nodes, scope);
    if (eql(name, "hashFiles") and scope.hash_files == null) {
        if (scope.diag) |d| d.* = "hashFiles() is not supported here";
        return error.Unsupported;
    }

    const args = try arena.alloc(Value, arg_nodes.len);
    for (arg_nodes, args) |an, *out| out.* = try eval(arena, an, scope);

    if (eql(name, "hashFiles")) return callHashFiles(arena, args, scope);
    if (eql(name, "contains")) return callContains(arena, args, scope);
    if (eql(name, "startsWith") or eql(name, "endsWith")) {
        if (args.len != 2) return scope.fail("{s}() takes 2 arguments", .{name}, arena);
        const s = try upperAlloc(arena, try toStr(arena, args[0]));
        const t = try upperAlloc(arena, try toStr(arena, args[1]));
        return .{ .boolean = if (eql(name, "startsWith"))
            std.mem.startsWith(u8, s, t)
        else
            std.mem.endsWith(u8, s, t) };
    }
    if (eql(name, "format")) {
        if (args.len < 1) return scope.fail("format() needs a format string", .{}, arena);
        return .{ .string = try formatString(arena, try toStr(arena, args[0]), args[1..], scope) };
    }
    if (eql(name, "join")) return callJoin(arena, args, scope);
    if (eql(name, "toJSON")) return callToJson(arena, args, scope);
    if (eql(name, "fromJSON")) return callFromJson(arena, args, scope);
    return scope.fail("unknown function '{s}'", .{name}, arena);
}

/// `case(pred1, value1, pred2, value2, ..., default)`: the value after the first true predicate,
/// else the default. Only what is needed is evaluated, and a predicate must be a boolean.
fn callCase(arena: Allocator, args: []*Node, scope: Scope) Error!Value {
    var i: usize = 0;
    while (i + 1 < args.len) : (i += 2) {
        switch (try eval(arena, args[i], scope)) {
            .boolean => |b| if (b) return eval(arena, args[i + 1], scope),
            else => return scope.fail("case(): a predicate must be true or false", .{}, arena),
        }
    }
    return eval(arena, args[args.len - 1], scope);
}

/// `success()`, `always()`, `cancelled()`, `failure()`: the job's state, no arguments evaluated.
fn statusFunction(name: []const u8, scope: Scope) ?Value {
    const eql = std.ascii.eqlIgnoreCase;
    if (eql(name, "success")) return .{ .boolean = !scope.job_failed and !scope.cancelled };
    if (eql(name, "always")) return .{ .boolean = true };
    if (eql(name, "cancelled")) return .{ .boolean = scope.cancelled };
    if (eql(name, "failure")) return .{ .boolean = scope.job_failed and !scope.cancelled };
    return null;
}

fn callHashFiles(arena: Allocator, args: []const Value, scope: Scope) Error!Value {
    if (args.len < 1) return scope.fail("hashFiles() takes at least 1 argument", .{}, arena);
    const patterns = try arena.alloc([]const u8, args.len);
    for (args, patterns) |a, *dst| dst.* = try toStr(arena, a);
    const hf = scope.hash_files.?;
    return switch (try hf.hashFn(hf.ptr, arena, patterns)) {
        .ok => |hex| .{ .string = hex },
        .failed => |why| scope.fail(
            "hashFiles({s}) failed: {s}",
            .{ try std.mem.join(arena, ", ", patterns), why },
            arena,
        ),
    };
}

fn callContains(arena: Allocator, args: []const Value, scope: Scope) Error!Value {
    if (args.len != 2) return scope.fail("contains() takes 2 arguments", .{}, arena);
    switch (args[0]) {
        .array => |a| {
            for (a) |e| if (looseEquals(e, args[1])) return .{ .boolean = true };
            return .{ .boolean = false };
        },
        else => {
            const hay = try upperAlloc(arena, try toStr(arena, args[0]));
            const needle = try upperAlloc(arena, try toStr(arena, args[1]));
            return .{ .boolean = std.mem.indexOf(u8, hay, needle) != null };
        },
    }
}

fn callJoin(arena: Allocator, args: []const Value, scope: Scope) Error!Value {
    if (args.len < 1 or args.len > 2)
        return scope.fail("join() takes 1 or 2 arguments", .{}, arena);
    const sep = if (args.len == 2) try toStr(arena, args[1]) else ",";
    switch (args[0]) {
        .array => |a| {
            var out: std.ArrayList(u8) = .empty;
            for (a, 0..) |e, i| {
                const item = try toStr(arena, e);
                try scope.charge(item.len + if (i > 0) sep.len else 0, arena);
                if (i > 0) try out.appendSlice(arena, sep);
                try out.appendSlice(arena, item);
            }
            return .{ .string = out.items };
        },
        else => return .{ .string = try toStr(arena, args[0]) },
    }
}

fn callToJson(arena: Allocator, args: []const Value, scope: Scope) Error!Value {
    if (args.len != 1) return scope.fail("toJSON() takes 1 argument", .{}, arena);
    var aw: std.Io.Writer.Allocating = .init(arena);
    writeJson(&aw.writer, args[0], 0) catch return error.OutOfMemory; // Allocating writer: only OOM
    try scope.charge(aw.written().len, arena);
    return .{ .string = aw.written() };
}

fn callFromJson(arena: Allocator, args: []const Value, scope: Scope) Error!Value {
    if (args.len != 1) return scope.fail("fromJSON() takes 1 argument", .{}, arena);
    const text = try toStr(arena, args[0]);
    try scope.charge(text.len, arena);
    if (jsonNesting(text) > max_json_nesting)
        return scope.fail("fromJSON(): nested more than {d} deep", .{max_json_nesting}, arena);
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch
        return scope.fail("fromJSON(): invalid JSON", .{}, arena);
    return fromJsonValue(arena, parsed);
}

/// The deepest nesting of arrays and objects in JSON text (outside strings), without parsing it.
fn jsonNesting(text: []const u8) usize {
    var depth: usize = 0;
    var deepest: usize = 0;
    var in_string = false;
    var escaped = false;
    for (text) |c| {
        if (in_string) {
            if (escaped) escaped = false else if (c == '\\') escaped = true else if (c == '"') in_string = false;
            continue;
        }
        switch (c) {
            '"' => in_string = true,
            '[', '{' => {
                depth += 1;
                deepest = @max(deepest, depth);
            },
            ']', '}' => depth -|= 1,
            else => {},
        }
    }
    return deepest;
}

fn formatString(
    arena: Allocator,
    fmt: []const u8,
    args: []const Value,
    scope: Scope,
) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < fmt.len) {
        const c = fmt[i];
        if (c == '{') {
            if (i + 1 < fmt.len and fmt[i + 1] == '{') {
                try out.append(arena, '{');
                i += 2;
                continue;
            }
            const close = std.mem.indexOfScalarPos(u8, fmt, i, '}') orelse
                return scope.fail("format(): unterminated '{{' in '{s}'", .{fmt}, arena);
            const placeholder = fmt[i .. close + 1];
            const idx = std.fmt.parseInt(usize, fmt[i + 1 .. close], 10) catch
                return scope.fail("format(): invalid placeholder '{s}'", .{placeholder}, arena);
            if (idx >= args.len)
                return scope.fail("format(): placeholder {{{d}}} has no argument", .{idx}, arena);
            const arg = try toStr(arena, args[idx]);
            try scope.charge(arg.len, arena);
            try out.appendSlice(arena, arg);
            i = close + 1;
        } else if (c == '}') {
            if (i + 1 < fmt.len and fmt[i + 1] == '}') {
                try out.append(arena, '}');
                i += 2;
                continue;
            }
            return scope.fail("format(): unmatched '}}' in '{s}'", .{fmt}, arena);
        } else {
            try out.append(arena, c);
            i += 1;
        }
    }
    return out.items;
}

fn writeJson(w: *std.Io.Writer, v: Value, depth: usize) !void {
    switch (v) {
        .null => try w.writeAll("null"),
        .boolean => |b| try w.writeAll(if (b) "true" else "false"),
        .number => |n| if (@floor(n) == n and @abs(n) < 1e15) try w.print(
            "{d}",
            .{@as(i64, @intFromFloat(n))},
        ) else try w.print("{d}", .{n}),
        .string => |s| try std.json.Stringify.value(s, .{}, w),
        .array => |a| {
            if (a.len == 0) return w.writeAll("[]");
            try w.writeAll("[\n");
            for (a, 0..) |e, i| {
                try w.splatByteAll(' ', (depth + 1) * 2);
                try writeJson(w, e, depth + 1);
                try w.writeAll(if (i + 1 < a.len) ",\n" else "\n");
            }
            try w.splatByteAll(' ', depth * 2);
            try w.writeByte(']');
        },
        .object => |o| {
            if (o.len == 0) return w.writeAll("{}");
            try w.writeAll("{\n");
            for (o, 0..) |e, i| {
                try w.splatByteAll(' ', (depth + 1) * 2);
                try std.json.Stringify.value(e.key, .{}, w);
                try w.writeAll(": ");
                try writeJson(w, e.value, depth + 1);
                try w.writeAll(if (i + 1 < o.len) ",\n" else "\n");
            }
            try w.splatByteAll(' ', depth * 2);
            try w.writeByte('}');
        },
    }
}

pub fn fromJsonValue(arena: Allocator, j: std.json.Value) Allocator.Error!Value {
    switch (j) {
        .null => return .null,
        .bool => |b| return .{ .boolean = b },
        .integer => |i| return .{ .number = @floatFromInt(i) },
        .float => |f| return .{ .number = f },
        .number_string => |s| return .{ .number = std.fmt.parseFloat(f64, s) catch
            std.math.nan(f64) },
        .string => |s| return .{ .string = s },
        .array => |a| {
            const out = try arena.alloc(Value, a.items.len);
            for (a.items, out) |e, *o| o.* = try fromJsonValue(arena, e);
            return .{ .array = out };
        },
        .object => |o| {
            const out = try arena.alloc(Value.Entry, o.count());
            var it = o.iterator();
            var i: usize = 0;
            while (it.next()) |e| : (i += 1) out[i] = .{
                .key = e.key_ptr.*,
                .value = try fromJsonValue(arena, e.value_ptr.*),
            };
            return .{ .object = out };
        },
    }
}

// --- public API ---

/// Evaluates one expression (the text inside `${{ }}`).
pub fn evaluate(arena: Allocator, text: []const u8, scope: Scope) Error!Value {
    const n = try parse(arena, text, scope.diag);
    var used: usize = 0;
    var s = scope;
    if (s.memory == null) s.memory = &used;
    return eval(arena, n, s) catch |e| switch (e) {
        error.Unsupported => {
            if (scope.diag) |d| if (d.*.len == 0) {
                d.* = "the '*' object filter is not supported yet";
            };
            return e;
        },
        else => return e,
    };
}

pub fn evalString(arena: Allocator, text: []const u8, scope: Scope) Error![]const u8 {
    return toStr(arena, try evaluate(arena, text, scope));
}

/// Replaces every `${{ <expression> }}` in `text` with its value as a string. The job message
/// arrives with this already done (as `format()` expressions), but `action.yml` files are read as
/// they are written. A `}}` inside a quoted string does not end the expression.
pub fn interpolate(arena: Allocator, text: []const u8, scope: Scope) Error![]const u8 {
    if (std.mem.indexOf(u8, text, "${{") == null) return text;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, text, i, "${{")) |open| {
        try out.appendSlice(arena, text[i..open]);
        const body_start = open + 3;
        const close = expressionEnd(text, body_start) orelse {
            if (scope.diag) |d| d.* = "'${{' is never closed with '}}'";
            return error.ParseError;
        };
        try out.appendSlice(arena, try evalString(arena, text[body_start..close], scope));
        i = close + 2;
    }
    try out.appendSlice(arena, text[i..]);
    return out.items;
}

/// Index of the `}}` that ends the expression starting at `from`, skipping 'quoted' strings.
fn expressionEnd(text: []const u8, from: usize) ?usize {
    var i = from;
    var in_str = false;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (in_str) {
            if (c == '\'') {
                if (i + 1 < text.len and text[i + 1] == '\'') i += 1 else in_str = false;
            }
        } else if (c == '\'') {
            in_str = true;
        } else if (c == '}' and i + 1 < text.len and text[i + 1] == '}') {
            return i;
        }
    }
    return null;
}

/// Whether an `if:` expression calls success(), always(), failure() or cancelled().
pub fn hasStatusFunction(arena: Allocator, text: []const u8) bool {
    const n = parse(arena, text, null) catch return false;
    return nodeHasStatus(n);
}

fn nodeHasStatus(n: *const Node) bool {
    return switch (n.*) {
        .call => |c| blk: {
            for ([_][]const u8{ "success", "always", "failure", "cancelled" }) |f|
                if (std.ascii.eqlIgnoreCase(c.name, f)) break :blk true;
            for (c.args) |a| if (nodeHasStatus(a)) break :blk true;
            break :blk false;
        },
        .not => |i| nodeHasStatus(i),
        .bin => |b| nodeHasStatus(b.l) or nodeHasStatus(b.r),
        .prop => |p| nodeHasStatus(p.obj),
        .index => |ix| nodeHasStatus(ix.obj) or nodeHasStatus(ix.idx),
        .star => |i| nodeHasStatus(i),
        else => false,
    };
}

/// Evaluates an `if:` condition. A condition without a status function is implicitly
/// `success() && (<condition>)`, as in GitHub. `${{ }}` around the whole condition is optional.
pub fn evalCondition(arena: Allocator, cond: []const u8, scope: Scope) Error!bool {
    var text = std.mem.trim(u8, cond, " \t\r\n");
    if (std.mem.startsWith(u8, text, "${{") and std.mem.endsWith(u8, text, "}}"))
        text = std.mem.trim(u8, text[3 .. text.len - 2], " \t\r\n");
    if (text.len == 0) return !scope.job_failed and !scope.cancelled;
    const v = try evaluate(arena, text, scope);
    if (!hasStatusFunction(arena, text) and (scope.job_failed or scope.cancelled)) return false;
    return toBool(v);
}

// --- tests ---

fn tctx(entries: []const Value.Entry) Scope {
    return .{ .contexts = entries };
}

fn evalStr(arena: Allocator, text: []const u8, scope: Scope) ![]const u8 {
    return evalString(arena, text, scope);
}

test "literals and coercion" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const s: Scope = .{};
    try std.testing.expectEqualStrings("hello", try evalStr(a.allocator(), "'hello'", s));
    try std.testing.expectEqualStrings("it's", try evalStr(a.allocator(), "'it''s'", s));
    try std.testing.expectEqualStrings("42", try evalStr(a.allocator(), "42", s));
    try std.testing.expectEqualStrings("-3.5", try evalStr(a.allocator(), "-3.5", s));
    try std.testing.expectEqualStrings("255", try evalStr(a.allocator(), "0xff", s));
    try std.testing.expectEqualStrings("true", try evalStr(a.allocator(), "TRUE", s));
    try std.testing.expectEqualStrings("", try evalStr(a.allocator(), "null", s));
}

test "operators follow GitHub's loose comparison" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    const s: Scope = .{};
    try std.testing.expect(try evalCondition(ar, "'ABC' == 'abc'", s)); // case-insensitive
    try std.testing.expect(try evalCondition(ar, "1 == '1'", s)); // string -> number
    try std.testing.expect(try evalCondition(ar, "null == 0", s));
    try std.testing.expect(try evalCondition(ar, "true == 1", s));
    try std.testing.expect(!(try evalCondition(ar, "'a' == 'b'", s)));
    try std.testing.expect(try evalCondition(ar, "'a' != 'b'", s));
    try std.testing.expect(try evalCondition(ar, "2 > 1 && 1 >= 1 && 1 < 2 && 2 <= 2", s));
    try std.testing.expect(try evalCondition(ar, "'b' > 'A'", s));
    try std.testing.expect(!(try evalCondition(ar, "NaN == NaN", s)));
    try std.testing.expect(!(try evalCondition(ar, "'x' > 1", s))); // NaN comparison is false
    try std.testing.expect(try evalCondition(ar, "!false", s));
    try std.testing.expect(try evalCondition(ar, "!(1 == 2)", s));
}

test "&& and || return operands" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    const s: Scope = .{};
    try std.testing.expectEqualStrings("fallback", try evalStr(ar, "'' || 'fallback'", s));
    try std.testing.expectEqualStrings("first", try evalStr(ar, "'first' || 'second'", s));
    try std.testing.expectEqualStrings("second", try evalStr(ar, "'first' && 'second'", s));
    try std.testing.expectEqualStrings("0", try evalStr(ar, "0 && 'x'", s));
    try std.testing.expectEqualStrings("", try evalStr(ar, "null || null", s));
    // short-circuit: the right side would be an error
    try std.testing.expectEqualStrings("ok", try evalStr(ar, "'ok' || fromJSON('{')", s));
}

test "contexts, properties and indexing" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    const matrix = [_]Value.Entry{ .{ .key = "os", .value = .{ .string = "linux" } }, .{ .key = "node", .value = .{ .number = 20 } } };
    const list = [_]Value{ .{ .string = "a" }, .{ .string = "b" } };
    const gh = [_]Value.Entry{ .{ .key = "Repository", .value = .{ .string = "o/r" } }, .{ .key = "list", .value = .{ .array = &list } } };
    const ctxs = [_]Value.Entry{ .{ .key = "github", .value = .{ .object = &gh } }, .{ .key = "matrix", .value = .{ .object = &matrix } } };
    const s = tctx(&ctxs);
    try std.testing.expectEqualStrings("o/r", try evalStr(ar, "github.repository", s)); // case-insensitive
    try std.testing.expectEqualStrings("o/r", try evalStr(ar, "GITHUB['REPOSITORY']", s));
    try std.testing.expectEqualStrings("linux", try evalStr(ar, "matrix.os", s));
    try std.testing.expectEqualStrings("20", try evalStr(ar, "matrix['node']", s));
    try std.testing.expectEqualStrings("b", try evalStr(ar, "github.list[1]", s));
    try std.testing.expectEqualStrings("", try evalStr(ar, "github.list[5]", s));
    // Numbers no index can be: once a panic that stopped the runner.
    try std.testing.expectEqualStrings("", try evalStr(ar, "github.list[1e30]", s));
    try std.testing.expectEqualStrings("", try evalStr(ar, "github.list[Infinity]", s));
    try std.testing.expectEqualStrings("", try evalStr(ar, "github.missing.deeper.still", s)); // null propagates
    try std.testing.expectEqualStrings("", try evalStr(ar, "nosuchcontext.x", s));
    try std.testing.expect(try evalCondition(ar, "github.repository == 'O/R' && matrix.os == 'linux'", s));
}

test "the * object filter selects from arrays and objects, and maps through properties" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const ar = a.allocator();

    // Two labels with a name, one without: GitHub's canonical case is
    // `contains(github.event.issue.labels.*.name, 'bug')`.
    const bug = [_]Value.Entry{ .{ .key = "name", .value = .str("bug") }, .{ .key = "color", .value = .str("red") } };
    const docs = [_]Value.Entry{.{ .key = "name", .value = .str("docs") }};
    const nameless = [_]Value.Entry{.{ .key = "color", .value = .str("blue") }};
    const labels = [_]Value{ .{ .object = &bug }, .{ .object = &docs }, .{ .object = &nameless } };

    // An object to filter the values of, and a nested one to filter through twice.
    const inner = [_]Value.Entry{.{ .key = "id", .value = .{ .number = 7 } }};
    const services = [_]Value.Entry{
        .{ .key = "postgres", .value = .{ .object = &inner } },
        .{ .key = "redis", .value = .{ .object = &inner } },
    };

    const ctxs = [_]Value.Entry{
        .{ .key = "labels", .value = .{ .array = &labels } },
        .{ .key = "services", .value = .{ .object = &services } },
        .{ .key = "plain", .value = .str("text") },
    };
    const s = tctx(&ctxs);

    // Over an array of objects, and usable by `contains`, which is the point of the feature.
    try std.testing.expectEqualStrings("bug docs", try evalStr(ar, "join(labels.*.name, ' ')", s));
    try std.testing.expect(try evalCondition(ar, "contains(labels.*.name, 'bug')", s));
    try std.testing.expect(!(try evalCondition(ar, "contains(labels.*.name, 'nope')", s)));
    // An element without the property contributes nothing: three labels, two names.
    try std.testing.expectEqualStrings("[\n  \"bug\",\n  \"docs\"\n]", try evalStr(ar, "toJSON(labels.*.name)", s));

    // Over an object, `*` selects its values — `job.services.*.id` is GitHub's example.
    try std.testing.expectEqualStrings("7 7", try evalStr(ar, "join(services.*.id, ' ')", s));

    // The filter is recognised from the expression's shape, not the value's: a property of a plain
    // array is still null, which is what it is on GitHub.
    try std.testing.expectEqualStrings("", try evalStr(ar, "labels.name", s));
    // Indexing a filtered result indexes the array it produced.
    try std.testing.expectEqualStrings("docs", try evalStr(ar, "labels.*.name[1]", s));
    // Filtering something that is neither an array nor an object selects nothing.
    try std.testing.expectEqualStrings("[]", try evalStr(ar, "toJSON(plain.*.anything)", s));
    try std.testing.expectEqualStrings("[]", try evalStr(ar, "toJSON(plain.*)", s));
    try std.testing.expectEqualStrings("[]", try evalStr(ar, "toJSON(nosuchcontext.*.x)", s));
}

test "functions" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    const list = [_]Value{ .{ .string = "x" }, .{ .number = 2 }, .{ .boolean = true } };
    const ctxs = [_]Value.Entry{.{ .key = "items", .value = .{ .array = &list } }};
    const s = tctx(&ctxs);
    try std.testing.expect(try evalCondition(ar, "contains('Hello World', 'WORLD')", s));
    try std.testing.expect(!(try evalCondition(ar, "contains('abc', 'z')", s)));
    try std.testing.expect(try evalCondition(ar, "contains(items, 'X')", s));
    try std.testing.expect(try evalCondition(ar, "contains(items, 2)", s));
    try std.testing.expect(try evalCondition(ar, "startsWith('refs/heads/main', 'refs/heads/')", s));
    try std.testing.expect(try evalCondition(ar, "endsWith('file.TXT', '.txt')", s));
    try std.testing.expectEqualStrings("Hello Ada, you are 7", try evalStr(ar, "format('Hello {0}, you are {1}', 'Ada', 7)", s));
    try std.testing.expectEqualStrings("{literal} 1", try evalStr(ar, "format('{{literal}} {0}', 1)", s));
    try std.testing.expectEqualStrings("x,2,true", try evalStr(ar, "join(items)", s));
    try std.testing.expectEqualStrings("x-2-true", try evalStr(ar, "join(items, '-')", s));
    try std.testing.expectEqualStrings("plain", try evalStr(ar, "join('plain', ',')", s));
    try std.testing.expectEqualStrings("[\n  \"x\",\n  2,\n  true\n]", try evalStr(ar, "toJSON(items)", s));
    try std.testing.expectEqualStrings("7", try evalStr(ar, "fromJSON('{\"n\": 7}').n", s));
    try std.testing.expectEqualStrings("b", try evalStr(ar, "fromJSON('[\"a\",\"b\"]')[1]", s));
    try std.testing.expect(try evalCondition(ar, "fromJSON('true')", s));
}

test "status functions and the implicit success()" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    const ok: Scope = .{};
    const failed: Scope = .{ .job_failed = true };
    try std.testing.expect(try evalCondition(ar, "success()", ok));
    try std.testing.expect(!(try evalCondition(ar, "success()", failed)));
    try std.testing.expect(try evalCondition(ar, "failure()", failed));
    try std.testing.expect(!(try evalCondition(ar, "failure()", ok)));
    try std.testing.expect(try evalCondition(ar, "always()", failed));
    try std.testing.expect(!(try evalCondition(ar, "cancelled()", ok)));
    // No status function: implicitly success() && (...)
    try std.testing.expect(try evalCondition(ar, "1 == 1", ok));
    try std.testing.expect(!(try evalCondition(ar, "1 == 1", failed)));
    try std.testing.expect(try evalCondition(ar, "always() && 1 == 1", failed));
    try std.testing.expect(try evalCondition(ar, "failure() && 1 == 1", failed));
    // empty condition and ${{ }} wrapper
    try std.testing.expect(try evalCondition(ar, "", ok));
    try std.testing.expect(try evalCondition(ar, "${{ 1 == 1 }}", ok));
    try std.testing.expect(hasStatusFunction(ar, "github.ref == 'x' && !cancelled()"));
    try std.testing.expect(!hasStatusFunction(ar, "github.ref == 'x'"));
}

test "errors say what is wrong" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    var diag: []const u8 = "";
    const s: Scope = .{ .diag = &diag };
    try std.testing.expectError(error.ParseError, evaluate(ar, "1 +", s));
    try std.testing.expectError(error.ParseError, evaluate(ar, "'unterminated", s));
    try std.testing.expectError(error.ParseError, evaluate(ar, "(1 == 1", s));
    try std.testing.expect(std.mem.indexOf(u8, diag, "(1 == 1") != null);
    // As GitHub: when parsing, so even where it would never be called.
    try std.testing.expectError(error.ParseError, evaluate(ar, "false && nosuch('x')", s));
    try std.testing.expect(std.mem.startsWith(u8, diag, "unknown function 'nosuch'"));
    try std.testing.expectError(error.ParseError, evaluate(ar, "join()", s));
    try std.testing.expectError(error.ParseError, evaluate(ar, "case(true, 1)", s));
    try std.testing.expectError(error.EvalError, evaluate(ar, "format('{3}', 'a')", s));
    try std.testing.expectError(error.Unsupported, evaluate(ar, "hashFiles('**/*.zig')", s));
    try std.testing.expectEqualStrings("hashFiles() is not supported here", diag);
    // `github.*.x` used to be refused here. It is supported now: filtering a context that has no
    // `x` selects nothing, which is an empty array rather than an error.
    try std.testing.expectEqualStrings("[]", try evalStr(ar, "toJSON(github.*.x)", s));
}

test "hashFiles calls the scope's hook with its patterns" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    const Fake = struct {
        fn hash(ptr: *anyopaque, arena: Allocator, patterns: []const []const u8) Allocator.Error!HashFiles.Result {
            _ = ptr;
            if (std.mem.eql(u8, patterns[0], "bad")) return .{ .failed = "no" };
            return .{ .ok = try std.mem.join(arena, "|", patterns) };
        }
    };
    var dummy: u8 = 0;
    var diag: []const u8 = "";
    const s: Scope = .{ .diag = &diag, .hash_files = .{ .ptr = &dummy, .hashFn = Fake.hash } };
    try std.testing.expectEqualStrings("**/go.sum|!x/**", (try evaluate(ar, "hashFiles('**/go.sum', '!x/**')", s)).string);
    try std.testing.expectError(error.EvalError, evaluate(ar, "hashFiles('bad')", s));
    try std.testing.expectEqualStrings("hashFiles(bad) failed: no", diag);
    try std.testing.expectError(error.ParseError, evaluate(ar, "hashFiles()", s));
}

test "case() picks the value after the first true predicate, evaluating only what it needs" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    const s: Scope = .{};
    try std.testing.expectEqualStrings("b", try evalStr(ar, "case(false, 'a', 1 == 1, 'b', 'c')", s));
    try std.testing.expectEqualStrings("c", try evalStr(ar, "case(false, 'a', false, 'b', 'c')", s));
    // The rest is never evaluated: fromJSON('{') would be an error.
    try std.testing.expectEqualStrings("a", try evalStr(ar, "case(true, 'a', fromJSON('{'), 'b', 'c')", s));
    try std.testing.expectError(error.EvalError, evaluate(ar, "case(1, 'a', 'b')", s));
}

test "unsupported contexts fail loudly" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    var diag: []const u8 = "";
    const s: Scope = .{ .unsupported_contexts = &.{"secrets"}, .diag = &diag };
    try std.testing.expectError(error.Unsupported, evaluate(a.allocator(), "secrets.TOKEN", s));
    try std.testing.expectEqualStrings("the 'secrets' context is not supported yet", diag);
    try std.testing.expectError(error.Unsupported, evaluate(a.allocator(), "format('{0}', SECRETS['x'])", s));
}

test "numbers print like GitHub" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    const s: Scope = .{};
    try std.testing.expectError(error.ParseError, evalStr(ar, "1 + 2", s)); // '+' is not an operator
    try std.testing.expectEqualStrings("1.5", try evalStr(ar, "1.5", s));
    try std.testing.expectEqualStrings("100", try evalStr(ar, "1e2", s));
    try std.testing.expectEqualStrings("NaN", try evalStr(ar, "NaN", s));
}

test "interpolate replaces each ${{ }} and leaves the rest alone" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    const inputs = [_]Value.Entry{ .{ .key = "version", .value = .{ .string = "0.21.10" } }, .{ .key = "args", .value = .{ .string = "ci --skip-links\nx" } } };
    const ctxs = [_]Value.Entry{.{ .key = "inputs", .value = .{ .object = &inputs } }};
    var diag: []const u8 = "";
    const s: Scope = .{ .contexts = &ctxs, .diag = &diag };
    try std.testing.expectEqualStrings("plain $HOME {{ x }}", try interpolate(ar, "plain $HOME {{ x }}", s));
    try std.testing.expectEqualStrings("VERSION=0.21.10 and 0.21.10!", try interpolate(ar, "VERSION=${{ inputs.version }} and ${{inputs.VERSION}}!", s));
    // toJSON as dagger-for-github uses it, and a '}}' inside a string literal
    try std.testing.expectEqualStrings("echo '\"ci --skip-links\\nx\"'", try interpolate(ar, "echo '${{ toJSON(inputs.args) }}'", s));
    // The '}}' inside the string does not end the expression (format() then reads it as an escaped '}').
    try std.testing.expectEqualStrings("a}b", try interpolate(ar, "${{ format('{0}}}{1}', 'a', 'b') }}", s));
    try std.testing.expectEqualStrings("it's", try interpolate(ar, "${{ 'it''s' }}", s));
    try std.testing.expectError(error.ParseError, interpolate(ar, "x ${{ inputs.version", s));
    try std.testing.expectEqualStrings("'${{' is never closed with '}}'", diag);
}

/// `parts` joined, each `{ text, times }` repeated `times` times.
fn repeated(arena: Allocator, parts: []const struct { []const u8, usize }) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (parts) |p| for (0..p[1]) |_| try out.appendSlice(arena, p[0]);
    return out.items;
}

test "nesting deeper than GitHub's 50 is refused, however it is written, and never overflows" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    const s: Scope = .{};
    // GitHub's own cases: 49 `!` evaluate, 50 do not (the literal is a level too).
    try std.testing.expectEqualStrings("true", try evalStr(ar, try repeated(ar, &.{ .{ "!", 49 }, .{ "false", 1 } }), s));
    try std.testing.expectError(error.ParseError, evaluate(ar, try repeated(ar, &.{ .{ "!", 50 }, .{ "false", 1 } }), s));
    try std.testing.expectError(error.ParseError, evaluate(ar, try repeated(ar, &.{ .{ "(", 60 }, .{ "1", 1 }, .{ ")", 60 } }), s));
    try std.testing.expectError(error.ParseError, evaluate(ar, try repeated(ar, &.{ .{ "x", 1 }, .{ ".a", 50 } }), s));
    // Far past the limit: refused, not a stack overflow (this took the runner down).
    try std.testing.expectError(error.ParseError, evaluate(ar, try repeated(ar, &.{.{ "!", 100_000 }}), s));
}

test "a long chain of && or || is one node to GitHub, and evaluates without recursing" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    const s: Scope = .{};
    var text: std.ArrayList(u8) = .empty;
    for (1..20_001) |i| try text.print(ar, "{s}{d}", .{ if (i > 1) " && " else "", i });
    try std.testing.expectEqualStrings("20000", try evalStr(ar, text.items, s));
    text.clearRetainingCapacity();
    for (0..20_000) |i| try text.print(ar, "{s}{d}", .{ if (i > 0) " || " else "", i });
    try std.testing.expectEqualStrings("1", try evalStr(ar, text.items, s));
    try std.testing.expectEqualStrings("0", try evalStr(ar, "1 && 0 && x.y", s));
    try std.testing.expectEqualStrings("2", try evalStr(ar, "1 && 2 || 3 && 4", s));
}

test "string building has a memory limit, and fromJSON a nesting limit" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    const s: Scope = .{};
    const f = "format('{0}{0}{0}{0}{0}{0}{0}{0}{0}{0}{0}{0}{0}{0}{0}{0}', ";
    // 16^6 = 16 Mi characters: refused once past the limit, without building them all.
    const huge = try repeated(ar, &.{ .{ f, 6 }, .{ "'x'", 1 }, .{ ")", 6 } });
    try std.testing.expectError(error.EvalError, evaluate(ar, huge, s));
    const fine = try repeated(ar, &.{ .{ f, 3 }, .{ "'x'", 1 }, .{ ")", 3 } });
    try std.testing.expectEqual(@as(usize, 16 * 16 * 16), (try evalStr(ar, fine, s)).len);
    const deep = try repeated(ar, &.{ .{ "fromJSON('", 1 }, .{ "[", 1001 }, .{ "]", 1001 }, .{ "')", 1 } });
    try std.testing.expectError(error.EvalError, evaluate(ar, deep, s));
    // Brackets inside strings do not count.
    try std.testing.expectEqualStrings("]]]]", try evalStr(ar, "fromJSON('[[\"]]]]\"]]')[0][0]", s));
}

test "numbers are read as JavaScript's Number() reads them, as GitHub does" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    const s: Scope = .{};
    for ([_][2][]const u8{
        .{ ".5", "0.5" },                               .{ "-.5", "-0.5" },            .{ "+1", "1" },
        .{ "0o17", "15" },                              .{ "0b101", "5" },             .{ "0xfF", "255" },
        .{ "1E+2", "100" },                             .{ "-Infinity", "-Infinity" }, .{ "-0", "0" },
        .{ "0.84551240822557006", "0.84551240822557" },
    }) |c| try std.testing.expectEqualStrings(c[1], try evalStr(ar, c[0], s));
    // Hex takes no sign; a point after a value is a property access.
    try std.testing.expectError(error.ParseError, evaluate(ar, "-0xFF", s));
    try std.testing.expectError(error.ParseError, evaluate(ar, "1_000", s));
    try std.testing.expectEqualStrings("true", try evalStr(ar, "' 0o10 ' == 8", s));
    try std.testing.expectEqualStrings("false", try evalStr(ar, "'inf' == Infinity", s));
    try std.testing.expectEqualStrings("false", try evalStr(ar, "!!NaN", s));
    try std.testing.expect(std.math.isNan(jsNumber("1_000")));
    try std.testing.expect(std.math.isNan(jsNumber("nan")));
    try std.testing.expectEqual(@as(f64, 0), jsNumber("  "));
}

test "strings compare as their upper-case forms, beyond ASCII, as GitHub compares them" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    const s: Scope = .{};
    for ([_][]const u8{
        "'ü' == 'Ü'",
        "'ς' == 'Σ' && 'σ' == 'Σ'",
        "'a' < '[' && 'A' < '['", // 'A' (65) is before '[' (91); 'a' (97) is not
        "startsWith('Привет, мир', 'ПРИВЕТ')",
        "endsWith('façade', 'ÇADE')",
        "contains('Grüße', 'RÜ')",
        "'ı' != 'I' && 'İ' != 'i'",
        "'\xff' == '\xff' && '\xff' != '\xfe'", // not UTF-8: compared as bytes
    }) |e| try std.testing.expectEqualStrings("true", try evalStr(ar, e, s));
}
