#!/usr/bin/env bash

if ! SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"; then
    echo "failed to locate e2e script directory" >&2
    exit 1
fi

if ! bash "${SCRIPT_DIR}/install-tools.sh" docker; then
    echo "docker install release e2e tests failed" >&2
    exit 1
fi

case "${DEV_ENV_TEST_TARGET:-}" in
    ubuntu-*)
        if ! test -s /etc/apt/keyrings/docker.asc; then
            echo "docker apt signing key was not installed" >&2
            exit 1
        fi
        if ! grep --quiet 'download.docker.com/linux/ubuntu' /etc/apt/sources.list.d/docker.list; then
            echo "docker apt repository was not configured" >&2
            exit 1
        fi
        if ! dpkg-query --show docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null; then
            echo "docker apt packages were not installed" >&2
            exit 1
        fi
        ;;
    fedora-*)
        if ! grep --quiet 'download.docker.com/linux/fedora' /etc/yum.repos.d/docker-ce.repo; then
            echo "docker dnf repository was not configured" >&2
            exit 1
        fi
        if ! rpm --query docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null; then
            echo "docker dnf packages were not installed" >&2
            exit 1
        fi
        ;;
esac
