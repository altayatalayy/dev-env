//! The source-builds.json manifest: the index of pre-built, source-compiled
//! tool archives a release server offers. `dev-env build` writes/merges it in
//! the builder; a target consults it to download and verify the right archive
//! for its platform instead of ever compiling locally.

const std = @import("std");
const json = @import("json.zig");

pub const Entry = struct {
    tool: []const u8,
    version: []const u8,
    /// OS identifier, e.g. "ubuntu" or "fedora".
    platform: []const u8,
    /// OS version, e.g. "24.04", "26.04", or "44".
    platform_version: []const u8,
    /// "x86_64" or "aarch64".
    arch: []const u8,
    filename: []const u8,
    /// Lowercase hex SHA-256 of the archive named by `filename`.
    sha256: []const u8,
};

pub const Manifest = struct {
    builds: []const Entry = &.{},
};

pub const Error = error{
    InvalidManifestEntry,
    InvalidSha256,
    DuplicateManifestEntry,
};

pub fn parse(alloc: std.mem.Allocator, slice: []const u8) !Manifest {
    return json.parse(Manifest, alloc, slice);
}

/// One archive is identified by (tool, platform, platform_version, arch); the
/// version/filename/sha256 are the looked-up result.
pub fn select(
    manifest: Manifest,
    tool: []const u8,
    platform: []const u8,
    platform_version: []const u8,
    arch: []const u8,
) ?Entry {
    for (manifest.builds) |entry| {
        if (sameKey(entry, tool, platform, platform_version, arch)) return entry;
    }
    return null;
}

fn sameKey(
    entry: Entry,
    tool: []const u8,
    platform: []const u8,
    platform_version: []const u8,
    arch: []const u8,
) bool {
    return std.mem.eql(u8, entry.tool, tool) and
        std.mem.eql(u8, entry.platform, platform) and
        std.mem.eql(u8, entry.platform_version, platform_version) and
        std.mem.eql(u8, entry.arch, arch);
}

pub fn validate(manifest: Manifest) Error!void {
    for (manifest.builds, 0..) |entry, i| {
        try validateEntry(entry);
        for (manifest.builds[i + 1 ..]) |other| {
            if (sameKey(other, entry.tool, entry.platform, entry.platform_version, entry.arch)) {
                return error.DuplicateManifestEntry;
            }
        }
    }
}

pub fn validateEntry(entry: Entry) Error!void {
    if (entry.tool.len == 0 or entry.version.len == 0 or entry.platform.len == 0 or
        entry.platform_version.len == 0 or entry.arch.len == 0 or entry.filename.len == 0)
    {
        return error.InvalidManifestEntry;
    }
    if (!isSha256Hex(entry.sha256)) return error.InvalidSha256;
}

fn isSha256Hex(text: []const u8) bool {
    if (text.len != 64) return false;
    for (text) |c| {
        const hex = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        if (!hex) return false;
    }
    return true;
}

/// Merges `additions` into `base`, replacing any existing entry sharing the
/// same (tool, platform, platform_version, arch) key so a rebuild supersedes
/// an older archive.
pub fn merge(alloc: std.mem.Allocator, base: Manifest, additions: []const Entry) !Manifest {
    var out: std.ArrayList(Entry) = .empty;
    for (base.builds) |entry| {
        if (containsKey(additions, entry)) continue;
        try out.append(alloc, entry);
    }
    try out.appendSlice(alloc, additions);
    return .{ .builds = out.items };
}

fn containsKey(entries: []const Entry, key: Entry) bool {
    for (entries) |entry| {
        if (sameKey(entry, key.tool, key.platform, key.platform_version, key.arch)) return true;
    }
    return false;
}

pub fn sha256Hex(bytes: []const u8) [64]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// Reads `path` and checks its SHA-256 against `expected`. A missing file is a
/// hard error, as is a digest mismatch.
pub fn verifyFile(
    alloc: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    expected: []const u8,
) !void {
    const contents = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return error.ArchiveMissing,
        else => return err,
    };
    defer alloc.free(contents);

    const actual = sha256Hex(contents);
    if (!std.mem.eql(u8, &actual, expected)) return error.Sha256Mismatch;
}

// --- tests ---

const testing = std.testing;

