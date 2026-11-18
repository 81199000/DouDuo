import Foundation

/// Short-video preference; clean-screen mode retains its existing PiP behavior.
enum DYAutoPiP {
    static let storageKey = "douyin_auto_pip_v1"

    static func enabled(in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: storageKey)
    }

    static func shortVideoWantsAutomaticPiP(preference: Bool, cleanScreen: Bool, isActive: Bool) -> Bool {
        isActive && (cleanScreen || preference)
    }

    /// System PiP controls the AVPlayer audio track, including pause/resume.
    static func requiresNativeAudio(preference: Bool, cleanScreen: Bool) -> Bool {
        cleanScreen || preference
    }

    static func keepsPiPController(enabled: Bool, active: Bool, starting: Bool) -> Bool {
        enabled || active || starting
    }
}
