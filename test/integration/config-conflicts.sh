#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
if [ $? -ne 0 ]; then
    echo "failed to locate integration script directory" >&2
    exit 1
fi

if ! . "${SCRIPT_DIR}/common.sh"; then
    echo "failed to load integration helpers" >&2
    exit 1
fi

if ! dev_env_require_binaries; then
    exit 1
fi

if ! dev_env_prepare_state config-conflicts; then
    exit 1
fi

if ! dev_env_install_release; then
    exit 1
fi

if ! "${DEV_ENV}" plan --installer "${RELEASE}" --tools tmux; then
    echo "dev-env plan failed for config conflict test" >&2
    exit 1
fi

if ! mkdir --parents "${HOME}/.config/tmux"; then
    echo "failed to create tmux config directory" >&2
    exit 1
fi

if ! printf '%s\n' "local tmux config" > "${HOME}/.config/tmux/tmux.conf"; then
    echo "failed to create local tmux conflict" >&2
    exit 1
fi

if "${DEV_ENV}" apply --config-conflict=fail; then
    echo "config conflict did not fail with fail policy" >&2
    exit 1
fi

if ! test -f "${HOME}/.config/tmux/tmux.conf"; then
    echo "fail policy removed the local tmux config" >&2
    exit 1
fi

if ! "${DEV_ENV}" apply --config-conflict=backup; then
    echo "backup policy did not resolve the config conflict" >&2
    exit 1
fi

if ! find "${XDG_DATA_HOME}/dev-env/backups" -type f -path '*/home/.config/tmux/tmux.conf' | grep . >/dev/null; then
    echo "backup policy did not record the conflicting tmux config" >&2
    exit 1
fi

if ! test -L "${HOME}/.config/tmux/tmux.conf"; then
    echo "tmux config was not stowed after backup policy" >&2
    exit 1
fi

if ! grep --extended-regexp '"configs"[[:space:]]*:' "${XDG_DATA_HOME}/dev-env/installed.json" >/dev/null; then
    echo "installed.json did not record configs" >&2
    exit 1
fi

echo "config conflict integration tests passed"
