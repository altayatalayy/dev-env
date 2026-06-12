//! All paths owned by dev-env, derived from $HOME.

const std = @import("std");

pub const Paths = struct {
    home: []const u8,
    /// ~/.local/share/dev-env
    data: []const u8,
    lock: []const u8,
    installed: []const u8,
    installers: []const u8,
    releases: []const u8,
    stow_source: []const u8,
    backups: []const u8,
    launcher: []const u8,
    /// ~/.local/bin
    bin: []const u8,
    /// ~/.local/opt
    opt: []const u8,

    pub fn init(alloc: std.mem.Allocator, home: []const u8) !Paths {
        if (!std.fs.path.isAbsolute(home)) return error.HomeNotAbsolute;
        const data = try std.fmt.allocPrint(alloc, "{s}/.local/share/dev-env", .{home});
        return .{
            .home = home,
            .data = data,
            .lock = try std.fmt.allocPrint(alloc, "{s}/lock.json", .{data}),
            .installed = try std.fmt.allocPrint(alloc, "{s}/installed.json", .{data}),
            .installers = try std.fmt.allocPrint(alloc, "{s}/installers", .{data}),
            .releases = try std.fmt.allocPrint(alloc, "{s}/releases", .{data}),
            .stow_source = try std.fmt.allocPrint(alloc, "{s}/stow-source", .{data}),
            .backups = try std.fmt.allocPrint(alloc, "{s}/backups", .{data}),
            .launcher = try std.fmt.allocPrint(alloc, "{s}/launcher", .{data}),
            .bin = try std.fmt.allocPrint(alloc, "{s}/.local/bin", .{home}),
            .opt = try std.fmt.allocPrint(alloc, "{s}/.local/opt", .{home}),
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
    try std.testing.expectEqualStrings("/home/u/.local/share/dev-env/lock.json", p.lock);
    try std.testing.expectEqualStrings("/home/u/.local/share/dev-env/installed.json", p.installed);
    try std.testing.expectEqualStrings("/home/u/.local/bin", p.bin);
    try std.testing.expectEqualStrings("/home/u/.local/opt", p.opt);

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
}
