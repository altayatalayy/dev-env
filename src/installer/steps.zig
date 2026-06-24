//! Execution of install/build/config steps.
//!
//! Steps never hardcode binary locations: argv[0] is resolved against the
//! step environment's PATH, which starts with the layout bin directory and
//! the exports of every active tool. Step output is streamed into a writer
//! and only logged when the step fails.

const std = @import("std");
const shared = @import("shared");
const proto = shared.protocol;
const platform = shared.platform;
const runner = shared.runner;
const templates = shared.templates;
const tools = @import("tools.zig");
const resolver = @import("resolver.zig");
const layout_mod = @import("layout.zig");
const progress_mod = @import("progress.zig");

pub const Vars = templates.Vars;
pub const render = templates.render;

pub const Context = struct {
    /// Working directory for the steps; null inherits the installer's cwd.
    cwd: ?[]const u8 = null,
    vars: Vars,
    env: *const std.process.Environ.Map,
};

/// What the steps belong to, for progress events and failure logs.
pub const Subject = struct {
    tool: ?[]const u8 = null,
    config: ?[]const u8 = null,

    fn name(s: Subject) []const u8 {
        return s.tool orelse s.config orelse "steps";
    }
};

/// Child environment for steps: the base environment with the layout bin
/// directory and every active tool's exports applied to it.
pub fn stepEnviron(
    alloc: std.mem.Allocator,
    base: *const std.process.Environ.Map,
    layout: layout_mod.Layout,
    defs: resolver.Defs,
    host: platform.Platform,
    active_tools: []const []const u8,
) !std.process.Environ.Map {
    var env = try base.clone(alloc);
    errdefer env.deinit();

    const vars: Vars = .{
        .home = layout.home,
        .cache_dir = layout.cache_dir,
        .bin = layout.bin,
        .opt = layout.opt,
    };
    try prependPath(alloc, &env, layout.bin);

    for (active_tools) |name| {
        const id = try resolver.toolByName(defs, name);
        const def = defs.tool(id).?;
        if (def.method(host) == null) continue;
        for (def.exports) |item| {
            const value = try render(alloc, item.value, vars);
            switch (item.mode) {
                .set => try env.put(item.name, value),
                .prepend_path => try prependPath(alloc, &env, value),
            }
        }
    }

    return env;
}

fn prependPath(
    alloc: std.mem.Allocator,
    env: *std.process.Environ.Map,
    dir: []const u8,
) !void {
    const old = env.get("PATH") orelse "";
    const updated = if (old.len == 0)
        dir
    else
        try std.fmt.allocPrint(alloc, "{s}:{s}", .{ dir, old });
    try env.put("PATH", updated);
}

/// Resolves a step executable against `path_env`. Names containing '/' are
/// returned unchanged; spawn would otherwise resolve against the parent
/// PATH, ignoring the exports built into the step environment.
pub fn findExecutable(
    alloc: std.mem.Allocator,
    io: std.Io,
    path_env: []const u8,
    name: []const u8,
) ![]const u8 {
    if (std.mem.indexOfScalar(u8, name, '/') != null) return name;
    var it = std.mem.tokenizeScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        const candidate = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, name });
        if (std.Io.Dir.accessAbsolute(io, candidate, .{})) |_| {
            return candidate;
        } else |_| {
            alloc.free(candidate);
        }
    }
    return error.ExecutableNotFound;
}

pub fn runSteps(
    alloc: std.mem.Allocator,
    io: std.Io,
    progress: ?*progress_mod.Progress,
    subject: Subject,
    step_list: []const tools.Step,
    ctx: Context,
) !void {
    for (step_list) |step| {
        if (progress) |p| try p.emit(.{
            .event = "step_started",
            .tool = subject.tool,
            .config = subject.config,
            .detail = step.name,
        });

        var sink: std.Io.Writer.Allocating = .init(alloc);
        defer sink.deinit();

        runStep(alloc, io, step, ctx, &sink.writer) catch |err| {
            std.log.err(
                "{s}: step '{s}' failed ({t}):\n{s}",
                .{ subject.name(), step.name, err, sink.written() },
            );
            return error.StepFailed;
        };

        if (progress) |p| try p.emit(.{
            .event = "step_finished",
            .tool = subject.tool,
            .config = subject.config,
            .detail = step.name,
        });
    }
}

