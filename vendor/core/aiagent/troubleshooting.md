# troubleshooting.md — 排障手册

## 先看哪里

| 位置 | 内容 |
|---|---|
| `$VAR/logs/gate.log` | 门户日志（启动参数、路由、异常） |
| `$VAR/logs/gate.out` | Python 未捕获异常会落这里 |
| `/var/log/apps/<appname>.log` | 平台捕获的钩子输出（install/uninstall 的 echo 都在这里） |
| `$VAR/rootfs/opt/lsi/LSIStorageAuthority/logs/lsa.txt` | **LSA 自己的日志，最重要的一个** |
| `$VAR/rootfs/opt/lsi/LSIStorageAuthority/logs/slpd.log` | SLP 相关 |

`$VAR` = `/vol1/@appdata/<appname>`。

## 三步定位法

```bash
# 1. 门户活着吗
curl -s http://127.0.0.1:2463/status

# 2. LSA 起来了吗（2464 前端 / 41000 后端）
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:2464/LSI/Storage/MR/API/1.0/

# 3. 环境自检（应用页面上那个按钮，或直接打接口）
curl -s http://127.0.0.1:2463/op/check
```

`/op/check` 的 7 项覆盖了绝大多数常见故障，输出里带 `status` 与 `fix` 建议。

## 常见症状对照

| 症状 | 大概率原因 | 怎么看 |
|---|---|---|
| 门户 404 / 面板图标打不开 | `GATE_PREFIX` 与实际 appname 不一致 | `ps` 里看 gate.py 的 `GATE_PREFIX` 环境变量 |
| 门户能开，进度卡在"等待 LSA 初始化" | LSA 还在预热（无卡机器可达数分钟） | `lsa.txt` 尾部；root API 是否已 200 |
| 状态 `FAILED` | LSA 进程没起来 | `lsa.txt` 里搜 `Library load failed` / `CPU ISA level` |
| 前端灰屏 | 插件/库加载失败，root API 400 | 同上看 `libgateway` / `OPENSSL_3.2` |
| 提示"未检测到控制器" | 没有卡，或卡在宿主未直通 | `ls /dev/megaraid_sas_ioctl_node`、`lsmod \| grep megaraid` |
| 设置口令后登录报 Invalid Credentials | 账号名不一致，或口令没写进去 | `chroot $VAR/rootfs passwd -S <账号>` 应为 `P` |
| 重启后一直显示"重启中" | 重启锁没清 | 正常情况下新门户启动会清；否则删 `$RUN/restart.lock` |
| 卸载报 `code 10111` | 平台残留记录 | 见 `pitfalls.md` 第 9 条 |

## 判断"预热中"还是"挂了"

```bash
# 连续两次，看 root API 的返回码与耗时
for i in 1 2; do curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' \
  http://127.0.0.1:2464/LSI/Storage/MR/API/1.0/; sleep 5; done
```

- 200 → 已就绪
- 400 且耗时在变短 → 仍在预热，等
- 连接失败 + `lsa.txt` 无新行 → 进程没起来，看 `main stop` 后再 `start` 的输出

## 无卡环境（测试机 `.15`）的正常长相

```
/op/check → ok 7 / warn 1 / fail 0
  唯一 warn：无 /dev/megaraid_sas_ioctl_node，megaraid_sas 未加载
```

如果这里出现 `fail`，说明不是"没卡"这么简单，按上表往下查。

## 想手工验证 LSA 是否真能登录

浏览器打开 `http://<host>:2464/ui/core/index.html`，用 `/setup` 设的账号登录。
**首次登录 20–40 秒**，期间无反馈是正常的。想跳过"远程服务器列表"中转页就直连这个
`ui/core/index.html`（LSA 根路径是一段 70 字节的 `onload` 跳转桩，会转到 remoteserver）。

## 收集现场信息

```bash
APP=LSI-Storage-Fnos
/var/apps/$APP/cmd/main status
curl -s http://127.0.0.1:2463/status
curl -s http://127.0.0.1:2463/op/check
tail -50 /vol1/@appdata/$APP/logs/gate.log
tail -80 /vol1/@appdata/$APP/rootfs/opt/lsi/LSIStorageAuthority/logs/lsa.txt
awk '$2 ~ /LSI-Storage-Fnos/' /proc/mounts      # 挂载残留
for p in /proc/[0-9]*; do r=$(readlink $p/root 2>/dev/null); case "$r" in *$APP/rootfs*) echo "$p $r";; esac; done
```
