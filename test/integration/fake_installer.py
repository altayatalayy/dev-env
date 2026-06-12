#!/usr/bin/env python3
import json
import os
import shutil
import sys
from pathlib import Path

PROTOCOL = 1
TOOLS = ["tmux", "neovim", "zig", "go", "rust", "alacritty", "docker"]
CONFIGS = {
    "tmux": ("tmux-config", "tmux"),
    "neovim": ("neovim-config", "neovim"),
    "alacritty": ("alacritty-config", "alacritty"),
}
BIN_NAMES = {
    "tmux": "tmux",
    "neovim": "nvim",
    "zig": "zig",
    "go": "go",
    "rust": "rustup",
    "alacritty": "alacritty",
    "docker": "docker",
}


def release_id() -> str:
    override = os.environ.get("DEV_ENV_FAKE_RELEASE")
    if override:
        return override
    parent = Path(sys.argv[0]).resolve().parent.name
    if parent and parent != "integration":
        return parent
    return "0.1.0"


def emit(command: str, response: dict) -> None:
    print(json.dumps({
        "protocol": PROTOCOL,
        "kind": "response",
        "command": command,
        "response": response,
    }, separators=(",", ":")))


def progress(command: str, event: dict) -> None:
    print(json.dumps({
        "protocol": PROTOCOL,
        "kind": "progress",
        "command": command,
        "event": event,
    }, separators=(",", ":")))
    sys.stdout.flush()


def read_request() -> dict:
    raw = sys.stdin.read()
    if raw.strip() == "":
        return {}
    return json.loads(raw)


def metadata() -> None:
    emit("metadata", {
        "protocol": PROTOCOL,
        "release": release_id(),
        "platforms": [
            {"ubuntu": {"versions": ["24.04", "26.04"], "archs": ["x86_64", "aarch64"]}},
            {"fedora": {"versions": ["44"], "archs": ["x86_64", "aarch64"]}},
            {"macos": {"versions": [], "archs": ["x86_64", "aarch64"]}},
        ],
        "tools": [{"name": name, "description": f"fake {name}"} for name in TOOLS],
        "configs": [
            {"name": config, "configures": tool}
            for tool, (config, _package) in CONFIGS.items()
        ],
    })


def resolve() -> None:
    req = read_request()
    selected = sorted(dict.fromkeys(req.get("tools", [])))
    unknown = [tool for tool in selected if tool not in TOOLS]
    if unknown:
        print(f"unknown fake tool: {unknown[0]}", file=sys.stderr)
        sys.exit(2)

    resolved = set(selected)
    if "neovim" in resolved:
        resolved.add("zig")
    if "alacritty" in resolved:
        resolved.add("rust")

    stow_packages = []
    resolved_configs = []
    if req.get("include_configs", True):
        for tool in selected:
            if tool in CONFIGS:
                config, package = CONFIGS[tool]
                resolved_configs.append(config)
                stow_packages.append(package)

    tool_actions = []
    for tool in sorted(resolved):
        tool_actions.append({"tool": tool, "kind": "archive", "version": release_id()})

    emit("resolve", {
        "selected_tools": selected,
        "resolved_tools": sorted(resolved),
        "resolved_configs": resolved_configs,
        "system_packages": {"apt": [], "dnf": [], "brew": [], "brew_cask": []},
        "stow_packages": stow_packages,
        "tool_actions": tool_actions,
    })


