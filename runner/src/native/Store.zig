//! The native backend's layer store (docs/native-backend.md, P2): the layers steps left, kept
//! between jobs under the key of what made them, so a step whose inputs are unchanged since an
//! earlier job is replayed instead of run. It stands where BuildKit's cache stood for the Dagger
//! backend, and keeps the model's key (proofs/Runner/Model.lean, `keyOf`): a step's key is its
//! parent's key, its script and its stable environment, never the volatile variables or the
//! mounts' content.
//!
//! On disk, under the store's directory (`RUNNER_NATIVE_STORE`, mode 0700):
//!
//!     layers/<key>/fs       the layer's tree, an overlay upper become a lower
//!     layers/<key>/log      the step's output as it was printed, markers and all
//!     layers/<key>/fc       its combined file commands (`scripts.writeCombinedFileCommands`)
//!     layers/<key>/size     its bytes on disk, for eviction
//!     layers/<key>/lock     held shared by every job using the layer; its mtime is its last use
//!     layers/<key>/digest   its deterministic digest, once asked for (`layerDigest`)
//!     keys/<key>.lock       held while a step with that key runs (`lockKey`)
//!     jobs/<id>/            the jobs running now (`Backend`)
//!
//! A layer is built under `layers/.tmp-<key>-<n>` and published by one rename, so a reader finds
//! it whole or not at all. Only a step that exited 0, is not always-run (it uses no secret) and
//! whose parent is in the store is published (`Backend.execScript`), so a failure is never
//! replayed (#69) and no layer or log holds a step's secrets.

const Store = @This();

const std = @import("std");
const linux = std.os.linux;

const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
const dagger = @import("../dagger.zig");

/// The store's directory.
root: []const u8,
/// Past this many bytes of layers, the least recently used go (`collect`).
max_bytes: u64 = default_max_bytes,

pub const default_max_bytes: u64 = 10 * 1024 * 1024 * 1024;

pub const Key = [Sha256.digest_length]u8;

pub fn hex(k: Key) [2 * Sha256.digest_length]u8 {
    return std.fmt.bytesToHex(k, .lower);
}

/// The store's format: what a layer and its record mean (the sandbox that made the tree, the
/// record's files and how they replay, the key's extras). Part of every base's parent
/// (`Backend.below`), so every key: bump it with any change to those, and a runner upgraded
/// finds none of the layers an older one left (they age out under the cap).
pub const store_format = "zig-runner native store 2";

/// What a key is of (P8's tag, proofs/Runner/Native.lean): a job's base, a step's container (a
/// `run:` step's exec, or a checkout's fetch), or one keyed on what a step produced.
pub const Tag = enum(u64) { base = 0, step = 1, output_keyed = 2 };

/// A key, from its preimage as P8 fixes it (proofs/Runner/Native.lean, `stepPreimage`; test
/// vectors in P8's `native/testdata/step_keys.tsv`): the tag as a u64, then the parent's key, the
/// script's text, the count of stable bindings and each name and value (`core`), every field
/// prefixed with its length as a u64, little-endian, so two different lists of fields never hash
/// alike. What the runner adds to P8's model (who runs it, where, the files kept) follows the
/// core (`Backend.keyFor`).
pub const KeyHasher = struct {
    h: Sha256,
    /// Tests: the preimage's bytes too.
    bytes: ?*std.Io.Writer = null,

    pub fn init(tag: Tag) KeyHasher {
        var k: KeyHasher = .{ .h = .init(.{}) };
        k.int(@backingInt(tag));
        return k;
    }

    /// A digest that is no key (a tree's, what lies below a base): no tag.
    pub fn plain(what: []const u8) KeyHasher {
        var k: KeyHasher = .{ .h = .init(.{}) };
        k.field(what);
        return k;
    }

    /// P8's core after the tag: the parent's key, the script, and the stable env in the
    /// container's order (`stableEnv`), counted first.
    pub fn core(k: *KeyHasher, parent: Key, script: []const u8, env: anytype) void {
        k.field(&parent);
        k.field(script);
        var stable: u64 = 0;
        for (env) |e| stable += @intFromBool(stableEnv(e.name));
        k.int(stable);
        for (env) |e| if (stableEnv(e.name)) {
            k.field(e.name);
            k.field(e.value);
        };
    }

    pub fn field(k: *KeyHasher, b: []const u8) void {
        k.int(b.len);
        k.update(b);
    }

    pub fn int(k: *KeyHasher, v: u64) void {
        var b: [8]u8 = undefined;
        std.mem.writeInt(u64, &b, v, .little);
        k.update(&b);
    }

    fn update(k: *KeyHasher, b: []const u8) void {
        k.h.update(b);
        if (k.bytes) |out| out.writeAll(b) catch {};
    }

    pub fn final(k: *KeyHasher) Key {
        return k.h.finalResult();
    }
};

/// Whether a container variable is part of a key. Not the run-specific ones
/// (`dagger.volatile_env`), which steps are given withheld (`dagger.volatile_sentinel`) unless
/// they always run, nor the runner's own per-job values, volatile under Dagger too (the event, the
/// ran marker, the markers' secret), nor the secret aliases.
pub fn stableEnv(name: []const u8) bool {
    if (dagger.isVolatile(name)) return false;
    for ([_][]const u8{ dagger.event_env, dagger.ran_env, dagger.mark_env }) |n|
        if (std.mem.eql(u8, name, n)) return false;
    return !std.mem.startsWith(u8, name, "ZIG_SECRET_");
}

/// The store's directories, made if missing, the store's own mode 0700: on a root runner its
/// layers hold files owned by the jobs' ids, setuid ones among them, which no host user may
/// reach.
pub fn prepare(arena: Allocator, io: std.Io, root: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    for ([_][]const u8{ "layers", "keys", "jobs" }) |d|
        try cwd.createDirPath(io, try std.fmt.allocPrint(arena, "{s}/{s}", .{ root, d }));
    const p = try arena.dupeSentinel(u8, root, 0);
    if (linux.errno(linux.chmod(p, 0o700)) != .SUCCESS) return error.StoreMode;
}

fn layerDir(s: Store, arena: Allocator, key: Key) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/layers/{s}", .{ s.root, &hex(key) });
}

const lock_sh: i32 = 1;
const lock_ex: i32 = 2;
const lock_nb: i32 = 4;

fn flock(f: std.Io.File, how: i32) bool {
    return linux.errno(linux.flock(f.handle, how)) == .SUCCESS;
}

/// Held while a step with this key runs, so two jobs sharing the store (a pool's runners, or two
/// jobs of one) never run one key at once: the second waits, then finds the first's layer.
/// Polled, so `stop` (a cancel or a timeout while it waits) ends the wait with `error.Stopped`.
/// A lock file `collect` removed while it was being taken is not trusted: the lock is taken only
/// on the file the path names.
pub fn lockKey(
    s: Store,
    arena: Allocator,
    io: std.Io,
    key: Key,
    stop: *const std.atomic.Value(bool),
) !std.Io.File {
    const path = try std.fmt.allocPrint(arena, "{s}/keys/{s}.lock", .{ s.root, &hex(key) });
    while (true) {
        const f = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = false });
        if (flock(f, lock_ex | lock_nb)) {
            if (sameFile(arena, f, path)) return f;
            f.close(io);
            continue;
        }
        f.close(io);
        if (stop.load(.acquire)) return error.Stopped;
        io.sleep(.fromMilliseconds(50), .awake) catch {};
    }
}

/// A layer a job uses, held shared until the job ends: eviction takes the lock exclusively, so
/// it never removes a layer under a running job.
pub const Layer = struct {
    /// The layer's tree, an overlay lower.
    fs: []const u8,
    lock: std.Io.File,
};

/// What made a layer, which says what its record must hold: a step's file commands end with its
/// ran marker; a base's and a checkout's fetch's are empty.
pub const Kind = enum { base, step, fetch };

/// A stored layer found: held, with its record.
pub const Hit = struct { layer: Layer, rec: Record };

