//! APT package installation. Already-installed packages are detected with
//! dpkg-query so sudo is only invoked when something is actually missing.

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
        .argv = &.{ "dpkg-query", "--show", "--showformat=${db:Status-Status}", package },
    }) catch return false;
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    return runner.succeeded(result.term) and std.mem.eql(u8, result.stdout, "installed");
}

pub fn ensureInstalled(alloc: std.mem.Allocator, io: std.Io, packages: []const []const u8) ![]const []const u8 {
    var missing: std.ArrayList([]const u8) = .empty;
    for (packages) |package| {
        if (!isInstalled(alloc, io, package)) try missing.append(alloc, package);
    }
    if (missing.items.len == 0) return &.{};

    const package_list = try std.mem.join(alloc, " ", missing.items);
    defer alloc.free(package_list);
    std.log.info("installing apt packages: {s}", .{package_list});

    try aptGet(alloc, io, &.{"update"});
    const install_args = try std.mem.concat(alloc, []const u8, &.{
        &.{ "install", "--yes" },
        missing.items,
    });
    try aptGet(alloc, io, install_args);

    return try missing.toOwnedSlice(alloc);
}

fn aptGet(alloc: std.mem.Allocator, io: std.Io, args: []const []const u8) !void {
    // sudo strips the environment, so DEBIAN_FRONTEND goes through env(1).
    const prefix: []const []const u8 = if (isRoot())
        &.{ "env", "DEBIAN_FRONTEND=noninteractive", "apt-get" }
    else
        &.{ "sudo", "env", "DEBIAN_FRONTEND=noninteractive", "apt-get" };
    const argv = try std.mem.concat(alloc, []const u8, &.{ prefix, args });

    const term = try runner.runQuietUnlessFailed(alloc, io, argv);
    if (!runner.succeeded(term)) {
        std.log.err("apt-get {s} failed", .{args[0]});
        return error.AptFailed;
    }
}
