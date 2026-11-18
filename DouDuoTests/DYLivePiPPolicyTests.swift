import CoreGraphics
import Foundation
import Testing

@Suite("直播画中画准备")
struct DYLivePiPPreparationTests {
    private func decision(vlcPlaysFLV: Bool = true, vlcQuality: String? = "HD1",
                          hlsQualities: Set<String> = ["HD1"],
                          vlcShowsPicture: Bool = true, handoffInProgress: Bool = false,
                          appActive: Bool = true, coverHold: Bool = false) -> DYLiveHandoffDecision {
        DYLivePiPPolicy.handoffDecision(vlcPlaysFLV: vlcPlaysFLV, vlcQuality: vlcQuality,
                                        hlsQualities: hlsQualities, vlcShowsPicture: vlcShowsPicture,
                                        handoffInProgress: handoffInProgress, appActive: appActive, coverHold: coverHold)
    }

    @Test func liveHandoffPreparesOnlyAfterVLCShowsAPicture() {
        #expect(decision(vlcShowsPicture: false) == .skip(.vlcNotShowingPicture))
        #expect(decision(vlcShowsPicture: true) == .prepare(quality: "HD1", warmsOnItemReady: false))
    }

    @Test func liveHandoffNeverPreparesTwiceOrOffscreen() {
        #expect(decision(handoffInProgress: true) == .skip(.busy))
        #expect(decision(appActive: false) == .skip(.notForeground))
        #expect(decision(coverHold: true) == .skip(.notForeground))
    }

    @Test func liveHandoffStaysOnVLCWithoutHLS() {
        #expect(decision(hlsQualities: []) == .skip(.noHLS))
    }

    @Test func hlsOnlyRoomPreparesTheSameQualityAndWarmsOnItemReady() {
        #expect(decision(vlcPlaysFLV: false) == .prepare(quality: "HD1", warmsOnItemReady: true))
        #expect(decision(vlcPlaysFLV: false, vlcQuality: "FULL_HD1", hlsQualities: ["HD1", "FULL_HD1"])
                == .prepare(quality: "FULL_HD1", warmsOnItemReady: true))
    }

    @Test func liveHandoffNeverSwitchesQuality() {
        #expect(decision(vlcQuality: "FULL_HD1", hlsQualities: ["HD1"]) == .skip(.hlsMissingAtQuality))
        #expect(decision(vlcPlaysFLV: false, vlcQuality: "FULL_HD1", hlsQualities: ["HD1"]) == .skip(.hlsMissingAtQuality))
        #expect(decision(vlcQuality: nil) == .skip(.hlsMissingAtQuality))
    }
}

@Suite("直播画中画就绪")
struct DYLivePiPReadinessTests {
    private func readiness(sourceExclusion: DYLiveHandoffExclusion? = nil, vlcShowsPicture: Bool = true,
                           phase: DYLivePiPPhase = .idle, possible: Bool = false,
                           attempts: DYLivePiPAttempts = DYLivePiPAttempts(),
                           retryPending: Bool = false) -> DYLivePiPReadiness {
        DYLivePiPPolicy.readiness(sourceExclusion: sourceExclusion, vlcShowsPicture: vlcShowsPicture,
                                  phase: phase, possible: possible, attempts: attempts, retryPending: retryPending)
    }

    @Test func transientFailureIsRetriedOnceThenStops() {
        var attempts = DYLivePiPAttempts()
        #expect(attempts.record(.notLoaded) == DYLivePiPAttempts.retryDelay)
        #expect(attempts.mayPrepare)
        #expect(readiness(attempts: attempts, retryPending: true) == .retrying(.notLoaded))
        #expect(readiness(phase: .preparing, attempts: attempts) == .preparing(attempt: 2))
        #expect(attempts.record(.stalled) == nil)
        #expect(attempts.mayPrepare == false)
        #expect(readiness(attempts: attempts) == .exhausted(.stalled))
    }

    @Test func incompatibleFailureIsNeverRetried() {
        for failure in [DYLivePiPPrepFailure.noPicture, .media] {
            var attempts = DYLivePiPAttempts()
            #expect(attempts.record(failure) == nil)
            #expect(attempts.unsupported)
            #expect(attempts.mayPrepare == false)
            #expect(readiness(attempts: attempts) == .unsupported(failure))
        }
    }

    @Test func timeoutIsClassifiedByHowFarPreparationGot() {
        #expect(DYLivePiPPolicy.timeoutFailure(phase: .preparing, itemReady: false, layerReady: false) == .notLoaded)
        #expect(DYLivePiPPolicy.timeoutFailure(phase: .preparing, itemReady: true, layerReady: false) == .noPicture)
        #expect(DYLivePiPPolicy.timeoutFailure(phase: .warming, itemReady: true, layerReady: true) == .stalled)
    }

