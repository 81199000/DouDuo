import AVFoundation
import Foundation
import Network
#if canImport(UIKit)
import UIKit
#endif

/// 边下边播。
///
/// 播放器永远只认一个地址 `ddstream://<id>`，数据全部由这里供：
/// 本地已有的字节直接从文件读，没有的现场从抖音 CDN 拉、一边喂给播放器一边写进同一个文件。
/// 播放器眼里只有一个连续的源，没有「本地 → 在线」的切换，所以不会再有以前那一下卡顿。
///
/// 省流量的关键是「允许下载到哪」（见 DYStreamPlan.horizon）：
/// - 还没划到的条只下开头几秒（秒开够用）；
/// - 正在看的条只比播放位置多下十几到三十秒；
/// - 划走就停，没看的部分一个字节都不下；看完的自然拼成完整文件，下次离线也能播。
enum DYStream {
    static let scheme = "ddstream"
    static let enabledKey = "douyin_stream_cache_v1"

    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    /// 蜂窝省流量：固定开
    static let saverOn = true
    /// Wi-Fi 省流量：固定开，Wi-Fi 下预缓存的条数也只下开头
    static let wifiSaverOn = true
    /// 降一档清晰度 + 只预热下一条 + 不预连直播：只在「用流量且蜂窝省流量开」时
    static var saving: Bool { saverOn && DYNetPath.shared.cellular }

    static func url(for id: String) -> URL { URL(string: "\(scheme)://v/\(id)")! }
    /// 拖进度条的预览小图用：同一份缓存，但只读本地已有的，绝不联网、不开跳读窗口
    /// （以前预览走播放器同一个资源：手指扫过的每个位置都开 8 秒跳读窗口去下，
    static func peekURL(for id: String) -> URL { URL(string: "\(scheme)://v/\(id)?peek=1")! }
    static func id(of url: URL) -> String? {
        guard url.scheme == scheme else { return nil }
        let id = url.lastPathComponent
        return id.isEmpty ? nil : id
    }
    static func isPeek(_ url: URL) -> Bool { url.query?.contains("peek=1") == true }

    /// 预览小图的资源：跟播放器共用同一份边下边播缓存；不是 ddstream 的（本地整条 / 在线）原样复用
    static func peekAsset(for playing: AVURLAsset) -> AVURLAsset {
        guard let key = id(of: playing.url) else { return playing }
        let a = AVURLAsset(url: peekURL(for: key))
        a.resourceLoader.setDelegate(DYStreamLoader.shared, queue: DYStreamLoader.queue)
        return a
    }

    /// 给播放器的资源：本地整条有 → 本地文件；开着边下边播 → ddstream 资源；否则原样在线
    static func asset(for item: DYAweme, remote: URL) -> AVURLAsset {
        if remote.isFileURL { return AVURLAsset(url: remote) }
        if let local = DYVideoCache.localURL(item.id) { return AVURLAsset(url: local) }
        guard enabled else { return DYMedia.asset(remote) }
        let key = DYStreamStore.shared.register(item, remote: remote)
        let asset = AVURLAsset(url: url(for: key))
        asset.resourceLoader.setDelegate(DYStreamLoader.shared, queue: DYStreamLoader.queue)
        return asset
    }

    /// 重建播放器时接着用这条已有的边下边播缓存（没登记过 / 关了边下边播返回 nil）
    static func reuseAsset(id: String) -> AVURLAsset? {
        guard enabled, let item = DYStreamStore.shared.item(id), let remote = item.play.flatMap(URL.init(string:)) else { return nil }
        let a = asset(for: item, remote: remote)
        return a.url.isFileURL || a.url.scheme == scheme ? a : nil
    }

    /// 只有 id 的地方（播放页）：已登记过就走 ddstream，否则原样
    static func asset(id: String, remote: URL) -> AVURLAsset {
        guard enabled, !remote.isFileURL, let item = DYStreamStore.shared.item(id) else {
            return remote.isFileURL ? AVURLAsset(url: remote) : DYMedia.asset(remote)
        }
        return asset(for: item, remote: remote)
    }
}

/// 流量策略：两个省流量开关 × 当前网络 → 清晰度 / 提前备几条 / 整条下几条
/// - Wi-Fi 省流量关（默认）：按「预缓存数量」提前备好，并把这几条整条下好
/// - Wi-Fi 省流量开：按「预缓存数量」提前备好，每条只下开头几秒，不播不继续下
/// - 蜂窝省流量开（默认）：低一档清晰度，只备下一条的开头
/// - 蜂窝省流量关：高清，提前备 2 条并整条下好
enum DYNetPolicy {
    struct Plan: Equatable {
        let lowQuality: Bool
        /// 提前建好播放器、取开头的条数
        let preload: Int
        /// 整条下载的条数（0 = 只取开头）
        let whole: Int
    }

    nonisolated static func plan(cellular: Bool, wifiSaver: Bool, cellSaver: Bool, streaming: Bool, limit: Int) -> Plan {
        let n = min(max(limit, 1), 10)
        // 关了边下边播：没有「只下开头」这回事，按老办法整条下
        guard streaming else { return Plan(lowQuality: false, preload: n, whole: n) }
        if cellular {
            return cellSaver ? Plan(lowQuality: true, preload: 1, whole: 0) : Plan(lowQuality: false, preload: 2, whole: 2)
        }
        return Plan(lowQuality: false, preload: n, whole: wifiSaver ? 0 : n)
    }

    static var current: Plan {
        plan(cellular: DYNetPath.shared.cellular, wifiSaver: DYStream.wifiSaverOn, cellSaver: DYStream.saverOn,
             streaming: DYStream.enabled, limit: DYVideoCache.limit)
    }
}

/// 当前网络是不是蜂窝（流量）
final class DYNetPath: @unchecked Sendable {
    static let shared = DYNetPath()
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var _cellular = false
    var cellular: Bool { lock.lock(); defer { lock.unlock() }; return _cellular }

    private init() {
        #if DEBUG
        // 真机测流量：DOUDUO_FORCE_CELLULAR=1 按「用流量」处理（Wi-Fi 下也走省流量路径）
        if ProcessInfo.processInfo.environment["DOUDUO_FORCE_CELLULAR"] == "1" { _cellular = true; return }
        #endif
        monitor.pathUpdateHandler = { [weak self] path in
            let cell = path.status == .satisfied && (path.isExpensive || path.usesInterfaceType(.cellular))
            self?.lock.lock(); self?._cellular = cell; self?.lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "douduo.netpath"))
    }
}

// MARK: - 每条视频的稀疏缓存文件

