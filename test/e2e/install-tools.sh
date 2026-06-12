#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
if [ $? -ne 0 ]; then
    echo "failed to locate e2e script directory" >&2
    exit 1
fi

if ! . "${SCRIPT_DIR}/../integration/common.sh"; then
    echo "failed to load test helpers" >&2
    exit 1
fi

if [ "$#" -eq 0 ]; then
    echo "usage: install-tools.sh <tool> [tool...]" >&2
    exit 1
fi

TOOLS_CSV="$(dev_env_csv "$@")"
TEST_NAME="install-${TOOLS_CSV//,/+}"

if ! dev_env_require_binaries; then
    exit 1
fi

if ! dev_env_prepare_state "${TEST_NAME}"; then
    exit 1
fi

if ! dev_env_install_release; then
    exit 1
fi

if ! "${DEV_ENV}" plan --installer "${RELEASE}" --tools "${TOOLS_CSV}"; then
    echo "dev-env plan failed for ${TOOLS_CSV}" >&2
    exit 1
fi

if ! "${DEV_ENV}" apply --config-conflict=backup; then
    echo "dev-env apply failed for ${TOOLS_CSV}" >&2
    exit 1
fi

if ! "${DEV_ENV}" doctor; then
    echo "dev-env doctor failed after installing ${TOOLS_CSV}" >&2
    exit 1
fi

INSTALLED_JSON="${XDG_DATA_HOME}/dev-env/installed.json"
if ! test -f "${INSTALLED_JSON}"; then
    echo "installed.json missing after apply" >&2
    exit 1
fi

for tool in "$@"; do
    if ! dev_env_json_assert contains-field "${INSTALLED_JSON}" tools tool "${tool}"; then
        echo "installed.json did not record ${tool}" >&2
        exit 1
    fi
done

case ",${TOOLS_CSV}," in
    *,zig,*)
        if ! "${HOME}/.local/bin/zig" version >/dev/null; then
            echo "zig install validation failed" >&2
            exit 1
        fi
        ;;
esac

case ",${TOOLS_CSV}," in
    *,go,*)
        if ! "${HOME}/.local/bin/go" version >/dev/null; then
            echo "go install validation failed" >&2
            exit 1
        fi
        ;;
esac

case ",${TOOLS_CSV}," in
    *,rust,*)
        if ! test -x "${HOME}/.local/share/cargo/bin/rustup"; then
            echo "rustup binary missing" >&2
            exit 1
        fi
        if ! RUSTUP_HOME="${HOME}/.local/share/rustup" CARGO_HOME="${HOME}/.local/share/cargo" "${HOME}/.local/share/cargo/bin/rustup" show active-toolchain >/dev/null; then
            echo "rust install validation failed" >&2
            exit 1
        fi
        ;;
esac

case ",${TOOLS_CSV}," in
    *,tmux,*)
        if ! "${HOME}/.local/bin/tmux" -V >/dev/null; then
            echo "tmux install validation failed" >&2
            exit 1
        fi
        if ! test -x "${HOME}/.tmux/plugins/tpm/bin/install_plugins"; then
            echo "tmux plugin manager validation failed" >&2
            exit 1
        fi
        ;;
esac

case ",${TOOLS_CSV}," in
    *,neovim,*)
        if ! "${HOME}/.local/bin/nvim" --version >/dev/null; then
            echo "neovim install validation failed" >&2
            exit 1
        fi
        ;;
esac

case ",${TOOLS_CSV}," in
    *,alacritty,*)
        if ! "${HOME}/.local/bin/alacritty" --version >/dev/null; then
            echo "alacritty install validation failed" >&2
            exit 1
        fi
        ;;
esac

case ",${TOOLS_CSV}," in
    *,docker,*)
        if ! docker --version >/dev/null; then
            echo "docker install validation failed" >&2
            exit 1
        fi
        ;;
esac

echo "install integration tests passed for ${TOOLS_CSV}"
