# 基于 Debian / PVE 博通 LSA 控制器工具 v0.1.03

在 PVE（Debian 11/12）宿主机上装出一套可视化的 Broadcom LSI Storage Authority，
浏览器打开 `http://<PVE地址>:2463` 就能看 MegaRAID 阵列状态。不需要 storcli，
不装 Docker，不重启宿主机，也不动你系统的软件包。

## 本次发布（首个版本）

- **一键安装脚本**：`installer/install.sh`，子命令 `doctor / install / status / upgrade / rollback / uninstall / repair`
- **`doctor` 只读体检**：安装前就能看清"有没有卡、端口占不占、磁盘够不够、现有安装在哪"
- **chroot 内解决所有依赖**：宿主永不执行 apt；Ubuntu 24.04 根文件系统是独立环境
- **systemd 单元 `lsa-pve.service`**：`PrivateMounts=yes`，挂载随单元销毁，不存在残留
- 与 fnOS 版共享内核：`vendor/core/` 从 [LSI-Storage-Fnos](https://github.com/a10463981/LSI-Storage-Fnos) 同步

## 安装

```bash
tar xzf LSI-Storage-PVE-0.1.03.tar.gz && cd LSI-Storage-PVE-0.1.03
sudo ./installer/install.sh doctor
sudo ./installer/install.sh install --lsa-package /root/008.018.012.000_MR_7.38_LSA_Linux.zip
```

LSA 安装包需自备（Broadcom 专有，不随本项目分发），`doctor` 与安装失败时都会给出获取指引。

## 已知限制

- 尚未在真实 PVE 上完成端到端安装验证（开发环境为 Debian 12 构建机）
- 只读组 `readonly_access_groups` 是否真拦写操作未验证
- 依赖 LSA 安装包内含 `gcc_8.3.x` 基线（无 AVX 的虚拟 CPU 只能用它）
