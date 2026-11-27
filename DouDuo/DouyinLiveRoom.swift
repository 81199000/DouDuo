import SwiftUI
import UIKit
import Combine
import AVFoundation

struct DYLiveStream: Hashable {
    let url: URL
    let quality: String
    let isFLV: Bool
    var cacheMS: Int32 { isFLV ? 800 : 1500 }
}

extension DYLiveRoom {
    /// 优先连续 HTTP-FLV，避免 HLS 播放列表/分片等待；同画质 HLS 保留为兜底。
    var liveStreams: [DYLiveStream] {
        let flv = flv ?? [:]
        let keys = ["HD1", def ?? "", "FULL_HD1", "SD1", "SD2"] + Array(Set(hls.keys).union(flv.keys)).sorted()
        var seen = Set<URL>()
        var result: [DYLiveStream] = []
        #if DEBUG
        let hlsOnly = ProcessInfo.processInfo.environment["DOUDUO_LIVE_HLS"] == "1"
        #else
        let hlsOnly = false
        #endif
        for key in keys where !key.isEmpty {
            for isFLV in [true, false] where !(hlsOnly && isFLV) {
                guard let value = (isFLV ? flv : hls)[key], let url = URL(string: value),
                      ["http", "https"].contains(url.scheme?.lowercased() ?? ""), seen.insert(url).inserted else { continue }
                result.append(DYLiveStream(url: url, quality: key, isFLV: isFLV))
            }
        }
        return result
    }
}

/// 进房接口（webcast/room/web/enter）只用来换 H.264 播放线路：匿名直连，不经过隐藏网页、不带登录 cookie。
/// 2026-11-28 实测：经隐藏网页（带登录 + 页面签名）发出去回 200 空包；只带一个匿名 ttwid 直连则稳定返回，约 0.4 秒。
/// 只拿流地址，不碰账号，所以就算被风控也牵连不到登录。
@MainActor
enum DYLiveEnterClient {
    private static var ttwid: String?
    private static var ttwidTask: Task<String?, Never>?

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.timeoutIntervalForRequest = 6
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    static func streams(webRid: String) async -> DYLiveEnterStreams? {
        guard !webRid.isEmpty else { return nil }
        for attempt in 0..<2 {
            guard let tt = await anonymousTTWID(fresh: attempt > 0) else { return nil }
            var q = URLComponents(string: "https://live.douyin.com/webcast/room/web/enter/")!
            q.queryItems = [("aid", "6383"), ("app_name", "douyin_web"), ("live_id", "1"), ("device_platform", "web"),
                            ("language", "zh-CN"), ("enter_from", "web_live"), ("cookie_enabled", "true"),
                            ("screen_width", "1440"), ("screen_height", "900"), ("browser_language", "zh-CN"),
                            ("browser_platform", "MacIntel"), ("browser_name", "Safari"), ("browser_version", "26.0"),
                            ("channel", "channel_pc_web"), ("enter_source", ""), ("web_rid", webRid)]
                .map { URLQueryItem(name: $0.0, value: $0.1) }
            guard let url = q.url else { return nil }
            var r = URLRequest(url: url)
            r.setValue(DouyinWeb.userAgent, forHTTPHeaderField: "User-Agent")
            r.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
            r.setValue("https://live.douyin.com/\(webRid)", forHTTPHeaderField: "Referer")
            r.setValue("ttwid=\(tt)", forHTTPHeaderField: "Cookie")
            guard let (data, resp) = try? await session.data(for: r) else { return nil }
            let http = (resp as? HTTPURLResponse)?.statusCode ?? -1
            if let s = DYLiveEnterStreams.parse(data) { return s }
            DYLiveModel.log("DDLIVE_H264 why=enter-miss http=\(http) bytes=\(data.count) attempt=\(attempt)")
            // 空包多半是这个 ttwid 被限了：换一个再试一次；有内容但不是在播的房间就不用再试
            if !data.isEmpty { return nil }
        }
        return nil
    }

    /// 匿名 ttwid：对直播首页发一次 HEAD 就会下发，进程内复用
    private static func anonymousTTWID(fresh: Bool) async -> String? {
        if fresh { ttwid = nil; ttwidTask = nil }
        if let ttwid { return ttwid }
        if let ttwidTask { return await ttwidTask.value }
        let task = Task<String?, Never> {
            var r = URLRequest(url: URL(string: "https://live.douyin.com/")!)
            r.httpMethod = "HEAD"
            r.setValue(DouyinWeb.userAgent, forHTTPHeaderField: "User-Agent")
            guard let (_, resp) = try? await session.data(for: r), let h = resp as? HTTPURLResponse, let url = h.url else { return nil }
            var fields: [String: String] = [:]
            for (k, v) in h.allHeaderFields { fields["\(k)"] = "\(v)" }
            return HTTPCookie.cookies(withResponseHeaderFields: fields, for: url).first { $0.name == "ttwid" }?.value
        }
        ttwidTask = task
        let value = await task.value
        ttwidTask = nil
        ttwid = value
        if value == nil { DYLiveModel.log("DDLIVE_H264 why=no-ttwid") }
        return value
    }
}

enum DDLogWriter {
    static let queue = DispatchQueue(label: "douduo.log", qos: .utility)
    nonisolated(unsafe) static let formatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()
    nonisolated(unsafe) private static var handle: FileHandle?
    /// 储存空间页「清理缓存」：删掉诊断日志 ddlog.txt，下次写日志时重建
    static func clear() async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async {
                try? handle?.close()
                handle = nil
                let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("ddlog.txt")
                continuation.resume(returning: DYStorageFiles.removeIfPresent(url))
            }
        }
    }

    static func append(_ line: String) {
        if handle == nil, let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let url = dir.appendingPathComponent("ddlog.txt")
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
            handle = try? FileHandle(forWritingTo: url)
            handle?.seekToEndOfFile()
        }
        handle?.write(Data(line.utf8))
    }
}

