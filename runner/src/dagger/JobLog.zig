//! Shared between the main task (which runs queries) and the reader task (which streams logs).

const JobLog = @This();

const std = @import("std");
const job_mod = @import("../job.zig");
const sink = @import("../sink.zig");
const redact = @import("../redact.zig");
const engine = @import("../engine.zig");
const matcher = @import("../matcher.zig");
/// commands.zig; not `commands`, which is a field of `JobLog`.
const commands_mod = @import("../commands.zig");
const Annotation = @import("../dagger.zig").Annotation;
const marker = @import("../dagger.zig").marker;
const bun_load_errors = @import("../dagger.zig").bun_load_errors;

const Allocator = std.mem.Allocator;

io: std.Io,
arena: Allocator,
log: *sink.LogSink,
sink_job_id: u64,
mu: std.Io.Mutex = .init,
/// Lines streamed live per step (index = step - 1) and whether the step's `end` marker was
/// seen.
live_lines: []std.atomic.Value(u32),
ended: []std.atomic.Value(bool),
/// The step whose live output said Bun refused to load the program (`bun_load_errors`), 0 for
/// none: an exec's recorded output, where this was looked for, is no longer read back unless
/// it is replayed (`Exec.Recorded`). Cleared as each exec begins.
bun_refused: std.atomic.Value(u32) = .init(0),
/// This job's `mark_env` value: a `begin` or `end` marker without it is a step's output.
/// Set before the log reader starts, and never changed.
mark: []const u8 = "",
/// Dagger's own progress lines outside any step (guarded by `mu`), kept for engine errors.
tail: [20][]const u8 = undefined,
tail_len: usize = 0,
/// Lines replayed from a query result whose live copy may still arrive late (guarded by `mu`).
/// Key is "<step>:<text>"; the value is how many live copies to swallow.
replayed: std.StringHashMapUnmanaged(u32) = .empty,
/// Workflow-command state per step (index = step - 1, guarded by `mu`).
commands: []StepCommands = &.{},
/// Steps whose recorded output was replayed (index = step - 1, guarded by `mu`). If no live
/// line ever arrives for one, Dagger served it from cache (see `noteReusedSteps`).
replayed_steps: []bool = &.{},
/// `ACTIONS_STEP_DEBUG`: show `::debug::` lines.
step_debug: bool = false,
/// The job's workspace (see `jobWorkspace`): annotations name files relative to it.
workspace: []const u8 = "",
/// `::error`/`::warning`/`::notice` lines and the runner's own errors, sent with completejob so
/// GitHub shows them on the run (guarded by `mu`).
annotations: std.ArrayList(Annotation) = .empty,
/// Problem matchers in force for the job (`::add-matcher::`, see matcher.zig), and the files a
/// step asked for but which have not been read yet (guarded by `mu`).
///
/// Reading the file needs a Dagger query, and this runs in the log path under `mu`: blocking
/// output on a round trip would stall the live feed. So a path is queued here and loaded
/// between steps, where the transport is at hand — which means a matcher takes effect from the
/// *next* step rather than part-way through the one that registered it. In practice that is
/// where it is wanted: `setup-node` registers tsc's matcher in its own step and the compiler
/// runs in a later one. SPEC.md §9 records the difference.
matchers: matcher.Set = .{},
pending_matchers: std.ArrayList([]const u8) = .empty,
/// Each service's output (index = service), printed in "Stop containers" as GitHub's runner
/// prints `docker logs` (guarded by `mu`); lines past `max_service_log_lines` are counted.
service_logs: []std.ArrayList([]const u8) = &.{},
service_dropped: []u32 = &.{},
/// Lines logged per log step so far (guarded by `mu`): an annotation without a file points to
/// its line in the step's log, as GitHub's runner does.
line_counts: []u32 = &.{},
/// The job's secrets and `::add-mask::` values (guarded by `mu`), created by the first mask and
/// handed to the log, which redacts through its index (see `redact.Set`).
masks: ?*redact.Set = null,
/// Where one line of a step's output is worked on (guarded by `mu`): parsed as a command, run
/// through the problem matchers, formatted. Reset after each line, keeping its capacity, so the
/// job's arena grows only by what a line leaves behind (an annotation, an output, a mask); see
/// `scratchAllocator`.
scratch: ?std.heap.ArenaAllocator = null,

pub const StepCommands = struct {
    stop_token: ?[]const u8 = null,
    /// From the deprecated `::set-output` and `::save-state`.
    outputs: std.ArrayList(job_mod.EnvVar) = .empty,
    state: std.ArrayList(job_mod.EnvVar) = .empty,
};

/// A line from the runner itself; never read as a workflow command.
pub fn append(sh: *JobLog, step: u32, text: []const u8) void {
    sh.mu.lockUncancelable(sh.io);
    defer sh.mu.unlock(sh.io);
    sh.appendLocked(step, text);
}

fn appendLocked(sh: *JobLog, step: u32, text: []const u8) void {
    sh.log.append(sh.sink_job_id, step, .stdout, text) catch {};
    if (step < sh.line_counts.len) sh.line_counts[step] += 1;
}

