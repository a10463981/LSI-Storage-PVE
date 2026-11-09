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
# 1. 下载并解压（建议固定到 Release 的 tag，不要用 main 分支的 raw 链接）
wget https://github.com/a10463981/LSI-Storage-PVE/releases/download/v0.1.03/LSI-Storage-PVE-0.1.03.tar.gz
wget https://github.com/a10463981/LSI-Storage-PVE/releases/download/v0.1.03/SHA256SUMS
sha256sum -c SHA256SUMS --ignore-missing
tar xzf LSI-Storage-PVE-0.1.03.tar.gz && cd LSI-Storage-PVE-0.1.03

# 2. 先体检（只读，不改任何东西）
sudo ./installer/install.sh doctor

# 3. 再安装（LSA 包需自备，见下节）
sudo ./installer/install.sh install --lsa-package /root/008.018.012.000_MR_7.38_LSA_Linux.zip

# 4. 打开浏览器
#    http://<PVE地址>:2463
```

装上后要设一个登录口令（LSA 用系统账号认证）：

```bash
sudo chroot /opt/lsi-storage/rootfs passwd lsiadmin
```

然后浏览器用 `lsiadmin` + 刚设的口令登录。

## 前置条件

| 项 | 要求 |
|---|---|
| 系统 | PVE 7.x / 8.x（Debian 11/12），systemd 运行中 |
| 权限 | root |
| 磁盘 | `/opt` 所在分区 ≥ 2 GB 空闲 |
| 端口 | 2463 与 9000 空闲（可用 `--port` / `--backend-port` 改） |
| 网络 | 能访问 `mirrors.tuna.tsinghua.edu.cn`（或用 `--rootfs-file` 离线安装） |
| 硬件 | MegaRAID 卡直通/在位。**没有卡也能装**，只是界面里列表为空 |
| **不需要** | 不需要 apt、不需要 Docker、不需要重启宿主机 |

## LSA 安装包从哪里来

LSA 是 Broadcom 的专有软件，**不随本项目分发**，需要你自己获取：

- 文件名通常形如 `008.018.012.000_MR_7.38_LSA_Linux.zip`（约 166 MB）
- 获取途径：服务器厂商支持页搜 "LSI Storage Authority"（多数不需要注册）；
  或 Broadcom 支持站 → 你的卡型号 → Management Software（需要注册账号）
- 必须包含 **`gcc_8.3.x` 基线**（无 AVX 的虚拟 CPU 只能用这个基线，用 14.2.x 会 `CPU ISA level is lower`）

不提供 `--lsa-package` 时，安装会停在预检阶段并打印上面的指引，不会半路失败。

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

1. **准备一个独立的 Ubuntu 24.04 根文件系统**（`ubuntu-base`，SHA256 硬校验），
   解到 `/opt/lsi-storage/rootfs`
2. **在这个 chroot 里装 LSA**：先 `apt-get install` 运行期依赖，再 `dpkg -i` LSA 的
   `gcc_8.3.x` 基线 deb，然后打兼容性补丁（库符号链接、端口、日志级别、预置账号）
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

1. 全新 PVE 上的完整安装（当前只在 Debian 12 构建机上跑过 `doctor` 与 `--dry-run`）
2. `--port` 参数化后 LSA 前端是否真的改到指定端口（8 处占位符是否覆盖全部引用）
3. `upgrade` 的 rootfs 原子替换与 `rollback`
4. `uninstall --purge` 的零残留断言
5. 有卡环境下的控制器枚举、虚拟盘/物理盘状态、重建进度
6. `readonly_access_groups` 是否真的拦住写操作
7. PVE 8.x / Debian 12 与 PVE 7.2 / Debian 11 的差异

## 声明与许可

本项目是**非官方第三方集成**，与 Broadcom Inc. 没有隶属关系，也未获其授权或背书。
Broadcom、LSI、MegaRAID、LSI Storage Authority 是 Broadcom Inc. 的商标或注册商标。

本仓库代码以 MIT 许可发布。Broadcom LSA 安装包与 Ubuntu 根文件系统分别归 Broadcom 与
Canonical 所有，不在 MIT 范围内，需自行获取。
