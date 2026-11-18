import CoreGraphics
import Foundation

enum DYLiveAudioOwner: Equatable { case vlc, avPlayer, none }

enum DYLiveOwnerTransition: Equatable { case claim, release }

/// 一代直播流里 AVPlayer 走到哪一步。`DYLivePiPSession` 只存这一个值，`preparing` 和接管状态都由它推出。
enum DYLivePiPPhase: Equatable {
    case idle
    /// VLC 出画出声；HLS 静音、暂停，等第一帧可显示。
    case preparing
    /// HLS 已有画面；AVPlayer 静音试播，VLC 仍是唯一出声者。
    case warming
    case prepared
    /// AVPlayer 出画出声，VLC 已停。
    case takenOver
}

/// HLS 预备没走到接管的原因。只有「没拿到」和「拿到了但没播起来」值得在同一代里再试。
enum DYLivePiPPrepFailure: Equatable {
    /// 时限内 item 一直没有 readyToPlay：清单或分片没拿到。
    case notLoaded
    /// item 失败且是网络错误。
    case network
    /// 有画面，试播时限内没真正播起来。
    case stalled
    /// item 已 readyToPlay，时限内仍没有可显示帧：这条流 AVPlayer 出不了画。
    case noPicture
    /// item 失败且不是网络错误。
    case media

    var isTransient: Bool {
        switch self {
        case .notLoaded, .network, .stalled: true
        case .noPicture, .media: false
        }
    }
}

/// 一代流（换房、重连、换源都是新一代）里 HLS 预备的失败记账。取消不算失败。
struct DYLivePiPAttempts: Equatable {
    /// 同一来源只重试一次暂时性失败。
    static let maxAttempts = 2
    static let retryDelay: Duration = .seconds(2)

    private(set) var failures = 0
    private(set) var lastFailure: DYLivePiPPrepFailure?

    var unsupported: Bool { lastFailure.map { !$0.isTransient } ?? false }
    var exhausted: Bool { failures >= Self.maxAttempts }
    var mayPrepare: Bool { !unsupported && !exhausted }
    var attempt: Int { failures + 1 }

    /// 记一次失败，返回下一次预备前要等多久；nil 表示这一代不再预备。
    mutating func record(_ failure: DYLivePiPPrepFailure) -> Duration? {
        failures += 1
        lastFailure = failure
        return mayPrepare ? Self.retryDelay : nil
    }
}

/// 由房间和会话的现有状态推出，供手动入口与状态提示共用。
enum DYLivePiPReadiness: Equatable {
    /// 来源条件不满足（没有 HLS，或没有 VLC 这一档的 HLS），本次进房不预备。
    case excluded(DYLiveHandoffExclusion)
    case waitingForPicture
    case preparing(attempt: Int)
    case warming
    /// AVPlayer 已接管，系统还没给 isPictureInPicturePossible。
    case controllerPending
    case ready
    case resolvingDetail
    case retrying(DYLivePiPPrepFailure)
    case unsupported(DYLivePiPPrepFailure)
    case exhausted(DYLivePiPPrepFailure)
    /// 具备条件但没在预备，例如进后台取消后还没重新开始。
    case idle
}

/// 一间直播间这一代流为什么没去预备 HLS。前几项是来源条件，后几项是时机。
enum DYLiveHandoffExclusion: Equatable {
    /// 没有任何 HLS 地址。
    case noHLS
    /// 有 HLS，但没有 VLC 正在播的这一档；不替用户换清晰度。
    case hlsMissingAtQuality
    case vlcNotShowingPicture
    case busy
    case notForeground
}

enum DYLiveHandoffDecision: Equatable {
    /// `warmsOnItemReady`：VLC 自己在播 HLS 时，暂停的 AVPlayer 不会自己解出首帧，要在 item 就绪时就开始静音试播；VLC 播 FLV 时沿用原来的「先有可显示帧再试播」。
    case prepare(quality: String, warmsOnItemReady: Bool)
    case skip(DYLiveHandoffExclusion)
}

enum DYLivePiPIndicator: String, Equatable {
    case preparing = "PREPARING"
    case ready = "READY"
    case failed = "FAILED"
}

enum DYLivePiPPolicy {
    static let liveHandoffPrepareLimit: Duration = .seconds(10)

    static func acceptsCallback(current: UUID, event: UUID, ownerRoom: String?, eventRoom: String?) -> Bool {
        current == event && ownerRoom != nil && ownerRoom == eventRoom
    }

    static func permitsHLSToVLCFallback(liveCanProgress: Bool, backgroundSound: Bool, appInBackground: Bool) -> Bool {
        liveCanProgress || (appInBackground && backgroundSound)
    }

    static func manualUnavailableMessage(readiness: DYLivePiPReadiness) -> String? {
        switch readiness {
        case .ready: return nil
        case .unsupported, .excluded:
            return "当前直播线路暂不支持画中画，仍以原清晰度播放。"
        case .exhausted:
            return "画中画准备失败，可重新连接直播后重试。"
        default:
            return "画中画正在准备，请稍后重试。"
        }
    }

