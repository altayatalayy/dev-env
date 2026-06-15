//! Command line parsing for dev-env.

const std = @import("std");
const cli_lib = @import("cli");
const configs = @import("configs.zig");
const planner = @import("planner.zig");

/// The full `--help` screen. The command list is generated from `Command` (so
/// it can never drift from the union), while `footer` documents the per-command
/// options — those are parsed by hand below, so their flag names don't all match
/// struct fields and can't be derived safely.
pub const usage = cli_lib.help(Command, "dev-env");

/// True when argv (pass the slice after the program name) asks for help.
pub const wantsHelp = cli_lib.helpRequested;

pub const Command = union(enum) {
    plan: Plan,
    apply: Apply,
    upgrade: Apply,
    build: Build,
    doctor,
    uninstall: Apply,
    clean,

    pub const about = "dev-env — reproducible developer environment manager";

    pub const descriptions = .{
        .plan = "write lock.json and show the pending diff",
        .apply = "apply lock.json (creates a default lock if missing)",
        .upgrade = "move to the newest compatible installer and apply",
        .build = "source-build tools into release archives",
        .doctor = "check host, state, and installed tools",
        .uninstall = "remove managed tools, configs, and state",
        .clean = "remove inactive tool versions and old state",
    };

    pub const footer =
        \\build options:
        \\  --release-root <dir>        directory to write archives and source-builds.json
        \\  --tool <name>               build only this tool (repeatable)
        \\
        \\plan options:
        \\  --installer <release>       lock a specific installer release
        \\  --installer-path <path>     use a local dev-env-install executable
        \\  --tools <a,b,...>           replace the tool selection
        \\  --add <a,b,...>             add tools to the selection
        \\  --remove <a,b,...>          remove tools from the selection
        \\  --bin-dir <path>            executable link directory (absolute)
        \\  --opt-dir <path>            versioned tool install directory (absolute)
        \\  --cache-dir <path>          installer download/build cache (absolute)
        \\
        \\config conflict options (apply/upgrade/uninstall):
        \\  --config-conflict=fail|backup|skip   default: fail
    ;

    pub const Plan = struct {
        installer: ?[]const u8 = null,
        installer_path: ?[]const u8 = null,
        tools: ?[]const []const u8 = null,
        add: []const []const u8 = &.{},
        remove: []const []const u8 = &.{},
        bin_dir: ?[]const u8 = null,
        opt_dir: ?[]const u8 = null,
        cache_dir: ?[]const u8 = null,
    };

    /// `dev-env build` always auto-detects the host platform/version/arch; it
    /// deliberately rejects --platform/--platform-version/--arch so builders
    /// cannot claim to produce artifacts for a host they are not running on.
    pub const Build = struct {
        release_root: ?[]const u8 = null,
        installer_path: ?[]const u8 = null,
        tools: []const []const u8 = &.{},
    };

    pub const Apply = struct {
        installer_path: ?[]const u8 = null,
        policy: configs.ConflictPolicy = .fail,
    };
};

pub const Error = error{ InvalidArguments, OutOfMemory };

const Verb = enum { plan, apply, upgrade, build, doctor, uninstall, clean };

pub fn parse(alloc: std.mem.Allocator, args: []const [:0]const u8) Error!Command {
    if (args.len == 0) return fail("missing command", .{});
    const rest = args[1..];

    return switch (cli_lib.command(Verb, args[0]) catch return fail("unknown command: {s}", .{args[0]})) {
        .plan => .{ .plan = try parsePlan(alloc, rest) },
        .apply => .{ .apply = try parseApply(rest) },
        .upgrade => .{ .upgrade = try parseApply(rest) },
        .build => .{ .build = try parseBuild(alloc, rest) },
        .doctor => blk: {
            try expectNoArgs("doctor", rest);
            break :blk .doctor;
        },
        .uninstall => .{ .uninstall = .{ .policy = try parsePolicy(rest) } },
        .clean => blk: {
            try expectNoArgs("clean", rest);
            break :blk .clean;
        },
    };
}