const sample_json =
    \\{"builds":[
    \\  {"tool":"tmux","version":"3.5a","platform":"ubuntu","platform_version":"24.04","arch":"x86_64","filename":"tmux-3.5a-ubuntu-24.04-x86_64.tar.zst","sha256":"0000000000000000000000000000000000000000000000000000000000000000"},
    \\  {"tool":"tmux","version":"3.5a","platform":"fedora","platform_version":"44","arch":"x86_64","filename":"tmux-3.5a-fedora-44-x86_64.tar.zst","sha256":"1111111111111111111111111111111111111111111111111111111111111111"}
    \\]}
;

test "parse and validate manifest" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const manifest = try parse(alloc, sample_json);
    try testing.expectEqual(@as(usize, 2), manifest.builds.len);
    try validate(manifest);
}

test "archive selection by platform key" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const manifest = try parse(alloc, sample_json);
    const fedora = select(manifest, "tmux", "fedora", "44", "x86_64").?;
    try testing.expectEqualStrings("tmux-3.5a-fedora-44-x86_64.tar.zst", fedora.filename);

    try testing.expectEqual(@as(?Entry, null), select(manifest, "tmux", "ubuntu", "26.04", "x86_64"));
    try testing.expectEqual(@as(?Entry, null), select(manifest, "git", "ubuntu", "24.04", "x86_64"));
}

test "validate rejects bad sha256 and empty fields" {
    const bad_hash: Manifest = .{ .builds = &.{.{
        .tool = "tmux",
        .version = "3.5a",
        .platform = "ubuntu",
        .platform_version = "24.04",
        .arch = "x86_64",
        .filename = "tmux.tar.zst",
        .sha256 = "xyz",
    }} };
    try testing.expectError(error.InvalidSha256, validate(bad_hash));

    const empty_tool: Manifest = .{ .builds = &.{.{
        .tool = "",
        .version = "3.5a",
        .platform = "ubuntu",
        .platform_version = "24.04",
        .arch = "x86_64",
        .filename = "tmux.tar.zst",
        .sha256 = "0000000000000000000000000000000000000000000000000000000000000000",
    }} };
    try testing.expectError(error.InvalidManifestEntry, validate(empty_tool));
}

test "validate rejects duplicate keys" {
    const dup: Manifest = .{ .builds = &.{
        .{ .tool = "tmux", .version = "3.5a", .platform = "ubuntu", .platform_version = "24.04", .arch = "x86_64", .filename = "a", .sha256 = "0000000000000000000000000000000000000000000000000000000000000000" },
        .{ .tool = "tmux", .version = "3.6", .platform = "ubuntu", .platform_version = "24.04", .arch = "x86_64", .filename = "b", .sha256 = "1111111111111111111111111111111111111111111111111111111111111111" },
    } };
    try testing.expectError(error.DuplicateManifestEntry, validate(dup));
}

test "merge supersedes entries sharing a key" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const base = try parse(alloc, sample_json);
    const rebuilt = [_]Entry{.{
        .tool = "tmux",
        .version = "3.6",
        .platform = "ubuntu",
        .platform_version = "24.04",
        .arch = "x86_64",
        .filename = "tmux-3.6-ubuntu-24.04-x86_64.tar.zst",
        .sha256 = "2222222222222222222222222222222222222222222222222222222222222222",
    }};

    const merged = try merge(alloc, base, &rebuilt);
    try validate(merged);
    try testing.expectEqual(@as(usize, 2), merged.builds.len);
    const ubuntu = select(merged, "tmux", "ubuntu", "24.04", "x86_64").?;
    try testing.expectEqualStrings("3.6", ubuntu.version);
    // The fedora entry is untouched.
    try testing.expect(select(merged, "tmux", "fedora", "44", "x86_64") != null);
}

test "verifyFile detects mismatch and missing archive" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", alloc);

    const path = try std.fs.path.join(alloc, &.{ dir, "archive.bin" });
    const payload = "hello dev-env";
    {
        const file = try std.Io.Dir.createFileAbsolute(io, path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, payload);
    }

    const good = sha256Hex(payload);
    try verifyFile(alloc, io, path, &good);

    try testing.expectError(
        error.Sha256Mismatch,
        verifyFile(alloc, io, path, "0000000000000000000000000000000000000000000000000000000000000000"),
    );

    const missing = try std.fs.path.join(alloc, &.{ dir, "nope.bin" });
    try testing.expectError(error.ArchiveMissing, verifyFile(alloc, io, missing, &good));
}
