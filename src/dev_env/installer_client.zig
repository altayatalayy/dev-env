//! Discovery of installer releases and the JSON-over-stdio client for
//! running them. dev-env only ever talks to installers through this file.

const std = @import("std");
const shared = @import("shared");
const proto = shared.protocol;
const platform = shared.platform;
const runner = shared.runner;
const json = shared.json;
const version = shared.version;
const paths_mod = @import("paths.zig");

pub const Installer = struct {
    release: []const u8,
    bin_path: []const u8,
    meta: proto.MetadataResponse,

    pub fn protocolSupported(inst: Installer) bool {
        return inst.meta.protocol == proto.version;
    }

    pub fn supportsPlatform(inst: Installer, p: platform.Platform) bool {
        return platform.isSupported(inst.meta.platforms, p);
    }

    /// Hard errors for the installer the user (or the lock file) selected.
    pub fn ensureCompatible(inst: Installer, p: platform.Platform) error{
        UnsupportedProtocol,
        UnsupportedPlatform,
    }!void {
        if (!inst.protocolSupported()) return error.UnsupportedProtocol;
        if (!inst.supportsPlatform(p)) return error.UnsupportedPlatform;
    }
};

pub fn local(alloc: std.mem.Allocator, io: std.Io, bin_path: []const u8) !Installer {
    if (!std.fs.path.isAbsolute(bin_path)) return error.InstallerPathNotAbsolute;
    try std.Io.Dir.accessAbsolute(io, bin_path, .{});
    const meta = try metadata(alloc, io, bin_path);
    return .{
        .release = meta.release,
        .bin_path = try alloc.dupe(u8, bin_path),
        .meta = meta,
    };
}

/// Scans ~/.local/share/dev-env/installers/<release>/dev-env-install and
/// loads metadata from each installer found.
pub fn discover(alloc: std.mem.Allocator, io: std.Io, paths: paths_mod.Paths) ![]Installer {
    var installers: std.ArrayList(Installer) = .empty;

    var dir = std.Io.Dir.cwd().openDir(io, paths.installers, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return installers.items,
        else => return err,
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const release = try alloc.dupe(u8, entry.name);
        // Release ids are ordered by newestCompatible, so an unparseable one
        // would otherwise fail every command instead of just being ignored.
        _ = version.Version.parse(release) catch {
            std.log.warn("skipping installer {s}: not a x.y.z release id", .{release});
            continue;
        };
        const bin_path = try paths.installerBin(alloc, release);
        std.Io.Dir.accessAbsolute(io, bin_path, .{}) catch continue;

        const meta = metadata(alloc, io, bin_path) catch |err| {
            std.log.warn("skipping installer {s}: {t}", .{ release, err });
            continue;
        };
        if (!std.mem.eql(u8, meta.release, release)) {
            std.log.warn(
                "skipping installer {s}: reports release {s}",
                .{ release, meta.release },
            );
            continue;
        }
        try installers.append(alloc, .{ .release = release, .bin_path = bin_path, .meta = meta });
    }

    return installers.items;
}

pub fn find(installers: []const Installer, release: []const u8) ?Installer {
    for (installers) |inst| {
        if (std.mem.eql(u8, inst.release, release)) return inst;
    }
    return null;
}

pub fn newestCompatible(
    installers: []const Installer,
    p: platform.Platform,
) error{InvalidVersion}!?Installer {
    var best: ?Installer = null;
    for (installers) |inst| {
        if (!inst.protocolSupported() or !inst.supportsPlatform(p)) continue;
        if (best) |b| {
            if (try version.orderReleases(inst.release, b.release) != .gt) continue;
        }
        best = inst;
    }
    return best;
}

pub fn metadata(alloc: std.mem.Allocator, io: std.Io, bin_path: []const u8) !proto.MetadataResponse {
    return exec(proto.MetadataResponse, alloc, io, bin_path, .metadata, "");
}

pub fn resolve(
    alloc: std.mem.Allocator,
    io: std.Io,
    inst: Installer,
    req: proto.ResolveRequest,
) !proto.ResolveResponse {
    return execJson(proto.ResolveResponse, alloc, io, inst.bin_path, .resolve, req);
}

pub fn applyTools(
    alloc: std.mem.Allocator,
    io: std.Io,
    inst: Installer,
    req: proto.ApplyRequest,
) !proto.ApplyResponse {
    return execJson(proto.ApplyResponse, alloc, io, inst.bin_path, .apply, req);
}

pub fn verify(
    alloc: std.mem.Allocator,
    io: std.Io,
    inst: Installer,
    req: proto.VerifyRequest,
) !proto.VerifyResponse {
    return execJson(proto.VerifyResponse, alloc, io, inst.bin_path, .verify, req);
}

pub fn applyConfigs(
    alloc: std.mem.Allocator,
    io: std.Io,
    inst: Installer,
    req: proto.ConfigApplyRequest,
) !proto.ConfigApplyResponse {
    return execJson(proto.ConfigApplyResponse, alloc, io, inst.bin_path, .@"apply-configs", req);
}

pub fn uninstall(
    alloc: std.mem.Allocator,
    io: std.Io,
    bin_path: []const u8,
    req: proto.UninstallRequest,
) !proto.UninstallResponse {
    return execJson(proto.UninstallResponse, alloc, io, bin_path, .uninstall, req);
}

pub fn extractDotfiles(
    alloc: std.mem.Allocator,
    io: std.Io,
    inst: Installer,
    req: proto.ExtractDotfilesRequest,
) !proto.ExtractDotfilesResponse {
    return execJson(proto.ExtractDotfilesResponse, alloc, io, inst.bin_path, .@"extract-dotfiles", req);
}

