//! "Set up job": the base container the job's steps start from (the image, provisioning of the
//! default image, the workspace, package cache volumes and the job's env), built in one query
//! with the job's actions loaded, and the `Exec` the steps run with.

const std = @import("std");
const job_mod = @import("../job.zig");
const sink = @import("../sink.zig");
const expr = @import("../expr.zig");
const config = @import("../config.zig");
const Query = @import("query.zig").Query;
const JobLog = @import("JobLog.zig");
const Evaluator = @import("Evaluator.zig");
const Exec = @import("Exec.zig");
const Transport = @import("../dagger.zig").Transport;
const SecretRef = @import("../dagger.zig").SecretRef;
const Secrets = @import("../dagger.zig").Secrets;
const Options = @import("../dagger.zig").Options;
const Outcome = @import("../dagger.zig").Outcome;
const StepResult = @import("../dagger.zig").StepResult;
const Result = @import("../dagger.zig").Result;
const run = @import("../dagger.zig").run;
const gql = @import("../dagger.zig").gql;
const jsonFind = @import("../dagger.zig").jsonFind;
const jsonFindString = @import("../dagger.zig").jsonFindString;
const splitEnv = @import("../dagger.zig").splitEnv;
const containsSecret = @import("../dagger.zig").containsSecret;
const envVarNode = @import("../dagger.zig").envVarNode;
const isVolatile = @import("../dagger.zig").isVolatile;
const logSteps = @import("../dagger.zig").logSteps;
const finish = @import("../dagger.zig").finish;
const default_image = @import("../dagger.zig").default_image;
const work_root = @import("../dagger.zig").work_root;
const runner_user = @import("../dagger.zig").runner_user;
const runner_home = @import("../dagger.zig").runner_home;
const docker_home = @import("../dagger.zig").docker_home;
const event_path = @import("../dagger.zig").event_path;
const event_env = @import("../dagger.zig").event_env;
const ran_env = @import("../dagger.zig").ran_env;
const mark_env = @import("../dagger.zig").mark_env;
const registryCredentials = @import("docker.zig").registryCredentials;
const registryAuth = @import("docker.zig").registryAuth;
const outputKeysKey = @import("output_keys.zig").outputKeysKey;
const FakeSession = @import("testing.zig").FakeSession;
const fake_child = @import("testing.zig").fake_child;
const base_answer = @import("testing.zig").base_answer;
const exec = @import("testing.zig").exec;
const testStep = @import("testing.zig").testStep;
const testJob = @import("testing.zig").testJob;
const usesStep = @import("testing.zig").usesStep;
const braceBalanced = @import("testing.zig").braceBalanced;

const Allocator = std.mem.Allocator;

/// What the default image (`ubuntu:24.04`) gets before a job: what workflows written for GitHub's
/// `ubuntu-latest` most often assume without a setup action. `sudo` (steps run as `runner_user`, as
/// on GitHub, and many call `sudo apt-get`), compilers and `make`, Python with pip and venv (and
/// `python`), `psql` for a Postgres service, archive and transfer tools, and what composite actions
/// often use (`jq`, `curl`). Installed once per engine: Dagger caches this exec, so only the first
/// job pays for it.
pub const provision_packages = [_][]const u8{
    "git",            "git-lfs",     "ca-certificates", "curl",              "wget",
    "xz-utils",       "bzip2",       "zstd",            "zip",               "unzip",
    "jq",             "sudo",        "gnupg",           "openssh-client",    "rsync",
    "file",           "lsb-release", "tzdata",          "build-essential",   "pkg-config",
    "python3",        "python3-pip", "python3-venv",    "python-is-python3", "postgresql-client",
    "netcat-openbsd", "procps",
};

pub const provision_script = "apt-get update -qq && DEBIAN_FRONTEND=noninteractive " ++
    "apt-get install -y -qq --no-install-recommends " ++ packageList() ++
    " >/dev/null && rm -rf /var/lib/apt/lists/*";

const chown_runner = " && chown -R " ++ runner_user ++ ":" ++ runner_user ++ " " ++ work_root;

const provision_runner_script = provision_script ++
    " && (id -u " ++ runner_user ++ " >/dev/null 2>&1 || " ++
    "useradd -m -u 1001 -s /bin/bash " ++ runner_user ++ ")" ++
    " && printf '%s\\n' '" ++ runner_user ++ " ALL=(ALL) NOPASSWD:ALL' > " ++
    "/etc/sudoers.d/" ++ runner_user ++ " && chmod 0440 /etc/sudoers.d/" ++ runner_user ++
    " && mkdir -p " ++ work_root ++ " " ++ docker_home ++ runnerCacheDirs() ++
    " && chown -R " ++ runner_user ++ ":" ++ runner_user ++ " /github " ++ runner_home;

/// The package caches' directories under the user's home, made in advance: Dagger creates a cache
/// mount's missing parents as root (`/home/runner/go` for `/home/runner/go/pkg/mod`), and then the
/// user could not create anything next to the mount (setup-go's `~/go/bin`).
fn runnerCacheDirs() []const u8 {
    comptime {
        var out: []const u8 = "";
        for (package_cache_dirs) |d| {
            if (std.mem.startsWith(u8, d.path, "/root/"))
                out = out ++ " " ++ runner_home ++ d.path["/root".len..];
        }
        return out ++ " " ++ runner_home ++ "/.cache/yarn";
    }
}

/// Where package cache `i` is mounted for steps that run as `runner_user`: its directory under the
/// user's home instead of root's.
fn runnerCachePath(arena: Allocator, i: usize) ![]const u8 {
    const p = package_cache_dirs[i].path;
    if (std.mem.startsWith(u8, p, "/root/"))
        return std.mem.concat(arena, u8, &.{ runner_home, p["/root".len..] });
    // Yarn's cache is under /usr/local/share for root, in the home directory for anyone else.
    if (std.mem.eql(u8, package_cache_dirs[i].name, "yarn")) return runner_home ++ "/.cache/yarn";
    return p;
}

/// Where Zig's local cache (`.zig-cache`) is mounted with `zig_local_cache`, instead of the workspace,
/// which goes with the job. The volume is per repository (and apart for forks' pull requests), and
/// Zig locks its cache entries, so jobs running at once share it safely.
fn zigLocalCacheDir(as_runner: bool) []const u8 {
    return if (as_runner) runner_home ++ "/.cache/zig-local" else "/root/.cache/zig-local";
}

/// Where uv's project environment goes with `uv_env_in_cache`: inside its own cache volume, the
/// only place a hardlink from that cache can reach (every mount is its own device, even two of one
/// volume). Keyed by the ref, so jobs on different branches do not reconcile one environment to
/// their own lockfiles in turn, and concurrent jobs on one branch want the same state anyway. Never
/// with step caching (see `uvEnvFor`).
fn uvEnvPath(arena: Allocator, cache_path: []const u8, ref: []const u8) ![]const u8 {
    var key: std.ArrayList(u8) = .empty;
    for (if (ref.len > 0) ref else "default") |c| {
        try key.append(
            arena,
            if (std.ascii.isAlphanumeric(c) or c == '.' or c == '-' or c == '_') c else '-',
        );
    }
    const trimmed = std.mem.trim(u8, key.items, "-");
    return std.fmt.allocPrint(
        arena,
        "{s}/zig-runner-envs/{s}",
        .{ cache_path, if (trimmed.len > 0) trimmed else "default" },
    );
}

