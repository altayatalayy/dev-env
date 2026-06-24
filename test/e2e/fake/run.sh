#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
if [ $? -ne 0 ]; then
    echo "failed to locate fake e2e script directory" >&2
    exit 1
fi

TESTS="
platform.sh
smoke.sh
exports.sh
plan-change.sh
apply-idempotent.sh
upgrade-downgrade.sh
config-conflicts.sh
doctor.sh
clean-uninstall.sh
protocol-failure.sh
"

for test_script in ${TESTS}; do
    echo "==> e2e/fake/${test_script}"
    if ! bash "${SCRIPT_DIR}/${test_script}"; then
        echo "fake e2e test failed: ${test_script}" >&2
        exit 1
    fi
done

echo "fake e2e suite passed"
