#if DEBUG
import SwiftUI

/// Direct, silent launch of the real message UI; fixtures use an isolated cache.
struct DYMessageLayoutProbe: View {
    @AppStorage(DDChromeMode.key) private var mode = DDChromeMode.classic.rawValue
    @State private var tab = DYMainTab.messages
    @Environment(\.appTheme) private var theme
    private let bridge = DouyinBridge()

    var body: some View {
        Group {
            if mode == DDChromeMode.duoClassic.rawValue {
                classicTabs
            } else {
                DYMessagesScreen(bridge: bridge, onWeb: { _ in })
            }
        }
        .overlay(alignment: .bottom) {
            if ProcessInfo.processInfo.environment["DOUDUO_HIDE_FIXTURE"] == "1" {
                Button("模拟新消息") {
                    Task { _ = try? await DYMessageCache.shared.chatModel.web?.evaluateJavaScript("people[0].text = '新的离线消息'; renderRows();") }
                }
                .accessibilityIdentifier("fixture.receive")
            }
        }
        .preferredColorScheme(.dark)
    }

    private var classicTabs: some View {
        TabView(selection: $tab) {
            Tab("我的", systemImage: "person.crop.circle", value: DYMainTab.mine) { Text("我的") }
            Tab("消息", systemImage: "bubble.left.and.bubble.right", value: DYMainTab.messages) {
                DYMessagesScreen(bridge: bridge, onWeb: { _ in })
            }
            Tab("首页", systemImage: "house", value: DYMainTab.home) { Text("首页") }
        }
        .tint(theme.accent.color(for: .dark))
        .preferredColorScheme(.dark)
    }
}
#endif
