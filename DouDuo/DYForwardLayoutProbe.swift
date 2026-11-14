#if DEBUG
import SwiftUI

/// An isolated share flow with no player, account context or send implementation.
struct DYForwardLayoutProbe: View {
    @AppStorage(DDChromeMode.key) private var mode = DDChromeMode.classic.rawValue
    @Environment(\.appTheme) private var theme
    @State private var showing = false
    @State private var tab = DYMainTab.home
    @State private var forwardedChat: DYForwardReceipt?
    private let bridge = DouyinBridge(startURL: URL(string: "about:blank")!)
    private let item = DYAweme(id: "fixture-video", desc: "离线测试视频", width: 720, height: 1280,
        duration: 10, play: nil, cover: nil, images: [], author: .init(name: "本地测试", avatar: nil, secUid: nil),
        stats: .init(digg: 0, comment: 0, collect: 0, share: 0), music: "", userDigged: nil, isCollect: nil)

    var body: some View {
        Group {
            if mode == DDChromeMode.duoClassic.rawValue {
                TabView(selection: $tab) {
                    Tab("我的", systemImage: "person.crop.circle", value: DYMainTab.mine) { Text("离线个人页") }
                    Tab("消息", systemImage: "bubble.left.and.bubble.right", value: DYMainTab.messages) {
                        DYMessagesScreen(bridge: bridge, onWeb: { _ in }, forwardedShare: forwardedChat)
                    }
                    Tab("首页", systemImage: "house", value: DYMainTab.home) { sharePage }
                }
                .tint(theme.accent.color(for: .dark))
                .environment(\.dyForwardOpenChat, { forwardedChat = $0; tab = .messages })
            } else { sharePage }
        }
    }

    private var sharePage: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 24) {
                Image(systemName: "play.rectangle").font(.system(size: 64)).foregroundStyle(.secondary)
                Text("离线分享测试").foregroundStyle(.secondary)
                Button("分享") { showing = true }.accessibilityIdentifier("douyin.share")
            }
        }
        .dyBottomSheet(isPresented: Binding(get: { showing && mode == DDChromeMode.duoClassic.rawValue }, set: { showing = $0 }), kind: .share) {
            DYForwardScreen(item: item)
        }
        .fullScreenCover(isPresented: Binding(get: { showing && mode != DDChromeMode.duoClassic.rawValue }, set: { showing = $0 })) {
            DYForwardScreen(item: item).presentationBackground(.clear)
        }
        .modifier(DYForwardFeedbackPresentation(bottomInset: 16))
        .preferredColorScheme(.dark)
    }
}
#endif
