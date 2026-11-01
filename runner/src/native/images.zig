//! Docker actions' images on the native backend (docs/native-backend.md, P7): for a reference,
//! its root filesystem and the parts of its config a Docker action starts from (entrypoint,
//! command, env, user). That is the whole interface the actions need from an image store.
//!
//! Until phase 3's pull, the store is a directory the operator fills (`RUNNER_NATIVE_IMAGES`),
//! one image per reference: `<dir>/<key>/rootfs`, the image's filesystem owned as the image has
//! it, and `<dir>/<key>/config.json`, its OCI image config (`{"config": {"Entrypoint": ...}}`).
//! `<key>` is the normalised reference (`normalize`) with every byte outside `[A-Za-z0-9._-]`
//! percent-encoded (`key`). A reference not in it sends the job to Dagger (`Backend.unsupported`).
//! Phase 3 replaces `lookup` with its image store; the callers keep `Image`.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// An image a Docker action runs in.
pub const Image = struct {
    /// The image's filesystem, absolute: the lowest layer of the action's overlay.
    rootfs: []const u8,
    /// The image's `ENTRYPOINT` and `CMD`, as `docker run` combines them with the action's.
    entrypoint: []const []const u8 = &.{},
    cmd: []const []const u8 = &.{},
    /// `NAME=value`, the image's `ENV`: the action's environment starts from it.
    env: []const []const u8 = &.{},
    /// The image's `USER`; "" for root.
    user: []const u8 = "",
};

/// The reference as Docker resolves it: a registry host first (`docker.io` when the first part
/// names none: no dot, no port, not `localhost`), `library/` for Docker Hub's official images, and
/// `:latest` when there is neither a tag nor a digest. `alpine:3.22` is
/// `docker.io/library/alpine:3.22`.
pub fn normalize(arena: Allocator, ref: []const u8) ![]const u8 {
    const slash = std.mem.indexOfScalar(u8, ref, '/');
    const names_host = if (slash) |s| blk: {
        const first = ref[0..s];
        break :blk std.mem.indexOfAny(u8, first, ".:") != null or
            std.mem.eql(u8, first, "localhost");
    } else false;
    const host = if (names_host) ref[0..slash.?] else "docker.io";
    const path = if (names_host) ref[slash.? + 1 ..] else ref;
    const library = std.mem.eql(u8, host, "docker.io") and
        std.mem.indexOfScalar(u8, path, '/') == null;
    const last = path[(std.mem.lastIndexOfScalar(u8, path, '/') orelse 0)..];
    const tagged = std.mem.indexOfScalar(u8, path, '@') != null or
        std.mem.indexOfScalar(u8, last, ':') != null;
    return std.fmt.allocPrint(arena, "{s}/{s}{s}{s}", .{
        host,
        if (library) "library/" else "",
        path,
        if (tagged) "" else ":latest",
    });
}

/// The directory name of `ref`'s image in the store: its normalised form, with every byte outside
/// `[A-Za-z0-9._-]` as `%XX`, so two references never share one and none names a path.
pub fn key(arena: Allocator, ref: []const u8) ![]const u8 {
    const full = try normalize(arena, ref);
    var out: std.ArrayList(u8) = .empty;
    for (full) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-')
            try out.append(arena, c)
        else
            try out.print(arena, "%{X:0>2}", .{c});
    }
    return out.items;
}

/// Whether an image's `USER` is root: unset, `root` or uid 0, with or without a group.
pub fn runsAsRoot(user: []const u8) bool {
    const name = user[0 .. std.mem.indexOfScalar(u8, user, ':') orelse user.len];
    return name.len == 0 or std.mem.eql(u8, name, "root") or std.mem.eql(u8, name, "0");
}

/// `ref`'s image in the store at `dir`, or why it is not there.
pub const Found = union(enum) { image: Image, missing: []const u8 };

