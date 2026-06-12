//! Tool installation for this release.
//!
//! Archive and source tools land in <opt>/<tool>/<version>/ and are
//! activated by symlinking executables into the layout bin directory.
//! Existing version directories are reused; nothing is deleted here
//! (dev-env clean removes inactive versions). System tools are installed by
//! dev-env via the host package manager and only recorded. Install order is
//! dependency-first so toolchains exist before the builds that need them.

const std = @import("std");
const builtin = @import("builtin");
const shared = @import("shared");
const proto = shared.protocol;
const platform = shared.platform;
const tools = @import("tools.zig");
const resolver = @import("resolver.zig");
const release = @import("release.zig");
const layout_mod = @import("layout.zig");
const steps_mod = @import("steps.zig");
const progress_mod = @import("progress.zig");

pub const Env = struct {
    layout: layout_mod.Layout,
    environ_map: *std.process.Environ.Map,
};

pub fn exists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    return true;
}

pub fn apply(
    alloc: std.mem.Allocator,
    io: std.Io,
    env: Env,
    progress: ?*progress_mod.Progress,
    req: proto.ApplyRequest,
) !proto.ApplyResponse {
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

    var installed: std.ArrayList(proto.InstalledTool) = .empty;

    const ordered = try resolver.installOrder(alloc, release.defs, pm, req.install);
    for (ordered) |name| {
        if (progress) |p| try p.emit(.{ .event = "install_started", .tool = name });
        const id = try resolver.toolByName(release.defs, name);
        const method = release.defs.tool(id).?.method(pm) orelse {
            std.log.err("{s} is not available via {t}", .{ name, pm });
            return error.UnsupportedPlatform;
        };
        switch (method.method) {
            .system => try installed.append(alloc, .{
                .tool = name,
                .kind = .system,
                .version = "system",
            }),
            .archive => |a| try installed.append(
                alloc,
                try installArchive(alloc, io, env.layout, req.platform.fields().arch, progress, name, a),
            ),
            .source => |s| try installed.append(
                alloc,
                try installSource(alloc, io, env.layout, &step_env, progress, name, s),
            ),
            .official => |o| try installed.append(
                alloc,
                try installOfficial(alloc, io, env.layout, &step_env, progress, name, o),
            ),
        }
        if (progress) |p| try p.emit(.{ .event = "install_finished", .tool = name });
    }

    for (req.deactivate) |name| {
        if (progress) |p| try p.emit(.{ .event = "step_started", .tool = name, .detail = "deactivate" });
        const id = try resolver.toolByName(release.defs, name);
        const method = release.defs.tool(id).?.method(pm) orelse continue;
        switch (method.method) {
            .system, .official => {},
            .archive => |a| try deactivateBinLinks(alloc, io, env.layout, name, a.bin_links),
            .source => |s| try deactivateBinLinks(alloc, io, env.layout, name, s.bin_links),
        }
    }

    return .{ .tools = installed.items };
}

pub fn applyConfigs(
    alloc: std.mem.Allocator,
    io: std.Io,
    env: Env,
    progress: ?*progress_mod.Progress,
    req: proto.ConfigApplyRequest,
) !proto.ConfigApplyResponse {
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

    var applied: std.ArrayList([]const u8) = .empty;
    for (req.configs) |name| {
        const id = try resolver.configByName(release.defs, name);
        const def = release.defs.config(id).?;
        if (progress) |p| try p.emit(.{ .event = "config_apply_started", .config = name });
        try steps_mod.runSteps(alloc, io, progress, .{ .config = name }, def.install_steps, .{
            .vars = .{ .home = env.layout.home, .cache_dir = env.layout.cache_dir },
            .env = &step_env,
        });
        if (progress) |p| try p.emit(.{ .event = "config_apply_finished", .config = name });
        try applied.append(alloc, name);
    }
    return .{ .applied = applied.items };
}

fn installOfficial(
    alloc: std.mem.Allocator,
    io: std.Io,
    layout: layout_mod.Layout,
    step_env: *const std.process.Environ.Map,
    progress: ?*progress_mod.Progress,
    name: []const u8,
    official: tools.OfficialInstaller,
) !proto.InstalledTool {
    try steps_mod.runSteps(alloc, io, progress, .{ .tool = name }, official.install_steps, .{
        .vars = .{ .home = layout.home, .cache_dir = layout.cache_dir },
        .env = step_env,
    });
    return .{
        .tool = name,
        .kind = .official,
        .version = official.version,
    };
}

