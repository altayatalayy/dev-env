//! Helpers for the tool/config name lists that cross the process boundary.
//! Inside the installer these names map to release-owned enums; dev-env only
//! ever sees them as strings.

const std = @import("std");

pub fn contains(names: []const []const u8, name: []const u8) bool {
    for (names) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

pub fn sort(names: [][]const u8) void {
    std.mem.sort([]const u8, names, {}, lessThan);
}

/// Returns a sorted copy of `names` with duplicates removed.
pub fn sortedUnique(alloc: std.mem.Allocator, names: []const []const u8) ![]const []const u8 {
    const copy = try alloc.dupe([]const u8, names);
    sort(copy);
    var len: usize = 0;
    for (copy) |name| {
        if (len > 0 and std.mem.eql(u8, copy[len - 1], name)) continue;
        copy[len] = name;
        len += 1;
    }
    return copy[0..len];
}

/// Set difference: every name in `from` that is not in `in`.
pub fn missingFrom(
    alloc: std.mem.Allocator,
    from: []const []const u8,
    in: []const []const u8,
) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (from) |name| {
        if (!contains(in, name)) try out.append(alloc, name);
    }
    return out.toOwnedSlice(alloc);
}

test sortedUnique {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const result = try sortedUnique(alloc, &.{ "tmux", "go", "tmux", "neovim" });
    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqualStrings("go", result[0]);
    try std.testing.expectEqualStrings("neovim", result[1]);
    try std.testing.expectEqualStrings("tmux", result[2]);
}

test missingFrom {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const result = try missingFrom(alloc, &.{ "go", "tmux", "zig" }, &.{"tmux"});
    try std.testing.expectEqual(@as(usize, 2), result.len);
    try std.testing.expectEqualStrings("go", result[0]);
    try std.testing.expectEqualStrings("zig", result[1]);

    const none = try missingFrom(alloc, &.{"go"}, &.{ "go", "tmux" });
    try std.testing.expectEqual(@as(usize, 0), none.len);
}
