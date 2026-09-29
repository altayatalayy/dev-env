//! The dotfiles archive embedded into this installer and its extraction.

const std = @import("std");
const zstd = std.compress.zstd;

const archive: []const u8 = @embedFile("dotfiles_archive");

const package_views = [_]PackageView{
    .{ .name = "alacritty", .paths = &.{".config/alacritty"} },
    .{ .name = "nvim", .paths = &.{".config/nvim"} },
    .{ .name = "shell", .paths = &.{ ".bashrc", ".zshenv" } },
    .{ .name = "tmux", .paths = &.{".config/tmux"} },
};

const PackageView = struct {
    name: []const u8,
    paths: []const []const u8,
};

const Decompressor = struct {
    input: std.Io.Reader,
    window: []u8,
    state: zstd.Decompress,

    fn init(d: *Decompressor, alloc: std.mem.Allocator) !void {
        d.input = .fixed(archive);
        d.window = try alloc.alloc(u8, zstd.default_window_len + zstd.block_size_max);
        d.state = .init(&d.input, d.window, .{});
    }

    fn reader(d: *Decompressor) *std.Io.Reader {
        return &d.state.reader;
    }
};

/// GNU Stow package views materialized from the flat embedded dotfiles tree.
pub fn packages(alloc: std.mem.Allocator) ![]const []const u8 {
    const names = try alloc.alloc([]const u8, package_views.len);
    for (package_views, names) |view, *name| name.* = view.name;
    return names;
}

/// Extracts the archive into `dest` (absolute path, created if missing) and
/// returns the extracted package names.
pub fn extract(alloc: std.mem.Allocator, io: std.Io, dest: []const u8) ![]const []const u8 {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, dest);
    var dest_dir = try cwd.openDir(io, dest, .{});
    defer dest_dir.close(io);

    var d: Decompressor = undefined;
    try d.init(alloc);
    try std.tar.extract(io, dest_dir, d.reader(), .{});
    try materializePackageViews(alloc, io, dest);

    return packages(alloc);
}

fn materializePackageViews(alloc: std.mem.Allocator, io: std.Io, dest: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    for (package_views) |view| {
        const package_root = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dest, view.name });
        cwd.deleteTree(io, package_root) catch {};
        try cwd.createDirPath(io, package_root);
        for (view.paths) |rel| {
            const source = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dest, rel });
            const target = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ package_root, rel });
            try copyPath(alloc, io, source, target);
        }
    }
}

fn copyPath(alloc: std.mem.Allocator, io: std.Io, source: []const u8, target: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const stat = try cwd.statFile(io, source, .{ .follow_symlinks = false });
    switch (stat.kind) {
        .directory => {
            try cwd.createDirPath(io, target);
            var dir = try cwd.openDir(io, source, .{ .iterate = true });
            defer dir.close(io);
            var walker = try dir.walk(alloc);
            defer walker.deinit();
            while (try walker.next(io)) |entry| {
                const src = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ source, entry.path });
                const dst = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ target, entry.path });
                if (entry.kind == .directory) {
                    try cwd.createDirPath(io, dst);
                } else {
                    try copyFile(alloc, io, src, dst);
                }
            }
        },
        .file => try copyFile(alloc, io, source, target),
        else => return error.UnsupportedDotfileEntry,
    }
}

fn copyFile(alloc: std.mem.Allocator, io: std.Io, source: []const u8, target: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(target)) |parent| try cwd.createDirPath(io, parent);
    const contents = try cwd.readFileAlloc(io, source, alloc, .unlimited);
    const file = try std.Io.Dir.createFileAbsolute(io, target, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, contents);
}

// --- tests ---

// `ConfigDef.stow_package` names a directory inside this archive, but nothing
// links the two declarations. A typo would only surface at apply time, as a
// FileNotFound while scanning the package for conflicts.
test "every config's stow package is provided by the dotfiles archive" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const release = @import("release.zig");
    const names = try packages(alloc);

    for (release.tool_defs) |tool| {
        for (tool.configs) |config| {
            var provided = false;
            for (names) |name| {
                if (std.mem.eql(u8, name, config.stow_package)) provided = true;
            }
            if (!provided) {
                std.log.err("config {s} wants stow package {s}, which the dotfiles archive does not provide", .{
                    @tagName(config.id),
                    config.stow_package,
                });
                return error.MissingStowPackage;
            }
        }
    }
}

test packages {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const names = try packages(alloc);
    try std.testing.expectEqual(@as(usize, 4), names.len);
    try std.testing.expectEqualStrings("alacritty", names[0]);
    try std.testing.expectEqualStrings("nvim", names[1]);
    try std.testing.expectEqualStrings("shell", names[2]);
    try std.testing.expectEqualStrings("tmux", names[3]);
}

test extract {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dest = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    const extracted_dest = try std.fs.path.join(alloc, &.{ dest, "dotfiles" });

    const names = try extract(alloc, io, extracted_dest);
    try std.testing.expectEqual(@as(usize, 4), names.len);

    var dest_dir = try std.Io.Dir.cwd().openDir(io, extracted_dest, .{});
    defer dest_dir.close(io);
    const init_lua = try dest_dir.readFileAlloc(io, "nvim/.config/nvim/init.lua", alloc, .unlimited);
    try std.testing.expect(init_lua.len > 0);
    _ = try dest_dir.statFile(io, "tmux/.config/tmux/tmux.conf", .{});
    _ = try dest_dir.statFile(io, "shell/.bashrc", .{});
}
