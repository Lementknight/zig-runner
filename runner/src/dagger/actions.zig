//! Actions (`uses:` steps): an action loaded (fetched once per job, or read from the workspace),
//! its inputs resolved, and run by kind, with composite actions' steps and nested actions run as
//! part of the step, and JavaScript actions' `pre` and `post` scripts run around the job's steps.

const std = @import("std");
const job_mod = @import("../job.zig");
const sink = @import("../sink.zig");
const expr = @import("../expr.zig");
const action = @import("../action.zig");
const Query = @import("query.zig").Query;
const Evaluator = @import("Evaluator.zig");
const Exec = @import("Exec.zig");
const SecretRef = @import("../dagger.zig").SecretRef;
const run = @import("../dagger.zig").run;
const gql = @import("../dagger.zig").gql;
const jsonFind = @import("../dagger.zig").jsonFind;
const jsonFindString = @import("../dagger.zig").jsonFindString;
const splitEnv = @import("../dagger.zig").splitEnv;
const withEntries = @import("../dagger.zig").withEntries;
const firstLine = @import("../dagger.zig").firstLine;
const logExitCode = @import("../dagger.zig").logExitCode;
const Outcome = @import("../dagger.zig").Outcome;
const Resolved = @import("../dagger.zig").Resolved;
const Mount = @import("../dagger.zig").Mount;
const skippedStep = @import("../dagger.zig").skippedStep;
const interpolateOptional = @import("../dagger.zig").interpolateOptional;
const envContext = @import("../dagger.zig").envContext;
const ActionOut = @import("Exec.zig").ActionOut;
const LoadResult = @import("Exec.zig").LoadResult;
const Loaded = @import("Exec.zig").Loaded;
const checkout = @import("checkout.zig");
const shellLine = @import("scripts.zig").shellLine;
const FakeSession = @import("testing.zig").FakeSession;
const fake_child = @import("testing.zig").fake_child;
const base_answer = @import("testing.zig").base_answer;
const exec = @import("testing.zig").exec;
const execFc = @import("testing.zig").execFc;
const testStep = @import("testing.zig").testStep;
const testJob = @import("testing.zig").testJob;
const treeAnswer = @import("testing.zig").treeAnswer;
const fileAnswer = @import("testing.zig").fileAnswer;
const usesStep = @import("testing.zig").usesStep;
const braceBalanced = @import("testing.zig").braceBalanced;

const Allocator = std.mem.Allocator;

/// GitHub's limit on composite actions inside composite actions.
const max_composite_depth = 9;

/// GitHub's error for an action it cannot resolve (verified next to `ubuntu-latest`): a missing
/// version names the action and the version, a repository it cannot see is "not found" by its
/// lower-case name. Dagger's message is kept for other failures (a network error).
fn unresolvedMessage(
    arena: Allocator,
    u: job_mod.Uses,
    msg: []const u8,
    own_repo: bool,
) ![]const u8 {
    if (std.mem.indexOf(u8, msg, "does not contain ref") != null)
        return std.fmt.allocPrint(
            arena,
            "Unable to resolve action `{s}/{s}@{s}`, unable to find version `{s}`",
            .{ u.owner, u.name, u.ref, u.ref },
        );
    if (checkout.looksLikeAuthFailure(msg)) {
        const repo = try std.ascii.allocLowerString(
            arena,
            try std.fmt.allocPrint(arena, "{s}/{s}", .{ u.owner, u.name }),
        );
        // GitHub can be given access to a private action elsewhere; this runner fetches it
        // anonymously.
        return std.fmt.allocPrint(
            arena,
            "Unable to resolve action {s}, repository not found{s}",
            .{ repo, if (own_repo) "" else " (or private: the job's GITHUB_TOKEN reads only " ++
                "the job's own repository)" },
        );
    }
    return std.fmt.allocPrint(
        arena,
        "Unable to resolve action `{s}/{s}@{s}`, {s}",
        .{ u.owner, u.name, u.ref, msg },
    );
}

/// `dir/name`; one of them alone when the other is empty.
fn joinPath(arena: Allocator, dir: []const u8, name: []const u8) ![]const u8 {
    if (dir.len == 0) return name;
    if (name.len == 0) return dir;
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, name });
}

/// `action.yml` when the directory has one, else `action.yaml`, else null.
fn actionFileName(data: std.json.Value) ?[]const u8 {
    const entries = jsonFind(data, "entries") orelse return null;
    if (entries != .array) return null;
    var found: ?[]const u8 = null;
    for (entries.array.items) |e| {
        if (e != .string) continue;
        if (std.mem.eql(u8, e.string, "action.yml")) return e.string;
        if (found == null and std.mem.eql(u8, e.string, "action.yaml")) found = e.string;
    }
    return found;
}

/// A `uses:` step that cannot run, with why, in the "Set up job" log.
fn loadFailed(arena: Allocator, comptime fmt: []const u8, args: anytype) !Exec.LoadResult {
    return .{ .failed = try std.fmt.allocPrint(arena, fmt, args) };
}

fn findInput(inputs: []const job_mod.Input, name: []const u8) ?job_mod.Template {
    for (inputs) |in| if (std.ascii.eqlIgnoreCase(in.name, name)) return in.value;
    return null;
}

/// Runs a `uses:` step: reads the action's metadata and, for a composite action, runs its steps
/// as part of step `num`. `caller` is the scope of the `uses:` step (for `with:` and defaults);
/// `step_env` and `step_secret` are its evaluated `env:`, which its steps inherit. `nested`: a
/// step of a composite action (loaded here, not with the job's own steps). Recursive through
/// composite actions' `uses:` steps, hence `anyerror`.
pub fn runAction(
    x: *Exec,
    num: u32,
    u: job_mod.Uses,
    caller: expr.Scope,
    step_env: []const job_mod.EnvVar,
    step_secret: []const SecretRef,
    nested: bool,
) anyerror!ActionOut {
    const arena = x.arena;
    const ev = x.ev;
    const loaded = try x.loadUses(num, u, nested);
    const act = switch (loaded) {
        .failed, .unresolved => |msg| return x.actionFailed(num, "{s}", .{msg}),
        .ok => |a| a,
    };

    const inputs = switch (try x.resolveInputs(num, act, u, caller, true)) {
        .failed => |out| return out,
        .ok => |in| in,
    };

    const steps = switch (act.meta.runs) {
        .composite => |st| st,
        .node => |nd| return x.runJs(num, act, u, nd, inputs, step_env, step_secret),
        .docker => |dk| return x.runDocker(num, act, u, dk, inputs, step_env, step_secret),
    };

    // GitHub allows composite actions nested 9 deep.
    if (x.depth >= max_composite_depth) return x.actionFailed(
        num,
        "{s}: composite actions can be nested at most {d} levels deep",
        .{ act.ref_label, max_composite_depth },
    );
    x.depth += 1;
    defer x.depth -= 1;

    // The action's steps see its own `inputs` and `steps`, and `github.action_path`; the job's
    // come back afterwards. GITHUB_ENV and GITHUB_PATH changes outlive the action, as on
    // GitHub.
    const saved_steps = ev.steps;
    const saved_inputs = ev.inputs;
    const saved_github = ev.github;
    const saved_failed = ev.job_failed;
    defer {
        ev.steps = saved_steps;
        ev.inputs = saved_inputs;
        ev.github = saved_github;
        ev.job_failed = saved_failed;
    }
    try x.enterAction(act, inputs);

    var outcome: CompositeOutcome = .{};
    const comp = CompositeRun{ .act = act, .step_env = step_env, .step_secret = step_secret };
    for (steps, 1..) |st, i| try x.runCompositeStep(num, comp, st, i, &outcome);

    // The action's outputs, evaluated against its own steps.
    const sc_out = try ev.scope(step_env);
    const outputs = try arena.alloc(job_mod.EnvVar, act.meta.outputs.len);
    for (act.meta.outputs, outputs) |o, *dst| dst.* = .{
        .name = o.name,
        .value = expr.interpolate(arena, o.value, sc_out) catch "",
    };
    return .{ .failed = outcome.failed, .exit_code = outcome.exit_code, .outputs = outputs };
}

