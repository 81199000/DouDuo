import SwiftUI

/// 发弹幕的输入条：默认/简洁/极简 与 经典 的视频页共用这一份。
/// 以前两套视频页各写了一份完全一样的输入条和发送逻辑，改样式要改两处。
struct DYDanmakuBar: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Binding var draft: String
    var sending: Bool
    @FocusState.Binding var focused: Bool
    var onSend: () -> Void
    var onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField("", text: $draft, prompt: Text("发个弹幕见证当下").foregroundStyle(.white.opacity(0.5)))
                .foregroundStyle(.white)
                .focused($focused)
                .submitLabel(.send)
                .onSubmit(onSend)
                .padding(.horizontal, 14).frame(height: 40)
                .background(Capsule().fill(.black.opacity(0.6)))
                .accessibilityIdentifier("douyin.danmaku.input")
            Button(action: onSend) {
                if sending { ProgressView().tint(.white) }
                else { Text("发送").font(.subheadline.weight(.semibold)) }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14).frame(height: 40)
            .background(Capsule().fill(theme.accent.color(for: scheme)))
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || sending)
            .accessibilityIdentifier("douyin.danmaku.send")
            Button(action: onClose) {
                Image(systemName: "xmark").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    .frame(width: 36, height: 40)
            }
        }
        .padding(.horizontal, 12)
    }
}

/// 两套视频页共用的发送时机：发出后按当前播放位置把这条立刻排进本地列表。
@MainActor enum DYDanmakuComposer {
    static func post(_ text: String, item: DYAweme, bridge: DouyinBridge) async throws -> DYDanmaku {
        let at = DDNowPlaying.id == item.id ? DDNowPlaying.time : 0
        let id = try await bridge.postDanmaku(item.id, text: text, offset: at)
        return DYDanmaku(id: id, text: text, offset: at + 0.3)
    }
}
