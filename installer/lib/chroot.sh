#!/usr/bin/env bash
# chroot.sh — 构建与操作 $PREFIX/rootfs
#
# ⚠️ 关于 apt 的重要说明（请勿误解）
#   下面所有 apt 调用都发生在 chroot 内部：目标是 $PREFIX/rootfs 这个**独立的
#   Ubuntu 24.04 根文件系统**，它有自己的 /etc/apt、自己的包数据库、自己的 dpkg。
#   宿主（Debian / PVE）的 apt 与包状态完全不参与，本工具**从不**在宿主执行 apt。
#   chroot 里能用 apt，正是因为它是另一个系统；宿主 apt 坏掉不影响这里。

# 在私有挂载命名空间里进入 chroot 执行命令；离开命名空间时挂载自动消失，
# 因此这里**没有任何 umount**，也就不可能误伤宿主的 /dev /proc /sys。
rfs_run() {   # rfs_run "<chroot 内要执行的命令字符串>"
  local cmd=$1
  if [ "${DRY_RUN:-0}" = "1" ]; then
    printf '%s  [dry-run] chroot %s: %s%s\n' "$C_DIM" "$RFS" "$cmd" "$C_OFF"
    return 0
  fi
  unshare -m --propagation private /bin/bash -c '
    set -e
    RFS="$1"; shift
    mount --rbind /dev  "$RFS/dev"
    mount --rbind /proc "$RFS/proc"
    mount --rbind /sys  "$RFS/sys"
    mount -t tmpfs tmpfs "$RFS/dev/shm" 2>/dev/null || true
    chroot "$RFS" /bin/bash -c "$*"
  ' _ "$RFS" "$cmd"
}

# ---------- 建 chroot ----------
rfs_create() {
  [ -n "${ROOTFS_TAR:-}" ] || die "内部错误：rootfs 未准备"
  run mkdir -p "$PREFIX"
  if [ -d "$RFS" ] && [ -n "$(ls -A "$RFS" 2>/dev/null)" ]; then
    say "已存在 rootfs，先清空：$RFS"
    run rm -rf "$RFS"
  fi
  run mkdir -p "$RFS"
  say "解包 rootfs → $RFS"
  run tar -xzf "$ROOTFS_TAR" -C "$RFS"
  if [ "$DRY_RUN" != "1" ]; then
    [ -x "$RFS/bin/bash" ] || die "rootfs 解包异常（缺 /bin/bash）"
  fi
  ok "rootfs 就绪（$(du -sm "$RFS" 2>/dev/null | cut -f1 || echo '?') MB）"
}

# ---------- apt 源：必须用 HTTP ----------
# ubuntu-base 镜像不含 ca-certificates，https 源会直接失败。
rfs_set_apt_sources() {
  local mirror=${APT_MIRROR:-http://mirrors.tuna.tsinghua.edu.cn/ubuntu}
  say "写入 chroot 内 apt 源（HTTP，$mirror）"
  run_shell "cat > '$RFS/etc/apt/sources.list' <<'EOF'
deb $mirror noble main restricted universe multiverse
deb $mirror noble-updates main restricted universe multiverse
EOF"
  # 24.04 的 base 镜像用 deb822 格式，旧的 .sources 必须清掉，否则会去拉 https
  run_shell "rm -f '$RFS'/etc/apt/sources.list.d/*.sources '$RFS'/etc/apt/sources.list.d/*.list 2>/dev/null || true"
  # DNS：容器/精简环境里 rootfs 自带的 resolv.conf 常常是空文件
  if [ -s /etc/resolv.conf ]; then
    run cp -f /etc/resolv.conf "$RFS/etc/resolv.conf"
  fi
}

# ---------- 装依赖（chroot 内）----------
rfs_install_deps() {
  say "在 chroot 内安装运行期依赖（宿主的 apt 不参与）"
  say "  包：libldap2 libsasl2-2 libaio1t64 libtinfo6 zlib1g libstdc++6 passwd"
  rfs_run "export DEBIAN_FRONTEND=noninteractive
apt-get update -qq || apt-get update
apt-get install -y --no-install-recommends \
  libldap2 libsasl2-2 libaio1t64 libtinfo6 zlib1g libstdc++6 passwd" \
    || die "chroot 内依赖安装失败。多为网络或 DNS 问题，可重跑 install（会复用已解包的 rootfs）"
  ok "依赖安装完成"
}

# ---------- 装 LSA ----------
rfs_install_lsa() {
  local baseline=${LSA_BASELINE:-gcc_8.3.x}
  local work="$STATE/lsa-extract"
  if [ "$DRY_RUN" = "1" ]; then
    say "[dry-run] 将执行：解外层 zip → 解内层 → 选 $baseline 基线 → chroot 内 dpkg -i"
    return 0
  fi
  rm -rf "$work"; mkdir -p "$work/outer"

  say "解 LSA 包（外层）"
  unzip_to "$LSA_ZIP" "$work/outer"

  local inner srcroot
  inner=$(find "$work/outer" -type f -name 'LSA_Linux.zip' | head -1)
  if [ -n "$inner" ]; then
    say "解内层（约 165MB，稍慢）"
    mkdir -p "$work/inner"
    unzip_to "$inner" "$work/inner"
    srcroot="$work/inner"
  else
    srcroot="$work/outer"
  fi

  local basedir
  basedir=$(find "$srcroot" -maxdepth 3 -type d -name "$baseline" | head -1)
  if [ -z "$basedir" ]; then
    err "在包里找不到基线目录 $baseline，实际可用："
    find "$srcroot" -maxdepth 3 -type d -name 'gcc_*' 2>/dev/null | sed 's/^/    /' >&2
    die "请确认 LSA 包版本（本工具需要含 gcc_8.3.x 基线的包）"
  fi

  local debs
  debs=$(ls -1 "$basedir"/*.deb 2>/dev/null || true)
  [ -n "$debs" ] || die "$basedir 下没有 .deb 文件"
  say "基线 = $baseline，共 $(echo "$debs" | wc -l) 个 deb"

  run rm -rf "$RFS/tmp/lsadeb"
  run mkdir -p "$RFS/tmp/lsadeb"
  # shellcheck disable=SC2086
  run cp $debs "$RFS/tmp/lsadeb/"

  say "chroot 内 dpkg -i"
  rfs_run "dpkg -i /tmp/lsadeb/*.deb" || die "dpkg 安装失败（日志：$LOG_FILE）"
  run rm -rf "$RFS/tmp/lsadeb"

  [ -d "$RFS/opt/lsi/LSIStorageAuthority" ] || die "安装后未出现 /opt/lsi/LSIStorageAuthority"
  [ -f "$RFS/etc/init.d/LsiSASH" ] || warn "未找到 /etc/init.d/LsiSASH（可能版本不同）"
  ok "LSA 已装入 chroot（opt/lsi = $(du -sm "$RFS/opt/lsi" 2>/dev/null | cut -f1) MB）"
}

# ---------- 清理 chroot 运行痕迹（回滚用）----------
rfs_destroy() {
  say "删除 rootfs：$RFS"
  run rm -rf "$RFS"
}
