//! Release id parsing and ordering ("0.2.0" style, strictly numeric).

const std = @import("std");

pub const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,

    pub fn parse(s: []const u8) error{InvalidVersion}!Version {
        var parts: [3]u32 = undefined;
        var it = std.mem.splitScalar(u8, s, '.');
        for (&parts) |*part| {
            const text = it.next() orelse return error.InvalidVersion;
            part.* = std.fmt.parseInt(u32, text, 10) catch return error.InvalidVersion;
        }
        if (it.next() != null) return error.InvalidVersion;
        return .{ .major = parts[0], .minor = parts[1], .patch = parts[2] };
    }

    pub fn order(a: Version, b: Version) std.math.Order {
        if (a.major != b.major) return std.math.order(a.major, b.major);
        if (a.minor != b.minor) return std.math.order(a.minor, b.minor);
        return std.math.order(a.patch, b.patch);
    }
};

pub fn orderReleases(a: []const u8, b: []const u8) error{InvalidVersion}!std.math.Order {
    return Version.order(try Version.parse(a), try Version.parse(b));
}

test Version {
    try std.testing.expectEqual(std.math.Order.lt, try orderReleases("0.1.0", "0.2.0"));
    try std.testing.expectEqual(std.math.Order.gt, try orderReleases("1.0.0", "0.9.9"));
    try std.testing.expectEqual(std.math.Order.eq, try orderReleases("0.10.1", "0.10.1"));
    try std.testing.expectEqual(std.math.Order.gt, try orderReleases("0.10.0", "0.9.0"));

    try std.testing.expectError(error.InvalidVersion, Version.parse("1.2"));
    try std.testing.expectError(error.InvalidVersion, Version.parse("1.2.3.4"));
    try std.testing.expectError(error.InvalidVersion, Version.parse("v1.2.3"));
    try std.testing.expectError(error.InvalidVersion, Version.parse(""));
}
