//! The host's system package manager. Each variant owns how packages are
//! detected and installed on its platform; callers hand over the full
//! per-manager package lists from an installer plan and the manager picks
//! the ones it is responsible for.

const std = @import("std");
const shared = @import("shared");
const proto = shared.protocol;
const platform = shared.platform;
const apt = @import("apt.zig");
const dnf = @import("dnf.zig");
const brew = @import("brew.zig");

pub const Manager = union(enum) {
    apt,
    dnf,
    brew,

    pub fn init(pm: platform.PackageManager) Manager {
        return switch (pm) {
            .apt => .apt,
            .dnf => .dnf,
            .brew => .brew,
        };
    }

    pub fn ensureInstalled(
        m: Manager,
        alloc: std.mem.Allocator,
        io: std.Io,
        packages: proto.SystemPackages,
    ) !void {
        switch (m) {
            .apt => try apt.ensureInstalled(alloc, io, packages.apt),
            .dnf => try dnf.ensureInstalled(alloc, io, packages.dnf),
            .brew => try brew.ensureInstalled(alloc, io, packages.brew, packages.brew_cask),
        }
    }
};

// --- tests ---

test "manager selects its own package lists" {
    // Empty lists are a no-op for every manager; this exercises dispatch
    // without touching the host system.
    const packages: proto.SystemPackages = .{};
    const io = std.testing.io;
    try Manager.init(.apt).ensureInstalled(std.testing.allocator, io, packages);
    try Manager.init(.dnf).ensureInstalled(std.testing.allocator, io, packages);
    try Manager.init(.brew).ensureInstalled(std.testing.allocator, io, packages);
}
