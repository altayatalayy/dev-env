//! Applies the difference between lock.json (desired) and installed.json
//! (actual): system packages, tool install/remove via the installer, dotfiles
//! refresh, conflict handling, and stowing.

const std = @import("std");
const shared = @import("shared");
const proto = shared.protocol;
const ids = shared.ids;
const paths_mod = @import("paths.zig");
const planner = @import("planner.zig");
const client = @import("installer_client.zig");
const receipt_mod = @import("receipt.zig");
const configs = @import("configs.zig");
const stow = @import("stow.zig");
const system = @import("system/manager.zig");

pub fn run(
    alloc: std.mem.Allocator,
    io: std.Io,
    paths: paths_mod.Paths,
    plan_options: planner.Options,
    policy: configs.ConflictPolicy,
) !void {
    const outcome = try planner.buildPlan(alloc, io, paths, plan_options);
    try applyOutcome(alloc, io, paths, outcome, policy);
}

pub fn applyOutcome(
    alloc: std.mem.Allocator,
    io: std.Io,
    paths: paths_mod.Paths,
    outcome: planner.Outcome,
    policy: configs.ConflictPolicy,
) !void {
    const lock = outcome.lock;
    const plan = outcome.plan;
    const old_receipt = try receipt_mod.load(alloc, io, paths.installed);

    const diff = try planner.computeDiff(alloc, lock, plan, old_receipt);
    planner.printDiff(diff);
    if (diff.isEmpty()) {
        if (old_receipt) |old| {
            if (!receiptNeedsExportRefresh(old, plan)) return;
            try receipt_mod.save(alloc, io, paths.installed, try receiptWithCurrentExports(alloc, old, plan));
            std.log.info("refreshed installed exports", .{});
            return;
        }
    }

    const manager: system.Manager = .init(lock.platform.packageManager());
    const package_result = try manager.ensureInstalled(alloc, io, plan.system_packages);
    if (package_result.changed()) {
        std.log.info("system packages changed: {d} installed", .{package_result.installed.len});
    }

    var merged_tools: std.ArrayList(proto.InstalledTool) = .empty;
    if (old_receipt) |old| {
        for (old.tools) |tool| {
            if (ids.contains(diff.install_tools, tool.tool)) continue;
            if (ids.contains(diff.remove_tools, tool.tool)) continue;
            try merged_tools.append(alloc, tool);
        }
    }
    try uninstallRemovedTools(alloc, io, old_receipt, diff.remove_tools);

    if (diff.install_tools.len > 0) {
        const response = try client.applyTools(alloc, io, outcome.installer, .{
            .protocol = proto.version,
            .platform = lock.platform,
            .layout = lock.install_layout,
            .tools = lock.resolved_tools,
            .install = diff.install_tools,
        });
        try merged_tools.appendSlice(alloc, response.tools);
    }
    const installed_tools = try toolsWithCurrentExports(alloc, merged_tools.items, plan);

    var stowed: []const []const u8 = &.{};
    var skipped_configs: []const []const u8 = &.{};
    var stow_links: []const []const u8 = &.{};
    if (lock.include_configs and
        (plan.stow_packages.len > 0 or diff.remove_stow_packages.len > 0))
    {
        const config_state = try applyConfigs(alloc, io, paths, outcome, diff, policy);
        stowed = config_state.stowed;
        skipped_configs = config_state.skipped_configs;
        stow_links = config_state.stow_links;
    }

    try receipt_mod.save(alloc, io, paths.installed, .{
        .installer_release = lock.installer_release,
        .installer_path = outcome.installer.bin_path,
        .platform = lock.platform,
        .install_layout = lock.install_layout,
        .tools = installed_tools,
        .configs = try configsForPackages(alloc, plan, stowed),
        .stow_packages = stowed,
        .skipped_configs = skipped_configs,
        .owned_symlinks = try ownedSymlinks(alloc, installed_tools, stow_links),
        .owned_prefixes = try ownedPrefixes(alloc, installed_tools, old_receipt, diff.remove_tools),
    });

    std.log.info("applied installer {s}", .{lock.installer_release});
}

