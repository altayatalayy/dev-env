//! Dependency resolution.
//!
//! Two graphs exist: config -> config edges, and tool -> tool edges declared
//! by method build/runtime dependencies. apt/dnf/brew packages are not graph
//! nodes. Resolution is package-manager aware because a tool's dependencies
//! belong to the install method selected for the host.
//!
//! Cycle detection and install ordering are backed by the zig-graph library;
//! an edge `from -> to` means `from` must be installed/applied before `to`.

const std = @import("std");
const dag = @import("graph");
const shared = @import("shared");
const platform = shared.platform;
const tools = @import("tools.zig");

const ToolNode = struct { id: std.meta.Tag(tools.ToolId) };
const ConfigNode = struct { id: std.meta.Tag(tools.ConfigId) };
const ToolDag = dag.Dag(ToolNode, null);
const ConfigDag = dag.Dag(ConfigNode, null);

pub const Defs = struct {
    tools: []const tools.ToolDef,

    pub fn tool(d: Defs, id: tools.ToolId) ?*const tools.ToolDef {
        for (d.tools) |*t| {
            if (t.id == id) return t;
        }
        return null;
    }

    pub fn config(d: Defs, id: tools.ConfigId) ?*const tools.ConfigDef {
        for (d.tools) |*t| {
            for (t.configs) |*c| {
                if (c.id == id) return c;
            }
        }
        return null;
    }
};

pub const GraphError = error{
    UnknownDependency,
    SelfDependency,
    DependencyCycle,
};

pub const ValidateError = GraphError || error{OutOfMemory};

pub const Error = GraphError || error{ UnknownTool, UnsupportedPlatform, OutOfMemory };

pub fn toolByName(defs: Defs, name: []const u8) error{UnknownTool}!tools.ToolId {
    for (defs.tools) |t| {
        if (std.mem.eql(u8, @tagName(t.id), name)) return t.id;
    }
    return error.UnknownTool;
}

pub fn configByName(defs: Defs, name: []const u8) error{UnknownConfig}!tools.ConfigId {
    for (defs.tools) |t| {
        for (t.configs) |c| {
            if (std.mem.eql(u8, @tagName(c.id), name)) return c.id;
        }
    }
    return error.UnknownConfig;
}

/// Rejects graphs with dependencies on undefined tools/configs, self
/// dependencies, and direct or indirect cycles in either graph. Tool
/// dependencies are validated across every package-manager domain and phase.
pub fn validate(alloc: std.mem.Allocator, defs: Defs) ValidateError!void {
    // Existence and ownership checks the dependency graphs cannot express:
    // every referenced id must be defined (across all methods, not just the
    // one a package manager selects) and a config must belong to its tool.
    for (defs.tools) |t| {
        for (t.methods) |m| {
            for (installToolDependencies(m.method)) |dep| {
                if (dep == t.id) return error.SelfDependency;
                if (defs.tool(dep) == null) return error.UnknownDependency;
            }
            for (runtimeToolDependencies(m.method)) |dep| {
                if (dep == t.id) return error.SelfDependency;
                if (defs.tool(dep) == null) return error.UnknownDependency;
            }
        }
        for (t.configs) |c| {
            if (c.for_tool != t.id) return error.UnknownDependency;
            for (c.install_dependencies.tools) |dep| {
                if (defs.tool(dep) == null) return error.UnknownDependency;
            }
            for (c.runtime_dependencies.tools) |dep| {
                if (defs.tool(dep) == null) return error.UnknownDependency;
            }
            for (c.config_dependencies) |dep| {
                if (dep == c.id) return error.SelfDependency;
                if (defs.config(dep) == null) return error.UnknownDependency;
            }
        }
    }

    var config_graph = ConfigDag.init(alloc);
    defer config_graph.deinit();
    for (std.enums.values(tools.ConfigId)) |id| {
        config_graph.addNode(.{ .id = @intFromEnum(id) }) catch |err| switch (err) {
            error.DuplicateNodeId => unreachable, // enum values are unique
            error.OutOfMemory => return error.OutOfMemory,
        };
    }
    for (defs.tools) |t| {
        for (t.configs) |c| {
            for (c.config_dependencies) |dep| {
                try addDependencyEdge(
                    ConfigDag,
                    &config_graph,
                    @intFromEnum(dep),
                    @intFromEnum(c.id),
                );
            }
        }
    }

    for (std.enums.values(platform.PackageManager.Kind)) |manager| {
        var tool_graph = ToolDag.init(alloc);
        defer tool_graph.deinit();
        for (std.enums.values(tools.ToolId)) |id| {
            tool_graph.addNode(.{ .id = @intFromEnum(id) }) catch |err| switch (err) {
                error.DuplicateNodeId => unreachable, // enum values are unique
                error.OutOfMemory => return error.OutOfMemory,
            };
        }
        for (defs.tools) |t| {
            const method = t.methodForManager(manager) orelse continue;
            for (installToolDependencies(method.method)) |dep| {
                try addDependencyEdge(
                    ToolDag,
                    &tool_graph,
                    @intFromEnum(dep),
                    @intFromEnum(t.id),
                );
            }
            for (runtimeToolDependencies(method.method)) |dep| {
                try addDependencyEdge(
                    ToolDag,
                    &tool_graph,
                    @intFromEnum(dep),
                    @intFromEnum(t.id),
                );
            }
        }
    }
}

