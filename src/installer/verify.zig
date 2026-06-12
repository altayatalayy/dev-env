//! Verification of installed tools, used by `dev-env doctor`.

const std = @import("std");
const shared = @import("shared");
const proto = shared.protocol;
const resolver = @import("resolver.zig");
const release = @import("release.zig");
const apply = @import("apply.zig");
const tools = @import("tools.zig");
const layout_mod = @import("layout.zig");
const steps_mod = @import("steps.zig");
const progress_mod = @import("progress.zig");

pub const Env = apply.Env;

pub fn verify(
    alloc: std.mem.Allocator,
    io: std.Io,
    env: Env,
    progress: ?*progress_mod.Progress,
    req: proto.VerifyRequest,
) !proto.VerifyResponse {
    const pm = req.platform.packageManager();

    // Same PATH the install/build steps saw: layout bin plus tool exports.
    var step_env = try steps_mod.stepEnviron(
        alloc,
        env.environ_map,
        env.layout,
        release.defs,
        pm,
        req.tools,
    );
    defer step_env.deinit();
    const path_env = step_env.get("PATH") orelse "";

    var results: std.ArrayList(proto.VerifyResult) = .empty;

    for (req.tools) |name| {
        if (progress) |p| try p.emit(.{ .event = "verify_started", .tool = name });
        const id = try resolver.toolByName(release.defs, name);
        const method = release.defs.tool(id).?.method(pm) orelse {
            try results.append(alloc, .{
                .tool = name,
                .ok = false,
                .detail = "not available on this platform",
            });
            continue;
        };
        const result: proto.VerifyResult = switch (method.method) {
            .archive => |a| try verifyBinLinks(alloc, io, env.layout, name, a.version, a.bin_links),
            .source => |s| try verifyBinLinks(alloc, io, env.layout, name, s.version, s.bin_links),
            .system => |s| .{
                .tool = name,
                .ok = foundOnPath(alloc, io, path_env, s.check_bin),
                .detail = try std.fmt.allocPrint(alloc, "system package ({s})", .{s.check_bin}),
            },
            .official => |o| try verifyOfficial(alloc, io, path_env, name, o),
        };
        try results.append(alloc, result);
        if (progress) |p| try p.emit(.{ .event = "verify_finished", .tool = name, .detail = result.detail });
    }

    return .{ .results = results.items };
}

fn verifyOfficial(
    alloc: std.mem.Allocator,
    io: std.Io,
    path_env: []const u8,
    name: []const u8,
    official: tools.OfficialInstaller,
) !proto.VerifyResult {
    for (official.verify_bins) |bin| {
        if (!foundOnPath(alloc, io, path_env, bin)) {
            return .{
                .tool = name,
                .ok = false,
                .detail = try std.fmt.allocPrint(alloc, "missing {s}", .{bin}),
            };
        }
    }
    return .{
        .tool = name,
        .ok = true,
        .detail = try std.fmt.allocPrint(alloc, "{s} available", .{official.version}),
    };
}

fn verifyBinLinks(
    alloc: std.mem.Allocator,
    io: std.Io,
    layout: layout_mod.Layout,
    name: []const u8,
    version: []const u8,
    bin_links: []const tools.Archive.BinLink,
) !proto.VerifyResult {
    const dest = try layout.versionDir(alloc, name, version);
    if (!apply.exists(io, dest)) {
        return .{
            .tool = name,
            .ok = false,
            .detail = try std.fmt.allocPrint(alloc, "missing {s}", .{dest}),
        };
    }
    for (bin_links) |link| {
        const link_path = try layout.binLink(alloc, link.name);
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const len = std.Io.Dir.readLinkAbsolute(io, link_path, &buffer) catch {
            return .{
                .tool = name,
                .ok = false,
                .detail = try std.fmt.allocPrint(alloc, "missing link {s}", .{link_path}),
            };
        };
        const expected = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dest, link.rel_path });
        if (!std.mem.eql(u8, buffer[0..len], expected)) {
            return .{
                .tool = name,
                .ok = false,
                .detail = try std.fmt.allocPrint(alloc, "{s} points elsewhere", .{link_path}),
            };
        }
    }
    return .{
        .tool = name,
        .ok = true,
        .detail = try std.fmt.allocPrint(alloc, "{s} active", .{version}),
    };
}

fn foundOnPath(alloc: std.mem.Allocator, io: std.Io, path_env: []const u8, bin: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        const candidate = std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, bin }) catch return false;
        defer alloc.free(candidate);
        if (apply.exists(io, candidate)) return true;
    }
    return false;
}
