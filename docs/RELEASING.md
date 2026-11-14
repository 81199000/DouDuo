# DouDuo 发版流程（维护者 / Agent 用）

DouDuo 发版不需要发布管家：负责该版本的维护者（人或 Agent）在主干上自己走完下面的步骤即可。

## 前置

- 主干：`~/Projects/douduo`（`main`），remote `origin` = GitHub `81199000/DouDuo`（公开），`gitee` = Gitee `remon8/douduo`（国内镜像）。
- `gh` 已登录；Gitee token 在 `~/.hermes/shared-credentials/gitee-remon8.json`（不入库）。
- 版本号、构建号在 `project.yml`（`MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`），发行说明写 `docs/releases/vX.Y.Z.md`。**发版不改 README**：首页只放功能与安装说明，不写版本号、不列版本流水，版本改动只进 `docs/releases/` 和 Release。

## 一键发版（推荐）

写好 `docs/releases/vX.Y.Z.md`（第一行 `# 标题` 会作为 Release 标题），在主干 main 上：

```bash
scripts/publish.sh X.Y.Z --dry-run   # 先演练：检查 + 编译 + 打包 + 全部测试，不提交不推送
scripts/publish.sh X.Y.Z             # 正式发版
```

脚本会依次完成：改版本号（构建号自动 +1）→ 模拟器与真机未签名包编译 → 全部脚本测试 → 提交并打 tag → 推 GitHub / Gitee → GitHub Release（带发行说明和 IPA）→ Gitee 发行版 → 更新全能签 / 轻松签软件源 → 用手机 UA 匿名验收。任何一步失败都会停下；修好后用同一个版本号重跑，已完成的步骤会跳过，已上传的 IPA 不会被覆盖。

下面是脚本内部的手动步骤，排查时对照用。

## 步骤

1. **合并 + 验证**：要发的分支 / PR 合进 `main`，`xcodegen generate`，模拟器和真机 Release 都 `BUILD SUCCEEDED`，`scripts/test_*.js` / `scripts/test_*.py` 全过。
2. **出包 + GitHub Release**：`./release.sh`（产出 `build/DouDuo-X.Y.Z-unsigned.ipa`，有 `gh` 时建 Release 并上传 IPA；Release 正文默认只有一句「安装方法见 README」，用 `gh release edit vX.Y.Z --title "…" --notes-file docs/releases/vX.Y.Z.md` 补上标题和发行说明——软件源的更新说明就取自这里）。
3. **推代码和 tag 到两边**：
   ```bash
   git push origin main && git push origin vX.Y.Z
   git push gitee main  && git push gitee vX.Y.Z
   ```
4. **Gitee 发行版**：`python3 scripts/sync_gitee_release.py vX.Y.Z`（建发行版、上传 IPA、匿名下载核对大小，失败会非 0 退出）。
5. **更新软件源**：`python3 scripts/build_sign_source.py`（读 GitHub 最近 5 个正式版，生成 `docs/source/douduo.json`（国内 Gitee）和 `docs/source/douduo-github.json`）。有「Gitee 缺 vX.Y.Z」提示就回到第 4 步。
   ```bash
   git add docs/source && git commit -m "chore(源): 软件源更新到 vX.Y.Z"
   git push origin main && git push gitee main
   ```
6. **验收**（用手机 UA 匿名访问）：
   - 两个源地址都返回 200，`apps[0].version` 是新版本；
   - 新版本的 `downloadURL` 能下载（Gitee 200，GitHub 200/206）；
   - Gitee 发行版页面能看到新版 IPA。

## 软件源说明

- 国内源：`https://gitee.com/remon8/douduo/raw/main/docs/source/douduo.json`（下载走 Gitee）
- 海外源：`https://raw.githubusercontent.com/81199000/DouDuo/main/docs/source/douduo-github.json`（下载走 GitHub）
- 全能签一键添加：`nsk-sign://addsource?url=<源地址>`
- 源里只放**未签名 IPA**，项目不提供、不出售任何证书。
