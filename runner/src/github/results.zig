//! Uploads step and job logs to GitHub's results service so the Actions UI can show them.
//!
//! Flow per log (names from `actions/runner`; verified live, see SPEC §3): ask the service for a
//! signed blob URL (Twirp JSON, authorized with the job-scoped token), PUT the log text to that
//! URL, then register the upload with a metadata call. Blob lines are `<ISO timestamp, 7 digits>
//! <text>`. Failures never block job completion: callers log the returned detail and carry on.
const std = @import("std");
const broker = @import("broker.zig");
const http = @import("http.zig");
const job_mod = @import("../job.zig");
const sink = @import("../sink.zig");
const timefmt = @import("../timefmt.zig");

const Allocator = std.mem.Allocator;

pub const service = "results.services.receiver.Receiver";

pub const Blob = struct {
    text: []const u8,
    line_count: usize,
};

/// Lines of one step (`step` set) or of the whole job (`step` null), in arrival order.
pub fn formatBlob(
    arena: Allocator,
    lines: []const sink.CollectedLine,
    step: ?u32,
) Allocator.Error!Blob {
    var aw: std.Io.Writer.Allocating = .init(arena);
    var n: usize = 0;
    for (lines) |l| {
        if (step) |s| if (l.step != s) continue;
        const ts = try timefmt.isoTime7(arena, l.ts_ms);
        aw.writer.print("{s} {s}\n", .{ ts, l.text }) catch return error.OutOfMemory;
        n += 1;
    }
    return .{ .text = aw.written(), .line_count = n };
}

pub const Result = struct {
    ok: bool,
    /// Human-readable outcome; error bodies are short and carry no credentials.
    detail: []const u8,
};

/// What every call answers for a job that names no results service.
const no_endpoint: Result = .{ .ok = false, .detail = "job has no results endpoint" };

/// The most of an error body a failure's detail quotes.
const max_detail_body = 300;

pub const Which = union(enum) { step: []const u8, job };
const Meta = struct { uploaded_at: []const u8, line_count: usize };

fn twirpUrl(arena: Allocator, endpoint: []const u8, method: []const u8) Allocator.Error![]const u8 {
    const base = std.mem.trimEnd(u8, endpoint, "/");
    return std.fmt.allocPrint(arena, "{s}/twirp/{s}/{s}", .{ base, service, method });
}

fn ids(arena: Allocator, job: job_mod.Job, which: Which, meta: ?Meta) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    try w.writeAll("{\"workflow_run_backend_id\":");
    try std.json.Stringify.value(job.plan_id, .{}, w);
    try w.writeAll(",\"workflow_job_run_backend_id\":");
    try std.json.Stringify.value(job.job_id, .{}, w);
    switch (which) {
        .step => |id| {
            try w.writeAll(",\"step_backend_id\":");
            try std.json.Stringify.value(id, .{}, w);
        },
        .job => {},
    }
    if (meta) |m| {
        try w.writeAll(",\"uploaded_at\":");
        try std.json.Stringify.value(m.uploaded_at, .{}, w);
        try w.print(",\"line_count\":{d}", .{m.line_count});
    }
    try w.writeByte('}');
    return aw.written();
}

pub fn upload(arena: Allocator, io: std.Io, job: job_mod.Job, which: Which, blob: Blob) Result {
    return uploadInner(
        arena,
        io,
        job,
        which,
        blob,
    ) catch |e| .{ .ok = false, .detail = @errorName(e) };
}

fn uploadInner(arena: Allocator, io: std.Io, job: job_mod.Job, which: Which, blob: Blob) !Result {
    if (job.results_endpoint.len == 0) return no_endpoint;
    const get_method = switch (which) {
        .step => "GetStepLogsSignedBlobURL",
        .job => "GetJobLogsSignedBlobURL",
    };
    const meta_method = switch (which) {
        .step => "CreateStepLogsMetadata",
        .job => "CreateJobLogsMetadata",
    };

    const signed = try broker.call(
        arena,
        io,
        .POST,
        try twirpUrl(arena, job.results_endpoint, get_method),
        job.job_token,
        try ids(arena, job, which, null),
    );
    if (signed.status.class() != .success) return failed(arena, get_method, signed);
    const logs_url = jsonString(arena, signed.body, "logs_url") orelse return .{
        .ok = false,
        .detail = try std.fmt.allocPrint(arena, "{s}: no logs_url in response", .{get_method}),
    };

    const put = try putBlob(arena, io, logs_url, blob.text);
    if (put.status.class() != .success) return failed(arena, "blob upload", put);

    const uploaded_at = try timefmt.isoTime(arena, std.Io.Clock.real.now(io).toMilliseconds());
    const meta = try broker.call(arena, io, .POST, try twirpUrl(
        arena,
        job.results_endpoint,
        meta_method,
    ), job.job_token, try ids(arena, job, which, .{
        .uploaded_at = uploaded_at,
        .line_count = blob.line_count,
    }));
    if (meta.status.class() != .success) return failed(arena, meta_method, meta);
    return .{
        .ok = true,
        .detail = try std.fmt.allocPrint(arena, "{d} lines", .{blob.line_count}),
    };
}

