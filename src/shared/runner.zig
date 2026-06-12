//! Child process helpers on top of std.process.

const std = @import("std");

pub fn succeeded(term: std.process.Child.Term) bool {
    return term == .exited and term.exited == 0;
}

/// Runs `argv` with stdio inherited from the parent; used for commands that
/// interact with the user (sudo, apt, dnf, brew).
pub fn runInherit(io: std.Io, argv: []const []const u8) !std.process.Child.Term {
    var child = try std.process.spawn(io, .{ .argv = argv });
    return child.wait(io);
}

test succeeded {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const term = try runInherit(std.testing.io, &.{ "sh", "-c", "exit 0" });
    try std.testing.expect(succeeded(term));

    const failed = try runInherit(std.testing.io, &.{ "sh", "-c", "exit 1" });
    try std.testing.expect(!succeeded(failed));
}
