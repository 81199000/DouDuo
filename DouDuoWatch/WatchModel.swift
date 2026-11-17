import Foundation
import WatchConnectivity

@MainActor
final class WatchModel: NSObject, ObservableObject {
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
        WCSession.default.delegate = WatchLink.shared
        WCSession.default.activate()
    }

    private func saveIndex() {
        if let d = try? JSONEncoder().encode(videos) { try? d.write(to: Self.indexURL, options: .atomic) }
    }

    func added(_ meta: DDWatchVideoMeta) {
        if !videos.contains(where: { $0.id == meta.id }) { videos.append(meta) }
        while videos.count > keep {   // 超出上限从最早的删
            let old = videos.removeFirst()
            try? FileManager.default.removeItem(at: Self.fileURL(old.id))
        }
        saveIndex()
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
        // 没连上 iPhone 就别占着「请求中」状态，连上后 sessionReachabilityDidChange 会再来一次
        guard !requestingVideos, WCSession.default.isReachable else { return }
        requestingVideos = true
        _ = await send([DDWatchKey.cmd: DDWatchCmd.videos, "have": videos.map(\.id)])
        // 文件传输是异步的，iPhone 转码 + 蓝牙传输需要一阵，到了会自动出现在列表里；这里只保持转圈提示
        try? await Task.sleep(nanoseconds: 8_000_000_000)
        requestingVideos = false
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
}

/// WatchConnectivity 回调放在独立的非 actor 类里：文件回调必须在回调内同步搬走临时文件，不能经过主线程隔离
final class WatchLink: NSObject, WCSessionDelegate {
    static let shared = WatchLink()
    private static func dbg(_ s: String) {
        #if DEBUG
        try? (s + "\n").appendLine(to: WatchModel.dir.deletingLastPathComponent().appendingPathComponent("wlog.txt"))
        #endif
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Self.dbg("activated \(activationState.rawValue)")
        let r = session.isReachable
        let ctx = session.receivedApplicationContext
        Task { @MainActor in
            let m = WatchModel.shared
            m.activated = activationState == .activated
            m.reachable = r
            if let d = ctx[DDWatchKey.status] as? Data, let st = try? JSONDecoder().decode(DDWatchStatus.self, from: d) { m.status = st }
        }
    }
    func sessionReachabilityDidChange(_ session: WCSession) {
        let r = session.isReachable
        Self.dbg("reach \(r)")
        Task { @MainActor in
            let m = WatchModel.shared
            m.reachable = r
            // 刚连上 iPhone 而手表上视频不够：自动请求（启动时往往还没连上，请求会被丢掉）
            if r, m.videos.count < 2 { await m.requestVideos() }
            // 消息同理：启动时没连上就失败了，连上后补刷
            if r, m.inboxError != nil || (m.inbox.notices.isEmpty && m.inbox.chats.isEmpty) { await m.refreshInbox() }
        }
    }
    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let d = applicationContext[DDWatchKey.status] as? Data, let st = try? JSONDecoder().decode(DDWatchStatus.self, from: d) else { return }
        Task { @MainActor in WatchModel.shared.status = st }
    }
    /// iPhone 分块发来的视频：第 0 块建文件，之后追加，最后一块搬到正式位置
    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        defer { replyHandler([:]) }
        guard message[DDWatchKey.cmd] as? String == DDWatchCmd.chunk,
              let id = message[DDWatchKey.id] as? String, let i = message["i"] as? Int, let n = message["n"] as? Int,
              let part = message["data"] as? Data else { return }
        let tmp = WatchModel.dir.appendingPathComponent("\(id).part")
        if i == 0 { try? FileManager.default.removeItem(at: tmp); FileManager.default.createFile(atPath: tmp.path, contents: nil) }
        guard let h = try? FileHandle(forWritingTo: tmp) else { return }
        h.seekToEndOfFile(); h.write(part); try? h.close()
        guard i == n - 1,
              let d = message[DDWatchKey.json] as? Data,
              let meta = try? JSONDecoder().decode(DDWatchVideoMeta.self, from: d) else { return }
        let dst = WatchModel.fileURL(id)
        try? FileManager.default.removeItem(at: dst)
        do { try FileManager.default.moveItem(at: tmp, to: dst) } catch { Self.dbg("chunk move 失败 \(error)"); return }
        Self.dbg("chunks saved \(id)")
        Task { @MainActor in WatchModel.shared.added(meta) }
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        Self.dbg("didReceive \(file.fileURL.lastPathComponent)")
        // 回调返回后系统会删临时文件，必须在这里同步搬走
        guard let d = file.metadata?[DDWatchKey.json] as? Data,
              let meta = try? JSONDecoder().decode(DDWatchVideoMeta.self, from: d) else { Self.dbg("meta 解析失败"); return }
        let dst = WatchModel.fileURL(meta.id)
        try? FileManager.default.removeItem(at: dst)
        do { try FileManager.default.moveItem(at: file.fileURL, to: dst) } catch { Self.dbg("move 失败 \(error)"); return }
        Self.dbg("saved \(meta.id)")
        Task { @MainActor in WatchModel.shared.added(meta) }
    }
}

#if DEBUG
extension String {
    func appendLine(to url: URL) throws {
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(utf8)); try h.close() }
        else { try write(to: url, atomically: true, encoding: .utf8) }
    }
}
#endif
