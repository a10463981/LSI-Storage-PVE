# 基于 Debian / PVE 博通 LSA 控制器工具

[English](README.en.md) | 中文

在 **PVE（Debian 11/12）宿主机**上装出一套可视化的 Broadcom LSI Storage Authority（LSA），
浏览器打开 `http://<PVE地址>:2463` 就能看 MegaRAID 阵列卡的状态。

不需要 storcli，不装 Docker，不重启宿主机，也不会动你系统的软件包。

> 姊妹项目（fnOS 版）：[LSI-Storage-Fnos](https://github.com/a10463981/LSI-Storage-Fnos)
> 两者共享同一份内核，本项目通过 `vendor/core/` 快照复用它的构建流水线。

**当前状态：首个版本（0.1.03）。** 安装脚本已完整实现；尚未在真实 PVE 上做端到端安装验证，
详见文末「未验证项」。

## 快速开始

```bash
# 1. 下载并解压（约 66MB，内含 Ubuntu 运行环境与 LSA）
wget https://github.com/a10463981/LSI-Storage-PVE/releases/download/v0.1.04/LSI-Storage-PVE-0.1.04.tar.gz
wget https://github.com/a10463981/LSI-Storage-PVE/releases/download/v0.1.04/SHA256SUMS
sha256sum -c SHA256SUMS --ignore-missing
tar xzf LSI-Storage-PVE-0.1.04.tar.gz && cd LSI-Storage-PVE-0.1.04

# 2. 先体检（只读，零风险）
sudo ./installer/install.sh doctor

# 3. 安装（离线，1–2 分钟；不需要另外准备 LSA 包）
sudo ./installer/install.sh install

# 4. 设登录口令，然后浏览器打开 http://<PVE地址>:2463
sudo chroot /opt/lsi-storage/rootfs passwd lsiadmin
```

**全程不需要联网、不需要 apt、不需要 Docker、不需要重启宿主机。**
安装器只做四件事：校验并解包运行环境 → 按参数写端口 → 装 systemd 单元 → 启动。

## 前置条件

| 项 | 要求 |
|---|---|
| 系统 | PVE 7.x / 8.x（Debian 11/12），systemd 运行中 |
| 权限 | root |
| 磁盘 | `/opt` 所在分区 ≥ 2 GB 空闲 |
| 端口 | 2463 与 9000 空闲（可用 `--port` / `--backend-port` 改） |
| 硬件 | MegaRAID 卡直通/在位。**没有卡也能装**，只是界面里列表为空 |
| **不需要** | 不需要联网、不需要 LSA 包、不需要 apt、不需要 Docker、不需要重启宿主机 |

## 为什么包这么大（66 MB）

因为**发行包里直接带了一份装好的运行环境**：Ubuntu 24.04 base + Broadcom LSA
（`gcc_8.3.x` 基线）+ 运行期依赖，压缩后约 66 MB，解包后约 101 MB。

另一种做法是只带安装脚本、让目标机现装（下载 Ubuntu base、在 chroot 里 `apt-get`、
`dpkg -i` LSA）。那样包只有几十 KB，但要求目标机联网到镜像站、还要你另外准备 166MB 的
LSA 安装包——在 PVE 上这两种失败率都不低。我们选了「一次下载、离线安装」。

**包里包含 Broadcom LSA 的专有二进制**（版权归 Broadcom，Ubuntu 归 Canonical），
仅面向个人在自己硬件上使用的场景；本项目的代码部分是 MIT。详见文末「声明与许可」。

## 高级：自备 LSA 包从源码现装

如果你已经有 LSA 安装包、机器也能联网，可以跳过 payload 走构建路径：

```bash
sudo ./installer/install.sh install --lsa-package /root/008.018.012.000_MR_7.38_LSA_Linux.zip
```

这条路会下载 Ubuntu base、在 chroot 内 `apt-get` 装依赖、`dpkg -i` 装 LSA，
耗时 10–20 分钟。LSA 包必须包含 **`gcc_8.3.x`** 基线（高版本基线要求 AVX，
虚拟 CPU 会报 `CPU ISA level is lower than required`）。

## 子命令

```
install.sh doctor                只读体检（普通用户也可跑）
install.sh install               全新安装
install.sh status                服务 / 端口 / 接口状态
install.sh upgrade               升级（替换 rootfs，保留配置，旧版留作回滚）
install.sh rollback --to <路径>  回滚
install.sh uninstall [--purge]   卸载（结束后自检零残留）
install.sh repair                白名单修复
```

常用参数：`--lsa-package` `--rootfs-file` `--port` `--backend-port` `--prefix`
`--timeout` `--yes` `--dry-run` `--force` `--purge`。

`--dry-run` 会把每一步将执行的动作打印出来，不写任何文件、不启动任何服务，
在任意机器上都能试跑。

## `doctor` 输出示例

```
=== 系统 ===
  发行版                      Debian GNU/Linux 12 (bookworm)
  内核                         6.18.18
  Proxmox VE                     8.2.4（/etc/pve 存在）
  Systemd                        运行中
  容器环境                   否
  权限                          root

=== 阵列卡 ===
  lspci                          MegaRAID SAS-3 3108 [Invader]
  scsi_host                      1 个 megaraid 主机
  megaraid_sas 模块            已加载
  /dev/megaraid_sas_ioctl_node   存在
  结论                         检测到 MegaRAID，可正常管理

=== 资源与网络 ===
  磁盘剩余（/opt）         38145 MB（需要 ≥ 2048）
  内存可用                   8033 MB（运行期约需 300MB）
  镜像站解析                mirrors.tuna.tsinghua.edu.cn 可解析
  下载器                      curl
  解压工具                   unzip

=== 现有安装 ===
  安装目录                   /opt/lsi-storage 不存在（未安装）
  systemd 单元                 未安装
  LSA 主程序                  不存在
  端口 2463                    空闲
  端口 9000                    空闲

=== 结论 ===
  环境检查全部通过，可以安装
```

## 工作原理

安装脚本做三件事：

1. **校验并解包发行包里的运行环境**（`payload/rootfs.tar.gz`，SHA256 硬校验）到
   `/opt/lsi-storage/rootfs` —— 这一步不联网、不执行 apt
2. **按参数写入端口**：rootfs 里的 LSA 配置保留着端口占位符，安装时替换成
   `--port` / `--backend-port` 指定的值；再幂等校验三处库符号链接
3. **注册 `lsa-pve.service`**：`Type=oneshot` + `RemainAfterExit=yes`，用
   `PrivateMounts=yes` 让 systemd 为这个单元建私有挂载命名空间 —— 挂载随单元销毁，
   所以本工具**从不执行 `umount`**，不可能误伤宿主的 `/dev /proc /sys`

**关于 apt，一个必须说清的点**：脚本里所有 `apt-get` 都在
`chroot /opt/lsi-storage/rootfs` 内部执行。那是**另一个系统**，有自己的
`/etc/apt`、自己的包数据库。宿主 PVE 的 apt 完全没被使用 —— 即使宿主的 apt 索引
是坏的，也不影响这里。本工具在宿主上除了 `systemctl` 与文件操作，不调用任何包管理器。

## 卸载

```bash
sudo ./installer/install.sh uninstall --purge
```

会停并删除 unit、清理本前缀下的残留挂载、删掉 `/opt/lsi-storage`、删配置与日志，
最后自检四项零残留（目录 / unit / 配置 / 挂载）并打印结果。

## 与 fnOS 版的关系

构建内核不在本仓库维护，从 fnOS 版单向同步到 `vendor/core/`：

```bash
scripts/sync-core.sh --from /path/to/LSI-Storage-Fnos    # 同步
scripts/sync-core.sh --check --from /path/to/LSI-Storage-Fnos   # CI 门禁
```

当前快照对应 `CORE_VERSION` = 0.1.03，上游 commit 见 `UPSTREAM`。
手改 `vendor/core/` 里的任何文件都会被 `--check` 抓出来。

## 未验证项

以下是**必须在真实 PVE 上验一遍**才能打勾的：

1. 全新 PVE 上的完整安装（当前只在 Debian 12 构建机上跑过 `doctor` 与 `--dry-run`；
   payload 的冒烟测试也尚未在构建机上通过——见下）
2. `--port` 参数化后 LSA 前端是否真的改到指定端口（8 处占位符是否覆盖全部引用）
3. `upgrade` 的 rootfs 原子替换与 `rollback`
4. `uninstall --purge` 的零残留断言
5. 有卡环境下的控制器枚举、虚拟盘/物理盘状态、重建进度
6. `readonly_access_groups` 是否真的拦住写操作
7. PVE 8.x / Debian 12 与 PVE 7.2 / Debian 11 的差异
8. payload 解包后 LSA 能否在真实 PVE 上起到 API 200（`gcc_8.3.x` 基线在 Intel/AMD 实机上的表现）
9. 端口参数化：`--port 8080` 后 LSA 前端是否真的监听 8080

## 声明与许可

本项目是**非官方第三方集成**，与 Broadcom Inc. 没有隶属关系，也未获其授权或背书。
Broadcom、LSI、MegaRAID、LSI Storage Authority 是 Broadcom Inc. 的商标或注册商标。

本仓库代码以 MIT 许可发布。Broadcom LSA 安装包与 Ubuntu 根文件系统分别归 Broadcom 与
Canonical 所有，不在 MIT 范围内，需自行获取。
