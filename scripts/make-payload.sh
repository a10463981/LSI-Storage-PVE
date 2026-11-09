#!/usr/bin/env bash
# make-payload.sh — 产出 payload/rootfs.tar.gz（预构建的 Ubuntu + LSA 运行环境）
#
# 设计：发行包直接带"装好的 rootfs"，用户安装时只解包 + 改端口 + 起服务，
# 全程不联网、不在 chroot 里跑 apt。原因见 README「为什么包这么大」。
#
# 用法：
#   scripts/make-payload.sh                      # 用默认源（../LSI-Storage-Fnos/build/work/rootfs 或 --rootfs-src）
#   scripts/make-payload.sh --rootfs-src <目录>   # 指定一份已构建好的 rootfs
#   scripts/make-payload.sh --build              # 从零构建（调 vendor/core/build 00→60，需要联网到 TUNA）
#   scripts/make-payload.sh --smoke              # 打包前先在构建机上把 LSA 起到 API 200
#
# 构建机要求：Linux x86_64、root、能访问 TUNA（仅 --build 时需要）、有 LSA 安装包。

set -euo pipefail
IFS=$'\n\t'

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJ=$(cd "$SELF_DIR/.." && pwd)
cd "$PROJ"

PAYLOAD_DIR="$PROJ/payload"
RFS_SRC=""
DO_BUILD=0
DO_SMOKE=0
LSA_ZIP="${LSA_ZIP:-}"

ROOTFS_URL="http://mirrors.tuna.tsinghua.edu.cn/ubuntu-cdimage/ubuntu-base/releases/24.04/release/ubuntu-base-24.04.5-base-amd64.tar.gz"
ROOTFS_SHA="e77b6f10c2590cef872b33ee9f635a0e3fd1f57fb074c0e52b5c7f56147a0c86"
LSA_BASELINE="${LSA_BASELINE:-gcc_8.3.x}"

c_ok=$'\033[1;32m'; c_err=$'\033[1;31m'; c_info=$'\033[1;34m'; c_warn=$'\033[1;33m'; c_off=$'\033[0m'
say()  { printf '%s[payload]%s %s\n' "$c_info" "$c_off" "$*"; }
ok()   { printf '%s[payload]%s %s\n' "$c_ok" "$c_off" "$*"; }
warn() { printf '%s[payload]%s %s\n' "$c_warn" "$c_off" "$*"; }
die()  { printf '%s[payload]%s %s\n' "$c_err" "$c_off" "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --rootfs-src) RFS_SRC="${2:-}"; shift 2 ;;
    --build)      DO_BUILD=1; shift ;;
    --smoke)      DO_SMOKE=1; shift ;;
    --lsa-zip)    LSA_ZIP="${2:-}"; shift 2 ;;
    -h|--help)    sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "未知参数：$1" ;;
  esac
done

[ "$(id -u)" -eq 0 ] || die "需要 root（要 chroot 进 rootfs 做清理与冒烟）"

WORK="$PROJ/build/payload-work"
RFS="$WORK/rootfs"

# ---------- 1. 取得 rootfs ----------
if [ "$DO_BUILD" = "1" ]; then
  say "从零构建 rootfs（调用 vendor/core/build，需要联网到 TUNA）"
  CORE="$PROJ/vendor/core/build"
  [ -d "$CORE" ] || die "缺少 vendor/core/build，先运行 scripts/sync-core.sh"
  [ -n "$LSA_ZIP" ] || die "--build 需要 --lsa-zip <LSA安装包>"
  export LSA_ZIP ROOTFS_URL ROOTFS_SHA LSA_BASELINE
  # core 的脚本以"仓库根/build/work/rootfs"为工作目录，这里给它们一个独立根
  CORE_ROOT="$PROJ/build/core-root"
  mkdir -p "$CORE_ROOT/build"
  ln -sfn "$CORE" "$CORE_ROOT/build/scripts" 2>/dev/null || true
  die "--build 模式尚未接线到 core 的目录约定，请先用 --rootfs-src 指定一份已构建 rootfs（见 README）"