fn installSource(
    alloc: std.mem.Allocator,
    io: std.Io,
    layout: layout_mod.Layout,
    step_env: *const std.process.Environ.Map,
    progress: ?*progress_mod.Progress,
    name: []const u8,
    source: tools.SourceBuild,
) !proto.InstalledTool {
    const cwd = std.Io.Dir.cwd();
    const dest = try layout.versionDir(alloc, name, source.version);
    if (!exists(io, dest)) {
        if (progress) |p| try p.emit(.{ .event = "build_started", .tool = name, .detail = source.version });
        const archive_path = try download(alloc, io, layout.cache_dir, source.url);
        const build_dir = try std.fmt.allocPrint(alloc, "{s}.build", .{dest});
        cwd.deleteTree(io, build_dir) catch {};
        try extractTo(alloc, io, archive_path, source.format, source.strip_components, build_dir);
        defer cwd.deleteTree(io, build_dir) catch {};

        if (std.fs.path.dirname(dest)) |parent| try cwd.createDirPath(io, parent);
        try steps_mod.runSteps(alloc, io, progress, .{ .tool = name }, source.build_steps, .{
            .cwd = build_dir,
            .vars = .{ .home = layout.home, .cache_dir = layout.cache_dir, .prefix = dest },
            .env = step_env,
        });
        if (progress) |p| try p.emit(.{ .event = "build_finished", .tool = name, .detail = source.version });
    } else if (progress) |p| {
        try p.emit(.{ .event = "step_skipped", .tool = name, .detail = "source build already installed" });
    }

    return .{
        .tool = name,
        .kind = .source,
        .version = source.version,
        .opt_dir = dest,
        .bin_links = try activateBinLinks(alloc, io, layout, dest, source.bin_links),
    };
}

fn installArchive(
    alloc: std.mem.Allocator,
    io: std.Io,
    layout: layout_mod.Layout,
    arch: platform.Arch,
    progress: ?*progress_mod.Progress,
    name: []const u8,
    archive: tools.Archive,
) !proto.InstalledTool {
    const source = archive.source(arch) orelse return error.UnsupportedPlatform;

    const dest = try layout.versionDir(alloc, name, archive.version);
    if (!exists(io, dest)) {
        if (progress) |p| try p.emit(.{ .event = "step_started", .tool = name, .detail = "download archive" });
        const archive_path = try download(alloc, io, layout.cache_dir, source.url);
        if (progress) |p| try p.emit(.{ .event = "step_finished", .tool = name, .detail = "download archive" });
        if (progress) |p| try p.emit(.{ .event = "step_started", .tool = name, .detail = "extract archive" });
        try extractTo(alloc, io, archive_path, source.format, source.strip_components, dest);
        if (progress) |p| try p.emit(.{ .event = "step_finished", .tool = name, .detail = "extract archive" });
    } else if (progress) |p| {
        try p.emit(.{ .event = "step_skipped", .tool = name, .detail = "archive already installed" });
    }

    return .{
        .tool = name,
        .kind = .archive,
        .version = archive.version,
        .opt_dir = dest,
        .bin_links = try activateBinLinks(alloc, io, layout, dest, archive.bin_links),
    };
}

/// Creates the layout bin symlinks for an installed version directory and
/// returns their absolute paths.
fn activateBinLinks(
    alloc: std.mem.Allocator,
    io: std.Io,
    layout: layout_mod.Layout,
    dest: []const u8,
    bin_links: []const tools.Archive.BinLink,
) ![]const []const u8 {
    var links: std.ArrayList([]const u8) = .empty;
    for (bin_links) |link| {
        const link_path = try layout.binLink(alloc, link.name);
        const target = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dest, link.rel_path });
        if (!exists(io, target)) {
            std.log.err("missing executable after install: {s}", .{target});
            return error.BrokenInstall;
        }
        try replaceSymlink(alloc, io, layout, target, link_path);
        try links.append(alloc, link_path);
    }
    return links.items;
}

/// Removes layout bin links, but only the ones that actually point into the
/// tool's own prefix.
fn deactivateBinLinks(
    alloc: std.mem.Allocator,
    io: std.Io,
    layout: layout_mod.Layout,
    name: []const u8,
    bin_links: []const tools.Archive.BinLink,
) !void {
    const owned_prefix = try layout.toolDir(alloc, name);
    for (bin_links) |link| {
        const link_path = try layout.binLink(alloc, link.name);
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const len = std.Io.Dir.readLinkAbsolute(io, link_path, &buffer) catch continue;
        if (std.mem.startsWith(u8, buffer[0..len], owned_prefix)) {
            try std.Io.Dir.deleteFileAbsolute(io, link_path);
        }
    }
}

