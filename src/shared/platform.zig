//! Host platform model shared by dev-env and dev-env-install.
//!
//! Platforms are tagged unions everywhere inside the two binaries; they only
//! become JSON across the process boundary (std.json represents a tagged
//! union as a single-key object, e.g. {"ubuntu":{"version":"24.04",...}}).

const std = @import("std");
const builtin = @import("builtin");
const runner = @import("runner.zig");

pub const Arch = enum { x86_64, aarch64 };

pub const Family = enum { linux, macos };

pub const PackageManager = struct {
    kind: Kind,

    pub const Kind = enum { apt, dnf, brew };

    pub const InstallOptions = struct {
        cask: bool = false,
    };

    pub fn init(kind: Kind) PackageManager {
        return .{ .kind = kind };
    }

    pub fn update(pm: PackageManager, alloc: std.mem.Allocator, io: std.Io) !void {
        const argv: []const []const u8 = switch (pm.kind) {
            .apt => if (isRoot())
                &.{ "apt-get", "update", "--quiet" }
            else
                &.{ "sudo", "apt-get", "update", "--quiet" },
            .dnf => if (isRoot())
                &.{ "dnf", "makecache", "--refresh", "--assumeyes" }
            else
                &.{ "sudo", "dnf", "makecache", "--refresh", "--assumeyes" },
            .brew => &.{ "brew", "update" },
        };
        try runPackageCommand(alloc, io, argv, error.PackageManagerUpdateFailed);
    }

    pub fn addRepository(
        pm: PackageManager,
        alloc: std.mem.Allocator,
        io: std.Io,
        repository: Repository,
    ) !void {
        switch (repository) {
            .apt => |repo| {
                if (pm.kind != .apt) return error.RepositoryManagerMismatch;
                try addAptRepository(alloc, io, repo);
            },
            .dnf => |repo| {
                if (pm.kind != .dnf) return error.RepositoryManagerMismatch;
                const prefix: []const []const u8 = if (isRoot()) &.{"dnf"} else &.{ "sudo", "dnf" };
                const repo_arg = try std.fmt.allocPrint(alloc, "--from-repofile={s}", .{repo.url});
                defer alloc.free(repo_arg);
                const argv = try std.mem.concat(alloc, []const u8, &.{
                    prefix,
                    &.{ "config-manager", "addrepo", "--overwrite", repo_arg },
                });
                defer alloc.free(argv);
                try runPackageCommand(alloc, io, argv, error.RepositorySetupFailed);
            },
            .brew => |repo| {
                if (pm.kind != .brew) return error.RepositoryManagerMismatch;
                try runPackageCommand(
                    alloc,
                    io,
                    &.{ "brew", "tap", repo.tap },
                    error.RepositorySetupFailed,
                );
            },
        }
    }

    pub fn install(
        pm: PackageManager,
        alloc: std.mem.Allocator,
        io: std.Io,
        packages: []const []const u8,
        options: InstallOptions,
    ) ![]const []const u8 {
        var missing: std.ArrayList([]const u8) = .empty;
        for (packages) |package| {
            if (!pm.isInstalled(alloc, io, package, options)) {
                try missing.append(alloc, package);
            }
        }
        if (missing.items.len == 0) return &.{};

        const package_list = try std.mem.join(alloc, " ", missing.items);
        defer alloc.free(package_list);
        std.log.info("installing {t} packages: {s}", .{ pm.kind, package_list });

        const prefix: []const []const u8 = switch (pm.kind) {
            .apt => blk: {
                try pm.update(alloc, io);
                break :blk if (isRoot())
                    &.{ "env", "DEBIAN_FRONTEND=noninteractive", "apt-get", "install", "--yes" }
                else
                    &.{ "sudo", "env", "DEBIAN_FRONTEND=noninteractive", "apt-get", "install", "--yes" };
            },
            .dnf => if (isRoot())
                &.{ "dnf", "install", "--assumeyes" }
            else
                &.{ "sudo", "dnf", "install", "--assumeyes" },
            .brew => if (options.cask)
                &.{ "brew", "install", "--cask" }
            else
                &.{ "brew", "install" },
        };
        const argv = try std.mem.concat(alloc, []const u8, &.{ prefix, missing.items });
        defer alloc.free(argv);
        try runPackageCommand(alloc, io, argv, error.PackageInstallFailed);
        return try missing.toOwnedSlice(alloc);
    }

    pub fn remove(
        pm: PackageManager,
        alloc: std.mem.Allocator,
        io: std.Io,
        packages: []const []const u8,
        options: InstallOptions,
    ) ![]const []const u8 {
        var installed: std.ArrayList([]const u8) = .empty;
        for (packages) |package| {
            if (pm.isInstalled(alloc, io, package, options)) {
                try installed.append(alloc, package);
            }
        }
        if (installed.items.len == 0) return &.{};

        const prefix: []const []const u8 = switch (pm.kind) {
            .apt => if (isRoot())
                &.{ "env", "DEBIAN_FRONTEND=noninteractive", "apt-get", "remove", "--yes" }
            else
                &.{ "sudo", "env", "DEBIAN_FRONTEND=noninteractive", "apt-get", "remove", "--yes" },
            .dnf => if (isRoot())
                &.{ "dnf", "remove", "--assumeyes" }
            else
                &.{ "sudo", "dnf", "remove", "--assumeyes" },
            .brew => if (options.cask)
                &.{ "brew", "uninstall", "--cask" }
            else
                &.{ "brew", "uninstall" },
        };
        const argv = try std.mem.concat(alloc, []const u8, &.{ prefix, installed.items });
        defer alloc.free(argv);
        try runPackageCommand(alloc, io, argv, error.PackageRemoveFailed);
        return try installed.toOwnedSlice(alloc);
    }

    fn isInstalled(
        pm: PackageManager,
        alloc: std.mem.Allocator,
        io: std.Io,
        package: []const u8,
        options: InstallOptions,
    ) bool {
        const argv: []const []const u8 = switch (pm.kind) {
            .apt => &.{ "dpkg-query", "--show", "--showformat=${db:Status-Status}", package },
            .dnf => &.{ "rpm", "--query", "--quiet", package },
            .brew => if (options.cask)
                &.{ "brew", "list", "--cask", "--versions", package }
            else
                &.{ "brew", "list", "--versions", package },
        };
        const result = std.process.run(alloc, io, .{ .argv = argv }) catch return false;
        defer alloc.free(result.stdout);
        defer alloc.free(result.stderr);
        if (!runner.succeeded(result.term)) return false;
        return pm.kind != .apt or std.mem.eql(u8, result.stdout, "installed");
    }
};

