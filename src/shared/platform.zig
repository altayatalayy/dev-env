//! Host platform model shared by dev-env and dev-env-install.
//!
//! Platforms are tagged unions everywhere inside the two binaries; they only
//! become JSON across the process boundary (std.json represents a tagged
//! union as a single-key object, e.g. {"ubuntu":{"version":"24.04",...}}).

const std = @import("std");

pub const Arch = enum { x86_64, aarch64 };

pub const Family = enum { linux, macos };

pub const PackageManager = enum { apt, dnf, brew };

pub const Platform = union(enum) {
    ubuntu: Versioned,
    debian: Versioned,
    fedora: Versioned,
    macos: Versioned,

    pub const Versioned = struct {
        version: []const u8,
        arch: Arch,
    };

    pub fn fields(p: Platform) Versioned {
        return switch (p) {
            inline else => |v| v,
        };
    }

    pub fn family(p: Platform) Family {
        return switch (p) {
            .ubuntu, .debian, .fedora => .linux,
            .macos => .macos,
        };
    }

    pub fn packageManager(p: Platform) PackageManager {
        return switch (p) {
            .ubuntu, .debian => .apt,
            .fedora => .dnf,
            .macos => .brew,
        };
    }

    pub fn eql(a: Platform, b: Platform) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return std.mem.eql(u8, a.fields().version, b.fields().version) and
            a.fields().arch == b.fields().arch;
    }

    pub fn format(p: Platform, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{s} {s} ({s})", .{
            @tagName(p),
            p.fields().version,
            @tagName(p.fields().arch),
        });
    }
};

/// One platform-support declaration of an installer release.
pub const Support = union(enum) {
    ubuntu: Entry,
    debian: Entry,
    fedora: Entry,
    macos: Entry,

    pub const Entry = struct {
        /// Supported OS versions; empty means every version.
        versions: []const []const u8 = &.{},
        archs: []const Arch,
    };

    pub fn matches(s: Support, p: Platform) bool {
        if (!std.mem.eql(u8, @tagName(s), @tagName(p))) return false;
        const entry = switch (s) {
            inline else => |e| e,
        };
        if (std.mem.indexOfScalar(Arch, entry.archs, p.fields().arch) == null) return false;
        if (entry.versions.len == 0) return true;
        for (entry.versions) |v| {
            if (std.mem.eql(u8, v, p.fields().version)) return true;
        }
        return false;
    }
};

pub fn isSupported(supports: []const Support, p: Platform) bool {
    for (supports) |s| {
        if (s.matches(p)) return true;
    }
    return false;
}

test "support matching" {
    const supports = [_]Support{
        .{ .ubuntu = .{ .versions = &.{ "24.04", "26.04" }, .archs = &.{ .x86_64, .aarch64 } } },
        .{ .macos = .{ .archs = &.{.aarch64} } },
    };

    const ubuntu2404: Platform = .{ .ubuntu = .{ .version = "24.04", .arch = .x86_64 } };
    const ubuntu2204: Platform = .{ .ubuntu = .{ .version = "22.04", .arch = .x86_64 } };
    const debian: Platform = .{ .debian = .{ .version = "13", .arch = .x86_64 } };
    const mac_arm: Platform = .{ .macos = .{ .version = "15.5", .arch = .aarch64 } };
    const mac_intel: Platform = .{ .macos = .{ .version = "15.5", .arch = .x86_64 } };

    try std.testing.expect(isSupported(&supports, ubuntu2404));
    try std.testing.expect(!isSupported(&supports, ubuntu2204));
    try std.testing.expect(!isSupported(&supports, debian));
    try std.testing.expect(isSupported(&supports, mac_arm));
    try std.testing.expect(!isSupported(&supports, mac_intel));
}

test "platform json round trip" {
    const alloc = std.testing.allocator;

    const original: Platform = .{ .ubuntu = .{ .version = "24.04", .arch = .aarch64 } };
    const encoded = try std.json.Stringify.valueAlloc(alloc, original, .{});
    defer alloc.free(encoded);

    const decoded = try std.json.parseFromSlice(Platform, alloc, encoded, .{});
    defer decoded.deinit();

    try std.testing.expect(original.eql(decoded.value));
}

test "platform equality and accessors" {
    const a: Platform = .{ .ubuntu = .{ .version = "24.04", .arch = .x86_64 } };
    const b: Platform = .{ .debian = .{ .version = "24.04", .arch = .x86_64 } };

    try std.testing.expect(!a.eql(b));
    try std.testing.expectEqual(Family.linux, a.family());
    try std.testing.expectEqual(PackageManager.apt, a.packageManager());

    const fedora: Platform = .{ .fedora = .{ .version = "44", .arch = .x86_64 } };
    try std.testing.expectEqual(PackageManager.dnf, fedora.packageManager());

    const mac: Platform = .{ .macos = .{ .version = "15.5", .arch = .aarch64 } };
    try std.testing.expectEqual(PackageManager.brew, mac.packageManager());
}