/// A line of a step's output: workflow commands (`::add-mask::`, `::group::`, ...) are carried
/// out and logged the way GitHub shows them; anything else is logged as it is.
fn stepOutput(sh: *JobLog, step: u32, text: []const u8) void {
    sh.mu.lockUncancelable(sh.io);
    defer sh.mu.unlock(sh.io);
    if (step == 0 or step > sh.commands.len) return sh.appendLocked(step, text);
    const st = &sh.commands[step - 1];
    const scratch = sh.scratchAllocator();
    defer sh.resetScratch();
    // What a command keeps (an annotation, an output, a stop token) can be a slice of its line,
    // and a direct session's line lives only as long as its log record: the line is copied,
    // and what outlives it is copied again into the job's arena below.
    const line = if (std.mem.indexOf(u8, text, "::") != null) scratch.dupe(u8, text) catch
        return else text;
    const cmd = commands_mod.parseWorkflow(scratch, line, st.stop_token) catch
        return sh.appendLocked(step, line);
    switch (cmd) {
        // Not a command: log it, then let the problem matchers see it.
        .none => {
            sh.appendLocked(step, text);
            sh.matchLocked(step, text);
        },
        .add_mask => |value| sh.addMask(value),
        .group => |title| sh.appendScratch(step, "##[group]{s}", .{title}),
        .endgroup => sh.appendLocked(step, "##[endgroup]"),
        .annotation => |an| {
            var lines = std.mem.splitScalar(u8, an.message, '\n');
            sh.appendScratch(
                step,
                "##[{s}]{s}",
                .{ an.level, std.mem.trimEnd(u8, lines.first(), "\r") },
            );
            while (lines.next()) |l| sh.appendLocked(step, std.mem.trimEnd(u8, l, "\r"));
            sh.annotateLocked(step, an);
        },
        .debug => |msg| if (sh.step_debug) sh.appendScratch(step, "##[debug]{s}", .{msg}),
        // GitHub logs nothing for either; the file is read between steps (see
        // `pending_matchers`).
        .add_matcher => |path| if (sh.arena.dupe(u8, path)) |p|
            sh.pending_matchers.append(sh.arena, p) catch {}
        else |_| {},
        .remove_matcher => |owner| sh.matchers.removeOwner(owner),
        .stop => |token| st.stop_token = sh.arena.dupe(u8, token) catch null,
        .resume_commands => st.stop_token = null,
        .set_output => |kv| if (sh.keepVar(kv)) |v| st.outputs.append(sh.arena, v) catch {},
        .save_state => |kv| if (sh.keepVar(kv)) |v| st.state.append(sh.arena, v) catch {},
        .disabled => |name| {
            const msg = std.fmt.allocPrint(
                scratch,
                "The `{s}` command is disabled. Please upgrade to using Environment Files " ++
                    "or opt " ++
                    "into unsecure command execution by setting the " ++
                    "`ACTIONS_ALLOW_UNSECURE_COMMANDS` environment variable to `true`. " ++
                    "For more information see: " ++
                    "https://github.blog/changelog/2020-10-01-github-actions-deprecating-set-env-and-add-path-commands/",
                .{name},
            ) catch return;
            sh.errorLineLocked(step, msg);
        },
        .echo => {},
    }
}

/// An error of the runner's own (a failed exit code, a timeout): logged as `##[error]<msg>` and
/// annotated, as GitHub's runner does.
pub fn errorLine(sh: *JobLog, step: u32, msg: []const u8) void {
    sh.mu.lockUncancelable(sh.io);
    defer sh.mu.unlock(sh.io);
    defer sh.resetScratch();
    sh.errorLineLocked(step, msg);
}

fn errorLineLocked(sh: *JobLog, step: u32, msg: []const u8) void {
    sh.appendScratch(step, "##[error]{s}", .{msg});
    sh.annotateLocked(step, .{ .level = "error", .message = msg });
}

/// The allocator for work on the current line, with `mu` held; the caller resets it with
/// `resetScratch` before letting go of `mu`. Built on the job's arena, which it returns memory
/// to only when a line needs more than any line before it, so it settles at the largest line's
/// needs.
fn scratchAllocator(sh: *JobLog) Allocator {
    if (sh.scratch == null) sh.scratch = .init(sh.arena);
    return sh.scratch.?.allocator();
}

fn resetScratch(sh: *JobLog) void {
    if (sh.scratch) |*s| _ = s.reset(.retain_capacity);
}

/// `appendFmt`, formatted in the scratch arena: for the log path, where `appendFmt` would keep
/// every formatted line in the job's arena.
fn appendScratch(sh: *JobLog, step: u32, comptime fmt: []const u8, args: anytype) void {
    const text = std.fmt.allocPrint(sh.scratchAllocator(), fmt, args) catch return;
    sh.appendLocked(step, text);
}

/// An output or state value parsed from a line, copied into the job's arena.
fn keepVar(sh: *JobLog, kv: job_mod.EnvVar) ?job_mod.EnvVar {
    return .{
        .name = sh.arena.dupe(u8, kv.name) catch return null,
        .value = sh.arena.dupe(u8, kv.value) catch return null,
    };
}

/// The matcher files steps have asked for, emptied. Called off the log path.
pub fn takePendingMatchers(sh: *JobLog) []const []const u8 {
    sh.mu.lockUncancelable(sh.io);
    defer sh.mu.unlock(sh.io);
    const out = sh.pending_matchers.items;
    sh.pending_matchers = .empty;
    return out;
}

pub fn addMatchers(sh: *JobLog, matchers: []const matcher.Matcher) void {
    sh.mu.lockUncancelable(sh.io);
    defer sh.mu.unlock(sh.io);
    sh.matchers.add(sh.arena, matchers) catch {};
}

/// A warning from off the log path. `appendFmt` reaches `appendLocked`, which mutates the log
/// and the per-step line counts that the live-output task also writes — so it needs `mu`, and
/// the first version of `loadPendingMatchers` called it without. That is a real data race.
///
/// It is **not** what caused the segfault that came with the problem-matcher work; the dangling
/// line in `matchLocked` is, and that one has evidence. This was found while looking for the
/// crash and fixed on its own merits. The distinction is kept because the alternative is a
/// reader concluding the crash is accounted for by a lock they can see.
pub fn warnUnlocked(sh: *JobLog, step: u32, text: []const u8) void {
    sh.mu.lockUncancelable(sh.io);
    defer sh.mu.unlock(sh.io);
    sh.appendLocked(step, text);
}

/// Offers a line to the problem matchers and annotates whatever they complete. Called with `mu`
/// held, straight after the line was logged, so `annotateLocked` can point an annotation
/// without a file at the line it came from.
fn matchLocked(sh: *JobLog, step: u32, text: []const u8) void {
    if (sh.matchers.count() == 0) return;
    // **The line must be duplicated first.** Everything a match captures is a slice of it, and
    // a direct session's line lives only as long as its log record — the same reason the
    // command path above dupes a line containing `::`. Storing an annotation that points into
    // a freed record corrupts the heap, and because every runner in this process shares it, the
    // crash surfaces in whatever job is unlucky: this cost a segfault in a hugo build that had
    // no matchers at all, while another job's matcher was matching.
    //
    // Into the scratch arena, with the matchers' work: an annotation keeps a copy of what it
    // needs (`annotateLocked`), and the rest goes when `stepOutput` resets the scratch.
    const scratch = sh.scratchAllocator();
    const line = scratch.dupe(u8, std.mem.trimEnd(u8, text, "\r")) catch return;
    const found = sh.matchers.feed(scratch, line) catch return;
    for (found) |f| sh.annotateLocked(step, .{
        .level = f.level,
        .message = f.message,
        .file = f.file,
        .line = f.line,
        .end_line = f.end_line,
        .col = f.col,
        .end_column = f.end_column,
        // GitHub shows a matcher's `code` as the annotation's title.
        .title = f.code,
    });
}