@MainActor
final class DYLiveModel: ObservableObject {
    @Published var rooms: [DYLiveRoom] = []
    @Published var currentID: String?
    @Published var error: String?
    @Published var playbackError: String?
    @Published var loading = false
    private(set) var fetchedAt = Date.distantPast
    @Published var ready = false
    /// 当前这一路解码出的画面尺寸。只在尺寸变化时更新，用来重新判断横屏分屏。
    @Published var playbackVideoSize: CGSize = .zero
    @Published var zone: DYLiveZone?
    /// 关注的主播里正在开播的（网页版直播首页顶上那排头像，复用同一个接口）
    @Published var followLive: [DYLiveRoom] = []
    /// 最近一次关注列表的分类。空数组本身不能当成未登录。
    @Published var followLiveKind: DYFollowLiveKind?
    private var followLiveFetchedAt = Date.distantPast
    private var loadedFollowSession = -1
    private var followedOnly = false
    @Published var clean = false
    @Published var entered = false
    /// 「发现更多」面板展开（在挑直播间）：不播任何直播，免得后台挂着一个还在出声
    var browsing = false
    /// 手动选的清晰度（nil = 自动，用抖音给的默认）；全局记住，换直播间也沿用
    @Published var quality: String? = UserDefaults.standard.string(forKey: "douyin_live_quality_v1")
    /// 这个直播间有的清晰度，高到低
    var qualityOptions: [String] {
        let have = Set((roomRef?.liveStreams ?? []).map(\.quality))
        return ["ORIGION", "FULL_HD1", "HD1", "SD1", "SD2"].filter(have.contains)
    }
    static func qualityName(_ q: String) -> String {
        ["ORIGION": "原画", "FULL_HD1": "蓝光", "HD1": "超清", "SD1": "高清", "SD2": "标清"][q] ?? q
    }
    func setQuality(_ q: String?) {
        quality = q
        UserDefaults.standard.set(q, forKey: "douyin_live_quality_v1")
        retry()
    }
    @Published var muted: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.environment["DOUDUO_TEST_MUTE"] == "1"
        #else
        false
        #endif
    }() {
        didSet {
            vlc.outputMuted = muted
            if !muted, sessionReleased {
                if activatePlaybackSession() {
                    vlc.reopenAudioOutput()
                    sessionReleased = false
                }
            } else {
                vlc.mediaPlayer.audio?.isMuted = muted
            }
        }
    }
    /// 当前这一路。切到预加载好的下一间时会换成那一路（见「预加载下一间」），所以不是常量。
    @Published private(set) var vlc = VLCPlayerController()
    /// 当前这一路自己的画面视图：界面只负责把它挂上去，换台时连视图一起换，已经在出画的画面不用重连
    private(set) var videoView = VLCPlayerUIView()
    private var requestGeneration = UUID()
    private var loadedRoom: String?
    private var roomRef: DYLiveRoom?
    private var sources: [DYLiveStream] = []
    private var retryTask: Task<Void, Never>?
    private var startedAt = ProcessInfo.processInfo.systemUptime
    private var streamGeneration = UUID()
    private let lifecycleID = UUID()
    private var visible = false
    /// 前后台过渡已经开始。重复回调不能再改策略，也不能再重连一次。
    private var suspended = false
    /// 后台声音关闭时，这次进后台已经停掉媒体。回前台必须重开，不能复用。
    private var stoppedForBackground = false
    /// 这次离开前台的墙钟时间。不用会在睡眠中停住的 systemUptime。
    private var suspendedAt: Date?
    /// 系统打断了音频。恢复时不能把打断前的缓冲接着播。
    private var audioInterrupted = false
    /// 音频会话被交还过。视频可能还在，但 VLC 的音频输出已经拆掉。
    private var sessionReleased = false
    private var interruptionObserver: NSObjectProtocol?
    /// 进入后台时输入模块已读字节。demux 计数会消化旧缓冲，不能当作新数据。
    private var inputReadAtBackground: Int64 = 0
    private var visit = DYLiveVisit()
    private var savedFeed: SavedLiveFeed?
    var isFollowedVisit: Bool { visit.followed }
    var isFollowedCatalog: Bool { followedOnly }
    /// 关注分类里的当前房间还没有播放地址时，界面用它重新解析这一间。
    @Published private(set) var catalogResolveNonce = 0

    private struct SavedLiveFeed {
        var rooms: [DYLiveRoom]
        var currentID: String?
        var zone: DYLiveZone?
        var error: String?
        var fetchedAt: Date
    }

    func activate() {
        visible = true
        if interruptionObserver == nil {
            interruptionObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main
            ) { [weak self] note in
                Task { @MainActor in
                    self?.handleAudioInterruption(note)
                }
            }
        }
        DDPlayback.shared.register(lifecycleID, stop: { [weak self] in self?.suspendForBackground() }, start: { [weak self] in
            self?.resumeFromBackground()
        }, retainsAudioSession: { [weak self] in
            self?.wantsBackgroundAudioSession ?? false
        })
        play(roomRef)
    }
    func deactivate() {
        visible = false
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
            self.interruptionObserver = nil
        }
        DDPlayback.shared.unregister(lifecycleID)
        stop()
    }

    /// 写日志不占主线程：时间戳在调用处取，落盘在后台串行队列（滑动起播那一帧不能做磁盘 IO）
    nonisolated static func log(_ s: String) {
        let now = Date()
        DDLogWriter.queue.async {
            let line = DDLogWriter.formatter.string(from: now) + " " + s + "\n"
            DDLogWriter.append(line)
        }
    }

    init() {
        bind(vlc)
        // 低电量模式 / 发热状态变了：马上按新方式重新安排下一间（两路同时播 ↔ 只截一帧）
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateWarmNext() }
            }
        }
    }

    /// 回调只认当前这一路：换台后旧的那一路还要 0.6 秒才停，它的就绪 / 出错不能算到新的这一间头上
    private func bind(_ c: VLCPlayerController) {
        c.onProgress = { [weak self, weak c] time in
            guard let self, let c, c === self.vlc else { return }
            if self.suspended {
                self.reapplyBackgroundMuteIfNeeded()
            } else if self.vlc.mediaPlayer.audio?.isMuted != DYLivePlaybackGate.foregroundOutputMuted(userMuted: self.muted) {
                self.vlc.mediaPlayer.audio?.isMuted = DYLivePlaybackGate.foregroundOutputMuted(userMuted: self.muted)
            }
            guard !self.ready, self.loadedRoom != nil, time > 0,
                  self.liveCanProgress,
                  self.vlc.mediaPlayer.hasVideoOut else { return }
            self.ready = true
            self.retryTask?.cancel()
            Self.log("DDLIVE_READY room=\(self.loadedRoom ?? "-") elapsed=\(String(format: "%.3f", ProcessInfo.processInfo.systemUptime - self.startedAt)) videoOut=true")
            // 这一间出画了再预加载下一间，不跟它抢起播带宽
            self.updateWarmNext()
        }
        c.onVideoSize = { [weak self, weak c] size in
            guard let self, let c, c === self.vlc, self.loadedRoom != nil, self.playbackVideoSize != size else { return }
            self.playbackVideoSize = size
        }
        c.onError = { [weak self, weak c] in
            guard let self, let c, c === self.vlc, self.loadedRoom != nil, self.liveCanProgress else { return }
            self.tryNextSource(reason: "decoder/network error", generation: self.streamGeneration)
        }
        c.onEnd = { [weak self, weak c] in
            guard let self, let c, c === self.vlc, self.loadedRoom != nil, self.liveCanProgress else { return }
            self.playbackError = "直播已结束或连接中断，可重试或上滑换台"
            self.ready = false
        }
    }

    private func unbind(_ c: VLCPlayerController) {
        c.onProgress = nil; c.onVideoSize = nil; c.onError = nil; c.onEnd = nil; c.onMediaAssigned = nil
    }

    func load(_ bridge: DouyinBridge, reset: Bool = false) async {
        guard visit.acceptsRecommendation else { return }
        #if DEBUG
        if ProcessInfo.processInfo.environment["DOUDUO_LIVEMOCK"] == "1" {
            guard reset || rooms.isEmpty else { return }
            let seeded = DYLiveRoom.debugFeed()
            rooms = seeded
            currentID = seeded.first?.id
            error = nil
            fetchedAt = .distantFuture
            visit.replaceFeed(ids: rooms.map(\.id), currentID: currentID, zoneID: zone?.id)
            return
        }
        #endif
        guard !loading, !followedOnly else { return }
        let generation = requestGeneration, requestedZone = zone
        let start = ProcessInfo.processInfo.systemUptime
        loading = true
        defer { if requestGeneration == generation { loading = false } }
        do {
            let r = try await bridge.fetchLive(reset: reset, zone: requestedZone)
            guard requestGeneration == generation, zone == requestedZone else { return }
            if reset { rooms = [] }
            var seen = Set(rooms.map(\.id))
            rooms.append(contentsOf: r.filter { seen.insert($0.id).inserted })
            if !rooms.contains(where: { $0.id == currentID }) { noteVisibleRoom(rooms.first?.id) }
            fetchedAt = Date()
            error = rooms.isEmpty ? (zone == nil ? "暂时没有直播" : "这个分类暂时没有直播") : nil
            visit.replaceFeed(ids: rooms.map(\.id), currentID: currentID, zoneID: zone?.id)
            Self.log("DDLIVE_FEED count=\(r.count) elapsed=\(String(format: "%.3f", ProcessInfo.processInfo.systemUptime - start))")
        } catch {
            guard requestGeneration == generation else { return }
            if rooms.isEmpty { self.error = error.localizedDescription }
        }
    }

    func play(_ room: DYLiveRoom?) {
        guard var room else { return }
        // 列表里同一间可能还是 H.265 的旧数据（重新拉列表、从推荐卡片进来）：用换好的 H.264 版本
        if !room.hasFLV, let upgraded = h264.upgraded(room.id, now: Date()) { room = upgraded }
        roomRef = room
        let restart = loadedRoom != room.id || DYLivePlaybackGate.shouldRestartSameRoom(
            state: playbackState(), ready: ready, hasMedia: vlc.mediaPlayer.media != nil)
        let applicationActive = UIApplication.shared.applicationState == .active
        if DYLivePlaybackGate.acceptsRoomChange(playbackRegisteredActive: DDPlayback.shared.appIsActive, applicationActive: applicationActive, visible: visible), restart {
            suspended = false
            suspendedAt = nil
            audioInterrupted = false
        }
        guard !browsing, DYLivePlaybackGate.acceptsRoomChange(playbackRegisteredActive: DDPlayback.shared.appIsActive, applicationActive: applicationActive, visible: visible), !suspended else {
            if loadedRoom != room.id {
                ready = false
                playbackError = nil
            }
            return
        }
        guard restart else { return }
        // 下一间已经预加载好：直接接过那一路（画面已经在出），跟刷视频一样一划就有
        if warm?.roomID == room.id, adoptWarm(room) { return }
        // 只有 H.265 线路：先问进房接口要 H.264 FLV（约 0.3 秒），比直接起 H.265 HLS（4–7 秒）快得多
        switch h264.next(room.id, wanted: needsH264(room), now: Date()) {
        case .play: break
        case .request:
            requestH264(room)
            holdForH264(room)
            return
        case .wait:
            holdForH264(room)
            return
        }
        holdingH264 = nil
        loadedRoom = room.id
        sources = orderedSources(room)
        startCurrentSource()
    }

    /// 选了清晰度就把它排最前，起不来才退回其他档。全局清晰度跨直播间保留。
    private func orderedSources(_ room: DYLiveRoom) -> [DYLiveStream] {
        let all = room.liveStreams
        guard let q = quality, all.contains(where: { $0.quality == q }) else { return all }
        return all.filter { $0.quality == q } + all.filter { $0.quality != q }
    }

    // MARK: 预加载下一间（同推荐流里的 DYFeedLiveWarm）

    /// 官方直播划过去几乎零延迟：下一间早就连上、解码好了。这里也一样——当前这间出画后，
    /// 用第二个播放器把下一间静音（音量 0）播在窗口最底层看不见的地方；划过去时把那一路连同画面视图一起接过来。
    /// 以前只有一个播放器，每划一次都要停掉重连（H.264 FLV 也要 0.4–1.8 秒）。
    private struct WarmSlot {
        let roomID: String
        let source: DYLiveStream
        let controller: VLCPlayerController
        let view: VLCPlayerUIView
        let startedAt: CFTimeInterval
        /// preview 模式：只播到第一帧截图就停，不留着给划过去接手
        let preview: Bool
    }
    private var warm: WarmSlot?
    private var warmKeeper: Task<Void, Never>?
    private var warmCap: Task<Void, Never>?
    /// 现在用哪种预加载（见 DYLivePreloadPolicy）：低电量 / 用流量 / 发热时只截一帧，其余两路同时播
    var preloadMode: DYLivePreloadMode {
        #if DEBUG
        if let m = ProcessInfo.processInfo.environment["DOUDUO_LIVE_PRELOAD"].flatMap(DYLivePreloadMode.init(rawValue:)) { return m }
        #endif
        return DYLivePreloadPolicy.mode(lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
                                        cellular: DYNetPath.shared.cellular,
                                        thermal: ProcessInfo.processInfo.thermalState.rawValue)
    }

    /// preview 模式截到的各间画面：划过去（以及划的过程中）先显示它，出画后由真画面盖过
    @Published private(set) var previewFrames: [String: UIImage] = [:]
    private var previewAt: [String: Date] = [:]

    func previewFrame(for id: String) -> UIImage? {
        guard let at = previewAt[id], Date().timeIntervalSince(at) < DYLivePreloadPolicy.previewShowSeconds else { return nil }
        return previewFrames[id]
    }

    private func previewFresh(_ id: String) -> Bool {
        previewAt[id].map { Date().timeIntervalSince($0) < DYLivePreloadPolicy.previewFreshSeconds } ?? false
    }

    /// 省流量用流量时、VLC 停播积压、线程吃紧时都不预加载（同推荐流）
    private var warmAllowed: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["DOUDUO_LIVE_NOWARM"] == "1" { return false }
        #endif
        return !DYStream.saving && VLCPlayerCensus.releaseBacklog < 2 && !DYThreadGuard.pressured
    }

    /// 下一间（往上滑看到的那间）。还在等进房接口换 H.264 的先不预加载，换好后 warmNeighbors 会再叫一次。
    private func warmTarget() -> (DYLiveRoom, DYLiveStream)? {
        guard visible, !suspended, !browsing, ready, warmAllowed,
              UIApplication.shared.applicationState == .active,
              let id = currentID, loadedRoom == id,
              let i = rooms.firstIndex(where: { $0.id == id }), rooms.indices.contains(i + 1) else { return nil }
        var next = rooms[i + 1]
        if !next.hasFLV, let up = h264.upgraded(next.id, now: Date()) { next = up }
        if needsH264(next) { return nil }
        guard let source = orderedSources(next).first else { return nil }
        return (next, source)
    }

    func updateWarmNext() {
        guard let (room, source) = warmTarget() else {
            // 当前这间还在起播时别丢掉已经预加载好的（可能马上就划过去）；其余情况才放掉
            if !ready || !visible || suspended || browsing { return }
            releaseWarm(reason: "no-target")
            return
        }
        let mode = preloadMode
        if let w = warm, w.roomID == room.id, w.preview == (mode == .preview) { return }
        if mode == .preview, previewFresh(room.id) {
            if warm != nil { releaseWarm(reason: "preview-fresh") }
            return
        }
        releaseWarm(reason: "switch")
        guard let window = Self.keyWindow else { return }
        let c = VLCPlayerController()
        c.outputMuted = false
        let v = VLCPlayerUIView(frame: window.bounds)
        v.controller = c
        v.fillWidth = room.portrait
        v.backgroundColor = .clear
        v.isUserInteractionEnabled = false
        v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        // 窗口最底层：被整个界面盖住看不见，但在视图树里、有尺寸，VLC 照常解码出画
        window.insertSubview(v, at: 0)
        c.boundSurface = v
        c.mediaPlayer.drawable = v
        c.play(url: source.url, headers: DYMedia.liveHeaders, cachingMs: source.cacheMS)
        c.mediaPlayer.audio?.volume = 0
        warm = WarmSlot(roomID: room.id, source: source, controller: c, view: v, startedAt: CACurrentMediaTime(),
                        preview: mode == .preview)
        Self.log("DDLIVEWARM2 start room=\(room.id.suffix(6)) q=\(source.quality) flv=\(source.isFLV) mode=\(mode.rawValue)")
        // 音量 0 而不是静音：静音会停掉音频输出，接过来时要重开、声音晚一截（同 DYFeedLiveWarm）。
        // 音频输出建好前设音量无效，前 3 秒每 30ms 盯一次
        warmKeeper?.cancel()
        warmKeeper = Task { @MainActor [weak c] in
            let t0 = CACurrentMediaTime()
            while !Task.isCancelled {
                guard let audio = c?.mediaPlayer.audio else { break }
                if audio.volume != 0 { audio.volume = 0 }
                if audio.isMuted { audio.isMuted = false }
                try? await Task.sleep(for: .milliseconds(CACurrentMediaTime() - t0 < 3 ? 30 : 200))
            }
        }
        warmCap?.cancel()
        let roomID = room.id
        if mode == .preview {
            warmCap = Task { @MainActor [weak self] in await self?.capturePreview(roomID: roomID, controller: c) }
        } else {
            warmCap = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(DYLivePreloadPolicy.fullMaxSeconds))
                guard !Task.isCancelled else { return }
                self?.releaseWarm(reason: "cap")
            }
        }
    }

    /// preview：等到第一帧，截一张就停（每间只播约 1 秒，不再持续下载、解码）。
    /// 停在这间久了画面会变旧，过一阵再叫一次 updateWarmNext，旧了就重截。
    private func capturePreview(roomID: String, controller c: VLCPlayerController) async {
        let t0 = CACurrentMediaTime()
        while !Task.isCancelled, warm?.controller === c, CACurrentMediaTime() - t0 < DYLivePreloadPolicy.previewProbeSeconds {
            if c.mediaPlayer.hasVideoOut, c.videoSize.width > 0, c.current > 0 { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard !Task.isCancelled, warm?.controller === c else { return }
        guard c.mediaPlayer.hasVideoOut, c.videoSize.width > 0 else {
            releaseWarm(reason: "preview-timeout")
            return
        }
        let image = await Self.snapshot(c)
        guard warm?.controller === c else { return }
        let ms = Int((CACurrentMediaTime() - t0) * 1000)
        if let image {
            previewFrames[roomID] = image
            previewAt[roomID] = Date()
            // 只留最近几间
            while previewAt.count > 8, let oldest = previewAt.min(by: { $0.value < $1.value })?.key {
                previewAt[oldest] = nil
                previewFrames[oldest] = nil
            }
        }
        Self.log("DDLIVEWARM2 preview room=\(roomID.suffix(6)) ok=\(image != nil ? 1 : 0) after=\(ms)ms")
        releaseWarm(reason: image == nil ? "preview-miss" : "preview-done")
        guard image != nil else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(DYLivePreloadPolicy.previewFreshSeconds + 1))
            self?.updateWarmNext()
        }
    }

    private static let snapshotQueue = DispatchQueue(label: "douduo.live.preview", qos: .userInitiated)

    /// 截当前画面。VLCKit 截不到图时会直接 @throw NSException（见 DYLiveAmbient），交给 DDTryObjC 接住当没截到。
    private static func snapshot(_ c: VLCPlayerController) async -> UIImage? {
        guard let mp = c.mediaPlayer else { return nil }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("dd-live-preview-\(UUID().uuidString).png").path
        return await withCheckedContinuation { (cont: CheckedContinuation<UIImage?, Never>) in
            snapshotQueue.async {
                var reason: NSString?
                let ok = DDTryObjC({ mp.saveVideoSnapshot(at: path, withWidth: 720, andHeight: 0) }, &reason)
                // 先整份读进内存再删文件（UIImage(contentsOfFile:) 是延迟读的）；解码也放在后台
                let image = ok ? (try? Data(contentsOf: URL(fileURLWithPath: path))).flatMap(UIImage.init(data:)).map { $0.preparingForDisplay() ?? $0 } : nil
                try? FileManager.default.removeItem(atPath: path)
                cont.resume(returning: image)
            }
        }
    }

    func releaseWarm(reason: String) {
        warmKeeper?.cancel(); warmKeeper = nil
        warmCap?.cancel(); warmCap = nil
        guard let w = warm else { return }
        warm = nil
        Self.log("DDLIVEWARM2 drop room=\(w.roomID.suffix(6)) reason=\(reason) after=\(Int((CACurrentMediaTime() - w.startedAt) * 1000))ms")
        DYFeedLiveWarm.dispose(DYFeedLiveWarm.Handle(roomID: w.roomID, controller: w.controller, view: w.view))
    }

    /// 划到预加载好的那间：接过那一路当当前播放器。那一路坏了（出错 / 已结束）返回 false，照常现连。
    private func adoptWarm(_ room: DYLiveRoom) -> Bool {
        guard let w = warm, w.roomID == room.id else { return false }
        warm = nil
        warmKeeper?.cancel(); warmKeeper = nil
        warmCap?.cancel(); warmCap = nil
        let state = w.controller.mediaPlayer.state
        let warmHasFrame = w.controller.mediaPlayer.hasVideoOut && w.controller.current > 0
        // preview 那一路本来马上就要停，还没出画就不接，照常现连（屏幕上先垫着截到的画面）
        guard state != .error, state != .ended, state != .stopped, !(w.preview && !warmHasFrame) else {
            Self.log("DDLIVEWARM2 drop room=\(w.roomID.suffix(6)) reason=broken state=\(state.rawValue)")
            DYFeedLiveWarm.dispose(DYFeedLiveWarm.Handle(roomID: w.roomID, controller: w.controller, view: w.view))
            return false
        }
        retryTask?.cancel()
        holdingH264 = nil
        // 旧的那一路：立刻无声，0.6 秒后再停、停完再留 10 秒才放（防主线程析构卡死，见 DYFeedLiveWarm）
        let old = vlc
        unbind(old)
        old.cancelInterruptionRebuild()
        DYFeedLiveWarm.stopLater(old)
        w.view.removeFromSuperview()
        vlc = w.controller
        videoView = w.view
        bind(vlc)
        loadedRoom = room.id
        sources = [w.source] + orderedSources(room).filter { $0.url != w.source.url }
        streamGeneration = UUID()
        startedAt = ProcessInfo.processInfo.systemUptime
        playbackError = nil
        playbackVideoSize = vlc.videoSize
        if activatePlaybackSession() { sessionReleased = false }
        let mute = DYLivePlaybackGate.foregroundOutputMuted(userMuted: muted)
        vlc.outputMuted = mute
        vlc.mediaPlayer.audio?.isMuted = mute
        vlc.mediaPlayer.audio?.volume = mute ? 0 : 100
        let hasFrame = vlc.mediaPlayer.hasVideoOut && vlc.current > 0
        ready = hasFrame
        if !hasFrame { armSourceTimeout(generation: streamGeneration, flv: w.source.isFLV) }
        Self.log("DDLIVEPLAY room=\(room.id) protocol=\(w.source.isFLV ? "FLV" : "HLS") q=\(w.source.quality) warm=1 warmed=\(Int((CACurrentMediaTime() - w.startedAt) * 1000))ms frame=\(hasFrame)")
        if hasFrame { Self.log("DDLIVE_READY room=\(room.id) elapsed=0.000 videoOut=true warm=1") }
        return true
    }

    private static var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow }
    }

    // MARK: H.265 → H.264（见 DYLiveH264Upgrade）

    private var h264 = DYLiveH264Upgrade<DYLiveRoom>()
    /// 正在等进房接口的那一间：期间不起任何线路
    private var holdingH264: String?

    private func needsH264(_ room: DYLiveRoom) -> Bool {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if env["DOUDUO_LIVEMOCK"] == "1" || env["DOUDUO_LIVE_HLS"] == "1" { return false }
        #endif
        return DYLiveH264Upgrade<DYLiveRoom>.wanted(hasFLV: room.hasFLV, hasHLS: !room.hls.isEmpty, webRid: room.webRid)
    }

    private func requestH264(_ room: DYLiveRoom) {
        let id = room.id, rid = room.webRid
        h264.begin(id)
        let start = ProcessInfo.processInfo.systemUptime
        Task { [weak self] in
            let streams = await DYLiveEnterClient.streams(webRid: rid)
            guard let self else { return }
            // 只认同一间、确实给了 H.264 FLV 的结果；其余照原线路播
            let merged = streams.flatMap { s -> DYLiveRoom? in
                guard s.id == id, !s.flv.isEmpty else { return nil }
                var r = room
                r.flv = s.flv
                r.hls = s.hls.isEmpty ? room.hls : s.hls
                r.def = s.def ?? room.def
                return r
            }
            self.h264.finish(id, room: merged, now: Date())
            Self.log("DDLIVE_H264 room=\(id) ok=\(merged != nil ? 1 : 0) elapsed=\(String(format: "%.3f", ProcessInfo.processInfo.systemUptime - start))")
            let wasHolding = self.holdingH264 == id
            if wasHolding { self.holdingH264 = nil }
            guard let merged else {
                // 换不到：照原来的 H.265 线路播
                if wasHolding, self.roomRef?.id == id { self.play(self.roomRef) }
                return
            }
            if let i = self.rooms.firstIndex(where: { $0.id == id }), !self.rooms[i].hasFLV { self.rooms[i] = merged }
            if self.roomRef?.id == id {
                // 还在等，或等超时先起了 HLS 但还没出画：换成 FLV。已经出画就不打断。
                if wasHolding || !self.ready {
                    self.loadedRoom = nil
                    self.play(merged)
                }
            } else {
                self.warmNeighbors()
            }
        }
    }

    /// 停掉上一间、先不起这一间，等进房接口；最多等 `waitLimit`，超时照原线路播。
    private func holdForH264(_ room: DYLiveRoom) {
        guard holdingH264 != room.id else { return }
        retryTask?.cancel()
        streamGeneration = UUID()
        loadedRoom = nil
        vlc.stop()
        ready = false
        playbackError = nil
        holdingH264 = room.id
        let id = room.id
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(DYLiveH264Upgrade<DYLiveRoom>.waitLimit))
            guard let self, self.holdingH264 == id, self.h264.giveUp(id) else { return }
            self.holdingH264 = nil
            Self.log("DDLIVE_H264 room=\(id) wait-timeout")
            if self.roomRef?.id == id { self.play(self.roomRef) }
        }
    }

    /// 滑到另一间时先撤掉上一间的就绪状态，避免旧画面被当成这一间已经播出。
    func noteVisibleRoom(_ id: String?) {
        guard id != currentID else { return }
        currentID = id
        if loadedRoom != id {
            ready = false
            playbackError = nil
        }
    }

    /// 人已经在前台时，清掉过期的后台锁，让超时和换源还能继续。
    private var liveCanProgress: Bool {
        let applicationActive = UIApplication.shared.applicationState == .active
        let allowed = DYLivePlaybackGate.acceptsRoomChange(
            playbackRegisteredActive: DDPlayback.shared.appIsActive,
            applicationActive: applicationActive,
            visible: visible)
        if allowed, applicationActive { suspended = false }
        return allowed && !suspended
    }

    private var backgroundSoundEnabled: Bool {
        UserDefaults.standard.bool(forKey: DYLiveBackgroundSound.storageKey)
    }

    /// 只有真正要播出直播声音时才占着播放会话。静音或被打断时不拿它保活。
    private var wantsBackgroundAudioSession: Bool {
        guard DDPlayback.shared.pauseReason == .background, !audioInterrupted else { return false }
        return DYLivePlaybackGate.retainsAudioSession(
            visible: visible,
            hasMedia: vlc.mediaPlayer.media != nil,
            userMuted: muted,
            backgroundSound: backgroundSoundEnabled,
            interrupted: audioInterrupted)
    }

    private func suspendForBackground() {
        releaseWarm(reason: "background")
        let reason = DDPlayback.shared.pauseReason
        if reason == .inactive || !visible { return }
        if reason == .cover {
            guard !suspended else { return }
            suspended = true
            suspendedAt = Date()
            retryTask?.cancel()
            sessionReleased = true
            if loadedRoom != nil, vlc.mediaPlayer.media != nil { vlc.pause() }
            return
        }
        let first = !suspended
        if first {
            suspended = true
            suspendedAt = Date()
            retryTask?.cancel()
        }
        // 只有「后台直播声音」关闭、并且已经进了真正的 background，才停媒体。
        if DYLivePlaybackGate.stopsMediaOnBackground(backgroundSound: backgroundSoundEnabled) {
            guard loadedRoom != nil, !stoppedForBackground else {
                if loadedRoom == nil, first {
                    suspended = false
                    suspendedAt = nil
                }
                return
            }
            stoppedForBackground = true
            sessionReleased = true
            streamGeneration = UUID()
            vlc.stop()
            return
        }
        guard first else { return }
        captureBackgroundInput()
        let outputMuted = audioInterrupted || DYLivePlaybackGate.backgroundOutputMuted(
            userMuted: muted, backgroundSound: backgroundSoundEnabled)
        vlc.outputMuted = outputMuted
        vlc.mediaPlayer.audio?.isMuted = outputMuted
        if wantsBackgroundAudioSession {
            if activatePlaybackSession() { sessionReleased = false }
        } else {
            sessionReleased = true
        }
    }

    private func resumeFromBackground() {
        if DDPlayback.shared.coverHold { return }
        if stoppedForBackground {
            let action = DYLivePlaybackGate.silenceResume(
                visible: visible, hasRoom: roomRef != nil, coverHold: false, pending: true)
            stoppedForBackground = false
            suspended = false
            suspendedAt = nil
            audioInterrupted = false
            guard action == .reconnect else { return }
            let room = roomRef
            loadedRoom = nil
            play(room)
            return
        }
        let away = suspendedAt.map { Date().timeIntervalSince($0) }
        let age = vlc.lastAdvanceAge
        let inputAdvanced = inputAdvancedSinceBackground()
        let decision = DYLivePlaybackGate.recovery(
            suspended: suspended,
            visible: visible,
            sameRoom: loadedRoom != nil && loadedRoom == roomRef?.id,
            hasMedia: vlc.mediaPlayer.media != nil,
            state: playbackState(),
            backgroundDuration: away,
            lastAdvanceAge: age,
            inputAdvanced: inputAdvanced,
            interrupted: audioInterrupted)
        let interrupted = audioInterrupted
        let awayText = String(format: "%.0f", away ?? -1)
        let ageText = age.map { String(format: "%.1f", $0) } ?? "-"
        Self.log("DDLIVE_RESUME action=\(decision.action == .continueExisting ? "reuse" : decision.action == .reconnect ? "reconnect" : "ignore") reason=\(decision.reason) away=\(awayText) age=\(ageText) input=\(inputAdvanced ? 1 : 0) gen=\(streamGeneration.uuidString.prefix(4))")
        guard decision.action != .ignore else { return }
        audioInterrupted = false
        suspendedAt = nil
        suspended = false
        switch decision.action {
        case .ignore:
            break
        case .continueExisting:
            let reopen = sessionReleased
            _ = activatePlaybackSession()
            applyForegroundAudio(reopenTrack: reopen)
            let age = vlc.lastAdvanceAge ?? .infinity
            let pictureReady = DYLivePlaybackGate.canShowExistingPicture(state: playbackState(), hasVideoOut: vlc.mediaPlayer.hasVideoOut)
            if pictureReady || age <= DYLivePlaybackGate.continuityWindow {
                ready = true
                playbackError = nil
                retryTask?.cancel()
            }
            armResumeWatch()
        case .reconnect:
            if DYLivePlaybackGate.shouldRebuildPlayer(
                backgroundSound: backgroundSoundEnabled,
                interrupted: interrupted,
                action: decision.action,
                coverHold: DDPlayback.shared.coverHold,
                visible: visible,
                hasRoom: roomRef != nil) {
                ready = false
                retryTask?.cancel()
                vlc.onInterruptionPlayerReady = { [weak self] in
                    guard let self, self.visible, self.roomRef != nil, !DDPlayback.shared.coverHold else { return }
                    let room = self.roomRef
                    self.loadedRoom = nil
                    self.play(room)
                }
                vlc.onInterruptionRebuildFailed = { [weak self] in
                    guard let self, self.visible, self.roomRef != nil else { return }
                    self.ready = false
                    self.playbackError = "直播连接失败，请重试或上滑换台"
                }
                vlc.rebuildPlayerAfterInterruption()
                return
            }
            let room = roomRef
            loadedRoom = nil
            play(room)
        }
    }

    /// 回到前台时只恢复进房静音。会话被释放过且用户没静音时，重开音轨，不换媒体。
    private func applyForegroundAudio(reopenTrack: Bool) {
        let output = DYLivePlaybackGate.foregroundAudio(userMuted: muted, sessionReleased: reopenTrack)
        vlc.outputMuted = output.muted
        if output.reopenTrack {
            vlc.reopenAudioOutput()
            sessionReleased = false
        } else if sessionReleased {
            vlc.mediaPlayer.audio?.isMuted = true
        } else {
            vlc.mediaPlayer.audio?.isMuted = output.muted
            if !output.muted { vlc.mediaPlayer.audio?.volume = 100 }
        }
    }

    private func handleAudioInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            guard visible, loadedRoom != nil else { return }
            audioInterrupted = true
            sessionReleased = true
            // 系统已经拿走音频。只静音的话，VLC 仍可能把播放会话抢回来。
            vlc.pause()
            vlc.outputMuted = true
            vlc.mediaPlayer.audio?.isMuted = true
            DDAudioSessionGuard.allowDeactivate {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        case .ended:
            let applicationActive = UIApplication.shared.applicationState == .active
            guard audioInterrupted, DDPlayback.shared.appIsActive || applicationActive else { return }
            resumeFromBackground()
        default:
            break
        }
    }

    private func captureBackgroundInput() {
        inputReadAtBackground = Int64(vlc.mediaPlayer.media?.statistics.readBytes ?? 0)
    }

    /// 只看输入模块的 readBytes。demux 字节增加只表示在消化已经读入的缓冲。
    private func inputAdvancedSinceBackground() -> Bool {
        guard let media = vlc.mediaPlayer.media else { return false }
        return Int64(media.statistics.readBytes) > inputReadAtBackground
    }

    /// 音轨对象可能晚于进后台才出现。进度回调上把后台静音再写一次。
    private func reapplyBackgroundMuteIfNeeded() {
        guard suspended, DDPlayback.shared.pauseReason == .background else { return }
        let shouldMute = audioInterrupted || DYLivePlaybackGate.backgroundOutputMuted(
            userMuted: muted, backgroundSound: backgroundSoundEnabled)
        guard vlc.mediaPlayer.audio?.isMuted != shouldMute else { return }
        vlc.mediaPlayer.audio?.isMuted = shouldMute
    }

    private func playbackState() -> DYLivePlaybackGate.PlayerState {
        guard vlc.mediaPlayer.media != nil else { return .empty }
        switch vlc.mediaPlayer.state {
        case .opening, .esAdded: return .opening
        case .buffering: return .buffering
        case .playing: return .playing
        case .paused: return .paused
        case .stopped: return .stopped
        case .ended, .error: return .failed
        @unknown default: return .failed
        }
    }

    private func startCurrentSource() {
        retryTask?.cancel()
        streamGeneration = UUID()
        let generation = streamGeneration
        ready = false; playbackError = nil; playbackVideoSize = .zero
        guard let source = sources.first else {
            playbackError = "没有可用直播线路，请重试或换一个直播间"
            vlc.stop()
            return
        }
        startedAt = ProcessInfo.processInfo.systemUptime
        let sessionOK = activatePlaybackSession()
        if sessionOK { sessionReleased = false }
        vlc.outputMuted = DYLivePlaybackGate.foregroundOutputMuted(userMuted: muted)
        let flv = source.isFLV
        vlc.onMediaAssigned = { [weak self] in
            self?.armSourceTimeout(generation: generation, flv: flv)
        }
        vlc.replace(url: source.url, headers: DYMedia.liveHeaders, cachingMs: source.cacheMS)
        Self.log("DDLIVEPLAY room=\(loadedRoom ?? "-") protocol=\(source.isFLV ? "FLV" : "HLS") q=\(source.quality) cache=\(source.cacheMS) drawable=\(vlc.mediaPlayer.drawable != nil) session=\(sessionOK ? 1 : 0)")
    }

    @discardableResult
    private func activatePlaybackSession() -> Bool {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: DYLaunchMute.sessionOptions)
            try AVAudioSession.sharedInstance().setActive(true)
            return true
        } catch {
            return false
        }
    }

    private func armSourceTimeout(generation: UUID, flv: Bool) {
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(flv ? 6 : 10)) } catch { return }
            guard let self else { return }
            guard DYLivePlaybackGate.acceptEvent(currentGeneration: self.streamGeneration, eventGeneration: generation, ownerRoomID: self.loadedRoom, eventRoomID: self.loadedRoom),
                  !self.ready, self.liveCanProgress else { return }
            self.tryNextSource(reason: "startup timeout", generation: generation)
        }
    }

    /// 沿用当前会话之后，时钟停住才整段重连。这只发现卡死，不证明还在直播前沿。
    private func armResumeWatch() {
        retryTask?.cancel()
        let generation = streamGeneration
        retryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(6)) } catch { return }
            guard let self else { return }
            guard DYLivePlaybackGate.acceptEvent(currentGeneration: self.streamGeneration, eventGeneration: generation, ownerRoomID: self.loadedRoom, eventRoomID: self.loadedRoom),
                  self.liveCanProgress else { return }
            let age = self.vlc.lastAdvanceAge ?? .infinity
            if age <= DYLivePlaybackGate.continuityWindow { return }
            self.loadedRoom = nil
            self.play(self.roomRef)
        }
    }

    private func tryNextSource(reason: String, generation: UUID) {
        guard DYLivePlaybackGate.acceptEvent(currentGeneration: streamGeneration, eventGeneration: generation, ownerRoomID: loadedRoom, eventRoomID: loadedRoom),
              liveCanProgress else { return }
        retryTask?.cancel()
        Self.log("DDLIVE_FALLBACK reason=\(reason) remaining=\(sources.count)")
        if !sources.isEmpty { sources.removeFirst() }
        guard !sources.isEmpty else {
            playbackError = "直播连接失败，请重试或上滑换台"; ready = false; vlc.stop(); return
        }
        startCurrentSource()
    }

    func retry() {
        if isFollowedCatalog, let room = rooms.first(where: { $0.id == currentID }), room.liveStreams.isEmpty {
            playbackError = nil
            catalogResolveNonce += 1
            return
        }
        guard let room = roomRef else { return }
        loadedRoom = nil; play(room)
    }
    func enterRoom() {
        entered = true; clean = false
        Self.log("DDLIVE_ENTER room=\(currentID ?? "-") reused=true")
    }
    func leaveRoom() {
        guard visit.followed, let saved = savedFeed else {
            entered = false; clean = false
            Self.log("DDLIVE_LEAVE room=\(currentID ?? "-") reused=true")
            return
        }
        visit.leave()
        savedFeed = nil
        requestGeneration = UUID()
        loading = false
        stop()
        rooms = saved.rooms
        currentID = visit.currentID
        if currentID == nil || !rooms.contains(where: { $0.id == currentID }) { currentID = rooms.first?.id }
        zone = saved.zone
        error = saved.error
        fetchedAt = saved.fetchedAt
        entered = false
        clean = false
        playbackError = nil
        visit.replaceFeed(ids: rooms.map(\.id), currentID: currentID, zoneID: zone?.id)
        Self.log("DDLIVE_LEAVE followed=1 restored=\(rooms.count)")
        let restored = rooms.first { $0.id == currentID }
        if followedOnly, restored?.liveStreams.isEmpty != false {
            playbackError = nil
        } else {
            play(restored)
        }
    }
    func stop() {
        suspended = false
        suspendedAt = nil
        stoppedForBackground = false
        audioInterrupted = false
        sessionReleased = false
        retryTask?.cancel(); streamGeneration = UUID()
        holdingH264 = nil
        releaseWarm(reason: "stop")
        vlc.cancelInterruptionRebuild()
        loadedRoom = nil; vlc.stop(); ready = false
    }
    func reset() {
        followedOnly = false
        requestGeneration = UUID(); loading = false
        stop(); rooms = []; currentID = nil; error = nil; playbackError = nil
        entered = false; clean = false
        visit.clear(); savedFeed = nil
    }
    func select(_ z: DYLiveZone?, _ bridge: DouyinBridge) {
        guard z != zone || rooms.isEmpty else { return }
        zone = z; reset()
        Task { await load(bridge, reset: true) }
    }
    func open(_ room: DYLiveRoom) {
        if !visit.followed {
            savedFeed = SavedLiveFeed(rooms: rooms, currentID: currentID, zone: zone, error: error, fetchedAt: fetchedAt)
            visit.replaceFeed(ids: rooms.map(\.id), currentID: currentID, zoneID: zone?.id)
        }
        visit.open(room.id)
        requestGeneration = UUID()
        loading = false
        stop()
        playbackError = nil
        error = nil
        rooms = [room]
        currentID = room.id
        entered = true
        clean = false
        fetchedAt = Date()
        play(room)
    }

    /// 关注分类里只补当前这一间的播放地址，不换掉整条列表。
    func adoptFollowPlayback(_ room: DYLiveRoom) {
        guard followedOnly else { return }
        guard let index = rooms.firstIndex(where: {
            $0.id == room.id || (!room.webRid.isEmpty && $0.webRid == room.webRid)
        }) else { return }
        let previous = rooms[index].id
        rooms[index] = room
        if currentID == previous { currentID = room.id }
        guard currentID == room.id else { return }
        loadedRoom = nil
        play(room)
    }

    /// 提前暖一下下一两间（和上一间）的直播线路：触发 DNS 解析、CDN 回源和边缘缓存。
    /// 只读前 1KB 就取消，不占带宽；VLC 自己的连接不能复用，收益在 DNS 与 CDN 首包。
    private var warmed = Set<URL>()
    func warmNeighbors() {
        guard let id = currentID, let i = rooms.firstIndex(where: { $0.id == id }) else { return }
        let ids = [i + 1, i + 2, i - 1].filter { rooms.indices.contains($0) }
        // 相邻几间提前换好 H.264 FLV：滑过去时不用再等进房接口
        let now = Date()
        for idx in [i] + ids where h264.next(rooms[idx].id, wanted: needsH264(rooms[idx]), now: now) == .request {
            requestH264(rooms[idx])
        }
        for idx in ids {
            guard let source = rooms[idx].liveStreams.first, warmed.insert(source.url).inserted else { continue }
            if warmed.count > 40 { warmed.removeAll() }
            var req = URLRequest(url: source.url, timeoutInterval: 6)
            for (k, v) in DYMedia.liveHeaders { req.setValue(v, forHTTPHeaderField: k) }
            req.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
            let start = ProcessInfo.processInfo.systemUptime
            let task = Self.warmSession.dataTask(with: req) { data, resp, _ in
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                Self.log("DDLIVE_WARM idx=\(idx) proto=\(source.isFLV ? "FLV" : "HLS") code=\(code) bytes=\(data?.count ?? 0) elapsed=\(String(format: "%.3f", ProcessInfo.processInfo.systemUptime - start))")
            }
            task.resume()
            // FLV 是无尽流：拿到首包就够，最多 3 秒后取消，别一直占着 CDN 连接。
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { task.cancel() }
        }
        updateWarmNext()
    }
    private static let warmSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 6
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    func invalidateFollowLive() {
        followLive = []
        followLiveKind = nil
        followLiveFetchedAt = .distantPast
        loadedFollowSession = -1
    }

    /// 关注列表按账号代际隔离。同一账号 2 分钟内不重复请求；换账号立刻丢掉上一份。
    /// `refresh` 只在用户点重试时绕过这两分钟，仍走原来的关注列表请求。
    func loadFollowLive(_ bridge: DouyinBridge, refresh: Bool = false) async {
        let session = bridge.followSession
        let sessionChanged = session != loadedFollowSession
        guard refresh || sessionChanged || Date().timeIntervalSince(followLiveFetchedAt) > 120 else { return }
        if sessionChanged {
            followLive = []
            followLiveKind = nil
        }
        followLiveFetchedAt = Date()
        loadedFollowSession = session
        let result = await bridge.followLiveResult(ignoreCache: refresh)
        guard session == bridge.followSession else { return }
        followLiveKind = result.kind
        switch result.kind {
        case .rooms:
            followLive = result.items
        case .nobodyLive, .filtered:
            followLive = []
        case .notLoggedIn, .requestFailed, .decodeFailed, .unexpectedShape:
            break
        }
    }

    /// 一级分类「关注」：把整条流换成关注主播的开播列表，仍可上下滑换台
    func openFollowed(_ bridge: DouyinBridge) {
        guard !followLive.isEmpty else { return }
        zone = nil; reset()
        rooms = followLive; currentID = followLive.first?.id
        followedOnly = true // 关注列表到末尾不能混入推荐直播。
        fetchedAt = Date()
        Self.log("DDLIVE_FOLLOWED count=\(followLive.count)")
    }

    /// 一级分类「精选」：不论之前是关注列表还是游戏专区，都回到推荐直播流
    func backToFeatured(_ bridge: DouyinBridge) {
        zone = nil; reset()
        Task { await load(bridge, reset: true) }
    }
}

