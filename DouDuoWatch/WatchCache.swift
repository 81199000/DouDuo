import Foundation

/// 手表端视频缓存（和手机一样：先把后面几条预存到本地，刷到时直接本地起播；用不上的定时清掉）。
/// - 只预存当前条之后的 `ahead` 条（当前条直接流播），串行下载，不和正在播的抢带宽
/// - 存在 Caches 目录（系统缺空间时也会自己清）；超过 `ttl` 的自动删，总量超 `capBytes` 先删最旧的
/// - 单个文件超过 `maxFile` 或时长超过 `maxDuration` 的不预存，继续流播
actor WatchCache {
    static let shared = WatchCache()

    /// 缓存保留时长（改这里即可：1 小时 / 2 小时）
    static let ttl: TimeInterval = 60 * 60
    static let capBytes = 120 * 1024 * 1024
    static let maxFile = 30 * 1024 * 1024
    static let maxDuration: Double = 120
    /// 往后预存几条
    static let ahead = 2

    nonisolated static let dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("dd-watch-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    nonisolated static func fileURL(_ id: String) -> URL { dir.appendingPathComponent("\(id).mp4") }
    /// 已完整缓存的本地文件
    nonisolated static func localURL(_ id: String) -> URL? {
        let u = fileURL(id)
        let size = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return size > 0 ? u : nil
    }

    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20
        c.timeoutIntervalForResource = 120
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()
    private static let headers = [
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
        "Referer": "https://www.douyin.com/",
    ]

    private var queue: [DDWatchVideoMeta] = []
    private var running = false

    /// 刷到哪条就把后面几条交进来；新的一批会顶掉还没开始的旧队列（正在下的那条会下完）
    func prefetch(_ metas: [DDWatchVideoMeta]) {
        queue = metas.filter { $0.duration <= Self.maxDuration && Self.localURL($0.id) == nil }
        guard !running, !queue.isEmpty else { return }
        running = true
        Task { await drain() }
    }

    private func drain() async {
        while !queue.isEmpty {
            let m = queue.removeFirst()
            if Self.localURL(m.id) == nil { await fetch(m) }
        }
        running = false
    }

    private func request(_ url: URL) -> URLRequest {
        var r = URLRequest(url: url)
        Self.headers.forEach { r.setValue($1, forHTTPHeaderField: $0) }
        return r
    }

    /// 先用 Range 0-0 探一下总大小，太大就不下（不读正文，拿到响应头就取消）
    private func totalSize(_ url: URL) async -> Int? {
        var r = request(url)
        r.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        guard let (bytes, resp) = try? await session.bytes(for: r), let http = resp as? HTTPURLResponse else { return nil }
        bytes.task.cancel()
        if http.statusCode == 206, let cr = http.value(forHTTPHeaderField: "Content-Range"),
           let n = cr.split(separator: "/").last, let total = Int(n) { return total }
        if http.statusCode == 200, http.expectedContentLength > 0 { return Int(http.expectedContentLength) }
        return nil
    }

    private func fetch(_ m: DDWatchVideoMeta) async {
        guard let url = URL(string: m.url), let total = await totalSize(url), total <= Self.maxFile else { return }
        guard let (tmp, resp) = try? await session.download(for: request(url)),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return }
        let dst = Self.fileURL(m.id)
        try? FileManager.default.removeItem(at: dst)
        try? FileManager.default.moveItem(at: tmp, to: dst)
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: dst.path)
        cleanup()   // 新文件进来后顺手检查总量
    }

    func remove(_ id: String) {
        try? FileManager.default.removeItem(at: Self.fileURL(id))
    }

    /// 过期的删掉；总量超限时从最旧的开始删
    func cleanup() {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? fm.contentsOfDirectory(at: Self.dir, includingPropertiesForKeys: keys) else { return }
        let now = Date()
        var live: [(url: URL, date: Date, size: Int)] = []
        for f in files {
            let v = try? f.resourceValues(forKeys: Set(keys))
            let d = v?.contentModificationDate ?? .distantPast
            if now.timeIntervalSince(d) > Self.ttl || f.pathExtension != "mp4" { try? fm.removeItem(at: f); continue }
            live.append((f, d, v?.fileSize ?? 0))
        }
        var total = live.reduce(0) { $0 + $1.size }
        for f in live.sorted(by: { $0.date < $1.date }) where total > Self.capBytes {
            try? fm.removeItem(at: f.url); total -= f.size
        }
    }

    func totalBytes() -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
}
