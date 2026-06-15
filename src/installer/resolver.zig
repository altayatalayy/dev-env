//! Dependency resolution.
//!
//! Two graphs exist: config -> config/tool edges, and method-level
//! tool -> tool edges (a source build requiring its toolchain). apt/dnf/brew
//! packages are not graph nodes. Resolution is package-manager aware because
//! a tool's dependencies belong to the install method selected for the host
//! (alacritty needs rust only where it is built from source).
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
/// dependencies, and direct or indirect cycles in either graph. Method-level
/// tool dependencies are validated across every package-manager domain.
pub fn validate(alloc: std.mem.Allocator, defs: Defs) ValidateError!void {
    // Existence and ownership checks the dependency graphs cannot express:
    // every referenced id must be defined (across all methods, not just the
    // one a package manager selects) and a config must belong to its tool.
    for (defs.tools) |t| {
        for (t.methods) |m| {
            for (m.requires_tools) |dep| {
                if (dep == t.id) return error.SelfDependency;
                if (defs.tool(dep) == null) return error.UnknownDependency;
            }
        }
        for (t.configs) |c| {
            if (c.for_tool != t.id) return error.UnknownDependency;
            for (c.requires_tools) |dep| {
                if (defs.tool(dep) == null) return error.UnknownDependency;
            }
            for (c.requires_configs) |dep| {
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
            for (c.requires_configs) |dep| {
                try addDependencyEdge(
                    ConfigDag,
                    &config_graph,
                    @intFromEnum(dep),
                    @intFromEnum(c.id),
                );
            }
        }
    }

    for (std.enums.values(platform.PackageManager)) |pm| {
        var tool_graph = ToolDag.init(alloc);
        defer tool_graph.deinit();
        for (std.enums.values(tools.ToolId)) |id| {
            tool_graph.addNode(.{ .id = @intFromEnum(id) }) catch |err| switch (err) {
                error.DuplicateNodeId => unreachable, // enum values are unique
                error.OutOfMemory => return error.OutOfMemory,
            };
        }
        for (defs.tools) |t| {
            const method = t.method(pm) orelse continue;
            for (method.requires_tools) |dep| {
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
    pm: platform.PackageManager,
    selected: []const tools.ToolId,
    include_configs: bool,
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
            for (c.requires_tools) |t| tool_set.insert(t);
            for (c.requires_configs) |dep| try queue.append(alloc, dep);
        }
    }

    // Close over method-level tool dependencies for the host's package
    // manager. Every resolved tool must be installable there.
    var changed = true;
    while (changed) {
        changed = false;
        for (defs.tools) |t| {
            if (!tool_set.contains(t.id)) continue;
            const method = t.method(pm) orelse return error.UnsupportedPlatform;
            for (method.requires_tools) |dep| {
                if (!tool_set.contains(dep)) {
                    tool_set.insert(dep);
                    changed = true;
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

/// Orders tool names so every tool comes after its method-level dependencies
/// (a source build's toolchain installs before the build runs). Independent
/// tools keep their request order.
pub fn installOrder(
    alloc: std.mem.Allocator,
    defs: Defs,
    pm: platform.PackageManager,
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
        const method = defs.tool(id).?.method(pm) orelse return error.UnsupportedPlatform;
        for (method.requires_tools) |dep| {
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

// --- tests ---

const testing = std.testing;

fn testTool(comptime id: tools.ToolId) tools.ToolDef {
    return testToolWithConfigs(id, &.{});
}

fn testToolWithConfigs(comptime id: tools.ToolId, comptime configs: []const tools.ConfigDef) tools.ToolDef {
    return .{
        .id = id,
        .description = "",
        .configs = configs,
        .methods = &.{
            .{ .method = .{ .system = .{ .packages = &.{@tagName(id)}, .check_bin = @tagName(id) } } },
        },
    };
}

fn testSourceTool(comptime id: tools.ToolId, comptime requires: []const tools.ToolId) tools.ToolDef {
    return .{
        .id = id,
        .description = "",
        .methods = &.{
            .{
                .on = &.{ .apt, .dnf },
                .requires_tools = requires,
                .method = .{ .source = .{
                    .version = "1",
                    .url = "https://example.invalid/src.tar.gz",
                    .format = .tar_gz,
                    .strip_components = 1,
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
    const res = try resolve(alloc, defs, .apt, &.{ .tmux, .neovim }, true);

    try testing.expectEqualSlices(tools.ToolId, &.{ .neovim, .tmux }, res.tools);
    try testing.expectEqual(@as(usize, 0), res.configs.len);
}

test "configs pull dependency tools" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const neovim_configs = [_]tools.ConfigDef{
        .{ .id = .@"neovim-config", .for_tool = .neovim, .stow_package = "nvim", .requires_tools = &.{ .go, .zig } },
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

    const res = try resolve(alloc, defs, .apt, &.{.neovim}, true);
    try testing.expectEqualSlices(tools.ToolId, &.{ .zig, .go, .neovim }, res.tools);
    try testing.expectEqualSlices(tools.ConfigId, &.{.@"neovim-config"}, res.configs);

    const no_configs = try resolve(alloc, defs, .apt, &.{.neovim}, false);
    try testing.expectEqualSlices(tools.ToolId, &.{.neovim}, no_configs.tools);
    try testing.expectEqual(@as(usize, 0), no_configs.configs.len);
}

test "method dependencies resolve only where the method is selected" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const test_tools = [_]tools.ToolDef{
        testSourceTool(.alacritty, &.{.rust}),
        testTool(.rust),
    };
    const defs: Defs = .{ .tools = &test_tools };

    // Built from source on apt: rust is required.
    const on_apt = try resolve(alloc, defs, .apt, &.{.alacritty}, false);
    try testing.expectEqualSlices(tools.ToolId, &.{ .rust, .alacritty }, on_apt.tools);

    // brew installs the cask/formula: no toolchain needed.
    const on_brew = try resolve(alloc, defs, .brew, &.{.alacritty}, false);
    try testing.expectEqualSlices(tools.ToolId, &.{.alacritty}, on_brew.tools);
}

test "config dependency closure includes config and its tool" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const neovim_configs = [_]tools.ConfigDef{
        .{ .id = .@"neovim-config", .for_tool = .neovim, .stow_package = "nvim", .requires_configs = &.{.@"tmux-config"} },
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

    const res = try resolve(alloc, defs, .apt, &.{.neovim}, true);
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
        .methods = &.{
            .{ .on = &.{.apt}, .method = .{ .official = .{ .version = "x", .install_steps = &.{}, .verify_bins = &.{} } } },
        },
    }};
    const defs: Defs = .{ .tools = &apt_only };

    _ = try resolve(alloc, defs, .apt, &.{.docker}, false);
    try testing.expectError(error.UnsupportedPlatform, resolve(alloc, defs, .dnf, &.{.docker}, false));
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
    const ordered = try installOrder(alloc, defs, .apt, &.{ "alacritty", "neovim", "rust", "zig" });
    try testing.expectEqual(@as(usize, 4), ordered.len);
    try testing.expectEqualStrings("rust", ordered[0]);
    try testing.expectEqualStrings("zig", ordered[1]);
    try testing.expectEqualStrings("alacritty", ordered[2]);
    try testing.expectEqualStrings("neovim", ordered[3]);

    // Dependencies that are not part of the request are not invented.
    const partial = try installOrder(alloc, defs, .apt, &.{"alacritty"});
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
        .{ .id = .@"neovim-config", .for_tool = .neovim, .stow_package = "nvim", .requires_tools = &.{.go} },
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
        .{ .id = .@"tmux-config", .for_tool = .tmux, .stow_package = "tmux", .requires_configs = &.{.@"tmux-config"} },
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
        .{ .id = .@"neovim-config", .for_tool = .neovim, .stow_package = "nvim", .requires_configs = &.{.@"tmux-config"} },
    };
    const tmux_configs = [_]tools.ConfigDef{
        .{ .id = .@"tmux-config", .for_tool = .tmux, .stow_package = "tmux", .requires_configs = &.{.@"neovim-config"} },
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
        .{ .id = .@"neovim-config", .for_tool = .neovim, .stow_package = "nvim", .requires_configs = &.{.@"tmux-config"} },
    };
    const tmux_configs = [_]tools.ConfigDef{
        .{ .id = .@"tmux-config", .for_tool = .tmux, .stow_package = "tmux", .requires_configs = &.{.@"alacritty-config"} },
    };
    const alacritty_configs = [_]tools.ConfigDef{
        .{ .id = .@"alacritty-config", .for_tool = .alacritty, .stow_package = "alacritty", .requires_configs = &.{.@"neovim-config"} },
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
