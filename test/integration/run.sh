#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
if [ $? -ne 0 ]; then
    echo "failed to locate integration script directory" >&2
    exit 1
fi

TESTS="
platform.sh
smoke.sh
plan-change.sh
apply-idempotent.sh
upgrade-downgrade.sh
config-conflicts.sh
doctor.sh
clean-uninstall.sh
protocol-failure.sh
"

for test_script in ${TESTS}; do
    echo "==> integration/${test_script}"
    if ! bash "${SCRIPT_DIR}/${test_script}"; then
        echo "integration test failed: ${test_script}" >&2
        exit 1
    fi
done

echo "integration suite passed"
