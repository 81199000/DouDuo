import AVKit
import Combine
import UIKit

/// One controller for the current inline AVPlayer layer. Clean-screen mode
/// opts into the system's automatic PiP transition; ordinary playback keeps
/// the app's existing pause-on-exit policy.
@MainActor
final class DYPictureInPicture: NSObject, ObservableObject, @MainActor AVPictureInPictureControllerDelegate {
    @Published private(set) var active = false
    @Published private(set) var canStart = false
    let supported = AVPictureInPictureController.isPictureInPictureSupported()
    private var controller: AVPictureInPictureController?
    private var possibleObservation: NSKeyValueObservation?
    private var generation = UUID()
    private weak var layer: AVPlayerLayer?
    private var enabled = false
    private(set) var starting = false
    private(set) var awaitingClose = false
    private var restoring = false
    private var stopping = false
    private var playingAtStop: Bool?
    var ending: Bool { restoring || stopping || awaitingClose }
    private var onWillStop: (() -> Void)?
    private var onWillReturn: ((Bool) -> Void)?
    private var fallbackTask: Task<Void, Never>?
    private var closeCheck: Task<Void, Never>?
    private var playingWhenLeaving = false
    private var onBackgroundClose: (() -> Void)?
    private var onUnavailable: (() -> Void)?
    private var onResume: (() -> Void)?
    private var onStarted: (() -> Void)?
    private var onReturned: (() -> Void)?
    private var canRestore: (() -> Bool)?
    private var manualStartIssued = false
    private let cancelledManualControllers = NSHashTable<AVPictureInPictureController>.weakObjects()
    var controllerPossible: Bool { controller?.isPictureInPicturePossible == true }

    /// Only call from a foreground user gesture while the same prepared layer is still eligible.
    func requestManualStart() -> Bool {
        guard enabled, !active, !starting, !manualStartIssued, !ending,
              UIApplication.shared.applicationState == .active,
              let controller, controller.isPictureInPicturePossible, !controller.isPictureInPictureActive,
              layer?.isReadyForDisplay == true, layer?.player?.timeControlStatus == .playing else { return false }
        manualStartIssued = true
        controller.startPictureInPicture()
        return true
    }


    var keepsVideoLayer: Bool { enabled || active || starting }
    var keepsPlaybackOnExit: Bool {
        active || starting || (enabled && controller?.isPictureInPicturePossible == true && (layer?.player?.rate ?? 0) > 0)
    }

