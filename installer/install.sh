#!/usr/bin/env bash
# install.sh — 唯一入口：参数解析 + 子命令分发
#
# 子命令：
#   doctor     只读体检（允许非 root）
#   install    全新安装
#   status     状态
#   upgrade    升级（保留旧 rootfs）
#   rollback   回滚到指定旧 rootfs
#   uninstall  卸载
#   repair     白名单修复
#
# 硬约束：
#   * 宿主永不执行 apt；所有包安装都在 $PREFIX/rootfs 这个独立 Ubuntu 内
#   * 不执行 pkill；停服务只用 systemd
#   * 不做 umount -R；挂载一律包在 unshare -m 或 systemd PrivateMounts 里

set -euo pipefail
IFS=$'\n\t'

INSTALLER=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJ=$(cd "$INSTALLER/.." && pwd)

# ---------- 默认值 ----------
PREFIX="/opt/lsi-storage"
PORT=2463
BACKEND_PORT=9000
LSA_PACKAGE=""
ROOTFS_FILE=""
LSA_BASELINE="gcc_8.3.x"
ROOTFS_URL=""
ROOTFS_SHA=""
READY_TIMEOUT=300
YES=0
DRY_RUN=0
FORCE=0
PURGE=0
KEEP_FAILED=0
ROLLBACK_TO=""
VERBOSE=0
COMMAND=""

CONF="/etc/lsi-storage-pve.conf"
STATE="/var/lib/lsi-storage-pve"
LOG_DIR="/var/log/lsi-storage-pve"
UNIT_FILE="/etc/systemd/system/lsa-pve.service"

usage() {
  cat <<'EOF'
基于 Debian / PVE 博通 LSA 控制器工具

用法：
  install.sh <子命令> [选项]

子命令：
  doctor                只读体检，不改任何东西（普通用户也可运行）
  install               全新安装
  status                查看服务/端口/接口状态
  upgrade               升级（替换 rootfs，保留配置，旧版留作回滚）
  rollback --to <路径>  回滚到 upgrade 保留的旧 rootfs
  uninstall             卸载（--purge 连配置与日志一起删）
  repair                白名单修复（符号链接/残留挂载/pid/重装单元/重启）

选项：
  --lsa-package <路径|URL>   高级：自备 LSA 包从源码现装（需联网）；不填则用发行包内
                             的预构建环境（离线，推荐）
  --rootfs-file <路径>       本地 ubuntu-base rootfs（离线安装用）
  --port <N>                 对外端口，默认 2463
  --backend-port <N>         LSA 后端端口，默认 9000
  --prefix <路径>            安装前缀，默认 /opt/lsi-storage
  --timeout <秒>             等待就绪的时间，默认 300
  --yes                      跳过确认
  --dry-run                  只打印将执行的动作，不落盘
  --force                    目标已存在时强制重装
  --purge                    uninstall 时连配置、缓存、日志一并删除
  --keep-failed              安装失败时保留现场（便于排查）
  --verbose                  更详细的输出
  -h, --help                 显示本帮助

示例：
  sudo ./installer/install.sh doctor
  sudo ./installer/install.sh install --lsa-package /root/008.018.012.000_MR_7.38_LSA_Linux.zip
  sudo ./installer/install.sh install --lsa-package https://example.com/LSA_Linux.zip --port 8080
  sudo ./installer/install.sh uninstall --purge
EOF
}

die_usage() { printf '错误：%s\n\n' "$*" >&2; usage >&2; exit 2; }

# ---------- 参数解析 ----------
[ $# -gt 0 ] || { usage; exit 0; }
case "$1" in
  -h|--help|help) usage; exit 0 ;;
  doctor|install|status|upgrade|rollback|uninstall|repair) COMMAND="$1"; shift ;;
  *) die_usage "未知子命令：$1" ;;
esac

