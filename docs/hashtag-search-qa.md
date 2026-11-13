# 标签与 Duo 搜索页

基线：上游正式发行标签 `v1.3.15`（`7900d854dc68172500e18d9f0bb72f13a051933b`）。
分支：`codex/hashtag`。交付版本：1.3.15，构建号 99。

## 行为

- 视频简介的 `#` / `＃` 标签加粗，点击以 `#标签` 搜索。优先采用平台标签元数据，旧缓存回退到简介解析。
- 更多 → 按标签过滤视频：输入完整标签或点选当前视频标签，可添加、移除屏蔽项；保存在本机并立即应用于推荐流、候选池及恢复的推荐会话。完整标签匹配，忽略英文大小写和全半角；普通正文中的同名词不屏蔽。搜索、关注、作者作品不经过推荐过滤。
- 输入框与独立的添加按钮同排。当前视频标签使用无外层底色的单行横向滚动；已屏蔽标签按内容宽度流式排列，空间不足自动换行。标签块采用固定圆角，长标签在可用宽度内折行，点按带 × 的标签可取消屏蔽。
- 热搜使用紧凑的渐变背景行，前三名依次为金、银、铜徽章，置顶行使用蓝色；热度以万/亿显示。保持平台返回的排名，不虚构热度和状态标记。
- 搜索框保留顶部和侧边留白；返回键是独立的原生工具栏项目，由 Duo 系统侧栏承载。
- Duo 内屏处于大横屏时，展开和半折均使用左右各 50% 的搜索布局。系统侧栏包含在右半屏内，不改变正中分界线。打开搜索先收起评论，并暂时隐藏半折常驻评论；退出搜索后恢复半折常驻评论。视频容器身份保持不变；转成竖屏或外屏时使用全屏搜索，保留关键词及搜索结果。

## 回归方法

仅使用 iPhone Duo 模拟器的外屏和内屏。Device Hub 的 Sound → Output 设为 None；查看和截图前暂停视频。固定素材用例不含音视频流，真实数据用例使用已登录的抖音会话。

核心逻辑直接执行生产 Swift 解析器、过滤器和推荐模型：

```sh
python3 scripts/test_hashtags.py
python3 scripts/test_menu_policy.py
python3 scripts/test_video_metadata.py
```

UI 用例：`testHashtagClassicFlow`、`testHashtagDefaultFlow`、`testHashtagChipLayout`、`testSearchClassicLayout`、`testSearchDefaultLayout`、`testSearchHalfFoldClassicLayout`、`testSearchHalfFoldDefaultLayout`。标签用例覆盖点击搜索、展开后的标签、屏蔽立即生效、重启持久化及取消屏蔽；标签块用例覆盖输入和按钮同排、当前标签横向滚动、已屏蔽标签同排显示、长标签折行和逐项移除；搜索用例覆盖评论切换到搜索、半折常驻评论、热搜点击、返回键、中线坐标、关键词保留及全屏/分屏切换。

真实数据用例：`testLiveHashtagClassicFlow`、`testLiveHashtagDefaultFlow`。从实际推荐中选择可点击的标签，不注入视频 ID 或搜索结果；验证真实搜索接口返回平台视频 ID，再添加屏蔽、刷新推荐、重启应用和取消屏蔽。内屏同时断言打开搜索不会改变左侧视频的暂停状态。录制器独立读取实际保存的推荐记录及标签偏好，核对各阶段没有被屏蔽的视频。用例结束移除临时屏蔽项，个人推荐记录与截图只留在被 Git 忽略的 `build/` 中。

真实接口测试需要登录。已覆盖平台实际返回的 HTTP 200 / 业务码 2483 登录错误；界面明确提示登录，不再把接口错误显示成空搜索结果。XHR 的 `-2` / `-3` 超时单独提示重试，不伪装为 HTTP 状态码或登录错误。

固定素材模式同时禁止加载抖音签名网页及调用接口，避免评论/相关搜索的布局用例消耗真实会话的请求额度。真实用例未启用该模式；只在明确需要时单独运行，超时最多普通重试一次，不循环请求。

使用显式 Duo UDID 运行，避免 Xcode 活动目的地漂移到其他设备：