/// Adds `from -> to` (`from` before `to`), mapping zig-graph edge errors onto
/// resolver errors. A duplicate edge means the same dependency was stated
/// twice, which is harmless.
fn addDependencyEdge(
    comptime Graph: type,
    graph: *Graph,
    from: Graph.NodeId,
    to: Graph.NodeId,
) ValidateError!void {
    graph.addEdge(from, to) catch |err| switch (err) {
        error.DuplicateEdge => {},
        error.SelfEdge => return error.SelfDependency,
        error.MissingNode => return error.UnknownDependency,
        error.CycleDetected => return error.DependencyCycle,
        error.OutOfMemory => return error.OutOfMemory,
    };
}

pub const Resolution = struct {
    /// Selected tools plus every tool required by a resolved method or
    /// config, in enum declaration order.
    tools: []const tools.ToolId,
    /// Configs for selected tools plus the closure of config dependencies.
    configs: []const tools.ConfigId,
};

pub fn resolve(
    alloc: std.mem.Allocator,
    defs: Defs,
    host: platform.Platform,
    selected: []const tools.ToolId,
    include_configs: bool,
    include_runtime_dependencies: bool,
) Error!Resolution {
    try validate(alloc, defs);

    var tool_set: std.EnumSet(tools.ToolId) = .initEmpty();
    for (selected) |id| {
        if (defs.tool(id) == null) return error.UnknownTool;
        tool_set.insert(id);
    }

    var config_set: std.EnumSet(tools.ConfigId) = .initEmpty();
    if (include_configs) {
        var queue: std.ArrayList(tools.ConfigId) = .empty;
        defer queue.deinit(alloc);
        for (defs.tools) |t| {
            for (t.configs) |c| {
                if (tool_set.contains(c.for_tool)) try queue.append(alloc, c.id);
            }
        }
        while (queue.pop()) |id| {
            if (config_set.contains(id)) continue;
            config_set.insert(id);
            const c = defs.config(id).?;
            tool_set.insert(c.for_tool);
            for (c.install_dependencies.tools) |dep| tool_set.insert(dep);
            if (include_runtime_dependencies) {
                for (c.runtime_dependencies.tools) |dep| tool_set.insert(dep);
            }
            for (c.config_dependencies) |dep| try queue.append(alloc, dep);
        }
    }

    // Close over dependencies of the method selected for the host. Runtime
    // dependencies are omitted when producing source-build artifacts.
    var changed = true;
    while (changed) {
        changed = false;
        for (defs.tools) |t| {
            if (!tool_set.contains(t.id)) continue;
            const method = t.method(host) orelse return error.UnsupportedPlatform;
            for (installToolDependencies(method.method)) |dep| {
                if (!tool_set.contains(dep)) {
                    tool_set.insert(dep);
                    changed = true;
                }
            }
            if (include_runtime_dependencies) {
                for (runtimeToolDependencies(method.method)) |dep| {
                    if (!tool_set.contains(dep)) {
                        tool_set.insert(dep);
                        changed = true;
                    }
                }
            }
        }
    }

    var resolved_tools: std.ArrayList(tools.ToolId) = .empty;
    errdefer resolved_tools.deinit(alloc);
    var tool_it = tool_set.iterator();
    while (tool_it.next()) |id| try resolved_tools.append(alloc, id);

    var resolved_configs: std.ArrayList(tools.ConfigId) = .empty;
    errdefer resolved_configs.deinit(alloc);
    var config_it = config_set.iterator();
    while (config_it.next()) |id| try resolved_configs.append(alloc, id);

    return .{
        .tools = try resolved_tools.toOwnedSlice(alloc),
        .configs = try resolved_configs.toOwnedSlice(alloc),
    };
}