// MARK: - live-playback-gate
enum DYLiveSceneSignal: Equatable {
    case active, inactive, background
}

enum DYLiveSceneCommand: Equatable {
    case none, pause, resume
}

enum DYLiveSurfaceMask: Equatable {
    case showVideo, coverPrevious
}

enum DYLiveResumeAction: Equatable {
    case ignore, continueExisting, reconnect
}

enum DYLiveMediaReplacement: Equatable {
    case assignNow, waitUntilStopped
}

/// 「后台直播声音」。默认关闭。和直播间里的静音开关不是同一个偏好。
enum DYLiveBackgroundSound {
    static let storageKey = "douyin_live_background_sound_v1"
}

/// 直播前后台和房间遮挡的纯判断。播放器实例仍只有一个。
/// 后台声音开或关共用 `resume`。设置只决定出声，不另起一套重连。
struct DYLivePlaybackGate {
    enum PlayerState: Equatable {
        case empty, opening, buffering, playing, paused, stopped, failed
    }

    static func sceneCommand(_ signal: DYLiveSceneSignal) -> DYLiveSceneCommand {
        switch signal {
        case .active: .resume
        case .background: .pause
        case .inactive: .none
        }
    }

    /// 已经在前台或后台时，重复回调不再停流、也不再重连。
    static func apply(appIsActive: Bool, command: DYLiveSceneCommand) -> Bool {
        switch command {
        case .none: false
        case .pause: appIsActive
        case .resume: !appIsActive
        }
    }

    static func mask(isCurrent: Bool, ready: Bool, failed: Bool) -> DYLiveSurfaceMask {
        isCurrent && ready && !failed ? .showVideo : .coverPrevious
    }

    /// 播放线程上的时钟比这个更旧，就说明进程已经停过，不能把离开前的缓冲接着播。
    /// 这个时间不是直播前沿距离。VLCKit 3.6 没有那项测量。readBytes 也不证明还在前沿。
    static let continuityWindow: TimeInterval = 3

    /// 后台只改出声。用户本来就静音，或者关掉了后台声音，输出都保持静音。
    static func backgroundOutputMuted(userMuted: Bool, backgroundSound: Bool) -> Bool {
        userMuted || !backgroundSound
    }

    /// 回到前台时恢复进房静音偏好，不把后台策略留下来。
    static func foregroundOutputMuted(userMuted: Bool) -> Bool { userMuted }

    /// 只有确实要播出声音时才保留播放会话。静音会话不拿来保活。
    static func retainsAudioSession(visible: Bool, hasMedia: Bool, userMuted: Bool, backgroundSound: Bool, interrupted: Bool) -> Bool {
        visible && hasMedia && backgroundSound && !userMuted && !interrupted
    }

    /// 开/关后台声音都走这里。播放线程的时钟还新鲜才沿用；否则换新的 VLCMedia。
    /// `inputAdvanced` 只留给诊断。计数停在 0 不能否定一条还在出声的流，增加了也不能证明就在直播前沿。
    static func resume(suspended: Bool, visible: Bool, sameRoom: Bool, hasMedia: Bool, state: PlayerState, backgroundDuration: TimeInterval? = nil, lastAdvanceAge: TimeInterval? = nil, inputAdvanced: Bool = false, interrupted: Bool = false) -> DYLiveResumeAction {
        recovery(suspended: suspended, visible: visible, sameRoom: sameRoom, hasMedia: hasMedia, state: state, backgroundDuration: backgroundDuration, lastAdvanceAge: lastAdvanceAge, inputAdvanced: inputAdvanced, interrupted: interrupted).action
    }

