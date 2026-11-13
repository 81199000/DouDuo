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
    private var starting = false
    private var restoring = false
    private var fallbackTask: Task<Void, Never>?
    private var onBackgroundClose: (() -> Void)?
    private var onUnavailable: (() -> Void)?

    var keepsVideoLayer: Bool { enabled || active || starting }
    var keepsPlaybackOnExit: Bool {
        active || starting || (enabled && controller?.isPictureInPicturePossible == true && (layer?.player?.rate ?? 0) > 0)
    }

    func attach(to layer: AVPlayerLayer, enabled: Bool,
                onBackgroundClose: @escaping () -> Void,
                onUnavailable: @escaping () -> Void) {
        self.onBackgroundClose = onBackgroundClose
        self.onUnavailable = onUnavailable
        if self.layer !== layer {
            invalidate()
            self.layer = layer
        }
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
        controller?.canStartPictureInPictureAutomaticallyFromInline = enabled
        if !enabled {
            fallbackTask?.cancel()
            if active || starting { controller?.stopPictureInPicture() }
        }
    }

    func didEnterBackground() {
        fallbackTask?.cancel()
        guard enabled else { return }
        // If iOS declines automatic PiP (for example, the system setting is
        // disabled), fall back to the normal pause policy instead of audio-only
        // playback. No delayed task may survive a return to the foreground.
        fallbackTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(1500)) } catch { return }
            guard let self, UIApplication.shared.applicationState == .background,
                  !self.active, !self.starting else { return }
            self.onUnavailable?()
        }
    }

    func returnToInline() {
        fallbackTask?.cancel()
        if active || starting {
            restoring = true
            controller?.stopPictureInPicture()
        }
    }

    func invalidate() {
        fallbackTask?.cancel()
        possibleObservation?.invalidate()
        possibleObservation = nil
        generation = UUID()
        if canStart { canStart = false }
        controller?.canStartPictureInPictureAutomaticallyFromInline = false
        controller?.delegate = nil
        if controller?.isPictureInPictureActive == true { controller?.stopPictureInPicture() }
        controller = nil
        layer = nil
        enabled = false
        starting = false
        restoring = false
        if active { active = false }
    }

    func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        starting = true
        restoring = false
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        starting = false
        active = true
        fallbackTask?.cancel()
        #if DEBUG
        ddWrite("DDPIP started")
        #endif
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        starting = false
        active = false
        #if DEBUG
        ddWrite("DDPIP failed \(error.localizedDescription)")
        #endif
        if UIApplication.shared.applicationState == .background { onUnavailable?() }
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        starting = false
        active = false
        #if DEBUG
        ddWrite("DDPIP stopped restoring=\(restoring)")
        #endif
        if !restoring, UIApplication.shared.applicationState == .background { onBackgroundClose?() }
        restoring = false
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        restoring = true
        // The same video page remains mounted in the same NavigationStack.
        completionHandler(true)
    }
}
