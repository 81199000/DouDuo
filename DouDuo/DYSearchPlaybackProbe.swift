#if DEBUG
import SwiftUI

/// Opt-in UI regression probe: reads the real players, including covered pages.
/// No media or account data is captured, and this code is absent from Release.
@MainActor
enum DYSearchPlaybackProbe {
    static var enabled: Bool { ProcessInfo.processInfo.environment["DOUDUO_PLAYBACK_FIXTURE"] == "1" }
    static var readers: [UUID: () -> [String: Any]] = [:]
    static var appearances: [String: Int] = [:]
    static var disappearances: [String: Int] = [:]

    static func register(_ instance: UUID, id: String, read: @escaping () -> [String: Any]) {
        guard enabled else { return }
        readers[instance] = read
        appearances[id, default: 0] += 1
    }

    static func unregister(_ instance: UUID, id: String) {
        guard enabled else { return }
        readers[instance] = nil
        disappearances[id, default: 0] += 1
    }

    static func snapshot() -> String {
        let payload: [String: Any] = ["players": readers.values.map { $0() },
                                      "appearances": appearances, "disappearances": disappearances]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

struct DYSearchPlaybackProbeView: View {
    @State private var snapshot = "{}"

    var body: some View {
        if DYSearchPlaybackProbe.enabled {
            Text(snapshot).font(.caption2).lineLimit(1).frame(width: 1, height: 1).opacity(0.01)
                .accessibilityIdentifier("douyin.search.playbackProbe")
                .allowsHitTesting(false)
                .onReceive(Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()) { _ in
                    snapshot = DYSearchPlaybackProbe.snapshot()
                }
        }
    }
}
#endif
