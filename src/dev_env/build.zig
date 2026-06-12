//! `dev-env build`: compiles the release's source-built tools on the host it
//! runs on and packages each into a deterministic archive, then writes/merges
//! source-builds.json so a release server can hand the prebuilt archive to
//! targets that must never compile locally.
//!
//! Platform/version/arch are always the detected host; there is deliberately
//! no override (see cli.Command.Build).

const std = @import("std");
const builtin = @import("builtin");
const shared = @import("shared");
const proto = shared.protocol;
const platform = shared.platform;
const manifest_mod = shared.source_builds;
const runner = shared.runner;
const ids = shared.ids;
const paths_mod = @import("paths.zig");
const host_detect = @import("host_detect.zig");
const client = @import("installer_client.zig");
const cli = @import("cli.zig");
const system = @import("system/manager.zig");

pub fn run(
    alloc: std.mem.Allocator,
    io: std.Io,
    paths: paths_mod.Paths,
    options: cli.Command.Build,
) !void {
    const release_root = options.release_root orelse {
        std.log.err("build requires --release-root <dir>", .{});
        return error.MissingReleaseRoot;
    };
    const host = try host_detect.detect(alloc, io);
    const inst = try selectInstaller(alloc, io, paths, host, options.installer_path);
    try inst.ensureCompatible(host);

    const available = try alloc.alloc([]const u8, inst.meta.tools.len);
    for (inst.meta.tools, available) |tool, *name| name.* = tool.name;

    const discovery = try client.resolve(alloc, io, inst, .{
        .protocol = proto.version,
        .platform = host,
        .tools = available,
        .include_configs = false,
        .include_runtime_dependencies = false,
    });
    const selected_sources = try selectedSourceTools(alloc, discovery, options.tools);
    if (selected_sources.len == 0) {
        std.log.info("no source-buildable tools for {f}", .{host});
        return;
    }

    const resolved = try client.resolve(alloc, io, inst, .{
        .protocol = proto.version,
        .platform = host,
        .tools = selected_sources,
        .include_configs = false,
        .include_runtime_dependencies = false,
    });
    const archive_targets = try sourceActions(alloc, resolved.tool_actions);

    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, release_root);
    const abs_release_root = try cwd.realPathFileAlloc(io, release_root, alloc);

    // Install only the system packages required by this source-build plan. The
    // package manager modules detect the missing set first, which gives us an
    // Ansible-like changed/no-change decision instead of blindly invoking the
    // package manager.
    const manager: system.Manager = .init(host.packageManager());
    const package_result = try manager.ensureInstalled(alloc, io, resolved.system_packages);
    if (package_result.changed()) {
        std.log.info("system packages changed: {d} installed", .{package_result.installed.len});
    }

    // Install/activate the full resolved build closure, not only the final
    // source targets: source builds may need archive/official toolchains such
    // as Zig or Rust before their build steps can run.
    const applied = try client.applyTools(alloc, io, inst, .{
        .protocol = proto.version,
        .platform = host,
        .layout = paths.installLayout(),
        .tools = resolved.resolved_tools,
        .install = resolved.resolved_tools,
        .deactivate = &.{},
    });

    var additions: std.ArrayList(manifest_mod.Entry) = .empty;
    for (applied.tools) |tool| {
        if (tool.kind != .source) continue;
        if (!ids.contains(archive_targets, tool.tool)) continue;
        const opt_dir = tool.opt_dir orelse {
            std.log.err("{s} reported no built prefix", .{tool.tool});
            return error.MissingBuildPrefix;
        };

        const filename = try std.fmt.allocPrint(alloc, "{s}-{s}-{s}-{s}-{s}.tar.zst", .{
            tool.tool,
            tool.version,
            @tagName(host),
            host.fields().version,
            @tagName(host.fields().arch),
        });
        const archive_path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ abs_release_root, filename });

        try packageDir(io, opt_dir, archive_path);
        const sha = try sha256OfFile(alloc, io, archive_path);

        try additions.append(alloc, .{
            .tool = tool.tool,
            .version = tool.version,
            .platform = @tagName(host),
            .platform_version = host.fields().version,
            .arch = @tagName(host.fields().arch),
            .filename = filename,
            .sha256 = try alloc.dupe(u8, &sha),
        });
        std.log.info("packaged {s} -> {s}", .{ tool.tool, filename });
    }

    try writeManifest(alloc, io, abs_release_root, additions.items);
    std.log.info("wrote {d} source build(s) to {s}/source-builds.json", .{ additions.items.len, abs_release_root });
}

