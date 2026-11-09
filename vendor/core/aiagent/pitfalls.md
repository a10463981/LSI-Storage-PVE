# pitfalls.md — 踩坑记录（现象 → 根因 → 解法）

按"症状最容易怎么被描述"排序。前三条花的时间最多。

---

## 1. LSA 前端灰屏，root API 返回 400，日志里 `libgateway.so` 加载失败

**现象**：门户正常、能跳转到 2464，但页面一片灰；`/LSI/Storage/MR/API/1.0/` 返回 400；
`lsa.txt` 里能看到 `Library load failed` 或 `OPENSSL_3.2` 字样。

**根因**：`/etc/init.d/LsiSASH` 里有一段 slpd 分支：

```sh
export LD_LIBRARY_PATH=/opt/lsi/LSA/libs2
```

它**覆盖**了调用方传进来的路径，导致 LSA 找不到 OpenSSL 3.2 那一套库，
`libgateway.so` 加载失败 → FastCGI 后端不可用 → 前端拿不到数据 → 灰屏。

**解法**：选定 `gcc_8.3.x` 基线后该目录里本来就带了正确的库路径，这段 export 不再有害；
补丁 3c 现在只做**检测与记录**，不强行改脚本（改它容易引发别的加载问题）。
判断标准始终是：**root API 能不能返回 200**。

---

## 2. 三处符号链接，缺一条就起不来

| 链接 | 目标 | 缺失后果 |
|---|---|---|
| `/usr/lib/x86_64-linux-gnu/libcrypt.so.2` | `libcrypt.so.1` | LSA 主程序加载失败 |
| `/usr/lib/x86_64-linux-gnu/libldap-2.4.so.2` | `libldap.so.2` | gcc8 基线二进制加载失败 |
| `/opt/lsi/LSA/libs2/libslp.so.1` | `libslp.so.1.0.0` | slpd / SLP 相关功能异常 |

`/op/check` 的第一、二项就是查这个。重建用 `ln -sfn`，别删原文件。

---

## 3. 8 处端口占位符

**现象**：装完 2463/2464 都没起来，或者 nginx 起在了奇怪端口。

**根因**：LSA 的 nginx 配置模板里有 8 处占位符（`nginx_default` / `LSA_Default` 之类），
不替换就用了模板默认值。

**解法**：补丁 4 在构建期统一替换成门户端口（2463）与后端端口（9000 → 实际映射 41000）。
新增端口相关改动时**回头数一遍这 8 处**，漏一处就会出现"某个接口 404 但主页正常"。

---

## 4. `GATE_PREFIX` 被算成了安装暂存目录名

**现象**：从 fnOS 面板点图标打不开，报 `not found`（这个 404 是我们自己返回的，
不是 nginx 的）。

**根因**：`install_callback` 运行在平台的**安装暂存目录**里
（`/vol1/appcenter-downloads/<appname>-<version>-tpk/`），那一刻
`basename(dirname(cmd))` 得到的是 `LSI-Storage-Fnos-0.1.01-tpk` 而不是应用名，
于是 `GATE_PREFIX` 变成 `/app/LSI-Storage-Fnos-0.1.01-tpk`，与面板转发的
`/app/LSI-Storage-Fnos` 对不上 → 落进 404 分支。

**解法**（三层，全部保留）：
1. 应用名以 `manifest` 的 `appname` 为准，不再用目录名；
2. `strip_prefix()` 兜底剥掉任意 `/app/<某个名字>` 前缀；
3. `cmd/main start` 校验在跑的门户的 `GATE_PREFIX`，不匹配就重启它；
   `install_callback` 优先用 `/var/apps/<appname>/cmd/main` 启动，避开暂存路径。

---

## 5. `countdown = countdown || 3` 导致倒计时永远不触发

**现象**：门户显示"N 秒后自动进入"，但时间到了什么也不发生。

**根因**：`0 || 3` 恒等于 `3`。计数降到 0 之后，下一次 tick 立刻把它重置回 3，
`countdown <= 0` 这个分支一次都进不去（同一个 bug 让 `countdown < 0` 也永远不成立）。