    static func indicator(readiness: DYLivePiPReadiness, current: Bool, active: Bool,
                          pending: Bool) -> DYLivePiPIndicator? {
        guard current, !active, !pending else { return nil }
        switch readiness {
        case .preparing, .warming, .controllerPending, .retrying, .resolvingDetail: return .preparing
        case .ready: return .ready
        case .unsupported, .exhausted: return .failed
        case .idle, .waitingForPicture, .excluded: return nil
        }
    }

    static let ownerAfterPrepare: DYLiveAudioOwner = .vlc

    /// VLC 出画后才在下面预备同一档 HLS。VLC 播的是 FLV 还是 HLS 都可以：能不能放进系统画中画由 AVPlayer 实际出不出画决定，
    /// 不按来源类型或编码名预先排除。
    static func handoffDecision(vlcPlaysFLV: Bool, vlcQuality: String?, hlsQualities: Set<String>,
                                vlcShowsPicture: Bool, handoffInProgress: Bool,
                                appActive: Bool, coverHold: Bool) -> DYLiveHandoffDecision {
        guard !hlsQualities.isEmpty else { return .skip(.noHLS) }
        guard let vlcQuality, hlsQualities.contains(vlcQuality) else { return .skip(.hlsMissingAtQuality) }
        guard vlcShowsPicture else { return .skip(.vlcNotShowingPicture) }
        guard !handoffInProgress else { return .skip(.busy) }
        guard appActive, !coverHold else { return .skip(.notForeground) }
        return .prepare(quality: vlcQuality, warmsOnItemReady: !vlcPlaysFLV)
    }

    /// 静音试播等待首帧的时限。
    static let warmupLimit: Duration = .seconds(5)

    /// 停止 VLC 后，等待 AVPlayer 恢复播放或稳定，再同步系统画中画控制器。
    static let handoffSettleLimit: Duration = .milliseconds(1500)

    static func owner(after action: DYLiveOwnerTransition, from current: DYLiveAudioOwner) -> DYLiveAudioOwner {
        switch (action, current) {
        case (.claim, .vlc): return .avPlayer
        case (.release, .avPlayer): return .vlc
        default: return current
        }
    }

    /// 试播已在走、条目只有声音轨没有视频轨：AVPlayer 认不出这路画面，不必再等试播时限。
    static func playsWithoutVideoTrack(playing: Bool, layerReady: Bool, audioTracks: Int, videoTracks: Int) -> Bool {
        playing && !layerReady && audioTracks > 0 && videoTracks == 0
    }

    static func timeoutFailure(phase: DYLivePiPPhase, itemReady: Bool, layerReady: Bool) -> DYLivePiPPrepFailure? {
        switch phase {
        case .preparing:
            if layerReady { return nil }
            return itemReady ? .noPicture : .notLoaded
        case .warming:
            // FLV 路径进试播时已经有帧，没帧只会出现在「item 就绪即试播」的 HLS 路径：AVPlayer 播了但出不了画。
            if layerReady { return .stalled }
            return itemReady ? .noPicture : .notLoaded
        case .idle, .prepared, .takenOver:
            return nil
        }
    }

    static func permitsPreparedVideo(_ formats: [UInt32]) -> Bool {
        formats == [0x61766331] // avc1
    }

    // PiP uses its own display. The inline layer stops receiving frames after didStart.
    // Keep the pre-start evidence bound to this item; recheck live ownership and codec.
    static func canClaimPreparedPiP(systemActive: Bool, playing: Bool, itemReady: Bool,
                                    validatedItem: Bool, compatibleVideo: Bool,
                                    sourceCurrent: Bool, ending: Bool) -> Bool {
        systemActive && playing && itemReady && validatedItem && compatibleVideo && sourceCurrent && !ending
    }

    enum ReturnAction: Equatable { case reconnectVLC, resumeExistingVLC, stayPaused }
    static func returnAction(hadTakenOver: Bool, wasPlaying: Bool) -> ReturnAction {
        guard wasPlaying else { return .stayPaused }
        return hadTakenOver ? .reconnectVLC : .resumeExistingVLC
    }

    static func itemFailure(errorDomain: String?) -> DYLivePiPPrepFailure {
        errorDomain == NSURLErrorDomain ? .network : .media
    }

    /// AVPlayer 被系统不带原因地停下（我们自己、后台、打断都会带原因）。每次试播或接管只补救一次；
    /// 只在前台或画中画正在起来/已起来时补，后台无画中画的暂停按原来的后台策略处理。
    static func recoversUnexplainedPause(hasReason: Bool, rate: Float, phase: DYLivePiPPhase,
                                         visible: Bool, alreadyRecovered: Bool) -> Bool {
        guard !hasReason, rate == 0, visible, !alreadyRecovered else { return false }
        return phase == .warming || phase == .takenOver
    }

