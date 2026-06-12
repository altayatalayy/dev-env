//! Homebrew package installation (macOS).

const std = @import("std");
const shared = @import("shared");
const runner = shared.runner;

fn isInstalled(alloc: std.mem.Allocator, io: std.Io, package: []const u8, cask: bool) bool {
    const argv: []const []const u8 = if (cask)
        &.{ "brew", "list", "--cask", "--versions", package }
    else
        &.{ "brew", "list", "--versions", package };
    const result = std.process.run(alloc, io, .{ .argv = argv }) catch return false;
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    return runner.succeeded(result.term);
}

pub fn ensureInstalled(
    alloc: std.mem.Allocator,
    io: std.Io,
    formulas: []const []const u8,
    casks: []const []const u8,
) !void {
    try install(alloc, io, formulas, false);
    try install(alloc, io, casks, true);
}

fn install(alloc: std.mem.Allocator, io: std.Io, packages: []const []const u8, cask: bool) !void {
    var missing: std.ArrayList([]const u8) = .empty;
    for (packages) |package| {
        if (!isInstalled(alloc, io, package, cask)) try missing.append(alloc, package);
    }
    if (missing.items.len == 0) return;

    const prefix: []const []const u8 = if (cask)
        &.{ "brew", "install", "--cask" }
    else
        &.{ "brew", "install" };
    const argv = try std.mem.concat(alloc, []const u8, &.{ prefix, missing.items });

    const term = try runner.runInherit(io, argv);
    if (!runner.succeeded(term)) {
        std.log.err("brew install failed", .{});
        return error.BrewFailed;
    }
}
