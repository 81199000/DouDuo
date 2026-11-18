import AVFoundation
import AVKit
import Combine
import SwiftUI
import UIKit

@MainActor
final class DYLivePiPSession: ObservableObject {
    private enum ManualRequest: Equatable { case awaitingPlayback, issued }
    private var manualRequest: ManualRequest?
    @Published private(set) var manualRequestInProgress = false
    private var possibleObserver: AnyCancellable?

    /// 这一代流里 AVPlayer 走到哪一步；预备、试播、接管都只看它。
    @Published private(set) var phase: DYLivePiPPhase = .idle
    @Published private(set) var audibleOwner: DYLiveAudioOwner = .none
    let playerLayer = AVPlayerLayer()
    private let player = AVPlayer()
    private let pictureInPicture = DYPictureInPicture()
    private var generation = UUID()
    private var roomID: String?
    private weak var vlc: VLCPlayerController?
    private var userMuted = false
    private var statusObservation: NSKeyValueObservation?
    private var readyObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var onReady: (() -> Void)?
    private var onPlaying: (() -> Void)?
    private var onPrepFailed: ((DYLivePiPPrepFailure) -> Void)?
    private var onBackgroundClose: (() -> Void)?
    private var onReturned: (() -> Void)?
    private var canUsePreparedItem: (() -> Bool)?
    private var canStartPreparedPlayback: (() -> Bool)?
    private var activeObserver: AnyCancellable?
    private weak var inlineView: UIView?
    private var startupTask: Task<Void, Never>?
    private var startup = DYLivePiPStartup()
    var startupPending: Bool { startup.pending }
    private weak var validatedItem: AVPlayerItem?
    private(set) var playAfterReturn = true
    private var onUnavailable: (() -> Void)?
    private var pipWantsAttach = false
    private var rateObserver: NSObjectProtocol?
    private var resignObserver: NSObjectProtocol?
    private var pictureInPictureChange: AnyCancellable?
    private var liveWindowObservation: NSKeyValueObservation?
    private var recoveredUnexplainedPause = false
    private var settleTask: Task<Void, Never>?
    private var warmsOnItemReady = false

    /// VLC 仍在出画出声；HLS 在下面预备或静音试播。
    var preparing: Bool { phase == .preparing || phase == .warming }
    var prepared: Bool { phase == .prepared }
    var preparedForSystemPiP: Bool {
        prepared && playerLayer.isReadyForDisplay && itemReady && pictureInPicturePossible && inlineView?.window != nil
    }
    /// AVPlayer 已从 VLC 接管画面和声音；VLC 已停。
    var hasTakenOver: Bool { phase == .takenOver }
    var isAudibleOwner: Bool { audibleOwner == .avPlayer }
    var pipActive: Bool { pictureInPicture.active }
    var pictureInPicturePossible: Bool { pictureInPicture.canStart }
    var itemReady: Bool { player.currentItem?.status == .readyToPlay }
    var pictureInPictureController: DYPictureInPicture { pictureInPicture }