    enum ResumePosition: Equatable {
        case inPlace
        case seek(to: Double)
    }

    /// 播放头还在已加载的直播窗口里就原地继续；不在（暂停预备的播放头停在 0）才跳到系统的直播位置。
    static func resumePosition(current: Double, loadedStart: Double, loadedEnd: Double, livePoint: Double?) -> ResumePosition {
        if current >= loadedStart, current < loadedEnd { return .inPlace }
        if let livePoint, livePoint >= loadedStart, livePoint <= loadedEnd { return .seek(to: livePoint) }
        return .seek(to: loadedStart)
    }

    static func readiness(sourceExclusion: DYLiveHandoffExclusion?, vlcShowsPicture: Bool,
                          phase: DYLivePiPPhase, possible: Bool,
                          attempts: DYLivePiPAttempts, retryPending: Bool,
                          resolvingDetail: Bool = false) -> DYLivePiPReadiness {
        switch phase {
        case .prepared, .takenOver: return possible ? .ready : .controllerPending
        case .warming: return .warming
        case .preparing: return .preparing(attempt: attempts.attempt)
        case .idle: break
        }
        if let sourceExclusion { return .excluded(sourceExclusion) }
        if resolvingDetail { return .resolvingDetail }
        if let failure = attempts.lastFailure {
            if attempts.unsupported { return .unsupported(failure) }
            if attempts.exhausted { return .exhausted(failure) }
            if retryPending { return .retrying(failure) }
        }
        return vlcShowsPicture ? .idle : .waitingForPicture
    }
}

/// One bounded activation attempt. didStart changes the kind of work still awaited,
/// without extending its deadline. Tokens prevent an old timer from cancelling a new attempt.
struct DYLivePiPStartup {
    enum Stage: Equatable { case idle, requesting, active, owned, restoring }
    enum Expiration: Equatable { case activation, playback }
    private(set) var stage: Stage = .idle
    private(set) var token: UUID?
    private(set) var deadline: TimeInterval?
    var pending: Bool { stage == .requesting || stage == .active }

    @discardableResult mutating func begin(at now: TimeInterval) -> UUID {
        let id = UUID()
        token = id
        deadline = now + 5
        stage = .requesting
        return id
    }
    mutating func didStart() {
        guard stage == .requesting else { return }
        stage = .active
    }
    mutating func claimed() {
        guard stage == .active else { return }
        stage = .owned
        deadline = nil
    }
    mutating func returning() {
        stage = .restoring
        deadline = nil
    }
    mutating func cancel() { self = .init() }
    func expiration(for id: UUID, at now: TimeInterval) -> Expiration? {
        guard token == id, let deadline, now >= deadline else { return nil }
        switch stage {
        case .requesting: return .activation
        case .active: return .playback
        case .idle, .owned, .restoring: return nil
        }
    }
}

/// 用户暂停后返回的所有权记录。停止后的新代次隔离旧播放器回调；不伪造首帧。
struct DYLivePausedReturn: Equatable {
    private(set) var roomID: String?
    private(set) var generation: UUID?

    mutating func hold(roomID: String, generation: UUID) {
        self.roomID = roomID
        self.generation = generation
    }

    mutating func clear() {
        roomID = nil
        generation = nil
    }

    func holds(currentRoom: String?, sourceRoom: String?, generation: UUID) -> Bool {
        guard let roomID, self.generation == generation else { return false }
        return roomID == currentRoom && roomID == sourceRoom
    }
}

enum DYLivePlaybackOverlay: Equatable {
    case none, connecting, paused, failed

    static func resolve(ready: Bool, hasError: Bool, paused: Bool) -> Self {
        if paused { return .paused }
        if hasError { return .failed }
        return ready ? .none : .connecting
    }
}

/// 原视频框定位优先，只在与实际测量的主播信息栏相交时避让。
enum DYLivePiPBadgePlacement {
    static func topInset(video: CGRect, header: CGRect, preferredTop: CGFloat = 110) -> CGFloat? {
        let leading: CGFloat = 8
        // 为最长的 PREPARING 保留避让空间，三种状态共用同一位置。
        let badgeWidth: CGFloat = 112
        guard video.width >= leading + badgeWidth, video.height >= 24 else { return nil }
        let badge = CGRect(x: video.minX + leading, y: video.minY + preferredTop, width: badgeWidth, height: 24)
        if preferredTop + 24 <= video.height, header.isNull || !badge.intersects(header) { return preferredTop }
        guard !header.isNull else { return nil }
        let below = header.maxY - video.minY + 6
        if below >= 0, below + 24 <= video.height { return below }
        let above = header.minY - video.minY - 6 - 24
        if above >= 0, above + 24 <= video.height { return above }
        // 非交互提示没有安全位置时隐藏，绝不覆盖主播或重要控件。
        return nil
    }
}
