//! Small `{name}` template rendering shared by installer steps and dev-env
//! state rendering. Unknown markers are preserved.

const std = @import("std");

pub const Vars = struct {
    home: []const u8,
    cache_dir: []const u8,
    bin: []const u8,
    opt: []const u8,
    prefix: ?[]const u8 = null,

    fn lookup(v: Vars, key: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, key, "home")) return v.home;
        if (std.mem.eql(u8, key, "cache_dir")) return v.cache_dir;
        if (std.mem.eql(u8, key, "bin")) return v.bin;
        if (std.mem.eql(u8, key, "opt")) return v.opt;
        if (std.mem.eql(u8, key, "prefix")) return v.prefix;
        return null;
    }
};

pub fn render(alloc: std.mem.Allocator, value: []const u8, vars: Vars) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    var rest = value;
    while (std.mem.indexOfScalar(u8, rest, '{')) |open| {
        try out.appendSlice(alloc, rest[0..open]);
        const after_open = rest[open + 1 ..];
        const close = std.mem.indexOfScalar(u8, after_open, '}') orelse {
            try out.appendSlice(alloc, rest[open..]);
            return out.items;
        };
        const key = after_open[0..close];
        if (vars.lookup(key)) |replacement| {
            try out.appendSlice(alloc, replacement);
        } else {
            try out.append(alloc, '{');
            try out.appendSlice(alloc, key);
            try out.append(alloc, '}');
        }
        rest = after_open[close + 1 ..];
    }
    if (out.items.len == 0) return value;
    try out.appendSlice(alloc, rest);
    return out.items;
}

test render {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const vars: Vars = .{ .home = "/h", .cache_dir = "/c", .bin = "/b", .opt = "/o", .prefix = "/p" };
    try std.testing.expectEqualStrings("plain", try render(alloc, "plain", vars));
    try std.testing.expectEqualStrings("/h/.local/share/tmux", try render(alloc, "{home}/.local/share/tmux", vars));
    try std.testing.expectEqualStrings("--prefix=/p", try render(alloc, "--prefix={prefix}", vars));
    try std.testing.expectEqualStrings("/o/tmux", try render(alloc, "{opt}/tmux", vars));
    try std.testing.expectEqualStrings("/c//h", try render(alloc, "{cache_dir}/{home}", vars));
    try std.testing.expectEqualStrings("echo ${ARCH}", try render(alloc, "echo ${ARCH}", vars));
    try std.testing.expectEqualStrings("{unclosed", try render(alloc, "{unclosed", vars));
}

test "render preserves missing prefix" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const vars: Vars = .{ .home = "/h", .cache_dir = "/c", .bin = "/b", .opt = "/o" };
    try std.testing.expectEqualStrings("{prefix}/bin", try render(alloc, "{prefix}/bin", vars));
}
