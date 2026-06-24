//! The release data compiled into this installer: tools, their supported
//! platforms and versions, and the dependency graph. This file is the only
//! place release content changes.
//!
//! Per platform family the rule is:
//! - apt/dnf (Linux): archives, source builds, and upstream official
//!   installers; build dependencies come from the system package manager.
//! - brew (macOS): plain formulas/casks only. brew resolves dependencies
//!   itself, so no method declares brew build dependencies.

const build_options = @import("build_options");
const std = @import("std");
const shared = @import("shared");
const platform = shared.platform;
const tools = @import("tools.zig");
const resolver = @import("resolver.zig");

pub const name: []const u8 = build_options.release;

const common_platforms = [_]platform.Support{
    .{ .ubuntu = .{
        .versions = &.{ "24.04", "26.04" },
        .archs = &.{ .x86_64, .aarch64 },
    } },
    .{ .fedora = .{
        .versions = &.{"44"},
        .archs = &.{ .x86_64, .aarch64 },
    } },
    .{ .macos = .{
        .archs = &.{ .x86_64, .aarch64 },
    } },
};

const git_version = "2.54.0";
const neovim_version = "0.12.1";
const tmux_version = "3.5a";
const go_version = "1.24.4";
const zig_version = "0.16.0";
const rust_version = "stable";
const docker_version = "official";
const alacritty_version = "0.15.1";

const linux = [_]platform.PackageManager.Kind{ .apt, .dnf };

const parallel_make = "make -j\"$(nproc)\"";

const alacritty_prefix = "{opt}/alacritty/" ++ alacritty_version;

const add_user_to_docker_group =
    "sudo usermod --append --groups docker \"$(id -un)\"";

