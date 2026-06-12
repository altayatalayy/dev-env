//! JSON encode/decode used on both sides of the process boundary and for the
//! two state files. Parsing is strict: unknown fields are errors so schema
//! drift fails early.

const std = @import("std");

pub fn parse(comptime T: type, alloc: std.mem.Allocator, slice: []const u8) !T {
    return std.json.parseFromSliceLeaky(T, alloc, slice, .{ .allocate = .alloc_always });
}

pub fn stringify(gpa: std.mem.Allocator, value: anytype) error{OutOfMemory}![]u8 {
    return std.json.Stringify.valueAlloc(gpa, value, .{ .whitespace = .indent_2 });
}

test "round trip" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const Sample = struct {
        name: []const u8,
        count: u32,
        names: []const []const u8,
    };

    const original: Sample = .{ .name = "dev-env", .count = 3, .names = &.{ "a", "b" } };
    const text = try stringify(alloc, original);
    const decoded = try parse(Sample, alloc, text);

    try std.testing.expectEqualStrings(original.name, decoded.name);
    try std.testing.expectEqual(original.count, decoded.count);
    try std.testing.expectEqual(@as(usize, 2), decoded.names.len);
}

test "unknown field is an error" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const Sample = struct { name: []const u8 };
    try std.testing.expectError(
        error.UnknownField,
        parse(Sample, alloc, "{\"name\":\"x\",\"extra\":1}"),
    );
}
