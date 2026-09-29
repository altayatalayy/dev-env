#!/usr/bin/env bash

if ! SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"; then
    echo "failed to locate fake e2e script directory" >&2
    exit 1
fi

if ! . "${SCRIPT_DIR}/common.sh"; then
    echo "failed to load fake e2e helpers" >&2
    exit 1
fi

if ! dev_env_require_binaries; then
    exit 1
fi
if ! dev_env_prepare_state smoke; then
    exit 1
fi
if ! dev_env_install_fake_release 0.1.0; then
    exit 1
fi

if ! "${DEV_ENV}" plan --installer 0.1.0 --tools tmux; then
    echo "dev-env plan failed" >&2
    exit 1
fi

LOCK_JSON="${XDG_DATA_HOME}/dev-env/lock.json"
if ! dev_env_json_assert equals "${LOCK_JSON}" installer_release 0.1.0; then
    exit 1
fi
if ! dev_env_json_assert contains "${LOCK_JSON}" selected_tools tmux; then
    exit 1
fi
if ! "${DEV_ENV}" doctor; then
    echo "dev-env doctor failed with only lock state" >&2
    exit 1
fi

DOTFILES_REQUEST="${TEST_HOME}/extract-dotfiles-request.json"
DOTFILES_OUT="${TEST_HOME}/extract-dotfiles.jsonl"
if ! printf '{"protocol":1,"dest":"%s"}\n' "${DOTFILES_DEST}" > "${DOTFILES_REQUEST}"; then
    echo "failed to write dotfiles extraction request" >&2
    exit 1
fi
if ! "${INSTALLER}" extract-dotfiles < "${DOTFILES_REQUEST}" > "${DOTFILES_OUT}"; then
    echo "fake dotfiles extraction failed" >&2
    exit 1
fi
if ! test -f "${DOTFILES_DEST}/tmux/.config/tmux/tmux.conf"; then
    echo "tmux dotfiles package was not extracted" >&2
    exit 1
fi
if ! test -f "${DOTFILES_DEST}/shell/.zshenv"; then
    echo "shell dotfiles package was not extracted" >&2
    exit 1
fi
if ! python3 - "${DOTFILES_OUT}" <<'PY'
import json
import sys
from pathlib import Path

for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    if not line.strip():
        continue
    msg = json.loads(line)
    if msg.get("kind") == "response" and msg.get("command") == "extract-dotfiles":
        raise SystemExit(0)
raise SystemExit(1)
PY
then
    echo "dotfiles extraction response has the wrong command" >&2
    exit 1
fi

echo "smoke fake e2e tests passed"
