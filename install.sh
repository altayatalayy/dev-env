#!/usr/bin/env bash

REPO="aatalay4/dev-env"

OS="$(uname -s)"
if [ $? -ne 0 ]; then
    echo "failed to detect operating system" >&2
    exit 1
fi

ARCH="$(uname -m)"
if [ $? -ne 0 ]; then
    echo "failed to detect architecture" >&2
    exit 1
fi

case "${OS}" in
    Linux)
        OS="linux"
        ;;
    Darwin)
        OS="macos"
        ;;
    *)
        echo "unsupported operating system: ${OS}" >&2
        exit 1
        ;;
esac

case "${ARCH}" in
    x86_64|aarch64)
        ;;
    arm64)
        ARCH="aarch64"
        ;;
    *)
        echo "unsupported architecture: ${ARCH}" >&2
        exit 1
        ;;
esac

TMP_DIR="$(mktemp -d)"
if [ $? -ne 0 ]; then
    echo "failed to create temporary directory" >&2
    exit 1
fi

cleanup() {
    if ! rm -rf "${TMP_DIR}"; then
        echo "failed to clean temporary directory: ${TMP_DIR}" >&2
    fi
}
trap cleanup EXIT

RELEASE_JSON_URL="${DEV_ENV_RELEASE_JSON_URL:-https://api.github.com/repos/${REPO}/releases/latest}"
RELEASE_JSON="${TMP_DIR}/release.json"
if ! curl --fail --location --show-error --silent \
    "${RELEASE_JSON_URL}" \
    --output "${RELEASE_JSON}"; then
    echo "failed to read latest release metadata" >&2
    exit 1
fi

TAG="$(sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p; t done; b; :done q' "${RELEASE_JSON}")"
if [ -z "${TAG}" ]; then
    echo "latest release metadata did not include tag_name" >&2
    exit 1
fi

VERSION="${TAG#v}"
ASSET_SUFFIX="${OS}-${ARCH}"
BASE_URL_ROOT="${DEV_ENV_RELEASE_BASE_URL:-https://github.com/${REPO}/releases/download}"
BASE_URL="${BASE_URL_ROOT}/${TAG}"

if ! curl --fail --location --show-error \
    "${BASE_URL}/dev-env-${ASSET_SUFFIX}" \
    --output "${TMP_DIR}/dev-env"; then
    echo "failed to download dev-env" >&2
    exit 1
fi

if ! curl --fail --location --show-error \
    "${BASE_URL}/dev-env-install-${ASSET_SUFFIX}" \
    --output "${TMP_DIR}/dev-env-install"; then
    echo "failed to download dev-env-install" >&2
    exit 1
fi

BIN_DIR="${HOME}/.local/bin"
DATA_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}"
INSTALLER_DIR="${DATA_DIR}/dev-env/installers/${VERSION}"

if ! mkdir -p "${BIN_DIR}" "${INSTALLER_DIR}"; then
    echo "failed to create install directories" >&2
    exit 1
fi

if ! chmod 755 "${TMP_DIR}/dev-env" "${TMP_DIR}/dev-env-install"; then
    echo "failed to mark binaries executable" >&2
    exit 1
fi

if ! mv "${TMP_DIR}/dev-env" "${BIN_DIR}/dev-env"; then
    echo "failed to install dev-env" >&2
    exit 1
fi

if ! mv "${TMP_DIR}/dev-env-install" "${INSTALLER_DIR}/dev-env-install"; then
    echo "failed to install dev-env-install" >&2
    exit 1
fi

echo "installed dev-env ${VERSION} to ${BIN_DIR}/dev-env"
