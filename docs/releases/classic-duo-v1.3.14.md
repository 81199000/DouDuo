# iPhone Duo 经典布局：v1.3.14 适配与验证

基于原作者 `81199000/DouDuo` 的 v1.3.14（`2515c86`）。经典布局为可选项，新安装默认使用上游默认布局，保留默认、简洁、极简的偏好值和呈现方式。

## 版本与兼容范围

- App 与 UI 测试目标的最低系统版本均为 iOS 26.0，`project.yml` 与 Xcode 工程一致。
- 经典布局依赖的 iOS 27.1 工具栏和折叠 API 有可用性判断；26.x 不显示经典布局选项，使用上游布局。
- 复用上游不透明的关注标记样式及折叠几何计算，保留 v1.3.14 的直播预览避让、环境光和音频策略。
- Bundle ID 为上游的 `me.rrmm.douduo`，未指定个人签名团队。
- **仅针对 iPhone Duo 适配，未测试 iPad。** iOS 26 真机运行也尚未验证。

## 本次修正

- 经典搜索入口使用完整的 44 点点击区域，将搜索呈现挂载到稳定的根视图；覆盖直接打开、关闭评论后打开、作者页返回后打开。
- 经典评论、分享与上游三种布局分别呈现，共用数据与业务逻辑。上游布局打开内屏评论时保留互动操作。
- 经典半折评论按实际折痕和窗口边界布局，填满评论所在面板，消除四周黑边；继续隐藏经典侧栏和 Dock。
- 关注加号复用上游尺寸、红色与符号，不添加半透明背景。
- 保留经典菜单／分享续播、作者页并排续播、评论及菜单下拉关闭、评论右滑关闭和拖动后不误触倍速。
- 清理过期版本验证说明，压缩参考截图；截图共约 1.66 MB，并明确标记为旧版布局参考，而非此次测试证据。

## 验证结果（2026-11-13）

环境：iPhone Duo 模拟器，iOS 27.2，外屏、展开内屏及实际书本半折状态。测试静音，结束后停止模拟器并关闭 Device Hub。

- Debug 与 Release 设备构建通过；Release 安装包元数据为 v1.3.14 / build 98 / iOS 26.0。
- 直播相关策略测试 26 项通过；菜单、侧栏、播放恢复与关注逻辑测试 12 项通过，同时执行其 Swift 几何和比例断言。
- 以下 11 项 UI 回归用例通过；部分用例分别在内外屏重复验证，并非每项都覆盖全部形态。

| 用例 | 本次覆盖 |
| --- | --- |
| `testAllFourChromeModesRoundTrip` | 内外屏四种布局往返切换 |
| `testCommentPresentationIsIsolatedAcrossLayouts` | 内外屏评论隔离；内屏上游三档互动按钮仍可点击 |
| `testClassicSearchOpensAndReturns` | 内外屏直接搜索、评论关闭后搜索、作者页返回后搜索 |
| `testPanelsKeepPlaybackAndDismissGestures` | 内外屏菜单／分享续播、关闭手势及作者页往返 |
| `testCleanScreenRestoresStableSidebar` | 外屏清屏及恢复 |
| `testDragAndHoldDoesNotStartBoost` | 外屏拖动后持续按住不误触倍速 |
| `testPlaybackRateLockedByLongPressDownAndSetting` | 外屏长按倍速与设置 |
| `testStandaloneCommentsRespectLayout` | 外屏非首页播放器的默认／经典评论 |
| `testInnerShareUsesTrailingHalf` | 内屏分享面板右侧半宽 |
| `testPhysicalHalfFoldCommentsHideSidebar` | 书本半折评论边界、侧栏隐藏 |
| `testNativeDockRestoresAfterClosingComments` | 内屏关闭评论后 Dock 恢复 |

直播进入／退出已通过 Device Hub 手动验证：进入后隐藏应用顶栏、侧栏与 Dock，返回后恢复。对应的 `testLiveDiscoveryAndBack` 自动化仍出现直播入口定位／等待失败，**未记为通过**；它依赖在线直播数据，仍需进一步稳定化。

未覆盖：iPad、iOS 26 运行、真机画中画、音频中断／音质、桌面式半折，以及本轮重新创建实时活动后的组合场景。模拟器不支持本次所需画中画能力，不能以编译通过替代真机验证。

## 未签名打包

`scripts/package_unsigned.py` 接受现有 iPhoneOS `.app`，只在临时副本保留 arm64、移除签名与描述文件，生成 IPA 和 SHA-256；不改变 Vendor 原文件，不覆盖历史交付。

上次体积增大是由于 VLCKit 同时带入 armv7、armv7s 和 arm64。当前设备包只保留 arm64，避免打入不适用的 32 位切片。