    @Test func hlsWarmUpWithoutAFrameIsNotRetried() {
        #expect(DYLivePiPPolicy.timeoutFailure(phase: .warming, itemReady: true, layerReady: false) == .noPicture)
        #expect(DYLivePiPPolicy.timeoutFailure(phase: .warming, itemReady: false, layerReady: false) == .notLoaded)
        #expect(DYLivePiPPrepFailure.noPicture.isTransient == false)
    }

    @Test func itemErrorsSplitIntoNetworkAndMedia() {
        #expect(DYLivePiPPolicy.itemFailure(errorDomain: NSURLErrorDomain) == .network)
        #expect(DYLivePiPPolicy.itemFailure(errorDomain: "AVFoundationErrorDomain") == .media)
        #expect(DYLivePiPPolicy.itemFailure(errorDomain: nil) == .media)
        #expect(DYLivePiPPrepFailure.network.isTransient)
        #expect(DYLivePiPPrepFailure.media.isTransient == false)
    }

    @Test func roomSwitchOrStaleCallbackCannotDriveTheNewRoom() {
        let current = UUID()
        #expect(DYLivePiPPolicy.acceptsCallback(current: current, event: UUID(), ownerRoom: "a", eventRoom: "a") == false)
        #expect(DYLivePiPPolicy.acceptsCallback(current: current, event: current, ownerRoom: "b", eventRoom: "a") == false)
        #expect(DYLivePiPPolicy.acceptsCallback(current: current, event: current, ownerRoom: "a", eventRoom: "a"))
    }

    @Test func unexplainedStopIsRecoveredOnceInTheForeground() {
        #expect(DYLivePiPPolicy.recoversUnexplainedPause(hasReason: false, rate: 0, phase: .takenOver,
                                                         visible: true, alreadyRecovered: false))
        #expect(DYLivePiPPolicy.recoversUnexplainedPause(hasReason: false, rate: 0, phase: .warming,
                                                         visible: true, alreadyRecovered: false))
        #expect(DYLivePiPPolicy.recoversUnexplainedPause(hasReason: false, rate: 0, phase: .takenOver,
                                                         visible: true, alreadyRecovered: true) == false)
    }

    @Test func userBackgroundAndInterruptionPausesArePreserved() {
        #expect(DYLivePiPPolicy.recoversUnexplainedPause(hasReason: true, rate: 0, phase: .takenOver,
                                                         visible: true, alreadyRecovered: false) == false)
        #expect(DYLivePiPPolicy.recoversUnexplainedPause(hasReason: false, rate: 0, phase: .takenOver,
                                                         visible: false, alreadyRecovered: false) == false)
        #expect(DYLivePiPPolicy.recoversUnexplainedPause(hasReason: false, rate: 0, phase: .preparing,
                                                         visible: true, alreadyRecovered: false) == false)
        #expect(DYLivePiPPolicy.recoversUnexplainedPause(hasReason: false, rate: 0, phase: .idle,
                                                         visible: true, alreadyRecovered: false) == false)
        #expect(DYLivePiPPolicy.recoversUnexplainedPause(hasReason: false, rate: 1, phase: .takenOver,
                                                         visible: true, alreadyRecovered: false) == false)
    }

    @Test func playbackStartsInsideTheLoadedLiveWindow() {
        #expect(DYLivePiPPolicy.resumePosition(current: 12, loadedStart: 10, loadedEnd: 20, livePoint: 18) == .inPlace)
        #expect(DYLivePiPPolicy.resumePosition(current: 0, loadedStart: 10, loadedEnd: 20, livePoint: 18) == .seek(to: 18))
        #expect(DYLivePiPPolicy.resumePosition(current: 0, loadedStart: 10, loadedEnd: 20, livePoint: 40) == .seek(to: 10))
        #expect(DYLivePiPPolicy.resumePosition(current: 0, loadedStart: 10, loadedEnd: 20, livePoint: nil) == .seek(to: 10))
    }
}

@Suite("直播画中画接管")
struct DYLivePiPActivationTests {
    @Test func onlyAcceptsUnambiguousAVC() {
        let avc: UInt32 = 0x61766331
        let hevc: UInt32 = 0x68766331
        #expect(DYLivePiPPolicy.permitsPreparedVideo([avc]))
        #expect(!DYLivePiPPolicy.permitsPreparedVideo([]))
        #expect(!DYLivePiPPolicy.permitsPreparedVideo([hevc]))
        #expect(!DYLivePiPPolicy.permitsPreparedVideo([avc, hevc]))
    }
}

