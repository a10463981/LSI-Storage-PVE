#!/usr/bin/env bash
# patch.sh — 构建期补丁（与 vendor/core/build/40-patch.sh 对应，端口与前缀参数化）
#
# 与 fnOS 版的差异：端口直接写成用户指定的值（PVE 版不跑门户，LSA 的 nginx
# 直接对外），不做"构建期占位 + 运行期注入"那一套。
#
# 补丁集（顺序不能变）：
#   1  libcrypt.so.2 → libcrypt.so.1
#   2  libslp.so.1   → libslp.so.1.0.0
#   3  server/html/ui/js → ../js
#   3b /usr/local/var/log 等目录（slpd 依赖，缺了会静默失败）
#   3c init 脚本里 LD_LIBRARY_PATH 覆盖（只检测并修正）
#   3d libldap-2.4.so.2 → libldap.so.2（gcc8 基线需要）
#   3e 注释 X-Frame-Options（允许被嵌入）
#   4  端口占位符 → 实际端口
#   5  log_level 64 → 4（否则日志刷盘）
#   6  预置账号 lsiadmin（锁定态，运行期只 chpasswd）

PATCH_LIST="1 libcrypt.so.2->libcrypt.so.1 | 2 libslp.so.1->libslp.so.1.0.0 | 3 ui/js->../js | 3b /usr/local/var/log | 3c LD_LIBRARY_PATH 检测 | 3d libldap-2.4.so.2->libldap.so.2 | 3e X-Frame-Options | 4 端口占位符->$PORT/$BACKEND_PORT | 5 log_level->4 | 6 预置账号 lsiadmin"

rfs_patch_all() {
  local LSA="$RFS/opt/lsi/LSIStorageAuthority"
  if [ "$DRY_RUN" = "1" ]; then
    say "[dry-run] 将应用补丁："
    printf '%s\n' "$PATCH_LIST" | tr '|' '\n' | sed 's/^ /         /'
    return 0
  fi
  [ -d "$LSA" ] || die "补丁阶段：LSA 未安装"
  local libdir="$RFS/usr/lib/x86_64-linux-gnu"

  # ---- 1 libcrypt ----
  if [ -e "$libdir/libcrypt.so.1" ]; then
    run ln -sfn libcrypt.so.1 "$libdir/libcrypt.so.2"
    ok "补丁1：libcrypt.so.2 → libcrypt.so.1"
  else
    warn "补丁1：找不到 libcrypt.so.1，跳过"
  fi

  # ---- 2 libslp ----
  if [ -e "$LSA/../LSA/libs2/libslp.so.1.0.0" ]; then
    run ln -sfn libslp.so.1.0.0 "$RFS/opt/lsi/LSA/libs2/libslp.so.1"
    ok "补丁2：libslp.so.1 → libslp.so.1.0.0"
  else
    warn "补丁2：libs2/libslp.so.1.0.0 不存在，跳过"
  fi

  # ---- 3 ui/js ----
  run mkdir -p "$LSA/server/html/ui"
  if [ -d "$LSA/server/html/js" ]; then
    run ln -sfn ../js "$LSA/server/html/ui/js"
    ok "补丁3：ui/js → ../js"
  else
    warn "补丁3：server/html/js 不存在，跳过"
  fi

  # ---- 3b slpd 需要的目录 ----
  run mkdir -p "$RFS/usr/local/var/log" "$RFS/usr/local/var/run" "$RFS/usr/local/var/lib"
  run chmod 755 "$RFS/usr/local/var/log"
  ok "补丁3b：/usr/local/var/log 已就绪"

  # ---- 3c init 脚本 LD_LIBRARY_PATH ----
  local INIT="$RFS/etc/init.d/LsiSASH"
  if [ -f "$INIT" ]; then
    if grep -qE '^[[:space:]]*export LD_LIBRARY_PATH=/opt/lsi/LSA/libs2[[:space:]]*$' "$INIT"; then
      run sed -i -E 's#^([[:space:]]*export LD_LIBRARY_PATH=)/opt/lsi/LSA/libs2([[:space:]]*)$#\1/opt/lsi/LSA/libs:/opt/lsi/LSA/libs2\2#' "$INIT"
      ok "补丁3c：已补上 /opt/lsi/LSA/libs（这是灰屏的根因）"
    else
      ok "补丁3c：init 脚本路径形态已正确，无需修改"
    fi
  fi

  # ---- 3d libldap soname ----
  if [ ! -e "$libdir/libldap-2.4.so.2" ] && [ -e "$libdir/libldap.so.2" ]; then
    run ln -sfn libldap.so.2 "$libdir/libldap-2.4.so.2"
    ok "补丁3d：libldap-2.4.so.2 → libldap.so.2"
  fi

  # ---- 3e X-Frame-Options ----
  local NGX="$LSA/server/conf/nginx.conf"
  if [ -f "$NGX" ] && grep -qE '^[[:space:]]*add_header[[:space:]]+X-Frame-Options' "$NGX"; then
    run sed -i -E 's|^([[:space:]]*)(add_header[[:space:]]+X-Frame-Options.*)$|\1# \2  # disabled by lsi-storage-pve|' "$NGX"
    ok "补丁3e：已注释 $(grep -c 'disabled by lsi-storage-pve' "$NGX") 处 X-Frame-Options"
  fi

  # ---- 4 端口占位符 ----
  local CONF="$LSA/conf/LSA.conf"
  [ -f "$CONF" ] || die "补丁阶段：缺 $CONF"
  [ -f "$CONF.dist" ] || run cp -a "$CONF" "$CONF.dist"
  [ -f "$NGX" ] && { [ -f "$NGX.dist" ] || run cp -a "$NGX" "$NGX.dist"; }

  local hits
  hits=$(grep -oE 'nginx_default|LSA_Default' "$CONF" "$NGX" 2>/dev/null | wc -l)
  say "补丁4：端口占位符 $hits 处 → nginx=$PORT 后端=$BACKEND_PORT"
  run sed -i "s/nginx_default/${PORT}/g; s/LSA_Default/${BACKEND_PORT}/g" "$CONF"
  [ -f "$NGX" ] && run sed -i "s/nginx_default/${PORT}/g; s/LSA_Default/${BACKEND_PORT}/g" "$NGX"
  if grep -qE 'nginx_default|LSA_Default' "$CONF" 2>/dev/null; then
    die "补丁4：占位符未清干净，配置结构可能变化，需人工核对"
  fi
  ok "补丁4：端口已写入（$PORT / $BACKEND_PORT）"

  # ---- 5 日志级别 ----
  if grep -qE '^[[:space:]]*log_level[[:space:]]*=' "$CONF"; then
    local old
    old=$(grep -E '^[[:space:]]*log_level[[:space:]]*=' "$CONF" | head -1 | sed 's/.*=[[:space:]]*//')
    run sed -i -E 's#^([[:space:]]*log_level[[:space:]]*=[[:space:]]*).*#\14#' "$CONF"
    ok "补丁5：log_level $old → 4（ERROR）"
  fi

  # ---- 6 预置账号 ----
  rfs_run "id lsiadmin >/dev/null 2>&1 || useradd -m -u 2000 -s /bin/bash lsiadmin; passwd -l lsiadmin >/dev/null 2>&1 || true" \
    || warn "补丁6：预置账号失败（不影响只读查看，登录时需自行建号）"
  ok "补丁6：lsiadmin 账号已就绪（锁定态，需设置口令后才能登录）"

  # 只读组（尽力而为）
  if grep -qE '^[[:space:]]*readonly_access_groups' "$CONF" 2>/dev/null; then
    run sed -i -E 's#^([[:space:]]*readonly_access_groups[[:space:]]*=[[:space:]]*).*#\1lsiadmin#' "$CONF"
    ok "readonly_access_groups = lsiadmin"
  fi
}

