//! Data types for release-owned tools and config packages.
//!
//! Tool and config ids are enums because the set is fixed per release; an
//! unknown name coming over the protocol fails to map and is rejected.
//!
//! Install methods are selected per package-manager domain (apt/dnf/brew):
//! the same tool can be a source build on apt/dnf and a plain brew formula
//! on macOS. Build and runtime dependencies belong to the selected method,
//! while dependencies used only by a config belong to that config.

const std = @import("std");
const shared = @import("shared");
const platform = shared.platform;

pub const ToolId = enum {
    git,
    zig,
    go,
    rust,
    neovim,
    tmux,
    docker,
    alacritty,
};

pub const ConfigId = enum {
    @"neovim-config",
    @"tmux-config",
    @"alacritty-config",
};

pub const ToolDef = struct {
    id: ToolId,
    description: []const u8,
    /// OS versions and architectures on which this tool can be installed.
    platforms: []const platform.Support,
    /// Config packages owned by this tool.
    configs: []const ConfigDef = &.{},
    /// Environment values exported whenever this tool is active, regardless
    /// of the installation method selected for the host.
    exports: []const EnvExport = &.{},
    /// Candidate install methods; the first entry matching the host's
    /// package manager wins. No match means the tool is unavailable there.
    methods: []const PlatformMethod,

    pub fn supports(t: ToolDef, p: platform.Platform) bool {
        return platform.isSupported(t.platforms, p);
    }

    pub fn method(t: *const ToolDef, p: platform.Platform) ?*const PlatformMethod {
        if (!t.supports(p)) return null;
        return t.methodForManager(p.packageManager().kind);
    }

    pub fn methodForManager(
        t: *const ToolDef,
        manager: platform.PackageManager.Kind,
    ) ?*const PlatformMethod {
        for (t.methods) |*m| {
            if (m.on.len == 0) return m;
            if (std.mem.indexOfScalar(platform.PackageManager.Kind, m.on, manager) != null) return m;
        }
        return null;
    }
};