@Suite("直播画中画启动与返回")
struct DYLivePiPStartupTests {
    @Test func didStartThenHandoffOutlivesTheOriginalWatchdog() {
        var state = DYLivePiPStartup()
        let token = state.begin(at: 10)
        state.didStart()
        #expect(state.stage == .active)
        #expect(claim())
        state.claimed()
        #expect(state.stage == .owned)
        #expect(state.expiration(for: token, at: 45) == nil)
        #expect(!state.pending)
    }

    @Test func didStartDoesNotExtendTheOriginalDeadlineWhenPlaybackIsStillWaiting() {
        var state = DYLivePiPStartup()
        let token = state.begin(at: 10)
        state.didStart()
        #expect(state.deadline == 15)
        #expect(state.expiration(for: token, at: 14.9) == nil)
        #expect(state.expiration(for: token, at: 15) == .playback)
    }

    @Test func failedStartKeepsTheExistingVLCOwner() {
        var state = DYLivePiPStartup()
        let token = state.begin(at: 1)
        #expect(state.expiration(for: token, at: 6) == .activation)
        #expect(!claim(active: false))
        state.cancel()
        #expect(state.expiration(for: token, at: 8) == nil)
    }

    @Test func returnOrCloseCancelsPendingHandoffBeforeTheDeadline() {
        for afterStart in [false, true] {
            var state = DYLivePiPStartup()
            let token = state.begin(at: 10)
            if afterStart { state.didStart() }
            state.returning()
            state.didStart() // A late delegate cannot resurrect a closing attempt.
            #expect(state.stage == .restoring)
            #expect(state.expiration(for: token, at: 15) == nil)
            #expect(!claim(ending: true))
            state.cancel()
            #expect(state.stage == .idle)
        }
    }

    @Test func staleWatchdogCannotDestroyARepeatedSession() {
        var state = DYLivePiPStartup()
        var last: UUID?
        for cycle in 0..<5 {
            let now = Double(cycle * 20)
            let token = state.begin(at: now)
            if let last { #expect(state.expiration(for: last, at: now + 10) == nil) }
            state.didStart()
            state.claimed()
            #expect(state.expiration(for: token, at: now + 35) == nil)
            state.returning()
            state.cancel()
            last = token
        }
    }

    @Test(arguments: Array(0..<128))
    func postStartValidationKeepsEveryIndependentSafetyGate(_ bits: Int) {
        #expect(DYLivePiPPolicy.canClaimPreparedPiP(
            systemActive: bits & 1 != 0, playing: bits & 2 != 0,
            itemReady: bits & 4 != 0, validatedItem: bits & 8 != 0,
            compatibleVideo: bits & 16 != 0, sourceCurrent: bits & 32 != 0,
            ending: bits & 64 != 0) == (bits == 63))
    }

    @Test func audioClaimIsIdempotentAndReturnPreservesPause() {
        let owner = DYLivePiPPolicy.owner(after: .claim, from: .vlc)
        #expect(owner == .avPlayer)
        #expect(DYLivePiPPolicy.owner(after: .claim, from: owner) == owner)
        #expect(DYLivePiPPolicy.returnAction(hadTakenOver: true, wasPlaying: true) == .reconnectVLC)
        #expect(DYLivePiPPolicy.returnAction(hadTakenOver: true, wasPlaying: false) == .stayPaused)
        #expect(DYLivePiPPolicy.returnAction(hadTakenOver: false, wasPlaying: true) == .resumeExistingVLC)
        #expect(DYLivePiPPolicy.returnAction(hadTakenOver: false, wasPlaying: false) == .stayPaused)
    }
}

private func claim(active: Bool = true, playing: Bool = true, ending: Bool = false) -> Bool {
    DYLivePiPPolicy.canClaimPreparedPiP(systemActive: active, playing: playing,
        itemReady: true, validatedItem: true, compatibleVideo: true, sourceCurrent: true, ending: ending)
}

