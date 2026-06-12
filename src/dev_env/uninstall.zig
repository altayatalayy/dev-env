//! Uninstall orchestration: unstow configs, call the installer recorded in
//! installed.json to remove release-owned tools, then remove dev-env state.
//! apt/brew packages are left installed.

const std = @import("std");
const shared = @import("shared");
const proto = shared.protocol;
const paths_mod = @import("paths.zig");
const receipt_mod = @import("receipt.zig");
const client = @import("installer_client.zig");
const configs = @import("configs.zig");
const stow = @import("stow.zig");

pub fn run(
    alloc: std.mem.Allocator,
    io: std.Io,
    paths: paths_mod.Paths,
    policy: configs.ConflictPolicy,
) !void {
    const cwd = std.Io.Dir.cwd();
    const receipt = (try receipt_mod.load(alloc, io, paths.installed)) orelse {
        std.log.info("nothing installed", .{});
        return;
    };

    // 1. Remove dev-env-managed configs from $HOME.
    if (receipt.stow_packages.len > 0) {
        try stow.run(alloc, io, paths.stow_source, paths.home, .delete, receipt.stow_packages);
    }

    // 2. With the backup policy, keep a copy of the managed config trees
    //    (including any local modifications) before state is deleted.
    if (policy == .backup and receipt.stow_packages.len > 0) {
        const now: u64 = @intCast(std.Io.Timestamp.now(io, .real).toSeconds());
        const timestamp = try configs.formatTimestamp(alloc, now);
        const dotfiles_dir = try paths.releaseDotfiles(alloc, receipt.installer_release);
        for (receipt.stow_packages) |package| {
            const source = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dotfiles_dir, package });
            std.Io.Dir.accessAbsolute(io, source, .{}) catch continue;
            const rel = try std.fmt.allocPrint(alloc, "dotfiles/{s}", .{package});
            const backup = try configs.moveToBackup(alloc, io, paths.backups, timestamp, rel, source);
            std.log.info("backed up {s} to {s}", .{ package, backup });
        }
    }

    // 3. Release-owned tools, via the exact installer recorded at apply time.
    const installer_bin = receipt.installer_path;
    std.Io.Dir.accessAbsolute(io, installer_bin, .{}) catch {
        std.log.err("recorded installer missing: {s}", .{installer_bin});
        return error.InstallerNotFound;
    };
    const response = try client.uninstall(alloc, io, installer_bin, .{
        .protocol = proto.version,
        .platform = receipt.platform,
        .tools = try receipt.toolNames(alloc),
    });
    for (response.removed) |name| std.log.info("removed {s}", .{name});
    for (response.kept_system) |name| {
        std.log.info("kept system package for {s} (remove via apt/brew if wanted)", .{name});
    }

    // 4. Leftover opt prefixes from older releases/deactivated tools.
    for (receipt.owned_prefixes) |prefix| {
        cwd.deleteTree(io, prefix) catch {};
    }

    // 5. dev-env state and the launcher; backups are kept.
    const launcher_link = try std.fmt.allocPrint(alloc, "{s}/dev-env", .{paths.bin});
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    if (std.Io.Dir.readLinkAbsolute(io, launcher_link, &buffer)) |len| {
        if (std.mem.startsWith(u8, buffer[0..len], paths.data)) {
            std.Io.Dir.deleteFileAbsolute(io, launcher_link) catch {};
        }
    } else |_| {}

    for ([_][]const u8{ paths.releases, paths.stow_source, paths.installers, paths.launcher }) |dir| {
        cwd.deleteTree(io, dir) catch {};
    }
    for ([_][]const u8{ paths.lock, paths.installed }) |file| {
        std.Io.Dir.deleteFileAbsolute(io, file) catch {};
    }
    if (cwd.deleteDir(io, paths.data)) {
        std.log.info("uninstalled; removed {s}", .{paths.data});
    } else |_| {
        std.log.info("uninstalled; kept {s} (backups remain)", .{paths.backups});
    }
}
