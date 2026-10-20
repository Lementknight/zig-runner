//! JIT runner registration: `generate-jitconfig` call and `encoded_jit_config` decoding (SPEC §3).
const std = @import("std");
const Config = @import("../config.zig").Config;
const Scope = @import("../config.zig").Scope;
const broker = @import("broker.zig");

const Allocator = std.mem.Allocator;

pub const File = struct {
    name: []const u8,
    content: []const u8,
};

pub const Jit = struct {
    runner_id: u64,
    runner_name: []const u8,
    /// Decoded files (runner settings, RSA credentials, OAuth credential data). Sensitive.
    files: []const File,
};

pub const Error = error{
    /// Non-2xx from GitHub. Maps to exit code 2.
    GithubRejected,
    BadResponse,
} || Allocator.Error || std.http.Client.FetchError;

fn runnersUrl(arena: Allocator, cfg: *const Config) Allocator.Error![]const u8 {
    return switch (cfg.scope) {
        .repo => |r| std.fmt.allocPrint(
            arena,
            "https://api.github.com/repos/{s}/{s}/actions/runners",
            .{ r.owner, r.name },
        ),
        .org => |o| std.fmt.allocPrint(
            arena,
            "https://api.github.com/orgs/{s}/actions/runners",
            .{o},
        ),
    };
}

/// Removes a registered runner (cleanup for runners that never ran a job). Goes through
/// `broker.request`: GitHub answers 204 with no Content-Length, and `std.http.Client.fetch` then
/// waits on the idle connection until GitHub closes it, which kept the runner from exiting for
/// minutes after its job.
pub fn deleteRunner(
    arena: Allocator,
    io: std.Io,
    cfg: *const Config,
    runner_id: u64,
) !std.http.Status {
    const url = try std.fmt.allocPrint(
        arena,
        "{s}/{d}",
        .{ try runnersUrl(arena, cfg), runner_id },
    );
    const r = try broker.request(arena, io, .DELETE, url, null, .{
        .token = cfg.gh_token,
        .extra_headers = &.{.{ .name = "X-GitHub-Api-Version", .value = "2022-11-28" }},
    });
    return r.status;
}

/// Request a JIT config for `name`. All returned memory is allocated from `arena`.
/// `status_out` receives the HTTP status, and `message_out` GitHub's reason when it refuses
/// ("Resource not accessible by personal access token"), for diagnostics.
pub fn generate(
    arena: Allocator,
    io: std.Io,
    cfg: *const Config,
    name: []const u8,
    status_out: *std.http.Status,
    message_out: *[]const u8,
) Error!Jit {
    const url = try std.fmt.allocPrint(
        arena,
        "{s}/generate-jitconfig",
        .{try runnersUrl(arena, cfg)},
    );

    var labels: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, cfg.labels, ',');
    while (it.next()) |l| try labels.append(arena, std.mem.trim(u8, l, " "));

    var body: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(.{
        .name = name,
        .runner_group_id = cfg.runner_group_id,
        .labels = labels.items,
    }, .{}, &body.writer);

    const auth = try std.fmt.allocPrint(arena, "Bearer {s}", .{cfg.gh_token});

    var local: std.http.Client = .{ .allocator = arena, .io = io };
    defer local.deinit();
    const client = @import("http.zig").client(&local);

    var resp: std.Io.Writer.Allocating = .init(arena);
    const result = try @import("http.zig").fetch(client, .{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body.written(),
        .headers = .{
            .authorization = .{ .override = auth },
            .content_type = .{ .override = "application/json" },
        },
        .extra_headers = &.{
            .{ .name = "Accept", .value = "application/vnd.github+json" },
            .{ .name = "X-GitHub-Api-Version", .value = "2022-11-28" },
        },
        .response_writer = &resp.writer,
    });
    status_out.* = result.status;
    if (result.status.class() != .success) {
        message_out.* = errorMessage(arena, resp.written());
        return error.GithubRejected;
    }

    return parseResponse(arena, resp.written());
}

/// The `message` of a GitHub API error body; "" when there is none.
fn errorMessage(arena: Allocator, body: []const u8) []const u8 {
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return "";
    if (v != .object) return "";
    const m = v.object.get("message") orelse return "";
    return if (m == .string) m.string else "";
}