@Suite("暂停返回与加载状态")
struct DYLivePausedReturnTests {
    @Test(arguments: Array(0..<8))
    func staleIdentityCannotPauseAnotherSession(_ bits: Int) {
        let current = UUID(), stale = UUID()
        var state = DYLivePausedReturn()
        state.hold(roomID: "room-a", generation: current)
        #expect(state.holds(currentRoom: bits & 1 != 0 ? "room-a" : "room-b",
                            sourceRoom: bits & 2 != 0 ? "room-a" : "room-b",
                            generation: bits & 4 != 0 ? current : stale) == (bits == 7))
    }

    @Test func pausedOverlayDoesNotPretendAFrameIsReady() {
        #expect(DYLivePlaybackOverlay.resolve(ready: false, hasError: false, paused: true) == .paused)
        // A stale ready/error update must not turn this user's paused session into a spinner or picture.
        #expect(DYLivePlaybackOverlay.resolve(ready: true, hasError: false, paused: true) == .paused)
        #expect(DYLivePlaybackOverlay.resolve(ready: false, hasError: true, paused: true) == .paused)
    }

    @Test(arguments: Array(0..<4))
    func ordinaryLoadingAndErrorBehaviorIsPreserved(_ bits: Int) {
        let ready = bits & 1 != 0, failed = bits & 2 != 0
        let expected: DYLivePlaybackOverlay = failed ? .failed : ready ? .none : .connecting
        #expect(DYLivePlaybackOverlay.resolve(ready: ready, hasError: failed, paused: false) == expected)
    }
}

@Suite("手动直播画中画")
struct DYManualLivePiPTests {
    @Test func onlyActualReadyCanStart() {
        #expect(DYLivePiPPolicy.manualUnavailableMessage(readiness: .ready) == nil)
        for readiness: DYLivePiPReadiness in [.excluded(.noHLS), .waitingForPicture,
                .preparing(attempt: 1), .warming, .controllerPending, .retrying(.network),
                .unsupported(.noPicture), .exhausted(.stalled), .idle] {
            #expect(DYLivePiPPolicy.manualUnavailableMessage(readiness: readiness) != nil)
        }
    }
}

@Suite("手动画中画状态指示")
struct DYManualPiPIndicatorTests {
    private func indicator(_ readiness: DYLivePiPReadiness) -> DYLivePiPIndicator? {
        DYLivePiPPolicy.indicator(readiness: readiness, current: true, active: false, pending: false)
    }

    @Test func upcomingAndTerminalStates() {
        for state: DYLivePiPReadiness in [.idle, .waitingForPicture, .excluded(.noHLS)] {
            #expect(indicator(state) == nil)
        }
        for state: DYLivePiPReadiness in [.preparing(attempt: 1), .warming, .controllerPending,
                                       .retrying(.network), .resolvingDetail] {
            #expect(indicator(state) == .preparing)
        }
        #expect(indicator(.unsupported(.noPicture)) == .failed)
        #expect(indicator(.exhausted(.stalled)) == .failed)
        #expect(indicator(.ready) == .ready)
    }

    @Test(arguments: Array(0..<8))
    func onlyCurrentInlineSessionShowsStatus(_ flags: Int) {
        for state: DYLivePiPReadiness in [.ready, .warming, .exhausted(.stalled)] {
            let shown = DYLivePiPPolicy.indicator(readiness: state, current: flags & 1 != 0,
                active: flags & 2 != 0, pending: flags & 4 != 0)
            #expect((shown != nil) == (flags == 1))
        }
    }
}

@Suite("READY 与主播信息避让")
struct DYReadyBadgePlacementTests {
    @Test func measuredInnerHeaderMovesBadgeBelowAvatar() {
        let video = CGRect(x: 0, y: 0, width: 680, height: 600)
        let header = CGRect(x: 18, y: 70, width: 640, height: 50)
        let top = DYLivePiPBadgePlacement.topInset(video: video, header: header)
        #expect(top == 126)
        #expect(top.map { $0 >= header.maxY + 6 } == true)
    }
    @Test func crampedVideoNeverOverlapsHeaderOrClipsBadge() {
        #expect(DYLivePiPBadgePlacement.topInset(video: CGRect(x: 0, y: 0, width: 320, height: 140),
            header: CGRect(x: 0, y: 0, width: 320, height: 120)) == nil)
        #expect(DYLivePiPBadgePlacement.topInset(video: CGRect(x: 0, y: 0, width: 320, height: 100), header: .null) == nil)
    }
    @Test func preparingLabelFitsAndAvoidsTheRightEdgeOfTheHeader() {
        let pane = CGRect(x: 0, y: 0, width: 320, height: 400)
        let header = CGRect(x: 94, y: 106, width: 40, height: 30)
        #expect(DYLivePiPBadgePlacement.topInset(video: pane, header: header) == 142)
        #expect(DYLivePiPBadgePlacement.topInset(video: CGRect(x: 0, y: 0, width: 119, height: 400),
            header: .null) == nil)
    }
}
