# build.md — 构建流水线与裁剪策略

## 前置

```bash
mkdir -p build/vendor
cp 008.018.012.000_MR_7.38_LSA_Linux.zip build/vendor/   # 自行获取，仓库不含
make image && make pkg
# 产物 build/dist/LSI-Storage-Fnos.fpk
```

需要：x86_64 Linux、root、能访问清华 TUNA 镜像、`fnpack`。
`fnpack build -d <dir>` 的产物落在**当前工作目录**，不要把输出接管道（会吞退出码）。

## 七阶段

| 阶段 | 输入 | 产出 | 要点 |
|---|---|---|---|
| 00-fetch | 网络 | `work/rootfs.tar.gz` + LSA zip | rootfs 走 TUNA；**SHA256 硬校验**，不匹配直接 die |
| 10-unpack | rootfs.tar.gz | `work/rootfs/` | apt 源换 HTTP，避免证书链问题 |
| 20-apt-deps | — | rootfs 内 6 个依赖 | `libaio1 libnuma1 libpci3 libssl3 libcurl4 libjson-c5` + `passwd` + `psmisc`（`killall`） |
| 30-install-lsa | LSA zip | `/opt/lsi/**` | 双层 zip；**必须选 gcc_8.3.x 基线**（见下） |
| 40-patch | rootfs | 打补丁后的 rootfs | 见补丁表 |
| 50-slim | rootfs | 更小的 rootfs | 四批删除，每批后过 ELF 检查 + 快速冒烟 |
| 60-smoke | rootfs | — | `--quick` 等端口，`--full` 等 API 200 |
| 70-package | rootfs | `work/70/rootfs.tar.gz` | gzip -6，排序 + 固定 mtime/owner 保证可重复；写 `/etc/lsi-storage-fnos-build` 指纹 |
| 80-pack | pkg/ + 载荷 | `build/dist/*.fpk` | 先跑 `check-mounts.sh` 守卫，再 `fnpack build` |

## LSA 基线为什么锁 gcc_8.3.x

LSA 安装包里有多个按 glibc/gcc 版本编译的变体。`gcc_14.2.x` / `gcc_11.2.x` 基线需要
AVX/SSE4.2，在 KVM 的虚拟 CPU（Common KVM processor）上会直接
`nginx: CPU ISA level is lower than required`。`gcc_8.3.x`（SLES 15 基线）不要求这些指令集，
是唯一能在这种环境跑起来的**代价最小**选择。

代价是它的 `libldap` soname 是 `libldap-2.4.so.2`，Ubuntu 24.04 只提供 `libldap.so.2`，
所以必须补一条符号链接（补丁 3d），并且把 LSA 配成 `ldap_mode = 0` 走本地认证。

**这条不要推翻**，除非目标环境保证有 AVX2 并且愿意为此换整套基线重测。

## 构建期补丁表（`40-patch.sh`）

| 编号 | 内容 | 为什么 |
|---|---|---|
| 1 | `libcrypt.so.2 → libcrypt.so.1` | LSA 二进制链接旧 soname |
| 2 | `libslp.so.1 → libslp.so.1.0.0` | 同上，SLP 库 |
| 3 | `server/html/js → ../js` | 前端相对路径少了这一层 |
| 3b | `mkdir /usr/local/var/log` | slpd 默认日志目录，缺了会起不来 |
| 3c | 检查 init 脚本里的 `LD_LIBRARY_PATH` | 见 `pitfalls.md` 的灰屏条目 |
| 3d | `libldap-2.4.so.2 → libldap.so.2` | gcc8 基线需要 |
| 3e | 注释 nginx 的 `X-Frame-Options` | 允许被门户/面板嵌入 |
| 4 | 8 处端口占位符 → `2463` / `9000` | 模板里的默认端口 |
| 5 | `log_level 64 → 4` | 64 会产生天量日志把盘写满 |
| 6 | 预置账号 `lsiadmin`（锁定态） | 运行期只 `chpasswd`，不 `useradd`（改名场景才动态建） |

## 瘦身与体积预算

四批删除：文档/man 页 → 非必要 locale → 静态库与头文件 → 冗余固件。
每批之后跑一次 `verify/check-elf.sh`（只看 `not found`，不看 undefined symbol），
再跑一次 `60-smoke-test.sh --quick`，任何一批把运行环境搞坏就能立刻定位。

目标体积：rootfs 原始 ~102 MB → 压缩 ~65 MB → fpk ~66 MB。
**单文件不要超过 100 MB**（GitHub 仓库限制；Release 资产上限 2 GB 但没必要）。

## 两个静态守卫

- `verify/check-elf.sh`：`ldd` 全量扫描，只报 `not found`
- `verify/check-mounts.sh`：R1 禁 `umount -R`、R2 禁对宿主 `/dev /proc /sys /run` 卸载、
  R3 `rbind` 必须处于命名空间内。已接进 `make check` 与 `80-pack.sh`

## 骨架包

`make skeleton`（`90-skeleton.sh`）打一个不含 LSA 的极简包，用来验证平台交互
（向导、钩子、面板入口）而不必每次等完整构建。排查平台侧问题时优先用它。
