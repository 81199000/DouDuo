# DouDuo · iPhone Duo 标准化改版方案（v1.3.0）

> 统筹：豹子（baozi）｜执行：红暴（redbao，简单件）、白虎（baihu，难件）｜验证：鲨鱼（shayu）
> 依据：skill `iphone-duo-design`（Apple HIG「Designing for iPhone Duo」+ Tech Talk 111461/111463/111466）
> 工具链：Xcode 27.2 / iOS 27.2 SDK（已具备 `ArrangementView`、`GeometryProxy.reservedRegions`、`glassEffect`）。
> 部署目标保持 iOS 17：所有 27.1 / 26 新 API 一律 `if #available` 包起来，老系统走旧布局，不许因此抬高 deploymentTarget。

---

## 1. 现状问题（代码核对）

| # | 问题 | 位置 |
|---|---|---|
| P1 | 播放时状态栏被隐藏：`INFOPLIST_KEY_UIStatusBarHidden: YES` + 两处 `.statusBarHidden(true)` | `project.yml`、`DouyinFeedView.swift:726`、`DouyinExtras.swift:608` |
| P2 | 姿态适配只靠 `geo.size.width >= 700` 一刀切；不认 size class、不认折痕（fold）和外屏摄像头遮挡区 | `DouyinFeedView.swift:703` |
| P3 | 右侧栏 8 个按钮（头像/赞/评论/弹幕/收藏/不感兴趣/转发/保存），外屏竖屏挤到顶，半折时还会压在折痕上 | `DYVideoPage.actions` |
| P4 | 侧栏按钮是裸图标+阴影，不是液态玻璃 | 同上 |
| P5 | 作者页「查看全部作品」跳网页（当初 `/aweme/post/` 403）——**今天已实测恢复可用** | `DYAuthorScreen` |
| P6 | 没有消息/通知、我的作品、关注/粉丝列表 | — |
| P7 | duo-lint：5 条 warning（3 条固定 1200/1280pt 是隐藏签名 WebView，可豁免；`DouyinFeedView.swift:650` 按方向判断布局要改） | — |

## 2. 设计方案

### 2.1 状态栏（P1）
- 删掉 Info 里的 `UIStatusBarHidden` 和两处 `.statusBarHidden(true)`；根视图 `.preferredColorScheme(.dark)`，状态栏白字。
- 视频画面仍然 `ignoresSafeArea()` 铺满到屏幕边（背景层允许，duo-lint DUO006 只管交互控件）。
- 顶栏（菜单｜关注·推荐·直播｜搜索·我的）放进安全区：`padding(.top, 10)` 改为基于 safe area 的上边距，不再压在状态栏/灵动岛上。
- 长按 2 倍速、横滑快进等全屏手势不变；直播页同样显示状态栏。

### 2.2 三种姿态（P2，Apple 规则：按 size class 设计，不按姿态写死）

| 姿态 | size class | 布局 |
|---|---|---|
| **折叠（外屏）** | 竖屏 compact/regular，横屏 compact/compact | 视频全屏沉浸；右侧液态按钮栏 **避开外屏摄像头遮挡区**（`reservedRegions(kind: .occlusion)`），整组小幅下移，不大挪；评论用系统 sheet（系统自动避让） |
| **半折叠**（折痕激活，`reservedRegions(kind: .division)` 有 active 区） | regular/regular | 用 `ArrangementView` + `.overlay`：**secondary = 视频流**，**primary = 当前视频的信息/评论面板**。书本姿态（竖折痕）→ 视频在 leading 半边、评论在 trailing 半边；桌面姿态（横折痕）→ 视频在上半屏、评论/操作在下半屏（Apple：可看内容放上、触控放下）。任何按钮都不许落在折痕上 |
| **展开（内屏）** | regular/regular | 平放时 overlay 退化为「视频 + 浮层」；点评论 → 评论栏从 trailing 侧展开（现在的行为保留），竖持内屏可用 `.split` 左视频右评论 |

- 用 `@Environment(\.overlayArrangementZIndex)` 判断 primary 是浮在视频上（>0，显示精简侧栏）还是并排（=0，显示完整评论面板）——Apple Tech Talk 111463 的标准写法。
- ArrangementView 不能嵌在 ScrollView/List 里（DUO013）：它包在**整个推荐流外面**，推荐流的竖向分页 ScrollView 作为 secondary。
- 尺寸判断一律基于容器 bounds / size class，不用 `UIScreen.main`、不用方向（修 `:650`）。
- iOS < 27.1 回退到现有 `wide >= 700` 逻辑。

### 2.3 右侧栏精简 + 液态按钮（P3/P4）
- 侧栏只留：**作者头像（+关注）/ 点赞 / 评论 / 收藏 / 更多**。
- 「更多」= `Menu`：**弹幕**（发弹幕）、**不感兴趣**（仅推荐流）、**转发**（ShareLink）、**下载**（保存到相册，带进度）。
- 液态按钮：参考無為 `ThemeGlassEffect` / `duoRailLabel`（`WuWei/GlassStyle.swift`、`ImageGenView+DuoSidePanel.swift`）：每颗按钮 `glassEffect(.regular.interactive(), in: .circle)`，整组包在 `GlassEffectContainer` 里；iOS < 26 回退 `.ultraThinMaterial` 圆底。点赞/收藏选中态用 `.regular.tint(色.opacity(0.22))`。计数文字放按钮下方。
- 顶栏三个图标（菜单/搜索/我的）同样换液态圆按钮（保持 40pt 点击区）。

### 2.4 新增网页接口（P5/P6）——今天在已登录模拟器签名页里逐个实测

