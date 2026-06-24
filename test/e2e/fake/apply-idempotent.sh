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
if ! dev_env_prepare_state apply-idempotent; then exit 1; fi
if ! dev_env_install_fake_release 0.1.0; then exit 1; fi

INSTALLED_JSON="${XDG_DATA_HOME}/dev-env/installed.json"

if ! "${DEV_ENV}" plan --installer 0.1.0 --tools tmux; then
    echo "plan failed" >&2
    exit 1
fi
if ! "${DEV_ENV}" apply --config-conflict=backup; then
    echo "first apply failed" >&2
    exit 1
fi
if ! test -L "${HOME}/.local/bin/tmux"; then
    echo "tmux link was not activated" >&2
    exit 1
fi
if ! test -f "${HOME}/.config/tmux/tmux.conf"; then
    echo "tmux config was not stowed" >&2
    exit 1
fi
if ! dev_env_json_assert contains "${INSTALLED_JSON}" stow_packages tmux; then exit 1; fi
if ! dev_env_json_assert contains "${INSTALLED_JSON}" configs tmux-config; then exit 1; fi

if ! cp "${INSTALLED_JSON}" "${TEST_HOME}/installed.before.json"; then
    echo "failed to save installed receipt" >&2
    exit 1
fi
if ! "${DEV_ENV}" apply --config-conflict=backup; then
    echo "second apply failed" >&2
    exit 1
fi
if ! cmp --silent "${TEST_HOME}/installed.before.json" "${INSTALLED_JSON}"; then
    echo "idempotent apply changed installed.json" >&2
    exit 1
fi
if ! "${DEV_ENV}" doctor; then
    echo "doctor failed after idempotent apply" >&2
    exit 1
fi

echo "apply-idempotent fake e2e tests passed"
