// Apple Watch 伴侣：iPhone 端服务。
// 手表不登录、不直接请求抖音：登录态、接口签名都在 iPhone 的隐藏 WKWebView 里，
// 手表通过 WatchConnectivity 向这里要数据——未读数 / 通知 / 私信列表（文字摘要），
// 以及转成小码率的短视频文件（transferFile 推过去，手表本地播放）。点赞也由这里代发。
import Foundation
import AVFoundation
import WatchConnectivity

@MainActor
final class DDWatchBridge: NSObject {
    static let shared = DDWatchBridge()

    private weak var bridge: DouyinBridge?
    private weak var feed: DYFeedModel?
    private var pushing = false

    /// 手表一次最多缓存几条；超过的由手表自己删最早的
    static let batch = 4
    /// 只给手表推不超过这个时长的视频（秒）：手表存储小、蓝牙传输慢
    static let maxDuration: Double = 90
    private static let sentKey = "dd_watch_sent_v1"

    /// 由 DYFeedShared 在创建签名页时调用；之后手表才能取到数据
    func attach(bridge: DouyinBridge, feed: DYFeedModel) {
        self.bridge = bridge
        self.feed = feed
        guard WCSession.isSupported() else { return }
        let s = WCSession.default
        if s.delegate == nil { s.delegate = self }
        if s.activationState != .activated { s.activate() }
    }

    // MARK: 状态 / 消息

    private func currentStatus() async -> DDWatchStatus {
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

    func pushStatusContext() async {
        guard WCSession.default.activationState == .activated else { return }
        let st = await currentStatus()
        try? WCSession.default.updateApplicationContext([DDWatchKey.status: (try? JSONEncoder().encode(st)) ?? Data()])
    }

    // MARK: 视频

    private func sentSet() -> [String] { UserDefaults.standard.stringArray(forKey: Self.sentKey) ?? [] }
    private func markSent(_ id: String) {
        var l = sentSet(); l.append(id)
        UserDefaults.standard.set(Array(l.suffix(300)), forKey: Self.sentKey)
    }

    private func candidates(limit: Int, have: Set<String>) async -> [DYAweme] {
        guard let bridge, let feed else { return [] }
        let skip = have.union(sentSet())
        var picked: [DYAweme] = []
        var seen = Set<String>()
        for _ in 0..<4 where picked.count < limit {
            guard let page = try? await bridge.fetchFeed() else { break }
            for a in feed.allowedRecommendations(page.items) {
                guard picked.count < limit, !skip.contains(a.id), seen.insert(a.id).inserted,
                      a.images.isEmpty, a.play != nil,
                      a.duration >= 1, a.duration <= Self.maxDuration else { continue }
                picked.append(a)
            }
        }
        return picked
    }

    private static let outDir: URL = {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("dd-watch-out", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    /// 取源文件（本地完整缓存优先，否则带浏览器 UA/Referer 下载）→ 转成手表能轻松播放的小分辨率 mp4
    private func makeWatchFile(for a: DYAweme) async throws -> URL {
        let src: URL
        let local = DYVideoCache.fileURL(a.id)
        if (try? local.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0 > 0 {
            src = local
        } else {
            guard let s = a.play, let u = URL(string: s) else { throw DYError.bad("无播放地址") }
            var req = URLRequest(url: u)
            req.timeoutInterval = 30
            DYMedia.headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
            let (tmp, resp) = try await URLSession.shared.download(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw DYError.bad("下载失败 HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
            }
            let keep = Self.outDir.appendingPathComponent("src-\(a.id).mp4")
            try? FileManager.default.removeItem(at: keep)
            try FileManager.default.moveItem(at: tmp, to: keep)
            src = keep
        }
        defer { if src != local { try? FileManager.default.removeItem(at: src) } }

        let dst = Self.outDir.appendingPathComponent("\(a.id).mp4")
        try? FileManager.default.removeItem(at: dst)
        let asset = AVURLAsset(url: src)
        guard let ex = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset640x480) else {
            throw DYError.bad("无法转码")
        }
        try await ex.export(to: dst, as: .mp4)
        return dst
    }

    /// 给手表推新视频。`have` 是手表已存的 id，不重复推。
    func pushVideos(have: [String]) async -> Int {
        guard !pushing, WCSession.default.activationState == .activated, WCSession.default.isWatchAppInstalled else { return 0 }
        pushing = true
        defer { pushing = false }
        let queued = WCSession.default.outstandingFileTransfers.count
        let want = max(0, Self.batch - queued)
        guard want > 0 else { return 0 }
        var sent = 0
        for a in await candidates(limit: want, have: Set(have)) {
            do {
                let url = try await makeWatchFile(for: a)
                let meta = DDWatchVideoMeta(id: a.id, desc: a.desc, author: a.author.name, duration: a.duration,
                                            liked: a.userDigged == 1, width: a.width, height: a.height)
                let dict = (try? JSONEncoder().encode(meta)).map { [DDWatchKey.json: $0] } ?? [:]
                WCSession.default.transferFile(url, metadata: dict)
                markSent(a.id)
                sent += 1
                DYLiveModel.log("DDWATCH push id=\(a.id) dur=\(Int(a.duration))s")
            } catch {
                DYLiveModel.log("DDWATCH push 失败 id=\(a.id) \(error.localizedDescription)")
            }
        }
        return sent
    }

    private func like(_ id: String, on: Bool) async -> Bool {
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
                let have = message["have"] as? [String] ?? []
                reply(["queued": true])
                let n = await self.pushVideos(have: have)
                DYLiveModel.log("DDWATCH videos 请求 → 推送 \(n) 条")
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
        Task { @MainActor in await self.pushStatusContext() }
    }
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in await self.pushStatusContext() }
    }
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        nonisolated(unsafe) let reply = replyHandler
        Task { @MainActor in self.handle(message, reply: reply) }
    }
    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        try? FileManager.default.removeItem(at: fileTransfer.file.fileURL)
        if let error { DYLiveModel.log("DDWATCH 传输失败 \(error.localizedDescription)") }
    }
}
