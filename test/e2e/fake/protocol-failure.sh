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
if ! dev_env_prepare_state protocol-failure; then exit 1; fi

FAKE_INSTALLER="$(dev_env_fake_installer)"
if DEV_ENV_FAKE_BROKEN=empty-response "${DEV_ENV}" plan --installer-path "${FAKE_INSTALLER}" --tools tmux; then
    echo "empty installer response was accepted" >&2
    exit 1
fi
if DEV_ENV_FAKE_BROKEN=invalid-json "${DEV_ENV}" plan --installer-path "${FAKE_INSTALLER}" --tools tmux; then
    echo "invalid protocol line was accepted" >&2
    exit 1
fi

echo "protocol-failure fake e2e tests passed"
