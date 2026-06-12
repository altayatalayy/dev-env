#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
if [ $? -ne 0 ]; then
    echo "failed to locate integration script directory" >&2
    exit 1
fi

if ! bash "${SCRIPT_DIR}/smoke.sh"; then
    echo "smoke integration tests failed" >&2
    exit 1
fi

if [ -n "${DEV_ENV_RELEASE_JSON_URL:-}" ] && [ -n "${DEV_ENV_RELEASE_BASE_URL:-}" ]; then
    if ! bash "${SCRIPT_DIR}/install-bootstrap.sh"; then
        echo "bootstrap integration tests failed" >&2
        exit 1
    fi
fi
