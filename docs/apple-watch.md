# Apple Watch 使用说明

DouDuo 1.6.0 起自带 Apple Watch App，可以在手表上刷推荐视频。手表上**不用登录**，账号、推荐都来自 iPhone 上的 DouDuo。

## 需要什么

- watchOS 26.0 及以上的 Apple Watch，已和 iPhone 配对
- iPhone 上装好 DouDuo 1.6.0 或更新版本，并且**已在 iPhone 上登录抖音**
- 手表能联网，建议连 Wi-Fi（视频由手表自己联网播放）

## 安装到手表

手表 App 打包在 DouDuo 的安装包里，不需要单独下载。但**手表比 iPhone 难装**：iPhone 能装上，不代表手表也能装。

### 为什么手表难装

自己签名的 App，只能装在签名时登记过的设备上，而且手表 App 要跟 iPhone 那份一起正确改签。常见的签名工具大多只登记数据线连着的那台 iPhone，不会处理手表，所以签完 iPhone 能用、手表装不上。用免费 Apple ID 签名时，手表还要打开「开发者模式」才能运行。

### 各签名方式能不能装手表

| 签名方式 | iPhone | 手表 |
| --- | --- | --- |
| 爱思助手（Apple ID 签名） | 可以 | 没有资料表明支持，一般装不上 |
| 全能签 / 轻松签（自备证书） | 可以 | 没有资料表明支持；证书里还必须登记了手表，一般装不上 |
| AltStore / SideStore | 可以 | 不支持 |
| Sideloadly 0.71 及以上 | 可以 | 付费开发者账号可以；免费 Apple ID 暂不支持（官方称下个版本支持） |
| WatchBridge（免费、开源） | 可以 | 可以，免费 Apple ID 即可，手表需打开开发者模式 |
| Mac 上用 Xcode 自己编译 | 可以 | 可以 |

> 只想在 iPhone 上用 DouDuo 的话，任何一种都行；想在手表上用，请看下面两种方法。

### 方法一：WatchBridge（推荐，Windows / Mac / Linux 都能用）

[WatchBridge](https://github.com/AdminZachary/WatchBridge) 是开源免费的工具，专门用来打开手表的开发者模式，并把带手表 App 的安装包同时装到 iPhone 和手表上，不需要 Xcode。

1. 下载 DouDuo 的 IPA（`DouDuo-x.x.x-unsigned.ipa`）和 WatchBridge。Windows 还要先装 iTunes 或微软商店的「Apple 设备」App。
2. iPhone 用数据线连电脑，手表戴着、解锁、放在手机旁边。
3. 在 WatchBridge 里选中设备，配对手表，在手表上点「信任」。
4. 让 WatchBridge 请求开发者模式开关，然后在手表上打开「设置 → 隐私与安全性 → 开发者模式」，按提示重启并确认，回到 WatchBridge 点「再次检查」。
5. 登录 Apple ID，选 DouDuo 的 IPA，签名并安装。它会先装 iPhone，再装手表。
6. 在手表上打开 DouDuo，确认能启动。

免费 Apple ID 签的包 7 天过期，手表上的那份会一起失效。WatchBridge 可以在到期前自动续签。具体操作以 WatchBridge 自己的说明为准。

### 方法二：付费开发者账号

- 有 Apple 付费开发者账号（每年 99 美元），可以用 Sideloadly 0.71 及以上签名，或者在 Mac 上用 Xcode 编译安装。
- 签名前要先把手表的设备编号（UDID）登记到开发者账号里。

### 装完以后

在 iPhone 上打开系统的「Watch」App，往下找到「DouDuo」，确认已安装。如果在「可用 App」里，点「安装」。

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
- **「Watch」App 里找不到 DouDuo，或点安装失败**：用的签名方式不支持手表（见上面的表格），换 WatchBridge 重签。
- **手表上打开 DouDuo 闪退或提示无法验证**：免费 Apple ID 签名需要手表打开开发者模式，或者签名已过期（7 天），重签即可。