test "a refusal says why" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    try std.testing.expectEqualStrings("Resource not accessible by personal access token", errorMessage(a.allocator(), "{\"message\":\"Resource not accessible by personal access token\",\"documentation_url\":\"x\",\"status\":\"403\"}"));
    try std.testing.expectEqualStrings("", errorMessage(a.allocator(), "<html>"));
}

/// Parse the `generate-jitconfig` response body.
pub fn parseResponse(arena: Allocator, body: []const u8) Error!Jit {
    const Resp = struct {
        runner: struct { id: u64, name: []const u8 },
        encoded_jit_config: []const u8,
    };
    const parsed = std.json.parseFromSliceLeaky(
        Resp,
        arena,
        body,
        .{ .ignore_unknown_fields = true },
    ) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.BadResponse,
    };
    return .{
        .runner_id = parsed.runner.id,
        .runner_name = parsed.runner.name,
        .files = decode(arena, parsed.encoded_jit_config) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.BadResponse,
        },
    };
}

/// `encoded_jit_config` is base64 JSON `{ "<filename>": "<base64 content>" }` (unverified against
/// live GitHub).
pub fn decode(arena: Allocator, encoded: []const u8) ![]const File {
    const dec = std.base64.standard.Decoder;
    const json_bytes = try arena.alloc(u8, try dec.calcSizeForSlice(encoded));
    try dec.decode(json_bytes, encoded);

    const map = try std.json.parseFromSliceLeaky(
        std.json.ArrayHashMap([]const u8),
        arena,
        json_bytes,
        .{},
    );
    const files = try arena.alloc(File, map.map.count());
    for (map.map.keys(), map.map.values(), files) |k, v, *f| {
        const content = try arena.alloc(u8, try dec.calcSizeForSlice(v));
        try dec.decode(content, v);
        f.* = .{ .name = k, .content = content };
    }
    return files;
}

test "decode nested base64 files" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // {".runner":"aGVsbG8=",".credentials":"d29ybGQ="}
    const enc = "eyIucnVubmVyIjoiYUdWc2JHOD0iLCIuY3JlZGVudGlhbHMiOiJkMjl5YkdRPSJ9";
    const files = try decode(arena, enc);
    try std.testing.expectEqual(@as(usize, 2), files.len);
    try std.testing.expectEqualStrings(".runner", files[0].name);
    try std.testing.expectEqualStrings("hello", files[0].content);
    try std.testing.expectEqualStrings("world", files[1].content);
}

test "parse generate-jitconfig response" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const body =
        \\{"runner":{"id":23,"name":"zig-h-1","os":"unknown","status":"offline"},
        \\ "encoded_jit_config":"eyIucnVubmVyIjoiYUdWc2JHOD0ifQ=="}
    ;
    const jit = try parseResponse(arena_state.allocator(), body);
    try std.testing.expectEqual(@as(u64, 23), jit.runner_id);
    try std.testing.expectEqualStrings("hello", jit.files[0].content);
}

test "bad response" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectError(error.BadResponse, parseResponse(arena_state.allocator(), "{}"));
}

/// The repository's current name when GitHub knows it by another than GH_SCOPE's (it was renamed
/// or transferred), else null. GitHub redirects requests for the old name, but registering a runner
/// sends a body, which cannot follow a redirect; so the runner asks once, at start, and uses the
/// current name. Null too for an organization, or when GitHub could not say: the runner then goes
/// on with GH_SCOPE as given, and any real problem shows on registering.
pub fn movedRepo(arena: Allocator, io: std.Io, cfg: *const Config) ?Scope {
    const r = switch (cfg.scope) {
        .repo => |r| r,
        .org => return null,
    };
    const url = std.fmt.allocPrint(
        arena,
        "https://api.github.com/repos/{s}/{s}",
        .{ r.owner, r.name },
    ) catch return null;
    const resp = broker.request(arena, io, .GET, url, null, .{
        .token = cfg.gh_token,
        .extra_headers = &.{.{ .name = "X-GitHub-Api-Version", .value = "2022-11-28" }},
    }) catch return null;
    if (resp.status.class() != .success) return null;
    return currentName(arena, cfg.scope, resp.body);
}

/// The repository's `full_name` from GitHub's answer, when it is not `scope` (names compare without
/// case, as GitHub's do).
fn currentName(arena: Allocator, scope: Scope, body: []const u8) ?Scope {
    const Repo = struct { full_name: []const u8 };
    const repo = std.json.parseFromSliceLeaky(Repo, arena, body, .{
        .ignore_unknown_fields = true,
    }) catch return null;
    const now = Scope.parse(repo.full_name) catch return null;
    const was = scope.repo;
    if (std.ascii.eqlIgnoreCase(was.owner, now.repo.owner) and
        std.ascii.eqlIgnoreCase(was.name, now.repo.name)) return null;
    return now;
}

