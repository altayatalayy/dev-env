#!/usr/bin/env bash
# Runs inside a builder container. Builds the release installer/CLI, publishes
# native Linux assets, optionally cross-compiles macOS assets, and builds every
# source-built tool archive for the container's detected distro/version/arch.

SOURCE_DIR="/src"
BUILD_DIR="/build"
RELEASE="${DEV_ENV_RELEASE:-0.1.0}"
RELEASE_DIR="${BUILD_DIR}/releases/download/v${RELEASE}"
BUILD_MACOS="${DEV_ENV_BUILD_MACOS:-0}"

if ! mkdir --parents "${BUILD_DIR}/bin" "${RELEASE_DIR}"; then
    echo "failed to create build directories" >&2
    exit 1
fi

if ! cd "${SOURCE_DIR}"; then
    echo "failed to enter source directory" >&2
    exit 1
fi

if ! zig build -Drelease="${RELEASE}" -Doptimize=ReleaseSafe; then
    echo "native zig build failed in builder container" >&2
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

if ! cp /src/zig-out/bin/dev-env "${BUILD_DIR}/bin/dev-env"; then
    echo "failed to copy dev-env binary" >&2
    exit 1
fi

if ! cp /src/zig-out/bin/dev-env-install "${BUILD_DIR}/bin/dev-env-install"; then
    echo "failed to copy dev-env-install binary" >&2
    exit 1
fi

if ! cp /src/zig-out/bin/dev-env "${RELEASE_DIR}/dev-env-${ASSET_SUFFIX}"; then
    echo "failed to publish dev-env release asset" >&2
    exit 1
fi

if ! cp /src/zig-out/bin/dev-env-install "${RELEASE_DIR}/dev-env-install-${ASSET_SUFFIX}"; then
    echo "failed to publish dev-env-install release asset" >&2
    exit 1
fi

if [ "${BUILD_MACOS}" = "1" ]; then
    for TARGET in x86_64-macos aarch64-macos; do
        case "${TARGET}" in
            x86_64-macos) MAC_ARCH="x86_64" ;;
            aarch64-macos) MAC_ARCH="aarch64" ;;
            *) echo "unknown macOS target: ${TARGET}" >&2; exit 1 ;;
        esac

        PREFIX="/tmp/dev-env-${TARGET}"
        if ! rm --recursive --force "${PREFIX}"; then
            echo "failed to remove old macOS prefix: ${PREFIX}" >&2
            exit 1
        fi

        if ! zig build \
            -Drelease="${RELEASE}" \
            -Dtarget="${TARGET}" \
            -Doptimize=ReleaseSafe \
            --prefix "${PREFIX}"; then
            echo "macOS cross build failed: ${TARGET}" >&2
            exit 1
        fi

        if ! cp "${PREFIX}/bin/dev-env" "${RELEASE_DIR}/dev-env-macos-${MAC_ARCH}"; then
            echo "failed to publish macOS dev-env asset: ${MAC_ARCH}" >&2
            exit 1
        fi
        if ! cp "${PREFIX}/bin/dev-env-install" "${RELEASE_DIR}/dev-env-install-macos-${MAC_ARCH}"; then
            echo "failed to publish macOS dev-env-install asset: ${MAC_ARCH}" >&2
            exit 1
        fi
    done
fi

# Build/merge distro-version-arch source archives for all source-built tools on
# this builder. dev-env build auto-detects the platform from /etc/os-release.
if ! /src/zig-out/bin/dev-env build \
    --release-root "${RELEASE_DIR}" \
    --installer-path /src/zig-out/bin/dev-env-install; then
    echo "source archive build failed" >&2
    exit 1
fi

if ! printf '{"tag_name":"v%s"}\n' "${RELEASE}" > "${BUILD_DIR}/releases/latest.json"; then
    echo "failed to write release metadata" >&2
    exit 1
fi