fn fail(comptime format: []const u8, args: anytype) error{InvalidArguments} {
    std.log.warn(format, args);
    return error.InvalidArguments;
}

fn expectNoArgs(command: []const u8, rest: []const [:0]const u8) error{InvalidArguments}!void {
    if (rest.len != 0) return fail("{s} takes no arguments", .{command});
}

fn splitNames(alloc: std.mem.Allocator, value: []const u8) ![]const []const u8 {
    return cli_lib.splitList(alloc, value);
}

fn parsePlan(alloc: std.mem.Allocator, args: []const [:0]const u8) Error!Command.Plan {
    var plan: Command.Plan = .{};
    var add: std.ArrayList([]const u8) = .empty;
    var remove: std.ArrayList([]const u8) = .empty;

    var parser = cli_lib.Parser.init(args);
    while (parser.next()) |arg| switch (arg) {
        .positional => |pos| return fail("unexpected argument: {s}", .{pos}),
        .flag => |flag| {
            if (flag.is("--installer")) {
                plan.installer = try flagValue(&parser, flag);
            } else if (flag.is("--installer-path")) {
                plan.installer_path = try absolutePathOption(&parser, flag);
            } else if (flag.is("--tools")) {
                plan.tools = try splitNames(alloc, try flagValue(&parser, flag));
            } else if (flag.is("--add")) {
                try add.appendSlice(alloc, try splitNames(alloc, try flagValue(&parser, flag)));
            } else if (flag.is("--remove")) {
                try remove.appendSlice(alloc, try splitNames(alloc, try flagValue(&parser, flag)));
            } else if (flag.is("--bin-dir")) {
                plan.bin_dir = try absolutePathOption(&parser, flag);
            } else if (flag.is("--opt-dir")) {
                plan.opt_dir = try absolutePathOption(&parser, flag);
            } else if (flag.is("--cache-dir")) {
                plan.cache_dir = try absolutePathOption(&parser, flag);
            } else {
                return fail("unknown plan option: {s}", .{flag.name});
            }
        },
    };
    if (plan.installer != null and plan.installer_path != null) {
        return fail("--installer and --installer-path are mutually exclusive", .{});
    }

    plan.add = add.items;
    plan.remove = remove.items;
    return plan;
}

fn parseApply(args: []const [:0]const u8) Error!Command.Apply {
    var apply: Command.Apply = .{};
    var parser = cli_lib.Parser.init(args);
    while (parser.next()) |arg| switch (arg) {
        .positional => |pos| return fail("unexpected argument: {s}", .{pos}),
        .flag => |flag| {
            if (flag.is("--installer-path")) {
                apply.installer_path = try absolutePathOption(&parser, flag);
            } else if (flag.is("--config-conflict")) {
                apply.policy = parser.enumValue(configs.ConflictPolicy, flag) catch |err| {
                    if (err == error.InvalidValue) {
                        return fail("invalid --config-conflict value: {s}", .{parser.offending});
                    }
                    return flagError(&parser, err);
                };
            } else {
                return fail("unknown option: {s}", .{flag.name});
            }
        },
    };
    return apply;
}

fn parseBuild(alloc: std.mem.Allocator, args: []const [:0]const u8) Error!Command.Build {
    var build: Command.Build = .{};
    var tools: std.ArrayList([]const u8) = .empty;

    var parser = cli_lib.Parser.init(args);
    while (parser.next()) |arg| switch (arg) {
        .positional => |pos| return fail("unexpected argument: {s}", .{pos}),
        .flag => |flag| {
            if (flag.is("--release-root")) {
                build.release_root = try flagValue(&parser, flag);
            } else if (flag.is("--installer-path")) {
                build.installer_path = try absolutePathOption(&parser, flag);
            } else if (flag.is("--tool")) {
                try tools.append(alloc, try flagValue(&parser, flag));
            } else if (flag.is("--platform") or flag.is("--platform-version") or flag.is("--arch")) {
                return fail("{s} is not allowed: build always targets the host it runs on", .{flag.name});
            } else {
                return fail("unknown build option: {s}", .{flag.name});
            }
        },
    };

    build.tools = tools.items;
    return build;
}