    /// 前台一次已确认的打断重连要换掉已经无法再 opening 的那只 VLC。后台声音开或关都换。
    /// 真正进入后台时，关闭后台声音仍由 `stopsMediaOnBackground` 停媒体，不经过这里。
    /// 没有打断标志的回前台、健康复用、遮罩和已经离房都不换。
    static func shouldRebuildPlayer(backgroundSound: Bool, interrupted: Bool, action: DYLiveResumeAction, coverHold: Bool, visible: Bool, hasRoom: Bool) -> Bool {
        _ = backgroundSound
        return interrupted && action == .reconnect && !coverHold && visible && hasRoom
    }

    static func recovery(suspended: Bool, visible: Bool, sameRoom: Bool, hasMedia: Bool, state: PlayerState, backgroundDuration: TimeInterval? = nil, lastAdvanceAge: TimeInterval? = nil, inputAdvanced: Bool = false, interrupted: Bool = false) -> (action: DYLiveResumeAction, reason: String) {
        guard visible else { return (.ignore, "hidden") }
        guard suspended || interrupted else { return (.ignore, "already-foreground") }
        if interrupted { return (.reconnect, "interrupted") }
        if !sameRoom { return (.reconnect, "different-room") }
        if !hasMedia { return (.reconnect, "no-media") }
        let alive = state == .playing || state == .buffering
        if !alive { return (.reconnect, "not-playing") }
        guard let age = lastAdvanceAge, age <= continuityWindow else { return (.reconnect, "stale-callback") }
        _ = backgroundDuration
        _ = inputAdvanced
        return (.continueExisting, "callbacks-fresh")
    }

    /// 后台声音关闭时，真正的 background 要停掉当前媒体。打开时继续原来的出声路径。
    static func stopsMediaOnBackground(backgroundSound: Bool) -> Bool { !backgroundSound }

    enum DYLiveSilenceResume: Equatable {
        case ignore, reconnect
    }

    /// OFF 回前台只重连一次。离开房间、覆盖层还在、或这次并没有因静音而停止，都不再打开。
    static func silenceResume(visible: Bool, hasRoom: Bool, coverHold: Bool, pending: Bool) -> DYLiveSilenceResume {
        guard pending, visible, hasRoom, !coverHold else { return .ignore }
        return .reconnect
    }

    /// 正在拆掉的流不能马上装新媒体。状态读数已经是 stopped 也不能证明异步 stop 已经返回。
    static func mediaReplacement(state: PlayerState, stopInFlight: Bool) -> DYLiveMediaReplacement {
        if stopInFlight { return .waitUntilStopped }
        switch state {
        case .empty, .stopped, .failed: return .assignNow
        case .opening, .buffering, .playing, .paused: return .waitUntilStopped
        }
    }

    enum LateStopKind: Equatable {
        case stopped, error, ended
    }

    /// 只重开仍属于当前这次换流的 stopped/error。换房、清晰度、手动重连和退房都会换掉 token。
    static func acceptsLateReplay(replayToken: Int?, currentToken: Int, kind: LateStopKind) -> Bool {
        guard let replayToken, replayToken == currentToken else { return false }
        switch kind {
        case .stopped, .error: return true
        case .ended: return false
        }
    }

    /// 渲染层重新挂上时，不能再发一次 play。已经排队的启动，或还没完成的 stop，由它们自己的所有权启动。
    static func surfaceMayStart(stopInFlight: Bool, ownedStartPending: Bool, waitingForSurface: Bool, playingIntent: Bool, state: PlayerState) -> Bool {
        if stopInFlight || ownedStartPending { return false }
        if waitingForSurface { return true }
        return playingIntent && (state == .stopped || state == .paused || state == .failed)
    }

    /// 同一房间还在打开或播放时，不要再 stop 一次。已经停住或失败则重新打开。
    static func shouldRestartSameRoom(state: PlayerState, ready: Bool, hasMedia: Bool) -> Bool {
        guard hasMedia else { return true }
        _ = ready
        switch state {
        case .opening, .buffering, .playing: return false
        case .empty, .paused, .stopped, .failed: return true
        }
    }

    /// 沿用的画面已经在输出时，加载指示可以拿掉。没有画面时不要假装已经播出来。
    static func canShowExistingPicture(state: PlayerState, hasVideoOut: Bool) -> Bool {
        hasVideoOut && (state == .playing || state == .buffering)
    }

    /// 后台或打断关掉音频会话之后，只把静音打开不够，音轨要重新接上。用户自己静音时不动音轨。
    static func foregroundAudio(userMuted: Bool, sessionReleased: Bool) -> (muted: Bool, reopenTrack: Bool) {
        (userMuted, sessionReleased && !userMuted)
    }

    /// 停止回调迟到时，只允许到点后强制装上已经排队的那一条新媒体。
    static let stopCompletionLimit: TimeInterval = 2

    static func shouldForceAssign(stopInFlight: Bool, hasPending: Bool, waited: TimeInterval) -> Bool {
        stopInFlight && hasPending && waited >= stopCompletionLimit
    }

    /// 用户已经回到前台时，登记表上的「仍在后台」不能挡住换房和重试。
    static func acceptsRoomChange(playbackRegisteredActive: Bool, applicationActive: Bool, visible: Bool) -> Bool {
        visible && (playbackRegisteredActive || applicationActive)
    }

    static func acceptEvent(currentGeneration: UUID, eventGeneration: UUID, ownerRoomID: String?, eventRoomID: String?) -> Bool {
        currentGeneration == eventGeneration && ownerRoomID != nil && ownerRoomID == eventRoomID
    }
}
// MARK: - live-playback-gate-end

private enum DYLiveCategoryKind {
    case featured, gameZones
    case partition(DYLiveZone)
}
private struct DYLiveCategory: Identifiable {
    let id: String, name: String
    let kind: DYLiveCategoryKind
}
private let ddLiveCategories: [DYLiveCategory] = [
    .init(id: "featured", name: "精选", kind: .featured),
    .init(id: "game", name: "游戏", kind: .gameZones),
    .init(id: "chat", name: "聊天", kind: .partition(.init(id: "101", type: "4", name: "聊天"))),
    .init(id: "music", name: "音乐", kind: .partition(.init(id: "102", type: "4", name: "音乐"))),
    .init(id: "anime", name: "二次元", kind: .partition(.init(id: "104", type: "4", name: "二次元"))),
    .init(id: "dance", name: "舞蹈", kind: .partition(.init(id: "105", type: "4", name: "舞蹈"))),
    .init(id: "culture", name: "文化", kind: .partition(.init(id: "106", type: "4", name: "文化"))),
    .init(id: "life", name: "生活", kind: .partition(.init(id: "107", type: "4", name: "生活"))),
    .init(id: "exercise", name: "运动", kind: .partition(.init(id: "108", type: "4", name: "运动"))),
]

@available(iOS 27.1, *)
private func dyLiveHingeStatus(_ hinge: DeviceHinge?) -> DYLiveHingeStatus {
    guard let hinge else { return .unsupported }
    if hinge.status == .closed { return .closed }
    if hinge.status == .partiallyOpen { return .partiallyOpen }
    if hinge.status == .fullyOpen { return .fullyOpen }
    return .unsupported
}

private extension View {
    @ViewBuilder
    func onLiveHingeChange(_ apply: @escaping (DYLiveHingeStatus) -> Void) -> some View {
        if #available(iOS 27.1, *) {
            onHingeChange { _, context in apply(dyLiveHingeStatus(context.hinge)) }
        } else {
            self
        }
    }

    func placed(in pane: CGRect) -> some View {
        frame(width: pane.width, height: pane.height)
            .position(x: pane.midX, y: pane.midY)
    }
}

private func livePane(_ requested: CGRect, fallback: CGSize) -> CGRect {
    let rect = requested.standardized
    guard rect.width > 1, rect.height > 1 else { return CGRect(origin: .zero, size: fallback) }
    return rect
}

/// 预览和直播间共用同一个 drawable / VLC，不用网页开第二套播放器。
/// 直播画面的挂载点：挂的是当前这一路自己的画面视图（不是每次新建）。
/// 换到预加载好的下一间时，那一路的视图已经在出画，直接搬进来，不用重新挂 drawable、不用重连。
/// 其余行为同 VLCPlayerSurface：drawable 丢了才补挂，页面拆掉时摘掉 drawable。
struct DYLiveVideoHost: UIViewRepresentable {
    let controller: VLCPlayerController
    let view: VLCPlayerUIView
    var fillWidth: Bool = true
    var letterbox: UIColor? = nil

    func makeUIView(context: Context) -> UIView {
        let box = UIView()
        box.clipsToBounds = true
        box.backgroundColor = .clear
        box.isUserInteractionEnabled = false
        mount(in: box)
        return box
    }

    func updateUIView(_ box: UIView, context: Context) { mount(in: box) }

    private func mount(in box: UIView) {
        if view.superview !== box {
            for old in box.subviews { old.removeFromSuperview() }
            view.removeFromSuperview()
            view.frame = box.bounds
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            box.addSubview(view)
        }
        view.controller = controller
        view.fillWidth = fillWidth
        view.backgroundColor = letterbox ?? .black
        view.isUserInteractionEnabled = false
        controller.boundSurface = view
        if !controller.blocksSurfaceAttachment, controller.mediaPlayer.drawable == nil {
            controller.mediaPlayer.drawable = view
            controller.drawableAttached()   // drawable 就绪后才真正 play，避免「有声无画」
        }
        view.applyFill()
    }

    static func dismantleUIView(_ box: UIView, coordinator: ()) {
        for case let v as VLCPlayerUIView in box.subviews {
            if let c = v.controller, c.mediaPlayer.drawable as? UIView === v { c.mediaPlayer.drawable = nil }
            if v.controller?.boundSurface === v { v.controller?.boundSurface = nil }
            v.removeFromSuperview()
        }
    }
}


/// 简洁 / 极简模块菜单发给直播页的一次性动作。token 变化才会再次触发。
struct DYLiveModuleRequest: Equatable {
    enum Action: Equatable {
        case followedLive
        case discover
    }
    var token: Int
    var action: Action
}

/// 布局 A 时，把下窗格从直播视图坐标换到 `douduo.feed`，供父级摆模块圆钮。
struct DYLiveModuleAnchor: Equatable {
    var active = false
    var pane = CGRect.zero
    var compact = false
    var safeBottom: CGFloat = 0
    var safeTrailing: CGFloat = 0
}

struct DYLiveModuleAnchorKey: PreferenceKey {
    static var defaultValue = DYLiveModuleAnchor()
    static func reduce(value: inout DYLiveModuleAnchor, nextValue: () -> DYLiveModuleAnchor) {
        let next = nextValue()
        if next.active || !value.active { value = next }
    }
}