elif [ -n "$RFS_SRC" ]; then
  [ -d "$RFS_SRC/opt/lsi/LSIStorageAuthority" ] || die "指定的目录不像已构建 rootfs（缺 opt/lsi/LSIStorageAuthority）：$RFS_SRC"
  say "使用现有 rootfs：$RFS_SRC"
  rm -rf "$WORK"; mkdir -p "$WORK"
  say "复制（102MB 级别，稍慢）"
  cp -a "$RFS_SRC/." "$RFS/"
else
  # 默认尝试同目录下的 fpk 仓库构建现场
  for cand in "$PROJ/../LSI-Storage-Fnos/build/work/rootfs"; do
    if [ -d "$cand/opt/lsi/LSIStorageAuthority" ]; then
      say "发现现有 rootfs：$cand"
      rm -rf "$WORK"; mkdir -p "$WORK"
      cp -a "$cand/." "$RFS/"
      RFS_SRC="$cand"
      break
    fi
  done
  [ -d "$RFS/opt/lsi/LSIStorageAuthority" ] || die "找不到已构建的 rootfs。用 --rootfs-src 指定，或 --build（需联网）"
fi

[ -d "$RFS/opt/lsi/LSIStorageAuthority" ] || die "rootfs 不完整（缺 LSA）"
ok "rootfs 就绪"

# ---------- 2. 配置回退到占位符（安装时按用户参数替换）----------
say "把 LSA 配置回退到端口占位符"
LSA="$RFS/opt/lsi/LSIStorageAuthority"
for pair in "$LSA/conf/LSA.conf" "$LSA/server/conf/nginx.conf"; do
  if [ -f "$pair.dist" ]; then
    cp -a "$pair.dist" "$pair"
  else
    warn "缺少 $(basename "$pair").dist，跳过（安装时无法参数化端口）"
  fi
done
PH=$(grep -o 'nginx_default\|LSA_Default' "$LSA/conf/LSA.conf" "$LSA/server/conf/nginx.conf" 2>/dev/null | wc -l)
[ "$PH" -gt 0 ] && ok "占位符已恢复（$PH 处）" || warn "配置里没有占位符，端口将无法参数化"

