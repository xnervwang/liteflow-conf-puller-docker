#!/bin/bash
# pull.sh — pull configuration via environment variables (no CLI args)
#
# REQUIRED (common)
#   DEST_FILE                 # 目标文件路径
#
# GIT mode (choose one mode automatically; or set PULL_MODE=git)
#   CONF_REPO                 # git 仓库（git@... 或 https://...）
#   CONF_SRC                  # 仓库内相对路径（例如 output/node.conf）
#
# WGET mode (set PULL_MODE=wget or仅设 FETCH_URL)
#   FETCH_URL                 # 直链 URL
#
# OPTIONAL (common)
#   BACKUP=1                  # 覆盖前做时间戳备份
#   FORCE=1                   # 允许覆盖（当 BACKUP 未开启时）
#   INTERVAL=60               # 秒；>0 循环拉取；未设或 0 仅拉一次
#
# OPTIONAL (git auth)
#   # 优先级：GIT_SSH_COMMAND > SSH agent > SSH_KEY_PATH > sudo 回退
#   SSH_KEY_PATH=/run/secrets/git_key
#   SSH_STRICT=accept-new     # accept-new|yes|no（默认 accept-new）
#   DISABLE_SSH_AGENT=1       # 如设为 1 则忽略 SSH_AUTH_SOCK
#
# OPTIONAL (https private git or API)
#   AUTH_HEADER="Authorization: Bearer <token>"
#   TOKEN=<pat>               # 若未设 AUTH_HEADER，则用 Authorization: Bearer <TOKEN>
#
# Notes:
# - 本脚本只读 env，不接受命令行参数。
# - 已将 known_hosts 写入 /etc/ssh/ssh_known_hosts（无需写入 ~/.ssh）。
# - 需要容器内具备：git（git 模式），wget 或 curl（wget 模式），可选 cmp。

set +e

PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin:${PATH}

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
PACKAGE_DIR=$(dirname "$SCRIPT_DIR")
PACKAGE_KEY=$(echo "$PACKAGE_DIR" | sed 's|/|_|g')

REAL_USER=${SUDO_USER:-$USER}
REAL_HOME=$(eval echo ~$REAL_USER)
TEMP_DIR="${TMPDIR:-${TMP:-${TEMP:-/tmp}}}"

log() {
  if [ "$1" = "-n" ]; then shift; printf "[%s] %s" "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
  elif [ "$1" = "-r" ]; then shift; printf "%s\n" "$*"
  else printf "[%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
  fi
}

is_true() { case "$1" in 1|true|TRUE|yes|YES|on|ON) return 0 ;; *) return 1 ;; esac; }

need() { command -v "$1" >/dev/null 2>&1 || { log "Error: '$1' not found"; return 1; }; }

ssh_host_from_url() {
  case "$1" in
    git@*:* ) echo "$1" | sed -n 's/^git@\([^:]*\):.*$/\1/p' ;;
    ssh://* ) echo "$1" | sed -n 's|^ssh://[^@]*@\([^/]*\)/.*$|\1|p' ;;
    https://*|http://* ) echo "$1" | sed -n 's|^[a-z]\+://\([^/]*\)/.*$|\1|p' ;;
    * ) : ;;
  esac
}

ensure_known_hosts() {
  local url="$1" host
  host="$(ssh_host_from_url "$url")"
  [ -n "$host" ] || return 0
  mkdir -p /etc/ssh
  ssh-keyscan -H "$host" >> /etc/ssh/ssh_known_hosts 2>/dev/null || true
}