fn packageList() []const u8 {
    comptime {
        var out: []const u8 = "";
        for (provision_packages, 0..) |p, n| out = out ++ (if (n == 0) "" else " ") ++ p;
        return out;
    }
}

fn writeEnvNodes(q: *Query, plain: []const job_mod.EnvVar, secret: []const SecretRef) !void {
    for (plain) |e| try q.call("withEnvVariable", .{ .name = e.name, .value = e.value });
    for (secret) |sr| try q.call("withSecretVariable", .{ .name = sr.name, .secret = sr.id });
}

/// Runs the job's steps once a session is up (through `dagger run` or directly).
/// What the base container is built from, decided before any query is sent.
const BasePlan = struct {
    job_image: []const u8,
    provision: bool,
    as_runner: bool,
    step_cache: bool,
    uv_env: ?[]const u8,
    cache_ids: []const []const u8,
    /// The volume for Zig's local cache, with `zig_local_cache`.
    zig_local: ?[]const u8 = null,
    /// The output-key store (`Exec.outputs_volume`), when the job setup's query asked for it.
    outputs_volume: ?[]const u8 = null,
    ran_marker: []const u8,
    /// The job's `mark_env` value (`JobLog.mark`).
    mark: []const u8,
    /// A `container:` job's own `env:` (`containerEnv`); empty for any other job.
    container_env: []const job_mod.EnvVar = &.{},
};

/// The container every step starts from, as one query: the job image behind its registry auth and
/// its own env, the provisioning exec, the workspace and user, the cache mounts, the event payload
/// and the job's environment. Each writer adds its calls to the query; `finish` closes them. On
/// failure the message is in `err_msg` and the caller fails the job with it.
pub fn baseContainerId(
    arena: Allocator,
    transport: Transport,
    ev: *Evaluator,
    job: job_mod.Job,
    plan: BasePlan,
    secrets: *Secrets,
    err_msg: *[]const u8,
) ![]const u8 {
    var q: Query = .init(arena);
    try q.open("container");
    try writeImage(&q, arena, transport, ev, job, plan, secrets, err_msg);
    try writeProvisionAndWorkspace(&q, arena, ev, plan);
    try writeCacheMounts(&q, arena, plan);
    try writeRunEnv(&q, ev, plan);
    try writeJobEnv(&q, arena, transport, ev, job, secrets, err_msg);
    try q.leaf("id");
    const data = gql(arena, transport, try q.finish(), err_msg) catch
        return error.BaseContainerFailed;
    return jsonFindString(data, "id") orelse {
        err_msg.* = "Dagger returned no container";
        return error.BaseContainerFailed;
    };
}

/// `from` the job image, behind a private registry's credentials when there are any, with a
/// container job's cache variables and its own `env:` set on it.
fn writeImage(
    q: *Query,
    arena: Allocator,
    transport: Transport,
    ev: *Evaluator,
    job: job_mod.Job,
    plan: BasePlan,
    secrets: *Secrets,
    err_msg: *[]const u8,
) !void {
    if (job.container) |jc| {
        // A private image: its registry's credentials.
        if (try registryAuth(
            arena,
            ev,
            transport,
            secrets,
            jc,
            plan.job_image,
            err_msg,
        )) |auth| {
            try q.call("withRegistryAuth", auth);
        } else if (err_msg.len > 0) return error.BaseContainerFailed;
    }
    try q.call("from", .{ .address = plan.job_image });
    // Before the container's env too, so its value (or the workflow's) wins.
    if (plan.zig_local != null) try q.call(
        "withEnvVariable",
        .{ .name = "ZIG_LOCAL_CACHE_DIR", .value = zigLocalCacheDir(plan.as_runner) },
    );
    if (job.container != null) for (plan.cache_ids, 0..) |_, i| {
        // Before the container's env, so its own value wins.
        if (package_cache_dirs[i].env.len == 0) continue;
        try q.call(
            "withEnvVariable",
            .{ .name = package_cache_dirs[i].env, .value = package_cache_dirs[i].path },
        );
    };
    // The container's env, as `docker create -e` sets it: every step sees it. What carries a
    // secret goes in as a Dagger secret, as the job's env does (#101).
    var plain: std.ArrayList(job_mod.EnvVar) = .empty;
    var secret: std.ArrayList(SecretRef) = .empty;
    splitEnv(
        arena,
        transport,
        job,
        null,
        secrets,
        plan.container_env,
        &plain,
        &secret,
        err_msg,
    ) catch
        return error.BaseContainerFailed;
    try writeEnvNodes(q, plain.items, secret.items);
}

/// A `container:` job's own `env:`, evaluated, without the names the job's env sets: those win
/// on GitHub (`docker exec -e` over `docker create -e`), and a secret variable and a plain one of
/// one name would leave it to the engine which of them a step sees. Null when it cannot be
/// evaluated (the reason in `ev.diag`).
fn containerEnv(arena: Allocator, ev: *Evaluator, job: job_mod.Job) !?[]const job_mod.EnvVar {
    const jc = job.container orelse return &.{};
    const env = ev.renderEnv(jc.env, try ev.scope(&.{})) catch return null;
    var out: std.ArrayList(job_mod.EnvVar) = .empty;
    for (env) |e| {
        for (ev.job_env.items) |j| {
            if (std.mem.eql(u8, j.name, e.name)) break;
        } else try out.append(arena, e);
    }
    return out.items;
}

/// Provisioning in the default image, the workspace and RUNNER_TEMP, the step user, and the
/// workdir.
fn writeProvisionAndWorkspace(q: *Query, arena: Allocator, ev: *Evaluator, plan: BasePlan) !void {
    if (plan.provision) {
        const script = if (plan.as_runner) provision_runner_script else provision_script;
        try q.call("withExec", .{ .args = &[_][]const u8{ "sh", "-c", script } });
    }
    // The job's workspace and RUNNER_TEMP, the step user's in the default image (cached per
    // repository). A job container's user may be unable to make them; its steps then report
    // that themselves.
    // With `uv_env_in_cache`, `.venv` in the workspace is a symlink to the environment in the
    // cache, so `uv run`, `.venv/bin/...` and `activate` all keep working. The link is made
    // here, before the checkout, which merges the repository over it and leaves it.
    const link = if (plan.uv_env) |e| try std.fmt.allocPrint(
        arena,
        " && ln -sfn {s} {s}/.venv",
        .{ e, ev.workspace },
    ) else "";
    const chown = if (plan.as_runner) chown_runner else "";
    const mk = if (plan.provision)
        try std.fmt.allocPrint(
            arena,
            "mkdir -p {s} {s}{s}{s}",
            .{ ev.workspace, ev.temp, link, chown },
        )
    else
        try std.fmt.allocPrint(
            arena,
            "mkdir -p {s} {s}{s} 2>/dev/null || true",
            .{ ev.workspace, ev.temp, link },
        );
    try q.call("withExec", .{ .args = &[_][]const u8{ "sh", "-c", mk } });
    if (plan.as_runner) {
        try q.call("withUser", .{ .name = runner_user });
        try q.call("withEnvVariable", .{ .name = "HOME", .value = runner_home });
    }
    try q.call("withWorkdir", .{ .path = ev.workspace });
}