struct DYLiveFeed: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.horizontalSizeClass) private var hSize
    let bridge: DouyinBridge
    @ObservedObject var model: DYLiveModel
    let onWeb: (URL) -> Void
    var active = true
    /// 顶栏在 `douduo.feed` 坐标里的框。位置仍由顶栏自己决定，这里只用来把按钮放到它下面。
    var topChrome: CGRect = .zero
    var screenInsets: EdgeInsets = .init()
    var moduleRequest: DYLiveModuleRequest? = nil
    /// 默认模式保留左上角「发现更多 / 正在直播」。简洁和极简只从模块菜单进入。
    var classicPreviewChrome: Bool = true
    var onChannelDrag: ((CGFloat, CGFloat) -> Void)? = nil
    var onChannelDragEnd: ((CGFloat, CGFloat, CGFloat, Bool) -> Void)? = nil
    @StateObject private var chat = DYLiveChat()
    @State private var draft = ""
    @State private var sending = false
    /// 表情面板（跟官网直播间输入框的「小表情」一样：点一下把 [名称] 插进输入框）
    @State private var emojiOpen = false
    @State private var sendError: String?
    @State private var showCategories = false
    @State private var showFollowLive = false
    /// 直播间里点了主播：打开原生主播主页（工单 B32）
    @State private var liveAuthor: DYAweme.Author?
    /// 「发现更多」只放分类。关注开播走旁边的「关注直播」。
    @State private var showDiscover = false
    /// 关注主播头像条：默认收起，只显示「N 位正在直播」胶囊；点胶囊展开，选了主播或离开直播页就收起。
    @State private var followStripExpanded = false
    @State private var appliedModuleToken = 0
    @State private var selectedCategory = "featured"
    @State private var categoryHint: String?
    @State private var followPick = DYFollowSelection()
    @State private var scrollID: String?
    @State private var userScrolling = false
    @State private var gestureStartID: String?
    @State private var scrollEndTask: Task<Void, Never>?
    @FocusState private var inputFocused: Bool
    /// 键盘盖住当前视口底部的高度。分页本身忽略键盘安全区，只用这个值把评论栏抬上去。
    @State private var keyboardOverlap: CGFloat = 0
    @State private var viewportMinY: CGFloat = 0
    @State private var viewportMaxY: CGFloat = 0
    @AppStorage("douyin_danmaku_v1") private var danmakuOn = true
    /// 系统只通过 onHingeChange 给出开合。没收到回调前保持不支持，继续整屏。
    @State private var hingeStatus: DYLiveHingeStatus = .unsupported
    @State private var layoutMemory = DYLiveAdaptiveMemory.empty
    /// 半折叠时仍可手动回到原来的整屏。只在同一种分屏仍然成立时保留。
    @State private var forceImmersive = false
    /// 内屏完全展开时，用户在「更多」里手动分屏（不需要半折叠）。
    @State private var manualSplit = false
    @State private var immersiveAnchor: DYLiveAdaptiveLayout = .existing
    private var foreground: Color { theme.media.onMedia.color(for: scheme) }
    private var currentRoom: DYLiveRoom? { model.rooms.first { $0.id == model.currentID } }
    private var chatRoom: String? {
        guard model.entered, danmakuOn, let rid = currentRoom?.webRid, !rid.isEmpty else { return nil }
        return rid
    }
    /// 评论网页要加载的房间。进房立刻加载；预览阶段视频出画后再预热当前这一间，进房时评论区已经连上。
    private var chatTarget: String? {
        guard active, danmakuOn, !model.browsing, let rid = currentRoom?.webRid, !rid.isEmpty else { return nil }
        if model.entered { return rid }
        return model.ready ? rid : nil
    }
    /// 键盘弹出期间锁住换台。收起后再接受竖滑。
    private var keyboardLocksPaging: Bool { inputFocused || keyboardOverlap > 1 }

    var body: some View {
        GeometryReader { geo in
            let viewport = geo.frame(in: .global)
            let layout = resolvedLayout(in: geo)
            let shown = layout.shown
            let placement = layoutTogglePlacement(stable: layout.stable.decision, in: geo)
            // 整屏仍按竖屏铺满。只有桌面模式把横屏画面放到状态栏下面，并贴住上窗格底边。
            let fillWidth = shown.layout == .existing && currentRoom?.portrait == true && geo.size.height > geo.size.width * 1.2
            let videoFrame = shown.layout == .layoutA
                ? DYLiveLayoutAVideo.frame(
                    in: shown.video,
                    aspect: DYLiveLayoutAVideo.aspect(of: model.playbackVideoSize),
                    safeTop: inset(geo.safeAreaInsets.top, screenInsets.top))
                : shown.video
            ZStack {
                (shown.layout == .existing ? Color.ddBackground : Color.black)
                DYLiveVideoHost(controller: model.vlc, view: model.videoView, fillWidth: fillWidth, letterbox: shown.layout == .existing ? nil : .black)
                    .frame(width: videoFrame.width, height: videoFrame.height)
                    .position(x: videoFrame.midX, y: videoFrame.midY)
                    .allowsHitTesting(false)
                if model.rooms.isEmpty { emptyState }
                else {
                    pages(video: shown.video, interaction: shown.interaction,
                          ambientAxis: DYLiveAmbientTreatment.axis(for: shown.layout),
                          paneWidth: geo.size.width,
                          splitRole: menuSplitRole(placement.role),
                          splitAction: {
                              if canManualSplit { withAnimation(.easeInOut(duration: 0.2)) { manualSplit.toggle() } }
                              else { performSplitToggle(role: placement.role, eligible: layout.stable.decision.layout) }
                          })
                }
                if !model.entered, classicPreviewChrome || showDiscover || followStripExpanded {
                    let chrome = previewChrome(in: geo, pane: shown.interaction)
                    VStack(alignment: .leading, spacing: 0) {
                        if classicPreviewChrome {
                            discoverBar
                                .padding(.trailing, chrome.trailing)
                        } else if followStripExpanded {
                            // 关闭键只占发现按钮那一行的高度，头像条才和经典模式展开后对齐。
                            railFollowDismiss
                                .padding(.trailing, chrome.trailing)
                        }
                        if followStripExpanded, (!classicPreviewChrome || !model.followLive.isEmpty) {
                            Group {
                                if model.followLive.isEmpty {
                                    railFollowNote
                                } else {
                                    followStrip(scrollTail: chrome.stripTail)
                                }
                            }
                            .padding(.top, 10)
                            .padding(.trailing, chrome.stripTrailing)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                        if showDiscover {
                            discoverPanel
                                .padding(.trailing, chrome.trailing)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                    .padding(.leading, chrome.leading)
                    .padding(.top, chrome.top)
                    .frame(width: shown.interaction.width, height: shown.interaction.height, alignment: .topLeading)
                    .position(x: shown.interaction.midX, y: shown.interaction.midY)
                    .animation(.easeInOut(duration: 0.2), value: showDiscover)
                    .animation(.easeInOut(duration: 0.2), value: followStripExpanded)
                }
                if placement.role != .hidden {
                    layoutToggle(placement, eligible: layout.stable.decision.layout)
                }
                #if DEBUG
                VStack {
                    Text(model.currentID ?? "-").accessibilityIdentifier("live.currentID")
                    Text(String(format: "%.1f", model.vlc.current)).accessibilityIdentifier("live.time")
                    Text(model.ready ? "1" : "0").accessibilityIdentifier("live.status")
                    Text("\(model.zone?.id ?? "featured")|\(model.rooms.count)|\(model.loading ? "loading" : "loaded")")
                        .accessibilityIdentifier("live.source")
                }.font(.caption2).opacity(0.01).allowsHitTesting(false)
                #endif
            }
            .preference(key: DYLiveModuleAnchorKey.self, value: liveModuleAnchor(in: geo, shown: shown))
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .onAppear { syncViewport(minY: viewport.minY, maxY: viewport.maxY) }
            .onChange(of: viewport) { _, frame in syncViewport(minY: frame.minY, maxY: frame.maxY) }
            .onChange(of: layout.stable) { _, memory in layoutMemory = memory }
            .onChange(of: layout.stable.decision.layout) { _, kind in
                if !DYLiveLayoutToggle.manualApplies(active: forceImmersive, anchored: immersiveAnchor, eligible: kind) {
                    forceImmersive = false
                }
            }
        }
        .onLiveHingeChange { status in
            hingeStatus = status
            if status == .closed || status == .partiallyOpen { manualSplit = false }
        }
        // 分页与 drawable 共用整屏视口。键盘安全区不能把这一屏缩短，否则上一间封面会从顶上露出来。
        .ignoresSafeArea(.container, edges: .bottom)
        .ignoresSafeArea(.keyboard)
        .background(DYLiveChatHost(chat: chat).frame(width: 1, height: 1).allowsHitTesting(false))
        .onAppear {
            guard active else { return }
            model.activate()
            if model.isFollowedCatalog, currentRoom?.liveStreams.isEmpty == true { model.playbackError = nil }
        }
        .onChange(of: active) { _, value in
            if value {
                followStripExpanded = false
                model.activate()
                presentCurrentRoom()
            } else {
                dismissPreviewOverlays()
                model.deactivate()
            }
        }
        .task {
            if model.rooms.isEmpty || Date().timeIntervalSince(model.fetchedAt) > 60 {
                await model.load(bridge, reset: true)
            }
            scrollID = model.currentID
            presentCurrentRoom()
            model.warmNeighbors()
            // 并发拉取关注主播，不占用首播带宽也不阻塞起播
            Task { await model.loadFollowLive(bridge) }
            // 弹幕里的 [表情] 要换成官方表情图（跟评论区同一套，已加载过不会重复拉）
            Task { await DYEmojiStore.shared.load(bridge: bridge) }
        }
        .onChange(of: model.currentID) { _, id in
            if let id, scrollID != id { scrollID = id }
            draft = ""; sendError = nil; inputFocused = false
            presentCurrentRoom()
            model.warmNeighbors()
            if !model.isFollowedVisit, !model.isFollowedCatalog, let id, let i = model.rooms.firstIndex(where: { $0.id == id }), i >= model.rooms.count - 3 {
                Task { await model.load(bridge) }
            }
        }
        .task(id: chatTarget) {
            guard let id = chatTarget else {
                // 离开直播页或关闭弹幕才断开；退出房间回到预览时保留，下次进同一间不用重连。
                if !active || !danmakuOn { chat.close() }
                return
            }
            if chat.loadedRoom == id { return }
            // 预览预热：停留 1.5 秒才加载，快速上下翻台不会每间都开一次评论网页。
            if !model.entered {
                do { try await Task.sleep(for: .milliseconds(1500)) } catch { return }
                guard !Task.isCancelled, id == chatTarget else { return }
            }
            chat.open(id)
        }
        .onChange(of: model.entered) { _, entered in
            if entered { dismissPreviewOverlays() }
            else {
                inputFocused = false; draft = ""; sendError = nil
                if model.isFollowedCatalog, currentRoom?.liveStreams.isEmpty == true { presentCurrentRoom() }
            }
        }
        .onChange(of: model.catalogResolveNonce) { _, _ in presentCurrentRoom() }
        .onChange(of: model.isFollowedVisit) { _, followed in
            if !followed, model.rooms.isEmpty { Task { await model.load(bridge, reset: true) } }
        }
        .onChange(of: showFollowLive) { _, shown in
            if shown { cancelFollowPick() }
        }
        .onChange(of: moduleRequest) { _, request in
            guard let request, request.token != appliedModuleToken else { return }
            appliedModuleToken = request.token
            DYLiveModel.log("DDLIVEMODULE apply \(request.action) token=\(request.token)")
            switch request.action {
            case .followedLive:
                withAnimation(.easeInOut(duration: 0.2)) {
                    if followStripExpanded {
                        followStripExpanded = false
                    } else {
                        showDiscover = false
                        followStripExpanded = true
                    }
                }
            case .discover:
                withAnimation(.easeInOut(duration: 0.2)) {
                    followStripExpanded = false
                    showDiscover = true
                }
            }
        }
        .onChange(of: classicPreviewChrome) { _, _ in
            dismissPreviewOverlays()
        }
        .onChange(of: bridge.followSession) { _, _ in
            cancelFollowPick()
            model.invalidateFollowLive()
            Task { await model.loadFollowLive(bridge) }
        }
        .onDisappear { dismissPreviewOverlays(); scrollEndTask?.cancel(); cancelFollowPick(); model.deactivate(); chat.close() }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { applyKeyboard($0) }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardOverlap = 0
            userScrolling = false
            gestureStartID = nil
            pinCurrentPage()
        }
        .sheet(isPresented: $showCategories) {
            DYLiveCategories(selection: model.zone) { z in
                showCategories = false
                cancelFollowPick()
                if let z {
                    model.select(z, bridge)
                    selectedCategory = "game"
                    categoryHint = "已切到「\(z.name)」专区"
                } else {
                    model.backToFeatured(bridge)
                    selectedCategory = "featured"; categoryHint = nil
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $liveAuthor, onDismiss: { DDPlayback.shared.releaseCover() }) { author in
            NavigationStack {
                DYAuthorScreen(bridge: bridge, author: author, onWeb: { url in
                    liveAuthor = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { onWeb(url) }
                })
            }
            // 主页里可能点开作品播放：先把直播停住，关掉主页再接上
            .onAppear { DDPlayback.shared.pauseAll(reason: .cover) }
        }
        .sheet(isPresented: $showFollowLive) {
            DYFollowLiveSheet(bridge: bridge) { room in
                showFollowLive = false
                model.open(room)
            } onLogin: {
                showFollowLive = false
                onWeb(DouyinWeb.home)
            }
            .presentationDragIndicator(.visible)
        }
    }

    /// 按钮顶边取导航下沿加 8pt，若顶部安全区更靠下则改到安全区下沿。左右各自让开安全区。
    private func resolvedLayout(in geo: GeometryProxy) -> (shown: DYLiveAdaptiveDecision, stable: DYLiveAdaptiveMemory) {
        let bounds = CGRect(origin: .zero, size: geo.size)
        let allowsFold = DYDuoMetrics.canUseFoldLayout
        let divisions = allowsFold ? liveDivisions(in: geo) : []
        let status: DYLiveHingeStatus = allowsFold ? hingeStatus : .unsupported
        let proposed = DYLiveAdaptiveLayoutEngine.decide(
            bounds: bounds,
            status: status,
            divisions: divisions,
            videoSize: DYLiveAdaptiveLayoutEngine.presentationSize(ready: model.ready, videoSize: model.playbackVideoSize))
        let stable = DYLiveAdaptiveLayoutEngine.stabilize(
            previous: layoutMemory,
            proposed: proposed,
            status: status,
            bounds: bounds,
            divisions: divisions)
        let manual = DYLiveLayoutToggle.manualApplies(
            active: forceImmersive,
            anchored: immersiveAnchor,
            eligible: stable.decision.layout)
        var shown = manual
            ? DYLiveAdaptiveDecision(layout: .existing, video: bounds, interaction: bounds)
            : stable.decision
        if canManualSplit, manualSplit {
            shown = DYLiveAdaptiveLayoutEngine.manualSplit(
                bounds: bounds,
                videoSize: DYLiveAdaptiveLayoutEngine.presentationSize(ready: model.ready, videoSize: model.playbackVideoSize))
        }
        return (shown, stable)
    }

    /// `shown.interaction` 在直播 GeometryReader 里。换成 `douduo.feed` 后父级才能和自己的坐标相减。
    private func liveModuleAnchor(in geo: GeometryProxy, shown: DYLiveAdaptiveDecision) -> DYLiveModuleAnchor {
        let origin = geo.frame(in: .named("douduo.feed")).origin
        return DYLiveModuleAnchor(
            active: shown.layout == .layoutA,
            pane: shown.interaction.offsetBy(dx: origin.x, dy: origin.y),
            compact: hSize == .compact,
            safeBottom: inset(geo.safeAreaInsets.bottom, screenInsets.bottom),
            safeTrailing: inset(geo.safeAreaInsets.trailing, screenInsets.trailing))
    }

    private func layoutTogglePlacement(stable: DYLiveAdaptiveDecision, in geo: GeometryProxy) -> DYLiveLayoutTogglePlacement {
        DYLiveLayoutToggle.place(
            eligible: stable.layout,
            manual: DYLiveLayoutToggle.manualApplies(active: forceImmersive, anchored: immersiveAnchor, eligible: stable.layout),
            bounds: CGRect(origin: .zero, size: geo.size),
            interaction: stable.interaction,
            compact: hSize == .compact,
            safeBottom: geo.safeAreaInsets.bottom,
            safeTrailing: geo.safeAreaInsets.trailing,
            keyboardOverlap: keyboardOverlap,
            entered: model.entered)
    }

    private func liveDivisions(in geo: GeometryProxy) -> [DYLiveDivision] {
        guard #available(iOS 27.1, *) else { return [] }
        return geo.reservedRegions(kind: .division).map {
            DYLiveDivision(frame: $0.frame, isActive: $0.isActive)
        }
    }

    /// 「更多」里的分屏/整屏：内屏完全展开时随时可点；半折叠沿用原来的资格判断；其余（外屏/普通手机）灰掉。
    /// restoreSplit = 当前是整屏，点了去分屏；enterImmersive = 当前是分屏，点了去整屏。
    /// 内屏完全展开。系统若没回调铰链状态（unsupported），宽屏（regular）也按展开处理，免得按钮永远灰掉。
    private var canManualSplit: Bool {
        hingeStatus == .fullyOpen || (hingeStatus == .unsupported && hSize == .regular)
    }

    private func menuSplitRole(_ placed: DYLiveLayoutToggleRole) -> DYLiveLayoutToggleRole {
        if canManualSplit { return manualSplit ? .enterImmersive : .restoreSplit }
        return placed
    }

    private func performSplitToggle(role: DYLiveLayoutToggleRole, eligible: DYLiveAdaptiveLayout) {
        if role == .restoreSplit {
            forceImmersive = false
        } else if role == .enterImmersive, eligible != .existing {
            immersiveAnchor = eligible
            forceImmersive = true
        }
    }

    private func layoutToggle(_ placement: DYLiveLayoutTogglePlacement, eligible: DYLiveAdaptiveLayout) -> some View {
        let restoring = placement.role == .restoreSplit
        return Button {
            performSplitToggle(role: placement.role, eligible: eligible)
        } label: {
            Text(restoring ? "分屏" : "整屏")
                .font(.subheadline.weight(.semibold))
                .frame(width: placement.frame.width, height: placement.frame.height)
                .ddMediaGlassCapsule()
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(restoring ? "live.layout.adaptive" : "live.layout.immersive")
        .position(x: placement.frame.midX, y: placement.frame.midY)
    }

    /// 按钮顶边取导航下沿加 8pt，若顶部安全区更靠下则改到安全区下沿。
    /// 遮挡区和折痕改成窗格内的内边距：整段平移会把左侧按钮和第一颗头像推出外屏。
    private func previewChrome(in geo: GeometryProxy, pane: CGRect) -> (top: CGFloat, leading: CGFloat, trailing: CGFloat, stripTrailing: CGFloat, stripTail: CGFloat) {
        let paneAtTop = pane.minY < 24
        let feedTop = geo.frame(in: .named("douduo.feed")).minY
        let top = paneAtTop
            ? DYLivePreviewChrome.buttonOriginY(
                feedMinY: feedTop,
                navMaxY: topChrome.maxY,
                safeTop: inset(geo.safeAreaInsets.top, screenInsets.top))
            : 12
        let leading = DYLivePreviewChrome.horizontalInset(inset(geo.safeAreaInsets.leading, screenInsets.leading))
        let trailing = DYLivePreviewChrome.horizontalInset(inset(geo.safeAreaInsets.trailing, screenInsets.trailing))
        let divisions = previewDivisions(in: geo)
        var regions = divisions
        if #available(iOS 27.1, *) {
            for region in geo.reservedRegions(kind: .occlusion) where region.isActive {
                regions.append(region.frame)
            }
        }
        let fitted = DYLivePreviewChrome.containedInsets(
            pane: pane, top: top, leading: leading, trailing: trailing, regions: regions)
        let strip = DYLivePreviewChrome.avatarStripInsets(
            conservativeTrailing: fitted.trailing, pane: pane, top: fitted.top,
            leading: fitted.leading, divisions: divisions)
        return (fitted.top, fitted.leading, fitted.trailing, strip.trailing, strip.scrollTail)
    }

    private func previewDivisions(in geo: GeometryProxy) -> [CGRect] {
        guard #available(iOS 27.1, *) else { return [] }
        var frames: [CGRect] = []
        for region in geo.reservedRegions(kind: .division) where region.isActive {
            frames.append(region.frame)
        }
        return frames
    }

    private func inset(_ local: CGFloat, _ passed: CGFloat) -> CGFloat {
        local > 0.5 ? local : passed
    }

    /// 顶部第一行：发现更多、关注直播选择器。位置由导航下沿和安全区决定。
    /// 2026-11-20 老板嫌两颗文字胶囊碍眼 → 都收成小号图标：发现 = 圆形网格钮；关注在播 = 叠起来的红圈头像，不写字。
    private var discoverBar: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showDiscover.toggle() }
            } label: {
                Image(systemName: showDiscover ? "xmark" : "square.grid.2x2")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 36, height: 36)
                    .ddMediaGlassCircle()
                    .frame(width: DYLivePreviewChrome.minTapHeight, height: DYLivePreviewChrome.minTapHeight)
                    .contentShape(Rectangle())
            }
            .foregroundStyle(.primary).buttonStyle(.plain)
            .accessibilityLabel(showDiscover ? "收起" : "发现更多")
            .accessibilityIdentifier("live.discover")
            if !model.followLive.isEmpty { followLiveButton }
            Spacer(minLength: 0)
        }
    }

    private var discoverPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !classicPreviewChrome {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showDiscover = false }
                } label: {
                    Text("关闭")
                        .font(.subheadline.weight(.medium))
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(foreground)
                .accessibilityIdentifier("live.discover.close")
            }
            categoryStrip
            if let categoryHint {
                Text(categoryHint).font(.caption)
                    .foregroundStyle(theme.media.onMediaSecondary.color(for: scheme))
            }
        }
        .padding(.top, classicPreviewChrome ? 14 : 0)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 一级分类条：只显示有真实列表接口的入口，横向滚动容纳窄屏。
    private var categoryStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("全部分类").font(.subheadline.weight(.semibold))
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(ddLiveCategories) { c in
                        Button { pickCategory(c) } label: {
                            Text(c.name)
                                .font(.subheadline.weight(selectedCategory == c.id ? .semibold : .regular))
                                .foregroundStyle(foreground)
                                .padding(.horizontal, 14).frame(height: 34)
                                .background(Capsule().fill(selectedCategory == c.id
                                    ? foreground.opacity(0.22)
                                    : theme.media.chromeFill.color(for: scheme)))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("live.category.\(c.id)")
                        .accessibilityValue(selectedCategory == c.id ? "已选择" : "未选择")
                    }
                }
            }
            .scrollIndicators(.hidden)
            .accessibilityIdentifier("live.categoryStrip")
        }
        .foregroundStyle(foreground)
    }

    private func pickCategory(_ c: DYLiveCategory) {
        cancelFollowPick()
        switch c.kind {
        case .featured:
            selectedCategory = c.id; categoryHint = nil
            model.backToFeatured(bridge)
        case .gameZones:
            selectedCategory = c.id
            model.select(DYLiveZone(id: "103", type: "4", name: "游戏"), bridge)
            categoryHint = "「游戏」下可选具体专区"
            showCategories = true
        case .partition(let zone):
            selectedCategory = c.id; categoryHint = nil
            model.select(zone, bridge)
        }
        if !classicPreviewChrome {
            withAnimation(.easeInOut(duration: 0.2)) { showDiscover = false }
        }
    }

    private func dismissPreviewOverlays() {
        showDiscover = false
        showFollowLive = false
        followStripExpanded = false
    }

    /// 有播放地址就直接播。关注分类里还没有地址的当前房间，只解析这一间。
    private func presentCurrentRoom() {
        if model.isFollowedCatalog, let room = currentRoom, room.liveStreams.isEmpty {
            model.playbackError = nil
            model.stop()
            resolveListedFollow(room, enter: false)
        } else {
            model.play(currentRoom)
        }
    }

    /// 列表里的关注直播只有展示信息。点某一间，或滑到分类里的一间时，才补这一间的播放地址。
    private func resolveListedFollow(_ room: DYLiveRoom, enter: Bool) {
        var pick = followPick
        let ticket = pick.begin(roomID: room.id, webRid: room.webRid, hasStream: !room.liveStreams.isEmpty)
        followPick = pick
        guard room.liveStreams.isEmpty else {
            if enter { model.open(room) } else { model.adoptFollowPlayback(room) }
            return
        }
        guard !room.webRid.isEmpty else {
            if !enter { model.playbackError = DYFollowSelectionFailure.unavailable.message }
            return
        }
        Task {
            let result = await bridge.resolveFollowRoom(webRid: room.webRid)
            guard followPick.isCurrent(roomID: room.id, token: ticket), !result.stale else { return }
            if result.kind == .notLoggedIn {
                model.followLive = []
                if !enter { model.playbackError = "抖音未登录" }
                return
            }
            if result.kind == .rooms, let resolved = result.items.first, !resolved.liveStreams.isEmpty {
                let ready = DYLiveRoom(playback: resolved, fallback: room)
                if enter { model.open(ready) } else { model.adoptFollowPlayback(ready) }
                return
            }
            if !enter {
                let failure = DYFollowSelectionFailure.from(kind: result.kind, hasPlayableRoom: false) ?? .unavailable
                model.playbackError = failure.message
            }
        }
    }

    private func cancelFollowPick() {
        var pick = followPick
        pick.cancel()
        followPick = pick
    }


    /// 替换原「我的关注」入口：有关注主播在播才出现。不再写「N 位正在直播」，只叠 3 个红圈头像 + 「+N」角标，
    /// 点开是一排头像，点头像直接进直播间。
    private var followLiveButton: some View {
        let count = model.followLive.count
        let shown = Array(model.followLive.prefix(3))
        return Button { followStripExpanded.toggle() } label: {
            HStack(spacing: 4) {
                HStack(spacing: -10) {
                    ForEach(shown) { r in
                        CachedAsyncImage(url: r.avatar.flatMap(URL.init(string:))) { $0.resizable().scaledToFill() }
                            placeholder: { theme.media.chromeFill.color(for: scheme) }
                            .frame(width: 26, height: 26).clipShape(Circle())
                            .overlay(Circle().stroke(theme.status.danger.color(for: scheme), lineWidth: 1.5))
                    }
                }
                if count > shown.count {
                    Text("+\(count - shown.count)").font(.caption2.weight(.semibold)).monospacedDigit()
                }
                Image(systemName: followStripExpanded ? "chevron.up" : "chevron.down").font(.caption2.weight(.semibold))
            }
            .padding(.leading, 5).padding(.trailing, 8)
            .frame(height: 36)
            .ddMediaGlassCapsule()
            .frame(minHeight: DYLivePreviewChrome.minTapHeight)
            .contentShape(Rectangle())
        }
        .foregroundStyle(.primary).buttonStyle(.plain)
        .accessibilityIdentifier("live.follow")
        .accessibilityLabel("\(count) 位正在直播（关注的主播）")
    }

    private func followStrip(scrollTail: CGFloat) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 14) {
                ForEach(model.followLive) { r in
                    Button {
                        followStripExpanded = false
                        resolveListedFollow(r, enter: true)
                    } label: {
                        VStack(spacing: 4) {
                            CachedAsyncImage(url: r.avatar.flatMap(URL.init(string:))) { img in img.resizable().scaledToFill() }
                                placeholder: { theme.media.chromeFill.color(for: scheme) }
                                .frame(width: 54, height: 54).clipShape(Circle())
                                .padding(3)
                                .overlay(Circle().stroke(theme.status.danger.color(for: scheme), lineWidth: 2.5))
                                .overlay(alignment: .bottom) {
                                    Text("直播中").font(.caption2.weight(.bold)).foregroundStyle(foreground)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Capsule().fill(theme.status.danger.color(for: scheme)))
                                        .offset(y: 6)
                                }
                            Text(r.owner).font(.caption2).foregroundStyle(foreground).lineLimit(1).frame(width: 68)
                                .padding(.top, 4)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(r.owner)，直播中")
                    .accessibilityIdentifier("live.strip.\(r.id)")
                }
            }
            .padding(.leading, 2)
            .padding(.trailing, 2 + scrollTail)
        }
        .scrollIndicators(.hidden)
        .themeShadow(.mediaLabel)
        .accessibilityIdentifier("live.follow.strip")
    }

    /// 简洁 / 极简没有发现和人数按钮。关闭键单独占这一行，高度与那两个按钮相同。
    private var railFollowDismiss: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { followStripExpanded = false }
        } label: {
            Image(systemName: "xmark")
                .font(.subheadline.weight(.semibold))
                .frame(width: DYLivePreviewChrome.minTapHeight, height: DYLivePreviewChrome.minTapHeight)
        }
        .buttonStyle(.plain)
        .foregroundStyle(foreground)
        .accessibilityLabel("关闭我的关注")
        .accessibilityIdentifier("live.follow.strip.close")
    }

    /// 没有可展示的主播时，说明落在头像条同一条上，不开整页列表。
    private var railFollowNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(followStripNote)
                .font(.caption)
                .foregroundStyle(foreground)
                .accessibilityIdentifier("live.follow.strip.empty")
            if model.followLiveKind == .notLoggedIn {
                Button("登录") { onWeb(DouyinWeb.home) }
                    .font(.caption.weight(.semibold))
                    .accessibilityIdentifier("live.follow.strip.login")
            } else if model.followLiveKind == .requestFailed || model.followLiveKind == .decodeFailed || model.followLiveKind == .unexpectedShape {
                Button("重试") { Task { await model.loadFollowLive(bridge, refresh: true) } }
                    .font(.caption.weight(.semibold))
                    .accessibilityIdentifier("live.follow.strip.retry")
            }
        }
        .padding(.leading, 2)
    }

    private var followStripNote: String {
        switch model.followLiveKind {
        case .notLoggedIn: "登录后才能看到关注的直播"
        case .filtered: "暂时没有可播放的线路"
        case .requestFailed: "关注直播加载失败"
        case .decodeFailed, .unexpectedShape: "直播数据无法解析"
        case .nobodyLive, .rooms: "关注的人现在没有在直播"
        case nil: "正在查看关注的直播"
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            if let error = model.error {
                Text(error).font(.footnote)
                Button("重试") { Task { await model.load(bridge, reset: true) } }
                Button("网页版 / 登录") { onWeb(URL(string: "https://live.douyin.com/")!) }
            } else {
                ProgressView().tint(foreground)
                Text("连接直播…").font(.footnote)
            }
        }.foregroundStyle(foreground).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func pages(video: CGRect, interaction: CGRect, ambientAxis: DYLiveAmbientAxis?,
                       paneWidth: CGFloat, splitRole: DYLiveLayoutToggleRole, splitAction: @escaping () -> Void) -> some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(model.rooms) { room in
                    DYLiveRoomPage(room: room, model: model, isCurrent: model.currentID == room.id,
                                   messages: model.currentID == room.id && chat.loadedRoom == room.webRid ? chat.messages : [],
                                   ticker: model.currentID == room.id && chat.loadedRoom == room.webRid ? chat.ticker : nil,
                                   stats: model.currentID == room.id && chat.loadedRoom == room.webRid ? chat.stats : DYLiveRoomStats(),
                                   keyboardOverlap: model.currentID == room.id ? keyboardOverlap : 0,
                                   input: AnyView(commentInput), onWeb: onWeb,
                                   videoPane: video, interactionPane: interaction,
                                   ambientAxis: model.currentID == room.id ? ambientAxis : nil,
                                   splitRole: splitRole, splitAction: splitAction,
                                   isolationID: "\(bridge.followSession):\(room.id)",
                                   bridge: bridge, onAuthor: { liveAuthor = $0 })
                        .containerRelativeFrame([.horizontal, .vertical])
                        .contentShape(Rectangle())
                        .accessibilityHidden(model.currentID != room.id)
                        .id(room.id)
                }
            }.scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $scrollID)
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .ignoresSafeArea(.container, edges: .bottom)
        .ignoresSafeArea(.keyboard)
        .background(DYLivePagingKeyboardLock(locked: keyboardLocksPaging))
        .simultaneousGesture(DragGesture(minimumDistance: 12)
            .onChanged { value in
                let horizontal = abs(value.translation.width) > abs(value.translation.height) * 1.2
                if horizontal, !model.entered, !model.clean, onChannelDrag != nil {
                    onChannelDrag?(value.translation.width, paneWidth)
                    return
                }
                guard abs(value.translation.height) > abs(value.translation.width) else { return }
                if !userScrolling {
                    gestureStartID = model.currentID
                    #if DEBUG
                    DYLiveModel.log("DDLIVE_SCROLL start=\(model.currentID ?? "-") count=\(model.rooms.count)")
                    #endif
                }
                scrollEndTask?.cancel(); userScrolling = true
            }
            .onEnded { value in
                let horizontal = abs(value.translation.width) > abs(value.translation.height) * 1.2
                if horizontal, !model.entered, !model.clean, onChannelDragEnd != nil {
                    onChannelDragEnd?(value.translation.width, value.predictedEndTranslation.width, paneWidth, false)
                    return
                }
                // 进房后横滑（官方同款）：右滑一次把界面上的信息全划走（清屏），清屏后再右滑一次退出直播间；左滑恢复。
                // 刻意复用分页这一个手势，不再叠第二层 simultaneousGesture，避免影响上滑换台。
                if model.entered, DYLiveRoomSwipe.isHorizontal(width: value.translation.width, height: value.translation.height) {
                    switch DYLiveRoomSwipe.action(width: value.translation.width, clean: model.clean) {
                    case .clean: withAnimation(.easeInOut(duration: 0.2)) { model.clean = true }
                    case .leave: model.leaveRoom()
                    case .restore: withAnimation(.easeInOut(duration: 0.2)) { model.clean = false }
                    case .none: break
                    }
                    scrollEndTask?.cancel(); userScrolling = false; gestureStartID = nil
                    return
                }
                scrollEndTask = Task {
                    try? await Task.sleep(for: .milliseconds(600))
                    guard !Task.isCancelled else { return }
                    userScrolling = false; gestureStartID = nil
                }
            })
        .onChange(of: scrollID) { _, id in
            // 键盘把分页视口顶偏时，把位置钉回当前房间，不接受这次换台。
            if keyboardLocksPaging {
                if id != model.currentID { pinCurrentPage() }
                return
            }
            guard let id, id != model.currentID else { return }
            // 仅接受真实竖滑引起的相邻页变化，布局/追加列表不得偷偷切台。
            let start = gestureStartID ?? model.currentID
            if userScrolling, let a = model.rooms.firstIndex(where: { $0.id == id }),
               let b = model.rooms.firstIndex(where: { $0.id == start }), abs(a - b) <= 1 {
                model.noteVisibleRoom(id)
            } else { scrollID = model.currentID }
        }
    }

    private func syncViewport(minY: CGFloat, maxY: CGFloat) {
        viewportMinY = minY
        viewportMaxY = maxY
    }

    private func applyKeyboard(_ note: Notification) {
        guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let overlap = DYLiveKeyboardLayout.overlap(
            viewportMinY: viewportMinY,
            viewportMaxY: viewportMaxY,
            keyboardMinY: frame.minY,
            keyboardMaxY: frame.maxY)
        if abs(keyboardOverlap - overlap) > 0.5 {
            let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
            withAnimation(.easeOut(duration: min(duration, 0.35))) { keyboardOverlap = overlap }
        }
        if overlap > 1 { pinCurrentPage() }
    }

    private func pinCurrentPage() {
        guard let id = model.currentID, scrollID != id else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { scrollID = id }
    }

    private var commentInput: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let sendError { Text(sendError).font(.caption).foregroundStyle(theme.status.warning.color(for: scheme)) }
            if emojiOpen { DYLiveEmojiPanel { draft += $0 } }
            HStack(spacing: 8) {
                // 官方同款：表情按钮在输入框里面右侧
                HStack(spacing: 4) {
                    TextField(chat.composerReady ? "说点什么…" : "评论区连接中…", text: $draft)
                        .font(.subheadline).foregroundStyle(.primary).focused($inputFocused)
                        .submitLabel(.send).onSubmit(sendComment)
                        .accessibilityIdentifier("live.chat.input")
                        .onChange(of: inputFocused) { _, focused in if focused { emojiOpen = false } }
                    Button {
                        inputFocused = false
                        withAnimation(.easeOut(duration: 0.2)) { emojiOpen.toggle() }
                    } label: {
                        Image(systemName: emojiOpen ? "keyboard" : "face.smiling").font(.system(size: 20, weight: .regular))
                            .frame(width: 36, height: 40).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(emojiOpen ? "收起表情" : "表情")
                    .accessibilityIdentifier("live.chat.emoji")
                }
                .padding(.leading, 14).padding(.trailing, 4).frame(height: 44).ddMediaGlassCapsule()
                if !draft.isEmpty {
                    Button(action: sendComment) {
                        if sending { ProgressView() } else { Text(chat.composerReady ? "发送" : "连接中").font(.subheadline.weight(.semibold)) }
                    }.disabled(sending || !chat.composerReady).accessibilityIdentifier("live.chat.send")
                }
            }
        }
    }

    private func sendComment() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        guard chatRoom != nil, chat.composerReady else { sendError = "评论区连接中，稍后再试"; return }
        sending = true
        let target = chatRoom, submittedDraft = draft
        Task {
            let error = await chat.send(text)
            guard chatRoom == target else { sending = false; return }
            if let error { sendError = error }
            else if draft == submittedDraft { draft = ""; sendError = nil; inputFocused = false; emojiOpen = false }
            sending = false
        }
    }
}

