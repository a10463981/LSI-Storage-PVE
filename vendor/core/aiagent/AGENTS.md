# AGENTS.md — 维护入口（先读这里）

这份目录是给**接手维护的人和 AI 工具**看的。README 面向用户，只讲"是什么、怎么用"；
实现细节、踩过的坑、排障与发版流程全部收在这里。

**动手改代码之前，请先读完本文件，再按需要读对应分册。**

## 项目一句话

把 Broadcom LSI Storage Authority（LSA）连同它需要的 Ubuntu 运行环境一起打进一个 fnOS
应用包（appname = `LSI-Storage-Fnos`），装完点开就是图形化 MegaRAID 管理界面。

## 目录地图

```
build/            七阶段构建流水线 + 两个静态守卫
  00-fetch.sh     下载 Ubuntu rootfs 与 LSA 安装包，校验 SHA256
  10-unpack.sh    解包 rootfs、换 HTTP apt 源
  20-apt-deps.sh  安装 6 个运行期依赖 + passwd + psmisc
  30-install-lsa.sh  双层 zip 解压 → 选 gcc_8.3.x 基线 → dpkg -i 三个 deb
  40-patch.sh     构建期补丁（符号链接、端口、账号、响应头…）
  50-slim.sh      四批瘦身，每批过后跑 ELF 依赖检查与快速冒烟
  60-smoke-test.sh   等端口 / 等 API 200
  70-package.sh   打 rootfs.tar.gz + 写构建指纹
  80-pack.sh      组装 pkg/ + 跑挂载守卫 + 调 fnpack
  90-skeleton.sh  只出骨架载荷（不含 LSA），用于验证平台交互
  verify/         check-elf.sh（ELF 依赖）、check-mounts.sh（挂载安全静态守卫）
pkg/              fpk 的内容
  manifest        平台清单（INI，key = value）
  cmd/            9 个生命周期钩子 + main + 3 个 lib + reset-password + audit-residue
  app/runtime/    gate.py（门户）、launch.sh（启动 LSA）、web/（门户页面）
  app/ui/         应用图标与 app/ui/config（面板入口声明）
  wizard/install  安装向导（合法 JSON 文件，不是目录）
docs/             有卡环境验证清单、截图
aiagent/          本目录
```

## 三个必须记住的约束

1. **`appname` 一旦发布就不能改。** 它是平台识别应用的唯一键，改了等于变成另一个应用，
   已装用户必须卸载重装，账号口令全部丢失。显示名（`display_name`）和仓库名可以随便改。
2. **挂载纪律。** 所有 mount/umount 只能发生在 `unshare -m --propagation private` 的私有
   命名空间内；脚本里**不允许**出现 `umount -R`，也不允许对宿主 `/dev /proc /sys /run` 动手。
   `build/verify/check-mounts.sh` 会静态拦截，已接进 `make check` 与 `80-pack.sh`。
3. **停 LSA 只能走 init 脚本。** `cmd/main stop` 最终调 `/etc/init.d/LsiSASH stop`。
   不要 `pkill`、不要手杀 `slpd` —— 原因见 `pitfalls.md`。

## 常见任务去哪查

| 我要做的事 | 读哪个文件 |
|---|---|
| 搞清楚门户、chroot、LSA 之间怎么串起来的 | `architecture.md` |
| 改构建流程 / 调体积 / 换 LSA 基线 | `build.md` |
| 遇到奇怪现象先看看是不是踩过的坑 | `pitfalls.md` |
| 用户报障，要定位问题 | `troubleshooting.md` |
| 要发新版 | `release.md` |

## 每次改动前的检查清单

- [ ] 改动是否碰到了 `pkg/cmd/*` 或 `app/runtime/*`？改完先在 `.15` 上 `uninstall` 再 `install` 验证
- [ ] 是否新增了 `mount` / `umount`？跑 `bash build/verify/check-mounts.sh`
- [ ] 是否新增了外部命令依赖？只能依赖 rootfs 内已有的与宿主的基础工具
- [ ] 是否引入了 Python 第三方库？**不允许**，gate.py 只用标准库
- [ ] 是否碰到账号 / 口令路径？口令只能经 stdin，不许进 argv、日志、`/status`
- [ ] 版本号是否按 `release.md` 的规则递增

## 文档与素材

| 文件 | 说明 |
|---|---|
| `README.md` / `README.en.md` | 面向用户，中英一一对应，**保持精简（中文 ≤120 行）** |
| `RELEASE_NOTES.md` | 每个版本的发布说明，直接粘到 Release 页 |
| `docs/有卡环境验证清单.md` | 有卡后的逐项验证步骤 |
| `docs/screenshots/screenshot-1.png` | README 引用的第一张（门户/主界面） |
| `docs/screenshots/screenshot-2.png` | **未被 README 引用**，保留备选 |
| `docs/screenshots/screenshot-3.png` | README 引用的第二张（控制器与磁盘） |

> 三张截图的拍摄顺序与实际界面内容的对应关系未能确认（拍照时无法读取图像内容），
> 若要重排顺序，直接看图片确认后在两版 README 里同时调整。

## 两条环境事实（避免重复摸索）

- 测试机 `.15` 是 fnOS，**没有 RAID 卡**：只能验证安装、启动、门户、登录链路，硬件相关一律未验证。
- 构建机需要 root、能访问清华 TUNA 镜像、有 `fnpack`（平台官方打包工具）。