/// Keeps an annotation for completejob. Like GitHub's runner, at most `max_annotations` of each
/// level per step (the rest are only logged), and a file in the workspace is named from its
/// root.
fn annotateLocked(sh: *JobLog, step: u32, an: commands_mod.Annotation) void {
    var same: usize = 0;
    for (sh.annotations.items) |a| {
        if (a.step == step and std.mem.eql(u8, a.an.level, an.level)) same += 1;
    }
    if (same >= max_annotations) return;
    // Its own copy: what it was given is usually a slice of a line in the scratch arena.
    const a = sh.arena;
    var copy: commands_mod.Annotation = .{
        .level = a.dupe(u8, an.level) catch return,
        .message = a.dupe(u8, an.message) catch return,
        .title = dupeOpt(a, an.title) catch return,
        .file = dupeOpt(a, an.file) catch return,
        .line = dupeOpt(a, an.line) catch return,
        .end_line = dupeOpt(a, an.end_line) catch return,
        .col = dupeOpt(a, an.col) catch return,
        .end_column = dupeOpt(a, an.end_column) catch return,
    };
    if (copy.file) |f| copy.file = if (std.mem.startsWith(
        u8,
        f,
        sh.workspace,
    ) and std.mem.startsWith(u8, f[sh.workspace.len..], "/")) f[sh.workspace.len + 1 ..] else f;
    // Its line in the log: the annotation's own line was logged just before this.
    if (an.file == null and an.line == null and step < sh.line_counts.len and
        sh.line_counts[step] > 0)
        copy.line = std.fmt.allocPrint(
            sh.arena,
            "{d}",
            .{sh.line_counts[step] - countLines(an.message) + 1},
        ) catch null;
    sh.annotations.append(sh.arena, .{ .step = step, .an = copy }) catch {};
}

pub fn appendFmt(sh: *JobLog, step: u32, comptime fmt: []const u8, args: anytype) void {
    const text = std.fmt.allocPrint(sh.arena, fmt, args) catch return;
    sh.appendLocked(step, text);
}

/// Masks `value` (and each of its lines) in everything logged from now on, in every sink.
///
/// The set keeps them longest first, so a secret that begins with another is masked whole. It
/// starts from the log's secrets (the job's), copied once; before it, each mask copied and
/// sorted the whole list again, which made 20000 masks cost 5.8 GB.
fn addMask(sh: *JobLog, value: []const u8) void {
    const set = sh.masks orelse set: {
        const set = sh.arena.create(redact.Set) catch return;
        set.* = .{};
        for (sh.log.currentSecrets()) |s| set.add(sh.arena, s) catch return;
        sh.masks = set;
        break :set set;
    };
    // In every form, as the job's own secrets are (redact.forms). The forms are worked out in
    // the scratch arena: the set copies the ones it has not seen.
    const forms = redact.forms(sh.scratchAllocator(), value) catch return;
    for (forms) |f| set.add(sh.arena, f) catch {};
    sh.log.setSecretSet(set);
}

fn dupeOpt(a: Allocator, s: ?[]const u8) Allocator.Error!?[]const u8 {
    return if (s) |t| try a.dupe(u8, t) else null;
}

/// `text` with the job's secrets and masks so far replaced, for what leaves the runner other
/// than through the log (a step's evaluated name, a job output).
pub fn redacted(sh: *JobLog, arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
    sh.mu.lockUncancelable(sh.io);
    defer sh.mu.unlock(sh.io);
    return redact.alloc(arena, text, sh.log.currentSecrets());
}

/// Whether `text` holds one of the job's secrets or masks, of `min_len` bytes or more.
pub fn holdsSecret(sh: *JobLog, text: []const u8, min_len: usize) bool {
    std.debug.assert(min_len > 0);
    sh.mu.lockUncancelable(sh.io);
    defer sh.mu.unlock(sh.io);
    for (sh.log.currentSecrets()) |s| {
        if (s.len >= min_len and std.mem.indexOf(u8, text, s) != null) return true;
    }
    return false;
}

/// State a step saved with the deprecated `::save-state`, since the last call.
pub fn takeState(sh: *JobLog, step: u32) []const job_mod.EnvVar {
    sh.mu.lockUncancelable(sh.io);
    defer sh.mu.unlock(sh.io);
    if (step == 0 or step > sh.commands.len) return &.{};
    const st = &sh.commands[step - 1];
    const out = st.state.items;
    st.state = .empty;
    return out;
}

/// Outputs a step set with the deprecated `::set-output`, since the last call.
pub fn takeOutputs(sh: *JobLog, step: u32) []const job_mod.EnvVar {
    sh.mu.lockUncancelable(sh.io);
    defer sh.mu.unlock(sh.io);
    if (step == 0 or step > sh.commands.len) return &.{};
    const st = &sh.commands[step - 1];
    const out = st.outputs.items;
    st.outputs = .empty;
    return out;
}

pub fn flush(sh: *JobLog) void {
    sh.mu.lockUncancelable(sh.io);
    defer sh.mu.unlock(sh.io);
    sh.log.flush() catch {};
}

/// Whether a marker is the runner's own, read in a span that is step `in_step`'s (null: no
/// step's yet). Anything else came from a step's own output and is logged as such.
///
/// A step's `begin` or `end` must carry the job's secret (`mark_env`): a step that printed
/// `::zig-step::begin 3` once had its lines counted as step 3's, and step 3, replayed later,
/// then looked live and its recorded output (`::set-output` included) was never processed
/// (issue #71). It must name one of the job's steps too: `echo '::zig-step::begin 4000000000'`
/// once made the log sink grow an array to that many entries, about 32 GB (#59). A service's
/// marker carries no secret (a service is not a step and is not given one); it counts only
/// before any step's marker in its span, which is where a service prints it.
fn isOwn(sh: *JobLog, sc: Scan, in_step: ?u32) bool {
    return switch (sc.marker) {
        .begin, .end => |n| n >= 1 and n <= sh.ended.len and std.mem.eql(u8, sc.mark, sh.mark),
        .service => |n| in_step == null and n < sh.service_logs.len,
    };
}

fn emitLive(sh: *JobLog, step: u32, text: []const u8) void {
    if (step >= 1 and step <= sh.live_lines.len)
        _ = sh.live_lines[step - 1].fetchAdd(1, .monotonic);
    for (bun_load_errors) |e| if (std.mem.indexOf(u8, text, e) != null)
        sh.bun_refused.store(step, .release);
    if (sh.swallowIfReplayed(step, text)) return;
    sh.stepOutput(step, text);
}

/// True if this live line was already logged by a replay (the stream was just late).
fn swallowIfReplayed(sh: *JobLog, step: u32, text: []const u8) bool {
    sh.mu.lockUncancelable(sh.io);
    defer sh.mu.unlock(sh.io);
    if (sh.replayed.count() == 0) return false;
    var key_buf: [512]u8 = undefined;
    const key = std.fmt.bufPrint(&key_buf, "{d}:{s}", .{ step, text }) catch return false;
    const entry = sh.replayed.getPtr(key) orelse return false;
    if (entry.* > 1) entry.* -= 1 else _ = sh.replayed.remove(key);
    return true;
}

