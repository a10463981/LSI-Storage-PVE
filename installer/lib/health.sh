#!/usr/bin/env bash
# health.sh — 健康检查与就绪等待
#
# LSA 的无卡/慢盘环境预热可能长达数分钟，等待时间可用 --timeout 调整（默认 300 秒）。

api_probe() {   # api_probe -> 打印 "<HTTP 码> <毫秒>"，失败为 "000 0"
  local url="http://127.0.0.1:${PORT}/LSI/Storage/MR/API/1.0/"
  local code ms
  if have curl; then
    ms=$(curl -s -o /dev/null -w '%{time_total}' --max-time 8 "$url" 2>/dev/null || echo 0)
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "$url" 2>/dev/null || echo 000)
    awk -v c="$code" -v t="$ms" 'BEGIN{printf "%s %d\n", c, t*1000}'
  elif have wget; then
    code=$(wget -q -S -O /dev/null --timeout=8 "$url" 2>&1 | awk '/HTTP\//{c=$2} END{print c+0}')
    printf '%s 0\n' "${code:-000}"
  else
    printf '000 0\n'
  fi
}

api_code() { api_probe | awk '{print $1}'; }

wait_ready() {
  local timeout=${READY_TIMEOUT:-300}
  local start now code elapsed
  start=$(date +%s)
  say "等待 LSA 就绪（最长 ${timeout}s）"
  while :; do
    code=$(api_code)
    now=$(date +%s); elapsed=$((now - start))
    if [ "$code" = "200" ]; then
      ok "LSA 接口已就绪（${elapsed}s）"
      return 0
    fi
    if [ "$elapsed" -ge "$timeout" ]; then
      err "等待超时（${elapsed}s，最后状态 HTTP $code）"
      cat <<EOF

排查建议：
  1. 看服务日志： journalctl -u lsa-pve.service -n 60 --no-pager
  2. 看 LSA 日志： $RFS/opt/lsi/LSIStorageAuthority/logs/lsa.txt 尾部
  3. 常见原因：
     - CPU 不支持该基线（日志出现 "CPU ISA level is lower than required"）
     - 缺符号链接（运行 repair 重建）
     - 预热还没结束（无卡或慢盘机器可达 5 分钟以上，可加大 --timeout）
EOF
      return 1
    fi
    printf '  %s… HTTP %s（%ss）\n' "${C_DIM}等待${C_OFF}" "$code" "$elapsed"
    sleep 5
  done
}

port_listen_line() {   # 打印端口监听状态
  local p
  for p in "$PORT" "$BACKEND_PORT"; do
    if port_in_use "$p"; then printf '%s=%s ' "$p" "监听"; else printf '%s=%s ' "$p" "未监听"; fi
  done
  echo
}
