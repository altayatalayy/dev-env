//! installed.json: what is actually installed on this machine.

const std = @import("std");
const shared = @import("shared");
const proto = shared.protocol;
const platform = shared.platform;
const json = shared.json;

pub const schema_version: u32 = 1;

pub const Receipt = struct {
    schema: u32 = schema_version,
    installer_release: []const u8,
    installer_path: []const u8,
    platform: platform.Platform,
    install_layout: proto.InstallLayout,
    tools: []const proto.InstalledTool = &.{},
    configs: []const []const u8 = &.{},
    stow_packages: []const []const u8 = &.{},
    skipped_configs: []const []const u8 = &.{},
    owned_symlinks: []const []const u8 = &.{},
    /// Directory trees dev-env created and may delete (opt tool prefixes).
    owned_prefixes: []const []const u8 = &.{},

    pub fn toolNames(r: Receipt, alloc: std.mem.Allocator) ![]const []const u8 {
        const names = try alloc.alloc([]const u8, r.tools.len);
        for (r.tools, names) |tool, *name| name.* = tool.tool;
        return names;
    }
};

pub fn load(alloc: std.mem.Allocator, io: std.Io, path: []const u8) !?Receipt {
    const receipt = (try loadJsonFile(Receipt, alloc, io, path)) orelse return null;
    if (receipt.schema != schema_version) return error.UnsupportedSchema;
    return receipt;
}

pub fn save(alloc: std.mem.Allocator, io: std.Io, path: []const u8, receipt: Receipt) !void {
    try saveJsonFile(alloc, io, path, receipt);
}

/// Returns null when the file does not exist.
pub fn loadJsonFile(comptime T: type, alloc: std.mem.Allocator, io: std.Io, path: []const u8) !?T {
    const contents = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    return try json.parse(T, alloc, contents);
}

/// Writes via a temp file + rename so state files are never half-written.
pub fn saveJsonFile(alloc: std.mem.Allocator, io: std.Io, path: []const u8, value: anytype) !void {
    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(path)) |parent| {
        try cwd.createDirPath(io, parent);
    }
    const text = try json.stringify(alloc, value);
    const tmp_path = try std.fmt.allocPrint(alloc, "{s}.tmp", .{path});
    {
        const file = try std.Io.Dir.createFileAbsolute(io, tmp_path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, text);
        try file.writeStreamingAll(io, "\n");
    }
    try std.Io.Dir.renameAbsolute(tmp_path, path, io);
}

// --- tests ---

test "receipt round trip" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    const path = try std.fmt.allocPrint(alloc, "{s}/state/installed.json", .{root});

    try std.testing.expectEqual(@as(?Receipt, null), try load(alloc, io, path));

    const original: Receipt = .{
        .installer_release = "0.1.0",
        .installer_path = "/x/dev-env-install",
        .platform = .{ .ubuntu = .{ .version = "24.04", .arch = .x86_64 } },
        .install_layout = .{
            .bin = "/bin",
            .opt = "/opt",
            .cache_dir = "/cache",
        },
        .tools = &.{
            .{ .tool = "neovim", .kind = .archive, .version = "0.11.2", .opt_dir = "/opt/neovim/0.11.2", .bin_links = &.{"/bin/nvim"} },
            .{ .tool = "tmux", .kind = .system, .version = "system" },
        },
        .configs = &.{"neovim-config"},
        .stow_packages = &.{"neovim"},
        .skipped_configs = &.{"tmux-config"},
        .owned_symlinks = &.{"/bin/nvim"},
        .owned_prefixes = &.{"/opt/neovim"},
    };
    try save(alloc, io, path, original);

    const loaded = (try load(alloc, io, path)).?;
    try std.testing.expectEqualStrings("0.1.0", loaded.installer_release);
    try std.testing.expectEqualStrings("/x/dev-env-install", loaded.installer_path);
    try std.testing.expectEqualStrings("/opt", loaded.install_layout.opt);
    try std.testing.expect(loaded.platform.eql(original.platform));
    try std.testing.expectEqual(@as(usize, 2), loaded.tools.len);
    try std.testing.expectEqualStrings("neovim", loaded.tools[0].tool);
    try std.testing.expectEqual(proto.ToolKind.archive, loaded.tools[0].kind);
    try std.testing.expectEqualStrings("/opt/neovim/0.11.2", loaded.tools[0].opt_dir.?);
    try std.testing.expectEqualStrings("tmux-config", loaded.skipped_configs[0]);

    const names = try loaded.toolNames(alloc);
    try std.testing.expectEqualStrings("neovim", names[0]);
    try std.testing.expectEqualStrings("tmux", names[1]);
}

test "unsupported schema is rejected" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    const path = try std.fmt.allocPrint(alloc, "{s}/installed.json", .{root});

    var bad: Receipt = .{
        .installer_release = "0.1.0",
        .installer_path = "/x/dev-env-install",
        .platform = .{ .ubuntu = .{ .version = "24.04", .arch = .x86_64 } },
        .install_layout = .{
            .bin = "/bin",
            .opt = "/opt",
            .cache_dir = "/cache",
        },
    };
    bad.schema = schema_version + 1;
    try save(alloc, io, path, bad);
    try std.testing.expectError(error.UnsupportedSchema, load(alloc, io, path));
}
