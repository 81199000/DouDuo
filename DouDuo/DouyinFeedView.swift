// DouDuo：抖音第三方客户端。数据走抖音网页端接口，界面 / 播放全原生。
// 源自 無為 App 的「抖音原生模式」。
// - 一个看不见的 WKWebView（电脑版 UA）挂在抖音页面上，只当「签名代理」：在页面里发 XHR，
//   抖音自己的安全 SDK 自动补 a_bogus 等签名，签名算法跟着官方更新走，我们不用逆向。
// - 登录态与「网页版」共用 WKWebsiteDataStore.default()，在网页版登录后原生模式即带账号。
// - 推荐流：POST /aweme/v2/web/module/feed/（module_id=3003101，绝大多数竖屏）；
//   播放用 /aweme/v1/play/ 链接（302 到 CDN mp4，不需要 cookie，系统播放器直接播）。
// - 评论：GET /aweme/v1/web/comment/list/。
import SwiftUI
import Combine
import WebKit
import AVFoundation

// MARK: - 数据

struct DYAweme: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let desc: String
    let width: Double
    let height: Double
    let duration: Double
    let play: String?
    /// 抖音默认清晰度的地址（play 选了更高一档时才有）；高清起不来时备用
    var playAlt: String? = nil
    /// 秒开用的低码率地址（冷启动先放它，高清好了再换）
    var playFast: String? = nil
    /// 选中的清晰度说明（调试日志用）
    var q: String? = nil
    let cover: String?
    let images: [String]
    let author: Author
    let stats: Stats
    let music: String
    /// 该视频在你账号里是否已点赞 / 已收藏（未登录时一般没有这些字段）
    let userDigged: Int?
    let isCollect: Int?
    /// 0=视频 68=图文；上报观看时要带
    var awemeType: Int? = nil
    /// 作品原始发布时间（Unix 秒）；可选以兼容已保存的旧播放会话。
    var publishedAt: TimeInterval? = nil
    /// 保留平台返回的 AI 声明原文；没有标记不代表非 AI。
    var aiDeclaration: String? = nil

    func publicationText(now: Date = Date()) -> String? {
        guard let publishedAt, publishedAt.isFinite, publishedAt > 0,
              publishedAt <= now.timeIntervalSince1970 else { return nil }
        let age = now.timeIntervalSince1970 - publishedAt
        if age < 60 { return "刚刚发布" }
        if age < 3600 { return "\(Int(age / 60))分钟前发布" }
        if age < 86400 { return "\(Int(age / 3600))小时前发布" }
        if age < 604800 { return "\(Int(age / 86400))天前发布" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date(timeIntervalSince1970: publishedAt)) + " 发布"
    }

    func metadataText(now: Date = Date()) -> String? {
        let parts = [publicationText(now: now), aiDeclaration?.trimmingCharacters(in: .whitespacesAndNewlines)]
            .compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    struct Author: Codable, Equatable { let name: String; let avatar: String?; let secUid: String?; var uid: String? = nil; var follow: Int? = nil }
    struct Stats: Codable, Equatable { let digg: Int; let comment: Int; let collect: Int; let share: Int; var play: Int? = nil }

    /// 视频画面高宽比，不是界面方向。界面布局看容器尺寸 / size class。
    var isTallFrame: Bool { height > width * 1.05 }
    var webURL: URL { URL(string: "https://www.douyin.com/video/\(id)")! }
}

/// 点赞/收藏的结果：成功 / 没登录 / 其它失败（带原因）
enum DYActionResult {
    case ok
    case notLoggedIn
    case failed(String)
}

struct DYActionResp: Decodable {
    let status: Int
    let statusCode: Int?
    let msg: String?
    enum CodingKeys: String, CodingKey { case status, statusCode = "statusCode", msg }
}

struct DYComment: Identifiable, Decodable, Equatable {
    let id: String
    let text: String
    let name: String
    let avatar: String?
    let digg: Int
    let time: Double
    let replies: Int
    let ip: String?
    /// 这条评论在账号里是否已赞。缺字段当未赞。
    var userDigged: Int? = nil
    /// 评论配图（image_list）与表情包贴纸（sticker），缺字段为空
    var images: [DYCommentImage]? = nil
    var sticker: DYCommentImage? = nil
    /// 定位评论时接口随一级评论一起带回的楼中楼（只在 insert_ids 请求里有）
    var pinned: [DYComment]? = nil
    /// 楼中楼被 insert_ids 直接顶到一级列表时，它所属的一级评论 cid（回复它要用）
    var parent: String? = nil
}

/// 评论里的一张图：缩略图用于列表，原图用于点开全屏
struct DYCommentImage: Decodable, Equatable, Hashable {
    let thumb: String
    let full: String
    let w: Double
    let h: Double
}

struct DYLiveRoom: Identifiable, Decodable, Equatable {
    let id: String
    let webRid: String
    let title: String
    let owner: String
    let avatar: String?
    let cover: String?
    let viewers: String
    let hls: [String: String]      // FULL_HD1 / HD1 / SD1 / SD2
    var flv: [String: String]? = nil
    let portrait: Bool
    var def: String? = nil

    var bestHLS: URL? {
        for k in ["HD1", "FULL_HD1", "SD2", "SD1"] { if let s = hls[k], let u = URL(string: s) { return u } }
        return hls.values.first.flatMap(URL.init(string:))
    }
    var webURL: URL { URL(string: "https://live.douyin.com/\(webRid)")! }
}

extension DYLiveRoom {
    var followMetadata: DYFollowMetadata {
        DYFollowMetadata(id: id, webRid: webRid, title: title, owner: owner, avatar: avatar, cover: cover, viewers: viewers, portrait: portrait)
    }

    init(_ metadata: DYFollowMetadata) {
        self.init(id: metadata.id, webRid: metadata.webRid, title: metadata.title, owner: metadata.owner,
                  avatar: metadata.avatar, cover: metadata.cover, viewers: metadata.viewers, hls: [:], portrait: metadata.portrait)
    }

    init(playback resolved: DYLiveRoom, fallback: DYLiveRoom) {
        let meta = resolved.followMetadata.fillingEmpty(from: fallback.followMetadata)
        self.init(id: meta.id, webRid: meta.webRid, title: meta.title, owner: meta.owner, avatar: meta.avatar,
                  cover: meta.cover, viewers: meta.viewers, hls: resolved.hls, flv: resolved.flv, portrait: meta.portrait, def: resolved.def)
    }
}

private struct DYLiveResp: Decodable { let status: Int; let items: [DYLiveRoom] }

struct DYFollowLiveResult: Equatable {
    var kind: DYFollowLiveKind
    var items: [DYLiveRoom]
    var status: Int
    var stats: DYFollowLiveStats?
    var fromCache = false
    var stale = false
}

private struct DYFollowLivePayload: Decodable {
    let status: Int
    let items: [DYLiveRoom]
    let stats: DYFollowLiveStats?
}

/// 直播专区（网页版「游戏」下的专区；id 取自 live.douyin.com/categorynew/4_103_1_<id>）
/// shortcut: 写死网页版游戏页上的几个专区，网页改版/要别的分类时再从页面里抓
struct DYLiveZone: Hashable {
    let id: String, type: String, name: String
    static let all: [DYLiveZone] = [
        ("1010017", "无畏契约"), ("1011032", "三角洲行动"), ("1010045", "王者荣耀"), ("1010014", "英雄联盟"),
        ("1010032", "和平精英"), ("1010037", "穿越火线"), ("1010026", "绝地求生"), ("1010146", "QQ飞车端游"),
    ].map { DYLiveZone(id: $0.0, type: "1", name: $0.1) }
}

private struct DYFeedPage: Decodable { let status: Int; let items: [DYAweme]; let hasMore: Bool; let msg: String? }
private struct DYCommentPage: Decodable { let status: Int; let items: [DYComment]; let cursor: Int; let hasMore: Bool; let total: Int; let msg: String? }

enum DYError: LocalizedError {
    case notReady, blocked(String), bad(String)
    var errorDescription: String? {
        switch self {
        case .notReady: "抖音页面还没加载好"
        case .blocked(let m): "抖音拦截了请求（\(m)），在「网页版」里过一下验证或登录后重试"
        case .bad(let m): m
        }
    }
}

// MARK: - 签名代理（隐藏网页）

@MainActor
final class DouyinBridge: NSObject, ObservableObject, WKNavigationDelegate {
    @Published private(set) var ready = false
    /// 只在 `reload` 推进。界面用它清掉上一账号的关注直播，不代表登录态本身。
    @Published private(set) var followSession = 0
    let web: WKWebView
    private var readyWaiters: [CheckedContinuation<Void, Never>] = []

    private let startURL: URL
    private var liveContext: DouyinBridge?

    override convenience init() {
        self.init(startURL: URL(string: "https://www.douyin.com/jingxuan")!)
    }

