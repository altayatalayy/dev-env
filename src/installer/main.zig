//! dev-env-install entry point: adapts JSON commands on stdin/stdout to the
//! typed API in api.zig. Human-readable diagnostics go to stderr; stdout is
//! reserved for line-delimited JSON protocol messages.

const std = @import("std");
const shared = @import("shared");
const proto = shared.protocol;
const api = @import("api.zig");

pub fn main(init: std.process.Init) u8 {
    const alloc = @field(init, "arena").allocator();
    const io = init.io;

    const argv = init.minimal.args.toSlice(alloc) catch |err| {
        std.log.err("dev-env-install: {t}", .{err});
        return 1;
    };
    if (argv.len <= 1) {
        std.log.err("dev-env-install: missing command", .{});
        return 1;
    }

    const cmd = parseCommand(argv[1]) catch {
        std.log.err("dev-env-install: unknown command: {s}", .{argv[1]});
        return 1;
    };

    const env = loadEnv(alloc, init.environ_map) catch |err| {
        std.log.err("dev-env-install: {t}", .{err});
        return 1;
    };
    var stdin_buffer: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buffer);
    const input = stdin_reader.interface.allocRemaining(alloc, .unlimited) catch |err| {
        std.log.err("dev-env-install: {t}", .{err});
        return 1;
    };

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout_writer.interface;
    var progress: api.Progress = .{ .alloc = alloc, .writer = out, .command = cmd };

    switch (cmd) {
        .metadata => {
            const response = api.metadata(alloc) catch |err| {
                std.log.err("dev-env-install: {t}", .{err});
                return 1;
            };
            proto.writeFinal(alloc, out, cmd, response) catch |err| {
                std.log.err("dev-env-install: {t}", .{err});
                return 1;
            };
        },
        .resolve => {
            const req = proto.parseRequest(proto.ResolveRequest, alloc, cmd, input) catch |err| {
                std.log.err("dev-env-install: {t}", .{err});
                return 1;
            };
            const response = api.resolve(alloc, &progress, req) catch |err| {
                std.log.err("dev-env-install: {t}", .{err});
                return 1;
            };
            proto.writeFinal(alloc, out, cmd, response) catch |err| {
                std.log.err("dev-env-install: {t}", .{err});
                return 1;
            };
        },
        .apply => {
            const req = proto.parseRequest(proto.ApplyRequest, alloc, cmd, input) catch |err| {
                std.log.err("dev-env-install: {t}", .{err});
                return 1;
            };
            const response = api.apply(alloc, io, env, &progress, req) catch |err| {
                std.log.err("dev-env-install: {t}", .{err});
                return 1;
            };
            proto.writeFinal(alloc, out, cmd, response) catch |err| {
                std.log.err("dev-env-install: {t}", .{err});
                return 1;
            };
        },
        .verify => {
            const req = proto.parseRequest(proto.VerifyRequest, alloc, cmd, input) catch |err| {
                std.log.err("dev-env-install: {t}", .{err});
                return 1;
            };
            const response = api.verify(alloc, io, env, &progress, req) catch |err| {
                std.log.err("dev-env-install: {t}", .{err});
                return 1;
            };
            proto.writeFinal(alloc, out, cmd, response) catch |err| {
                std.log.err("dev-env-install: {t}", .{err});
                return 1;
            };
        },
        .@"apply-configs" => {
            const req = proto.parseRequest(proto.ConfigApplyRequest, alloc, cmd, input) catch |err| {
                std.log.err("dev-env-install: {t}", .{err});
                return 1;
            };
            const response = api.applyConfigs(alloc, io, env, &progress, req) catch |err| {
                std.log.err("dev-env-install: {t}", .{err});
                return 1;
            };
            proto.writeFinal(alloc, out, cmd, response) catch |err| {
                std.log.err("dev-env-install: {t}", .{err});
                return 1;
            };
        },
        .uninstall => {
            const req = proto.parseRequest(proto.UninstallRequest, alloc, cmd, input) catch |err| {
                std.log.err("dev-env-install: {t}", .{err});
                return 1;
            };
            const response = api.uninstall(alloc, io, env, &progress, req) catch |err| {
                std.log.err("dev-env-install: {t}", .{err});
                return 1;
            };
            proto.writeFinal(alloc, out, cmd, response) catch |err| {
                std.log.err("dev-env-install: {t}", .{err});
                return 1;
            };
        },
        .@"extract-dotfiles" => {
            const req = proto.parseRequest(proto.ExtractDotfilesRequest, alloc, cmd, input) catch |err| {
                std.log.err("dev-env-install: {t}", .{err});
                return 1;
            };
            const response = api.extractDotfiles(alloc, io, &progress, req) catch |err| {
                std.log.err("dev-env-install: {t}", .{err});
                return 1;
            };
            proto.writeFinal(alloc, out, cmd, response) catch |err| {
                std.log.err("dev-env-install: {t}", .{err});
                return 1;
            };
        },
    }

    return 0;
}

fn parseCommand(word: []const u8) error{UnknownCommand}!proto.Command {
    return std.meta.stringToEnum(proto.Command, word) orelse error.UnknownCommand;
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

test parseCommand {
    try std.testing.expectEqual(proto.Command.metadata, try parseCommand("metadata"));
    try std.testing.expectEqual(proto.Command.@"apply-configs", try parseCommand("apply-configs"));
    try std.testing.expectEqual(proto.Command.@"extract-dotfiles", try parseCommand("extract-dotfiles"));
    try std.testing.expectError(error.UnknownCommand, parseCommand("missing"));
}

test {
    _ = @import("api.zig");
    _ = @import("apply.zig");
    _ = @import("dotfiles.zig");
    _ = @import("git.zig");
    _ = @import("layout.zig");
    _ = @import("planner.zig");
    _ = @import("release.zig");
    _ = @import("resolver.zig");
    _ = @import("steps.zig");
    _ = @import("tools.zig");
    _ = @import("uninstall.zig");
    _ = @import("verify.zig");
}
