#!/usr/bin/env bash
# commands/doctor.sh — 只读体检。允许非 root 运行（只读部分）。
#
# 输出三段：系统信息 / 能力检查 / 现有安装，最后给一句结论。

doctor_main() {
  local problems=0 warns=0

  printf '\n%s=== 系统 ===%s\n' "$C_INFO" "$C_OFF"
  row "发行版" "$( ( . /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-未知}" ) || echo 未知 )"
  row "内核" "$(uname -r)"
  if is_pve; then
    local pvev="未知"
    have pveversion && pvev=$(pveversion 2>/dev/null | head -1 | sed 's|^pve-manager/||; s|/.*||')
    row "Proxmox VE" "$pvev（/etc/pve 存在）"
  else
    row "Proxmox VE" "未检测到 —— 本工具面向 PVE，但纯 Debian 也能装"
    warns=$((warns + 1))
  fi
  row "Systemd" "$( [ -d /run/systemd/system ] && echo "运行中" || echo "未运行" )"
  [ -d /run/systemd/system ] || problems=$((problems + 1))
  if in_container; then
    row "容器环境" "是（$(systemd-detect-virt --container 2>/dev/null || echo container)）—— 不能装 systemd 服务"
    problems=$((problems + 1))
  else
    row "容器环境" "否"
  fi
  row "权限" "$( [ "$(id -u)" -eq 0 ] && echo "root" || echo "非 root（安装需要 sudo）" )"

  printf '\n%s=== 阵列卡 ===%s\n' "$C_INFO" "$C_OFF"
  local lspci_line dev mod hosts
  if have lspci; then
    lspci_line=$( { lspci 2>/dev/null || true; } | grep -iE 'raid bus controller|megaraid' | head -1 || true)
  fi
  row "lspci" "${lspci_line:-未发现 MegaRAID 设备}"
  hosts=$( { grep -l megaraid /sys/class/scsi_host/*/proc_name 2>/dev/null || true; } | wc -l)
  row "scsi_host" "$hosts 个 megaraid 主机"
  [ -d /sys/module/megaraid_sas ] && mod="已加载" || mod="未加载"
  row "megaraid_sas 模块" "$mod"
  [ -e /dev/megaraid_sas_ioctl_node ] && dev="存在" || dev="不存在"
  row "/dev/megaraid_sas_ioctl_node" "$dev"
  if megaraid_present; then
    row "结论" "检测到 MegaRAID，可正常管理"
  else
    row "结论" "未检测到阵列卡 —— 可以装，但界面里只会显示空列表"
    warns=$((warns + 1))
  fi

  printf '\n%s=== 资源与网络 ===%s\n' "$C_INFO" "$C_OFF"
  local free_mb mem_mb
  free_mb=$(disk_free_mb "$(dirname "$PREFIX")")
  mem_mb=$(mem_avail_mb)
  row "磁盘剩余（$(dirname "$PREFIX")）" "${free_mb:-?} MB（需要 ≥ 2048）"
  [ "${free_mb:-0}" -ge 2048 ] 2>/dev/null || { warns=$((warns + 1)); }
  row "内存可用" "${mem_mb} MB（运行期约需 300MB）"
  [ "$mem_mb" -ge 300 ] 2>/dev/null || warns=$((warns + 1))
  local mirror_host
  mirror_host=$(printf '%s' "${ROOTFS_URL:-$ROOTFS_URL_DEFAULT}" | sed -E 's#^https?://([^/]+)/.*#\1#') || true
  if have getent && getent hosts "$mirror_host" >/dev/null 2>&1; then
    row "镜像站解析" "$mirror_host 可解析"
  else
    row "镜像站解析" "$mirror_host 解析失败（可用 --rootfs-file 本地安装）"
    warns=$((warns + 1))
  fi
  row "下载器" "$( have curl && echo curl || ( have wget && echo wget || echo "无（需本地文件）" ) )"
  row "解压工具" "$( have unzip && echo unzip || ( have python3 && echo "python3 zipfile" || echo "无（需 --lsa-package 已解压目录）" ) )"

  printf '\n%s=== 现有安装 ===%s\n' "$C_INFO" "$C_OFF"
  if [ -d "$PREFIX" ]; then
    row "安装目录" "$PREFIX（$(du -sm "$PREFIX" 2>/dev/null | cut -f1) MB）"
  else
    row "安装目录" "$PREFIX 不存在（未安装）"
  fi
  row "systemd 单元" "$(unit_status_line)"
  row "LSA 主程序" "$( [ -x "$RFS/opt/lsi/LSIStorageAuthority/bin/LSA" ] && echo 存在 || echo 不存在 )"
  if port_in_use "$PORT"; then row "端口 $PORT" "已被占用（安装时需 --port 换一个）"; warns=$((warns + 1));
  else row "端口 $PORT" "空闲"; fi
  if port_in_use "$BACKEND_PORT"; then row "端口 $BACKEND_PORT" "已被占用（安装时需 --backend-port 换一个）"; warns=$((warns + 1));
  else row "端口 $BACKEND_PORT" "空闲"; fi
  if [ -f "$RFS/opt/lsi/LSIStorageAuthority/logs/lsa.txt" ]; then
    local fatal
    fatal=$(grep -cE 'Library load failed|OPENSSL_3.2|CPU ISA level' \
              "$RFS/opt/lsi/LSIStorageAuthority/logs/lsa.txt" 2>/dev/null || echo 0)
    row "LSA 日志致命行" "$fatal 处"
    [ "$fatal" -gt 0 ] && warns=$((warns + 1))
  fi

  printf '\n%s=== 结论 ===%s\n' "$C_INFO" "$C_OFF"
  if [ "$problems" -gt 0 ]; then
    printf '  %s不能安装%s：有 %d 项硬性条件不满足（见上）\n' "$C_ERR" "$C_OFF" "$problems"
    return 1
  fi
  if [ "$warns" -gt 0 ]; then
    printf '  %s可以安装，但有 %d 项提示%s —— 不影响安装，功能可能受限\n' "$C_WARN" "$warns" "$C_OFF"
  else
    printf '  %s环境检查全部通过，可以安装%s\n' "$C_OK" "$C_OFF"
  fi
  echo
  printf '  下一步：sudo %s install --lsa-package <LSA包路径>\n\n' "$0"
  return 0
}

row() {   # row <名称> <值>
  printf '  %-30s %s\n' "$1" "$2"
  _log_raw "  $1 = $2"
}
