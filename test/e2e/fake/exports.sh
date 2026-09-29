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
if ! dev_env_prepare_state exports; then exit 1; fi
if ! dev_env_install_fake_release 0.1.0; then exit 1; fi

if ! "${DEV_ENV}" plan --installer 0.1.0 --tools go,rust; then
    echo "plan failed" >&2
    exit 1
fi
if ! "${DEV_ENV}" apply --config-conflict=backup; then
    echo "apply failed" >&2
    exit 1
fi

EXPORTS_OUT="${TEST_HOME}/exports.env"
if ! "${DEV_ENV}" exports > "${EXPORTS_OUT}"; then
    echo "exports command failed" >&2
    exit 1
fi

want_goroot="GOROOT=${XDG_DATA_HOME}/dev-env/tools/go/0.1.0"
want_gopath="GOPATH=${HOME}/.local/share/go"
want_rustup="RUSTUP_HOME=${HOME}/.local/share/rustup"
want_cargo="CARGO_HOME=${HOME}/.local/share/cargo"

if ! grep --fixed-strings --line-regexp "${want_goroot}" "${EXPORTS_OUT}" >/dev/null; then
    echo "GOROOT export missing" >&2
    exit 1
fi
if ! grep --fixed-strings --line-regexp "${want_gopath}" "${EXPORTS_OUT}" >/dev/null; then
    echo "GOPATH export missing" >&2
    exit 1
fi
if ! grep --fixed-strings --line-regexp "${want_rustup}" "${EXPORTS_OUT}" >/dev/null; then
    echo "RUSTUP_HOME export missing" >&2
    exit 1
fi
if ! grep --fixed-strings --line-regexp "${want_cargo}" "${EXPORTS_OUT}" >/dev/null; then
    echo "CARGO_HOME export missing" >&2
    exit 1
fi

PATH_LINE="$(grep '^PATH=' "${EXPORTS_OUT}")"
case ":${PATH_LINE#PATH=}:" in
    *":${HOME}/.local/share/cargo/bin:"*) ;;
    *) echo "cargo bin path missing from PATH export" >&2; exit 1 ;;
esac
case ":${PATH_LINE#PATH=}:" in
    *":${XDG_DATA_HOME}/dev-env/tools/go/0.1.0/bin:"*) ;;
    *) echo "go bin path missing from PATH export" >&2; exit 1 ;;
esac
case ":${PATH_LINE#PATH=}:" in
    *":${HOME}/.local/bin:"*) ;;
    *) echo "layout bin path missing from PATH export" >&2; exit 1 ;;
esac

(
    while IFS='=' read -r name value; do
        export "${name}=${value}"
    done < "${EXPORTS_OUT}"

    if [ "${GOROOT}" != "${XDG_DATA_HOME}/dev-env/tools/go/0.1.0" ]; then
        echo "GOROOT was not consumable by shell loop" >&2
        exit 1
    fi
    if [ "${CARGO_HOME}" != "${HOME}/.local/share/cargo" ]; then
        echo "CARGO_HOME was not consumable by shell loop" >&2
        exit 1
    fi
)

echo "exports fake e2e tests passed"