    init(startURL: URL) {
        self.startURL = startURL
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        // 隐藏签名页只要接口，不要视频：⚠️ 不能设 allowsInlineMediaPlayback=false——
        // 抖音页自动播放时会弹系统全屏播放器盖住整个原生界面（UI 测试实测）。改成允许内联 + 脚本禁掉所有媒体播放
        cfg.mediaTypesRequiringUserActionForPlayback = .all
        cfg.allowsInlineMediaPlayback = true
        cfg.allowsPictureInPictureMediaPlayback = false
        cfg.userContentController.addUserScript(WKUserScript(source: Self.noMediaJS, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        web = WKWebView(frame: CGRect(x: 0, y: 0, width: 1200, height: 800), configuration: cfg)
        web.customUserAgent = DouyinWeb.userAgent
        super.init()
        web.navigationDelegate = self
        reload()
    }

    func reload() {
        followSessionCache.invalidate()
        followSession = followSessionCache.generation
        ready = false
        web.load(URLRequest(url: startURL))
        liveContext?.reload()
    }

    /// 直播专区请求在 live.douyin.com 的网页 SDK 中发出，共享真实登录态，避免跨域签名/请求被拒。
    private func callLive(_ body: String, args: [String: Any]) async throws -> Data {
        if liveContext == nil {
            let context = DouyinBridge(startURL: URL(string: "https://live.douyin.com/")!)
            context.web.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
            web.superview?.addSubview(context.web)
            liveContext = context
        }
        guard let context = liveContext, context.web.superview != nil else { throw DYError.notReady }
        return try await context.call(body, args: args, attempts: 1)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // 安全 SDK 在 load 之后还要初始化一小会儿
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }
            self.ready = true
            // 签名 SDK 就绪后把整页 DOM 清空：隐藏页面不再持续渲染（真机上 WebContent 曾占约 43% 一个核，手机发烫）
            self.web.evaluateJavaScript(Self.quietPageJS) { r, _ in DYLiveModel.log("DDQUIET \(r.map { String(describing: $0) } ?? "nil")") }
            self.readyWaiters.forEach { $0.resume() }
            self.readyWaiters.removeAll()
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let s = action.request.url?.scheme?.lowercased() ?? ""
        decisionHandler(["http", "https", "about", "blob", "data"].contains(s) ? .allow : .cancel)
    }

    private func waitReady() async {
        if ready { return }
        await withCheckedContinuation { readyWaiters.append($0) }
    }

    /// 在抖音页面里发请求（页面 SDK 自动签名），JS 端把大 JSON 裁成精简结构再回传
    func call(_ body: String, args: [String: Any], attempts: Int = 3) async throws -> Data {
        await waitReady()
        var lastErr: Error = DYError.notReady
        for attempt in 0..<attempts {
            do {
                // 大响应（如消息列表 ~150KB）冷网络下求值慢，失败时记录真实错误码便于定位
                let r = try await web.callAsyncJavaScript(Self.requestJS + body, arguments: args, contentWorld: .page)
                guard let s = r as? String, let d = s.data(using: .utf8) else { throw DYError.bad("返回为空") }
                return d
            } catch {
                lastErr = error
                #if DEBUG
                DYLiveModel.log("DDCALL err code=\(String(describing: (error as? WKError)?.code)) \(error.localizedDescription) attempt=\(attempt)")
                #endif
                try? await Task.sleep(nanoseconds: UInt64(600_000_000 * (attempt + 1)))
            }
        }
        throw lastErr
    }

    private var refreshIndex = 1
    /// 首次安装时间要固定：以前每次请求都用「现在-15分钟」，服务端会当成刚装的新设备，推荐偏冷启动内容
    static let installTime: Int = {
        let k = "douyin_install_time_v1"
        let v = UserDefaults.standard.integer(forKey: k)
        if v > 0 { return v }
        let now = Int(Date().timeIntervalSince1970)
        UserDefaults.standard.set(now, forKey: k)
        return now
    }()

    /// 观看上报：跟网页版一样，起播时报播放(aweme/stats)、登录时写观看历史(history/write)。
    /// 不上报，账号就学不到你在DouDuo里看了什么，推荐会和 App 越走越远。
    func reportWatch(_ a: DYAweme, preID: String?, preSeen: Bool) async {
        let d = try? await call(Self.watchJS, args: [
            "id": a.id, "type": String(a.awemeType ?? 0), "author": a.author.uid ?? "",
            "pre": preID ?? "", "seen": preSeen ? "1" : "0"], attempts: 1)
        #if DEBUG
        DYLiveModel.log("DDWATCH \(a.id) \(d.flatMap { String(data: $0, encoding: .utf8) } ?? "fail")")
        #endif
    }
    /// 自己的 sec_uid（拉「喜欢」列表要用）
    var selfSecCache: String?

    private static let noMediaJS = """
    (() => {
      const P = HTMLMediaElement.prototype;
      P.play = function () { try { this.muted = true; this.pause(); } catch (e) {} return Promise.resolve(); };
      const V = HTMLVideoElement.prototype;
      // 签名页绝不能占用原生全屏播放器；部分网站会直接请求全屏而不调用 play()。
      V.webkitEnterFullscreen = V.webkitEnterFullScreen = function () {};
      for (const key of ['requestFullscreen', 'webkitRequestFullscreen', 'webkitRequestFullScreen']) {
        Element.prototype[key] = function () { return Promise.resolve(); };
      }
      const kill = () => document.querySelectorAll('video,audio').forEach(v => { try {
        v.muted = true; v.pause(); v.removeAttribute('autoplay'); v.preload = 'none';
        v.playsInline = true; v.setAttribute('playsinline', ''); v.setAttribute('webkit-playsinline', '');
      } catch (e) {} });
      const observe = () => {
        kill();
        if (document.documentElement) new MutationObserver(kill).observe(document.documentElement, { childList: true, subtree: true });
      };
      document.addEventListener('DOMContentLoaded', observe);
      if (document.documentElement) observe();
    })();
    """

    func fetchFeed() async throws -> (items: [DYAweme], hasMore: Bool) {
        refreshIndex += 1
        let d = try await call(Self.feedJS, args: ["refresh": String(refreshIndex),
                                                   "install": String(Self.installTime),
                                                   "pull": refreshIndex <= 2 ? "0" : "2"])
        let p = try JSONDecoder().decode(DYFeedPage.self, from: d)
        guard p.status == 200 else { throw DYError.blocked("HTTP \(p.status)") }
        if p.items.isEmpty, let m = p.msg, !m.isEmpty { throw DYError.blocked(m) }
        return (p.items, p.hasMore)
    }

    /// 真点赞（走网页端同一个接口，页面 SDK 自动签名）
    func digg(_ id: String, like: Bool) async throws -> DYActionResult {
        let d = try await call(Self.diggJS, args: ["id": id, "type": like ? "1" : "0"])
        let r = try JSONDecoder().decode(DYActionResp.self, from: d)
        #if DEBUG
        ddWrite("DDACT digg id=\(id) like=\(like) status=\(r.status) code=\(r.statusCode ?? -1) msg=\(r.msg ?? "-")")
        #endif
        return Self.interpret(r)
    }

    /// 不感兴趣：网页版同一个接口（commit/dislike/item），抖音据此减少同类推荐
    func dislike(_ id: String) async throws -> DYActionResult {
        let d = try await call(Self.dislikeJS, args: ["id": id], attempts: 2)
        let r = try JSONDecoder().decode(DYActionResp.self, from: d)
        #if DEBUG
        ddWrite("DDACT dislike id=\(id) status=\(r.status) code=\(r.statusCode ?? -1) msg=\(r.msg ?? "-")")
        #endif
        return Self.interpret(r)
    }

    /// 统一解读：status_code 8 = 用户未登录；0 = 成功
    private static func interpret(_ r: DYActionResp) -> DYActionResult {
        if r.status == 200, (r.statusCode ?? 0) == 0 { return .ok }
        if r.statusCode == 8 || (r.msg ?? "").contains("未登录") { return .notLoggedIn }
        return .failed(r.msg?.isEmpty == false ? r.msg! : "HTTP \(r.status) / code \(r.statusCode ?? -1)")
    }

    /// 真收藏 / 取消收藏
    func favorite(_ id: String, add: Bool) async throws -> DYActionResult {
        #if DEBUG
        ddWrite("DDACT fav start id=\(id) add=\(add)")
        #endif
        let d = try await call(Self.favJS, args: ["id": id, "action": add ? "1" : "0"])
        #if DEBUG
        ddWrite("DDACT fav raw \(String(data: d, encoding: .utf8)?.prefix(200) ?? "-")")
        #endif
        let r = try JSONDecoder().decode(DYActionResp.self, from: d)
        #if DEBUG
        ddWrite("DDACT fav id=\(id) add=\(add) status=\(r.status) code=\(r.statusCode ?? -1) msg=\(r.msg ?? "-")")
        #endif
        return Self.interpret(r)
    }

    #if DEBUG
    /// 模拟器扫码登录：直接走抖音 SSO 的二维码接口，二维码存 Documents/qr.png，扫完自动跳 redirect 落 cookie
    func debugQRLogin() async {
        await waitReady()
        let getJS = #"""
        const r = await fetch('https://sso.douyin.com/get_qrcode/?service=' + encodeURIComponent('https://www.douyin.com') + '&need_logo=false&need_short_url=false&aid=6383&account_sdk_source=sso&language=zh', { credentials: 'include' });
        const t = await r.text();
        return t;
        """#
        guard let raw = try? await web.callAsyncJavaScript(getJS, arguments: [:], contentWorld: .page) as? String,
              let d = raw.data(using: .utf8),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let data = j["data"] as? [String: Any],
              let b64 = data["qrcode"] as? String, let token = data["token"] as? String,
              let png = Data(base64Encoded: b64) else {
            DYLiveModel.log("DDQR get 失败 \((try? await web.callAsyncJavaScript(getJS, arguments: [:], contentWorld: .page)) as? String ?? "nil")")
            return
        }
        let u = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("qr.png")
        try? png.write(to: u)
        DYLiveModel.log("DDQR 二维码已生成 token=\(token.prefix(8))")
        let checkJS = #"""
        const r = await fetch('https://sso.douyin.com/check_qrconnect/?service=' + encodeURIComponent('https://www.douyin.com') + '&token=' + token + '&need_logo=false&aid=6383&account_sdk_source=sso&language=zh', { credentials: 'include' });
        return await r.text();
        """#
        for _ in 0..<100 {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let s = try? await web.callAsyncJavaScript(checkJS, arguments: ["token": token], contentWorld: .page) as? String,
                  let cd = s.data(using: .utf8), let cj = try? JSONSerialization.jsonObject(with: cd) as? [String: Any],
                  let dd = cj["data"] as? [String: Any] else { continue }
            let st = "\(dd["status"] ?? "?")"
            DYLiveModel.log("DDQR status=\(st)")
            if let redirect = dd["redirect_url"] as? String, let ru = URL(string: redirect), !redirect.isEmpty {
                DYLiveModel.log("DDQR 已确认，跳转落 cookie")
                web.load(URLRequest(url: ru))
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                reload()
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                if let me = try? await selfProfile() { DYLiveModel.log("DDQR 登录成功 \(me.name)") }
                else { DYLiveModel.log("DDQR 跳转后仍未登录") }
                return
            }
            if st == "5" || st == "4" { DYLiveModel.log("DDQR 二维码过期"); return }
        }
    }

    /// 调试：把真机登录态导出 / 导入到模拟器（只在 DEBUG，本机两台设备之间搬，不上传）
    func debugExportCookies() async {
        let store = WKWebsiteDataStore.default().httpCookieStore
        let cs = await store.allCookies().filter { $0.domain.contains("douyin") }
        let arr: [[String: Any]] = cs.map { c in
            var p: [String: Any] = ["name": c.name, "value": c.value, "domain": c.domain, "path": c.path,
                                    "secure": c.isSecure, "httpOnly": c.isHTTPOnly]
            if let e = c.expiresDate { p["expires"] = e.timeIntervalSince1970 }
            return p
        }
        let u = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("dd-cookies.json")
        if let d = try? JSONSerialization.data(withJSONObject: arr) { try? d.write(to: u) }
        DYLiveModel.log("DDCK export \(arr.count) sessionid=\(cs.contains { $0.name == "sessionid" })")
    }

    func debugImportCookies() async {
        let u = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("dd-cookies.json")
        guard let d = try? Data(contentsOf: u), let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] else {
            DYLiveModel.log("DDCK import 没有文件"); return
        }
        let store = WKWebsiteDataStore.default().httpCookieStore
        var n = 0
        for p in arr {
            var props: [HTTPCookiePropertyKey: Any] = [.name: p["name"] ?? "", .value: p["value"] ?? "",
                                                      .domain: p["domain"] ?? "", .path: p["path"] ?? "/"]
            if (p["secure"] as? Bool) == true { props[.secure] = "TRUE" }
            if (p["httpOnly"] as? Bool) == true { props[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
            if let e = p["expires"] as? Double { props[.expires] = Date(timeIntervalSince1970: e) }
            if let c = HTTPCookie(properties: props) { await store.setCookie(c); n += 1 }
        }
        try? FileManager.default.removeItem(at: u)
        DYLiveModel.log("DDCK import \(n)")
        reload()
        try? await Task.sleep(nanoseconds: 8_000_000_000)
        if let me = try? await selfProfile() { DYLiveModel.log("DDCK 登录成功 \(me.name)") } else { DYLiveModel.log("DDCK 导入后仍未登录") }
    }

    /// 探针：在签名页里跑一段 JS（可用 req/base/parse/first），返回字符串
    func probe(_ body: String) async -> String {
        (try? await call(body, args: [:])).flatMap { String(data: $0, encoding: .utf8) } ?? "ERR"
    }
    #endif

    /// 是否已登录（登录后推荐流才跟着账号走）
    func isLoggedIn() async -> Bool {
        let r = try? await web.callAsyncJavaScript(Self.loginJS, arguments: [:], contentWorld: .page)
        let s = (r as? String) ?? ""
        #if DEBUG
        ddWrite("DDACT login check -> \(s)")
        #endif
        return s.contains("sessionid") || s == "1"
    }

    /// insert：要「插到最前」的评论 cid（逗号分隔，一级评论在前、楼中楼在后）。网页从消息点评论跳视频就是这么定位的，
    /// 实测传楼中楼 cid 时会把它的一级评论顶到第一条，并把那条回复放进 reply_comment。
    func fetchComments(_ id: String, cursor: Int, insert: String? = nil) async throws -> (items: [DYComment], cursor: Int, hasMore: Bool, total: Int) {
        let d = try await call(Self.commentJS, args: ["id": id, "cursor": String(cursor), "ins": insert ?? ""])
        let p = try JSONDecoder().decode(DYCommentPage.self, from: d)
        guard p.status == 200 else { throw DYError.blocked("HTTP \(p.status)") }
        let withImg = p.items.filter { !($0.images ?? []).isEmpty }.count
        let withStk = p.items.filter { $0.sticker != nil }.count
        if withImg + withStk > 0 { DYLiveModel.log("DDCOMMENTIMG aweme=\(id) n=\(p.items.count) images=\(withImg) stickers=\(withStk)") }
        return (p.items, p.cursor, p.hasMore, p.total)
    }

    private var liveMaxTime = "0"
    private var liveOffset = 0
    private var liveCursorGeneration = UUID()

    /// 关注的主播里正在直播的。列表只带展示信息；播放地址等选中单个主播再解析。
    func fetchFollowLive() async throws -> [DYLiveRoom] {
        let result = await followLiveResult()
        switch result.kind {
        case .rooms:
            return result.items
        case .nobodyLive, .filtered:
            return []
        case .notLoggedIn:
            throw DYError.blocked("HTTP 401")
        case .decodeFailed, .unexpectedShape:
            throw DYError.bad("直播数据无法解析")
        case .requestFailed:
            throw DYError.blocked(result.status == 200 ? "连接失败" : "HTTP \(result.status)")
        }
    }

    /// 同一次关注直播请求的分类结果。空列表不会一律当成没人直播。
    /// `ignoreCache` 用于手动刷新。15 秒内的缓存只有主播信息，没有播放地址。
    func followLiveResult(ignoreCache: Bool = false) async -> DYFollowLiveResult {
        let generation = followSessionCache.generation
        if !ignoreCache, let cached = followSessionCache.cachedItems(now: Date()) {
            let rooms = DYFollowLiveIdentity.unique(cached.map { DYLiveRoom($0) }, id: \.id, webRid: \.webRid)
            DYLiveModel.log("DDFOLLOWLIVE outcome=rooms source=cache n=\(rooms.count) listRequests=0 detailRequests=0")
            return DYFollowLiveResult(kind: .rooms, items: rooms, status: 200, stats: nil, fromCache: true)
        }
        let joining = followSessionCache.beginList(generation: generation)
        let epoch = followSessionCache.listEpoch
        if joining, let followLiveTask {
            let result = await followLiveTask.value
            return scopedFollowResult(result, generation: generation, epoch: epoch)
        }
        followLiveTicket += 1
        let ticket = followLiveTicket
        let task = Task { await self.performFollowLive(generation: generation, epoch: epoch) }
        followLiveTask = task
        let result = await task.value
        if followLiveTicket == ticket {
            followLiveTask = nil
            followSessionCache.finishList(generation: generation)
        }
        return scopedFollowResult(result, generation: generation, epoch: epoch)
    }

    /// 只解析当前这一间。已有可播地址时不再请求。同一个 webRid、同一代际的进行中请求会合并。
    func resolveFollowRoom(webRid: String) async -> DYFollowLiveResult {
        let generation = followSessionCache.generation
        let epoch = followSessionCache.listEpoch
        let result: DYFollowLiveResult
        if followSessionCache.beginRoom(webRid: webRid), let current = followRoomTask, current.rid == webRid {
            result = await current.task.value
        } else {
            followRoomTicket += 1
            let ticket = followRoomTicket
            let task = Task { await self.performFollowRoom(webRid) }
            followRoomTask = (webRid, ticket, task)
            result = await task.value
            if followRoomTask?.ticket == ticket {
                followRoomTask = nil
                followSessionCache.finishRoom(webRid: webRid, generation: generation)
            }
        }
        if result.kind == .notLoggedIn {
            followSessionCache.noteNotLoggedIn(generation: generation, epoch: epoch)
        }
        return scopedFollowResult(result, generation: generation, epoch: epoch)
    }

    private var followLiveTask: Task<DYFollowLiveResult, Never>?
    private var followLiveTicket = 0
    private var followSessionCache = DYFollowSessionCache(ttl: 15)
    private var followRoomTask: (rid: String, ticket: Int, task: Task<DYFollowLiveResult, Never>)?
    private var followRoomTicket = 0

    private func scopedFollowResult(_ result: DYFollowLiveResult, generation: Int, epoch: Int) -> DYFollowLiveResult {
        if result.kind == .notLoggedIn, followSessionCache.generation == generation, followSessionCache.listEpoch == epoch {
            var visible = result
            visible.items = []
            visible.stale = false
            return visible
        }
        guard followSessionCache.accepts(generation: generation, epoch: epoch) else {
            var hidden = result
            hidden.items = []
            hidden.stale = true
            return hidden
        }
        return result
    }

    private func performFollowLive(generation: Int, epoch: Int) async -> DYFollowLiveResult {
        let started = ProcessInfo.processInfo.systemUptime
        let data: Data
        do { data = try await call(DYFollowLiveScripts.list, args: [:], attempts: 2) }
        catch {
            DYLiveModel.log("DDFOLLOWLIVE outcome=request_failed listRequests=1 detailRequests=0 elapsed=\(Self.elapsed(since: started))")
            return DYFollowLiveResult(kind: .requestFailed, items: [], status: -1, stats: nil)
        }
        do {
            let page = try JSONDecoder().decode(DYFollowLivePayload.self, from: data)
            let items = DYFollowLiveIdentity.unique(page.items, id: \.id, webRid: \.webRid)
            let kind = DYFollowLiveClassify.kind(status: page.status, itemCount: items.count, stats: page.stats)
            let stats = page.stats
            if kind == .rooms, !items.isEmpty {
                followSessionCache.store(items: items.map(\.followMetadata), generation: generation, epoch: epoch, now: Date())
            } else if kind == .notLoggedIn {
                followSessionCache.noteNotLoggedIn(generation: generation, epoch: epoch)
            }
            DYLiveModel.log("DDFOLLOWLIVE outcome=\(kind.rawValue) status=\(page.status) http=\(stats?.http ?? -1) code=\(stats?.code.map(String.init) ?? "-") list=\(stats?.list ?? -1) kept=\(items.count) dropped=\(stats?.dropped ?? -1) listRequests=1 detailRequests=0 elapsed=\(Self.elapsed(since: started))")
            return DYFollowLiveResult(kind: kind, items: kind == .rooms ? items : [], status: page.status, stats: stats)
        } catch {
            DYLiveModel.log("DDFOLLOWLIVE outcome=decode_failed listRequests=1 detailRequests=0 elapsed=\(Self.elapsed(since: started))")
            return DYFollowLiveResult(kind: .decodeFailed, items: [], status: -1, stats: nil)
        }
    }

    private func performFollowRoom(_ webRid: String) async -> DYFollowLiveResult {
        let started = ProcessInfo.processInfo.systemUptime
        let data: Data
        do { data = try await call(DYFollowLiveScripts.room, args: ["rid": webRid], attempts: 1) }
        catch {
            DYLiveModel.log("DDFOLLOWROOM outcome=request_failed detailRequests=1 elapsed=\(Self.elapsed(since: started))")
            return DYFollowLiveResult(kind: .requestFailed, items: [], status: -1, stats: nil)
        }
        do {
            let page = try JSONDecoder().decode(DYFollowLivePayload.self, from: data)
            let decoded = DYFollowLiveClassify.kind(status: page.status, itemCount: page.items.count, stats: page.stats)
            let playable = page.items.filter { !$0.liveStreams.isEmpty }
            let kind: DYFollowLiveKind = decoded == .rooms && playable.isEmpty ? .filtered : decoded
            DYLiveModel.log("DDFOLLOWROOM outcome=\(kind.rawValue) status=\(page.status) detailRequests=1 elapsed=\(Self.elapsed(since: started))")
            return DYFollowLiveResult(kind: kind, items: kind == .rooms ? playable : [], status: page.status, stats: page.stats)
        } catch {
            DYLiveModel.log("DDFOLLOWROOM outcome=decode_failed detailRequests=1 elapsed=\(Self.elapsed(since: started))")
            return DYFollowLiveResult(kind: .decodeFailed, items: [], status: -1, stats: nil)
        }
    }

    private static func elapsed(since started: TimeInterval) -> String {
        String(format: "%.3f", ProcessInfo.processInfo.systemUptime - started)
    }

    func fetchLive(reset: Bool, zone: DYLiveZone? = nil) async throws -> [DYLiveRoom] {
        if reset { liveMaxTime = "0"; liveOffset = 0; liveCursorGeneration = UUID() }
        let generation = liveCursorGeneration
        if let zone {
            let d = try await callLive(Self.zoneJS, args: ["partition": zone.id, "ptype": zone.type, "offset": String(liveOffset)])
            guard liveCursorGeneration == generation else { return [] }
            let p = try JSONDecoder().decode(DYLiveResp.self, from: d)
            guard p.status == 200 else {
                throw DYError.bad("专区连接失败（HTTP \(p.status)），可打开网页版检查或返回推荐直播")
            }
            liveOffset += 15
            return p.items
        }
        let d = try await call(Self.liveJS, args: ["maxtime": liveMaxTime])
        guard liveCursorGeneration == generation else { return [] }
        let p = try JSONDecoder().decode(DYLiveResp.self, from: d)
        guard p.status == 200 else { throw DYError.blocked("HTTP \(p.status)") }
        liveMaxTime = String(Int(Date().timeIntervalSince1970))
        return p.items
    }

    // 直播专区（网页版 live.douyin.com/categorynew/4_103_1_<id> 同一接口）：一页 15 个，按 offset 翻页
    private static let zoneJS = #"""
    const P = { aid: '6383', app_name: 'douyin_web', live_id: '1', device_platform: 'web', language: 'zh-CN', enter_from: 'page_refresh',
      cookie_enabled: 'true', screen_width: '1440', screen_height: '900', browser_language: 'zh-CN', browser_platform: 'MacIntel',
      browser_name: 'Safari', browser_version: '26.0', os_name: 'Mac OS', os_version: '10.15.7',
      count: '15', offset: offset, partition: partition, partition_type: ptype, req_from: '2' };
    const r = await req('GET', 'https://live.douyin.com/webcast/web/partition/detail/room/v2/?' + new URLSearchParams(P).toString());
    const d = parse(r.t);
    const arr = d && d.data && Array.isArray(d.data.data) ? d.data.data : null;
    if (!arr) return JSON.stringify({ status: r.s === 200 ? 403 : r.s, items: [] });
    const items = arr.filter(it => it && it.room && it.room.stream_url).map(it => {
      const room = it.room, su = room.stream_url || {}, o = room.owner || {};
      return { id: String(room.id_str || room.id), webRid: String(it.web_rid || o.web_rid || ''), title: room.title || '',
        owner: o.nickname || '', avatar: first(o.avatar_thumb), cover: first(room.cover),
        viewers: (room.stats && room.stats.user_count_str) || room.user_count_str || (room.user_count ? String(room.user_count) : ''),
        hls: su.hls_pull_url_map || {}, flv: compatibleLiveFLV(su), portrait: su.stream_orientation !== 2, def: su.default_resolution || null };
    }).filter(x => Object.keys(x.hls).length > 0 || Object.keys(x.flv).length > 0);
    return JSON.stringify({ status: r.s, items });
    """#

    // 直播推荐：live.douyin.com/webcast/feed/（跨子域 XHR 同样被页面 SDK 签名，实测 200 / 20 条）
    private static let liveJS = #"""
    const P = { aid: '6383', app_name: 'douyin_web', live_id: '1', device_platform: 'web', language: 'zh-CN', enter_from: 'link_share',
      cookie_enabled: 'true', screen_width: '1440', screen_height: '900', browser_language: 'zh-CN', browser_platform: 'MacIntel',
      browser_name: 'Safari', browser_version: '26.0', os_name: 'Mac OS', os_version: '10.15.7', channel: 'channel_pc_web',
      request_tag_from: 'web', need_map: '1', liveid: '1', is_draw: '1', inner_from_drawer: '0', custom_count: '20',
      action: 'load_more', action_type: 'loadmore', enter_source: 'web_homepage_hot_web_live_card',
      source_key: 'web_homepage_hot_web_live_card', is_ssr: 'true', maxtime: maxtime };
    const r = await req('GET', 'https://live.douyin.com/webcast/feed/?' + new URLSearchParams(P).toString());
    const d = parse(r.t);
    if (!d || !Array.isArray(d.data)) return JSON.stringify({ status: r.s === 200 ? 403 : r.s, items: [] });
    const items = d.data.filter(it => it && it.type === 1 && it.data && it.data.stream_url).map(it => {
      const room = it.data, su = room.stream_url || {}, o = room.owner || {};
      return { id: String(room.id_str || room.id), webRid: String(it.web_rid || o.web_rid || ''), title: room.title || '',
        owner: o.nickname || '', avatar: first(o.avatar_thumb), cover: first(room.cover),
        viewers: (room.stats && room.stats.user_count_str) || room.user_count_str || '',
        hls: su.hls_pull_url_map || {}, flv: compatibleLiveFLV(su), portrait: su.stream_orientation !== 2, def: su.default_resolution || null };
    }).filter(x => Object.keys(x.hls).length > 0 || Object.keys(x.flv).length > 0);
    return JSON.stringify({ status: r.s, items });
    """#

    private static let diggJS = #"""
    const P = Object.assign({}, base, { aweme_id: id, type: type, item_type: '0' });
    const u = '/aweme/v1/web/commit/item/digg/?' + new URLSearchParams(P).toString();
    const r = await req('POST', u, '');
    const d = parse(r.t) || {};
    return JSON.stringify({ status: r.s, statusCode: d.status_code, msg: d.status_msg || (r.s === 200 ? '' : r.t.slice(0, 120)) });
    """#

    private static let dislikeJS = #"""
    const r = await req('POST', '/aweme/v1/web/commit/dislike/item/?' + q({ aweme_id: id }),
      new URLSearchParams({ aweme_id: id }).toString());
    const d = parse(r.t) || {};
    return JSON.stringify({ status: r.s, statusCode: d.status_code, msg: d.status_msg || (r.s === 200 ? '' : (r.t || '').slice(0, 120)) });
    """#

    private static let favJS = #"""
    const P = Object.assign({}, base, { aweme_id: id, action: action });
    const tries = ['/aweme/v1/web/commit/item/collect/', '/aweme/v1/web/aweme/collect/'];
    let last = { status: -1 };
    for (const u of tries) {
      const r = await req('POST', u + '?' + new URLSearchParams(P).toString(), '');
      const d = parse(r.t) || {};
      if (r.s === 200 && (d.status_code === 0 || d.status_code === undefined)) return JSON.stringify({ status: 200, statusCode: 0 });
      last = { status: r.s, statusCode: d.status_code, msg: (d.status_msg || r.t.slice(0, 120)) };
    }
    return JSON.stringify(last);
    """#

    /// SDK 就绪后清空隐藏页：停媒体、清 body 与样式表，之后新增元素（脚本除外）也移除。
    /// 清空后签名请求照常（热搜、观看上报、作品列表都验证过）。
    private static let quietPageJS = #"""
    (() => { try {
      document.querySelectorAll('video,audio').forEach(v => { try { v.pause(); v.removeAttribute('src'); v.load(); } catch (e) {} });
      if (document.body) {
        document.body.replaceChildren();
        new MutationObserver(ms => ms.forEach(m => m.addedNodes.forEach(n => { if (n.nodeType === 1 && n.tagName !== 'SCRIPT') n.remove(); })))
          .observe(document.body, { childList: true });
      }
      document.querySelectorAll('style,link[rel=stylesheet]').forEach(e => e.remove());
      return 'quiet';
    } catch (e) { return 'err ' + e; } })()
    """#

    private static let loginJS = #"""
    return (document.cookie || '').includes('sessionid') ? 'sessionid' : '0';
    """#

    // 共用：在页面世界里发 XHR（被抖音 SDK hook，自动加签名）
    static let requestJS = #"""
    // VLCKit 3 能播 AVC-FLV，但部分 HEVC-FLV 会一直等首帧；先读网页 SDK 明确给出的编码，不能盲试 6 秒。
    const compatibleLiveFLV = su => {
      const raw = su.live_core_sdk_data && su.live_core_sdk_data.pull_data && su.live_core_sdk_data.pull_data.stream_data;
      const sdk = typeof raw === 'string' ? parse(raw) : raw;
      const streams = [];
      for (const [name, group] of Object.entries((sdk && sdk.data) || {})) {
        if (name === 'ao') continue; // ao 是纯音频，不能拿它的 h264 标记判定同路径视频流。
        for (const stream of Object.values(group || {})) {
          if (!stream || !stream.flv || stream.enableEncryption) continue;
          const params = typeof stream.sdk_params === 'string' ? parse(stream.sdk_params) : stream.sdk_params;
          const codec = String((params && params.VCodec) || '').toLowerCase();
          if ((codec === 'h264' || codec === 'avc') && Number(params.vbitrate) > 0) streams.push(stream.flv);
        }
      }
      const urls = new Set(streams);
      return Object.fromEntries(Object.entries(su.flv_pull_url || {}).filter(([_, u]) => urls.has(u)));
    };
    const req = (method, path, body) => new Promise(ok => {
      const x = new XMLHttpRequest();
      let done = false;
      const fin = r => { if (!done) { done = true; ok(r) } };
      x.timeout = 12000;
      x.ontimeout = () => fin({ s: -2, t: '' });
      // 硬超时：页面安全 SDK 会接管 XHR，部分接口它压着不放、x.timeout 也不触发 → Promise 永远挂死
      setTimeout(() => { try { x.abort() } catch (e) {} fin({ s: -3, t: '' }) }, 14000);
      x.open(method, path); x.withCredentials = true;
      x.setRequestHeader('Accept', 'application/json, text/plain, */*');
      if (method === 'POST') x.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded; charset=UTF-8');
      x.onload = () => fin({ s: x.status, t: x.responseText }); x.onerror = () => fin({ s: -1, t: '' });
      x.send(body || null);
    });
    const base = { device_platform: 'webapp', aid: '6383', channel: 'channel_pc_web', pc_client_type: '1', pc_libra_divert: 'Mac',
      update_version_code: '170400', support_h265: '1', support_dash: '0', version_code: '170400', version_name: '17.4.0',
      cookie_enabled: 'true', screen_width: '1440', screen_height: '900', browser_language: 'zh-CN', browser_platform: 'MacIntel',
      browser_name: 'Safari', browser_version: '26.0', browser_online: 'true', engine_name: 'WebKit', engine_version: '605.1.15',
      os_name: 'Mac OS', os_version: '10.15.7', cpu_core_num: '8', device_memory: '8', platform: 'PC', downlink: '10',
      effective_type: '4g', round_trip_time: '50' };
    const parse = t => { try { return JSON.parse(t) } catch (e) { return null } };
    const first = o => (o && o.url_list && o.url_list[0]) || null;
    const q = s => new URLSearchParams(Object.assign({}, base, s)).toString();
    // 直连 CDN（douyinvod）优先：实测首字节 0.27–0.30s；www.douyin.com/aweme/v1/play/ 多跳一次 0.95–1.85s
    const pickPlay = l => (l || []).find(u => !u.includes('/aweme/v1/play/')) || (l && l[0]) || null;
    const pickRedirect = l => (l || []).find(u => u.includes('/aweme/v1/play/')) || null;
    // 清晰度：按「有效码率」挑最高一档（H.265 同码率约等于 H.264 的 1.4 倍），跳过弱网档
    const resOf = r => {
      const pa = r.play_addr || {}, w = pa.width || 0, h = pa.height || 0;
      if (w && h) return Math.min(w, h);
      const m = /_(\d{3,4})_/.exec(r.gear_name || ''); return m ? +m[1] : 0;
    };
    const bestRate = v => {
      const rs = (v.bit_rate || []).filter(r => r && r.play_addr && r.play_addr.url_list && r.play_addr.url_list.length)
        .filter(r => !/adapt_lowest|lower/i.test(r.gear_name || ''));
      rs.sort((a, b) => ((b.bit_rate || 0) * (b.is_h265 ? 1.4 : 1)) - ((a.bit_rate || 0) * (a.is_h265 ? 1.4 : 1)));
      return rs[0] || null;
    };
    const fastRate = v => {
      const rs = (v.bit_rate || []).filter(r => r && r.play_addr && r.play_addr.url_list && r.play_addr.url_list.length && resOf(r) >= 540);
      rs.sort((a, b) => (a.bit_rate || 0) - (b.bit_rate || 0));
      return rs[0] || null;
    };
    // 抖音作品 → 精简结构（推荐 / 关注 / 搜索 / 喜欢 / 收藏 / 历史 / 作品 共用）
    const mapA = a => {
      const v = a.video || {}, urls = (v.play_addr && v.play_addr.url_list) || [];
      const st = a.statistics || {};
      const def = pickPlay(urls), br = bestRate(v), best = br ? pickPlay(br.play_addr.url_list) : null;
      const fr = fastRate(v), fast = fr ? pickPlay(fr.play_addr.url_list) : null;
      const pd = v.play_addr || {};
      return {
        id: String(a.aweme_id), desc: a.desc || '', width: v.width || 0, height: v.height || 0, duration: (v.duration || 0) / 1000,
        play: best || def,
        playAlt: pickRedirect(br ? br.play_addr.url_list : urls) || (best && def && best !== def ? def : null),
        playFast: fast && fast !== (best || def) ? fast : null,
        q: (br ? (br.gear_name || '?') + ' ' + resOf(br) + 'p h265=' + (br.is_h265 ? 1 : 0) + ' ' + Math.round((br.bit_rate || 0) / 1000) + 'k' : 'nolist')
          + ' | def ' + (pd.width || 0) + 'x' + (pd.height || 0) + ' | gears ' + (v.bit_rate || []).map(r => (r.gear_name || '?') + ':' + Math.round((r.bit_rate || 0) / 1000) + 'k' + (r.is_h265 ? 'h' : '')).join(','),
        cover: first(v.cover) || first(v.origin_cover) || (a.images && a.images[0] && first(a.images[0])) || null,
        images: (a.images || []).map(i => first(i)).filter(Boolean),
        author: { name: (a.author && a.author.nickname) || '', avatar: a.author && first(a.author.avatar_thumb), secUid: a.author && a.author.sec_uid, uid: a.author && a.author.uid ? String(a.author.uid) : null, follow: a.author ? (a.author.follow_status || 0) : 0 },
        awemeType: a.aweme_type || 0,
        publishedAt: typeof a.create_time === 'number' && Number.isFinite(a.create_time) && a.create_time > 0 ? a.create_time : null,
        aiDeclaration: a.risk_infos && typeof a.risk_infos.content === 'string' && /(?:\bAI\b|人工智能)/i.test(a.risk_infos.content) ? (a.risk_infos.content.trim() || null) : null,
        stats: { digg: st.digg_count || 0, comment: st.comment_count || 0, collect: st.collect_count || 0, share: st.share_count || 0, play: st.play_count == null ? null : Number(st.play_count) },
        music: (a.music && a.music.title) || '',
        userDigged: a.user_digged ? 1 : 0,
        isCollect: (a.is_collect || a.is_collected || (a.collect_stat === 1)) ? 1 : 0
      };
    };
    """#

    private static let feedJS = #"""
    const P = Object.assign({}, base, { module_id: '3003101', count: '20', screen_width: '430', screen_height: '932', filterGids: '', presented_ids: '', refresh_index: refresh,
      refer_id: '', refer_type: '10', pull_type: pull,
      awemePcRecRawData: JSON.stringify({ is_xigua_user: 0, danmaku_switch_status: 0, is_client: false }),
      'Seo-Flag': '0', install_time: install, tag_id: '', active_id: '', is_active_tab: 'false', use_lite_type: '0',
      xigua_user: '0', is_out_feed: '1', enable_ad: '1' });
    const r = await req('POST', '/aweme/v2/web/module/feed/?' + new URLSearchParams(P).toString(), '');
    const d = parse(r.t);
    if (!d) return JSON.stringify({ status: r.s, items: [], hasMore: false, msg: (r.t || '').replace(/[^\u4e00-\u9fa5A-Za-z0-9 ]/g, '').slice(-20) });
    const items = (d.aweme_list || []).filter(a => a && a.video && !a.is_ads && !(a.raw_ad_data)).map(mapA);
    return JSON.stringify({ status: r.s, items, hasMore: !!d.has_more, msg: d.status_msg || null });
    """#

    private static let watchJS = #"""
    const s = await req('POST', '/aweme/v2/web/aweme/stats/?' + q({}),
      new URLSearchParams({ aweme_type: type, item_id: id, source: '0', play_delta: '1' }).toString());
    const ds = parse(s.t) || {};
    let h = { s: 0 }, dh = {};
    if (author) {
      h = await req('POST', '/aweme/v1/web/history/write/?' + q({}),
        new URLSearchParams({ aweme_id: id, author_id: author, pre_item_seen: seen, pre_item_id: pre }).toString());
      dh = parse(h.t) || {};
    }
    return JSON.stringify({ stats: [s.s, ds.status_code], history: [h.s, dh.status_code] });
    """#

    private static let commentJS = #"""
    const P = Object.assign({}, base, { aweme_id: id, cursor: cursor, count: '20', item_type: '0', whale_cut_token: '', cut_version: '1', rcFT: '' });
    if (ins) P.insert_ids = ins;
    const r = await req('GET', '/aweme/v1/web/comment/list/?' + new URLSearchParams(P).toString());
    const d = parse(r.t);
    if (!d) return JSON.stringify({ status: r.s, items: [], cursor: 0, hasMore: false, total: 0, msg: 'blocked' });
    const ddImg = o => { const u = o && o.url_list && o.url_list[0]; return u ? { u, w: o.width || 0, h: o.height || 0 } : null; };
    const ddImages = c => (c.image_list || []).map(x => {
      const m = ddImg(x.medium_url) || ddImg(x.thumb_url) || ddImg(x.crop_url) || ddImg(x.origin_url);
      const o = ddImg(x.origin_url) || m;
      return m ? { thumb: m.u, full: o.u, w: o.w || m.w, h: o.h || m.h } : null;
    }).filter(Boolean);
    const ddSticker = c => {
      const s = c.sticker; if (!s) return null;
      const st = ddImg(s.static_url) || ddImg(s.animate_url); if (!st) return null;
      const an = ddImg(s.animate_url) || st;
      return { thumb: st.u, full: an.u, w: s.width || st.w, h: s.height || st.h };
    };
    const one = c => ({
      id: String(c.cid), text: c.text || '', name: (c.user && c.user.nickname) || '', avatar: c.user && first(c.user.avatar_thumb),
      digg: c.digg_count || 0, time: c.create_time || 0, replies: c.reply_comment_total || 0, ip: c.ip_label || null, userDigged: c.user_digged ? 1 : 0,
      images: ddImages(c), sticker: ddSticker(c),
      parent: (c.reply_id && String(c.reply_id) !== '0') ? String(c.reply_id) : null
    });
    // insert_ids 定位楼中楼时，那条回复挂在一级评论的 reply_comment 里
    const items = (d.comments || []).map(c => Object.assign(one(c), (ins && c.reply_comment && c.reply_comment.length) ? { pinned: c.reply_comment.map(r => Object.assign(one(r), { replies: 0 })) } : {}));
    return JSON.stringify({ status: r.s, items, cursor: d.cursor || 0, hasMore: !!d.has_more, total: d.total || 0, msg: null });
    """#
}

/// 隐藏网页要挂进窗口里，JS 定时器 / 网络才不被系统节流
private struct DouyinBridgeHost: UIViewRepresentable {
    let bridge: DouyinBridge
    func makeUIView(context: Context) -> UIView {
        let v = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        v.isUserInteractionEnabled = false
        v.accessibilityElementsHidden = true
        v.alpha = 0.01
        v.clipsToBounds = true
        bridge.web.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        v.addSubview(bridge.web)
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

private struct DYPlayerLayerView: UIViewRepresentable {
    let player: AVPlayer?
    let gravity: AVLayerVideoGravity
    /// 首帧出来前透明（露出封面），出来后填底色盖住封面——封面是 4:3 裁图，和视频比例不一致
    let readyFill: UIColor
    final class V: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var pl: AVPlayerLayer { layer as! AVPlayerLayer }
        var fill: UIColor = .clear
        private var obs: NSKeyValueObservation?
        func watch() {
            obs = pl.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] l, _ in
                let ready = l.isReadyForDisplay
                DispatchQueue.main.async { self?.backgroundColor = ready ? self?.fill : .clear }
            }
        }
    }
    func makeUIView(context: Context) -> V {
        let v = V(); v.isUserInteractionEnabled = false; v.fill = readyFill; v.watch(); return v
    }
    func updateUIView(_ v: V, context: Context) {
        v.fill = readyFill
        if v.pl.player !== player { v.pl.player = player }
        if v.pl.videoGravity != gravity { v.pl.videoGravity = gravity }
    }
}

// MARK: - 预加载（抖音同款：提前缓冲后面几条）

/// 当前条后面 N 条提前建好 AVPlayer 并缓冲开头几秒（不出声、不播放），滑到时页面直接接管 → 秒开。
/// 封面同时预取。窗口外的立即释放（硬解码会话有限，不能无限开）。
@MainActor
final class DYPreloader {
    static let ahead = 3   // 提前暖 3 条；微热降到 2、烫了 1
    private var players: [String: AVPlayer] = [:]
    private var handedOut: Set<String> = []
    private var obs: [String: NSKeyValueObservation] = [:]
    #if DEBUG
    var disabled = ProcessInfo.processInfo.environment["WUWEI_DEBUG_DOUYIN_NOPRELOAD"] == "1"
    #else
    let disabled = false
    #endif

    func update(_ items: [DYAweme], current index: Int) {
        guard !disabled, items.indices.contains(index) else { return }
        let th = ProcessInfo.processInfo.thermalState
        let ahead = th == .nominal ? Self.ahead : (th == .fair ? 2 : 1)
        let lo = index + 1, hi = min(items.count - 1, index + ahead)
        let window = lo <= hi ? Array(items[lo...hi]) : []
        let ids = Set(window.map(\.id))
        // 离开窗口的：释放没被领走的；已领走的只要离当前 ≥2 条就不再记账（页面已经销毁）
        for (id, p) in players where !ids.contains(id) { release(id, p) }
        let near = Set(items[max(0, index - 1)...min(items.count - 1, index + 1)].map(\.id))
        handedOut = handedOut.filter { near.contains($0) || ids.contains($0) }
        for a in window where players[a.id] == nil && !handedOut.contains(a.id) {
            guard a.images.isEmpty, let s = a.play, let url = URL(string: s) else {
                if let c = a.images.first.flatMap(URL.init(string:)) { Task { _ = await ImageCache.shared.load(c) } }
                continue
            }
            let item = AVPlayerItem(asset: DYMedia.asset(DYVideoCache.localURL(a.id) ?? url))
            item.preferredForwardBufferDuration = 6
            let p = AVPlayer(playerItem: item)
            p.isMuted = true
            p.automaticallyWaitsToMinimizeStalling = true
            players[a.id] = p
            // ready 后 preroll：把开头的数据和首帧解码好
            obs[a.id] = item.observe(\.status, options: [.new]) { [weak p] it, _ in
                guard it.status == .readyToPlay else { return }
                DispatchQueue.main.async { p?.preroll(atRate: 1) { _ in } }
            }
            if let c = a.cover.flatMap(URL.init(string:)) { Task { _ = await ImageCache.shared.load(c) } }
        }
    }

    /// 页面起播时来领；领走后由页面负责释放
    func take(_ id: String) -> AVPlayer? {
        guard let p = players.removeValue(forKey: id) else { return nil }
        obs.removeValue(forKey: id)?.invalidate()
        handedOut.insert(id)
        p.isMuted = false
        return p
    }

    func clear() {
        for (id, p) in players { release(id, p) }
        handedOut.removeAll()
    }

    private func release(_ id: String, _ p: AVPlayer) {
        obs.removeValue(forKey: id)?.invalidate()
        p.pause()
        p.replaceCurrentItem(with: nil)
        players[id] = nil
    }
}

// MARK: - 推荐流

@MainActor
final class DYFeedModel: ObservableObject {
    @Published var items: [DYAweme] = []
    @Published var error: String?
    @Published var loading = false
    @Published var liked: Set<String> = []
    @Published var collected: Set<String> = []
    @Published var toast: String?
    /// 是否已登录抖音（登录后推荐流才按账号个性化，点赞/收藏才能进账号）
    @Published var isLoggedIn = false
    private var hasMore = true

    /// 推荐方向固定目标由 targetRatio 给出，不读取旧版方向偏好。
    /// 候选池保留暂未排入的素材；素材不足仍允许放宽，横屏限定除外。
    /// 竖屏播放时「短视频」的目标占比（0–100）
    @AppStorage("douyin_short_ratio_portrait_v1") var shortRatioPortrait = 70
    /// 横屏播放时「短视频」的目标占比（0–100）
    @AppStorage("douyin_short_ratio_landscape_v1") var shortRatioLandscape = 70
    /// 横着看（屏幕/播放区比高宽）时只放横屏视频
    @AppStorage("douyin_wide_landscape_v1") var landscapeWhenWide = true
    /// 视频比屏幕窄（左右黑边）时自动放大铺满宽度；菜单里可关
    @AppStorage("douyin_autofit_v1") var autoFit = true
    /// 当前播放区是不是横的（宽 > 高），由页面布局同步
    var screenWide = false
    /// 候选池：拉到了但按比例暂时没排进列表的（保持推荐原顺序），以及启动时本地已缓存没看过的
    var pool: [DYAweme] = []
    static let poolCap = 80
    private var mixCredit: Double = 0
    private var shortCredit: Double = 0
    /// 短视频判定：3 分钟内（网页推荐里 60 秒内的几乎为 0，用 3 分钟才凑得出占比）
    static func isShort(_ a: DYAweme) -> Bool { a.duration > 0 && a.duration <= 180 }

    static func isPortrait(_ a: DYAweme) -> Bool { !a.images.isEmpty || a.isTallFrame }

    /// 固定竖屏目标；横屏限定优先，不依赖任何历史方向偏好或迁移。
    var targetRatio: Double? {
        screenWide && landscapeWhenWide ? 0 : 0.7
    }

    /// 从候选池按比例往列表里排最多 maxN 条；relaxed = 比例凑不齐时也照原顺序放（别让列表断粮）
    @discardableResult
    func fill(_ maxN: Int, relaxed: Bool = false) -> Int {
        var n = 0
        while n < maxN, !pool.isEmpty {
            var idx: Int?
            var wantPortrait: Bool?
            if let r = targetRatio, !relaxed || r == 0 {
                // 均匀穿插（类似 Bresenham）：每条攒 r 份「竖屏额度」，满 1 份就放竖屏，例如 70% → 竖横竖竖横竖竖…
                wantPortrait = r >= 1 ? true : r <= 0 ? false : (mixCredit + r >= 1)
                idx = pickIndex(wantPortrait: wantPortrait!, wantShort: wantedShort())
            } else {
                idx = 0
            }
            guard let i = idx else { break }
            let a = pool.remove(at: i)
            items.append(a)
            if let r = targetRatio, r > 0, r < 1 {
                mixCredit = (mixCredit + r - (Self.isPortrait(a) ? 1 : 0)).clamped(-1, 1)
            }
            let pct = screenWide ? shortRatioLandscape : shortRatioPortrait
            if pct > 0, pct < 100 {
                let sr = Double(pct) / 100
                shortCredit = (shortCredit + sr - (Self.isShort(a) ? 1 : 0)).clamped(-1, 1)
            }
            n += 1
        }
        return n
    }

    /// 竖屏优先短视频、横屏优先长视频：只在同方向的候选里、前 8 条内挑，
    /// 不会把推荐顺序整体打乱（网页推荐里 60 秒以下几乎没有，竖屏也常是中长视频）。
    /// 当前方向下这一条要不要短视频（按设置比例均匀穿插）
    private func wantedShort() -> Bool? {
        let pct = screenWide ? shortRatioLandscape : shortRatioPortrait
        guard pct >= 0, pct <= 100 else { return nil }
        if pct >= 100 { return true }
        if pct <= 0 { return false }
        let r = Double(pct) / 100
        return shortCredit + r >= 1
    }

    private func pickIndex(wantPortrait: Bool, wantShort: Bool?) -> Int? {
        let matches = pool.indices.filter { Self.isPortrait(pool[$0]) == wantPortrait }
        guard let first = matches.first else { return nil }
        if let wantShort {
            // 先找「方向 + 长短」都符合的；凑不到就退到只按方向挑（别让列表断粮）
            let window = Array(matches.prefix(24))
            if let i = window.first(where: { Self.isShort(pool[$0]) == wantShort }) { return i }
            return first
        }
        return first
    }

    /// 方向 / 比例变了：当前条之后的重新按比例排（当前这条不动，不打断播放）
    func remix(after index: Int?) {
        let keep = (index ?? -1) + 1
        guard keep <= items.count else { return }
        let upcoming = Array(items[keep...])
        items.removeSubrange(keep...)
        pool = upcoming + pool
        mixCredit = 0
        shortCredit = 0
        fill(max(upcoming.count, 6))
        trimPool()
    }

    /// 启动时把本地已缓存、没看过、又不在列表里的放到候选池最前（秒开）
    func seedPool(_ cached: [DYAweme]) {
        let have = Set(items.map(\.id)).union(pool.map(\.id))
        pool = cached.filter { !have.contains($0.id) } + pool
    }

    private func trimPool() {
        // 超上限先丢多出来的那一类里最早的（网页推荐横屏多，通常丢横屏）
        while pool.count > Self.poolCap {
            let wantPortrait = (targetRatio ?? 0.5) >= 0.5
            if let i = pool.firstIndex(where: { Self.isPortrait($0) != wantPortrait }) { pool.remove(at: i) }
            else { pool.removeFirst() }
        }
    }

    func loadMore(_ bridge: DouyinBridge) async {
        guard !loading, hasMore || items.isEmpty || !pool.isEmpty else { return }
        loading = true
        defer { loading = false }
        let want = 6
        var added = fill(want)
        do {
            var pages = 0
            while added < want && pages < 8 && (hasMore || items.isEmpty) {
                let r = try await bridge.fetchFeed()
                pages += 1
                let seen = Set(items.map(\.id)).union(pool.map(\.id))
                let fresh = r.items.filter { a in !seen.contains(a.id) && (a.play != nil || !a.images.isEmpty) }
                // 账号里已点赞/已收藏的，进页面就是选中态
                for a in fresh {
                    if a.userDigged == 1 { liked.insert(a.id) }
                    if a.isCollect == 1 { collected.insert(a.id) }
                }
                pool.append(contentsOf: fresh)
                hasMore = r.hasMore || !r.items.isEmpty
                added += fill(want - added)
            }
            // 素材不足时放宽固定目标，但不放宽横屏限定。
            if added == 0, let r = targetRatio, r > 0, r < 1 { added += fill(want, relaxed: true) }
            trimPool()
            DYLiveModel.log("DDMIX added=\(added) pool=\(pool.count) ratio=\(targetRatio.map { String(format: "%.2f", $0) } ?? "free") wide=\(screenWide) recent=\(items.suffix(20).filter(Self.isPortrait).count)/\(min(20, items.count))")
            error = (items.isEmpty && added == 0) ? "暂时没刷到推荐，登录后或稍后再试" : nil
        } catch {
            if items.isEmpty { self.error = error.localizedDescription }
        }
    }

    func reset() { items = []; hasMore = true; error = nil; pool = []; mixCredit = 0; shortCredit = 0 }
}

private struct DYTopChromeFrameKey: PreferenceKey {
    static var defaultValue: CGRect { .zero }
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next.maxY > value.maxY { value = next }
    }
}

struct DouyinFeedScreen: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dismiss) private var dismiss
    @StateObject private var bridge = DouyinBridge()
    @StateObject private var feed = DYFeedModel()
    @State private var insets = EdgeInsets()
    @State private var preloader = DYPreloader()
    @State private var resume: [String: Double] = [:]
    @State private var currentID: String?
    @State private var scrollID: String?
    @State private var userScrolling = false
    @State private var dragStartID: String?
    @State private var scrollEndTask: Task<Void, Never>?
    @State private var initialized = false
    @State private var refreshing = false
    @State private var showComments = false
    @State private var web: DYWebTarget?
    @State private var tab: DYTab = {
        let e = ProcessInfo.processInfo.environment
        if e["DOUDUO_STARTLIVE"] == "1" { return .live }
        if e["DOUDUO_STARTFOLLOW"] == "1" { return .follow }
        return .recommend
    }()
    @StateObject private var live = DYLiveModel()
    @State private var showSearch = false
    @State private var lastFeedPull = Date.distantPast
    @AppStorage(DYVideoCache.countKey) private var cacheCount = DYVideoCache.defaultCount
    @State private var showMine = false
    /// 顶栏「我的」按钮用的账号头像
    @State private var myUser: DYUser?
    @State private var authorTarget: DYAweme.Author?
    @Environment(\.horizontalSizeClass) private var hSize
    @AppStorage("douyin_autoplay_v1") private var autoNext = false
    @AppStorage("douyin_muted_v1") private var muted = false
    @State private var pendingUpdate: DDUpdate?
    @State private var showMessages = false
    /// 盖在视频上的页面（我的/信息/搜索/作者）打开时，所有视频和直播都停
    private var overlayOpen: Bool { showSearch || showMine || showMessages || authorTarget != nil }
    /// 半折叠/合屏：顶栏要整体左移躲开前摄挖孔，间距也收紧
    @State private var topNudge: CGFloat = 0
    /// 顶栏可用宽度：评论栏从右侧滑出时 = 视频区宽度，顶栏跟着视频居中、自适应收紧
    @State private var topBarWidth: CGFloat?
    /// 播放速度（设置 → 播放设置 → 播放速度）：全局速度，长按锁定只作用于单条视频，不写这里
    @AppStorage("douyin_playback_rate_v1") private var playbackRate = 1.0
    @AppStorage("douyin_bg_play_v1") private var bgPlay = false
    @State private var noticeUnread = 0
    @State private var wideToken = UUID()
    @State private var topChrome = CGRect.zero

    private var currentIndex: Int? { currentID.flatMap { id in feed.items.firstIndex { $0.id == id } } }
    private var current: DYAweme? { currentIndex.map { feed.items[$0] } }

    var body: some View {
        ZStack(alignment: .top) {
            layoutRoot
            if !(tab == .live && (live.clean || live.entered)) {
                VStack(spacing: 6) {
                    topBar
                }
                .padding(.top, hSize == .regular ? 0 : -80)
                // 评论栏展开：顶栏只占视频那一块，跟着视频缩到左边。直播预览仍量这块的下沿。
                .frame(width: topBarWidth)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: DYTopChromeFrameKey.self, value: proxy.frame(in: .named("douduo.feed")))
                    }
                }
            }
        }
        .coordinateSpace(.named("douduo.feed"))
        .onPreferenceChange(DYTopChromeFrameKey.self) { next in
            guard abs(next.maxY - topChrome.maxY) > 0.5 || abs(next.minY - topChrome.minY) > 0.5 else { return }
            topChrome = next
        }
        // 顶栏要从物理屏最上沿开始排（外屏/内屏都贴顶），所以整层忽略顶部安全区
        .ignoresSafeArea(edges: [.top, .horizontal])
        // 直播间返回键只保留 DYLiveRoomPage 里那一颗画面内「返回」胶囊：
        // 主视图不挂 NavigationStack / toolbar，避免 Duo 系统侧栏再渲染一个重复的返回按钮。
        .background(DouyinBridgeHost(bridge: bridge).frame(width: 1, height: 1).allowsHitTesting(false))
        .task {
            guard !initialized else { return }
            initialized = true
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try? AVAudioSession.sharedInstance().setActive(true)
            #if DEBUG
            if ProcessInfo.processInfo.environment["DOUDUO_SELFTEST"] == "1" { Task { await DDSelfTest.run(bridge) } }
            if ProcessInfo.processInfo.environment["DOUDUO_APITEST"] == "1" { Task { await DDApiProbe.run(bridge) } }
            if ProcessInfo.processInfo.environment["DOUDUO_LIVEPROBE"] == "1" { Task { await DDFeatureProbe.run(bridge, live: live) } }
            #if DEBUG
            if ProcessInfo.processInfo.environment["DOUDUO_APISCAN"] == "1" { Task { await DYApiScanner.run(bridge) } }
            if ProcessInfo.processInfo.environment["DOUDUO_CPROBE"] == "1" { Task { await DYCommentApiProbe.run(bridge) } }
            if ProcessInfo.processInfo.environment["DOUDUO_LOGINPROBE"] == "1" { Task { await DYLoginProbe.run(bridge) } }
            #endif
            if ProcessInfo.processInfo.environment["DOUDUO_EXPORTTEST"] == "1" { Task { await DDFeatureProbe.exportHeadProbe(bridge) } }
            // 真机验收用：DOUDUO_STARTLIVE=1 + DOUDUO_AUTOLIVEROOM=1 直接进房，省去手点。
            if ProcessInfo.processInfo.environment["DOUDUO_AUTOLIVEROOM"] == "1" {
                Task { @MainActor in
                    var waited = 0
                    while live.rooms.isEmpty, waited < 24 {
                        try? await Task.sleep(for: .milliseconds(500))
                        waited += 1
                    }
                    try? await Task.sleep(for: .milliseconds(800))
                    if !live.entered, !live.rooms.isEmpty { live.enterRoom() }
                }
            }
            #endif
            Task { myUser = try? await bridge.selfProfile() }
            if tab == .live { return }   // 起手就是直播页（调试）时别把推荐流的播放器都拉起来
            // 秒开：先播上次缓存好、还没看过的；连接抖音 / 拉推荐在后台接着往后补
            if feed.items.isEmpty, let saved = DYFeedSession.load() {
                feed.items = saved.items
                resume = saved.positions
                currentID = saved.currentID
                scrollID = saved.currentID
                for a in saved.items {
                    if a.userDigged == 1 { feed.liked.insert(a.id) }
                    if a.isCollect == 1 { feed.collected.insert(a.id) }
                }
                DYLiveModel.log("DDSESSION 恢复 id=\(saved.currentID) t=\(saved.positions[saved.currentID] ?? 0)")
            }
            if feed.items.isEmpty {
                // 没有会话：本地缓存好、没看过的按竖横比例挑出来先播
                let cached = DYVideoCache.pendingSnapshot()
                if !cached.isEmpty {
                    feed.seedPool(cached)
                    feed.fill(6)
                    for a in cached {
                        if a.userDigged == 1 { feed.liked.insert(a.id) }
                        if a.isCollect == 1 { feed.collected.insert(a.id) }
                    }
                    currentID = feed.items.first?.id
                    DYLiveModel.log("DDCACHE 启动从缓存起播 n=\(feed.items.count)/\(cached.count)")
                }
            }
            feed.seedPool(DYVideoCache.pendingSnapshot())
            // 恢复的会话里「当前条之后」是上次的排法：按现在的方向 / 比例重排（当前这条不动）
            if currentIndex != nil { feed.remix(after: currentIndex) }
            await feed.loadMore(bridge)
            if currentID == nil { currentID = feed.items.first?.id }
            focusCurrent()
            #if DEBUG
            // 用真实作品详情复验元数据显示，不造预览数据、不做账号互动。
            if let id = ProcessInfo.processInfo.environment["DOUDUO_VIDEO_ID"],
               let item = try? await bridge.awemeDetail(id) {
                feed.items = [item]; currentID = item.id; scrollID = item.id
                focusCurrent()
            }
            let env0 = ProcessInfo.processInfo.environment
            if let d = env0["DOUDUO_LIVEDELAY"], let sec = Double(d) {
                DispatchQueue.main.asyncAfter(deadline: .now() + sec) { tab = .live }
            }
            let env = ProcessInfo.processInfo.environment
            if let o = env["DOUDUO_OPEN"] {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                switch o {
                case "search": showSearch = true
                case "mine": showMine = true
                case "follow": tab = .follow
                case "author": authorTarget = current?.author
                case "comments": showComments = true
                case "messages": showMessages = true
                case "login": web = DYWebTarget(url: URL(string: "https://www.douyin.com/?recommend=1")!)
                case "qr": Task { await bridge.debugQRLogin() }
                case "export": Task { await bridge.debugExportCookies() }
                case "import": Task { await bridge.debugImportCookies() }
                default: break
                }
            }
            if env["WUWEI_DEBUG_DOUYIN_ADVANCE"] == "1" {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                if feed.items.count > 1 { withAnimation { currentID = feed.items[1].id } }
            }
            if env["WUWEI_DEBUG_DOUYIN_LIVE"] == "1" { tab = .live }
            if env["WUWEI_DEBUG_DOUYIN_COMMENTS"] == "1" {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                showComments = true
            }
            #endif
        }
        .task(id: currentID) {
            // 旧会话没有新增字段：只补当前作品元数据，不换播放地址、不丢进度。
            guard let id = currentID, feed.items.contains(where: { $0.id == id && $0.publishedAt == nil }),
                  let detail = try? await bridge.awemeDetail(id), !Task.isCancelled,
                  let index = feed.items.firstIndex(where: { $0.id == id }) else { return }
            feed.items[index].publishedAt = detail.publishedAt
            feed.items[index].aiDeclaration = detail.aiDeclaration
            saveSession()
        }
        .onChange(of: currentID) { old, new in
            // ⚠️ 宽屏（Duo 内屏）首次布局时 ScrollView 会把 scrollPosition 回写成 nil → 没有「当前条」→ 全部不播、上滑也不认。
            // 列表非空时把 nil 顶回上一个；刷新 / 重载会先清空列表再置 nil，不受影响。
            if new == nil, let old, feed.items.contains(where: { $0.id == old }) { currentID = old; return }
            scrollID = new
            focusCurrent()
            saveSession()
            reportWatch(old: old, new: new)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            saveSession()
        }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            if DDPlayback.shared.appIsActive { saveSession() }
        }
        .onChange(of: cacheCount) { _, _ in focusCurrent() }
        .onChange(of: feed.landscapeWhenWide) { _, _ in remixUpcoming() }
        .onChange(of: feed.shortRatioPortrait) { _, _ in remixUpcoming() }
        .onChange(of: feed.shortRatioLandscape) { _, _ in remixUpcoming() }
        .onDisappear { live.stop(); preloader.clear() }
        .fullScreenCover(item: $web, onDismiss: {
            // 网页里可能登录 / 过了验证：重开签名页，先重新读登录态，再刷推荐
            live.reset(); preloader.clear(); feed.reset(); currentID = nil; bridge.reload()
            Task {
                await feed.loadMore(bridge)
                currentID = feed.items.first?.id
                focusCurrent()
            }
            if tab == .live { Task { await live.load(bridge, reset: true) } }
        }) { t in
            DouyinWebScreen(start: t.url)
        }
        .fullScreenCover(isPresented: $showMessages) {
            DYMessagesScreen(bridge: bridge, onClose: { showMessages = false }, onWeb: { u in
                showMessages = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { web = DYWebTarget(url: u) }
            })
        }
        .task { await refreshNoticeUnread() }
        .task {
            #if DEBUG
            // 模拟器无触摸输入：DOUDUO_MSGTEST=1 → 起播后自动打开消息页
            if ProcessInfo.processInfo.environment["DOUDUO_MSGTEST"] == "1" {
                try? await Task.sleep(for: .seconds(8))
                showMessages = true
                DYLiveModel.log("DDMSGTEST auto-open messages")
            }
            #endif
        }
        .task {
            // 只预取一页直播元数据，不拉流、不进房；用户点直播时不必再从零等列表。
            guard tab != .live else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard live.rooms.isEmpty, !Task.isCancelled else { return }
            await live.load(bridge, reset: true)
        }
        .onChange(of: showMessages) { _, open in
            if !open { Task { await refreshNoticeUnread() } }
        }
        .task {
            // 启动查一次新版本；关掉后同一版本不再提示
            if let u = await DDUpdateChecker.check() { pendingUpdate = u }
        }
        .alert("有新版本", isPresented: Binding(get: { pendingUpdate != nil }, set: { if !$0 { if let u = pendingUpdate { DDUpdateChecker.dismiss(u) }; pendingUpdate = nil } })) {
            Button("去 GitHub 更新") {
                if let u = pendingUpdate { DDUpdateChecker.dismiss(u); DDUpdateChecker.open(u) }
                pendingUpdate = nil
            }
            Button("关闭", role: .cancel) {
                if let u = pendingUpdate { DDUpdateChecker.dismiss(u) }
                pendingUpdate = nil
            }
        } message: {
            Text("新版本 \(pendingUpdate?.version ?? "")（当前 \(DDUpdateChecker.currentVersion)）\n去 GitHub 下载新版，重新签名安装即可，登录态会保留。")
        }
    }

    @ViewBuilder
    private var layoutRoot: some View {
        GeometryReader { geo in
            let wide = Self.playAreaIsWide(geo)
            let panelW = sidePanelWidth(geo)
            // 右侧有评论栏时前摄落在评论栏上，顶栏不用再躲
            let nudge = panelW > 0 ? 0 : DYDuoMetrics.topBarLeftShift(geo)
            let barW: CGFloat? = panelW > 0 ? geo.size.width - panelW : nil
            flatArrangement(geo)
                .onAppear { topNudge = nudge; topBarWidth = barW }
                .onChange(of: nudge) { _, n in topNudge = n }
                .onChange(of: barW) { _, v in withAnimation(.snappy) { topBarWidth = v } }
                .onAppear { feed.screenWide = wide }
                .onChange(of: wide) { _, w in
                    // 转屏过程中尺寸会抖几下，稳定 0.4 秒再重排
                    let token = UUID(); wideToken = token
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        guard wideToken == token, feed.screenWide != w else { return }
                        feed.screenWide = w
                        remixUpcoming()
                    }
                }
        }
    }

    /// 播放区是不是横的：平放/单屏看整个窗口；半折叠看视频实际占的那块
    private static func playAreaIsWide(_ geo: GeometryProxy) -> Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["DOUDUO_FORCEWIDE"] == "1" { return true }
        #endif
        let w = geo.size.width, h = geo.size.height
        guard DYDuoMetrics.foldIsActive(geo) else { return w > h }
        return w > h ? (w * 0.55 > h) : false
    }

    /// 当前条之后按新的方向/比例重排；不够就接着拉
    private func remixUpcoming() {
        guard tab == .recommend || !feed.items.isEmpty else { return }
        feed.remix(after: currentIndex)
        DYLiveModel.log("DDMIX remix wide=\(feed.screenWide) upcoming=\(feed.items.count - (currentIndex ?? -1) - 1)")
        if currentID == nil { currentID = feed.items.first?.id; scrollID = currentID }
        lastFeedPull = .distantPast
        focusCurrent()
    }

    /// 一套布局通吃所有状态，且**不换容器**（换容器会重建播放器 → 黑屏 / 重播）：
    /// - 平放/外屏：视频铺满；够宽时评论从右侧滑出（视频缩窄），窄屏走底部 sheet
    /// - 半折叠：视频自动缩到一多半，另一半常驻评论（宽>高→左右分；高>宽→上下分）
    /// 右侧评论栏宽度（没有右侧栏 = 0）；布局和顶栏共用同一算法
    private func sidePanelWidth(_ geo: GeometryProxy) -> CGFloat {
        let fold = tab == .recommend && DYDuoMetrics.foldIsActive(geo)
        let w = geo.size.width, h = geo.size.height
        let bookFold = fold && w > h
        let sideBySide = w >= DYDuoMetrics.legacyWideMin || bookFold
        let showPanel = fold || (showComments && sideBySide && tab == .recommend)
        return showPanel && sideBySide ? (bookFold ? w * 0.45 : min(380, w * 0.42)) : 0
    }

    private func flatArrangement(_ geo: GeometryProxy) -> some View {
        let fold = tab == .recommend && DYDuoMetrics.foldIsActive(geo)
        let wide = geo.size.width >= DYDuoMetrics.legacyWideMin
        let w = geo.size.width, h = geo.size.height
        let bookFold = fold && w > h          // 书本姿态：左右分
        let tableFold = fold && w <= h        // 桌面姿态：上下分
        let sideBySide = wide || bookFold
        let showPanel = fold || (showComments && sideBySide && tab == .recommend)

        let panelW = sidePanelWidth(geo)
        let panelH = tableFold ? h * 0.45 : 0
        let videoW = sideBySide && panelW > 0 ? w - panelW : w
        let videoH = tableFold ? h - panelH : h

        return ZStack(alignment: .topLeading) {
            feedArea
                .frame(width: videoW, height: videoH, alignment: .topLeading)
            if showPanel, let cur = current {
                DYCommentPanel(bridge: bridge, aweme: cur,
                               onClose: fold ? nil : { withAnimation(.snappy) { showComments = false } })
                    .frame(width: sideBySide ? panelW : w,
                           height: tableFold ? panelH : h)
                    .offset(x: sideBySide ? videoW : 0, y: tableFold ? videoH : 0)
                    .id(cur.id)
            }
        }
        .background(theme.media.strongScrim.color(for: scheme).ignoresSafeArea())
        .animation(.snappy, value: fold)
        .animation(.snappy, value: showComments)
        .sheet(isPresented: Binding(get: { showComments && !sideBySide && !fold }, set: { showComments = $0 })) {
            if let cur = current {
                DYCommentPanel(bridge: bridge, aweme: cur, onClose: { showComments = false })
                    // 竖屏锁死半屏：不给 .large，上滑不能把评论区撑满整屏
                    .presentationDetents([.fraction(0.62)])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    private func refreshNoticeUnread() async {
        guard let groups = try? await bridge.noticeCounts() else { return }
        noticeUnread = DYMessagesScreen.badge(groups)
    }

    /// 换条时：上一条看完没有（≥95%，网页版同口径）+ 新一条起播 1.5 秒后上报
    private func reportWatch(old: String?, new: String?) {
        guard let new, let item = feed.items.first(where: { $0.id == new }) else { return }
        var seen = false
        if let old, let prev = feed.items.first(where: { $0.id == old }), prev.duration > 0,
           DDNowPlaying.id == old { seen = DDNowPlaying.time / prev.duration >= 0.95 }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard currentID == new else { return }
            await bridge.reportWatch(item, preID: old, preSeen: seen)
        }
    }

    private func saveSession() {
        guard let id = currentID, feed.items.contains(where: { $0.id == id }) else { return }
        var positions = resume
        if DDNowPlaying.id == id, DDNowPlaying.time.isFinite {
            positions[id] = max(0, DDNowPlaying.time)
        }
        DYFeedSession(items: feed.items, currentID: id, positions: positions).save()
    }

    /// 自动连播：播完滑到下一条；快到底时先补一页
    private func playNext(after id: String) {
        guard let i = feed.items.firstIndex(where: { $0.id == id }) else { return }
        if i + 1 < feed.items.count {
            withAnimation { currentID = feed.items[i + 1].id }
        } else {
            Task {
                await feed.loadMore(bridge)
                if let j = feed.items.firstIndex(where: { $0.id == id }), j + 1 < feed.items.count {
                    withAnimation { currentID = feed.items[j + 1].id }
                }
            }
        }
    }

    /// 点页签只切页，不再顺手刷新（点顶部会误触成「刷新视频」）。
    /// 要换一批推荐走「更多 → 刷新推荐」。
    private func selectTab(_ target: DYTab) {
        guard tab != target else { return }
        tab = target
    }

    /// 先拉到新一批再替换，失败不清空当前画面；与预取互斥，避免旧请求覆盖刷新结果。
    @MainActor private func refreshRecommendations() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false; focusCurrent() }
        showToast("正在刷新推荐…")
        while feed.loading {
            do { try await Task.sleep(nanoseconds: 100_000_000) }
            catch { return }
        }
        guard !Task.isCancelled else { return }
        let previous = Set(feed.items.map(\.id))
        let replacement = DYFeedModel()
        replacement.screenWide = feed.screenWide
        await replacement.loadMore(bridge)
        guard !Task.isCancelled else { return }
        let fresh = replacement.items.filter { !previous.contains($0.id) }
        guard !fresh.isEmpty else {
            showToast(replacement.error ?? "暂时没有新的推荐，已保留当前视频")
            DYLiveModel.log("DDREFRESH failed kept=\(currentID ?? "-")")
            return
        }
        showComments = false
        scrollEndTask?.cancel(); userScrolling = false
        preloader.clear()
        feed.reset()
        feed.items = fresh
        feed.pool = replacement.pool
        feed.liked.formUnion(replacement.liked)
        feed.collected.formUnion(replacement.collected)
        resume = [:]
        currentID = fresh.first?.id
        scrollID = currentID
        lastFeedPull = Date()
        saveSession()
        showToast("推荐已刷新")
        DYLiveModel.log("DDREFRESH ok n=\(fresh.count) first=\(currentID ?? "-")")
    }

    private func focusCurrent() {
        guard !refreshing, let i = currentIndex else { return }
        preloader.update(feed.items, current: i)
        let curID = feed.items[i].id
        let ahead = Array(feed.items.dropFirst(i + 1))
        let currentItem = feed.items[i]
        Task {
            await DYVideoCache.shared.markWatched(curID)
            await DYVideoCache.shared.focus(current: currentItem, ahead: ahead)
        }
        // 后面不足「缓存条数」就继续拉推荐（至少保证 6 条，节流 4 秒一次）
        let want = max(6, min(DYVideoCache.limit, 60))
        if feed.items.count - i - 1 < want, Date().timeIntervalSince(lastFeedPull) > 4 {
            lastFeedPull = Date()
            Task {
                await feed.loadMore(bridge)
                if let j = currentIndex {
                    preloader.update(feed.items, current: j)
                    await DYVideoCache.shared.focus(current: feed.items[j], ahead: Array(feed.items.dropFirst(j + 1)))
                    if feed.items.count - j - 1 < want { focusCurrent() }
                }
            }
        }
    }

    @ViewBuilder
    private var feedArea: some View {
        ZStack(alignment: .top) {
            if tab == .live {
                DYLiveFeed(bridge: bridge, model: live, onWeb: { u in web = DYWebTarget(url: u) }, active: web == nil && !overlayOpen,
                           topChrome: topChrome, screenInsets: insets)
            } else if tab == .follow {
                DYFollowFeed(bridge: bridge, insets: insets, active: tab == .follow && web == nil && !overlayOpen,
                             onAuthor: { a in authorTarget = a.author },
                             onLogin: { web = DYWebTarget(url: DouyinWeb.home) },
                             onToast: { showToast($0) })
            } else {
                recommendArea
            }
            if let t = feed.toast {
                Text(t).font(.footnote.weight(.medium)).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Capsule().fill(.black.opacity(0.62)))
                    .frame(maxHeight: .infinity, alignment: .center)
                    .transition(.opacity)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("douyin.toast")
            }
            #if DEBUG
            // UI 测试锚点：当前视频 id / 当前锁定倍速
            Text(currentID ?? "-").font(.caption2).opacity(0.01)
                .accessibilityIdentifier("douyin.currentID")
                .allowsHitTesting(false)
            Text(String(format: "%g", playbackRate)).font(.caption2).opacity(0.01)
                .accessibilityIdentifier("douyin.rate")
                .allowsHitTesting(false)
            #endif
        }
        // 顶栏要压在系统状态栏那一行，所以整块忽略顶部安全区；
        // 外屏左右有侧边控制区，安全区会把顶栏整行往左挤，所以水平方向也忽略（视频本来就铺满）
        .ignoresSafeArea(edges: [.top, .horizontal])
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { insets = geo.safeAreaInsets
                    }
                    .onChange(of: geo.safeAreaInsets) { _, v in insets = v }
            }
        }
        .onChange(of: tab) { _, t in
            if t == .recommend { focusCurrent() } else { preloader.clear() }
            if t != .live { live.stop() }
        }
        .fullScreenCover(isPresented: $showSearch) {
            DYSearchScreen(bridge: bridge, onAuthor: { a in authorTarget = a.author })
        }
        .fullScreenCover(isPresented: $showMine) {
            DYMineScreen(bridge: bridge,
                         onLogin: { showMine = false; DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { web = DYWebTarget(url: DouyinWeb.home) } },
                         onAuthor: { a in authorTarget = a.author })
        }
        .sheet(item: $authorTarget) { a in
            DYAuthorScreen(bridge: bridge, author: a, onWeb: { u in web = DYWebTarget(url: u) })
                .presentationDetents([.medium, .large])
                .presentationBackground(.black)
        }

    }

    /// 顶部一排：左菜单，中间 关注/推荐/直播，右边 搜索 / 我的
    /// 顶栏：只留「关注 / 推荐 / 直播」三个纯文字页签，不用胶囊，与状态栏时间/信号同一行。
    /// 自适应仅收紧间距；消息与头像入口始终保留最小触摸区。
    private var topBar: some View {
        ViewThatFits(in: .horizontal) {
            topBarRow(spacing: topNudge > 0 ? 5 : 14, hPad: 16)
            topBarRow(spacing: 0, hPad: 10)
            topBarRow(spacing: 0, hPad: 8)
            topBarRow(spacing: 0, hPad: 5)
        }
        .themeShadow(.mediaLabel)
        .frame(maxWidth: .infinity, alignment: .center)
        // 整行可点区域随内容高度撑开，避免点在文字上方的极窄条带时落空
        .frame(minHeight: 54)
        // 合屏避让：用右侧内缩把居中点推左（small move），绝不把左边的「关注」推出屏幕
        .padding(.trailing, topNudge)
        // 外屏（compact）状态区更深：外屏时间约 85pt，内屏（regular）约 39pt
        // 注意用 size class 判断，不能用容器宽度——评论栏打开时视频区会变窄。
        .padding(.top, hSize == .regular ? 23 : 76)
    }

    private func topBarRow(spacing: CGFloat, hPad: CGFloat) -> some View {
        // 触摸区左右各扩 hPad、上下各扩 14（图标与字号不动）
        HStack(spacing: spacing) {
            ForEach(DYTab.allCases, id: \.self) { t in
                Button { selectTab(t) } label: {
                    VStack(spacing: 3) {
                        Text(t.title)
                            .font(.headline.weight(tab == t ? .bold : .medium))
                            .foregroundStyle(theme.media.onMedia.color(for: scheme).opacity(tab == t ? 1 : 0.62))
                            .lineLimit(1).fixedSize()
                        Capsule()
                            .fill(theme.media.onMedia.color(for: scheme))
                            .frame(width: 16, height: 3)
                            .opacity(tab == t ? 1 : 0)
                    }
                    // 文字本身小，撑开触摸区，避免点不中/误判成下拉
                    .padding(.horizontal, hPad)
                    .padding(.vertical, 14)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            // 消息只留图标，未读红点仍独立显示。
            Button { showMessages = true } label: {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.headline.weight(.medium))
                    .foregroundStyle(theme.media.onMedia.color(for: scheme).opacity(0.62))
                .padding(.horizontal, hPad)
                .padding(.vertical, 14)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .overlay(alignment: .topTrailing) {
                    if noticeUnread > 0 {
                        Circle().fill(theme.status.danger.color(for: scheme))
                            .frame(width: 7, height: 7)
                            .offset(x: -(hPad - 2), y: 10)
                            .allowsHitTesting(false)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("消息")
            .accessibilityIdentifier("douyin.messages.top")

            // 「我的」：独立按钮（不属于 tab 切换）
            Button { showMine = true } label: {
                HStack(spacing: 5) {
                    CachedAsyncImage(url: myUser?.avatar.flatMap(URL.init(string:))) { img in
                        img.resizable().scaledToFill()
                    } placeholder: {
                        Image(systemName: "person.crop.circle")
                            .font(.system(size: 19))
                            .foregroundStyle(theme.media.onMedia.color(for: scheme).opacity(0.62))
                    }
                    .frame(width: 22, height: 22)
                    .clipShape(Circle())
                }
                .padding(.horizontal, max(hPad - 2, 4))
                .padding(.vertical, 12)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("我的")
            .accessibilityIdentifier("douyin.mine.top")
        }
        .fixedSize()
    }

    private func topIcon(_ name: String, _ id: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: name)
                .font(.system(size: theme.typography.pointSize(.headline), weight: .semibold))
                .foregroundStyle(theme.media.onMedia.color(for: scheme))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    /// 顶栏「消息」。样式跟现有 topIcon，红暴液态按钮合并后会一起换。
    private var messageEntry: some View {
        topIcon("bell", "douyin.messages") { showMessages = true }
            .overlay(alignment: .topTrailing) {
                if noticeUnread > 0 {
                    Circle().fill(theme.status.danger.color(for: scheme))
                        .frame(width: 8, height: 8)
                        .offset(x: -6, y: 6)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("douyin.messages.badge")
                }
            }
    }

    /// 顶部「关注 / 推荐 / 直播」切换（抖音顶栏同款位置）
    private var tabSwitcher: some View {
        let fg = theme.media.onMedia.color(for: scheme)
        return HStack(spacing: 14) {
            ForEach(DYTab.allCases, id: \.self) { t in
                Button { selectTab(t) } label: {
                    VStack(spacing: 4) {
                        Text(t.title)
                            .font(.headline.weight(tab == t ? .bold : .medium))
                            .foregroundStyle(fg.opacity(tab == t ? 1 : 0.6))
                            .lineLimit(1)
                            .fixedSize()
                        Capsule().fill(fg).frame(width: 18, height: 3).opacity(tab == t ? 1 : 0)
                    }
                    .padding(.horizontal, 2)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 2)
    }

    @ViewBuilder
    private var recommendArea: some View {
        ZStack(alignment: .topLeading) {
            if feed.items.isEmpty {
                VStack(spacing: WuWeiDesign.Spacing.md) {
                    if let e = feed.error {
                        Text(e).font(.footnote).multilineTextAlignment(.center)
                            .foregroundStyle(theme.media.onMediaSecondary.color(for: scheme))
                        HStack {
                            Button("重试") { Task { await feed.loadMore(bridge); currentID = feed.items.first?.id } }
                                .buttonStyle(.borderedProminent)
                            Button("打开网页版") { web = DYWebTarget(url: DouyinWeb.home) }
                                .buttonStyle(.bordered)
                        }
                    } else {
                        ProgressView().tint(theme.media.onMedia.color(for: scheme))
                        Text(bridge.ready ? "加载推荐…" : "连接抖音…").font(.footnote)
                            .foregroundStyle(theme.media.onMediaSecondary.color(for: scheme))
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(feed.items) { item in
                            page(for: item)
                                .containerRelativeFrame([.horizontal, .vertical])
                                .id(item.id)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $scrollID, anchor: .center)
                .onAppear { scrollID = currentID }
                .simultaneousGesture(DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        if abs(value.translation.height) > abs(value.translation.width) {
                            if !userScrolling { dragStartID = currentID }
                            scrollEndTask?.cancel(); userScrolling = true
                        }
                    }
                    .onEnded { _ in
                        // 下拉不再触发刷新（顶部点击/轻扫会误判成刷新）；刷新走「更多 → 刷新推荐」。
                        dragStartID = nil
                        scrollEndTask = Task {
                            try? await Task.sleep(nanoseconds: 800_000_000)
                            if !Task.isCancelled { userScrolling = false }
                        }
                    })
                .onChange(of: scrollID) { _, id in
                    guard let id, feed.items.contains(where: { $0.id == id }) else { return }
                    if userScrolling { currentID = id }
                    else if id != currentID { scrollID = currentID }
                }
                .scrollIndicators(.hidden)
                .ignoresSafeArea()
            }
        }
    }

    /// 单页构造拆成独立函数：参数太多，写在 ForEach 里会让类型检查超时。
    private func page(for item: DYAweme) -> some View {
        let extras = AnyView(moreExtrasMenu(item))
        let active = item.id == currentID && web == nil && tab == .recommend && !overlayOpen
        return DYVideoPage(item: item,
                           isCurrent: active,
                           insets: insets,
                           resume: resume[item.id],
                           liked: feed.liked.contains(item.id),
                           collected: feed.collected.contains(item.id),
                           onLike: { toggleLike(item.id, force: nil) },
                           onCollect: { toggleCollect(item.id) },
                           onDoubleTap: { toggleLike(item.id, force: true) },
                           onComments: { withAnimation(.snappy) { showComments.toggle() } },
                           onSearch: { showSearch = true },
                           onAuthor: { authorTarget = item.author },
                           onSavePosition: { resume[item.id] = $0; saveSession() },
                           preloader: preloader,
                           bridge: bridge,
                           onToast: { showToast($0) },
                           onDislike: { dislike(item.id) },
                           moreExtras: extras,
                           onEnded: { playNext(after: item.id) })
    }

    /// 点赞：先本地乐观更新，再调抖音网页接口，按服务端返回决定成败
    /// （不用 cookie 判断登录态：sessionid 是 HttpOnly，document.cookie 读不到，会误判成未登录）
    private func toggleLike(_ id: String, force: Bool?) {
        let has = feed.liked.contains(id)
        let want = force ?? !has
        guard want != has else { return }
        if want { feed.liked.insert(id) } else { feed.liked.remove(id) }
        Task {
            do {
                switch try await bridge.digg(id, like: want) {
                case .ok:
                    break
                case .notLoggedIn:
                    await MainActor.run {
                        if want { feed.liked.remove(id) } else { feed.liked.insert(id) }
                        showToast("抖音未登录：菜单 → 网页版 / 登录")
                    }
                case .failed(let why):
                    await MainActor.run {
                        if want { feed.liked.remove(id) } else { feed.liked.insert(id) }
                        showToast("点赞失败：\(why)")
                    }
                }
            } catch {
                #if DEBUG
                ddWrite("DDACT digg ERROR \(error)")
                #endif
                await MainActor.run {
                    if want { feed.liked.remove(id) } else { feed.liked.insert(id) }
                    showToast("点赞失败：\(error.localizedDescription)")
                }
            }
        }
    }

    /// 不感兴趣：立刻从列表拿掉并切到下一条，后台告诉抖音（失败只提示，不把视频塞回来）
    private func dislike(_ id: String) {
        guard let i = feed.items.firstIndex(where: { $0.id == id }) else { return }
        let next = i + 1 < feed.items.count ? feed.items[i + 1].id : (i > 0 ? feed.items[i - 1].id : nil)
        scrollEndTask?.cancel(); userScrolling = false
        showComments = false
        if currentID == id { currentID = next; scrollID = next }
        feed.items.remove(at: i)
        resume[id] = nil
        saveSession()
        showToast("将减少此类推荐")
        Task {
            await DYVideoCache.shared.markWatched(id)
            do {
                switch try await bridge.dislike(id) {
                case .ok: break
                case .notLoggedIn: showToast("抖音未登录，「不感兴趣」没同步到账号")
                case .failed(let why): showToast("「不感兴趣」同步失败：\(why)")
                }
            } catch {
                showToast("「不感兴趣」同步失败：\(error.localizedDescription)")
            }
        }
        if next == nil { Task { await feed.loadMore(bridge); currentID = feed.items.first?.id; scrollID = currentID } }
    }

    /// 收藏 / 取消收藏（同步到抖音账号的「收藏」）
    private func toggleCollect(_ id: String) {
        let has = feed.collected.contains(id)
        let want = !has
        if want { feed.collected.insert(id) } else { feed.collected.remove(id) }
        Task {
            do {
                switch try await bridge.favorite(id, add: want) {
                case .ok:
                    await MainActor.run { showToast(want ? "已收藏" : "已取消收藏") }
                case .notLoggedIn:
                    await MainActor.run {
                        if want { feed.collected.remove(id) } else { feed.collected.insert(id) }
                        showToast("抖音未登录：菜单 → 网页版 / 登录")
                    }
                case .failed(let why):
                    await MainActor.run {
                        if want { feed.collected.remove(id) } else { feed.collected.insert(id) }
                        showToast("收藏失败：\(why)")
                    }
                }
            } catch {
                #if DEBUG
                ddWrite("DDACT fav ERROR \(error)")
                #endif
                await MainActor.run {
                    if want { feed.collected.remove(id) } else { feed.collected.insert(id) }
                    showToast("收藏失败：\(error.localizedDescription)")
                }
            }
        }
    }

    private func rateTitle(_ r: Double) -> String { r == 1 ? "正常速度" : String(format: "%g 倍速", r) }

    private func showToast(_ s: String) {
        feed.toast = s
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            if feed.toast == s { feed.toast = nil }
        }
    }

    /// 当前作品操作留在第一层，全局偏好统一收进设置。
    @ViewBuilder
    private func moreExtrasMenu(_ item: DYAweme) -> some View {
        Section {
            Button("刷新推荐", systemImage: "arrow.clockwise") {
                Task { await refreshRecommendations() }
            }
            .disabled(refreshing)
            Menu {
                Menu {
                    Toggle(isOn: $autoNext) { Label("自动连播", systemImage: "play.square.stack") }
                    Toggle(isOn: $muted) { Label("静音", systemImage: "speaker.slash") }
                    Toggle(isOn: $feed.autoFit) { Label("自动铺满宽度", systemImage: "arrow.up.left.and.arrow.down.right") }
                    Menu {
                        ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { r in
                            Button {
                                playbackRate = r
                            } label: {
                                if abs(playbackRate - r) < 0.01 {
                                    Label(rateTitle(r), systemImage: "checkmark")
                                } else {
                                    Text(rateTitle(r))
                                }
                            }
                        }
                    } label: {
                        Label("播放速度", systemImage: "speedometer")
                    }
                    .accessibilityIdentifier("douyin.playback.speed")
                    Toggle(isOn: $bgPlay) { Label("后台播放（听书）", systemImage: "headphones") }
                } label: { Label("播放设置", systemImage: "play.circle") }
                Menu {
                    Toggle(isOn: $feed.landscapeWhenWide) { Label("横屏时只放横屏内容", systemImage: "rectangle.on.rectangle") }
                        .accessibilityIdentifier("douyin.landscape.only")
                    Menu {
                        Picker(selection: $feed.shortRatioPortrait) {
                            Text("不限").tag(-1)
                            Text("短视频 30%").tag(30)
                            Text("短视频 50%").tag(50)
                            Text("短视频 70%").tag(70)
                            Text("只看短视频").tag(100)
                        } label: { Label("竖屏短视频占比（3 分钟内）", systemImage: "rectangle.portrait") }
                        .pickerStyle(.menu)
                        .accessibilityIdentifier("douyin.short.portrait")
                        Picker(selection: $feed.shortRatioLandscape) {
                            Text("不限").tag(-1)
                            Text("短视频 30%").tag(30)
                            Text("短视频 50%").tag(50)
                            Text("短视频 70%").tag(70)
                            Text("只看短视频").tag(100)
                        } label: { Label("横屏短视频占比（3 分钟内）", systemImage: "rectangle") }
                        .pickerStyle(.menu)
                        .accessibilityIdentifier("douyin.short.landscape")
                    } label: { Label("高级筛选", systemImage: "line.3.horizontal.decrease") }
                } label: { Label("内容偏好", systemImage: "slider.horizontal.3") }
                Menu {
                    Picker(selection: $cacheCount) {
                        Text("5 条").tag(5)
                        Text("10 条").tag(10)
                        Text("20 条").tag(20)
                        Text("50 条").tag(50)
                        Text("100 条").tag(100)
                        Text("关闭").tag(0)
                    } label: { Label("预缓存数量", systemImage: "arrow.down.circle") }
                    .pickerStyle(.menu)
                    Button("清除视频缓存", systemImage: "trash") {
                        Task {
                            let b = await DYVideoCache.shared.clear()
                            showToast("已清除 \(b / 1024 / 1024) MB")
                            focusCurrent()
                        }
                    }
                } label: { Label("缓存管理", systemImage: "internaldrive") }
                Menu {
                    Button("官网 / 登录（备用入口）", systemImage: "safari") { web = DYWebTarget(url: DouyinWeb.home) }
                } label: { Label("账号与登录", systemImage: "person.crop.circle") }
                Menu {
                    Button {
                        UIApplication.shared.open(DDUpdateChecker.repoURL)
                    } label: {
                        Label("开源仓库", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    .accessibilityIdentifier("douyin.about")
                } label: { Label("关于", systemImage: "info.circle") }
            } label: {
                Label("设置", systemImage: "gearshape")
            }
        }
    }
}

private extension Double {
    func clamped(_ lo: Double, _ hi: Double) -> Double { Swift.min(Swift.max(self, lo), hi) }
}

struct DYWebTarget: Identifiable { let id = UUID(); let url: URL }

enum DYTab: CaseIterable { case follow, recommend, live
    var title: String {
        switch self {
        case .follow: "关注"
        case .recommend: "推荐"
        case .live: "直播"
        }
    }
}

// MARK: - 单页

struct DYVideoPage: View {
    @Environment(\.horizontalSizeClass) private var hSize
    private var railWidth: CGFloat { hSize == .compact ? 50 : 54 }
    private var actionColumnWidth: CGFloat { 54 }
    private var chromeSidePadding: CGFloat { 12 }
    // Full-bleed ancestors may report zero safe-area insets. Read the app's
    // foreground key window as a fallback, never a guessed device/rail width.
    private var systemColumnInset: CGFloat {
        let windowInset = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?.safeAreaInsets.right ?? 0
        return max(insets.trailing, windowInset)
    }
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    let item: DYAweme
    let isCurrent: Bool
    let insets: EdgeInsets
    let resume: Double?
    let liked: Bool
    let collected: Bool
    let onLike: () -> Void
    let onCollect: () -> Void
    let onDoubleTap: () -> Void
    let onComments: () -> Void
    let onSearch: () -> Void
    let onAuthor: () -> Void
    let onSavePosition: (Double) -> Void
    let preloader: DYPreloader
    let bridge: DouyinBridge?
    let onToast: ((String) -> Void)?
    /// 只有推荐流传：关注 / 搜索 / 我的 里不显示「不感兴趣」
    let onDislike: (() -> Void)?
    /// 「更多」菜单末尾追加的条目（消息 / 我的 / 设置），由推荐流注入
    var moreExtras: AnyView = AnyView(EmptyView())
    /// 播完切下一条（「自动连播」打开才生效）
    var onEnded: (() -> Void)? = nil
    var onBack: (() -> Void)? = nil
    @AppStorage("douyin_autoplay_v1") private var autoNext = false
    @State private var heart = false
    @State private var danmaku: [DYDanmaku] = []
    @State private var danmakuLoaded = false
    @State private var saving = false
    @State private var showDanmakuInput = false
    @State private var danmakuDraft = ""
    @State private var danmakuSending = false
    @FocusState private var danmakuFocused: Bool
    @AppStorage("douyin_autofit_v1") private var autoFit = true
    @AppStorage("douyin_danmaku_v1") private var danmakuOn = true
    @AppStorage("douyin_playback_rate_v1") private var playbackRate = 1.0
    /// 长按加速时右侧按钮/作者区淡出；这些控件按住也能触发加速（见 DYHoldBoost）。
    @StateObject private var boost = DYBoostControl()

    init(item: DYAweme, isCurrent: Bool, insets: EdgeInsets, resume: Double?, liked: Bool, collected: Bool,
         onLike: @escaping () -> Void, onCollect: @escaping () -> Void, onDoubleTap: @escaping () -> Void,
         onComments: @escaping () -> Void, onSearch: @escaping () -> Void, onAuthor: @escaping () -> Void, onSavePosition: @escaping (Double) -> Void,
         preloader: DYPreloader, bridge: DouyinBridge? = nil, onToast: ((String) -> Void)? = nil,
         onDislike: (() -> Void)? = nil, moreExtras: AnyView = AnyView(EmptyView()),
         onEnded: (() -> Void)? = nil, onBack: (() -> Void)? = nil) {
        self.item = item; self.isCurrent = isCurrent; self.insets = insets; self.resume = resume
        self.liked = liked; self.collected = collected
        self.onLike = onLike; self.onCollect = onCollect; self.onDoubleTap = onDoubleTap
        self.onComments = onComments; self.onSearch = onSearch; self.onAuthor = onAuthor; self.onSavePosition = onSavePosition
        self.preloader = preloader; self.bridge = bridge; self.onToast = onToast
        self.onDislike = onDislike
        self.moreExtras = moreExtras
        self.onEnded = onEnded
        self.onBack = onBack
    }

    var body: some View {
        let fg = theme.media.onMedia.color(for: scheme)
        ZStack(alignment: .bottomLeading) {
            if item.images.isEmpty, let s = item.play, let remote = URL(string: s) {
                // 只用「整条缓存」或「在线流」：不再走头部缓存 + 接续（那一下切换必然闪/卡）
                let url = DYVideoCache.localURL(item.id) ?? remote
                // 复用影库播放器：横滑快进（带预览缩略图）、双击、长按 2 倍速、竖滑切视频、底部可拖进度条、VLC 兜底
                PlayerPage.external(id: item.id, title: item.desc, url: url, durationSec: item.duration,
                                    isActive: isCurrent, topInset: insets.top, bottomInset: insets.bottom,
                                    resumePosition: resume, compactChrome: true,
                                    preparedPlayer: { preloader.take(item.id) },
                                    onEnded: autoNext ? onEnded : nil,
                                    onDoubleTap: {
                                        onDoubleTap()
                                        heart = true
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { heart = false }
                                    },
                                    onSavePosition: onSavePosition, onClose: {}, fillWidth: autoFit,
                                    danmaku: danmakuOn ? danmaku : [],
                                    altURL: item.playAlt.flatMap(URL.init(string:)),
                                    quality: item.q,
                                    fastURL: item.playFast.flatMap(URL.init(string:)),
                                    posterURL: item.cover.flatMap(URL.init(string:)),
                                    videoAspect: item.height > 0 ? item.width / item.height : 0,
                                    headEndSeconds: nil,
                                    continuationURL: nil,
                                    boost: boost)
            } else {
                TabView {
                    ForEach(item.images, id: \.self) { s in
                        CachedAsyncImage(url: URL(string: s)) { img in img.resizable().scaledToFit() } placeholder: { ProgressView() }
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
            }

            if heart {
                Image(systemName: "heart.fill")
                    .font(.system(size: theme.typography.pointSize(.splash)))
                    .scaleEffect(1.7)
                    .foregroundStyle(theme.status.danger.color(for: scheme))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.scale.combined(with: .opacity))
                    .allowsHitTesting(false)
            }

            // 左下信息贴近进度条；右侧按钮维持原高度，不跟随标题下移。
            HStack(alignment: .bottom, spacing: 12) {
                info(fg)
                Spacer(minLength: 0)
                actions(fg)
                    .offset(x: DYDuoMetrics.actionRailHorizontalOffset(
                        isRegular: hSize == .regular, trailingInset: systemColumnInset,
                        columnWidth: actionColumnWidth, outerPadding: chromeSidePadding,
                        opticalLeadingInset: theme.media.expandedRailOpticalInset))
                    .modifier(DYRailReservedNudge())
                    .offset(x: hSize == .compact ? -9 : 0)
                    .padding(.bottom, item.images.isEmpty ? 56 : 0)
            }
            .padding(.horizontal, chromeSidePadding)
            .padding(.bottom, max(insets.bottom, 18) + (item.images.isEmpty ? 36 : 24))
            // 长按加速时淡出按钮和信息，画面干净；不禁用点击区，手指按在按钮上也能继续加速。
            .opacity(boost.boosting ? 0 : 1)
            .animation(.easeOut(duration: 0.15), value: boost.boosting)
        }
        .overlay(alignment: .bottom) {
            if showDanmakuInput { danmakuBar.padding(.bottom, max(insets.bottom, 12) + 6) }
        }
        .animation(.snappy, value: heart)
        .onChange(of: isCurrent) { _, c in if !c { showDanmakuInput = false } }
        // 弹幕：轮到这条时才拉（一次拉整条视频的）
        .task(id: isCurrent) {
            guard isCurrent, !danmakuLoaded, item.images.isEmpty, let b = bridge else { return }
            danmakuLoaded = true
            do {
                danmaku = try await b.danmaku(item.id, durationMs: Int(item.duration * 1000))
                DYLiveModel.log("DDDM id=\(item.id) n=\(danmaku.count) first=\(danmaku.first.map { "\($0.offset)s \($0.text)" } ?? "-")")
            } catch {
                DYLiveModel.log("DDDM id=\(item.id) error=\(error)")
            }
        }
    }

    private var danmakuBar: some View {
        HStack(spacing: 8) {
            TextField("", text: $danmakuDraft, prompt: Text("发个弹幕见证当下").foregroundStyle(.white.opacity(0.5)))
                .foregroundStyle(.white)
                .focused($danmakuFocused)
                .submitLabel(.send)
                .onSubmit { sendDanmaku() }
                .padding(.horizontal, 14).frame(height: 40)
                .background(Capsule().fill(.black.opacity(0.6)))
                .accessibilityIdentifier("douyin.danmaku.input")
            Button(action: sendDanmaku) {
                if danmakuSending { ProgressView().tint(.white) }
                else { Text("发送").font(.subheadline.weight(.semibold)) }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14).frame(height: 40)
            .background(Capsule().fill(theme.accent.color(for: scheme)))
            .disabled(danmakuDraft.trimmingCharacters(in: .whitespaces).isEmpty || danmakuSending)
            .accessibilityIdentifier("douyin.danmaku.send")
            Button { showDanmakuInput = false; danmakuFocused = false } label: {
                Image(systemName: "xmark").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    .frame(width: 36, height: 40)
            }
        }
        .padding(.horizontal, 12)
    }

    private func sendDanmaku() {
        let text = danmakuDraft.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !danmakuSending, let b = bridge else { return }
        danmakuSending = true
        let at = DDNowPlaying.id == item.id ? DDNowPlaying.time : 0
        Task {
            do {
                let id = try await b.postDanmaku(item.id, text: text, offset: at)
                // 自己发的立刻上屏（从当前时间点开始飘）
                danmaku.append(DYDanmaku(id: id, text: text, offset: at + 0.3))
                danmaku.sort { $0.offset < $1.offset }
                danmakuDraft = ""
                showDanmakuInput = false
                danmakuFocused = false
                onToast?("弹幕已发送")
            } catch {
                onToast?("弹幕发送失败：\(error.localizedDescription)")
            }
            danmakuSending = false
        }
    }

    private func save() {
        guard !saving else { return }
        saving = true
        onToast?("正在保存…")
        Task {
            do {
                try await DYSaver.save(item)
                onToast?(item.images.isEmpty ? "视频已保存到相册" : "图集已保存到相册")
            } catch {
                onToast?("保存失败：\(error.localizedDescription)")
            }
            saving = false
        }
    }

    /// 小红书式左下信息区：头像 + 昵称 + 红色「关注」胶囊，下面文案 / 音乐
    private func info(_ fg: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button(action: { if !boost.blocksTap { onAuthor() } }) {
                    HStack(spacing: 8) {
                        CachedAsyncImage(url: item.author.avatar.flatMap(URL.init(string:))) { img in
                            img.resizable().scaledToFill()
                        } placeholder: { theme.media.chromeFill.color(for: scheme) }
                        .frame(width: 34, height: 34)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(fg.opacity(0.9), lineWidth: 1))
                        .overlay(alignment: .bottomTrailing) {
                            // 已关注：绿色对勾；未关注：红色加号。follow_status > 0 即已关注（互关为 2）。
                            let followed = (item.author.follow ?? 0) > 0
                            Image(systemName: followed ? "checkmark" : "plus")
                                .font(.system(size: 8, weight: .heavy))
                                .foregroundStyle(.white)
                                .frame(width: 14, height: 14)
                                .background(Circle().fill(followed ? theme.status.success.color(for: scheme) : theme.status.danger.color(for: scheme)))
                                .overlay(Circle().stroke(.black.opacity(0.35), lineWidth: 0.5))
                                .offset(x: 3, y: 3)
                                .accessibilityIdentifier(followed ? "douyin.author.followed" : "douyin.author.notfollowed")
                        }
                        Text(item.author.name).font(.subheadline.weight(.semibold)).foregroundStyle(fg).lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .modifier(DYHoldBoost(control: boost))
                .accessibilityIdentifier("douyin.author")
            }
            if let metadata = item.metadataText() {
                Text(metadata)
                    .font(.subheadline)
                    .foregroundStyle(theme.media.onMediaSecondary.color(for: scheme))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("douyin.video.metadata")
            }
            if !item.desc.isEmpty {
                DYExpandableTitle(text: item.desc, foreground: fg,
                                  secondary: theme.media.onMediaSecondary.color(for: scheme))
            }
            if !item.music.isEmpty {
                Label(item.music, systemImage: "music.note")
                    .font(.caption).lineLimit(1)
                    .foregroundStyle(theme.media.onMediaSecondary.color(for: scheme))
            }
        }
        .themeShadow(.mediaLabel)
    }

    /// 小红书式右侧栏：一根竖向液态玻璃胶囊（赞 / 评论 / 收藏 / 搜索，数字在图标下），下方单独一颗「更多」圆按钮
    private func actions(_ fg: Color) -> some View {
        VStack(spacing: theme.media.actionGroupSpacing) {
            if let onBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.backward")
                        .font(.title2.weight(.medium))
                        .foregroundStyle(fg)
                        .frame(width: 50, height: 50)
                }
                .buttonStyle(.plain)
                .ddGlassCapsule()
                .accessibilityLabel("返回上一层")
                .accessibilityIdentifier("douyin.list.back")
            }
            VStack(spacing: theme.media.actionItemSpacing) {
                railItem(liked ? "heart.fill" : "heart", DYFormat.count(item.stats.digg + (liked ? 1 : 0)),
                         tint: liked ? theme.status.danger.color(for: scheme) : fg, "douyin.like", onLike)
                railItem("ellipsis.bubble", DYFormat.count(item.stats.comment), tint: fg, "douyin.comments", onComments)
                railItem(collected ? "star.fill" : "star", DYFormat.count(item.stats.collect + (collected ? 1 : 0)),
                         tint: collected ? theme.status.warning.color(for: scheme) : fg, "douyin.collect", onCollect)
                railItem("magnifyingglass", "", tint: fg, "douyin.search", onSearch)
                if item.images.isEmpty {
                    // 有些视频铺满后会裁掉边缘，随手切回完整画面
                    railItem("arrow.up.left.and.arrow.down.right", "", tint: autoFit ? theme.status.warning.color(for: scheme) : fg,
                             "douyin.fit") {
                        autoFit.toggle()
                        onToast?(autoFit ? "铺满：开" : "完整画面")
                    }
                }
            }
            .padding(.vertical, 8)
            .frame(width: railWidth)
            .ddGlassCapsule()
            .frame(width: actionColumnWidth)
            moreMenu(fg)
        }
        .themeShadow(.mediaLabel)
    }

    private func railItem(_ icon: String, _ text: String, tint: Color, _ id: String, _ act: @escaping () -> Void) -> some View {
        Button(action: { if !boost.blocksTap { act() } }) {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: theme.typography.pointSize(.displayLarge), weight: .regular))
                    .foregroundStyle(tint)
                    .frame(height: 34)
                if !text.isEmpty {
                    Text(text).font(.caption2.weight(.medium)).monospacedDigit()
                        .foregroundStyle(theme.media.onMediaSecondary.color(for: scheme))
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
            }
            .frame(width: railWidth, height: text.isEmpty ? 44 : 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(DYHoldBoost(control: boost))
        .accessibilityIdentifier(id)
    }

    private func rateTitle(_ r: Double) -> String { r == 1 ? "正常速度" : String(format: "%g 倍速", r) }

    /// 「更多」：转发 / 下载快捷入口 → 不感兴趣 → 弹幕 → 刷新推荐 / 设置。
    @ViewBuilder
    private func moreMenu(_ fg: Color) -> some View {
        Menu {
            ControlGroup {
                DYForwardMenu(item: item, bridge: bridge, foreground: fg)
                Button {
                    save()
                } label: {
                    Label(saving ? "保存中…" : "下载", systemImage: "arrow.down.to.line")
                }
                .disabled(saving)
                .accessibilityIdentifier("douyin.save")
            }
            // 常用播放设置放在「更多」第一层：点「倍速」弹出速度列表，选哪个就切到哪个，当前视频立刻生效
            Section {
                Menu {
                    Picker("倍速", selection: Binding(
                        get: { playbackRate },
                        set: { r in playbackRate = r; onToast?(rateTitle(r)) })) {
                        ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { r in Text(rateTitle(r)).tag(r) }
                    }
                } label: {
                    Label("倍速 · \(playbackRate == playbackRate.rounded() ? String(format: "%.0f", playbackRate) : String(format: "%g", playbackRate))×", systemImage: "speedometer")
                }
                .accessibilityIdentifier("douyin.quick.speed")
                Toggle(isOn: $autoNext) { Label("自动连播", systemImage: "play.square.stack") }
                    .accessibilityIdentifier("douyin.quick.autonext")
            }
            if let onDislike {
                Button("不感兴趣", systemImage: "hand.thumbsdown", role: .destructive) { onDislike() }
                    .accessibilityIdentifier("douyin.dislike")
            }
            if item.images.isEmpty {
                DYDanmakuOptions(onSend: bridge == nil ? nil : {
                    showDanmakuInput = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { danmakuFocused = true }
                })
            }
            moreExtras
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: theme.typography.pointSize(.displayLarge), weight: .semibold))
                .foregroundStyle(fg)
                .frame(width: 50, height: 50)
                .contentShape(Circle())
                .ddGlassCircle()
                .frame(width: 54)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityIdentifier("douyin.more")
        .modifier(DYForwardPresentation(item: item))
    }

}

enum DYFormat {
    static func clock(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let i = Int(t.rounded(.down))
        return i >= 3600 ? String(format: "%d:%02d:%02d", i / 3600, i % 3600 / 60, i % 60) : String(format: "%d:%02d", i / 60, i % 60)
    }
    static func count(_ n: Int) -> String {
        if n >= 100_000_000 { return String(format: "%.1f亿", Double(n) / 1e8) }
        if n >= 10_000 { return String(format: "%.1fw", Double(n) / 1e4) }
        return "\(n)"
    }
    static func time(_ ts: Double) -> String {
        let d = Date().timeIntervalSince1970 - ts
        if d < 3600 { return "\(max(1, Int(d / 60)))分钟前" }
        if d < 86400 { return "\(Int(d / 3600))小时前" }
        if d < 86400 * 30 { return "\(Int(d / 86400))天前" }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date(timeIntervalSince1970: ts))
    }
}

// MARK: - 评论

struct DYCommentPanel: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.horizontalSizeClass) private var hSize
    let bridge: DouyinBridge
    let aweme: DYAweme
    let onClose: (() -> Void)?
    /// 从消息点评论进来：首屏用 insert_ids 把这条评论顶到第一条并高亮
    let focus: DYCommentFocus?
    @State private var items: [DYComment] = []
    @State private var cursor = 0
    @State private var hasMore = true
    @State private var total = 0
    @State private var loading = false
    @State private var error: String?
    @State private var replies: [String: [DYComment]] = [:]
    @State private var replyCursor: [String: Int] = [:]
    @State private var replyMore: [String: Bool] = [:]
    @State private var replyLoading: Set<String> = []
    @State private var replyErr: [String: String] = [:]
    @State private var draft = ""
    @State private var replyTo: DYComment?
    /// replyTo 是楼中楼时它所在的一级评论 cid（发送走 reply_id=一级、reply_to_reply_id=这条）
    @State private var replyParent: String?
    @State private var highlight: String?
    @State private var focusMiss = false
    @State private var showEmoji = false
    @State private var showAt = false
    @State private var emojis: [DYEmoji] = []
    @State private var friends: [DYFriend] = []
    @State private var atLoading = false
    @State private var atError: String?
    @State private var sending = false
    @State private var sendErr: String?
    @State private var digged: Set<String> = []
    @State private var diggShown: [String: Int] = [:]
    @State private var relatedWords: [String] = []
    @State private var relatedQuery: DYRelatedQuery?
    @FocusState private var inputFocused: Bool

    init(bridge: DouyinBridge, aweme: DYAweme, onClose: (() -> Void)?, focus: DYCommentFocus? = nil) {
        self.bridge = bridge; self.aweme = aweme; self.onClose = onClose
        self.focus = focus?.awemeID == aweme.id ? focus : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(total > 0 ? "\(DYFormat.count(total)) 条评论" : "评论").font(.subheadline.weight(.semibold))
                Spacer()
                if let onClose {
                    Button(action: onClose) { Image(systemName: "xmark").font(.subheadline.weight(.semibold)) }
                        .buttonStyle(.plain)
                }
            }
            .foregroundStyle(.themeTextPrimary)
            .padding(.horizontal, 16).padding(.vertical, 12)
            // 横屏（侧栏）时关闭键离右缘太近，会和视频时间显示挤在一起，整体左移让位
            .padding(.trailing, hSize == .regular ? 88 : 0)
            Divider()
            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if focusMiss {
                        Text("这条评论已删除或暂不可见").font(.caption).foregroundStyle(.themeTextSecondary)
                            .frame(maxWidth: .infinity)
                    }
                    ForEach(items) { c in
                        VStack(alignment: .leading, spacing: 10) {
                            row(c, parent: nil)
                            if c.replies > 0 || !(replies[c.id] ?? []).isEmpty { replyBlock(c) }
                        }
                        .id(c.id)
                    }
                    if let error {
                        Text(error).font(.caption).foregroundStyle(theme.status.danger.color(for: scheme))
                    }
                    if hasMore {
                        ProgressView().frame(maxWidth: .infinity)
                            .onAppear { Task { await load() } }
                    } else if items.isEmpty {
                        Text("还没有评论").font(.footnote).foregroundStyle(.themeTextSecondary).frame(maxWidth: .infinity)
                    }
                }
                .padding(16)
            }
            .onChange(of: highlight) { _, h in
                guard let h else { return }
                withAnimation(.snappy) { proxy.scrollTo(h, anchor: .center) }
            }
            }
            if !relatedWords.isEmpty {
                Divider()
                ScrollView(.horizontal) {
                    HStack(spacing: 12) {
                        Text("相关搜索").font(.caption).foregroundStyle(.themeTextSecondary)
                        ForEach(relatedWords, id: \.self) { word in
                            Button { relatedQuery = DYRelatedQuery(word: word) } label: {
                                Label(word, systemImage: "magnifyingglass")
                                    .font(.footnote).lineLimit(1)
                                    .foregroundStyle(theme.accent.color(for: scheme))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                }
                .scrollIndicators(.hidden)
                .accessibilityIdentifier("douyin.comments.relatedSearch")
            }
            Divider()
            inputBar
        }
        .background(GlassBackground())
        .modifier(DYRailReservedNudge())
        .task(id: aweme.id) { relatedWords = await bridge.relatedSearch(for: aweme) }
        .fullScreenCover(item: $relatedQuery) { query in
            DYRelatedSearchScreen(bridge: bridge, word: query.word)
        }
    }

    private var inputBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showAt { atPanel }
            if let r = replyTo {
                HStack {
                    Text("回复 @\(r.name)").font(.caption).foregroundStyle(.themeTextSecondary).lineLimit(1)
                    Spacer()
                    Button { replyTo = nil; replyParent = nil } label: { Image(systemName: "xmark.circle.fill").font(.caption) }
                        .buttonStyle(.plain).foregroundStyle(.themeTextSecondary)
                }
            }
            if let e = sendErr {
                Text(e).font(.caption2).foregroundStyle(theme.status.danger.color(for: scheme))
            }
            HStack(spacing: 8) {
                Button {
                    showEmoji.toggle()
                    showAt = false
                    if showEmoji, emojis.isEmpty { Task { emojis = await bridge.emojiList() } }
                } label: {
                    Image(systemName: showEmoji ? "keyboard" : "face.smiling")
                        .font(.body).foregroundStyle(showEmoji ? theme.accent.color(for: scheme) : .themeTextSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("douyin.comment.emoji")
                Button {
                    showAt.toggle()
                    showEmoji = false
                    if showAt { Task { await loadFriends() } }
                } label: {
                    Image(systemName: "at").font(.body.weight(.medium))
                        .foregroundStyle(showAt ? theme.accent.color(for: scheme) : .themeTextSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("douyin.comment.at")
                TextField(replyTo == nil ? "说点什么…" : "回复 \(replyTo!.name)", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($inputFocused)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                    .accessibilityIdentifier("douyin.comment.input")
                Button { Task { await send() } } label: {
                    if sending { ProgressView().controlSize(.small) }
                    else { Image(systemName: "paperplane.fill").font(.body.weight(.semibold)) }
                }
                .buttonStyle(.plain)
                .foregroundStyle(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.secondary : theme.accent.color(for: scheme))
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
                .accessibilityIdentifier("douyin.comment.send")
            }
            if showEmoji {
                if emojis.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.mini)
                        Text("加载表情…").font(.caption2).foregroundStyle(.themeTextSecondary)
                    }
                    .frame(height: 60)
                } else {
                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 8), spacing: 8) {
                            ForEach(emojis) { e in
                                Button { draft += e.displayName } label: {
                                    CachedAsyncImage(url: e.url.flatMap(URL.init(string:))) { img in
                                        img.resizable().scaledToFit()
                                    } placeholder: { Color.clear }
                                    .frame(width: 30, height: 30)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(height: 150)
                    .accessibilityIdentifier("douyin.comment.emojis")
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .task { await DYEmojiStore.shared.load(bridge: bridge) }
    }

    /// 拉「我关注的人」给 @ 面板用
    private func loadFriends() async {
        guard friends.isEmpty, !atLoading else { return }
        atLoading = true
        defer { atLoading = false }
        do {
            let r = try await bridge.followingUsers()
            friends = r.items
            atError = r.items.isEmpty ? "没拿到关注列表（可能未登录）" : nil
        } catch {
            atError = "关注列表加载失败：\(error.localizedDescription)"
        }
    }

    /// @ 面板：优先「我关注的人」，拿不到时退回本视频评论区里的人
    @ViewBuilder
    private var atPanel: some View {
        let people: [DYFriend] = friends.isEmpty
            ? atCandidates.map { DYFriend(name: $0.name, avatar: $0.avatar, secUid: $0.id) }
            : friends
        // 跟抖音一致：输入框上方一排头像 + 昵称，横滑
        VStack(alignment: .leading, spacing: 4) {
            if atLoading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("加载朋友…").font(.caption2).foregroundStyle(.themeTextSecondary)
                }
                .padding(.vertical, 8)
            } else if people.isEmpty {
                Text(atError ?? "没有可 @ 的人").font(.caption2).foregroundStyle(.themeTextSecondary)
                    .padding(.vertical, 8)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 18) {
                        ForEach(people, id: \.id) { u in
                            Button {
                                draft += "@\(u.name) "
                                showAt = false
                                inputFocused = true
                            } label: {
                                VStack(spacing: 5) {
                                    CachedAsyncImage(url: u.avatar.flatMap(URL.init(string:))) { img in
                                        img.resizable().scaledToFill()
                                    } placeholder: { Color.primary.opacity(0.08) }
                                    .frame(width: 50, height: 50).clipShape(Circle())
                                    Text(u.name)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.themeTextPrimary)
                                        .lineLimit(1)
                                        .frame(width: 56)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.vertical, 6)
                }
                .frame(height: 92)
            }
        }
        .padding(.top, 2)
    }

    /// @ 候选：评论作者 + 楼中楼作者，去重
    private var atCandidates: [DYComment] {
        var seen = Set<String>()
        var out: [DYComment] = []
        for c in items {
            if seen.insert(c.name).inserted { out.append(c) }
            for r in replies[c.id] ?? [] where seen.insert(r.name).inserted { out.append(r) }
        }
        return Array(out.prefix(30))
    }

    private func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        sending = true
        defer { sending = false }
        do {
            // 回楼中楼：reply_id 必须是一级评论，被回的那条放 reply_to_reply_id（网页同款）
            let top = replyParent ?? replyTo?.id
            let c = try await bridge.publishComment(aweme.id, text: text, replyID: top,
                                                    replyToReplyID: replyParent == nil ? nil : replyTo?.id)
            if let top {
                replies[top, default: []].insert(c, at: 0)
            } else {
                items.insert(c, at: 0)
                total += 1
            }
            draft = ""; replyTo = nil; replyParent = nil; sendErr = nil
            inputFocused = false
        } catch {
            sendErr = "发送失败：\(error.localizedDescription)"
        }
    }

    private func row(_ c: DYComment, parent: String?) -> some View {
        rowBody(c)
            .contentShape(Rectangle())
            .onTapGesture { replyTo = c; replyParent = parent ?? c.parent; inputFocused = true }
            .padding(highlight == c.id ? 6 : 0)
            .background {
                if highlight == c.id {
                    RoundedRectangle(cornerRadius: 10).fill(theme.accent.color(for: scheme).opacity(0.16))
                }
            }
            .accessibilityIdentifier(highlight == c.id ? "douyin.comment.focused" : "douyin.comment.row")
    }

    private func rowBody(_ c: DYComment) -> some View {
        HStack(alignment: .top, spacing: 10) {
            CachedAsyncImage(url: c.avatar.flatMap(URL.init(string:))) { img in img.resizable().scaledToFill() }
                placeholder: { Color.primary.opacity(0.08) }
                .frame(width: 32, height: 32).clipShape(Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(c.name).font(.caption.weight(.semibold)).foregroundStyle(.themeTextSecondary)
                if !c.text.isEmpty {
                    DYEmojiStore.shared.rich(c.text).font(.subheadline).foregroundStyle(.themeTextPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                DYCommentMedia(comment: c)
                HStack(spacing: 8) {
                    Text(DYFormat.time(c.time))
                    if let ip = c.ip, !ip.isEmpty { Text(ip) }
                }
                .font(.caption2).foregroundStyle(.themeTextSecondary)
            }
            Spacer(minLength: 4)
            commentDigg(c)
        }
    }

    private func commentDigg(_ c: DYComment) -> some View {
        let on = digged.contains(c.id)
        let n = diggShown[c.id] ?? c.digg
        return Button { Task { await toggleDigg(c) } } label: {
            VStack(spacing: 2) {
                Image(systemName: on ? "heart.fill" : "heart").font(.caption)
                Text(DYFormat.count(max(0, n))).font(.caption2)
            }
            .foregroundStyle(on ? theme.status.danger.color(for: scheme) : Color.themeTextSecondary)
            .frame(minWidth: 32, minHeight: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("douyin.comment.digg")
    }

    private func toggleDigg(_ c: DYComment) async {
        let want = !digged.contains(c.id)
        let before = diggShown[c.id] ?? c.digg
        if want { digged.insert(c.id) } else { digged.remove(c.id) }
        diggShown[c.id] = max(0, before + (want ? 1 : -1))
        do {
            switch try await bridge.diggComment(c.id, awemeID: aweme.id, like: want) {
            case .ok:
                break
            case .notLoggedIn:
                revertDigg(c, want: want, before: before)
                sendErr = "抖音未登录"
            case .failed(let why):
                revertDigg(c, want: want, before: before)
                sendErr = why
            }
        } catch {
            revertDigg(c, want: want, before: before)
            sendErr = error.localizedDescription
        }
    }

    private func revertDigg(_ c: DYComment, want: Bool, before: Int) {
        if want { digged.remove(c.id) } else { digged.insert(c.id) }
        diggShown[c.id] = before
    }

    @ViewBuilder
    private func replyBlock(_ c: DYComment) -> some View {
        let got = replies[c.id] ?? []
        VStack(alignment: .leading, spacing: 10) {
            ForEach(got) { r in row(r, parent: c.id).id(r.id) }
            if replyErr[c.id] != nil {
                Button { replyErr[c.id] = nil; Task { await loadReplies(c) } } label: {
                    Text("回复加载失败，点此重试").font(.caption).foregroundStyle(.themeTextSecondary)
                }
                .buttonStyle(.plain)
                .padding(.top, 12)
            } else if replies[c.id] == nil || (replyMore[c.id] ?? false) {
                Button { Task { await loadReplies(c) } } label: {
                    HStack(spacing: 6) {
                        Rectangle().fill(Color.secondary.opacity(0.5)).frame(width: 18, height: 1)
                        Text(replies[c.id] == nil ? "展开 \(c.replies) 条回复" : "展开更多回复")
                        if replyLoading.contains(c.id) { ProgressView().controlSize(.mini) }
                    }
                    .font(.caption.weight(.medium)).foregroundStyle(.themeTextSecondary)
                }
                .buttonStyle(.plain)
                // 和上方回复拉开距离，避免误点到回复评论
                .padding(.top, 12)
                .accessibilityIdentifier("douyin.replies")
            }
        }
        .padding(.leading, 42)
    }

    /// insert_ids 回来后：一级评论已在第一条；楼中楼挂在它的 pinned 里，先塞进回复区再高亮
    private func applyFocus(_ f: DYCommentFocus, page: [DYComment]) {
        // 接口两种形态（2026-11 实测）：
        // A. 一级评论排第一，楼中楼挂在它的 reply_comment 里；
        // B. 一级评论没回来时，楼中楼本身直接排在一级列表第一条（reply_id = 一级评论）。
        let top = f.parentCid ?? f.cid
        var target: String?
        if let head = page.first(where: { $0.id == top }) {
            if f.parentCid != nil, let pinned = head.pinned, !pinned.isEmpty {
                replies[top] = pinned
                replyMore[top] = head.replies > pinned.count
            }
            target = (replies[top] ?? []).contains { $0.id == f.cid } ? f.cid : top
        }
        if target == nil || target == top, page.contains(where: { $0.id == f.cid }) { target = f.cid }
        guard let target else {
            focusMiss = true
            DYLiveModel.log("DDFOCUS miss aweme=\(f.awemeID) cid=\(f.cid) parent=\(f.parentCid ?? "-")")
            return
        }
        let head = page.first(where: { $0.id == top })
        DYLiveModel.log("DDFOCUS hit aweme=\(f.awemeID) cid=\(f.cid) parent=\(f.parentCid ?? "-") target=\(target) pinned=\(head?.pinned?.count ?? 0)")
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            highlight = target
            try? await Task.sleep(for: .seconds(6))
            withAnimation(.easeOut(duration: 0.8)) { if highlight == target { highlight = nil } }
        }
    }

    private func loadReplies(_ c: DYComment) async {
        guard !replyLoading.contains(c.id) else { return }
        replyLoading.insert(c.id)
        defer { replyLoading.remove(c.id) }
        do {
            let r = try await bridge.fetchReplies(aweme.id, commentID: c.id, cursor: replyCursor[c.id] ?? 0)
            DYLiveModel.log("DDREPLY cid=\(c.id) n=\(r.items.count) first=\(r.items.first?.text ?? "-")")
            let seen = Set((replies[c.id] ?? []).map(\.id))
            replies[c.id, default: []].append(contentsOf: r.items.filter { !seen.contains($0.id) })
            replyCursor[c.id] = r.cursor
            replyMore[c.id] = r.hasMore && !r.items.isEmpty
            replyErr[c.id] = nil
        } catch {
            DYLiveModel.log("DDREPLY cid=\(c.id) error=\(error)")
            replyErr[c.id] = "回复加载失败：\(error.localizedDescription)"
        }
    }

    private func load() async {
        guard !loading, hasMore else { return }
        loading = true
        defer { loading = false }
        do {
            let first = cursor == 0 && items.isEmpty
            let ins = first ? focus.map { f in [f.parentCid, f.cid].compactMap { $0 }.joined(separator: ",") } : nil
            let r = try await bridge.fetchComments(aweme.id, cursor: cursor, insert: ins)
            let seen = Set(items.map(\.id))
            items.append(contentsOf: r.items.filter { !seen.contains($0.id) })
            if let f = focus, first { applyFocus(f, page: r.items) }
            for c in r.items where c.userDigged == 1 { digged.insert(c.id) }
            cursor = r.cursor
            hasMore = r.hasMore && !r.items.isEmpty
            total = max(total, r.total, aweme.stats.comment)
            error = nil
            #if DEBUG
            if ProcessInfo.processInfo.environment["DOUDUO_AUTOREPLY"] == "1", let c = items.first(where: { $0.replies > 0 }), replies[c.id] == nil {
                Task { await loadReplies(c) }
            }
            #endif
        } catch {
            self.error = error.localizedDescription
            hasMore = false
        }
    }
}

// MARK: - 评论表情

/// 评论输入框的表情面板（纯 emoji，跟着文字一起发，不依赖抖音的表情包接口）
enum DYCommentEmoji {
    static let all: [String] = [
        "😀", "😄", "😁", "😂", "🤣", "😊", "😍", "🥰",
        "😘", "😎", "🤩", "🥳", "😏", "😅", "😅", "🙃",
        "😢", "😭", "😤", "😡", "🤬", "😱", "😨", "😰",
        "🤔", "🤨", "😐", "😑", "🙄", "😴", "🥱", "🤯",
        "😳", "🥺", "😬", "🤐", "🤫", "🤭", "😷", "🤒",
        "👍", "👎", "👏", "🙏", "💪", "🤝", "👌", "✌️",
        "👊", "🫶", "❤️", "💔", "🔥", "🎉", "🎊", "💯",
        "⭐", "✨", "🌹", "🌸", "🍺", "🍻", "☕", "🧋",
        "🍜", "🍚", "🍗", "🍰", "🎮", "⚽", "🏀", "🚀",
        "💰", "🎁", "🐶", "🐱", "🐼", "🦁", "🐸", "🦄"
    ]
}

// MARK: - 评论配图 / 表情包贴纸

/// 评论里的图片与贴纸：缩略图按原比例限高显示，点开全屏横滑看原图（同图集用 TabView 分页）
struct DYCommentMedia: View {
    let comment: DYComment
    @State private var viewer: DYCommentViewerTarget?

    private var pics: [DYCommentImage] { comment.images ?? [] }

    var body: some View {
        content.fullScreenCover(item: $viewer) { t in DYCommentImageViewer(target: t) }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) { media }
    }

    @ViewBuilder
    private var media: some View {
        if let s = comment.sticker {
            // 贴纸：表情包尺寸，不放大
            thumb(s, maxSide: 96)
                .onTapGesture { viewer = DYCommentViewerTarget(images: [s], start: 0) }
                .accessibilityIdentifier("douyin.comment.sticker")
        }
        if !pics.isEmpty {
            HStack(spacing: 6) {
                ForEach(Array(pics.prefix(3).enumerated()), id: \.offset) { i, img in
                    thumb(img, maxSide: pics.count == 1 ? 160 : 96)
                        .overlay(alignment: .bottomTrailing) {
                            if i == 2, pics.count > 3 {
                                Text("+\(pics.count - 3)").font(.caption.weight(.bold)).foregroundStyle(.white)
                                    .padding(4).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
                                    .padding(4)
                            }
                        }
                        .onTapGesture { viewer = DYCommentViewerTarget(images: pics, start: i) }
                }
            }
            .accessibilityIdentifier("douyin.comment.images")
        }
    }

    private func thumb(_ img: DYCommentImage, maxSide: CGFloat) -> some View {
        let ratio = (img.w > 0 && img.h > 0) ? img.w / img.h : 1
        let w = ratio >= 1 ? maxSide : maxSide * ratio
        let h = ratio >= 1 ? maxSide / ratio : maxSide
        return CachedAsyncImage(url: URL(string: img.thumb)) { i in i.resizable().scaledToFill() }
            placeholder: { Color.primary.opacity(0.08) }
            .frame(width: max(w, 44), height: max(h, 44))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
    }
}

struct DYCommentViewerTarget: Identifiable {
    let id = UUID()
    let images: [DYCommentImage]
    let start: Int
}

struct DYCommentImageViewer: View {
    let target: DYCommentViewerTarget
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            TabView(selection: $page) {
                ForEach(Array(target.images.enumerated()), id: \.offset) { i, img in
                    CachedAsyncImage(url: URL(string: img.full)) { v in v.resizable().scaledToFit() }
                        placeholder: { ProgressView().tint(.white) }
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: target.images.count > 1 ? .always : .never))
            .ignoresSafeArea()
            .onTapGesture { dismiss() }
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.headline.weight(.semibold)).foregroundStyle(.white)
                    .frame(width: 44, height: 44).background(Circle().fill(.black.opacity(0.4)))
            }
            .padding(16)
            .accessibilityIdentifier("douyin.comment.viewer.close")
        }
        .onAppear { page = target.start }
    }
}