fn uninstallRemovedTools(
    alloc: std.mem.Allocator,
    io: std.Io,
    receipt: ?receipt_mod.Receipt,
    tools: []const []const u8,
) !void {
    if (tools.len == 0) return;
    const old = receipt orelse return error.MissingReceipt;

    const installer_bin = old.installer_path;
    std.Io.Dir.accessAbsolute(io, installer_bin, .{}) catch {
        std.log.err("recorded installer missing: {s}", .{installer_bin});
        return error.InstallerNotFound;
    };

    const response = try client.uninstall(alloc, io, installer_bin, .{
        .protocol = proto.version,
        .platform = old.platform,
        .layout = old.install_layout,
        .tools = tools,
    });
    for (response.removed) |name| std.log.info("removed {s}", .{name});
    for (response.kept_system) |name| {
        std.log.info("kept system package for {s} (remove via apt/brew if wanted)", .{name});
    }
}

fn receiptWithCurrentExports(
    alloc: std.mem.Allocator,
    receipt: receipt_mod.Receipt,
    plan: proto.ResolveResponse,
) !receipt_mod.Receipt {
    var updated = receipt;
    updated.tools = try toolsWithCurrentExports(alloc, receipt.tools, plan);
    return updated;
}

fn toolsWithCurrentExports(
    alloc: std.mem.Allocator,
    tools: []const proto.InstalledTool,
    plan: proto.ResolveResponse,
) ![]const proto.InstalledTool {
    var updated: std.ArrayList(proto.InstalledTool) = .empty;
    for (tools) |tool| {
        var next = tool;
        if (toolAction(plan, tool.tool)) |action| next.env_exports = action.env_exports;
        try updated.append(alloc, next);
    }
    return updated.items;
}

fn receiptNeedsExportRefresh(receipt: receipt_mod.Receipt, plan: proto.ResolveResponse) bool {
    for (receipt.tools) |tool| {
        const action = toolAction(plan, tool.tool) orelse continue;
        if (!envExportsEqual(tool.env_exports, action.env_exports)) return true;
    }
    return false;
}

fn toolAction(plan: proto.ResolveResponse, name: []const u8) ?proto.ToolAction {
    for (plan.tool_actions) |action| {
        if (std.mem.eql(u8, action.tool, name)) return action;
    }
    return null;
}

fn envExportsEqual(a: []const proto.EnvExport, b: []const proto.EnvExport) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (!std.mem.eql(u8, left.name, right.name)) return false;
        if (!std.mem.eql(u8, left.value, right.value)) return false;
        if (left.mode != right.mode) return false;
    }
    return true;
}

const ConfigState = struct {
    stowed: []const []const u8,
    skipped_configs: []const []const u8,
    stow_links: []const []const u8,
};