while [ $# -gt 0 ]; do
  case "$1" in
    --lsa-package)  LSA_PACKAGE="${2:-}"; shift 2 ;;
    --rootfs-file)  ROOTFS_FILE="${2:-}"; shift 2 ;;
    --port)         PORT="${2:-}"; shift 2 ;;
    --backend-port) BACKEND_PORT="${2:-}"; shift 2 ;;
    --prefix)       PREFIX="${2:-}"; shift 2 ;;
    --timeout)      READY_TIMEOUT="${2:-}"; shift 2 ;;
    --to)           ROLLBACK_TO="${2:-}"; shift 2 ;;
    --yes|-y)       YES=1; shift ;;
    --dry-run)      DRY_RUN=1; shift ;;
    --force)        FORCE=1; shift ;;
    --purge)        PURGE=1; shift ;;
    --keep-failed)  KEEP_FAILED=1; shift ;;
    --verbose|-v)   VERBOSE=1; shift ;;
    -h|--help)      usage; exit 0 ;;
    *) die_usage "未知选项：$1" ;;
  esac
done

case "$PORT" in ''|*[!0-9]*) die_usage "--port 必须是数字" ;; esac
case "$BACKEND_PORT" in ''|*[!0-9]*) die_usage "--backend-port 必须是数字" ;; esac
[ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || die_usage "--port 超出范围"
[ "$BACKEND_PORT" -ge 1 ] && [ "$BACKEND_PORT" -le 65535 ] || die_usage "--backend-port 超出范围"
[ "$PORT" != "$BACKEND_PORT" ] || die_usage "--port 与 --backend-port 不能相同"
case "$PREFIX" in /*) ;; *) die_usage "--prefix 必须是绝对路径" ;; esac

RFS="$PREFIX/rootfs"

# ---------- 载入库 ----------
# shellcheck source=lib/log.sh
. "$INSTALLER/lib/log.sh"
# shellcheck source=lib/preflight.sh
. "$INSTALLER/lib/preflight.sh"
# shellcheck source=lib/fetch.sh
. "$INSTALLER/lib/fetch.sh"
# shellcheck source=lib/payload.sh
. "$INSTALLER/lib/payload.sh"
# shellcheck source=lib/chroot.sh
. "$INSTALLER/lib/chroot.sh"
# shellcheck source=lib/patch.sh
. "$INSTALLER/lib/patch.sh"
# shellcheck source=lib/service.sh
. "$INSTALLER/lib/service.sh"
# shellcheck source=lib/health.sh
. "$INSTALLER/lib/health.sh"

log_init

# ---------- 复用已写入的配置 ----------
if [ -f "$CONF" ]; then
  # 只在用户没有显式传参时采用配置里的值
  conf_prefix=$(sed -n 's/^PREFIX=//p' "$CONF" 2>/dev/null || true)
  conf_port=$(sed -n 's/^PORT=//p' "$CONF" 2>/dev/null || true)
  conf_backend=$(sed -n 's/^BACKEND_PORT=//p' "$CONF" 2>/dev/null || true)
  [ -n "$conf_prefix" ] && [ "$PREFIX" = "/opt/lsi-storage" ] && PREFIX="$conf_prefix"
  [ -n "$conf_port" ] && [ "$PORT" = "2463" ] && PORT="$conf_port"
  [ -n "$conf_backend" ] && [ "$BACKEND_PORT" = "9000" ] && BACKEND_PORT="$conf_backend"
  RFS="$PREFIX/rootfs"
fi

say "子命令：$COMMAND${DRY_RUN:+}$( [ "$DRY_RUN" = "1" ] && echo "（dry-run）" || true )"
say "安装前缀：$PREFIX　端口：$PORT / $BACKEND_PORT"
[ "$DRY_RUN" = "1" ] && warn "dry-run：不会写入任何文件、不会启动任何服务"
say "日志：${LOG_FILE:-（不可写，跳过）}"

case "$COMMAND" in
  doctor)    . "$INSTALLER/commands/doctor.sh";    doctor_main "$@" ;;
  install)   . "$INSTALLER/commands/install.sh";   install_main "$@" ;;
  status)    . "$INSTALLER/commands/status.sh";    status_main "$@" ;;
  upgrade)   . "$INSTALLER/commands/upgrade.sh";   upgrade_main "$@" ;;
  rollback)  . "$INSTALLER/commands/upgrade.sh";   rollback_main "$@" ;;
  uninstall) . "$INSTALLER/commands/uninstall.sh"; uninstall_main "$@" ;;
  repair)    . "$INSTALLER/commands/repair.sh";    repair_main "$@" ;;
  *) die "内部错误：未处理的子命令 $COMMAND" ;;
esac