/// The layer stored under `key`, held (`Layer`), checked whole (`readEntry`) and its last use now;
/// null when there is none. An entry that cannot be replayed (a part missing or cut short, a disk
/// that filled, a hand that changed it) is evicted, and then is a miss too; `error.Invalid` when
/// another job holds it, so it can be neither replayed nor replaced now.
pub fn open(s: Store, arena: Allocator, io: std.Io, key: Key) !?Hit {
    const dir = try s.layerDir(arena, key);
    const lock_path = try join(arena, dir, "lock");
    const f = std.Io.Dir.cwd().openFile(io, lock_path, .{}) catch return null;
    // Waits out an eviction under way, which then leaves the path naming nothing.
    if (!flock(f, lock_sh) or !sameFile(arena, f, lock_path)) {
        f.close(io);
        return null;
    }
    const rec = readEntry(arena, io, dir) catch {
        f.close(io);
        if (s.evict(arena, io, &hex(key))) return null;
        return error.Invalid;
    };
    // Only a whole entry counts as used, so a broken one ages out.
    _ = linux.utimensat(f.handle, null, null, 0);
    return .{ .layer = .{ .fs = try join(arena, dir, "fs"), .lock = f }, .rec = rec };
}

/// What replaying a stored step needs: its output as printed, and its file commands.
pub const Record = struct { log: []const u8, fc: []const u8 };

/// A step that printed more than this is not published: its replay would hold it all in memory.
/// Dagger's limit on a recorded output (`dagger.max_recorded_bytes`).
pub const max_record_bytes = dagger.max_recorded_bytes;

const fc_ran = @import("../dagger/scripts.zig").fc_marker ++ "ran\n";

/// Why a record cannot be stored or replayed as a `kind`'s, or null when it can.
fn recordFault(kind: Kind, rec: Record) ?anyerror {
    if (rec.log.len > max_record_bytes or rec.fc.len > max_record_bytes)
        return error.RecordTooLarge;
    return switch (kind) {
        // Its file commands end with its ran marker (`scripts.writeCombinedFileCommands`):
        // without it, they were cut short.
        .step => if (std.mem.indexOf(u8, rec.fc, fc_ran) == null) error.ShortRecord else null,
        .base, .fetch => if (rec.fc.len > 0) error.ShortRecord else null,
    };
}

/// An entry's `meta`: the store's format, what made it, its bytes on disk, and its record's
/// files' lengths and sha256s, so a part cut short or changed is told from a whole one.
const Meta = struct {
    kind: Kind,
    bytes: u64,
    log_len: u64,
    fc_len: u64,
    log_sha: Key,
    fc_sha: Key,

    fn write(m: Meta, arena: Allocator) ![]const u8 {
        return std.fmt.allocPrint(arena, "format {s}\nkind {t}\nbytes {d}\nlog {d} {s}\n" ++
            "fc {d} {s}\n", .{
            store_format, m.kind,         m.bytes, m.log_len, &hex(m.log_sha),
            m.fc_len,     &hex(m.fc_sha),
        });
    }

    fn parse(text: []const u8) !Meta {
        var m: Meta = undefined;
        var lines = std.mem.splitScalar(u8, text, '\n');
        const want = [_][]const u8{ "format", "kind", "bytes", "log", "fc" };
        for (want) |name| {
            const line = lines.next() orelse return error.BadMeta;
            var f = std.mem.splitScalar(u8, line, ' ');
            if (!std.mem.eql(u8, f.next() orelse "", name)) return error.BadMeta;
            const v = f.rest();
            switch (name[0]) {
                'f' => if (name.len == 2) {
                    try parseFile(v, &m.fc_len, &m.fc_sha);
                } else if (!std.mem.eql(u8, v, store_format)) return error.BadMeta,
                'k' => m.kind = std.meta.stringToEnum(Kind, v) orelse return error.BadMeta,
                'b' => m.bytes = try std.fmt.parseInt(u64, v, 10),
                'l' => try parseFile(v, &m.log_len, &m.log_sha),
                else => unreachable,
            }
        }
        return m;
    }

    fn parseFile(v: []const u8, len: *u64, sha: *Key) !void {
        var f = std.mem.splitScalar(u8, v, ' ');
        len.* = try std.fmt.parseInt(u64, f.next() orelse return error.BadMeta, 10);
        _ = try std.fmt.hexToBytes(sha, f.next() orelse return error.BadMeta);
    }
};

/// The entry in `dir` read and checked whole: its tree there, its `meta` this format's, its
/// record's files of the lengths and sha256s it says, and the record one its kind may have.
fn readEntry(arena: Allocator, io: std.Io, dir: []const u8) !Record {
    const m = try metaOf(arena, io, dir);
    if (!isDir(arena, try join(arena, dir, "fs"))) return error.NoTree;
    const cwd = std.Io.Dir.cwd();
    const limit: std.Io.Limit = .limited(max_record_bytes + 1);
    const rec: Record = .{
        .log = try cwd.readFileAlloc(io, try join(arena, dir, "log"), arena, limit),
        .fc = try cwd.readFileAlloc(io, try join(arena, dir, "fc"), arena, limit),
    };
    if (rec.log.len != m.log_len or rec.fc.len != m.fc_len) return error.ShortRecord;
    var sha: Key = undefined;
    Sha256.hash(rec.log, &sha, .{});
    if (!std.mem.eql(u8, &sha, &m.log_sha)) return error.ChangedRecord;
    Sha256.hash(rec.fc, &sha, .{});
    if (!std.mem.eql(u8, &sha, &m.fc_sha)) return error.ChangedRecord;
    if (recordFault(m.kind, rec)) |e| return e;
    return rec;
}

fn metaOf(arena: Allocator, io: std.Io, dir: []const u8) !Meta {
    const text = try std.Io.Dir.cwd().readFileAlloc(io, try join(arena, dir, "meta"), arena, .limited(1024));
    return Meta.parse(text);
}

/// The cheap half of `readEntry`, for `collect`, which looks at every entry after every job: the
/// meta, the tree, and the record's files' lengths, without reading them.
fn entryLooksWhole(arena: Allocator, io: std.Io, dir: []const u8) ?Meta {
    const m = metaOf(arena, io, dir) catch return null;
    if (!isDir(arena, join(arena, dir, "fs") catch return null)) return null;
    for ([_]struct { []const u8, u64 }{ .{ "log", m.log_len }, .{ "fc", m.fc_len } }) |part| {
        const p = std.fmt.allocPrintSentinel(arena, "{s}/{s}", .{ dir, part[0] }, 0) catch
            return null;
        var st: linux.Statx = undefined;
        const mask: linux.STATX = .{ .TYPE = true, .SIZE = true };
        if (linux.errno(linux.statx(linux.AT.FDCWD, p, linux.AT.SYMLINK_NOFOLLOW, mask, &st)) !=
            .SUCCESS) return null;
        if (st.mode & linux.S.IFMT != linux.S.IFREG or st.size != part[1]) return null;
    }
    if (m.log_len > max_record_bytes or m.fc_len > max_record_bytes) return null;
    if (m.kind == .step and m.fc_len == 0) return null;
    return m;
}

fn isDir(arena: Allocator, p: []const u8) bool {
    const z = arena.dupeSentinel(u8, p, 0) catch return false;
    var st: linux.Statx = undefined;
    const rc = linux.statx(linux.AT.FDCWD, z, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true }, &st);
    return linux.errno(rc) == .SUCCESS and st.mode & linux.S.IFMT == linux.S.IFDIR;
}