fn applyConfigs(
    alloc: std.mem.Allocator,
    io: std.Io,
    paths: paths_mod.Paths,
    outcome: planner.Outcome,
    diff: planner.Diff,
    policy: configs.ConflictPolicy,
) !ConfigState {
    const lock = outcome.lock;
    const plan = outcome.plan;
    const cwd = std.Io.Dir.cwd();

    const now: u64 = @intCast(std.Io.Timestamp.now(io, .real).toSeconds());
    const timestamp = try configs.formatTimestamp(alloc, now);

    // Fresh extract first: conflicts are detected against the new release's
    // file lists before anything user-visible changes.
    const fresh = try std.fmt.allocPrint(alloc, "{s}/{s}/dotfiles.new", .{ paths.releases, lock.installer_release });
    cwd.deleteTree(io, fresh) catch {};
    _ = try client.extractDotfiles(alloc, io, outcome.installer, .{
        .protocol = proto.version,
        .dest = fresh,
    });

    const managed_roots = [_][]const u8{ paths.stow_source, paths.releases };

    var to_stow: std.ArrayList([]const u8) = .empty;
    var skipped: std.ArrayList([]const u8) = .empty;
    var failed = false;
    for (plan.stow_packages) |package| {
        const conflicts = try configs.scanPackageConflicts(
            alloc,
            io,
            fresh,
            package,
            paths.home,
            &managed_roots,
        );
        if (conflicts.len == 0) {
            try to_stow.append(alloc, package);
            continue;
        }
        switch (policy) {
            .fail => {
                for (conflicts) |conflict| {
                    std.log.err(
                        "config conflict: {s} ({t})",
                        .{ conflict.target, conflict.state },
                    );
                }
                failed = true;
            },
            .backup => {
                for (conflicts) |conflict| {
                    const rel = try std.fmt.allocPrint(
                        alloc,
                        "home/{s}",
                        .{conflict.target[paths.home.len + 1 ..]},
                    );
                    const backup = try configs.moveToBackup(alloc, io, paths.backups, timestamp, rel, conflict.target);
                    std.log.info("backed up {s} to {s}", .{ conflict.target, backup });
                }
                try to_stow.append(alloc, package);
            },
            .skip => {
                std.log.info("skipping config package {s}: target conflicts", .{package});
                try skipped.append(alloc, package);
            },
        }
    }
    if (failed) {
        std.log.err("stopping before changing configs; use --config-conflict=backup|skip", .{});
        return error.ConfigConflict;
    }

    // Unstow packages that are no longer wanted while their stow-source
    // links and dotfiles trees still exist.
    var removable: std.ArrayList([]const u8) = .empty;
    for (diff.remove_stow_packages) |package| {
        const link = try paths.stowPackageLink(alloc, package);
        std.Io.Dir.accessAbsolute(io, link, .{}) catch continue;
        try removable.append(alloc, package);
    }
    try stow.run(alloc, io, paths.stow_source, paths.home, .delete, removable.items);

    // Refresh the release's dotfiles tree; locally modified managed configs
    // go through the same conflict policy. Consumes `fresh`.
    const refresh = try configs.refreshDotfiles(
        alloc,
        io,
        paths,
        lock.installer_release,
        fresh,
        plan.stow_packages,
        policy,
        timestamp,
    );
    if (refresh.skipped_packages.len > 0) {
        var filtered: std.ArrayList([]const u8) = .empty;
        for (to_stow.items) |package| {
            if (!ids.contains(refresh.skipped_packages, package)) try filtered.append(alloc, package);
        }
        to_stow.items = filtered.items;
        for (refresh.skipped_packages) |package| try skipped.append(alloc, package);
    }

    // Packages that must stay linked from stow-source, which is a superset of
    // the ones being restowed: a skipped package that is already stowed keeps
    // its entry, or the links the skip policy promised to preserve would be
    // left dangling in $HOME.
    var keep_linked: std.ArrayList([]const u8) = .empty;
    try keep_linked.appendSlice(alloc, to_stow.items);
    for (skipped.items) |package| {
        const link = try paths.stowPackageLink(alloc, package);
        std.Io.Dir.accessAbsolute(io, link, .{}) catch continue;
        try keep_linked.append(alloc, package);
    }

    const links = try configs.syncStowSource(alloc, io, paths, lock.installer_release, keep_linked.items);
    try stow.run(alloc, io, paths.stow_source, paths.home, .restow, to_stow.items);
    const stowed_configs = try configsForPackages(alloc, plan, to_stow.items);
    if (stowed_configs.len > 0) {
        _ = try client.applyConfigs(alloc, io, outcome.installer, .{
            .protocol = proto.version,
            .platform = lock.platform,
            .layout = lock.install_layout,
            .tools = plan.resolved_tools,
            .configs = stowed_configs,
        });
    }

    var skipped_configs: std.ArrayList([]const u8) = .empty;
    for (skipped.items) |package| {
        try skipped_configs.append(alloc, try configForPackage(plan, package));
    }

    // A skipped-but-still-stowed package is reported as stowed so the receipt
    // matches reality: uninstall must unstow it, and the next plan must not
    // keep re-adding it and skipping it forever.
    return .{
        .stowed = keep_linked.items,
        .skipped_configs = skipped_configs.items,
        .stow_links = links,
    };
}

