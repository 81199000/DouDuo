# 四种界面模式的维护规矩

DouDuo 有四种界面：**默认 / 简洁 / 极简 / 经典**（`DDChromeMode`：`classic` / `rail` / `minimal` / `duoClassic`）。

**原则：交互统一，同一份代码。** 只有「菜单放在哪」或「手势冲突」的地方允许分开写。新功能默认四种模式都要有；改一个 bug，四种模式一起好。

## 代码结构

| 层 | 文件 | 说明 |
| --- | --- | --- |
| 推荐流数据（共用） | `DouDuo/DYRecommendFeedHost.swift` | 刷新推荐、自动连播、不感兴趣、话题屏蔽、存档会话、上报观看、点赞收藏、预加载、未读数、打开搜索。**只写这一份。** |
| 弹幕（共用） | `DouDuo/DYDanmakuInput.swift` | 拉弹幕、发弹幕、输入条。 |
| 推荐页评论（共用） | `DouDuo/DYCommentStage.swift` | 评论怎么摆：外屏横屏视频上移、内屏右侧滑出、半折常驻、贴边底部面板、右划关闭。**评论位置只改这里**。 |
| 推荐流横竖选片（共用） | `DYVideoFit.feedPlaysLandscape` + `DYFeedOrientation` | 「横屏时只放横屏内容」按什么算横屏。 |
| 推荐页外壳 | `DYUpstreamFeedScreen`（默认/简洁/极简）、`DYClassicFeedScreen`（经典） | 只负责摆放：菜单、顶栏、评论面板位置。都遵守 `DYRecommendFeedHost`。 |
| 视频页外壳 | `DYUpstreamVideoPage`、`DYClassicVideoPage` | 只负责按钮放在哪个容器里。 |

### 不要做

- 不要在两个推荐页 / 两个视频页里各写一份同名函数。需要新的数据操作 → 加到 `DYRecommendFeedHost` 的扩展里。
- 不要用 `if chromeMode == .duoClassic` 让同一个功能在不同模式下行为不同，除非它在下面「必须分开」的清单里。要加新的例外，先在这份文档里写清楚理由。

## 必须分开的地方（清单）

只有下面这些允许按模式写不同代码，其它一律统一。

1. **菜单入口**
   - 经典：系统 `TabView`（我的 / 消息 / 首页）+ 系统竖栏。
   - 默认：顶栏 + 右侧按钮栏；简洁：系统侧栏 + 模块圆钮；极简：只留一个圆形入口（进度画在外圈）。
   - 理由：这是四种模式的本质区别。

2. **互动按钮的外层容器**
   - 按钮本身（头像、点赞、评论、收藏、分享）是同一组动作；经典装在液态玻璃胶囊 / 系统栏里，其它模式装在自绘右侧栏里。
   - 理由：容器跟着菜单位置走。

3. **左右滑**
   - 经典：左右滑切换「关注 / 推荐 / 直播」（跟手动画）。
   - 默认 / 简洁 / 极简：左右滑是**快进快退**。
   - 理由：简洁和极简没有底部进度条，左右滑是唯一的快进方式；合并会让它们没法快进。

4. **清屏按钮的位置**
   - 经典挂在系统竖栏上；其它模式靠长按面板。功能相同，只是入口位置不同（属于第 1 条）。

5. **简介（视频描述）**
   - 经典：默认 3 行，点正文 / 「…展开」打开简介面板（作者、关注、全文、发布时间，下面接评论）——`DYClassicExpandableTitle`。
   - 默认 / 简洁 / 极简：默认 1 行，点「展开」原地展开、「收起」收回——`DYExpandableTitle`。
   - 理由：老板 2026-11-17 试用后决定各管各的（统一成面板的版本已回滚，见 bf20b3f 的 revert）。不要再把两边合并。

## 已统一 / 计划统一给所有模式

- [x] 推荐流数据操作（14 个函数）合成一份
- [x] 弹幕拉取 / 发送 / 输入条合成一份
- [x] 点已选中的「推荐」刷新推荐（简洁 / 极简的模块菜单里显示为「刷新推荐」）
- [x] 推荐页评论（老板 2026-11-17 定「直接套经典的评论区」）：四种模式同一份 `DYCommentStage` + 经典评论面板样式
  - Duo 外屏：横屏视频移到顶部，评论在下，贴满宽（原来简洁右边空约 84pt 的问题随之消失）
  - 内屏横拿：评论从右侧滑出、视频缩窄；横屏右划关闭
  - 半折：评论常驻
  - 评论打开 / 半折常驻时：顶栏、右侧按钮栏、模块圆钮、视频上的按钮全部收起，评论在最顶层
  - 外屏叠放评论时状态栏让位（原「必须分开」第 4 条，已统一）
  - 坑：侧栏评论时视频区必须裁边（`DDClipIf`），否则播放器的环境光底（忽略安全区、铺满整屏）会盖住右侧评论栏 → 简洁内屏评论空白
  - 回归：`testOuterLandscapeVideoLiftsAboveCommentsInEveryMode`、`testInnerSideCommentsSwipeRightToCloseInEveryMode`、`testPhysicalHalfFoldCommentsHideSidebar`（四种模式）、`testCommentPresentationIsUnifiedAcrossLayouts`
- [x] 推荐流横竖选片（老板 2026-11-17）：**半折叠时横竖反过来**——竖拿半折（视频在上半块）按横屏规则；横拿半折（视频在左半块）按竖屏规则；没半折看窗口宽高。单元测试 `halfFoldFlipsFeedOrientation`
- [ ] 「我的 / 作者页 / 搜索」点进去的列表播放页（`DYCommentPlayerLayout`）评论还分 `classicBody` / `upstreamBody` 两份，待接 `DYCommentStage`

## 模拟器测 Duo 各姿态

Xcode 27 模拟器窗口（DeviceHub）底栏右侧四个按钮：旋转 / 外屏 / 半折叠 / 展开。脚本里切换见 skill `douduo-app-development`「模拟器切 Duo 姿态」。外屏截图 `--display=1`，内屏 `--display=3`。内屏 / 半折的问题先在模拟器复现，别拿真机当测试机。

## 改动前自检

```bash
# 两个推荐页里不该再出现共用函数的副本（DouyinBridge / DYFeedModel 里的底层同名函数不算）
grep -nE "private func (advance|applyHashtagFilter|dislike|focusCurrent|openSearch|playNext|refreshNoticeUnread|refreshRecommendations|remixUpcoming|reportWatch|saveSession|showToast|toggleCollect|toggleLike)\(" DouDuo/DouyinFeedView.swift
# 应该没有输出（这些只在 DYRecommendFeedHost.swift 里）
```

UI 回归至少四种模式各跑一遍：`testHashtagClassicFlow`、`testHashtagDefaultFlow`、`testSearchClassicLayout`、`testSearchDefaultLayout`、`testAutoNextAfterSeek`、`testPagingSpeedClassicLayout`、`testChromeModeClassicHasTopTabsAndSearchOnRail`、`testChromeModeRailMovesSearchIntoModuleMenu`。
