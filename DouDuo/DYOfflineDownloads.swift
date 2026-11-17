import Combine
import Foundation
import Network

@MainActor
final class DYOfflineDownloads: ObservableObject {
    static let shared = DYOfflineDownloads()
    static let maximumCount = 200
    static let downloadCounts = [50, 100, 150, maximumCount]
    static let automaticDownloadKey = "douyin_offline_auto_download"
    static let downloadTargetKey = "douyin_offline_download_target"
    static let defaultDownloadTarget = 50

    static func estimatedSize(for count: Int) -> String {
        let gigabytes = Double(count) * 0.03
        return "\(gigabytes.formatted(.number.precision(.fractionLength(0...2)))) GB"
    }

    static func playableDurationText(_ duration: TimeInterval) -> String? {
        guard duration.isFinite, duration > 0, duration < Double(Int.max) else { return nil }
        return DYFormat.clock(max(1, duration))
    }

    struct Progress {
        let total: Int
        var saved = 0
    }

    struct Result: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let success: Bool
    }

    @Published private(set) var preparing = false
    @Published private(set) var progress: Progress?
    @Published private(set) var savedCount = 0
    @Published private(set) var totalPlayableDuration: TimeInterval = 0
    @Published private(set) var playableUntil: Date?
    @Published private(set) var result: Result?
    @Published private(set) var banner: Result?
    @Published private(set) var isOffline = false
    @Published private(set) var isOnWiFi = false
    @Published private(set) var storageRevision = 0
    @Published private(set) var removing = false

    var remainingCapacity: Int { max(0, Self.maximumCount - savedCount) }

    private var task: Task<Void, Never>?
    private var hideBanner: Task<Void, Never>?
    private var retentionTimer: Task<Void, Never>?
    private var lastLibraryRevision = 0
    private var automaticTask = false
    private var lastAutomaticAttempt: (target: Int, startedAt: ContinuousClock.Instant)?
    private var manuallyCleared = false
    private let monitor = NWPathMonitor()

    private init() {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if environment["DOUDUO_TEST_OFFLINE"] == "1" {
            isOffline = true
            if let rawDelay = environment["DOUDUO_TEST_RECONNECT_AFTER"],
               let seconds = Double(rawDelay), seconds.isFinite, seconds > 0, seconds <= 300 {
                Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                    self?.isOffline = false
                }
            }
            return
        }
        #endif
        monitor.pathUpdateHandler = { [weak self] path in
            let offline = path.status == .unsatisfied
            let onWiFi = path.status == .satisfied && path.usesInterfaceType(.wifi)
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.isOffline != offline { self.isOffline = offline }
                if self.isOnWiFi != onWiFi { self.isOnWiFi = onWiFi }
                if !onWiFi, self.automaticTask { self.cancel() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "douduo.offline-connectivity"))
    }

    func refreshRetention() async {
        let status = await DYVideoCache.shared.refreshOfflineRetention()
        applyLibrary(status.library, revision: status.revision)
    }

    func recordPlayback(of id: String, completed: Bool) async {
        guard let status = await DYVideoCache.shared.recordOfflinePlayback(id, completed: completed) else { return }
        applyLibrary(status.library, revision: status.revision)
    }

    private func applyLibrary(_ library: DYOfflineVideoStore.Library, revision: Int) {
        guard revision > lastLibraryRevision else {
            if library.removedExpiredVideos { storageRevision += 1 }
            return
        }
        lastLibraryRevision = revision
        if savedCount != library.videos.count { savedCount = library.videos.count }
        let duration = library.duration
        if totalPlayableDuration != duration { totalPlayableDuration = duration }
        if playableUntil != library.expiresAt || retentionTimer == nil {
            if playableUntil != library.expiresAt { playableUntil = library.expiresAt }
            scheduleRetentionCheck(at: library.expiresAt)
        }
        if library.removedExpiredVideos { storageRevision += 1 }
    }

    private func scheduleRetentionCheck(at date: Date?) {
        retentionTimer?.cancel()
        retentionTimer = nil
        guard let date else { return }
        retentionTimer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow))) } catch { return }
            guard let self else { return }
            self.retentionTimer = nil
            await self.refreshRetention()
        }
    }

    func startAutomatic(candidateSource: @escaping (Int) async throws -> [DYAweme]) {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Self.automaticDownloadKey) else {
            stopAutomatic()
            return
        }
        guard isOnWiFi, !manuallyCleared, !removing, task == nil else { return }
        let preference = defaults.integer(forKey: Self.downloadTargetKey)
        let target = Self.downloadCounts.contains(preference) ? preference : Self.defaultDownloadTarget
        guard savedCount < target else { return }
        if let attempt = lastAutomaticAttempt, attempt.target == target,
           attempt.startedAt.duration(to: .now) < .seconds(30 * 60) { return }
        lastAutomaticAttempt = (target, .now)
        start(count: target, automatic: true, candidateSource: candidateSource)
    }

    func stopAutomatic() {
        if automaticTask { cancel() }
        lastAutomaticAttempt = nil
    }

    func start(count: Int, candidateSource: @escaping (Int) async throws -> [DYAweme]) {
        start(count: count, automatic: false, candidateSource: candidateSource)
    }

    private func start(count: Int, automatic: Bool, candidateSource: @escaping (Int) async throws -> [DYAweme]) {
        guard !removing, task == nil, Self.downloadCounts.contains(count) else { return }
        result = nil
        dismissBanner()
        preparing = true
        automaticTask = automatic
        task = Task(priority: .utility) {
            let cache = DYVideoCache.shared
            let status = await cache.refreshOfflineRetention()
            let saved = status.library.videos
            applyLibrary(status.library, revision: status.revision)
            if Task.isCancelled {
                finish(Result(title: "下载已停止", message: "已保存 0 条离线视频", success: false))
                return
            }
            let limit = max(0, min(automatic ? count - saved.count : count, Self.maximumCount - saved.count))
            guard limit > 0 else {
                finish(Result(title: "离线视频已达上限", message: "删除部分离线视频后可继续下载。", success: false))
                return
            }

            let candidates: [DYAweme]
            do {
                candidates = try await candidateSource(limit)
                try Task.checkCancellation()
            } catch {
                let cancelled = Task.isCancelled || error is CancellationError
                finish(Result(title: cancelled ? "下载已停止" : "下载失败",
                              message: cancelled ? "已保存 0 条离线视频" : "暂时无法获取推荐，请联网后重试。",
                              success: false))
                return
            }
            var seen = Set(saved.map(\.id))
            let videos = Array(candidates.filter { seen.insert($0.id).inserted }.prefix(limit))
            guard !videos.isEmpty else {
                finish(Result(title: "没有可下载的视频", message: "推荐更新后可以再试。", success: false))
                return
            }
            preparing = false
            progress = Progress(total: videos.count)
            await download(videos, automatic: automatic, cache: cache)
        }
    }

    private func download(_ videos: [DYAweme], automatic: Bool, cache: DYVideoCache) async {
        await cache.beginOfflineBatch()
        var failures = 0
        var outOfSpace = false
        for video in videos {
            if Task.isCancelled { break }
            do {
                try await cache.saveOffline(video, wifiOnly: automatic)
                progress?.saved += 1
            } catch is CancellationError {
                break
            } catch {
                if Task.isCancelled { break }
                failures += 1
                let error = error as NSError
                if error.domain == NSCocoaErrorDomain && error.code == NSFileWriteOutOfSpaceError {
                    outOfSpace = true
                    break
                }
            }
        }
        await cache.endOfflineBatch()
        await refreshRetention()
        storageRevision += 1

        let successes = progress?.saved ?? 0
        let countText = "已保存 \(DYFormat.count(successes)) 条离线视频"
        let summary: Result
        if Task.isCancelled {
            summary = Result(title: "下载已停止", message: countText, success: false)
        } else if outOfSpace {
            summary = Result(title: "储存空间不足", message: countText, success: false)
        } else if failures > 0 {
            summary = Result(title: successes > 0 ? "已下载部分离线视频" : "下载失败",
                             message: "保存 \(DYFormat.count(successes)) 条，失败 \(DYFormat.count(failures)) 条", success: false)
        } else {
            let message: String
            if let duration = Self.playableDurationText(totalPlayableDuration) {
                message = "\(countText)，离线视频预计可播放 \(duration)"
            } else {
                message = "\(countText)，断网可在推荐页播放"
            }
            summary = Result(title: "离线视频下载完成", message: message, success: true)
        }
        finish(summary)
    }

    private func finish(_ summary: Result) {
        let showResult = !automaticTask || summary.success || (progress?.saved ?? 0) > 0
        if showResult { result = summary }
        preparing = false
        progress = nil
        task = nil
        automaticTask = false
        if showResult, !Task.isCancelled { showBanner(summary) }
    }

    func cancel() { task?.cancel() }

    func removeAll() async {
        guard task == nil, !removing else { return }
        removing = true
        manuallyCleared = true
        let removed = await DYVideoCache.shared.removeOfflineItems()
        await refreshRetention()
        storageRevision += 1
        result = Result(title: removed ? "已删除离线视频" : "部分视频未能删除",
                        message: removed ? "已释放离线视频占用的储存空间" : "请稍后重试", success: removed)
        removing = false
    }

    private func showBanner(_ result: Result) {
        dismissBanner()
        banner = result
        hideBanner = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            self?.banner = nil
        }
    }

    func dismissBanner() {
        hideBanner?.cancel()
        hideBanner = nil
        banner = nil
    }
}
