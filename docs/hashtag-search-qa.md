# 标签与 Duo 搜索页

基线：上游正式发行标签 `v1.3.15`（`7900d854dc68172500e18d9f0bb72f13a051933b`）。
分支：`codex/hashtag`。交付版本：1.3.15，构建号 100。

本功能的简介与说明仅更新本分支的 README、文档及对应 PR，不修改仓库级 About、默认分支或其他分支。

## 行为

- 视频简介的 `#` / `＃` 标签加粗，点击以 `#标签` 搜索。优先采用平台标签元数据，旧缓存回退到简介解析。
- 更多 → 按标签过滤视频：输入完整标签或点选当前视频标签，可添加、移除屏蔽项；保存在本机并立即应用于推荐流、候选池及恢复的推荐会话。完整标签匹配，忽略英文大小写和全半角；普通正文中的同名词不屏蔽。搜索、关注、作者作品不经过推荐过滤。
- 输入框与独立的添加按钮同排。当前视频标签使用无外层底色的单行横向滚动；已屏蔽标签按内容宽度流式排列，空间不足自动换行。标签块采用固定圆角，长标签在可用宽度内折行，点按带 × 的标签可取消屏蔽。
- 热搜使用紧凑的渐变背景行，前三名依次为金、银、铜徽章，置顶行使用蓝色；热度以万/亿显示。保持平台返回的排名，不虚构热度和状态标记。
- 搜索框保留顶部和侧边留白；返回键是独立的原生工具栏项目，由 Duo 系统侧栏承载。
- Duo 内屏处于大横屏时，展开和半折均使用左右各 50% 的搜索布局。系统侧栏包含在右半屏内，不改变正中分界线。打开搜索先收起评论，并暂时隐藏半折常驻评论；退出搜索后恢复半折常驻评论。视频容器身份保持不变；转成竖屏或外屏时使用全屏搜索，保留关键词及搜索结果。
- 打开搜索结果播放器时，暂停被覆盖的推荐视频，直到结果播放器关闭完成；返回时恢复原有播放或手动暂停状态。评论切换到搜索在同一无动画事务内完成，避免中途恢复全屏再缩小。

## 回归方法

仅使用 iPhone Duo 模拟器的外屏和内屏。Device Hub 的 Sound → Output 设为 None；查看和截图前暂停视频。布局用例不含音视频流；播放切换用例使用本地生成的视频，由实际 AVPlayer 播放；真实数据用例使用已登录的抖音会话。

核心逻辑直接执行生产 Swift 解析器、过滤器和推荐模型：

```sh
python3 scripts/test_hashtags.py
python3 scripts/test_menu_policy.py
python3 scripts/test_video_metadata.py
python3 scripts/test_playback_resume.py
```

UI 用例：`testHashtagClassicFlow`、`testHashtagDefaultFlow`、`testHashtagChipLayout`、`testSearchClassicLayout`、`testSearchDefaultLayout`、`testSearchHalfFoldClassicLayout`、`testSearchHalfFoldDefaultLayout`。标签用例覆盖点击搜索、展开后的标签、屏蔽立即生效、重启持久化及取消屏蔽；标签块用例覆盖输入和按钮同排、当前标签横向滚动、已屏蔽标签同排显示、长标签折行和逐项移除；搜索用例覆盖评论切换到搜索、半折常驻评论、热搜点击、返回键、中线坐标、关键词保留及全屏/分屏切换。

播放用例：`testSearchPlaybackClassic`、`testSearchPlaybackDefault`。通过仅 DEBUG 可启用的探针读取实际播放器速率和实例，断言评论切换搜索时保留左侧播放器、打开结果时仅结果播放、返回后恢复原有播放状态、手动暂停不被取消，以及搜索往返后仍可翻页。录制器同时保存评论切换搜索的内屏录像；这些本地视频测试不作为真实搜索接口的证明。

播放用例需要先安装 Debug 应用，再将本地测试片复制到模拟器的应用 Documents（不提交到仓库）：

```sh
ffmpeg -f lavfi -i 'color=c=0x287588:s=640x360:r=30:d=60' \
  -f lavfi -i 'sine=frequency=440:duration=60' \
  -vf 'drawbox=x=40:y=80:w=120:h=120:color=yellow:t=fill' \
  -c:v libx264 -preset ultrafast -pix_fmt yuv420p -c:a aac -shortest \
  build/search-playback-fixture.mp4
DUO_APP_DATA=$(xcrun simctl get_app_container <DUO_UDID> me.rrmm.douduo data)
cp build/search-playback-fixture.mp4 "$DUO_APP_DATA/Documents/"
```

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
  test CODE_SIGNING_ALLOWED=NO \
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

