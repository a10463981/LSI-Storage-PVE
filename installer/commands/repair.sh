#!/usr/bin/env bash
# commands/repair.sh — 白名单修复。只做这四件事，别的一概不碰。

repair_main() {
  req_root "$@"
  [ -d "$RFS" ] || die "未安装（$RFS 不存在）"

  step "修复 1/4：重建库符号链接"
  local libdir="$RFS/usr/lib/x86_64-linux-gnu" fixed=0
  [ -e "$libdir/libcrypt.so.1" ] && { run ln -sfn libcrypt.so.1 "$libdir/libcrypt.so.2"; fixed=$((fixed+1)); }
  [ -e "$libdir/libldap.so.2" ]  && { run ln -sfn libldap.so.2  "$libdir/libldap-2.4.so.2"; fixed=$((fixed+1)); }
  [ -e "$RFS/opt/lsi/LSA/libs2/libslp.so.1.0.0" ] && \
    { run ln -sfn libslp.so.1.0.0 "$RFS/opt/lsi/LSA/libs2/libslp.so.1"; fixed=$((fixed+1)); }
  [ -d "$RFS/opt/lsi/LSIStorageAuthority/server/html/js" ] && \
    { run ln -sfn ../js "$RFS/opt/lsi/LSIStorageAuthority/server/html/ui/js"; fixed=$((fixed+1)); }
  ok "处理 $fixed 处链接"

  step "修复 2/4：清理残留挂载"
  local mp n=0
  while read -r mp; do
    [ -n "$mp" ] || continue
    case "$mp" in
      "$RFS"/*) say "卸载 $mp"; run umount "$mp" || true; n=$((n+1)) ;;
      *) warn "跳过非本应用挂载点：$mp" ;;
    esac
  done < <(awk -v p="$RFS" '$2 ~ p {print $2}' /proc/mounts 2>/dev/null)
  ok "处理 $n 处挂载"

  step "修复 3/4：清理残留 pid/socket"
  run rm -f "$RFS/var/run/"*.pid "$RFS/var/run/"*.sock 2>/dev/null || true
  ok "已清理"

  step "修复 4/4：重装并重启服务"
  unit_install
  unit_stop
  unit_start
  if wait_ready; then
    ok "修复完成，服务已就绪"
  else
    err "修复后仍未就绪，请运行：$0 status 并查看 journalctl -u lsa-pve -n 80"
    exit 1
  fi
}
