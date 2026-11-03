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
    @"shell-config",
    @"neovim-config",
    @"tmux-config",
    @"alacritty-config",
};