    func attach(to layer: AVPlayerLayer, enabled: Bool, automaticallyFromInline: Bool = true,
                onBackgroundClose: @escaping () -> Void,
                onUnavailable: @escaping () -> Void,
                onResume: @escaping () -> Void = {},
                onStarted: (() -> Void)? = nil,
                onWillReturn: ((Bool) -> Void)? = nil,
                onWillStop: (() -> Void)? = nil,
                onReturned: (() -> Void)? = nil,
                canRestore: (() -> Bool)? = nil) {
        if self.layer !== layer {
            invalidate()
            self.layer = layer
        }
        self.onBackgroundClose = onBackgroundClose
        self.onUnavailable = onUnavailable
        self.onResume = onResume
        self.onStarted = onStarted
        self.onWillReturn = onWillReturn
        self.onWillStop = onWillStop
        self.onReturned = onReturned
        self.canRestore = canRestore
        if enabled, controller == nil, supported {
            controller = AVPictureInPictureController(playerLayer: layer)
            controller?.delegate = self
            let currentGeneration = generation
            possibleObservation = controller?.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] _, change in
                let possible = change.newValue ?? false
                Task { @MainActor [weak self] in
                    guard let self, self.generation == currentGeneration else { return }
                    self.canStart = possible
                }
            }
        }
        #if DEBUG
        if self.enabled != enabled {
            ddWrite("DDPIP enabled=\(enabled) controller=\(controller != nil) supported=\(AVPictureInPictureController.isPictureInPictureSupported()) ready=\(layer.isReadyForDisplay) rate=\(layer.player?.rate ?? -1)")
        }
        #endif
        self.enabled = enabled
        controller?.canStartPictureInPictureAutomaticallyFromInline = enabled && automaticallyFromInline
        if !enabled {
            fallbackTask?.cancel()
            playingWhenLeaving = false
            if active || starting { controller?.stopPictureInPicture() }
        }
        if onStarted != nil, !keepsVideoLayer {
            releaseController()
        }
    }

    /// 离开前台、决定不暂停内联时调用：记下当时在播，系统画中画起来后据此校正。
    func notePlayingOnExit() {
        guard enabled, !active, !starting, (layer?.player?.rate ?? 0) > 0 else { return }
        playingWhenLeaving = true
    }

    func didEnterBackground() {
        fallbackTask?.cancel()
        guard enabled else { return }
        // If iOS declines automatic PiP (for example, the system setting is
        // disabled), fall back to the normal pause policy instead of audio-only
        // playback. No delayed task may survive a return to the foreground.
        fallbackTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(1500)) } catch { return }
            guard let self, UIApplication.shared.applicationState == .background, self.onStarted == nil || !self.ending,
                  !self.active, !self.starting || self.onStarted != nil else { return }
            self.playingWhenLeaving = false
            self.onUnavailable?()
        }
    }

    func returnToInline() {
        fallbackTask?.cancel()
        closeCheck?.cancel()
        playingWhenLeaving = false
        if active || starting {
            if !restoring { onWillReturn?(playingAtStop ?? ((layer?.player?.rate ?? 0) > 0)) }
            restoring = true
            controller?.stopPictureInPicture()
        }
    }

    func invalidate() {
        fallbackTask?.cancel()
        closeCheck?.cancel()
        let explicitController = manualStartIssued ? controller : nil
        manualStartIssued = false
        if let explicitController {
            // Drop ownership first so a callback from a cancelled request cannot claim this room.
            cancelledManualControllers.add(explicitController)
            releaseController(retainingDelegate: true)
            explicitController.stopPictureInPicture()
        } else {
            let previous = controller
            releaseController()
            if previous?.isPictureInPictureActive == true { previous?.stopPictureInPicture() }
        }
        layer = nil
        enabled = false
        starting = false
        restoring = false
        awaitingClose = false
        playingWhenLeaving = false
        if active { active = false }
        onBackgroundClose = nil
        onUnavailable = nil
        onResume = nil
        onStarted = nil
        onWillReturn = nil
        onWillStop = nil
        stopping = false
        playingAtStop = nil
        onReturned = nil
        canRestore = nil
    }

    private func releaseController(retainingDelegate: Bool = false) {
        guard controller != nil else { return }
        possibleObservation?.invalidate()
        possibleObservation = nil
        generation = UUID()
        if canStart { canStart = false }
        controller?.canStartPictureInPictureAutomaticallyFromInline = false
        if !retainingDelegate { controller?.delegate = nil }
        controller = nil
    }

    func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        guard self.controller === controller else { return }
        starting = true
        restoring = false
        stopping = false
        playingAtStop = nil
        awaitingClose = false
        closeCheck?.cancel()
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        guard self.controller === controller else {
            if cancelledManualControllers.contains(controller) {
                cancelledManualControllers.remove(controller)
                controller.delegate = nil
                controller.stopPictureInPicture()
            }
            return
        }
        starting = false
        active = true
        fallbackTask?.cancel()
        if onStarted != nil, ending {
            controller.stopPictureInPicture()
            return
        }
        let paused = layer?.player?.timeControlStatus == .paused
        onStarted?()
        if playingWhenLeaving && paused {
            onResume?()
        }
        playingWhenLeaving = false
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        guard self.controller === controller else { return }
        starting = false
        active = false
        playingWhenLeaving = false
        #if DEBUG
        let failure = error as NSError
        ddWrite("DDPIP failed \(failure.domain) \(failure.code)")
        #endif
        if onStarted != nil || UIApplication.shared.applicationState == .background { onUnavailable?() }
    }

    func pictureInPictureControllerWillStopPictureInPicture(_ controller: AVPictureInPictureController) {
        guard self.controller === controller, onStarted != nil else { return }
        fallbackTask?.cancel()
        stopping = true
        playingAtStop = (layer?.player?.rate ?? 0) > 0
        onWillStop?()
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        guard self.controller === controller else { return }
        stopping = false
        starting = false
        active = false
        guard onStarted != nil else {
            if !restoring, UIApplication.shared.applicationState == .background { onBackgroundClose?() }
            restoring = false
            return
        }
        layer?.player?.isMuted = true
        let wasRestoring = restoring
        restoring = false
        if wasRestoring {
            onReturned?()
            return
        }
        // Give a foreground restore time to cancel the pending live-room close.
        closeCheck?.cancel()
        awaitingClose = true
        closeCheck = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            guard let self, self.controller === controller else { return }
            self.awaitingClose = false
            self.onBackgroundClose?()
        }
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        guard self.controller === controller, canRestore?() != false else {
            completionHandler(false)
            return
        }
        fallbackTask?.cancel()
        if !restoring { onWillReturn?(playingAtStop ?? ((layer?.player?.rate ?? 0) > 0)) }
        restoring = true
        completionHandler(true)
    }
}