/// Moves a finished upper (`upper`, in the job's directory) into the store under `key`, with its
/// record (`Record`, which must be one its `kind` may have and within `max_record_bytes`), and
/// holds it for the job. Built under a temporary name, written to disk (`syncfs`) before it is
/// visible, held before it is visible (so an eviction cannot take it at once), and published by
/// one rename that never replaces. On failure the upper is back where it was, or, if it cannot be
/// put back, left in the temporary entry and logged, never deleted.
pub fn publish(
    s: Store,
    arena: Allocator,
    io: std.Io,
    key: Key,
    kind: Kind,
    upper: []const u8,
    rec: Record,
) !Layer {
    if (recordFault(kind, rec)) |e| return e;
    const cwd = std.Io.Dir.cwd();
    var raw: [8]u8 = undefined;
    io.random(&raw);
    const tmp = try std.fmt.allocPrint(arena, "{s}/layers/.tmp-{s}-{s}", .{
        s.root,
        &hex(key),
        &std.fmt.bytesToHex(raw, .lower),
    });
    const fs_tmp = try join(arena, tmp, "fs");
    var moved = false;
    var lock: ?std.Io.File = null;
    try cwd.createDirPath(io, tmp);
    errdefer {
        if (lock) |l| l.close(io);
        const back = !moved or if (cwd.rename(fs_tmp, cwd, upper, io)) true else |e| no: {
            std.log.warn("native: cannot put {s} back from {s}: {s}", .{ upper, fs_tmp, @errorName(e) });
            break :no false;
        };
        if (back) removeTree(arena, io, tmp);
    }
    var m: Meta = .{
        .kind = kind,
        .bytes = treeBytes(arena, io, upper),
        .log_len = rec.log.len,
        .fc_len = rec.fc.len,
        .log_sha = undefined,
        .fc_sha = undefined,
    };
    Sha256.hash(rec.log, &m.log_sha, .{});
    Sha256.hash(rec.fc, &m.fc_sha, .{});
    try cwd.writeFile(io, .{ .sub_path = try join(arena, tmp, "log"), .data = rec.log });
    try cwd.writeFile(io, .{ .sub_path = try join(arena, tmp, "fc"), .data = rec.fc });
    try cwd.writeFile(io, .{ .sub_path = try join(arena, tmp, "meta"), .data = try m.write(arena) });
    lock = try cwd.createFile(io, try join(arena, tmp, "lock"), .{});
    if (!flock(lock.?, lock_sh)) return error.Locked;
    try cwd.rename(upper, cwd, fs_tmp, io);
    moved = true;
    // On disk before it is visible: a crash after the rename must not leave a whole-looking
    // entry whose files are empty or short.
    if (linux.errno(linux.syncfs(lock.?.handle)) != .SUCCESS) return error.Sync;
    const dir = try s.layerDir(arena, key);
    // One rename that never replaces: a layer published meanwhile stays, and this one is not.
    const rc = linux.renameat2(
        linux.AT.FDCWD,
        try arena.dupeSentinel(u8, tmp, 0),
        linux.AT.FDCWD,
        try arena.dupeSentinel(u8, dir, 0),
        .{ .NOREPLACE = true },
    );
    if (linux.errno(rc) != .SUCCESS) return error.Publish;
    return .{ .fs = try join(arena, dir, "fs"), .lock = lock.? };
}

fn join(arena: Allocator, dir: []const u8, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, name });
}

/// Keeps the store under `max_bytes`: the layers no job holds go, least recently used first.
/// Also removes what dead runners left (a layer half built, one half evicted) and the lock files
/// of keys no step is running. One runner at a time collects; another finding it busy goes on.
pub fn collect(s: Store, arena: Allocator, io: std.Io) void {
    const cwd = std.Io.Dir.cwd();
    const gc = cwd.createFile(io, join(arena, s.root, "gc.lock") catch return, .{
        .truncate = false,
    }) catch return;
    defer gc.close(io);
    if (!flock(gc, lock_ex | lock_nb)) return;

    const layers = join(arena, s.root, "layers") catch return;
    var dir = cwd.openDir(io, layers, .{ .iterate = true }) catch return;
    defer dir.close(io);
    const Entry = struct { name: []const u8, bytes: u64, used_ns: i128 };
    var entries: std.ArrayList(Entry) = .empty;
    var total: u64 = 0;
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        const full = join(arena, layers, e.name) catch return;
        if (std.mem.startsWith(u8, e.name, ".dead-")) {
            removeTree(arena, io, full);
            continue;
        }
        if (std.mem.startsWith(u8, e.name, ".tmp-")) {
            // Its publisher holds the key's lock while it builds; a free lock means it died.
            const key_hex = e.name[".tmp-".len..][0..@min(64, e.name.len - ".tmp-".len)];
            const lock_path = std.fmt.allocPrint(arena, "{s}/keys/{s}.lock", .{
                s.root,
                key_hex,
            }) catch return;
            const kl = cwd.createFile(io, lock_path, .{ .truncate = false }) catch continue;
            defer kl.close(io);
            if (flock(kl, lock_ex | lock_nb)) removeTree(arena, io, full);
            continue;
        }
        // An entry that cannot be replayed would only take room (`open` evicts it too).
        const meta = entryLooksWhole(arena, io, full) orelse {
            _ = s.evict(arena, io, e.name);
            continue;
        };
        const bytes = meta.bytes;
        var st: linux.Statx = undefined;
        const lock_z = arena.dupeSentinel(u8, join(arena, full, "lock") catch return, 0) catch
            return;
        const rc = linux.statx(linux.AT.FDCWD, lock_z, 0, .{ .MTIME = true }, &st);
        const used_ns: i128 = if (linux.errno(rc) == .SUCCESS)
            @as(i128, st.mtime.sec) * std.time.ns_per_s + st.mtime.nsec
        else
            0;
        total += bytes;
        entries.append(arena, .{
            .name = arena.dupe(u8, e.name) catch return,
            .bytes = bytes,
            .used_ns = used_ns,
        }) catch return;
    }
    if (total > s.max_bytes) {
        std.mem.sort(Entry, entries.items, {}, struct {
            fn lt(_: void, a: Entry, b: Entry) bool {
                return a.used_ns < b.used_ns;
            }
        }.lt);
        for (entries.items) |e| {
            if (total <= s.max_bytes) break;
            if (s.evict(arena, io, e.name)) total -|= e.bytes;
        }
    }
    s.dropKeyLocks(arena, io);
}

/// Removes one layer no job holds: renamed away under its lock taken exclusively (no job can
/// take it after that: the path names nothing), then deleted. False when a job holds it.
fn evict(s: Store, arena: Allocator, io: std.Io, name: []const u8) bool {
    const cwd = std.Io.Dir.cwd();
    const full = std.fmt.allocPrint(arena, "{s}/layers/{s}", .{ s.root, name }) catch return false;
    // An entry without its lock file (a broken one) no job can hold.
    const lock: ?std.Io.File = cwd.openFile(io, join(arena, full, "lock") catch return false, .{}) catch |e|
        if (e == error.FileNotFound) null else return false;
    defer if (lock) |l| l.close(io);
    if (lock) |l| if (!flock(l, lock_ex | lock_nb)) return false;
    var raw: [8]u8 = undefined;
    io.random(&raw);
    const dead = std.fmt.allocPrint(arena, "{s}/layers/.dead-{s}", .{
        s.root,
        &std.fmt.bytesToHex(raw, .lower),
    }) catch return false;
    cwd.rename(full, cwd, dead, io) catch return false;
    removeTree(arena, io, dead);
    return true;
}

/// The lock files of keys no step is running now, removed so `keys/` does not grow with every
/// key ever run. A runner that opened one just before is not misled (`lockKey`).
fn dropKeyLocks(s: Store, arena: Allocator, io: std.Io) void {
    const cwd = std.Io.Dir.cwd();
    const keys = join(arena, s.root, "keys") catch return;
    var dir = cwd.openDir(io, keys, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        const full = join(arena, keys, e.name) catch return;
        const f = cwd.openFile(io, full, .{}) catch continue;
        defer f.close(io);
        if (!flock(f, lock_ex | lock_nb)) continue;
        cwd.deleteFile(io, full) catch {};
    }
}