/// Orders tool names so every tool comes after its selected method's build,
/// install, and runtime tool dependencies. Independent tools keep request
/// order.
pub fn installOrder(
    alloc: std.mem.Allocator,
    defs: Defs,
    host: platform.Platform,
    names: []const []const u8,
) Error![]const []const u8 {
    var graph = ToolDag.init(alloc);
    defer graph.deinit();

    for (names) |name| {
        const id = try toolByName(defs, name);
        graph.addNode(.{ .id = @intFromEnum(id) }) catch |err| switch (err) {
            error.DuplicateNodeId => {}, // requesting a tool twice is harmless
            error.OutOfMemory => return error.OutOfMemory,
        };
    }

    // Edges only between requested tools: dependencies that are not part of
    // the request are not invented.
    for (names) |name| {
        const id = try toolByName(defs, name);
        const method = defs.tool(id).?.method(host) orelse return error.UnsupportedPlatform;
        for (installToolDependencies(method.method)) |dep| {
            const dep_id: ToolDag.NodeId = @intFromEnum(dep);
            if (graph.node(dep_id) == null) continue;
            try addDependencyEdge(ToolDag, &graph, dep_id, @intFromEnum(id));
        }
        for (runtimeToolDependencies(method.method)) |dep| {
            const dep_id: ToolDag.NodeId = @intFromEnum(dep);
            if (graph.node(dep_id) == null) continue;
            try addDependencyEdge(ToolDag, &graph, dep_id, @intFromEnum(id));
        }
    }

    const sorted = graph.topologicalSort() catch |err| switch (err) {
        error.CycleDetected => return error.DependencyCycle,
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer alloc.free(sorted);

    const ordered = try alloc.alloc([]const u8, sorted.len);
    for (sorted, ordered) |id, *out| {
        out.* = @tagName(@as(tools.ToolId, @enumFromInt(id)));
    }
    return ordered;
}

fn installToolDependencies(method: tools.Method) []const tools.ToolId {
    return switch (method) {
        .source => |source| source.build_dependencies.tools,
        .official => |official| official.install_dependencies.tools,
        .archive, .system => &.{},
    };
}

fn runtimeToolDependencies(method: tools.Method) []const tools.ToolId {
    return switch (method) {
        .source => |source| source.runtime_dependencies.tools,
        .archive, .system, .official => &.{},
    };
}

// --- tests ---

const testing = std.testing;
const test_platforms = [_]platform.Support{
    .{ .ubuntu = .{ .versions = &.{"24.04"}, .archs = &.{.x86_64} } },
    .{ .fedora = .{ .versions = &.{"44"}, .archs = &.{.x86_64} } },
    .{ .macos = .{ .archs = &.{.aarch64} } },
};
const ubuntu: platform.Platform = .{ .ubuntu = .{ .version = "24.04", .arch = .x86_64 } };
const fedora: platform.Platform = .{ .fedora = .{ .version = "44", .arch = .x86_64 } };
const macos: platform.Platform = .{ .macos = .{ .version = "15.5", .arch = .aarch64 } };

fn testTool(comptime id: tools.ToolId) tools.ToolDef {
    return testToolWithConfigs(id, &.{});
}

fn testToolWithConfigs(comptime id: tools.ToolId, comptime configs: []const tools.ConfigDef) tools.ToolDef {
    return .{
        .id = id,
        .description = "",
        .platforms = &test_platforms,
        .configs = configs,
        .methods = &.{
            .{ .method = .{ .system = .{ .packages = &.{@tagName(id)}, .check_bin = @tagName(id) } } },
        },
    };
}

fn testSourceTool(comptime id: tools.ToolId, comptime requires: []const tools.ToolId) tools.ToolDef {
    return testSourceToolWithDependencies(id, requires, &.{});
}

fn testSourceToolWithDependencies(
    comptime id: tools.ToolId,
    comptime build_dependencies: []const tools.ToolId,
    comptime runtime_dependencies: []const tools.ToolId,
) tools.ToolDef {
    return .{
        .id = id,
        .description = "",
        .platforms = &test_platforms,
        .methods = &.{
            .{
                .on = &.{ .apt, .dnf },
                .method = .{ .source = .{
                    .version = "1",
                    .url = "https://example.invalid/src.tar.gz",
                    .format = .tar_gz,
                    .strip_components = 1,
                    .build_dependencies = .{ .tools = build_dependencies },
                    .runtime_dependencies = .{ .tools = runtime_dependencies },
                    .build_steps = &.{},
                    .bin_links = &.{},
                } },
            },
            .{ .on = &.{.brew}, .method = .{ .system = .{ .packages = &.{@tagName(id)}, .check_bin = @tagName(id) } } },
        },
    };
}

const all_test_tools = [_]tools.ToolDef{
    testTool(.neovim),
    testTool(.tmux),
    testTool(.go),
    testTool(.zig),
    testTool(.rust),
    testTool(.alacritty),
};

test "selected tools resolve to themselves without configs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const defs: Defs = .{ .tools = &all_test_tools };
    const res = try resolve(alloc, defs, ubuntu, &.{ .tmux, .neovim }, true, true);

    try testing.expectEqualSlices(tools.ToolId, &.{ .neovim, .tmux }, res.tools);
    try testing.expectEqual(@as(usize, 0), res.configs.len);
}

