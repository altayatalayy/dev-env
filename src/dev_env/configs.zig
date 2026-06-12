//! Config management owned by dev-env: stow-source links, dotfiles refresh,
//! conflict classification, and backups.
//!
//! Stable link layout:
//!   ~/.local/share/dev-env/stow-source/<pkg>
//!     -> ~/.local/share/dev-env/releases/<release>/dotfiles/<pkg>
//! Stow runs from stow-source into $HOME, so switching releases only
//! retargets the stow-source links.

const std = @import("std");
const paths_mod = @import("paths.zig");

pub const ConflictPolicy = enum {
    fail,
    backup,
    skip,
};

pub const TargetState = enum {
    /// Nothing in the way.
    missing,
    /// Symlink that resolves into dev-env-owned directories.
    managed,
    foreign_file,
    foreign_dir,
    foreign_symlink,
};

pub const Conflict = struct {
    /// Absolute path in $HOME.
    target: []const u8,
    state: TargetState,
};

/// Resolves a symlink value read from `link_path` to an absolute path.
pub fn resolveLinkTarget(
    alloc: std.mem.Allocator,
    link_path: []const u8,
    link_value: []const u8,
) ![]const u8 {
    if (std.fs.path.isAbsolute(link_value)) {
        return std.fs.path.resolve(alloc, &.{link_value});
    }
    const dir = std.fs.path.dirname(link_path) orelse "/";
    return std.fs.path.resolve(alloc, &.{ dir, link_value });
}

pub fn isManagedTarget(resolved: []const u8, managed_roots: []const []const u8) bool {
    for (managed_roots) |root| {
        if (std.mem.startsWith(u8, resolved, root) and
            (resolved.len == root.len or resolved[root.len] == '/'))
        {
            return true;
        }
    }
    return false;
}

pub fn classifyTarget(
    alloc: std.mem.Allocator,
    io: std.Io,
    target: []const u8,
    managed_roots: []const []const u8,
) !TargetState {
    const cwd = std.Io.Dir.cwd();
    const stat = cwd.statFile(io, target, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return .missing,
        else => return err,
    };
    switch (stat.kind) {
        .sym_link => {
            var buffer: [std.fs.max_path_bytes]u8 = undefined;
            const len = try std.Io.Dir.readLinkAbsolute(io, target, &buffer);
            const resolved = try resolveLinkTarget(alloc, target, buffer[0..len]);
            return if (isManagedTarget(resolved, managed_roots)) .managed else .foreign_symlink;
        },
        .directory => return .foreign_dir,
        else => return .foreign_file,
    }
}

/// Checks every file of a dotfiles package against its target in $HOME and
/// returns the conflicts. Existing real directories along the way are fine
/// (stow merges trees); only the package's leaf entries can conflict.
pub fn scanPackageConflicts(
    alloc: std.mem.Allocator,
    io: std.Io,
    dotfiles_dir: []const u8,
    package: []const u8,
    home: []const u8,
    managed_roots: []const []const u8,
) ![]const Conflict {
    var conflicts: std.ArrayList(Conflict) = .empty;

    const package_path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dotfiles_dir, package });
    var dir = try std.Io.Dir.cwd().openDir(io, package_path, .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walk(alloc);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind == .directory) continue;
        const target = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ home, entry.path });
        const state = try classifyTarget(alloc, io, target, managed_roots);
        switch (state) {
            .missing, .managed => {},
            .foreign_file, .foreign_dir, .foreign_symlink => try conflicts.append(alloc, .{
                .target = try alloc.dupe(u8, target),
                .state = state,
            }),
        }
    }

    return conflicts.items;
}

/// "20260611-143501" (UTC) used as the per-run backup directory name.
pub fn formatTimestamp(alloc: std.mem.Allocator, epoch_seconds: u64) ![]const u8 {
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = epoch_seconds };
    const day = epoch.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch.getDaySeconds();
    return std.fmt.allocPrint(alloc, "{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    });
}

pub fn backupPath(
    alloc: std.mem.Allocator,
    backups_root: []const u8,
    timestamp: []const u8,
    relative: []const u8,
) ![]const u8 {
    return std.fmt.allocPrint(alloc, "{s}/{s}/{s}", .{ backups_root, timestamp, relative });
}

/// Moves `source` (file or tree) into the backups directory.
pub fn moveToBackup(
    alloc: std.mem.Allocator,
    io: std.Io,
    backups_root: []const u8,
    timestamp: []const u8,
    relative: []const u8,
    source: []const u8,
) ![]const u8 {
    const dest = try backupPath(alloc, backups_root, timestamp, relative);
    if (std.fs.path.dirname(dest)) |parent| {
        try std.Io.Dir.cwd().createDirPath(io, parent);
    }
    try std.Io.Dir.renameAbsolute(source, dest, io);
    return dest;
}

