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
if ! dev_env_prepare_state doctor; then exit 1; fi
if ! dev_env_install_fake_release 0.1.0; then exit 1; fi

if ! "${DEV_ENV}" plan --installer 0.1.0 --tools tmux; then
    echo "plan failed" >&2
    exit 1
fi
if ! "${DEV_ENV}" apply --config-conflict=backup; then
    echo "apply failed" >&2
    exit 1
fi
if ! "${DEV_ENV}" doctor; then
    echo "doctor failed for healthy install" >&2
    exit 1
fi
if DEV_ENV_FAKE_VERIFY_FAIL=tmux "${DEV_ENV}" doctor; then
    echo "doctor succeeded despite failed verification" >&2
    exit 1
fi

echo "doctor fake e2e tests passed"