test "configs pull dependency tools" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const neovim_configs = [_]tools.ConfigDef{
        .{
            .id = .@"neovim-config",
            .for_tool = .neovim,
            .stow_package = "nvim",
            .runtime_dependencies = .{ .tools = &.{ .go, .zig } },
        },
    };
    const tmux_configs = [_]tools.ConfigDef{
        .{ .id = .@"tmux-config", .for_tool = .tmux, .stow_package = "tmux" },
    };
    const test_tools = [_]tools.ToolDef{
        testToolWithConfigs(.neovim, &neovim_configs),
        testToolWithConfigs(.tmux, &tmux_configs),
        testTool(.go),
        testTool(.zig),
        testTool(.alacritty),
    };
    const defs: Defs = .{ .tools = &test_tools };

    const res = try resolve(alloc, defs, ubuntu, &.{.neovim}, true, true);
    try testing.expectEqualSlices(tools.ToolId, &.{ .zig, .go, .neovim }, res.tools);
    try testing.expectEqualSlices(tools.ConfigId, &.{.@"neovim-config"}, res.configs);

    const no_configs = try resolve(alloc, defs, ubuntu, &.{.neovim}, false, true);
    try testing.expectEqualSlices(tools.ToolId, &.{.neovim}, no_configs.tools);
    try testing.expectEqual(@as(usize, 0), no_configs.configs.len);

    const no_runtime = try resolve(alloc, defs, ubuntu, &.{.neovim}, true, false);
    try testing.expectEqualSlices(tools.ToolId, &.{.neovim}, no_runtime.tools);
    try testing.expectEqualSlices(tools.ConfigId, &.{.@"neovim-config"}, no_runtime.configs);
}

