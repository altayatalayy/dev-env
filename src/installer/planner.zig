//! Builds the installer's plan response: resolved tools/configs, merged and
//! deduplicated system packages, stow packages, and per-tool actions, all
//! for the install methods selected by the host's package manager.

const std = @import("std");
const shared = @import("shared");
const proto = shared.protocol;
const platform = shared.platform;
const ids = shared.ids;
const tools = @import("tools.zig");
const resolver = @import("resolver.zig");
const release = @import("release.zig");

pub const Error = resolver.Error || error{UnsupportedPlatform};

pub fn resolve(alloc: std.mem.Allocator, req: proto.ResolveRequest) Error!proto.ResolveResponse {
    return resolveWithDefs(alloc, release.defs, &release.supported_platforms, req);
}

pub fn resolveWithDefs(
    alloc: std.mem.Allocator,
    defs: resolver.Defs,
    supported: []const platform.Support,
    req: proto.ResolveRequest,
) Error!proto.ResolveResponse {
    if (!platform.isSupported(supported, req.platform)) return error.UnsupportedPlatform;
    const pm = req.platform.packageManager();

    var selected: std.ArrayList(tools.ToolId) = .empty;
    for (req.tools) |name| {
        const id = try resolver.toolByName(defs, name);
        if (std.mem.indexOfScalar(tools.ToolId, selected.items, id) == null) {
            try selected.append(alloc, id);
        }
    }

    const res = try resolver.resolve(alloc, defs, pm, selected.items, req.include_configs);

    var packages: PackageLists = .{};
    var actions: std.ArrayList(proto.ToolAction) = .empty;
    var resolved_names: std.ArrayList([]const u8) = .empty;

    for (res.tools) |id| {
        const def = defs.tool(id).?;
        const method = def.method(pm) orelse return error.UnsupportedPlatform;
        try resolved_names.append(alloc, @tagName(id));

        const action: proto.ToolAction = switch (method.method) {
            .archive => |a| .{
                .tool = @tagName(id),
                .kind = .archive,
                .version = a.version,
                .env_exports = try envExports(alloc, method.exports),
            },
            .system => |s| blk: {
                try packages.addSystem(alloc, pm, s);
                break :blk .{
                    .tool = @tagName(id),
                    .kind = .system,
                    .version = "system",
                    .env_exports = try envExports(alloc, method.exports),
                };
            },
            .source => |s| blk: {
                try packages.add(alloc, pm, s.build_dependencies.forManager(pm));
                break :blk .{
                    .tool = @tagName(id),
                    .kind = .source,
                    .version = s.version,
                    .build_dependencies = .{
                        .apt = s.build_dependencies.apt,
                        .dnf = s.build_dependencies.dnf,
                    },
                    .env_exports = try envExports(alloc, method.exports),
                };
            },
            .official => |o| blk: {
                try packages.add(alloc, pm, o.install_dependencies.forManager(pm));
                break :blk .{
                    .tool = @tagName(id),
                    .kind = .official,
                    .version = o.version,
                    .build_dependencies = .{
                        .apt = o.install_dependencies.apt,
                        .dnf = o.install_dependencies.dnf,
                    },
                    .env_exports = try envExports(alloc, method.exports),
                };
            },
        };
        try actions.append(alloc, action);
    }

    var resolved_configs: std.ArrayList([]const u8) = .empty;
    var stow_packages: std.ArrayList([]const u8) = .empty;
    for (res.configs) |id| {
        const def = defs.config(id).?;
        try resolved_configs.append(alloc, @tagName(id));
        try stow_packages.append(alloc, def.stow_package);
        try packages.add(alloc, pm, def.install_dependencies.forManager(pm));
    }

    // dev-env runs GNU Stow; make sure it is present whenever configs are.
    if (res.configs.len > 0) {
        try packages.add(alloc, pm, &.{"stow"});
    }

    var selected_names: std.ArrayList([]const u8) = .empty;
    for (selected.items) |id| try selected_names.append(alloc, @tagName(id));

    return .{
        .selected_tools = try ids.sortedUnique(alloc, selected_names.items),
        .resolved_tools = try ids.sortedUnique(alloc, resolved_names.items),
        .resolved_configs = resolved_configs.items,
        .system_packages = .{
            .apt = try ids.sortedUnique(alloc, packages.apt.items),
            .dnf = try ids.sortedUnique(alloc, packages.dnf.items),
            .brew = try ids.sortedUnique(alloc, packages.brew.items),
            .brew_cask = try ids.sortedUnique(alloc, packages.brew_cask.items),
        },
        .stow_packages = stow_packages.items,
        .tool_actions = actions.items,
    };
}

