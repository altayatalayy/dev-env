//! Removal of release-owned tools. Archive and source tools lose their bin
//! links and their whole <opt>/<tool> prefix; system packages are never
//! removed here. Official installers run their uninstall steps when they
//! have any, otherwise the tool is reported as kept.

const std = @import("std");
const shared = @import("shared");
const proto = shared.protocol;
const resolver = @import("resolver.zig");
const release = @import("release.zig");
const apply = @import("apply.zig");
const tools = @import("tools.zig");
const steps_mod = @import("steps.zig");
const progress_mod = @import("progress.zig");

pub fn uninstall(
    alloc: std.mem.Allocator,
    io: std.Io,
    env: apply.Env,
    progress: ?*progress_mod.Progress,
    req: proto.UninstallRequest,
) !proto.UninstallResponse {
    const pm = req.platform.packageManager();
    var step_env = try steps_mod.stepEnviron(
        alloc,
        env.environ_map,
        env.layout,
        release.defs,
        pm,
        req.tools,
    );
    defer step_env.deinit();

    var removed: std.ArrayList([]const u8) = .empty;
    var kept_system: std.ArrayList([]const u8) = .empty;

    for (req.tools) |name| {
        if (progress) |p| try p.emit(.{ .event = "step_started", .tool = name, .detail = "uninstall" });
        const id = try resolver.toolByName(release.defs, name);
        const method = release.defs.tool(id).?.method(pm) orelse continue;
        switch (method.method) {
            .system => try kept_system.append(alloc, name),
            .archive => |a| try uninstallOwnedPrefix(alloc, io, env, name, a.bin_links, &removed),
            .source => |s| try uninstallOwnedPrefix(alloc, io, env, name, s.bin_links, &removed),
            .official => |o| {
                if (o.uninstall_steps.len == 0) {
                    try kept_system.append(alloc, name);
                } else {
                    try steps_mod.runSteps(alloc, io, progress, .{ .tool = name }, o.uninstall_steps, .{
                        .vars = .{
                            .home = env.layout.home,
                            .cache_dir = env.layout.cache_dir,
                            .bin = env.layout.bin,
                            .opt = env.layout.opt,
                        },
                        .env = &step_env,
                    });
                    try removed.append(alloc, name);
                }
            },
        }
    }

    return .{ .removed = removed.items, .kept_system = kept_system.items };
}

fn uninstallOwnedPrefix(
    alloc: std.mem.Allocator,
    io: std.Io,
    env: apply.Env,
    name: []const u8,
    bin_links: []const tools.Archive.BinLink,
    removed: *std.ArrayList([]const u8),
) !void {
    const prefix = try env.layout.toolDir(alloc, name);
    for (bin_links) |link| {
        const link_path = try env.layout.binLink(alloc, link.name);
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const len = std.Io.Dir.readLinkAbsolute(io, link_path, &buffer) catch continue;
        if (std.mem.startsWith(u8, buffer[0..len], prefix)) {
            try std.Io.Dir.deleteFileAbsolute(io, link_path);
        }
    }
    std.Io.Dir.cwd().deleteTree(io, prefix) catch {};
    try removed.append(alloc, name);
}