/// Logs a line taken from a query result and remembers it so a late live copy is dropped.
fn replay(sh: *JobLog, step: u32, text: []const u8) void {
    {
        sh.mu.lockUncancelable(sh.io);
        defer sh.mu.unlock(sh.io);
        if (std.fmt.allocPrint(sh.arena, "{d}:{s}", .{ step, text })) |key| {
            const gop = sh.replayed.getOrPut(sh.arena, key) catch null;
            if (gop) |g| {
                if (!g.found_existing) g.value_ptr.* = 0;
                g.value_ptr.* += 1;
            }
        } else |_| {}
    }
    sh.stepOutput(step, text);
}

/// Service `n`'s output so far, and a note when lines were left out.
pub fn takeServiceLog(sh: *JobLog, n: usize) []const []const u8 {
    sh.mu.lockUncancelable(sh.io);
    defer sh.mu.unlock(sh.io);
    if (n >= sh.service_logs.len) return &.{};
    if (sh.service_dropped[n] > 0) {
        const note = std.fmt.allocPrint(
            sh.arena,
            "... {d} more lines not kept",
            .{sh.service_dropped[n]},
        ) catch return sh.service_logs[n].items;
        sh.service_logs[n].append(sh.arena, note) catch {};
    }
    return sh.service_logs[n].items;
}

fn serviceLine(sh: *JobLog, n: u32, line: []const u8) void {
    sh.mu.lockUncancelable(sh.io);
    defer sh.mu.unlock(sh.io);
    if (n >= sh.service_logs.len) return;
    if (sh.service_logs[n].items.len >= max_service_log_lines) {
        sh.service_dropped[n] += 1;
        return;
    }
    sh.service_logs[n].append(sh.arena, sh.arena.dupe(u8, line) catch return) catch {};
}

fn noise(sh: *JobLog, line: []const u8) void {
    sh.mu.lockUncancelable(sh.io);
    defer sh.mu.unlock(sh.io);
    if (sh.tail_len == sh.tail.len) {
        std.mem.copyForwards([]const u8, sh.tail[0 .. sh.tail.len - 1], sh.tail[1..]);
        sh.tail_len -= 1;
    }
    sh.tail[sh.tail_len] = sh.arena.dupe(u8, line) catch return;
    sh.tail_len += 1;
}

/// The log lines a message takes (an annotation's message is logged one line per line).
fn countLines(msg: []const u8) u32 {
    return @intCast(std.mem.count(u8, msg, "\n") + 1);
}

/// Per service, kept for "Stop containers".
const max_service_log_lines = 10_000;

/// Per level and step, as GitHub's runner limits them.
const max_annotations = 10;

// --- the log reader ---

pub const Marker = union(enum) {
    begin: u32,
    end: u32,
    /// The first line a service prints (see `startServices`): its output is service n's (0-based).
    service: u32,
};

pub const Scan = struct {
    /// Step output that preceded the marker on the same line (output without a trailing newline).
    before: []const u8,
    marker: Marker,
    /// The word after the step number: the job's `mark_env` value in a marker the runner's script
    /// printed, "" when there is none (a service's marker).
    mark: []const u8 = "",
};

/// Finds a marker at the end of `line` (`<marker><kind> <n>[ <mark>]`). Returns null for ordinary
/// output. Whether it is the runner's own, and not text a step printed, is for the caller to say
/// (`JobLog.isOwn`, `replayRecorded`): any step can print this text.
///
/// The last occurrence counts: the runner's markers are echoed on a line of their own, so one that
/// shares a line follows a step's output without a trailing newline — output that may itself
/// contain the marker text.
pub fn scan(line: []const u8) ?Scan {
    const i = std.mem.lastIndexOf(u8, line, marker) orelse return null;
    var it = std.mem.tokenizeScalar(u8, line[i + marker.len ..], ' ');
    const kind = it.next() orelse return null;
    const step = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    const mark = it.next() orelse "";
    if (it.next() != null) return null;
    const m: Marker = if (std.mem.eql(u8, kind, "begin"))
        .{ .begin = step }
    else if (std.mem.eql(u8, kind, "end"))
        .{ .end = step }
    else if (std.mem.eql(u8, kind, "service"))
        .{ .service = step }
    else
        return null;
    return .{ .before = line[0..i], .marker = m, .mark = mark };
}

/// Dagger prefixes span headers with a block glyph (U+25xx, e.g. "▼", "▋").
fn isSpanHeader(line: []const u8) bool {
    return line.len >= 4 and line[0] == 0xE2 and line[1] == 0x96;
}

/// Step number from a script line such as `echo '::zig-step::begin 2'`.
fn headerStep(line: []const u8) ?u32 {
    const i = std.mem.indexOf(u8, line, marker ++ "begin ") orelse return null;
    const rest = line[i + marker.len + "begin ".len ..];
    var n: usize = 0;
    while (n < rest.len and std.ascii.isDigit(rest[n])) n += 1;
    if (n == 0) return null;
    return std.fmt.parseInt(u32, rest[0..n], 10) catch null;
}

/// Splits Dagger's log stream into per-step output.
const Demux = struct {
    sh: *JobLog,
    span_step: ?u32 = null,

    fn feed(d: *Demux, line: []const u8) void {
        // Span headers are one line (the script's newlines are escaped) and name the step.
        if (isSpanHeader(line)) {
            d.span_step = headerStep(line);
            return;
        }
        if (scan(line)) |sc| {
            // A step can print a marker itself: that is its output, not a marker.
            if (!d.sh.isOwn(sc, d.span_step)) {
                if (d.span_step) |c| d.sh.emitLive(c, line) else if (line.len > 0) d.sh.noise(line);
                return;
            }
            if (d.span_step) |c| if (sc.before.len > 0) d.sh.emitLive(c, sc.before);
            switch (sc.marker) {
                .begin => |n| d.span_step = n,
                .end => |n| {
                    if (n >= 1 and n <= d.sh.ended.len) d.sh.ended[n - 1].store(true, .release);
                    d.sh.flush();
                    d.span_step = null;
                },
                .service => {},
            }
        } else if (d.span_step) |c| {
            d.sh.emitLive(c, line);
        } else if (line.len > 0) {
            d.sh.noise(line);
        }
    }
};

