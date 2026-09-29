//! The installation layout used by this installer release. Every path a
//! tool install touches is derived here, so tests (and future releases) can
//! relocate installs by changing one place.

const std = @import("std");
const templates = @import("shared").templates;

pub const Layout = struct {
    home: []const u8,
    /// Directory the step PATH starts with; bin links land here.
    bin: []const u8,
    /// Versioned tool installs: <opt>/<tool>/<version>.
    opt: []const u8,
    /// Downloaded archives, reused across runs.
    cache_dir: []const u8,

    pub fn init(
        home: []const u8,
        install: @import("shared").protocol.InstallLayout,
    ) !Layout {
        if (!std.fs.path.isAbsolute(home)) return error.HomeNotAbsolute;
        if (!std.fs.path.isAbsolute(install.bin)) return error.BinNotAbsolute;
        if (!std.fs.path.isAbsolute(install.opt)) return error.OptNotAbsolute;
        if (!std.fs.path.isAbsolute(install.cache_dir)) return error.CacheNotAbsolute;
        return .{
            .home = home,
            .bin = install.bin,
            .opt = install.opt,
            .cache_dir = install.cache_dir,
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

    pub fn vars(l: Layout) templates.Vars {
        return .{
            .home = l.home,
            .cache_dir = l.cache_dir,
            .bin = l.bin,
            .opt = l.opt,
        };
    }
};

// --- tests ---

test Layout {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const layout = try Layout.init("/home/u", .{
        .bin = "/xdg/bin",
        .opt = "/xdg/share/dev-env/tools",
        .cache_dir = "/xdg/cache/dev-env/downloads",
    });
    try std.testing.expectEqualStrings("/xdg/bin", layout.bin);
    try std.testing.expectEqualStrings("/xdg/share/dev-env/tools/go", try layout.toolDir(alloc, "go"));
    try std.testing.expectEqualStrings(
        "/xdg/share/dev-env/tools/go/1.24.4",
        try layout.versionDir(alloc, "go", "1.24.4"),
    );
    try std.testing.expectEqualStrings("/xdg/bin/go", try layout.binLink(alloc, "go"));

    try std.testing.expectError(error.HomeNotAbsolute, Layout.init("relative", .{
        .bin = "/b",
        .opt = "/o",
        .cache_dir = "/c",
    }));
    try std.testing.expectError(error.OptNotAbsolute, Layout.init("/home/u", .{
        .bin = "/b",
        .opt = "o",
        .cache_dir = "/c",
    }));
}