| 功能 | 接口 | 实测 |
|---|---|---|
| 未读数（各分组） | `GET /aweme/v1/web/notice/count/?is_new_notice=1&need_social_count=1` → `notice_count[{group,count}]` | 200/0 |
| 消息列表 | `GET /aweme/v1/web/notice/?is_new_notice=1&is_mark_read=0&count=10&notice_group=<g>&min_time=0&max_time=<翻页用上页max_time>` → `notice_list_v2[]`、`has_more`、`max_time` | 200/0 |
| 分组 | 700=全部，2=评论/@，3=赞，401=新粉丝，961=系统/推荐通知 | 均有数据 |
| 通知类型 | type 31=评论（`comment.comment.{text,user,aweme_id}`），41=赞（`digg.aweme` + 点赞人），33=关注（`follow.from_user`），9009=推荐了你的视频（`interactive_notice.content`），其余类型显示通用标题 | 样本见 `docs/notice-samples.json`（已去头像链接外的大字段） |
| 我的作品 / 他人作品 | `GET /aweme/v1/web/aweme/post/?sec_user_id=..&max_cursor=0&locate_query=false&show_live_replay_strategy=1&need_time_list=1&time_list_query=0&whale_cut_token=&cut_version=1&count=18` → `aweme_list`、`has_more`、`max_cursor` | 自己 14 条；他人 20 条，第二页 15 条 0 重复 |
| 关注列表 | `GET /aweme/v1/web/user/following/list/?user_id=&sec_user_id=&offset=0&min_time=0&max_time=0&count=20&source_type=2&gps_access=0&address_book_access=0&is_top=1` → `followings[]` | 200/0 |
| 粉丝列表 | `GET /aweme/v1/web/user/follower/list/?`（同上去掉 is_top）→ `followers[]` | 200/0 |
| 收藏的合集 | `GET /aweme/v1/web/mix/listcollection/?cursor=0&count=12` → `mix_infos[]` | 200/0（本期可选） |
| 评论点赞 | `POST /aweme/v1/web/comment/digg`，参数 `cid, aweme_id, digg_type(1赞/0取消), channel_id=0, app_name=aweme, item_type=0` | 网页 JS 原样抓取，**未用老板账号真发** |
| 关注作者 | `POST /aweme/v1/web/commit/follow/user/`，body `user_id=<uid>&type=1|0`，回包 `follow_status` | 同上，未真发 |
| 私信 | 走 `imapi.douyin.com` protobuf + websocket | **不做原生**，消息页放「私信（网页版）」入口 |
| 访客 | `/view/user/visited/list/` 返回 code 5 | 不做 |

接口都在签名页里发（`requestJS` 的 `req()`+`base`），安全 SDK 自动补签名；登录判定看 `status_code`（8 = 未登录），不读 cookie。

## 3. 分工与文件归属（避免互相覆盖）

| 人 | 分支 / worktree | 负责 | 只许改的文件区域 |
|---|---|---|---|
| 红暴 | `redbao` / `~/Projects/douduo-redbao` | 2.1 状态栏、2.3 侧栏+更多菜单+液态按钮（含顶栏图标）、「我的」页加「作品」页签 + 关注/粉丝列表 | `project.yml`（仅删 UIStatusBarHidden）、`Theme.swift`、`DouyinFeedView.swift` 中 `DYVideoPage.actions/action/save`、`topIcon`、`menuButton` label、两处 statusBarHidden；`DouyinExtras.swift` 中 `DYListKind`、`myList`、`DYMineScreen`；新文件 `DouyinRelations.swift` |
| 白虎 | `baihu` / `~/Projects/douduo-baihu` | 2.2 三姿态、消息中心、作者页原生作品+关注按钮、评论点赞 | `DouyinFeedView.swift` 根 `body` 布局（GeometryReader/wide/HStack/sheet）、`DYCommentPanel`、`:650` 方向判断；`DouyinExtras.swift` 中 `DYAuthorScreen`；新文件 `DouyinDuoLayout.swift`、`DouyinMessages.swift`、`DouyinBridge+More.swift`；顶栏右侧加一个「消息」入口（只加一行调用） |
| 鲨鱼 | `shayu` / `~/Projects/douduo-shayu` | 合并 redbao+baihu 到 shayu 分支 → 编译 → duo-lint → UI 测试 → 模拟器内外屏截图 → 接口数据核对 → 出验收报告 | 只读，不改业务代码（只许改 UI 测试） |
| 豹子 | `main` | 方案、冲突解决、最终合并、版本号（1.3.0 / build 23）、CHANGELOG、真机装包 | — |

规则：只本地 commit，**不 push**（DouDuo 是公开仓，半成品分支不上 GitHub）；不改版本号；不 `git add -A`；commit message 中文 `feat/fix(模块): …`；**禁止用老板账号发评论/弹幕/点赞评论/关注做测试**（写接口只接线，日志打 `DDSEND`）；编译验证用 `-derivedDataPath build/dd` 别和别人抢 DerivedData。

## 4. 验收标准
1. 推荐/关注/直播/列表播放页均显示系统时间、信号、电量；顶栏不压状态栏。
2. 侧栏仅 5 个液态按钮；「更多」里 4 项都能用（转发弹分享面板、下载存相册）。
3. 外屏：侧栏不被外屏摄像头遮挡；内屏平放、半折（书本/桌面）三种状态布局符合 2.2，按钮不落在折痕上。
4. 消息页显示各分组未读数、列表可翻页、点通知能跳到对应视频；我的作品/他人作品原生网格可播放可翻页；关注/粉丝列表可看。
5. `BUILD SUCCEEDED`；duo-lint 不新增 warning；原有 UI 测试全过（跳过的单列）。