/// Points the evaluator at a composite action: its `inputs`, an empty `steps`, and the
/// `github.action_*` entries. The caller saves and restores what this replaces.
/// A `uses:` step's action: a nested one is read without a "Set up job" line (the job's own
/// steps were listed there), a local one from the workspace.
pub fn loadUses(x: *Exec, num: u32, u: job_mod.Uses, nested: bool) !LoadResult {
    if (!nested) return x.loadFor(num, u);
    return if (u.local) x.loadLocal(u) else x.loadAction(u);
}

pub fn enterAction(x: *Exec, act: Loaded, inputs: []const expr.Value.Entry) !void {
    const ev = x.ev;
    ev.steps = .empty;
    ev.inputs = .{ .object = inputs };
    ev.github = try withEntries(x.arena, ev.github, &.{
        .{ .key = "action_path", .value = .{ .string = act.path } },
        .{ .key = "action_repository", .value = .{ .string = act.repository } },
        .{ .key = "action_ref", .value = .{ .string = act.ref } },
    });
    ev.job_failed = false;
}

/// What a composite action's steps run under: the action, and the `uses:` step's evaluated env,
/// which they inherit.
const CompositeRun = struct {
    act: Loaded,
    step_env: []const job_mod.EnvVar,
    step_secret: []const SecretRef,
};

/// Whether any step of a composite action failed without `continue-on-error`, and the first
/// non-zero exit code — what the action reports as its own.
const CompositeOutcome = struct {
    failed: bool = false,
    exit_code: i32 = 0,

    /// A step's result: recorded in the action's `steps` context, and in the outcome unless the
    /// step continues on error.
    fn record(
        o: *CompositeOutcome,
        ev: *Evaluator,
        arena: Allocator,
        ctx_id: []const u8,
        ok: bool,
        coe: bool,
        outputs: []const job_mod.EnvVar,
        code: i32,
    ) !void {
        try ev.steps.append(arena, .{
            .id = ctx_id,
            .outcome = if (ok) "success" else "failure",
            .conclusion = if (ok or coe) "success" else "failure",
            .outputs = outputs,
        });
        if (!ok and !coe) {
            o.failed = true;
            ev.job_failed = true;
            if (o.exit_code == 0) o.exit_code = code;
        }
    }
};

/// One step of a composite action, as part of step `num`: its env and condition evaluated in
/// the action's scope, then run as a nested `uses:` or as a script.
pub fn runCompositeStep(
    x: *Exec,
    num: u32,
    comp: CompositeRun,
    st: action.Step,
    i: usize,
    outcome: *CompositeOutcome,
) !void {
    const arena = x.arena;
    const ev = x.ev;
    const ctx_id = st.id orelse try std.fmt.allocPrint(arena, "__{d}", .{i});
    ev.diag = "";
    // The step's env is evaluated with the `uses:` step's env visible, then added to it.
    const sc_env = try ev.scope(comp.step_env);
    var nested_env: std.ArrayList(job_mod.EnvVar) = .empty;
    var env_error: ?[]const u8 = null;
    for (st.env) |e| {
        const v = expr.interpolate(arena, e.value, sc_env) catch {
            env_error = try std.fmt.allocPrint(arena, "could not evaluate env '{s}': {s}", .{
                e.name,
                ev.diag,
            });
            break;
        };
        try nested_env.append(arena, .{ .name = e.name, .value = v });
    }
    const all_env = try std.mem.concat(arena, job_mod.EnvVar, &.{
        comp.step_env,
        nested_env.items,
    });
    const sc = try ev.scope(all_env);
    const display = if (st.name) |nm|
        (expr.interpolate(arena, nm, sc) catch nm)
    else if (st.run) |r|
        firstLine(r)
    else
        st.uses orelse "";
    if (env_error) |msg| return x.nestedFailed(num, ctx_id, display, msg, outcome);

    const cond = st.condition orelse "success()";
    const go = expr.evalCondition(arena, cond, sc) catch {
        const msg = try std.fmt.allocPrint(arena, "could not evaluate the condition " ++
            "'{s}': {s}", .{ cond, ev.diag });
        return x.nestedFailed(num, ctx_id, display, msg, outcome);
    };
    if (!go) {
        try ev.steps.append(arena, skippedStep(ctx_id));
        return;
    }
    const coe = if (st.continue_on_error) |c|
        std.mem.eql(u8, expr.interpolate(arena, c, sc) catch "false", "true")
    else
        false;
    const step = NestedStep{
        .ctx_id = ctx_id,
        .display = display,
        .sc = sc,
        .all_env = all_env,
        .nested_env = nested_env.items,
        .coe = coe,
    };
    if (st.run) |run_text| {
        try x.runNestedScript(num, comp, st, step, run_text, outcome);
    } else {
        try x.runNestedUses(num, comp, st, step, outcome);
    }
}

/// A composite step once its env and condition are settled: its id in the `steps` context, how
/// it is shown, the scope it is evaluated in, its env, and whether it continues on error.
const NestedStep = struct {
    ctx_id: []const u8,
    display: []const u8,
    sc: expr.Scope,
    all_env: []const job_mod.EnvVar,
    nested_env: []const job_mod.EnvVar,
    coe: bool,
};

/// The `uses:` step's env, split into plain variables and Dagger secrets, on top of the
/// composite step's own.
pub fn nestedEnv(
    x: *Exec,
    comp: CompositeRun,
    nested_env: []const job_mod.EnvVar,
    plain: *std.ArrayList(job_mod.EnvVar),
    secret: *std.ArrayList(SecretRef),
) !void {
    const arena = x.arena;
    try plain.appendSlice(arena, comp.step_env);
    try secret.appendSlice(arena, comp.step_secret);
    splitEnv(
        arena,
        x.transport,
        x.job.*,
        &x.secrets,
        nested_env,
        plain,
        secret,
        &x.err_msg,
    ) catch return error.EngineFailed;
}

