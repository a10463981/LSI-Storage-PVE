#!/usr/bin/env bash
# preflight.sh — 安装前检查。只读，不改变任何东西。
#
# 重要边界：本脚本**绝不在宿主机上执行 apt**。所有包安装都发生在
# $PREFIX/rootfs 这个独立 Ubuntu 根文件系统内部（见 lib/chroot.sh），
# 宿主的 /etc/apt 与 /var/lib/apt 完全不参与。

ROOTFS_URL_DEFAULT="http://mirrors.tuna.tsinghua.edu.cn/ubuntu-cdimage/ubuntu-base/releases/24.04/release/ubuntu-base-24.04.5-base-amd64.tar.gz"
ROOTFS_SHA_DEFAULT="e77b6f10c2590cef872b33ee9f635a0e3fd1f57fb074c0e52b5c7f56147a0c86"

req_root() {
  if [ "$(id -u)" -eq 0 ]; then return 0; fi
  # --dry-run 不写任何东西，允许非 root 试跑（方便在任意机器上验证流程）
  if [ "${DRY_RUN:-0}" = "1" ]; then
    warn "非 root + dry-run：只打印动作，不会真的执行"
    return 0
  fi
  die "需要 root 权限。请用：sudo $0 $*"
}

# 是否运行在容器里（LXC / Docker 里装 systemd unit 没意义）
in_container() {
  if have systemd-detect-virt; then
    systemd-detect-virt --container >/dev/null 2>&1 && return 0
  fi
  head -1 /proc/1/sched 2>/dev/null | grep -q '^lxc' && return 0
  grep -qaE '(docker|lxc|containerd)' /proc/1/cgroup 2>/dev/null && return 0
  return 1
}

is_pve() {
  [ -d /etc/pve ] || have pmxversion || have pvesh
}

# 端口是否已被占用（监听态）
port_in_use() {
  local p=$1
  if have ss; then ss -lntH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}$"
  elif have netstat; then netstat -lnt 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}$"
  else grep -qE ":$p " /proc/net/tcp /proc/net/tcp6 2>/dev/null
  fi
}

disk_free_mb() {   # disk_free_mb <路径>
  df -Pm "$1" 2>/dev/null | awk 'NR==2{print $4}'
}

mem_avail_mb() {
  awk '/^MemAvailable:/{print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0
}

megaraid_present() {
  local hosts
  hosts=$(grep -l megaraid /sys/class/scsi_host/*/proc_name 2>/dev/null | wc -l)
  [ "$hosts" -gt 0 ] && return 0
  [ -d /sys/module/megaraid_sas ] && return 0
  [ -e /dev/megaraid_sas_ioctl_node ] && return 0
  return 1
}

# 可用的下载器
http_fetch() {   # http_fetch <url> <outfile>
  local url=$1 out=$2
  if have curl; then
    curl -fL --retry 3 --retry-delay 2 -C - --connect-timeout 15 -o "$out" "$url"
  elif have wget; then
    wget -c -T 20 -t 3 -O "$out" "$url"
  else
    die "找不到 curl 或 wget，无法下载。可加 --rootfs-file/--lsa-package 指定本地文件"
  fi
}

check_sha256() {   # check_sha256 <file> <expect>
  local f=$1 exp=$2 got
  have sha256sum || die "缺少 sha256sum"
  got=$(sha256sum "$f" | awk '{print $1}')
  if [ "$got" != "$exp" ]; then
    err "SHA256 不匹配"
    err "  期望：$exp"
    err "  实际：$got"
    err "  文件：$f"
    return 1
  fi
  return 0
}

# 打印预检结论；供 install 与 doctor 共用
preflight_summary() {
  local rc=0
  in_container && { warn "检测到容器环境，宿主 systemd 不可用"; rc=1; }
  [ -d /run/systemd/system ] || { warn "没有运行中的 systemd"; rc=1; }
  return $rc
}