test "method dependencies resolve only where the method is selected" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const test_tools = [_]tools.ToolDef{
        testSourceToolWithDependencies(.alacritty, &.{.rust}, &.{.go}),
        testTool(.rust),
        testTool(.go),
    };
    const defs: Defs = .{ .tools = &test_tools };

    // Built from source on apt: rust is required.
    const on_apt = try resolve(alloc, defs, ubuntu, &.{.alacritty}, false, true);
    try testing.expectEqualSlices(tools.ToolId, &.{ .go, .rust, .alacritty }, on_apt.tools);

    const without_runtime = try resolve(alloc, defs, ubuntu, &.{.alacritty}, false, false);
    try testing.expectEqualSlices(tools.ToolId, &.{ .rust, .alacritty }, without_runtime.tools);

    // brew installs the cask/formula: no toolchain needed.
    const on_brew = try resolve(alloc, defs, macos, &.{.alacritty}, false, true);
    try testing.expectEqualSlices(tools.ToolId, &.{.alacritty}, on_brew.tools);
}

test "config dependency closure includes config and its tool" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const neovim_configs = [_]tools.ConfigDef{
        .{ .id = .@"neovim-config", .for_tool = .neovim, .stow_package = "nvim", .config_dependencies = &.{.@"tmux-config"} },
    };
    const tmux_configs = [_]tools.ConfigDef{
        .{ .id = .@"tmux-config", .for_tool = .tmux, .stow_package = "tmux" },
    };
    const test_tools = [_]tools.ToolDef{
        testToolWithConfigs(.neovim, &neovim_configs),
        testToolWithConfigs(.tmux, &tmux_configs),
        testTool(.go),
    };
    const defs: Defs = .{ .tools = &test_tools };

    const res = try resolve(alloc, defs, ubuntu, &.{.neovim}, true, true);
    try testing.expectEqualSlices(tools.ToolId, &.{ .neovim, .tmux }, res.tools);
    try testing.expectEqualSlices(
        tools.ConfigId,
        &.{ .@"neovim-config", .@"tmux-config" },
        res.configs,
    );
}

test "resolution fails when a tool has no method for the platform" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const apt_only = [_]tools.ToolDef{.{
        .id = .docker,
        .description = "",
        .platforms = &.{
            .{ .ubuntu = .{ .versions = &.{"24.04"}, .archs = &.{.x86_64} } },
        },
        .methods = &.{
            .{ .on = &.{.apt}, .method = .{ .official = .{ .version = "x", .install_steps = &.{}, .verify_bins = &.{} } } },
        },
    }};
    const defs: Defs = .{ .tools = &apt_only };

    _ = try resolve(alloc, defs, ubuntu, &.{.docker}, false, true);
    try testing.expectError(error.UnsupportedPlatform, resolve(alloc, defs, fedora, &.{.docker}, false, true));
}

test installOrder {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const test_tools = [_]tools.ToolDef{
        testSourceTool(.alacritty, &.{.rust}),
        testSourceTool(.neovim, &.{.zig}),
        testTool(.rust),
        testTool(.zig),
    };
    const defs: Defs = .{ .tools = &test_tools };

    // Alphabetical request order (what dev-env sends) must come out
    // dependency-first; tools with no unmet dependencies keep request order.
    const ordered = try installOrder(alloc, defs, ubuntu, &.{ "alacritty", "neovim", "rust", "zig" });
    try testing.expectEqual(@as(usize, 4), ordered.len);
    try testing.expectEqualStrings("rust", ordered[0]);
    try testing.expectEqualStrings("zig", ordered[1]);
    try testing.expectEqualStrings("alacritty", ordered[2]);
    try testing.expectEqualStrings("neovim", ordered[3]);

    // Dependencies that are not part of the request are not invented.
    const partial = try installOrder(alloc, defs, ubuntu, &.{"alacritty"});
    try testing.expectEqual(@as(usize, 1), partial.len);
    try testing.expectEqualStrings("alacritty", partial[0]);
}