/// Whether `f` is the file `path` names now.
pub fn sameFile(arena: Allocator, f: std.Io.File, p: []const u8) bool {
    var held: linux.Statx = undefined;
    var named: linux.Statx = undefined;
    const z = arena.dupeSentinel(u8, p, 0) catch return false;
    const mask: linux.STATX = .{ .INO = true };
    if (linux.errno(linux.statx(f.handle, "", linux.AT.EMPTY_PATH, mask, &held)) != .SUCCESS)
        return false;
    if (linux.errno(linux.statx(linux.AT.FDCWD, z, 0, mask, &named)) != .SUCCESS) return false;
    return held.ino == named.ino and held.dev_major == named.dev_major and
        held.dev_minor == named.dev_minor;
}

/// Removes a tree, giving its directories their owner's permissions back first if a plain
/// delete fails (a step's `chmod 000`, overlay's work directory). What still fails is logged.
pub fn removeTree(arena: Allocator, io: std.Io, p: []const u8) void {
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, p) catch {
        chmodDirs(arena, io, p, 0);
        cwd.deleteTree(io, p) catch |e|
            std.log.warn("native: cannot remove {s}: {s}", .{ p, @errorName(e) });
    };
}

fn chmodDirs(arena: Allocator, io: std.Io, p: []const u8, depth: u32) void {
    if (depth > max_depth) return;
    const z = arena.dupeSentinel(u8, p, 0) catch return;
    _ = linux.chmod(z, 0o700);
    var dir = std.Io.Dir.cwd().openDir(io, p, .{ .iterate = true, .follow_symlinks = false }) catch
        return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind != .directory) continue;
        chmodDirs(arena, io, join(arena, p, e.name) catch return, depth + 1);
    }
}

const max_depth = 256;

// --- walking trees: sizes, digests, the rootfs's fingerprint ---

/// One entry of a directory, as `walk` sees it: never through a symlink.
const Node = struct {
    name: [:0]const u8,
    st: linux.Statx,

    fn kind(n: Node) u32 {
        return n.st.mode & linux.S.IFMT;
    }
};

const stat_mask: linux.STATX = .{
    .TYPE = true,
    .MODE = true,
    .UID = true,
    .GID = true,
    .SIZE = true,
    .MTIME = true,
    .CTIME = true,
    .INO = true,
    .BLOCKS = true,
    .NLINK = true,
};

