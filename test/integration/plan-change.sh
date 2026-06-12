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

if ! dev_env_require_binaries; then exit 1; fi
if ! dev_env_prepare_state plan-change; then exit 1; fi
if ! dev_env_install_fake_release 0.1.0; then exit 1; fi

LOCK_JSON="${XDG_DATA_HOME}/dev-env/lock.json"

if ! "${DEV_ENV}" plan --installer 0.1.0 --tools tmux; then
    echo "initial plan failed" >&2
    exit 1
fi
if ! dev_env_json_assert equals "${LOCK_JSON}" selected_tools.0 tmux; then exit 1; fi

if ! "${DEV_ENV}" plan --add neovim; then
    echo "plan add failed" >&2
    exit 1
fi
if ! dev_env_json_assert contains "${LOCK_JSON}" selected_tools tmux; then exit 1; fi
if ! dev_env_json_assert contains "${LOCK_JSON}" selected_tools neovim; then exit 1; fi
if ! dev_env_json_assert contains "${LOCK_JSON}" resolved_tools zig; then exit 1; fi

if ! "${DEV_ENV}" plan --remove tmux; then
    echo "plan remove failed" >&2
    exit 1
fi
if ! dev_env_json_assert not-contains "${LOCK_JSON}" selected_tools tmux; then exit 1; fi
if ! dev_env_json_assert contains "${LOCK_JSON}" selected_tools neovim; then exit 1; fi

if "${DEV_ENV}" plan --add missing-tool; then
    echo "unknown tool was accepted" >&2
    exit 1
fi

echo "plan-change integration tests passed"
