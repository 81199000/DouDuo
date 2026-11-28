import SwiftUI

struct DYLiveAudioOnlyCover: View {
    let room: DYLiveRoom
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let fg = theme.media.onMedia.color(for: scheme)
        let art = (room.cover ?? room.avatar).flatMap(URL.init(string:))
        GeometryReader { g in
            ZStack {
                Color.black
                if let art {
                    CachedAsyncImage(url: art) { $0.resizable().aspectRatio(contentMode: .fill) } placeholder: { Color.black }
                        .frame(width: g.size.width, height: g.size.height)
                        .blur(radius: 40)
                        .clipped()
                    Color.black.opacity(0.45)
                }
                VStack(spacing: 14) {
                    if let art {
                        CachedAsyncImage(url: art) { $0.resizable().aspectRatio(contentMode: .fill) } placeholder: { Color.black }
                            .frame(width: 112, height: 112)
                            .clipShape(Circle())
                    }
                    Label("语音直播", systemImage: "waveform")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(fg)
                        .themeShadow(.mediaLabel)
                }
                .position(x: g.size.width / 2, y: g.size.height * 0.42)
            }
        }
        .allowsHitTesting(false)
        .accessibilityIdentifier("live.audioOnly")
    }
}
