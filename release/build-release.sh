#!/usr/bin/env bash
# Runs inside a builder container. Uses host-built dev-env binaries and builds
# every source-built tool archive for the container's detected distro/version/arch.

SOURCE_DIR="/src"
BUILD_DIR="/build"
RELEASE="${DEV_ENV_RELEASE:-0.1.1}"
RELEASE_DIR="${BUILD_DIR}/releases/download/v${RELEASE}"

if ! mkdir --parents "${BUILD_DIR}/bin" "${RELEASE_DIR}"; then
    echo "failed to create build directories" >&2
    exit 1
fi

if ! cd "${SOURCE_DIR}"; then
    echo "failed to enter source directory" >&2
    exit 1
fi

case "$(uname -s)" in
    Linux)
        OS="linux"
        ;;
    Darwin)
        OS="macos"
        ;;
    *)
        echo "unsupported host operating system for release packaging" >&2
        exit 1
        ;;
esac

case "$(uname -m)" in
    x86_64|amd64)
        ARCH="x86_64"
        ;;
    aarch64|arm64)
        ARCH="aarch64"
        ;;
    *)
        echo "unsupported host architecture for release packaging" >&2
        exit 1
        ;;
esac

ASSET_SUFFIX="${OS}-${ARCH}"
DEV_ENV_BIN="${BUILD_DIR}/host-bin/dev-env-${ASSET_SUFFIX}"
INSTALLER_BIN="${BUILD_DIR}/host-bin/dev-env-install-${ASSET_SUFFIX}"

if [ ! -x "${DEV_ENV_BIN}" ]; then
    echo "missing host-built dev-env binary: ${DEV_ENV_BIN}" >&2
    exit 1
fi

if [ ! -x "${INSTALLER_BIN}" ]; then
    echo "missing host-built dev-env-install binary: ${INSTALLER_BIN}" >&2
    exit 1
fi

if ! cp "${DEV_ENV_BIN}" "${BUILD_DIR}/bin/dev-env"; then
    echo "failed to copy active dev-env binary" >&2
    exit 1
fi

if ! cp "${INSTALLER_BIN}" "${BUILD_DIR}/bin/dev-env-install"; then
    echo "failed to copy active dev-env-install binary" >&2
    exit 1
fi

if ! cp "${DEV_ENV_BIN}" "${RELEASE_DIR}/dev-env-${ASSET_SUFFIX}"; then
    echo "failed to publish dev-env release asset" >&2
    exit 1
fi

if ! cp "${INSTALLER_BIN}" "${RELEASE_DIR}/dev-env-install-${ASSET_SUFFIX}"; then
    echo "failed to publish dev-env-install release asset" >&2
    exit 1
fi

# Build/merge distro-version-arch source archives for all source-built tools on
# this builder. dev-env build auto-detects the platform from /etc/os-release.
if ! "${DEV_ENV_BIN}" build \
    --release-root "${RELEASE_DIR}" \
    --installer-path "${INSTALLER_BIN}"; then
    echo "source archive build failed" >&2
    exit 1
fi

if ! printf '{"tag_name":"v%s"}\n' "${RELEASE}" > "${BUILD_DIR}/releases/latest.json"; then
    echo "failed to write release metadata" >&2
    exit 1
fi
