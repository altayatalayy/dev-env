const std = @import("std");
const shared = @import("shared");
const proto = shared.protocol;

pub const Progress = struct {
    alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    command: proto.Command,

    pub fn emit(p: *Progress, event: proto.ProgressEvent) !void {
        try proto.writeProgress(p.alloc, p.writer, p.command, event);
    }
};