build_git_ssh_command() {
  # 优先级：GIT_SSH_COMMAND > agent > SSH_KEY_PATH > sudo 回退
  local strict="${SSH_STRICT:-accept-new}"
  local base="ssh -o IdentitiesOnly=yes -o StrictHostKeyChecking=${strict} -F /dev/null"

  if [ -n "${GIT_SSH_COMMAND:-}" ]; then
    echo "$GIT_SSH_COMMAND"; return
  fi

  if [ -n "${SSH_AUTH_SOCK:-}" ] && ! is_true "${DISABLE_SSH_AGENT:-0}"; then
    echo "$base"; return
  fi

  if [ -n "${SSH_KEY_PATH:-}" ]; then
    echo "$base -i ${SSH_KEY_PATH}"; return
  fi

  if [ -n "$SUDO_USER" ]; then
    echo "$base -i $REAL_HOME/.ssh/id_rsa"; return
  fi

  echo "$base"
}

git_with_optional_header() {
  # 用于 HTTPS 私库：支持 AUTH_HEADER / TOKEN
  # 用法：git_with_optional_header <git args...>
  if [ -n "${AUTH_HEADER:-}" ]; then
    git -c http.extraHeader="$AUTH_HEADER" "$@"
  elif [ -n "${TOKEN:-${GITHUB_TOKEN:-}}" ]; then
    git -c http.extraHeader="Authorization: Bearer ${TOKEN:-${GITHUB_TOKEN}}" "$@"
  else
    git "$@"
  fi
}

pull_wget() {
  local url="$1" dest_path="$2" backup="$3" force="$4"

  need wget || need curl || { log "Error: need wget or curl"; return 1; }
  [ -n "$url" ] && [ -n "$dest_path" ] || { log "Error: FETCH_URL/DEST_FILE required"; return 1; }

  local dest_dir; dest_dir="$(dirname "$dest_path")"
  mkdir -p "$dest_dir" && { log "Created folder $dest_dir" } || { log "Error: cannot create $dest_dir"; return 1; }

  if [ -f "$dest_path" ]; then
    if is_true "$backup"; then
      local b="$dest_path.backup.$(date '+%Y-%m-%d_%H-%M-%S-%6N')"
      log "Creating backup: $b"; cp "$dest_path" "$b" || return 1
    elif ! is_true "$force"; then
      log "Error: $dest_path exists (set FORCE=1 or BACKUP=1)"; return 1
    fi
  fi

  local tmp="$TEMP_DIR/liteflow_wget.$PACKAGE_KEY.$(date '+%Y-%m-%d_%H-%M-%S-%6N')"
  log "Downloading: $url"
  if command -v wget >/dev/null; then
    wget -q -O "$tmp" "$url" || { log "Error: wget failed"; rm -f "$tmp"; return 1; }
  else
    curl -fsSL -o "$tmp" "$url" || { log "Error: curl failed"; rm -f "$tmp"; return 1; }
  fi
  [ -s "$tmp" ] || { log "Error: empty download"; rm -f "$tmp"; return 1; }

  if command -v cmp >/dev/null 2>&1 && [ -f "$dest_path" ]; then
    if ! cmp -s "$tmp" "$dest_path"; then
      log "Updating $dest_path"; cp "$tmp" "$dest_path" || { rm -f "$tmp"; return 1; }
    else
      log "No changes detected"
    fi
  else
    [ -f "$dest_path" ] && ! command -v cmp >/dev/null 2>&1 && log "cmp not found, overwriting"
    cp "$tmp" "$dest_path" || { rm -f "$tmp"; return 1; }
  fi
  rm -f "$tmp"
  log "Successfully pulled (wget)"
  return 0
}