fn configForPackage(plan: proto.ResolveResponse, package: []const u8) ![]const u8 {
    for (plan.stow_packages, plan.resolved_configs) |pkg, config| {
        if (std.mem.eql(u8, pkg, package)) return config;
    }
    return error.UnknownConfigPackage;
}

fn configsForPackages(
    alloc: std.mem.Allocator,
    plan: proto.ResolveResponse,
    packages: []const []const u8,
) ![]const []const u8 {
    var result: std.ArrayList([]const u8) = .empty;
    for (packages) |package| {
        try result.append(alloc, try configForPackage(plan, package));
    }
    return result.items;
}

fn ownedSymlinks(
    alloc: std.mem.Allocator,
    tools: []const proto.InstalledTool,
    stow_links: []const []const u8,
) ![]const []const u8 {
    var links: std.ArrayList([]const u8) = .empty;
    for (tools) |tool| {
        try links.appendSlice(alloc, tool.bin_links);
    }
    try links.appendSlice(alloc, stow_links);
    return ids.sortedUnique(alloc, links.items);
}

/// Opt prefixes (<opt>/<tool>) ever created. Prefixes for removed tools are
/// dropped after the installer uninstalls them; active tools keep old prefixes
/// so clean can remove inactive versions left by upgrades.
fn ownedPrefixes(
    alloc: std.mem.Allocator,
    tools: []const proto.InstalledTool,
    old_receipt: ?receipt_mod.Receipt,
    remove_tools: []const []const u8,
) ![]const []const u8 {
    var prefixes: std.ArrayList([]const u8) = .empty;
    if (old_receipt) |old| {
        var removed_prefixes: std.ArrayList([]const u8) = .empty;
        for (old.tools) |tool| {
            if (!ids.contains(remove_tools, tool.tool)) continue;
            const opt_dir = tool.opt_dir orelse continue;
            const prefix = std.fs.path.dirname(opt_dir) orelse continue;
            try removed_prefixes.append(alloc, prefix);
        }
        for (old.owned_prefixes) |prefix| {
            if (!ids.contains(removed_prefixes.items, prefix)) try prefixes.append(alloc, prefix);
        }
    }
    for (tools) |tool| {
        const opt_dir = tool.opt_dir orelse continue;
        const prefix = std.fs.path.dirname(opt_dir) orelse continue;
        try prefixes.append(alloc, prefix);
    }
    return ids.sortedUnique(alloc, prefixes.items);
}

// --- tests ---

test "ownedSymlinks returns unique sorted links" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const tools = [_]proto.InstalledTool{
        .{ .tool = "tmux", .kind = .archive, .version = "1", .bin_links = &.{ "/b/tmux", "/b/shared" } },
        .{ .tool = "zig", .kind = .archive, .version = "1", .bin_links = &.{"/b/zig"} },
    };
    const links = try ownedSymlinks(alloc, &tools, &.{ "/b/shared", "/b/stow" });

    const expected = [_][]const u8{ "/b/shared", "/b/stow", "/b/tmux", "/b/zig" };
    try std.testing.expectEqual(expected.len, links.len);
    for (expected, links) |want, got| {
        try std.testing.expectEqualStrings(want, got);
    }
}

test "ownedPrefixes keeps old prefixes and adds active tool prefixes uniquely" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const old_receipt: receipt_mod.Receipt = .{
        .installer_release = "0.1.0",
        .installer_path = "/x/dev-env-install",
        .platform = .{ .ubuntu = .{ .version = "24.04", .arch = .x86_64 } },
        .install_layout = .{ .bin = "/b", .opt = "/opt", .cache_dir = "/cache" },
        .owned_prefixes = &.{ "/opt/tmux", "/opt/old" },
    };
    const tools = [_]proto.InstalledTool{
        .{ .tool = "tmux", .kind = .archive, .version = "0.2.0", .opt_dir = "/opt/tmux/0.2.0" },
        .{ .tool = "zig", .kind = .archive, .version = "0.16.0", .opt_dir = "/opt/zig/0.16.0" },
    };
    const prefixes = try ownedPrefixes(alloc, &tools, old_receipt, &.{});

    const expected = [_][]const u8{ "/opt/old", "/opt/tmux", "/opt/zig" };
    try std.testing.expectEqual(expected.len, prefixes.len);
    for (expected, prefixes) |want, got| {
        try std.testing.expectEqualStrings(want, got);
    }
}