pub fn readLogs(io: std.Io, sh: *JobLog, file: std.Io.File) void {
    var demux: Demux = .{ .sh = sh };
    var rbuf: [64 * 1024]u8 = undefined;
    var fr = file.readerStreaming(io, &rbuf);
    const r = &fr.interface;
    while (true) {
        const raw = r.takeDelimiter('\n') catch |e| switch (e) {
            error.StreamTooLong => {
                _ = r.discardDelimiterInclusive('\n') catch return;
                continue;
            },
            error.ReadFailed => return,
        } orelse return;
        demux.feed(std.mem.trimEnd(u8, raw, "\r"));
    }
}

/// Routes a direct session's log records to steps. Each exec is a span: its output arrives as
/// records with the span's id, in pieces that are joined into lines here. A span belongs to the
/// step whose `begin` marker it prints; records the engine marks verbose (a repeat of output it
/// already logged, such as a `stdout` field's value) are skipped, as in Dagger's own progress
/// output.
pub const SpanDemux = struct {
    sh: *JobLog,
    gpa: Allocator,
    mu: std.Io.Mutex = .init,
    spans: std.StringHashMapUnmanaged(Span) = .empty,

    pub const Span = struct {
        step: ?u32 = null,
        /// The span is a service's (its output is kept for "Stop containers").
        service: ?u32 = null,
        partial: std.ArrayList(u8) = .empty,
    };

    /// The longest line joined from a span's pieces (`onRecord`).
    const max_line_bytes = 1024 * 1024;

    pub fn onRecord(ptr: *anyopaque, rec: engine.LogRecord) void {
        const d: *SpanDemux = @ptrCast(@alignCast(ptr));
        if (rec.verbose) return;
        d.mu.lockUncancelable(d.sh.io);
        defer d.mu.unlock(d.sh.io);
        const gop = d.spans.getOrPut(d.gpa, rec.span) catch return;
        if (!gop.found_existing) {
            gop.key_ptr.* = d.gpa.dupe(u8, rec.span) catch {
                _ = d.spans.remove(rec.span);
                return;
            };
            gop.value_ptr.* = .{};
        }
        const span = gop.value_ptr;
        span.partial.appendSlice(d.gpa, rec.text) catch return;
        var start: usize = 0;
        while (std.mem.indexOfScalarPos(u8, span.partial.items, start, '\n')) |nl| {
            d.line(span, std.mem.trimEnd(u8, span.partial.items[start..nl], "\r"));
            start = nl + 1;
        }
        span.partial.replaceRangeAssumeCapacity(0, start, &.{});
        // Output with no newline in it (`head -c 200M /dev/zero`) is a line that never ends: past
        // `max_line_bytes` what has come is a line of its own, rather than all of it held here.
        if (span.partial.items.len >= max_line_bytes) {
            d.line(span, span.partial.items);
            span.partial.clearAndFree(d.gpa);
        }
        if (rec.eof and span.partial.items.len > 0) {
            d.line(span, span.partial.items);
            span.partial.clearRetainingCapacity();
        }
    }

    pub fn line(d: *SpanDemux, span: *Span, text: []const u8) void {
        if (scan(text)) |sc| {
            if (!d.sh.isOwn(sc, span.step)) {
                if (span.step) |c| d.sh.emitLive(c, text) else if (text.len > 0) d.sh.noise(text);
                return;
            }
            if (span.step) |c| if (sc.before.len > 0) d.sh.emitLive(c, sc.before);
            switch (sc.marker) {
                .begin => |n| span.step = n,
                .end => |n| {
                    if (n >= 1 and n <= d.sh.ended.len) d.sh.ended[n - 1].store(true, .release);
                    d.sh.flush();
                    span.step = null;
                },
                .service => |n| span.service = n,
            }
        } else if (span.step) |c| {
            d.sh.emitLive(c, text);
        } else if (span.service) |n| {
            d.sh.serviceLine(n, text);
        } else if (text.len > 0) {
            d.sh.noise(text);
        }
    }

    /// Output left without a final newline, once the stream has ended.
    pub fn flushPartial(d: *SpanDemux) void {
        d.mu.lockUncancelable(d.sh.io);
        defer d.mu.unlock(d.sh.io);
        var it = d.spans.valueIterator();
        while (it.next()) |span| if (span.partial.items.len > 0) {
            d.line(span, span.partial.items);
            span.partial.clearRetainingCapacity();
        };
    }

    pub fn deinit(d: *SpanDemux) void {
        var it = d.spans.iterator();
        while (it.next()) |e| {
            d.gpa.free(e.key_ptr.*);
            e.value_ptr.partial.deinit(d.gpa);
        }
        d.spans.deinit(d.gpa);
    }
};

/// How long to wait for a step's live lines before assuming it was served from cache. The log
/// stream delivers a real step's `end` marker within milliseconds, and a real run stops waiting as
/// soon as it arrives, so only cached steps pay this. If the stream is later than this, lines show
/// up twice rather than being lost.
const live_grace_ms = 60;

/// Gives the reader a moment to deliver this step's lines; if none show up the step was served from
/// cache, so its recorded output is logged instead (`replayRecorded`). `ran`: whether the step ran
/// in this job, when its marker says so (see `ran_env`); null when there is none, and then a step
/// counts as cached if neither its lines nor its end marker arrived in time.
pub fn awaitLiveOrReplay(
    io: std.Io,
    sh: *JobLog,
    step: u32,
    stdout: []const u8,
    stderr: []const u8,
    ran: ?bool,
) bool {
    if (awaitLive(io, sh, step)) return false;
    return replayNotLive(sh, step, stdout, stderr, ran);
}