/// Compares two directory trees by structure and file contents.
pub fn treesEqual(
    alloc: std.mem.Allocator,
    io: std.Io,
    a_path: []const u8,
    b_path: []const u8,
) !bool {
    const cwd = std.Io.Dir.cwd();

    var a_dir = try cwd.openDir(io, a_path, .{ .iterate = true });
    defer a_dir.close(io);
    var b_dir = cwd.openDir(io, b_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer b_dir.close(io);

    var a_count: usize = 0;
    var walker = try a_dir.walk(alloc);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        a_count += 1;
        const b_stat = b_dir.statFile(io, entry.path, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return err,
        };
        if (b_stat.kind != entry.kind) return false;
        if (entry.kind != .file) continue;
        const a_contents = try a_dir.readFileAlloc(io, entry.path, alloc, .unlimited);
        const b_contents = try b_dir.readFileAlloc(io, entry.path, alloc, .unlimited);
        if (!std.mem.eql(u8, a_contents, b_contents)) return false;
    }

    var b_count: usize = 0;
    var b_walker = try b_dir.walk(alloc);
    defer b_walker.deinit();
    while (try b_walker.next(io)) |_| b_count += 1;

    return a_count == b_count;
}

pub const RefreshOutcome = struct {
    /// Stow packages whose locally modified copies were kept (policy skip).
    skipped_packages: []const []const u8 = &.{},
    backed_up: []const []const u8 = &.{},
};

pub const RefreshError = error{ModifiedConfig};

/// Reconciles the extracted dotfiles tree for `release` with a freshly
/// extracted copy at `fresh_path`. A difference means the user modified a
/// dev-env-managed config; the conflict policy decides what happens.
/// Consumes `fresh_path`.
pub fn refreshDotfiles(
    alloc: std.mem.Allocator,
    io: std.Io,
    paths: paths_mod.Paths,
    release: []const u8,
    fresh_path: []const u8,
    packages: []const []const u8,
    policy: ConflictPolicy,
    timestamp: []const u8,
) !RefreshOutcome {
    const cwd = std.Io.Dir.cwd();
    const dest = try paths.releaseDotfiles(alloc, release);
    defer cwd.deleteTree(io, fresh_path) catch {};

    if (std.Io.Dir.accessAbsolute(io, dest, .{})) |_| {} else |_| {
        if (std.fs.path.dirname(dest)) |parent| try cwd.createDirPath(io, parent);
        try std.Io.Dir.renameAbsolute(fresh_path, dest, io);
        return .{};
    }

    var skipped: std.ArrayList([]const u8) = .empty;
    var backed_up: std.ArrayList([]const u8) = .empty;

    for (packages) |package| {
        const current = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dest, package });
        const fresh = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ fresh_path, package });

        const current_exists = blk: {
            std.Io.Dir.accessAbsolute(io, current, .{}) catch break :blk false;
            break :blk true;
        };
        if (!current_exists) {
            try std.Io.Dir.renameAbsolute(fresh, current, io);
            continue;
        }
        if (try treesEqual(alloc, io, fresh, current)) continue;

        switch (policy) {
            .fail => {
                std.log.err(
                    "managed config {s} was modified locally ({s}); use --config-conflict=backup|skip",
                    .{ package, current },
                );
                return error.ModifiedConfig;
            },
            .backup => {
                const rel = try std.fmt.allocPrint(alloc, "dotfiles/{s}", .{package});
                const backup = try moveToBackup(alloc, io, paths.backups, timestamp, rel, current);
                std.log.info("backed up modified config {s} to {s}", .{ package, backup });
                try std.Io.Dir.renameAbsolute(fresh, current, io);
                try backed_up.append(alloc, package);
            },
            .skip => {
                std.log.info("keeping locally modified config {s}", .{package});
                try skipped.append(alloc, package);
            },
        }
    }

    return .{
        .skipped_packages = skipped.items,
        .backed_up = backed_up.items,
    };
}

