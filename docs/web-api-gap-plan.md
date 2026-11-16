# 网页端接口补齐方案

> 分支：`feat/web-api-gap`（从 `main` 622e7d9 拉出）｜日期：2026-11-17
> 依据：2026-11-17 重新抓取的抖音 PC web bundle，共 918 个 JS：14 个页面首屏加载的 518 个，加上主站的懒加载 chunk 400 个。搜索站、直播站的懒加载 chunk 没有补抓。
> **本文所有参数都来自 bundle 源码，没有任何一条在登录态下实测过。** 每一项落地前必须先过第 0 步的探针。

---

## 0. 先验证，再动手（探针）

现有 `probe/web-api-validation` 分支的 `DYWebApiProbe.swift` / `DYWebApiProbe2.swift` 参数是猜的，其中 `related/recommend` 试了 `aweme_id` / `item_id` / `group_id`，而网页实际用 `related_aweme_id` + `related_rt`，结论不可用。

做法：本分支的 `DouDuo/DYWebApiProbe.swift` 按网页 bundle 里的真实参数重写了一遍，开关沿用 `DOUDUO_WEBAPI=1`，只打日志不改界面，结果在 `Documents/ddlog.txt` 里找 `DDGAP` 开头的行。只发读请求；每条记录 HTTP 状态、`status_code`、返回的顶层 key、列表长度和第一项的字段名，**不记录正文、cookie、token**（与 `publishJS` 的 diagnostic 同一规矩）。参数里要用的作品、音乐、合集、话题 ID 从推荐流和热榜现取。

另有 `DOUDUO_IMGUP=1`：取评论图片凭证并往 ImageX 传一张 64×64 的纯色小图，用来单独验证上传链路，不发评论。

通过标准：读接口返回 200 + `status_code == 0` + 列表非空；写接口先在自己的测试号上各做一次并能撤销。

受安全 SDK 策略名单监管、需要重点看是否被拦的：`mix/aweme`、`mix/list`、`mix/detail`、`music/aweme`、`music/detail`、`collects/list`、`collects/video/list`。

### 0.1 首轮实测（2026-11-17，模拟器，**未登录**）

| 接口 | 结果 |
| --- | --- |
| `aweme/related` | 通，10 条 |
| `related/recommend`（`related_aweme_id` + `related_rt`） | 通，6 条 |
| `music/detail` | 通 |
| `challenge/detail` | 通 |
| `hot/search/video/list` | 通，要 6 条只回 1 条 |
| `social/count`、`danmaku/conf/get` | 通 |
| `music/aweme` | HTTP 200 但 body 为空（带了签名），和搜索翻页被拦时一个样 |
| `challenge/aweme` | 14 秒硬超时，请求被压着没放出来 |
| `multi/aweme/detail` | `status_code` 0 但 `aweme_details` 为 null，body 的写法可能不对，待查 |
| `mix/list` | 通，但取到的那位作者没有合集，`mix/detail`、`mix/aweme` 因此没测到 |
| `collects/list`、`familiar/feed`、`view/user/visited/list`、`comment/upload/auth` | `status_code` 8，要登录 |

`music/aweme` 和 `challenge/aweme` 没通：要在登录态下再跑一次，确认是没登录的缘故还是被风控拦。同款音乐页和话题页能不能做取决于这两条。

### 0.2 第二轮实测（2026-11-17，真机，**已登录**）

| 接口 | 结果 |
| --- | --- |
| `comment/upload/auth` + ImageX 传图（`DOUDUO_IMGUP=1`） | 通。64×64 的 JPEG 走完申请、传图、提交三步，拿到 `Uri`、宽高、格式。原生请求不经过签名页也行 |
| `aweme/related`、`related/recommend` | 通，各 10 条，`has_more` 为 1 |
| `challenge/detail`、`challenge/aweme` | 通，作品 8 条（未登录时超时，登录后正常） |
| `mix/list`、`mix/detail` | 通，合集 12 个 |
| `collects/list`、`collects/video/list` | 通，夹内作品 9 条 |
| `familiar/feed` | 通，列表在 `data` 里（3 条），不是 `aweme_list` |
| `user/recommend` | 通，10 个 |
| `hot/search/video/list` | 通，要 6 条只回 1 条 |
| `music/detail`、`social/count`、`danmaku/conf/get` | 通 |
| `music/aweme` | **不通**：HTTP 200、带了签名、body 为空，登录后也一样。按被风控拦处理，同款音乐页暂时做不了作品列表 |
| `mix/aweme` | `status_code` 0 但 `aweme_list` 为 null、`has_more` 0。参数可能不对（`mix_scene`？），待查 |
| `multi/aweme/detail` | `status_code` 0 但 `aweme_details` 为 null，body 写法待查 |
| `view/user/visited/list` | `status_code` 5，原因未查 |

