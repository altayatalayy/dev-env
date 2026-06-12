//! Removes inactive tool versions and old release state. Normal apply only
//! activates/deactivates; this is the only place old versions are deleted.

const std = @import("std");
const shared = @import("shared");
const ids = shared.ids;
const paths_mod = @import("paths.zig");
const receipt_mod = @import("receipt.zig");

pub fn run(alloc: std.mem.Allocator, io: std.Io, paths: paths_mod.Paths) !void {
    const cwd = std.Io.Dir.cwd();
    const receipt = (try receipt_mod.load(alloc, io, paths.installed)) orelse {
        std.log.info("nothing installed; nothing to clean", .{});
        return;
    };

    var active_dirs: std.ArrayList([]const u8) = .empty;
    for (receipt.tools) |tool| {
        if (tool.opt_dir) |dir| try active_dirs.append(alloc, dir);
    }

    var removed: usize = 0;
    var kept_prefixes: std.ArrayList([]const u8) = .empty;
    for (receipt.owned_prefixes) |prefix| {
        var dir = cwd.openDir(io, prefix, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer dir.close(io);

        var stale: std.ArrayList([]const u8) = .empty;
        var remaining: usize = 0;
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            const full = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ prefix, entry.name });
            if (ids.contains(active_dirs.items, full)) {
                remaining += 1;
            } else {
                try stale.append(alloc, full);
            }
        }
        for (stale.items) |path| {
            std.log.info("removing inactive {s}", .{path});
            try cwd.deleteTree(io, path);
            removed += 1;
        }
        if (remaining == 0) {
            cwd.deleteDir(io, prefix) catch {};
        } else {
            try kept_prefixes.append(alloc, prefix);
        }
    }

    // Old releases' extracted state (dotfiles trees of inactive releases).
    if (cwd.openDir(io, paths.releases, .{ .iterate = true })) |releases_dir| {
        var releases = releases_dir;
        defer releases.close(io);
        var stale: std.ArrayList([]const u8) = .empty;
        var it = releases.iterate();
        while (try it.next(io)) |entry| {
            if (std.mem.eql(u8, entry.name, receipt.installer_release)) continue;
            try stale.append(alloc, try alloc.dupe(u8, entry.name));
        }
        for (stale.items) |name| {
            std.log.info("removing old release state {s}/{s}", .{ paths.releases, name });
            try releases.deleteTree(io, name);
            removed += 1;
        }
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    var updated = receipt;
    updated.owned_prefixes = kept_prefixes.items;
    try receipt_mod.save(alloc, io, paths.installed, updated);

    if (removed == 0) {
        std.log.info("nothing to clean", .{});
    } else {
        std.log.info("cleaned {d} entries", .{removed});
    }
}
