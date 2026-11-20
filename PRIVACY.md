# DouDuo 隐私说明 / Privacy Policy

更新日期：2026-11-17

DouDuo 是一个开源的第三方视频客户端，**与抖音、北京字节跳动科技有限公司没有任何关联**，仅供个人学习使用。

## 我们不收集任何数据

- DouDuo **没有自己的服务器**，不收集、不上传、不出售你的任何个人信息、使用记录或设备信息。
- App 内没有广告 SDK、统计 SDK 或第三方追踪。

## 数据去了哪里

- 你在 App 内登录的抖音账号，登录态（Cookie）只保存在**你手机本机**的系统网页存储里，由抖音网页版直接处理。
- 浏览推荐、点赞、收藏、评论、弹幕、观看记录等请求，都是**从你的手机直接发给抖音**，适用抖音自己的隐私政策：https://www.douyin.com/agreements/?id=6773901168964798477
- 预缓存的视频、浏览进度只保存在本机，可在系统设置里删除 App 清除。

## 国内发布地

- 随作品信息默认显示，优先使用作品已有的地区字段；已展示或懒加载的相邻作品、推荐流后面两条缺失有效国内地区时，向 `aweme.snssdk.com/aweme/v1/feed/` 发送作品 ID 补查，不携带登录 Cookie 或账号凭据。服务方仍能看到正常网络请求的来源 IP。
- 只使用与请求作品 ID 完全匹配的作品 `city` / `region` 字段，不读取作者资料、POI、评论位置，不调用设备定位。它不等同于平台展示的 IP 属地或实时位置；海外及缺失值显示未知。
- 仅在本机缓存作品 ID、地区码、国家码和查询/重试时间，最多 512 条；已知地区 7 天后重新查询，无地区 5 分钟、失败 1 分钟后可重试。推荐换条时替换过期的待预查队列，已经发出的请求会在超时内结束；不记录或缓存该接口返回的完整内容、账号数据或媒体。
- 地区缓存位于 App 的系统 Caches 目录，可被系统回收。

## 权限

- **添加到相册**：仅在你点「保存」时，把视频/图集写入相册。

## 联系

问题或建议请在 GitHub 提 Issue：https://github.com/WuWeiDuo/DouDuo/issues

---

DouDuo does not operate any server and does not collect, store or share personal data. Account sign-in and all content requests go directly from your device to Douyin and are governed by Douyin's own privacy policy. Saved-to-Photos is used only when you tap Save.

Domestic publication regions are displayed by default. Missing metadata for displayed works, lazily mounted neighbours and the next two recommendations is fetched directly from aweme.snssdk.com using the work ID, without login cookies or credentials. Only a bounded local region cache is retained. The service receives the normal network source IP. These work fields are not verified IP attribution or real-time location.