/// 一条视频的边下边播状态：一个按偏移写的稀疏文件 + 已有区间 + 文件信息。
final class DYStreamEntry: @unchecked Sendable {
    /// 视频 id（播放位置、正式缓存都按它）
    let id: String
    /// 缓存文件名：省流量档单独一份（不同清晰度是不同文件，字节不能混）
    let key: String
    var item: DYAweme
    /// 候选地址（同一条视频）：第一个成功的锁定为 source，之后只认同样大小的文件
    var sources: [URL]
    var source: URL?
    /// 跳转后的最终 CDN 地址（省掉每次 0.15s 的重定向）；403 / 失败时清空重新走跳转
    var resolved: URL?
    var total: Int64?
    var contentType = "video/mp4"
    var ranges: [Range<Int64>] = []
    var mediaStart: Int64?
    /// 拖进度条 / 读尾部 moov 时临时放开的窗口
    var windows: [Range<Int64>] = []
    /// 本条已从网络拉了多少字节（这次运行）
    var fetched: Int64 = 0
    var lastUsed = Date()
    var adopted = false
    /// 当前条的后台补货是否在跑
    var pumping = false
    /// 正在下载中的区间：别的请求要这段就等它写进来，不重复下
    var inflight: [Range<Int64>] = []
    /// 第一次拿文件大小（多个请求同时来只发一次）
    var infoTask: Task<Void, Error>?
    let lock = NSLock()

    init(key: String, item: DYAweme, sources: [URL]) {
        id = item.id; self.key = key; self.item = item; self.sources = sources
    }

    var dataURL: URL { DYStreamStore.dir.appendingPathComponent("\(key).part") }
    var metaURL: URL { DYStreamStore.dir.appendingPathComponent("\(key).json") }

    struct Meta: Codable { var total: Int64; var contentType: String; var ranges: [[Int64]]; var mediaStart: Int64? }

    func loadMeta() {
        guard let d = try? Data(contentsOf: metaURL), let m = try? JSONDecoder().decode(Meta.self, from: d),
              FileManager.default.fileExists(atPath: dataURL.path) else { return }
        total = m.total; contentType = m.contentType; mediaStart = m.mediaStart
        ranges = m.ranges.compactMap { $0.count == 2 && $0[0] < $0[1] ? $0[0]..<$0[1] : nil }
    }

    func saveMeta() {
        guard let total else { return }
        let m = Meta(total: total, contentType: contentType, ranges: ranges.map { [$0.lowerBound, $0.upperBound] }, mediaStart: mediaStart)
        if let d = try? JSONEncoder().encode(m) { try? d.write(to: metaURL, options: .atomic) }
    }

    func read(_ offset: Int64, _ count: Int) -> Data? {
        guard count > 0, DYStreamPlan.contiguous(from: offset, in: ranges) >= Int64(count),
              let h = try? FileHandle(forReadingFrom: dataURL) else { return nil }
        defer { try? h.close() }
        try? h.seek(toOffset: UInt64(offset))
        return try? h.read(upToCount: count)
    }

    func write(_ data: Data, at offset: Int64) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: dataURL.path) { fm.createFile(atPath: dataURL.path, contents: nil) }
        guard let h = try? FileHandle(forWritingTo: dataURL) else { return }
        defer { try? h.close() }
        try? h.seek(toOffset: UInt64(offset))
        try? h.write(contentsOf: data)
        ranges = DYStreamPlan.insert(offset..<(offset + Int64(data.count)), into: ranges)
        fetched += Int64(data.count)
        if mediaStart == nil, let total {
            mediaStart = DYStreamPlan.mediaStart(total: total) { o, n in
                let have = DYStreamPlan.contiguous(from: o, in: ranges)
                return have >= 8 ? self.readRaw(o, Int(min(Int64(n), have))) : nil
            }
        }
    }

    private func readRaw(_ offset: Int64, _ count: Int) -> Data? {
        guard let h = try? FileHandle(forReadingFrom: dataURL) else { return nil }
        defer { try? h.close() }
        try? h.seek(toOffset: UInt64(offset))
        return try? h.read(upToCount: count)
    }

    var shape: DYStreamPlan.Shape? {
        guard let total else { return nil }
        return .init(total: total, mediaStart: mediaStart ?? 0, duration: item.duration)
    }

    var complete: Bool { total.map { DYStreamPlan.isComplete(ranges, total: $0) } ?? false }
}

/// 所有条目的登记处 + 播放位置（决定每条最多下到哪）
final class DYStreamStore: @unchecked Sendable {
    static let shared = DYStreamStore()
    static let dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dd-videos", isDirectory: true).appendingPathComponent("stream", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    /// 部分缓存最多留多少条（按最近使用淘汰）
    static let keep = 30

    private let lock = NSLock()
    private var entries: [String: DYStreamEntry] = [:]
    private var items: [String: DYAweme] = [:]
    private var currentID: String?
    private var playhead: [String: Double] = [:]
    /// 当前条播放位置最后一次推进的时间：一直不动 = 还没起播 / 卡住等数据
    private var advancedAt = Date.distantPast
    /// 本次运行网络总下载量（日志对比用）
    private(set) var sessionBytes: Int64 = 0

    /// 登记一条并返回缓存 key。省流量模式（用流量时）优先用低一档的地址（抖音给的 H.265 档通常一半码率）
    @discardableResult
    func register(_ item: DYAweme, remote: URL) -> String {
        let saver = DYStream.saving ? item.playSaver.flatMap(URL.init(string:)) : nil
        let key = saver != nil ? item.id + "~s" : item.id
        var sources = [saver, remote, item.play.flatMap(URL.init(string:)), item.playAlt.flatMap(URL.init(string:))].compactMap { $0 }
        var seen = Set<URL>(); sources = sources.filter { seen.insert($0).inserted }
        lock.lock(); defer { lock.unlock() }
        items[item.id] = item
        if let e = entries[key] { e.item = item; e.sources = sources; e.lastUsed = Date(); return key }
        let e = DYStreamEntry(key: key, item: item, sources: sources)
        e.loadMeta()
        entries[key] = e
        return key
    }

    func item(_ id: String) -> DYAweme? { lock.lock(); defer { lock.unlock() }; return items[id] }

    func entry(_ key: String) -> DYStreamEntry? {
        lock.lock(); defer { lock.unlock() }
        let e = entries[key]; e?.lastUsed = Date(); return e
    }

    /// 播放器每 0.25s 报一次（只报当前条）
    func setPlayhead(_ id: String, _ seconds: Double) {
        lock.lock()
        let previous = currentID
        let moved = previous != id || abs((playhead[id] ?? -1) - seconds) > 0.05
        currentID = id; playhead[id] = seconds
        if moved { advancedAt = Date() }
        let leaving = previous != id ? entries.values.filter { $0.id == previous } : []
        lock.unlock()
        DYStreamLoader.shared.bump()
        logLeave(leaving)
        if previous != id, let e = entry(forVideo: id) { DYStreamLoader.shared.pump(e) }
        if previous != id { scheduleTrim() }
    }

