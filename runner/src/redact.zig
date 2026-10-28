//! Secret redaction for anything written to logs or stderr (SPEC §9).
const std = @import("std");

pub const mask = "***";

/// Writes `text` to `w` with every occurrence of any secret replaced by `***`.
pub fn write(
    w: *std.Io.Writer,
    text: []const u8,
    secrets: []const []const u8,
) std.Io.Writer.Error!void {
    var i: usize = 0;
    outer: while (i < text.len) {
        for (secrets) |s| {
            if (s.len > 0 and std.mem.startsWith(u8, text[i..], s)) {
                try w.writeAll(mask);
                i += s.len;
                continue :outer;
            }
        }
        try w.writeByte(text[i]);
        i += 1;
    }
}

/// `text` with every secret replaced by `***`, as a new string (`text` itself when nothing matched).
pub fn alloc(arena: std.mem.Allocator, text: []const u8, secrets: []const []const u8) std.mem.Allocator.Error![]const u8 {
    var found = false;
    for (secrets) |s| {
        if (s.len > 0 and std.mem.indexOf(u8, text, s) != null) {
            found = true;
            break;
        }
    }
    if (!found) return text;
    var aw: std.Io.Writer.Allocating = .init(arena);
    write(&aw.writer, text, secrets) catch return error.OutOfMemory; // Allocating: only OOM
    return aw.written();
}

/// The shortest line of a multi-line secret masked on its own. A JSON key file's `{` and `}` lines
/// would otherwise mask every brace of every log; the whole value and its longer lines still are.
pub const min_line = 4;

/// What one secret must be masked as, wherever it appears: its value without the whitespace around
/// it (a token saved with a trailing newline still matches), each line of a multi-line value (the
/// log is redacted line by line, so a whole multi-line value never matches there), and the whole
/// value as JSON (`toJSON(secrets)`), base64 and URL encoding write it.
pub fn forms(arena: std.mem.Allocator, value: []const u8) std.mem.Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    const whole = std.mem.trim(u8, value, " \t\r\n");
    if (whole.len == 0) return out.items;
    try out.append(arena, whole);
    if (std.mem.indexOfScalar(u8, whole, '\n') != null) {
        var lines = std.mem.splitScalar(u8, whole, '\n');
        while (lines.next()) |l| {
            const line = std.mem.trim(u8, l, " \t\r");
            if (line.len >= min_line) try out.append(arena, line);
        }
    }
    // As a JSON string's contents.
    var json: std.Io.Writer.Allocating = .init(arena);
    std.json.Stringify.encodeJsonStringChars(whole, .{}, &json.writer) catch return error.OutOfMemory;
    if (!std.mem.eql(u8, json.written(), whole)) try out.append(arena, json.written());
    // Base64, without padding, so it also matches inside a longer encoded text that starts with it.
    const enc = std.base64.standard_no_pad.Encoder;
    const b64 = try arena.alloc(u8, enc.calcSize(whole.len));
    try out.append(arena, enc.encode(b64, whole));
    // URL-encoded (every byte outside the unreserved set), when that differs.
    var url: std.ArrayList(u8) = .empty;
    for (whole) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '.' or ch == '_' or ch == '~')
            try url.append(arena, ch)
        else
            try url.print(arena, "%{X:0>2}", .{ch});
    }
    if (!std.mem.eql(u8, url.items, whole)) try out.append(arena, url.items);
    return out.items;
}

/// `secrets`, each in all its `forms`, longest first: `write` takes the first match, so a secret
/// that begins with another is then masked whole (`abc` and `abcdef` would give `***def`).
pub fn expand(arena: std.mem.Allocator, secrets: []const []const u8) std.mem.Allocator.Error![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (secrets) |s| try out.appendSlice(arena, try forms(arena, s));
    sortLongestFirst(out.items);
    return out.items;
}

pub fn sortLongestFirst(list: [][]const u8) void {
    std.mem.sort([]const u8, list, {}, struct {
        fn longer(_: void, a: []const u8, b: []const u8) bool {
            return a.len > b.len;
        }
    }.longer);
}

test "a secret is masked in every form it takes: trimmed, line by line, JSON, base64, URL" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const ar = a.allocator();
    // A PEM key saved with a trailing newline, as `gh secret set < file` stores it.
    const pem = "-----BEGIN KEY-----\nMIIEabcdefgh\n}\n-----END KEY-----\n";
    const list = try expand(ar, &.{ pem, "abc", "abcdef" });
    // The log is redacted line by line: each line of the key is masked, the short `}` is not.
    try std.testing.expectEqualStrings("***", try alloc(ar, "MIIEabcdefgh", list));
    try std.testing.expectEqualStrings("***", try alloc(ar, "-----BEGIN KEY-----", list));
    try std.testing.expectEqualStrings("x } y", try alloc(ar, "x } y", list));
    // Longest first: `abcdef` is masked whole, not as `***def`.
    try std.testing.expectEqualStrings("*** ***", try alloc(ar, "abcdef abc", list));
    // As toJSON, base64 and a URL write it.
    try std.testing.expectEqualStrings("{\"k\":\"***\\n\"}", try alloc(ar, "{\"k\":\"-----BEGIN KEY-----\\nMIIEabcdefgh\\n}\\n-----END KEY-----\\n\"}", list));
    try std.testing.expectEqualStrings("auth ***", try alloc(ar, "auth YWJjZGVm", list));
    const spaced = try expand(ar, &.{"p@ss word"});
    try std.testing.expectEqualStrings("u=***", try alloc(ar, "u=p%40ss%20word", spaced));
}

test "redacts all occurrences" {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try write(&w, "tok=abc123 url=pg://abc123@h", &.{ "abc123", "" });
    try std.testing.expectEqualStrings("tok=*** url=pg://***@h", w.buffered());
}
