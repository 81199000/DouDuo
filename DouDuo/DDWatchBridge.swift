// Apple Watch 伴侣：iPhone 端服务。
// 手表不登录、不直接请求抖音接口：登录态和接口签名都在 iPhone 的隐藏网页里。
// 手表向这里要两样东西：① 未读数 / 通知 / 私信摘要；② 可播视频的「链接清单」（不是视频文件）。
// 清单经 updateApplicationContext 推送，系统替手表保存最后一份，所以手机 App 没在运行时手表也能用。
// 手表拿到链接后用自己的 WiFi 直接拉流播放。点赞由这里代发。
import Foundation
import WatchConnectivity

@MainActor
final class DDWatchBridge: NSObject {
    static let shared = DDWatchBridge()

    private weak var bridge: DouyinBridge?
    private weak var feed: DYFeedModel?
    private var refreshing = false
    private var lastRefresh = Date.distantPast

    /// 清单最多留几条；手表看过的自己删，手机每次补到这个数
    static let poolCap = 60
    /// 链接放多久算可能过期（实测放 2 小时仍可解析，这里保守取 6 小时）
    static let maxAge: TimeInterval = 6 * 3600
    /// 流播不占手表存储，只挡掉超长视频
    static let maxDuration: Double = 300
    private static let poolKey = "dd_watch_pool_v3"

    /// 启动即激活通信：手机 App 被系统唤醒时就算没有界面，也要能接住手表的请求
    func activate() {
        guard WCSession.isSupported() else { return }
        let s = WCSession.default
        if s.delegate == nil { s.delegate = self }
        if s.activationState != .activated { s.activate() }
    }

    /// 由 DYFeedShared 在创建签名页时调用；之后才能向抖音要新链接
    func attach(bridge: DouyinBridge, feed: DYFeedModel) {
        self.bridge = bridge
        self.feed = feed
        activate()
        Task { await refreshPool(force: false) }
    }

    // MARK: 状态 / 消息

    #if DEBUG
    /// 模拟器没有抖音登录态：DOUDUO_WATCH_FIXTURE=1 时消息页用假数据（视频链接是真实推荐流）
    static var fixture: Bool { ProcessInfo.processInfo.environment["DOUDUO_WATCH_FIXTURE"] != nil }
    private static let fixtureInbox: DDWatchInbox = {
        var i = DDWatchInbox()
        i.status = DDWatchStatus(loggedIn: true, comment: 3, digg: 12, fans: 1, system: 0, chat: 2, updated: Date().timeIntervalSince1970)
        i.fresh = true
        i.notices = [
            DDWatchNotice(id: "n1", name: "小鹿", action: "评论了你的作品", detail: "这个转场太丝滑了", time: Date().timeIntervalSince1970 - 300, unread: true),
            DDWatchNotice(id: "n2", name: "阿远", action: "赞了你的作品", detail: "", time: Date().timeIntervalSince1970 - 3600, unread: true),
            DDWatchNotice(id: "n3", name: "木木", action: "关注了你", detail: "", time: Date().timeIntervalSince1970 - 86400, unread: false),
        ]
        i.chats = [
            DDWatchChat(id: "c1", name: "小鹿", preview: "晚上要不要一起吃饭？", time: "刚刚", badge: 2),
            DDWatchChat(id: "c2", name: "阿远", preview: "[视频] 看看这个", time: "昨天", badge: 0),
        ]
        return i
    }()
    #endif

    private func currentStatus() async -> DDWatchStatus {
        #if DEBUG
        if Self.fixture { return Self.fixtureInbox.status }
        #endif
        let cache = DYMessageCache.shared
        await cache.prepare()
        var st = DDWatchStatus()
        st.loggedIn = cache.hasSession
        st.updated = Date().timeIntervalSince1970
        guard st.loggedIn else { return st }
        var counts = cache.snapshot.counts
        if let bridge, let values = try? await bridge.noticeCounts() {
            counts = Dictionary(values.map { ($0.group, $0.count) }, uniquingKeysWith: { a, _ in a })
        }
        st.comment = counts[DYNoticeGroup.comment.rawValue] ?? 0
        st.digg = counts[DYNoticeGroup.digg.rawValue] ?? 0
        st.fans = counts[DYNoticeGroup.fans.rawValue] ?? 0
        st.system = counts[DYNoticeGroup.system.rawValue] ?? 0
        st.chat = cache.snapshot.conversations.reduce(0) { $0 + (Int($1.badge) ?? 0) }
        return st
    }

    private func buildInbox() async -> DDWatchInbox {
        #if DEBUG
        if Self.fixture { return Self.fixtureInbox }
        #endif
        var out = DDWatchInbox()
        out.status = await currentStatus()
        guard out.status.loggedIn else { return out }
        let cache = DYMessageCache.shared
        var page = cache.page(DYNoticeGroup.all.rawValue)
        if let bridge, let fresh = try? await cache.refresh(DYNoticeGroup.all.rawValue, bridge: bridge) {
            page = fresh
            out.fresh = true
        }
        out.notices = (page?.items ?? []).prefix(20).map {
            DDWatchNotice(id: $0.id, name: $0.name, action: $0.action, detail: $0.detail,
                          time: $0.time, unread: !$0.hasRead)
        }
        let hidden = Set(cache.hiddenConversations.keys)
        out.chats = cache.snapshot.conversations.filter { !hidden.contains($0.id) }.prefix(20).map {
            DDWatchChat(id: $0.id, name: $0.name, preview: $0.preview, time: $0.time, badge: Int($0.badge) ?? 0)
        }
        return out
    }