    /// 页面一激活（划到这条）就算当前条——不能等时间观察者报播放位置：
    /// 还没起播时观察者不报，下载又只给当前条放开 → 互相等，长视频永远起不来（真机实测等 20 秒）
    func activate(_ id: String, at seconds: Double = 0) {
        lock.lock()
        let previous = currentID
        let changed = previous != id
        // 上一条到切走都没再跟 ddstream 要字节 = 预热已缓冲够（或走本地整条），记一笔 src=buffered
        let unmet = changed ? ttfbArmed : nil
        if changed { currentID = id; advancedAt = Date(); if playhead[id] == nil { playhead[id] = seconds }; ttfbArmed = (id, Date()) }
        let leaving = changed ? entries.values.filter { $0.id == previous } : []
        lock.unlock()
        if let unmet { DYLiveModel.log("DDTTFB \(unmet.id.suffix(6)) ms=-1 src=buffered") }
        if changed { DYStreamLoader.shared.bump(); scheduleTrim() }
        logLeave(leaving)
        if let e = entry(forVideo: id) { DYStreamLoader.shared.pump(e) }
    }

    /// DDTTFB 测量：页面接管（activate）时刻 → 播放器第一次从 ddstream 拿到字节
    private var ttfbArmed: (id: String, at: Date)?
    func noteFirstByte(_ id: String, src: String) {
        lock.lock()
        guard let a = ttfbArmed, a.id == id else { lock.unlock(); return }
        ttfbArmed = nil
        lock.unlock()
        DYLiveModel.log("DDTTFB \(id.suffix(6)) ms=\(Int(Date().timeIntervalSince(a.at) * 1000)) src=\(src)")
    }

    private var trimScheduled = false
    /// 换条后 5 秒在后台清一次（同一时间只排一个）
    func scheduleTrim() {
        lock.lock(); let skip = trimScheduled; trimScheduled = true; lock.unlock()
        guard !skip else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.trimScheduled = false; self.lock.unlock()
            self.trim()
        }
    }

    /// 换条时记一笔：上一条实际下了多少 / 总共多大 / 看到第几秒——验证省了多少流量
    private func logLeave(_ list: [DYStreamEntry]) {
        for e in list {
            e.lock.lock(); let got = e.fetched, total = e.total ?? 0, have = DYStreamPlan.covered(e.ranges); e.lock.unlock()
            DYLiveModel.log("DDSTREAM leave \(e.id.suffix(6)) key=\(e.key == e.id ? "hd" : "saver") net=\(got / 1024)KB have=\(have / 1024)KB total=\(total / 1024)KB watched=\(Int(position(e.id) ?? 0))/\(Int(e.item.duration))s session=\(sessionBytes / 1024 / 1024)MB")
        }
    }

    /// 当前条且播放位置超过 1 秒没推进（还没起播 / 卡住等数据）：播放器要多少给多少，不卡着它
    func isStarving(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        // 划到后先给 1.5 秒正常起播；过了还没动才算「饿」（模拟器实测：一划到就算饿，
        // 起播前播放器猛要数据，每条都多下 2–4MB，省流量只剩 16%）
        return currentID == id && Date().timeIntervalSince(advancedAt) > 1.5
    }

    /// 这条视频最近用的那份缓存（高清 / 省流量各一份时取最近用的）
    func entry(forVideo id: String) -> DYStreamEntry? {
        lock.lock(); defer { lock.unlock() }
        return entries.values.filter { $0.id == id }.max { $0.lastUsed < $1.lastUsed }
    }

    func isCurrent(_ id: String) -> Bool { lock.lock(); defer { lock.unlock() }; return currentID == id }

    /// 起播慢诊断（DDWAIT）：这条的边下边播状态——本地有哪些段、哪些在下、允许下到哪、是不是在「饿」
    func debugLine(forVideo id: String) -> String {
        guard let e = entry(forVideo: id) else { return "stream=none" }
        let horizon = self.horizon(e).map { "\($0 / 1024)KB" } ?? "-"
        let starving = isStarving(id)
        e.lock.lock(); defer { e.lock.unlock() }
        func kb(_ r: Range<Int64>) -> String { "\(r.lowerBound / 1024)-\(r.upperBound / 1024)" }
        let total = e.total.map { "\($0 / 1024)KB" } ?? "?"
        return "key=\(e.key == e.id ? "hd" : "saver") total=\(total) moovEnd=\(e.mediaStart.map { "\($0 / 1024)KB" } ?? "?") have=[\(e.ranges.map(kb).joined(separator: ","))] inflight=[\(e.inflight.map(kb).joined(separator: ","))] horizon=\(horizon) starving=\(starving) pumping=\(e.pumping) windows=\(e.windows.count)"
    }
    func position(_ id: String) -> Double? { lock.lock(); defer { lock.unlock() }; return playhead[id] }

    func noteFetched(_ n: Int64) { lock.lock(); sessionBytes += n; lock.unlock() }

    /// 这条现在最多允许下到哪个字节
    func horizon(_ e: DYStreamEntry) -> Int64? {
        e.lock.lock(); let shape = e.shape; e.lock.unlock()
        guard let shape else { return nil }
        return DYStreamPlan.horizon(shape: shape, playhead: position(e.id), current: isCurrent(e.id),
                                    cellular: DYNetPath.shared.cellular)
    }

    /// 下完整条：硬链接成正式缓存（DYVideoCache 的 <id>.mp4，不多占空间），之后直接本地播
    func finishIfComplete(_ e: DYStreamEntry) {
        e.lock.lock(); let done = e.complete && !e.adopted, total = e.total ?? 0
        if done { e.adopted = true }
        e.lock.unlock()
        guard done else { return }
        let item = e.item, src = e.dataURL
        Task { await DYVideoCache.shared.adoptStreamed(item, file: src, bytes: Int(total)) }
        DYLiveModel.log("DDSTREAM complete \(e.id.suffix(6)) \(total / 1024)KB")
    }

    /// 边下边播的半截文件最多占多少（超了按最近使用淘汰）
    static let keepBytes: Int64 = 300 * 1024 * 1024

    /// 清理边下边播目录（启动时 + 每次换条时）。以前这个函数没人调，半截文件一直堆着不删。
    /// 规则：已整条收进正式缓存的、孤儿文件直接删；其余按最近使用留 keep 条且不超过 keepBytes。
    /// 正在播 / 正在下 / 2 分钟内刚用过的不动。
    func trim() {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileAllocatedSizeKey, .fileSizeKey]
        guard let files = try? fm.contentsOfDirectory(at: Self.dir, includingPropertiesForKeys: keys) else { return }
        lock.lock()
        let current = currentID
        let busy = Set(entries.values.filter { e in
            e.lock.lock(); defer { e.lock.unlock() }
            return !e.inflight.isEmpty || e.pumping || e.id == current
        }.map(\.key))
        lock.unlock()
        let names = Set(files.map(\.lastPathComponent))
        let now = Date()
        func mtime(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        func size(_ u: URL) -> Int64 {
            let v = try? u.resourceValues(forKeys: [.fileAllocatedSizeKey, .fileSizeKey])
            return Int64(v?.fileAllocatedSize ?? v?.fileSize ?? 0)
        }
        func untouchable(_ key: String, _ u: URL) -> Bool { busy.contains(key) || now.timeIntervalSince(mtime(u)) < 120 }
        var removed = 0, freed: Int64 = 0
        func drop(_ key: String) {
            let part = Self.dir.appendingPathComponent(key + ".part"), meta = Self.dir.appendingPathComponent(key + ".json")
            freed += size(part)
            try? fm.removeItem(at: part); try? fm.removeItem(at: meta)
            lock.lock(); entries[key] = nil; lock.unlock()
            removed += 1
        }
        // 孤儿 .json（没有对应 .part）
        for f in files where f.pathExtension == "json" && !names.contains(f.deletingPathExtension().lastPathComponent + ".part") {
            try? fm.removeItem(at: f)
        }
        var parts = files.filter { $0.pathExtension == "part" }
        // 已整条收进正式缓存（.part 只是它的硬链接，留着会在正式缓存删掉后继续占盘）、或没有 .json 的孤儿
        for f in parts {
            let key = f.deletingPathExtension().lastPathComponent
            let id = String(key.split(separator: "~").first ?? Substring(key))
            let orphan = !names.contains(key + ".json")
            if (DYVideoCache.localURL(id) != nil || orphan) && !untouchable(key, f) { drop(key) }
        }
        parts = parts.filter { fm.fileExists(atPath: $0.path) }.sorted { mtime($0) > mtime($1) }
        var kept = 0, keptBytes: Int64 = 0
        for f in parts {
            let key = f.deletingPathExtension().lastPathComponent
            let b = size(f)
            if untouchable(key, f) || (kept < Self.keep && keptBytes + b <= Self.keepBytes) {
                kept += 1; keptBytes += b
            } else {
                drop(key)
            }
        }
        if removed > 0 {
            DYLiveModel.log("DDSTREAM trim removed=\(removed) freed=\(freed / 1024 / 1024)MB kept=\(kept) keptMB=\(keptBytes / 1024 / 1024)")
        }
    }

    /// 整条缓存已就位：删掉这条视频的半截文件（播放器那边下次读会走整条文件）
    func dropPartial(_ id: String) {
        lock.lock()
        let parts = entries.values.filter { $0.id == id && !$0.adopted }
        lock.unlock()
        lock.lock(); let current = currentID; lock.unlock()
        for e in parts {
            // 正在播 / 正在下 / 在补货的先不删（播放器可能还在读这份），换条后由 trim 收尾
            e.lock.lock(); let busy = !e.inflight.isEmpty || e.pumping || e.id == current; e.lock.unlock()
            if busy { continue }
            // 以前只删 .json、留着 .part：数据文件永远不删（缓存越堆越大的原因之一）
            try? FileManager.default.removeItem(at: e.metaURL)
            try? FileManager.default.removeItem(at: e.dataURL)
            lock.lock(); entries[e.key] = nil; lock.unlock()
        }
    }

    func clearAll() {
        lock.lock(); entries = [:]; lock.unlock()
        try? FileManager.default.removeItem(at: Self.dir)
        try? FileManager.default.createDirectory(at: Self.dir, withIntermediateDirectories: true)
    }
}

