# DouDuo 改版集成验收报告（不通过，已完成本轮验证）

## 对象与结论

- 工作树 `/Users/zhanghongsheng/Projects/douduo-shayu`，分支 `shayu`；本地合并 redbao `7e96ee7`、baihu `de95f81`，后合并修复 `061cbc1`，当前验证业务提交 `eb1e2f0`。
- main 基线 `cdb95e13d2212ad0ca94f9b3af5acc0bbaa895e0`。
- 前轮 postJS 重复声明已由上游修复，本轮集成 **BUILD SUCCEEDED**。但 UI 测试 **4 passed / 3 failed / 2 skipped**，故不满足发布验收，不能因编译成功宣布改版通过。
- 业务代码未修改、未 push、未卸载 App；只改本报告和 UI 测试。现有 Vendor 软链未入提交。

## 1. 编译与 lint

实跑任务指定 build 命令：

```sh
xcodebuild -project DouDuo.xcodeproj -scheme DouDuo -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath build/dd build CODE_SIGNING_ALLOWED=NO
```

`build/qa/build-retry.log` 结尾 **BUILD SUCCEEDED**。随后 `simctl install` 覆盖安装该 Debug 包（`me.rrmm.douduo`），`simctl launch` 返回 PID，登录数据保留。

同一 duo-lint 对 main 快照与集成源运行，前轮基线实测保留；本轮 `lint-retry.txt` 再确认：

| 项目 | main | 集成 |
|---|---:|---:|
| Swift 文件 | 11 | 15 |
| warning / error | 5 / 0 | 4 / 0 |
| DUO002 | 4 | 4 |
| DUO003 | 1 | 0 |

新增 **0**、消除 **1**（原 FeedView:650 方向判断 DUO003）。保留 FeedView:120、519 的 1200pt 与 LiveChat:28 的 1280pt 隐藏签名 WebView（三条豁免）；ShortVideoPlayer:324 的 320pt 遗留 warning 未消除，不能视为适配合格证据。

## 2. UI 测试（跳过不算通过）

原命令完整执行，日志 `build/qa/test-retry.log`：

```sh
xcodebuild test -project DouDuo.xcodeproj -scheme DouDuo -destination 'id=E696C9FB-6688-4855-8E2B-9017F0A09F83' -derivedDataPath build/dd
```

首轮执行 9 项，4 passed / 3 failed / 2 skipped，**TEST FAILED**。修正过时测试后重跑完整命令，工具在 420 秒中断（`test-final.log`，已完成5项）；随后只补跑另外4项（`test-completion.log`）。以每个用例最后完成结果合并去重仍为 **4 / 3 / 2**，不是宣称第二轮一次完整 test 命令成功。程序汇总见 `test-counts.json`。

| 用例 | 最终结果 | 证据/说明 |
|---|---|---|
| testAutoFitToggle | passed | 菜单开关往返 |
| testCoreFlow | failed | 第二轮上滑后 currentID 未变化；首轮到作者点击时 firstMatch 命中离屏元素 y=-500.1 |
| testLikeAndCollect | skipped | 本轮只读授权，主动 XCTSkip，未执行真实点赞/收藏 |
| testLivePlayback | failed | live.status=0，预期1，流未 ready；尚不能归因业务回归或直播/环境 |
| testLocalFillBothOrientations | passed | 本地片两方向截图流程完成；无像素断言，不能替代实际姿态验证 |
| testLocalNarrowFill | passed | 本地窄片截图流程完成 |
| testPauseAllPlumbing | passed | 停声/进度冻结断言通过 |
| testRotationSanity | skipped | 连续3次转屏未使窗口变横，环境原因；不算通过 |
| testVLCFallback | failed | 上滑前后 currentID 相同，切片断言失败 |

测试文件仅两类修改：禁止账号写操作的 skip；作者入口选择当前 isHittable 元素，并把旧网页版返回 identifier `douyin.web.back` 更新为原生 `douyin.author.back`。原 selector 的确过时，但修改后核心流程仍在上滑处失败，不能将全部失败归为测试过时。未改业务、未削弱上滑/播放断言。VLC 测试运行时日志可见 AV 引擎记录，因此强制 VLC 是否真正生效仍需另查，不能把失败直接归罪 VLC。

## 3. 实机式模拟器观察与截图

设备 `E696C9FB-6688-4855-8E2B-9017F0A09F83`。`simctl io enumerate` 识别外屏 display 1、内屏 display 3。最初无 Simulator 窗口，实际打开 Xcode 包内 `Contents/Applications/DeviceHub.app` 后，工具栏 Closed / Partially Open / Open 可点击，Open 后内屏确有图像；此前“内屏不可用”的限制已解除。

截图目录 **`/Users/zhanghongsheng/Projects/douduo-shayu/build/qa/`**（不入库）。程序枚举核实 **14张**：