/// Points stow-source/<pkg> at the release's dotfiles and removes entries for
/// packages that are no longer wanted. Returns the link paths.
pub fn syncStowSource(
    alloc: std.mem.Allocator,
    io: std.Io,
    paths: paths_mod.Paths,
    release: []const u8,
    packages: []const []const u8,
) ![]const []const u8 {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, paths.stow_source);

    var dir = try cwd.openDir(io, paths.stow_source, .{ .iterate = true });
    defer dir.close(io);

    var stale: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        var wanted = false;
        for (packages) |package| {
            if (std.mem.eql(u8, entry.name, package)) {
                wanted = true;
                break;
            }
        }
        if (!wanted) try stale.append(alloc, try alloc.dupe(u8, entry.name));
    }
    for (stale.items) |name| {
        try dir.deleteFile(io, name);
    }

    var links: std.ArrayList([]const u8) = .empty;
    const dotfiles_dir = try paths.releaseDotfiles(alloc, release);
    for (packages) |package| {
        const link_path = try paths.stowPackageLink(alloc, package);
        const target = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dotfiles_dir, package });
        std.Io.Dir.deleteFileAbsolute(io, link_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        try std.Io.Dir.symLinkAbsolute(io, target, link_path, .{});
        try links.append(alloc, link_path);
    }
    return links.items;
}

// --- tests ---

const testing = std.testing;

test resolveLinkTarget {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    try testing.expectEqualStrings(
        "/home/u/.local/share/dev-env/stow-source/neovim/.config/nvim",
        try resolveLinkTarget(
            alloc,
            "/home/u/.config/nvim",
            "../.local/share/dev-env/stow-source/neovim/.config/nvim",
        ),
    );
    try testing.expectEqualStrings(
        "/abs/target",
        try resolveLinkTarget(alloc, "/home/u/.config/x", "/abs/target"),
    );
}

test isManagedTarget {
    const roots = [_][]const u8{
        "/home/u/.local/share/dev-env/stow-source",
        "/home/u/.local/share/dev-env/releases",
    };
    try testing.expect(isManagedTarget("/home/u/.local/share/dev-env/stow-source/neovim/.config", &roots));
    try testing.expect(isManagedTarget("/home/u/.local/share/dev-env/releases/0.1.0/dotfiles/tmux", &roots));
    try testing.expect(!isManagedTarget("/home/u/.config/own", &roots));
    // Prefix match must respect path component boundaries.
    try testing.expect(!isManagedTarget("/home/u/.local/share/dev-env/stow-sources-fake", &roots));
}

test formatTimestamp {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    try testing.expectEqualStrings("19700101-000000", try formatTimestamp(alloc, 0));
    // 2026-06-11 14:35:01 UTC
    try testing.expectEqualStrings("20260611-143501", try formatTimestamp(alloc, 1781188501));
}

test backupPath {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    try testing.expectEqualStrings(
        "/home/u/.local/share/dev-env/backups/20260611-143501/home/.tmux.conf",
        try backupPath(
            alloc,
            "/home/u/.local/share/dev-env/backups",
            "20260611-143501",
            "home/.tmux.conf",
        ),
    );
}

test classifyTarget {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);

    const managed_root = try std.fmt.allocPrint(alloc, "{s}/stow-source", .{root});
    const roots = [_][]const u8{managed_root};

    const missing = try std.fmt.allocPrint(alloc, "{s}/missing", .{root});
    try testing.expectEqual(TargetState.missing, try classifyTarget(alloc, io, missing, &roots));

    try tmp.dir.writeFile(io, .{ .sub_path = "regular", .data = "x" });
    const regular = try std.fmt.allocPrint(alloc, "{s}/regular", .{root});
    try testing.expectEqual(TargetState.foreign_file, try classifyTarget(alloc, io, regular, &roots));

    try tmp.dir.createDirPath(io, "subdir");
    const subdir = try std.fmt.allocPrint(alloc, "{s}/subdir", .{root});
    try testing.expectEqual(TargetState.foreign_dir, try classifyTarget(alloc, io, subdir, &roots));

    try tmp.dir.createDirPath(io, "stow-source/pkg");
    const managed_link = try std.fmt.allocPrint(alloc, "{s}/managed-link", .{root});
    try std.Io.Dir.symLinkAbsolute(io, try std.fmt.allocPrint(alloc, "{s}/pkg", .{managed_root}), managed_link, .{});
    try testing.expectEqual(TargetState.managed, try classifyTarget(alloc, io, managed_link, &roots));

    const foreign_link = try std.fmt.allocPrint(alloc, "{s}/foreign-link", .{root});
    try std.Io.Dir.symLinkAbsolute(io, "/etc/hostname", foreign_link, .{});
    try testing.expectEqual(TargetState.foreign_symlink, try classifyTarget(alloc, io, foreign_link, &roots));
}

