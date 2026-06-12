#!/usr/bin/env bash
# Host-side release builder. Builds every release artifact for every supported
# Linux distro/version/arch builder plus cross-compiled macOS CLI binaries.
#
# Output: ./build/releases/download/v${DEV_ENV_RELEASE:-0.1.0}/

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

BUILD_DIR="${REPO_ROOT}/build"
RELEASE="${DEV_ENV_RELEASE:-0.1.0}"

if ! mkdir --parents "${BUILD_DIR}"; then
    echo "failed to create build directory" >&2
    exit 1
fi

build_and_run() {
    DISTRO="$1"
    VERSION="$2"
    DOCKER_PLATFORM="$3"
    ZIG_ARCH="$4"
    BUILD_MACOS="$5"

    DOCKERFILE="${REPO_ROOT}/containers/release/Dockerfile.builder.${DISTRO}"
    IMAGE="dev-env-builder:${DISTRO}-${VERSION}-${ZIG_ARCH}"

    echo "==> building ${DISTRO} ${VERSION} ${ZIG_ARCH} builder"
    if [ "${DISTRO}" = "ubuntu" ]; then
        if ! docker build \
            --platform "${DOCKER_PLATFORM}" \
            --file "${DOCKERFILE}" \
            --build-arg "UBUNTU_VERSION=${VERSION}" \
            --build-arg "ZIG_ARCH=${ZIG_ARCH}" \
            --tag "${IMAGE}" \
            "${REPO_ROOT}"; then
            echo "builder image build failed: ${IMAGE}" >&2
            exit 1
        fi
    elif [ "${DISTRO}" = "fedora" ]; then
        if ! docker build \
            --platform "${DOCKER_PLATFORM}" \
            --file "${DOCKERFILE}" \
            --build-arg "FEDORA_VERSION=${VERSION}" \
            --build-arg "ZIG_ARCH=${ZIG_ARCH}" \
            --tag "${IMAGE}" \
            "${REPO_ROOT}"; then
            echo "builder image build failed: ${IMAGE}" >&2
            exit 1
        fi
    else
        echo "unknown builder distro: ${DISTRO}" >&2
        exit 1
    fi

    echo "==> running ${DISTRO} ${VERSION} ${ZIG_ARCH} release build"
    if ! docker run \
        --rm \
        --platform "${DOCKER_PLATFORM}" \
        --volume "${BUILD_DIR}:/build" \
        --env "DEV_ENV_RELEASE=${RELEASE}" \
        --env "DEV_ENV_BUILD_MACOS=${BUILD_MACOS}" \
        "${IMAGE}"; then
        echo "release build container failed: ${IMAGE}" >&2
        exit 1
    fi
}

# Linux source archives are distro/version/arch specific. Build all supported
# Linux targets. macOS assets are cross-compiled once from the first x86_64
# builder because macOS tools are installed through Homebrew at runtime.
build_and_run ubuntu 24.04 linux/amd64 x86_64 1
build_and_run ubuntu 24.04 linux/arm64 aarch64 0
build_and_run ubuntu 26.04 linux/amd64 x86_64 0
build_and_run ubuntu 26.04 linux/arm64 aarch64 0
build_and_run fedora 44 linux/amd64 x86_64 0
build_and_run fedora 44 linux/arm64 aarch64 0
