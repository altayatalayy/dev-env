#!/usr/bin/env bash
# Host-side release builder. Builds dev-env binaries on the host, then runs
# distro/version/arch builders only for source-built tool archives.
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
HOST_BIN_DIR="${BUILD_DIR}/host-bin"

if ! mkdir --parents "${HOST_BIN_DIR}"; then
    echo "failed to create build directory" >&2
    exit 1
fi

build_zig_target() {
    TARGET="$1"
    OS="$2"
    ARCH="$3"

    ASSET_SUFFIX="${OS}-${ARCH}"
    PREFIX="${BUILD_DIR}/zig-prefix/${ASSET_SUFFIX}"

    echo "==> building dev-env ${ASSET_SUFFIX} on host"
    if ! rm --recursive --force "${PREFIX}"; then
        echo "failed to remove old build prefix: ${PREFIX}" >&2
        exit 1
    fi

    if [ "${TARGET}" = "native" ]; then
        if ! zig build \
            -Drelease="${RELEASE}" \
            -Doptimize=ReleaseSafe \
            --prefix "${PREFIX}"; then
            echo "host zig build failed: ${ASSET_SUFFIX}" >&2
            exit 1
        fi
    else
        if ! zig build \
            -Drelease="${RELEASE}" \
            -Dtarget="${TARGET}" \
            -Doptimize=ReleaseSafe \
            --prefix "${PREFIX}"; then
            echo "host zig cross build failed: ${TARGET}" >&2
            exit 1
        fi
    fi

    if ! cp "${PREFIX}/bin/dev-env" "${HOST_BIN_DIR}/dev-env-${ASSET_SUFFIX}"; then
        echo "failed to stage dev-env binary: ${ASSET_SUFFIX}" >&2
        exit 1
    fi

    if ! cp "${PREFIX}/bin/dev-env-install" "${HOST_BIN_DIR}/dev-env-install-${ASSET_SUFFIX}"; then
        echo "failed to stage dev-env-install binary: ${ASSET_SUFFIX}" >&2
        exit 1
    fi
}

build_and_run() {
    DISTRO="$1"
    VERSION="$2"
    DOCKER_PLATFORM="$3"
    ZIG_ARCH="$4"

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
        "${IMAGE}"; then
        echo "release build container failed: ${IMAGE}" >&2
        exit 1
    fi
}

build_zig_target native linux x86_64

# Keep these host-side cross builds ready for release publishing once needed.
# build_zig_target aarch64-linux linux aarch64
# build_zig_target x86_64-macos macos x86_64
# build_zig_target aarch64-macos macos aarch64

# Linux source archives are distro/version/arch specific. Build all supported
# Linux targets. Arm builders are disabled for now to keep release builds fast.
build_and_run ubuntu 24.04 linux/amd64 x86_64
# build_and_run ubuntu 24.04 linux/arm64 aarch64
build_and_run ubuntu 26.04 linux/amd64 x86_64
# build_and_run ubuntu 26.04 linux/arm64 aarch64
build_and_run fedora 44 linux/amd64 x86_64
# build_and_run fedora 44 linux/arm64 aarch64