test treesEqual {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);

    try tmp.dir.createDirPath(io, "a/.config");
    try tmp.dir.writeFile(io, .{ .sub_path = "a/.config/f", .data = "same" });
    try tmp.dir.createDirPath(io, "b/.config");
    try tmp.dir.writeFile(io, .{ .sub_path = "b/.config/f", .data = "same" });

    const a = try std.fmt.allocPrint(alloc, "{s}/a", .{root});
    const b = try std.fmt.allocPrint(alloc, "{s}/b", .{root});
    try testing.expect(try treesEqual(alloc, io, a, b));

    try tmp.dir.writeFile(io, .{ .sub_path = "b/.config/f", .data = "different" });
    try testing.expect(!try treesEqual(alloc, io, a, b));

    try tmp.dir.writeFile(io, .{ .sub_path = "b/.config/f", .data = "same" });
    try tmp.dir.writeFile(io, .{ .sub_path = "b/extra", .data = "" });
    try testing.expect(!try treesEqual(alloc, io, a, b));
}

test "scanPackageConflicts detects foreign home files" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    const dotfiles_dir = try std.fmt.allocPrint(alloc, "{s}/dotfiles", .{root});
    const home = try std.fmt.allocPrint(alloc, "{s}/home", .{root});
    const package = "tmux";

    try tmp.dir.createDirPath(io, "dotfiles/tmux/.config/tmux");
    try tmp.dir.writeFile(io, .{ .sub_path = "dotfiles/tmux/.config/tmux/tmux.conf", .data = "new" });
    try tmp.dir.createDirPath(io, "home/.config/tmux");
    try tmp.dir.writeFile(io, .{ .sub_path = "home/.config/tmux/tmux.conf", .data = "local" });

    const managed_root = try std.fmt.allocPrint(alloc, "{s}/stow-source", .{root});
    const conflicts = try scanPackageConflicts(alloc, io, dotfiles_dir, package, home, &.{managed_root});
    try testing.expectEqual(@as(usize, 1), conflicts.len);
    try testing.expectEqual(TargetState.foreign_file, conflicts[0].state);
}

test "refreshDotfiles applies backup and skip policies" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    const home = try std.fmt.allocPrint(alloc, "{s}/home", .{root});
    const paths = try paths_mod.Paths.init(alloc, home);
    const package = "tmux";

    try tmp.dir.createDirPath(io, "home/.local/share/dev-env/releases/0.1.0/dotfiles/tmux/.config/tmux");
    try tmp.dir.writeFile(io, .{
        .sub_path = "home/.local/share/dev-env/releases/0.1.0/dotfiles/tmux/.config/tmux/tmux.conf",
        .data = "old",
    });
    try tmp.dir.createDirPath(io, "fresh-backup/tmux/.config/tmux");
    try tmp.dir.writeFile(io, .{
        .sub_path = "fresh-backup/tmux/.config/tmux/tmux.conf",
        .data = "new",
    });
    const fresh_backup = try std.fmt.allocPrint(alloc, "{s}/fresh-backup", .{root});
    const backed_up = try refreshDotfiles(
        alloc,
        io,
        paths,
        "0.1.0",
        fresh_backup,
        &.{package},
        .backup,
        "stamp",
    );
    try testing.expectEqual(@as(usize, 1), backed_up.backed_up.len);
    const backup_path = try std.fmt.allocPrint(
        alloc,
        "{s}/stamp/dotfiles/tmux/.config/tmux/tmux.conf",
        .{paths.backups},
    );
    const backup_contents = try std.Io.Dir.cwd().readFileAlloc(io, backup_path, alloc, .unlimited);
    try testing.expectEqualStrings("old", backup_contents);

    try tmp.dir.createDirPath(io, "fresh-skip/tmux/.config/tmux");
    try tmp.dir.writeFile(io, .{
        .sub_path = "fresh-skip/tmux/.config/tmux/tmux.conf",
        .data = "third",
    });
    const fresh_skip = try std.fmt.allocPrint(alloc, "{s}/fresh-skip", .{root});
    const skipped = try refreshDotfiles(
        alloc,
        io,
        paths,
        "0.1.0",
        fresh_skip,
        &.{package},
        .skip,
        "stamp",
    );
    try testing.expectEqual(@as(usize, 1), skipped.skipped_packages.len);
    try testing.expectEqualStrings(package, skipped.skipped_packages[0]);
    const current_path = try std.fmt.allocPrint(
        alloc,
        "{s}/releases/0.1.0/dotfiles/tmux/.config/tmux/tmux.conf",
        .{paths.data},
    );
    const current_contents = try std.Io.Dir.cwd().readFileAlloc(io, current_path, alloc, .unlimited);
    try testing.expectEqualStrings("new", current_contents);
}
