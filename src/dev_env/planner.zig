//! lock.json management, installer/tool selection, and the diff between
//! desired state (lock + installer plan) and actual state (installed.json).

const std = @import("std");
const shared = @import("shared");
const proto = shared.protocol;
const platform = shared.platform;
const ids = shared.ids;
const paths_mod = @import("paths.zig");
const host_detect = @import("host_detect.zig");
const client = @import("installer_client.zig");
const receipt_mod = @import("receipt.zig");

pub const schema_version: u32 = 1;

/// Desired state. Tool versions are intentionally absent: they are owned by
/// the selected installer release.
pub const Lock = struct {
    schema: u32 = schema_version,
    installer_release: []const u8,
    installer_path: []const u8,
    platform: platform.Platform,
    selected_tools: []const []const u8,
    resolved_tools: []const []const u8,
    resolved_configs: []const []const u8,
    include_configs: bool = true,
    install_layout: proto.InstallLayout,
};

pub fn loadLock(alloc: std.mem.Allocator, io: std.Io, paths: paths_mod.Paths) !?Lock {
    const lock = (try receipt_mod.loadJsonFile(Lock, alloc, io, paths.lock)) orelse return null;
    if (lock.schema != schema_version) return error.UnsupportedSchema;
    return lock;
}

pub const InstallerChoice = union(enum) {
    /// Keep the locked installer; pick the newest compatible one only when
    /// no lock exists (plan/apply default).
    keep_locked,
    /// Always pick the newest compatible installer (upgrade).
    newest,
    /// Pick this exact release (plan --installer).
    release: []const u8,
    /// Use this exact local executable.
    local_path: []const u8,
};

pub const Options = struct {
    installer: InstallerChoice = .keep_locked,
    /// Replaces the selection; null keeps the locked selection (or all tools
    /// when there is no lock).
    tools: ?[]const []const u8 = null,
    add: []const []const u8 = &.{},
    remove: []const []const u8 = &.{},
    bin_dir: ?[]const u8 = null,
    opt_dir: ?[]const u8 = null,
    cache_dir: ?[]const u8 = null,
};

pub const Outcome = struct {
    lock: Lock,
    installer: client.Installer,
    plan: proto.ResolveResponse,
};

/// Builds the desired state, asks the installer to resolve it, and writes
/// lock.json.
pub fn buildPlan(
    alloc: std.mem.Allocator,
    io: std.Io,
    paths: paths_mod.Paths,
    options: Options,
) !Outcome {
    const host = try host_detect.detect(alloc, io);
    const existing = try loadLock(alloc, io, paths);
    const installers = try client.discover(alloc, io, paths);

    const inst = switch (options.installer) {
        .release => |release| client.find(installers, release) orelse {
            std.log.err("installer release {s} not found under {s}", .{ release, paths.installers });
            return error.InstallerNotFound;
        },
        .local_path => |path| try client.local(alloc, io, path),
        .newest => try requireNewest(installers, host, paths),
        .keep_locked => if (existing) |lock|
            if (std.fs.path.isAbsolute(lock.installer_path))
                try client.local(alloc, io, lock.installer_path)
            else
                client.find(installers, lock.installer_release) orelse {
                    std.log.err("locked installer release {s} not found under {s}", .{ lock.installer_release, paths.installers });
                    return error.InstallerNotFound;
                }
        else
            try requireNewest(installers, host, paths),
    };
    try inst.ensureCompatible(host);

    const available = try alloc.alloc([]const u8, inst.meta.tools.len);
    for (inst.meta.tools, available) |tool, *name| name.* = tool.name;

    const selected = try selectTools(alloc, available, existing, options);
    const install_layout = selectedLayout(paths, existing, options);

    const resolve_response = try client.resolve(alloc, io, inst, .{
        .protocol = proto.version,
        .platform = host,
        .tools = selected,
        .include_configs = if (existing) |lock| lock.include_configs else true,
    });

    const lock: Lock = .{
        .installer_release = inst.release,
        .installer_path = inst.bin_path,
        .platform = host,
        .selected_tools = resolve_response.selected_tools,
        .resolved_tools = resolve_response.resolved_tools,
        .resolved_configs = resolve_response.resolved_configs,
        .include_configs = if (existing) |lock| lock.include_configs else true,
        .install_layout = install_layout,
    };
    try receipt_mod.saveJsonFile(alloc, io, paths.lock, lock);

    return .{ .lock = lock, .installer = inst, .plan = resolve_response };
}

