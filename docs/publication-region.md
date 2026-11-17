# 国内作品发布地区

默认随作品信息显示，无需开关。

- 在现有发布时间 / AI 声明行追加 `发布地：广东·深圳市`，沿用四种界面原有文字样式，描述展开页也一致。
- 优先使用作品根级 `city`、`region`。缺失时异步匿名补查；推荐页提前准备后面两条，懒加载的相邻作品页也提前查询。视频不等待地区起播。
- 已完成预查或有效本地缓存可在页面第一帧同步读取；冷启动、快划或接口缓慢时不承诺与视频同帧出现，以免拖慢起播。
- 等待补查期间保留上游原有信息，不先显示「未知」；收到结果后一次性显示地区或「未知」。已有有效国内字段则立即显示。
- 补查固定使用 `https://aweme.snssdk.com/aweme/v1/feed/?aweme_id=作品ID`，严格匹配响应中的同一作品 ID；不从作者资料、POI、内容文案或评论推断。
- 该接口没有稳定性保证，可能返回空数据、校验页或限流。未取得有效国内地区、海外地区均显示「未知」。**这不是经过验证的 IP 属地，也不是设备实时定位。**
- 不发送登录 Cookie / 凭据；无定位权限。只查询已展示、已挂载的相邻页及推荐流后面两条，不查询整个候选池。每次响应最多 2 MB、最多两个并发请求，同作品请求合并；已发出的请求受 10 / 15 秒传输超时约束。
- 本机缓存最多 512 条；已知地区 7 天、有效但无国内地区 5 分钟、失败 1 分钟后重新查询。删除缓存不会影响播放。

## 地区数据与许可

静态映射来自 [province-city-china v9.0.0](https://github.com/uiwjs/province-city-china/tree/v9.0.0)，MIT，Copyright (c) 2019 wabg；完整许可随 App 放在 `ProvinceCityChina-MIT.txt`。省 / 地级市保留名称，县级码归并到所属地级市或直辖市，不展示精确位置。

离线生成步骤（需要 Python 3.9+）：

```sh
curl -fL https://registry.npmjs.org/province-city-china/-/province-city-china-9.0.0.tgz -o /tmp/province-city-china-9.0.0.tgz
mkdir -p /tmp/province-city-china-9.0.0
tar -xzf /tmp/province-city-china-9.0.0.tgz -C /tmp/province-city-china-9.0.0
python3 scripts/generate-publication-regions.py /tmp/province-city-china-9.0.0/package/dist
```

数据包 SHA-256：`1093d93e776dd2c9cee11dfb3ff1bd8b4035fc9317e5d5ab82e88bc17029a08c`。
生成结果：3218 个码，SHA-256 `026f830e34519fa54daaa71faeb1f95526f787b3a188e563118d841efeb1e1ea`。

## 回归

```sh
python3 scripts/test_publication_region.py
python3 scripts/test_video_metadata.py
```

编译真实 Swift 解析 / 客户端代码，以 URLProtocol 模拟响应，验证 ID 匹配、输入边界、大小上限、请求合并、并发上限、缓存、同步首帧快照、两条预查与重试；同时执行实际 JS 映射和旧会话解码。测试不访问真实账号。

DEBUG 真机样本：沿用现有 `DOUDUO_HASHTAG_FIXTURE=1` 与 `DOUDUO_PLAYBACK_FIXTURE=1`（Documents/search-playback-fixture.mp4），加 `DOUDUO_REGION_FIXTURE=1`。包含已有国内字段、需要真实匿名补查的公开作品 ID、海外字段三种情形；Release 不含这些样本入口。不应把本地样本当作真实推荐流验收。