| 页面 | 外屏1398×2034 | 内屏2853×2007 |
|---|---|---|
| 推荐 | outer_recommend.png | inner_recommend.png |
| 更多 | outer_more_menu.png | inner_more_menu.png |
| 评论 | outer_comment.png | inner_comment.png |
| 我的作品 | outer_my_works.png | inner_my_works.png |
| 关注列表 | outer_following.png | inner_following.png |
| 消息 | outer_messages.png | inner_messages.png |
| 作者网格 | outer_author_grid.png | inner_author_grid.png |

已视觉复核联系表 `contact-sheet.jpg` 及原始推荐页：页面与命名吻合。推荐页两屏均为五颗液态圆侧栏（作者/点赞/评论/收藏/更多），顶栏不压右侧系统时间；外屏摄像头系统状态区域与作者按钮可见分离。系统状态显示时间和 Wi-Fi/环形指示，但未看到明确蜂窝信号格及电池，不能宣称全三项通过。

更多菜单可见四项（弹幕、不感兴趣、转发、下载）；GUI 操作记录显示内屏转发打开系统分享面板后取消，未实际发送。下载未执行、相册落盘未验证；弹幕/不感兴趣未发送，保持账号只读。

消息分组可见 全部22/评论12/赞2/粉丝8/系统1，关注列表可见20行数据标题；我的默认作品页签有网格，作者为原生作品网格。GUI 操作记录显示两屏点作者网格可进入播放页且时间走动；这些行为记录与静态截图分开陈述。我的作品网格播放、粉丝列表、通知跳视频仍未独立验证。

Partially Open 控件已能切换，但没有保存可核验的半折书本/桌面截图，也没有逐一验证折痕避让，因此 **半折书本/桌面布局未验证（需 Device Hub/真机继续验收）**；不能因切换按钮成功就判通过。内屏竖持、任意角度连续性、Split View、PiP、键盘连续性未测。

GUI 轨迹：`/Users/zhanghongsheng/Applications/OpenGCUA/runs/20261107_143038_DouDuo_E696C9FB-6688-4855-8E2B-9_cdccd9`。最终回到 Closed；GUI 最后一次返回后的画面未另截图确认。

## 4. 接口证据与风险

实际重新查询当前 App 数据容器后读取 `Documents/ddlog.txt`，保存本地快照 `build/qa/ddlog-snapshot.txt`（不入库，含账号上下文，不作为对外附件）。注意测试重新安装可使容器 UUID 改变，不应沿用旧路径。

只引用本次启动后的时段，不把14:08旧记录当新证据：

- 14:33:58 `DDNOTICE group=700 n=10 more=true max=1794030808`。
- 14:35:53 同组第一页，14:35:54 下一页 `max=1794027581`，10条且游标变化，证明消息读翻页发生；未验证通知跳视频。
- 作者页14:36起大量 `DDPOST n=14..18 more=true`，最终14:37:04 `n=0 more=false`，证明作品接口有数据且翻页发生；**短时连续大量自动取页是性能/过度预取风险**，待业务方核对 onAppear 触发，不擅自修。
- 日志快照内 `DDSEND` **0行**；本轮未触发账号评论/弹幕/点赞/收藏/关注写测试。
- 此版本成功读取日志仅包含 n/more/max，没有逐请求 HTTP status/status_code；不能由“有数据”补造为200/0。**新接口精确 status/code 未验证**，也未执行 dd-cmd GET 补测。DDREL tag 无记录，不据此断言关注接口失败（UI已显示数据）。

## 5. 方案第4节逐条判定

| 标准 | 判定 | 已有证据与剩余缺口 |
|---|---|---|
| 1 推荐/关注/直播/列表播放均显示时间、信号、电量且顶栏避让 | 未验证（部分满足） | 推荐两屏时间/Wi-Fi可见且顶栏分离；蜂窝/电池、关注/直播/列表逐页状态栏未全验 |
| 2 五颗液态按钮、更多四项均能用 | 未验证（部分满足） | 五颗/四项展示通过；内屏分享面板观察通过；下载落盘未测，账号写动作禁测 |
| 3 外屏避摄像头、内屏平放与半折书本/桌面符合布局 | 未验证（部分满足） | 外屏/内屏Open有当前包截图；半折双姿态和折痕安全未验 |
| 4 消息未读/翻页/跳视频，双方网格播放翻页，关注/粉丝列表 | 未验证（部分满足） | 未读/消息翻页、作者网格与播放、作品翻页、关注列表有证据；通知跳转、我的播放、粉丝未验 |
| 5 编译成功、lint不新增、原UI测试全过，跳过单列 | **不通过** | BUILD SUCCEEDED、lint新增0通过；用例4通过/3失败/2跳过，不满足全过 |

结论：**本轮 QA 已执行并交付，但产品验收不通过，不能发布为全部合格。** 需业务方复核上滑切片/直播 ready、作者作品连续预取，再补齐上述姿态和功能缺口。审查量表证据不足，不虚构24分总分或宣称达到发布门槛。