fn selectedLayout(
    paths: paths_mod.Paths,
    existing: ?Lock,
    options: Options,
) proto.InstallLayout {
    const base = if (existing) |lock| lock.install_layout else paths.installLayout();
    return .{
        .bin = options.bin_dir orelse base.bin,
        .opt = options.opt_dir orelse base.opt,
        .cache_dir = options.cache_dir orelse base.cache_dir,
    };
}

fn requireNewest(
    installers: []const client.Installer,
    host: platform.Platform,
    paths: paths_mod.Paths,
) !client.Installer {
    return (try client.newestCompatible(installers, host)) orelse {
        std.log.err(
            "no compatible installer for {f} under {s}",
            .{ host, paths.installers },
        );
        return error.NoCompatibleInstaller;
    };
}

/// Selection base: --tools, else the locked selection, else every tool the
/// installer exposes. --add/--remove then adjust the base. Explicitly named
/// tools must exist; tools carried over from an old lock that the selected
/// installer no longer exposes are dropped with a warning ("preserve where
/// possible" for upgrade).
pub fn selectTools(
    alloc: std.mem.Allocator,
    available: []const []const u8,
    existing: ?Lock,
    options: Options,
) ![]const []const u8 {
    var selection: std.ArrayList([]const u8) = .empty;

    if (options.tools) |explicit| {
        for (explicit) |name| {
            if (!ids.contains(available, name)) return errorUnknownTool(name);
            try selection.append(alloc, name);
        }
    } else if (existing) |lock| {
        for (lock.selected_tools) |name| {
            if (!ids.contains(available, name)) {
                std.log.warn("dropping {s}: not provided by this installer", .{name});
                continue;
            }
            try selection.append(alloc, name);
        }
    } else {
        try selection.appendSlice(alloc, available);
    }

    for (options.add) |name| {
        if (!ids.contains(available, name)) return errorUnknownTool(name);
        try selection.append(alloc, name);
    }

    for (options.remove) |name| {
        const index = for (selection.items, 0..) |item, i| {
            if (std.mem.eql(u8, item, name)) break i;
        } else {
            std.log.warn("cannot remove {s}: not selected", .{name});
            return error.ToolNotSelected;
        };
        _ = selection.orderedRemove(index);
    }

    return ids.sortedUnique(alloc, selection.items);
}

fn errorUnknownTool(name: []const u8) error{UnknownTool} {
    std.log.warn("unknown tool: {s}", .{name});
    return error.UnknownTool;
}

pub const Diff = struct {
    install_tools: []const []const u8,
    deactivate_tools: []const []const u8,
    add_configs: []const []const u8,
    remove_configs: []const []const u8,
    remove_stow_packages: []const []const u8,
    release_change: ?ReleaseChange,

    pub const ReleaseChange = struct {
        from: []const u8,
        to: []const u8,
    };

    pub fn isEmpty(d: Diff) bool {
        return d.install_tools.len == 0 and d.deactivate_tools.len == 0 and
            d.add_configs.len == 0 and d.remove_configs.len == 0 and
            d.remove_stow_packages.len == 0 and d.release_change == null;
    }
};

/// What apply has to do to move the machine from `receipt` to `lock`.
/// When the installer release changes, every resolved tool is re-applied so
/// the new release's versions become active.
pub fn computeDiff(
    alloc: std.mem.Allocator,
    lock: Lock,
    resolve_response: proto.ResolveResponse,
    receipt: ?receipt_mod.Receipt,
) !Diff {
    if (receipt == null) {
        return .{
            .install_tools = lock.resolved_tools,
            .deactivate_tools = &.{},
            .add_configs = lock.resolved_configs,
            .remove_configs = &.{},
            .remove_stow_packages = &.{},
            .release_change = null,
        };
    }
    const actual = receipt.?;
    const actual_tools = try actual.toolNames(alloc);
    const release_changed = !std.mem.eql(u8, actual.installer_release, lock.installer_release);

    return .{
        .install_tools = if (release_changed)
            lock.resolved_tools
        else
            try ids.missingFrom(alloc, lock.resolved_tools, actual_tools),
        .deactivate_tools = try ids.missingFrom(alloc, actual_tools, lock.resolved_tools),
        .add_configs = try ids.missingFrom(alloc, lock.resolved_configs, actual.configs),
        .remove_configs = try ids.missingFrom(alloc, actual.configs, lock.resolved_configs),
        .remove_stow_packages = try ids.missingFrom(alloc, actual.stow_packages, resolve_response.stow_packages),
        .release_change = if (release_changed)
            .{ .from = actual.installer_release, .to = lock.installer_release }
        else
            null,
    };
}

