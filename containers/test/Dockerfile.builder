# syntax=docker/dockerfile:1.7

FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
ARG ZIG_VERSION=0.16.0
ARG ZIG_ARCH=x86_64

ENV LANG=C.UTF-8
ENV PATH=/opt/zig:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

RUN rm -f /etc/apt/apt.conf.d/docker-clean
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update && \
    apt-get install --yes --no-install-recommends \
        bash \
        ca-certificates \
        coreutils \
        tar \
        xz-utils \
        zstd

ADD https://ziglang.org/download/${ZIG_VERSION}/zig-${ZIG_ARCH}-linux-${ZIG_VERSION}.tar.xz /tmp/zig.tar.xz
RUN mkdir --parents /opt/zig && \
    tar --extract --xz --file /tmp/zig.tar.xz --directory /opt/zig --strip-components=1 && \
    rm --force /tmp/zig.tar.xz

WORKDIR /src
COPY . .
COPY --from=zig_cli . /zig-cli
COPY --from=zig_graph . /zig-graph