fn flagValue(parser: *cli_lib.Parser, flag: cli_lib.Flag) Error![]const u8 {
    return parser.value(flag) catch |err| flagError(parser, err);
}

fn flagError(parser: *cli_lib.Parser, err: cli_lib.ParseError) error{InvalidArguments} {
    return switch (err) {
        error.MissingValue => fail("{s} requires a value", .{parser.offending}),
        error.InvalidValue => fail("invalid value: {s}", .{parser.offending}),
        error.DuplicateFlag => fail("duplicate option: {s}", .{parser.offending}),
        error.UnknownFlag => fail("unknown option: {s}", .{parser.offending}),
        error.UnexpectedArgument => fail("unexpected argument: {s}", .{parser.offending}),
        error.UnknownCommand => fail("unknown command: {s}", .{parser.offending}),
        error.MissingCommand => fail("missing command: {s}", .{parser.offending}),
        error.MissingFlag => fail("missing option: {s}", .{parser.offending}),
        error.MissingArgument => fail("missing argument: {s}", .{parser.offending}),
    };
}

fn absolutePathOption(parser: *cli_lib.Parser, flag: cli_lib.Flag) Error![]const u8 {
    const value = try flagValue(parser, flag);
    if (!std.fs.path.isAbsolute(value)) return fail("{s} requires an absolute path", .{flag.name});
    return value;
}

fn parsePolicy(args: []const [:0]const u8) error{InvalidArguments}!configs.ConflictPolicy {
    var policy: configs.ConflictPolicy = .fail;

    var parser = cli_lib.Parser.init(args);
    while (parser.next()) |arg| switch (arg) {
        .positional => |pos| return fail("unexpected argument: {s}", .{pos}),
        .flag => |flag| {
            if (flag.is("--config-conflict")) {
                policy = parser.enumValue(configs.ConflictPolicy, flag) catch |err| {
                    if (err == error.InvalidValue) {
                        return fail("invalid --config-conflict value: {s}", .{parser.offending});
                    }
                    return flagError(&parser, err);
                };
            } else {
                return fail("unknown option: {s}", .{flag.name});
            }
        },
    };

    return policy;
}

pub fn plannerOptions(plan: Command.Plan) planner.Options {
    return .{
        .installer = if (plan.installer_path) |path|
            .{ .local_path = path }
        else if (plan.installer) |release|
            .{ .release = release }
        else
            .keep_locked,
        .tools = plan.tools,
        .add = plan.add,
        .remove = plan.remove,
        .bin_dir = plan.bin_dir,
        .opt_dir = plan.opt_dir,
        .cache_dir = plan.cache_dir,
    };
}

pub fn applyPlannerOptions(apply: Command.Apply, installer: planner.InstallerChoice) planner.Options {
    return .{
        .installer = if (apply.installer_path) |path| .{ .local_path = path } else installer,
    };
}

// --- tests ---

const testing = std.testing;

test "parse commands" {
    const old_log_level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = old_log_level;

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    try testing.expectEqual(Command.doctor, try parse(alloc, &.{"doctor"}));
    try testing.expectEqual(Command.clean, try parse(alloc, &.{"clean"}));

    const apply = try parse(alloc, &.{"apply"});
    try testing.expectEqual(configs.ConflictPolicy.fail, apply.apply.policy);

    const skip = try parse(alloc, &.{ "upgrade", "--config-conflict=skip" });
    try testing.expectEqual(configs.ConflictPolicy.skip, skip.upgrade.policy);

    try testing.expectError(error.InvalidArguments, parse(alloc, &.{}));
    try testing.expectError(error.InvalidArguments, parse(alloc, &.{"unknown"}));
    try testing.expectError(error.InvalidArguments, parse(alloc, &.{ "doctor", "extra" }));
    try testing.expectError(error.InvalidArguments, parse(alloc, &.{ "apply", "--config-conflict=bad" }));
}