pub fn printDiff(diff: Diff) void {
    if (diff.isEmpty()) {
        std.log.info("nothing to change", .{});
        return;
    }
    if (diff.release_change) |change| {
        std.log.info("installer: {s} -> {s}", .{ change.from, change.to });
    }
    for (diff.install_tools) |name| std.log.info("+ tool   {s}", .{name});
    for (diff.deactivate_tools) |name| std.log.info("- tool   {s}", .{name});
    for (diff.add_configs) |name| std.log.info("+ config {s}", .{name});
    for (diff.remove_configs) |name| std.log.info("- config {s}", .{name});
}

// --- tests ---

const testing = std.testing;

const test_platform: platform.Platform = .{ .ubuntu = .{ .version = "24.04", .arch = .x86_64 } };

fn testLock(release: []const u8) Lock {
    return .{
        .installer_release = release,
        .installer_path = "/x/dev-env-install",
        .platform = test_platform,
        .selected_tools = &.{ "neovim", "tmux" },
        .resolved_tools = &.{ "go", "neovim", "tmux", "zig" },
        .resolved_configs = &.{ "neovim-config", "tmux-config" },
        .install_layout = .{
            .bin = "/x/bin",
            .opt = "/x/opt",
            .cache_dir = "/x/cache",
        },
    };
}

const test_resolve_response: proto.ResolveResponse = .{
    .selected_tools = &.{ "neovim", "tmux" },
    .resolved_tools = &.{ "go", "neovim", "tmux", "zig" },
    .resolved_configs = &.{ "neovim-config", "tmux-config" },
    .system_packages = .{},
    .stow_packages = &.{ "neovim", "tmux" },
    .tool_actions = &.{},
};

test "lock round trip" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    // Paths.init derives lock.json from a fake home inside the tmp dir.
    const paths = try paths_mod.Paths.init(alloc, root);

    try testing.expectEqual(@as(?Lock, null), try loadLock(alloc, io, paths));

    const original = testLock("0.1.0");
    try receipt_mod.saveJsonFile(alloc, io, paths.lock, original);

    const loaded = (try loadLock(alloc, io, paths)).?;
    try testing.expectEqualStrings("0.1.0", loaded.installer_release);
    try testing.expect(loaded.platform.eql(test_platform));
    try testing.expectEqual(@as(usize, 2), loaded.selected_tools.len);
    try testing.expectEqual(@as(usize, 4), loaded.resolved_tools.len);
    try testing.expect(loaded.include_configs);
    try testing.expectEqualStrings("/x/opt", loaded.install_layout.opt);
}

test "selectedLayout keeps locked values unless overridden" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const paths = try paths_mod.Paths.initWithXdg(alloc, "/home/u", "/xdg/data", "/xdg/cache");
    const initial = selectedLayout(paths, null, .{});
    try testing.expectEqualStrings("/xdg/data/dev-env/tools", initial.opt);
    try testing.expectEqualStrings("/xdg/cache/dev-env", initial.cache_dir);

    const overridden = selectedLayout(paths, testLock("0.1.0"), .{
        .opt_dir = "/new/opt",
    });
    try testing.expectEqualStrings("/x/bin", overridden.bin);
    try testing.expectEqualStrings("/new/opt", overridden.opt);
    try testing.expectEqualStrings("/x/cache", overridden.cache_dir);
}

test "diff with no receipt installs everything" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const diff = try computeDiff(alloc, testLock("0.1.0"), test_resolve_response, null);
    try testing.expectEqual(@as(usize, 4), diff.install_tools.len);
    try testing.expectEqual(@as(usize, 2), diff.add_configs.len);
    try testing.expectEqual(@as(usize, 0), diff.deactivate_tools.len);
    try testing.expect(diff.release_change == null);
    try testing.expect(!diff.isEmpty());
}

