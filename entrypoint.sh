#!/usr/bin/env bash
# BSD 3-Clause License
# Copyright (c) 2025, Xnerv Wang
# All rights reserved.

set -euo pipefail

log() { printf '[%(%F %T)T] [puller] %s\n' -1 "$*"; }

prepare_env() {
  # 时区
  if [[ -n "${TZ:-}" && -e "/usr/share/zoneinfo/${TZ}" ]]; then
    ln -sf "/usr/share/zoneinfo/${TZ}" /etc/localtime || true
    echo "$TZ" > /etc/timezone || true
  fi

  # known_hosts（避免 SSH 首次交互）
  mkdir -p /etc/ssh
  if [[ -n "${SSH_KNOWN_HOSTS:-}" ]]; then
    printf '%s\n' "$SSH_KNOWN_HOSTS" >> /etc/ssh/ssh_known_hosts
  fi
  ssh-keyscan -H github.com >> /etc/ssh/ssh_known_hosts 2>/dev/null || true
}

main_loop() {
  : "${INTERVAL:=60}"

  if [[ ! -x /app/scripts/pull.sh ]]; then
    log "ERROR: /app/scripts/pull.sh 不存在或不可执行"; exit 1
  fi

  trap 'log "terminating"; exit 0' SIGINT SIGTERM

  while :; do
    if bash /app/scripts/pull.sh; then
      log "pull.sh done"
    else
      log "pull.sh failed (non-zero exit)"
    fi
    sleep "$INTERVAL"
  done
}

prepare_env
main_loop
