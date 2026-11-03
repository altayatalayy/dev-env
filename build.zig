const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const release = b.option([]const u8, "release", "Release id") orelse "0.1.1";
    const dotfiles_dir = b.option([]const u8, "dotfiles-dir", "Directory to embed") orelse "dotfiles";

    const dep = b.dependency("dev_env_lib", .{ .target = target, .optimize = optimize });
    const tools = dep.module("installer_tools");
    const resolver = dep.module("installer_resolver");
    const installer = dep.module("installer");
    const ids = b.createModule(.{
        .root_source_file = b.path("src/installer/environment_ids.zig"),
        .target = target,
        .optimize = optimize,
    });
    tools.addImport("environment_ids", ids);

    const options = b.addOptions();
    options.addOption([]const u8, "release", release);
    const catalog = b.createModule(.{
        .root_source_file = b.path("src/installer/release.zig"),
        .target = target,
        .optimize = optimize,
    });
    catalog.addImport("shared", dep.module("shared"));
    catalog.addImport("installer_tools", tools);
    catalog.addImport("installer_resolver", resolver);
    catalog.addOptions("build_options", options);
    installer.addImport("environment_release", catalog);

    const tar = b.addSystemCommand(&.{
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
    const archive = tar.addOutputFileArg("dotfiles.tar.zst");
    tar.addPrefixedDirectoryArg("--directory=", b.path(dotfiles_dir));
    tar.addArg(".");
    installer.addAnonymousImport("dotfiles_archive", .{ .root_source_file = archive });
    b.installArtifact(b.addExecutable(.{ .name = "dev-env-install", .root_module = installer }));
    b.installArtifact(dep.artifact("dev-env"));

    const test_fixtures = b.addInstallDirectory(.{
        .source_dir = dep.path("test/e2e/fake"),
        .install_dir = .prefix,
        .install_subdir = "test/e2e/fake",
    });
    const test_fixtures_step = b.step("test-fixtures", "Install generic integration test fixtures");
    test_fixtures_step.dependOn(&test_fixtures.step);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = installer })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = tools })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = resolver })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = dep.module("shared") })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = dep.module("frontend") })).step);
}
