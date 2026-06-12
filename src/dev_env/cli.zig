//! Command line parsing for dev-env.

const std = @import("std");
const configs = @import("configs.zig");
const planner = @import("planner.zig");

pub const usage =
    \\usage: dev-env <command> [options]
    \\
    \\commands:
    \\  plan [options]              write lock.json and show the pending diff
    \\  apply [options]             apply lock.json (creates a default lock if missing)
    \\  upgrade [options]           move to the newest compatible installer and apply
    \\  build [options]             source-build tools into release archives
    \\  doctor                      check host, state, and installed tools
    \\  uninstall [options]         remove managed tools, configs, and state
    \\  clean                       remove inactive tool versions and old state
    \\
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
    \\
;

pub const Command = union(enum) {
    plan: Plan,
    apply: Apply,
    upgrade: Apply,
    build: Build,
    doctor,
    uninstall: Apply,
    clean,

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

pub fn parse(alloc: std.mem.Allocator, args: []const []const u8) Error!Command {
    if (args.len == 0) return fail("missing command", .{});
    const command = args[0];
    const rest = args[1..];

    if (std.mem.eql(u8, command, "plan")) {
        return .{ .plan = try parsePlan(alloc, rest) };
    }
    if (std.mem.eql(u8, command, "apply")) {
        return .{ .apply = try parseApply(rest) };
    }
    if (std.mem.eql(u8, command, "upgrade")) {
        return .{ .upgrade = try parseApply(rest) };
    }
    if (std.mem.eql(u8, command, "build")) {
        return .{ .build = try parseBuild(alloc, rest) };
    }
    if (std.mem.eql(u8, command, "doctor")) {
        try expectNoArgs(command, rest);
        return .doctor;
    }
    if (std.mem.eql(u8, command, "uninstall")) {
        return .{ .uninstall = .{ .policy = try parsePolicy(rest) } };
    }
    if (std.mem.eql(u8, command, "clean")) {
        try expectNoArgs(command, rest);
        return .clean;
    }
    return fail("unknown command: {s}", .{command});
}

fn fail(comptime format: []const u8, args: anytype) error{InvalidArguments} {
    std.log.warn(format, args);
    return error.InvalidArguments;
}

fn expectNoArgs(command: []const u8, rest: []const []const u8) error{InvalidArguments}!void {
    if (rest.len != 0) return fail("{s} takes no arguments", .{command});
}

const Flag = struct {
    name: []const u8,
    value: ?[]const u8,
};

/// Accepts --flag=value and --flag value forms; advances `index` past any
/// consumed value argument.
fn nextFlag(args: []const []const u8, index: *usize) error{InvalidArguments}!Flag {
    const arg = args[index.*];
    index.* += 1;
    if (!std.mem.startsWith(u8, arg, "--")) {
        return fail("unexpected argument: {s}", .{arg});
    }
    if (std.mem.indexOfScalar(u8, arg, '=')) |eq| {
        return .{ .name = arg[0..eq], .value = arg[eq + 1 ..] };
    }
    return .{ .name = arg, .value = null };
}

fn flagValue(flag: Flag, args: []const []const u8, index: *usize) error{InvalidArguments}![]const u8 {
    if (flag.value) |value| return value;
    if (index.* >= args.len or std.mem.startsWith(u8, args[index.*], "--")) {
        return fail("{s} requires a value", .{flag.name});
    }
    const value = args[index.*];
    index.* += 1;
    return value;
}

fn splitNames(alloc: std.mem.Allocator, value: []const u8) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, value, ',');
    while (it.next()) |name| try names.append(alloc, name);
    return names.items;
}