    // MARK: 视频链接清单

    private func loadPool() -> [DDWatchVideoMeta] {
        guard let d = UserDefaults.standard.data(forKey: Self.poolKey),
              let list = try? JSONDecoder().decode([DDWatchVideoMeta].self, from: d) else { return [] }
        let now = Date().timeIntervalSince1970
        // 只留重定向地址：直连 CDN 地址现在一律 403
        return list.filter { now - $0.fetched < Self.maxAge && $0.url.contains("/aweme/v1/play/") }
    }
    private func savePool(_ list: [DDWatchVideoMeta]) {
        if let d = try? JSONEncoder().encode(list) { UserDefaults.standard.set(d, forKey: Self.poolKey) }
    }

    private func candidates(limit: Int, have: Set<String>) async -> [DYAweme] {
        guard let bridge, let feed else { return [] }
        var picked: [DYAweme] = []
        var seen = have
        for _ in 0..<8 where picked.count < limit {
            guard let page = try? await bridge.fetchFeed() else { break }
            for a in feed.allowedRecommendations(page.items) {
                guard picked.count < limit, seen.insert(a.id).inserted,
                      a.images.isEmpty, a.play != nil,
                      a.duration >= 1, a.duration <= Self.maxDuration else { continue }
                picked.append(a)
            }
        }
        DYLiveModel.log("DDWATCH feed 取到 \(picked.count)/\(limit)")
        return picked
    }

    /// 补满清单并推给手表。force=false 时 2 分钟内不重复向抖音取
    func refreshPool(force: Bool) async {
        guard !refreshing else { return }
        if !force, Date().timeIntervalSince(lastRefresh) < 120 { await publish(loadPool()); return }
        refreshing = true
        defer { refreshing = false }
        lastRefresh = Date()
        var pool = loadPool()
        let need = min(24, Self.poolCap - pool.count)
        if need > 0 {
            let now = Date().timeIntervalSince1970
            for a in await candidates(limit: need, have: Set(pool.map(\.id))) {
                // ⚠️ 只能用 play（/aweme/v1/play/ 重定向地址）：playFast/playAlt 是直连 CDN，现在一律 403
                guard let url = a.play else { continue }
                pool.append(DDWatchVideoMeta(id: a.id, desc: a.desc, author: a.author.name, duration: a.duration,
                                             liked: a.userDigged == 1, width: a.width, height: a.height,
                                             url: url, fetched: now))
            }
            pool = Array(pool.suffix(Self.poolCap))
            savePool(pool)
        }
        DYLiveModel.log("DDWATCH 清单 \(pool.count) 条")
        await publish(pool)
    }

    /// context 整体替换，所以每次都把状态和清单一起发
    private func publish(_ pool: [DDWatchVideoMeta]) async {
        guard WCSession.default.activationState == .activated, WCSession.default.isWatchAppInstalled else { return }
        let st = await currentStatus()
        let ctx: [String: Any] = [
            DDWatchKey.status: (try? JSONEncoder().encode(st)) ?? Data(),
            DDWatchKey.list: (try? JSONEncoder().encode(DDWatchList(videos: pool))) ?? Data(),
        ]
        do { try WCSession.default.updateApplicationContext(ctx) }
        catch { DYLiveModel.log("DDWATCH context 失败 \(error.localizedDescription)") }
    }

    private func like(_ id: String, on: Bool) async -> Bool {
        #if DEBUG
        if Self.fixture { DYLiveModel.log("DDWATCH like id=\(id) on=\(on)"); return true }
        #endif
        guard let bridge else { return false }
        if case .ok? = try? await bridge.digg(id, like: on) { return true }
        return false
    }

    // MARK: 命令分发

    fileprivate func handle(_ message: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        let cmd = message[DDWatchKey.cmd] as? String ?? ""
        Task { @MainActor in
            switch cmd {
            case DDWatchCmd.status:
                reply(DDWatchCodec.pack(await self.currentStatus()))
            case DDWatchCmd.inbox:
                reply(DDWatchCodec.pack(await self.buildInbox()))
            case DDWatchCmd.videos:
                await self.refreshPool(force: false)
                reply(DDWatchCodec.pack(DDWatchList(videos: self.loadPool())))
            case DDWatchCmd.like:
                let ok = await self.like(message[DDWatchKey.id] as? String ?? "", on: message[DDWatchKey.on] as? Bool ?? true)
                reply(["ok": ok])
            default:
                reply([:])
            }
        }
    }
}

extension DDWatchBridge: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        guard activationState == .activated else { return }
        Task { @MainActor in await self.refreshPool(force: false) }
    }
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in await self.refreshPool(force: false) }
    }
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        nonisolated(unsafe) let reply = replyHandler
        Task { @MainActor in self.handle(message, reply: reply) }
    }
}
