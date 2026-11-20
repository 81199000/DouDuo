import AVFoundation
import Foundation
import Network

/// 边下边播（老板 2026-11-20 定 A 方案）。
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
    /// 设置里的「省流量模式」：用流量时降一档清晰度、只预热 1 条
    static let saverKey = "douyin_data_saver_v1"

    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    static var saverOn: Bool { UserDefaults.standard.object(forKey: saverKey) as? Bool ?? true }
    /// 省流量模式只在走蜂窝网络时生效
    static var saving: Bool { saverOn && DYNetPath.shared.cellular }

    static func url(for id: String) -> URL { URL(string: "\(scheme)://v/\(id)")! }
    static func id(of url: URL) -> String? {
        guard url.scheme == scheme else { return nil }
        let id = url.lastPathComponent
        return id.isEmpty ? nil : id
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

    /// 只有 id 的地方（播放页）：已登记过就走 ddstream，否则原样
    static func asset(id: String, remote: URL) -> AVURLAsset {
        guard enabled, !remote.isFileURL, let item = DYStreamStore.shared.item(id) else {
            return remote.isFileURL ? AVURLAsset(url: remote) : DYMedia.asset(remote)
        }
        return asset(for: item, remote: remote)
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
    }

    /// 页面一激活（划到这条）就算当前条——不能等时间观察者报播放位置：
    /// 还没起播时观察者不报，下载又只给当前条放开 → 互相等，长视频永远起不来（真机实测等 20 秒）
    func activate(_ id: String, at seconds: Double = 0) {
        lock.lock()
        let previous = currentID
        let changed = previous != id
        if changed { currentID = id; advancedAt = .distantPast; if playhead[id] == nil { playhead[id] = seconds } }
        let leaving = changed ? entries.values.filter { $0.id == previous } : []
        lock.unlock()
        if changed { DYStreamLoader.shared.bump() }
        logLeave(leaving)
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
        return currentID == id && Date().timeIntervalSince(advancedAt) > 1.0
    }

    func isCurrent(_ id: String) -> Bool { lock.lock(); defer { lock.unlock() }; return currentID == id }
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

    /// 启动 / 清缓存：部分文件按最近使用留 keep 条
    func trim() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: Self.dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let parts = files.filter { $0.pathExtension == "part" }
            .sorted { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) ?? .distantPast
                    > (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast) ?? .distantPast }
        for f in parts.dropFirst(Self.keep) {
            try? fm.removeItem(at: f)
            try? fm.removeItem(at: f.deletingPathExtension().appendingPathExtension("json"))
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

    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.httpMaximumConnectionsPerHost = 6
        c.timeoutIntervalForRequest = 20
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

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

    func resourceLoader(_ loader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource req: AVAssetResourceLoadingRequest) -> Bool {
        guard let url = req.request.url, let streamKey = DYStream.id(of: url), let e = DYStreamStore.shared.entry(streamKey) else { return false }
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
            // 跳着读：当前条拖进度条，或任何条读文件尾部的 moov → 给一个临时窗口，不受播放前瞻限制。
            // 预热中的条正常往后读不放开（否则每次重发请求都多下 8 秒，省流量就白做了）
            e.lock.lock(); let shape = e.shape; e.lock.unlock()
            if let h = DYStreamStore.shared.horizon(e), let shape, cursor > h + DYStreamPlan.jumpSlack,
               DYStreamStore.shared.isCurrent(e.id) || cursor > shape.total * 9 / 10 {
                e.lock.lock(); e.windows = Array((e.windows + [DYStreamPlan.jumpWindow(from: cursor, shape: shape)]).suffix(4)); e.lock.unlock()
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
                    cursor += Int64(d.count)
                    continue
                }
                // 2) 别的请求正在下这段：等它写进来（每 60ms 看一次），不重复下
                // 先在锁外算好：horizon() 自己要拿 e.lock，NSLock 不可重入，锁里再调会死锁
                // （2026-11-20 真机：上一版在锁里调 horizon → 加载线程卡死，画面冻住）
                let horizon = DYStreamStore.shared.horizon(e) ?? total
                let starving = DYStreamStore.shared.isStarving(e.id)
                e.lock.lock()
                if e.inflight.contains(where: { $0.contains(cursor) }) {
                    e.lock.unlock()
                    try await Task.sleep(for: .milliseconds(60))
                    continue
                }
                // 3) 允许范围内就拉，否则挂起等播放位置推进
                var allowed = DYStreamPlan.allowedEnd(for: cursor, horizon: horizon, windows: e.windows)
                // 当前条播放器在等数据（没起播 / 卡住）：放开 1MB，不让「等播放推进」和「等数据」互相卡死
                // （真机：分片 MP4 起播前要先读到 512KB 之后，被允许范围拦住，等了 20 秒）
                // 但每条最多多放 4MB（真机：28 分钟的长视频没起播，这条规则一路放开下了 32MB）
                if starving, cursor < horizon + 4 * 1024 * 1024 {
                    allowed = max(allowed, min(total, cursor + DYStreamPlan.chunkBytes))
                }
                var fetch = DYStreamPlan.nextFetch(need: cursor, ranges: e.ranges, total: total, allowed: allowed)
                if let f = fetch, let busy = e.inflight.map(\.lowerBound).filter({ $0 > f.lowerBound && $0 < f.upperBound }).min() {
                    fetch = f.lowerBound..<busy
                }
                if let f = fetch { e.inflight.append(f) }
                e.lock.unlock()
                guard let fetch else {
                    try await park(seconds: 2)
                    continue
                }
                defer { e.lock.lock(); e.inflight.removeAll { $0 == fetch }; e.lock.unlock() }
                var fed = cursor
                try await download(e, fetch) { data in
                    // 只喂播放器要的那部分（下载块的尾巴可能超出这次请求）
                    let room = end - fed
                    guard room > 0 else { return }
                    let piece = Int64(data.count) <= room ? data : data.prefix(Int(room))
                    dr.respond(with: piece)
                    fed += Int64(piece.count)
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
                let (bytes, resp) = try await session.bytes(for: r)
                #if DEBUG
                DYLiveModel.log("DDSTREAMNET \(e.id.suffix(6)) \((resp as? HTTPURLResponse)?.statusCode ?? -1) range=\(range.lowerBound)-\(range.upperBound)")
                #endif
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
                for try await b in bytes {
                    buf.append(b)
                    if buf.count >= 64 * 1024 { try flush() }
                }
                if !buf.isEmpty { try flush() }
                e.lock.lock(); e.saveMeta(); e.lock.unlock()
                DYStreamStore.shared.finishIfComplete(e)
                return
            } catch {
                e.lock.lock(); e.saveMeta(); e.lock.unlock()
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                if target == e.resolved { e.lock.lock(); e.resolved = nil; e.lock.unlock() }
                lastError = error
            }
        }
        throw lastError
    }
}