/// Whether any of the step's lines arrived live, given a moment to.
pub fn awaitLive(io: std.Io, sh: *JobLog, step: u32) bool {
    const idx = step - 1;
    var waited: u32 = 0;
    while (waited < live_grace_ms and !sh.ended[idx].load(.acquire)) : (waited += 10) {
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    return sh.live_lines[idx].load(.monotonic) > 0;
}

/// Whether a step none of whose lines arrived live was served from the cache: its marker says it
/// did not run in this job, or, without one, its end marker never arrived either.
pub fn servedFromCache(sh: *JobLog, step: u32, ran: ?bool) bool {
    return if (ran) |r| !r else !sh.ended[step - 1].load(.acquire);
}

/// The rest of `awaitLiveOrReplay`, once none of the step's lines arrived live.
pub fn replayNotLive(sh: *JobLog, step: u32, stdout: []const u8, stderr: []const u8, ran: ?bool) bool {
    const idx = step - 1;
    // The step ran (its end marker arrived) but none of its lines did. Before a step's stderr went
    // to its stdout (`stream_prologue`), a program's stderr could arrive after the marker when it
    // failed at once (Bun refusing an action's bundle, on Linux), and so belonged to no step. Show
    // the result's output, which has them, as the step's own.
    const cached = servedFromCache(sh, step, ran);
    if (cached) {
        sh.mu.lockUncancelable(sh.io);
        defer sh.mu.unlock(sh.io);
        if (idx < sh.replayed_steps.len) sh.replayed_steps[idx] = true;
    }
    replayRecorded(sh, step, stdout, stderr);
    sh.flush();
    return cached;
}

/// Logs an exec's recorded output as step `step`'s, as the live log showed it when it ran: every
/// line in order, blank ones included, each through the same workflow-command processing
/// (`JobLog.stepOutput`), so masks, stopped commands, `::set-output` and problem matchers come out
/// as they did (issue #71).
///
/// The recorded stdout is the script's whole output, stderr included (`stream_prologue`), so its
/// order is the order it was written. `stderr` is normally empty and is logged after it.
///
/// The script's own markers are left out, and nothing else is: a marker is the script's when it
/// carries the secret of the job that ran the exec, which for a replayed exec is an earlier job's
/// (`mark_env`). That one is learnt from the `begin` marker on the first line, printed before any
/// of the step's output. Any other marker text is the step's output, as it was live
/// (`JobLog.isOwn`); recorded output without a `begin` marker first is all output.
fn replayRecorded(sh: *JobLog, step: u32, stdout: []const u8, stderr: []const u8) void {
    var mark: ?[]const u8 = null;
    var first = true;
    for ([_][]const u8{ stdout, stderr }) |text| {
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |l| {
            // After the last newline: nothing (the usual end), or a last line without one.
            if (l.len == 0 and lines.peek() == null) break;
            const t = std.mem.trimEnd(u8, l, "\r");
            defer first = false;
            if (scan(t)) |sc| own: {
                if (sc.marker == .service) break :own;
                if (first and sc.marker == .begin) mark = sc.mark;
                const m = mark orelse break :own;
                if (!std.mem.eql(u8, sc.mark, m)) break :own;
                if (sc.before.len > 0) sh.replay(step, sc.before);
                continue;
            }
            sh.replay(step, t);
        }
    }
}

/// The note a replayed step's log ends with. The runner counts it per job (see `loop/job.zig`), so
/// a step cached by the engine is visible in the runner's own log, not only in the step's.
pub const reused_note = "Reused from Dagger's cache: this step's inputs were unchanged since " ++
    "an earlier run, so the output above was recorded then.";

/// Says which steps Dagger served from cache. Decided once the session has ended and the log stream
/// is fully read, not when a step's output is replayed: the live stream can lag behind a step that
/// did run, and its lines then arrive (and are dropped as duplicates) after the replay. Only a step
/// none of whose live lines ever arrived was reused. The note goes to that step's own log, after
/// its output.
pub fn noteReusedSteps(sh: *JobLog) void {
    for (sh.replayed_steps, 0..) |replayed, idx| {
        if (!replayed or sh.live_lines[idx].load(.monotonic) > 0 or sh.ended[idx].load(.acquire))
            continue;
        sh.append(@intCast(idx + 1), reused_note);
    }
}

/// A one-step job's `JobLog` for the log path's memory tests, logging to a sink that discards.
const LogPathFixture = struct {
    disc: std.Io.Writer.Discarding,
    log: sink.LogSink,
    live: [1]std.atomic.Value(u32) = .{.init(0)},
    ended: [1]std.atomic.Value(bool) = .{.init(false)},
    replayed: [1]bool = .{false},
    cmds: [1]JobLog.StepCommands = .{.{}},
    line_counts: [2]u32 = .{ 0, 0 },
    buf: [256]u8 = undefined,
    sh: JobLog,

    /// In place: the log and `sh` point into the fixture.
    fn init(f: *LogPathFixture, arena: Allocator) void {
        f.* = .{ .disc = undefined, .log = undefined, .sh = undefined };
        f.disc = .init(&f.buf);
        f.log = .{ .stdout = .{ .writer = &f.disc.writer } };
        f.sh = .{
            .io = std.testing.io,
            .arena = arena,
            .log = &f.log,
            .sink_job_id = 0,
            .live_lines = &f.live,
            .ended = &f.ended,
            .replayed_steps = &f.replayed,
            .commands = &f.cmds,
            .line_counts = &f.line_counts,
        };
    }
};

test "a service's first line names its output" {
    const sc = scan("::zig-step::service 1").?;
    try std.testing.expectEqual(Marker{ .service = 1 }, sc.marker);
}

test "scan finds markers, with and without leading output" {
    try std.testing.expect(scan("plain output") == null);
    try std.testing.expectEqual(@as(u32, 3), scan(marker ++ "begin 3").?.marker.begin);
    const e = scan("tail without newline" ++ marker ++ "end 2").?;
    try std.testing.expectEqualStrings("tail without newline", e.before);
    try std.testing.expectEqual(@as(u32, 2), e.marker.end);
    try std.testing.expect(scan(marker ++ "bogus 1") == null);
    // Script source shown in a span header must not parse as a marker.
    try std.testing.expect(scan("echo '" ++ marker ++ "begin 2'\\''") == null);
    try std.testing.expectEqual(@as(?u32, 2), headerStep("echo '" ++ marker ++ "begin 2'\\''"));
}

test "the marker a step's script prints is one `scan` reads, with the secret after the number" {
    const sc = scan(marker ++ "begin 2 0123abcd").?;
    try std.testing.expectEqual(@as(u32, 2), sc.marker.begin);
    try std.testing.expectEqualStrings("0123abcd", sc.mark);
    // The variable unset: `echo` leaves a trailing space and no secret.
    try std.testing.expectEqualStrings("", scan(marker ++ "end 2 ").?.mark);
    // The runner's marker is the last on its line; output before it may hold marker text.
    const e = scan("out " ++ marker ++ marker ++ "end 2 m").?;
    try std.testing.expectEqual(@as(u32, 2), e.marker.end);
    try std.testing.expectEqualStrings("out " ++ marker, e.before);
    try std.testing.expect(scan(marker ++ "end 2 m extra") == null);
}

test "a live line that arrives after its step was replayed is dropped, not logged twice" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    const live = [_]std.atomic.Value(u32){.init(0)};
    const ended = [_]std.atomic.Value(bool){.init(false)};
    var sh: JobLog = .{ .io = std.testing.io, .arena = a.allocator(), .log = &log, .sink_job_id = 0, .live_lines = @constCast(&live), .ended = @constCast(&ended) };
    sh.replay(1, "hello"); // the step looked cached
    sh.emitLive(1, "hello"); // ...but its live copy arrives late
    sh.emitLive(1, "hello"); // a genuine second line with the same text is kept
    sh.emitLive(1, "other");
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, w.buffered(), "hello\n"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, w.buffered(), "other\n"));
}