    init() {
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
        player.automaticallyWaitsToMinimizeStalling = true
        rateObserver = NotificationCenter.default.addObserver(
            forName: AVPlayer.rateDidChangeNotification, object: player, queue: .main) { [weak self] note in
            let hasReason = note.userInfo?[AVPlayer.rateDidChangeReasonKey] != nil
            MainActor.assumeIsolated { self?.recoverUnexplainedPause(hasReason: hasReason) }
        }
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            guard player.timeControlStatus == .playing else { return }
            Task { @MainActor [weak self] in
                self?.warmupReachedPlayback()
                self?.issueManualRequestIfReady()
                self?.claimPiPIfPlaying()
            }
        }
        pictureInPictureChange = pictureInPicture.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        possibleObserver = pictureInPicture.$canStart.removeDuplicates().sink { [weak self] possible in
            guard possible else { return }
            Task { @MainActor [weak self] in self?.issueManualRequestIfReady() }
        }
        // Preserve playback state only for an already requested or active live PiP session.
        resignObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.notePlayingOnExit() }
        }
        activeObserver = NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.cancelPendingStart() }
    }

    deinit {
        if let rateObserver { NotificationCenter.default.removeObserver(rateObserver) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    }

    private func prepare(asset: AVURLAsset, generation: UUID, roomID: String) {
        self.generation = generation
        self.roomID = roomID
        audibleOwner = DYLivePiPPolicy.ownerAfterPrepare
        let item = AVPlayerItem(asset: asset)
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        observeItem(item, generation: generation, roomID: roomID)
        player.replaceCurrentItem(with: item)
        player.pause()
        player.rate = 0
    }

    /// VLC 继续出画出声。HLS 只装上、静音、rate 0：首帧可显示回调 `onReady`，试播真正出画回调 `onPlaying`，
    /// 接管前失败回调 `onPrepFailed`。是否试播、是否接管都由房间决定。
    func prepareHandoff(asset: AVURLAsset, generation: UUID, roomID: String, warmsOnItemReady: Bool,
                        onReady: @escaping () -> Void,
                        onPlaying: @escaping () -> Void,
                        onPrepFailed: @escaping (DYLivePiPPrepFailure) -> Void,
                        onBackgroundClose: @escaping () -> Void,
                        onUnavailable: @escaping () -> Void,
                        onReturned: (() -> Void)? = nil,
                        canUsePreparedItem: (() -> Bool)? = nil,
                        canStartPreparedPlayback: (() -> Bool)? = nil) {
        self.onReady = onReady
        self.onPlaying = onPlaying
        self.onPrepFailed = onPrepFailed
        self.onBackgroundClose = onBackgroundClose
        self.onUnavailable = onUnavailable
        self.onReturned = onReturned
        self.canUsePreparedItem = canUsePreparedItem
        self.canStartPreparedPlayback = canStartPreparedPlayback
        self.warmsOnItemReady = warmsOnItemReady
        recoveredUnexplainedPause = false
        playAfterReturn = true
        validatedItem = nil
        startup.cancel()
        transition(to: .preparing)
        player.isMuted = true
        prepare(asset: asset, generation: generation, roomID: roomID)
    }

    /// HLS 有画面后静音试播。VLC 不动，仍是唯一出声者；真正出画才回调 `onPlaying`，没出画前不停 VLC。
    func warmUp(generation: UUID, roomID: String) {
        guard phase == .preparing,
              DYLivePiPPolicy.acceptsCallback(current: self.generation, event: generation,
                                        ownerRoom: self.roomID, eventRoom: roomID) else { return }
        recoveredUnexplainedPause = false
        transition(to: .warming)
        player.isMuted = true
        if let item = player.currentItem,
           let loaded = item.loadedTimeRanges.last?.timeRangeValue, loaded.duration.seconds > 0 {
            playInsideLiveWindow(item: item, loaded: loaded, generation: generation, phase: .warming)
        } else {
            player.play()
        }
        warmupReachedPlayback()
    }

    /// 真正播放且画面层有可显示帧才算试播成功；只有声音没有画面的流不会接管。
    private func warmupReachedPlayback() {
        guard phase == .warming, player.timeControlStatus == .playing else { return }
        guard playerLayer.isReadyForDisplay else {
            let types = player.currentItem?.tracks.compactMap { $0.assetTrack?.mediaType } ?? []
            if DYLivePiPPolicy.playsWithoutVideoTrack(playing: true, layerReady: false,
                                                      audioTracks: types.filter { $0 == .audio }.count,
                                                      videoTracks: types.filter { $0 == .video }.count) {
                onPrepFailed?(.noPicture)
            }
            return
        }
        onPlaying?()
    }

    func finishPreparation() {
        guard phase == .warming, let item = player.currentItem else { return }
        guard isCompatibleVideo(item) else {
            onPrepFailed?(.media)
            return
        }
        guard itemReady, playerLayer.isReadyForDisplay else { return }
        validatedItem = item
        player.pause()
        transition(to: .prepared)
        syncPictureInPictureAttachment()
        let generation = self.generation
        startupTask = Task { [weak self] in
            do { try await Task.sleep(for: DYLivePiPPolicy.warmupLimit) } catch { return }
            guard let self, self.generation == generation, self.prepared,
                  !self.preparedForSystemPiP, !self.startupPending else { return }
            self.onUnavailable?()
        }
    }

    private func isCompatibleVideo(_ item: AVPlayerItem) -> Bool {
        let videos = item.tracks.filter(\.isEnabled).compactMap { track -> [CMFormatDescription]? in
            guard let assetTrack = track.assetTrack, assetTrack.mediaType == .video else { return nil }
            return assetTrack.formatDescriptions as? [CMFormatDescription] ?? []
        }
        let formats = videos.count == 1 ? videos[0].map(CMFormatDescriptionGetMediaSubType) : []
        return DYLivePiPPolicy.permitsPreparedVideo(formats)
    }

    func noteInlineView(_ view: UIView) {
        inlineView = view
    }

    private func claimPiPIfPlaying() {
        guard prepared, startup.stage == .active, !pictureInPicture.ending else { return }
        let item = player.currentItem
        let validated = item != nil && item === validatedItem
        let compatible = item.map(isCompatibleVideo) ?? false
        let current = canUsePreparedItem?() == true
        guard validated, itemReady, compatible, current else {
            onUnavailable?()
            return
        }
        guard DYLivePiPPolicy.canClaimPreparedPiP(
            systemActive: pipActive, playing: player.timeControlStatus == .playing,
            itemReady: itemReady, validatedItem: validated, compatibleVideo: compatible,
            sourceCurrent: current, ending: pictureInPicture.ending) else { return }
        onPlaying?()
    }

    private var hasActiveSourceWindow: Bool {
        guard UIApplication.shared.applicationState == .active,
              let view = inlineView, !view.isHidden, view.alpha > 0,
              let window = view.window, !window.isHidden, window.alpha > 0,
              window.windowScene?.activationState == .foregroundActive,
              playerLayer.superlayer === view.layer, !playerLayer.bounds.isEmpty else { return false }
        return true
    }

    /// Read-only eligibility shared by the READY indicator and the explicit user action.
    var manualPiPAvailable: Bool {
        guard preparedForSystemPiP,
              hasActiveSourceWindow, pictureInPicture.controllerPossible,
              manualRequest == nil, !startupPending, !pipActive,
              !pictureInPicture.starting, !pictureInPicture.ending,
              let item = player.currentItem, item === validatedItem, isCompatibleVideo(item),
              canUsePreparedItem?() == true, canStartPreparedPlayback?() == true else {
            return false
        }
        return true
    }

    /// Start only after an explicit foreground action for the current prepared live source.
    @discardableResult
    func requestManualPiP() -> Bool {
        guard manualPiPAvailable else { return false }
        manualRequest = .awaitingPlayback
        manualRequestInProgress = true
        player.isMuted = true
        startPreparedPlayback()
        issueManualRequestIfReady()
        return true
    }

    private func issueManualRequestIfReady() {
        guard manualRequest == .awaitingPlayback, prepared,
              let item = player.currentItem, item === validatedItem, isCompatibleVideo(item),
              itemReady, playerLayer.isReadyForDisplay, hasActiveSourceWindow,
              !pictureInPicture.ending, pictureInPicture.controllerPossible,
              canUsePreparedItem?() == true, canStartPreparedPlayback?() == true,
              player.timeControlStatus == .playing else { return }
        manualRequest = .issued
        if !pictureInPicture.requestManualStart() {
            onUnavailable?()
        }
    }

    private func startPreparedPlayback() {
        guard prepared, !startupPending, !pictureInPicture.ending, startup.stage != .restoring,
              canUsePreparedItem?() == true else { return }
        startup.begin(at: ProcessInfo.processInfo.systemUptime)
        player.play()
        armStartupDeadline()
    }

    private func armStartupDeadline() {
        startupTask?.cancel()
        guard let token = startup.token, let deadline = startup.deadline else { return }
        let generation = generation
        let remaining = max(0, deadline - ProcessInfo.processInfo.systemUptime)
        startupTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
            guard let self, self.generation == generation, self.prepared,
                  self.startup.expiration(for: token, at: ProcessInfo.processInfo.systemUptime) != nil,
                  !self.pictureInPicture.ending else { return }
            self.onUnavailable?()
        }
    }

    private func systemDidStart() {
        guard prepared, !pictureInPicture.ending, startup.stage != .restoring else { return }
        guard let item = player.currentItem, item === validatedItem, itemReady,
              isCompatibleVideo(item), canUsePreparedItem?() == true else {
            onUnavailable?()
            return
        }
        guard manualRequest == .issued, startupPending else {
            onUnavailable?()
            return
        }
        startupTask?.cancel()
        startupTask = nil
        startup.didStart()
        claimPiPIfPlaying()
        // Only actual playback still pending may use the remainder of the same deadline.
        if prepared, startup.stage == .active { armStartupDeadline() }
    }

    private func systemWillReturn(wasPlaying: Bool) {
        playAfterReturn = wasPlaying
        systemWillStop()
    }

    private func systemWillStop() {
        manualRequestInProgress = false
        startup.returning()
        startupTask?.cancel()
        startupTask = nil
    }

    func cancelPendingStart() {
        objectWillChange.send()
        guard manualRequest == nil else { return }
        guard prepared, startupPending, !pipActive, !pictureInPicture.starting else { return }
        startup.cancel()
        startupTask?.cancel()
        startupTask = nil
        player.pause()
    }

    private func transition(to next: DYLivePiPPhase) {
        guard phase != next else { return }
        phase = next
    }

    /// 接管：AVPlayer 已经静音在播，先停 VLC（停掉后它排队的回调全部作废），同一刻打开 AVPlayer 的声音。
    func claimAudibleOwner(generation: UUID, roomID: String,
                           vlc: VLCPlayerController,
                           userMuted: Bool) {
        guard prepared, pipActive,
              DYLivePiPPolicy.acceptsCallback(current: self.generation, event: generation,
                                        ownerRoom: self.roomID, eventRoom: roomID) else { return }
        startupTask?.cancel()
        startupTask = nil
        startup.claimed()
        manualRequestInProgress = false
        self.vlc = vlc
        self.userMuted = userMuted
        recoveredUnexplainedPause = false
        vlc.outputMuted = true
        vlc.mediaPlayer.audio?.isMuted = true
        vlc.stop()
        player.isMuted = userMuted
        if player.rate == 0 { player.play() }
        audibleOwner = DYLivePiPPolicy.owner(after: .claim, from: audibleOwner)
        transition(to: .takenOver)
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            do { try await Task.sleep(for: DYLivePiPPolicy.handoffSettleLimit) } catch { return }
            self?.settleHandoff(generation: generation)
        }
    }

    private func settleHandoff(generation: UUID) {
        guard phase == .takenOver, !pipWantsAttach, self.generation == generation else { return }
        settleTask?.cancel()
        settleTask = nil
        pipWantsAttach = true
        syncPictureInPictureAttachment()
    }

    func releaseAudibleOwner(generation: UUID, roomID: String,
                             userMuted: Bool,
                             foregroundOutputMuted: Bool) {
        guard DYLivePiPPolicy.acceptsCallback(current: self.generation, event: generation,
                                        ownerRoom: self.roomID, eventRoom: roomID) else { return }
        settleTask?.cancel()
        settleTask = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        pictureInPicture.invalidate()
        pipWantsAttach = false
        audibleOwner = DYLivePiPPolicy.owner(after: .release, from: audibleOwner)
        if let vlc {
            vlc.outputMuted = foregroundOutputMuted
            vlc.mediaPlayer.audio?.isMuted = foregroundOutputMuted
            _ = userMuted
        }
        transition(to: .idle)
        statusObservation?.invalidate()
        statusObservation = nil
        readyObservation?.invalidate()
        readyObservation = nil
        liveWindowObservation?.invalidate()
        liveWindowObservation = nil
    }

    func setMuted(_ muted: Bool) {
        userMuted = muted
        guard isAudibleOwner else { return }
        player.isMuted = muted
    }

    func stopForBackgroundWithoutPiP() {
        guard hasTakenOver, !pipActive else { return }
        player.pause()
        player.rate = 0
    }

    func syncPictureInPictureAttachment() {
        guard prepared || (pipWantsAttach && isAudibleOwner && player.rate > 0) else { return }
        pictureInPicture.attach(to: playerLayer, enabled: true, automaticallyFromInline: false,
                                onBackgroundClose: { [weak self] in
                                    guard let self else { return }
                                    self.onBackgroundClose?()
                                },
                                onUnavailable: { [weak self] in
                                    guard let self else { return }
                                    self.onUnavailable?()
                                },
                                onResume: { [weak self] in
                                    self?.resumeAfterPictureInPictureStart()
                                },
                                onStarted: { [weak self] in
                                    self?.systemDidStart()
                                },
                                onWillReturn: { [weak self] wasPlaying in
                                    self?.systemWillReturn(wasPlaying: wasPlaying)
                                },
                                onWillStop: { [weak self] in
                                    self?.systemWillStop()
                                },
                                onReturned: onReturned,
                                canRestore: { [weak self] in
                                    guard let self else { return false }
                                    return self.canUsePreparedItem?() == true && self.player.currentItem != nil
                                        && self.inlineView?.window != nil
                                })
    }

    /// 离开时在播、系统画中画起来时却停着（接管后 VLC 停止带来的无原因暂停落在离开途中）：接着播。
    private func resumeAfterPictureInPictureStart() {
        guard phase == .takenOver, player.rate == 0, let item = player.currentItem else { return }
        if let loaded = item.loadedTimeRanges.last?.timeRangeValue, loaded.duration.seconds > 0 {
            playInsideLiveWindow(item: item, loaded: loaded, generation: generation, phase: .takenOver)
        } else {
            player.play()
        }
    }

    /// AVPlayer 已接管时，和短视频一样记下离开前在播。
    private func notePlayingOnExit() {
        objectWillChange.send()
        guard hasTakenOver || startupPending else { return }
        pictureInPicture.notePlayingOnExit()
    }

    func invalidate() {
        statusObservation?.invalidate()
        statusObservation = nil
        readyObservation?.invalidate()
        readyObservation = nil
        liveWindowObservation?.invalidate()
        liveWindowObservation = nil
        settleTask?.cancel()
        settleTask = nil
        startupTask?.cancel()
        startupTask = nil
        startup.cancel()
        validatedItem = nil
        player.isMuted = true
        manualRequest = nil
        manualRequestInProgress = false
        pictureInPicture.invalidate()
        player.cancelPendingPrerolls()
        player.currentItem?.cancelPendingSeeks()
        player.pause()
        player.replaceCurrentItem(with: nil)
        transition(to: .idle)
        generation = UUID()
        roomID = nil
        vlc = nil
        audibleOwner = .none
        pipWantsAttach = false
        recoveredUnexplainedPause = false
        onReady = nil
        onPlaying = nil
        onPrepFailed = nil
        onBackgroundClose = nil
        onUnavailable = nil
        onReturned = nil
        canUsePreparedItem = nil
        canStartPreparedPlayback = nil
    }

    private func observeItem(_ item: AVPlayerItem, generation: UUID, roomID: String) {
        statusObservation?.invalidate()
        readyObservation?.invalidate()
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self, self.player.currentItem === item,
                      DYLivePiPPolicy.acceptsCallback(current: self.generation, event: generation,
                                                ownerRoom: self.roomID, eventRoom: roomID) else { return }
                self.objectWillChange.send()
                if item.status == .failed {
                    let error = item.error as NSError?
                    if self.preparing {
                        self.onPrepFailed?(DYLivePiPPolicy.itemFailure(errorDomain: error?.domain))
                    } else {
                        self.onUnavailable?()
                    }
                } else if item.status == .readyToPlay {
                    if self.phase == .preparing, self.warmsOnItemReady, self.player.currentItem === item {
                        self.onReady?()
                    } else {
                        self.prerollIfPreparing(item)
                    }
                }
            }
        }
        readyObservation = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
            Task { @MainActor [weak self] in
                guard let self, self.player.currentItem === item,
                      DYLivePiPPolicy.acceptsCallback(current: self.generation, event: generation,
                                                ownerRoom: self.roomID, eventRoom: roomID) else { return }
                self.objectWillChange.send()
                guard layer.isReadyForDisplay else { return }
                if self.phase == .preparing {
                    self.onReady?()
                } else if self.phase == .warming {
                    self.warmupReachedPlayback()
                } else if self.prepared {
                    self.issueManualRequestIfReady()
                    self.claimPiPIfPlaying()
                }
                self.syncPictureInPictureAttachment()
            }
        }
    }

    /// 暂停的 AVPlayer 不会自己解第一帧（短视频预热同样如此）；preroll 让首帧进到画面层，rate 仍为 0。
    private func prerollIfPreparing(_ item: AVPlayerItem) {
        guard phase == .preparing, player.currentItem === item, player.rate == 0,
              player.status == .readyToPlay else { return }
        player.preroll(atRate: 1, completionHandler: nil)
    }

    /// AVPlayer 在试播或接管后被系统不带原因地停下（暂停预备的播放头停在 0，不在直播窗口里时会这样）。
    /// 每次试播、每次接管各补救一次：等直播窗口加载出来，播放头在窗口里就原地继续，否则跳到系统给的直播位置。
    /// 我们自己、后台和音频打断造成的暂停都带原因，不碰。
    private func recoverUnexplainedPause(hasReason: Bool) {
        let visible = UIApplication.shared.applicationState == .active
            || pictureInPicture.active || pictureInPicture.starting
        guard DYLivePiPPolicy.recoversUnexplainedPause(hasReason: hasReason, rate: player.rate, phase: phase,
                                                       visible: visible,
                                                       alreadyRecovered: recoveredUnexplainedPause),
              let item = player.currentItem else { return }
        recoveredUnexplainedPause = true
        let generation = self.generation
        let recoveringPhase = phase
        liveWindowObservation = item.observe(\.loadedTimeRanges, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation, self.phase == recoveringPhase,
                      self.player.currentItem === item, self.liveWindowObservation != nil,
                      let loaded = item.loadedTimeRanges.last?.timeRangeValue, loaded.duration.seconds > 0 else { return }
                self.liveWindowObservation?.invalidate()
                self.liveWindowObservation = nil
                self.playInsideLiveWindow(item: item, loaded: loaded, generation: generation, phase: recoveringPhase)
            }
        }
    }

    /// 播放头在已加载窗口里就原地 play；否则先跳到系统的直播位置再 play。跳转回来时代或阶段变了就不播。
    private func playInsideLiveWindow(item: AVPlayerItem, loaded: CMTimeRange, generation: UUID, phase expected: DYLivePiPPhase) {
        let position = DYLivePiPPolicy.resumePosition(
            current: item.currentTime().seconds,
            loadedStart: loaded.start.seconds, loadedEnd: loaded.end.seconds,
            livePoint: item.seekableTimeRanges.last?.timeRangeValue.end.seconds)
        guard case .seek(let seconds) = position else {
            player.play()
            if expected == .takenOver { settleHandoff(generation: generation) }
            return
        }
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .positiveInfinity) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation, self.phase == expected,
                      self.player.currentItem === item else { return }
                self.player.play()
                if expected == .takenOver { self.settleHandoff(generation: generation) }
            }
        }
    }

}

struct DYLivePiPVideoSurface: UIViewRepresentable {
    @ObservedObject var session: DYLivePiPSession

    func makeUIView(context: Context) -> DYLivePiPPlayerUIView {
        let view = DYLivePiPPlayerUIView(playerLayer: session.playerLayer)
        session.noteInlineView(view)
        return view
    }

    func updateUIView(_ uiView: DYLivePiPPlayerUIView, context: Context) {
        session.syncPictureInPictureAttachment()
    }
}

final class DYLivePiPPlayerUIView: UIView {
    private let embeddedLayer: AVPlayerLayer

    init(playerLayer: AVPlayerLayer) {
        embeddedLayer = playerLayer
        super.init(frame: .zero)
        backgroundColor = .black
        layer.addSublayer(playerLayer)
        playerLayer.videoGravity = .resizeAspect
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        embeddedLayer.frame = bounds
    }
}
