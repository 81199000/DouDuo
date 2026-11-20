import AVFoundation
import Foundation
import Synchronization

/// 浏览会话保存在 Application Support，不随视频缓存清理或系统回收而丢失。
struct DYFeedSession: Codable {
    var items: [DYAweme]
    var currentID: String
    var positions: [String: Double]

    static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("feed-session.json")
    }
    static func load() -> DYFeedSession? {
        guard let data = try? Data(contentsOf: url),
              let session = try? JSONDecoder().decode(Self.self, from: data),
              session.items.contains(where: { $0.id == session.currentID }) else { return nil }
        return session
    }
    func save() {
        guard items.contains(where: { $0.id == currentID }),
              let data = try? JSONEncoder().encode(self) else { return }
        do { try data.write(to: Self.url, options: .atomic) }
        catch { DYLiveModel.log("DDSESSION 保存失败 \(error.localizedDescription)") }
    }
}

actor DYVideoCache {
    static let shared = DYVideoCache()
    static let countKey = "douyin_cache_count_v2"
    static let defaultCount = 5
    /// 超过这个时长不缓存（整条太大），直接在线播。30 分钟以内整条下，长视频切换也能秒开
    static let maxDuration: Double = 1800
    /// 播放中的长视频避免同时整条下载，给起播和缓冲留出带宽。
    static let longThreshold: Double = 600
    /// 「已看过」的缓存最多留几条：看过的没必要占盘，重启也不该再刷到
    static let watchedKeep = 3
    /// 单条缓存体积上限（估算）：超过就不整条下，避免 20 分钟以上的大片把盘和带宽吃满
    static let sizeCap: Double = 400 * 1024 * 1024
    /// 不超过这个时长的算短视频：整条几秒内下完，优先下；更长的排在后面，不堵下一条
    static let blockingDuration: Double = 90
    /// 给下一、下下条准备完整缓存。
    static let headPrefetch = 2
    static let assumeBitsPerSecond: Double = 2_500_000
    static let maxBytes = 2 * 1024 * 1024 * 1024

    struct Entry: Codable {
        var aweme: DYAweme
        var watched: Bool
        var added: Double
        var bytes: Int
    }
    nonisolated static let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("dd-videos", isDirectory: true)
    nonisolated static var indexURL: URL { dir.appendingPathComponent("index.json") }
    nonisolated static func fileURL(_ id: String) -> URL { dir.appendingPathComponent("\(id).mp4") }
    private nonisolated static var headIndexURL: URL { dir.appendingPathComponent("heads.json") }
    private nonisolated static func headURL(_ id: String) -> URL { dir.appendingPathComponent("\(id).head") }
    private nonisolated static func headFiles() -> [URL] {
        let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])
        return (files ?? []).filter { $0.pathExtension == "head" }
    }

    nonisolated static var limit: Int {
        (UserDefaults.standard.object(forKey: countKey) as? Int) ?? defaultCount
    }

    /// 已经整条下完的本地文件
    nonisolated static func localURL(_ id: String) -> URL? {
        DYOfflineVideoStore.localURL(id) ?? automaticURL(id)
    }

    private nonisolated static func automaticURL(_ id: String) -> URL? {
        let f = fileURL(id)
        return FileManager.default.fileExists(atPath: f.path) ? f : nil
    }

    private nonisolated static func readIndex() -> [Entry]? {
        guard let data = try? Data(contentsOf: indexURL) else { return nil }
        return try? JSONDecoder().decode([Entry].self, from: data)
    }

    /// 启动时用：缓存好、还没看过的，按加入顺序
    nonisolated static func pendingSnapshot() -> [DYAweme] {
        (readIndex() ?? []).filter { !$0.watched && automaticURL($0.aweme.id) != nil }.map(\.aweme)
    }

    /// 调试日志用（不要求精确）
    private static let downloadCount = Mutex(0)
    nonisolated static var activeDownloads: Int { downloadCount.withLock { $0 } }

    private var entries: [Entry]
    private var job: Task<Void, Never>?
    private var jobID: String?
    private var focusedItems: [DYAweme] = []
    private var longCompletion: Task<Void, Never>?
    private var failed: Set<String> = []
    /// 本次运行已划到过的：markWatched 时这条可能还没入库（边下边播看着看着才拼齐 / 整条下载晚于划到），
    /// 入库时按这里置已看，否则重启后会被当成「没看过」塞回推荐（工单 B2：重复内容）
    private var watchedIDs: Set<String> = []
    private var prepared = false
    private var clearing = false
    private var manualBatch = false
    private var offlineLibraryRevision = 0
    private var playbackWaiting = false
    private let session: URLSession

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.httpMaximumConnectionsPerHost = 6
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 600
        cfg.waitsForConnectivity = false
        cfg.urlCache = nil
        session = URLSession(configuration: cfg)
        entries = (Self.readIndex() ?? []).filter { Self.automaticURL($0.aweme.id) != nil }
    }

    func setPlaybackWaiting(_ v: Bool) { playbackWaiting = v }

    /// 播放器直接调用（不 await）：起播/卡顿时让缓存下载让路
    nonisolated func reportPlaybackWaiting(_ v: Bool) {
        Task { await setPlaybackWaiting(v) }
    }

    private func waitWhilePlaybackWaiting() async {
        for _ in 0..<40 where playbackWaiting && !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    func focus(current: DYAweme?, ahead: [DYAweme]) {
        guard !clearing, !manualBatch else { return }
        // 边下边播开着且在用流量：不再整条预下载（省流量的关键）。开头几秒由预热播放器经 ddstream 取，
        // 看完的条由边下边播自然拼成完整文件再收进来。Wi-Fi 下照旧整条预下后面几条（启动秒开池靠它）
        if DYStream.enabled, DYNetPath.shared.cellular {
            job?.cancel(); job = nil; jobID = nil
            prepare()
            return
        }
        prepare()
        let previous = job
        guard Self.limit > 0 else {
            previous?.cancel()
            longCompletion?.cancel()
            jobID = nil
            focusedItems = []
            evict()
            save()
            return
        }
        guard let target = current ?? ahead.first else { return }
        let rest = current == nil ? Array(ahead.dropFirst()) : ahead
        let follow = Array(rest.prefix(Self.headPrefetch))
        let candidates = [target] + follow
        focusedItems = candidates
        if jobID == target.id { return }
        previous?.cancel()
        jobID = target.id
        // 边下边播时当前这条由播放器自己边播边存，整条下载只管后面的，免得同一条下两遍
        let plan = Self.plan(current: target, ahead: follow).filter { !(DYStream.enabled && current != nil && $0 == target.id) }
        job = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            for id in plan {
                guard !Task.isCancelled else { return }
                if let item = candidates.first(where: { $0.id == id }) {
                    await self.store(item)
                }
            }
        }
    }

    /// 整条缓存的顺序（纯函数，脚本测试直接跑）：
    /// 先下一条、当前、再后面一条里的短视频（≤90 秒），再补长视频（当前 → 下一条 → 后面），超 10 分钟的不排。
    nonisolated static func plan(current: DYAweme, ahead: [DYAweme]) -> [String] {
        func playable(_ a: DYAweme) -> Bool { a.images.isEmpty && a.play != nil }
        func quick(_ a: DYAweme) -> Bool { a.duration > 0 && a.duration <= blockingDuration }
        /// 能整条下：时长在范围内、估算体积不至于太大
        func cacheable(_ a: DYAweme) -> Bool {
            a.duration > 0 && a.duration <= maxDuration
                && a.duration * assumeBitsPerSecond / 8 <= sizeCap
        }
        let next = Array(ahead.prefix(1)), later = Array(ahead.dropFirst())
        // 正在播的这条：短的下完不碍事；长的（还在联网播）绝不同时整条下载，
        // 否则下载和播放抢同一条连接，起播要等到十秒以上（实测 dur=1228 等了 11.78s 还没起）
        let currentIsLong = current.duration > longThreshold && localURL(current.id) == nil
        let order = (currentIsLong ? [] : [current]) + next + later
        var out: [String] = []
        for a in order where playable(a) && quick(a) && cacheable(a) && !out.contains(a.id) { out.append(a.id) }
        for a in order where playable(a) && !quick(a) && cacheable(a) && !out.contains(a.id) { out.append(a.id) }
        return out
    }

    private func store(_ item: DYAweme) async {
        guard Self.localURL(item.id) == nil, !failed.contains(item.id) else { return }
        await waitWhilePlaybackWaiting()
        guard !Task.isCancelled, Self.limit > 0 else { return }
        // 边下边播开着：整条预下也写进同一个边下边播文件（播放器正在读的那份），拼齐后自动收进来，
        // 不再另下一份完整文件（模拟器实测：两条路各下一遍，同一条视频花两倍流量）
        if DYStream.enabled, let remote = item.play.flatMap(URL.init(string:)) {
            let t0 = Date()
            if await DYStreamLoader.shared.fillWhole(item, remote: remote) {
                // 收进正式缓存是异步的，等它落地再继续，免得下一轮又当成没缓存
                for _ in 0..<20 where Self.localURL(item.id) == nil { try? await Task.sleep(for: .milliseconds(50)) }
                DYLiveModel.log("DDCACHE ok \(item.id) via-stream \(String(format: "%.1f", Date().timeIntervalSince(t0)))s total=\(entries.count)")
            } else if !Task.isCancelled {
                failed.insert(item.id)
            }
            return
        }
        await storeFull(item)
    }

    private func downloadURLs(_ item: DYAweme) -> [URL] {
        [item.play, item.playAlt, item.playFast].compactMap { $0 }.compactMap { URL(string: $0) }
    }

    /// 较大的视频用四条 Range 请求并行下载。
    private static let segments = 4
    /// 小于这个体积就单连接，分段反而多几次握手
    private static let segmentMinBytes = 6 * 1024 * 1024

    /// 播过 10 秒后补齐已经有头段的长视频。常规预缓存仍使用完整文件，
    /// 避免用只有部分数据的 MP4 起播时的 AVFoundation 解码错误。
    func completeLong(id: String) async {
        guard !clearing, !manualBatch, Self.limit > 0, longCompletion == nil,
              Self.localURL(id) == nil,
              let item = focusedItems.first(where: { $0.id == id }) else { return }
        let head = Self.headURL(id)
        guard let bytes = try? head.resourceValues(forKeys: [.fileSizeKey]).fileSize, bytes > 120_000 else { return }
        let completion = Task {
            await waitWhilePlaybackWaiting()
            await storeFull(item, fromHead: head)
        }
        longCompletion = completion
        await completion.value
        longCompletion = nil
    }

    private func storeFull(_ item: DYAweme, fromHead head: URL? = nil) async {
        let fm = FileManager.default
        let t0 = Date()
        Self.downloadCount.withLock { $0 += 1 }
        defer { Self.downloadCount.withLock { $0 -= 1 } }

        let urls = downloadURLs(item)
        for url in head == nil ? urls[...] : urls.prefix(1) {
            guard !Task.isCancelled else { return }
            let staging = DYStorageFiles.videoWorkDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            do {
                try fm.createDirectory(at: staging, withIntermediateDirectories: true)
                defer { try? fm.removeItem(at: staging) }
                let file = try await downloadParallel(url, staging: staging, maximumBytes: Int(Self.sizeCap), fromHead: head)
                defer { try? fm.removeItem(at: file) }
                try Task.checkCancellation()
                guard Self.limit > 0 else { return }
                let bytes = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard bytes > 50_000, bytes <= Int(Self.sizeCap) else { continue }
                try fm.createDirectory(at: Self.dir, withIntermediateDirectories: true)
                let destination = Self.fileURL(item.id)
                guard Self.localURL(item.id) == nil else { return }
                try fm.moveItem(at: file, to: destination)
                if let head { try? fm.removeItem(at: head) }
                entries.removeAll { $0.aweme.id == item.id }
                entries.append(Entry(aweme: item, watched: watchedIDs.contains(item.id), added: Date().timeIntervalSince1970, bytes: bytes))
                evict()
                save()
                // 整条下好了：边下边播那份半截的没用了，之后播放 / 补货都直接用这个整条文件
                DYStreamStore.shared.dropPartial(item.id)
                DYLiveModel.log("DDCACHE ok \(item.id) \(bytes / 1024)KB host=\(url.host ?? "-") \(String(format: "%.1f", Date().timeIntervalSince(t0)))s total=\(entries.count)")
                return
            } catch {
                if Task.isCancelled { return }
                DYLiveModel.log("DDCACHE fail host=\(url.host ?? "-") \(error.localizedDescription)")
            }
        }
        if head == nil, !Task.isCancelled { failed.insert(item.id) }
    }

    func beginOfflineBatch() async {
        manualBatch = true
        await stopAutomaticWork()
        _ = DYStorageFiles.removeIfPresent(DYOfflineVideoStore.stagingDirectory)
    }

    func endOfflineBatch() {
        manualBatch = false
    }

    func offlinePlaybackItems() -> (saved: [DYAweme], automatic: [DYAweme]) {
        // This also works before the actor has restored its in-memory index on launch.
        let list = Self.readIndex() ?? entries
        let available = list.filter { Self.automaticURL($0.aweme.id) != nil }
        return (DYOfflineVideoStore.snapshot(),
                available.filter { !$0.watched }.map(\.aweme) + available.filter(\.watched).map(\.aweme))
    }

    func offlineItems() -> [DYAweme] { DYOfflineVideoStore.snapshot() }
    func removeOfflineItems() -> Bool { DYOfflineVideoStore.removeAll() }

    func refreshOfflineRetention() -> (revision: Int, library: DYOfflineVideoStore.Library) {
        offlineLibraryRevision += 1
        return (offlineLibraryRevision, DYOfflineVideoStore.refreshRetention())
    }

    func recordOfflinePlayback(_ id: String, completed: Bool) -> (revision: Int, library: DYOfflineVideoStore.Library)? {
        guard let library = DYOfflineVideoStore.recordPlayback(id: id, completed: completed) else { return nil }
        offlineLibraryRevision += 1
        return (offlineLibraryRevision, library)
    }

    func saveOffline(_ video: DYAweme, wifiOnly: Bool = false) async throws {
        if DYOfflineVideoStore.localURL(video.id) != nil { return }
        try Task.checkCancellation()
        let fm = FileManager.default
        let available = DYOfflineVideoStore.availableBytes() ?? Int.max
        guard available > 0 else { throw CocoaError(.fileWriteOutOfSpace) }
        if let file = Self.automaticURL(video.id),
           (try? await offlinePlayable(file)) == true,
           Self.automaticURL(video.id) != nil {
            try Task.checkCancellation()
            let staging = DYOfflineVideoStore.stagingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: staging) }
            try DYOfflineVideoStore.save(video, file: file, copying: true, staging: staging)
            return
        }

        await waitWhilePlaybackWaiting()
        for url in downloadURLs(video) {
            try Task.checkCancellation()
            let staging = DYOfflineVideoStore.stagingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: staging) }
            do {
                let file = try await downloadParallel(url, staging: staging, maximumBytes: available, wifiOnly: wifiOnly)
                defer { try? fm.removeItem(at: file) }
                try Task.checkCancellation()
                let bytes = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard bytes > 50_000 else { continue }
                guard bytes <= available else { throw CocoaError(.fileWriteOutOfSpace) }
                let stagedVideo = staging.appendingPathComponent("source.mp4")
                try fm.moveItem(at: file, to: stagedVideo)
                // 检查下载结果能否独立播放，避免把 CDN 的错误正文当成离线视频。
                guard try await offlinePlayable(stagedVideo) else { continue }
                try DYOfflineVideoStore.save(video, file: stagedVideo, copying: false, staging: staging)
                return
            } catch {
                try Task.checkCancellation()
                if (error as? URLError)?.code == .dataLengthExceedsMaximum
                    || (error as? CocoaError)?.code == .fileWriteOutOfSpace {
                    throw CocoaError(.fileWriteOutOfSpace)
                }
            }
        }
        throw URLError(.cannotDecodeContentData)
    }

    private func offlinePlayable(_ file: URL) async throws -> Bool {
        let asset = AVURLAsset(url: file)
        guard try await asset.load(.isPlayable) else { return false }
        return try await !asset.loadTracks(withMediaType: .video).isEmpty
    }

    /// 返回的临时文件由调用方持有。探测文件和每一段下载也各自有清理路径。
    private func downloadParallel(_ url: URL, staging: URL, maximumBytes: Int, wifiOnly: Bool = false,
                                  fromHead head: URL? = nil) async throws -> URL {
        var request = URLRequest(url: url)
        request.allowsCellularAccess = !wifiOnly
        DYMedia.headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        var probe = request
        probe.setValue("bytes=0-0", forHTTPHeaderField: "Range")

        let (first, response) = try await session.download(for: probe)
        let http = response as? HTTPURLResponse
        if http?.statusCode == 200 { return first }
        try? FileManager.default.removeItem(at: first)
        guard http?.statusCode == 206 else { throw URLError(.badServerResponse) }
        let range = http?.value(forHTTPHeaderField: "Content-Range")
        let total = range?.split(separator: "/").last.flatMap { Int($0) } ?? 0
        guard total <= maximumBytes else { throw URLError(.dataLengthExceedsMaximum) }

        let headBytes = try head?.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        if headBytes == 0, total <= Self.segmentMinBytes {
            let (file, response) = try await session.download(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                try? FileManager.default.removeItem(at: file)
                throw URLError(.badServerResponse)
            }
            return file
        }

        guard total > headBytes else { throw URLError(.badServerResponse) }
        let session = session
        let remaining = total - headBytes
        let count = headBytes == 0 ? Self.segments : min(Self.segments, max(1, remaining / (4 << 20)))
        let partSize = remaining / count
        let parts = try await withThrowingTaskGroup(of: (Int, URL).self) { group in
            for index in 0..<count {
                let low = headBytes + index * partSize
                let high = index == count - 1 ? total - 1 : low + partSize - 1
                var partRequest = request
                partRequest.setValue("bytes=\(low)-\(high)", forHTTPHeaderField: "Range")
                let rangedRequest = partRequest
                group.addTask {
                    let (file, response) = try await session.download(for: rangedRequest)
                    defer { try? FileManager.default.removeItem(at: file) }
                    try Task.checkCancellation()
                    guard let http = response as? HTTPURLResponse, http.statusCode == 206,
                          http.value(forHTTPHeaderField: "Content-Range")?.lowercased() == "bytes \(low)-\(high)/\(total)",
                          try file.resourceValues(forKeys: [.fileSizeKey]).fileSize == high - low + 1 else {
                        throw URLError(.badServerResponse)
                    }
                    let part = staging.appendingPathComponent(String(index))
                    try FileManager.default.moveItem(at: file, to: part)
                    return (index, part)
                }
            }
            var parts: [(Int, URL)] = []
            for try await part in group { parts.append(part) }
            return parts.sorted { $0.0 < $1.0 }.map(\.1)
        }

        let joined = staging.appendingPathComponent("full")
        if let head {
            try FileManager.default.copyItem(at: head, to: joined)
        } else {
            FileManager.default.createFile(atPath: joined.path, contents: nil)
        }
        let output = try FileHandle(forWritingTo: joined)
        defer { try? output.close() }
        if head != nil { _ = try output.seekToEnd() }
        for part in parts {
            let input = try FileHandle(forReadingFrom: part)
            defer { try? input.close() }
            while let chunk = try input.read(upToCount: 4 << 20), !chunk.isEmpty {
                try Task.checkCancellation()
                try output.write(contentsOf: chunk)
            }
            try FileManager.default.removeItem(at: part)
        }
        guard try output.offset() == UInt64(total) else { throw URLError(.badServerResponse) }
        return joined
    }

    /// 边下边播把整条拼齐了：硬链接成正式缓存（同一份数据，不多占空间），以后直接本地播 / 离线看
    func adoptStreamed(_ item: DYAweme, file: URL, bytes: Int) {
        let fm = FileManager.default
        let destination = Self.fileURL(item.id)
        guard Self.localURL(item.id) == nil, bytes > 50_000 else { return }
        try? fm.createDirectory(at: Self.dir, withIntermediateDirectories: true)
        do { try fm.linkItem(at: file, to: destination) } catch {
            guard (try? fm.copyItem(at: file, to: destination)) != nil else { return }
        }
        entries.removeAll { $0.aweme.id == item.id }
        // 当前条看着看着拼齐的：划到时 markWatched 已记进 watchedIDs，这里直接记成已看；Wi-Fi 整条预下的没看过，进启动秒开池
        entries.append(Entry(aweme: item, watched: watchedIDs.contains(item.id), added: Date().timeIntervalSince1970, bytes: bytes))
        evict()
        save()
    }

    func markWatched(_ id: String) {
        watchedIDs.insert(id)
        guard let i = entries.firstIndex(where: { $0.aweme.id == id }), !entries[i].watched else { return }
        entries[i].watched = true
        save()
    }

    private func stopAutomaticWork() async {
        let pendingJob = job
        let pendingCompletion = longCompletion
        pendingJob?.cancel()
        pendingCompletion?.cancel()
        await pendingJob?.value
        await pendingCompletion?.value
        job = nil
        jobID = nil
    }

    func clear() async -> Int {
        await clearAutomaticCache().bytes
    }

    func clearForStorage() async -> Bool {
        await clearAutomaticCache().removed
    }

    private func clearAutomaticCache() async -> (bytes: Int, removed: Bool) {
        guard !clearing else { return (0, false) }
        clearing = true
        defer { clearing = false }
        await stopAutomaticWork()
        failed.removeAll()
        let heads = Self.headFiles()
        let headBytes = heads.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        let bytes = entries.reduce(headBytes) { $0 + $1.bytes }
        DYStreamStore.shared.clearAll()
        let removed = DYStorageFiles.removeIfPresent(Self.dir)
        entries.removeAll { Self.automaticURL($0.aweme.id) == nil }
        let removedTemporary = DYStorageFiles.removeVideoWork()
        return (removed ? bytes : 0, removed && removedTemporary)
    }

    private func prepare() {
        guard !prepared else { return }
        prepared = true
        _ = DYStorageFiles.removeIfPresent(DYStorageFiles.videoWorkDirectory)
        if !manualBatch { _ = DYStorageFiles.removeIfPresent(DYOfflineVideoStore.stagingDirectory) }
        // 丢失索引或被中断的写入可能留下未登记的视频。保留可由索引恢复的完整文件。
        let retained = Set(entries.map { Self.fileURL($0.aweme.id).lastPathComponent }
                           + [Self.indexURL.lastPathComponent, Self.headIndexURL.lastPathComponent])
        if let files = try? FileManager.default.contentsOfDirectory(at: Self.dir, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension != "head" && !retained.contains(file.lastPathComponent)
                && file.lastPathComponent != DYStreamStore.dir.lastPathComponent {
                _ = DYStorageFiles.removeIfPresent(file)
            }
        }
    }

    /// 超上限：先删看过的（最早的先删），还超就删最早加进来的
    private func evict() {
        // 「已看过」最多留 watchedKeep 条，其余先删：看过的缓存没意义，重启也不该再刷到
        var watched = entries.filter(\.watched).count
        while watched > Self.watchedKeep, let idx = entries.firstIndex(where: \.watched) {
            let e = entries.remove(at: idx)
            try? FileManager.default.removeItem(at: Self.fileURL(e.aweme.id))
            watched -= 1
        }
        let lim = max(Self.limit, 0)
        while entries.count > lim || entries.reduce(0, { $0 + $1.bytes }) > Self.maxBytes {
            let idx = entries.firstIndex(where: \.watched) ?? 0
            let e = entries.remove(at: idx)
            try? FileManager.default.removeItem(at: Self.fileURL(e.aweme.id))
        }
    }

    /// 启动时回收旧版分段、索引之外的文件和已看过的视频。
    func purgeWatched() {
        prepare()
        let stale = entries.filter(\.watched)
        for entry in stale { _ = DYStorageFiles.removeIfPresent(Self.fileURL(entry.aweme.id)) }
        entries.removeAll(where: \.watched)
        evict()
        save()
    }

    /// 清理之前版本留下的头段文件；目前的常规预缓存不再生成这些文件。
    func purgeHeads() {
        for head in Self.headFiles() { _ = DYStorageFiles.removeIfPresent(head) }
        _ = DYStorageFiles.removeIfPresent(Self.headIndexURL)
    }

    private func save() {
        if let d = try? JSONEncoder().encode(entries) { try? d.write(to: Self.indexURL, options: .atomic) }
    }
}
