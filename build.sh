#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
if [ $? -ne 0 ]; then
    echo "failed to locate script directory" >&2
    exit 1
fi

REPO_ROOT="$(cd "${SCRIPT_DIR}" >/dev/null 2>&1 && pwd)"
if [ $? -ne 0 ]; then
    echo "failed to locate repository root" >&2
    exit 1
fi

BUILD_IMAGE="dev-env-builder:zig-0.16"
BUILD_DIR="${REPO_ROOT}/build"

if ! mkdir --parents "${BUILD_DIR}"; then
    echo "failed to create build directory" >&2
    exit 1
fi

if ! docker build \
    --file "${REPO_ROOT}/Dockerfile.builder" \
    --tag "${BUILD_IMAGE}" \
    "${REPO_ROOT}"; then
    echo "builder image build failed" >&2
    exit 1
fi

if ! docker run \
    --rm \
    --volume "${BUILD_DIR}:/build" \
    "${BUILD_IMAGE}"; then
    echo "release build container failed" >&2
    exit 1
fi
