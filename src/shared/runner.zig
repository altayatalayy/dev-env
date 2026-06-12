//! Child process helpers on top of std.process.

const std = @import("std");
const builtin = @import("builtin");

pub fn succeeded(term: std.process.Child.Term) bool {
    return term == .exited and term.exited == 0;
}

/// Runs `argv` with stdio inherited from the parent; used for commands that
/// need fully interactive stdio.
pub fn runInherit(io: std.Io, argv: []const []const u8) !std.process.Child.Term {
    var child = try std.process.spawn(io, .{ .argv = argv });
    return child.wait(io);
}

/// Runs `argv` with stdin inherited but stdout/stderr captured. Output is
/// printed only when the command fails, matching the installer build-step UX.
pub fn runQuietUnlessFailed(
    alloc: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
) !std.process.Child.Term {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .inherit,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(io);

    var output: std.Io.Writer.Allocating = .init(alloc);
    defer output.deinit();

    var buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi: std.Io.File.MultiReader = undefined;
    multi.init(alloc, io, buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi.deinit();

    while (multi.fill(64, .none)) |_| {
        try drain(&multi, &output.writer);
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => |e| return e,
    }
    try drain(&multi, &output.writer);
    try multi.checkAnyError();

    const term = try child.wait(io);
    if (!succeeded(term)) {
        const command = try std.mem.join(alloc, " ", argv);
        defer alloc.free(command);
        if (!builtin.is_test) {
            std.log.err("command failed: {s}\n{s}", .{ command, output.written() });
        }
    }
    return term;
}

fn drain(multi: *std.Io.File.MultiReader, sink: *std.Io.Writer) !void {
    for (0..2) |i| {
        const r = multi.reader(i);
        const data = r.buffered();
        if (data.len == 0) continue;
        try sink.writeAll(data);
        r.tossBuffered();
    }
}

test succeeded {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const term = try runInherit(std.testing.io, &.{ "sh", "-c", "exit 0" });
    try std.testing.expect(succeeded(term));

    const failed = try runInherit(std.testing.io, &.{ "sh", "-c", "exit 1" });
    try std.testing.expect(!succeeded(failed));
}

test "runQuietUnlessFailed captures command output" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;

    const ok = try runQuietUnlessFailed(std.testing.allocator, std.testing.io, &.{ "sh", "-c", "echo hidden" });
    try std.testing.expect(succeeded(ok));

    const failed = try runQuietUnlessFailed(std.testing.allocator, std.testing.io, &.{ "sh", "-c", "echo visible; exit 7" });
    try std.testing.expect(!succeeded(failed));
}
