import Foundation
import WatchConnectivity

/// 手表端数据：不存视频文件，只存「链接清单」，播放时用手表自己的 WiFi 直接拉流。
/// 清单和未读数/消息都落盘，手机 App 没运行、手表没连上手机时也能用上次的内容。
@MainActor
final class WatchModel: NSObject, ObservableObject {
    static let shared = WatchModel()

    @Published var status = DDWatchStatus()
    @Published var videos: [DDWatchVideoMeta] = []
    @Published var reachable = false
    @Published var activated = false
    @Published var requestingVideos = false
    @Published var notice: String?

    /// 链接放多久算可能过期（与手机端 maxAge 一致）
    static let maxAge: TimeInterval = 6 * 3600
    /// 看到只剩几条时向手机要新的
    private let lowWater = 8
    /// 已看过的 id，换清单时不再重复出现
    private var watched = Set<String>()

    nonisolated static let dir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    nonisolated private static var listURL: URL { dir.appendingPathComponent("watch-list.json") }
    nonisolated private static var watchedURL: URL { dir.appendingPathComponent("watch-seen.json") }

    override init() {
        super.init()
        if let d = try? Data(contentsOf: Self.listURL), let l = try? JSONDecoder().decode([DDWatchVideoMeta].self, from: d) { videos = l }
        if let d = try? Data(contentsOf: Self.watchedURL), let w = try? JSONDecoder().decode([String].self, from: d) { watched = Set(w) }
        dropExpired()
        // 启动清一次缓存，之后每 10 分钟一次（App 开着期间也不会越存越多）
        Task {
            await WatchCache.shared.cleanup()
            while true {
                try? await Task.sleep(nanoseconds: 600 * 1_000_000_000)
                await WatchCache.shared.cleanup()
            }
        }
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = WatchLink.shared
        WCSession.default.activate()
    }

    private func save() {
        if let d = try? JSONEncoder().encode(videos) { try? d.write(to: Self.listURL, options: .atomic) }
        if let d = try? JSONEncoder().encode(Array(watched.suffix(500))) { try? d.write(to: Self.watchedURL, options: .atomic) }
    }

    private func dropExpired() {
        let now = Date().timeIntervalSince1970
        videos.removeAll { now - $0.fetched > Self.maxAge || watched.contains($0.id) || !$0.url.contains("/aweme/v1/play/") }
    }

    /// 手机推来的最新清单：保留手表上已有的顺序，补上新的，去掉看过和过期的
    func apply(list: [DDWatchVideoMeta]) {
        let known = Set(videos.map(\.id))
        videos.append(contentsOf: list.filter { !known.contains($0.id) && !watched.contains($0.id) })
        // 手机给了更新的链接就替换（链接新鲜度以手机为准）
        for n in list { if let i = videos.firstIndex(where: { $0.id == n.id }), n.fetched > videos[i].fetched { var m = n; m.liked = videos[i].liked || n.liked; videos[i] = m } }
        dropExpired()
        save()
    }

    /// 看完/划走一条：记为已看过，列表快见底就向手机要新的
    func markWatched(_ id: String) {
        watched.insert(id)
        Task { await WatchCache.shared.remove(id) }   // 看过的不留
        if let i = videos.firstIndex(where: { $0.id == id }) {
            // 只丢掉当前条之前的，当前条留着以免翻页跳动
            if i > 0 { videos.removeFirst(i) }
        }
        save()
        if videos.count <= lowWater { Task { await requestVideos() } }
    }

    /// 链接失效（播放失败）：丢掉这条
    func drop(_ id: String) {
        videos.removeAll { $0.id == id }
        Task { await WatchCache.shared.remove(id) }
        save()
        if videos.count <= lowWater { Task { await requestVideos() } }
    }

    /// 把当前条后面的几条预存到本地
    func prefetchAhead(from id: String?) {
        guard let id, let i = videos.firstIndex(where: { $0.id == id }) else { return }
        let next = Array(videos.dropFirst(i + 1).prefix(WatchCache.ahead))
        Task { await WatchCache.shared.prefetch(next) }
    }

    // MARK: 向 iPhone 要数据

    private func send(_ msg: [String: Any], timeout: TimeInterval = 20) async -> [String: Any]? {
        let s = WCSession.default
        guard s.activationState == .activated, s.isReachable else { return nil }
        return await withCheckedContinuation { cont in
            var done = false
            let finish: ([String: Any]?) -> Void = { r in
                DispatchQueue.main.async { if !done { done = true; cont.resume(returning: r) } }
            }
            s.sendMessage(msg, replyHandler: { finish($0) }, errorHandler: { _ in finish(nil) })
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }

    func refreshStatus() async {
        guard let r = await send([DDWatchKey.cmd: DDWatchCmd.status]),
              let st = DDWatchCodec.unpack(DDWatchStatus.self, from: r) else { return }
        status = st
    }

    /// 向手机要新链接。手机没连上也无妨：手表用已有清单继续播
    func requestVideos() async {
        guard !requestingVideos, WCSession.default.isReachable else { return }
        requestingVideos = true
        defer { requestingVideos = false }
        guard let r = await send([DDWatchKey.cmd: DDWatchCmd.videos], timeout: 40),
              let l = DDWatchCodec.unpack(DDWatchList.self, from: r) else { return }
        apply(list: l.videos)
    }

    func toggleLike(_ id: String) async {
        guard let i = videos.firstIndex(where: { $0.id == id }) else { return }
        let want = !videos[i].liked
        videos[i].liked = want
        let r = await send([DDWatchKey.cmd: DDWatchCmd.like, DDWatchKey.id: id, DDWatchKey.on: want])
        if (r?["ok"] as? Bool) != true, let j = videos.firstIndex(where: { $0.id == id }) {
            videos[j].liked = !want   // 手机没响应就回滚，并提示
            notice = "点赞需要连接 iPhone"
        }
        save()
    }

    func applyContext(_ ctx: [String: Any]) {
        if let d = ctx[DDWatchKey.status] as? Data, let st = try? JSONDecoder().decode(DDWatchStatus.self, from: d) { status = st }
        if let d = ctx[DDWatchKey.list] as? Data, let l = try? JSONDecoder().decode(DDWatchList.self, from: d) { apply(list: l.videos) }
    }
}

/// WatchConnectivity 回调
final class WatchLink: NSObject, WCSessionDelegate {
    static let shared = WatchLink()

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let r = session.isReachable
        let ctx = session.receivedApplicationContext   // 系统替手表保存的最后一份：手机没运行也读得到
        Task { @MainActor in
            let m = WatchModel.shared
            m.activated = activationState == .activated
            m.reachable = r
            m.applyContext(ctx)
        }
    }
    func sessionReachabilityDidChange(_ session: WCSession) {
        let r = session.isReachable
        Task { @MainActor in
            let m = WatchModel.shared
            m.reachable = r
            // 刚连上手机：补刷清单
            if r { await m.requestVideos() }
        }
    }
    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in WatchModel.shared.applyContext(applicationContext) }
    }
}
