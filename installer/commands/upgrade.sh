#!/usr/bin/env bash
# commands/upgrade.sh — 替换 rootfs，保留端口等配置，旧 rootfs 留作回滚

upgrade_main() {
  req_root "$@"
  [ -f "$CONF" ] || die "未安装（找不到 $CONF）。全新安装请用：$0 install"
  [ -n "${LSA_PACKAGE:-}" ] || die "upgrade 需要 --lsa-package（或 --rootfs-file 走离线）"

  local old="$PREFIX/rootfs.old-$(date +%Y%m%d-%H%M%S)"
  step "停止服务"
  unit_stop
  ok "已停止"

  step "备份现有 rootfs → $old"
  run mv "$RFS" "$old"
  ok "已备份"

  ROLLBACK=1
  trap 'rc=$?; if [ "${ROLLBACK:-0}" = "1" ] && [ "$rc" -ne 0 ]; then
          err "升级失败（rc=$rc），回滚到备份…"
          rm -rf "$RFS" 2>/dev/null || true
          mv "$old" "$RFS" 2>/dev/null || true
          systemctl start lsa-pve.service >/dev/null 2>&1 || true
          err "已回滚并尝试重启旧版本。日志：$LOG_FILE"
        fi' EXIT

  STEP_TOTAL=6
  step "准备 rootfs 与 LSA 包"
  fetch_rootfs
  fetch_lsa

  step "重建 chroot（依赖 + LSA + 补丁）"
  rfs_create
  rfs_set_apt_sources
  rfs_install_deps
  rfs_install_lsa
  rfs_patch_all

  step "重启服务"
  write_config
  unit_render
  run systemctl daemon-reload
  unit_start

  ROLLBACK=0
  if wait_ready; then
    trap - EXIT
    ok "升级完成；旧版本保留在 $old"
    say "确认新版正常后可删除：rm -rf $old"
    say "如需回滚：$0 rollback --to $old"
  else
    err "新版本未就绪，保留旧版本在 $old"
    exit 1
  fi
}

rollback_main() {
  req_root "$@"
  [ -n "${ROLLBACK_TO:-}" ] || die "用法：$0 rollback --to <旧 rootfs 路径>"
  [ -d "$ROLLBACK_TO" ] || die "路径不存在：$ROLLBACK_TO"
  step "停止服务"
  unit_stop
  step "回滚 rootfs"
  run rm -rf "$RFS"
  run mv "$ROLLBACK_TO" "$RFS"
  step "启动"
  unit_start
  wait_ready && ok "回滚完成"
}
