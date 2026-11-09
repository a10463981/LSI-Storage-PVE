# architecture.md — 分层与数据流

## 三层结构

```
┌─────────────────────────────────────────────────────────┐
│ fnOS 平台                                                │
│  /var/apps/LSI-Storage-Fnos/          ← 应用目录（平台装)  │
│  /vol1/@appcenter/LSI-Storage-Fnos/   ← 载荷与 app.sock   │
│  /vol1/@appdata/LSI-Storage-Fnos/     ← rootfs / 日志 / 状态│
│  /vol1/@appconf/…  @apphome/…  @appmeta/…                 │
└───────────────┬─────────────────────────────────────────┘
                │ cmd/main start
                ▼
┌─────────────────────────────────────────────────────────┐
│ 门户层（宿主命名空间）                                     │
│  gate.py  →  TCP 0.0.0.0:2463                             │
│           →  unix $TRIM_APPDEST/app.sock（面板网关）       │
└───────────────┬─────────────────────────────────────────┘
                │ 起一个 unshare -m 子进程
                ▼
┌─────────────────────────────────────────────────────────┐
│ 运行层（私有 mount namespace）                             │
│  launch.sh → rbind /dev /proc /sys → chroot rootfs        │
│           → /etc/init.d/LsiSASH start                     │
│           → 常驻作 PID1 锚点，等 stop.flag                 │
│   chroot 内：slpd(427) + nginx(2464) + LSA 后端(41000)     │
└─────────────────────────────────────────────────────────┘
```

## 端口

| 端口 | 谁 | 说明 |
|---|---|---|
| 2463 | gate.py | 门户页、`/status`、`/setup`、`/op/*` |
| 2464 | chroot 内 nginx | LSA 前端（UI + FastCGI 反代） |
| 41000 | LSA 后端 | 只监听 127.0.0.1 |
| 427 | slpd | SLP 服务发现（UDP） |

## 两个入口

1. **直连**：浏览器打开 `http://<host>:2463/`，gate 直接应答。
2. **面板**：fnOS 桌面点图标 → 面板 nginx 把 `/app/LSI-Storage-Fnos` 反代到
   `$TRIM_APPDEST/app.sock` → 同一份 gate 代码，只是请求路径带前缀。

`gate.py` 的 `strip_prefix()` 会剥掉配置的 `GATE_PREFIX`，另外兜底剥掉任意
`/app/<某个名字>` 前缀，并对无尾斜杠的路径补 302。前端所有 URL 用**相对路径**，
这样两种入口共用一套页面。

## 生命周期钩子

| 钩子 | 时机 | 做什么 |
|---|---|---|
| `install_init` | 解包 app.tgz **之前** | CPU 指令集预检、空间预检、chroot 可用性检查 |
| `install_callback` | 解包之后 | 解 rootfs、写默认配置、按向导设账号口令、自动 `main start` |
| `upgrade_init` / `upgrade_callback` | 覆盖安装 | 保留 `@appdata` 与状态文件，重放已保存的 shadow 行 |
| `uninstall_init` / `uninstall_callback` | 卸载 | 停服务、删 `@appdata`（rootfs 约 172MB） |
| `config_init` / `config_callback` | 改配置 | 只写 `@appconf/<app>/<app>.conf` |
| `main` | 手动/平台调用 | `start` / `stop` / `status` / `restart` / `set-password` |

## 状态与配置

| 路径 | 内容 |
|---|---|
| `$ETC/LSI-Storage-Fnos.conf` | 端口、账号等运行配置（shell 变量格式） |
| `$VAR/config.json` | `{"account": "..."}`，只记账号名，**不含口令** |
| `$VAR/state/shadow.<account>` | 该账号的 shadow 行（0600），升级替换 rootfs 后重放用 |
| `$VAR/state/credential-setup-done` | 标记"已设过口令"，决定门户是否显示设置页 |
| `$VAR/state/setup-in-progress` | 防并发提交的锁 |
| `$RUN/gate.pid` `lsa.pid` `lsa.ns.pid` | 进程锚点 |
| `$RUN/restart.lock` | 重启进行中标记（超 180 秒自动失效） |
| `$TRIM_APPDEST/app.sock` | 面板网关 socket（0600） |

## 进程归属判定

chroot 之后进程的 cmdline 不再包含宿主路径，`pgrep -f` 必然失效。
唯一可靠方式是读 `/proc/<pid>/root` 的符号链接，看是否指向 `$VAR/rootfs`。
`gate.py` 的 `/op/check`、`cmd/main` 的停止逻辑都这么判断。

## 门户路由

| 路由 | 方法 | 作用 |
|---|---|---|
| `/` | GET | 门户页；未设口令时显示设置页 |
| `/status` | GET | JSON：phase、耗时、端口、`need_setup`、`account`、`restarting` |
| `/setup` | POST | 提交账号+口令（口令走 stdin 给 `cmd/main set-password`） |
| `/enter` | GET | 302 到 `http://<Host 头的主机>:2464/` |
| `/op/check` | GET | 7 项只读环境检查 |
| `/op/restart` | POST | 触发 `cmd/main restart`；进行中再点返回 409 |
| `/healthz` `/ping` | GET | 存活探测 |

## 预热门

`compute()` 依次判断：gate 端口 → 2464 是否监听 → 对 LSA root API 发一次 GET 并记录耗时 →
得出 `STARTING` / `WARMING` / `READY` / `FAILED`。前端据此显示三步进度条。
preheat 阶段不要报错，只显示进度——用户看到的第一印象很重要。