```sh
TEST_RUNNER_DOUDUO_TEST_DISPLAY=inner xcodebuild \
  -project DouDuo.xcodeproj -scheme DouDuo -configuration Debug \
  -destination 'platform=iOS Simulator,id=<DUO_UDID>' \
  -derivedDataPath build/HashtagDerivedData -parallel-testing-enabled NO \
  -only-testing:DouDuoUITests/DouDuoUITests/testSearchClassicLayout \
  -only-testing:DouDuoUITests/DouDuoUITests/testSearchDefaultLayout \
  test CODE_SIGNING_ALLOWED=NO TEST_RUNNER_DOUDUO_TEST_DISPLAY=inner \
  > build/duo-search.log 2>&1
```

同时在另一终端启动录制器；辅助功能需允许操作 Device Hub。它根据用例标记旋转实际内屏、切换展开/半折姿态、显示软件键盘并截图。外屏运行前在 Device Hub 选择 Closed，两处 `inner` 改为 `outer`。半折用例仅在内屏执行。

```sh
python3 scripts/capture_duo_regression.py build/duo-search.log build/duo-search-screens \
  --udid <DUO_UDID> --display inner
```

Duo 的 `XCUIApplication.frame` 和 XCTest 截图可能仍指向外屏。几何断言使用实际窗口尺寸，画面证据使用 `simctl io --display=3`（内屏）或 `--display=1`（外屏）。测试素材只在 DEBUG 环境变量启用时出现，不保存到正常推荐会话；发行包不含测试入口。

打包使用 `scripts/package_unsigned.py`，它验证真机平台、arm64 架构和 ZIP 完整性，移除签名并生成 SHA-256，拒绝覆盖已有交付。

## 真实数据验证记录（2026-11-14）

均在已登录的 iPhone Duo 模拟器上执行，使用真实推荐和搜索接口。以下记录是已完成的成功用例，不代表平台对所有关键词均可用。

| 屏幕 / 模式 | 搜索结果 | 屏蔽前匹配 / 总数 | 屏蔽后 | 刷新后 | 重启后 |
| --- | --- | --- | --- | --- | --- |
| 内屏 / Duo 经典 | 返回真实视频 ID | 1 / 15 | 0 / 14 | 0 / 6 | 0 / 9 |
| 外屏 / 默认 | 返回真实视频 ID | 1 / 21 | 0 / 20 | 0 / 6 | 0 / 13 |

内屏证据：`build/LiveHashtagInner3.xcresult` 和 `build/live-hashtag-inner3-audit.log`。外屏证据：`build/HashtagChipsOuter.xcresult` 和 `build/hashtag-chips-outer-audit.log`。两次均已移除临时屏蔽标签，内屏还验证了分屏打开后视频保持暂停。

后续复验遇到网页请求硬超时（`-3`），普通重试仍未取得结果，因此停止追加真实请求。频率拦截是可能原因，平台未返回可确认原因的响应；失败及中止记录保留在 `build/HashtagSearchInnerFinal.xcresult`、`build/HashtagSearchInnerReady.xcresult`。后续布局检查使用禁用网络的固定素材，不将其作为真实数据通过证明。

## 最终本地检查

- 生产逻辑：标签与搜索错误处理 3 项、原有菜单策略 7 项、视频元数据 2 项全部通过。
- `build/HashtagLayoutInnerOffline.xcresult`：3 项全部通过，覆盖最新屏蔽页、展开时评论切换搜索、半折时搜索、横竖屏切换、关键词保留、正中分界线和侧栏返回。
- `build/HashtagLayoutOuterOffline.xcresult`：3 项全部通过，覆盖最新屏蔽页、标签点击搜索、展开标签、屏蔽/取消屏蔽、重启持久化及外屏全屏搜索。
- 两种界面模式在展开与半折时的 4 项搜索布局用例，均已在 `build/HashtagSearchInnerFinal.xcresult` 单项通过；该批次的真实搜索超时另按上文记录，不将整批标记为通过。
- Release 真机构建成功；确认 1.3.15（99）、`iphoneos`、不含标签/搜索素材测试入口。打包验证 arm64 和 ZIP 完整性，并移除签名。
- 回归结束已关闭本次 Duo 模拟器与 Device Hub。

交付：`DouDuo-1.3.15-build99-unsigned.ipa`，SHA-256：`df38843325a05986793c97f0c903c51f1784b8ec15db55d58e39536efc497399`。