/// Runs one step, streaming its stdout and stderr into `sink`. The caller
/// decides what to do with the collected output on failure.
pub fn runStep(
    alloc: std.mem.Allocator,
    io: std.Io,
    step: tools.Step,
    ctx: Context,
    sink: *std.Io.Writer,
) !void {
    const argv = try alloc.alloc([]const u8, step.argv.len);
    defer alloc.free(argv);
    for (step.argv, argv) |arg, *rendered| {
        rendered.* = try render(alloc, arg, ctx.vars);
    }
    argv[0] = findExecutable(alloc, io, ctx.env.get("PATH") orelse "", argv[0]) catch |err| {
        try sink.print("executable not found on step PATH: {s}", .{argv[0]});
        return err;
    };

    var child = try std.process.spawn(io, .{
        .argv = argv,
        .cwd = if (ctx.cwd) |dir| .{ .path = dir } else .inherit,
        .environ_map = ctx.env,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(io);

    var buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi: std.Io.File.MultiReader = undefined;
    multi.init(alloc, io, buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi.deinit();

    while (multi.fill(64, .none)) |_| {
        try drain(&multi, sink);
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }
    try drain(&multi, sink);
    try multi.checkAnyError();

    const term = try child.wait(io);
    if (!runner.succeeded(term)) return error.StepFailed;
}

fn drain(multi: *std.Io.File.MultiReader, sink: *std.Io.Writer) !void {
    for (0..2) |i| {
        const r = multi.reader(i);
        const data = r.buffered();
        if (data.len == 0) continue;
        try sink.writeAll(data);
        r.tossBuffered();
    }
}

// --- tests ---

const testing = std.testing;

test findExecutable {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    try tmp.dir.createDirPath(io, "bin");
    try tmp.dir.writeFile(io, .{ .sub_path = "bin/mytool", .data = "" });

    const path_env = try std.fmt.allocPrint(alloc, "{s}/bin:/nonexistent", .{root});
    const found = try findExecutable(alloc, io, path_env, "mytool");
    const expected = try std.fmt.allocPrint(alloc, "{s}/bin/mytool", .{root});
    try testing.expectEqualStrings(expected, found);

    try testing.expectEqualStrings("./local", try findExecutable(alloc, io, path_env, "./local"));
    try testing.expectError(error.ExecutableNotFound, findExecutable(alloc, io, path_env, "missing"));
}

test "runStep streams output into the sink and fails on bad exit" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const io = testing.io;

    var env = std.process.Environ.Map.init(alloc);
    defer env.deinit();
    try env.put("PATH", "/usr/bin:/bin");

    const ctx: Context = .{
        .vars = .{ .home = "/h", .cache_dir = "/c", .bin = "/b", .opt = "/o" },
        .env = &env,
    };

    var ok_sink: std.Io.Writer.Allocating = .init(alloc);
    defer ok_sink.deinit();
    try runStep(alloc, io, .{
        .name = "echo",
        .argv = &.{ "sh", "-c", "echo out; echo err >&2" },
    }, ctx, &ok_sink.writer);
    try testing.expect(std.mem.indexOf(u8, ok_sink.written(), "out") != null);
    try testing.expect(std.mem.indexOf(u8, ok_sink.written(), "err") != null);

    var fail_sink: std.Io.Writer.Allocating = .init(alloc);
    defer fail_sink.deinit();
    try testing.expectError(error.StepFailed, runStep(alloc, io, .{
        .name = "fail",
        .argv = &.{ "sh", "-c", "echo broken >&2; exit 3" },
    }, ctx, &fail_sink.writer));
    try testing.expect(std.mem.indexOf(u8, fail_sink.written(), "broken") != null);
}

test stepEnviron {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var base = std.process.Environ.Map.init(alloc);
    defer base.deinit();
    try base.put("PATH", "/usr/bin");

    const test_tools = [_]tools.ToolDef{
        .{
            .id = .rust,
            .description = "",
            .platforms = &.{
                .{ .ubuntu = .{ .versions = &.{"24.04"}, .archs = &.{.x86_64} } },
            },
            .exports = &.{
                .{ .name = "CARGO_HOME", .value = "{home}/.local/share/cargo" },
                .{ .name = "PATH", .value = "{home}/.local/share/cargo/bin", .mode = .prepend_path },
            },
            .methods = &.{.{
                .method = .{ .official = .{ .version = "stable", .install_steps = &.{}, .verify_bins = &.{} } },
            }},
        },
    };
    const defs: resolver.Defs = .{ .tools = &test_tools };
    const layout = try layout_mod.Layout.init(alloc, "/h", .{
        .bin = "/h/.local/bin",
        .opt = "/h/.local/share/dev-env/tools",
        .cache_dir = "/c",
    });

    var env = try stepEnviron(
        alloc,
        &base,
        layout,
        defs,
        .{ .ubuntu = .{ .version = "24.04", .arch = .x86_64 } },
        &.{"rust"},
    );
    defer env.deinit();

    try testing.expectEqualStrings("/h/.local/share/cargo", env.get("CARGO_HOME").?);
    try testing.expectEqualStrings(
        "/h/.local/share/cargo/bin:/h/.local/bin:/usr/bin",
        env.get("PATH").?,
    );
}
