//! dev-env-install entry point: adapts JSON commands on stdin/stdout to the
//! typed API in api.zig. Human-readable diagnostics go to stderr; stdout is
//! reserved for line-delimited JSON protocol messages.

const std = @import("std");
const shared = @import("shared");
const proto = shared.protocol;
const api = @import("api.zig");

pub fn main(init: std.process.Init) u8 {
    run(init) catch |err| {
        std.log.err("dev-env-install: {t}", .{err});
        return 1;
    };
    return 0;
}

fn run(init: std.process.Init) !void {
    const alloc = @field(init, "arena").allocator();
    const io = init.io;

    var args = init.minimal.args.iterate();
    _ = args.skip();
    const cmd_name = args.next() orelse return error.MissingCommand;
    const cmd = std.meta.stringToEnum(proto.Command, cmd_name) orelse {
        std.log.err("dev-env-install: unknown command: {s}", .{cmd_name});
        return error.UnknownCommand;
    };

    const env = try loadEnv(alloc, init.environ_map);
    var stdin_buffer: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buffer);
    const input = try stdin_reader.interface.allocRemaining(alloc, .unlimited);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout_writer.interface;
    var progress: api.Progress = .{ .alloc = alloc, .writer = out, .command = cmd };

    switch (cmd) {
        .metadata => try proto.writeFinal(alloc, out, cmd, try api.metadata(alloc)),
        .resolve => {
            const req = try proto.parseRequest(proto.ResolveRequest, alloc, cmd, input);
            try proto.writeFinal(alloc, out, cmd, try api.resolve(alloc, &progress, req));
        },
        .apply => {
            const req = try proto.parseRequest(proto.ApplyRequest, alloc, cmd, input);
            try proto.writeFinal(alloc, out, cmd, try api.apply(alloc, io, env, &progress, req));
        },
        .verify => {
            const req = try proto.parseRequest(proto.VerifyRequest, alloc, cmd, input);
            try proto.writeFinal(alloc, out, cmd, try api.verify(alloc, io, env, &progress, req));
        },
        .@"apply-configs" => {
            const req = try proto.parseRequest(proto.ConfigApplyRequest, alloc, cmd, input);
            try proto.writeFinal(alloc, out, cmd, try api.applyConfigs(alloc, io, env, &progress, req));
        },
        .uninstall => {
            const req = try proto.parseRequest(proto.UninstallRequest, alloc, cmd, input);
            try proto.writeFinal(alloc, out, cmd, try api.uninstall(alloc, io, env, &progress, req));
        },
        .@"extract-dotfiles" => {
            const req = try proto.parseRequest(proto.ExtractDotfilesRequest, alloc, cmd, input);
            try proto.writeFinal(alloc, out, cmd, try api.extractDotfiles(alloc, io, &progress, req));
        },
    }
}

fn loadEnv(alloc: std.mem.Allocator, environ_map: *std.process.Environ.Map) !api.Env {
    const home = environ_map.get("HOME") orelse return error.HomeNotSet;
    const cache_root = environ_map.get("XDG_CACHE_HOME") orelse
        try std.fmt.allocPrint(alloc, "{s}/.cache", .{home});
    return .{
        .home = home,
        .cache_dir = try std.fmt.allocPrint(alloc, "{s}/dev-env/downloads", .{cache_root}),
        .environ_map = environ_map,
    };
}

test {
    _ = @import("api.zig");
    _ = @import("apply.zig");
    _ = @import("dotfiles.zig");
    _ = @import("layout.zig");
    _ = @import("planner.zig");
    _ = @import("release.zig");
    _ = @import("resolver.zig");
    _ = @import("steps.zig");
    _ = @import("tools.zig");
    _ = @import("uninstall.zig");
    _ = @import("verify.zig");
}
