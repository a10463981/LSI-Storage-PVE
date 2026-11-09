#!/usr/bin/env bash
# log.sh — 统一日志、颜色、dry-run 执行器
# 被 installer/install.sh 在所有子命令之前 source。

if [ -t 1 ]; then
  C_OK=$'\033[1;32m'; C_ERR=$'\033[1;31m'; C_WARN=$'\033[1;33m'
  C_INFO=$'\033[1;34m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_OK=''; C_ERR=''; C_WARN=''; C_INFO=''; C_DIM=''; C_OFF=''
fi

: "${LOG_DIR:=/var/log/lsi-storage-pve}"
: "${LOG_FILE:=}"
STEP_NO=0
STEP_TOTAL=0

LOG_ENABLED=0

log_init() {
  LOG_FILE="${LOG_FILE:-$LOG_DIR/run-$(date +%Y%m%d-%H%M%S).log}"
  if mkdir -p "$LOG_DIR" 2>/dev/null && : >>"$LOG_FILE" 2>/dev/null; then
    LOG_ENABLED=1
  else
    # 非 root 跑 doctor 时写不进 /var/log，静默降级（不刷屏、不影响输出）
    LOG_ENABLED=0
    LOG_FILE=""
  fi
}

_log_raw() {   # 写文件，始终保持纯文本（无颜色）
  [ "$LOG_ENABLED" = "1" ] || return 0
  printf '%s\n' "$*" >>"$LOG_FILE" 2>/dev/null || true
}

say()  { printf '%s[lsi]%s %s\n'  "$C_INFO" "$C_OFF" "$*"; _log_raw "[lsi] $*"; }
ok()   { printf '%s[ OK]%s %s\n'  "$C_OK"   "$C_OFF" "$*"; _log_raw "[ OK] $*"; }
warn() { printf '%s[!!]%s %s\n'   "$C_WARN" "$C_OFF" "$*"; _log_raw "[!!] $*"; }
err()  { printf '%s[ERR]%s %s\n'  "$C_ERR"  "$C_OFF" "$*" >&2; _log_raw "[ERR] $*"; }
dim()  { printf '%s%s%s\n' "$C_DIM" "$*" "$C_OFF"; }

step() {   # step "标题"
  STEP_NO=$((STEP_NO + 1))
  if [ "$STEP_TOTAL" -gt 0 ]; then
    printf '\n%s==> [%d/%d] %s%s\n' "$C_INFO" "$STEP_NO" "$STEP_TOTAL" "$*" "$C_OFF"
    _log_raw "==> [$STEP_NO/$STEP_TOTAL] $*"
  else
    printf '\n%s==> %s%s\n' "$C_INFO" "$*" "$C_OFF"
    _log_raw "==> $*"
  fi
}

die() { err "$*"; exit 1; }

# run —— 所有会改变系统的命令都经过它，--dry-run 时只打印
run() {
  local IFS=' '
  if [ "${DRY_RUN:-0}" = "1" ]; then
    printf '%s  [dry-run] %s%s\n' "$C_DIM" "$*" "$C_OFF"
    return 0
  fi
  _log_raw "  $ $*"
  "$@"
}

# run_shell —— 需要管道/重定向时用；同样受 dry-run 控制
run_shell() {
  local IFS=' '
  if [ "${DRY_RUN:-0}" = "1" ]; then
    printf '%s  [dry-run] %s%s\n' "$C_DIM" "$*" "$C_OFF"
    return 0
  fi
  _log_raw "  $ $*"
  bash -c "$*"
}

confirm() {   # confirm "问题" -> 0=继续
  [ "${YES:-0}" = "1" ] && return 0
  [ "${DRY_RUN:-0}" = "1" ] && return 0
  [ -t 0 ] || die "非交互环境，请加 --yes 确认"
  printf '%s%s [y/N] %s' "$C_WARN" "$1" "$C_OFF"
  read -r ans
  case "$ans" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

have() { command -v "$1" >/dev/null 2>&1; }