/// One cache volume mount per package manager, owned by the step user when steps run as it.
fn writeCacheMounts(q: *Query, arena: Allocator, plan: BasePlan) !void {
    for (plan.cache_ids, 0..) |id, i| {
        const path = if (plan.as_runner) try runnerCachePath(
            arena,
            i,
        ) else package_cache_dirs[i].path;
        const owner: ?[]const u8 = if (plan.as_runner) runner_user else null;
        try q.call("withMountedCache", .{ .path = path, .cache = id, .owner = owner });
    }
    if (plan.zig_local) |id| try q.call("withMountedCache", .{
        .path = zigLocalCacheDir(plan.as_runner),
        .cache = id,
        .owner = if (plan.as_runner) runner_user else null,
    });
}

/// The values that identify this run: the event payload, the ran marker, uv's environment, and the
/// default variables — volatile under step caching, so they do not reach exec cache keys.
fn writeRunEnv(q: *Query, ev: *Evaluator, plan: BasePlan) !void {
    // The event payload, as on GitHub (actions read it through GITHUB_EVENT_PATH). It differs on
    // every run, so with step caching it travels in a volatile variable that each step writes to
    // the file; a payload too large for one variable is written into the container instead.
    const event = try ev.eventJson();
    if (plan.step_cache and event.len <= max_event_env) {
        try q.call("withVolatileVariable", .{ .name = event_env, .value = event });
    } else {
        try q.call("withNewFile", .{ .path = event_path, .contents = event });
    }
    if (plan.step_cache)
        try q.call("withVolatileVariable", .{ .name = ran_env, .value = plan.ran_marker });
    // Every step's markers carry it, with step caching or without (`mark_env`).
    try q.call(envVarNode(plan.step_cache), .{ .name = mark_env, .value = plan.mark });
    if (plan.uv_env) |e| {
        try q.call("withEnvVariable", .{ .name = "UV_PROJECT_ENVIRONMENT", .value = e });
        // The environment outlives the job, and `uv venv` refuses to replace one that exists
        // ("A virtual environment already exists at ..."), where on a hosted runner the
        // workspace is new every job and it always succeeds. This keeps `uv venv` meaning
        // "make me a fresh environment"; `uv sync` still reconciles the one that is there.
        try q.call("withEnvVariable", .{ .name = "UV_VENV_CLEAR", .value = "1" });
    }
    for (try ev.defaultEnv()) |e| {
        // Run-specific values do not take part in exec cache keys, so unchanged steps are reused.
        const node = envVarNode(plan.step_cache and isVolatile(e.name));
        try q.call(node, .{ .name = e.name, .value = e.value });
    }
}

/// Workflow- and job-level env is part of every step's environment; what carries a secret goes in
/// as a Dagger secret.
fn writeJobEnv(
    q: *Query,
    arena: Allocator,
    transport: Transport,
    ev: *Evaluator,
    job: job_mod.Job,
    secrets: *Secrets,
    err_msg: *[]const u8,
) !void {
    var plain: std.ArrayList(job_mod.EnvVar) = .empty;
    var secret: std.ArrayList(SecretRef) = .empty;
    splitEnv(
        arena,
        transport,
        job,
        null,
        secrets,
        ev.job_env.items,
        &plain,
        &secret,
        err_msg,
    ) catch
        return error.BaseContainerFailed;
    try writeEnvNodes(q, plain.items, secret.items);
}

/// The job's name as GitHub shows it: its display name, else its key in the workflow, else "job".
fn jobLabel(job: job_mod.Job) []const u8 {
    if (job.display_name.len > 0) return job.display_name;
    return if (job.github.job.len > 0) job.github.job else "job";
}

/// What the job runs in, decided before any step: the image, whether it is provisioned and steps
/// run as the runner user, uv's environment, the package cache volumes, and this job's run marker.
/// On failure the message is in `err_msg` and the caller fails the job with it.
pub fn basePlan(
    arena: Allocator,
    io: std.Io,
    transport: Transport,
    ev: *Evaluator,
    job: job_mod.Job,
    opts: Options,
    step_cache: bool,
    mark: []const u8,
    secrets: *Secrets,
    err_msg: *[]const u8,
) !BasePlan {
    // `container:` replaces the image every step runs in.
    const job_image: []const u8 = if (job.container) |jc| (ev.render(
        jc.image,
        try ev.scope(&.{}),
    ) catch "") else opts.image;
    if (job_image.len == 0) {
        err_msg.* = try std.fmt.allocPrint(arena, "container: has no image: {s}", .{ev.diag});
        return error.BaseContainerFailed;
    }
    const container_env = try containerEnv(arena, ev, job) orelse {
        err_msg.* = try std.fmt.allocPrint(
            arena,
            "could not evaluate the container's env: {s}",
            .{ev.diag},
        );
        return error.BaseContainerFailed;
    };
    const provision = opts.provision and std.mem.eql(u8, job_image, default_image);
    const as_runner = provision and opts.step_user == .runner;
    const ran_marker = opts.test_ran_marker orelse ran: {
        var raw: [12]u8 = undefined;
        io.random(&raw);
        break :ran try arena.dupe(u8, &std.fmt.bytesToHex(raw, .lower));
    };
    const volumes = try cacheVolumeIds(
        arena,
        transport,
        ev,
        job,
        opts,
        job_image,
        container_env,
        as_runner,
        step_cache,
        secrets,
        err_msg,
    );
    return .{
        .container_env = container_env,
        .job_image = job_image,
        .provision = provision,
        .as_runner = as_runner,
        .step_cache = step_cache,
        .uv_env = try uvEnvFor(arena, opts, job, as_runner, step_cache),
        .cache_ids = volumes.ids,
        .zig_local = volumes.zig_local,
        .outputs_volume = volumes.outputs,
        .ran_marker = ran_marker,
        .mark = mark,
    };
}

/// uv's project environment, inside its cache volume so uv can hardlink into it (see `uvEnvPath`).
/// Null when there is no cache volume to put it in, and when the job's steps are cached: a cache
/// volume's content is not part of a step's key and a replayed step's writes into one are not made
/// again, so a replayed `uv sync` would leave the environment another commit's job synced there,
/// and later steps would run against its dependencies (#70). Left in the workspace, the environment
/// is part of the container each step produces, and a replay restores it exactly; uv's download
/// and wheel cache stays in its volume, content-addressed and safe to share.
fn uvEnvFor(
    arena: Allocator,
    opts: Options,
    job: job_mod.Job,
    as_runner: bool,
    step_cache: bool,
) !?[]const u8 {
    if (!opts.uv_env_in_cache or !opts.package_caches or job.github.repository.len == 0)
        return null;
    if (step_cache) return null;
    const i = for (
        package_cache_dirs,
        0..,
    ) |d, n| (if (std.mem.eql(u8, d.name, "uv")) break n) else return null;
    const path = if (job.container != null)
        package_cache_dirs[i].path
    else if (as_runner)
        try runnerCachePath(arena, i)
    else
        package_cache_dirs[i].path;
    return try uvEnvPath(arena, path, job.github.ref);
}

const CacheVolumes = struct {
    ids: []const []const u8 = &.{},
    zig_local: ?[]const u8 = null,
    outputs: ?[]const u8 = null,
};

