#!/usr/bin/env bash
# Installs (or uninstalls) the dev-env launcher from a release server.
#
# usage:
#   install.sh --release-root-url http://server/releases
#   install.sh --release-root-url http://server/releases --uninstall
#
# The release root must serve:
#   <release-root-url>/latest.json            {"tag_name":"v<version>", ...}
#   <release-root-url>/download/<tag>/...     release assets
#
# Managed, versioned install layout:
#   ~/.local/share/dev-env/bin/<version>/dev-env
#   ~/.local/share/dev-env/installers/<version>/dev-env-install
#   ~/.local/share/dev-env/installers/<version>/release.json
#   ~/.local/bin/dev-env -> ~/.local/share/dev-env/bin/<version>/dev-env

RELEASE_ROOT_URL=""
MODE="install"

while [ $# -gt 0 ]; do
    case "$1" in
        --release-root-url)
            shift
            if [ $# -eq 0 ]; then
                echo "--release-root-url requires a value" >&2
                exit 1
            fi
            RELEASE_ROOT_URL="$1"
            ;;
        --release-root-url=*)
            RELEASE_ROOT_URL="${1#--release-root-url=}"
            ;;
        --uninstall)
            MODE="uninstall"
            ;;
        *)
            echo "unknown argument: $1" >&2
            exit 1
            ;;
    esac
    shift
done

if [ -z "${RELEASE_ROOT_URL}" ]; then
    echo "missing required --release-root-url <url>" >&2
    exit 1
fi
RELEASE_ROOT_URL="${RELEASE_ROOT_URL%/}"

DATA_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}"
STATE_DIR="${DATA_DIR}/dev-env"
BIN_DIR="${HOME}/.local/bin"
LAUNCHER="${BIN_DIR}/dev-env"

# --- uninstall ---------------------------------------------------------------

if [ "${MODE}" = "uninstall" ]; then
    # Only remove the launcher if it is a symlink pointing into managed state;
    # never touch unrelated regular files or symlinks outside dev-env state.
    if [ -L "${LAUNCHER}" ]; then
        TARGET="$(readlink -f "${LAUNCHER}" 2>/dev/null)"
        case "${TARGET}" in
            "${STATE_DIR}"/*)
                if ! rm -f "${LAUNCHER}"; then
                    echo "failed to remove ${LAUNCHER}" >&2
                    exit 1
                fi
                echo "removed launcher ${LAUNCHER}"
                ;;
            *)
                echo "leaving ${LAUNCHER}: not a dev-env-managed symlink" >&2
                ;;
        esac
    elif [ -e "${LAUNCHER}" ]; then
        echo "leaving ${LAUNCHER}: not a symlink into dev-env state" >&2
    fi

    if [ -d "${STATE_DIR}" ]; then
        if ! rm -rf "${STATE_DIR}"; then
            echo "failed to remove ${STATE_DIR}" >&2
            exit 1
        fi
        echo "removed managed state ${STATE_DIR}"
    fi
    exit 0
fi

# --- platform detection ------------------------------------------------------

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
    Linux) OS="linux" ;;
    Darwin) OS="macos" ;;
    *)
        echo "unsupported operating system: ${OS}" >&2
        exit 1
        ;;
esac

case "${ARCH}" in
    x86_64|aarch64) ;;
    arm64) ARCH="aarch64" ;;
    *)
        echo "unsupported architecture: ${ARCH}" >&2
        exit 1
        ;;
esac
ASSET_SUFFIX="${OS}-${ARCH}"

# --- temp workspace ----------------------------------------------------------

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

# --- resolve release ---------------------------------------------------------

LATEST_JSON="${TMP_DIR}/latest.json"
if ! curl --fail --location --show-error --silent \
    "${RELEASE_ROOT_URL}/latest.json" \
    --output "${LATEST_JSON}"; then
    echo "failed to read ${RELEASE_ROOT_URL}/latest.json" >&2
    exit 1
fi

TAG="$(sed -n 's/.*"tag_name" *: *"\([^"]*\)".*/\1/p' "${LATEST_JSON}" | head -n 1)"
if [ -z "${TAG}" ]; then
    echo "latest.json did not include tag_name" >&2
    exit 1
fi
VERSION="${TAG#v}"

DOWNLOAD_URL="${RELEASE_ROOT_URL}/download/${TAG}"

if ! curl --fail --location --show-error \
    "${DOWNLOAD_URL}/dev-env-${ASSET_SUFFIX}" \
    --output "${TMP_DIR}/dev-env"; then
    echo "failed to download dev-env-${ASSET_SUFFIX}" >&2
    exit 1
fi

if ! curl --fail --location --show-error \
    "${DOWNLOAD_URL}/dev-env-install-${ASSET_SUFFIX}" \
    --output "${TMP_DIR}/dev-env-install"; then
    echo "failed to download dev-env-install-${ASSET_SUFFIX}" >&2
    exit 1
fi

# --- install into versioned layout -------------------------------------------

VERSION_BIN_DIR="${STATE_DIR}/bin/${VERSION}"
INSTALLER_DIR="${STATE_DIR}/installers/${VERSION}"

if ! mkdir -p "${BIN_DIR}" "${VERSION_BIN_DIR}" "${INSTALLER_DIR}"; then
    echo "failed to create install directories" >&2
    exit 1
fi

if ! chmod 755 "${TMP_DIR}/dev-env" "${TMP_DIR}/dev-env-install"; then
    echo "failed to mark binaries executable" >&2
    exit 1
fi

if ! mv "${TMP_DIR}/dev-env" "${VERSION_BIN_DIR}/dev-env"; then
    echo "failed to install dev-env" >&2
    exit 1
fi

if ! mv "${TMP_DIR}/dev-env-install" "${INSTALLER_DIR}/dev-env-install"; then
    echo "failed to install dev-env-install" >&2
    exit 1
fi

if ! printf '{"tag_name":"%s","release_root_url":"%s"}\n' \
    "${TAG}" "${RELEASE_ROOT_URL}" > "${INSTALLER_DIR}/release.json"; then
    echo "failed to write release.json sidecar" >&2
    exit 1
fi

# Point the launcher at the freshly installed version.
if ! ln -sfn "${VERSION_BIN_DIR}/dev-env" "${LAUNCHER}"; then
    echo "failed to link ${LAUNCHER}" >&2
    exit 1
fi

echo "installed dev-env ${VERSION}"
echo "  launcher:  ${LAUNCHER} -> ${VERSION_BIN_DIR}/dev-env"
echo "  installer: ${INSTALLER_DIR}/dev-env-install"