/// The entries of the directory `fd`, sorted by name (as bytes), stat'ed without following
/// symlinks.
fn listDir(arena: Allocator, io: std.Io, fd: linux.fd_t) ![]Node {
    const dir: std.Io.Dir = .{ .handle = fd };
    var out: std.ArrayList(Node) = .empty;
    var it = dir.iterateAssumeFirstIteration();
    while (try it.next(io)) |e| {
        const name = try arena.dupeSentinel(u8, e.name, 0);
        var st: linux.Statx = undefined;
        const rc = linux.statx(fd, name, linux.AT.SYMLINK_NOFOLLOW, stat_mask, &st);
        if (linux.errno(rc) != .SUCCESS) return error.Stat;
        try out.append(arena, .{ .name = name, .st = st });
    }
    std.mem.sort(Node, out.items, {}, struct {
        fn lt(_: void, a: Node, b: Node) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.lt);
    return out.items;
}

fn openDirAt(fd: linux.fd_t, name: [*:0]const u8) !linux.fd_t {
    const flags: linux.O = .{
        .ACCMODE = .RDONLY,
        .DIRECTORY = true,
        .NOFOLLOW = true,
        .CLOEXEC = true,
    };
    const rc = linux.openat(fd, name, flags, 0);
    if (linux.errno(rc) != .SUCCESS) return error.OpenDir;
    return @intCast(rc);
}

fn openRoot(arena: Allocator, p: []const u8) !linux.fd_t {
    return openDirAt(linux.AT.FDCWD, try arena.dupeSentinel(u8, p, 0));
}

/// The bytes a tree takes on disk, each inode counted once.
pub fn treeBytes(arena: Allocator, io: std.Io, p: []const u8) u64 {
    const fd = openRoot(arena, p) catch return 0;
    defer _ = linux.close(fd);
    var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
    return bytesIn(arena, io, fd, &seen, 0);
}

fn bytesIn(
    arena: Allocator,
    io: std.Io,
    fd: linux.fd_t,
    seen: *std.AutoHashMapUnmanaged(u64, void),
    depth: u32,
) u64 {
    if (depth > max_depth) return 0;
    var total: u64 = 0;
    const nodes = listDir(arena, io, fd) catch return 0;
    for (nodes) |n| {
        if (n.st.nlink > 1) {
            const got = seen.getOrPut(arena, n.st.ino) catch continue;
            if (got.found_existing) continue;
        }
        total += n.st.blocks * 512;
        if (n.kind() != linux.S.IFDIR) continue;
        const sub = openDirAt(fd, n.name) catch continue;
        defer _ = linux.close(sub);
        total += bytesIn(arena, io, sub, seen, depth + 1);
    }
    return total;
}

/// How a job's namespace sees host ids: `base` onwards, `count` of them, as 0 onwards; any other
/// is the kernel's overflow id. A digest hashes ids so, never the host's.
pub const Ids = struct {
    base: u32 = 0,
    count: u32 = std.math.maxInt(u32),

    pub const host: Ids = .{};
    const overflow: u32 = 65534;

    fn inside(m: Ids, id: u32) u32 {
        if (id < m.base or id - m.base >= m.count) return overflow;
        return id - m.base;
    }
};

/// What a digest covers of a regular file: its content (a layer's digest), or only its size and
/// mtime (the rootfs's fingerprint, where reading every byte of an image would cost seconds).
pub const Depth = enum { content, metadata };

/// A tree's digest: sha256 over a walk in byte order of names of each entry's path, type, mode,
/// owner as the job's namespace sees it (`ids`, so a layer made in one slot's range of ids
/// digests as one made in another's), the xattrs that say what it is (sorted; overlay's
/// bookkeeping, `origin`, `impure` and the like, left out), and its content: a file's bytes (or
/// its size and mtime, `Depth.metadata`), a symlink's target, a device's numbers (an overlay
/// whiteout among them). The same tree gives the same digest wherever and whenever it was made:
/// mtimes (but for `metadata`), inode numbers and link counts are not in it.
pub fn treeDigest(arena: Allocator, io: std.Io, p: []const u8, depth: Depth, ids: Ids) !Key {
    const fd = try openRoot(arena, p);
    defer _ = linux.close(fd);
    var h: KeyHasher = .plain("tree");
    try digestIn(arena, io, &h, fd, "", depth, ids, 0);
    return h.final();
}

fn digestIn(
    arena: Allocator,
    io: std.Io,
    h: *KeyHasher,
    fd: linux.fd_t,
    rel: []const u8,
    depth: Depth,
    ids: Ids,
    level: u32,
) !void {
    if (level > max_depth) return error.TooDeep;
    for (try listDir(arena, io, fd)) |n| {
        const sub_rel = try std.fmt.allocPrint(arena, "{s}/{s}", .{ rel, n.name });
        h.field(sub_rel);
        h.int(n.st.mode);
        h.int(ids.inside(n.st.uid));
        h.int(ids.inside(n.st.gid));
        try digestXattrs(arena, h, fd, n);
        // The rootfs's fingerprint: any write, chmod or touch since moves an entry's ctime,
        // which no tool can set back (a tar restoring mtimes does not restore it).
        if (depth == .metadata) {
            h.int(n.st.ino);
            h.int(@bitCast(n.st.ctime.sec));
            h.int(n.st.ctime.nsec);
        }
        switch (n.kind()) {
            linux.S.IFREG => switch (depth) {
                .metadata => {
                    h.int(n.st.size);
                    h.int(@bitCast(n.st.mtime.sec));
                    h.int(n.st.mtime.nsec);
                },
                .content => {
                    const flags: linux.O = .{
                        .ACCMODE = .RDONLY,
                        .NOFOLLOW = true,
                        .CLOEXEC = true,
                    };
                    const f = linux.openat(fd, n.name, flags, 0);
                    if (linux.errno(f) != .SUCCESS) return error.Open;
                    defer _ = linux.close(@intCast(f));
                    var fh: Sha256 = .init(.{});
                    var buf: [64 * 1024]u8 = undefined;
                    while (true) {
                        const got = linux.read(@intCast(f), &buf, buf.len);
                        if (linux.errno(got) != .SUCCESS) return error.Read;
                        if (got == 0) break;
                        fh.update(buf[0..got]);
                    }
                    h.field(&fh.finalResult());
                },
            },
            linux.S.IFLNK => {
                var buf: [linux.PATH_MAX]u8 = undefined;
                const got = linux.readlinkat(fd, n.name, &buf, buf.len);
                if (linux.errno(got) != .SUCCESS) return error.ReadLink;
                h.field(buf[0..got]);
            },
            linux.S.IFCHR, linux.S.IFBLK => {
                h.int(n.st.rdev_major);
                h.int(n.st.rdev_minor);
            },
            linux.S.IFDIR => {
                const sub = try openDirAt(fd, n.name);
                defer _ = linux.close(sub);
                try digestIn(arena, io, h, sub, sub_rel, depth, ids, level + 1);
                h.field("..");
            },
            else => {},
        }
    }
}

/// Whether an xattr says what an entry is (a digest covers it), rather than being overlay's
/// bookkeeping about where it came from.
fn digestedXattr(name: []const u8) bool {
    for ([_][]const u8{ "trusted.overlay.", "user.overlay." }) |prefix| {
        if (!std.mem.startsWith(u8, name, prefix)) continue;
        const rest = name[prefix.len..];
        return std.mem.eql(u8, rest, "opaque") or std.mem.eql(u8, rest, "redirect") or
            std.mem.eql(u8, rest, "metacopy") or std.mem.eql(u8, rest, "whiteout");
    }
    return true;
}

fn digestXattrs(arena: Allocator, h: *KeyHasher, dir: linux.fd_t, n: Node) !void {
    const p = try procPath(arena, dir, n.name);
    const names = try xattrNames(arena, p);
    for (names) |name| {
        if (!digestedXattr(name)) continue;
        h.field(name);
        h.field(try xattrValue(arena, p, name) orelse "");
    }
}

/// A path to `name` in the directory `dir` for the `l*xattr` calls, which take no directory.
fn procPath(arena: Allocator, dir: linux.fd_t, name: []const u8) ![:0]const u8 {
    return std.fmt.allocPrintSentinel(arena, "/proc/self/fd/{d}/{s}", .{ dir, name }, 0);
}

/// The xattrs' names of `p` (not through a final symlink), sorted.
fn xattrNames(arena: Allocator, p: [:0]const u8) ![]const []const u8 {
    var buf: [64 * 1024]u8 = undefined;
    const got = linux.llistxattr(p, &buf, buf.len);
    switch (linux.errno(got)) {
        .SUCCESS => {},
        .OPNOTSUPP, .NODATA => return &.{},
        else => return error.ListXattr,
    }
    var out: std.ArrayList([]const u8) = .empty;
    var names = std.mem.splitScalar(u8, buf[0..got], 0);
    while (names.next()) |name| if (name.len > 0) try out.append(arena, try arena.dupe(u8, name));
    std.mem.sort([]const u8, out.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    return out.items;
}

fn xattrValue(arena: Allocator, p: [:0]const u8, name: []const u8) !?[]const u8 {
    var buf: [64 * 1024]u8 = undefined;
    const got = linux.lgetxattr(p, try arena.dupeSentinel(u8, name, 0), &buf, buf.len);
    switch (linux.errno(got)) {
        .SUCCESS => return try arena.dupe(u8, buf[0..got]),
        .NODATA => return null,
        else => return error.GetXattr,
    }
}

/// A layer's digest (`treeDigest` of its tree), computed when first asked for and then kept
/// beside it. What `changes(from:).layer.digest` gives the Dagger backend's output keys.
pub fn layerDigest(s: Store, arena: Allocator, io: std.Io, key: Key, ids: Ids) !Key {
    const dir = try s.layerDir(arena, key);
    const cwd = std.Io.Dir.cwd();
    const kept = try join(arena, dir, "digest");
    if (cwd.readFileAlloc(io, kept, arena, .limited(128))) |text| {
        var d: Key = undefined;
        if (std.fmt.hexToBytes(&d, std.mem.trim(u8, text, " \n"))) |_| return d else |_| {}
    } else |_| {}
    const d = try treeDigest(arena, io, try join(arena, dir, "fs"), .content, ids);
    // Written aside and renamed, so a reader never sees half of it.
    var raw: [8]u8 = undefined;
    io.random(&raw);
    const tmp = try std.fmt.allocPrint(arena, "{s}.{s}", .{
        kept,
        &std.fmt.bytesToHex(raw, .lower),
    });
    try cwd.writeFile(io, .{ .sub_path = tmp, .data = &hex(d) });
    cwd.rename(tmp, cwd, kept, io) catch cwd.deleteFile(io, tmp) catch {};
    return d;
}

/// The rootfs's fingerprint, for the base's parent (`Backend.below`): a rootfs made again gives
/// the jobs new keys. It is `treeDigest` of the metadata (ctimes and inodes among it), which a walk
/// of a whole image costs, so it is kept per process and checked again for every job against
/// what changes when the rootfs is replaced or touched: the root's inode and ctime, and the
/// provisioning stamp's (`rootfs_stamp`, which the recipe touches after changing the rootfs in
/// place). A change the stamp does not show, under a running runner, is found at its restart.
pub fn rootfsFingerprint(arena: Allocator, io: std.Io, rootfs: []const u8) !Key {
    const seen = try rootfsSeen(arena, rootfs);
    fp_mu.lockUncancelable(io);
    defer fp_mu.unlock(io);
    if (fp_len > 0 and std.mem.eql(u8, fp_path[0..fp_len], rootfs) and
        std.mem.eql(u8, &fp_seen, &seen)) return fp_key;
    var h: KeyHasher = .plain("rootfs");
    h.field(&try treeDigest(arena, io, rootfs, .metadata, .host));
    h.field(&seen);
    const k = h.final();
    if (rootfs.len <= fp_path.len) {
        @memcpy(fp_path[0..rootfs.len], rootfs);
        fp_len = rootfs.len;
        fp_key = k;
        fp_seen = seen;
    }
    return k;
}

/// The file, in the rootfs, that says it was provisioned again: touched after changing it in place
/// (docs/native-backend.md, "The rootfs").
pub const rootfs_stamp = ".zig-runner-provisioned";

/// What `rootfsFingerprint` checks for every job: the root's and the stamp's identity and ctime.
fn rootfsSeen(arena: Allocator, rootfs: []const u8) !Key {
    var h: KeyHasher = .plain("rootfs seen");
    for ([_][]const u8{ "", rootfs_stamp }) |name| {
        const p = try std.fmt.allocPrintSentinel(arena, "{s}/{s}", .{ rootfs, name }, 0);
        var st: linux.Statx = undefined;
        const mask: linux.STATX = .{ .INO = true, .CTIME = true };
        const rc = linux.statx(linux.AT.FDCWD, p, linux.AT.SYMLINK_NOFOLLOW, mask, &st);
        if (linux.errno(rc) != .SUCCESS) {
            if (name.len == 0) return error.RootfsUnreadable;
            h.field("none");
            continue;
        }
        h.int(st.dev_major);
        h.int(st.dev_minor);
        h.int(st.ino);
        h.int(@bitCast(st.ctime.sec));
        h.int(st.ctime.nsec);
    }
    return h.final();
}

var fp_mu: std.Io.Mutex = .init;
var fp_path: [std.Io.Dir.max_path_bytes]u8 = undefined;
var fp_len: usize = 0;
var fp_key: Key = undefined;
var fp_seen: Key = undefined;

// --- flattening ---

/// Merges overlay layers (`layers`, bottom first) into the new directory `out`, as overlay shows
/// them over what lies below: a later layer's entry replaces an earlier one's, its whiteout
/// deletes it (and is kept, to hide the rootfs below `out`), its opaque directory hides what
/// earlier ones had there (and stays opaque). Files are hard links, not copies, so a merge costs
/// directories and links, not bytes; directories are made with their owner, mode, xattrs and
/// times. `opaque_xattr` is overlay's (`trusted.overlay.opaque`, or `user.overlay.opaque` under
/// `userxattr`). Overlay's redirects and metacopy, which the runner never turns on, are refused.
pub fn flatten(
    arena: Allocator,
    io: std.Io,
    layers: []const []const u8,
    out: []const u8,
    opaque_xattr: [:0]const u8,
) !void {
    const out_z = try arena.dupeSentinel(u8, out, 0);
    if (linux.errno(linux.mkdir(out_z, 0o700)) != .SUCCESS) return error.MakeDir;
    const out_fd = try openRoot(arena, out);
    defer _ = linux.close(out_fd);
    var top: ?linux.fd_t = null;
    defer if (top) |t| {
        _ = linux.close(t);
    };
    for (layers) |l| {
        const src = try openRoot(arena, l);
        try merge(arena, io, src, out_fd, opaque_xattr, 0);
        if (top) |t| _ = linux.close(t);
        top = src;
    }
    // The root's own owner, mode and xattrs: the top layer's, as overlay shows them.
    if (top) |t| try copyDirMeta(arena, t, out_fd);
}

fn merge(
    arena: Allocator,
    io: std.Io,
    src: linux.fd_t,
    out: linux.fd_t,
    opaque_xattr: [:0]const u8,
    depth: u32,
) !void {
    if (depth > max_depth) return error.TooDeep;
    for (try listDir(arena, io, src)) |n| {
        var ost: linux.Statx = undefined;
        const rc = linux.statx(out, n.name, linux.AT.SYMLINK_NOFOLLOW, stat_mask, &ost);
        const exists = linux.errno(rc) == .SUCCESS;
        if (n.kind() != linux.S.IFDIR) {
            if (exists) try removeAt(arena, io, out, n.name, 0);
            // A whiteout too: kept, as it hides the rootfs's entry below.
            if (linux.errno(linux.linkat(src, n.name, out, n.name, 0)) != .SUCCESS)
                return error.Link;
            continue;
        }
        const p = try procPath(arena, src, n.name);
        for ([_][]const u8{ "redirect", "metacopy" }) |what| {
            const name = try std.fmt.allocPrint(arena, "{s}{s}", .{
                opaque_xattr[0 .. opaque_xattr.len - "opaque".len],
                what,
            });
            if (try xattrValue(arena, p, name) != null) return error.OverlayRedirectOrMetacopy;
        }
        const opaque_dir = if (try xattrValue(arena, p, opaque_xattr)) |v|
            std.mem.eql(u8, v, "y")
        else
            false;
        const merges = exists and (ost.mode & linux.S.IFMT) == linux.S.IFDIR and !opaque_dir;
        if (exists and !merges) try removeAt(arena, io, out, n.name, 0);
        if (!merges) {
            if (linux.errno(linux.mkdirat(out, n.name, 0o700)) != .SUCCESS) return error.MakeDir;
        } else _ = linux.fchmodat(out, n.name, 0o700);
        const s = try openDirAt(src, n.name);
        defer _ = linux.close(s);
        const o = try openDirAt(out, n.name);
        defer _ = linux.close(o);
        try merge(arena, io, s, o, opaque_xattr, depth + 1);
        try copyDirMeta(arena, s, o);
    }
}

/// A directory's owner, mode, xattrs and times from `src` onto `out`. Xattrs are set, never
/// removed, so an opaque `out` stays opaque: a later layer's plain directory over an opaque one
/// still hides the rootfs's.
fn copyDirMeta(arena: Allocator, src: linux.fd_t, out: linux.fd_t) !void {
    var st: linux.Statx = undefined;
    if (linux.errno(linux.statx(src, "", linux.AT.EMPTY_PATH, stat_mask, &st)) != .SUCCESS)
        return error.Stat;
    // Through `.`, so the `l*xattr` calls see the directory, not the magic link to it.
    const sp = try std.fmt.allocPrintSentinel(arena, "/proc/self/fd/{d}/.", .{src}, 0);
    for (try xattrNames(arena, sp)) |name| {
        if (!digestedXattr(name)) continue;
        const v = try xattrValue(arena, sp, name) orelse continue;
        const name_z = try arena.dupeSentinel(u8, name, 0);
        // An LSM's label (`security.selinux`) may be refused; the rest says what the entry is.
        if (linux.errno(linux.fsetxattr(out, name_z, v.ptr, v.len, 0)) != .SUCCESS and
            !std.mem.startsWith(u8, name, "security.")) return error.SetXattr;
    }
    if (linux.errno(linux.fchown(out, st.uid, st.gid)) != .SUCCESS) return error.Chown;
    if (linux.errno(linux.fchmod(out, st.mode & 0o7777)) != .SUCCESS) return error.Chmod;
    const times = [2]linux.timespec{
        .{ .sec = @intCast(st.mtime.sec), .nsec = @intCast(st.mtime.nsec) },
        .{ .sec = @intCast(st.mtime.sec), .nsec = @intCast(st.mtime.nsec) },
    };
    _ = linux.utimensat(out, null, &times, 0);
}

/// Removes `name` from the directory `dir`, a directory with everything in it.
fn removeAt(arena: Allocator, io: std.Io, dir: linux.fd_t, name: [*:0]const u8, depth: u32) !void {
    switch (linux.errno(linux.unlinkat(dir, name, 0))) {
        .SUCCESS, .NOENT => return,
        .ISDIR => {},
        else => return error.Unlink,
    }
    if (depth > max_depth) return error.TooDeep;
    _ = linux.fchmodat(dir, name, 0o700);
    const sub = try openDirAt(dir, name);
    {
        defer _ = linux.close(sub);
        for (try listDir(arena, io, sub)) |n| try removeAt(arena, io, sub, n.name, depth + 1);
    }
    if (linux.errno(linux.unlinkat(dir, name, linux.AT.REMOVEDIR)) != .SUCCESS)
        return error.Unlink;
}

// --- tests ---

test "native store: a tree's digest: the same tree anywhere digests alike; content, mode and xattrs count" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const d = tmp.dir;
    // The same files, made in different orders at different times.
    for ([_][]const u8{ "x", "y" }) |top| {
        const order: []const []const u8 = if (top[0] == 'x')
            &.{ "a/b/one", "a/two", "three" }
        else
            &.{ "three", "a/two", "a/b/one" };
        for (order) |f| {
            const p = try std.fmt.allocPrint(arena, "{s}/{s}", .{ top, f });
            try d.createDirPath(io, std.fs.path.dirname(p).?);
            try d.writeFile(io, .{ .sub_path = p, .data = f });
        }
        try d.symLink(io, "three", try std.fmt.allocPrint(arena, "{s}/link", .{top}), .{});
    }
    const root = try d.realPathFileAlloc(io, ".", arena);
    const x = try std.fmt.allocPrint(arena, "{s}/x", .{root});
    const y = try std.fmt.allocPrint(arena, "{s}/y", .{root});
    const dx = try treeDigest(arena, io, x, .content, .host);
    try std.testing.expectEqualSlices(u8, &dx, &try treeDigest(arena, io, y, .content, .host));
    // The content counts.
    try d.writeFile(io, .{ .sub_path = "y/a/two", .data = "changed" });
    const changed = try treeDigest(arena, io, y, .content, .host);
    try std.testing.expect(!std.mem.eql(u8, &dx, &changed));
    try d.writeFile(io, .{ .sub_path = "y/a/two", .data = "a/two" });
    try std.testing.expectEqualSlices(u8, &dx, &try treeDigest(arena, io, y, .content, .host));
    // The mode counts.
    const two = try arena.dupeSentinel(u8, try std.fmt.allocPrint(arena, "{s}/a/two", .{y}), 0);
    var was: linux.Statx = undefined;
    _ = linux.statx(linux.AT.FDCWD, two, 0, .{ .MODE = true }, &was);
    _ = linux.chmod(two, 0o600);
    try std.testing.expect(!std.mem.eql(u8, &dx, &try treeDigest(arena, io, y, .content, .host)));
    _ = linux.chmod(two, was.mode & 0o7777);
    try std.testing.expectEqualSlices(u8, &dx, &try treeDigest(arena, io, y, .content, .host));
    // A user xattr counts, where the filesystem has them.
    if (linux.errno(linux.setxattr(two, "user.zr", "v", 1, 0)) == .SUCCESS)
        try std.testing.expect(!std.mem.eql(u8, &dx, &try treeDigest(arena, io, y, .content, .host)));
    // A metadata digest sees a touch the content digest does not.
    const mx = try treeDigest(arena, io, x, .metadata, .host);
    const one = try arena.dupeSentinel(u8, try std.fmt.allocPrint(arena, "{s}/a/b/one", .{x}), 0);
    const t = [2]linux.timespec{ .{ .sec = 1, .nsec = 0 }, .{ .sec = 1, .nsec = 0 } };
    _ = linux.utimensat(linux.AT.FDCWD, one, &t, 0);
    try std.testing.expect(!std.mem.eql(u8, &mx, &try treeDigest(arena, io, x, .metadata, .host)));
    try std.testing.expectEqualSlices(u8, &dx, &try treeDigest(arena, io, x, .content, .host));
}

test "native store: flattening layers: later entries win, whiteouts are kept, opaque directories hide" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const d = tmp.dir;
    const files = [_][2][]const u8{
        .{ "l0/keep", "0" },       .{ "l0/replaced", "0" }, .{ "l0/dir/old", "0" },
        .{ "l0/merged/a", "0" },   .{ "l1/replaced", "1" }, .{ "l1/dir/new", "1" },
        .{ "l1/merged/b", "1" },   .{ "l2/gone", "2" },     .{ "l2/became-dir/x", "2" },
        .{ "l0/became-dir", "0" },
    };
    for (files) |f| {
        try d.createDirPath(io, std.fs.path.dirname(f[0]).?);
        try d.writeFile(io, .{ .sub_path = f[0], .data = f[1] });
    }
    const root = try d.realPathFileAlloc(io, ".", arena);
    const opaque_name = "user.overlay.opaque";
    // l1's `dir` is opaque: l0's `dir/old` is hidden.
    const dir1 = try std.fmt.allocPrintSentinel(arena, "{s}/l1/dir", .{root}, 0);
    if (linux.errno(linux.setxattr(dir1, opaque_name, "y", 1, 0)) != .SUCCESS)
        return error.SkipZigTest; // no user xattrs here
    // l2 deletes `keep` with a whiteout; a whiteout needs CAP_MKNOD, so where it cannot be made
    // the case is left out.
    const wh = try std.fmt.allocPrintSentinel(arena, "{s}/l2/keep", .{root}, 0);
    const whiteout = linux.errno(linux.mknod(wh, linux.S.IFCHR | 0o000, 0)) == .SUCCESS;
    const layers = [_][]const u8{
        try std.fmt.allocPrint(arena, "{s}/l0", .{root}),
        try std.fmt.allocPrint(arena, "{s}/l1", .{root}),
        try std.fmt.allocPrint(arena, "{s}/l2", .{root}),
    };
    const out = try std.fmt.allocPrint(arena, "{s}/out", .{root});
    try flatten(arena, io, &layers, out, opaque_name);
    const read = struct {
        fn f(ar: Allocator, dd: std.Io.Dir, p: []const u8) ?[]const u8 {
            return dd.readFileAlloc(std.testing.io, p, ar, .limited(64)) catch null;
        }
    }.f;
    try std.testing.expectEqualStrings("1", read(arena, d, "out/replaced").?);
    try std.testing.expectEqualStrings("1", read(arena, d, "out/dir/new").?);
    try std.testing.expect(read(arena, d, "out/dir/old") == null);
    try std.testing.expectEqualStrings("0", read(arena, d, "out/merged/a").?);
    try std.testing.expectEqualStrings("1", read(arena, d, "out/merged/b").?);
    try std.testing.expectEqualStrings("2", read(arena, d, "out/gone").?);
    try std.testing.expectEqualStrings("2", read(arena, d, "out/became-dir/x").?);
    // The opaque directory stays opaque, for the rootfs below.
    const out_dir = try std.fmt.allocPrintSentinel(arena, "{s}/out/dir", .{root}, 0);
    var v: [4]u8 = undefined;
    const got = linux.getxattr(out_dir, opaque_name, &v, v.len);
    try std.testing.expectEqualStrings("y", v[0..got]);
    if (whiteout) {
        var st: linux.Statx = undefined;
        const p = try std.fmt.allocPrintSentinel(arena, "{s}/out/keep", .{root}, 0);
        try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.statx(linux.AT.FDCWD, p, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true }, &st)));
        try std.testing.expectEqual(@as(u32, linux.S.IFCHR), st.mode & linux.S.IFMT);
    } else try std.testing.expectEqualStrings("0", read(arena, d, "out/keep").?);
    // Files are links to the layers' own, not copies.
    var s0: linux.Statx = undefined;
    var s1: linux.Statx = undefined;
    const a0 = try std.fmt.allocPrintSentinel(arena, "{s}/l1/replaced", .{root}, 0);
    const a1 = try std.fmt.allocPrintSentinel(arena, "{s}/out/replaced", .{root}, 0);
    _ = linux.statx(linux.AT.FDCWD, a0, 0, .{ .INO = true }, &s0);
    _ = linux.statx(linux.AT.FDCWD, a1, 0, .{ .INO = true }, &s1);
    try std.testing.expectEqual(s0.ino, s1.ino);
}

