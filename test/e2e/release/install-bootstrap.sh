#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
if [ $? -ne 0 ]; then
    echo "failed to locate e2e script directory" >&2
    exit 1
fi

if ! . "${SCRIPT_DIR}/../fake/common.sh"; then
    echo "failed to load test helpers" >&2
    exit 1
fi

if ! dev_env_require_binaries; then
    exit 1
fi

if ! dev_env_prepare_state bootstrap; then
    exit 1
fi

if [ -z "${DEV_ENV_RELEASE_ROOT_URL:-}" ]; then
    echo "missing DEV_ENV_RELEASE_ROOT_URL" >&2
    exit 1
fi

if ! bash /opt/dev-env-install.sh --release-root-url "${DEV_ENV_RELEASE_ROOT_URL}"; then
    echo "bootstrap install failed" >&2
    exit 1
fi

if ! test -x "${HOME}/.local/bin/dev-env"; then
    echo "installed dev-env binary missing" >&2
    exit 1
fi

if ! test -d "${XDG_DATA_HOME}/dev-env/installers"; then
    echo "installed dev-env-install directory missing" >&2
    exit 1
fi

if ! "${HOME}/.local/bin/dev-env" plan --tools tmux >/dev/null; then
    echo "installed dev-env could not plan from the local release" >&2
    exit 1
fi

if ! "${HOME}/.local/bin/dev-env" doctor >/dev/null; then
    echo "installed dev-env doctor failed after bootstrap install" >&2
    exit 1
fi

echo "bootstrap release e2e tests passed"