/// A composite action's `uses:` step: its `with:` is evaluated here, in the action's scope; it
/// inherits the env.
pub fn runNestedUses(
    x: *Exec,
    num: u32,
    comp: CompositeRun,
    st: action.Step,
    step: NestedStep,
    outcome: *CompositeOutcome,
) !void {
    const arena = x.arena;
    const ev = x.ev;
    var with: std.ArrayList(job_mod.Input) = .empty;
    for (st.with) |kv| {
        const v = expr.interpolate(arena, kv.value, step.sc) catch {
            const msg = try std.fmt.allocPrint(
                arena,
                "could not evaluate input '{s}': {s}",
                .{ kv.name, ev.diag },
            );
            return x.nestedFailed(num, step.ctx_id, step.display, msg, outcome);
        };
        try with.append(arena, .{ .name = kv.name, .value = .{ .lit = v } });
    }
    var plain: std.ArrayList(job_mod.EnvVar) = .empty;
    var secret: std.ArrayList(SecretRef) = .empty;
    try x.nestedEnv(comp, step.nested_env, &plain, &secret);
    const out = try x.runNested(
        num,
        step.ctx_id,
        st.uses.?,
        with.items,
        step.sc,
        plain.items,
        secret.items,
    );
    const code: i32 = if (out.exit_code != 0) out.exit_code else 1;
    try outcome.record(ev, arena, step.ctx_id, !out.failed, step.coe, out.outputs, code);
}

/// A composite action's `run:` step: the script, shell and working directory evaluated, its
/// header logged as the official runner logs it, then run with the action's files mounted.
pub fn runNestedScript(
    x: *Exec,
    num: u32,
    comp: CompositeRun,
    st: action.Step,
    step: NestedStep,
    run_text: []const u8,
    outcome: *CompositeOutcome,
) !void {
    const arena = x.arena;
    const ev = x.ev;
    const act = comp.act;
    const script = expr.interpolate(arena, run_text, step.sc) catch {
        const msg = try std.fmt.allocPrint(arena, "could not evaluate the script: {s}", .{
            ev.diag,
        });
        return x.nestedFailed(num, step.ctx_id, step.display, msg, outcome);
    };
    // Without a name, the step is shown by its command as it will run.
    const display = if (st.name == null) firstLine(script) else step.display;
    const shell = expr.interpolate(arena, st.shell.?, step.sc) catch st.shell.?;
    if (!job_mod.validShell(shell)) {
        const msg = try job_mod.unsupportedShell(arena, shell);
        return x.nestedFailed(num, step.ctx_id, display, msg, outcome);
    }
    const wd = interpolateOptional(arena, st.working_directory, step.sc);

    // Env that carries a secret goes in as a Dagger secret, the rest in the script.
    var plain: std.ArrayList(job_mod.EnvVar) = .empty;
    var secret: std.ArrayList(SecretRef) = .empty;
    try x.nestedEnv(comp, step.nested_env, &plain, &secret);
    try plain.appendSlice(arena, &[_]job_mod.EnvVar{
        .{ .name = "GITHUB_ACTION_PATH", .value = act.path },
        .{ .name = "GITHUB_ACTION_REPOSITORY", .value = act.repository },
        .{ .name = "GITHUB_ACTION_REF", .value = act.ref },
    });
    try x.logNestedRunHeader(num, display, script, shell, step.all_env);

    // The action's files are mounted once per job; its steps may change them, as on GitHub.
    const mounted = x.mounted_actions.contains(act.mount);
    const m = [_]Mount{.{ .dir = .{ .path = act.mount, .id = act.dir, .owner = x.dir_owner } }};
    const fc = x.next_fc;
    x.next_fc += 1;
    const resolved: Resolved = .{
        .run = .{
            .script = script,
            .shell = shell,
            .working_directory = wd,
            .env = plain.items,
        },
    };
    const mounts: []const Mount = if (mounted) &.{} else &m;
    const out = try x.execScript(num, fc, resolved, step.ctx_id, secret.items, mounts);
    try x.mounted_actions.put(arena, act.mount, {});
    if (out.code != 0) logExitCode(x.sh, num, out.code);
    try outcome.record(ev, arena, step.ctx_id, out.code == 0, step.coe, out.outputs, out.code);
}

/// As the official runner does: the command, folded away, then its shell and env.
pub fn logNestedRunHeader(
    x: *Exec,
    num: u32,
    display: []const u8,
    script: []const u8,
    shell: []const u8,
    all_env: []const job_mod.EnvVar,
) !void {
    const arena = x.arena;
    x.sh.append(num, try std.fmt.allocPrint(arena, "##[group]Run {s}", .{display}));
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, script, "\n"), '\n');
    while (lines.next()) |l| x.sh.append(num, l);
    x.sh.append(num, try shellLine(arena, shell));
    const shown_env = try envContext(arena, x.ev.job_env.items, all_env);
    if (shown_env.len > 0) {
        x.sh.append(num, "env:");
        for (shown_env) |e| x.sh.append(
            num,
            try std.fmt.allocPrint(arena, "  {s}: {s}", .{ e.name, firstLine(e.value) }),
        );
    }
    x.sh.append(num, "##[endgroup]");
}

/// A composite action's `uses:` step, run as part of step `num` like a step of the job: the
/// built-in checkout for actions/checkout, a `docker://` image, or a local or remote action
/// (which may be composite again). Nested actions' `pre` scripts do not run; their `post`
/// scripts do, at the end.
pub fn runNested(
    x: *Exec,
    num: u32,
    ctx_id: []const u8,
    uses_text: []const u8,
    with: []const job_mod.Input,
    caller: expr.Scope,
    step_env: []const job_mod.EnvVar,
    step_secret: []const SecretRef,
) anyerror!ActionOut {
    const parsed = action.parseUses(uses_text) orelse
        return x.actionFailed(num, "uses: {s} is not a valid action reference", .{uses_text});
    switch (parsed) {
        .docker => |image| return x.runImageStep(
            num,
            .{ .image = image, .inputs = with },
            caller,
            step_env,
            step_secret,
        ),
        .local => |raw| {
            const dir = job_mod.localActionPath(raw) orelse return x.actionFailed(
                num,
                "uses: {s}: a local action must be inside the workspace",
                .{raw},
            );
            return x.runAction(
                num,
                .{
                    .owner = "",
                    .name = "",
                    .path = dir,
                    .ref = "",
                    .inputs = with,
                    .local = true,
                },
                caller,
                step_env,
                step_secret,
                true,
            );
        },
        .repo => |r| {
            const is_checkout = std.ascii.eqlIgnoreCase(r.owner, "actions") and
                std.ascii.eqlIgnoreCase(r.name, "checkout") and r.path.len == 0;
            if (is_checkout) return x.runNestedCheckout(num, ctx_id, with);
            return x.runAction(
                num,
                .{
                    .owner = r.owner,
                    .name = r.name,
                    .path = r.path,
                    .ref = r.ref,
                    .inputs = with,
                },
                caller,
                step_env,
                step_secret,
                true,
            );
        },
    }
}