const PackageLists = struct {
    apt: std.ArrayList([]const u8) = .empty,
    dnf: std.ArrayList([]const u8) = .empty,
    brew: std.ArrayList([]const u8) = .empty,
    brew_cask: std.ArrayList([]const u8) = .empty,

    fn add(
        p: *PackageLists,
        alloc: std.mem.Allocator,
        pm: platform.PackageManager,
        names: []const []const u8,
    ) !void {
        switch (pm) {
            .apt => try p.apt.appendSlice(alloc, names),
            .dnf => try p.dnf.appendSlice(alloc, names),
            .brew => try p.brew.appendSlice(alloc, names),
        }
    }

    fn addSystem(
        p: *PackageLists,
        alloc: std.mem.Allocator,
        pm: platform.PackageManager,
        system: tools.System,
    ) !void {
        if (pm == .brew and system.cask) {
            try p.brew_cask.appendSlice(alloc, system.packages);
        } else {
            try p.add(alloc, pm, system.packages);
        }
    }
};

fn envExports(alloc: std.mem.Allocator, exports: []const tools.EnvExport) ![]const proto.EnvExport {
    var out: std.ArrayList(proto.EnvExport) = .empty;
    for (exports) |item| {
        try out.append(alloc, .{
            .name = item.name,
            .value = item.value,
            .mode = switch (item.mode) {
                .set => .set,
                .prepend_path => .prepend_path,
            },
        });
    }
    return out.items;
}

// --- tests ---

const testing = std.testing;

const ubuntu: platform.Platform = .{ .ubuntu = .{ .version = "24.04", .arch = .x86_64 } };
const fedora: platform.Platform = .{ .fedora = .{ .version = "44", .arch = .x86_64 } };
const macos: platform.Platform = .{ .macos = .{ .version = "15.5", .arch = .aarch64 } };

test "plan merges and dedupes apt packages and adds stow" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const tmux_configs = [_]tools.ConfigDef{
        .{ .id = .@"tmux-config", .for_tool = .tmux, .stow_package = "tmux" },
    };
    const test_tools = [_]tools.ToolDef{
        .{ .id = .tmux, .description = "", .configs = &tmux_configs, .methods = &.{
            .{ .method = .{ .system = .{ .packages = &.{ "tmux", "libevent" }, .check_bin = "tmux" } } },
        } },
        .{ .id = .alacritty, .description = "", .methods = &.{
            .{ .method = .{ .system = .{ .packages = &.{ "alacritty", "libevent" }, .check_bin = "alacritty" } } },
        } },
    };
    const defs: resolver.Defs = .{ .tools = &test_tools };

    const resp = try resolveWithDefs(alloc, defs, &release.supported_platforms, .{
        .protocol = proto.version,
        .platform = ubuntu,
        .tools = &.{ "alacritty", "tmux", "tmux" },
        .include_configs = true,
    });

    const expected_apt = [_][]const u8{ "alacritty", "libevent", "stow", "tmux" };
    try testing.expectEqual(expected_apt.len, resp.system_packages.apt.len);
    for (expected_apt, resp.system_packages.apt) |want, got| {
        try testing.expectEqualStrings(want, got);
    }
    try testing.expectEqual(@as(usize, 0), resp.system_packages.dnf.len);
    try testing.expectEqual(@as(usize, 0), resp.system_packages.brew.len);
    try testing.expectEqual(@as(usize, 2), resp.selected_tools.len);
    try testing.expectEqual(@as(usize, 1), resp.stow_packages.len);
    try testing.expectEqualStrings("tmux", resp.stow_packages[0]);
    try testing.expectEqualStrings("tmux-config", resp.resolved_configs[0]);
}