test "ownedPrefixes drops prefixes for removed tools" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const old_receipt: receipt_mod.Receipt = .{
        .installer_release = "0.1.0",
        .installer_path = "/x/dev-env-install",
        .platform = .{ .ubuntu = .{ .version = "24.04", .arch = .x86_64 } },
        .install_layout = .{ .bin = "/b", .opt = "/opt", .cache_dir = "/cache" },
        .tools = &.{
            .{ .tool = "tmux", .kind = .archive, .version = "0.1.0", .opt_dir = "/opt/tmux/0.1.0" },
            .{ .tool = "neovim", .kind = .archive, .version = "0.1.0", .opt_dir = "/opt/neovim/0.1.0" },
        },
        .owned_prefixes = &.{ "/opt/neovim", "/opt/old", "/opt/tmux" },
    };
    const tools = [_]proto.InstalledTool{
        .{ .tool = "neovim", .kind = .archive, .version = "0.1.0", .opt_dir = "/opt/neovim/0.1.0" },
    };
    const prefixes = try ownedPrefixes(alloc, &tools, old_receipt, &.{"tmux"});

    const expected = [_][]const u8{ "/opt/neovim", "/opt/old" };
    try std.testing.expectEqual(expected.len, prefixes.len);
    for (expected, prefixes) |want, got| {
        try std.testing.expectEqualStrings(want, got);
    }
}

test "toolsWithCurrentExports refreshes receipt tools from plan actions" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const tools = [_]proto.InstalledTool{
        .{ .tool = "go", .kind = .archive, .version = "1.24.4" },
        .{ .tool = "tmux", .kind = .archive, .version = "3.5a" },
    };
    const plan: proto.ResolveResponse = .{
        .selected_tools = &.{ "go", "tmux" },
        .resolved_tools = &.{ "go", "tmux" },
        .resolved_configs = &.{},
        .system_packages = .{},
        .stow_packages = &.{},
        .tool_actions = &.{
            .{
                .tool = "go",
                .kind = .archive,
                .version = "1.24.4",
                .env_exports = &.{.{ .name = "GOROOT", .value = "{opt}/go/1.24.4" }},
            },
        },
    };

    const updated = try toolsWithCurrentExports(alloc, &tools, plan);
    try std.testing.expectEqual(@as(usize, 1), updated[0].env_exports.len);
    try std.testing.expectEqualStrings("GOROOT", updated[0].env_exports[0].name);
    try std.testing.expectEqual(@as(usize, 0), updated[1].env_exports.len);
}

test "receiptNeedsExportRefresh detects missing or stale exports" {
    const plan: proto.ResolveResponse = .{
        .selected_tools = &.{"go"},
        .resolved_tools = &.{"go"},
        .resolved_configs = &.{},
        .system_packages = .{},
        .stow_packages = &.{},
        .tool_actions = &.{
            .{
                .tool = "go",
                .kind = .archive,
                .version = "1.24.4",
                .env_exports = &.{.{ .name = "GOROOT", .value = "{opt}/go/1.24.4" }},
            },
        },
    };
    const missing: receipt_mod.Receipt = .{
        .installer_release = "0.1.0",
        .installer_path = "/x/dev-env-install",
        .platform = .{ .ubuntu = .{ .version = "24.04", .arch = .x86_64 } },
        .install_layout = .{ .bin = "/b", .opt = "/opt", .cache_dir = "/cache" },
        .tools = &.{.{ .tool = "go", .kind = .archive, .version = "1.24.4" }},
    };
    try std.testing.expect(receiptNeedsExportRefresh(missing, plan));

    var current = missing;
    current.tools = &.{.{
        .tool = "go",
        .kind = .archive,
        .version = "1.24.4",
        .env_exports = &.{.{ .name = "GOROOT", .value = "{opt}/go/1.24.4" }},
    }};
    try std.testing.expect(!receiptNeedsExportRefresh(current, plan));
}