// MARK: - AVAssetResourceLoader

/// 播放器要数据 → 这里给。一个请求 = 一个 Task：本地有就读本地；没有就在允许范围内拉网络、边拉边喂。
/// 超出允许范围的请求挂起，等播放位置推进（setPlayhead → wake）再继续——这就是「看到哪下到哪」。
final class DYStreamLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let shared = DYStreamLoader()
    static let queue = DispatchQueue(label: "douduo.stream.loader")

    private static func makeSession() -> URLSession {
        let c = URLSessionConfiguration.default
        c.httpMaximumConnectionsPerHost = 6
        c.timeoutIntervalForRequest = 20
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }
    private var _session = DYStreamLoader.makeSession()
    private var session: URLSession { lock.lock(); defer { lock.unlock() }; return _session }
    /// 正在收数据的连接（回前台时要整批作废）
    private var live: [ObjectIdentifier: DYChunkStream] = [:]
    private var backgroundAt: Date?
    private var lifecycle: [NSObjectProtocol] = []

    override init() {
        super.init()
        #if canImport(UIKit)
        let nc = NotificationCenter.default
        lifecycle = [
            nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
                self?.lock.lock(); self?.backgroundAt = Date(); self?.lock.unlock()
            },
            nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { [weak self] _ in
                self?.reviveAfterForeground()
            },
        ]
        #endif
    }

    private func track(_ c: DYChunkStream) { lock.lock(); live[ObjectIdentifier(c)] = c; lock.unlock() }
    private func untrack(_ id: ObjectIdentifier) { lock.lock(); live[id] = nil; lock.unlock() }

    /// App 挂起时系统把边下边播的连接冻住，回来后连接已死但任务还挂着：它占着「正在下这段」的标记，
    /// 播放器要的数据就一直等它，直到 20 秒超时。
    /// 回前台：换新会话，旧连接按「连接断了」作废 → 下载循环立刻用新连接重拉同一段。
    private func reviveAfterForeground() {
        lock.lock()
        let away = backgroundAt.map { Date().timeIntervalSince($0) } ?? 0
        backgroundAt = nil
        guard away >= DYStreamPlan.reviveAfterBackground else { lock.unlock(); return }
        let old = _session
        _session = DYStreamLoader.makeSession()
        let streams = Array(live.values)
        live.removeAll()
        lock.unlock()
        streams.forEach { $0.abortForRevive() }
        old.finishTasksAndInvalidate()
        DYLiveModel.log("DDSTREAM revive away=\(Int(away))s aborted=\(streams.count)")
    }

    private let lock = NSLock()
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    /// 播放位置 / 当前条一变就 +1；挂起的请求看到变化就回去重新判断
    private var generation = 0

    func bump() { lock.lock(); generation &+= 1; lock.unlock() }
    private var gen: Int { lock.lock(); defer { lock.unlock() }; return generation }

    /// 超出允许范围的请求在这里等：播放位置推进 / 换条 / 超时 就回去重算
    private func park(seconds: Double) async throws {
        let start = gen
        let deadline = Date().addingTimeInterval(seconds)
        while gen == start, Date() < deadline {
            try await Task.sleep(for: .milliseconds(150))
        }
    }

    /// 当前条的后台补货：不等播放器来要，自己把「播放位置之后 18–30 秒」提前下到本地。
    /// 播放器默认只在缓冲快见底时才来要数据，那时再联网就来不及，每次都卡 1–3 秒（模拟器实测）。
    /// 有了补货，播放器要的数据基本都已在本地，读本地是瞬间的。只有当前条在跑，划走自动停。
    func pump(_ e: DYStreamEntry) {
        e.lock.lock()
        if e.pumping { e.lock.unlock(); return }
        e.pumping = true
        e.lock.unlock()
        Task.detached(priority: .utility) { [weak self] in
            defer { e.lock.lock(); e.pumping = false; e.lock.unlock() }
            guard let self else { return }
            if DYVideoCache.localURL(e.id) != nil { return }
            do { try await self.ensureInfo(e) } catch { return }
            while DYStreamStore.shared.isCurrent(e.id), !Task.isCancelled, DYVideoCache.localURL(e.id) == nil {
                let horizon = DYStreamStore.shared.horizon(e) ?? 0
                let pos = DYStreamStore.shared.position(e.id) ?? 0
                e.lock.lock()
                guard let total = e.total, let shape = e.shape else { e.lock.unlock(); return }
                // 从播放位置往后找第一个缺口
                var need = shape.offset(at: pos)
                if pos < 1 { need = 0 }
                need += DYStreamPlan.contiguous(from: need, in: e.ranges)
                // 低水位补货：本地领先播放位置不到前瞻的一半就补，一次至少 512KB（可略超前瞻）。
                // 以前沿用播放器那套「攒够 512KB 才发」：码率低的视频要播十几秒才攒够，
                // 期间缓冲见底卡 2.4 秒（模拟器实测）。
                let playOffset = pos < 1 ? 0 : shape.offset(at: pos)
                let ahead = need - playOffset, window = max(horizon - playOffset, 1)
                var fetch: Range<Int64>? = nil
                if need < total, ahead < window / 2 || horizon - need >= DYStreamPlan.minFetchBytes {
                    var end = min(total, max(horizon, need + DYStreamPlan.minFetchBytes), need + DYStreamPlan.chunkBytes)
                    if let next = DYStreamPlan.nextCachedStart(after: need, in: e.ranges) { end = min(end, next) }
                    if end > need { fetch = need..<end }
                }
                if let f = fetch, e.inflight.contains(where: { $0.overlaps(f) }) { fetch = nil }
                if let f = fetch { e.inflight.append(f) }
                e.lock.unlock()
                guard let fetch else {
                    if need >= total { return }
                    try? await self.park(seconds: 2)
                    continue
                }
                do { try await self.download(e, fetch, sink: nil) } catch {
                    e.lock.lock(); e.inflight.removeAll { $0 == fetch }; e.lock.unlock()
                    if !DYChunkStream.isRevive(error) { try? await Task.sleep(for: .seconds(1)) }
                    continue
                }
                e.lock.lock(); e.inflight.removeAll { $0 == fetch }; e.lock.unlock()
            }
        }
    }

    /// Wi-Fi 整条预下：往同一个边下边播文件里补齐缺口（不再另下一份完整文件，避免同一条下两遍）。
    /// 补齐后 finishIfComplete 会把它收成正式缓存。返回是否拼齐。
    func fillWhole(_ item: DYAweme, remote: URL) async -> Bool {
        let key = DYStreamStore.shared.register(item, remote: remote)
        guard let e = DYStreamStore.shared.entry(key) else { return false }
        do { try await ensureInfo(e) } catch { return false }
        while !Task.isCancelled {
            e.lock.lock()
            guard let total = e.total else { e.lock.unlock(); return false }
            if e.complete { e.lock.unlock(); return true }
            // 第一个缺口：0 没有就从 0，否则从第一段之后
            let need: Int64 = (e.ranges.first?.lowerBound ?? 1) > 0 ? 0 : (e.ranges.first?.upperBound ?? 0)
            var end = min(total, need + DYStreamPlan.chunkBytes)
            if let next = DYStreamPlan.nextCachedStart(after: need, in: e.ranges) { end = min(end, next) }
            let busy = e.inflight.contains { $0.contains(need) }
            let fetch = need..<end
            if !busy { e.inflight.append(fetch) }
            e.lock.unlock()
            if busy { try? await Task.sleep(for: .milliseconds(200)); continue }
            defer { e.lock.lock(); e.inflight.removeAll { $0 == fetch }; e.lock.unlock() }
            do { try await download(e, fetch, sink: nil) } catch { return false }
        }
        return false
    }

    /// 只把开头（预热范围：Wi-Fi 约 6 秒）下好。整条预下之前先跑这个，保证后面一两条划到就能起播。
    /// 看直播时直播流也在抢网速，直播后面那条划到时常常只缓冲了 0.8–1 秒。
    func fillHead(_ item: DYAweme, remote: URL) async {
        let key = DYStreamStore.shared.register(item, remote: remote)
        guard let e = DYStreamStore.shared.entry(key) else { return }
        do { try await ensureInfo(e) } catch { return }
        while !Task.isCancelled {
            // horizon 自己要拿 e.lock（NSLock 不可重入），先在锁外算
            guard let horizon = DYStreamStore.shared.horizon(e) else { return }
            e.lock.lock()
            guard let total = e.total else { e.lock.unlock(); return }
            let limit = min(total, horizon)
            let need = DYStreamPlan.contiguous(from: 0, in: e.ranges)
            if need >= limit { e.lock.unlock(); return }
            var end = min(limit, need + DYStreamPlan.chunkBytes)
            if let next = DYStreamPlan.nextCachedStart(after: need, in: e.ranges) { end = min(end, next) }
            let fetch = need..<end
            let busy = e.inflight.contains { $0.overlaps(fetch) }
            if !busy { e.inflight.append(fetch) }
            e.lock.unlock()
            // 播放器（预热的那个）正在要这段：等它下完再看
            if busy { try? await Task.sleep(for: .milliseconds(150)); continue }
            defer { e.lock.lock(); e.inflight.removeAll { $0 == fetch }; e.lock.unlock() }
            do { try await download(e, fetch, sink: nil) } catch { return }
        }
    }

    func resourceLoader(_ loader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource req: AVAssetResourceLoadingRequest) -> Bool {
        guard let url = req.request.url, let streamKey = DYStream.id(of: url), let e = DYStreamStore.shared.entry(streamKey) else { return false }
        if DYStream.isPeek(url) { servePeek(req, entry: e); return true }
        let key = ObjectIdentifier(req)
        let t = Task { [weak self] in
            await self?.serve(req, entry: e)
            self?.lock.lock(); self?.tasks[key] = nil; self?.lock.unlock()
        }
        lock.lock(); tasks[key] = t; lock.unlock()
        return true
    }

    func resourceLoader(_ loader: AVAssetResourceLoader, didCancel req: AVAssetResourceLoadingRequest) {
        lock.lock(); let t = tasks.removeValue(forKey: ObjectIdentifier(req)); lock.unlock()
        t?.cancel()
    }

    // MARK: 供数据

    /// 预览小图：只给本地已有的连续数据；缺了马上报错（小图不出就不出，不能去抢播放的带宽）
    private func servePeek(_ req: AVAssetResourceLoadingRequest, entry e: DYStreamEntry) {
        e.lock.lock(); let total = e.total; e.lock.unlock()
        guard let total else { DDSeekProbe.peek(miss: true); req.finishLoading(with: URLError(.resourceUnavailable)); return }
        if let info = req.contentInformationRequest {
            info.contentType = "public.mpeg-4"
            info.contentLength = total
            info.isByteRangeAccessSupported = true
        }
        guard let dr = req.dataRequest else { req.finishLoading(); return }
        let want: Int64 = dr.requestsAllDataToEndOfResource ? total - dr.requestedOffset : Int64(dr.requestedLength)
        let end = min(total, dr.requestedOffset + want)
        var cursor = max(dr.requestedOffset, dr.currentOffset)
        let whole = DYVideoCache.localURL(e.id).flatMap { try? FileHandle(forReadingFrom: $0) }
        defer { try? whole?.close() }
        while cursor < end {
            if req.isCancelled { return }
            var d: Data?
            if let whole {
                try? whole.seek(toOffset: UInt64(cursor))
                d = try? whole.read(upToCount: Int(min(end - cursor, 2 * 1024 * 1024)))
            } else {
                e.lock.lock()
                let local = DYStreamPlan.contiguous(from: cursor, in: e.ranges)
                if local > 0 { d = e.read(cursor, Int(min(local, end - cursor, 2 * 1024 * 1024))) }
                e.lock.unlock()
            }
            guard let d, !d.isEmpty else {
                DDSeekProbe.peek(miss: true)
                req.finishLoading(with: URLError(.resourceUnavailable)); return
            }
            dr.respond(with: d); cursor += Int64(d.count)
        }
        DDSeekProbe.peek(miss: false)
        req.finishLoading()
    }

    private func serve(_ req: AVAssetResourceLoadingRequest, entry e: DYStreamEntry) async {
        do {
            try await ensureInfo(e)
            guard let total = e.total else { throw URLError(.badServerResponse) }
            if let info = req.contentInformationRequest {
                info.contentType = "public.mpeg-4"
                info.contentLength = total
                info.isByteRangeAccessSupported = true
            }
            guard let dr = req.dataRequest else { req.finishLoading(); return }
            let start = dr.requestedOffset
            let want: Int64 = dr.requestsAllDataToEndOfResource ? total - start : Int64(dr.requestedLength)
            let end = min(total, start + want)
            var cursor = max(start, dr.currentOffset)
            var revives = 0
            var waitInflightSince: Date?
            var parks = 0
            #if DEBUG
            let reqT0 = Date(), reqStart = cursor
            if DYStreamStore.shared.isCurrent(e.id) {
                DYLiveModel.log("DDSTREAMREQ \(e.id.suffix(6)) open at=\(cursor / 1024)KB want=\(want / 1024)KB toEnd=\(dr.requestsAllDataToEndOfResource) pos=\(String(format: "%.1f", DYStreamStore.shared.position(e.id) ?? -1))")
            }
            defer {
                if DYStreamStore.shared.isCurrent(e.id) {
                    DYLiveModel.log("DDSTREAMREQ \(e.id.suffix(6)) close at=\(reqStart / 1024)KB served=\((cursor - reqStart) / 1024)KB in=\(Int(Date().timeIntervalSince(reqT0) * 1000))ms cancelled=\(Task.isCancelled)")
                }
            }
            #endif
            // 跳着读：当前条拖进度条，或任何条读文件尾部的 moov → 给一个临时窗口，不受播放前瞻限制。
            // 预热中的条正常往后读不放开（否则每次重发请求都多下 8 秒，省流量就白做了）
            e.lock.lock(); let shape = e.shape; e.lock.unlock()
            if let h = DYStreamStore.shared.horizon(e), let shape, cursor > h + DYStreamPlan.jumpSlack,
               DYStreamStore.shared.isCurrent(e.id) || cursor > shape.total * 9 / 10 {
                e.lock.lock(); e.windows = Array((e.windows + [DYStreamPlan.jumpWindow(from: cursor, shape: shape)]).suffix(4)); e.lock.unlock()
                DDSeekProbe.jump(e.id, at: cursor, shape: shape)
            }
            // 整条已经在正式缓存里（Wi-Fi 下整条预下好了）：直接从那个文件给，不再联网
            if let whole = DYVideoCache.localURL(e.id), let h = try? FileHandle(forReadingFrom: whole) {
                defer { try? h.close() }
                let size = Int64((try? whole.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                if size == total {
                    try? h.seek(toOffset: UInt64(cursor))
                    while cursor < end {
                        try Task.checkCancellation()
                        guard let d = try h.read(upToCount: Int(min(end - cursor, 2 * 1024 * 1024))), !d.isEmpty else { break }
                        dr.respond(with: d); cursor += Int64(d.count)
                    }
                    if cursor >= end { DYStreamStore.shared.noteFirstByte(e.id, src: "file"); req.finishLoading(); return }
                }
            }
            while cursor < end {
                try Task.checkCancellation()
                // 1) 本地有：直接给
                e.lock.lock()
                let local = DYStreamPlan.contiguous(from: cursor, in: e.ranges)
                e.lock.unlock()
                if local > 0 {
                    let n = Int(min(local, end - cursor, 2 * 1024 * 1024))
                    e.lock.lock(); let d = e.read(cursor, n); e.lock.unlock()
                    guard let d, !d.isEmpty else { throw URLError(.cannotOpenFile) }
                    dr.respond(with: d)
                    DYStreamStore.shared.noteFirstByte(e.id, src: "local")
                    cursor += Int64(d.count)
                    continue
                }
                // 2) 别的请求正在下这段：等它写进来（每 60ms 看一次），不重复下
                // 先在锁外算好：horizon() 自己要拿 e.lock，NSLock 不可重入，锁里再调会死锁
                let horizon = DYStreamStore.shared.horizon(e) ?? total
                let starving = DYStreamStore.shared.isStarving(e.id)
                e.lock.lock()
                if e.inflight.contains(where: { $0.contains(cursor) }) {
                    e.lock.unlock()
                    if waitInflightSince == nil { waitInflightSince = Date() }
                    try await Task.sleep(for: .milliseconds(60))
                    continue
                }
                if let since = waitInflightSince {
                    waitInflightSince = nil
                    let w = Date().timeIntervalSince(since)
                    if w > 1, DYStreamStore.shared.isCurrent(e.id) {
                        DYLiveModel.log("DDSTREAMWAIT \(e.id.suffix(6)) at=\(cursor / 1024)KB 等别的请求下这段 \(Int(w * 1000))ms")
                    }
                }
                // 3) 允许范围内就拉，否则挂起等播放位置推进
                var allowed = DYStreamPlan.allowedEnd(for: cursor, horizon: horizon, windows: e.windows)
                // 当前条播放器在等数据（没起播 / 卡住）：放开 1MB，不让「等播放推进」和「等数据」互相卡死
                // （真机：分片 MP4 起播前要先读到 512KB 之后，被允许范围拦住，等了 20 秒）
                // 但每条最多多放 2MB（真机：28 分钟的长视频没起播，这条规则一路放开下了 32MB）
                if starving, cursor < horizon + 2 * 1024 * 1024 {
                    allowed = max(allowed, min(total, cursor + DYStreamPlan.minFetchBytes))
                }
                var fetch = DYStreamPlan.nextFetch(need: cursor, ranges: e.ranges, total: total, allowed: allowed)
                if let f = fetch, let busy = e.inflight.map(\.lowerBound).filter({ $0 > f.lowerBound && $0 < f.upperBound }).min() {
                    fetch = f.lowerBound..<busy
                }
                if let f = fetch { e.inflight.append(f) }
                e.lock.unlock()
                guard let fetch else {
                    // 播放器真来要的数据却挂起超过 1 秒、且离允许范围很远：这是跳转落点（播放位置没跟上），开跳读窗口直接给。
                    // 兜住「播放位置被旧值覆盖 / 回调没报」这类情况，不让播放器和下载互等。
                    e.lock.lock()
                    let shapeNow = e.shape, inWindow = e.windows.contains(where: { $0.contains(cursor) })
                    e.lock.unlock()
                    // 只在「播放器停着等数据」（starving：位置 1.5 秒没动）时开，正常播放时照样按前瞻限速，不白下流量
                    if parks >= 2, starving, cursor > horizon + DYStreamPlan.jumpSlack,
                       let shape = shapeNow, !inWindow {
                        e.lock.lock(); e.windows = Array((e.windows + [DYStreamPlan.jumpWindow(from: cursor, shape: shape)]).suffix(4)); e.lock.unlock()
                        DYLiveModel.log("DDSTREAMJUMP \(e.id.suffix(6)) 挂起太久开跳读窗口 at=\(cursor / 1024)KB horizon=\(horizon / 1024)KB pos=\(String(format: "%.1f", DYStreamStore.shared.position(e.id) ?? -1))")
                        parks = 0
                        continue
                    }
                    let parkT0 = Date()
                    parks += 1
                    #if DEBUG
                    if parks == 1 || parks % 8 == 0, DYStreamStore.shared.isCurrent(e.id) {
                        DYLiveModel.log("DDSTREAMPARKN \(e.id.suffix(6)) n=\(parks) at=\(cursor / 1024)KB allowed=\(allowed / 1024)KB horizon=\(horizon / 1024)KB starving=\(starving) pos=\(String(format: "%.1f", DYStreamStore.shared.position(e.id) ?? -1)) windows=\(e.windows.map { "\($0.lowerBound / 1024)-\($0.upperBound / 1024)" })")
                    }
                    #endif
                    try await park(seconds: 2)
                    if Date().timeIntervalSince(parkT0) > 1 {
                        DYLiveModel.log("DDSTREAMPARK \(e.id.suffix(6)) cur=\(DYStreamStore.shared.isCurrent(e.id)) pos=\(String(format: "%.1f", DYStreamStore.shared.position(e.id) ?? -1)) at=\(cursor / 1024)KB allowed=\(allowed / 1024)KB horizon=\(horizon / 1024)KB waited=\(Int(Date().timeIntervalSince(parkT0) * 1000))ms")
                    }
                    continue
                }
                defer { e.lock.lock(); e.inflight.removeAll { $0 == fetch }; e.lock.unlock() }
                var fed = cursor
                do {
                    try await download(e, fetch) { data in
                        // 只喂播放器要的那部分（下载块的尾巴可能超出这次请求）
                        let room = end - fed
                        guard room > 0 else { return }
                        let piece = Int64(data.count) <= room ? data : data.prefix(Int(room))
                        dr.respond(with: piece)
                        if fed == cursor { DYStreamStore.shared.noteFirstByte(e.id, src: "net") }
                        fed += Int64(piece.count)
                    }
                } catch where DYChunkStream.isRevive(error) && revives < 3 {
                    // 回前台作废了冻住的连接：从已经喂到的位置接着来，新连接马上重拉
                    revives += 1
                    cursor = fed
                    continue
                }
                // 200 整条回来时没直接喂（fed 没动），下一轮从本地读
                cursor = fed
            }
            req.finishLoading()
        } catch is CancellationError {
            // 播放器不要了（划走 / 换条）：什么都不做
        } catch {
            if !Task.isCancelled {
                DYLiveModel.log("DDSTREAM err \(e.id.suffix(6)) \((error as NSError).domain)/\((error as NSError).code)")
                req.finishLoading(with: error)
            }
        }
    }

    /// 拿文件总大小（第一次）：取开头 probeBytes，顺便存下来；同时来的请求共用一次
    private func ensureInfo(_ e: DYStreamEntry) async throws {
        e.lock.lock()
        if e.total != nil { e.lock.unlock(); return }
        let t: Task<Void, Error>
        if let running = e.infoTask { t = running } else {
            t = Task { try await self.download(e, 0..<DYStreamPlan.probeBytes, sink: nil) }
            e.infoTask = t
        }
        e.lock.unlock()
        do { try await t.value } catch {
            e.lock.lock(); if e.infoTask == t { e.infoTask = nil }; e.lock.unlock()
            throw error
        }
    }

    /// 拉一段网络数据：写进稀疏文件，同时按块喂给播放器（sink）
    private func download(_ e: DYStreamEntry, _ range: Range<Int64>, sink: ((Data) -> Void)?) async throws {
        var lastError: Error = URLError(.badServerResponse)
        e.lock.lock()
        // 锁定了来源就只用它（+ 它的跳转结果）；还没锁定按候选顺序试
        var candidates = e.source.map { [e.resolved, $0].compactMap { $0 } } ?? e.sources
        if let s = e.source, !candidates.contains(s) { candidates.append(s) }
        if e.source != nil { candidates += e.sources.filter { !candidates.contains($0) } }
        let knownTotal = e.total
        e.lock.unlock()
        for target in candidates {
            try Task.checkCancellation()
            var r = URLRequest(url: target)
            DYMedia.headers.forEach { r.setValue($1, forHTTPHeaderField: $0) }
            r.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
            do {
                // 按块收（URLSession 每次给几十 KB），不再逐字节 `for try await b in bytes`：
                // 逐字节一条 10MB 视频就是一千万次异步迭代，真机分析里是后台 CPU 第一大户（发烫原因之一）
                let chunks = DYChunkStream(session: session, request: r)
                // 握手占比：每段网络请求是否复用连接、DNS/建连/TLS 各花多少（只记当前条）
                chunks.onMetrics = { m in
                    guard DYStreamStore.shared.isCurrent(e.id), let t = m.transactionMetrics.last else { return }
                    func ms(_ a: Date?, _ b: Date?) -> Int { guard let a, let b else { return -1 }; return Int(b.timeIntervalSince(a) * 1000) }
                    DYLiveModel.log("DDSTREAMCONN \(e.id.suffix(6)) at=\(range.lowerBound / 1024)KB reused=\(t.isReusedConnection) dns=\(ms(t.domainLookupStartDate, t.domainLookupEndDate)) connect=\(ms(t.connectStartDate, t.connectEndDate)) tls=\(ms(t.secureConnectionStartDate, t.secureConnectionEndDate)) ttfb=\(ms(t.requestStartDate, t.responseStartDate)) proto=\(t.networkProtocolName ?? "-") host=\(t.request.url?.host ?? "-")")
                }
                let cid = ObjectIdentifier(chunks)
                track(chunks)
                defer { chunks.cancel(); untrack(cid) }
                let netT0 = Date()
                let resp = try await chunks.response()
                let ttfb = Int(Date().timeIntervalSince(netT0) * 1000)
                defer {
                    // 快进排查：每段网络请求的首字节耗时 / 总耗时 / 速度（只记当前条，划走的预热条不记）
                    if DYStreamStore.shared.isCurrent(e.id) {
                        let ms = max(1, Int(Date().timeIntervalSince(netT0) * 1000))
                        let kb = (range.upperBound - range.lowerBound) / 1024
                        DYLiveModel.log("DDSTREAMNET \(e.id.suffix(6)) \((resp as? HTTPURLResponse)?.statusCode ?? -1) at=\(range.lowerBound / 1024)KB len=\(kb)KB ttfb=\(ttfb)ms total=\(ms)ms \(kb * 1000 / Int64(ms))KB/s sink=\(sink != nil)")
                    }
                }
                guard let http = resp as? HTTPURLResponse, http.statusCode == 206 || http.statusCode == 200 else {
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                    if target == e.resolved { e.lock.lock(); e.resolved = nil; e.lock.unlock() }
                    lastError = URLError(.badServerResponse, userInfo: ["status": code])
                    continue
                }
                var total: Int64?
                if http.statusCode == 206, let cr = http.value(forHTTPHeaderField: "Content-Range"),
                   let slash = cr.split(separator: "/").last { total = Int64(slash) }
                else if http.statusCode == 200, http.expectedContentLength > 0 { total = http.expectedContentLength }
                // 换了地址但文件大小不一样 = 另一个清晰度的文件，字节不能混进来
                if let knownTotal, let total, knownTotal != total {
                    lastError = URLError(.badServerResponse)
                    continue
                }
                e.lock.lock()
                if e.total == nil { e.total = total }
                if e.source == nil { e.source = target }
                if let final = http.url, final != target { e.resolved = final }
                e.lock.unlock()
                // 200 = 服务器不认 Range，回来的是整条：从 0 写，不直接喂（serve 循环会从本地读）
                var offset = http.statusCode == 206 ? range.lowerBound : 0
                let feed = http.statusCode == 206 ? sink : nil
                var buf = Data(); buf.reserveCapacity(64 * 1024)
                func flush() throws {
                    try Task.checkCancellation()
                    e.lock.lock(); e.write(buf, at: offset); e.lock.unlock()
                    feed?(buf)
                    DYStreamStore.shared.noteFetched(Int64(buf.count))
                    offset += Int64(buf.count)
                    buf.removeAll(keepingCapacity: true)
                }
                #if DEBUG
                // 复现真机慢网：DOUDUO_NETKBPS=总带宽(KB/s)，所有连接共用（模拟器网太快，真机卡的场景复现不出来）
                let throttle = Double(ProcessInfo.processInfo.environment["DOUDUO_NETKBPS"] ?? "") ?? 0
                #endif
                for try await chunk in chunks.data {
                    buf.append(chunk)
                    #if DEBUG
                    if throttle > 0 { try await DYNetThrottle.take(chunk.count, kbps: throttle) }
                    #endif
                    if buf.count >= 64 * 1024 { try flush() }
                }
                if !buf.isEmpty { try flush() }
                e.lock.lock(); e.saveMeta(); e.lock.unlock()
                DYStreamStore.shared.finishIfComplete(e)
                return
            } catch {
                e.lock.lock(); e.saveMeta(); e.lock.unlock()
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                // 回前台作废的旧连接：不换地址、不清跳转结果，直接抛给调用方从「已写到哪」重算再拉
                // （serve 已经按块喂过播放器，这里原地重下同一段会把重复字节喂进去）
                if DYChunkStream.isRevive(error) { throw error }
                if target == e.resolved { e.lock.lock(); e.resolved = nil; e.lock.unlock() }
                lastError = error
            }
        }
        throw lastError
    }
}


/// 快进排查日志（DDSEEKNET）：拖进度条期间预览命中/落空多少次、网络在哪开了跳读窗口
#if DEBUG
/// 模拟器限速：令牌桶，所有下载连接共用一个带宽
enum DYNetThrottle {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var next = Date.distantPast
    static func take(_ bytes: Int, kbps: Double) async throws {
        lock.lock()
        let now = Date()
        let start = max(now, next)
        next = start.addingTimeInterval(Double(bytes) / (kbps * 1024))
        let wait = next.timeIntervalSince(now)
        lock.unlock()
        if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
    }
}
#endif

enum DDSeekProbe {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var hits = 0, misses = 0, jumps: [String] = []
    static func peek(miss: Bool) { lock.lock(); if miss { misses += 1 } else { hits += 1 }; lock.unlock() }
    static func jump(_ id: String, at offset: Int64, shape: DYStreamPlan.Shape) {
        let sec = Double(offset - shape.mediaStart) / shape.bytesPerSecond
        lock.lock(); jumps.append(String(format: "%.0fs", sec)); if jumps.count > 8 { jumps.removeFirst() }; lock.unlock()
    }
    /// 取走并清零（一次拖动一份）
    static func drain() -> String {
        lock.lock(); defer { hits = 0; misses = 0; jumps = []; lock.unlock() }
        return "peekHit=\(hits) peekMiss=\(misses) jumps=[\(jumps.joined(separator: ","))]"
    }
}

/// 用 dataTask + delegate 按块收数据（替代逐字节的 URLSession.AsyncBytes）
final class DYChunkStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let data: AsyncThrowingStream<Data, Error>
    private let cont: AsyncThrowingStream<Data, Error>.Continuation
    private var task: URLSessionDataTask?
    private let lock = NSLock()
    private var respCont: CheckedContinuation<URLResponse, Error>?
    private var gotResponse: URLResponse?
    private var failed: Error?

    init(session: URLSession, request: URLRequest) {
        var c: AsyncThrowingStream<Data, Error>.Continuation!
        data = AsyncThrowingStream(bufferingPolicy: .unbounded) { c = $0 }
        cont = c
        super.init()
        let t = session.dataTask(with: request)
        t.delegate = self
        task = t
        t.resume()
    }

    func response() async throws -> URLResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (k: CheckedContinuation<URLResponse, Error>) in
                lock.lock()
                if let r = gotResponse { lock.unlock(); k.resume(returning: r); return }
                if let e = failed { lock.unlock(); k.resume(throwing: e); return }
                respCont = k
                lock.unlock()
            }
        } onCancel: { self.cancel() }
    }

    func cancel() { task?.cancel() }

    private var revived = false
    var onMetrics: ((URLSessionTaskMetrics) -> Void)?
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        onMetrics?(metrics)
    }
    static func isRevive(_ error: Error) -> Bool {
        let n = error as NSError
        return n.domain == NSURLErrorDomain && n.code == URLError.networkConnectionLost.rawValue && n.userInfo["dd.revive"] as? Bool == true
    }
    /// 回前台作废：按「连接断了」结束（不是取消——取消会让播放器的数据请求永远挂着没人答）
    func abortForRevive() {
        lock.lock(); revived = true; lock.unlock()
        task?.cancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock(); gotResponse = response; let k = respCont; respCont = nil; lock.unlock()
        k?.resume(returning: response)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        cont.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let k = respCont; respCont = nil
        var error = error
        if revived { error = URLError(.networkConnectionLost, userInfo: ["dd.revive": true]) }
        if let error { failed = error }
        lock.unlock()
        if let error {
            k?.resume(throwing: error)
            cont.finish(throwing: (error as? URLError)?.code == .cancelled ? CancellationError() : error)
        } else {
            k?.resume(throwing: URLError(.badServerResponse))
            cont.finish()
        }
    }
}
