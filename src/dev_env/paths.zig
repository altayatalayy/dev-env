//! All paths owned by dev-env, derived from XDG roots and $HOME.

const std = @import("std");
const proto = @import("shared").protocol;

pub const Paths = struct {
    home: []const u8,
    /// $XDG_DATA_HOME/dev-env.
    data: []const u8,
    /// $XDG_CACHE_HOME/dev-env.
    cache: []const u8,
    lock: []const u8,
    installed: []const u8,
    installers: []const u8,
    releases: []const u8,
    stow_source: []const u8,
    backups: []const u8,
    /// Versioned dev-env launcher binaries, written by install.sh as
    /// <launchers>/<version>/dev-env. The `dev-env` symlink in `bin` points
    /// into here.
    launchers: []const u8,
    /// Executable links. Defaults to ~/.local/bin because XDG has no bin dir.
    bin: []const u8,
    /// Versioned tool installs. Defaults to $XDG_DATA_HOME/dev-env/tools.
    opt: []const u8,

    pub fn init(alloc: std.mem.Allocator, home: []const u8) !Paths {
        const data_root = try std.fmt.allocPrint(alloc, "{s}/.local/share", .{home});
        const cache_root = try std.fmt.allocPrint(alloc, "{s}/.cache", .{home});
        return initWithXdg(alloc, home, data_root, cache_root);
    }

    pub fn initWithXdg(
        alloc: std.mem.Allocator,
        home: []const u8,
        data_root: []const u8,
        cache_root: []const u8,
    ) !Paths {
        if (!std.fs.path.isAbsolute(home)) return error.HomeNotAbsolute;
        if (!std.fs.path.isAbsolute(data_root)) return error.DataRootNotAbsolute;
        if (!std.fs.path.isAbsolute(cache_root)) return error.CacheRootNotAbsolute;
        const data = try std.fmt.allocPrint(alloc, "{s}/dev-env", .{data_root});
        const cache = try std.fmt.allocPrint(alloc, "{s}/dev-env", .{cache_root});
        return .{
            .home = home,
            .data = data,
            .cache = cache,
            .lock = try std.fmt.allocPrint(alloc, "{s}/lock.json", .{data}),
            .installed = try std.fmt.allocPrint(alloc, "{s}/installed.json", .{data}),
            .installers = try std.fmt.allocPrint(alloc, "{s}/installers", .{data}),
            .releases = try std.fmt.allocPrint(alloc, "{s}/releases", .{data}),
            .stow_source = try std.fmt.allocPrint(alloc, "{s}/stow-source", .{data}),
            .backups = try std.fmt.allocPrint(alloc, "{s}/backups", .{data}),
            .launchers = try std.fmt.allocPrint(alloc, "{s}/bin", .{data}),
            .bin = try std.fmt.allocPrint(alloc, "{s}/.local/bin", .{home}),
            .opt = try std.fmt.allocPrint(alloc, "{s}/tools", .{data}),
        };
    }

    pub fn installLayout(p: Paths) proto.InstallLayout {
        return .{
            .bin = p.bin,
            .opt = p.opt,
            .cache_dir = p.cache,
        };
    }

    pub fn installerBin(p: Paths, alloc: std.mem.Allocator, release: []const u8) ![]u8 {
        return std.fmt.allocPrint(alloc, "{s}/{s}/dev-env-install", .{ p.installers, release });
    }

    pub fn releaseDotfiles(p: Paths, alloc: std.mem.Allocator, release: []const u8) ![]u8 {
        return std.fmt.allocPrint(alloc, "{s}/{s}/dotfiles", .{ p.releases, release });
    }

    pub fn stowPackageLink(p: Paths, alloc: std.mem.Allocator, package: []const u8) ![]u8 {
        return std.fmt.allocPrint(alloc, "{s}/{s}", .{ p.stow_source, package });
    }
};

test Paths {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const p = try Paths.init(alloc, "/home/u");
    try std.testing.expectEqualStrings("/home/u/.local/share/dev-env", p.data);
    try std.testing.expectEqualStrings("/home/u/.cache/dev-env", p.cache);
    try std.testing.expectEqualStrings("/home/u/.local/share/dev-env/lock.json", p.lock);
    try std.testing.expectEqualStrings("/home/u/.local/share/dev-env/installed.json", p.installed);
    try std.testing.expectEqualStrings("/home/u/.local/bin", p.bin);
    try std.testing.expectEqualStrings("/home/u/.local/share/dev-env/tools", p.opt);
    // install.sh writes the launcher to <data>/bin/<version>/dev-env; uninstall
    // must remove that tree, not a directory nothing ever creates.
    try std.testing.expectEqualStrings("/home/u/.local/share/dev-env/bin", p.launchers);

    try std.testing.expectEqualStrings(
        "/home/u/.local/share/dev-env/installers/0.2.0/dev-env-install",
        try p.installerBin(alloc, "0.2.0"),
    );
    try std.testing.expectEqualStrings(
        "/home/u/.local/share/dev-env/releases/0.2.0/dotfiles",
        try p.releaseDotfiles(alloc, "0.2.0"),
    );
    try std.testing.expectEqualStrings(
        "/home/u/.local/share/dev-env/stow-source/neovim",
        try p.stowPackageLink(alloc, "neovim"),
    );

    try std.testing.expectError(error.HomeNotAbsolute, Paths.init(alloc, "relative"));

    const xdg = try Paths.initWithXdg(alloc, "/home/u", "/tmp/data", "/tmp/cache");
    try std.testing.expectEqualStrings("/tmp/data/dev-env", xdg.data);
    try std.testing.expectEqualStrings("/tmp/cache/dev-env", xdg.cache);
    try std.testing.expectEqualStrings("/tmp/data/dev-env/tools", xdg.opt);
}