/// actions/checkout inside a composite action: the runner's built-in checkout, as for the job's
/// steps.
pub fn runNestedCheckout(
    x: *Exec,
    num: u32,
    ctx_id: []const u8,
    with: []const job_mod.Input,
) !ActionOut {
    const arena = x.arena;
    const kv = try arena.alloc(job_mod.EnvVar, with.len);
    for (with, kv) |in, *dst| dst.* = .{ .name = in.name, .value = in.value.lit };
    const co = switch (try job_mod.checkoutFromInputs(arena, kv)) {
        .ok => |c| c,
        .unsupported => |why| return x.actionFailed(num, "{s}", .{why}),
    };
    const f = try checkout.fetch(arena, x.transport, x.job.*, co, x.gitAuth());
    if (f.result == .failed) return x.actionFailed(num, "{s}", .{f.result.failed});
    const m = [_]Mount{.{ .dir = .{
        .path = f.mount,
        .id = f.result.dir,
        .owner = x.dir_owner,
    } }};
    const fc = x.next_fc;
    x.next_fc += 1;
    const out = try x.execScript(num, fc, .{ .checkout = f }, ctx_id, &.{}, &m);
    return .{ .failed = out.code != 0, .exit_code = out.code, .outputs = out.outputs };
}

/// The action's repository, loaded once per step, whether it loads or not: the `pre` pass at
/// the start of the job (as GitHub downloads every action in "Set up job") and the step itself
/// share it.
pub fn loadFor(x: *Exec, num: u32, u: job_mod.Uses) !LoadResult {
    if (x.loaded[num - 1]) |l| return l;
    const lr = if (u.local) try x.loadLocal(u) else try x.loadAction(u);
    x.loaded[num - 1] = lr;
    return lr;
}

/// Inputs: the step's `with:` values, else the defaults, evaluated where the `uses:` step is.
/// `warn`: log GitHub's warning about undeclared inputs (once, for the step itself).
pub fn resolveInputs(
    x: *Exec,
    num: u32,
    act: Loaded,
    u: job_mod.Uses,
    caller: expr.Scope,
    warn: bool,
) !union(enum) { ok: []const expr.Value.Entry, failed: ActionOut } {
    const arena = x.arena;
    const ev = x.ev;
    var inputs: std.ArrayList(expr.Value.Entry) = .empty;
    for (act.meta.inputs) |def| {
        var val: []const u8 = "";
        if (findInput(u.inputs, def.name)) |t| {
            ev.diag = "";
            val = ev.render(t, caller) catch return .{
                .failed = try x.actionFailed(num, "could not evaluate input '{s}': {s}", .{
                    def.name,
                    ev.diag,
                }),
            };
        } else if (def.default) |d| {
            ev.diag = "";
            val = expr.interpolate(arena, d, caller) catch return .{
                .failed = try x.actionFailed(num, "could not evaluate the default of " ++
                    "input '{s}': {s}", .{ def.name, ev.diag }),
            };
        }
        try inputs.append(arena, .{ .key = def.name, .value = .{ .string = val } });
    }
    // Like GitHub: warn about inputs the action does not declare, and pass them on anyway.
    var unexpected: std.ArrayList([]const u8) = .empty;
    for (u.inputs) |in| if (act.meta.input(in.name) == null) {
        try unexpected.append(arena, in.name);
        const val = ev.render(in.value, caller) catch "";
        try inputs.append(arena, .{ .key = in.name, .value = .{ .string = val } });
    };
    if (warn and unexpected.items.len > 0) {
        var valid: std.ArrayList([]const u8) = .empty;
        for (act.meta.inputs) |def| try valid.append(arena, def.name);
        x.sh.append(num, try std.fmt.allocPrint(arena, "Warning: Unexpected input(s) " ++
            "'{s}', valid inputs are ['{s}']", .{
            try std.mem.join(
                arena,
                "', '",
                unexpected.items,
            ),
            try std.mem.join(arena, "', '", valid.items),
        }));
    }
    return .{ .ok = inputs.items };
}

/// Runs a JavaScript action's `pre` script before the job's steps, when it has one and its
/// `pre-if` (default `always()`) holds. A failing `pre` fails the job, so later steps see
/// failure(). An action that cannot be loaded or evaluated here is left to its step, which
/// reports why.
pub fn runPre(x: *Exec, num: u32, step: job_mod.Step) !void {
    const u = step.action.uses;
    // A local action is read when its step runs, after the checkout; GitHub runs no `pre` for
    // it.
    if (u.local) return;
    const act = switch (try x.loadFor(num, u)) {
        .failed, .unresolved => return,
        .ok => |a| a,
    };
    const pre: []const u8, const pre_if: ?[]const u8 = switch (act.meta.runs) {
        .node => |nd| .{ nd.pre orelse return, nd.pre_if },
        .docker => |dk| .{ dk.pre_entrypoint orelse return, dk.pre_if },
        .composite => return,
    };
    const ev = x.ev;
    ev.diag = "";
    const sc0 = try ev.scope(&.{});
    const step_env = ev.renderEnv(step.env, sc0) catch return;
    const sc1 = try ev.scope(step_env);
    if (!(expr.evalCondition(x.arena, pre_if orelse "always()", sc1) catch false)) return;
    const inputs = switch (try x.resolveInputs(num, act, u, sc1, false)) {
        .failed => return,
        .ok => |in| in,
    };
    var plain: std.ArrayList(job_mod.EnvVar) = .empty;
    var secret: std.ArrayList(SecretRef) = .empty;
    x.splitStepEnv(step_env, &plain, &secret) catch return error.EngineFailed;
    // A step of its own, "Pre Run x@v1", logged under the next log step.
    const ls = x.next_log_step;
    x.next_log_step += 1;
    const started = std.Io.Clock.real.now(x.io).toMilliseconds();
    const pre_name = x.extraName("Pre", num, act) catch "Pre";
    x.startExtra(.pre, ls, pre_name, started);
    const env = plain.items;
    const sec = secret.items;
    const pre_out = switch (act.meta.runs) {
        .docker => |dk| blk: {
            const dr = try x.dockerRunFor(ls, act, u, dk, inputs, env, sec, pre) orelse
                break :blk null;
            break :blk try x.runContainer(ls, .pre, dr, &.{});
        },
        else => try x.runJsScript(ls, .pre, act, u, pre, inputs, env, sec, &.{}),
    };
    var ok = false;
    defer x.addExtra(.{
        .kind = .pre,
        .name = pre_name,
        .log_step = ls,
        .outcome = if (ok) .success else .failure,
        .started_ms = started,
        .completed_ms = std.Io.Clock.real.now(x.io).toMilliseconds(),
    }) catch {};
    const out = pre_out orelse {
        ev.job_failed = true;
        x.hook_failed = true;
        return;
    };
    x.pre_state[num - 1] = out.state;
    if (out.code != 0) {
        logExitCode(x.sh, ls, out.code);
        ev.job_failed = true;
        x.hook_failed = true;
    } else ok = true;
}