pub const tool_defs = [_]tools.ToolDef{
    .{
        .id = .git,
        .description = "Git built from source",
        .platforms = &common_platforms,
        .methods = &.{
            .{
                .on = &linux,
                .method = .{ .source = .{
                    .version = git_version,
                    .url = "https://www.kernel.org/pub/software/scm/git/git-" ++ git_version ++ ".tar.gz",
                    .format = .tar_gz,
                    .strip_components = 1,
                    .build_dependencies = .{
                        .packages = .{
                            .apt = &.{ "autoconf", "build-essential", "curl", "dh-autoreconf", "gettext", "libcurl4-gnutls-dev", "libexpat1-dev", "libssl-dev", "tcl", "unzip", "zlib1g-dev" },
                            .dnf = &.{ "autoconf", "curl", "curl-devel", "expat-devel", "gcc", "gettext", "make", "openssl-devel", "perl-ExtUtils-MakeMaker", "zlib-devel" },
                        },
                    },
                    .build_steps = &.{
                        .{ .name = "generate configure", .argv = &.{ "make", "configure" } },
                        .{ .name = "configure", .argv = &.{ "./configure", "--prefix={prefix}" } },
                        .{ .name = "make", .argv = &.{ "sh", "-c", parallel_make ++ " all" } },
                        .{ .name = "install", .argv = &.{ "make", "install" } },
                    },
                    .bin_links = &.{
                        .{ .name = "git", .rel_path = "bin/git" },
                    },
                } },
            },
            .{
                .on = &.{.brew},
                .method = .{ .system = .{ .packages = &.{"git"}, .check_bin = "git" } },
            },
        },
    },
    .{
        .id = .zig,
        .description = "Zig toolchain",
        .platforms = &common_platforms,
        .methods = &.{
            .{
                .on = &linux,
                .method = .{ .archive = .{
                    .version = zig_version,
                    .sources = &.{
                        .{ .arch = .x86_64, .url = "https://ziglang.org/download/" ++ zig_version ++ "/zig-x86_64-linux-" ++ zig_version ++ ".tar.xz", .format = .tar_xz, .strip_components = 1 },
                        .{ .arch = .aarch64, .url = "https://ziglang.org/download/" ++ zig_version ++ "/zig-aarch64-linux-" ++ zig_version ++ ".tar.xz", .format = .tar_xz, .strip_components = 1 },
                    },
                    .bin_links = &.{
                        .{ .name = "zig", .rel_path = "zig" },
                    },
                } },
            },
            .{
                .on = &.{.brew},
                .method = .{ .system = .{ .packages = &.{"zig"}, .check_bin = "zig" } },
            },
        },
    },
    .{
        .id = .go,
        .description = "Go toolchain",
        .platforms = &common_platforms,
        .exports = &.{
            .{ .name = "GOPATH", .value = "{home}/.local/share/go" },
            .{ .name = "PATH", .value = "{home}/.local/share/go/bin", .mode = .prepend_path },
        },
        .methods = &.{
            .{
                .on = &linux,
                .method = .{ .archive = .{
                    .version = go_version,
                    .sources = &.{
                        .{ .arch = .x86_64, .url = "https://go.dev/dl/go" ++ go_version ++ ".linux-amd64.tar.gz", .format = .tar_gz, .strip_components = 1 },
                        .{ .arch = .aarch64, .url = "https://go.dev/dl/go" ++ go_version ++ ".linux-arm64.tar.gz", .format = .tar_gz, .strip_components = 1 },
                    },
                    .bin_links = &.{
                        .{ .name = "go", .rel_path = "bin/go" },
                        .{ .name = "gofmt", .rel_path = "bin/gofmt" },
                    },
                } },
            },
            .{
                .on = &.{.brew},
                .method = .{ .system = .{ .packages = &.{"go"}, .check_bin = "go" } },
            },
        },
    },
    .{
        .id = .rust,
        .description = "Rust toolchain",
        .platforms = &common_platforms,
        .exports = &.{
            .{ .name = "RUSTUP_HOME", .value = "{home}/.local/share/rustup" },
            .{ .name = "CARGO_HOME", .value = "{home}/.local/share/cargo" },
            .{ .name = "PATH", .value = "{home}/.local/share/cargo/bin", .mode = .prepend_path },
        },
        .methods = &.{
            .{
                .on = &linux,
                .method = .{ .official = .{
                    .version = rust_version,
                    .install_dependencies = .{
                        .packages = .{
                            .apt = &.{ "build-essential", "ca-certificates", "curl", "libssl-dev", "pkg-config" },
                            .dnf = &.{ "ca-certificates", "curl", "gcc", "openssl-devel", "pkgconf-pkg-config" },
                        },
                    },
                    .install_steps = &.{
                        .{ .name = "create rust directories", .argv = &.{ "mkdir", "-p", "{home}/.local/share/rustup", "{home}/.local/share/cargo", "{cache_dir}" } },
                        .{ .name = "download rustup", .argv = &.{ "curl", "--fail", "--silent", "--show-error", "--location", "https://sh.rustup.rs", "--output", "{cache_dir}/rustup-init.sh" } },
                        .{ .name = "install rustup", .argv = &.{ "sh", "{cache_dir}/rustup-init.sh", "-y", "--no-modify-path" } },
                        .{ .name = "install stable", .argv = &.{ "rustup", "toolchain", "install", "stable" } },
                        .{ .name = "select stable", .argv = &.{ "rustup", "default", "stable" } },
                    },
                    .uninstall_steps = &.{
                        .{ .name = "remove rustup state", .argv = &.{ "rm", "-rf", "{home}/.local/share/rustup", "{home}/.local/share/cargo" } },
                    },
                    .verify_bins = &.{ "rustup", "cargo", "rustc" },
                } },
            },
            .{
                .on = &.{.brew},
                .method = .{ .system = .{ .packages = &.{"rust"}, .check_bin = "cargo" } },
            },
        },
    },
    .{
        .id = .neovim,
        .description = "Neovim text editor",
        .platforms = &common_platforms,
        .configs = &.{
            .{
                .id = .@"neovim-config",
                .for_tool = .neovim,
                .stow_package = "nvim",
                .install_dependencies = .{
                    .packages = .{
                        .apt = &.{"git"},
                        .dnf = &.{"git"},
                        .brew = &.{"git"},
                    },
                },
                .runtime_dependencies = .{
                    .tools = &.{.go},
                },
                .install_steps = &.{
                    .{ .name = "update neovim packs", .argv = &.{
                        "nvim",
                        "--headless",
                        "+lua vim.pack.update(nil, { force = true })",
                        "+qa",
                    } },
                    .{ .name = "install neovim mason packages", .argv = &.{
                        "nvim",
                        "--headless",
                        "+set nomore",
                        "+silent! MasonInstallAll",
                        "+qa",
                    } },
                },
            },
        },
        .methods = &.{
            .{
                .on = &linux,
                .method = .{ .source = .{
                    .version = neovim_version,
                    .url = "https://github.com/neovim/neovim/archive/refs/tags/v" ++ neovim_version ++ ".tar.gz",
                    .format = .tar_gz,
                    .strip_components = 1,
                    .build_dependencies = .{
                        .packages = .{
                            .apt = &.{ "build-essential", "cmake", "curl", "gettext", "git", "ninja-build", "pkg-config", "unzip" },
                            .dnf = &.{ "cmake", "curl", "gcc", "gcc-c++", "gettext", "git", "make", "ninja-build", "pkgconf-pkg-config", "unzip" },
                        },
                    },
                    .runtime_dependencies = .{
                        .packages = .{
                            .apt = &.{"gettext"},
                            .dnf = &.{"gettext"},
                        },
                    },
                    .build_steps = &.{
                        .{ .name = "build", .argv = &.{ "sh", "-c", parallel_make ++ " CMAKE_BUILD_TYPE=Release CMAKE_INSTALL_PREFIX=\"{prefix}\"" } },
                        .{ .name = "install", .argv = &.{ "make", "install" } },
                    },
                    .bin_links = &.{
                        .{ .name = "nvim", .rel_path = "bin/nvim" },
                    },
                } },
            },
            .{
                .on = &.{.brew},
                .method = .{ .system = .{ .packages = &.{"neovim"}, .check_bin = "nvim" } },
            },
        },
    },
    .{
        .id = .tmux,
        .description = "Terminal multiplexer",
        .platforms = &common_platforms,
        .configs = &.{
            .{
                .id = .@"tmux-config",
                .for_tool = .tmux,
                .stow_package = "tmux",
                .git_checkouts = &.{
                    .{
                        .url = "https://github.com/tmux-plugins/tpm",
                        .destination = "{home}/.local/share/tmux/plugins/tpm",
                    },
                },
                .install_steps = &.{
                    .{ .name = "install tmux plugins", .argv = &.{
                        "env",
                        "TMUX_PLUGIN_MANAGER_PATH={home}/.local/share/tmux/plugins",
                        "{home}/.local/share/tmux/plugins/tpm/bin/install_plugins",
                    } },
                },
            },
        },
        .methods = &.{
            .{
                .on = &linux,
                .method = .{ .source = .{
                    .version = tmux_version,
                    .url = "https://github.com/tmux/tmux/releases/download/" ++ tmux_version ++ "/tmux-" ++ tmux_version ++ ".tar.gz",
                    .format = .tar_gz,
                    .strip_components = 1,
                    .build_dependencies = .{
                        .packages = .{
                            .apt = &.{ "automake", "bison", "build-essential", "libevent-dev", "libncurses-dev", "pkg-config" },
                            .dnf = &.{ "automake", "bison", "gcc", "libevent-devel", "make", "ncurses-devel", "pkgconf-pkg-config" },
                        },
                    },
                    .runtime_dependencies = .{
                        .packages = .{
                            .apt = &.{ "libevent-2.1-7t64", "libncurses6" },
                            .dnf = &.{ "libevent", "ncurses-libs" },
                        },
                    },
                    .build_steps = &.{
                        .{ .name = "configure", .argv = &.{ "./configure", "--prefix={prefix}" } },
                        .{ .name = "make", .argv = &.{ "sh", "-c", parallel_make } },
                        .{ .name = "install", .argv = &.{ "make", "install" } },
                    },
                    .bin_links = &.{
                        .{ .name = "tmux", .rel_path = "bin/tmux" },
                    },
                } },
            },
            .{
                .on = &.{.brew},
                .method = .{ .system = .{ .packages = &.{"tmux"}, .check_bin = "tmux" } },
            },
        },
    },
    .{
        .id = .docker,
        .description = "Docker Engine",
        .platforms = &common_platforms,
        .methods = &.{
            .{
                .on = &.{.apt},
                .method = .{ .official = .{
                    .version = docker_version,
                    .install_dependencies = .{
                        .packages = .{
                            .apt = &.{ "ca-certificates", "curl" },
                        },
                    },
                    .repositories = &.{
                        .{ .apt = .{
                            .key_url = "https://download.docker.com/linux/ubuntu/gpg",
                            .key_path = "/etc/apt/keyrings/docker.asc",
                            .source_path = "/etc/apt/sources.list.d/docker.list",
                            .source_line = "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable",
                        } },
                    },
                    .packages = &.{
                        "docker-ce",
                        "docker-ce-cli",
                        "containerd.io",
                        "docker-buildx-plugin",
                        "docker-compose-plugin",
                    },
                    .conflicting_packages = &.{
                        "docker.io",
                        "docker-doc",
                        "docker-compose",
                        "docker-compose-v2",
                        "podman-docker",
                        "containerd",
                        "runc",
                    },
                    .install_steps = &.{
                        .{ .name = "add user to docker group", .argv = &.{
                            "sh", "-c", add_user_to_docker_group,
                        } },
                    },
                    .verify_bins = &.{"docker"},
                } },
            },
            .{
                .on = &.{.dnf},
                .method = .{ .official = .{
                    .version = docker_version,
                    .install_dependencies = .{
                        .packages = .{
                            .dnf = &.{"dnf-plugins-core"},
                        },
                    },
                    .repositories = &.{
                        .{ .dnf = .{
                            .url = "https://download.docker.com/linux/fedora/docker-ce.repo",
                        } },
                    },
                    .packages = &.{
                        "docker-ce",
                        "docker-ce-cli",
                        "containerd.io",
                        "docker-buildx-plugin",
                        "docker-compose-plugin",
                    },
                    .install_steps = &.{
                        .{ .name = "add user to docker group", .argv = &.{
                            "sh", "-c", add_user_to_docker_group,
                        } },
                    },
                    .verify_bins = &.{"docker"},
                } },
            },
            .{
                .on = &.{.brew},
                .method = .{ .system = .{ .packages = &.{"docker"}, .cask = true, .check_bin = "docker" } },
            },
        },
    },
    .{
        .id = .alacritty,
        .description = "GPU-accelerated terminal emulator",
        .platforms = &common_platforms,
        .configs = &.{
            .{
                .id = .@"alacritty-config",
                .for_tool = .alacritty,
                .stow_package = "alacritty",
                .install_dependencies = .{
                    .packages = .{
                        .apt = &.{ "desktop-file-utils", "ncurses-bin" },
                        .dnf = &.{ "desktop-file-utils", "ncurses" },
                    },
                },
                .install_steps = &.{
                    .{ .name = "validate desktop entry", .argv = &.{
                        "desktop-file-validate",
                        alacritty_prefix ++ "/share/applications/Alacritty.desktop",
                    } },
                    .{ .name = "refresh desktop database", .argv = &.{
                        "update-desktop-database",
                        alacritty_prefix ++ "/share/applications",
                    } },
                    .{ .name = "install alacritty terminfo", .argv = &.{
                        "tic",
                        "-xe",
                        "alacritty,alacritty-direct",
                        alacritty_prefix ++ "/share/alacritty/alacritty.info",
                    } },
                },
            },
        },
        .methods = &.{
            .{
                .on = &linux,
                .method = .{ .source = .{
                    .version = alacritty_version,
                    .url = "https://github.com/alacritty/alacritty/archive/refs/tags/v" ++ alacritty_version ++ ".tar.gz",
                    .format = .tar_gz,
                    .strip_components = 1,
                    .build_dependencies = .{
                        .tools = &.{.rust},
                        .packages = .{
                            .apt = &.{ "cmake", "g++", "gzip", "libfontconfig1-dev", "libfreetype6-dev", "libxcb-xfixes0-dev", "libxkbcommon-dev", "pkg-config", "python3", "scdoc" },
                            .dnf = &.{ "cmake", "fontconfig-devel", "freetype-devel", "gcc-c++", "gzip", "libxcb-devel", "libxkbcommon-devel", "pkgconf-pkg-config", "python3", "scdoc" },
                        },
                    },
                    .runtime_dependencies = .{
                        .packages = .{
                            .apt = &.{ "libfontconfig1", "libfreetype6", "libxcb-xfixes0", "libxkbcommon0" },
                            .dnf = &.{ "fontconfig", "freetype", "libxcb", "libxkbcommon" },
                        },
                    },
                    .build_steps = &.{
                        .{ .name = "cargo build", .argv = &.{ "sh", "-c", "cargo build --locked --release --jobs \"$(nproc)\"" } },
                        .{ .name = "install binary", .argv = &.{ "install", "-D", "-m", "0755", "target/release/alacritty", "{prefix}/bin/alacritty" } },
                        .{ .name = "install desktop file", .argv = &.{ "install", "-D", "-m", "0644", "extra/linux/Alacritty.desktop", "{prefix}/share/applications/Alacritty.desktop" } },
                        .{ .name = "install icon", .argv = &.{ "install", "-D", "-m", "0644", "extra/logo/alacritty-term.svg", "{prefix}/share/icons/hicolor/scalable/apps/Alacritty.svg" } },
                        .{ .name = "install terminfo source", .argv = &.{ "install", "-D", "-m", "0644", "extra/alacritty.info", "{prefix}/share/alacritty/alacritty.info" } },
                    },
                    .bin_links = &.{
                        .{ .name = "alacritty", .rel_path = "bin/alacritty" },
                    },
                } },
            },
            .{
                .on = &.{.brew},
                .method = .{ .system = .{ .packages = &.{"alacritty"}, .cask = true, .check_bin = "alacritty" } },
            },
        },
    },
};

pub const defs: resolver.Defs = .{
    .tools = &tool_defs,
};

pub fn supportsPlatform(p: platform.Platform) bool {
    for (tool_defs) |tool| {
        if (tool.supports(p)) return true;
    }
    return false;
}

pub fn supportedPlatforms(alloc: std.mem.Allocator) ![]const platform.Support {
    var supports: std.ArrayList(platform.Support) = .empty;
    for (tool_defs) |tool| {
        for (tool.platforms) |candidate| {
            var found = false;
            for (supports.items) |existing| {
                if (candidate.eql(existing)) {
                    found = true;
                    break;
                }
            }
            if (!found) try supports.append(alloc, candidate);
        }
    }
    return supports.items;
}
