#!/usr/bin/env bash
# Host-side release builder. Builds a builder image (Ubuntu by default, or
# Fedora) and runs it to populate ./build/releases with downloadable assets.
#
# usage: release/build.sh [ubuntu|fedora]

DISTRO="${1:-ubuntu}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
if [ $? -ne 0 ]; then
    echo "failed to locate script directory" >&2
    exit 1
fi

REPO_ROOT="$(cd "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)"
if [ $? -ne 0 ]; then
    echo "failed to locate repository root" >&2
    exit 1
fi

case "${DISTRO}" in
    ubuntu|fedora) ;;
    *)
        echo "unknown builder distro: ${DISTRO} (expected ubuntu or fedora)" >&2
        exit 1
        ;;
esac

DOCKERFILE="${SCRIPT_DIR}/Dockerfile.builder.${DISTRO}"
BUILD_IMAGE="dev-env-builder:${DISTRO}"
BUILD_DIR="${REPO_ROOT}/build"

if ! mkdir --parents "${BUILD_DIR}"; then
    echo "failed to create build directory" >&2
    exit 1
fi

if ! docker build \
    --file "${DOCKERFILE}" \
    --tag "${BUILD_IMAGE}" \
    "${REPO_ROOT}"; then
    echo "builder image build failed" >&2
    exit 1
fi

if ! docker run \
    --rm \
    --volume "${BUILD_DIR}:/build" \
    --env "DEV_ENV_RELEASE=${DEV_ENV_RELEASE:-0.1.0}" \
    "${BUILD_IMAGE}"; then
    echo "release build container failed" >&2
    exit 1
fi