/// Runs the registered `post` scripts, last first, each when its `post-if` (default `always()`)
/// holds. A failing one fails the job; the steps' own results stay as they were.
pub fn runPosts(x: *Exec) !void {
    // Only posts follow a post, and they always run: keying them on its output gains nothing.
    x.output_keys = null;
    var i = x.posts.items.len;
    while (i > 0) {
        i -= 1;
        const p = x.posts.items[i];
        x.ev.diag = "";
        const sc = try x.ev.scope(&.{});
        if (!(expr.evalCondition(x.arena, p.condition, sc) catch true)) continue;
        // A step of its own, "Post Run x@v1", logged under the next log step.
        const ls = x.next_log_step;
        x.next_log_step += 1;
        const started = std.Io.Clock.real.now(x.io).toMilliseconds();
        x.startExtra(.post, ls, p.name, started);
        x.sh.append(ls, "Post job cleanup.");
        if (p.checkout) {
            try x.addExtra(.{
                .kind = .post,
                .name = p.name,
                .log_step = ls,
                .outcome = .success,
                .started_ms = started,
                .completed_ms = std.Io.Clock.real.now(x.io).toMilliseconds(),
            });
            continue;
        }
        const post_out = if (p.docker) |dr|
            try x.runContainer(ls, .post, dr, p.state)
        else
            try x.runJsScript(
                ls,
                .post,
                p.act,
                p.u,
                p.script,
                p.inputs,
                p.step_env,
                p.step_secret,
                p.state,
            );
        const ok = if (post_out) |out| out.code == 0 else false;
        try x.addExtra(.{
            .kind = .post,
            .name = p.name,
            .log_step = ls,
            .outcome = if (ok) .success else .failure,
            .started_ms = started,
            .completed_ms = std.Io.Clock.real.now(x.io).toMilliseconds(),
        });
        const out = post_out orelse {
            x.hook_failed = true;
            continue;
        };
        if (out.code != 0) {
            logExitCode(x.sh, ls, out.code);
            x.hook_failed = true;
            x.ev.job_failed = true;
        }
    }
}

/// Logs why one of a composite action's steps could not run, and fails the action.
pub fn nestedFailed(
    x: *Exec,
    num: u32,
    ctx_id: []const u8,
    display: []const u8,
    msg: []const u8,
    outcome: *CompositeOutcome,
) !void {
    x.sh.errorLine(num, try std.fmt.allocPrint(x.arena, "{s}: {s}", .{ display, msg }));
    try x.ev.steps.append(
        x.arena,
        .{ .id = ctx_id, .outcome = "failure", .conclusion = "failure", .outputs = &.{} },
    );
    outcome.failed = true;
    x.ev.job_failed = true;
    if (outcome.exit_code == 0) outcome.exit_code = 1;
}

/// A remote action, fetched once per job however many steps (or composite actions) use it, as
/// GitHub downloads each action once in "Set up job".
pub fn loadAction(x: *Exec, u: job_mod.Uses) !LoadResult {
    const key = try std.fmt.allocPrint(x.arena, "{s}/{s}/{s}@{s}", .{ u.owner, u.name, u.path, u.ref });
    if (x.actions.get(key)) |lr| return lr;
    const lr = try x.fetchAction(u);
    try x.actions.put(x.arena, key, lr);
    return lr;
}

/// Fetches the action's repository (Dagger's git support, cached by the engine) and reads its
/// `action.yml` or `action.yaml`.
pub fn fetchAction(x: *Exec, u: job_mod.Uses) !LoadResult {
    const arena = x.arena;
    const repository = try std.fmt.allocPrint(arena, "{s}/{s}", .{ u.owner, u.name });
    const sub = if (u.path.len > 0) try std.fmt.allocPrint(arena, "/{s}", .{u.path}) else "";
    const ref_label = try std.fmt.allocPrint(arena, "{s}{s}@{s}", .{ repository, sub, u.ref });
    // GITHUB_TOKEN reads only the job's own repository; other actions are fetched anonymously.
    const own_repo = std.mem.eql(u8, repository, x.job.github.repository);
    var msg: []const u8 = "";
    const tree_query = try x.actionTreeQuery(u, repository, own_repo);
    const data = gql(arena, x.transport, tree_query, &msg) catch
        return .{ .unresolved = try unresolvedMessage(arena, u, msg, own_repo) };
    const dir = jsonFindString(data, "id") orelse
        return loadFailed(arena, "could not fetch {s}: Dagger returned no tree", .{ref_label});
    const name = actionFileName(data) orelse
        return loadFailed(arena, "{s} has no action.yml or action.yaml", .{ref_label});

    const file_path = try joinPath(arena, u.path, name);
    var fq: Query = .init(arena);
    try fq.call("loadDirectoryFromID", .{ .id = dir });
    try fq.call("file", .{ .path = file_path });
    try fq.leaf("contents");
    const fdata = gql(arena, x.transport, try fq.finish(), &msg) catch
        return loadFailed(arena, "could not read {s} of {s}: {s}", .{ name, ref_label, msg });
    const text = jsonFindString(fdata, "contents") orelse
        return loadFailed(arena, "could not read {s} of {s}", .{ name, ref_label });

    const meta = switch (try action.parse(arena, text)) {
        .ok => |m| m,
        .invalid => |why| return loadFailed(arena, "{s} of {s} {s}", .{ name, ref_label, why }),
    };
    const mount = try std.fmt.allocPrint(arena, "/github/_actions/{s}/{s}", .{
        repository,
        u.ref,
    });
    return .{ .ok = .{
        .meta = meta,
        .dir = dir,
        .mount = mount,
        .path = try joinPath(arena, mount, u.path),
        .sub = u.path,
        .ref_label = ref_label,
        .sha = jsonFindString(data, "sha") orelse "",
        .repository = repository,
        .ref = u.ref,
    } };
}

/// The action's repository at its ref: the tree's id, the entries of the action's directory
/// (to find its metadata file), and the commit it resolved to. The job's token only for its
/// own repository.
pub fn actionTreeQuery(
    x: *Exec,
    u: job_mod.Uses,
    repository: []const u8,
    own_repo: bool,
) ![]const u8 {
    const arena = x.arena;
    const server = std.mem.trimEnd(u8, x.job.github.server_url, "/");
    const url = try std.fmt.allocPrint(arena, "{s}/{s}.git", .{ server, repository });
    const auth: ?[]const u8 = if (own_repo) x.gitAuth() else null;
    const auth_user: ?[]const u8 = if (auth != null) "x-access-token" else null;
    var q: Query = .init(arena);
    try q.call("git", .{ .url = url, .httpAuthUsername = auth_user, .httpAuthToken = auth });
    if (checkout.isSha(u.ref)) {
        try q.call("commit", .{ .id = u.ref });
    } else {
        try q.call("ref", .{ .name = u.ref });
    }
    try q.call("tree", .{ .depth = @as(u32, 1) });
    try q.leaf("id");
    try q.leafArgs(null, "entries", .{ .path = if (u.path.len > 0) u.path else "." });
    try q.close(1);
    try q.leafAs("sha", "commit");
    return q.finish();
}