fn replaceSymlink(
    alloc: std.mem.Allocator,
    io: std.Io,
    layout: layout_mod.Layout,
    target: []const u8,
    link_path: []const u8,
) !void {
    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(link_path)) |parent| {
        try cwd.createDirPath(io, parent);
    }

    const stat = cwd.statFile(io, link_path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => {
            try std.Io.Dir.symLinkAbsolute(io, target, link_path, .{});
            return;
        },
        else => return err,
    };

    if (stat.kind != .sym_link) {
        if (!builtin.is_test) {
            std.log.err("executable link conflict: {s} already exists", .{link_path});
        }
        return error.ExecutableConflict;
    }

    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const len = try std.Io.Dir.readLinkAbsolute(io, link_path, &buffer);
    const resolved = try resolveLinkTarget(alloc, link_path, buffer[0..len]);
    if (!isManagedExecutable(resolved, layout.opt)) {
        if (!builtin.is_test) {
            std.log.err("executable link conflict: {s} points to {s}", .{ link_path, resolved });
        }
        return error.ExecutableConflict;
    }

    try std.Io.Dir.deleteFileAbsolute(io, link_path);
    try std.Io.Dir.symLinkAbsolute(io, target, link_path, .{});
}

fn resolveLinkTarget(
    alloc: std.mem.Allocator,
    link_path: []const u8,
    link_value: []const u8,
) ![]const u8 {
    if (std.fs.path.isAbsolute(link_value)) return std.fs.path.resolve(alloc, &.{link_value});
    const dir = std.fs.path.dirname(link_path) orelse "/";
    return std.fs.path.resolve(alloc, &.{ dir, link_value });
}

fn isManagedExecutable(resolved: []const u8, opt_root: []const u8) bool {
    return std.mem.startsWith(u8, resolved, opt_root) and
        (resolved.len == opt_root.len or resolved[opt_root.len] == '/');
}

/// Downloads `url` into the cache directory unless already present; returns
/// the cached file path.
fn download(
    alloc: std.mem.Allocator,
    io: std.Io,
    cache_dir: []const u8,
    url: []const u8,
) ![]const u8 {
    const basename = std.fs.path.basename(url);
    const cached = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ cache_dir, basename });
    if (exists(io, cached)) return cached;

    std.log.info("downloading {s}", .{url});

    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, cache_dir);
    const partial = try std.fmt.allocPrint(alloc, "{s}.partial", .{cached});

    {
        const file = try std.Io.Dir.createFileAbsolute(io, partial, .{});
        defer file.close(io);

        var client: std.http.Client = .{ .allocator = alloc, .io = io };
        defer client.deinit();

        var write_buffer: [64 * 1024]u8 = undefined;
        var file_writer = file.writer(io, &write_buffer);
        const result = try client.fetch(.{
            .location = .{ .url = url },
            .response_writer = &file_writer.interface,
        });
        try file_writer.interface.flush();

        if (result.status != .ok) {
            std.log.err("GET {s} returned {d}", .{ url, @intFromEnum(result.status) });
            return error.DownloadFailed;
        }
    }

    try std.Io.Dir.renameAbsolute(partial, cached, io);
    return cached;
}

/// Extracts the archive into a partial directory, then renames it into place
/// so an interrupted extraction never looks installed.
fn extractTo(
    alloc: std.mem.Allocator,
    io: std.Io,
    archive_path: []const u8,
    format: tools.Archive.Format,
    strip_components: u32,
    dest: []const u8,
) !void {
    const cwd = std.Io.Dir.cwd();
    const partial = try std.fmt.allocPrint(alloc, "{s}.partial", .{dest});
    cwd.deleteTree(io, partial) catch {};
    try cwd.createDirPath(io, partial);

    {
        var partial_dir = try cwd.openDir(io, partial, .{});
        defer partial_dir.close(io);

        const file = try std.Io.Dir.openFileAbsolute(io, archive_path, .{});
        defer file.close(io);
        var read_buffer: [64 * 1024]u8 = undefined;
        var file_reader = file.reader(io, &read_buffer);

        const options: std.tar.ExtractOptions = .{ .strip_components = strip_components };
        switch (format) {
            .tar_gz => {
                const window = try alloc.alloc(u8, std.compress.flate.max_window_len);
                defer alloc.free(window);
                var decompress: std.compress.flate.Decompress = .init(&file_reader.interface, .gzip, window);
                try std.tar.extract(io, partial_dir, &decompress.reader, options);
            },
            .tar_xz => {
                var decompress = try std.compress.xz.Decompress.init(
                    &file_reader.interface,
                    alloc,
                    try alloc.alloc(u8, 0),
                );
                try std.tar.extract(io, partial_dir, &decompress.reader, options);
            },
        }
    }

    try std.Io.Dir.renameAbsolute(partial, dest, io);
}