/// Package managers' caches persist across jobs in Dagger cache volumes (see `package_cache_dirs`):
/// one query asks for every volume's id, and for Zig's local cache's with `zig_local_cache`. None
/// when caches are off or there is no repository to key them by.
///
/// The same query registers the secrets the base container needs (`baseSecrets`) and, being sent
/// anyway, those the job's steps will (`stepSecrets`), and asks for the output-key store: one round
/// trip where each was one of its own. Without caches the secrets the base needs go in it alone;
/// with neither, nothing is sent. Should the query fail with secrets in it, it is sent again
/// without them, which are then registered when first needed, failing as they always did.
fn cacheVolumeIds(
    arena: Allocator,
    transport: Transport,
    ev: *Evaluator,
    job: job_mod.Job,
    opts: Options,
    job_image: []const u8,
    container_env: []const job_mod.EnvVar,
    as_runner: bool,
    step_cache: bool,
    secrets: *Secrets,
    err_msg: *[]const u8,
) !CacheVolumes {
    const caches = opts.package_caches and job.github.repository.len > 0;
    const needed = try baseSecrets(arena, ev, job, container_env);
    if (!caches and (try secrets.missing(arena, needed)).len == 0) return .{};
    const ahead = try std.mem.concat(arena, []const u8, &.{ needed, try stepSecrets(arena, job) });
    const pending = try secrets.missing(arena, ahead);
    const set_up: SetUpQuery = .{
        .ev = ev,
        .job = job,
        .opts = opts,
        .job_image = job_image,
        .as_runner = as_runner,
        .caches = caches,
        .outputs_key = try outputKeysKey(arena, ev, job, opts, step_cache),
    };
    var msg: []const u8 = "";
    if (try set_up.send(arena, transport, secrets, pending, &msg)) |v| return v;
    if (!caches) return .{};
    if (pending.len == 0) {
        err_msg.* = msg;
        return error.BaseContainerFailed;
    }
    return try set_up.send(arena, transport, secrets, &.{}, err_msg) orelse
        error.BaseContainerFailed;
}

/// `cacheVolumeIds`' query: the cache volumes with `caches`, the output-key store with
/// `outputs_key`, and the secrets asked for.
const SetUpQuery = struct {
    ev: *Evaluator,
    job: job_mod.Job,
    opts: Options,
    job_image: []const u8,
    as_runner: bool,
    caches: bool,
    outputs_key: ?[]const u8,

    /// Sends the query with `pending` registered. Null, with the reason in `err_msg`, when it
    /// failed or lacked an answer.
    fn send(
        u: SetUpQuery,
        arena: Allocator,
        transport: Transport,
        secrets: *Secrets,
        pending: []const []const u8,
        err_msg: *[]const u8,
    ) !?CacheVolumes {
        var q: Query = .init(arena);
        try secrets.write(arena, &q, pending);
        if (u.outputs_key) |key| {
            try q.callAs("cout", "cacheVolume", .{ .key = key });
            try q.leaf("id");
            try q.close(1);
        }
        if (u.caches) try writeCacheVolumes(&q, arena, u.ev, u.job, u.opts, u.job_image, u.as_runner);
        const data = gql(arena, transport, try q.finish(), err_msg) catch return null;
        if (!try secrets.read(arena, data, pending)) {
            err_msg.* = "Dagger returned no secret id";
            return null;
        }
        var out: CacheVolumes = .{};
        if (u.outputs_key != null)
            out.outputs = if (jsonFind(data, "cout")) |v| jsonFindString(v, "id") else null;
        if (!u.caches) return out;
        const no_volume = "Dagger returned no cache volume";
        const ids = try arena.alloc([]const u8, package_cache_dirs.len);
        for (ids, 0..) |*id, i| {
            const v = jsonFind(data, try std.fmt.allocPrint(arena, "c{d}", .{i})) orelse {
                err_msg.* = no_volume;
                return null;
            };
            id.* = jsonFindString(v, "id") orelse {
                err_msg.* = no_volume;
                return null;
            };
        }
        out.ids = ids;
        if (u.opts.zig_local_cache) {
            const v = jsonFind(data, "czl") orelse {
                err_msg.* = no_volume;
                return null;
            };
            out.zig_local = jsonFindString(v, "id") orelse {
                err_msg.* = no_volume;
                return null;
            };
        }
        return out;
    }
};

/// One `cacheVolume` per package manager (`c<i>`), and Zig's local cache's (`czl`).
fn writeCacheVolumes(
    q: *Query,
    arena: Allocator,
    ev: *Evaluator,
    job: job_mod.Job,
    opts: Options,
    job_image: []const u8,
    as_runner: bool,
) !void {
    const scope = try packageCacheScope(arena, ev, job.github.repository, opts.trusted);
    // Its own volume, so the engine can collect it (it only grows) without the global cache.
    if (opts.zig_local_cache) {
        const key = try std.fmt.allocPrint(
            arena,
            "zig-runner/{s}/{s}/zig-local{s}",
            .{ job.github.repository, scope, if (as_runner) "/" ++ runner_user else "" },
        );
        try q.callAs("czl", "cacheVolume", .{ .key = key });
        try q.leaf("id");
        try q.close(1);
    }
    for (package_cache_dirs, 0..) |d, i| {
        // The tool cache holds binaries built for one image (glibc or musl, its libraries), so
        // each image has its own.
        const key = if (std.mem.eql(u8, d.name, "toolcache"))
            try std.fmt.allocPrint(
                arena,
                "zig-runner/{s}/{s}/{s}/{s}",
                .{ job.github.repository, scope, d.name, job_image },
            )
        else
            try std.fmt.allocPrint(
                arena,
                "zig-runner/{s}/{s}/{s}",
                .{ job.github.repository, scope, d.name },
            );
        // Volumes root filled hold files `runner_user` cannot write: steps that run as it get
        // their own.
        const user_key = if (as_runner) try std.mem.concat(
            arena,
            u8,
            &.{ key, "/", runner_user },
        ) else key;
        try q.callAs(
            try std.fmt.allocPrint(arena, "c{d}", .{i}),
            "cacheVolume",
            .{ .key = user_key },
        );
        try q.leaf("id");
        try q.close(1);
    }
}

/// The secrets the base container is made with: a private job image's registry password, and
/// job-level and container env that carries one.
fn baseSecrets(
    arena: Allocator,
    ev: *Evaluator,
    job: job_mod.Job,
    container_env: []const job_mod.EnvVar,
) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    if (job.container) |jc| if (try registryCredentials(ev, jc)) |c| try out.append(arena, c.pass);
    for (ev.job_env.items) |e| if (containsSecret(job, e.value)) try out.append(arena, e.value);
    for (container_env) |e| if (containsSecret(job, e.value)) try out.append(arena, e.value);
    return out.items;
}

/// Secrets the job's steps will register if nothing else does: the job token, which every action
/// gets (ACTIONS_RUNTIME_TOKEN) and OIDC requests use, and GITHUB_TOKEN, which fetches checkouts
/// and the job's own repository's actions. One costs only its field in a query sent anyway.
fn stepSecrets(arena: Allocator, job: job_mod.Job) ![]const []const u8 {
    var actions = false;
    var fetches = false;
    for (job.steps) |st| switch (st.action) {
        .uses => {
            actions = true;
            fetches = true;
        },
        .docker => actions = true,
        .checkout => fetches = true,
        else => {},
    };
    var out: std.ArrayList([]const u8) = .empty;
    if ((actions or job.runtime.id_token_url.len > 0) and containsSecret(job, job.job_token))
        try out.append(arena, job.job_token);
    if (fetches) for (job.secret_vars) |sv| {
        if (std.mem.eql(u8, sv.name, "GITHUB_TOKEN") and sv.value.len > 0)
            try out.append(arena, sv.value);
    };
    return out.items;
}