# ---------- 3. 清理运行痕迹与缓存 ----------
say "清理缓存与运行痕迹"
rm -rf "$RFS/var/cache/apt" "$RFS/var/lib/apt/lists"/* "$RFS/tmp/"* 2>/dev/null || true
rm -rf "$RFS/opt/lsi/LSIStorageAuthority/logs/"*.txt 2>/dev/null || true
rm -f  "$RFS/home/lsiadmin/.bash_history" "$RFS/root/.bash_history" 2>/dev/null || true
rm -rf "$RFS/var/log/lsi-storage-pve" 2>/dev/null || true

# 账号：确保存在且是锁定态（安装后由用户 passwd 设置）
if ! chroot "$RFS" id lsiadmin >/dev/null 2>&1; then
  warn "rootfs 里没有 lsiadmin，补建"
  unshare -m --propagation private /bin/bash -c '
    set -e; RFS="$1"
    mount --rbind /dev "$RFS/dev"; mount --rbind /proc "$RFS/proc"
    chroot "$RFS" useradd -m -u 2000 -s /bin/bash lsiadmin
    chroot "$RFS" passwd -l lsiadmin >/dev/null 2>&1 || true
  ' _ "$RFS"
fi
chroot "$RFS" passwd -l lsiadmin >/dev/null 2>&1 || true
ok "账号 lsiadmin 就绪（锁定态）"

# ---------- 4. 冒烟（可选）----------
smoke_test() {
  local tp=24863 tb=24864
  say "冒烟测试：临时端口 $tp/$tb"
  local S="$WORK/smoke"
  rm -rf "$S"; cp -a "$RFS" "$S"
  local C="$S/opt/lsi/LSIStorageAuthority/conf/LSA.conf"
  local N="$S/opt/lsi/LSIStorageAuthority/server/conf/nginx.conf"
  sed -i "s/nginx_default/$tp/g; s/LSA_Default/$tb/g" "$C" "$N"

  local started=0
  unshare -m --propagation private /bin/bash -c '
    set -e
    R="$1"
    mount --rbind /dev "$R/dev"; mount --rbind /proc "$R/proc"; mount --rbind /sys "$R/sys"
    chroot "$R" /etc/init.d/LsiSASH start
  ' _ "$S" || { warn "LSA 启动命令返回非零"; }

  local i code
  for i in $(seq 1 40); do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$tp/LSI/Storage/MR/API/1.0/" 2>/dev/null || echo 000)
    if [ "$code" = "200" ]; then started=1; break; fi
    sleep 5
  done

  unshare -m --propagation private /bin/bash -c '
    set -e; R="$1"
    mount --rbind /dev "$R/dev"; mount --rbind /proc "$R/proc"
    chroot "$R" /etc/init.d/LsiSASH stop || true
  ' _ "$S" || true

  if [ "$started" = "1" ]; then
    ok "冒烟通过：API 返回 200（端口 $tp）"
  else
    warn "冒烟未通过（最后状态 HTTP ${code:-000}）——payload 仍会生成，但需在真机复核"
    warn "  日志：$S/opt/lsi/LSIStorageAuthority/logs/lsa.txt"
  fi
  rm -rf "$S"
}

[ "$DO_SMOKE" = "1" ] && smoke_test

# ---------- 5. 打包 ----------
say "打包 rootfs.tar.gz（单线程 gzip，约 1–3 分钟）"
mkdir -p "$PAYLOAD_DIR"
rm -f "$PAYLOAD_DIR/rootfs.tar.gz"
# tar 可能因个别不可读文件返回非零，但归档仍然可用；用后面的完整性校验兜底
set +e
tar --numeric-owner -cf - -C "$RFS" . 2>"$WORK/tar.err" | gzip -6 > "$PAYLOAD_DIR/rootfs.tar.gz"
TAR_RC=$?
set -e
[ -s "$PAYLOAD_DIR/rootfs.tar.gz" ] || die "打包失败（输出为空）"
[ "$TAR_RC" -eq 0 ] || warn "tar 返回 $TAR_RC（可能有不可读文件），继续校验归档完整性"

# 完整性校验：能列出目录 + 关键文件都在
gzip -t "$PAYLOAD_DIR/rootfs.tar.gz" || die "归档损坏（gzip -t 失败）"
for must in ./opt/lsi/LSIStorageAuthority/bin/LSA ./etc/init.d/LsiSASH ./usr/bin/bash \
            ./opt/lsi/LSIStorageAuthority/conf/LSA.conf; do
  tar -tzf "$PAYLOAD_DIR/rootfs.tar.gz" "$must" >/dev/null 2>&1 \
    || die "归档缺少关键路径：$must"
done
ok "归档完整性校验通过"

SHA=$(sha256sum "$PAYLOAD_DIR/rootfs.tar.gz" | awk '{print $1}')
SIZE=$(stat -c %s "$PAYLOAD_DIR/rootfs.tar.gz")
printf '%s  rootfs.tar.gz\n' "$SHA" > "$PAYLOAD_DIR/rootfs.sha256"

LSA_VER=$( { sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
          "$RFS/opt/lsi/LSIStorageAuthority/server/html/message_en.js" 2>/dev/null || true; } | head -1 || true)
[ -n "$LSA_VER" ] || LSA_VER="008.018.012.000"

cat > "$PAYLOAD_DIR/PAYLOAD_INFO" <<EOF
# 由 scripts/make-payload.sh 生成；安装器只读它做展示与校验
format=1
built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
base=ubuntu-base-24.04.5
lsa_version=$LSA_VER
lsa_baseline=$LSA_BASELINE
rootfs_tar_size=$SIZE
rootfs_tar_sha256=$SHA
rootfs_unpacked_size=$(du -sm "$RFS" 2>/dev/null | cut -f1)
installed_account=lsiadmin
note=configs 使用端口占位符（nginx_default / LSA_Default），安装时按 --port / --backend-port 替换
EOF

ok "payload 完成"
printf '  %s\n' "$PAYLOAD_DIR/rootfs.tar.gz"
printf '  大小    %s bytes（%s MB）\n' "$SIZE" "$((SIZE / 1024 / 1024))"
printf '  sha256  %s\n' "$SHA"
printf '  解包后  %s MB\n' "$(du -sm "$RFS" 2>/dev/null | cut -f1)"
echo
say "下一步：scripts/make-dist.sh 会把 payload/ 一起打进发行包"
