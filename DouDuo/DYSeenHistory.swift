import AVFoundation
import Foundation

/// 「看过的视频不再推荐」（老板 2026-11-22：只要划到就算看过）。
/// 推荐页每划到一条就记下 id；之后推荐接口再推这条（重启、刷新、换一批之后也一样）直接跳过。
/// 按登录账号分开存（账号 uid；没登录记在 guest），每个账号保留最近 5000 条，先进先出。
/// 只作用于推荐页：关注页是「关注的人最新作品」按时间排的，过滤掉会变空。
/// 这里只做内存 + 本地文件，不碰网络；判断在 DYFeedModel.allowedRecommendations 里统一生效。
final class DYSeenHistory: @unchecked Sendable {
    static let shared = DYSeenHistory()
    static let enabledKey = "douyin_hide_seen_v1"
    static let cap = 5000

    /// 开关：默认开
    static var enabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    private let lock = NSLock()
    private var scope = ""
    private var order: [String] = []
    private var set: Set<String> = []
    private var dirty = false
    private var saveScheduled = false
    private let io = DispatchQueue(label: "douduo.seen-history", qos: .utility)

    private init() {}

    private static var dir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("seen-history", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private static func currentScope() -> String {
        let uid = UserDefaults.standard.string(forKey: "douduo_account_current_v1") ?? ""
        return uid.isEmpty ? "guest" : uid.filter { $0.isLetter || $0.isNumber }
    }

    /// 账号变了就换一份名单
    private func ensureScope() {
        let s = Self.currentScope()
        guard s != scope else { return }
        if dirty { writeNow() }
        scope = s
        let f = Self.dir.appendingPathComponent(s + ".txt")
        let ids = (try? String(contentsOf: f, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
        order = Array(ids.suffix(Self.cap))
        set = Set(order)
        dirty = false
    }

    /// 划到一条就记下
    func mark(_ id: String) {
        guard !id.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        ensureScope()
        guard set.insert(id).inserted else { return }
        order.append(id)
        if order.count > Self.cap {
            let drop = order.count - Self.cap
            for old in order.prefix(drop) { set.remove(old) }
            order.removeFirst(drop)
        }
        dirty = true
        scheduleSave()
    }

    func contains(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        ensureScope()
        return set.contains(id)
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        ensureScope()
        return order.count
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        ensureScope()
        order = []; set = []; dirty = true
        writeNow()
    }

    /// 写盘合并：2 秒内多次划动只写一次
    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        io.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            self.saveScheduled = false
            if self.dirty { self.writeNow() }
        }
    }

    /// 调用方持有锁
    private func writeNow() {
        let f = Self.dir.appendingPathComponent(scope + ".txt")
        try? order.joined(separator: "\n").write(to: f, atomically: true, encoding: .utf8)
        dirty = false
    }
}

/// 粉丝许愿（11-23）：「打开抖音时默认静音播放」——开着时每次启动把全局静音打开，并且不打断别的 App 正在放的音乐。
enum DYLaunchMute {
    static let key = "douyin_launch_muted_v1"
    static let mutedKey = "douyin_muted_v1"
    nonisolated(unsafe) private static var lastMuted: Bool?
    nonisolated(unsafe) private static var observer: NSObjectProtocol?

    /// 静音时音频会话带「与其他 App 混音」：不打断用户自己在放的音乐（原生抖音同款）；取消静音恢复独占
    static var sessionOptions: AVAudioSession.CategoryOptions {
        UserDefaults.standard.bool(forKey: mutedKey) ? [.mixWithOthers] : []
    }

    static func apply() {
        if UserDefaults.standard.bool(forKey: key) { UserDefaults.standard.set(true, forKey: mutedKey) }
        lastMuted = UserDefaults.standard.bool(forKey: mutedKey)
        // 静音开关一变就重设会话类别（静音→混音不打断别的 App；取消静音→恢复正常出声）
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            let now = UserDefaults.standard.bool(forKey: mutedKey)
            guard now != lastMuted else { return }
            lastMuted = now
            let s = AVAudioSession.sharedInstance()
            try? s.setCategory(.playback, mode: .moviePlayback, options: sessionOptions)
            if !now { try? s.setActive(true) }
        }
    }
}