/// The Exec a job's steps run through, from everything decided before the first step.
pub fn execFor(
    arena: Allocator,
    io: std.Io,
    transport: Transport,
    sh: *JobLog,
    ev: *Evaluator,
    job: *const job_mod.Job,
    opts: Options,
    plan: BasePlan,
    container_id: []const u8,
    secrets: Secrets,
    step_cache: bool,
) !Exec {
    // What the base container set as Dagger secrets (`writeJobEnv`, `writeImage`).
    var secret_vars: std.StringHashMapUnmanaged(void) = .empty;
    for ([_][]const job_mod.EnvVar{ ev.job_env.items, plan.container_env }) |env| for (env) |e| {
        if (containsSecret(job.*, e.value)) try secret_vars.put(arena, e.name, {});
    };
    return .{
        .arena = arena,
        .io = io,
        .transport = transport,
        .sh = sh,
        .ev = ev,
        .job = job,
        .container_id = container_id,
        .secrets = secrets,
        .next_fc = @intCast(job.steps.len + 1),
        .js_runtime = opts.js_runtime,
        .nesting = opts.nesting,
        .step_cache = step_cache,
        .enforce_volatile = step_cache and opts.enforce_volatile,
        .output_keys = try outputKeysKey(arena, ev, job.*, opts, step_cache),
        .outputs_volume = plan.outputs_volume,
        .outputs_days = opts.output_keys_days,
        .event_from_env = step_cache and (try ev.eventJson()).len <= max_event_env,
        .job_secret_env = secret_vars.count() > 0,
        .secret_vars = secret_vars,
        // Per job, not per run: a run's matrix jobs share its id and attempt, and a step that must
        // run in each of them would otherwise be replayed from the first one's result.
        .run_nonce = try std.fmt.allocPrint(
            arena,
            "{s}, job {s}",
            .{ try runNonce(arena, io, ev), plan.ran_marker },
        ),
        .ran_marker = plan.ran_marker,
        .dir_owner = if (plan.as_runner) runner_user else null,
        .execs = try zeroed(arena, u32, logSteps(job.steps.len)),
        .next_log_step = @intCast(job.steps.len + 1),
        .loaded = try nulls(arena, Exec.LoadResult, job.steps.len),
        .pre_state = try emptySlices(arena, job_mod.EnvVar, job.steps.len),
        .summaries = try emptySlices(arena, u8, logSteps(job.steps.len)),
        .job_image = plan.job_image,
        .observer = opts.observer,
    };
}

/// "Set up job": what GitHub's runner logs before the first step, including fetching every action.
/// As on GitHub, an action that cannot be resolved (even one whose step would be skipped) fails
/// "Set up job" with one error naming them all, and no step runs: that is the Result returned. So
/// does `defaults.run` that cannot be read or evaluated.
pub fn setUpJob(x: *Exec, opts: Options, results: []StepResult) !?Result {
    const arena = x.arena;
    try x.logSetUp(opts);
    if (try evalRunDefaults(x)) |why| return try failSetUp(x, results, why);
    var downloaded: std.StringHashMapUnmanaged(void) = .empty;
    var unresolved: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (x.job.steps, 1..) |step, n| if (step.action == .uses and !step.action.uses.local) {
        const lr = try x.loadFor(@intCast(n), step.action.uses);
        if (lr == .unresolved) try unresolved.put(arena, lr.unresolved, {});
        if (lr != .ok) continue;
        const u = step.action.uses;
        const label = try std.fmt.allocPrint(arena, "{s}/{s}@{s}", .{ u.owner, u.name, u.ref });
        if ((try downloaded.getOrPut(arena, label)).found_existing) continue;
        x.setUpLine(if (lr.ok.sha.len > 0)
            try std.fmt.allocPrint(
                arena,
                "Download action repository '{s}' (SHA:{s})",
                .{ label, lr.ok.sha },
            )
        else
            try std.fmt.allocPrint(arena, "Download action repository '{s}'", .{label}));
    };
    if (unresolved.count() > 0)
        return try failSetUp(x, results, try std.mem.join(arena, ". ", unresolved.keys()));
    const job = x.job;
    x.setUpLine(try std.fmt.allocPrint(arena, "Complete job name: {s}", .{jobLabel(job.*)}));
    return null;
}

/// "Set up job" failed with `why`: logged as its error, and no step runs.
fn failSetUp(x: *Exec, results: []StepResult, why: []const u8) !Result {
    x.sh.errorLine(0, why);
    var failed = try finish(x.arena, x.sh, results, "");
    failed.succeeded = false;
    failed.engine_error = null;
    failed.set_up_failed = true;
    return failed;
}

/// Evaluates `defaults.run` into `Exec.default_shell` and `default_working_directory`, once for
/// the job as GitHub's runner does in "Set up job"; an empty value counts as unset (actions/runner
/// src/Runner.Worker/JobExtension.cs 277-293). Returns why, when it cannot.
fn evalRunDefaults(x: *Exec) !?[]const u8 {
    if (x.job.defaults_error) |why| return why;
    const d = x.job.defaults_run;
    const sc = try x.ev.scope(&.{});
    if (d.shell) |t| {
        const v = x.ev.render(t, sc) catch return try std.fmt.allocPrint(
            x.arena,
            "defaults.run.shell: {s}",
            .{x.ev.diag},
        );
        if (v.len > 0) x.default_shell = v;
    }
    if (d.working_directory) |t| {
        const v = x.ev.render(t, sc) catch return try std.fmt.allocPrint(
            x.arena,
            "defaults.run.working-directory: {s}",
            .{x.ev.diag},
        );
        if (v.len > 0) x.default_working_directory = v;
    }
    return null;
}

fn zeroed(arena: Allocator, comptime T: type, n: usize) ![]T {
    const s = try arena.alloc(T, n);
    @memset(s, 0);
    return s;
}

fn nulls(arena: Allocator, comptime T: type, n: usize) ![]?T {
    const s = try arena.alloc(?T, n);
    @memset(s, null);
    return s;
}

fn emptySlices(arena: Allocator, comptime T: type, n: usize) ![][]const T {
    const s = try arena.alloc([]const T, n);
    @memset(s, &.{});
    return s;
}

/// Linux limits one environment string to 128 KiB; larger payloads are written as a file instead.
const max_event_env = 100 * 1024;

/// `<run_id>.<run_attempt>`, or the time when the job has no run id (`--exec-job`).
fn runNonce(arena: Allocator, io: std.Io, ev: *const Evaluator) ![]const u8 {
    const id = ev.githubString("run_id");
    if (id.len > 0)
        return std.fmt.allocPrint(arena, "{s}.{s}", .{ id, ev.githubString("run_attempt") });
    return std.fmt.allocPrint(arena, "t{d}", .{std.Io.Clock.real.now(io).toMilliseconds()});
}