---

## 1. 评论发图（优先做）

### 1.1 结论

接口有，而且网页端正在用。链路是三步：

1. **取上传凭证**：`GET /aweme/v1/web/comment/upload/auth/?content_type=0`
   返回 `access_key`、`secret_key`、`session_token`、`expired_time`、`current_time`、`service_id`。
2. **传图到 ImageX**（`imagex.bytedanceapi.com`，不走抖音域名，不需要 `a_bogus`）：
   - `GET /?Action=ApplyImageUpload&Version=2018-08-01&ServiceId=<service_id>&NeedFallback=true&FileSize=<字节数>&s=<随机串>`，用上一步的临时密钥做 AWS4 签名（region `cn-north-1`，service `imagex`，参与签名的头只有 `x-amz-date` 和 `x-amz-security-token`）。返回 `UploadAddress.UploadHosts`、`StoreInfos[].StoreUri / Auth`、`SessionKey`、`UploadHeader`。
   - 把文件 `POST` 到 `https://<UploadHosts[0]>/upload/v1/<StoreUri>`，头：`Authorization: <StoreInfos.Auth>`、`Content-CRC32: <整个文件的 crc32，8 位小写十六进制>`、`X-Storage-U: <用户 uid>`、`Content-Type: application/octet-stream`，再加上 `UploadHeader` 里给的头。成功时回 `{"code":2000}`。
   - `POST /?Action=CommitImageUpload&Version=2018-08-01&ServiceId=<service_id>`，JSON body `{"SessionKey":"<SessionKey>"}`，同样 AWS4 签名（多签一个 `x-amz-content-sha256` = body 的 SHA-256）。返回 `Result.Results[0].Uri`，宽高和格式在 `Result.PluginResult[0]` 的 `ImageWidth`、`ImageHeight`、`ImageFormat`。
3. **发评论**：仍是 `POST /aweme/v1/web/comment/publish`，body 多带四个字段：
   `image_uri_list=<Uri>`、`image_widths=<宽>`、`image_heights=<高>`、`image_formats=<格式>`。
   网页同时还带 `paste_edit_method=non_paste`、`one_level_comment_rank=-1`。

网页端的规则：一次一张图；图片和表情包二选一；有图时文字可以为空；格式 png / webp / jpeg / bmp / jpg；单张不超过 10MB；宽高各不超过 10000。失败码 19 = 评论功能受限，3002575 = 健康分问题。

以上协议细节（region、service、上传地址、提交方式）都是照评论输入框实际用的那版上传器源码写的，签名算法另用 AWS 官方测试向量和一份独立的 Python 实现对过账（`scripts/test_imagex_upload.py`）。

**已实测（2026-11-17，真机，已登录）**：`DOUDUO_IMGUP=1` 上传自检通过；随后从评论输入栏真发了一条带图评论，`comment/publish` 返回 `status_code` 0，回执的 `comment.image_list` 里带着那张图。原生请求直接打 ImageX 网关可行，不需要退回到签名页里传。

### 1.2 实现

