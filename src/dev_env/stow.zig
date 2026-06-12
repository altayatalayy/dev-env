//! GNU Stow execution. dev-env owns stowing; installers only ship the
//! dotfiles trees.

const std = @import("std");
const shared = @import("shared");
const runner = shared.runner;

pub const Mode = enum {
    restow,
    delete,

    fn flag(mode: Mode) []const u8 {
        return switch (mode) {
            .restow => "--restow",
            .delete => "--delete",
        };
    }
};

pub fn args(
    alloc: std.mem.Allocator,
    stow_dir: []const u8,
    target: []const u8,
    mode: Mode,
    packages: []const []const u8,
) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(alloc, &.{
        "stow",
        try std.fmt.allocPrint(alloc, "--dir={s}", .{stow_dir}),
        try std.fmt.allocPrint(alloc, "--target={s}", .{target}),
        mode.flag(),
    });
    try argv.appendSlice(alloc, packages);
    return argv.items;
}

pub fn run(
    alloc: std.mem.Allocator,
    io: std.Io,
    stow_dir: []const u8,
    target: []const u8,
    mode: Mode,
    packages: []const []const u8,
) !void {
    if (packages.len == 0) return;
    const argv = try args(alloc, stow_dir, target, mode, packages);
    const result = std.process.run(alloc, io, .{ .argv = argv }) catch |err| switch (err) {
        error.FileNotFound => {
            std.log.err("GNU Stow is not installed", .{});
            return error.StowMissing;
        },
        else => return err,
    };
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    if (!runner.succeeded(result.term)) {
        std.log.err("stow failed:\n{s}", .{result.stderr});
        return error.StowFailed;
    }
}

test args {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const restow = try args(
        alloc,
        "/home/u/.local/share/dev-env/stow-source",
        "/home/u",
        .restow,
        &.{ "neovim", "tmux" },
    );
    const expected = [_][]const u8{
        "stow",
        "--dir=/home/u/.local/share/dev-env/stow-source",
        "--target=/home/u",
        "--restow",
        "neovim",
        "tmux",
    };
    try std.testing.expectEqual(expected.len, restow.len);
    for (expected, restow) |want, got| {
        try std.testing.expectEqualStrings(want, got);
    }

    const delete = try args(alloc, "/d", "/t", .delete, &.{"tmux"});
    try std.testing.expectEqualStrings("--delete", delete[3]);
}