/// Package managers' cache directories (for root, the default images' user), each mounted from its
/// own cache volume. Their contents are caches the tools validate themselves, so sharing them
/// between jobs is safe; they are keyed by repository (see `packageCacheScope`).
///
/// A `container:` image may put them elsewhere (the golang image's GOPATH is /go), so in a
/// container job a tool with a variable naming its cache directory gets the variable pointing at
/// the volume. The paths stay the default image's: Go keys compiled packages on their source
/// directory, so a module cache at one path everywhere lets every image share the build cache. The
/// container's or the workflow's own value wins (and the tool then works without the volume).
pub const package_cache_dirs = [_]struct { name: []const u8, path: []const u8, env: []const u8 = "" }{
    // RUNNER_TOOL_CACHE: what setup-node, setup-python, setup-go and the like download and unpack,
    // found again by the next job instead of fetched (GitHub's images come with it filled).
    .{ .name = "toolcache", .path = "/opt/hostedtoolcache" },
    .{ .name = "npm", .path = "/root/.npm", .env = "npm_config_cache" },
    .{ .name = "pnpm", .path = "/root/.local/share/pnpm/store" },
    .{ .name = "yarn", .path = "/usr/local/share/.cache/yarn" },
    .{ .name = "pip", .path = "/root/.cache/pip", .env = "PIP_CACHE_DIR" },
    .{ .name = "uv", .path = "/root/.cache/uv", .env = "UV_CACHE_DIR" },
    .{ .name = "go-mod", .path = "/root/go/pkg/mod", .env = "GOMODCACHE" },
    .{ .name = "go-build", .path = "/root/.cache/go-build", .env = "GOCACHE" },
    .{ .name = "cargo-registry", .path = "/root/.cargo/registry" },
    .{ .name = "cargo-git", .path = "/root/.cargo/git" },
    .{ .name = "bun", .path = "/root/.bun/install/cache", .env = "BUN_INSTALL_CACHE_DIR" },
    .{ .name = "zig", .path = "/root/.cache/zig", .env = "ZIG_GLOBAL_CACHE_DIR" },
    .{ .name = "gradle", .path = "/root/.gradle/caches" },
    .{ .name = "maven", .path = "/root/.m2/repository" },
    // Not package caches, but state tools rewrite on every run, kept out of the container's
    // filesystem so that what a step leaves there is what it produced (see `Options.output_keys`).
    // Node's compile cache: V8 code npm and Node write and Node validates, which also lets them
    // start faster. No variable: NODE_COMPILE_CACHE would turn it on for every Node program; this
    // is where Node puts it when a program turns it on. And Go's local telemetry counters.
    .{ .name = "node-compile-cache", .path = "/tmp/node-compile-cache" },
    .{ .name = "go-telemetry", .path = "/root/.config/go/telemetry" },
};

/// Which volumes the job shares: `repo`, the repository's trusted jobs', only for a job the runner
/// vouches for (`Options.trusted`, `trust.vouches`); every other job gets `untrusted`, so untrusted
/// code cannot plant content in the caches trusted jobs read (GitHub scopes its cache by branch for
/// the same reason). Several of them are not checked again on use (Go's module cache, Zig's package
/// cache, cargo's sources, the tool cache's binaries). It fails closed (#105): it used to give a
/// separate scope only to a pull request whose head repository was named and was another, so a
/// same-repository pull request, a `workflow_run` or `issue_comment` a fork triggered, or a fork's
/// pull request whose repository was deleted all shared `repo`. A fork's pull request stays apart
/// even on a runner that vouches for pull requests.
pub fn packageCacheScope(
    arena: Allocator,
    ev: *Evaluator,
    repository: []const u8,
    trusted: bool,
) ![]const u8 {
    if (!trusted) return "untrusted";
    const ctxs = [_]expr.Value.Entry{.{ .key = "github", .value = ev.github }};
    const head = expr.evalString(
        arena,
        "github.event.pull_request.head.repo.full_name",
        .{ .contexts = &ctxs },
    ) catch "";
    return if (head.len > 0 and !std.ascii.eqlIgnoreCase(head, repository)) "untrusted" else "repo";
}

test "the default image is provisioned with git; a custom image is left alone" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);
    const steps = [_]job_mod.Step{testStep("true")};
    for ([_]struct { image: []const u8, expect_provision: bool }{
        .{ .image = default_image, .expect_provision = true },
        .{ .image = "custom/image:1", .expect_provision = false },
    }) |case| {
        const answers = [_][]const u8{ base_answer, try exec(arena, "C1", 0, "") };
        var fake: FakeSession = .{ .answers = &answers, .arena = arena };
        var buf: [512]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
        _ = try run(arena, std.testing.io, &env, .{ .image = case.image, .test_session_argv = &.{ "sh", "-c", fake_child }, .test_transport = fake.transport() }, testJob(&steps), &log);
        const base = fake.seen.items[0];
        try std.testing.expect(braceBalanced(base));
        try std.testing.expectEqual(case.expect_provision, std.mem.indexOf(u8, base, "apt-get install") != null);
        try std.testing.expect(std.mem.indexOf(u8, base, case.image) != null);
    }
}

test "an action that cannot be resolved fails Set up job, and no step runs" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);
    // The second action's step would be skipped; GitHub resolves it anyway.
    var skipped = usesStep("gone", "Someone", "Gone", "v1", &.{});
    skipped.condition = "failure()";
    const steps = [_]job_mod.Step{ testStep("echo before"), usesStep("uv", "astral-sh", "setup-uv", "v10", &.{}), skipped };
    const job = testJob(&steps);
    const answers = [_][]const u8{
        base_answer,
        "{\"errors\":[{\"message\":\"git error: repository does not contain ref \\\"v10\\\"\"}]}",
        "{\"errors\":[{\"message\":\"git error: git authentication failed\"}]}",
    };
    var fake: FakeSession = .{ .answers = &answers, .arena = arena };
    var buf: [8192]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    const res = try run(arena, std.testing.io, &env, .{ .test_session_argv = &.{ "sh", "-c", fake_child }, .test_transport = fake.transport() }, job, &log);
    try std.testing.expect(!res.succeeded and res.set_up_failed);
    try std.testing.expect(res.engine_error == null);
    for (res.steps) |r| try std.testing.expectEqual(Outcome.not_run, r.outcome);
    // Nothing ran: the base container and the two fetches were the only queries.
    try std.testing.expectEqual(@as(usize, 3), fake.seen.items.len);
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "[job 0 step 0 stdout] ##[error]Unable to resolve action `astral-sh/setup-uv@v10`, unable to find version `v10`. Unable to resolve action someone/gone, repository not found") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Complete job name") == null);
    try std.testing.expectEqual(@as(usize, 1), res.annotations.len);
}