| 步骤 | 改哪里 | 做什么 |
| --- | --- | --- |
| 凭证（已写） | `DouyinBridge+CommentImage.swift` 的 `commentUploadCredential()` | 走现有 `call(...)`，在签名页里发 `comment/upload/auth` |
| 上传（已写） | `DYImageXUploader.swift`；入口是 `DouyinBridge.uploadCommentImage(_:fileName:measured:)` | 原生 `URLSession` 完成申请 → 传图 → 提交；AWS4 签名用 `CryptoKit` 的 HMAC-SHA256，CRC32 自己查表算 |
| 发布（已写） | `DouyinExtras.swift` 的 `publishComment` 加可选参数 `image: DYImageXUploadResult?`；`publishJS` 有图时往 body 追加那几个字段 | 不改无图时的请求形状（`scripts/test_comment_send.js` 有用例盯着） |
| 回显（已写） | `DouyinExtras.swift` 的 `cmap` | 回执里的 `image_list` 按评论列表同一套规则映射成图片；回执没带图时去评论列表里把这条找回来 |
| 核对（已写） | `DouyinExtras.swift` 的 `findMySentComment` | 带图时加一条「我的昵称 + 评论里有图 + 时间不早于发送前两分钟」的匹配，纯图评论也能核对 |
| 界面（已写） | `DouyinFeedView.swift` 评论输入栏（@ 按钮右边） | `PhotosPicker` 按钮；选中后在输入框上方显示缩略图和移除按钮；文字和图片都为空才禁用发送 |
| 预处理（已写） | `DouyinBridge+CommentImage.swift` 的 `DYCommentImagePrep` | JPEG / PNG 没超限的原样传；HEIC、GIF、超过 10MB 或边长超过 10000 的转成 JPEG（最长边 2560），再不行才提示 |

上传放原生而不是放进签名页的理由：不用把几 MB 的图片塞进 `callAsyncJavaScript`；上传请求本身不需要抖音的签名；进度、取消、重试都好做。如果实测发现 ImageX 校验 `Origin` / `Referer`，退路是在签名页里用 `fetch` 实现同一套流程。

风控注意：上传成功但 publish 失败时不自动重发（沿用现在「不自动重试写操作」的规矩），用户再点发送时复用已经传好的图，不重传；上传凭证用完即弃，不落盘、不进日志。

还没做：评论里发表情包（网页评论框里图片和表情包二选一，字段是 `sticker_id` 等七个）；私信里的评论入口（`DouyinMessages.swift` 那处 `publishComment` 调用）没有加选图。

还没测：回复里带图、纯图评论、HEIC 照片、超大图压缩这几种情况只有代码，没有逐个在真机上发过。

### 1.3 顺带发现的问题

`publishJS` 调用 `req('POST', path, body, { 'x-secsdk-csrf-token': 'DOWNGRADE' })`，但 `req` 的定义（`DouyinFeedView.swift:871`）只收三个参数，第四个参数被丢掉，**这个头实际上从来没发出去过**。现在发评论能成功，说明没有它也行；是补上还是删掉注释，需要在探针里对比一次再定，不要顺手改。

---

## 2. 小改动：已有界面，只缺接口

这些功能 App 里已有入口或列表，补一个动作即可。全部是写接口，统一先 `ensureWriteReady()`。

| 功能 | 接口（`/aweme/v1/web/`） | 参数 | 落点 |
| --- | --- | --- | --- |
| 加入 / 移出稍后再看 | `POST watchlater/upsert`、`POST watchlater/remove` | JSON body：`{item_to_playinfo, action_type}` / `{remove_item_ids, remove_type}` | 视频长按菜单；稍后再看列表左滑 |
| 清空观看历史 | `POST history/clear` | 空 body | 历史页右上角 |
| 拉黑 / 取消拉黑 | `POST user/block` | `user_id`, `sec_user_id`, `block_type`（1 / 0）, `source` | 作者页菜单 |
| 移除粉丝 | `POST remove/follower` | `sec_user_id`（query） | 粉丝列表左滑 |
| 通过关注请求 | `POST commit/follow/request/approve` | `from_user_id` | 通知页 |
| 删除通知 | `POST notice/del` | `{action_type, notice_id_str}` | 通知页左滑 |
| 弹幕点赞 | `GET danmaku/digg` | `danmaku_id`, `aweme_id`, `action_type` | 弹幕长按 |