/// Uploads what a step wrote to $GITHUB_STEP_SUMMARY, as actions/runner does: a signed URL from
/// `GetStepSummarySignedBlobURL` (`summary_url`), the markdown PUT to it, then
/// `CreateStepSummaryMetadata` with its size. GitHub shows it on the run's summary page.
pub fn uploadSummary(
    arena: Allocator,
    io: std.Io,
    job: job_mod.Job,
    step_id: []const u8,
    markdown: []const u8,
) Result {
    return uploadSummaryInner(
        arena,
        io,
        job,
        step_id,
        markdown,
    ) catch |e| .{ .ok = false, .detail = @errorName(e) };
}

fn uploadSummaryInner(
    arena: Allocator,
    io: std.Io,
    job: job_mod.Job,
    step_id: []const u8,
    markdown: []const u8,
) !Result {
    if (job.results_endpoint.len == 0) return no_endpoint;
    const which: Which = .{ .step = step_id };
    const signed = try broker.call(
        arena,
        io,
        .POST,
        try twirpUrl(arena, job.results_endpoint, "GetStepSummarySignedBlobURL"),
        job.job_token,
        try ids(arena, job, which, null),
    );
    if (signed.status.class() != .success) return failed(
        arena,
        "GetStepSummarySignedBlobURL",
        signed,
    );
    const url = jsonString(arena, signed.body, "summary_url") orelse return .{
        .ok = false,
        .detail = "GetStepSummarySignedBlobURL: no summary_url in response",
    };
    const put = try putBlob(arena, io, url, markdown);
    if (put.status.class() != .success) return failed(arena, "summary upload", put);
    const uploaded_at = try timefmt.isoTime(arena, std.Io.Clock.real.now(io).toMilliseconds());
    // The ids, then the size and time (the object's closing brace is replaced).
    const head = try ids(arena, job, which, null);
    const body = try std.fmt.allocPrint(
        arena,
        "{s},\"upload_size\":{d},\"uploaded_at\":\"{s}\"}}",
        .{ head[0 .. head.len - 1], markdown.len, uploaded_at },
    );
    const meta = try broker.call(
        arena,
        io,
        .POST,
        try twirpUrl(arena, job.results_endpoint, "CreateStepSummaryMetadata"),
        job.job_token,
        body,
    );
    if (meta.status.class() != .success) return failed(arena, "CreateStepSummaryMetadata", meta);
    return .{ .ok = true, .detail = try std.fmt.allocPrint(arena, "{d} bytes", .{markdown.len}) };
}

/// Tells GitHub the job's steps and where each stands, so its UI lists them while the job runs
/// (actions/runner's `WorkflowStepsUpdate`). `steps` is a JSON array of `{external_id, number,
/// name, status, conclusion, started_at, completed_at}`; a later `change_order` replaces earlier
/// ones.
pub fn updateSteps(
    arena: Allocator,
    io: std.Io,
    job: job_mod.Job,
    steps: []const u8,
    change_order: u64,
) Result {
    return updateStepsInner(
        arena,
        io,
        job,
        steps,
        change_order,
    ) catch |e| .{ .ok = false, .detail = @errorName(e) };
}

fn updateStepsInner(
    arena: Allocator,
    io: std.Io,
    job: job_mod.Job,
    steps: []const u8,
    change_order: u64,
) !Result {
    if (job.results_endpoint.len == 0) return no_endpoint;
    const base = std.mem.trimEnd(u8, job.results_endpoint, "/");
    const url = try std.fmt.allocPrint(
        arena,
        "{s}/twirp/github.actions.results.api.v1.WorkflowStepUpdateService/WorkflowStepsUpdate",
        .{base},
    );
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    try w.print(
        "{{\"steps\":{s},\"change_order\":{d},\"workflow_job_run_backend_id\":",
        .{ steps, change_order },
    );
    try std.json.Stringify.value(job.job_id, .{}, w);
    try w.writeAll(",\"workflow_run_backend_id\":");
    try std.json.Stringify.value(job.plan_id, .{}, w);
    try w.writeByte('}');
    const r = try broker.call(arena, io, .POST, url, job.job_token, aw.written());
    if (r.status.class() != .success) return failed(arena, "WorkflowStepsUpdate", r);
    return .{ .ok = true, .detail = "" };
}

