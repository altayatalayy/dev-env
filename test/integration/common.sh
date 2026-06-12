#!/usr/bin/env bash

# Common helpers for fast integration tests. These tests use a protocol-compatible
# fake installer so they exercise the real dev-env lifecycle without downloading
# or building external tools.

dev_env_script_dir() {
    cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 || return 1
    pwd
}

dev_env_repo_root() {
    local script_dir
    script_dir="$(dev_env_script_dir)" || return 1
    cd "${script_dir}/../.." >/dev/null 2>&1 || return 1
    pwd
}

dev_env_bin_dir() {
    if [ -n "${DEV_ENV_BIN_DIR:-}" ]; then
        printf '%s\n' "${DEV_ENV_BIN_DIR}"
        return 0
    fi
    if [ -x /opt/dev-env/bin/dev-env ]; then
        printf '%s\n' /opt/dev-env/bin
        return 0
    fi

    local repo_root
    repo_root="$(dev_env_repo_root)" || return 1
    printf '%s\n' "${repo_root}/zig-out/bin"
}

dev_env_prepare_state() {
    if [ "$#" -ne 1 ]; then
        echo "dev_env_prepare_state requires a test name" >&2
        return 1
    fi

    TEST_HOME="/tmp/dev-env-test-$1"
    XDG_CACHE_HOME="${TEST_HOME}/.cache"
    XDG_DATA_HOME="${TEST_HOME}/.local/share"
    DOTFILES_DEST="/tmp/dev-env-test-dotfiles-$1"

    if ! rm --recursive --force "${TEST_HOME}" "${DOTFILES_DEST}"; then
        echo "failed to clean previous test state" >&2
        return 1
    fi

    if ! mkdir --parents "${XDG_CACHE_HOME}" "${XDG_DATA_HOME}" "${TEST_HOME}/.local/bin"; then
        echo "failed to create test home" >&2
        return 1
    fi

    export HOME="${TEST_HOME}"
    export XDG_CACHE_HOME
    export XDG_DATA_HOME
    export PATH="${BIN_DIR}:${TEST_HOME}/.local/bin:${PATH}"
}

dev_env_require_binaries() {
    BIN_DIR="$(dev_env_bin_dir)" || {
        echo "failed to locate dev-env binaries" >&2
        return 1
    }
    DEV_ENV="${BIN_DIR}/dev-env"
    INSTALLER="${BIN_DIR}/dev-env-install"

    if ! test -x "${DEV_ENV}"; then
        echo "missing CLI binary: ${DEV_ENV}" >&2
        return 1
    fi
    if [ -e "${INSTALLER}" ] && ! test -x "${INSTALLER}"; then
        echo "installer exists but is not executable: ${INSTALLER}" >&2
        return 1
    fi
}

dev_env_install_release() {
    if ! test -x "${INSTALLER}"; then
        echo "missing installer binary: ${INSTALLER}" >&2
        return 1
    fi

    local metadata_out="${TEST_HOME}/metadata.jsonl"
    if ! "${INSTALLER}" metadata > "${metadata_out}"; then
        echo "installer metadata command failed" >&2
        return 1
    fi

    RELEASE="$(python3 - <<'PY2' "${metadata_out}"
import json, sys
for line in open(sys.argv[1], encoding='utf-8'):
    if not line.strip():
        continue
    msg = json.loads(line)
    if msg.get('kind') == 'response':
        print(msg['response']['release'])
        break
PY2
)"
    if [ -z "${RELEASE}" ]; then
        echo "installer metadata did not include a release" >&2
        return 1
    fi

    local installer_dir="${XDG_DATA_HOME}/dev-env/installers/${RELEASE}"
    if ! mkdir --parents "${installer_dir}"; then
        echo "failed to create installer state directory" >&2
        return 1
    fi
    if ! cp "${INSTALLER}" "${installer_dir}/dev-env-install"; then
        echo "failed to install test installer" >&2
        return 1
    fi
}

dev_env_fake_installer() {
    local script_dir
    script_dir="$(dev_env_script_dir)" || return 1
    printf '%s\n' "${script_dir}/fake_installer.py"
}

dev_env_install_fake_release() {
    if [ "$#" -ne 1 ]; then
        echo "dev_env_install_fake_release requires a release" >&2
        return 1
    fi
    RELEASE="$1"
    INSTALLER="${XDG_DATA_HOME}/dev-env/installers/${RELEASE}/dev-env-install"
    if ! mkdir --parents "$(dirname "${INSTALLER}")"; then
        echo "failed to create fake installer directory" >&2
        return 1
    fi
    if ! cp "$(dev_env_fake_installer)" "${INSTALLER}"; then
        echo "failed to copy fake installer" >&2
        return 1
    fi
    if ! chmod +x "${INSTALLER}"; then
        echo "failed to mark fake installer executable" >&2
        return 1
    fi
}

dev_env_json_assert() {
    local script_dir
    script_dir="$(dev_env_script_dir)" || return 1
    python3 "${script_dir}/json_assert.py" "$@"
}

dev_env_csv() {
    local out=""
    local value
    for value in "$@"; do
        if [ -z "${out}" ]; then
            out="${value}"
        else
            out="${out},${value}"
        fi
    done
    printf '%s\n' "${out}"
}