test "unknown selected tool name" {
    const defs: Defs = .{ .tools = &all_test_tools };
    try testing.expectError(error.UnknownTool, toolByName(defs, "python"));
}

test "unknown dependency" {
    // go is referenced but not defined in the tool set.
    const configs = [_]tools.ConfigDef{
        .{
            .id = .@"neovim-config",
            .for_tool = .neovim,
            .stow_package = "nvim",
            .runtime_dependencies = .{ .tools = &.{.go} },
        },
    };
    const partial_tools = [_]tools.ToolDef{testToolWithConfigs(.neovim, &configs)};
    const defs: Defs = .{ .tools = &partial_tools };
    try testing.expectError(error.UnknownDependency, validate(testing.allocator, defs));
}

test "unknown method dependency" {
    const partial_tools = [_]tools.ToolDef{testSourceTool(.alacritty, &.{.rust})};
    const defs: Defs = .{ .tools = &partial_tools };
    try testing.expectError(error.UnknownDependency, validate(testing.allocator, defs));
}

test "self dependency" {
    const configs = [_]tools.ConfigDef{
        .{ .id = .@"tmux-config", .for_tool = .tmux, .stow_package = "tmux", .config_dependencies = &.{.@"tmux-config"} },
    };
    const test_tools = [_]tools.ToolDef{
        testToolWithConfigs(.tmux, &configs),
    };
    const defs: Defs = .{ .tools = &test_tools };
    try testing.expectError(error.SelfDependency, validate(testing.allocator, defs));

    const self_method = [_]tools.ToolDef{testSourceTool(.zig, &.{.zig})};
    try testing.expectError(error.SelfDependency, validate(testing.allocator, .{ .tools = &self_method }));
}

test "direct config cycle" {
    const neovim_configs = [_]tools.ConfigDef{
        .{ .id = .@"neovim-config", .for_tool = .neovim, .stow_package = "nvim", .config_dependencies = &.{.@"tmux-config"} },
    };
    const tmux_configs = [_]tools.ConfigDef{
        .{ .id = .@"tmux-config", .for_tool = .tmux, .stow_package = "tmux", .config_dependencies = &.{.@"neovim-config"} },
    };
    const test_tools = [_]tools.ToolDef{
        testToolWithConfigs(.neovim, &neovim_configs),
        testToolWithConfigs(.tmux, &tmux_configs),
    };
    const defs: Defs = .{ .tools = &test_tools };
    try testing.expectError(error.DependencyCycle, validate(testing.allocator, defs));
}

test "indirect config cycle" {
    const neovim_configs = [_]tools.ConfigDef{
        .{ .id = .@"neovim-config", .for_tool = .neovim, .stow_package = "nvim", .config_dependencies = &.{.@"tmux-config"} },
    };
    const tmux_configs = [_]tools.ConfigDef{
        .{ .id = .@"tmux-config", .for_tool = .tmux, .stow_package = "tmux", .config_dependencies = &.{.@"alacritty-config"} },
    };
    const alacritty_configs = [_]tools.ConfigDef{
        .{ .id = .@"alacritty-config", .for_tool = .alacritty, .stow_package = "alacritty", .config_dependencies = &.{.@"neovim-config"} },
    };
    const test_tools = [_]tools.ToolDef{
        testToolWithConfigs(.neovim, &neovim_configs),
        testToolWithConfigs(.tmux, &tmux_configs),
        testToolWithConfigs(.alacritty, &alacritty_configs),
    };
    const defs: Defs = .{ .tools = &test_tools };
    try testing.expectError(error.DependencyCycle, validate(testing.allocator, defs));
}

test "tool method cycle" {
    const test_tools = [_]tools.ToolDef{
        testSourceTool(.rust, &.{.go}),
        testSourceTool(.go, &.{.rust}),
    };
    const defs: Defs = .{ .tools = &test_tools };
    try testing.expectError(error.DependencyCycle, validate(testing.allocator, defs));
}