test "parse plan flags" {
    const old_log_level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = old_log_level;

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const plan = (try parse(alloc, &.{
        "plan",
        "--installer",
        "0.2.0",
        "--tools=neovim,tmux",
        "--add",
        "go",
        "--add=zig",
        "--remove",
        "alacritty",
        "--bin-dir",
        "/tmp/bin",
        "--opt-dir=/tmp/opt",
        "--cache-dir",
        "/tmp/cache",
    })).plan;

    try testing.expectEqualStrings("0.2.0", plan.installer.?);
    try testing.expectEqual(@as(usize, 2), plan.tools.?.len);
    try testing.expectEqualStrings("neovim", plan.tools.?[0]);
    try testing.expectEqualStrings("tmux", plan.tools.?[1]);
    try testing.expectEqual(@as(usize, 2), plan.add.len);
    try testing.expectEqualStrings("go", plan.add[0]);
    try testing.expectEqualStrings("zig", plan.add[1]);
    try testing.expectEqual(@as(usize, 1), plan.remove.len);
    try testing.expectEqualStrings("/tmp/bin", plan.bin_dir.?);
    try testing.expectEqualStrings("/tmp/opt", plan.opt_dir.?);
    try testing.expectEqualStrings("/tmp/cache", plan.cache_dir.?);

    const options = plannerOptions(plan);
    try testing.expectEqualStrings("0.2.0", options.installer.release);
    try testing.expectEqualStrings("/tmp/bin", options.bin_dir.?);

    try testing.expectError(error.InvalidArguments, parse(alloc, &.{ "plan", "--tools" }));
    try testing.expectError(error.InvalidArguments, parse(alloc, &.{ "plan", "--bogus=1" }));
    try testing.expectError(error.InvalidArguments, parse(alloc, &.{ "plan", "--opt-dir", "relative" }));
}

test "parse build flags" {
    const old_log_level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = old_log_level;

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const build = (try parse(alloc, &.{
        "build",
        "--release-root",
        "build/releases/download/v0.1.0",
        "--tool",
        "tmux",
        "--tool=git",
    })).build;

    try testing.expectEqualStrings("build/releases/download/v0.1.0", build.release_root.?);
    try testing.expectEqual(@as(usize, 2), build.tools.len);
    try testing.expectEqualStrings("tmux", build.tools[0]);
    try testing.expectEqualStrings("git", build.tools[1]);

    // No tools means "all source-buildable tools".
    const all = (try parse(alloc, &.{ "build", "--release-root", "out" })).build;
    try testing.expectEqual(@as(usize, 0), all.tools.len);
}

test "build rejects platform overrides" {
    const old_log_level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = old_log_level;

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    try testing.expectError(error.InvalidArguments, parse(alloc, &.{ "build", "--platform", "ubuntu" }));
    try testing.expectError(error.InvalidArguments, parse(alloc, &.{ "build", "--platform-version", "24.04" }));
    try testing.expectError(error.InvalidArguments, parse(alloc, &.{ "build", "--arch", "x86_64" }));
    try testing.expectError(error.InvalidArguments, parse(alloc, &.{ "build", "--bogus" }));
}

test "parse installer path flags" {
    const old_log_level = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = old_log_level;

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const plan = (try parse(alloc, &.{ "plan", "--installer-path", "/tmp/dev-env-install" })).plan;
    try testing.expectEqualStrings("/tmp/dev-env-install", plan.installer_path.?);
    try testing.expectEqualStrings("/tmp/dev-env-install", plannerOptions(plan).installer.local_path);

    const apply = (try parse(alloc, &.{
        "apply",
        "--installer-path=/tmp/dev-env-install",
        "--config-conflict=backup",
    })).apply;
    try testing.expectEqualStrings("/tmp/dev-env-install", apply.installer_path.?);
    try testing.expectEqual(configs.ConflictPolicy.backup, apply.policy);

    try testing.expectError(error.InvalidArguments, parse(alloc, &.{ "plan", "--installer-path", "relative" }));
    try testing.expectError(error.InvalidArguments, parse(alloc, &.{ "plan", "--installer", "0.1.0", "--installer-path", "/tmp/dev-env-install" }));
}
