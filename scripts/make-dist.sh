#!/usr/bin/env bash
# make-dist.sh — 打发行包：dist/LSI-Storage-PVE-<版本>.tar.gz + SHA256SUMS
#
# 用法：
#   scripts/make-dist.sh                # 校验 + 打包
#   scripts/make-dist.sh --check        # 只校验，不打包
#   UPSTREAM_DIR=/path/to/fnos scripts/make-dist.sh   # 顺带校验 core 是否与上游一致

set -euo pipefail
IFS=$'\n\t'

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROJ=$(cd "$SELF_DIR/.." && pwd)
cd "$PROJ"

VERSION=$(cat VERSION 2>/dev/null || cat CORE_VERSION 2>/dev/null || echo "0.0.0")
NAME="LSI-Storage-PVE-$VERSION"
DIST="$PROJ/dist"

c_ok=$'\033[1;32m'; c_err=$'\033[1;31m'; c_info=$'\033[1;34m'; c_off=$'\033[0m'
say() { printf '%s[dist]%s %s\n' "$c_info" "$c_off" "$*"; }
die() { printf '%s[错误]%s %s\n' "$c_err" "$c_off" "$*" >&2; exit 2; }

MODE=build
case "${1:-}" in
  --check) MODE=check ;;
  "")      ;;
  -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) die "未知参数：$1" ;;
esac

say "版本：$VERSION"

# ---------- 校验 1：core 快照 ----------
if [ -n "${UPSTREAM_DIR:-}" ]; then
  say "校验 vendor/core 与上游一致性…"
  "$SELF_DIR/sync-core.sh" --check --from "$UPSTREAM_DIR" \
    || die "vendor/core 与上游不一致，先运行 scripts/sync-core.sh"
else
  say "跳过上游一致性校验（未设置 UPSTREAM_DIR）"
fi

# ---------- 校验 2：必需文件 ----------
required=(
  README.md README.en.md LICENSE CORE_VERSION VERSION UPSTREAM
  installer/install.sh installer/systemd/lsa-pve.service.in
  vendor/core/CORE_SHA256
  payload/rootfs.tar.gz payload/rootfs.sha256 payload/PAYLOAD_INFO
)
for f in "${required[@]}"; do
  [ -e "$f" ] || die "仓库不完整，缺少：$f"
done

# ---------- 校验 3：脚本语法 ----------
say "bash -n 全量检查"
fail=0
while IFS= read -r f; do
  bash -n "$f" 2>/dev/null || { printf '  语法错误：%s\n' "$f"; fail=1; }
done < <(find installer scripts -name '*.sh' -type f)
[ "$fail" -eq 0 ] || die "存在语法错误"
say "全部通过"

[ "$MODE" = "check" ] && { say "${c_ok}校验通过${c_off}"; exit 0; }

# ---------- 组装 ----------
say "组装 staging 目录"
STAGE="$DIST/$NAME"
rm -rf "$STAGE"
mkdir -p "$STAGE"

cp -a installer "$STAGE/"
cp -a vendor    "$STAGE/"
cp -a payload   "$STAGE/"
mkdir -p "$STAGE/scripts"
cp -a scripts/sync-core.sh "$STAGE/scripts/"
cp -a README.md README.en.md LICENSE CORE_VERSION VERSION UPSTREAM RELEASE_NOTES.md "$STAGE/" 2>/dev/null || true

# 不把 .git 与缓存带进去
find "$STAGE" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
find "$STAGE" -name '*.pyc' -delete 2>/dev/null || true

say "打包（排序 + 固定 mtime/owner，保证可重复）"
mkdir -p "$DIST"
tar --sort=name --owner=0 --group=0 --numeric-owner \
    --mtime='2026-01-01 00:00:00 UTC' \
    -czf "$DIST/$NAME.tar.gz" -C "$DIST" "$NAME"

( cd "$DIST" && sha256sum "$NAME.tar.gz" > SHA256SUMS )

rm -rf "$STAGE"

say "${c_ok}完成${c_off}"
printf '  %s  %s\n' "$(stat -c %s "$DIST/$NAME.tar.gz") bytes" "$DIST/$NAME.tar.gz"
cat "$DIST/SHA256SUMS" | sed 's/^/  /'
cat <<EOF

上传到 GitHub Release 的资产：
  $NAME.tar.gz
  SHA256SUMS

用户侧用法（固定 tag，不要用 main 分支的 raw 链接）：
  wget https://github.com/<owner>/LSI-Storage-PVE/releases/download/v$VERSION/$NAME.tar.gz
  wget https://github.com/<owner>/LSI-Storage-PVE/releases/download/v$VERSION/SHA256SUMS
  sha256sum -c SHA256SUMS --ignore-missing
  tar xzf $NAME.tar.gz && cd $NAME
  sudo ./installer/install.sh doctor
  sudo ./installer/install.sh install --lsa-package /path/to/LSA_Linux.zip
EOF
