#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
if [ $? -ne 0 ]; then
    echo "failed to locate integration script directory" >&2
    exit 1
fi

if ! . "${SCRIPT_DIR}/common.sh"; then
    echo "failed to load integration helpers" >&2
    exit 1
fi

if ! dev_env_require_binaries; then
    exit 1
fi

if ! dev_env_prepare_state smoke; then
    exit 1
fi

if ! dev_env_install_release; then
    exit 1
fi

PLAN_OUT="${TEST_HOME}/plan.out"
if ! "${DEV_ENV}" plan --installer "${RELEASE}" --tools tmux > "${PLAN_OUT}"; then
    echo "dev-env plan failed with installer release" >&2
    exit 1
fi

if ! test -f "${XDG_DATA_HOME}/dev-env/lock.json"; then
    echo "dev-env plan did not write lock.json" >&2
    exit 1
fi

if ! grep --fixed-strings '"installer_path"' "${XDG_DATA_HOME}/dev-env/lock.json" >/dev/null; then
    echo "lock.json did not record installer_path" >&2
    exit 1
fi

if ! grep --fixed-strings 'tmux' "${XDG_DATA_HOME}/dev-env/lock.json" >/dev/null; then
    echo "dev-env plan did not record tmux in lock.json" >&2
    exit 1
fi

if ! "${DEV_ENV}" doctor; then
    echo "dev-env doctor failed from recorded state" >&2
    exit 1
fi

DOTFILES_REQUEST="${TEST_HOME}/extract-dotfiles-request.json"
DOTFILES_OUT="${TEST_HOME}/extract-dotfiles.jsonl"
if ! printf '{"protocol":1,"dest":"%s"}\n' "${DOTFILES_DEST}" > "${DOTFILES_REQUEST}"; then
    echo "failed to write dotfiles extraction request" >&2
    exit 1
fi

if ! "${INSTALLER}" extract-dotfiles < "${DOTFILES_REQUEST}" > "${DOTFILES_OUT}"; then
    echo "dotfiles extraction failed" >&2
    exit 1
fi

if ! test -f "${DOTFILES_DEST}/tmux/.config/tmux/tmux.conf"; then
    echo "tmux dotfiles package was not extracted with the expected layout" >&2
    exit 1
fi

if ! test -f "${DOTFILES_DEST}/shell/.zshenv"; then
    echo "shell dotfiles package was not extracted with the expected layout" >&2
    exit 1
fi

if ! grep --fixed-strings '"command":"extract-dotfiles"' "${DOTFILES_OUT}" >/dev/null; then
    echo "dotfiles extraction response has the wrong command" >&2
    exit 1
fi

echo "smoke integration tests passed"
