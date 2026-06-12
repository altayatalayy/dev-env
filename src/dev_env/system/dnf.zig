//! DNF package installation (Fedora). Already-installed packages are
//! detected with rpm so sudo is only invoked when something is missing.

const std = @import("std");
const builtin = @import("builtin");
const shared = @import("shared");
const runner = shared.runner;

fn isRoot() bool {
    if (builtin.os.tag != .linux) return false;
    return std.os.linux.geteuid() == 0;
}

fn isInstalled(alloc: std.mem.Allocator, io: std.Io, package: []const u8) bool {
    const result = std.process.run(alloc, io, .{
        .argv = &.{ "rpm", "--query", "--quiet", package },
    }) catch return false;
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    return runner.succeeded(result.term);
}

pub fn ensureInstalled(alloc: std.mem.Allocator, io: std.Io, packages: []const []const u8) ![]const []const u8 {
    var missing: std.ArrayList([]const u8) = .empty;
    for (packages) |package| {
        if (!isInstalled(alloc, io, package)) try missing.append(alloc, package);
    }
    if (missing.items.len == 0) return &.{};

    const package_list = try std.mem.join(alloc, " ", missing.items);
    defer alloc.free(package_list);
    std.log.info("installing dnf packages: {s}", .{package_list});

    const prefix: []const []const u8 = if (isRoot())
        &.{ "dnf", "install", "--assumeyes" }
    else
        &.{ "sudo", "dnf", "install", "--assumeyes" };
    const argv = try std.mem.concat(alloc, []const u8, &.{ prefix, missing.items });
    defer alloc.free(argv);

    const term = try runner.runQuietUnlessFailed(alloc, io, argv);
    if (!runner.succeeded(term)) {
        std.log.err("dnf install failed", .{});
        return error.DnfFailed;
    }

    return try missing.toOwnedSlice(alloc);
}
