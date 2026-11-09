#!/usr/bin/env bash
# fetch.sh — 获取 Ubuntu rootfs 与 LSA 安装包
#
# 两个来源都可以是本地文件（离线场景）：--rootfs-file / --lsa-package。
# 下载一律支持断点续传 + 重试；校验不通过绝不进入下一步。

# ---------- Ubuntu base rootfs ----------
fetch_rootfs() {
  local url=${ROOTFS_URL:-$ROOTFS_URL_DEFAULT}
  local sha=${ROOTFS_SHA:-$ROOTFS_SHA_DEFAULT}
  local out="$STATE/rootfs-base.tar.gz"

  if [ -n "${ROOTFS_FILE:-}" ]; then
    [ -f "$ROOTFS_FILE" ] || die "指定的 --rootfs-file 不存在：$ROOTFS_FILE"
    say "使用本地 rootfs：$ROOTFS_FILE"
    check_sha256 "$ROOTFS_FILE" "$sha" || die "本地 rootfs 校验失败"
    ROOTFS_TAR="$ROOTFS_FILE"
    return 0
  fi

  if [ "${DRY_RUN:-0}" = "1" ]; then
    printf '%s  [dry-run] 下载 %s → %s%s\n' "$C_DIM" "$url" "$out" "$C_OFF"
    ROOTFS_TAR="$out"
    return 0
  fi
  run mkdir -p "$STATE"
  if [ -f "$out" ] && check_sha256 "$out" "$sha" 2>/dev/null; then
    ok "已存在且校验通过的 rootfs：$out"
    ROOTFS_TAR="$out"
    return 0
  fi

  say "下载 Ubuntu base rootfs（约 30MB）"
  say "  $url"
  local tries=0
  while [ $tries -lt 3 ]; do
    tries=$((tries + 1))
    if http_fetch "$url" "$out"; then
      if check_sha256 "$out" "$sha"; then
        ROOTFS_TAR="$out"
        ok "rootfs 下载并校验通过"
        return 0
      fi
      warn "校验失败，删除重下（第 $tries 次）"
      run rm -f "$out"
    else
      warn "下载中断（第 $tries 次），准备续传"
    fi
    sleep 2
  done
  die "rootfs 下载失败。可手动下载后使用 --rootfs-file <路径>：
  $url
  期望 sha256: $sha"
}

# ---------- LSA 安装包 ----------
# LSA 是 Broadcom 专有二进制，不随本项目分发，必须由用户提供。
lsa_guidance() {
  cat <<'EOF'

需要 Broadcom LSA 的 Linux 安装包（约 166MB），文件名通常形如：

    008.018.012.000_MR_7.38_LSA_Linux.zip

获取途径（二选一，均由你自己操作）：
  1. 服务器厂商支持页搜 "LSI Storage Authority"（Dell/HPE/浪潮/华为…），
     多数不需要注册，下载到的就是上面这个 zip
  2. Broadcom 支持站 → 你的 MegaRAID 卡型号（如 9460-8i）→ Management Software
     （需要注册账号）

拿到后放到机器上，然后：

    sudo ./installer/install.sh install --lsa-package /root/008.018.012.000_MR_7.38_LSA_Linux.zip

也支持直链（你自己的下载地址）：

    sudo ./installer/install.sh install --lsa-package https://example.com/LSA_Linux.zip

EOF
}

fetch_lsa() {
  local pkg=${LSA_PACKAGE:-}
  [ -n "$pkg" ] || { err "未提供 --lsa-package"; lsa_guidance; exit 2; }

  case "$pkg" in
    http://*|https://*)
      run mkdir -p "$STATE"
      local out="$STATE/LSA_Linux.zip"
      if [ "${DRY_RUN:-0}" = "1" ]; then
        printf '%s  [dry-run] 下载 %s → %s%s\n' "$C_DIM" "$pkg" "$out" "$C_OFF"
        LSA_ZIP="$out"
        return 0
      fi
      say "下载 LSA 安装包：$pkg"
      if ! http_fetch "$pkg" "$out"; then
        die "LSA 包下载失败：$pkg"
      fi
      LSA_ZIP="$out"
      ;;
    *)
      [ -f "$pkg" ] || { err "LSA 包不存在：$pkg"; lsa_guidance; exit 2; }
      LSA_ZIP=$(cd "$(dirname "$pkg")" && pwd)/$(basename "$pkg")
      ;;
  esac

  if [ "${DRY_RUN:-0}" = "1" ]; then
    printf '%s  [dry-run] 跳过 zip 完整性校验%s\n' "$C_DIM" "$C_OFF"
  else
    verify_zip "$LSA_ZIP" || die "LSA 包不是有效的 zip：$LSA_ZIP"
  fi
  local mb; mb=$(( $(stat -c %s "$LSA_ZIP") / 1024 / 1024 ))
  ok "LSA 包就绪：$LSA_ZIP（${mb}MB）"
}

# zip 完整性：优先 unzip -t，其次 python3 zipfile，最后只验魔数
verify_zip() {
  local z=$1
  [ -f "$z" ] || return 1
  if have unzip; then
    unzip -tqq "$z" >/dev/null 2>&1 || return 1
    return 0
  fi
  if have python3; then
    python3 - "$z" <<'PY' >/dev/null 2>&1 || return 1
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    bad = z.testzip()
    if bad: raise SystemExit(1)
PY
    return 0
  fi
  # 兜底：只看魔数 PK\x03\x04
  local magic
  magic=$(head -c 4 "$z" | od -An -tx1 | tr -d ' \n')
  [ "$magic" = "504b0304" ]
}

# 解 zip（宿主可能没有 unzip）
unzip_to() {   # unzip_to <zip> <dir>
  local z=$1 d=$2
  mkdir -p "$d"
  if have unzip; then
    unzip -q -o "$z" -d "$d"
  elif have python3; then
    python3 - "$z" "$d" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    z.extractall(sys.argv[2])
PY
  else
    die "需要 unzip 或 python3 才能解压 LSA 包；请先手动解压后用 --lsa-extracted 指定目录"
  fi
}