# ---------- 端口参数化（payload 路径用）----------
# payload 里的配置保留着占位符（nginx_default / LSA_Default），安装时按用户参数替换。
# 若用户选的正好是默认值，结果与默认一致。
rfs_apply_ports() {
  local LSA="$RFS/opt/lsi/LSIStorageAuthority"
  local CONF="$LSA/conf/LSA.conf" NGX="$LSA/server/conf/nginx.conf"
  if [ "$DRY_RUN" = "1" ]; then
    printf '%s  [dry-run] 把 %s 与 %s 里的端口占位符替换为 %s / %s%s\n' \
      "$C_DIM" "$CONF" "$NGX" "$PORT" "$BACKEND_PORT" "$C_OFF"
    return 0
  fi
  [ -f "$CONF" ] || die "缺少 $CONF"
  [ -f "$NGX" ]  || die "缺少 $NGX"

  local hits
  hits=$(grep -oE 'nginx_default|LSA_Default' "$CONF" "$NGX" 2>/dev/null | wc -l)
  if [ "$hits" -eq 0 ]; then
    warn "配置里没有端口占位符，跳过替换（可能是已参数化过的 rootfs）"
    return 0
  fi
  run sed -i "s/nginx_default/${PORT}/g; s/LSA_Default/${BACKEND_PORT}/g" "$CONF" "$NGX"
  if [ "$DRY_RUN" != "1" ] && grep -qE 'nginx_default|LSA_Default' "$CONF" "$NGX"; then
    die "端口占位符未清干净"
  fi
  ok "端口已写入：前端 $PORT / 后端 $BACKEND_PORT（替换 $hits 处）"
}

# ---------- 符号链接幂等校验（payload 里应已建好）----------
rfs_verify_links() {
  if [ "$DRY_RUN" = "1" ]; then
    printf '%s  [dry-run] 校验 3 处库符号链接与前端 js 链接（缺失则重建）%s\n' "$C_DIM" "$C_OFF"
    return 0
  fi
  local libdir="$RFS/usr/lib/x86_64-linux-gnu" bad=0
  check_link() {   # check_link <链接> <目标> <说明>
    local l="$1" t="$2" d="$3"
    if [ -L "$l" ] && [ "$(readlink "$l")" = "$t" ] && [ -e "$l" ]; then return 0; fi
    warn "符号链接缺失或指向不对：$d（修复中）"
    ln -sfn "$t" "$l" 2>/dev/null || { err "无法重建 $l"; bad=1; }
  }
  check_link "$libdir/libcrypt.so.2"        "libcrypt.so.1"  "libcrypt soname"
  check_link "$libdir/libldap-2.4.so.2"     "libldap.so.2"   "libldap 2.4 soname"
  check_link "$RFS/opt/lsi/LSA/libs2/libslp.so.1" "libslp.so.1.0.0" "libslp"
  if [ -d "$RFS/opt/lsi/LSIStorageAuthority/server/html/js" ]; then
    check_link "$RFS/opt/lsi/LSIStorageAuthority/server/html/ui/js" "../js" "前端 js 目录"
  fi
  [ "$bad" -eq 0 ] && ok "库符号链接校验通过" || die "符号链接修复失败"
}