/// 直播间「小表情」面板：官方表情（跟评论区同一套），点一下把 [名称] 插进输入框，发出去跟官网一样是表情代码
private struct DYLiveEmojiPanel: View {
    @ObservedObject private var store = DYEmojiStore.shared
    let insert: (String) -> Void
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 8)

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(store.names, id: \.self) { name in
                    Button { insert(name) } label: {
                        if let img = store.images[name] {
                            Image(uiImage: img).resizable().scaledToFit().frame(width: 28, height: 28)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(name)
                }
            }
            .padding(10)
        }
        .frame(height: 168)
        .overlay { if store.names.isEmpty { ProgressView() } }
        .background(RoundedRectangle(cornerRadius: 16).fill(.black.opacity(0.55)))
        .accessibilityIdentifier("live.chat.emojiPanel")
    }
}

private struct DYLiveRoomPage: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.horizontalSizeClass) private var hSize
    @AppStorage(DYLiveBackgroundSound.storageKey) private var backgroundSound = false
    let room: DYLiveRoom
    @ObservedObject var model: DYLiveModel
    let isCurrent: Bool
    let messages: [DYLiveIMEvent]
    var ticker: DYLiveIMEvent? = nil
    /// 头部：本场点赞、在线人数、前三名观众（来自弹幕数据）
    var stats = DYLiveRoomStats()
    let keyboardOverlap: CGFloat
    let input: AnyView
    let onWeb: (URL) -> Void
    var videoPane: CGRect
    var interactionPane: CGRect
    var ambientAxis: DYLiveAmbientAxis?
    /// 「更多」里的分屏/整屏入口。只有折叠屏处在可分屏姿态时才可点。
    var splitRole: DYLiveLayoutToggleRole = .hidden
    var splitAction: () -> Void = {}
    var isolationID: String
    /// 关注主播 / 读关注状态用（工单 B32）
    @ObservedObject var bridge: DouyinBridge
    /// 点主播头像/昵称：打开原生主播主页
    var onAuthor: (DYAweme.Author) -> Void = { _ in }
    @State private var followBusy = false
    @State private var followMsg: String?
    private var foreground: Color { theme.media.onMedia.color(for: scheme) }
    private var ownerFollowed: Bool {
        guard let author = room.ownerAuthor else { return false }
        return author.secUid.flatMap { bridge.authorFollowStates[$0] }
            ?? author.uid.flatMap { bridge.authorFollowStates[$0] }
            ?? ((author.follow ?? 0) > 0)
    }

    var body: some View {
        GeometryReader { geo in
            let video = livePane(videoPane, fallback: geo.size)
            let interaction = livePane(interactionPane, fallback: geo.size)
            let topInset = DYLiveLayoutToggle.returnTopInset(paneMinY: interaction.minY, compact: hSize == .compact)
            ZStack(alignment: .topLeading) {
                ZStack {
                if DYLivePlaybackGate.mask(isCurrent: isCurrent, ready: model.ready, failed: model.playbackError != nil) == .coverPrevious {
                    ZStack {
                        // 视频画面区出画前保持纯黑，不随亮色外观变白（老板定；test_live_playback_gate 守着）
                        Color.black
                        // 省电预加载截到的真实画面优先（划的过程中、现连出画前都垫着它），没有才用封面
                        if let frame = model.previewFrame(for: room.id) {
                            Image(uiImage: frame).resizable().aspectRatio(contentMode: room.portrait ? .fill : .fit)
                                .frame(width: geo.size.width, height: geo.size.height).clipped()
                        } else if let cover = room.cover, let url = URL(string: cover) {
                            CachedAsyncImage(url: url) { $0.resizable().aspectRatio(contentMode: room.portrait ? .fill : .fit) }
                                placeholder: { Color.black }
                                .frame(width: geo.size.width, height: geo.size.height).clipped()
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .allowsHitTesting(false)
                }
                if isCurrent && !model.entered {
                    Color.clear.contentShape(Rectangle()).onTapGesture { model.enterRoom() }
                }
                if isCurrent, !model.ready || model.playbackError != nil {
                    VStack(spacing: 10) {
                        if let error = model.playbackError {
                            Text(error).font(.footnote).multilineTextAlignment(.center)
                            Button("重试", action: model.retry).buttonStyle(.bordered)
                        } else {
                            ProgressView().tint(foreground)
                            // 已经垫着这一间的真实画面时不再写「连接直播…」，看起来就是马上要动的画面
                            if model.previewFrame(for: room.id) == nil { Text("连接直播…").font(.caption) }
                        }
                    }.foregroundStyle(foreground).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                }
                .placed(in: video)
                if isCurrent, let axis = ambientAxis {
                    let surface = DYLiveAdaptiveLayoutEngine.interactionSurface(
                        video: video, interaction: interaction, book: axis == .horizontal)
                    DouyinLiveAmbientBackground(
                        coverURL: room.cover.flatMap(URL.init(string:)), axis: axis, isolationID: isolationID)
                        .frame(width: surface.width, height: surface.height)
                        .padding(.leading, surface.minX)
                        .padding(.top, surface.minY)
                }
                Group {
                if !isCurrent {
                    Color.clear.allowsHitTesting(false)
                } else if model.clean {
                    // 清屏：界面上什么都不留（官方同款），点任意处或左滑恢复，再右滑退出
                    Button { withAnimation(.easeInOut(duration: 0.2)) { model.clean = false } } label: {
                        Color.clear.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("恢复直播间界面")
                    .accessibilityIdentifier("live.room.restore")
                } else if model.entered {
                    let closeOnBottom = DYLiveChromePlacement.closeOnBottomTrailing(
                        regularWidth: hSize == .regular,
                        foldActive: DYDuoMetrics.foldIsActive(geo))
                    VStack {
                        header(showsClose: !closeOnBottom)
                        Spacer(minLength: 12)
                        HStack(alignment: .bottom, spacing: 12) {
                            VStack(alignment: .leading, spacing: 12) {
                                if !messages.isEmpty || ticker != nil { DYLiveChatOverlay(messages: messages, ticker: ticker) }
                                // 底部一排（官方同款）：输入框（表情在框里）· 礼物 · 转发 · 更多。底对齐：表情面板展开时别的按钮不跟着飘上去
                                HStack(alignment: .bottom, spacing: 10) {
                                    input
                                    // 送礼物要花抖币：打开这一间的官网页面，用抖音自己的送礼和支付确认流程，App 不代发
                                    Button { onWeb(room.webURL) } label: {
                                        Image(systemName: "gift.fill").font(.system(size: 19, weight: .semibold))
                                            .foregroundStyle(Color(red: 1.0, green: 0.36, blue: 0.55))
                                            .frame(width: 44, height: 44).ddMediaGlassCircle()
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("送礼物（打开官网直播间）")
                                    .accessibilityIdentifier("live.room.gift")
                                    ShareLink(item: room.webURL, subject: Text(room.owner),
                                              message: Text(room.title.isEmpty ? "\(room.owner) 正在直播" : "\(room.owner) 正在直播：\(room.title)")) {
                                        Image(systemName: "arrowshape.turn.up.right.fill").font(.system(size: 18, weight: .semibold))
                                            .frame(width: 44, height: 44).ddMediaGlassCircle()
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("转发直播间")
                                    .accessibilityIdentifier("live.room.share")
                                    Menu {
                                    Button("清屏", systemImage: "rectangle") { model.clean = true }
                                    Toggle("静音", systemImage: "speaker.slash", isOn: $model.muted)
                                    Toggle("后台播放", systemImage: "speaker.wave.2", isOn: $backgroundSound)
                                        .accessibilityIdentifier("live.room.backgroundSound")
                                    Menu("清晰度", systemImage: "sparkles.tv") {
                                        Picker("清晰度", selection: Binding(get: { model.quality ?? "" },
                                                                         set: { model.setQuality($0.isEmpty ? nil : $0) })) {
                                            Text("自动").tag("")
                                            ForEach(model.qualityOptions, id: \.self) { Text(DYLiveModel.qualityName($0)).tag($0) }
                                        }
                                    }
                                    .accessibilityIdentifier("live.room.quality")
                                    Button(splitRole == .restoreSplit ? "分屏" : "整屏",
                                           systemImage: splitRole == .restoreSplit ? "rectangle.split.1x2" : "rectangle.expand.vertical",
                                           action: splitAction)
                                        .disabled(splitRole == .hidden)
                                        .accessibilityIdentifier("live.room.split")
                                    Button("重新连接", systemImage: "arrow.clockwise", action: model.retry)
                                    Button("官网互动（礼物）", systemImage: "safari") { onWeb(room.webURL) }
                                    } label: { Image(systemName: "ellipsis").font(.title2).frame(width: 44, height: 44).ddMediaGlassCircle() }
                                    .accessibilityIdentifier("live.room.more")
                                }
                            }
                            .frame(maxWidth: 420, alignment: .leading)
                            if closeOnBottom {
                                Spacer(minLength: 12)
                                closeX(action: model.leaveRoom, id: "live.room.close")
                                    .modifier(DYRailReservedNudge())
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.leading, 18)
                    .padding(.trailing, hSize == .compact ? 82 : 18)
                    .padding(.top, topInset)
                    .padding(.bottom, DYLiveKeyboardLayout.bottomPadding(
                        safeBottom: geo.safeAreaInsets.bottom,
                        keyboardOverlap: isCurrent ? keyboardOverlap : 0))
                } else {
                    // 与推荐流里的直播卡同一套（老板 2026-11-20）：下方居中「点击进入直播间」，
                    // 左下「直播中」小标签 + @主播 + 标题；不挡画面中间。
                    VStack(spacing: 14) {
                        Spacer()
                        Button(action: model.enterRoom) {
                            HStack(spacing: 6) {
                                Image(systemName: "chart.bar.fill")
                                Text(room.viewers.isEmpty ? "点击进入直播间" : "点击进入直播间 · \(room.viewers)人在看")
                            }
                            .font(.subheadline)
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .background(Capsule().fill(.black.opacity(0.28)))
                            .overlay(Capsule().stroke(foreground.opacity(0.25), lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("live.room.enter")
                        VStack(alignment: .leading, spacing: 6) {
                            Text("直播中")
                                .font(.caption.weight(.bold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 3).fill(theme.status.danger.color(for: scheme)))
                            Text("@" + room.owner).font(.headline.weight(.bold)).lineLimit(1)
                            Text(room.title.isEmpty ? "\(room.owner) 正在直播" : room.title)
                                .font(.subheadline).opacity(0.9)
                                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        }
                        .themeShadow(.mediaLabel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.trailing, hSize == .compact ? 62 : 0)
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, max(geo.safeAreaInsets.bottom, 12) + 28)
                }
                }
                .frame(width: interaction.width, height: interaction.height)
                .padding(.leading, interaction.minX)
                .padding(.top, interaction.minY)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .foregroundStyle(foreground)
        }
        #if DEBUG
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("live.page.\(room.id)")
        #endif
    }

    private var avatar: some View {
        CachedAsyncImage(url: room.avatar.flatMap(URL.init(string:))) { $0.resizable().scaledToFill() }
            placeholder: { theme.media.chromeFill.color(for: scheme) }
            .frame(width: 36, height: 36).clipShape(Circle())
    }
    private func header(showsClose: Bool) -> some View {
        // 直播间唯一的返回键：与「我的 / 信息 / 网页版」页同款标题 + chevron.backward 符号。
        // 外屏和半折叠仍放左上，右上留给系统状态栏/前摄挖孔。
        // 完全展开的内屏改放右下，避免被内屏系统层盖住，并离开左下聊天和更多按钮。
        // 主视图不再挂 NavigationStack / toolbar，Duo 系统侧栏不会再多渲染一颗返回。
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Button {
                        if let author = room.ownerAuthor { onAuthor(author) }
                    } label: {
                        HStack(spacing: 8) {
                            avatar
                            VStack(alignment: .leading, spacing: 2) {
                                Text(room.owner).font(.subheadline.weight(.semibold)).lineLimit(1)
                                // 官方：进房后名字下面写「本场点赞」；还没收到时先用列表里的在看人数
                                Text(stats.likeTotal.map { "\(DYLiveRoomStats.short($0))本场点赞" } ?? "\(room.viewers) 在看")
                                    .font(.caption2).monospacedDigit()
                                    .contentTransition(.numericText())
                                    .accessibilityIdentifier("live.room.likes")
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(room.ownerAuthor == nil)
                    .accessibilityLabel("主播 \(room.owner)，打开主页")
                    .accessibilityIdentifier("live.room.owner")
                    if room.ownerAuthor != nil, !ownerFollowed {
                        Button { Task { await followOwner() } } label: {
                            ZStack {
                                Text("关注").opacity(followBusy ? 0 : 1)
                                if followBusy { ProgressView().controlSize(.mini).tint(.white) }
                            }
                            .font(.caption.weight(.semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 12).frame(height: 28)
                            .background(Capsule().fill(theme.status.danger.color(for: scheme)))
                        }
                        .buttonStyle(.plain)
                        .disabled(followBusy)
                        .accessibilityLabel("关注 \(room.owner)")
                        .accessibilityIdentifier("live.room.follow")
                    }
                }
                .padding(.trailing, room.ownerAuthor != nil && !ownerFollowed ? 4 : 12).padding(.leading, 4).padding(.vertical, 4)
                .foregroundStyle(.primary).ddMediaGlassCapsule()
                if let followMsg {
                    Text(followMsg).font(.caption2).foregroundStyle(theme.status.warning.color(for: scheme))
                        .themeShadow(.mediaLabel)
                }
            }
            Spacer(minLength: 8)
            // 前三名观众头像 + 在线人数（官方同款）。窄屏放不下时先去掉头像，只留人数
            if stats.online != nil || stats.topViewers?.isEmpty == false {
                ViewThatFits(in: .horizontal) {
                    viewerStrip(avatars: true)
                    viewerStrip(avatars: false)
                }
            }
            // 退出直播间：官方同款右上角小 ×（右边距已让开 Duo 外屏右侧的系统状态栏）
            if showsClose {
                closeX(action: model.leaveRoom, id: "live.room.close")
            }
        }
    }

    private func followOwner() async {
        guard let author = room.ownerAuthor, !followBusy, !ownerFollowed else { return }
        followBusy = true
        defer { followBusy = false }
        let failure: String?
        do { failure = try await bridge.followVideoAuthor(author) } catch { failure = "关注失败：" + error.localizedDescription }
        DYLiveModel.log("DDLIVE_FOLLOW room=\(room.id) ok=\(failure == nil)")
        followMsg = failure
        guard failure != nil else { return }
        try? await Task.sleep(for: .seconds(3))
        if followMsg == failure { followMsg = nil }
    }
    private func viewerStrip(avatars: Bool) -> some View {
        HStack(spacing: 6) {
            if avatars, let tops = stats.topViewers, !tops.isEmpty {
                HStack(spacing: -8) {
                    ForEach(Array(tops.prefix(3).enumerated()), id: \.offset) { _, url in
                        CachedAsyncImage(url: URL(string: url)) { $0.resizable().scaledToFill() }
                            placeholder: { Color.white.opacity(0.18) }
                            .frame(width: 30, height: 30).clipShape(Circle())
                            .overlay(Circle().stroke(.white.opacity(0.55), lineWidth: 1))
                    }
                }
                .accessibilityHidden(true)
            }
            if let n = stats.online {
                Text(DYLiveRoomStats.short(n))
                    .font(.footnote.weight(.semibold)).monospacedDigit()
                    .contentTransition(.numericText())
                    .padding(.horizontal, 10).frame(height: 30)
                    .background(Capsule().fill(.black.opacity(0.28)))
                    .accessibilityLabel("\(n) 人在线")
                    .accessibilityIdentifier("live.room.online")
            }
        }
        .fixedSize()
    }

    /// 退出直播间：官方直播间同款的小 × 圆钮（不再是「返回」胶囊）
    private func closeX(action: @escaping () -> Void, id: String) -> some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(theme.media.onMedia.color(for: scheme))
                .frame(width: 34, height: 34)
                .background(Circle().fill(.black.opacity(0.28)))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("退出直播间")
        .accessibilityIdentifier(id)
    }
}

// MARK: - live-close-placement
enum DYLiveChromePlacement {
    /// 只有完全展开的内屏（regular 且折痕未激活）把关闭按钮放到右下。
    /// 外屏是 compact；半折叠时折痕激活，两者都保持左上。
    static func closeOnBottomTrailing(regularWidth: Bool, foldActive: Bool) -> Bool {
        regularWidth && !foldActive
    }
}
/// 进房后的横滑（官方直播间同款）：右滑一次清屏，清屏后再右滑退出直播间，左滑恢复界面。
enum DYLiveRoomSwipe {
    enum Action: Equatable { case none, clean, leave, restore }
    /// 横向且够长才算（不跟上滑换台抢）
    static let minDistance: CGFloat = 70
    static func isHorizontal(width: CGFloat, height: CGFloat) -> Bool {
        abs(width) > minDistance && abs(width) > abs(height) * 1.2
    }
    static func action(width: CGFloat, clean: Bool) -> Action {
        if width > 0 { return clean ? .leave : .clean }
        return clean ? .restore : .none
    }
}
// MARK: - live-close-placement-end

// MARK: - live-layout-toggle
enum DYLiveLayoutToggleRole: Equatable {
    case hidden
    case enterImmersive
    case restoreSplit
}

struct DYLiveLayoutTogglePlacement: Equatable {
    var role: DYLiveLayoutToggleRole
    var frame: CGRect
}

enum DYLiveLayoutToggle {
    static let spacing: CGFloat = 12
    static let controlSize = CGSize(width: 72, height: 36)
    static let returnHeight: CGFloat = 40
    static let returnLeading: CGFloat = 18
    static let composerHeight: CGFloat = 44
    static let composerMaxWidth: CGFloat = 420

    static func returnTopInset(paneMinY: CGFloat, compact: Bool) -> CGFloat {
        paneMinY > 24 ? 12 : (compact ? 64 : 70)
    }

    /// 手动整屏只跟着当时那一种分屏。换成另一种分屏、竖屏或不支持时取消。
    static func manualApplies(active: Bool, anchored: DYLiveAdaptiveLayout, eligible: DYLiveAdaptiveLayout) -> Bool {
        active && anchored == eligible && eligible != .existing
    }

    static func place(
        eligible: DYLiveAdaptiveLayout,
        manual: Bool,
        bounds: CGRect,
        interaction: CGRect,
        compact: Bool,
        safeBottom: CGFloat,
        safeTrailing: CGFloat,
        keyboardOverlap: CGFloat,
        entered: Bool
    ) -> DYLiveLayoutTogglePlacement {
        guard eligible == .layoutA || eligible == .layoutB else {
            return DYLiveLayoutTogglePlacement(role: .hidden, frame: .zero)
        }
        if manual {
            return DYLiveLayoutTogglePlacement(
                role: .restoreSplit,
                frame: restoreFrame(bounds: bounds, compact: compact, safeBottom: safeBottom, safeTrailing: safeTrailing, keyboardOverlap: keyboardOverlap))
        }
        let frame = eligible == .layoutA
            ? layoutAFrame(interaction: interaction, compact: compact, safeTrailing: safeTrailing)
            : layoutBFrame(interaction: interaction, compact: compact, safeBottom: safeBottom, safeTrailing: safeTrailing, entered: entered)
        return DYLiveLayoutTogglePlacement(role: .enterImmersive, frame: frame)
    }

    private static func trailingInset(compact: Bool, safeTrailing: CGFloat) -> CGFloat {
        max(compact ? 82 : 18, safeTrailing)
    }

    private static func layoutAFrame(interaction: CGRect, compact: Bool, safeTrailing: CGFloat) -> CGRect {
        let trailing = trailingInset(compact: compact, safeTrailing: safeTrailing)
        return CGRect(
            x: interaction.maxX - trailing - controlSize.width,
            y: interaction.minY + spacing,
            width: controlSize.width,
            height: controlSize.height)
    }

    private static func layoutBFrame(
        interaction: CGRect,
        compact: Bool,
        safeBottom: CGFloat,
        safeTrailing: CGFloat,
        entered: Bool
    ) -> CGRect {
        guard entered else {
            return layoutBPreviewFrame(interaction: interaction, compact: compact, safeBottom: safeBottom, safeTrailing: safeTrailing)
        }
        let top = returnTopInset(paneMinY: interaction.minY, compact: compact)
        return CGRect(
            x: interaction.minX + returnLeading,
            y: interaction.minY + top + returnHeight + spacing,
            width: controlSize.width,
            height: controlSize.height)
    }

    /// 预览还没有进房「返回」。整屏改放右窗格右下，避开进入按钮。
    private static func layoutBPreviewFrame(
        interaction: CGRect,
        compact: Bool,
        safeBottom: CGFloat,
        safeTrailing: CGFloat
    ) -> CGRect {
        let trailing = trailingInset(compact: compact, safeTrailing: safeTrailing)
        let bottom = DYLiveKeyboardLayout.bottomPadding(safeBottom: safeBottom, keyboardOverlap: 0)
        var frame = CGRect(
            x: interaction.maxX - trailing - controlSize.width,
            y: interaction.maxY - bottom - controlSize.height,
            width: controlSize.width,
            height: controlSize.height)
        let entry = previewEntryFrame(interaction: interaction, safeBottom: safeBottom)
        if frame.intersects(entry) {
            frame.origin.y = entry.minY - spacing - controlSize.height
        }
        return frame
    }

    private static func previewEntryFrame(interaction: CGRect, safeBottom: CGFloat) -> CGRect {
        let bottom = max(safeBottom, 12) + 24
        let width = min(168, max(0, interaction.width - 40))
        return CGRect(
            x: interaction.minX + 20,
            y: interaction.maxY - bottom - 44,
            width: width,
            height: 44)
    }

    private static func restoreFrame(
        bounds: CGRect,
        compact: Bool,
        safeBottom: CGFloat,
        safeTrailing: CGFloat,
        keyboardOverlap: CGFloat
    ) -> CGRect {
        let trailing = trailingInset(compact: compact, safeTrailing: safeTrailing)
        let bottom = DYLiveKeyboardLayout.bottomPadding(safeBottom: safeBottom, keyboardOverlap: keyboardOverlap)
        var frame = CGRect(
            x: bounds.maxX - trailing - controlSize.width,
            y: bounds.maxY - bottom - controlSize.height,
            width: controlSize.width,
            height: controlSize.height)
        let composer = composerFrame(bounds: bounds, compact: compact, safeBottom: safeBottom, safeTrailing: safeTrailing, keyboardOverlap: keyboardOverlap)
        if frame.intersects(composer) {
            frame.origin.y = composer.minY - spacing - controlSize.height
        }
        return frame
    }

    private static func composerFrame(
        bounds: CGRect,
        compact: Bool,
        safeBottom: CGFloat,
        safeTrailing: CGFloat,
        keyboardOverlap: CGFloat
    ) -> CGRect {
        let leading = returnLeading
        let trailing = trailingInset(compact: compact, safeTrailing: safeTrailing)
        let bottom = DYLiveKeyboardLayout.bottomPadding(safeBottom: safeBottom, keyboardOverlap: keyboardOverlap)
        let available = max(0, bounds.width - leading - trailing)
        return CGRect(
            x: bounds.minX + leading,
            y: bounds.maxY - bottom - composerHeight,
            width: min(composerMaxWidth, available),
            height: composerHeight)
    }

    /// 布局 A 的模块圆钮放在下窗格右下。边距沿用分屏按钮的 12pt，再加安全区。
    /// 窗格太矮、右下角会压住「整屏」或「进入直播间」时，先上移，再改到「整屏」左侧。
    static func layoutAModuleFrame(
        interaction: CGRect,
        button: CGSize,
        compact: Bool,
        safeBottom: CGFloat,
        safeTrailing: CGFloat
    ) -> CGRect {
        let margin = spacing
        let width = max(0, button.width)
        let height = max(0, button.height)
        var frame = CGRect(
            x: interaction.maxX - max(0, safeTrailing) - margin - width,
            y: interaction.maxY - max(0, safeBottom) - margin - height,
            width: width,
            height: height)
        frame.origin.x = clamped(frame.origin.x, min: interaction.minX + margin, max: interaction.maxX - margin - width)
        frame.origin.y = clamped(frame.origin.y, min: interaction.minY + margin, max: interaction.maxY - margin - height)
        let entry = previewEntryFrame(interaction: interaction, safeBottom: safeBottom)
        if frame.intersects(entry) {
            let lifted = entry.minY - spacing - height
            if lifted >= interaction.minY + margin { frame.origin.y = lifted }
        }
        let toggle = layoutAFrame(interaction: interaction, compact: compact, safeTrailing: safeTrailing)
        if frame.intersects(toggle) {
            let lifted = toggle.minY - spacing - height
            if lifted >= interaction.minY + margin {
                frame.origin.y = lifted
            } else {
                let beside = toggle.minX - spacing - width
                if beside >= interaction.minX + margin { frame.origin.x = beside }
            }
        }
        frame.origin.x = clamped(frame.origin.x, min: interaction.minX + margin, max: interaction.maxX - margin - width)
        frame.origin.y = clamped(frame.origin.y, min: interaction.minY + margin, max: interaction.maxY - margin - height)
        return frame
    }

    private static func clamped(_ value: CGFloat, min lower: CGFloat, max upper: CGFloat) -> CGFloat {
        guard upper >= lower else { return lower }
        return min(max(value, lower), upper)
    }
}
// MARK: - live-layout-toggle-end

// MARK: - live-keyboard-layout
enum DYLiveKeyboardLayout {
    /// 只计算贴住视口底边的键盘。悬浮键盘不顶起分页。
    static func overlap(viewportMinY: CGFloat, viewportMaxY: CGFloat, keyboardMinY: CGFloat, keyboardMaxY: CGFloat) -> CGFloat {
        guard keyboardMaxY >= viewportMaxY - 1 else { return 0 }
        let covered = min(viewportMaxY, keyboardMaxY) - max(viewportMinY, keyboardMinY)
        guard covered > 0 else { return 0 }
        return min(covered, max(0, viewportMaxY - viewportMinY))
    }

    /// 键盘收起时保留原来的底部留白；弹出后评论栏贴在键盘上沿，不再叠加安全区。
    static func bottomPadding(safeBottom: CGFloat, keyboardOverlap: CGFloat) -> CGFloat {
        let resting = max(safeBottom, 12) + 12
        guard keyboardOverlap > 1 else { return resting }
        return keyboardOverlap + 12
    }
}

/// 只在键盘占用期间关掉分页 ScrollView 的自动 inset。收起后恢复系统 inset，避免平时把页面顶进状态栏。
private struct DYLivePagingKeyboardLock: UIViewRepresentable {
    var locked: Bool

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        let locked = locked
        DispatchQueue.main.async { apply(locked, from: uiView) }
    }

    private func apply(_ locked: Bool, from view: UIView) {
        var ancestor = view.superview
        while let current = ancestor {
            if let scroll = current as? UIScrollView {
                let behavior: UIScrollView.ContentInsetAdjustmentBehavior = locked ? .never : .automatic
                if scroll.contentInsetAdjustmentBehavior != behavior {
                    scroll.contentInsetAdjustmentBehavior = behavior
                }
                scroll.automaticallyAdjustsScrollIndicatorInsets = !locked
                return
            }
            ancestor = current.superview
        }
    }
}
// MARK: - live-keyboard-layout-end

private struct DYLiveCategories: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    let selection: DYLiveZone?
    let onSelect: (DYLiveZone?) -> Void
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130))], spacing: 14) {
                    ForEach([nil] + DYLiveZone.all.map(Optional.some), id: \.self) { zone in
                        Button { onSelect(zone) } label: {
                            HStack {
                                Text(zone?.name ?? "推荐直播").font(.subheadline)
                                if selection == zone { Image(systemName: "checkmark").font(.caption) }
                            }
                            .frame(maxWidth: .infinity).frame(height: 46)
                            .foregroundStyle(Color.primary)
                            .ddGlassCapsule()
                        }.buttonStyle(.plain)
                    }
                }.padding(20)
            }
            .navigationTitle("直播分类").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }.accessibilityIdentifier("live.categories.close")
                }
            }
        }
    }
}

