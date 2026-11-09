#!/usr/bin/env bash
# service.sh — 渲染并管理系统单元
# 停服务只用 systemd；本工具任何地方都不执行 pkill。

unit_render() {
  local tpl="$INSTALLER/systemd/lsa-pve.service.in"
  [ -f "$tpl" ] || die "缺少 unit 模板：$tpl"
  if [ "${DRY_RUN:-0}" = "1" ]; then
    printf '%s  [dry-run] 渲染 %s → %s（PREFIX=%s RFS=%s）%s\n' "$C_DIM" "$tpl" "$UNIT_FILE" "$PREFIX" "$RFS" "$C_OFF"
    return 0
  fi
  sed -e "s|@PREFIX@|$PREFIX|g" \
      -e "s|@RFS@|$RFS|g" \
      "$tpl" > "$UNIT_FILE.tmp"
  mv "$UNIT_FILE.tmp" "$UNIT_FILE"
  chmod 644 "$UNIT_FILE"
}

unit_install() {
  say "安装 systemd 单元：$UNIT_FILE"
  unit_render
  run systemctl daemon-reload
  run systemctl enable lsa-pve.service >/dev/null 2>&1 || true
  ok "单元已安装并设为开机自启"
}

unit_installed() { [ -f "$UNIT_FILE" ]; }

unit_active() {
  have systemctl || return 1
  [ "$(systemctl is-active lsa-pve.service 2>/dev/null)" = "active" ]
}

unit_start() {
  say "启动 lsa-pve.service（LSA 需要预热，可能数分钟）"
  run systemctl start lsa-pve.service
}

unit_stop() {
  unit_installed || return 0
  say "停止 lsa-pve.service"
  run systemctl stop lsa-pve.service || true
}

unit_remove() {
  if unit_installed; then
    run systemctl stop lsa-pve.service >/dev/null 2>&1 || true
    run systemctl disable lsa-pve.service >/dev/null 2>&1 || true
    say "删除 unit 文件"
    run rm -f "$UNIT_FILE"
    run systemctl daemon-reload
    run systemctl reset-failed lsa-pve.service >/dev/null 2>&1 || true
  fi
}

unit_status_line() {
  if unit_installed; then
    systemctl is-active lsa-pve.service 2>/dev/null || echo "inactive"
  else
    echo "未安装"
  fi
}