/// PUTs `text` to a signed blob URL: no bearer token (the URL is the authorization), but Azure needs
/// the blob type.
fn putBlob(arena: Allocator, io: std.Io, url: []const u8, text: []const u8) !broker.Response {
    return broker.request(arena, io, .PUT, url, text, .{
        .content_type = "text/plain",
        .extra_headers = &.{.{ .name = "x-ms-blob-type", .value = "BlockBlob" }},
        .deadline = blobDeadline(text.len),
    });
}

/// How long a blob upload of `bytes` may take: a request's deadline, and as long again for each
/// `blob_rate` bytes, at most `blob_deadline_max`. A step's log is at most 1 MiB
/// (`StepLogs.max_bytes`, 38 s), a job's up to 64 MiB (`sink.CollectSink.max_bytes`), and a
/// Raspberry Pi on a slow uplink sends far less than a server: a fixed 30 s would cut off a big
/// log that was still going up.
pub fn blobDeadline(bytes: usize) std.Io.Duration {
    const base = http.request_deadline.nanoseconds;
    const ns = base + @as(i96, @intCast(bytes / blob_rate)) * std.time.ns_per_s;
    return .{ .nanoseconds = @min(ns, blob_deadline_max.nanoseconds) };
}

/// The slowest upload rate, in bytes a second, that a blob upload's deadline allows for: 128 KiB/s,
/// about 1 Mbit/s.
const blob_rate = 128 * 1024;
/// 64 MiB at `blob_rate` would be over 8 minutes; the job's end waits at most this long for one.
pub const blob_deadline_max: std.Io.Duration = .fromSeconds(5 * 60);

fn failed(arena: Allocator, what: []const u8, r: broker.Response) !Result {
    return .{
        .ok = false,
        .detail = try std.fmt.allocPrint(arena, "{s}: HTTP {d}: {s}", .{
            what,
            @backingInt(r.status),
            r.body[0..@min(r.body.len, max_detail_body)],
        }),
    };
}

fn jsonString(arena: Allocator, body: []const u8, key: []const u8) ?[]const u8 {
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return null;
    if (v != .object) return null;
    const s = v.object.get(key) orelse return null;
    return if (s == .string) s.string else null;
}

test "formatBlob prefixes timestamps and filters by step" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const lines = [_]sink.CollectedLine{
        .{ .step = 0, .seq = 1, .ts_ms = 1000, .text = "job acquired" },
        .{ .step = 1, .seq = 1, .ts_ms = 2000, .text = "hello" },
        .{ .step = 2, .seq = 1, .ts_ms = 3500, .text = "two" },
        .{ .step = 1, .seq = 2, .ts_ms = 4000, .text = "done" },
    };
    const s1 = try formatBlob(a.allocator(), &lines, 1);
    try std.testing.expectEqual(@as(usize, 2), s1.line_count);
    try std.testing.expectEqualStrings("1970-01-01T00:00:02.0000000Z hello\n1970-01-01T00:00:04.0000000Z done\n", s1.text);
    const all = try formatBlob(a.allocator(), &lines, null);
    try std.testing.expectEqual(@as(usize, 4), all.line_count);
}

test "a blob upload's deadline grows with its size, up to a cap" {
    try std.testing.expectEqual(http.request_deadline, blobDeadline(0));
    try std.testing.expectEqual(http.request_deadline, blobDeadline(blob_rate - 1));
    // A step's whole log, at most.
    try std.testing.expectEqual(std.Io.Duration.fromSeconds(38), blobDeadline(1 << 20));
    try std.testing.expectEqual(blob_deadline_max, blobDeadline(64 << 20));
}

test "request bodies" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const job: job_mod.Job = .{ .plan_id = "P", .job_id = "J", .job_token = "t", .check_run_id = 1, .secrets = &.{}, .steps = &.{} };
    try std.testing.expectEqualStrings(
        "{\"workflow_run_backend_id\":\"P\",\"workflow_job_run_backend_id\":\"J\",\"step_backend_id\":\"S\",\"uploaded_at\":\"T\",\"line_count\":3}",
        try ids(a.allocator(), job, .{ .step = "S" }, .{ .uploaded_at = "T", .line_count = 3 }),
    );
    try std.testing.expectEqualStrings("https://r.test/twirp/" ++ service ++ "/X", try twirpUrl(a.allocator(), "https://r.test/", "X"));
}
