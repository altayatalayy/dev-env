//! The release data compiled into this installer: which platforms it
//! supports, which tools it ships at which versions, and the dependency
//! graph. This file is the only place release content changes.
//!
//! Per platform family the rule is:
//! - apt/dnf (Linux): archives, source builds, and upstream official
//!   installers; build dependencies come from the system package manager.
//! - brew (macOS): plain formulas/casks only. brew resolves dependencies
//!   itself, so no method declares brew build dependencies.

const build_options = @import("build_options");
const shared = @import("shared");
const platform = shared.platform;
const tools = @import("tools.zig");
const resolver = @import("resolver.zig");

pub const name: []const u8 = build_options.release;

pub const supported_platforms = [_]platform.Support{
    .{ .ubuntu = .{
        .versions = &.{ "24.04", "26.04" },
        .archs = &.{ .x86_64, .aarch64 },
    } },
    .{ .fedora = .{
        .versions = &.{ "42", "43" },
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

const linux = [_]platform.PackageManager{ .apt, .dnf };

const tmux_install_tpm =
    "if [ ! -d \"{home}/.tmux/plugins/tpm\" ]; then " ++
    "mkdir -p \"{home}/.tmux/plugins\" && " ++
    "git clone --depth 1 https://github.com/tmux-plugins/tpm \"{home}/.tmux/plugins/tpm\"; " ++
    "fi";

const docker_apt_install_key =
    "curl --fail --silent --show-error --location https://download.docker.com/linux/ubuntu/gpg " ++
    "| sudo tee /etc/apt/keyrings/docker.asc >/dev/null";

const docker_apt_enable_source =
    ". /etc/os-release && ARCH=$(dpkg --print-architecture) && " ++
    "echo \"deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] " ++
    "https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable\" " ++
    "| sudo tee /etc/apt/sources.list.d/docker.list >/dev/null";

const docker_apt_install_packages =
    "sudo apt-get update --quiet && " ++
    "sudo env DEBIAN_FRONTEND=noninteractive apt-get install --yes " ++
    "docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin";

const add_user_to_docker_group =
    "sudo usermod --append --groups docker \"$(id -un)\"";

pub const tool_defs = [_]tools.ToolDef{
    .{
        .id = .git,
        .description = "Git built from source",
        .methods = &.{
            .{
                .on = &linux,
                .method = .{ .source = .{
                    .version = git_version,
                    .url = "https://www.kernel.org/pub/software/scm/git/git-" ++ git_version ++ ".tar.gz",
                    .format = .tar_gz,
                    .strip_components = 1,
                    .build_dependencies = .{
                        .apt = &.{ "autoconf", "build-essential", "curl", "dh-autoreconf", "gettext", "libcurl4-gnutls-dev", "libexpat1-dev", "libssl-dev", "tcl", "unzip", "zlib1g-dev" },
                        .dnf = &.{ "autoconf", "curl", "curl-devel", "expat-devel", "gcc", "gettext", "make", "openssl-devel", "perl-ExtUtils-MakeMaker", "zlib-devel" },
                    },
                    .build_steps = &.{
                        .{ .name = "generate configure", .argv = &.{ "make", "configure" } },
                        .{ .name = "configure", .argv = &.{ "./configure", "--prefix={prefix}" } },
                        .{ .name = "make", .argv = &.{ "make", "all" } },
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
        .methods = &.{
            .{
                .on = &linux,
                .exports = &.{
                    .{ .name = "RUSTUP_HOME", .value = "{home}/.local/share/rustup" },
                    .{ .name = "CARGO_HOME", .value = "{home}/.local/share/cargo" },
                    .{ .name = "PATH", .value = "{home}/.local/share/cargo/bin", .mode = .prepend_path },
                },
                .method = .{ .official = .{
                    .version = rust_version,
                    .install_dependencies = .{
                        .apt = &.{ "build-essential", "ca-certificates", "curl", "libssl-dev", "pkg-config" },
                        .dnf = &.{ "ca-certificates", "curl", "gcc", "openssl-devel", "pkgconf-pkg-config" },
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
        .configs = &.{
            .{
                .id = .@"neovim-config",
                .for_tool = .neovim,
                .stow_package = "nvim",
                .requires_tools = &.{.go},
                .install_dependencies = .{
                    .apt = &.{"git"},
                    .dnf = &.{"git"},
                    .brew = &.{"git"},
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
                .requires_tools = &.{.zig},
                .method = .{ .source = .{
                    .version = neovim_version,
                    .url = "https://github.com/neovim/neovim/archive/refs/tags/v" ++ neovim_version ++ ".tar.gz",
                    .format = .tar_gz,
                    .strip_components = 1,
                    .build_dependencies = .{
                        .apt = &.{"git"},
                        .dnf = &.{"git"},
                    },
                    .build_steps = &.{
                        .{ .name = "build and install", .argv = &.{ "zig", "build", "install", "--prefix", "{prefix}" } },
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
        .configs = &.{
            .{
                .id = .@"tmux-config",
                .for_tool = .tmux,
                .stow_package = "tmux",
                .install_dependencies = .{
                    .apt = &.{"git"},
                    .dnf = &.{"git"},
                    .brew = &.{"git"},
                },
                .install_steps = &.{
                    .{ .name = "install tmux plugin manager", .argv = &.{
                        "sh",
                        "-c",
                        tmux_install_tpm,
                    } },
                    .{ .name = "install tmux plugins", .argv = &.{
                        "env",
                        "TMUX_PLUGIN_MANAGER_PATH={home}/.tmux/plugins",
                        "{home}/.tmux/plugins/tpm/bin/install_plugins",
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
                        .apt = &.{ "automake", "bison", "build-essential", "libevent-dev", "libncurses-dev", "pkg-config" },
                        .dnf = &.{ "automake", "bison", "gcc", "libevent-devel", "make", "ncurses-devel", "pkgconf-pkg-config" },
                    },
                    .build_steps = &.{
                        .{ .name = "configure", .argv = &.{ "./configure", "--prefix={prefix}" } },
                        .{ .name = "make", .argv = &.{"make"} },
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
        .methods = &.{
            .{
                .on = &.{.apt},
                .method = .{ .official = .{
                    .version = docker_version,
                    .install_dependencies = .{
                        .apt = &.{ "ca-certificates", "curl" },
                    },
                    .install_steps = &.{
                        .{ .name = "remove conflicting docker packages", .argv = &.{
                            "sh",
                            "-c",
                            "sudo env DEBIAN_FRONTEND=noninteractive apt-get remove --yes " ++
                                "docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc || true",
                        } },
                        .{ .name = "create apt keyring directory", .argv = &.{
                            "sudo", "install", "-m", "0755", "-d", "/etc/apt/keyrings",
                        } },
                        .{ .name = "install docker apt key", .argv = &.{
                            "sh", "-c", docker_apt_install_key,
                        } },
                        .{ .name = "allow reading docker apt key", .argv = &.{
                            "sudo", "chmod", "a+r", "/etc/apt/keyrings/docker.asc",
                        } },
                        .{ .name = "enable docker apt source", .argv = &.{
                            "sh", "-c", docker_apt_enable_source,
                        } },
                        .{ .name = "install docker apt packages", .argv = &.{
                            "sh", "-c", docker_apt_install_packages,
                        } },
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
                        .dnf = &.{"dnf-plugins-core"},
                    },
                    .install_steps = &.{
                        .{ .name = "add docker dnf repository", .argv = &.{
                            "sudo", "dnf", "config-manager", "addrepo",
                            "--overwrite",
                            "--from-repofile=https://download.docker.com/linux/fedora/docker-ce.repo",
                        } },
                        .{ .name = "install docker dnf packages", .argv = &.{
                            "sudo", "dnf",                "install",            "--assumeyes",
                            "docker-ce", "docker-ce-cli", "containerd.io",      "docker-buildx-plugin",
                            "docker-compose-plugin",
                        } },
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
        .configs = &.{
            .{
                .id = .@"alacritty-config",
                .for_tool = .alacritty,
                .stow_package = "alacritty",
            },
        },
        .methods = &.{
            .{
                .on = &linux,
                .requires_tools = &.{.rust},
                .method = .{ .source = .{
                    .version = alacritty_version,
                    .url = "https://github.com/alacritty/alacritty/archive/refs/tags/v" ++ alacritty_version ++ ".tar.gz",
                    .format = .tar_gz,
                    .strip_components = 1,
                    .build_dependencies = .{
                        .apt = &.{ "cmake", "desktop-file-utils", "g++", "gzip", "libfontconfig1-dev", "libfreetype6-dev", "libxcb-xfixes0-dev", "libxkbcommon-dev", "ncurses-bin", "pkg-config", "python3", "scdoc" },
                        .dnf = &.{ "cmake", "desktop-file-utils", "fontconfig-devel", "freetype-devel", "gcc-c++", "gzip", "libxcb-devel", "libxkbcommon-devel", "ncurses", "pkgconf-pkg-config", "python3", "scdoc" },
                    },
                    .build_steps = &.{
                        .{ .name = "cargo build", .argv = &.{ "cargo", "build", "--locked", "--release" } },
                        .{ .name = "install binary", .argv = &.{ "install", "-D", "-m", "0755", "target/release/alacritty", "{prefix}/bin/alacritty" } },
                        .{ .name = "install desktop file", .argv = &.{ "install", "-D", "-m", "0644", "extra/linux/Alacritty.desktop", "{prefix}/share/applications/Alacritty.desktop" } },
                        .{ .name = "install icon", .argv = &.{ "install", "-D", "-m", "0644", "extra/logo/alacritty-term.svg", "{prefix}/share/icons/hicolor/scalable/apps/Alacritty.svg" } },
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