test "plan rejects unsupported platform" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const old_fedora: platform.Platform = .{ .fedora = .{ .version = "40", .arch = .x86_64 } };
    try testing.expectError(error.UnsupportedPlatform, resolve(alloc, .{
        .protocol = proto.version,
        .platform = old_fedora,
        .tools = &.{"tmux"},
        .include_configs = true,
    }));

    const old_ubuntu: platform.Platform = .{ .ubuntu = .{ .version = "22.04", .arch = .x86_64 } };
    try testing.expectError(error.UnsupportedPlatform, resolve(alloc, .{
        .protocol = proto.version,
        .platform = old_ubuntu,
        .tools = &.{"tmux"},
        .include_configs = true,
    }));
}

test "plan rejects unknown tool" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    try testing.expectError(error.UnknownTool, resolve(alloc, .{
        .protocol = proto.version,
        .platform = ubuntu,
        .tools = &.{"python"},
        .include_configs = true,
    }));
}

test "release plan resolves config and toolchain dependencies" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const resp = try resolve(alloc, .{
        .protocol = proto.version,
        .platform = ubuntu,
        .tools = &.{"neovim"},
        .include_configs = true,
    });

    // neovim-config -> go; Neovim's CMake source build uses system packages.
    const expected_tools = [_][]const u8{ "go", "neovim" };
    try testing.expectEqual(expected_tools.len, resp.resolved_tools.len);
    for (expected_tools, resp.resolved_tools) |want, got| {
        try testing.expectEqualStrings(want, got);
    }
    try testing.expectEqual(@as(usize, 1), resp.resolved_configs.len);
    try testing.expectEqualStrings("neovim-config", resp.resolved_configs[0]);
    try testing.expect(ids.contains(resp.system_packages.apt, "cmake"));
    try testing.expect(ids.contains(resp.system_packages.apt, "git"));

    var found_neovim = false;
    for (resp.tool_actions) |action| {
        if (std.mem.eql(u8, action.tool, "neovim")) {
            found_neovim = true;
            try testing.expectEqual(proto.ToolKind.source, action.kind);
        }
        if (std.mem.eql(u8, action.tool, "zig")) {
            try testing.expectEqual(proto.ToolKind.archive, action.kind);
        }
    }
    try testing.expect(found_neovim);
}

test "release plan selects dnf dependencies on fedora" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const resp = try resolve(alloc, .{
        .protocol = proto.version,
        .platform = fedora,
        .tools = &.{"tmux"},
        .include_configs = true,
    });

    try testing.expectEqual(@as(usize, 0), resp.system_packages.apt.len);
    try testing.expect(ids.contains(resp.system_packages.dnf, "libevent-devel"));
    try testing.expect(ids.contains(resp.system_packages.dnf, "git"));
    try testing.expect(ids.contains(resp.system_packages.dnf, "stow"));
    try testing.expectEqualStrings("tmux-config", resp.resolved_configs[0]);
    try testing.expectEqualStrings("tmux", resp.stow_packages[0]);
}

test "release plan on macos uses brew only, with no build dependencies" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const resp = try resolve(alloc, .{
        .protocol = proto.version,
        .platform = macos,
        .tools = &.{ "alacritty", "go", "neovim", "rust" },
        .include_configs = true,
    });

    // brew handles dependency resolution itself: every tool is a plain
    // formula/cask and rust is not pulled in for alacritty.
    try testing.expectEqual(@as(usize, 0), resp.system_packages.apt.len);
    try testing.expectEqual(@as(usize, 0), resp.system_packages.dnf.len);
    try testing.expect(ids.contains(resp.system_packages.brew, "go"));
    try testing.expect(ids.contains(resp.system_packages.brew, "neovim"));
    try testing.expect(ids.contains(resp.system_packages.brew, "rust"));
    try testing.expect(ids.contains(resp.system_packages.brew_cask, "alacritty"));
    try testing.expect(!ids.contains(resp.system_packages.brew, "cmake"));
    for (resp.tool_actions) |action| {
        try testing.expectEqual(proto.ToolKind.system, action.kind);
        try testing.expectEqual(@as(usize, 0), action.build_dependencies.apt.len);
        try testing.expectEqual(@as(usize, 0), action.env_exports.len);
    }

    // zig is not selected, so brew must not include it.
    try testing.expect(!ids.contains(resp.system_packages.brew, "zig"));
}

