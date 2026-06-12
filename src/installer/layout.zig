//! The installation layout used by this installer release. Every path a
//! tool install touches is derived here, so tests (and future releases) can
//! relocate installs by changing one place.

const std = @import("std");

pub const Layout = struct {
    home: []const u8,
    /// Directory the step PATH starts with; bin links land here.
    bin: []const u8,
    /// Versioned tool installs: <opt>/<tool>/<version>.
    opt: []const u8,
    /// Downloaded archives, reused across runs.
    cache_dir: []const u8,

    pub fn init(alloc: std.mem.Allocator, home: []const u8, cache_dir: []const u8) !Layout {
        if (!std.fs.path.isAbsolute(home)) return error.HomeNotAbsolute;
        return .{
            .home = home,
            .bin = try std.fmt.allocPrint(alloc, "{s}/.local/bin", .{home}),
            .opt = try std.fmt.allocPrint(alloc, "{s}/.local/opt", .{home}),
            .cache_dir = cache_dir,
        };
    }

    pub fn toolDir(l: Layout, alloc: std.mem.Allocator, tool: []const u8) ![]u8 {
        return std.fmt.allocPrint(alloc, "{s}/{s}", .{ l.opt, tool });
    }

    pub fn versionDir(
        l: Layout,
        alloc: std.mem.Allocator,
        tool: []const u8,
        version: []const u8,
    ) ![]u8 {
        return std.fmt.allocPrint(alloc, "{s}/{s}/{s}", .{ l.opt, tool, version });
    }

    pub fn binLink(l: Layout, alloc: std.mem.Allocator, name: []const u8) ![]u8 {
        return std.fmt.allocPrint(alloc, "{s}/{s}", .{ l.bin, name });
    }
};

// --- tests ---

test Layout {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const layout = try Layout.init(alloc, "/home/u", "/home/u/.cache/dev-env/downloads");
    try std.testing.expectEqualStrings("/home/u/.local/bin", layout.bin);
    try std.testing.expectEqualStrings("/home/u/.local/opt/go", try layout.toolDir(alloc, "go"));
    try std.testing.expectEqualStrings(
        "/home/u/.local/opt/go/1.24.4",
        try layout.versionDir(alloc, "go", "1.24.4"),
    );
    try std.testing.expectEqualStrings("/home/u/.local/bin/go", try layout.binLink(alloc, "go"));

    try std.testing.expectError(error.HomeNotAbsolute, Layout.init(alloc, "relative", "/c"));
}
