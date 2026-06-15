const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const release = b.option(
        []const u8,
        "release",
        "Release id baked into dev-env-install",
    ) orelse "0.1.0";
    const dotfiles_dir = b.option(
        []const u8,
        "dotfiles-dir",
        "Directory packed into dev-env-install as dotfiles",
    ) orelse "dotfiles";

    const build_opts = b.addOptions();
    build_opts.addOption([]const u8, "release", release);

    const zig_cli = b.dependency("zig_cli", .{
        .target = target,
        .optimize = optimize,
    });
    const cli_mod = zig_cli.module("cli");

    const zig_graph = b.dependency("zig_graph", .{
        .target = target,
        .optimize = optimize,
    });
    const graph_mod = zig_graph.module("graph");

    // Pack dotfiles/ into one zstd-compressed tar archive embedded in the installer.
    const tar_cmd = b.addSystemCommand(&.{
        "tar",
        "--zstd",
        "--create",
        "--format=ustar",
        "--sort=name",
        "--owner=0",
        "--group=0",
        "--numeric-owner",
        "--mtime=@0",
        "--file",
    });
    const dotfiles_archive = tar_cmd.addOutputFileArg("dotfiles.tar.zst");
    tar_cmd.addPrefixedDirectoryArg("--directory=", b.path(dotfiles_dir));
    tar_cmd.addArg(".");

    const shared_mod = b.createModule(.{
        .root_source_file = b.path("src/shared/shared.zig"),
        .target = target,
        .optimize = optimize,
    });

    const dev_env_mod = b.createModule(.{
        .root_source_file = b.path("src/dev_env/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "shared", .module = shared_mod },
            .{ .name = "cli", .module = cli_mod },
        },
    });

    const installer_mod = b.createModule(.{
        .root_source_file = b.path("src/installer/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "shared", .module = shared_mod },
            .{ .name = "cli", .module = cli_mod },
            .{ .name = "graph", .module = graph_mod },
        },
    });
    installer_mod.addOptions("build_options", build_opts);
    installer_mod.addAnonymousImport("dotfiles_archive", .{
        .root_source_file = dotfiles_archive,
    });

    const dev_env_exe = b.addExecutable(.{
        .name = "dev-env",
        .root_module = dev_env_mod,
    });
    b.installArtifact(dev_env_exe);

    const installer_exe = b.addExecutable(.{
        .name = "dev-env-install",
        .root_module = installer_mod,
    });
    b.installArtifact(installer_exe);

    const test_step = b.step("test", "Run unit tests");
    for ([_]*std.Build.Module{ shared_mod, dev_env_mod, installer_mod }) |mod| {
        const unit_test = b.addTest(.{ .root_module = mod });
        test_step.dependOn(&b.addRunArtifact(unit_test).step);
    }
}
