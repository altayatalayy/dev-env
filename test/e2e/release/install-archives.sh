#!/usr/bin/env bash

if ! SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"; then
    echo "failed to locate e2e script directory" >&2
    exit 1
fi

if ! bash "${SCRIPT_DIR}/install-tools.sh" zig go; then
    echo "archive install release e2e tests failed" >&2
    exit 1
fi
