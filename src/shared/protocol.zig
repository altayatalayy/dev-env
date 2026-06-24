//! JSON protocol between dev-env and dev-env-install.
//!
//! Requests travel on the installer's stdin, responses on its stdout; human
//! readable diagnostics go to its stderr. Compatibility is decided purely by
//! `version`: dev-env must support the protocol the installer exposes.
//!
//! Tool and config names are strings at this boundary so dev-env never has to
//! know the tool set of a particular release; the installer maps them to its
//! release-owned enums.

const platform = @import("platform.zig");
const json = @import("json.zig");
const std = @import("std");

pub const version: u32 = 1;

/// Installer argv subcommands.
pub const Command = enum {
    metadata,
    resolve,
    apply,
    verify,
    uninstall,
    @"apply-configs",
    @"extract-dotfiles",
};

pub const MessageKind = enum {
    progress,
    response,
};

pub const ProgressEvent = struct {
    event: []const u8,
    tool: ?[]const u8 = null,
    config: ?[]const u8 = null,
    packages: []const []const u8 = &.{},
    tools: []const []const u8 = &.{},
    detail: ?[]const u8 = null,
};

pub const ProgressMessage = struct {
    protocol: u32 = version,
    kind: MessageKind = .progress,
    command: Command,
    event: ProgressEvent,
};

pub fn FinalMessage(comptime Response: type) type {
    return struct {
        protocol: u32 = version,
        kind: MessageKind = .response,
        command: Command,
        response: Response,
    };
}

pub const LineHeader = struct {
    protocol: u32,
    kind: MessageKind,
    command: Command,
};

pub fn parseRequest(
    comptime Request: type,
    alloc: std.mem.Allocator,
    command: Command,
    input: []const u8,
) !Request {
    const req = try json.parse(Request, alloc, input);
    try validateRequest(command, req.protocol);
    return req;
}

pub fn validateRequest(command: Command, requested: u32) error{UnsupportedProtocol}!void {
    _ = command;
    if (requested != version) return error.UnsupportedProtocol;
}

pub fn parseLineHeader(alloc: std.mem.Allocator, line: []const u8) !LineHeader {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, alloc, line, .{});
    const object = switch (parsed) {
        .object => |object| object,
        else => return error.InvalidProtocolMessage,
    };
    const protocol_value = object.get("protocol") orelse return error.InvalidProtocolMessage;
    const protocol_number = switch (protocol_value) {
        .integer => |value| value,
        else => return error.InvalidProtocolMessage,
    };
    if (protocol_number < 0 or protocol_number > std.math.maxInt(u32)) return error.InvalidProtocolMessage;

    const kind_text = switch (object.get("kind") orelse return error.InvalidProtocolMessage) {
        .string => |value| value,
        else => return error.InvalidProtocolMessage,
    };
    const command_text = switch (object.get("command") orelse return error.InvalidProtocolMessage) {
        .string => |value| value,
        else => return error.InvalidProtocolMessage,
    };

    const header: LineHeader = .{
        .protocol = @intCast(protocol_number),
        .kind = std.meta.stringToEnum(MessageKind, kind_text) orelse return error.InvalidProtocolMessage,
        .command = std.meta.stringToEnum(Command, command_text) orelse return error.InvalidProtocolMessage,
    };
    if (header.protocol != version) return error.UnsupportedProtocol;
    return header;
}

pub fn parseProgress(alloc: std.mem.Allocator, expected: Command, line: []const u8) !ProgressMessage {
    const msg = try json.parse(ProgressMessage, alloc, line);
    try validateLine(.progress, expected, msg.protocol, msg.kind, msg.command);
    return msg;
}

pub fn parseFinal(
    comptime Response: type,
    alloc: std.mem.Allocator,
    expected: Command,
    line: []const u8,
) !FinalMessage(Response) {
    const msg = try json.parse(FinalMessage(Response), alloc, line);
    try validateLine(.response, expected, msg.protocol, msg.kind, msg.command);
    return msg;
}

