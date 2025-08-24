# BSD 3-Clause License
# Copyright (c) 2025, Xnerv Wang
# All rights reserved.

# TODO: Need a graceful way to support both ssh git repo and https git repo.

# syntax=docker/dockerfile:1
FROM alpine:3.20

ENV TZ=UTC \
    INTERVAL="60"

# 预设 APK 源到 kernel.org（美国镜像）
RUN set -eux; \
    ver="$(cut -d. -f1,2 /etc/alpine-release)"; \
    base="https://mirrors.edge.kernel.org/alpine/v${ver}"; \
    printf "%s/main\n%s/community\n" "$base" "$base" > /etc/apk/repositories; \
    apk add --no-cache bash git openssh-client diffutils ca-certificates tzdata; \
    update-ca-certificates

WORKDIR /app

# 将本地根目录的 entrypoint.sh 和 pull.sh 复制到镜像 /app/scripts/
COPY entrypoint.sh /app/scripts/entrypoint.sh
COPY pull.sh /app/scripts/pull.sh

RUN chmod +x /app/scripts/entrypoint.sh /app/scripts/pull.sh \
    && mkdir -p /app/etc /app/scripts /var/lib/liteflow-conf-puller

ENTRYPOINT ["/app/scripts/entrypoint.sh"]
