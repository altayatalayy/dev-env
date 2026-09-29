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
if ! dev_env_prepare_state platform; then exit 1; fi
if ! dev_env_install_fake_release 0.1.0; then exit 1; fi

if ! "${DEV_ENV}" plan --installer 0.1.0 --tools tmux; then
    echo "platform plan failed" >&2
    exit 1
fi

LOCK_JSON="${XDG_DATA_HOME}/dev-env/lock.json"
TARGET="${DEV_ENV_TEST_TARGET:-}"
if [ -z "${TARGET}" ]; then
    echo "DEV_ENV_TEST_TARGET is not set; skipping explicit target assertion"
    exit 0
fi

if ! python3 - "${LOCK_JSON}" "${TARGET}" <<'PY'
import json
import sys
from pathlib import Path

lock = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
target = sys.argv[2]
parts = target.split("-")
if len(parts) != 3:
    raise SystemExit(f"invalid DEV_ENV_TEST_TARGET: {target}")
want_distro, want_version, want_arch = parts
platform = lock["platform"]
if list(platform.keys()) != [want_distro]:
    raise SystemExit(f"platform distro mismatch: expected {want_distro}, got {platform}")
fields = platform[want_distro]
if fields["version"] != want_version:
    raise SystemExit(f"platform version mismatch: expected {want_version}, got {fields['version']}")
if fields["arch"] != want_arch:
    raise SystemExit(f"platform arch mismatch: expected {want_arch}, got {fields['arch']}")
PY
then
    echo "lock platform did not match ${TARGET}" >&2
    exit 1
fi

echo "platform fake e2e test passed for ${TARGET}"
