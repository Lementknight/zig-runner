//! Which jobs a runner will run. A runner on a machine that untrusted code must not reach (prod)
//! runs only jobs from trusted refs and events (`RUNNER_TRUSTED_REFS`, `RUNNER_TRUSTED_EVENTS`).
//! A pull request can name any runner's labels in `runs-on`, and a personal account's repository
//! has no runner groups to stop it, so the runner itself refuses: before any step runs, from the
//! github context that GitHub, not the workflow, wrote into the job.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Github = @import("job.zig").Github;

/// Why the job may not run here, or null when it may. `refs` is comma-separated, a trailing `*`
/// matching any rest (`refs/tags/v*`); empty trusts every job. Both the run's ref and the ref its
/// workflow file was read from must be trusted: an event can run a workflow from another ref.
pub fn refusal(
    arena: Allocator,
    refs: []const u8,
    events: []const u8,
    g: Github,
) Allocator.Error!?[]const u8 {
    if (refs.len == 0) return null;
    if (!listed(events, g.event_name)) return try std.fmt.allocPrint(
        arena,
        "This runner does not run jobs from '{s}' events (RUNNER_TRUSTED_EVENTS: {s}).",
        .{ g.event_name, events },
    );
    if (!listed(refs, g.ref)) return try std.fmt.allocPrint(
        arena,
        "This runner does not run jobs for '{s}' (RUNNER_TRUSTED_REFS: {s}).",
        .{ g.ref, refs },
    );
    const workflow = workflowRef(g.workflow_ref);
    if (!listed(refs, workflow)) return try std.fmt.allocPrint(
        arena,
        "This runner does not run workflows read from '{s}' (RUNNER_TRUSTED_REFS: {s}).",
        .{ workflow, refs },
    );
    return null;
}

/// `owner/repo/.github/workflows/ci.yml@refs/heads/main` -> `refs/heads/main`; empty without one.
fn workflowRef(workflow_ref: []const u8) []const u8 {
    const at = std.mem.lastIndexOfScalar(u8, workflow_ref, '@') orelse return "";
    return workflow_ref[at + 1 ..];
}

/// Whether `item` is in the comma-separated `list`, where an entry ending in `*` matches any rest.
fn listed(list: []const u8, item: []const u8) bool {
    if (item.len == 0) return false;
    var entries = std.mem.tokenizeScalar(u8, list, ',');
    while (entries.next()) |raw| {
        const entry = std.mem.trim(u8, raw, " ");
        if (entry.len == 0) continue;
        if (entry[entry.len - 1] == '*') {
            if (std.mem.startsWith(u8, item, entry[0 .. entry.len - 1])) return true;
        } else if (std.mem.eql(u8, entry, item)) return true;
    }
    return false;
}

const testing = std.testing;
const prod_refs = "refs/heads/main, refs/tags/v*";
const prod_events = "push,workflow_dispatch";

fn ctx(event: []const u8, ref: []const u8, workflow_ref: []const u8) Github {
    return .{ .event_name = event, .ref = ref, .workflow_ref = workflow_ref };
}

test "no trusted refs: every job runs" {
    const wf = "o/r/.github/workflows/ci.yml@";
    const g = ctx("pull_request", "refs/pull/7/merge", wf ++ "refs/pull/7/merge");
    try testing.expectEqual(null, try refusal(testing.allocator, "", prod_events, g));
}

test "a push to main, a dispatch and a version tag run" {
    const wf = "o/r/.github/workflows/ci.yml@";
    const ok = [_]Github{
        ctx("push", "refs/heads/main", wf ++ "refs/heads/main"),
        ctx("workflow_dispatch", "refs/heads/main", wf ++ "refs/heads/main"),
        ctx("push", "refs/tags/v1.2.3", wf ++ "refs/tags/v1.2.3"),
    };
    for (ok) |g| {
        try testing.expectEqual(null, try refusal(testing.allocator, prod_refs, prod_events, g));
    }
}

test "pull requests, other branches and workflows from elsewhere are refused" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const wf = "o/r/.github/workflows/ci.yml@";
    const refused = [_]Github{
        // A pull request's workflow file is the pull request's own.
        ctx("pull_request", "refs/pull/7/merge", wf ++ "refs/pull/7/merge"),
        // Runs on main's ref, but is not a trusted event.
        ctx("pull_request_target", "refs/heads/main", wf ++ "refs/heads/main"),
        // Anyone who can push a branch can dispatch on it.
        ctx("workflow_dispatch", "refs/heads/mine", wf ++ "refs/heads/mine"),
        ctx("push", "refs/heads/maintenance", wf ++ "refs/heads/maintenance"),
        ctx("push", "refs/tags/x1", wf ++ "refs/tags/x1"),
        // The ref is trusted, the workflow file's is not (or is missing).
        ctx("push", "refs/heads/main", wf ++ "refs/heads/mine"),
        ctx("push", "refs/heads/main", ""),
        ctx("", "", ""),
    };
    for (refused) |g| try testing.expect(try refusal(a, prod_refs, prod_events, g) != null);
    const why = (try refusal(a, prod_refs, prod_events, refused[0])).?;
    try testing.expect(std.mem.indexOf(u8, why, "'pull_request' events") != null);
}