test "a marker a step prints itself, naming no step of the job, is output, not a marker" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    const live = [_]std.atomic.Value(u32){.init(0)};
    const ended = [_]std.atomic.Value(bool){.init(false)};
    var sh: JobLog = .{ .io = std.testing.io, .arena = a.allocator(), .log = &log, .sink_job_id = 0, .live_lines = @constCast(&live), .ended = @constCast(&ended) };
    var d: Demux = .{ .sh = &sh };
    d.feed(marker ++ "begin 1");
    d.feed(marker ++ "begin 4000000000"); // printed by the step
    d.feed("still step 1");
    d.feed(marker ++ "end 1");
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, marker ++ "begin 4000000000") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "still step 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "step 4000000000") == null);
    try std.testing.expect(ended[0].load(.acquire));
}

test "output with no newline is cut into lines of max_line_bytes, not held whole" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    var log: sink.LogSink = .{ .stdout = .{ .writer = undefined } };
    // No step is open, so the lines are noise: kept in `tail`, not logged.
    var live = [_]std.atomic.Value(u32){.init(0)};
    var ended = [_]std.atomic.Value(bool){.init(false)};
    var sh: JobLog = .{
        .io = std.testing.io,
        .arena = a.allocator(),
        .log = &log,
        .sink_job_id = 0,
        .live_lines = &live,
        .ended = &ended,
    };
    var sd: SpanDemux = .{ .sh = &sh, .gpa = std.testing.allocator };
    defer sd.deinit();
    // 3.5 MiB in 64 KiB pieces, none of them ending a line.
    const piece: [64 * 1024]u8 = @splat('x');
    for (0..56) |_| {
        SpanDemux.onRecord(&sd, .{ .span = "s1", .stream = 1, .text = &piece });
        const span = sd.spans.get("s1").?;
        try std.testing.expect(span.partial.capacity <= 2 * SpanDemux.max_line_bytes);
    }
    try std.testing.expectEqual(@as(usize, 3), sh.tail_len);
    const left = sd.spans.get("s1").?.partial.items.len;
    try std.testing.expectEqual(SpanDemux.max_line_bytes / 2, left);
}

test "a marker a step prints for another step of the job is output, not a marker" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    var live = [_]std.atomic.Value(u32){ .init(0), .init(0), .init(0) };
    var ended = [_]std.atomic.Value(bool){ .init(false), .init(false), .init(false) };
    var replayed = [_]bool{ false, false, false };
    var cmds = [_]JobLog.StepCommands{ .{}, .{}, .{} };
    var sh: JobLog = .{ .io = std.testing.io, .arena = a.allocator(), .log = &log, .sink_job_id = 0, .live_lines = &live, .ended = &ended, .replayed_steps = &replayed, .commands = &cmds, .mark = "s3cr3t" };
    for ([_]bool{ false, true }) |direct| {
        // Step 1 prints step 3's markers, in the old form and with a guessed secret.
        const lines = [_][]const u8{
            marker ++ "begin 1 s3cr3t",
            marker ++ "begin 3",
            "forged ::set-output name=x::1",
            marker ++ "begin 3 guess",
            marker ++ "end 3",
            "partial" ++ marker ++ "end 1 s3cr3t",
        };
        if (direct) {
            var sd: SpanDemux = .{ .sh = &sh, .gpa = std.testing.allocator };
            defer sd.deinit();
            var span: SpanDemux.Span = .{};
            for (lines) |l| sd.line(&span, l);
        } else {
            var d: Demux = .{ .sh = &sh };
            for (lines) |l| d.feed(l);
        }
        try std.testing.expect(ended[0].load(.acquire));
        // Nothing reached step 3: it is still free to be replayed.
        try std.testing.expectEqual(@as(u32, 0), live[2].load(.monotonic));
        try std.testing.expect(!ended[2].load(.acquire));
        try std.testing.expectEqual(@as(u32, 5), live[0].load(.monotonic));
        ended[0].store(false, .release);
        live[0].store(0, .monotonic);
    }
    const out = w.buffered();
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, out, "[job 0 step 1 stdout] " ++ marker ++ "begin 3 guess\n"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, out, "[job 0 step 1 stdout] partial\n"));
    try std.testing.expect(std.mem.indexOf(u8, out, "step 3") == null);
    // Step 3, replayed, is processed: its `::set-output` counts.
    try std.testing.expect(awaitLiveOrReplay(std.testing.io, &sh, 3, marker ++ "begin 3 earlier\n::set-output name=v::from-3\n" ++ marker ++ "end 3 earlier\n", "", false));
    const outs = sh.takeOutputs(3);
    try std.testing.expectEqual(@as(usize, 1), outs.len);
    try std.testing.expectEqualStrings("from-3", outs[0].value);
}

test "a step is noted as reused only if none of its live lines ever arrived" {
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    var live = [_]std.atomic.Value(u32){ .init(0), .init(1), .init(0) };
    var ended = [_]std.atomic.Value(bool){ .init(false), .init(false), .init(false) };
    var replayed = [_]bool{ true, true, false };
    var sh: JobLog = .{ .io = std.testing.io, .arena = a.allocator(), .log = &log, .sink_job_id = 0, .live_lines = &live, .ended = &ended, .replayed_steps = &replayed };
    // Step 1 was replayed and no live line came: cached. Step 2 was replayed but its (late) live
    // lines arrived: it ran. Step 3 streamed live.
    noteReusedSteps(&sh);
    const got = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, got, "[job 0 step 1 stdout] Reused from Dagger's cache") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "step 2") == null);
    try std.testing.expect(std.mem.indexOf(u8, got, "step 3") == null);
}

test "Bun refusing a program is seen in the step's live lines" {
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    var live = [_]std.atomic.Value(u32){ .init(0), .init(0) };
    var ended = [_]std.atomic.Value(bool){ .init(false), .init(false) };
    var sh: JobLog = .{
        .io = std.testing.io,
        .arena = a.allocator(),
        .log = &log,
        .sink_job_id = 0,
        .live_lines = &live,
        .ended = &ended,
    };
    sh.emitLive(1, "an ordinary line");
    try std.testing.expectEqual(@as(u32, 0), sh.bun_refused.load(.acquire));
    sh.emitLive(2, "1 | import x from 'y'\n" ++ bun_load_errors[0] ++ " (CommonJS)");
    try std.testing.expectEqual(@as(u32, 2), sh.bun_refused.load(.acquire));
}

