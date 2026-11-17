// Apple Watch 伴侣：iPhone 端服务。
// 手表不登录、不直接请求抖音接口：登录态和接口签名都在 iPhone 的隐藏网页里。
// 手表向这里要：可播视频的「链接清单」（不是视频文件）；点赞也由这里代发。手表不做消息功能。
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
    private static let seenKey = "dd_watch_seen_v1"
    /// 手表已经看过（或被划走）的作品 id：补货时不再给手表，避免手机推荐流重复推同一条。最多留 2000 条
    private func seenIDs() -> [String] { UserDefaults.standard.stringArray(forKey: Self.seenKey) ?? [] }
    private func markSeen(_ id: String) {
        var l = seenIDs()
        guard !l.contains(id) else { return }
        l.append(id)
        UserDefaults.standard.set(Array(l.suffix(2000)), forKey: Self.seenKey)
        savePool(loadPool())     // 顺手把已看的从保存的清单里剔掉
    }

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
    #endif

    private func currentStatus() async -> DDWatchStatus {
        #if DEBUG
        if Self.fixture { return DDWatchStatus(loggedIn: true, updated: Date().timeIntervalSince1970) }
        #endif
        let cache = DYMessageCache.shared
        await cache.prepare()
        var st = DDWatchStatus()
        st.loggedIn = cache.hasSession
        st.updated = Date().timeIntervalSince1970
        return st
    }

    // MARK: 视频链接清单

    private func loadPool() -> [DDWatchVideoMeta] {
        guard let d = UserDefaults.standard.data(forKey: Self.poolKey),
              let list = try? JSONDecoder().decode([DDWatchVideoMeta].self, from: d) else { return [] }
        let now = Date().timeIntervalSince1970
        // 只留重定向地址：直连 CDN 地址现在一律 403；手表已看过的不再给
        let seen = Set(seenIDs())
        return list.filter { now - $0.fetched < Self.maxAge && $0.url.contains("/aweme/v1/play/") && !seen.contains($0.id) }
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
            for a in await candidates(limit: need, have: Set(pool.map(\.id)).union(seenIDs())) {
                // ⚠️ 只能用 play（/aweme/v1/play/ 重定向地址）：playFast/playAlt 是直连 CDN，现在一律 403
                guard let url = a.play else { continue }
                pool.append(DDWatchVideoMeta(id: a.id, desc: a.desc, author: a.author.name, duration: a.duration,
                                             liked: a.userDigged == 1, width: a.width, height: a.height,
                                             url: url, authorUID: a.author.uid ?? "", awemeType: a.awemeType ?? 0, fetched: now))
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

    /// 手表看完/划走一条：记入已看表，并向抖音上报观看（和手机推荐流同一个接口，账号才知道你看过、不再重复推）
    private func reportSeen(_ m: [String: Any]) async {
        guard let id = m[DDWatchKey.id] as? String, !id.isEmpty else { return }
        markSeen(id)
        let prev = m["pre"] as? String ?? ""
        let seenFull = m["full"] as? Bool ?? false
        #if DEBUG
        if Self.fixture { DYLiveModel.log("DDWATCH seen id=\(id) pre=\(prev) full=\(seenFull)"); return }
        #endif
        guard let bridge else { DYLiveModel.log("DDWATCH seen 仅本地记录（签名页未就绪）id=\(id)"); return }
        let aweme = DYAweme(id: id, desc: "", width: 0, height: 0, duration: m["dur"] as? Double ?? 0, play: nil, cover: nil, images: [],
                            author: .init(name: "", avatar: nil, secUid: nil, uid: m["uid"] as? String, follow: nil),
                            stats: .init(digg: 0, comment: 0, collect: 0, share: 0), music: "", userDigged: nil, isCollect: nil,
                            awemeType: m["type"] as? Int ?? 0)
        await bridge.reportWatch(aweme, preID: prev.isEmpty ? nil : prev, preSeen: seenFull)
        DYLiveModel.log("DDWATCH seen 已上报 id=\(id) full=\(seenFull)")
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
            case DDWatchCmd.videos:
                await self.refreshPool(force: false)
                reply(DDWatchCodec.pack(DDWatchList(videos: self.loadPool())))
            case DDWatchCmd.seen:
                await self.reportSeen(message)
                reply(["ok": true])
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
