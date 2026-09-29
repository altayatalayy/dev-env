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
if ! dev_env_prepare_state clean-uninstall; then exit 1; fi
if ! dev_env_install_fake_release 0.1.0; then exit 1; fi
if ! dev_env_install_fake_release 0.2.0; then exit 1; fi

if ! "${DEV_ENV}" plan --installer 0.1.0 --tools tmux; then
    echo "initial plan failed" >&2
    exit 1
fi
if ! "${DEV_ENV}" apply --config-conflict=backup; then
    echo "initial apply failed" >&2
    exit 1
fi
if ! "${DEV_ENV}" upgrade --config-conflict=backup; then
    echo "upgrade failed" >&2
    exit 1
fi
if ! test -d "${XDG_DATA_HOME}/dev-env/tools/tmux/0.1.0"; then
    echo "old tmux version missing before clean" >&2
    exit 1
fi
if ! test -d "${XDG_DATA_HOME}/dev-env/tools/tmux/0.2.0"; then
    echo "active tmux version missing before clean" >&2
    exit 1
fi
if ! "${DEV_ENV}" clean; then
    echo "clean failed" >&2
    exit 1
fi
if test -d "${XDG_DATA_HOME}/dev-env/tools/tmux/0.1.0"; then
    echo "clean kept inactive tmux version" >&2
    exit 1
fi
if ! test -d "${XDG_DATA_HOME}/dev-env/tools/tmux/0.2.0"; then
    echo "clean removed active tmux version" >&2
    exit 1
fi

# install.sh puts the launcher binaries under <data>/bin/<version>; uninstall
# has to reclaim that tree too, not just the installers.
LAUNCHER_DIR="${XDG_DATA_HOME}/dev-env/bin/0.2.0"
if ! mkdir --parents "${LAUNCHER_DIR}"; then
    echo "failed to stage launcher directory" >&2
    exit 1
fi
if ! cp "${DEV_ENV}" "${LAUNCHER_DIR}/dev-env"; then
    echo "failed to stage launcher binary" >&2
    exit 1
fi

if ! "${DEV_ENV}" uninstall --config-conflict=backup; then
    echo "uninstall failed" >&2
    exit 1
fi
if test -d "${XDG_DATA_HOME}/dev-env/bin"; then
    echo "uninstall kept the launcher directory" >&2
    exit 1
fi
if test -f "${XDG_DATA_HOME}/dev-env/installed.json"; then
    echo "uninstall kept installed.json" >&2
    exit 1
fi
if test -L "${HOME}/.config/tmux/tmux.conf"; then
    echo "uninstall kept tmux config symlink" >&2
    exit 1
fi
if test -e "${HOME}/.local/bin/tmux"; then
    echo "uninstall kept tmux executable link" >&2
    exit 1
fi
if ! test -d "${XDG_DATA_HOME}/dev-env/backups"; then
    echo "uninstall backup policy did not keep backups directory" >&2
    exit 1
fi

echo "clean-uninstall fake e2e tests passed"
