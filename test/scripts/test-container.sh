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

TEST_SCRIPT="${1:-/opt/dev-env-test/e2e/fake/run.sh}"
TEST_TARGETS="${TEST_TARGETS:-ubuntu-24.04-x86_64 ubuntu-26.04-x86_64 fedora-44-x86_64}"
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

BUILD_IMAGE="dev-env-test-builder:zig-0.16"
BUILD_BIN_DIR="${REPO_ROOT}/build/test-bin"
RELEASE="${DEV_ENV_RELEASE:-0.1.0}"
ZIG_CLI_DIR="${REPO_ROOT}/../zig-cli"
ZIG_GRAPH_DIR="${REPO_ROOT}/../zig-graph"

if ! mkdir --parents "${BUILD_BIN_DIR}"; then
    echo "failed to create test binary directory" >&2
    exit 1
fi

if [ ! -d "${ZIG_CLI_DIR}" ]; then
    echo "missing local Zig CLI library: ${ZIG_CLI_DIR}" >&2
    exit 1
fi

if [ ! -d "${ZIG_GRAPH_DIR}" ]; then
    echo "missing local Zig graph library: ${ZIG_GRAPH_DIR}" >&2
    exit 1
fi

if ! docker build \
    --platform linux/amd64 \
    --file "${REPO_ROOT}/containers/test/Dockerfile.builder" \
    --tag "${BUILD_IMAGE}" \
    --build-context "zig_cli=${ZIG_CLI_DIR}" \
    --build-context "zig_graph=${ZIG_GRAPH_DIR}" \
    "${REPO_ROOT}"; then
    echo "test builder image build failed" >&2
    exit 1
fi

TEST_ARCHES=""
for target in ${TEST_TARGETS}; do
    ARCH="$(printf '%s' "${target}" | cut --delimiter=- --fields=3)"
    case " ${TEST_ARCHES} " in
        *" ${ARCH} "*) ;;
        *) TEST_ARCHES="${TEST_ARCHES} ${ARCH}" ;;
    esac
done

if ! docker run \
    --rm \
    --volume "${BUILD_BIN_DIR}:/out" \
    --env "DEV_ENV_RELEASE=${RELEASE}" \
    --env "DEV_ENV_TEST_ARCHES=${TEST_ARCHES}" \
    "${BUILD_IMAGE}" \
    bash -c '
        zig build test || exit 1
        for arch in ${DEV_ENV_TEST_ARCHES}; do
            case "${arch}" in
                x86_64) zig_target=x86_64-linux-gnu ;;
                aarch64) zig_target=aarch64-linux-gnu ;;
                *) echo "unknown arch: ${arch}" >&2; exit 1 ;;
            esac
            prefix="/tmp/dev-env-test-prefix-${arch}"
            rm --recursive --force "${prefix}" || exit 1
            zig build -Drelease="${DEV_ENV_RELEASE}" -Dtarget="${zig_target}" -Doptimize=Debug --prefix "${prefix}" || exit 1
            mkdir --parents "/out/${arch}" || exit 1
            cp "${prefix}/bin/dev-env" "/out/${arch}/dev-env" || exit 1
            cp "${prefix}/bin/dev-env-install" "/out/${arch}/dev-env-install" || exit 1
        done
    '; then
    echo "test binary build failed" >&2
    exit 1
fi

run_target() {
    TARGET="$1"
    DISTRO="$(printf '%s' "${TARGET}" | cut --delimiter=- --fields=1)"
    VERSION="$(printf '%s' "${TARGET}" | cut --delimiter=- --fields=2)"
    ARCH="$(printf '%s' "${TARGET}" | cut --delimiter=- --fields=3)"

    case "${ARCH}" in
        x86_64)
            DOCKER_PLATFORM=linux/amd64
            ;;
        aarch64)
            DOCKER_PLATFORM=linux/arm64
            ;;
        *)
            echo "unsupported test target arch: ${TARGET}" >&2
            return 1
            ;;
    esac

    case "${DISTRO}" in
        ubuntu)
            DOCKERFILE="${REPO_ROOT}/containers/test/Dockerfile.ubuntu"
            BUILD_ARGS=(--build-arg "UBUNTU_VERSION=${VERSION}")
            ;;
        fedora)
            DOCKERFILE="${REPO_ROOT}/containers/test/Dockerfile.fedora"
            BUILD_ARGS=(--build-arg "FEDORA_VERSION=${VERSION}")
            ;;
        *)
            echo "unsupported test target: ${TARGET}" >&2
            return 1
            ;;
    esac

    TARGET_IMAGE="dev-env-test-${TARGET}:zig-0.16"
    echo "==> building ${TARGET} test image"
    if ! docker build \
        --platform "${DOCKER_PLATFORM}" \
        --file "${DOCKERFILE}" \
        --tag "${TARGET_IMAGE}" \
        --build-arg "TEST_UID=${TEST_UID}" \
        --build-arg "TEST_GID=${TEST_GID}" \
        "${BUILD_ARGS[@]}" \
        "${REPO_ROOT}"; then
        echo "target image build failed: ${TARGET}" >&2
        return 1
    fi

    echo "==> running tests on ${TARGET}"
    if ! docker run \
        --rm \
        --platform "${DOCKER_PLATFORM}" \
        --tmpfs /tmp:exec \
        --volume "${BUILD_BIN_DIR}/${ARCH}:/opt/dev-env/bin:ro" \
        --volume "${REPO_ROOT}/test:/opt/dev-env-test:ro" \
        --volume "${REPO_ROOT}/install.sh:/opt/dev-env-install.sh:ro" \
        --env "DEV_ENV_BIN_DIR=/opt/dev-env/bin" \
        --env "DEV_ENV_E2E_TESTS=${DEV_ENV_E2E_TESTS:-}" \
        --env "DEV_ENV_RELEASE_ROOT_URL=${DEV_ENV_RELEASE_ROOT_URL:-}" \
        --env "DEV_ENV_TEST_TARGET=${TARGET}" \
        "${TARGET_IMAGE}" \
        bash "${TEST_SCRIPT}"; then
        echo "containerized tests failed: ${TARGET}" >&2
        return 1
    fi
}

for target in ${TEST_TARGETS}; do
    if ! run_target "${target}"; then
        exit 1
    fi
done

echo "container matrix passed: ${TEST_TARGETS}"