fn validateLine(
    expected_kind: MessageKind,
    expected_command: Command,
    found_protocol: u32,
    found_kind: MessageKind,
    found_command: Command,
) !void {
    if (found_protocol != version) return error.UnsupportedProtocol;
    if (found_kind != expected_kind) return error.UnexpectedProtocolMessage;
    if (found_command != expected_command) return error.UnexpectedProtocolMessage;
}

pub fn writeProgress(
    alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    command: Command,
    event: ProgressEvent,
) !void {
    try writeLine(alloc, writer, ProgressMessage{ .command = command, .event = event });
}

pub fn writeFinal(
    alloc: std.mem.Allocator,
    writer: *std.Io.Writer,
    command: Command,
    response: anytype,
) !void {
    try writeLine(alloc, writer, FinalMessage(@TypeOf(response)){ .command = command, .response = response });
}

fn writeLine(alloc: std.mem.Allocator, writer: *std.Io.Writer, message: anytype) !void {
    const text = try std.json.Stringify.valueAlloc(alloc, message, .{ .whitespace = .minified });
    try writer.writeAll(text);
    try writer.writeByte('\n');
    try writer.flush();
}

pub const ToolKind = enum {
    /// Downloaded archive installed under the configured opt root.
    archive,
    /// Provided by the system package manager (apt/brew); never versioned
    /// or removed by dev-env.
    system,
    /// Built from source by the release installer.
    source,
    /// Installed by the upstream project's official installer flow.
    official,
};

pub const ToolInfo = struct {
    name: []const u8,
    description: []const u8,
    platforms: []const platform.Support = &.{},
};

pub const ConfigInfo = struct {
    name: []const u8,
    /// Tool this config package configures.
    configures: []const u8,
};

pub const MetadataResponse = struct {
    protocol: u32,
    release: []const u8,
    platforms: []const platform.Support,
    tools: []const ToolInfo,
    configs: []const ConfigInfo,
};

pub const ResolveRequest = struct {
    protocol: u32,
    platform: platform.Platform,
    tools: []const []const u8,
    include_configs: bool,
    include_runtime_dependencies: bool = true,
};

pub const SystemPackages = struct {
    apt: []const []const u8 = &.{},
    dnf: []const []const u8 = &.{},
    brew: []const []const u8 = &.{},
    brew_cask: []const []const u8 = &.{},

    pub fn isEmpty(p: SystemPackages) bool {
        return p.apt.len == 0 and p.dnf.len == 0 and
            p.brew.len == 0 and p.brew_cask.len == 0;
    }
};

pub const ToolAction = struct {
    tool: []const u8,
    kind: ToolKind,
    /// Display/debugging only; versions are owned by the installer release.
    version: []const u8,
    build_dependencies: SystemPackages = .{},
    env_exports: []const EnvExport = &.{},
};

pub const InstallLayout = struct {
    bin: []const u8,
    opt: []const u8,
    cache_dir: []const u8,
};

pub const EnvExport = struct {
    name: []const u8,
    value: []const u8,
    mode: Mode = .set,

    pub const Mode = enum {
        set,
        prepend_path,
    };
};

pub const ResolveResponse = struct {
    selected_tools: []const []const u8,
    resolved_tools: []const []const u8,
    /// Parallel to `stow_packages`: resolved_configs[i] is provided by
    /// stow_packages[i].
    resolved_configs: []const []const u8,
    system_packages: SystemPackages,
    stow_packages: []const []const u8,
    tool_actions: []const ToolAction,
};