**解法**：倒计时已整体删除，改为用户点按钮手动进入（产品决策，不是补丁）。
教训：**JS 里用 `||` 给计数器兜默认值是个陷阱**，0 是合法值。

---

## 6. CPU 指令集决定 LSA 基线

**现象**：`nginx: CPU ISA level is lower than required`，服务起不来。

**根因**：LSA 提供多个编译基线，高版本基线要求 AVX/AVX2/SSE4.2；
KVM 的 Common KVM processor 不提供这些。

**解法**：锁 `gcc_8.3.x`。详见 `build.md`。为此付出的代价是 libldap soname 不匹配（见坑 2）。

---

## 7. SLP 单向不通，远程服务器条目退化成 127.0.0.1

**现象**：LSA 的「远程服务器」里能看到某台机器，点进去灰屏；该机器本身的 LSA 其实健康。

**根因**：LSA 靠 SLP（UDP 427）发现远端属性。宿主装了 Docker 会有 5–7 个网桥接口，
slpd 绑多网卡时属性请求可能从错误接口发出，回复回不来。加上
`slp_find_service_strictness = 0` 允许显示"属性不完整"的服务器，
于是列表里有条目、点进去后端拿不到地址，退化解析成 `127.0.0.1` —— 浏览器于是去连
用户自己的电脑。

**为什么没在构建期"修"**：把 strictness 改成 1、给 slpd 限定 `net.slp.interfaces`
都要重跑整条 `make image` 并重新验证，而且只影响"自动发现"这条脆弱路径。
当前的产品选择是：**不在应用里做远程代理**，让用户直接访问对方 LSA 的界面。

---

## 8. `X-Frame-Options` 阻止被嵌入

**现象**：把远端 LSA 嵌进 iframe 时白屏，页面什么都没报。

**根因**：LSA 的 nginx 模板里有 `add_header X-Frame-Options "SAMEORIGIN"`（两处：
server 级 + `location /` 里）。我们自己的构建用补丁 3e 注释掉了这两行，
所以本机可嵌入；**别人机器上原厂的 LSA 仍然带这个头**。

**判断方法**：`curl -sI http://<host>:2464/ui/core/index.html | grep -i x-frame`。
有输出就是拒绝嵌入。

**注意**：0.1.02 / 0.1.03 期间曾做过 iframe 嵌入方案，后来按用户要求整体回退，
当前版本不做嵌入，直接用顶层跳转。

---

## 9. 卸载后平台残留记录，导致装不上

**现象**：`appcenter-cli uninstall` 返回 `code 10111`，`list` 里那条记录还在，
再 `install-fpk` 只说 "is installed" 什么也不做。

**根因**：某次安装中途失败（例如载荷缺失）时平台回滚不完整，DB 里留下一条
"已安装"记录，但文件已经没了，卸载钩子跑不起来。

**解法**：**按记录里的版本号**重建一个最小应用目录再卸载：

```bash
mkdir -p /var/apps/<appname>
# 放入 manifest（version 必须等于记录里的版本）、cmd/ 钩子（可直接 exit 0）、config/
appcenter-cli uninstall <appname>
```

版本号对不上仍然会 10111。重启 `trim_app_center` 无效。

---

## 10. 平台把 `cmd/main start` 的退出码当安装结果

**现象**：装完应用立刻消失。

**根因**：`cmd/main start` 返回非零 → 平台判定安装失败 → 自动卸载（code 10237）。

**解法**：`main start` 只要 supervisor 起来了就 `exit 0`，LSA 没就绪不算失败——
那是预热门要展示的过程，不是安装错误。

---

## 11. `install-fpk` 对已装应用是 no-op

同版本号、甚至不同版本号，只要平台认为它"已安装"，`install-fpk` 都会跳过。
**换版本必须 `uninstall` + `install`**。`appcenter-cli` 没有 upgrade 命令。

---

## 12. 口令的几条红线

- 只能经 **stdin** 交给 `chpasswd`，不许出现在 argv（`ps` 可见）
- 不许写日志，日志只记"已设置/失败 + 退出码"
- 不许出现在 `/status` 或任何页面
- 落盘只存 **shadow 行**（哈希），不存明文；升级替换 rootfs 后重放这一行
