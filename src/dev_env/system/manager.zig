//! Adapts protocol package lists to the host package-manager implementation
//! shared with release installers.

const std = @import("std");
const shared = @import("shared");
const proto = shared.protocol;
const platform = shared.platform;

pub const InstallResult = struct {
    installed: []const []const u8 = &.{},

    pub fn changed(r: InstallResult) bool {
        return r.installed.len > 0;
    }
};

pub const Manager = struct {
    package_manager: platform.PackageManager,

    pub fn init(pm: platform.PackageManager) Manager {
        return .{ .package_manager = pm };
    }

    pub fn ensureInstalled(
        m: Manager,
        alloc: std.mem.Allocator,
        io: std.Io,
        packages: proto.SystemPackages,
    ) !InstallResult {
        const installed = switch (m.package_manager.kind) {
            .apt => try m.package_manager.install(alloc, io, packages.apt, .{}),
            .dnf => try m.package_manager.install(alloc, io, packages.dnf, .{}),
            .brew => blk: {
                var all: std.ArrayList([]const u8) = .empty;
                try all.appendSlice(
                    alloc,
                    try m.package_manager.install(alloc, io, packages.brew, .{}),
                );
                try all.appendSlice(
                    alloc,
                    try m.package_manager.install(alloc, io, packages.brew_cask, .{ .cask = true }),
                );
                break :blk all.items;
            },
        };
        return .{ .installed = installed };
    }
};

// --- tests ---

test "manager selects its own package lists" {
    // Empty lists are a no-op for every manager; this exercises dispatch
    // without touching the host system.
    const packages: proto.SystemPackages = .{};
    const io = std.testing.io;
    const apt_result = try Manager.init(.init(.apt)).ensureInstalled(std.testing.allocator, io, packages);
    const dnf_result = try Manager.init(.init(.dnf)).ensureInstalled(std.testing.allocator, io, packages);
    const brew_result = try Manager.init(.init(.brew)).ensureInstalled(std.testing.allocator, io, packages);
    try std.testing.expect(!apt_result.changed());
    try std.testing.expect(!dnf_result.changed());
    try std.testing.expect(!brew_result.changed());
}
