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
    return resolveWithDefs(alloc, release.defs, req);
}

pub fn resolveWithDefs(
    alloc: std.mem.Allocator,
    defs: resolver.Defs,
    req: proto.ResolveRequest,
) Error!proto.ResolveResponse {
    var platform_supported = false;
    for (defs.tools) |tool| {
        if (tool.supports(req.platform)) {
            platform_supported = true;
            break;
        }
    }
    if (!platform_supported) return error.UnsupportedPlatform;

    const pm = req.platform.packageManager();

    var selected: std.ArrayList(tools.ToolId) = .empty;
    for (req.tools) |name| {
        try selected.append(alloc, try resolver.toolByName(defs, name));
    }

    const res = try resolver.resolve(
        alloc,
        defs,
        req.platform,
        selected.items,
        req.include_configs,
        req.include_runtime_dependencies,
    );

    var packages: PackageLists = .{};
    var actions: std.ArrayList(proto.ToolAction) = .empty;
    var resolved_names: std.ArrayList([]const u8) = .empty;

    for (res.tools) |id| {
        const def = defs.tool(id).?;
        const method = def.method(req.platform) orelse return error.UnsupportedPlatform;
        const exports = try envExports(alloc, def.exports);
        try resolved_names.append(alloc, @tagName(id));
        const dependencies = method.method.dependencies();
        try packages.addDependencies(alloc, pm, dependencies.install);
        if (req.include_runtime_dependencies) {
            try packages.addDependencies(alloc, pm, dependencies.runtime);
        }

        const action: proto.ToolAction = switch (method.method) {
            .archive => |a| .{
                .tool = @tagName(id),
                .kind = .archive,
                .version = a.version,
                .env_exports = exports,
            },
            .system => |s| blk: {
                try packages.addSystem(alloc, pm, s);
                break :blk .{
                    .tool = @tagName(id),
                    .kind = .system,
                    .version = "system",
                    .env_exports = exports,
                };
            },
            .source => |s| .{
                .tool = @tagName(id),
                .kind = .source,
                .version = s.version,
                .build_dependencies = .{
                    .apt = s.build_dependencies.packages.apt,
                    .dnf = s.build_dependencies.packages.dnf,
                },
                .env_exports = exports,
            },
            .official => |o| .{
                .tool = @tagName(id),
                .kind = .official,
                .version = o.version,
                .build_dependencies = .{
                    .apt = o.install_dependencies.packages.apt,
                    .dnf = o.install_dependencies.packages.dnf,
                },
                .env_exports = exports,
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
        try packages.addDependencies(alloc, pm, def.install_dependencies);
        if (req.include_runtime_dependencies) {
            try packages.addDependencies(alloc, pm, def.runtime_dependencies);
        }
        if (def.git_checkouts.len > 0) {
            try packages.add(alloc, pm, &.{"git"});
        }
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
        switch (pm.kind) {
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
        if (pm.kind == .brew and system.cask) {
            try p.brew_cask.appendSlice(alloc, system.packages);
        } else {
            try p.add(alloc, pm, system.packages);
        }
    }

    fn addDependencies(
        p: *PackageLists,
        alloc: std.mem.Allocator,
        pm: platform.PackageManager,
        dependencies: tools.Dependencies,
    ) !void {
        try p.add(alloc, pm, dependencies.packages.forManager(pm));
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
const test_platforms = [_]platform.Support{
    .{ .ubuntu = .{ .versions = &.{"24.04"}, .archs = &.{.x86_64} } },
    .{ .fedora = .{ .versions = &.{"44"}, .archs = &.{.x86_64} } },
    .{ .macos = .{ .archs = &.{ .x86_64, .aarch64 } } },
};

test "plan merges and dedupes apt packages and adds stow" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const tmux_configs = [_]tools.ConfigDef{
        .{
            .id = .@"tmux-config",
            .for_tool = .tmux,
            .stow_package = "tmux",
            .git_checkouts = &.{.{
                .url = "https://example.invalid/plugin",
                .destination = "{home}/plugin",
            }},
        },
    };
    const test_tools = [_]tools.ToolDef{
        .{ .id = .tmux, .description = "", .platforms = &test_platforms, .configs = &tmux_configs, .methods = &.{
            .{ .method = .{ .system = .{ .packages = &.{ "tmux", "libevent" }, .check_bin = "tmux" } } },
        } },
        .{ .id = .alacritty, .description = "", .platforms = &test_platforms, .methods = &.{
            .{ .method = .{ .system = .{ .packages = &.{ "alacritty", "libevent" }, .check_bin = "alacritty" } } },
        } },
    };
    const defs: resolver.Defs = .{ .tools = &test_tools };

    const resp = try resolveWithDefs(alloc, defs, .{
        .protocol = proto.version,
        .platform = ubuntu,
        .tools = &.{ "alacritty", "tmux", "tmux" },
        .include_configs = true,
    });

    const expected_apt = [_][]const u8{ "alacritty", "git", "libevent", "stow", "tmux" };
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

test "plan rejects a tool unsupported on an otherwise supported platform" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const defs: resolver.Defs = .{ .tools = &.{
        .{
            .id = .git,
            .description = "",
            .platforms = &.{
                .{ .ubuntu = .{ .versions = &.{"24.04"}, .archs = &.{.x86_64} } },
            },
            .methods = &.{
                .{ .on = &.{.apt}, .method = .{ .system = .{
                    .packages = &.{"git"},
                    .check_bin = "git",
                } } },
            },
        },
        .{
            .id = .tmux,
            .description = "",
            .platforms = &.{
                .{ .fedora = .{ .versions = &.{"44"}, .archs = &.{.x86_64} } },
            },
            .methods = &.{
                .{ .on = &.{.dnf}, .method = .{ .system = .{
                    .packages = &.{"tmux"},
                    .check_bin = "tmux",
                } } },
            },
        },
    } };

    try testing.expectError(error.UnsupportedPlatform, resolveWithDefs(alloc, defs, .{
        .protocol = proto.version,
        .platform = fedora,
        .tools = &.{"git"},
        .include_configs = false,
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

    // Neovim's source build and plugin config use managed Git on Linux;
    // its config also brings in Go.
    const expected_tools = [_][]const u8{ "git", "go", "neovim" };
    try testing.expectEqual(expected_tools.len, resp.resolved_tools.len);
    for (expected_tools, resp.resolved_tools) |want, got| {
        try testing.expectEqualStrings(want, got);
    }
    try testing.expectEqual(@as(usize, 2), resp.resolved_configs.len);
    try testing.expect(ids.contains(resp.resolved_configs, "neovim-config"));
    try testing.expect(ids.contains(resp.resolved_configs, "shell-config"));
    try testing.expect(ids.contains(resp.stow_packages, "shell"));
    try testing.expect(ids.contains(resp.system_packages.apt, "cmake"));
    try testing.expect(!ids.contains(resp.system_packages.apt, "git"));

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
    try testing.expect(ids.contains(resp.system_packages.brew, "git"));
    try testing.expect(ids.contains(resp.system_packages.brew, "go"));
    try testing.expect(ids.contains(resp.system_packages.brew, "neovim"));
    try testing.expect(ids.contains(resp.system_packages.brew, "rust"));
    try testing.expect(ids.contains(resp.system_packages.brew_cask, "alacritty"));
    try testing.expect(!ids.contains(resp.system_packages.brew, "cmake"));
    try testing.expect(ids.contains(resp.stow_packages, "shell"));
    for (resp.tool_actions) |action| {
        try testing.expectEqual(proto.ToolKind.system, action.kind);
        try testing.expectEqual(@as(usize, 0), action.build_dependencies.apt.len);
        if (std.mem.eql(u8, action.tool, "go")) {
            try testing.expectEqual(@as(usize, 2), action.env_exports.len);
            try testing.expectEqualStrings("GOPATH", action.env_exports[0].name);
        } else if (std.mem.eql(u8, action.tool, "rust")) {
            try testing.expectEqual(@as(usize, 3), action.env_exports.len);
            try testing.expectEqualStrings("RUSTUP_HOME", action.env_exports[0].name);
        } else {
            try testing.expectEqual(@as(usize, 0), action.env_exports.len);
        }
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
    try testing.expectEqual(@as(usize, 3), resp.tool_actions[0].env_exports.len);
    try testing.expect(ids.contains(resp.system_packages.apt, "curl"));
    try testing.expect(ids.contains(resp.system_packages.apt, "libssl-dev"));
}

test "release plan exposes go runtime exports on linux" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const resp = try resolve(alloc, .{
        .protocol = proto.version,
        .platform = ubuntu,
        .tools = &.{"go"},
        .include_configs = false,
    });

    try testing.expectEqual(@as(usize, 1), resp.tool_actions.len);
    try testing.expectEqualStrings("go", resp.tool_actions[0].tool);
    try testing.expectEqual(@as(usize, 2), resp.tool_actions[0].env_exports.len);
    try testing.expectEqualStrings("GOPATH", resp.tool_actions[0].env_exports[0].name);
}

test "release plan excludes runtime dependencies for source archive builds" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const resp = try resolve(alloc, .{
        .protocol = proto.version,
        .platform = ubuntu,
        .tools = &.{"alacritty"},
        .include_configs = false,
        .include_runtime_dependencies = false,
    });

    try testing.expect(ids.contains(resp.system_packages.apt, "libfontconfig1-dev"));
    try testing.expect(!ids.contains(resp.system_packages.apt, "libfontconfig1"));
    try testing.expect(!ids.contains(resp.system_packages.apt, "desktop-file-utils"));
    try testing.expect(ids.contains(resp.resolved_tools, "rust"));
}

test "release plan excludes config runtime tools when runtime dependencies are disabled" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const resp = try resolve(alloc, .{
        .protocol = proto.version,
        .platform = ubuntu,
        .tools = &.{"neovim"},
        .include_configs = true,
        .include_runtime_dependencies = false,
    });

    try testing.expect(ids.contains(resp.resolved_tools, "neovim"));
    try testing.expect(ids.contains(resp.resolved_tools, "git"));
    try testing.expect(!ids.contains(resp.resolved_tools, "go"));
    try testing.expect(ids.contains(resp.resolved_configs, "neovim-config"));
    try testing.expect(ids.contains(resp.resolved_configs, "shell-config"));
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
    const ubuntu_method = release.defs.tool(.docker).?.method(ubuntu).?;
    try testing.expectEqual(@as(usize, 1), ubuntu_method.method.official.repositories.len);
    try testing.expectEqual(@as(usize, 5), ubuntu_method.method.official.packages.len);

    const on_fedora = try resolve(alloc, .{
        .protocol = proto.version,
        .platform = fedora,
        .tools = &.{"docker"},
        .include_configs = true,
    });
    try testing.expectEqual(proto.ToolKind.official, on_fedora.tool_actions[0].kind);
    try testing.expect(ids.contains(on_fedora.system_packages.dnf, "dnf-plugins-core"));
    const fedora_method = release.defs.tool(.docker).?.method(fedora).?;
    try testing.expectEqual(@as(usize, 1), fedora_method.method.official.repositories.len);
    try testing.expectEqual(@as(usize, 5), fedora_method.method.official.packages.len);

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
    try testing.expectEqualStrings("2.56.0", resp.tool_actions[0].version);
    try testing.expect(ids.contains(resp.stow_packages, "shell"));
    try testing.expect(ids.contains(resp.system_packages.apt, "libcurl4-gnutls-dev"));
    try testing.expect(ids.contains(resp.system_packages.apt, "dh-autoreconf"));
}
