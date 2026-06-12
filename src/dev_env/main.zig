const std = @import("std");
const shared = @import("shared");
const proto = shared.protocol;
const platform = shared.platform;

const cli = @import("cli.zig");
const paths_mod = @import("paths.zig");
const host_detect = @import("host_detect.zig");
const planner = @import("planner.zig");
const apply_mod = @import("apply.zig");
const uninstall_mod = @import("uninstall.zig");
const clean_mod = @import("clean.zig");
const receipt_mod = @import("receipt.zig");
const client = @import("installer_client.zig");

pub fn main(init: std.process.Init) u8 {
    run(init) catch |err| {
        std.log.err("{t}", .{err});
        return 1;
    };
    return 0;
}

fn run(init: std.process.Init) !void {
    const alloc = @field(init, "arena").allocator();
    const io = init.io;

    var argv: std.ArrayList([]const u8) = .empty;
    var args = init.minimal.args.iterate();
    _ = args.skip();
    while (args.next()) |arg| try argv.append(alloc, arg);

    if (argv.items.len == 0) {
        try printUsage(io);
        return error.InvalidArguments;
    }

    const command = try cli.parse(alloc, argv.items);
    const paths = try pathsFromEnv(alloc, init.environ_map);

    switch (command) {
        .plan => |options| {
            const outcome = try planner.buildPlan(alloc, io, paths, cli.plannerOptions(options));
            const receipt = try receipt_mod.load(alloc, io, paths.installed);
            const diff = try planner.computeDiff(alloc, outcome.lock, outcome.plan, receipt);
            planner.printDiff(diff);
        },
        .apply => |options| try apply_mod.run(
            alloc,
            io,
            paths,
            cli.applyPlannerOptions(options, .keep_locked),
            options.policy,
        ),
        .upgrade => |options| try apply_mod.run(
            alloc,
            io,
            paths,
            cli.applyPlannerOptions(options, .newest),
            options.policy,
        ),
        .doctor => try runDoctor(alloc, io, paths),
        .uninstall => |options| try uninstall_mod.run(alloc, io, paths, options.policy),
        .clean => try clean_mod.run(alloc, io, paths),
    }
}

fn printUsage(io: std.Io) !void {
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stderr().writer(io, &buffer);
    try writer.interface.writeAll(cli.usage);
    try writer.interface.flush();
}

fn pathsFromEnv(alloc: std.mem.Allocator, environ_map: *std.process.Environ.Map) !paths_mod.Paths {
    const home = environ_map.get("HOME") orelse return error.HomeNotSet;
    return paths_mod.Paths.init(alloc, home);
}

fn runDoctor(
    alloc: std.mem.Allocator,
    io: std.Io,
    paths: paths_mod.Paths,
) !void {
    const host = try host_detect.detect(alloc, io);
    std.log.info("host: {f}", .{host});

    const lock = try planner.loadLock(alloc, io, paths);
    const receipt = try receipt_mod.load(alloc, io, paths.installed);
    const inst = if (receipt) |r|
        try client.local(alloc, io, r.installer_path)
    else if (lock) |l|
        try client.local(alloc, io, l.installer_path)
    else
        try selectedInstaller(alloc, io, paths, host, null);
    if (!inst.protocolSupported()) return error.UnsupportedProtocol;
    if (!inst.supportsPlatform(host)) return error.UnsupportedPlatform;
    std.log.info("installer: {s} ({s})", .{ inst.release, inst.bin_path });

    if (lock) |l| {
        if (!l.platform.eql(host)) std.log.warn("lock platform differs: {f}", .{l.platform});
        std.log.info("lock: {s}", .{l.installer_release});
    } else {
        std.log.warn("lock.json missing", .{});
    }

    if (receipt) |r| {
        std.log.info("installed: {s}", .{r.installer_release});
        if (!std.mem.eql(u8, r.installer_path, inst.bin_path)) {
            std.log.warn("installed tools were applied by {s}", .{r.installer_path});
        }
        const verify = try client.verify(alloc, io, .{
            .release = r.installer_release,
            .bin_path = r.installer_path,
            .meta = inst.meta,
        }, .{
            .protocol = proto.version,
            .platform = r.platform,
            .tools = try r.toolNames(alloc),
        });
        for (verify.results) |result| {
            if (result.ok) {
                std.log.info("verify {s}: {s}", .{ result.tool, result.detail });
            } else {
                std.log.err("verify {s}: {s}", .{ result.tool, result.detail });
            }
        }
        try checkStowState(alloc, io, paths, r);
    } else {
        std.log.warn("installed.json missing", .{});
    }
}

fn selectedInstaller(
    alloc: std.mem.Allocator,
    io: std.Io,
    paths: paths_mod.Paths,
    host: platform.Platform,
    maybe_path: ?[]const u8,
) !client.Installer {
    if (maybe_path) |path| return client.local(alloc, io, path);

    if (try planner.loadLock(alloc, io, paths)) |lock| {
        return client.local(alloc, io, lock.installer_path);
    }

    const installers = try client.discover(alloc, io, paths);
    return (try client.newestCompatible(installers, host)) orelse error.NoCompatibleInstaller;
}

fn checkStowState(
    alloc: std.mem.Allocator,
    io: std.Io,
    paths: paths_mod.Paths,
    receipt: receipt_mod.Receipt,
) !void {
    for (receipt.stow_packages) |package| {
        const link = try paths.stowPackageLink(alloc, package);
        std.Io.Dir.accessAbsolute(io, link, .{}) catch |err| {
            std.log.err("stow package {s}: {t}", .{ package, err });
        };
    }
    for (receipt.skipped_configs) |config| std.log.warn("config skipped: {s}", .{config});
}

test {
    _ = @import("cli.zig");
    _ = @import("planner.zig");
    _ = @import("apply.zig");
    _ = @import("configs.zig");
    _ = @import("stow.zig");
    _ = @import("receipt.zig");
    _ = @import("system/manager.zig");
}