test "diff installs and deactivates only the difference" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const receipt: receipt_mod.Receipt = .{
        .installer_release = "0.1.0",
        .installer_path = "/x/dev-env-install",
        .platform = test_platform,
        .install_layout = testLock("0.1.0").install_layout,
        .tools = &.{
            .{ .tool = "neovim", .kind = .archive, .version = "0.11.2" },
            .{ .tool = "tmux", .kind = .system, .version = "system" },
            .{ .tool = "alacritty", .kind = .system, .version = "system" },
        },
        .configs = &.{ "neovim-config", "alacritty-config" },
        .stow_packages = &.{ "neovim", "alacritty" },
    };

    const diff = try computeDiff(alloc, testLock("0.1.0"), test_resolve_response, receipt);

    const expected_install = [_][]const u8{ "go", "zig" };
    try testing.expectEqual(expected_install.len, diff.install_tools.len);
    for (expected_install, diff.install_tools) |want, got| {
        try testing.expectEqualStrings(want, got);
    }
    try testing.expectEqual(@as(usize, 1), diff.deactivate_tools.len);
    try testing.expectEqualStrings("alacritty", diff.deactivate_tools[0]);
    try testing.expectEqual(@as(usize, 1), diff.add_configs.len);
    try testing.expectEqualStrings("tmux-config", diff.add_configs[0]);
    try testing.expectEqual(@as(usize, 1), diff.remove_configs.len);
    try testing.expectEqualStrings("alacritty-config", diff.remove_configs[0]);
    try testing.expectEqual(@as(usize, 1), diff.remove_stow_packages.len);
    try testing.expectEqualStrings("alacritty", diff.remove_stow_packages[0]);
    try testing.expect(diff.release_change == null);
}

test "diff reinstalls all tools on release change" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const receipt: receipt_mod.Receipt = .{
        .installer_release = "0.1.0",
        .installer_path = "/x/dev-env-install",
        .platform = test_platform,
        .install_layout = testLock("0.1.0").install_layout,
        .tools = &.{
            .{ .tool = "neovim", .kind = .archive, .version = "0.10.0" },
        },
        .configs = &.{"neovim-config"},
        .stow_packages = &.{"neovim"},
    };

    const diff = try computeDiff(alloc, testLock("0.2.0"), test_resolve_response, receipt);
    try testing.expectEqual(@as(usize, 4), diff.install_tools.len);
    try testing.expectEqual(@as(usize, 0), diff.deactivate_tools.len);
    try testing.expectEqualStrings("0.1.0", diff.release_change.?.from);
    try testing.expectEqualStrings("0.2.0", diff.release_change.?.to);
}

test "diff is empty when states match" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const receipt: receipt_mod.Receipt = .{
        .installer_release = "0.1.0",
        .installer_path = "/x/dev-env-install",
        .platform = test_platform,
        .install_layout = testLock("0.1.0").install_layout,
        .tools = &.{
            .{ .tool = "go", .kind = .archive, .version = "1.24.4" },
            .{ .tool = "neovim", .kind = .archive, .version = "0.11.2" },
            .{ .tool = "tmux", .kind = .system, .version = "system" },
            .{ .tool = "zig", .kind = .archive, .version = "0.14.1" },
        },
        .configs = &.{ "neovim-config", "tmux-config" },
        .stow_packages = &.{ "neovim", "tmux" },
    };

    const diff = try computeDiff(alloc, testLock("0.1.0"), test_resolve_response, receipt);
    try testing.expect(diff.isEmpty());
}

test selectTools {
    const old_log_level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = old_log_level;

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const available = [_][]const u8{ "alacritty", "go", "neovim", "tmux", "zig" };

    // No lock, no flags: everything.
    const all = try selectTools(alloc, &available, null, .{});
    try testing.expectEqual(available.len, all.len);

    // Explicit --tools replaces the selection.
    const explicit = try selectTools(alloc, &available, testLock("0.1.0"), .{
        .tools = &.{ "tmux", "neovim" },
    });
    try testing.expectEqual(@as(usize, 2), explicit.len);
    try testing.expectEqualStrings("neovim", explicit[0]);

    // --add/--remove adjust the locked selection.
    const adjusted = try selectTools(alloc, &available, testLock("0.1.0"), .{
        .add = &.{"go"},
        .remove = &.{"neovim"},
    });
    try testing.expectEqual(@as(usize, 2), adjusted.len);
    try testing.expectEqualStrings("go", adjusted[0]);
    try testing.expectEqualStrings("tmux", adjusted[1]);

    try testing.expectError(error.UnknownTool, selectTools(alloc, &available, null, .{
        .tools = &.{"rust"},
    }));
    try testing.expectError(error.ToolNotSelected, selectTools(alloc, &available, null, .{
        .remove = &.{"missing"},
    }));

    // Locked tools the installer no longer exposes are dropped, not errors.
    const reduced = [_][]const u8{"tmux"};
    const preserved = try selectTools(alloc, &reduced, testLock("0.1.0"), .{});
    try testing.expectEqual(@as(usize, 1), preserved.len);
    try testing.expectEqualStrings("tmux", preserved[0]);
}