test "native store: a published layer is found and held; eviction keeps under the cap, never a held one" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const s: Store = .{ .root = try std.fmt.allocPrint(arena, "{s}/store", .{root}), .max_bytes = 0 };
    try prepare(arena, io, s.root);
    var keys: [3]Key = undefined;
    var held: [3]?Layer = .{ null, null, null };
    defer for (held) |h| if (h) |l| l.lock.close(io);
    for (&keys, 0..) |*k, i| {
        var kh: KeyHasher = .plain("test");
        kh.int(i);
        k.* = kh.final();
        try std.testing.expect(try s.open(arena, io, k.*) == null);
        const upper = try std.fmt.allocPrint(arena, "{s}/up{d}", .{ root, i });
        try tmp.dir.createDirPath(io, try std.fmt.allocPrint(arena, "up{d}/d", .{i}));
        try tmp.dir.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(arena, "up{d}/d/f", .{i}), .data = &@as([5000]u8, @splat('x')) });
        var never: std.atomic.Value(bool) = .init(false);
        const kl = try s.lockKey(arena, io, k.*, &never);
        defer kl.close(io);
        const l = try s.publish(arena, io, k.*, .step, upper, .{ .log = "the log\n", .fc = "::zig-file-command::ran\nj1\n" });
        // The upper moved in.
        try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, try std.fmt.allocPrint(arena, "up{d}", .{i}), .{}));
        held[i] = l;
        const hit = (try s.open(arena, io, k.*)).?;
        hit.layer.lock.close(io);
        try std.testing.expectEqualStrings("the log\n", hit.rec.log);
        try std.testing.expectEqualStrings("::zig-file-command::ran\nj1\n", hit.rec.fc);
    }
    // Over the cap (0), but every layer is held: nothing goes.
    s.collect(arena, io);
    for (keys) |k| {
        const h = (try s.open(arena, io, k)).?;
        h.layer.lock.close(io);
    }
    // Let the first two go: they are evicted, the held one stays, and a new open misses.
    for (held[0..2]) |*h| {
        h.*.?.lock.close(io);
        h.* = null;
    }
    s.collect(arena, io);
    try std.testing.expect(try s.open(arena, io, keys[0]) == null);
    try std.testing.expect(try s.open(arena, io, keys[1]) == null);
    const kept = (try s.open(arena, io, keys[2])).?.layer;
    kept.lock.close(io);
    // Its digest, kept once computed, is the tree's.
    const d1 = try s.layerDigest(arena, io, keys[2], .host);
    const d2 = try s.layerDigest(arena, io, keys[2], .host);
    try std.testing.expectEqualSlices(u8, &d1, &d2);
    try std.testing.expectEqualSlices(u8, &d1, &try treeDigest(arena, io, kept.fs, .content, .host));
    // The key locks of steps no longer running were dropped.
    var kd = try tmp.dir.openDir(io, "store/keys", .{ .iterate = true });
    defer kd.close(io);
    var it = kd.iterate();
    try std.testing.expect(try it.next(io) == null);
}

