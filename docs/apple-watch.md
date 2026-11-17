# Apple Watch 使用说明

DouDuo 1.6.0 起自带 Apple Watch App，可以在手表上刷推荐视频。手表上**不用登录**，账号、推荐都来自 iPhone 上的 DouDuo。

## 需要什么

- watchOS 26.0 及以上的 Apple Watch，已和 iPhone 配对
- iPhone 上装好 DouDuo 1.6.0 或更新版本，并且**已在 iPhone 上登录抖音**
- 手表能联网，建议连 Wi-Fi（视频由手表自己联网播放）

## 安装到手表

手表 App 打包在 DouDuo 的安装包里，不需要单独下载。

1. 按 README 的方法签名并安装 DouDuo 1.6.0 到 iPhone。
2. 在 iPhone 上打开系统的「Watch」App，往下找到「DouDuo」，点「安装」。如果在「可用 App」里看不到，打开「通用 → 自动安装 App」也可以。
3. 等手表上出现 DouDuo 图标即可。

**签名时注意：**
- 签名工具要保留安装包里的手表 App（`Watch/DouDuoWatch.app`）。有些工具或选项会把它去掉，签完后在「Watch」App 里就找不到 DouDuo。
- 用自己的 Apple ID 或证书签名时，手表 App 的标识要跟着 iPhone 那份一起改（必须是 `iPhone 的标识.watchkitapp`），否则手表装不上。爱思助手、全能签一般会自动处理，装不上时先检查这一项。
- 免费 Apple ID 签的包 7 天过期，手表上的那份也会一起失效，重签 iPhone 后要在「Watch」App 里重新安装一次。

## 第一次使用

1. 先在 iPhone 上打开一次 DouDuo，确认已登录、推荐能正常刷。
2. 再打开手表上的 DouDuo，它会向 iPhone 要一批视频，几秒后开始播放。
3. 如果手表显示「请在 iPhone 上登录 DouDuo」，回到 iPhone 登录后，在手表上点「刷新」。

## 怎么操作

- **上下滑**：切到下一条 / 上一条
- **点一下**：暂停 / 继续
- **双击**：点赞（需要手表和 iPhone 连着）
- **数码表冠**：DouDuo 不占用，交给系统（播放时一般用来调音量）

## 它是怎么工作的

- iPhone 上的 DouDuo 从你的推荐里挑一批视频，把链接发给手表；手表自己联网播放，播到快没了再向 iPhone 要。
- iPhone 不用一直开着 DouDuo：手表会先用上次拿到的那一批继续播，跟手机连上时再补。
- 手表会提前存好后面 5 条，刷过去直接播；缓存最多约 120MB，1 小时后自动清掉，看过的立刻删。
- 在手表上看过的视频会同步给 iPhone，记为已看，之后不会再推给你。

## 常见问题

- **手表一直转圈、没有视频**：确认 iPhone 上的 DouDuo 已登录，并且最近打开过；手表和 iPhone 连上后会自动补。
- **播放失败或跳过**：视频链接大约 6 小时后会失效，手表会自动跳过；在 iPhone 上打开一次 DouDuo 就能拿到新的一批。
- **「Watch」App 里找不到 DouDuo**：多半是签名时手表 App 被去掉了，换一个保留手表 App 的签名方式重签。
