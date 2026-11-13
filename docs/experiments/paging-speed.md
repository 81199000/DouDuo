# 可调上下翻页速度

基线：`2515c86dcf366325a351dae488deb6d3944f4aa4`，DouDuo 1.3.14。关联 [issue #22](https://github.com/81199000/DouDuo/issues/22)。

## 改了什么

- 更多 → **翻页设置 → 上下翻页**：标准（系统）、快速、更快。
- `@AppStorage` 键 `douyin_paging_speed_v1`，值 `standard` / `fast` / `faster`；缺失或非法值回到标准。
- 标准档不安装代理，仍走原 SwiftUI `.scrollTargetBehavior(.paging)`；开启系统“减少动态效果”也使用系统路径。
- 快速档收尾动画 180ms，更快档 100ms。改变的是手指松开后的归位动画，不是视频播放倍率、网络加载速度或翻页距离阈值。
- 作用于推荐、关注、沉浸短视频列表；**直播保持原行为**。

## 为什么不是改一行减速率

原生实验中 `.paging` 已使用 `isPagingEnabled=true`、`decelerationRate=0.99`（`.fast`）；强制设置 0.95 会被 SwiftUI 重置，停稳时间不变。推荐页 800ms 是允许 `scrollPosition` 更新的状态窗口，不是动画时长，保留不动。

快速档局部桥接内容栈的祖先 `UIScrollView`：先转发给原 SwiftUI delegate 求系统分页目标，再抑制系统惯性，用 `CADisplayLink` 完成剩余位移。未覆盖的可选 delegate 消息仍转发，不伪造完成事件，不全局修改 `UIScrollView`。停稳时以稳定视频 ID 同步 `currentID`，避免短拖后画面与绑定页不一致。

新拖动终止上一动画；取消、数据变化、尺寸变化会取消旧目标；关闭档位恢复原 delegate 并保留当前绑定视频。实现集中在 `DouDuo/DYPagingSpeed.swift`。

## 验证记录（2026-11-13～14）

### 已验

- 实际 App 模拟器编译成功。
- 无视频、网络依赖的 iOS 27.2 / iPhone 18 Pro 分页 fixture：同样 900pt/s 拖动，松手至位移连续 4 帧稳定，标准约 0.432s、快速 0.249–0.266s、更快 0.181–0.183s。测量包含 4 帧确认余量，不是严格动画时长，也不代表真实视频加载速度。
- fixture 测试：首尾、短慢拖回弹、上下反向、连续多页、当前 ID、标准/更快切换保持页、横竖屏往返。
- `python3 scripts/test_paging_speed.py`：两项通过，覆盖默认/非法值回退、参数/偏好保存、三处接线与直播排除。
- 实际 App `testPagingSpeedSettingAndVerticalNavigation`：更多 → 翻页设置 → 快速 → 更快 → 上滑后 `currentID` 更新 → 恢复标准且当前页保持。临时诊断版及移除日志版均 `TEST SUCCEEDED`。
- 诊断版确认目标 1748pt/index2 → 动画结束 1748pt → `didSettle` → `currentID`/`scrollID` 同步；标准档正常拆卸。临时诊断日志不进入产品代码。

### 未验与限制

- 真机、实际播放/横滑快进/长按与快档组合未完成验收。原有 `testCoreFlow` 在模拟器中视频时间一直为 0，播放和快进断言失败，整个测试不能算通过。
- 设置测试早期一次上滑等待 ID 变化超时；后续诊断版与无日志版通过，但该次失败的根因未确定，不能据此宣称彻底排除偶现不同步。真机应重点复测。
- 简化 fixture 直接叠加 `PlayerGestureView` 后，连移除本桥接的基线也无法纵滑，说明它不代表实际播放器宿主；不作为手势兼容性通过的证据。
- 中途取消、折叠屏真实几何、减少动态效果切换仍缺可重复 UI 验证。

## 如何复验

需要 Xcode 和已按仓库 README 下载的 VLC 依赖。只在干净模拟器中运行 UI 测试，测试会修改本地翻页偏好；失败时可能未恢复标准档。

```sh
python3 scripts/test_paging_speed.py
xcodebuild -project DouDuo.xcodeproj -scheme DouDuo \
  -destination 'platform=iOS Simulator,id=<模拟器 UUID>' -jobs 2 \
  -only-testing:DouDuoUITests/DouDuoUITests/testPagingSpeedSettingAndVerticalNavigation \
  test CODE_SIGNING_ALLOWED=NO
```

实际 App 测试需要推荐页加载成功。`scripts/fixtures/paging-speed/` 为无网络探针源文件：另建 iOS SwiftUI App，将 `PagingProbe.swift` 作为入口并加入产品 `DYPagingSpeed.swift`；UI 测试 target 加入 `PagingProbeUITests.swift`。探针未接入主工程，默认不随 App 打包。

## 维护与上游同步

- 不改 `PlayerGestureView.swift`、播放倍率、缓存、登录或个人签名配置。
- 原 delegate 为弱引用；桥接更新发现 SwiftUI 更换 delegate 时退还所有权。iOS 升级后需重测 offset 与 `currentID` 一致性、delegate 转发和标准档行为。
- 上游接受等效设置后，个人 fork 删除重复补丁；SwiftUI 若提供公开可调分页动画 API，优先迁移并删除此桥接，不同时维持两套动画。
- 提交不包含 VLC 二进制、DerivedData、签名证书、归档、IPA 或个人账号资料。