fn selectedSourceTools(
    alloc: std.mem.Allocator,
    discovery: proto.ResolveResponse,
    requested: []const []const u8,
) ![]const []const u8 {
    const all_sources = try sourceActions(alloc, discovery.tool_actions);
    if (requested.len == 0) return all_sources;

    var selected: std.ArrayList([]const u8) = .empty;
    for (requested) |name| {
        if (!ids.contains(all_sources, name)) {
            if (!builtin.is_test) {
                std.log.err("{s} is not source-buildable on this platform", .{name});
            }
            return error.NotSourceBuildable;
        }
        try selected.append(alloc, name);
    }
    return ids.sortedUnique(alloc, selected.items);
}

fn sourceActions(alloc: std.mem.Allocator, actions: []const proto.ToolAction) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (actions) |action| {
        if (action.kind == .source) try out.append(alloc, action.tool);
    }
    return ids.sortedUnique(alloc, out.items);
}

fn selectInstaller(
    alloc: std.mem.Allocator,
    io: std.Io,
    paths: paths_mod.Paths,
    host: platform.Platform,
    maybe_path: ?[]const u8,
) !client.Installer {
    if (maybe_path) |path| return client.local(alloc, io, path);
    const installers = try client.discover(alloc, io, paths);
    return (try client.newestCompatible(installers, host)) orelse {
        std.log.err("no compatible installer for {f} under {s}", .{ host, paths.installers });
        return error.NoCompatibleInstaller;
    };
}

/// Deterministic tar.zst of `dir`'s contents (sorted, zeroed owner/mtime) so
/// identical source builds produce byte-identical archives.
fn packageDir(io: std.Io, dir: []const u8, archive_path: []const u8) !void {
    const term = try runner.runInherit(io, &.{
        "tar",
        "--zstd",
        "--create",
        "--format=ustar",
        "--sort=name",
        "--owner=0",
        "--group=0",
        "--numeric-owner",
        "--mtime=@0",
        "--file",
        archive_path,
        "--directory",
        dir,
        ".",
    });
    if (!runner.succeeded(term)) return error.PackageFailed;
}

fn sha256OfFile(alloc: std.mem.Allocator, io: std.Io, path: []const u8) ![64]u8 {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited);
    defer alloc.free(bytes);
    return manifest_mod.sha256Hex(bytes);
}

fn writeManifest(
    alloc: std.mem.Allocator,
    io: std.Io,
    release_root: []const u8,
    additions: []const manifest_mod.Entry,
) !void {
    const path = try std.fmt.allocPrint(alloc, "{s}/source-builds.json", .{release_root});
    const cwd = std.Io.Dir.cwd();

    const base: manifest_mod.Manifest = if (cwd.readFileAlloc(io, path, alloc, .unlimited)) |existing|
        try manifest_mod.parse(alloc, existing)
    else |err| switch (err) {
        error.FileNotFound => .{},
        else => return err,
    };

    const merged = try manifest_mod.merge(alloc, base, additions);
    try manifest_mod.validate(merged);

    const text = try shared.json.stringify(alloc, merged);
    const file = try std.Io.Dir.createFileAbsolute(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, text);
}

// --- tests ---

const testing = std.testing;

test "sourceActions returns sorted unique source tools" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const actions = [_]proto.ToolAction{
        .{ .tool = "tmux", .kind = .source, .version = "1" },
        .{ .tool = "zig", .kind = .archive, .version = "1" },
        .{ .tool = "git", .kind = .source, .version = "1" },
        .{ .tool = "tmux", .kind = .source, .version = "1" },
    };
    const sources = try sourceActions(alloc, &actions);

    const expected = [_][]const u8{ "git", "tmux" };
    try testing.expectEqual(expected.len, sources.len);
    for (expected, sources) |want, got| {
        try testing.expectEqualStrings(want, got);
    }
}

test "selectedSourceTools accepts all or requested source-only tools" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const discovery: proto.ResolveResponse = .{
        .selected_tools = &.{ "git", "zig", "tmux" },
        .resolved_tools = &.{ "git", "zig", "tmux" },
        .resolved_configs = &.{},
        .system_packages = .{},
        .stow_packages = &.{},
        .tool_actions = &.{
            .{ .tool = "git", .kind = .source, .version = "1" },
            .{ .tool = "tmux", .kind = .source, .version = "1" },
            .{ .tool = "zig", .kind = .archive, .version = "1" },
        },
    };

    const all = try selectedSourceTools(alloc, discovery, &.{});
    try testing.expectEqual(@as(usize, 2), all.len);
    try testing.expectEqualStrings("git", all[0]);
    try testing.expectEqualStrings("tmux", all[1]);

    const selected = try selectedSourceTools(alloc, discovery, &.{ "tmux", "tmux" });
    try testing.expectEqual(@as(usize, 1), selected.len);
    try testing.expectEqualStrings("tmux", selected[0]);

    try testing.expectError(error.NotSourceBuildable, selectedSourceTools(alloc, discovery, &.{"zig"}));
}
