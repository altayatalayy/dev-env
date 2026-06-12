#!/usr/bin/env bash

SOURCE_DIR="/src"
BUILD_DIR="/build"
RELEASE="${DEV_ENV_RELEASE:-0.1.0}"

if ! mkdir --parents "${BUILD_DIR}/bin" "${BUILD_DIR}/releases/download/v${RELEASE}"; then
    echo "failed to create build directories" >&2
    exit 1
fi

if ! cd "${SOURCE_DIR}"; then
    echo "failed to enter source directory" >&2
    exit 1
fi

if ! zig build -Drelease="${RELEASE}" -Ddotfiles-dir=test/dotfiles; then
    echo "zig build failed in builder container" >&2
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
RELEASE_DIR="${BUILD_DIR}/releases/download/v${RELEASE}"

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

if ! printf '{"tag_name":"v%s"}\n' "${RELEASE}" > "${BUILD_DIR}/releases/latest.json"; then
    echo "failed to write release metadata" >&2
    exit 1
fi