@MainActor
private final class DYFollowLiveList: ObservableObject {
    enum Phase: Equatable {
        case idle, loading, ready, empty, notLoggedIn, failed, decodeFailed, filtered
    }

    @Published var rooms: [DYLiveRoom] = []
    @Published private(set) var phase: Phase = .idle
    @Published var resolvingID: String?
    @Published var selectionMessage: String?
    private var token = UUID()
    private var task: Task<Void, Never>?
    private var resolveTask: Task<Void, Never>?
    private var selection = DYFollowSelection()
    private var didRetryStale = false

    func reload(_ bridge: DouyinBridge, refresh: Bool = false) {
        task?.cancel()
        resolveTask?.cancel()
        selection.cancel()
        resolvingID = selection.resolvingID
        selectionMessage = nil
        let token = UUID()
        self.token = token
        #if DEBUG
        if let mocked = Self.mocked() {
            rooms = mocked.rooms
            phase = mocked.phase
            return
        }
        #endif
        phase = .loading
        let started = ProcessInfo.processInfo.systemUptime
        task = Task {
            let result = await bridge.followLiveResult(ignoreCache: refresh)
            guard !Task.isCancelled, token == self.token else { return }
            if result.stale {
                guard !didRetryStale else {
                    rooms = []
                    phase = .failed
                    return
                }
                didRetryStale = true
                reload(bridge)
                return
            }
            didRetryStale = false
            switch result.kind {
            case .rooms where !result.items.isEmpty:
                rooms = result.items
                phase = .ready
            case .nobodyLive:
                rooms = []
                phase = .empty
            case .notLoggedIn:
                rooms = []
                phase = .notLoggedIn
            case .filtered:
                rooms = []
                phase = .filtered
            case .requestFailed:
                rooms = []
                phase = .failed
            case .rooms, .decodeFailed, .unexpectedShape:
                rooms = []
                phase = .decodeFailed
            }
            let elapsed = String(format: "%.3f", ProcessInfo.processInfo.systemUptime - started)
            DYLiveModel.log("DDFOLLOWLIST phase=\(self.phase) n=\(self.rooms.count) elapsed=\(elapsed) cache=\(result.fromCache ? 1 : 0) listRequests=\(result.fromCache ? 0 : 1) detailRequests=0")
        }
    }

