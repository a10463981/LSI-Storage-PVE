#!/usr/bin/env bash
# payload.sh — 使用发行包内预构建的 rootfs（默认安装路径）
#
# 为什么这样：现装（下载 Ubuntu base + chroot 里 apt + dpkg）依赖网络与镜像站，
# 在用户机器上失败率高；payload 是构建机上装好依赖、装好 LSA、打好补丁的一整份
# rootfs，安装时只做「解包 + 改端口 + 起服务」，全程离线、1–2 分钟完成。

PAYLOAD_DIR_DEFAULT="$PROJ/payload"
PAYLOAD_TAR=""
PAYLOAD_INFO=""

payload_locate() {
  local d="${PAYLOAD_DIR:-$PAYLOAD_DIR_DEFAULT}"
  PAYLOAD_TAR="$d/rootfs.tar.gz"
  PAYLOAD_INFO="$d/PAYLOAD_INFO"

  if [ ! -f "$PAYLOAD_TAR" ]; then
    cat >&2 <<EOF

${C_ERR}这个发行包里没有预构建的运行环境（缺 payload/rootfs.tar.gz）${C_OFF}

  你下载的可能是「精简包」。安装需要完整包（内含 Ubuntu 运行环境与 LSA，约 66MB）。

  两个选择：
    1. 下载完整发行包：
         https://github.com/a10463981/LSI-Storage-PVE/releases/latest
    2. 自备 LSA 安装包，走源码构建路径（需要联网到镜像站）：
         sudo $0 install --lsa-package /path/to/LSA_Linux.zip

EOF
    exit 2
  fi
  ok "找到预构建运行环境：$PAYLOAD_TAR（$(($(stat -c %s "$PAYLOAD_TAR") / 1024 / 1024)) MB）"
}

payload_verify() {
  local sumfile="$PAYLOAD_DIR_DEFAULT/rootfs.sha256"
  [ -f "$sumfile" ] || sumfile="$(dirname "$PAYLOAD_TAR")/rootfs.sha256"
  if [ -f "$sumfile" ]; then
    local expect
    expect=$(awk '{print $1}' "$sumfile" | head -1)
    say "校验 payload sha256…"
    check_sha256 "$PAYLOAD_TAR" "$expect" || die "payload 校验失败，请重新下载发行包"
    ok "payload 校验通过"
  else
    warn "没有 rootfs.sha256，跳过校验"
  fi
}

payload_show_info() {
  [ -f "$PAYLOAD_INFO" ] || return 0
  local lsa base built
  lsa=$(sed -n 's/^lsa_version=//p' "$PAYLOAD_INFO")
  base=$(sed -n 's/^base=//p' "$PAYLOAD_INFO")
  built=$(sed -n 's/^built_at=//p' "$PAYLOAD_INFO")
  say "载荷信息：$base · LSA ${lsa:-未知} · 构建于 ${built:-未知}"
}

payload_unpack() {
  say "解包运行环境 → $RFS（约 101MB，1–2 分钟）"
  if [ -d "$RFS" ] && [ -n "$(ls -A "$RFS" 2>/dev/null)" ]; then
    say "目标已存在，先清空：$RFS"
    run rm -rf "$RFS"
  fi
  run mkdir -p "$RFS"
  run tar -xzf "$PAYLOAD_TAR" -C "$RFS" --numeric-owner
  if [ "$DRY_RUN" != "1" ]; then
    [ -x "$RFS/bin/bash" ] || die "解包异常：缺 /bin/bash"
    [ -d "$RFS/opt/lsi/LSIStorageAuthority" ] || die "解包异常：缺 LSA 目录"
  fi
  ok "运行环境就绪"
}