pub const Repository = union(PackageManager.Kind) {
    apt: AptRepository,
    dnf: DnfRepository,
    brew: BrewRepository,

    pub const AptRepository = struct {
        key_url: []const u8,
        key_path: []const u8,
        source_path: []const u8,
        /// Shell-expanded APT source line. `${ARCH}` and
        /// `${VERSION_CODENAME}` are available.
        source_line: []const u8,
    };

    pub const DnfRepository = struct {
        url: []const u8,
    };

    pub const BrewRepository = struct {
        tap: []const u8,
    };
};

fn isRoot() bool {
    if (builtin.os.tag != .linux) return false;
    return std.os.linux.geteuid() == 0;
}

fn runPackageCommand(
    alloc: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    failure: anyerror,
) !void {
    const term = try runner.runQuietUnlessFailed(alloc, io, argv);
    if (!runner.succeeded(term)) return failure;
}

fn addAptRepository(
    alloc: std.mem.Allocator,
    io: std.Io,
    repo: Repository.AptRepository,
) !void {
    const key_dir = std.fs.path.dirname(repo.key_path) orelse return error.InvalidRepositoryPath;
    const install_prefix: []const []const u8 = if (isRoot()) &.{"install"} else &.{ "sudo", "install" };
    const install_argv = try std.mem.concat(alloc, []const u8, &.{
        install_prefix,
        &.{ "-m", "0755", "-d", key_dir },
    });
    defer alloc.free(install_argv);
    try runPackageCommand(alloc, io, install_argv, error.RepositorySetupFailed);

    const tee = if (isRoot()) "tee" else "sudo tee";
    const key_command = try std.fmt.allocPrint(
        alloc,
        "curl --fail --silent --show-error --location {s} | {s} {s} >/dev/null",
        .{ repo.key_url, tee, repo.key_path },
    );
    defer alloc.free(key_command);
    try runPackageCommand(alloc, io, &.{ "sh", "-c", key_command }, error.RepositorySetupFailed);

    const chmod_prefix: []const []const u8 = if (isRoot()) &.{"chmod"} else &.{ "sudo", "chmod" };
    const chmod_argv = try std.mem.concat(alloc, []const u8, &.{ chmod_prefix, &.{ "a+r", repo.key_path } });
    defer alloc.free(chmod_argv);
    try runPackageCommand(alloc, io, chmod_argv, error.RepositorySetupFailed);

    const source_command = try std.fmt.allocPrint(
        alloc,
        ". /etc/os-release && ARCH=$(dpkg --print-architecture) && echo \"{s}\" | {s} {s} >/dev/null",
        .{ repo.source_line, tee, repo.source_path },
    );
    defer alloc.free(source_command);
    try runPackageCommand(alloc, io, &.{ "sh", "-c", source_command }, error.RepositorySetupFailed);
}

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
        return .init(switch (p) {
            .ubuntu, .debian => .apt,
            .fedora => .dnf,
            .macos => .brew,
        });
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

    pub fn eql(a: Support, b: Support) bool {
        if (!std.mem.eql(u8, @tagName(a), @tagName(b))) return false;
        const a_entry = switch (a) {
            inline else => |entry| entry,
        };
        const b_entry = switch (b) {
            inline else => |entry| entry,
        };
        return std.mem.eql(Arch, a_entry.archs, b_entry.archs) and
            stringSlicesEqual(a_entry.versions, b_entry.versions);
    }
};

fn stringSlicesEqual(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |a_item, b_item| {
        if (!std.mem.eql(u8, a_item, b_item)) return false;
    }
    return true;
}

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
    try std.testing.expectEqual(PackageManager.Kind.apt, a.packageManager().kind);

    const fedora: Platform = .{ .fedora = .{ .version = "44", .arch = .x86_64 } };
    try std.testing.expectEqual(PackageManager.Kind.dnf, fedora.packageManager().kind);

    const mac: Platform = .{ .macos = .{ .version = "15.5", .arch = .aarch64 } };
    try std.testing.expectEqual(PackageManager.Kind.brew, mac.packageManager().kind);
}

test "repository must match package manager" {
    try std.testing.expectError(
        error.RepositoryManagerMismatch,
        PackageManager.init(.apt).addRepository(
            std.testing.allocator,
            std.testing.io,
            .{ .dnf = .{ .url = "https://example.invalid/repo" } },
        ),
    );
}

test "installing an empty package list is a no-op" {
    const installed = try PackageManager.init(.apt).install(
        std.testing.allocator,
        std.testing.io,
        &.{},
        .{},
    );
    try std.testing.expectEqual(@as(usize, 0), installed.len);
}

test "removing an empty package list is a no-op" {
    const removed = try PackageManager.init(.apt).remove(
        std.testing.allocator,
        std.testing.io,
        &.{},
        .{},
    );
    try std.testing.expectEqual(@as(usize, 0), removed.len);
}