## 构建 99 的验证记录

- 生产逻辑：标签与搜索错误处理 3 项、原有菜单策略 7 项、视频元数据 2 项全部通过。
- `build/HashtagLayoutInnerOffline.xcresult`：3 项全部通过，覆盖最新屏蔽页、展开时评论切换搜索、半折时搜索、横竖屏切换、关键词保留、正中分界线和侧栏返回。
- `build/HashtagLayoutOuterOffline.xcresult`：3 项全部通过，覆盖最新屏蔽页、标签点击搜索、展开标签、屏蔽/取消屏蔽、重启持久化及外屏全屏搜索。
- 两种界面模式在展开与半折时的 4 项搜索布局用例，均已在 `build/HashtagSearchInnerFinal.xcresult` 单项通过；该批次的真实搜索超时另按上文记录，不将整批标记为通过。
- Release 真机构建成功；确认 1.3.15（99）、`iphoneos`、不含标签/搜索素材测试入口。打包验证 arm64 和 ZIP 完整性，并移除签名。
- 回归结束已关闭本次 Duo 模拟器与 Device Hub。

交付：`DouDuo-1.3.15-build99-unsigned.ipa`，SHA-256：`df38843325a05986793c97f0c903c51f1784b8ec15db55d58e39536efc497399`。

## 构建 100：搜索播放与闪烁修复（2026-11-14）

- `build/HashtagPlaybackInner100.xcresult`：2 项全部通过。经典与默认布局都验证了评论切换搜索时保留原播放器、结果视频独占播放、返回恢复播放或保留手动暂停，以及继续翻页后仅当前视频播放。
- `build/HashtagSearchInner100.xcresult`：4 项全部通过。覆盖经典与默认布局、展开与半折、评论切换搜索、整屏正中分界线、侧栏返回、热搜点击和横竖屏切换时保留关键词。
- `build/HashtagSearchOuter100.xcresult`：4 项全部通过。两种布局均保持外屏全屏搜索；结果播放器独占播放，返回正确恢复播放或保留手动暂停，继续翻页正常。
- 内屏录像位于 `build/hashtag-playback-inner100-screens/`。两种布局分别检查 245、307 帧，左侧视频中央采样区未出现黑帧；播放器实例在评论切换搜索时没有销毁或重建。截图核对了左右各半的最终画面。
- 最终播放器状态修改后重新执行标签与搜索错误处理 3 项、后台恢复策略检查，全部通过；菜单策略与元数据用例仍沿用本轮已通过的结果。
- Release 真机构建成功，版本 1.3.15（100），平台 `iphoneos`。已核对发行二进制不含标签、搜索、播放素材开关或播放探针；打包验证 arm64、ZIP 完整性并移除签名。
- 回归结束已关闭本次 Duo 模拟器与 Device Hub。

交付：`DouDuo-1.3.15-build100-unsigned.ipa`，SHA-256：`519de34b05fcd9b36b9a642998cbda8e0ea5e8b5273db04c3039b4ab269ebf4d`。IPA 与 `.ipa.sha256` 已复制到约定的 iCloud `ipa/未签名/DouDuo` 目录，构建 99 等历史文件保留。


## 截图交付约定

本分支功能说明与 PR 截图先压缩，再通过 GitHub 描述附件上传。原图和压缩副本均不加入 Git 仓库；本地副本保存在被忽略的 `build/pr-assets/`。本次使用用户提供的三张功能截图，以及一张键盘问题截图。截图中的固定素材只展示布局，不作为真实接口测试证据。

发布前已检查分支相对 v1.3.15 的新增内容和 PR 描述，未发现令牌、Cookie、密码或个人绝对路径；运行日志、登录会话、测试视频及安装包均不入库。提交身份使用 GitHub 隐私邮箱，不发布本机自动生成的主机名邮箱。四张附件未携带 GPS、作者或设备序列号元数据；沿用用户原图已有遮挡，可见的搜索历史词和头像仍保留。

## 已知问题：非经典布局的键盘避让（待上游修复）

用户反馈：iPhone Duo 内屏大横屏、非经典布局下，打开软件键盘会把视频互动栏向上抬，部分互动按钮可能超出屏幕上缘。搜索页输入框和评论区输入框均适用。

复现：切换为非经典布局 → 展开 Duo 内屏并横放 → 打开搜索或评论 → 点击对应输入框唤起软件键盘。预期输入区域避让键盘，同时视频互动栏保留在可见、可点击范围内。用户提供的搜索场景截图随 PR 附件说明；评论场景由用户报告，本项不计入已修复列表。