注意 `watchlater/*` 的 body 是 JSON，而现有 `req` 固定发 `application/x-www-form-urlencoded`，需要给 `req` 加可选的 headers 参数（与 1.3 是同一处改动）。

---

## 3. 新页面：App 里完全没有的功能

按「用户点得到」的顺序排。每一项都是：桥接方法 + 列表页 + 入口。列表页尽量复用现有的作品网格和 `DYAweme` 解析。

| 顺序 | 功能 | 接口 | 参数 | 入口 |
| --- | --- | --- | --- | --- |
| 1 | 合集 | `mix/aweme`、`mix/detail`、`mix/list`、`mix/collect` | `mix_id`, `cursor`, `count=12`；`mix/list` 用 `sec_user_id` | 视频简介下的合集条；作者页「合集」页签 |
| 2 | 话题页 | `challenge/detail`、`challenge/aweme` | `ch_id`, `query_type=0`, `sort_type`, `cursor`, `count` | 简介里的 `#话题`（现在只能跳搜索） |
| 3 | 同款音乐 | `music/detail`、`music/aweme`、`music/collect` | `music_id`, `cursor`, `count=10` | 视频右下角音乐条 |
| 4 | 相关推荐 | `aweme/related`；备选 `related/recommend` | `aweme_id`, `count=6`, `refresh_index`；备选用 `related_aweme_id`, `related_rt` | 视频详情侧栏 / 播完推荐 |
| 5 | 收藏夹分组 | `collects/list`、`collects/video/list` | `collects_id`, `cursor`, `count=12` | 「我的」→ 收藏 |
| 6 | 热点对应视频 | `hot/search/video/list` | `hotword`, `sentence_id`, `offest`（原文如此）, `count` | 热榜点进去（现在走搜索，受翻页限制） |
| 7 | 短剧 | `series/detail`、`series/aweme` | `series_id`, `pull_type=2`, `cursor`, `count` | 视频上的短剧条 |
| 8 | 谁看过我 | `POST view/user/visited/list` | `{cursor, count=20}` | 「我的」 |
| 9 | 朋友动态流 | `familiar/feed` | `pull_type`, `cursor`, `level` | 「朋友」页签（需先确认要不要这个页签） |

`aweme/related` 在 2026-11-09 无登录测试时返回 200 空 body，登录态下是否有数据是第 0 步要回答的头一个问题。

---

## 4. 直播侧

`live.douyin.com/webcast/` 下可以考虑：`room/like`（点赞）、`ranklist/audience`（观众榜）、`gift/list`（只展示）、`user/profile`（用户卡片）、`web/similar_room_by_anchor`、`moment/latest_replay`（回放）。

直播站的懒加载 chunk 还没补抓（缺 315 个），这一组的参数没有核对，等前三步做完再单独查。

---

## 5. 不做

- 连麦、送礼支付、钱包、抽奖、红包。
- 发布作品、视频上传。
- passport 登录相关接口：登录态继续共用网页的。
- 私信直连 `imapi.douyin.com`：bundle 里只有 `/v1/message/send` 和 `/v1/user/webid` 两条明文路径，收消息不是普通 HTTP 接口，维持现在读网页状态的做法。
- 搜索翻页相关（`general/search/stream`、`discover/search`、`live/search`）：大概率和现有搜索一样被安全 SDK 拦，放到最后单独试。

---

## 6. 提交拆分

每一行一个提交，按现有提交格式 `feat(模块): 说明`。

1. `chore(探针)`：按真实参数重写网页接口探针（第 0 步）。
2. `feat(评论)`：ImageX 上传器 + 凭证接口。
3. `feat(评论)`：评论输入框选图、发图、回显、核对。
4. `feat(稍后再看/历史)`：加入、移出、清空。
5. `feat(关系)`：拉黑、移除粉丝、通过关注请求。
6. 第 3 节每个功能各一个提交。
7. `docs(接口)`：重写 `docs/api-inventory.md`（现在只扫了 43 个 bundle、只看 `/aweme/v1/`，`familiar/atlist` 已接入却仍列在未接入）。

第 1 步的探针结果决定后面哪些做、哪些砍，所以 2 之后的顺序可能调整。