pull_git() {
  local repo_url="$1" src_path="$2" dest_path="$3" backup="$4" force="$5"

  need git || return 1
  [ -n "$repo_url" ] && [ -n "$src_path" ] && [ -n "$dest_path" ] || { log "Error: CONF_REPO/CONF_SRC/DEST_FILE required"; return 1; }

  # SSH 配置 & known_hosts
  export GIT_SSH_COMMAND="$(build_git_ssh_command)"
  log "GIT_SSH_COMMAND: $GIT_SSH_COMMAND"
  ensure_known_hosts "$repo_url"

  local dest_dir; dest_dir="$(dirname "$dest_path")"
  mkdir -p "$dest_dir" && { log "Created folder $dest_dir" } || { log "Error: cannot create $dest_dir"; return 1; }

  if [ -f "$dest_path" ]; then
    if is_true "$backup"; then
      local b="$dest_path.backup.$(date '+%Y-%m-%d_%H-%M-%S-%6N')"
      log "Creating backup: $b"; cp "$dest_path" "$b" || return 1
    elif ! is_true "$force"; then
      log "Error: $dest_path exists (set FORCE=1 or BACKUP=1)"; return 1
    fi
  fi

  local git_tmp="$TEMP_DIR/liteflow_git.$PACKAGE_KEY"

  if [ -d "$git_tmp/.git" ]; then
    log "Updating repo at $git_tmp"
    ( cd "$git_tmp" && git remote set-url origin "$repo_url" >/dev/null 2>&1 || true
      git_with_optional_header pull --depth=1 origin HEAD
    ) || { log "Error: git pull failed"; return 1; }
    ( cd "$git_tmp" && git reset --hard FETCH_HEAD ) || { log "Error: git reset failed"; return 1; }
  else
    log "Cloning repo to $git_tmp"
    rm -rf "$git_tmp"
    git_with_optional_header clone --depth=1 "$repo_url" "$git_tmp" || { log "Error: git clone failed"; return 1; }
  fi

  local src_file="$git_tmp/$src_path"
  [ -f "$src_file" ] || { log "Error: file not found in repo: $src_path"; return 1; }

  if command -v cmp >/dev/null 2>&1 && [ -f "$dest_path" ]; then
    if ! cmp -s "$src_file" "$dest_path"; then
      log "Updating $dest_path from repo"; cp "$src_file" "$dest_path" || return 1
    else
      log "No changes detected"
    fi
  else
    [ -f "$dest_path" ] && ! command -v cmp >/dev/null 2>&1 && log "cmp not found, overwriting"
    cp "$src_file" "$dest_path" || return 1
  fi

  log "Successfully pulled (git)"
  return 0
}

run_once() {
  case "$1" in
    git)  pull_git  "$CONF_REPO" "$CONF_SRC" "$DEST_FILE" "$BACKUP" "$FORCE" ;;
    wget) pull_wget "$FETCH_URL" "$DEST_FILE"              "$BACKUP" "$FORCE" ;;
    *)    log "Error: unknown mode '$1'"; return 2 ;;
  esac
}

auto_mode() {
  if [ -n "${PULL_MODE:-${MODE:-}}" ]; then echo "${PULL_MODE:-${MODE:-}}"; return; fi
  if [ -n "${CONF_REPO:-}" ] && [ -n "${CONF_SRC:-}" ]; then echo "git"; return; fi
  if [ -n "${FETCH_URL:-}" ]; then echo "wget"; return; fi
  echo ""
}

main() {
  local mode; mode="$(auto_mode)"
  [ -n "${DEST_FILE:-}" ] || { log "Error: DEST_FILE required"; exit 1; }
  [ -n "$mode" ] || {
    log "Usage (env-only):"
    log "  git : CONF_REPO, CONF_SRC, DEST_FILE [BACKUP=1|FORCE=1] [INTERVAL=<sec>]"
    log "  wget: FETCH_URL, DEST_FILE           [BACKUP=1|FORCE=1] [INTERVAL=<sec>]"
    exit 2
  }

  BACKUP="$(is_true "${BACKUP:-0}" && echo 1 || echo 0)"
  FORCE="$(is_true "${FORCE:-0}" && echo 1 || echo 0)"
  local interval="${INTERVAL:-0}"

  log "Mode=$mode DEST_FILE=$DEST_FILE BACKUP=$BACKUP FORCE=$FORCE INTERVAL=${interval:-0}"

  if [ -n "$interval" ] && [ "$interval" -gt 0 ] 2>/dev/null; then
    while :; do
      if run_once "$mode"; then
        log "fetch done"
      else
        log "fetch failed"
      fi
      sleep "$interval"
    done
  else
    run_once "$mode"
  fi
}

main