// --- tests ---

test "apply config command accepts configs without install steps" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    const cache_dir = try std.fs.path.join(alloc, &.{ home, ".cache" });

    var env_map = std.process.Environ.Map.init(alloc);
    defer env_map.deinit();
    try env_map.put("PATH", "");

    const resp = try applyConfigs(alloc, io, .{
        .layout = try layout_mod.Layout.init(alloc, home, cache_dir),
        .environ_map = &env_map,
    }, null, .{
        .protocol = proto.version,
        .platform = .{ .ubuntu = .{ .version = "24.04", .arch = .x86_64 } },
        .tools = &.{},
        .configs = &.{"alacritty-config"},
    });

    try std.testing.expectEqual(@as(usize, 1), resp.applied.len);
    try std.testing.expectEqualStrings("alacritty-config", resp.applied[0]);
}

test "apply installs system tools dependency-first" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    const cache_dir = try std.fs.path.join(alloc, &.{ home, ".cache" });

    var env_map = std.process.Environ.Map.init(alloc);
    defer env_map.deinit();
    try env_map.put("PATH", "");

    // brew: every tool is a system package, so apply only records them.
    const resp = try apply(alloc, io, .{
        .layout = try layout_mod.Layout.init(alloc, home, cache_dir),
        .environ_map = &env_map,
    }, null, .{
        .protocol = proto.version,
        .platform = .{ .macos = .{ .version = "15.5", .arch = .aarch64 } },
        .tools = &.{ "alacritty", "rust" },
        .install = &.{ "alacritty", "rust" },
        .deactivate = &.{},
    });

    try std.testing.expectEqual(@as(usize, 2), resp.tools.len);
    for (resp.tools) |tool| {
        try std.testing.expectEqual(proto.ToolKind.system, tool.kind);
    }
}

test "replaceSymlink only replaces managed executable links" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    const layout = try layout_mod.Layout.init(alloc, home, try std.fmt.allocPrint(alloc, "{s}/.cache", .{home}));

    const old_target = try std.fmt.allocPrint(alloc, "{s}/tmux/old/bin/tmux", .{layout.opt});
    const new_target = try std.fmt.allocPrint(alloc, "{s}/tmux/new/bin/tmux", .{layout.opt});
    if (std.fs.path.dirname(old_target)) |parent| try cwd.createDirPath(io, parent);
    if (std.fs.path.dirname(new_target)) |parent| try cwd.createDirPath(io, parent);
    {
        const file = try std.Io.Dir.createFileAbsolute(io, old_target, .{});
        file.close(io);
    }
    {
        const file = try std.Io.Dir.createFileAbsolute(io, new_target, .{});
        file.close(io);
    }

    const link = try layout.binLink(alloc, "tmux");
    if (std.fs.path.dirname(link)) |parent| try cwd.createDirPath(io, parent);
    try std.Io.Dir.symLinkAbsolute(io, old_target, link, .{});
    try replaceSymlink(alloc, io, layout, new_target, link);

    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const len = try std.Io.Dir.readLinkAbsolute(io, link, &buffer);
    try std.testing.expectEqualStrings(new_target, buffer[0..len]);
}

test "replaceSymlink refuses foreign executable path" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const io = std.testing.io;
    const cwd = std.Io.Dir.cwd();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    const layout = try layout_mod.Layout.init(alloc, home, try std.fmt.allocPrint(alloc, "{s}/.cache", .{home}));

    const target = try std.fmt.allocPrint(alloc, "{s}/tmux/new/bin/tmux", .{layout.opt});
    if (std.fs.path.dirname(target)) |parent| try cwd.createDirPath(io, parent);
    {
        const file = try std.Io.Dir.createFileAbsolute(io, target, .{});
        file.close(io);
    }

    const link = try layout.binLink(alloc, "tmux");
    if (std.fs.path.dirname(link)) |parent| try cwd.createDirPath(io, parent);
    {
        const file = try std.Io.Dir.createFileAbsolute(io, link, .{});
        file.close(io);
    }

    try std.testing.expectError(error.ExecutableConflict, replaceSymlink(alloc, io, layout, target, link));
}
