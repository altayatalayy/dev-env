#!/usr/bin/env bash

if ! SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"; then
    echo "failed to locate fake e2e script directory" >&2
    exit 1
fi
if ! . "${SCRIPT_DIR}/common.sh"; then
    echo "failed to load fake e2e helpers" >&2
    exit 1
fi

if ! dev_env_require_binaries; then exit 1; fi

prepare_case() {
    if ! dev_env_prepare_state "config-conflicts-$1"; then return 1; fi
    if ! dev_env_install_fake_release 0.1.0; then return 1; fi
    if ! "${DEV_ENV}" plan --installer 0.1.0 --tools tmux; then
        echo "plan failed for config conflict case $1" >&2
        return 1
    fi
}

if ! prepare_case fail-file; then exit 1; fi
if ! mkdir --parents "${HOME}/.config/tmux"; then exit 1; fi
if ! printf '%s\n' "local tmux config" > "${HOME}/.config/tmux/tmux.conf"; then exit 1; fi
if "${DEV_ENV}" apply --config-conflict=fail; then
    echo "file conflict did not fail with fail policy" >&2
    exit 1
fi
if ! grep --fixed-strings "local tmux config" "${HOME}/.config/tmux/tmux.conf" >/dev/null; then
    echo "fail policy changed the local file" >&2
    exit 1
fi
if test -f "${XDG_DATA_HOME}/dev-env/installed.json"; then
    echo "fail policy wrote installed.json" >&2
    exit 1
fi

if ! prepare_case backup-file; then exit 1; fi
if ! mkdir --parents "${HOME}/.config/tmux"; then exit 1; fi
if ! printf '%s\n' "local tmux config" > "${HOME}/.config/tmux/tmux.conf"; then exit 1; fi
if ! "${DEV_ENV}" apply --config-conflict=backup; then
    echo "backup policy failed" >&2
    exit 1
fi
if ! find "${XDG_DATA_HOME}/dev-env/backups" -type f -path '*/home/.config/tmux/tmux.conf' | grep . >/dev/null; then
    echo "backup policy did not save the local file" >&2
    exit 1
fi
if ! test -f "${HOME}/.config/tmux/tmux.conf"; then
    echo "backup policy did not stow the config" >&2
    exit 1
fi
# A managed symlink must not be treated as a conflict on the next apply.
if ! "${DEV_ENV}" apply --config-conflict=fail; then
    echo "managed symlink was treated as a conflict" >&2
    exit 1
fi

if ! prepare_case skip-file; then exit 1; fi
if ! mkdir --parents "${HOME}/.config/tmux"; then exit 1; fi
if ! printf '%s\n' "local tmux config" > "${HOME}/.config/tmux/tmux.conf"; then exit 1; fi
if ! "${DEV_ENV}" apply --config-conflict=skip; then
    echo "skip policy failed" >&2
    exit 1
fi
if ! grep --fixed-strings "local tmux config" "${HOME}/.config/tmux/tmux.conf" >/dev/null; then
    echo "skip policy changed the local file" >&2
    exit 1
fi
if ! dev_env_json_assert contains "${XDG_DATA_HOME}/dev-env/installed.json" skipped_configs tmux-config; then exit 1; fi

# A locally modified managed config kept by the skip policy must stay linked:
# dropping its stow-source entry would leave the $HOME symlinks dangling.
if ! prepare_case skip-modified; then exit 1; fi
if ! "${DEV_ENV}" apply --config-conflict=fail; then
    echo "initial apply failed" >&2
    exit 1
fi
if ! printf '%s\n' "my own tmux settings" > "${HOME}/.config/tmux/tmux.conf"; then exit 1; fi
if ! "${DEV_ENV}" plan --installer 0.1.0 --add neovim >/dev/null; then
    echo "plan --add failed" >&2
    exit 1
fi
if ! "${DEV_ENV}" apply --config-conflict=skip; then
    echo "skip policy failed for a modified managed config" >&2
    exit 1
fi
if ! grep --fixed-strings "my own tmux settings" "${HOME}/.config/tmux/tmux.conf" >/dev/null; then
    echo "skip policy left the modified config unreadable" >&2
    exit 1
fi
if ! test -e "${XDG_DATA_HOME}/dev-env/stow-source/tmux"; then
    echo "skip policy removed the stow-source entry of a stowed package" >&2
    exit 1
fi
if ! dev_env_json_assert contains "${XDG_DATA_HOME}/dev-env/installed.json" stow_packages tmux; then exit 1; fi

if ! prepare_case fail-dir; then exit 1; fi
if ! mkdir --parents "${HOME}/.config/tmux/tmux.conf"; then exit 1; fi
if "${DEV_ENV}" apply --config-conflict=fail; then
    echo "directory conflict did not fail" >&2
    exit 1
fi

if ! prepare_case fail-symlink; then exit 1; fi
if ! mkdir --parents "${HOME}/.config/tmux"; then exit 1; fi
if ! printf '%s\n' "foreign" > "${TEST_HOME}/foreign-tmux.conf"; then exit 1; fi
if ! ln --symbolic "${TEST_HOME}/foreign-tmux.conf" "${HOME}/.config/tmux/tmux.conf"; then exit 1; fi
if "${DEV_ENV}" apply --config-conflict=fail; then
    echo "foreign symlink conflict did not fail" >&2
    exit 1
fi

echo "config-conflicts fake e2e tests passed"