pub const ApplyRequest = struct {
    protocol: u32,
    platform: platform.Platform,
    layout: InstallLayout,
    /// Every resolved active tool, including ones already installed. The
    /// installer derives step environments (e.g. cargo on PATH) from this
    /// set, so it must not be limited to the install diff.
    tools: []const []const u8,
    /// Tools to install/activate; a subset of `tools`.
    install: []const []const u8,
    /// Legacy apply-time link deactivation. Normal plan removals call the
    /// installer's `uninstall` command so release-owned tool files are removed.
    deactivate: []const []const u8,
};

pub const InstalledTool = struct {
    tool: []const u8,
    kind: ToolKind,
    version: []const u8,
    opt_dir: ?[]const u8 = null,
    env_exports: []const EnvExport = &.{},
    /// Absolute paths of symlinks created in ~/.local/bin.
    bin_links: []const []const u8 = &.{},
};

pub const ApplyResponse = struct {
    tools: []const InstalledTool,
};

pub const VerifyRequest = struct {
    protocol: u32,
    platform: platform.Platform,
    layout: InstallLayout,
    tools: []const []const u8,
};

pub const VerifyResult = struct {
    tool: []const u8,
    ok: bool,
    detail: []const u8,
};

pub const VerifyResponse = struct {
    results: []const VerifyResult,
};

pub const ConfigApplyRequest = struct {
    protocol: u32,
    platform: platform.Platform,
    layout: InstallLayout,
    /// Active resolved tools, used only so the installer can apply tool-owned
    /// runtime environment exports while running config steps.
    tools: []const []const u8,
    configs: []const []const u8,
};

pub const ConfigApplyResponse = struct {
    applied: []const []const u8,
};

pub const UninstallRequest = struct {
    protocol: u32,
    platform: platform.Platform,
    layout: InstallLayout,
    tools: []const []const u8,
};

pub const UninstallResponse = struct {
    removed: []const []const u8,
    /// System-managed tools that were intentionally left installed.
    kept_system: []const []const u8,
};

pub const ExtractDotfilesRequest = struct {
    protocol: u32,
    /// Absolute destination directory; created if missing.
    dest: []const u8,
};

pub const ExtractDotfilesResponse = struct {
    packages: []const []const u8,
};

// --- tests ---

const testing = std.testing;

test "final protocol line round trip" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const response: ExtractDotfilesResponse = .{ .packages = &.{"tmux"} };
    const line = try json.stringify(alloc, FinalMessage(ExtractDotfilesResponse){
        .command = .@"extract-dotfiles",
        .response = response,
    });

    const header = try parseLineHeader(alloc, line);
    try testing.expectEqual(MessageKind.response, header.kind);
    try testing.expectEqual(Command.@"extract-dotfiles", header.command);

    const parsed = try parseFinal(ExtractDotfilesResponse, alloc, .@"extract-dotfiles", line);
    try testing.expectEqualStrings("tmux", parsed.response.packages[0]);
}

test "apply-configs protocol line round trip" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const response: ConfigApplyResponse = .{ .applied = &.{"tmux-config"} };
    const line = try json.stringify(alloc, FinalMessage(ConfigApplyResponse){
        .command = .@"apply-configs",
        .response = response,
    });

    const header = try parseLineHeader(alloc, line);
    try testing.expectEqual(MessageKind.response, header.kind);
    try testing.expectEqual(Command.@"apply-configs", header.command);

    const parsed = try parseFinal(ConfigApplyResponse, alloc, .@"apply-configs", line);
    try testing.expectEqualStrings("tmux-config", parsed.response.applied[0]);
}

test "protocol version mismatch is rejected" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    try testing.expectError(
        error.UnsupportedProtocol,
        parseLineHeader(alloc,
            \\{"protocol":999,"kind":"response","command":"extract-dotfiles","response":{"packages":[]}}
        ),
    );
    try testing.expectError(error.UnsupportedProtocol, parseRequest(ResolveRequest, alloc, .resolve,
        \\{"protocol":999,"platform":{"ubuntu":{"version":"24.04","arch":"x86_64"}},"tools":[],"include_configs":true}
    ));
}