def make_tool(req: dict, tool: str) -> dict:
    bin_name = BIN_NAMES.get(tool, tool)
    layout = req.get("layout", {})
    opt_root = Path(layout.get("opt", str(Path(os.environ["HOME"]) / ".local" / "share" / "dev-env" / "tools")))
    bin_root = Path(layout.get("bin", str(Path(os.environ["HOME"]) / ".local" / "bin")))
    opt_dir = opt_root / tool / release_id()
    bin_dir = opt_dir / "bin"
    bin_dir.mkdir(parents=True, exist_ok=True)
    exe = bin_dir / bin_name
    exe.write_text(f"#!/usr/bin/env sh\nprintf '%s\\n' 'fake {tool} {release_id()}'\n", encoding="utf-8")
    exe.chmod(0o755)

    link = bin_root / bin_name
    link.parent.mkdir(parents=True, exist_ok=True)
    if link.exists() or link.is_symlink():
        link.unlink()
    link.symlink_to(exe)
    return {
        "tool": tool,
        "kind": "archive",
        "version": release_id(),
        "opt_dir": str(opt_dir),
        "bin_links": [str(link)],
    }


def apply() -> None:
    req = read_request()
    read_request.current = req
    tools = []
    for tool in req.get("install", []):
        progress("apply", {"event": "install_started", "tool": tool})
        tools.append(make_tool(req, tool))
        progress("apply", {"event": "install_finished", "tool": tool})

    layout = req.get("layout", {})
    bin_root = Path(layout.get("bin", str(Path(os.environ["HOME"]) / ".local" / "bin")))
    for tool in req.get("deactivate", []):
        bin_name = BIN_NAMES.get(tool, tool)
        link = bin_root / bin_name
        if link.is_symlink():
            link.unlink()

    emit("apply", {"tools": tools})


def extract_dotfiles() -> None:
    req = read_request()
    dest = Path(req["dest"])
    if dest.exists():
        shutil.rmtree(dest)

    files = {
        "tmux/.config/tmux/tmux.conf": "set -g status on\n",
        "neovim/.config/nvim/init.lua": "vim.g.fake_dev_env = true\n",
        "alacritty/.config/alacritty/alacritty.toml": "[window]\nopacity = 1.0\n",
        "shell/.zshenv": "export ZDOTDIR=\"$HOME/.config/zsh\"\n",
    }
    for rel, contents in files.items():
        path = dest / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents, encoding="utf-8")

    emit("extract-dotfiles", {"packages": ["tmux", "neovim", "alacritty", "shell"]})


def apply_configs() -> None:
    req = read_request()
    for config in req.get("configs", []):
        progress("apply-configs", {"event": "config_apply_started", "config": config})
        progress("apply-configs", {"event": "config_apply_finished", "config": config})
    emit("apply-configs", {"applied": req.get("configs", [])})


def verify() -> None:
    req = read_request()
    fail = {x for x in os.environ.get("DEV_ENV_FAKE_VERIFY_FAIL", "").split(",") if x}
    results = []
    for tool in req.get("tools", []):
        ok = tool not in fail
        results.append({"tool": tool, "ok": ok, "detail": "ok" if ok else "fake verification failed"})
    emit("verify", {"results": results})


def uninstall() -> None:
    req = read_request()
    layout = req.get("layout", {})
    bin_root = Path(layout.get("bin", str(Path(os.environ["HOME"]) / ".local" / "bin")))
    removed = []
    for tool in req.get("tools", []):
        bin_name = BIN_NAMES.get(tool, tool)
        link = bin_root / bin_name
        if link.is_symlink():
            link.unlink()
        removed.append(tool)
    emit("uninstall", {"removed": removed, "kept_system": []})


def main() -> int:
    if os.environ.get("DEV_ENV_FAKE_BROKEN") == "empty-response":
        return 0
    if os.environ.get("DEV_ENV_FAKE_BROKEN") == "invalid-json":
        print("not json")
        return 0

    if len(sys.argv) != 2:
        print("usage: fake_installer.py <command>", file=sys.stderr)
        return 2
    command = sys.argv[1]
    if command == "metadata":
        metadata()
    elif command == "resolve":
        resolve()
    elif command == "apply":
        apply()
    elif command == "verify":
        verify()
    elif command == "uninstall":
        uninstall()
    elif command == "apply-configs":
        apply_configs()
    elif command == "extract-dotfiles":
        extract_dotfiles()
    else:
        print(f"unknown command: {command}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
