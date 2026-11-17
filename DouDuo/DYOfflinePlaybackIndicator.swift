import SwiftUI

struct DYOfflinePlaybackIndicator: View {
    let position: Int
    let total: Int

    var body: some View {
        DYPlaybackBadge(title: .offline, detail: "\(position)/\(total)")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("离线视频")
            .accessibilityValue("\(position)/\(total)")
            .accessibilityIdentifier("douyin.video.offlineIndicator")
    }
}

struct DYPlaybackBadge: View {
    enum Title {
        case offline
        case speed(String)
    }

    let title: Title
    let detail: String?
    var showsLockInstructions = false

    var body: some View {
        ZStack(alignment: .leading) {
            if !showsLockInstructions {
                VStack(alignment: .leading, spacing: 2) {
                    Self.offlineTitle.font(.caption.weight(.bold))
                    Text("下滑锁定倍速").font(.system(size: 9))
                }
                .hidden()
                .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 2) {
                titleContent.font(.caption.weight(.bold)).monospacedDigit()
                if let detail {
                    Text(detail).font(.system(size: 9)).monospacedDigit().opacity(0.85)
                }
            }
        }
        .fixedSize()
        .foregroundStyle(.white)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.black.opacity(0.45), in: .capsule)
    }

    @ViewBuilder private var titleContent: some View {
        switch title {
        case .offline:
            Self.offlineTitle
        case let .speed(rate):
            Text(rate).accessibilityIdentifier("douyin.rateBadge")
        }
    }

    private static var offlineTitle: some View {
        Label("离线视频", systemImage: "airplane")
    }
}

extension View {
    func dyPlaybackHintStyle() -> some View {
        padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .environment(\.colorScheme, .dark)
            .allowsHitTesting(false)
    }
}