fn execJson(
    comptime Response: type,
    alloc: std.mem.Allocator,
    io: std.Io,
    bin_path: []const u8,
    cmd: proto.Command,
    request: anytype,
) !Response {
    return exec(Response, alloc, io, bin_path, cmd, try json.stringify(alloc, request));
}

fn exec(
    comptime Response: type,
    alloc: std.mem.Allocator,
    io: std.Io,
    bin_path: []const u8,
    cmd: proto.Command,
    input: []const u8,
) !Response {
    var child = try std.process.spawn(io, .{
        .argv = &.{ bin_path, @tagName(cmd) },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit,
    });
    defer child.kill(io);

    try child.stdin.?.writeStreamingAll(io, input);
    child.stdin.?.close(io);
    child.stdin = null;

    var read_buffer: [8192]u8 = undefined;
    var stdout_reader = child.stdout.?.reader(io, &read_buffer);
    var final: ?Response = null;
    while (try stdout_reader.interface.takeDelimiter('\n')) |line| {
        if (line.len == 0) continue;
        const header = proto.parseLineHeader(alloc, line) catch |err| {
            std.log.err("invalid installer protocol line from {s}: {t}", .{ bin_path, err });
            return err;
        };
        switch (header.kind) {
            .progress => {
                const progress = try proto.parseProgress(alloc, cmd, line);
                displayProgress(progress.event);
            },
            .response => {
                const msg = try proto.parseFinal(Response, alloc, cmd, line);
                final = msg.response;
            },
        }
    }

    const term = try child.wait(io);
    if (!runner.succeeded(term)) {
        std.log.err("{s} {t} failed", .{ bin_path, cmd });
        return error.InstallerFailed;
    }
    return final orelse error.MissingInstallerResponse;
}

fn displayProgress(event: proto.ProgressEvent) void {
    const subject = event.tool orelse event.config orelse event.detail orelse "";

    if (std.mem.eql(u8, event.event, "install_started")) {
        std.log.info("installing {s}", .{subject});
    } else if (std.mem.eql(u8, event.event, "install_finished")) {
        std.log.info("installed {s}", .{subject});
    } else if (std.mem.eql(u8, event.event, "build_started")) {
        std.log.info("building {s} {s}", .{ subject, event.detail orelse "" });
    } else if (std.mem.eql(u8, event.event, "build_finished")) {
        std.log.info("built {s} {s}", .{ subject, event.detail orelse "" });
    } else if (std.mem.eql(u8, event.event, "step_started")) {
        std.log.info("{s}: {s}", .{ subject, event.detail orelse "step" });
    } else if (std.mem.eql(u8, event.event, "step_finished")) {
        std.log.info("{s}: finished {s}", .{ subject, event.detail orelse "step" });
    } else if (std.mem.eql(u8, event.event, "step_skipped")) {
        std.log.info("{s}: skipped {s}", .{ subject, event.detail orelse "step" });
    } else if (std.mem.eql(u8, event.event, "config_apply_started")) {
        std.log.info("applying config {s}", .{subject});
    } else if (std.mem.eql(u8, event.event, "config_apply_finished")) {
        std.log.info("applied config {s}", .{subject});
    } else if (event.tools.len > 0) {
        std.log.info("{s}: {d} tools", .{ event.event, event.tools.len });
    } else if (event.packages.len > 0) {
        std.log.info("{s}: {d} packages", .{ event.event, event.packages.len });
    } else if (event.detail) |detail| {
        std.log.info("{s}: {s}", .{ event.event, detail });
    } else {
        std.log.info("{s}", .{event.event});
    }
}

// --- tests ---

const testing = std.testing;

fn testInstaller(release: []const u8, protocol: u32) Installer {
    return .{
        .release = release,
        .bin_path = "",
        .meta = .{
            .protocol = protocol,
            .release = release,
            .platforms = &.{
                .{ .ubuntu = .{ .versions = &.{"24.04"}, .archs = &.{.x86_64} } },
            },
            .tools = &.{},
            .configs = &.{},
        },
    };
}

const test_platform: platform.Platform = .{ .ubuntu = .{ .version = "24.04", .arch = .x86_64 } };

test newestCompatible {
    const installers = [_]Installer{
        testInstaller("0.1.0", proto.version),
        testInstaller("0.10.0", proto.version),
        testInstaller("0.2.0", proto.version),
        // Newest release, but a protocol we do not speak: must be skipped.
        testInstaller("1.0.0", proto.version + 1),
    };

    const best = (try newestCompatible(&installers, test_platform)).?;
    try testing.expectEqualStrings("0.10.0", best.release);

    const debian: platform.Platform = .{ .debian = .{ .version = "13", .arch = .x86_64 } };
    try testing.expectEqual(@as(?Installer, null), try newestCompatible(&installers, debian));
}

test "ensureCompatible rejects protocol and platform mismatches" {
    const wrong_protocol = testInstaller("0.1.0", proto.version + 1);
    try testing.expectError(error.UnsupportedProtocol, wrong_protocol.ensureCompatible(test_platform));

    const ok = testInstaller("0.1.0", proto.version);
    const debian: platform.Platform = .{ .debian = .{ .version = "13", .arch = .x86_64 } };
    try testing.expectError(error.UnsupportedPlatform, ok.ensureCompatible(debian));
    try ok.ensureCompatible(test_platform);
}

test find {
    const installers = [_]Installer{
        testInstaller("0.1.0", proto.version),
        testInstaller("0.2.0", proto.version),
    };
    try testing.expectEqualStrings("0.2.0", find(&installers, "0.2.0").?.release);
    try testing.expectEqual(@as(?Installer, null), find(&installers, "9.9.9"));
}