/// Reads a local action (`uses: ./path`) from the workspace as the job's container has it now,
/// so the repository must have been checked out first (GitHub says the same). Nothing is
/// mounted: the action's files are already there.
pub fn loadLocal(x: *Exec, u: job_mod.Uses) !LoadResult {
    const arena = x.arena;
    const abs = if (u.path.len > 0) try std.fmt.allocPrint(
        arena,
        "{s}/{s}",
        .{ x.ev.workspace, u.path },
    ) else x.ev.workspace;
    const label = try std.fmt.allocPrint(arena, "./{s}", .{u.path});
    const missing = try std.fmt.allocPrint(
        arena,
        "Can't find 'action.yml' or 'action.yaml' under '{s}'. Did you forget to run " ++
            "actions/checkout before running your local action?",
        .{abs},
    );
    var q: Query = .init(arena);
    try q.call("loadContainerFromID", .{ .id = x.container_id });
    try q.call("directory", .{ .path = abs });
    try q.leaf("id");
    try q.leaf("entries");
    const doc = try q.finish();
    var msg: []const u8 = "";
    const data = gql(arena, x.transport, doc, &msg) catch return .{ .failed = missing };
    const dir = jsonFindString(data, "id") orelse return .{ .failed = missing };
    var file_name: ?[]const u8 = null;
    if (jsonFind(data, "entries")) |entries|
        if (entries == .array) for (entries.array.items) |e| {
            if (e != .string) continue;
            if (std.mem.eql(u8, e.string, "action.yml") or (file_name == null and
                std.mem.eql(u8, e.string, "action.yaml"))) file_name = e.string;
        };
    const name = file_name orelse return .{ .failed = missing };
    var fq: Query = .init(arena);
    try fq.call("loadDirectoryFromID", .{ .id = dir });
    try fq.call("file", .{ .path = name });
    try fq.leaf("contents");
    const fdoc = try fq.finish();
    const fdata = gql(arena, x.transport, fdoc, &msg) catch
        return .{ .failed = try std.fmt.allocPrint(
            arena,
            "could not read {s} of {s}: {s}",
            .{ name, label, msg },
        ) };
    const text = jsonFindString(fdata, "contents") orelse
        return loadFailed(arena, "could not read {s} of {s}", .{ name, label });
    const meta = switch (try action.parse(arena, text)) {
        .ok => |m| m,
        .invalid => |why| return .{ .failed = try std.fmt.allocPrint(
            arena,
            "{s} of {s} {s}",
            .{ name, label, why },
        ) },
    };
    try x.mounted_actions.put(arena, abs, {});
    return .{ .ok = .{
        .meta = meta,
        .dir = dir,
        .mount = abs,
        .path = abs,
        .ref_label = label,
    } };
}

test "a composite action runs its steps with its inputs, and its outputs reach later steps" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);

    const action_yml =
        \\inputs:
        \\  version:
        \\    default: latest
        \\  verb:
        \\    default: call
        \\outputs:
        \\  out:
        \\    value: ${{ steps.second.outputs.result }}-${{ inputs.version }}
        \\runs:
        \\  using: composite
        \\  steps:
        \\    - shell: bash
        \\      run: echo v=${{ inputs.version }} verb=${{ inputs.verb }} path=${{ github.action_path }}
        \\    - id: skipped
        \\      if: inputs.verb == 'nope'
        \\      shell: bash
        \\      run: echo never
        \\    - id: second
        \\      shell: sh
        \\      env:
        \\        X: ${{ inputs.version }}
        \\      run: echo "result=ok" >> "$GITHUB_OUTPUT"
    ;
    const inputs = [_]job_mod.Input{ .{ .name = "version", .value = .{ .lit = "0.21.10" } }, .{ .name = "bogus", .value = .{ .lit = "1" } } };
    var after = testStep("");
    after.action.script.script = .{ .expr = "format('echo {0}', steps.dag.outputs.out)" };
    const steps = [_]job_mod.Step{ usesStep("dag", "o", "act", "v1", &inputs), after };
    const answers = [_][]const u8{
        base_answer,
        try treeAnswer(arena, "D1", &.{ "README.md", "action.yml" }),
        try fileAnswer(arena, action_yml),
        try exec(arena, "C1", 0, ""),
        try execFc(arena, "C2", "", "result=ok\\n", "", ""),
        try exec(arena, "C3", 0, ""),
    };
    var fake: FakeSession = .{ .answers = &answers, .arena = arena };
    var buf: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    const res = try run(arena, std.testing.io, &env, .{ .test_session_argv = &.{ "sh", "-c", fake_child }, .test_transport = fake.transport() }, testJob(&steps), &log);

    try std.testing.expect(res.succeeded);
    try std.testing.expectEqual(Outcome.success, res.steps[0].outcome);
    const seen = fake.seen.items;
    try std.testing.expectEqual(@as(usize, 6), seen.len); // the skipped step never runs
    for (seen) |d| try std.testing.expect(braceBalanced(d));
    try std.testing.expect(std.mem.indexOf(u8, seen[1], "git(url:\"https://github.com/o/act.git\") { ref(name:\"v1\") { tree(depth:1) { id entries(path:\".\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen[2], "loadDirectoryFromID(id:\"D1\") { file(path:\"action.yml\")") != null);
    // First step: interpolated inputs (given and default) and action path; the action is mounted once.
    try std.testing.expect(std.mem.indexOf(u8, seen[3], "echo v=0.21.10 verb=call path=/github/_actions/o/act/v1") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen[3], "withDirectory(path:\"/github/_actions/o/act/v1\",source:\"D1\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen[3], "/github/file_commands/output_3") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen[4], "withDirectory") == null);
    try std.testing.expect(std.mem.indexOf(u8, seen[4], "'X=0.21.10'") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen[4], "'GITHUB_ACTION_PATH=/github/_actions/o/act/v1'") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen[4], "/github/file_commands/output_4") != null);
    // The action's output, built from its own step's output and input, reaches the next job step.
    try std.testing.expect(std.mem.indexOf(u8, seen[5], "echo ok-0.21.10") != null);
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "Warning: Unexpected input(s) 'bogus', valid inputs are ['version', 'verb']") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "##[group]Run echo v=0.21.10") != null);
}

test "action failures: an image that cannot be pulled, a missing action.yml, and a failing step with failure() cleanup" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);

    const failing_yml =
        \\runs:
        \\  using: composite
        \\  steps:
        \\    - shell: bash
        \\      run: exit 3
        \\    - if: failure()
        \\      shell: bash
        \\      run: echo cleanup
        \\    - shell: bash
        \\      run: echo not after a failure
    ;
    var s2 = usesStep("missing", "o", "none", "v1", &.{});
    s2.condition = "always()";
    var s3 = usesStep("fails", "o", "act2", "0123456789012345678901234567890123456789", &.{});
    s3.condition = "always()";
    const steps = [_]job_mod.Step{ usesStep("dock", "o", "dock", "v1", &.{}), s2, s3 };
    const answers = [_][]const u8{
        base_answer,
        try treeAnswer(arena, "D1", &.{"action.yml"}),
        try fileAnswer(arena, "runs:\n  using: docker\n  image: docker://nope:1\n"),
        try treeAnswer(arena, "D2", &.{"README.md"}),
        try treeAnswer(arena, "D3", &.{"action.yaml"}),
        try fileAnswer(arena, failing_yml),
        "{\"data\":{\"bb\":{\"from\":{\"file\":{\"id\":\"BB\"}}},\"empty\":{\"id\":\"EMPTY\"}}}",
        "{\"errors\":[{\"message\":\"pull access denied for nope\"}]}",
        try exec(arena, "C1", 3, ""),
        try exec(arena, "C2", 0, ""),
    };
    var fake: FakeSession = .{ .answers = &answers, .arena = arena };
    var buf: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    const res = try run(arena, std.testing.io, &env, .{ .test_session_argv = &.{ "sh", "-c", fake_child }, .test_transport = fake.transport() }, testJob(&steps), &log);

    try std.testing.expect(!res.succeeded);
    try std.testing.expectEqual(Outcome.failure, res.steps[0].outcome);
    try std.testing.expectEqual(Outcome.failure, res.steps[1].outcome);
    try std.testing.expectEqual(Outcome.failure, res.steps[2].outcome);
    try std.testing.expectEqual(@as(i32, 3), res.steps[2].exit_code);
    const seen = fake.seen.items;
    try std.testing.expectEqual(@as(usize, 10), seen.len); // the step after the failure is skipped
    try std.testing.expect(std.mem.indexOf(u8, seen[4], "commit(id:\"0123456789012345678901234567890123456789\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen[5], "file(path:\"action.yaml\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen[9], "echo cleanup") != null);
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "could not pull nope:1 for o/dock@v1: pull access denied for nope") != null);
    // As GitHub's runner logs a script that exits non-zero.
    try std.testing.expect(std.mem.indexOf(u8, out, "##[error]Process completed with exit code 3.") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "o/none@v1 has no action.yml or action.yaml") != null);
}

