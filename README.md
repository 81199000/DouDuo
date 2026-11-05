# 抖Duo

一个**适配 iPhone Duo（折叠屏）/ iPad 的第三方抖音客户端**。官方抖音 App 在 Duo 内屏上不适配，网页版又会一直跳 App，所以有了它。

- 推荐流整页上下滑，系统播放器原生播放，**提前缓存后面 3 条**，滑到即播
- 屏幕上**横滑快进 / 快退**（带预览缩略图），双击点赞，长按 2 倍速，单击暂停，底部进度条可拖
- 评论：外屏从底部弹出；内屏 / 横屏从右侧滑出评论栏
- **直播**：顶部「直播 / 推荐」切换，原生播放直播流
- 默认「只看竖屏」（网页端推荐给未登录用户大多是横屏长视频），菜单里可关
- 「网页版」入口：登录、搜索、作者主页；在网页版登录后，原生推荐也带上你的账号

## 安装

### 方式一：下载 IPA 自签安装（不用电脑编译）
到 [Releases](../../releases) 下载 `DouDuo-x.y.z-unsigned.ipa`，用任一侧载工具安装（工具会用你自己的 Apple ID 重新签名）：
- [AltStore](https://altstore.io) / [SideStore](https://sidestore.io)（免费 Apple ID 每 7 天需刷新一次）
- [Sideloadly](https://sideloadly.io)（Mac / Windows）
- TrollStore（仅支持的系统版本）

### 方式二：自己编译
需要 Xcode 26+、[XcodeGen](https://github.com/yonaskolb/XcodeGen)：
```bash
brew install xcodegen
xcodegen generate
open DouDuo.xcodeproj   # Signing & Capabilities 里选你自己的 Team，必要时把 Bundle ID 改成你自己的
```

系统要求：iOS 17+。

## 原理
没有逆向抖音 App，也不需要任何密钥：
- App 里挂一个**看不见的抖音网页**（电脑版 UA），所有接口请求都在这个页面里发出，由抖音网页自己的安全 SDK 自动补签名（`a_bogus` 等），所以签名算法跟着官方更新走。
- 推荐流：`/aweme/v2/web/module/feed/`；评论：`/aweme/v1/web/comment/list/`；直播：`live.douyin.com/webcast/feed/`。
- 视频用接口返回的 `/aweme/v1/play/` 地址（302 到 CDN mp4），`AVPlayer` 直接播放。
- 登录态和「网页版」共用 `WKWebsiteDataStore.default()`。

## 已知限制
- 点赞 / 收藏目前只在本机显示，不会同步到你的抖音账号
- 直播的弹幕、礼物要点「进直播间」用网页版看
- 抖音风控时会提示去「网页版」过一下验证
- 抖音网页接口改版时可能需要跟着更新

## 声明
本项目是个人学习用的非官方客户端，与北京微播视界科技有限公司 / 抖音没有任何关系。所有内容版权归原作者与抖音所有。请遵守抖音用户协议，仅供个人使用，**禁止用于任何商业用途或批量抓取**。如有侵权请提 Issue，会第一时间处理。

## License
MIT
