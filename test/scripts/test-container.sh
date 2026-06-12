#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
if [ $? -ne 0 ]; then
    echo "failed to locate script directory" >&2
    exit 1
fi

REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." >/dev/null 2>&1 && pwd)"
if [ $? -ne 0 ]; then
    echo "failed to locate repository root" >&2
    exit 1
fi

TEST_SCRIPT="${1:-/opt/dev-env-test/integration/run.sh}"
TARGET="${TEST_TARGET:-ubuntu}"
TEST_UID="$(id -u)"
if [ $? -ne 0 ]; then
    echo "failed to read current uid" >&2
    exit 1
fi

TEST_GID="$(id -g)"
if [ $? -ne 0 ]; then
    echo "failed to read current gid" >&2
    exit 1
fi

BUILD_IMAGE="dev-env-builder:zig-0.16"
SERVER_IMAGE="dev-env-test-server:zig-0.16"
SERVER_NAME="dev-env-test-server"
NETWORK_NAME="dev-env-test-network"
TARGET_IMAGE="dev-env-test-${TARGET}:zig-0.16"
TARGET_DOCKERFILE="${REPO_ROOT}/test/docker/Dockerfile.${TARGET}"
BUILD_DIR="${REPO_ROOT}/build"

case "${TARGET}" in
    ubuntu|fedora)
        ;;
    *)
        echo "unsupported test target: ${TARGET}" >&2
        exit 1
        ;;
esac

if ! test -f "${TARGET_DOCKERFILE}"; then
    echo "missing target dockerfile: ${TARGET_DOCKERFILE}" >&2
    exit 1
fi

cleanup() {
    if ! docker rm --force "${SERVER_NAME}" >/dev/null 2>&1; then
        :
    fi
    if ! docker network rm "${NETWORK_NAME}" >/dev/null 2>&1; then
        :
    fi
}
trap cleanup EXIT

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

if ! docker build \
    --file "${REPO_ROOT}/test/docker/Dockerfile.server" \
    --tag "${SERVER_IMAGE}" \
    "${REPO_ROOT}"; then
    echo "server image build failed" >&2
    exit 1
fi

if ! docker network inspect "${NETWORK_NAME}" >/dev/null 2>&1; then
    if ! docker network create "${NETWORK_NAME}" >/dev/null; then
        echo "failed to create docker network" >&2
        exit 1
    fi
fi

if ! docker run \
    --detach \
    --name "${SERVER_NAME}" \
    --network "${NETWORK_NAME}" \
    "${SERVER_IMAGE}"; then
    echo "failed to start server container" >&2
    exit 1
fi

if ! docker build \
    --file "${TARGET_DOCKERFILE}" \
    --tag "${TARGET_IMAGE}" \
    --build-arg "TEST_UID=${TEST_UID}" \
    --build-arg "TEST_GID=${TEST_GID}" \
    "${REPO_ROOT}"; then
    echo "target image build failed" >&2
    exit 1
fi

if ! docker run \
    --rm \
    --network "${NETWORK_NAME}" \
    --tmpfs /tmp:exec \
    --env "DEV_ENV_RELEASE_JSON_URL=http://${SERVER_NAME}:8000/releases/latest.json" \
    --env "DEV_ENV_RELEASE_BASE_URL=http://${SERVER_NAME}:8000/releases/download" \
    "${TARGET_IMAGE}" \
    bash "${TEST_SCRIPT}"; then
    echo "containerized tests failed" >&2
    exit 1
fi