test "a local action is read from the workspace when its step runs, and is not mounted" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);
    const action_yml =
        \\inputs:
        \\  who:
        \\    default: nobody
        \\runs:
        \\  using: composite
        \\  steps:
        \\    - shell: bash
        \\      run: echo "hi ${{ inputs.who }} from $GITHUB_ACTION_PATH (${{ github.action_repository }})"
    ;
    const inputs = [_]job_mod.Input{.{ .name = "who", .value = .{ .lit = "you" } }};
    var greet = usesStep("greet", "", "", "", &inputs);
    greet.action.uses.path = ".github/actions/greet";
    greet.action.uses.local = true;
    var missing = usesStep("missing", "", "", "", &.{});
    missing.action.uses.path = "nope";
    missing.action.uses.local = true;
    missing.condition = "always()";
    const steps = [_]job_mod.Step{ testStep("echo checkout"), greet, missing };
    const answers = [_][]const u8{
        base_answer,
        try exec(arena, "C1", 0, ""),
        "{\"data\":{\"loadContainerFromID\":{\"directory\":{\"id\":\"LD\",\"entries\":[\"action.yml\"]}}}}",
        try fileAnswer(arena, action_yml),
        try exec(arena, "C2", 0, ""),
        "{\"errors\":[{\"message\":\"lstat /home/runner/work/r/r/nope: no such file or directory\"}]}",
    };
    var fake: FakeSession = .{ .answers = &answers, .arena = arena };
    var buf: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    const res = try run(arena, std.testing.io, &env, .{ .test_session_argv = &.{ "sh", "-c", fake_child }, .test_transport = fake.transport() }, testJob(&steps), &log);
    const seen = fake.seen.items;
    try std.testing.expectEqual(@as(usize, 6), seen.len);
    for (seen) |d| try std.testing.expect(braceBalanced(d));
    // Read after the earlier step, from the container that step left; nothing is fetched up front.
    try std.testing.expect(std.mem.indexOf(u8, seen[2], "loadContainerFromID(id:\"C1\") { directory(path:\"/home/runner/work/r/r/.github/actions/greet\") { id entries } }") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen[3], "loadDirectoryFromID(id:\"LD\") { file(path:\"action.yml\")") != null);
    const run1 = seen[4];
    try std.testing.expect(std.mem.indexOf(u8, run1, "withDirectory") == null);
    try std.testing.expect(std.mem.indexOf(u8, run1, "hi you from $GITHUB_ACTION_PATH ()") != null);
    try std.testing.expect(std.mem.indexOf(u8, run1, "'GITHUB_ACTION_PATH=/home/runner/work/r/r/.github/actions/greet'") != null);
    try std.testing.expect(std.mem.indexOf(u8, run1, "'GITHUB_ACTION_REPOSITORY='") != null);
    try std.testing.expectEqual(Outcome.success, res.steps[1].outcome);
    try std.testing.expectEqual(Outcome.failure, res.steps[2].outcome);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "Can't find 'action.yml' or 'action.yaml' under '/home/runner/work/r/r/nope'. Did you forget to run actions/checkout") != null);
}