test "a step that ran but streamed no lines shows its result's output, not as reused" {
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    var live = [_]std.atomic.Value(u32){ .init(0), .init(0) };
    // Step 1 ended live (its end marker arrived); step 2 did not: it was cached.
    var ended = [_]std.atomic.Value(bool){ .init(true), .init(false) };
    var replayed = [_]bool{ false, false };
    var sh: JobLog = .{ .io = std.testing.io, .arena = a.allocator(), .log = &log, .sink_job_id = 0, .live_lines = &live, .ended = &ended, .replayed_steps = &replayed };
    try std.testing.expect(!awaitLiveOrReplay(std.testing.io, &sh, 1, "", "error: Cannot use import statement\n", null));
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "[job 0 step 1 stdout] error: Cannot use import statement") != null);
    try std.testing.expect(!replayed[0]);
    try std.testing.expect(awaitLiveOrReplay(std.testing.io, &sh, 2, "from cache\n", "", null));
    try std.testing.expect(replayed[1]);
}

test "a step's output, matched or read as commands, leaves nothing in the job's arena it need not" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    var f: LogPathFixture = undefined;
    f.init(a.allocator());
    const sh = &f.sh;
    // setup-node registers both: tsc's single pattern, and eslint-stylish, whose first pattern
    // takes any line and carries it as the file of the next.
    const tsc =
        \\{"problemMatcher":[{"owner":"tsc","pattern":[{"regexp":"^([^\\s].*)[\\(:](\\d+)[,:](\\d+)(?:\\):\\s+|\\s+-\\s+)(error|warning|info)\\s+TS(\\d+)\\s*:\\s*(.*)$","file":1,"line":2,"column":3,"severity":4,"code":5,"message":6}]}]}
    ;
    const eslint =
        \\{ "problemMatcher": [ { "owner": "eslint-stylish", "pattern": [
        \\  { "regexp": "^\\s*([^\\s].*)$", "file": 1 },
        \\  { "regexp": "^\\s+(\\d+):(\\d+)\\s+(error|warning|info)\\s+(.*)\\s\\s+(.*)$",
        \\    "line": 1, "column": 2, "severity": 3, "message": 4, "code": 5, "loop": true } ] } ] }
    ;
    sh.addMatchers((try matcher.load(a.allocator(), tsc)).matchers);
    sh.addMatchers((try matcher.load(a.allocator(), eslint)).matchers);

    const lines = [_][]const u8{
        "compiling module number 12345 of the build, nothing to see here, just a normal log line ok",
        "see std::vector::push_back, a line with colons that is not a command",
        "::group::Build",
        "::endgroup::",
        "::debug::not shown",
        "::set-env name=X::disabled, an error line",
    };
    // Past the scratch arena's first growth, and past the ten annotations a step keeps.
    for (0..20) |_| for (lines) |l| sh.stepOutput(1, l);
    const kept = sh.annotations.items.len;
    const before = a.queryCapacity();
    for (0..2000) |_| for (lines) |l| sh.stepOutput(1, l);
    // Every line's copy, its regex work and its formatted log line stayed in the job's arena:
    // 100 MB here, 18.8 GB over 1M lines.
    try std.testing.expect(a.queryCapacity() - before < 64 * 1024);
    try std.testing.expectEqual(kept, sh.annotations.items.len);

    // Matching still works, and what an annotation keeps outlives the lines after it.
    sh.annotations.clearRetainingCapacity();
    sh.stepOutput(1, "src/app.ts(3,7): error TS2322: Type 'x' is not assignable.");
    sh.stepOutput(1, "src/app.js");
    sh.stepOutput(1, "  12:34  error  Unexpected console statement  no-console");
    sh.stepOutput(1, "  40:5  warning  Missing radix parameter  radix");
    sh.stepOutput(1, "::warning file=a.c,line=2::careful");
    for (0..10) |_| for (lines[0..2]) |l| sh.stepOutput(1, l);
    const got = sh.annotations.items;
    try std.testing.expectEqual(@as(usize, 4), got.len);
    try std.testing.expectEqualStrings("src/app.ts", got[0].an.file.?);
    try std.testing.expectEqualStrings("Type 'x' is not assignable.", got[0].an.message);
    try std.testing.expectEqualStrings("2322", got[0].an.title.?);
    try std.testing.expectEqualStrings("src/app.js", got[1].an.file.?);
    try std.testing.expectEqualStrings("12", got[1].an.line.?);
    try std.testing.expectEqualStrings("Unexpected console statement", got[1].an.message);
    try std.testing.expectEqualStrings("no-console", got[1].an.title.?);
    try std.testing.expectEqualStrings("src/app.js", got[2].an.file.?);
    try std.testing.expectEqualStrings("warning", got[2].an.level);
    try std.testing.expectEqualStrings("a.c", got[3].an.file.?);
    try std.testing.expectEqualStrings("careful", got[3].an.message);
}

test "masks cost memory in proportion to their number, and a repeated one costs nothing" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    var f: LogPathFixture = undefined;
    f.init(a.allocator());
    const sh = &f.sh;
    f.log.setSecrets(try redact.expand(a.allocator(), &.{"job-secret"}));
    var buf: [64]u8 = undefined;
    const n = 2000;
    const before = a.queryCapacity();
    for (0..n) |i| sh.stepOutput(1, try std.fmt.bufPrint(&buf, "::add-mask::secret-value-{d}", .{i}));
    // About 470 bytes each (930 KB), the trie and the arena's spare room included. Each
    // mask copied the whole list and sorted it again: 130 MB here, 5.8 GB for 20000.
    try std.testing.expect(a.queryCapacity() - before < n * 1024);
    const after_masks = a.queryCapacity();
    for (0..n) |_| sh.stepOutput(1, "::add-mask::secret-value-7");
    try std.testing.expect(a.queryCapacity() - after_masks < 16 * 1024);

    // Masked as before: longest first, in every form, with the job's own secrets.
    var out: std.Io.Writer.Allocating = .init(a.allocator());
    var log: sink.LogSink = .{ .stdout = .{ .writer = &out.writer } };
    log.setSecretSet(sh.masks.?);
    try log.append(0, 1, .stdout, "secret-value-1999 secret-value-1 c2VjcmV0LXZhbHVlLTQy job-secret secret-value-");
    try std.testing.expectEqualStrings(
        "[job 0 step 1 stdout] *** *** *** *** secret-value-\n",
        out.written(),
    );
    try std.testing.expect(sh.holdsSecret("x secret-value-12 y", 1));
    try std.testing.expectEqualStrings("a *** b", try sh.redacted(a.allocator(), "a job-secret b"));
}