test "native store: a key's lock: a second taker waits, and a stop ends its wait" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const s: Store = .{ .root = root };
    try prepare(arena, io, root);
    var kh: KeyHasher = .plain("test");
    const k = kh.final();
    var never: std.atomic.Value(bool) = .init(false);
    const first = try s.lockKey(arena, io, k, &never);
    var stop: std.atomic.Value(bool) = .init(true);
    try std.testing.expectError(error.Stopped, s.lockKey(arena, io, k, &stop));
    first.close(io);
    const second = try s.lockKey(arena, io, k, &never);
    second.close(io);
}

test "native store: a key's preimage is P8's: tag, parent, script, then the stable env counted" {
    // P8's vector `volatile-absent` (native/testdata/step_keys.tsv on its branch): GITHUB_RUN_ID
    // is volatile, so the env counts 2.
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    // `init(.step)`, with the bytes seen from the tag on.
    var k: KeyHasher = .{ .h = .init(.{}), .bytes = &w };
    k.int(@backingInt(Tag.step));
    const Binding = struct { name: []const u8, value: []const u8 };
    k.core(@splat(0), ": step 1\nmake test", &[_]Binding{
        .{ .name = "PATH", .value = "/usr/bin:/bin" },
        .{ .name = "GITHUB_RUN_ID", .value = "123" },
        .{ .name = "HOME", .value = "/root" },
    });
    const want_hex = "01000000000000002000000000000000000000000000000000000000000000000000000000000000" ++
        "000000000000000012000000000000003a207374657020310a6d616b652074657374020000000000" ++
        "00000400000000000000504154480d000000000000002f7573722f62696e3a2f62696e0400000000" ++
        "000000484f4d4505000000000000002f726f6f74";
    var want: [want_hex.len / 2]u8 = undefined;
    _ = try std.fmt.hexToBytes(&want, want_hex);
    try std.testing.expectEqualSlices(u8, &want, w.buffered());
    var plain: [32]u8 = undefined;
    Sha256.hash(&want, &plain, .{});
    try std.testing.expectEqualSlices(u8, &plain, &k.final());
}

