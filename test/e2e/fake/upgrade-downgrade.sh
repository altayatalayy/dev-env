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
if ! dev_env_prepare_state upgrade-downgrade; then exit 1; fi
if ! dev_env_install_fake_release 0.1.0; then exit 1; fi
if ! dev_env_install_fake_release 0.2.0; then exit 1; fi

LOCK_JSON="${XDG_DATA_HOME}/dev-env/lock.json"
INSTALLED_JSON="${XDG_DATA_HOME}/dev-env/installed.json"

if ! "${DEV_ENV}" plan --installer 0.1.0 --tools tmux; then
    echo "initial plan failed" >&2
    exit 1
fi
if ! "${DEV_ENV}" apply --config-conflict=backup; then
    echo "initial apply failed" >&2
    exit 1
fi
if ! dev_env_json_assert equals "${INSTALLED_JSON}" installer_release 0.1.0; then exit 1; fi
if ! test -d "${XDG_DATA_HOME}/dev-env/tools/tmux/0.1.0"; then
    echo "initial tmux opt dir missing" >&2
    exit 1
fi

if ! "${DEV_ENV}" upgrade --config-conflict=backup; then
    echo "upgrade failed" >&2
    exit 1
fi
if ! dev_env_json_assert equals "${LOCK_JSON}" installer_release 0.2.0; then exit 1; fi
if ! dev_env_json_assert equals "${INSTALLED_JSON}" installer_release 0.2.0; then exit 1; fi
if ! test -d "${XDG_DATA_HOME}/dev-env/tools/tmux/0.2.0"; then
    echo "upgraded tmux opt dir missing" >&2
    exit 1
fi

if ! "${DEV_ENV}" plan --installer 0.1.0; then
    echo "downgrade plan failed" >&2
    exit 1
fi
if ! "${DEV_ENV}" apply --config-conflict=backup; then
    echo "downgrade apply failed" >&2
    exit 1
fi
if ! dev_env_json_assert equals "${INSTALLED_JSON}" installer_release 0.1.0; then exit 1; fi
if ! dev_env_json_assert contains "${LOCK_JSON}" selected_tools tmux; then exit 1; fi

echo "upgrade-downgrade fake e2e tests passed"
