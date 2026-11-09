# release.md — 发版流程

## 版本号规则

- 形如 `0.1.03`，**保留前导零**。fnpack 与 fnOS 应用中心都会原样显示，不会被规范成 `0.1.1`。
- 递增用 `0.1.04 → 0.1.05 …`；换成 `0.1.10` 也可以。
- **不要发 `0.1.1`**：字符串比较下它与 `0.1.01` 的大小关系不确定，可能出现"装了新版却不触发升级"。
- 应用标识变更（`appname`）属于大版本事件，且**必须让用户卸载重装**，要单独说明。

## 发版前检查

```bash
bash build/verify/check-mounts.sh          # 挂载静态守卫
make check                                 # ELF + 挂载
grep -E '^appname|^version' pkg/manifest
git status --porcelain                     # 必须干净
git grep -niE '<旧标识>' HEAD -- .          # 改名后应为 0
find . -type f -not -path './.git/*' -size +1M   # 仓库里不该有大文件
```

## 打包装机验证（每次都要做）

```bash
make image && make pkg                     # → build/dist/LSI-Storage-Fnos.fpk

# 测试机：先卸载再装（install-fpk 对已装应用是 no-op）
appcenter-cli stop LSI-Storage-Fnos
appcenter-cli uninstall LSI-Storage-Fnos
rm -rf /var/apps/LSI-Storage-Fnos /vol1/@appcenter/LSI-Storage-Fnos /vol1/@appdata/LSI-Storage-Fnos
appcenter-cli install-fpk LSI-Storage-Fnos.fpk
curl -s http://127.0.0.1:2463/status       # 等 READY
```

必须核对的几项：

- [ ] 应用中心显示的版本字符串正确
- [ ] `/status` 为 `READY`
- [ ] 直连 `:2463` 与面板 `:5666/app/LSI-Storage-Fnos/` 都 200
- [ ] 首启能设账号口令，且**真实登录 LSA 成功**（不是只看哈希）
- [ ] 连续启停两轮，停止后进程 0 / 挂载 0 / 端口 0
- [ ] `/op/check` 无 `fail`

## 产物

| 文件 | 说明 |
|---|---|
| `LSI-Storage-Fnos-<ver>.fpk` | 主资产，含 LSA |
| `LSI-Storage-Fnos-src-<ver>.tar.gz` | `git archive HEAD`，只含源码与截图 |
| `SHA256SUMS` | **只覆盖上面两个**，`sha256sum -c` 必须两项 OK |

放置到共享目录后：

```bash
cd /vol1/1000 && sha256sum -c SHA256SUMS
chown admin:Users LSI-Storage-Fnos-* SHA256SUMS && chmod 644 …
rm -f <旧版本的 fpk 与源码包>          # 只留最新一份，避免用户拿错
```

## git 与 Release

```bash
git add -A
git -c user.name="a10463981" \
    -c user.email="113079843+a10463981@users.noreply.github.com" \
    commit -m "release: <ver> …"
git tag -a v<ver> -m "博通控制器管理 v<ver>"
# 不要 push，推送由持有写权限凭据的人执行
```

Release 页：

- Tag `v<ver>`，Target `main`
- 标题 `博通控制器管理 v<ver>`
- 正文直接粘 `RELEASE_NOTES.md` 全文
- 资产上传三个文件（fpk / src / SHA256SUMS）
- 发布前确认正文**没有写未实现的功能**

## 不能做的事

- ❌ 把 fpk 提交进 git 仓库（仓库只放源码；fpk 挂在 Release 上）
- ❌ 把 `build/vendor/` 的 LSA 安装包提交进仓库
- ❌ 用 `rsync --delete` 同步源码到本地仓库副本（会删掉 `docs/screenshots/` 这类后加的文件）
- ❌ 手动改 fpk 文件名里的 appname 部分（`fnpack` 用 `appname` 生成产物名）
- ❌ 在没跑完整验证的情况下发版

## 本次交付后的已知缺口

有卡环境的四项仍未验证：控制器枚举、虚拟盘/物理盘状态、重建进度、
`readonly_access_groups` 是否真的拦住写操作。发版说明里要如实标注为"已知限制"。
