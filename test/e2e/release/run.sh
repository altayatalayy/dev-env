#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
if [ $? -ne 0 ]; then
    echo "failed to locate release e2e script directory" >&2
    exit 1
fi

TESTS="${DEV_ENV_E2E_TESTS:-install-archives.sh install-source-tools.sh}"

for test_script in ${TESTS}; do
    echo "==> e2e/release/${test_script}"
    if ! bash "${SCRIPT_DIR}/${test_script}"; then
        echo "release e2e test failed: ${test_script}" >&2
        exit 1
    fi
done

echo "release e2e suite passed"
