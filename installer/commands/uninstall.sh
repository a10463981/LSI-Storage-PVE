#!/usr/bin/env bash
# commands/uninstall.sh — 卸载并自检零残留

uninstall_main() {
  req_root "$@"
  confirm "将停止服务并删除 $PREFIX（约 $(du -sm "$PREFIX" 2>/dev/null | cut -f1) MB）。继续？" \
    || die "已取消"

  step "停止并移除 systemd 单元"
  unit_remove
  ok "unit 已移除"

  step "清理 chroot 挂载与进程"
  # 只针对本前缀下的残留挂载（正常路径不该有，PrivateMounts 会随 unit 销毁）
  local mp
  while read -r mp; do
    [ -n "$mp" ] || continue
    case "$mp" in
      "$RFS"/*) say "卸载残留挂载 $mp"; run umount "$mp" || true ;;
      *)        warn "跳过非本应用挂载点：$mp" ;;
    esac
  done < <(awk -v p="$RFS" '$2 ~ p {print $2}' /proc/mounts 2>/dev/null)

  step "删除安装目录"
  run rm -rf "$PREFIX"
  ok "$PREFIX 已删除"

  step "清理配置与日志"
  run rm -f "$CONF"
  if [ "${PURGE:-0}" = "1" ]; then
    run rm -rf "$STATE" "$LOG_DIR"
    ok "--purge：配置、下载缓存与日志已删除"
  else
    say "保留下载缓存 $STATE 与日志 $LOG_DIR（加 --purge 一并删除）"
  fi

  step "零残留自检"
  verify_clean
}

verify_clean() {
  local bad=0
  [ -d "$PREFIX" ]                     && { warn "残留：目录 $PREFIX"; bad=1; }
  [ -f "$UNIT_FILE" ]                  && { warn "残留：unit $UNIT_FILE"; bad=1; }
  [ -f "$CONF" ]                       && { warn "残留：配置 $CONF"; bad=1; }
  awk -v p="$RFS" '$2 ~ p {print; n++} END{exit !n}' /proc/mounts 2>/dev/null \
                                       && { warn "残留：挂载"; bad=1; }
  port_in_use "$PORT"                  && { warn "端口 $PORT 仍被占用（可能是别的服务）"; bad=1; }
  if have systemctl && systemctl list-unit-files 2>/dev/null | grep -q '^lsa-pve.service'; then
    warn "残留：lsa-pve.service 仍在 unit 列表中"; bad=1
  fi
  if [ "$bad" -eq 0 ]; then
    ok "零残留：目录 / unit / 配置 / 挂载 / 端口 均已清理"
    return 0
  fi
  warn "存在残留项，见上（端口被别的服务占用不算本工具的残留）"
  return 1
}
