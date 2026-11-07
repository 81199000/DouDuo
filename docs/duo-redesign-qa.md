# DouDuo 改版验收报告（阻塞，非最终通过）

## 验证对象与结论

- 工作树：`/Users/zhanghongsheng/Projects/douduo-shayu`，分支 `shayu`。
- 基线 main：`cdb95e13d2212ad0ca94f9b3af5acc0bbaa895e0`。
- redbao：`7e96ee7a0750ffbf391adbabde113d80a7ce4440`；baihu：`de95f8195d36922f167f9f8491a27881ebe4a305`。
- 按要求依次合并，文本合并无冲突；集成提交 `e8db303`。
- **总判定：不通过，集成编译失败。不得将父任务各自编译通过视为集成通过。**

## 阻塞缺陷

`DouDuo/DouyinBridge+More.swift:224` 报 `invalid redeclaration of 'postJS'`。
红暴在 `DouDuo/DouyinExtras.swift:231` 已声明 `DouyinBridge.postJS`，白虎又在同类型的 extension 中声明同名静态属性。Git 自动合并未发现文本冲突，但 Swift 编译器发现语义冲突。

建议由豹子协调业务代码修复：区分“我的作品”和“作者作品”的 JS 属性命名并核对各调用点及返回结构，或合并为明确共用实现；鲨鱼按只读职责未修改业务代码，也未擅自消解此冲突。

## 编译与 UI 测试实测

执行任务指定的完整命令：

```sh
xcodebuild -project DouDuo.xcodeproj -scheme DouDuo -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath build/dd build CODE_SIGNING_ALLOWED=NO
xcodebuild test -project DouDuo.xcodeproj -scheme DouDuo -destination 'id=E696C9FB-6688-4855-8E2B-9017F0A09F83' -derivedDataPath build/dd
```

- 编译：`BUILD FAILED`，退出码 65。
- 测试：`TEST FAILED`，退出码 65；在编译阶段被上述重复声明阻止，未运行测试用例。
- 用例统计：passed **0** / failed **0** / skipped **0**，executed **0**。这里 failed=0 仅代表没有用例实际执行，**不代表测试通过**；未执行不等于 skipped。
- 原始日志：`build/qa/build.log`、`build/qa/test.log`。
- 未修改 UI 测试；当前不是 identifier 过时问题。

## duo-lint 对比

分别对 main 的 Swift 源码快照与合并后的 `DouDuo` 实际运行同一 duo-lint。

| 项目 | main | 合并后 |
|---|---:|---:|
| 扫描 Swift 文件 | 11 | 15 |
| warning | 5 | 4 |
| error | 0 | 0 |
| DUO002 | 4 | 4 |
| DUO003 | 1 | 0 |

- 新增 **0**；消除 **1**：原 `DouyinFeedView.swift:650` 的 DUO003 方向判断。
- 保留：`DouyinFeedView.swift:120,519` 固定 1200pt 的隐藏签名 WebView；`DouyinLiveChat.swift:28` 固定 1280pt 的隐藏 WebView（三条可豁免）；`ShortVideoPlayer.swift:324` 固定 320pt（遗留项，不因本次保留就判为适配通过）。

## 方案第 4 节逐条验收

| 标准 | 判定 | 证据/缺口 |
|---|---|---|
| 1 推荐/关注/直播/列表播放状态栏、顶栏安全区 | 未验证 | 集成包无法构建，不能将旧包或父分支截图当成本次证据 |
| 2 五颗液态侧栏按钮、更多四项及分享/下载 | 未验证 | 未运行集成包，四项交互及相册落盘未验收 |
| 3 外屏摄像头避让、内屏平放/半折书本与桌面、折痕避让 | 未验证 | 尚无集成包截图；半折姿态未验证（需 Device Hub/真机） |
| 4 消息未读/翻页/跳视频、双方作品网格播放/翻页、关注/粉丝 | 未验证 | 集成包未运行；未以父任务结果代替本次实测 |
| 5 编译成功、lint 不新增、原 UI 测试 | 不通过 | BUILD FAILED；lint 不新增通过；UI 测试编译阻塞、执行 0 |

## 截图、接口与操作边界

- 预定截图目录：`/Users/zhanghongsheng/Projects/douduo-shayu/build/qa/`（不入库）。**本轮未生成集成包 UI 截图**。
- 已执行 `simctl io ... enumerate`：外屏 Screen ID 1（1398×2034）、内屏 Screen ID 3（2007×2853）可识别；端口 On 不能证明实际画面亮起或姿态正确。
- 未安装失败构建产物，未卸载现有 App，保留已登录会话。
- 未读取旧 App 日志作为新包接口验收，未写 `dd-cmd.js`；新接口 status/code 未验证。
- 未触发评论、弹幕、点赞、关注等账号写操作；未 push、未改版本号或 Vendor。
- 审查量表：证据不足，不打满分或虚构 24 分制总分；不满足发布门槛。需修复集成编译后重新跑完整验证。
