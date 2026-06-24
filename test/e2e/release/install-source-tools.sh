#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
if [ $? -ne 0 ]; then
    echo "failed to locate e2e script directory" >&2
    exit 1
fi

if ! bash "${SCRIPT_DIR}/install-tools.sh" tmux neovim alacritty; then
    echo "source build release e2e tests failed" >&2
    exit 1
fi
