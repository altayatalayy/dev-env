//! Renders installed tool environment exports as `NAME=value` lines.

const std = @import("std");
const shared = @import("shared");
const proto = shared.protocol;
const templates = shared.templates;
const paths_mod = @import("paths.zig");
const receipt_mod = @import("receipt.zig");

pub const Entry = struct {
    name: []const u8,
    value: []const u8,
};

pub fn run(
    alloc: std.mem.Allocator,
    io: std.Io,
    paths: paths_mod.Paths,
    environ_map: *std.process.Environ.Map,
) !void {
    const receipt = (try receipt_mod.load(alloc, io, paths.installed)) orelse return error.NotInstalled;
    const entries = try collect(alloc, receipt, paths.home, environ_map.get("PATH") orelse "");

    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buffer);
    try writeEntries(&writer.interface, entries);
    try writer.interface.flush();
}

pub fn collect(
    alloc: std.mem.Allocator,
    receipt: receipt_mod.Receipt,
    home: []const u8,
    base_path: []const u8,
) ![]const Entry {
    var entries: std.ArrayList(Entry) = .empty;

    try putEntry(alloc, &entries, "PATH", base_path);
    try prependPathEntry(alloc, &entries, "PATH", receipt.install_layout.bin);

    const vars: templates.Vars = .{
        .home = home,
        .cache_dir = receipt.install_layout.cache_dir,
        .bin = receipt.install_layout.bin,
        .opt = receipt.install_layout.opt,
    };

    for (receipt.tools) |tool| {
        for (tool.env_exports) |item| {
            const value = try templates.render(alloc, item.value, vars);
            switch (item.mode) {
                .set => try putEntry(alloc, &entries, item.name, value),
                .prepend_path => try prependPathEntry(alloc, &entries, item.name, value),
            }
        }
    }

    return entries.items;
}

pub fn writeEntries(writer: *std.Io.Writer, entries: []const Entry) !void {
    for (entries) |entry| {
        try writer.print("{s}={s}\n", .{ entry.name, entry.value });
    }
}

fn putEntry(
    alloc: std.mem.Allocator,
    entries: *std.ArrayList(Entry),
    name: []const u8,
    value: []const u8,
) !void {
    try validateEntry(name, value);
    for (entries.items) |*entry| {
        if (std.mem.eql(u8, entry.name, name)) {
            entry.value = value;
            return;
        }
    }
    try entries.append(alloc, .{ .name = name, .value = value });
}

fn prependPathEntry(
    alloc: std.mem.Allocator,
    entries: *std.ArrayList(Entry),
    name: []const u8,
    dir: []const u8,
) !void {
    if (dir.len == 0) return;
    try validateEntry(name, dir);

    for (entries.items) |*entry| {
        if (!std.mem.eql(u8, entry.name, name)) continue;
        entry.value = try prependPath(alloc, entry.value, dir);
        return;
    }

    try entries.append(alloc, .{ .name = name, .value = dir });
}

fn prependPath(alloc: std.mem.Allocator, existing: []const u8, dir: []const u8) ![]const u8 {
    if (existing.len == 0) return dir;

    var parts: std.ArrayList([]const u8) = .empty;
    try parts.append(alloc, dir);

    var it = std.mem.tokenizeScalar(u8, existing, ':');
    while (it.next()) |part| {
        if (!std.mem.eql(u8, part, dir)) try parts.append(alloc, part);
    }

    return std.mem.join(alloc, ":", parts.items);
}

fn validateEntry(name: []const u8, value: []const u8) !void {
    if (!validName(name)) return error.InvalidEnvName;
    if (std.mem.indexOfAny(u8, value, "\n\r") != null) return error.InvalidEnvValue;
}

fn validName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!std.ascii.isAlphabetic(name[0]) and name[0] != '_') return false;
    for (name[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
}

// --- tests ---

test "collect renders installed tool exports" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const receipt: receipt_mod.Receipt = .{
        .installer_release = "0.1.0",
        .installer_path = "/x/dev-env-install",
        .platform = .{ .ubuntu = .{ .version = "24.04", .arch = .x86_64 } },
        .install_layout = .{
            .bin = "/home/u/.local/bin",
            .opt = "/home/u/.local/share/dev-env/tools",
            .cache_dir = "/home/u/.cache/dev-env",
        },
        .tools = &.{
            .{
                .tool = "go",
                .kind = .archive,
                .version = "1.24.4",
                .env_exports = &.{
                    .{ .name = "GOROOT", .value = "{opt}/go/1.24.4" },
                    .{ .name = "GOPATH", .value = "{home}/.local/share/go" },
                    .{ .name = "PATH", .value = "{opt}/go/1.24.4/bin", .mode = .prepend_path },
                    .{ .name = "PATH", .value = "{home}/.local/share/go/bin", .mode = .prepend_path },
                },
            },
        },
    };

    const entries = try collect(alloc, receipt, "/home/u", "/usr/bin:/home/u/.local/bin");
    try std.testing.expectEqual(@as(usize, 3), entries.len);
    try std.testing.expectEqualStrings("PATH", entries[0].name);
    try std.testing.expectEqualStrings(
        "/home/u/.local/share/go/bin:/home/u/.local/share/dev-env/tools/go/1.24.4/bin:/home/u/.local/bin:/usr/bin",
        entries[0].value,
    );
    try std.testing.expectEqualStrings("GOROOT", entries[1].name);
    try std.testing.expectEqualStrings("/home/u/.local/share/dev-env/tools/go/1.24.4", entries[1].value);
    try std.testing.expectEqualStrings("GOPATH", entries[2].name);
    try std.testing.expectEqualStrings("/home/u/.local/share/go", entries[2].value);
}

test "writeEntries emits key value lines" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try writeEntries(&out.writer, &.{
        .{ .name = "A", .value = "one" },
        .{ .name = "B", .value = "two" },
    });
    try std.testing.expectEqualStrings("A=one\nB=two\n", out.written());
}

test "collect rejects invalid names and values" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const base: receipt_mod.Receipt = .{
        .installer_release = "0.1.0",
        .installer_path = "/x/dev-env-install",
        .platform = .{ .ubuntu = .{ .version = "24.04", .arch = .x86_64 } },
        .install_layout = .{ .bin = "/bin", .opt = "/opt", .cache_dir = "/cache" },
        .tools = &.{
            .{
                .tool = "bad",
                .kind = .archive,
                .version = "1",
                .env_exports = &.{.{ .name = "BAD-NAME", .value = "x" }},
            },
        },
    };
    try std.testing.expectError(error.InvalidEnvName, collect(alloc, base, "/home/u", "/usr/bin"));

    const newline: receipt_mod.Receipt = .{
        .installer_release = "0.1.0",
        .installer_path = "/x/dev-env-install",
        .platform = .{ .ubuntu = .{ .version = "24.04", .arch = .x86_64 } },
        .install_layout = .{ .bin = "/bin", .opt = "/opt", .cache_dir = "/cache" },
        .tools = &.{
            .{
                .tool = "bad",
                .kind = .archive,
                .version = "1",
                .env_exports = &.{.{ .name = "OK", .value = "x\ny" }},
            },
        },
    };
    try std.testing.expectError(error.InvalidEnvValue, collect(alloc, newline, "/home/u", "/usr/bin"));
}
