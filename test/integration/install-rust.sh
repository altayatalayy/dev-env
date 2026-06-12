#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
if [ $? -ne 0 ]; then
    echo "failed to locate integration script directory" >&2
    exit 1
fi

if ! bash "${SCRIPT_DIR}/install-tools.sh" rust; then
    echo "rust install integration tests failed" >&2
    exit 1
fi