pub fn lookup(arena: Allocator, io: std.Io, dir: []const u8, ref: []const u8) !Found {
    if (dir.len == 0) return .{ .missing = "there is no native image store (RUNNER_NATIVE_IMAGES; " ++
        "the native image pull is phase 3)" };
    const k = try key(arena, ref);
    const rootfs = try std.fmt.allocPrint(arena, "{s}/{s}/rootfs", .{ dir, k });
    std.Io.Dir.accessAbsolute(io, rootfs, .{}) catch return .{ .missing = try std.fmt.allocPrint(
        arena,
        "the image {s} is not in the native image store (RUNNER_NATIVE_IMAGES, as {s}; the " ++
            "native image pull is phase 3)",
        .{ ref, k },
    ) };
    const config_path = try std.fmt.allocPrint(arena, "{s}/{s}/config.json", .{ dir, k });
    const text = std.Io.Dir.cwd().readFileAlloc(io, config_path, arena, .limited(4 << 20)) catch
        return .{ .missing = try std.fmt.allocPrint(
            arena,
            "the image {s} has no config.json in the native image store",
            .{ref},
        ) };
    var image = parseConfig(arena, text) catch return .{ .missing = try std.fmt.allocPrint(
        arena,
        "the image {s} has a config.json the runner cannot read",
        .{ref},
    ) };
    image.rootfs = rootfs;
    return .{ .image = image };
}

/// The parts of an OCI image config (`application/vnd.oci.image.config.v1+json`, which Docker's
/// image config also is) a Docker action needs. `rootfs` is left for the caller.
pub fn parseConfig(arena: Allocator, text: []const u8) !Image {
    const Oci = struct {
        config: ?struct {
            Entrypoint: ?[]const []const u8 = null,
            Cmd: ?[]const []const u8 = null,
            Env: ?[]const []const u8 = null,
            User: ?[]const u8 = null,
        } = null,
    };
    const oci = try std.json.parseFromSliceLeaky(Oci, arena, text, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    const c = oci.config orelse return .{ .rootfs = "" };
    return .{
        .rootfs = "",
        .entrypoint = c.Entrypoint orelse &.{},
        .cmd = c.Cmd orelse &.{},
        .env = c.Env orelse &.{},
        .user = c.User orelse "",
    };
}

test "references normalise as Docker resolves them, and key one directory each" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const Case = struct { []const u8, []const u8 };
    for ([_]Case{
        .{ "alpine", "docker.io/library/alpine:latest" },
        .{ "alpine:3.22", "docker.io/library/alpine:3.22" },
        .{ "bitnami/postgresql:17", "docker.io/bitnami/postgresql:17" },
        .{ "docker.io/library/alpine:3", "docker.io/library/alpine:3" },
        .{ "ghcr.io/acme/tool", "ghcr.io/acme/tool:latest" },
        .{ "localhost:5000/x", "localhost:5000/x:latest" },
        .{ "localhost/x:1", "localhost/x:1" },
        .{ "alpine@sha256:abcd", "docker.io/library/alpine@sha256:abcd" },
    }) |c| try std.testing.expectEqualStrings(c[1], try normalize(arena, c[0]));
    try std.testing.expectEqualStrings(
        "docker.io%2Flibrary%2Falpine%3A3.22",
        try key(arena, "alpine:3.22"),
    );
    // Nothing in a key leaves its directory.
    try std.testing.expectEqualStrings(
        "..%2F..%2Fetc%3Alatest",
        try key(arena, "../../etc"),
    );
}

test "an OCI image config gives the entrypoint, command, env and user" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const img = try parseConfig(arena,
        \\{"architecture":"amd64","config":{"Env":["PATH=/usr/bin","X=1"],
        \\"Entrypoint":["/entry.sh"],"Cmd":null,"User":"","WorkingDir":"/app"},"rootfs":{}}
    );
    try std.testing.expectEqual(@as(usize, 1), img.entrypoint.len);
    try std.testing.expectEqualStrings("/entry.sh", img.entrypoint[0]);
    try std.testing.expectEqual(@as(usize, 0), img.cmd.len);
    try std.testing.expectEqualStrings("X=1", img.env[1]);
    try std.testing.expect(runsAsRoot(img.user));
    try std.testing.expect(runsAsRoot("0:0") and runsAsRoot("root"));
    try std.testing.expect(!runsAsRoot("1000") and !runsAsRoot("actionuser:actionuser"));
    const bare = try parseConfig(arena, "{}");
    try std.testing.expectEqual(@as(usize, 0), bare.env.len);
}
