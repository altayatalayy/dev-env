#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
if [ $? -ne 0 ]; then
    echo "failed to locate fake e2e script directory" >&2
    exit 1
fi
if ! . "${SCRIPT_DIR}/common.sh"; then
    echo "failed to load fake e2e helpers" >&2
    exit 1
fi

if ! dev_env_require_binaries; then exit 1; fi
if ! dev_env_prepare_state plan-change; then exit 1; fi
if ! dev_env_install_fake_release 0.1.0; then exit 1; fi

LOCK_JSON="${XDG_DATA_HOME}/dev-env/lock.json"
INSTALLED_JSON="${XDG_DATA_HOME}/dev-env/installed.json"

if ! "${DEV_ENV}" plan --installer 0.1.0 --tools tmux; then
    echo "initial plan failed" >&2
    exit 1
fi
if ! dev_env_json_assert equals "${LOCK_JSON}" selected_tools.0 tmux; then exit 1; fi
if ! "${DEV_ENV}" apply --config-conflict=backup; then
    echo "initial apply failed" >&2
    exit 1
fi
if ! test -L "${HOME}/.local/bin/tmux"; then
    echo "tmux link was not activated" >&2
    exit 1
fi
if ! test -d "${XDG_DATA_HOME}/dev-env/tools/tmux/0.1.0"; then
    echo "tmux opt dir was not installed" >&2
    exit 1
fi

if ! "${DEV_ENV}" plan --add neovim; then
    echo "plan add failed" >&2
    exit 1
fi
if ! dev_env_json_assert contains "${LOCK_JSON}" selected_tools tmux; then exit 1; fi
if ! dev_env_json_assert contains "${LOCK_JSON}" selected_tools neovim; then exit 1; fi
if ! dev_env_json_assert contains "${LOCK_JSON}" resolved_tools zig; then exit 1; fi
if ! "${DEV_ENV}" apply --config-conflict=backup; then
    echo "apply after add failed" >&2
    exit 1
fi
if ! dev_env_json_assert contains-field "${INSTALLED_JSON}" tools tool tmux; then exit 1; fi
if ! dev_env_json_assert contains-field "${INSTALLED_JSON}" tools tool neovim; then exit 1; fi

if ! "${DEV_ENV}" plan --remove tmux; then
    echo "plan remove failed" >&2
    exit 1
fi
if ! dev_env_json_assert not-contains "${LOCK_JSON}" selected_tools tmux; then exit 1; fi
if ! dev_env_json_assert contains "${LOCK_JSON}" selected_tools neovim; then exit 1; fi
if ! "${DEV_ENV}" apply --config-conflict=backup; then
    echo "apply after remove failed" >&2
    exit 1
fi
if test -e "${HOME}/.local/bin/tmux" || test -L "${HOME}/.local/bin/tmux"; then
    echo "removed tmux executable link still exists" >&2
    exit 1
fi
if test -d "${XDG_DATA_HOME}/dev-env/tools/tmux"; then
    echo "removed tmux opt prefix still exists" >&2
    exit 1
fi
if test -L "${HOME}/.config/tmux/tmux.conf"; then
    echo "removed tmux config symlink still exists" >&2
    exit 1
fi
if ! test -L "${HOME}/.local/bin/nvim"; then
    echo "neovim link was removed with tmux" >&2
    exit 1
fi
if ! dev_env_json_assert not-contains-field "${INSTALLED_JSON}" tools tool tmux; then exit 1; fi
if ! dev_env_json_assert contains-field "${INSTALLED_JSON}" tools tool neovim; then exit 1; fi
if ! "${DEV_ENV}" doctor; then
    echo "doctor failed after plan removal" >&2
    exit 1
fi

if "${DEV_ENV}" plan --add missing-tool; then
    echo "unknown tool was accepted" >&2
    exit 1
fi

echo "plan-change fake e2e tests passed"
