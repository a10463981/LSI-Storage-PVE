# 基于 Debian / PVE 博通 LSA 控制器工具 v0.1.04

在 PVE（Debian 11/12）宿主机上装出一套可视化的 Broadcom LSI Storage Authority，
浏览器打开 `http://<PVE地址>:2463` 就能看 MegaRAID 阵列状态。

## 本次更新：一个包全带走

上一版（0.1.03）的发行包只有 70 KB，因为它只带脚本，要求你自己准备 LSA 安装包、
而且目标机要联网在 chroot 里现装。这一版改成**把装好的运行环境直接打进包里**：

| | 0.1.03 | 0.1.04 |
|---|---|---|
| 发行包体积 | 72 KB | **66 MB** |
| 需要自备 LSA 包 | 是 | **否** |
| 安装时需要联网 | 是（下载 Ubuntu base + 镜像站装依赖） | **否** |
| 安装耗时 | 10–20 分钟 | **1–2 分钟** |
| 安装步骤 | 9 步 | **6 步** |

包里是 Ubuntu 24.04 base + Broadcom LSA（`gcc_8.3.x` 基线）+ 运行期依赖，
压缩后 66 MB、解包后约 101 MB。因为包含 Broadcom 的专有二进制，所以：

> **非官方第三方工具**，与 Broadcom Inc. 无隶属关系、未获其授权或背书。
> Broadcom、LSI、MegaRAID、LSI Storage Authority 是 Broadcom Inc. 的商标或注册商标。
> 包内 LSA 与 Ubuntu 根文件系统版权分别归 Broadcom 与 Canonical，不在本项目 MIT 许可范围内；
> 仅面向个人在自己硬件上使用的场景，**可能被要求下架**。
> 若二进制分发被移除，源码仓库不受影响——可自备 LSA 包按 README「高级」一节自行构建。

## 安装

```bash
wget https://github.com/a10463981/LSI-Storage-PVE/releases/download/v0.1.04/LSI-Storage-PVE-0.1.04.tar.gz
wget https://github.com/a10463981/LSI-Storage-PVE/releases/download/v0.1.04/SHA256SUMS
sha256sum -c SHA256SUMS --ignore-missing
tar xzf LSI-Storage-PVE-0.1.04.tar.gz && cd LSI-Storage-PVE-0.1.04

sudo ./installer/install.sh doctor     # 只读体检
sudo ./installer/install.sh install    # 离线安装，1–2 分钟

sudo chroot /opt/lsi-storage/rootfs passwd lsiadmin   # 设登录口令
```

端口被占用时换一个：`install --port 8080 --backend-port 9000`。

## 高级：自备 LSA 包从源码现装

```bash
sudo ./installer/install.sh install --lsa-package /path/to/LSA_Linux.zip
```

## 已知限制

- 完整安装与 payload 冒烟测试**尚未在真实 PVE 上跑过**（开发环境为 Debian 12 构建机）
- 端口参数化后 LSA 前端是否真的改到指定端口，需实测
- 有卡环境下的控制器枚举、虚拟盘/物理盘状态、重建进度未验证
- `readonly_access_groups` 是否真的拦住写操作未验证

## 姊妹项目

fnOS 版本：[LSI-Storage-Fnos](https://github.com/a10463981/LSI-Storage-Fnos)（v0.1.03）
两个项目共享同一份内核（`vendor/core/` 从 fpk 仓库同步）。