fn parsePlan(alloc: std.mem.Allocator, args: []const []const u8) Error!Command.Plan {
    var plan: Command.Plan = .{};
    var add: std.ArrayList([]const u8) = .empty;
    var remove: std.ArrayList([]const u8) = .empty;

    var index: usize = 0;
    while (index < args.len) {
        const flag = try nextFlag(args, &index);
        if (std.mem.eql(u8, flag.name, "--installer")) {
            plan.installer = try flagValue(flag, args, &index);
        } else if (std.mem.eql(u8, flag.name, "--installer-path")) {
            plan.installer_path = try absolutePathOption(flag, args, &index);
        } else if (std.mem.eql(u8, flag.name, "--tools")) {
            plan.tools = try splitNames(alloc, try flagValue(flag, args, &index));
        } else if (std.mem.eql(u8, flag.name, "--add")) {
            try add.appendSlice(alloc, try splitNames(alloc, try flagValue(flag, args, &index)));
        } else if (std.mem.eql(u8, flag.name, "--remove")) {
            try remove.appendSlice(alloc, try splitNames(alloc, try flagValue(flag, args, &index)));
        } else if (std.mem.eql(u8, flag.name, "--bin-dir")) {
            plan.bin_dir = try absolutePathOption(flag, args, &index);
        } else if (std.mem.eql(u8, flag.name, "--opt-dir")) {
            plan.opt_dir = try absolutePathOption(flag, args, &index);
        } else if (std.mem.eql(u8, flag.name, "--cache-dir")) {
            plan.cache_dir = try absolutePathOption(flag, args, &index);
        } else {
            return fail("unknown plan option: {s}", .{flag.name});
        }
    }
    if (plan.installer != null and plan.installer_path != null) {
        return fail("--installer and --installer-path are mutually exclusive", .{});
    }

    plan.add = add.items;
    plan.remove = remove.items;
    return plan;
}

fn parseApply(args: []const []const u8) Error!Command.Apply {
    var apply: Command.Apply = .{};
    var index: usize = 0;
    while (index < args.len) {
        const flag = try nextFlag(args, &index);
        if (std.mem.eql(u8, flag.name, "--installer-path")) {
            apply.installer_path = try absolutePathOption(flag, args, &index);
        } else if (std.mem.eql(u8, flag.name, "--config-conflict")) {
            const value = try flagValue(flag, args, &index);
            apply.policy = std.meta.stringToEnum(configs.ConflictPolicy, value) orelse {
                return fail("invalid --config-conflict value: {s}", .{value});
            };
        } else {
            return fail("unknown option: {s}", .{flag.name});
        }
    }
    return apply;
}

fn parseBuild(alloc: std.mem.Allocator, args: []const []const u8) Error!Command.Build {
    var build: Command.Build = .{};
    var tools: std.ArrayList([]const u8) = .empty;

    var index: usize = 0;
    while (index < args.len) {
        const flag = try nextFlag(args, &index);
        if (std.mem.eql(u8, flag.name, "--release-root")) {
            build.release_root = try flagValue(flag, args, &index);
        } else if (std.mem.eql(u8, flag.name, "--installer-path")) {
            build.installer_path = try absolutePathOption(flag, args, &index);
        } else if (std.mem.eql(u8, flag.name, "--tool")) {
            try tools.append(alloc, try flagValue(flag, args, &index));
        } else if (std.mem.eql(u8, flag.name, "--platform") or
            std.mem.eql(u8, flag.name, "--platform-version") or
            std.mem.eql(u8, flag.name, "--arch"))
        {
            return fail("{s} is not allowed: build always targets the host it runs on", .{flag.name});
        } else {
            return fail("unknown build option: {s}", .{flag.name});
        }
    }

    build.tools = tools.items;
    return build;
}

fn absolutePathOption(flag: Flag, args: []const []const u8, index: *usize) Error![]const u8 {
    const value = try flagValue(flag, args, index);
    if (!std.fs.path.isAbsolute(value)) return fail("{s} requires an absolute path", .{flag.name});
    return value;
}

fn parsePolicy(args: []const []const u8) error{InvalidArguments}!configs.ConflictPolicy {
    var policy: configs.ConflictPolicy = .fail;

    var index: usize = 0;
    while (index < args.len) {
        const flag = try nextFlag(args, &index);
        if (std.mem.eql(u8, flag.name, "--config-conflict")) {
            const value = try flagValue(flag, args, &index);
            policy = std.meta.stringToEnum(configs.ConflictPolicy, value) orelse {
                return fail("invalid --config-conflict value: {s}", .{value});
            };
        } else {
            return fail("unknown option: {s}", .{flag.name});
        }
    }

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