test "a composite action's uses: steps: nested actions, the built-in checkout, outputs, and the nesting limit" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);
    const outer_yml =
        \\inputs:
        \\  who:
        \\    default: nobody
        \\outputs:
        \\  greeting:
        \\    value: ${{ steps.inner.outputs.greeting }}
        \\runs:
        \\  using: composite
        \\  steps:
        \\    - id: inner
        \\      uses: o/inner@v1
        \\      with:
        \\        name: ${{ inputs.who }}
        \\    - uses: actions/checkout@v4
        \\      with:
        \\        path: sub
        \\    - shell: bash
        \\      run: echo "inner said ${{ steps.inner.outputs.greeting }}"
    ;
    const inner_yml =
        \\inputs:
        \\  name:
        \\    required: true
        \\outputs:
        \\  greeting:
        \\    value: ${{ steps.g.outputs.text }}
        \\runs:
        \\  using: composite
        \\  steps:
        \\    - id: g
        \\      shell: bash
        \\      run: echo "text=hello ${{ inputs.name }}" >> "$GITHUB_OUTPUT"
    ;
    const inputs = [_]job_mod.Input{.{ .name = "who", .value = .{ .lit = "zig" } }};
    var after = testStep("");
    after.action.script.script = .{ .expr = "format('echo {0}', steps.outer.outputs.greeting)" };
    const steps = [_]job_mod.Step{ usesStep("outer", "o", "outer", "v1", &inputs), after };
    const answers = [_][]const u8{
        base_answer,
        try treeAnswer(arena, "D1", &.{"action.yml"}),
        try fileAnswer(arena, outer_yml),
        // the nested action, loaded when its step runs
        try treeAnswer(arena, "D2", &.{"action.yml"}),
        try fileAnswer(arena, inner_yml),
        "{\"data\":{\"loadContainerFromID\":{\"withExec\":{\"id\":\"C1\",\"exitCode\":0,\"stdout\":\"\",\"stderr\":\"\",\"fc_output\":{\"contents\":\"text=hello zig\\n\"}}}}}",
        // the checkout
        "{\"data\":{\"git\":{\"commit\":{\"tree\":{\"id\":\"TREE1\"}}}}}",
        try exec(arena, "C2", 0, ""),
        try exec(arena, "C3", 0, ""),
        try exec(arena, "C4", 0, ""),
    };
    var fake: FakeSession = .{ .answers = &answers, .arena = arena };
    var buf: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    const res = try run(arena, std.testing.io, &env, .{ .test_session_argv = &.{ "sh", "-c", fake_child }, .test_transport = fake.transport() }, testJob(&steps), &log);
    try std.testing.expect(res.succeeded);
    const seen = fake.seen.items;
    try std.testing.expectEqual(@as(usize, 10), seen.len);
    for (seen) |d| try std.testing.expect(braceBalanced(d));
    try std.testing.expect(std.mem.indexOf(u8, seen[3], "git(url:\"https://github.com/o/inner.git\")") != null);
    // The nested action gets the outer action's input, and its own directory.
    try std.testing.expect(std.mem.indexOf(u8, seen[5], "withDirectory(path:\"/github/_actions/o/inner/v1\",source:\"D2\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen[5], "echo \\\"text=hello zig\\\"") != null);
    // actions/checkout is the built-in checkout, at its path.
    try std.testing.expect(std.mem.indexOf(u8, seen[7], "withDirectory(path:\"/home/runner/work/r/r/sub\",source:\"TREE1\")") != null);
    // Its outputs reach the outer action's steps and outputs, and the job's next step.
    try std.testing.expect(std.mem.indexOf(u8, seen[8], "inner said hello zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, seen[9], "echo hello zig") != null);

    // An action that uses itself stops at GitHub's limit of 9 levels; it is fetched once.
    const loop_yml = "runs:\n  using: composite\n  steps:\n    - uses: o/loop@v1\n";
    const loop_answers = [_][]const u8{
        base_answer,
        try treeAnswer(arena, "DL", &.{"action.yml"}),
        try fileAnswer(arena, loop_yml),
    };
    const loop_steps = [_]job_mod.Step{usesStep("loop", "o", "loop", "v1", &.{})};
    var fake2: FakeSession = .{ .answers = &loop_answers, .arena = arena };
    var buf2: [8192]u8 = undefined;
    var w2: std.Io.Writer = .fixed(&buf2);
    var log2: sink.LogSink = .{ .stdout = .{ .writer = &w2 } };
    const res2 = try run(arena, std.testing.io, &env, .{ .test_session_argv = &.{ "sh", "-c", fake_child }, .test_transport = fake2.transport() }, testJob(&loop_steps), &log2);
    try std.testing.expect(!res2.succeeded);
    try std.testing.expectEqual(@as(usize, 3), fake2.seen.items.len);
    try std.testing.expect(std.mem.indexOf(u8, w2.buffered(), "o/loop@v1: composite actions can be nested at most 9 levels deep") != null);
}

test "an action that cannot be resolved: GitHub's message" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const u: job_mod.Uses = .{ .owner = "astral-sh", .name = "setup-uv", .ref = "v10" };
    try std.testing.expectEqualStrings("Unable to resolve action `astral-sh/setup-uv@v10`, unable to find version `v10`", try unresolvedMessage(arena, u, "git error: repository does not contain ref \"v10\"", false));
    const missing: job_mod.Uses = .{ .owner = "Lementknight", .name = "No-Such", .ref = "v1" };
    try std.testing.expectEqualStrings("Unable to resolve action lementknight/no-such, repository not found (or private: the job's GITHUB_TOKEN reads only the job's own repository)", try unresolvedMessage(arena, missing, "git error: git authentication failed", false));
    try std.testing.expectEqualStrings("Unable to resolve action lementknight/no-such, repository not found", try unresolvedMessage(arena, missing, "git error: git authentication failed", true));
    try std.testing.expectEqualStrings("Unable to resolve action `astral-sh/setup-uv@v10`, dial tcp: i/o timeout", try unresolvedMessage(arena, u, "dial tcp: i/o timeout", false));
}

test "JavaScript pre and post: pre runs first and hands its state on, post-if is honoured, a failing pre fails the job" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);
    const action_yml =
        \\runs:
        \\  using: node24
        \\  pre: dist/pre.js
        \\  main: dist/main.js
        \\  post: dist/post.js
        \\  post-if: success()
    ;
    const pre_with_state = "{\"data\":{\"loadContainerFromID\":{\"withExec\":{\"id\":\"C1\",\"exitCode\":0,\"stdout\":\"\",\"stderr\":\"\",\"fc_state\":{\"contents\":\"fromPre=1\\n\"}}}}}";
    for ([_]bool{ false, true }) |pre_fails| {
        const steps = [_]job_mod.Step{ usesStep("act", "o", "act", "v1", &.{}), testStep("exit 1") };
        var job = testJob(&steps);
        job.secrets = &.{"ghs_jobtoken"};
        job.job_token = "ghs_jobtoken";
        var answers: std.ArrayList([]const u8) = .empty;
        try answers.appendSlice(arena, &.{
            base_answer,
            try treeAnswer(arena, "D1", &.{ "action.yml", "dist" }),
            try fileAnswer(arena, action_yml),
            "{\"data\":{\"container\":{\"from\":{\"bin\":{\"id\":\"BUN\"}}}}}",
            "{\"data\":{\"zsec0\":{\"id\":\"S1\"}}}",
        });
        if (pre_fails) {
            try answers.append(arena, try exec(arena, "C1", 1, ""));
        } else {
            try answers.appendSlice(arena, &.{
                pre_with_state,
                // main: the job token registered for pre is used again
                try exec(arena, "C2", 0, ""),
                try exec(arena, "C3", 1, ""), // the failing step: success() is false for the post
            });
        }
        var fake: FakeSession = .{ .answers = answers.items, .arena = arena };
        var buf: [4096]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
        const res = try run(arena, std.testing.io, &env, .{ .test_session_argv = &.{ "sh", "-c", fake_child }, .test_transport = fake.transport() }, job, &log);
        const seen = fake.seen.items;
        for (seen) |d| try std.testing.expect(braceBalanced(d));
        try std.testing.expect(!res.succeeded);
        try std.testing.expect(std.mem.indexOf(u8, seen[5], "/github/_actions/o/act/v1/dist/pre.js") != null);
        // The pre is a step of its own, logged after the job's two steps.
        try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "##[group]Pre") == null);
        try std.testing.expectEqual(@as(usize, 1), res.extra.len);
        try std.testing.expectEqual(@as(u32, 3), res.extra[0].log_step);
        try std.testing.expect(std.mem.startsWith(u8, res.extra[0].name, "Pre "));
        try std.testing.expectEqual(@as(u32, 4), res.next_log_step);
        if (pre_fails) {
            try std.testing.expectEqual(@as(usize, 6), seen.len);
            try std.testing.expectEqual(Outcome.failure, res.extra[0].outcome);
            try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "[job 0 step 3 stdout] ##[error]Process completed with exit code 1.") != null);
            try std.testing.expectEqual(Outcome.skipped, res.steps[0].outcome);
            try std.testing.expectEqual(Outcome.skipped, res.steps[1].outcome);
        } else {
            // main gets pre's state; no post after the failing step (post-if: success()).
            try std.testing.expectEqual(@as(usize, 8), seen.len);
            try std.testing.expect(std.mem.indexOf(u8, seen[6], "dist/main.js") != null);
            try std.testing.expect(std.mem.indexOf(u8, seen[6], "'STATE_fromPre=1'") != null);
            try std.testing.expect(std.mem.indexOf(u8, seen[6], "secret:\"S1\"") != null);
            try std.testing.expectEqual(Outcome.success, res.steps[0].outcome);
            try std.testing.expectEqual(Outcome.failure, res.steps[1].outcome);
            try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "Post o/act") == null);
            try std.testing.expectEqual(Outcome.success, res.extra[0].outcome);
        }
    }
}
