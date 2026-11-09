#!/usr/bin/env bash
# commands/status.sh — 一次输出 unit / 端口 / 接口 / 版本

status_main() {
  local code t
  printf '\n%s=== 状态 ===%s\n' "$C_INFO" "$C_OFF"
  printf '  服务单元          %s\n' "$(unit_status_line)"
  printf '  安装前缀          %s %s\n' "$PREFIX" "$( [ -d "$PREFIX" ] && echo "（$(du -sm "$PREFIX" 2>/dev/null | cut -f1) MB）" || echo "（不存在）" )"
  printf '  LSA 主程序        %s\n' "$( [ -x "$RFS/opt/lsi/LSIStorageAuthority/bin/LSA" ] && echo 存在 || echo 不存在 )"
  printf '  端口              %s\n' "$(port_listen_line)"

  IFS=" " read -r code t <<<"$(api_probe)"
  printf '  LSA 接口          HTTP %s（%s ms）http://127.0.0.1:%s/\n' "$code" "$t" "$PORT"

  local ver="未知"
  local rel="$RFS/opt/lsi/LSIStorageAuthority/version.txt"
  [ -f "$rel" ] && ver=$(head -1 "$rel")
  [ "$ver" = "未知" ] && ver=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
      "$RFS/opt/lsi/LSIStorageAuthority/server/html/message_en.js" 2>/dev/null | head -1)
  printf '  LSA 版本          %s\n' "${ver:-未知}"

  if unit_active && [ "$code" = "200" ]; then
    printf '\n  %s运行正常%s\n\n' "$C_OK" "$C_OFF"
    return 0
  fi
  if unit_active; then
    printf '\n  %s服务在跑但接口未就绪%s（预热中，或运行 doctor 排查）\n\n' "$C_WARN" "$C_OFF"
    return 1
  fi
  printf '\n  %s未运行%s（启动：systemctl start lsa-pve 或 %s repair）\n\n' "$C_ERR" "$C_OFF" "$0"
  return 1
}
