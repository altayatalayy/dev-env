//! Host platform detection. Unknown hosts are hard errors.

const std = @import("std");
const builtin = @import("builtin");
const shared = @import("shared");
const platform = shared.platform;
const runner = shared.runner;

pub const Error = error{ UnsupportedArch, UnsupportedPlatform, MalformedOsRelease };

fn hostArch() Error!platform.Arch {
    return switch (builtin.cpu.arch) {
        .x86_64 => .x86_64,
        .aarch64 => .aarch64,
        else => error.UnsupportedArch,
    };
}

pub fn detect(alloc: std.mem.Allocator, io: std.Io) !platform.Platform {
    const arch = try hostArch();
    switch (builtin.os.tag) {
        .linux => {
            const contents = try std.Io.Dir.cwd().readFileAlloc(io, "/etc/os-release", alloc, .limited(64 * 1024));
            return fromOsRelease(contents, arch);
        },
        .macos => {
            const result = try std.process.run(alloc, io, .{
                .argv = &.{ "sw_vers", "-productVersion" },
            });
            defer alloc.free(result.stdout);
            defer alloc.free(result.stderr);
            if (!runner.succeeded(result.term)) return error.UnsupportedPlatform;
            const version = std.mem.trim(u8, result.stdout, " \t\r\n");
            return .{ .macos = .{ .version = try alloc.dupe(u8, version), .arch = arch } };
        },
        else => return error.UnsupportedPlatform,
    }
}

pub const OsRelease = struct {
    id: []const u8,
    version_id: []const u8,
};

/// Parses the few fields we need from /etc/os-release.
pub fn parseOsRelease(contents: []const u8) Error!OsRelease {
    var id: ?[]const u8 = null;
    var version_id: ?[]const u8 = null;

    var lines = std.mem.tokenizeScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        const key = trimmed[0..eq];
        const value = std.mem.trim(u8, trimmed[eq + 1 ..], "\"");
        if (std.mem.eql(u8, key, "ID")) id = value;
        if (std.mem.eql(u8, key, "VERSION_ID")) version_id = value;
    }

    return .{
        .id = id orelse return error.MalformedOsRelease,
        .version_id = version_id orelse return error.MalformedOsRelease,
    };
}

pub fn fromOsRelease(contents: []const u8, arch: platform.Arch) Error!platform.Platform {
    const os_release = try parseOsRelease(contents);
    const versioned: platform.Platform.Versioned = .{
        .version = os_release.version_id,
        .arch = arch,
    };
    if (std.mem.eql(u8, os_release.id, "ubuntu")) return .{ .ubuntu = versioned };
    if (std.mem.eql(u8, os_release.id, "debian")) return .{ .debian = versioned };
    if (std.mem.eql(u8, os_release.id, "fedora")) return .{ .fedora = versioned };
    return error.UnsupportedPlatform;
}

// --- tests ---

const ubuntu_os_release =
    \\PRETTY_NAME="Ubuntu 24.04.2 LTS"
    \\NAME="Ubuntu"
    \\VERSION_ID="24.04"
    \\VERSION="24.04.2 LTS (Noble Numbat)"
    \\ID=ubuntu
    \\ID_LIKE=debian
;

test parseOsRelease {
    const parsed = try parseOsRelease(ubuntu_os_release);
    try std.testing.expectEqualStrings("ubuntu", parsed.id);
    try std.testing.expectEqualStrings("24.04", parsed.version_id);

    try std.testing.expectError(error.MalformedOsRelease, parseOsRelease("NAME=x\n"));
}

test fromOsRelease {
    const detected = try fromOsRelease(ubuntu_os_release, .x86_64);
    try std.testing.expect(detected.eql(.{ .ubuntu = .{ .version = "24.04", .arch = .x86_64 } }));

    const arch_linux = "ID=arch\nVERSION_ID=20260101\n";
    try std.testing.expectError(error.UnsupportedPlatform, fromOsRelease(arch_linux, .x86_64));
}
