#!/usr/bin/env bash
# commands/install.sh — 全新安装
#
# 每一步都能独立重试：已下载的制品在 $STATE 复用，已解包的 rootfs 在
# --force 之外不会重复解。失败时 trap 回滚到"干净"状态。

install_main() {
  req_root "$@"
  STEP_TOTAL=9

  # 已装则拒绝
  if [ -d "$RFS" ] && [ -f "$RFS/etc/init.d/LsiSASH" ] && [ "${FORCE:-0}" != "1" ]; then
    die "看起来已安装（$RFS 存在且含 LsiSASH）。升级请用：$0 upgrade ；强制重装加 --force"
  fi

  ROLLBACK=1
  trap 'rc=$?; if [ "${ROLLBACK:-0}" = "1" ] && [ "$rc" -ne 0 ]; then
          err "安装未完成（rc=$rc），开始回滚…"
          [ "${KEEP_FAILED:-0}" = "1" ] || { unit_remove || true; rm -rf "$RFS" 2>/dev/null || true; }
          err "回滚结束。日志：${LOG_FILE:-（未启用）}"
        fi' EXIT

  # ---------- 1 预检 ----------
  step "预检"
  [ -d /run/systemd/system ] || die "systemd 未运行，无法安装"
  in_container && die "检测到容器环境，拒绝安装（宿主的 systemd 服务在容器里没有意义）"

  local free_mb
  free_mb=$(disk_free_mb "$(dirname "$PREFIX")")
  [ "${free_mb:-0}" -ge 2048 ] || die "磁盘剩余不足：${free_mb:-?} MB（至少需要 2048 MB）"
  ok "磁盘剩余 ${free_mb} MB"

  port_in_use "$PORT" && die "端口 $PORT 已被占用，换一个：--port <N>"
  port_in_use "$BACKEND_PORT" && die "端口 $BACKEND_PORT 已被占用，换一个：--backend-port <N>"
  ok "端口 $PORT / $BACKEND_PORT 空闲"

  have tar || die "缺少 tar"
  megaraid_present || warn "未检测到 MegaRAID 卡：可以继续安装，界面里将是空列表"

  if [ -z "${LSA_PACKAGE:-}" ]; then
    err "缺少 --lsa-package"
    lsa_guidance
    exit 2
  fi

  # ---------- 2 取 rootfs ----------
  step "准备 Ubuntu rootfs"
  fetch_rootfs

  # ---------- 3 取 LSA 包 ----------
  step "准备 LSA 安装包"
  fetch_lsa

  # ---------- 4 建 chroot ----------
  step "建立 chroot 运行环境"
  rfs_create
  rfs_set_apt_sources

  # ---------- 5 chroot 内装依赖 ----------
  step "在 chroot 内安装运行期依赖"
  say "（这是 Ubuntu 24.04 的独立根文件系统，宿主的 apt 完全没被使用）"
  rfs_install_deps

  # ---------- 6 装 LSA ----------
  step "在 chroot 内安装 LSA"
  rfs_install_lsa

  # ---------- 7 打补丁 ----------
  step "应用兼容性补丁"
  rfs_patch_all

  # ---------- 8 装 unit ----------
  step "安装 systemd 服务"
  write_config
  unit_install

  # ---------- 9 启动 + 健康检查 ----------
  step "启动并等待就绪"
  unit_start
  ROLLBACK=0
  if [ "$DRY_RUN" = "1" ]; then
    say "[dry-run] 跳过就绪等待（真机会轮询 http://127.0.0.1:$PORT/ 直到 200）"
    trap - EXIT
    print_success
    return 0
  fi
  if ! wait_ready; then
    err "服务已安装但未就绪，保留现场以便排查（可用 $0 status / repair）"
    exit 1
  fi

  trap - EXIT
  print_success
}

write_config() {
  [ "$DRY_RUN" = "1" ] && { printf '%s  [dry-run] 写配置 %s（PREFIX=%s PORT=%s BACKEND_PORT=%s）%s\n' "$C_DIM" "$CONF" "$PREFIX" "$PORT" "$BACKEND_PORT" "$C_OFF"; return 0; }
  mkdir -p "$(dirname "$CONF")"
  cat > "$CONF" <<EOF
# 由 installer/install.sh 生成；卸载时 --purge 会一并删除
PREFIX=$PREFIX
PORT=$PORT
BACKEND_PORT=$BACKEND_PORT
LSA_BASELINE=${LSA_BASELINE:-gcc_8.3.x}
INSTALLED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
  chmod 644 "$CONF"
  ok "配置写入 $CONF"
}

print_success() {
  cat <<EOF

${C_OK}安装完成${C_OFF}

  访问地址   http://$(hostname -I 2>/dev/null | awk '{print $1}'):${PORT}
  本机地址   http://127.0.0.1:${PORT}
  安装前缀   ${PREFIX}
  服务名     lsa-pve.service
  日志       ${LOG_FILE}

  登录：LSA 需要系统账号。默认预置了 lsiadmin（锁定态），设置口令后即可登录：

      sudo chroot ${RFS} passwd lsiadmin

  然后浏览器打开上面的地址，用 lsiadmin + 刚设的口令登录。

  常用命令：
      $0 status      # 状态
      $0 doctor      # 体检
      $0 uninstall   # 卸载

EOF
}