pub const PlatformMethod = struct {
    /// Package-manager domains this method applies to; empty means any.
    on: []const platform.PackageManager.Kind = &.{},
    method: Method,
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

pub const Method = union(enum) {
    archive: Archive,
    system: System,
    source: SourceBuild,
    official: OfficialInstaller,

    pub fn dependencies(m: Method) struct {
        install: Dependencies,
        runtime: Dependencies,
    } {
        return switch (m) {
            .source => |source| .{
                .install = source.build_dependencies,
                .runtime = source.runtime_dependencies,
            },
            .official => |official| .{
                .install = official.install_dependencies,
                .runtime = .{},
            },
            .archive, .system => .{ .install = .{}, .runtime = .{} },
        };
    }

    pub fn binLinks(m: Method) ?[]const Archive.BinLink {
        return switch (m) {
            .archive => |archive| archive.bin_links,
            .source => |source| source.bin_links,
            .system, .official => null,
        };
    }
};

pub const Step = struct {
    name: []const u8,
    argv: []const []const u8,
};

/// Packages supplied by the host package manager.
pub const PackageDependencies = struct {
    apt: []const []const u8 = &.{},
    dnf: []const []const u8 = &.{},
    brew: []const []const u8 = &.{},

    pub fn forManager(d: PackageDependencies, pm: platform.PackageManager) []const []const u8 {
        return switch (pm.kind) {
            .apt => d.apt,
            .dnf => d.dnf,
            .brew => d.brew,
        };
    }
};

/// Tools and system packages needed for one lifecycle phase.
pub const Dependencies = struct {
    tools: []const ToolId = &.{},
    packages: PackageDependencies = .{},
};

pub const Archive = struct {
    version: []const u8,
    sources: []const Source,
    bin_links: []const BinLink,

    pub const Source = struct {
        arch: platform.Arch,
        url: []const u8,
        format: Format,
        strip_components: u32,
    };

    pub const Format = enum { tar_gz, tar_xz };

    pub const BinLink = struct {
        /// Symlink name created in the layout's bin directory.
        name: []const u8,
        /// Path of the executable inside the installed version directory.
        rel_path: []const u8,
    };

    pub fn source(a: Archive, arch: platform.Arch) ?Source {
        for (a.sources) |s| {
            if (s.arch == arch) return s;
        }
        return null;
    }
};

pub const System = struct {
    /// Package names for the package manager this method is bound to.
    packages: []const []const u8,
    /// brew only: install the packages as casks.
    cask: bool = false,
    /// Executable expected on PATH once installed; used by verify.
    check_bin: []const u8,
};

pub const SourceBuild = struct {
    version: []const u8,
    url: []const u8,
    format: Archive.Format,
    strip_components: u32,
    build_dependencies: Dependencies = .{},
    runtime_dependencies: Dependencies = .{},
    /// Run inside the extracted source tree. Executables resolve against the
    /// step PATH (layout bin dir plus active tool exports).
    build_steps: []const Step,
    bin_links: []const Archive.BinLink,
};

pub const OfficialInstaller = struct {
    version: []const u8,
    install_dependencies: Dependencies = .{},
    conflicting_packages: []const []const u8 = &.{},
    repositories: []const platform.Repository = &.{},
    packages: []const []const u8 = &.{},
    install_steps: []const Step = &.{},
    uninstall_steps: []const Step = &.{},
    verify_bins: []const []const u8,
};

pub const GitCheckout = struct {
    url: []const u8,
    destination: []const u8,
    branch: ?[]const u8 = null,
    depth: ?u32 = 1,
};

pub const ConfigDef = struct {
    id: ConfigId,
    /// Tool this config package configures; including the config pulls the
    /// tool into the resolved set.
    for_tool: ToolId,
    /// Directory name inside the dotfiles archive (a GNU Stow package).
    stow_package: []const u8,
    /// Other config packages this config depends on.
    config_dependencies: []const ConfigId = &.{},
    /// Dependencies needed while applying the config.
    install_dependencies: Dependencies = .{},
    /// Dependencies used by the configured tool after installation.
    runtime_dependencies: Dependencies = .{},
    /// Git repositories checked out before install steps. Declaring any
    /// checkout automatically adds git to the config's system dependencies.
    git_checkouts: []const GitCheckout = &.{},
    /// Steps run after dev-env has stowed this config package.
    install_steps: []const Step = &.{},
};

// --- tests ---

test "method selection by package manager" {
    const supports = [_]platform.Support{
        .{ .ubuntu = .{ .archs = &.{.x86_64} } },
        .{ .macos = .{ .archs = &.{.x86_64} } },
    };
    const def: ToolDef = .{
        .id = .docker,
        .description = "",
        .platforms = &supports,
        .methods = &.{
            .{ .on = &.{.apt}, .method = .{ .official = .{
                .version = "x",
                .install_steps = &.{},
                .verify_bins = &.{"docker"},
            } } },
            .{ .on = &.{.brew}, .method = .{ .system = .{
                .packages = &.{"docker"},
                .cask = true,
                .check_bin = "docker",
            } } },
        },
    };

    const ubuntu: platform.Platform = .{ .ubuntu = .{ .version = "24.04", .arch = .x86_64 } };
    const macos: platform.Platform = .{ .macos = .{ .version = "15", .arch = .x86_64 } };
    const fedora: platform.Platform = .{ .fedora = .{ .version = "44", .arch = .x86_64 } };
    try std.testing.expect(def.method(ubuntu).?.method == .official);
    try std.testing.expect(def.method(macos).?.method == .system);
    try std.testing.expectEqual(@as(?*const PlatformMethod, null), def.method(fedora));
}

test "empty selector matches any package manager" {
    const supports = [_]platform.Support{
        .{ .ubuntu = .{ .archs = &.{.x86_64} } },
        .{ .fedora = .{ .archs = &.{.x86_64} } },
        .{ .macos = .{ .archs = &.{.x86_64} } },
    };
    const def: ToolDef = .{
        .id = .go,
        .description = "",
        .platforms = &supports,
        .methods = &.{
            .{ .method = .{ .archive = .{ .version = "1", .sources = &.{}, .bin_links = &.{} } } },
        },
    };

    try std.testing.expect(def.method(.{ .ubuntu = .{ .version = "24.04", .arch = .x86_64 } }) != null);
    try std.testing.expect(def.method(.{ .fedora = .{ .version = "44", .arch = .x86_64 } }) != null);
    try std.testing.expect(def.method(.{ .macos = .{ .version = "15", .arch = .x86_64 } }) != null);
}

test "tool platform support is checked before package manager selection" {
    const def: ToolDef = .{
        .id = .git,
        .description = "",
        .platforms = &.{
            .{ .ubuntu = .{ .versions = &.{"24.04"}, .archs = &.{.x86_64} } },
        },
        .methods = &.{
            .{ .on = &.{.apt}, .method = .{ .system = .{
                .packages = &.{"git"},
                .check_bin = "git",
            } } },
        },
    };

    try std.testing.expect(def.method(.{
        .ubuntu = .{ .version = "24.04", .arch = .x86_64 },
    }) != null);
    try std.testing.expect(def.method(.{
        .ubuntu = .{ .version = "22.04", .arch = .x86_64 },
    }) == null);
    try std.testing.expect(def.method(.{
        .debian = .{ .version = "13", .arch = .x86_64 },
    }) == null);
}

test "archive source selection by arch" {
    const a: Archive = .{
        .version = "1",
        .sources = &.{
            .{ .arch = .x86_64, .url = "u1", .format = .tar_gz, .strip_components = 1 },
            .{ .arch = .aarch64, .url = "u2", .format = .tar_gz, .strip_components = 1 },
        },
        .bin_links = &.{},
    };
    try std.testing.expectEqualStrings("u2", a.source(.aarch64).?.url);
}