    func pick(_ room: DYLiveRoom, bridge: DouyinBridge, open: @escaping (DYLiveRoom) -> Void) {
        resolveTask?.cancel()
        selectionMessage = nil
        let ticket = selection.begin(roomID: room.id, webRid: room.webRid, hasStream: !room.liveStreams.isEmpty)
        resolvingID = selection.resolvingID
        guard room.liveStreams.isEmpty else {
            guard selection.isCurrent(roomID: room.id, token: ticket) else { return }
            DYLiveModel.log("DDFOLLOWPLAY outcome=ready reused=1 detailRequests=0 elapsed=0.000")
            open(room)
            return
        }
        guard !room.webRid.isEmpty else {
            selectionMessage = DYFollowSelectionFailure.unavailable.message
            return
        }
        selection.startResolving(roomID: room.id)
        resolvingID = selection.resolvingID
        let started = ProcessInfo.processInfo.systemUptime
        resolveTask = Task {
            let result = await bridge.resolveFollowRoom(webRid: room.webRid)
            guard selection.complete(roomID: room.id, token: ticket) else { return }
            resolvingID = selection.resolvingID
            guard !Task.isCancelled else { return }
            let elapsed = String(format: "%.3f", ProcessInfo.processInfo.systemUptime - started)
            if result.stale { return }
            if result.kind == .notLoggedIn {
                DYLiveModel.log("DDFOLLOWPLAY outcome=notLoggedIn reused=0 detailRequests=1 elapsed=\(elapsed)")
                rooms = []
                phase = .notLoggedIn
                return
            }
            if result.kind == .rooms, let resolved = result.items.first, !resolved.liveStreams.isEmpty {
                DYLiveModel.log("DDFOLLOWPLAY outcome=ready reused=0 detailRequests=1 elapsed=\(elapsed)")
                open(DYLiveRoom(playback: resolved, fallback: room))
                return
            }
            let failure = DYFollowSelectionFailure.from(kind: result.kind, hasPlayableRoom: false) ?? .unavailable
            DYLiveModel.log("DDFOLLOWPLAY outcome=\(failure) reused=0 detailRequests=1 elapsed=\(elapsed)")
            selectionMessage = failure.message
        }
    }

    func cancel() {
        task?.cancel()
        resolveTask?.cancel()
        selection.cancel()
        token = UUID()
        resolvingID = selection.resolvingID
    }

    #if DEBUG
    private static func mocked() -> (phase: Phase, rooms: [DYLiveRoom])? {
        switch ProcessInfo.processInfo.environment["DOUDUO_FOLLOWMOCK"] {
        case "rooms": return (.ready, DYLiveRoom.debugFollowed())
        case "empty": return (.empty, [])
        case "login": return (.notLoggedIn, [])
        case "failed": return (.failed, [])
        case "decode": return (.decodeFailed, [])
        case "filtered": return (.filtered, [])
        default: return nil
        }
    }
    #endif
}

// MARK: - follow-live-sheet-layout
enum DYFollowLiveSheetLayout {
    static let minimumTap: CGFloat = 44
    static let ringWidth: CGFloat = 2
    static let expandedContentWidth: CGFloat = 520
    static let navigationChrome: CGFloat = 64
    static let bottomAllowance: CGFloat = 36
    static let messageHeight: CGFloat = 44

    static func avatarSide(regularWidth: Bool) -> CGFloat { regularWidth ? 64 : 56 }
    static func rowSpacing(regularWidth: Bool) -> CGFloat { regularWidth ? 12 : 6 }
    static func rowVerticalPadding(regularWidth: Bool) -> CGFloat { regularWidth ? 8 : 6 }
    static let listVerticalPadding: CGFloat = 8
    static func maximumSheetHeight(regularWidth: Bool) -> CGFloat { regularWidth ? 640 : 520 }

    static func contentMaxWidth(regularWidth: Bool) -> CGFloat {
        regularWidth ? expandedContentWidth : .infinity
    }

    static func rowHeight(regularWidth: Bool) -> CGFloat {
        let avatar = avatarSide(regularWidth: regularWidth) + ringWidth * 2
        let padded = avatar + rowVerticalPadding(regularWidth: regularWidth) * 2
        return max(padded, minimumTap)
    }

    /// 按行数估算 sheet 高度，并限制在一屏可放下的上限内。人少时不拉高，人多时只让列表滚动。
    static func sheetHeight(rowCount: Int, regularWidth: Bool, showsMessage: Bool) -> CGFloat {
        let maximum = maximumSheetHeight(regularWidth: regularWidth)
        let message = showsMessage ? messageHeight : 0
        guard rowCount > 0 else {
            return min(navigationChrome + bottomAllowance + 168 + message, maximum)
        }
        let spacing = rowSpacing(regularWidth: regularWidth)
        let rows = CGFloat(rowCount) * rowHeight(regularWidth: regularWidth)
        let gaps = CGFloat(rowCount - 1) * spacing
        let raw = navigationChrome + bottomAllowance + message + rows + gaps + listVerticalPadding * 2
        return min(max(raw, navigationChrome + minimumTap), maximum)
    }
}
// MARK: - follow-live-sheet-layout-end

private struct DYFollowLiveSheet: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.horizontalSizeClass) private var hSize
    @ObservedObject var bridge: DouyinBridge
    let onPick: (DYLiveRoom) -> Void
    let onLogin: () -> Void
    @StateObject private var model = DYFollowLiveList()
    @State private var foldActive = false
    private var foreground: Color { Color.primary }
    private var secondary: Color { Color.secondary }
    private var regularWidth: Bool { hSize == .regular && !foldActive }
    private var sheetDetent: CGFloat {
        DYFollowLiveSheetLayout.sheetHeight(
            rowCount: model.phase == .ready ? model.rooms.count : 0,
            regularWidth: regularWidth,
            showsMessage: model.selectionMessage != nil)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch model.phase {
                case .idle, .loading:
                    ProgressView("加载我的关注…").tint(foreground)
                case .ready:
                    VStack(alignment: .leading, spacing: 0) {
                        if let message = model.selectionMessage {
                            Text(message)
                                .font(.footnote)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 24)
                                .padding(.top, 8)
                                .accessibilityIdentifier("live.follow.selection")
                        }
                        list
                    }
                case .empty:
                    notice("关注的人现在没有在直播", id: "live.follow.empty", action: "刷新") { model.reload(bridge, refresh: true) }
                case .notLoggedIn:
                    notice("抖音未登录，登录后才能看到关注的直播", id: "live.follow.login", action: "网页版 / 登录", actionID: "live.follow.login.button", onLogin)
                case .failed:
                    notice("我的关注加载失败", id: "live.follow.failed", action: "重试") { model.reload(bridge, refresh: true) }
                case .decodeFailed:
                    notice("直播数据无法解析", id: "live.follow.decode", action: "重试") { model.reload(bridge, refresh: true) }
                case .filtered:
                    notice("关注的人正在直播，但暂时没有可播放的线路", id: "live.follow.filtered", action: "重试") { model.reload(bridge, refresh: true) }
                }
            }
            .frame(maxWidth: DYFollowLiveSheetLayout.contentMaxWidth(regularWidth: regularWidth), maxHeight: .infinity, alignment: .top)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .foregroundStyle(foreground)
            .navigationTitle("我的关注")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("刷新") { model.reload(bridge, refresh: true) }
                        .disabled(model.phase == .loading)
                        .accessibilityIdentifier("live.follow.refresh")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }.accessibilityIdentifier("live.follow.close")
                }
            }
        }
        .background {
            DYFollowFoldReader { foldActive = $0 }
        }
        .background(Color.ddBackground.ignoresSafeArea())
        .presentationDetents([.height(sheetDetent)])
        .presentationBackground(Color.ddBackground)
        .presentationDragIndicator(.visible)

        .task { model.reload(bridge) }
        .onChange(of: bridge.followSession) { _, _ in
            model.rooms = []
            model.reload(bridge)
        }
        .onDisappear { model.cancel() }
    }

    @Environment(\.dismiss) private var dismiss

    private var list: some View {
        let side = DYFollowLiveSheetLayout.avatarSide(regularWidth: regularWidth)
        return ScrollView {
            LazyVStack(spacing: DYFollowLiveSheetLayout.rowSpacing(regularWidth: regularWidth)) {
                ForEach(model.rooms) { room in
                    Button { model.pick(room, bridge: bridge, open: onPick) } label: {
                        HStack(spacing: 12) {
                            liveAvatar(room, side: side)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(room.owner.isEmpty ? "未命名主播" : room.owner)
                                    .font(.body.weight(.semibold))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                HStack(spacing: 8) {
                                    Text("直播中")
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(Color.primary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(theme.status.danger.color(for: scheme)))
                                    if !room.viewers.isEmpty {
                                        Text("\(room.viewers) 在看")
                                            .font(.subheadline)
                                            .foregroundStyle(secondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                            Spacer(minLength: 8)
                            if model.resolvingID == room.id {
                                ProgressView().controlSize(.small).tint(foreground)
                            } else {
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(secondary.opacity(0.75))
                                    .accessibilityHidden(true)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, DYFollowLiveSheetLayout.rowVerticalPadding(regularWidth: regularWidth))
                        .frame(maxWidth: .infinity, minHeight: DYFollowLiveSheetLayout.minimumTap, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("live.follow.room.\(room.id)")
                    .accessibilityLabel(rowLabel(room))
                }
            }
            .padding(.vertical, DYFollowLiveSheetLayout.listVerticalPadding)
        }
        .scrollBounceBehavior(.basedOnSize)
        .accessibilityIdentifier("live.follow.list")
    }

    private func rowLabel(_ room: DYLiveRoom) -> String {
        let name = room.owner.isEmpty ? "未命名主播" : room.owner
        if room.viewers.isEmpty { return "\(name)，直播中" }
        return "\(name)，直播中，\(room.viewers) 在看"
    }

    private func liveAvatar(_ room: DYLiveRoom, side: CGFloat) -> some View {
        CachedAsyncImage(url: room.avatar.flatMap(URL.init(string:))) { $0.resizable().scaledToFill() }
            placeholder: { theme.media.chromeFill.color(for: scheme) }
            .frame(width: side, height: side)
            .clipShape(Circle())
            .padding(DYFollowLiveSheetLayout.ringWidth)
            .overlay(Circle().stroke(theme.status.danger.color(for: scheme), lineWidth: DYFollowLiveSheetLayout.ringWidth))
    }

    private func notice(_ text: String, id: String, action: String, actionID: String? = nil, _ run: @escaping () -> Void) -> some View {
        VStack(spacing: 16) {
            Text(text).font(.footnote).multilineTextAlignment(.center).accessibilityIdentifier(id)
            Button(action, action: run)
                .buttonStyle(.bordered)
                .accessibilityIdentifier(actionID ?? "\(id).action")
        }
        .padding(24)
    }
}

private struct DYFollowFoldReader: View {
    var onChange: (Bool) -> Void

    var body: some View {
        GeometryReader { geo in
            let active = DYDuoMetrics.foldIsActive(geo)
            Color.clear
                .onAppear { onChange(active) }
                .onChange(of: active) { _, value in onChange(value) }
        }
        .allowsHitTesting(false)
    }
}

#if DEBUG
extension DYLiveRoom {
    static func debugRoom(_ id: String, owner: String, title: String, viewers: String) -> DYLiveRoom {
        DYLiveRoom(id: id, webRid: id, title: title, owner: owner, avatar: nil, cover: nil, viewers: viewers,
                   hls: ["HD1": "https://example.com/\(id).m3u8"], portrait: true, def: "HD1")
    }

    static func debugFeed() -> [DYLiveRoom] {
        [debugRoom("rec-a", owner: "推荐甲", title: "推荐直播甲", viewers: "10"),
         debugRoom("rec-b", owner: "推荐乙", title: "推荐直播乙", viewers: "20")]
    }

    static func debugFollowed() -> [DYLiveRoom] {
        [debugRoom("fol-a", owner: "关注甲", title: "关注直播甲", viewers: "30"),
         debugRoom("fol-b", owner: "关注乙", title: "关注直播乙", viewers: "")]
    }
}
#endif
