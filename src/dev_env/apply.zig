//! Applies the difference between lock.json (desired) and installed.json
//! (actual): system packages, tool activation via the installer, dotfiles
//! refresh, conflict handling, and stowing. Old tool versions are only
//! deactivated here, never deleted (see clean.zig).

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
    if (diff.isEmpty() and old_receipt != null) return;

    const manager: system.Manager = .init(lock.platform.packageManager());
    try manager.ensureInstalled(alloc, io, plan.system_packages);

    var merged_tools: std.ArrayList(proto.InstalledTool) = .empty;
    if (old_receipt) |old| {
        for (old.tools) |tool| {
            if (ids.contains(diff.install_tools, tool.tool)) continue;
            if (ids.contains(diff.deactivate_tools, tool.tool)) continue;
            try merged_tools.append(alloc, tool);
        }
    }
    if (diff.install_tools.len > 0 or diff.deactivate_tools.len > 0) {
        const response = try client.applyTools(alloc, io, outcome.installer, .{
            .protocol = proto.version,
            .platform = lock.platform,
            .tools = lock.resolved_tools,
            .install = diff.install_tools,
            .deactivate = diff.deactivate_tools,
        });
        try merged_tools.appendSlice(alloc, response.tools);
    }

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
        .tools = merged_tools.items,
        .configs = try configsForPackages(alloc, plan, stowed),
        .stow_packages = stowed,
        .skipped_configs = skipped_configs,
        .owned_symlinks = try ownedSymlinks(alloc, merged_tools.items, stow_links),
        .owned_prefixes = try ownedPrefixes(alloc, merged_tools.items, old_receipt),
    });

    std.log.info("applied installer {s}", .{lock.installer_release});
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

    const links = try configs.syncStowSource(alloc, io, paths, lock.installer_release, to_stow.items);
    try stow.run(alloc, io, paths.stow_source, paths.home, .restow, to_stow.items);
    const stowed_configs = try configsForPackages(alloc, plan, to_stow.items);
    if (stowed_configs.len > 0) {
        _ = try client.applyConfigs(alloc, io, outcome.installer, .{
            .protocol = proto.version,
            .platform = lock.platform,
            .tools = plan.resolved_tools,
            .configs = stowed_configs,
        });
    }

    var skipped_configs: std.ArrayList([]const u8) = .empty;
    for (skipped.items) |package| {
        try skipped_configs.append(alloc, try configForPackage(plan, package));
    }

    return .{
        .stowed = to_stow.items,
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
    return links.items;
}

/// Opt prefixes (~/.local/opt/<tool>) ever created; kept across applies even
/// for deactivated tools so clean can find their leftover versions.
fn ownedPrefixes(
    alloc: std.mem.Allocator,
    tools: []const proto.InstalledTool,
    old_receipt: ?receipt_mod.Receipt,
) ![]const []const u8 {
    var prefixes: std.ArrayList([]const u8) = .empty;
    if (old_receipt) |old| {
        try prefixes.appendSlice(alloc, old.owned_prefixes);
    }
    for (tools) |tool| {
        const opt_dir = tool.opt_dir orelse continue;
        const prefix = std.fs.path.dirname(opt_dir) orelse continue;
        try prefixes.append(alloc, prefix);
    }
    return ids.sortedUnique(alloc, prefixes.items);
}
