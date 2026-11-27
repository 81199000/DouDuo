# 抖音 web 接口清单（DouDuo 已接入 vs 未接入）

来源：抖音 PC web 前端 bundle（`lf-douyin-pc-web.douyinstatic.com/obj/douyin-pc-web/ies/douyin_web/*.js`，43 个大 bundle，14MB）
提取方式：`grep -rhoE '/aweme/v1/[a-zA-Z0-9_/]+'`，去重后 **223 个 `/aweme/v1/web/*` 接口**。

- 已接入：**33**
- 未接入：**192**（含上报/广告/电商/实验等噪声，下面按功能分组只列有用的）

## 已接入（33）

推荐流 `channel/feed`（我们走的是签名页 requestJS 里的其它路径）· `aweme/detail` · `aweme/post` · `aweme/favorite` · `aweme/listcollection` · `aweme/collect` · `comment/list` · `comment/list/reply` · `comment/publish` · `comment/digg` · `comment/delete` · `commit/item/digg` · `commit/item/collect` · `commit/follow/user` · `commit/dislike/item` · `follow/feed` · `user/profile/self` · `user/profile/other` · `user/following/list` · `user/follower/list` · `history/read` · `history/write` · `watchlater/list` · `search/item` · `search/sug` · `general/search/single` · `api/suggest_words` · `hot/search/list` · `notice` · `notice/count` · `danmaku/get_v2` · `danmaku/post_v2` · `danmaku/delete_v2` · `emoji/list`

## 未接入 · 值得做

### 评论（3）
- `comment/upload/auth` — **评论发图的授权（图片评论能做了）**
- `comment/translate` — 评论翻译
- `comment/stats` — 评论计数

### 自定义表情包（im 域，16 个里的关键几个）
- `im/resources/emoticon/trending` — 热门表情包
- `im/resource/list/aggregation` — 表情包聚合列表
- `im/resource/emoticon/search` — 搜表情包
- `im/resource/sticker/collect` — 收藏表情
- `im/recent/sticker/fetch` / `im/recent/sticker/record` — 最近使用
- 其余：`im/conversation/info/other`、`im/token`、`im/spotlight/relation`、`im/strategy/config`、`im/user/active/*`

### @ 好友（4）
- `familiar/atlist` — **@ 专用列表（比 following/list 更贴）**
- `familiar/feed` — 朋友动态
- `familiar/recommend/feed`、`familiar/recommend/submit` — 可能认识的人

### 内容扩展
- `aweme/related` — 相关视频（视频下方推荐）
- `challenge/detail` / `challenge/aweme` / `challenge/search` — 话题挑战
- `music/detail` / `music/aweme` / `music/list` / `music/collect` — 音乐
- `collects/list` / `collects/video/list` / `collects/video/move` / `collects/maintain` — 合集
- `mix/detail` / `mix/list` / `mix/aweme` / `mix/listcollection` / `mix/collect` — 播放列表
- `search/general/vision` / `search/vision/overlay` — 以图搜视频
- `live/search` — 直播搜索

### 弹幕（4）
- `danmaku/list` — 弹幕列表
- `danmaku/conf/get` / `danmaku/conf/set` — 弹幕配置
- `danmaku/digg` — 弹幕点赞

### 用户与社交（8）
- `user/block` — 拉黑
- `user/settings` / `user/set/settings` — 设置
- `user/recommend` — 推荐用户
- `user/paid_content/get` — 付费内容
- `user/self/right` — 自己的权限
- `user/appointment/list` — 预约
- `user/guide/channel` — 引导

### 通知（3）
- `notice/detail` / `notice/digg/list` / `notice/del`

### 噪声（不接）
`monitor`、`report`、`impression`、`ecom/*`、`brand/ad/*`、`activity/*`、`creator/*`、`epidemic/*`、`admin/config`、`page/turn/offline`、`seo/inner/link`、`solution/resource/list` 等上报/广告/运营埋点。

## 验证记录

无登录态 curl 实测（2026-11-09）：

```
200 comment/upload/auth              {"status_code":8,"status_msg":"用户未登录"}   ← 接口存在
200 im/resources/emoticon/trending   {"status_code":8,...}                          ← 接口存在
200 familiar/atlist                  {"status_code":8,...}                          ← 接口存在
404 comment/translate                Unsupported path(Janus)                        ← 路径要补斜杠再试
200 aweme/related                    （空 body，需要参数）
```
