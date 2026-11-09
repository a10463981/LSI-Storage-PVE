#!/usr/bin/env bash
# commands/install.sh — 全新安装
#
# 两条路径：
#   默认（payload）  解包预构建 rootfs → 改端口 → 起服务。离线、1–2 分钟。
#   高级（--lsa-package）  从 Ubuntu base 现装 + chroot 内 apt + dpkg，需要网络。
#
# 每一步都能独立重试；失败时 trap 回滚到干净状态。

install_main() {
  req_root "$@"

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
  if [ -n "${LSA_PACKAGE:-}" ]; then STEP_TOTAL=9; else STEP_TOTAL=6; fi
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

  if [ -n "${LSA_PACKAGE:-}" ]; then
    install_from_source
  else
    install_from_payload
  fi
}

# ==================== 默认路径：预构建 payload ====================
install_from_payload() {
  step "检查发行包内的运行环境"
  payload_locate
  payload_verify
  payload_show_info

  step "解包预构建 rootfs（不联网、不执行 apt）"
  payload_unpack

  step "按参数写入端口并校验链接"
  rfs_apply_ports
  rfs_verify_links

  step "安装 systemd 服务"
  write_config
  unit_install

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

# ==================== 高级路径：自备 LSA 包现装 ====================
install_from_source() {
  step "准备 Ubuntu rootfs（需要网络）"
  fetch_rootfs

  step "准备 LSA 安装包"
  fetch_lsa

  step "建立 chroot 运行环境"
  rfs_create
  rfs_set_apt_sources

  step "在 chroot 内安装运行期依赖"
  say "（这是 Ubuntu 24.04 的独立根文件系统，宿主的 apt 完全没被使用）"
  rfs_install_deps

  step "在 chroot 内安装 LSA"
  rfs_install_lsa

  step "应用兼容性补丁"
  rfs_patch_all

  step "安装 systemd 服务"
  write_config
  unit_install

  step "启动并等待就绪"
  unit_start
  ROLLBACK=0
  if [ "$DRY_RUN" = "1" ]; then
    say "[dry-run] 跳过就绪等待"
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
INSTALL_MODE=${INSTALL_MODE:-payload}
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
  日志       ${LOG_FILE:-（未启用）}

  登录：LSA 需要系统账号。默认预置了 lsiadmin（锁定态），设置口令后即可登录：

      sudo chroot ${RFS} passwd lsiadmin

  然后浏览器打开上面的地址，用 lsiadmin + 刚设的口令登录。

  常用命令：
      $0 status      # 状态
      $0 doctor      # 体检
      $0 uninstall   # 卸载

EOF
}