test "native store: a digest sees ids as the job's namespace does, never the host's" {
    try std.testing.expectEqual(@as(u32, 0), (Ids{ .base = 1000, .count = 1 }).inside(1000));
    try std.testing.expectEqual(@as(u32, 65534), (Ids{ .base = 1000, .count = 1 }).inside(0));
    try std.testing.expectEqual(@as(u32, 1001), (Ids{ .base = 1_900_000_000, .count = 65536 }).inside(1_900_001_001));
    try std.testing.expectEqual(@as(u32, 65534), (Ids{ .base = 1_900_000_000, .count = 65536 }).inside(1_900_065_536));
}

test "native store: the rootfs's fingerprint changes when the rootfs is changed in place" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "rootfs/usr/bin");
    try tmp.dir.writeFile(io, .{ .sub_path = "rootfs/usr/bin/tool", .data = "v1" });
    const rootfs = try tmp.dir.realPathFileAlloc(io, "rootfs", arena);
    const first = try rootfsFingerprint(arena, io, rootfs);
    try std.testing.expectEqualSlices(u8, &first, &try rootfsFingerprint(arena, io, rootfs));
    // Provisioned again in place, as `tar -x` over it does: same size, mtime set back. The ctime
    // moved, but only a new walk sees it; the stamp, touched after, makes the next job walk.
    try tmp.dir.writeFile(io, .{ .sub_path = "rootfs/usr/bin/tool", .data = "v2" });
    const tool = try std.fmt.allocPrintSentinel(arena, "{s}/usr/bin/tool", .{rootfs}, 0);
    const t = [2]linux.timespec{ .{ .sec = 1, .nsec = 0 }, .{ .sec = 1, .nsec = 0 } };
    _ = linux.utimensat(linux.AT.FDCWD, tool, &t, 0);
    try tmp.dir.writeFile(io, .{ .sub_path = "rootfs/" ++ rootfs_stamp, .data = "" });
    const second = try rootfsFingerprint(arena, io, rootfs);
    try std.testing.expect(!std.mem.eql(u8, &first, &second));
    // A walk sees an in-place change by its ctime even with the stamp untouched, as at a
    // restart, when nothing is kept.
    _ = linux.utimensat(linux.AT.FDCWD, tool, &t, 0);
    fp_len = 0;
    const third = try rootfsFingerprint(arena, io, rootfs);
    try std.testing.expect(!std.mem.eql(u8, &second, &third));
}

test "native store: a record that cannot be replayed is refused, and a broken entry is evicted" {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    const arena = a.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const s: Store = .{ .root = try std.fmt.allocPrint(arena, "{s}/store", .{root}) };
    try prepare(arena, io, s.root);
    try tmp.dir.createDirPath(io, "up");
    const upper = try std.fmt.allocPrint(arena, "{s}/up", .{root});
    var kh: KeyHasher = .plain("test");
    const k = kh.final();
    const ran = "::zig-file-command::ran\nj1\n";
    // Refused, and the upper left where it was: a step's file commands without their ran marker
    // or empty, a base's with any, and file commands past the limit.
    const big = try arena.alloc(u8, max_record_bytes + 1);
    @memset(big, 'x');
    const refused = [_]struct { Kind, Record }{
        .{ .step, .{ .log = "", .fc = "::zig-file-command::env\n" } },
        .{ .step, .{ .log = "", .fc = "" } },
        .{ .base, .{ .log = "", .fc = ran } },
        .{ .step, .{ .log = "", .fc = big } },
    };
    for (refused) |r| {
        try std.testing.expect(std.meta.isError(s.publish(arena, io, k, r[0], upper, r[1])));
        try tmp.dir.access(io, "up", .{});
    }
    // A base's empty record is whole.
    const base = try s.publish(arena, io, k, .base, upper, .{ .log = "", .fc = "" });
    base.lock.close(io);
    (try s.open(arena, io, k)).?.layer.lock.close(io);

    // A step's entry whose log was cut short afterwards: a miss, and evicted, so it can be
    // published again.
    var kh2: KeyHasher = .plain("test 2");
    const k2 = kh2.final();
    try tmp.dir.createDirPath(io, "up2");
    const up2 = try std.fmt.allocPrint(arena, "{s}/up2", .{root});
    const l = try s.publish(arena, io, k2, .step, up2, .{ .log = "a whole log\n", .fc = ran });
    l.lock.close(io);
    const log_path = try std.fmt.allocPrint(arena, "store/layers/{s}/log", .{&hex(k2)});
    try tmp.dir.writeFile(io, .{ .sub_path = log_path, .data = "a who" });
    try std.testing.expect(try s.open(arena, io, k2) == null);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, log_path, .{}));
    // `collect` removes one too, by its lengths, without reading it.
    try tmp.dir.createDirPath(io, "up3");
    const up3 = try std.fmt.allocPrint(arena, "{s}/up3", .{root});
    (try s.publish(arena, io, k2, .step, up3, .{ .log = "a whole log\n", .fc = ran })).lock.close(io);
    try tmp.dir.writeFile(io, .{ .sub_path = log_path, .data = "a who" });
    s.collect(arena, io);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, log_path, .{}));
}