test "release plan exposes rust official installer on linux" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const resp = try resolve(alloc, .{
        .protocol = proto.version,
        .platform = ubuntu,
        .tools = &.{"rust"},
        .include_configs = true,
    });

    try testing.expectEqual(@as(usize, 1), resp.tool_actions.len);
    try testing.expectEqualStrings("rust", resp.tool_actions[0].tool);
    try testing.expectEqual(proto.ToolKind.official, resp.tool_actions[0].kind);
    try testing.expect(resp.tool_actions[0].env_exports.len >= 3);
    try testing.expect(ids.contains(resp.system_packages.apt, "curl"));
    try testing.expect(ids.contains(resp.system_packages.apt, "libssl-dev"));
}

test "release plan selects the docker method per platform" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const on_ubuntu = try resolve(alloc, .{
        .protocol = proto.version,
        .platform = ubuntu,
        .tools = &.{"docker"},
        .include_configs = true,
    });
    try testing.expectEqual(proto.ToolKind.official, on_ubuntu.tool_actions[0].kind);
    try testing.expect(ids.contains(on_ubuntu.system_packages.apt, "ca-certificates"));

    const on_fedora = try resolve(alloc, .{
        .protocol = proto.version,
        .platform = fedora,
        .tools = &.{"docker"},
        .include_configs = true,
    });
    try testing.expectEqual(proto.ToolKind.official, on_fedora.tool_actions[0].kind);
    try testing.expect(ids.contains(on_fedora.system_packages.dnf, "dnf-plugins-core"));

    const on_macos = try resolve(alloc, .{
        .protocol = proto.version,
        .platform = macos,
        .tools = &.{"docker"},
        .include_configs = true,
    });
    try testing.expectEqual(proto.ToolKind.system, on_macos.tool_actions[0].kind);
    try testing.expect(ids.contains(on_macos.system_packages.brew_cask, "docker"));
}

test "release plan pulls rust for alacritty only where it is built" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const on_ubuntu = try resolve(alloc, .{
        .protocol = proto.version,
        .platform = ubuntu,
        .tools = &.{"alacritty"},
        .include_configs = true,
    });
    try testing.expect(ids.contains(on_ubuntu.resolved_tools, "rust"));
    try testing.expect(ids.contains(on_ubuntu.system_packages.apt, "libfontconfig1-dev"));
    try testing.expect(ids.contains(on_ubuntu.system_packages.apt, "stow"));
    try testing.expectEqualStrings("alacritty-config", on_ubuntu.resolved_configs[0]);

    const on_macos = try resolve(alloc, .{
        .protocol = proto.version,
        .platform = macos,
        .tools = &.{"alacritty"},
        .include_configs = true,
    });
    try testing.expect(!ids.contains(on_macos.resolved_tools, "rust"));
}

test "release plan includes git source build" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const resp = try resolve(alloc, .{
        .protocol = proto.version,
        .platform = ubuntu,
        .tools = &.{"git"},
        .include_configs = true,
    });

    try testing.expectEqual(@as(usize, 1), resp.tool_actions.len);
    try testing.expectEqualStrings("git", resp.tool_actions[0].tool);
    try testing.expectEqual(proto.ToolKind.source, resp.tool_actions[0].kind);
    try testing.expectEqualStrings("2.54.0", resp.tool_actions[0].version);
    try testing.expect(ids.contains(resp.system_packages.apt, "libcurl4-gnutls-dev"));
    try testing.expect(ids.contains(resp.system_packages.apt, "dh-autoreconf"));
}