test "uv's environment goes in its cache, with a .venv symlink to it" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    // Keyed by the ref, with anything else in a path turned into a dash.
    try std.testing.expectEqualStrings("/home/runner/.cache/uv/zig-runner-envs/refs-heads-main", try uvEnvPath(arena, "/home/runner/.cache/uv", "refs/heads/main"));
    try std.testing.expectEqualStrings("/c/zig-runner-envs/refs-pull-7-merge", try uvEnvPath(arena, "/c", "refs/pull/7/merge"));
    try std.testing.expectEqualStrings("/c/zig-runner-envs/default", try uvEnvPath(arena, "/c", ""));

    var env: std.process.Environ.Map = .init(arena);
    const steps = [_]job_mod.Step{testStep("uv sync")};
    var job = testJob(&steps);
    job.github.ref = "refs/heads/main";
    const vols = "{\"data\":{\"c0\":{\"id\":\"V\"},\"c1\":{\"id\":\"V\"},\"c2\":{\"id\":\"V\"},\"c3\":{\"id\":\"V\"},\"c4\":{\"id\":\"V\"},\"c5\":{\"id\":\"V\"},\"c6\":{\"id\":\"V\"},\"c7\":{\"id\":\"V\"},\"c8\":{\"id\":\"V\"},\"c9\":{\"id\":\"V\"},\"c10\":{\"id\":\"V\"},\"c11\":{\"id\":\"V\"},\"c12\":{\"id\":\"V\"},\"c13\":{\"id\":\"V\"},\"c14\":{\"id\":\"V\"},\"c15\":{\"id\":\"V\"},\"c16\":{\"id\":\"V\"}}}";
    const answers = [_][]const u8{ vols, base_answer, try exec(arena, "C1", 0, "") };
    var fake: FakeSession = .{ .answers = &answers, .arena = arena };
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    const res = try run(arena, std.testing.io, &env, .{ .step_user = .runner, .package_caches = true, .test_session_argv = &.{ "sh", "-c", fake_child }, .test_transport = fake.transport() }, job, &log);
    try std.testing.expect(res.succeeded);
    const base = fake.seen.items[1];
    const path = "/home/runner/.cache/uv/zig-runner-envs/refs-heads-main";
    try std.testing.expect(std.mem.indexOf(u8, base, "withEnvVariable(name:\"UV_PROJECT_ENVIRONMENT\",value:\"" ++ path ++ "\")") != null);
    // `uv venv` would otherwise fail on the second job for a ref, the environment being there already.
    try std.testing.expect(std.mem.indexOf(u8, base, "withEnvVariable(name:\"UV_VENV_CLEAR\",value:\"1\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, base, "ln -sfn " ++ path ++ " /home/runner/work/r/r/.venv") != null);

    // Off: no variable, no link.
    var fake2: FakeSession = .{ .answers = &answers, .arena = arena };
    var w2: std.Io.Writer = .fixed(&buf);
    var log2: sink.LogSink = .{ .stdout = .{ .writer = &w2 } };
    _ = try run(arena, std.testing.io, &env, .{ .step_user = .runner, .package_caches = true, .uv_env_in_cache = false, .test_session_argv = &.{ "sh", "-c", fake_child }, .test_transport = fake2.transport() }, job, &log2);
    try std.testing.expect(std.mem.indexOf(u8, fake2.seen.items[1], "UV_PROJECT_ENVIRONMENT") == null);
    try std.testing.expect(std.mem.indexOf(u8, fake2.seen.items[1], "ln -sfn") == null);

    // With step caching, the environment stays in the workspace, where a replayed `uv sync`
    // restores it with the rest of the container, not in a volume another commit's job synced
    // (#70). uv's own cache is still mounted from its volume.
    var fake3: FakeSession = .{ .answers = &answers, .arena = arena };
    var w3: std.Io.Writer = .fixed(&buf);
    var log3: sink.LogSink = .{ .stdout = .{ .writer = &w3 } };
    const res3 = try run(arena, std.testing.io, &env, .{ .step_user = .runner, .package_caches = true, .step_cache = true, .test_session_argv = &.{ "sh", "-c", fake_child }, .test_transport = fake3.transport() }, job, &log3);
    try std.testing.expect(res3.succeeded);
    const cached = fake3.seen.items[1];
    try std.testing.expect(std.mem.indexOf(u8, cached, "UV_PROJECT_ENVIRONMENT") == null);
    try std.testing.expect(std.mem.indexOf(u8, cached, "UV_VENV_CLEAR") == null);
    try std.testing.expect(std.mem.indexOf(u8, cached, "ln -sfn") == null);
    try std.testing.expect(std.mem.indexOf(u8, cached, "zig-runner-envs") == null);
    try std.testing.expect(std.mem.indexOf(u8, cached, "withMountedCache(path:\"/home/runner/.cache/uv\"") != null);
    // The step's own query does not point uv at the volume either.
    try std.testing.expect(std.mem.indexOf(u8, fake3.seen.items[2], "UV_PROJECT_ENVIRONMENT") == null);
}

test "package caches: one volume per tool, keyed by repository, shared only by vouched-for jobs" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);
    const steps = [_]job_mod.Step{testStep("npm ci")};
    const pr_head =
        \\{"github":{"t":2,"d":[{"k":"repository","v":"o/r"},{"k":"event","v":{"t":2,"d":[
    ++
        \\{"k":"pull_request","v":{"t":2,"d":[{"k":"head","v":
    ;
    const pr_tail = "}]}}]}}]}}";
    const head_repo =
        \\{"t":2,"d":[{"k":"repo","v":{"t":2,"d":[{"k":"full_name","v":
    ;
    const fork_ctx = pr_head ++ head_repo ++ "\"someone/r\"}]}}]}" ++ pr_tail;
    const same_repo_ctx = pr_head ++ head_repo ++ "\"o/r\"}]}}]}" ++ pr_tail;
    // A fork's pull request whose repository was deleted: GitHub sends `head.repo: null`.
    const deleted_ctx = pr_head ++ "{\"t\":2,\"d\":[{\"k\":\"repo\",\"v\":null}]}" ++ pr_tail;
    const Case = struct { trusted: bool, ctx: ?[]const u8, scope: []const u8 };
    for ([_]Case{
        .{ .trusted = true, .ctx = null, .scope = "repo" },
        // A runner that vouches for pull requests (RUNNER_TRUSTED_EVENTS names them): its own.
        .{ .trusted = true, .ctx = same_repo_ctx, .scope = "repo" },
        // ...but not for a fork's, whatever the lists say.
        .{ .trusted = true, .ctx = fork_ctx, .scope = "untrusted" },
        // Not vouched for (`trust.vouches`): a same-repository pull request, an event the lists
        // do not name (`workflow_run`, `issue_comment`), any job on a `*` runner, and a fork's
        // pull request whose head repository is gone, which the old rule could not tell apart.
        .{ .trusted = false, .ctx = null, .scope = "untrusted" },
        .{ .trusted = false, .ctx = same_repo_ctx, .scope = "untrusted" },
        .{ .trusted = false, .ctx = deleted_ctx, .scope = "untrusted" },
        .{ .trusted = false, .ctx = fork_ctx, .scope = "untrusted" },
    }) |case| {
        var job = testJob(&steps);
        if (case.ctx) |ctx| {
            job.context_data = try std.json.parseFromSliceLeaky(std.json.Value, arena, ctx, .{});
        }
        var vols: std.Io.Writer.Allocating = .init(arena);
        try vols.writer.writeAll("{\"data\":{");
        for (package_cache_dirs, 0..) |_, i| try vols.writer.print("{s}\"c{d}\":{{\"id\":\"V{d}\"}}", .{ if (i == 0) "" else ",", i, i });
        try vols.writer.writeAll("}}");
        const answers = [_][]const u8{ vols.written(), base_answer, try exec(arena, "C1", 0, "") };
        var fake: FakeSession = .{ .answers = &answers, .arena = arena };
        var buf: [1024]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
        const res = try run(arena, std.testing.io, &env, .{ .package_caches = true, .trusted = case.trusted, .test_session_argv = &.{ "sh", "-c", fake_child }, .test_transport = fake.transport() }, job, &log);
        try std.testing.expect(res.succeeded);
        const scope = case.scope;
        try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[0], try std.fmt.allocPrint(arena, "c1: cacheVolume(key:\"zig-runner/o/r/{s}/npm\")", .{scope})) != null);
        // The tool cache is also keyed by the job's image (its binaries are built for it).
        try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[0], try std.fmt.allocPrint(arena, "c0: cacheVolume(key:\"zig-runner/o/r/{s}/toolcache/ubuntu:24.04\")", .{scope})) != null);
        try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[0], try std.fmt.allocPrint(arena, "cacheVolume(key:\"zig-runner/o/r/{s}/zig\")", .{scope})) != null);
        // Mounted on the base container, so every step has them.
        try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[1], "withMountedCache(path:\"/opt/hostedtoolcache\",cache:\"V0\")") != null);
        try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[1], "withMountedCache(path:\"/root/.npm\",cache:\"V1\")") != null);
        try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[1], "withMountedCache(path:\"/root/.cache/zig\",cache:\"V11\")") != null);
        // Zig's local cache stays in the workspace unless `zig_local_cache` is on.
        try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[0], "zig-local") == null);
        try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[1], "ZIG_LOCAL_CACHE_DIR") == null);
        // State tools rewrite on every run stays out of the container's filesystem.
        try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[1], "withMountedCache(path:\"/tmp/node-compile-cache\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, fake.seen.items[1], "withMountedCache(path:\"/root/.config/go/telemetry\"") != null);
        try std.testing.expect(braceBalanced(fake.seen.items[1]));
    }
}

