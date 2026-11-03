#!/usr/bin/env bash

if ! . /opt/dev-env-lib-test/common.sh; then
    echo "failed to load library test helpers" >&2
    return 1
fi

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
