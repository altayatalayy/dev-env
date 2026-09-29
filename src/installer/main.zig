//! dev-env-install entry point: adapts JSON commands on stdin/stdout to the
//! typed API in api.zig. Human-readable diagnostics go to stderr; stdout is
//! reserved for line-delimited JSON protocol messages.

const std = @import("std");
const shared = @import("shared");
const proto = shared.protocol;
const api = @import("api.zig");

pub fn main(init: std.process.Init) u8 {
    const alloc = @field(init, "arena").allocator();
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

    run(init, alloc, cmd) catch |err| {
        std.log.err("dev-env-install: {t}", .{err});
        return 1;
    };
    return 0;
}

fn run(init: std.process.Init, alloc: std.mem.Allocator, cmd: proto.Command) !void {
    const io = init.io;
    const env = try loadEnv(init.environ_map);
    var stdin_buffer: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buffer);
    const input = try stdin_reader.interface.allocRemaining(alloc, .unlimited);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout_writer.interface;
    var progress: api.Progress = .{ .alloc = alloc, .writer = out, .command = cmd };

    switch (cmd) {
        .metadata => {
            const response = try api.metadata(alloc);
            try proto.writeFinal(alloc, out, cmd, response);
        },
        .resolve => {
            const req = try proto.parseRequest(proto.ResolveRequest, alloc, input);
            const response = try api.resolve(alloc, &progress, req);
            try proto.writeFinal(alloc, out, cmd, response);
        },
        .apply => {
            const req = try proto.parseRequest(proto.ApplyRequest, alloc, input);
            const response = try api.apply(alloc, io, env, &progress, req);
            try proto.writeFinal(alloc, out, cmd, response);
        },
        .verify => {
            const req = try proto.parseRequest(proto.VerifyRequest, alloc, input);
            const response = try api.verify(alloc, io, env, &progress, req);
            try proto.writeFinal(alloc, out, cmd, response);
        },
        .@"apply-configs" => {
            const req = try proto.parseRequest(proto.ConfigApplyRequest, alloc, input);
            const response = try api.applyConfigs(alloc, io, env, &progress, req);
            try proto.writeFinal(alloc, out, cmd, response);
        },
        .uninstall => {
            const req = try proto.parseRequest(proto.UninstallRequest, alloc, input);
            const response = try api.uninstall(alloc, io, env, &progress, req);
            try proto.writeFinal(alloc, out, cmd, response);
        },
        .@"extract-dotfiles" => {
            const req = try proto.parseRequest(proto.ExtractDotfilesRequest, alloc, input);
            const response = try api.extractDotfiles(alloc, io, &progress, req);
            try proto.writeFinal(alloc, out, cmd, response);
        },
    }
}

fn parseCommand(word: []const u8) error{UnknownCommand}!proto.Command {
    return std.meta.stringToEnum(proto.Command, word) orelse error.UnknownCommand;
}

fn loadEnv(environ_map: *std.process.Environ.Map) !api.Env {
    const home = environ_map.get("HOME") orelse return error.HomeNotSet;
    return .{
        .home = home,
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
