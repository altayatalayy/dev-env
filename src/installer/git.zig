//! Idempotent Git checkouts owned by config packages.

const std = @import("std");
const shared = @import("shared");
const templates = shared.templates;
const tools = @import("tools.zig");
const steps = @import("steps.zig");
const progress_mod = @import("progress.zig");

pub fn ensureCheckout(
    alloc: std.mem.Allocator,
    io: std.Io,
    progress: ?*progress_mod.Progress,
    config: []const u8,
    checkout: tools.GitCheckout,
    vars: templates.Vars,
    env: *const std.process.Environ.Map,
) !void {
    const destination = try templates.render(alloc, checkout.destination, vars);
    if (exists(io, destination)) {
        const git_dir = try std.fmt.allocPrint(alloc, "{s}/.git", .{destination});
        if (!exists(io, git_dir)) return error.CheckoutDestinationNotRepository;
        return;
    }

    if (std.fs.path.dirname(destination)) |parent| {
        try std.Io.Dir.cwd().createDirPath(io, parent);
    }

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(alloc, &.{ "git", "clone" });
    if (checkout.depth) |depth| {
        try argv.appendSlice(alloc, &.{
            "--depth",
            try std.fmt.allocPrint(alloc, "{d}", .{depth}),
        });
    }
    if (checkout.branch) |branch| {
        try argv.appendSlice(alloc, &.{ "--branch", branch, "--single-branch" });
    }
    try argv.appendSlice(alloc, &.{ checkout.url, checkout.destination });

    try steps.runSteps(alloc, io, progress, .{ .config = config }, &.{.{
        .name = "clone git repository",
        .argv = argv.items,
    }}, .{
        .vars = vars,
        .env = env,
    });
}

fn exists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    return true;
}

test "existing checkout is kept" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    try tmp.dir.createDirPath(io, "plugin/.git");

    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("PATH", "");

    try ensureCheckout(alloc, io, null, "config", .{
        .url = "https://example.invalid/plugin",
        .destination = try std.fmt.allocPrint(alloc, "{s}/plugin", .{root}),
    }, .{
        .home = root,
        .cache_dir = root,
        .bin = root,
        .opt = root,
    }, &env);
}

test "existing non-repository destination is rejected" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    try tmp.dir.createDirPath(io, "plugin");

    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("PATH", "");

    try std.testing.expectError(error.CheckoutDestinationNotRepository, ensureCheckout(
        alloc,
        io,
        null,
        "config",
        .{
            .url = "https://example.invalid/plugin",
            .destination = try std.fmt.allocPrint(alloc, "{s}/plugin", .{root}),
        },
        .{
            .home = root,
            .cache_dir = root,
            .bin = root,
            .opt = root,
        },
        &env,
    ));
}
