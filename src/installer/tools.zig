//! Data types for release-owned tools and config packages.
//!
//! Tool and config ids are enums because the set is fixed per release; an
//! unknown name coming over the protocol fails to map and is rejected.
//!
//! Install methods are selected per package-manager domain (apt/dnf/brew):
//! the same tool can be a source build on apt/dnf and a plain brew formula
//! on macOS. Toolchain dependencies and environment exports belong to the
//! selected method, not the tool, so e.g. rust is only pulled in where
//! alacritty is actually built from source.

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
    /// Config packages owned by this tool.
    configs: []const ConfigDef = &.{},
    /// Candidate install methods; the first entry matching the host's
    /// package manager wins. No match means the tool is unavailable there.
    methods: []const PlatformMethod,

    pub fn method(t: *const ToolDef, pm: platform.PackageManager) ?*const PlatformMethod {
        for (t.methods) |*m| {
            if (m.on.len == 0) return m;
            if (std.mem.indexOfScalar(platform.PackageManager, m.on, pm) != null) return m;
        }
        return null;
    }
};

pub const PlatformMethod = struct {
    /// Package-manager domains this method applies to; empty means any.
    on: []const platform.PackageManager = &.{},
    /// Tools that must be installed first (e.g. a source build's toolchain).
    requires_tools: []const ToolId = &.{},
    /// Environment values exported to every later install/build/config step
    /// while this tool is active.
    exports: []const EnvExport = &.{},
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
};

pub const Step = struct {
    name: []const u8,
    argv: []const []const u8,
};

/// Packages installed by the system package manager before building or
/// running an upstream installer. There is intentionally no brew list:
/// on macOS tools are installed as brew formulas/casks, which resolve
/// their own dependencies.
pub const BuildDependencies = struct {
    apt: []const []const u8 = &.{},
    dnf: []const []const u8 = &.{},

    pub fn forManager(d: BuildDependencies, pm: platform.PackageManager) []const []const u8 {
        return switch (pm) {
            .apt => d.apt,
            .dnf => d.dnf,
            .brew => &.{},
        };
    }
};

/// Packages needed when applying a config package (e.g. git for plugin
/// clones); configs apply on every platform, so brew is included here.
pub const InstallDependencies = struct {
    apt: []const []const u8 = &.{},
    dnf: []const []const u8 = &.{},
    brew: []const []const u8 = &.{},

    pub fn forManager(d: InstallDependencies, pm: platform.PackageManager) []const []const u8 {
        return switch (pm) {
            .apt => d.apt,
            .dnf => d.dnf,
            .brew => d.brew,
        };
    }
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
    build_dependencies: BuildDependencies = .{},
    runtime_dependencies: BuildDependencies = .{},
    /// Run inside the extracted source tree. Executables resolve against the
    /// step PATH (layout bin dir plus active tool exports).
    build_steps: []const Step,
    bin_links: []const Archive.BinLink,
};

pub const OfficialInstaller = struct {
    version: []const u8,
    install_dependencies: BuildDependencies = .{},
    install_steps: []const Step,
    uninstall_steps: []const Step = &.{},
    verify_bins: []const []const u8,
};

pub const ConfigDef = struct {
    id: ConfigId,
    /// Tool this config package configures; including the config pulls the
    /// tool into the resolved set.
    for_tool: ToolId,
    /// Directory name inside the dotfiles archive (a GNU Stow package).
    stow_package: []const u8,
    /// Extra tools this config depends on (e.g. LSP toolchains).
    requires_tools: []const ToolId = &.{},
    /// Other config packages this config depends on.
    requires_configs: []const ConfigId = &.{},
    install_dependencies: InstallDependencies = .{},
    /// Steps run after dev-env has stowed this config package.
    install_steps: []const Step = &.{},
};

// --- tests ---

test "method selection by package manager" {
    const def: ToolDef = .{
        .id = .docker,
        .description = "",
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

    try std.testing.expect(def.method(.apt).?.method == .official);
    try std.testing.expect(def.method(.brew).?.method == .system);
    try std.testing.expectEqual(@as(?*const PlatformMethod, null), def.method(.dnf));
}

test "empty selector matches any package manager" {
    const def: ToolDef = .{
        .id = .go,
        .description = "",
        .methods = &.{
            .{ .method = .{ .archive = .{ .version = "1", .sources = &.{}, .bin_links = &.{} } } },
        },
    };

    try std.testing.expect(def.method(.apt) != null);
    try std.testing.expect(def.method(.dnf) != null);
    try std.testing.expect(def.method(.brew) != null);
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
