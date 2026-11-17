import Foundation
import WatchConnectivity

@MainActor
final class WatchModel: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = WatchModel()

    @Published var status = DDWatchStatus()
    @Published var inbox = DDWatchInbox()
    @Published var videos: [DDWatchVideoMeta] = []
    @Published var reachable = false
    @Published var activated = false
    @Published var loadingInbox = false
    @Published var requestingVideos = false
    @Published var inboxError: String?

    /// 手表上最多留这么多条，播过的先删
    private let keep = 8

    nonisolated static let dir: URL = {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("videos", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    nonisolated static func fileURL(_ id: String) -> URL { dir.appendingPathComponent("\(id).mp4") }
    nonisolated private static var indexURL: URL { dir.appendingPathComponent("index.json") }

    override init() {
        super.init()
        if let d = try? Data(contentsOf: Self.indexURL),
           let list = try? JSONDecoder().decode([DDWatchVideoMeta].self, from: d) {
            videos = list.filter { FileManager.default.fileExists(atPath: Self.fileURL($0.id).path) }
        }
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    private func saveIndex() {
        if let d = try? JSONEncoder().encode(videos) { try? d.write(to: Self.indexURL, options: .atomic) }
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

    func refreshInbox() async {
        loadingInbox = true
        defer { loadingInbox = false }
        guard let r = await send([DDWatchKey.cmd: DDWatchCmd.inbox], timeout: 30),
              let box = DDWatchCodec.unpack(DDWatchInbox.self, from: r) else {
            inboxError = reachable ? "iPhone 没有响应" : "未连接 iPhone"
            return
        }
        inboxError = nil
        inbox = box
        status = box.status
    }

    func refreshStatus() async {
        guard let r = await send([DDWatchKey.cmd: DDWatchCmd.status]),
              let st = DDWatchCodec.unpack(DDWatchStatus.self, from: r) else { return }
        status = st
    }

    /// 播放列表快见底时，请 iPhone 再推几条
    func requestVideos() async {
        guard !requestingVideos else { return }
        requestingVideos = true
        defer { requestingVideos = false }
        _ = await send([DDWatchKey.cmd: DDWatchCmd.videos, "have": videos.map(\.id)])
        // 文件传输是异步的，iPhone 转码 + 蓝牙传输需要一阵，这里只负责发请求，到了会自动出现在列表里
        try? await Task.sleep(nanoseconds: 3_000_000_000)
    }

    func toggleLike(_ id: String) async {
        guard let i = videos.firstIndex(where: { $0.id == id }) else { return }
        let want = !videos[i].liked
        videos[i].liked = want
        let r = await send([DDWatchKey.cmd: DDWatchCmd.like, DDWatchKey.id: id, DDWatchKey.on: want])
        if (r?["ok"] as? Bool) != true, let j = videos.firstIndex(where: { $0.id == id }) {
            videos[j].liked = !want   // 没成功就回滚
        }
        saveIndex()
    }

    /// 播过的视频删掉，腾出手表空间
    func prune(keepingFrom id: String?) {
        guard let id, let idx = videos.firstIndex(where: { $0.id == id }) else { return }
        let drop = max(0, idx - 1)
        if drop > 0 {
            for m in videos.prefix(drop) { try? FileManager.default.removeItem(at: Self.fileURL(m.id)) }
            videos.removeFirst(drop)
            saveIndex()
        }
    }

    // MARK: WCSessionDelegate

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let r = session.isReachable
        let ctx = session.receivedApplicationContext
        Task { @MainActor in
            self.activated = activationState == .activated
            self.reachable = r
            if let d = ctx[DDWatchKey.status] as? Data, let st = try? JSONDecoder().decode(DDWatchStatus.self, from: d) { self.status = st }
        }
    }
    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let r = session.isReachable
        Task { @MainActor in self.reachable = r }
    }
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let d = applicationContext[DDWatchKey.status] as? Data, let st = try? JSONDecoder().decode(DDWatchStatus.self, from: d) else { return }
        Task { @MainActor in self.status = st }
    }
    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        // 回调返回后系统会删临时文件，必须在这里同步搬走
        guard let d = file.metadata?[DDWatchKey.json] as? Data,
              let meta = try? JSONDecoder().decode(DDWatchVideoMeta.self, from: d) else { return }
        let dst = Self.fileURL(meta.id)
        try? FileManager.default.removeItem(at: dst)
        do { try FileManager.default.moveItem(at: file.fileURL, to: dst) } catch { return }
        Task { @MainActor in
            if !self.videos.contains(where: { $0.id == meta.id }) { self.videos.append(meta) }
            // 超出上限从最早的删
            while self.videos.count > self.keep {
                let old = self.videos.removeFirst()
                try? FileManager.default.removeItem(at: Self.fileURL(old.id))
            }
            self.saveIndex()
        }
    }
}