/// Removes this instance's registrations that a stopped runner left behind: offline, idle, and
/// named `<prefix>-<8 hex digits>` as this runner names its own. They were registered for one
/// just-in-time session each, which cannot be resumed, so none of them can come back. A runner that
/// could not remove its own on stopping (as when GitHub redirected the request) left them there.
/// Returns how many were removed; failures are left for the next start.
pub fn removeStale(arena: Allocator, io: std.Io, cfg: *const Config) u32 {
    const list_url = std.fmt.allocPrint(
        arena,
        "{s}?per_page=100",
        .{runnersUrl(arena, cfg) catch return 0},
    ) catch return 0;
    const resp = broker.request(arena, io, .GET, list_url, null, .{
        .token = cfg.gh_token,
        .extra_headers = &.{.{ .name = "X-GitHub-Api-Version", .value = "2022-11-28" }},
    }) catch return 0;
    if (resp.status.class() != .success) return 0;
    const ids = staleIds(arena, resp.body, cfg.name_prefix) catch return 0;
    var removed: u32 = 0;
    for (ids) |id| {
        const status = deleteRunner(arena, io, cfg, id) catch continue;
        if (status.class() == .success) removed += 1;
    }
    return removed;
}

/// The ids of the stale registrations in a `GET .../actions/runners` answer (see `removeStale`).
fn staleIds(arena: Allocator, body: []const u8, prefix: []const u8) ![]const u64 {
    const Runners = struct {
        runners: []const struct { id: u64, name: []const u8, status: []const u8, busy: bool },
    };
    const list = try std.json.parseFromSliceLeaky(Runners, arena, body, .{
        .ignore_unknown_fields = true,
    });
    var ids: std.ArrayList(u64) = .empty;
    for (list.runners) |r| {
        if (!std.mem.eql(u8, r.status, "offline") or r.busy) continue;
        if (!ownName(r.name, prefix)) continue;
        try ids.append(arena, r.id);
    }
    return ids.items;
}

/// Whether `name` is one this runner gives its registrations: `<prefix>-` and 8 hex digits.
fn ownName(name: []const u8, prefix: []const u8) bool {
    if (name.len != prefix.len + 9) return false;
    if (!std.mem.startsWith(u8, name, prefix) or name[prefix.len] != '-') return false;
    for (name[prefix.len + 1 ..]) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

test "a moved repository's current name" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const old: Scope = .{ .repo = .{ .owner = "Lementknight", .name = "zig-runner" } };
    const moved = currentName(a.allocator(), old, "{\"id\":1,\"full_name\":\"Open-Blue/zig-runner\"}").?;
    try std.testing.expectEqualStrings("Open-Blue", moved.repo.owner);
    try std.testing.expectEqualStrings("zig-runner", moved.repo.name);
    // The same name, whatever its case, is not a move; nor is an answer without one.
    try std.testing.expectEqual(null, currentName(a.allocator(), old, "{\"full_name\":\"lementknight/Zig-Runner\"}"));
    try std.testing.expectEqual(null, currentName(a.allocator(), old, "{\"message\":\"Not Found\"}"));
    try std.testing.expectEqual(null, currentName(a.allocator(), old, "<html>"));
}

test "stale registrations: offline, idle, and named as this runner names its own" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const body =
        \\{"total_count":6,"runners":[
        \\ {"id":24,"name":"zig-ci-9216e058","status":"offline","busy":false,"labels":[]},
        \\ {"id":25,"name":"zig-ci-2f160103","status":"online","busy":false},
        \\ {"id":26,"name":"zig-ci-41ef27a0","status":"offline","busy":true},
        \\ {"id":27,"name":"zig-ci-handmade","status":"offline","busy":false},
        \\ {"id":28,"name":"zig-sandbox-0a1b2c3d","status":"offline","busy":false},
        \\ {"id":29,"name":"zig-ci-0a1b2c3d4","status":"offline","busy":false}
        \\]}
    ;
    const ids = try staleIds(a.allocator(), body, "zig-ci");
    try std.testing.expectEqualSlices(u64, &.{24}, ids);
}
