#!/bin/sh
# LSA 启动器：在独立 mount 命名空间里挂载 + chroot 启动 LSA，并常驻等待停止信号。
#
# 为什么用 unshare -m：
#   fnOS 的 / 传播是 shared（.15 实测）。若直接在宿主命名空间 rbind /dev，
#   挂载会向外传播，且崩溃时留下残留挂载 —— 这正是"上次没卸干净，这次起不来"的根因。
#   包在独立 mount 命名空间里，命名空间销毁时内核自动卸载全部挂载。
#
# 为什么 PID1 必须常驻：
#   若内层 shell 在 init 脚本返回后退出，命名空间里仍有 slpd/nginx/LSA（它们 daemonize 了），
#   挂载会继续存在但没有"控制器"。常驻 shell 同时承担"收到停止信号后优雅停 LSA"的职责。
#
# 用法: launch.sh <RFS> <RUN>
set -eu
RFS=${1:?RFS}
RUN=${2:?RUN}
STOPFLAG=$RUN/stop.flag
mkdir -p "$RUN"

exec unshare -m --propagation private /bin/sh -c '
set -eu
RFS=$1; RUN=$2; STOPFLAG=$3
echo $$ > "$RUN/lsa.ns.pid"

mkdir -p "$RFS/dev" "$RFS/proc" "$RFS/sys" "$RFS/run"
# 已经在 private 挂载命名空间里，传播到宿主是不可能的，--make-rslave 只是双保险。
# 但它在某些内核/传播状态下会返回 EINVAL（.15 实测），加上 set -e 会直接中止启动，
# 所以这里必须容错：失败只记一行，不影响挂载本身。
mount --rbind /dev  "$RFS/dev"  || { echo "[launch] rbind /dev failed"; exit 1; }
mount --rbind /sys  "$RFS/sys"  || { echo "[launch] rbind /sys failed"; exit 1; }
mount --rbind /proc "$RFS/proc" || { echo "[launch] rbind /proc failed"; exit 1; }
mount --make-rslave "$RFS/dev"  2>/dev/null || true
mount --make-rslave "$RFS/sys"  2>/dev/null || true
mount --make-rslave "$RFS/proc" 2>/dev/null || true
# /run 用独立 tmpfs，避免宿主 pid 文件串进来
mount -t tmpfs -o size=16m tmpfs "$RFS/run" 2>/dev/null || mount --rbind /run "$RFS/run" 2>/dev/null || true

echo "[launch] mounts ready, starting LSA"
chroot "$RFS" /usr/bin/env LD_LIBRARY_PATH=/opt/lsi/LSA/libs:/opt/lsi/LSA/libs2 \
  /etc/init.d/LsiSASH start || echo "[launch] init start returned non-zero"
echo "[launch] LSA start issued, waiting for stop flag"

while [ ! -f "$STOPFLAG" ]; do sleep 2; done
echo "[launch] stop flag seen, stopping LSA"
chroot "$RFS" /usr/bin/env LD_LIBRARY_PATH=/opt/lsi/LSA/libs:/opt/lsi/LSA/libs2 \
  /etc/init.d/LsiSASH stop || true
sleep 1
echo "[launch] done"
' sh "$RFS" "$RUN" "$STOPFLAG"