test "with zig_local_cache, Zig's local cache gets a volume of its own, outside the workspace" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);
    const steps = [_]job_mod.Step{testStep("zig build test")};
    const job = testJob(&steps);
    var vols: std.Io.Writer.Allocating = .init(arena);
    try vols.writer.writeAll("{\"data\":{\"czl\":{\"id\":\"VZL\"}");
    for (package_cache_dirs, 0..) |_, i| try vols.writer.print(",\"c{d}\":{{\"id\":\"V{d}\"}}", .{ i, i });
    try vols.writer.writeAll("}}");
    const answers = [_][]const u8{ vols.written(), base_answer, try exec(arena, "C1", 0, "") };
    var fake: FakeSession = .{ .answers = &answers, .arena = arena };
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    const res = try run(arena, std.testing.io, &env, .{
        .package_caches = true,
        .trusted = true,
        .zig_local_cache = true,
        .step_user = .runner,
        .test_session_argv = &.{ "sh", "-c", fake_child },
        .test_transport = fake.transport(),
    }, job, &log);
    try std.testing.expect(res.succeeded);
    const keys = fake.seen.items[0];
    const base = fake.seen.items[1];
    try std.testing.expect(braceBalanced(base));
    // Apart from the global cache's volume, so the engine can collect it alone.
    try std.testing.expect(std.mem.indexOf(u8, keys, "czl: cacheVolume(key:\"zig-runner/o/r/repo/zig-local/runner\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, base, "withEnvVariable(name:\"ZIG_LOCAL_CACHE_DIR\",value:\"/home/runner/.cache/zig-local\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, base, "withMountedCache(path:\"/home/runner/.cache/zig-local\",cache:\"VZL\",owner:\"runner\")") != null);
}

test "steps run as runner in the default image, as on GitHub, with their own package caches" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);
    const steps = [_]job_mod.Step{testStep("go test ./...")};
    const job = testJob(&steps);
    var vols: std.Io.Writer.Allocating = .init(arena);
    try vols.writer.writeAll("{\"data\":{");
    for (package_cache_dirs, 0..) |_, i| try vols.writer.print("{s}\"c{d}\":{{\"id\":\"V{d}\"}}", .{ if (i == 0) "" else ",", i, i });
    try vols.writer.writeAll("}}");
    const answers = [_][]const u8{ vols.written(), base_answer, try exec(arena, "C1", 0, "") };
    var fake: FakeSession = .{ .answers = &answers, .arena = arena };
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    const res = try run(arena, std.testing.io, &env, .{ .package_caches = true, .trusted = true, .step_user = .runner, .test_session_argv = &.{ "sh", "-c", fake_child }, .test_transport = fake.transport() }, job, &log);
    try std.testing.expect(res.succeeded);
    const keys = fake.seen.items[0];
    const base = fake.seen.items[1];
    try std.testing.expect(braceBalanced(base));
    // Volumes of their own: root's hold files the user cannot write.
    try std.testing.expect(std.mem.indexOf(u8, keys, "cacheVolume(key:\"zig-runner/o/r/repo/npm/runner\")") != null);
    // Provisioned with the user (uid 1001, passwordless sudo, /github its own), then run as it.
    try std.testing.expect(std.mem.indexOf(u8, base, "useradd -m -u 1001 -s /bin/bash runner") != null);
    try std.testing.expect(std.mem.indexOf(u8, base, "runner ALL=(ALL) NOPASSWD:ALL") != null);
    // The caches' directories exist and are its own before they are mounted (Dagger would make the
    // parents of a mount as root).
    try std.testing.expect(std.mem.indexOf(u8, base, " /home/runner/go/pkg/mod ") != null);
    try std.testing.expect(std.mem.indexOf(u8, base, "chown -R runner:runner /github /home/runner") != null);
    try std.testing.expect(std.mem.indexOf(u8, base, "withUser(name:\"runner\") { withEnvVariable(name:\"HOME\",value:\"/home/runner\")") != null);
    // Caches under its home, owned by it; the tool cache stays where actions look for it.
    try std.testing.expect(std.mem.indexOf(u8, base, "withMountedCache(path:\"/home/runner/go/pkg/mod\",cache:\"V6\",owner:\"runner\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, base, "withMountedCache(path:\"/home/runner/.cache/yarn\",cache:\"V3\",owner:\"runner\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, base, "withMountedCache(path:\"/opt/hostedtoolcache\",cache:\"V0\",owner:\"runner\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, base, "/root/") == null);
}

test "package caches in a container job: variables point the tools at the volumes, the image's own value winning" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    var env: std.process.Environ.Map = .init(arena);
    const steps = [_]job_mod.Step{testStep("go test ./...")};
    var job = testJob(&steps);
    job.container = .{ .name = "", .image = .{ .lit = "golang:1.25" }, .env = &.{.{ .name = "GOCACHE", .value = .{ .lit = "/tmp/gocache" } }} };
    var vols: std.Io.Writer.Allocating = .init(arena);
    try vols.writer.writeAll("{\"data\":{");
    for (package_cache_dirs, 0..) |_, i| try vols.writer.print("{s}\"c{d}\":{{\"id\":\"V{d}\"}}", .{ if (i == 0) "" else ",", i, i });
    try vols.writer.writeAll("}}");
    // Only the base container matters here: the job stops when the answers run out.
    const answers = [_][]const u8{ vols.written(), base_answer };
    var fake: FakeSession = .{ .answers = &answers, .arena = arena };
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var log: sink.LogSink = .{ .stdout = .{ .writer = &w } };
    _ = try run(arena, std.testing.io, &env, .{ .package_caches = true, .test_session_argv = &.{ "sh", "-c", fake_child }, .test_transport = fake.transport() }, job, &log);
    const base = fake.seen.items[1];
    // The golang image's GOPATH is /go, not /root/go: the variable says where the volume is.
    try std.testing.expect(std.mem.indexOf(u8, base, "withEnvVariable(name:\"GOMODCACHE\",value:\"/root/go/pkg/mod\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, base, "withMountedCache(path:\"/root/go/pkg/mod\"") != null);
    // A tool without such a variable gets none.
    try std.testing.expect(std.mem.indexOf(u8, base, "CARGO_HOME") == null);
    // The container's env comes after, so its GOCACHE is the one the steps see.
    const ours = std.mem.indexOf(u8, base, "withEnvVariable(name:\"GOCACHE\",value:\"/root/.cache/go-build\")").?;
    const theirs = std.mem.indexOf(u8, base, "withEnvVariable(name:\"GOCACHE\",value:\"/tmp/gocache\")").?;
    try std.testing.expect(ours < theirs);
    try std.testing.expect(braceBalanced(base));
}
