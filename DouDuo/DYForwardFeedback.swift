import SwiftUI

private struct DYForwardOpenChatKey: EnvironmentKey {
    static let defaultValue: ((DYForwardReceipt) -> Void)? = nil
}

private struct DYForwardCompletionKey: EnvironmentKey {
    static let defaultValue: ((DYForwardReceipt) -> Void)? = nil
}

extension EnvironmentValues {
    var dyForwardOpenChat: ((DYForwardReceipt) -> Void)? {
        get { self[DYForwardOpenChatKey.self] }
        set { self[DYForwardOpenChatKey.self] = newValue }
    }
    var dyForwardCompletion: ((DYForwardReceipt) -> Void)? {
        get { self[DYForwardCompletionKey.self] }
        set { self[DYForwardCompletionKey.self] = newValue }
    }
}

/// Lives on the video page, so dismissing the share panel preserves the receipt.
struct DYForwardFeedbackPresentation: ViewModifier {
    @Environment(\.dyForwardOpenChat) private var openChat
    let bottomInset: CGFloat
    var isCurrent = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @State private var pending: DYForwardReceipt?
    @State private var receipt: DYForwardReceipt?
    @State private var chat: DYForwardReceipt?

    func body(content: Content) -> some View {
        content
            .environment(\.dyForwardCompletion, { pending = $0 })
            .overlay(alignment: .bottom) {
                if let receipt {
                    DYForwardSuccessBanner(receipt: receipt, onOpen: {
                        if let openChat { openChat(receipt) } else { chat = receipt }
                        self.receipt = nil
                    }, onClose: { self.receipt = nil })
                    .frame(maxWidth: 560)
                    .padding(.horizontal, 16)
                    .padding(.bottom, max(16, bottomInset + 12))
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? .easeOut(duration: 0.12) : .snappy(duration: 0.25), value: receipt?.id)
            .sensoryFeedback(.success, trigger: receipt?.id) { _, next in next != nil }
            .task(id: pending?.id) {
                guard let pending else { return }
                do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
                guard isCurrent else { return }
                receipt = pending
            }
            .task(id: receipt?.id) {
                guard receipt != nil, !voiceOverEnabled else { return }
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                receipt = nil
            }
            .onChange(of: isCurrent) { _, active in
                if !active { pending = nil; receipt = nil }
            }
            .fullScreenCover(item: $chat) { receipt in
                DYForwardChatScreen(receipt: receipt)
            }
    }
}

struct DYForwardSuccessBanner: View {
    let receipt: DYForwardReceipt
    let onOpen: () -> Void
    let onClose: () -> Void

    @AppStorage(DDChromeMode.key) private var mode = DDChromeMode.classic.rawValue

    var body: some View {
        HStack(spacing: 10) {
            CachedAsyncImage(url: receipt.contact.avatar.flatMap(URL.init(string:))) {
                $0.resizable().scaledToFill()
            } placeholder: {
                Image(systemName: receipt.contact.kind == 2 ? "person.2.circle.fill" : "person.crop.circle.fill")
                    .resizable().foregroundStyle(.secondary)
            }
            .frame(width: 36, height: 36).clipShape(.circle).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Label("分享成功", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                Text("已私信给 \(receipt.contact.name)")
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onOpen) {
                HStack(spacing: 4) { Text("去看看"); Image(systemName: "chevron.forward") }
                    .font(.headline)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minHeight: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color(red: 1, green: 0.17, blue: 0.33))
            .accessibilityLabel("去聊天框看看")
            .accessibilityIdentifier("douyin.forward.success.open")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .foregroundStyle(.white)
        .background {
            if mode != DDChromeMode.duoClassic.rawValue {
                RoundedRectangle(cornerRadius: 18).fill(Color(uiColor: .secondarySystemBackground))
            }
        }
        .glassEffect(mode == DDChromeMode.duoClassic.rawValue ? .regular : .identity, in: .rect(cornerRadius: 18))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("douyin.forward.success")
        .accessibilityAction(.escape, onClose)
    }

}

private struct DYForwardChatScreen: View {
    let receipt: DYForwardReceipt
    @Environment(\.dismiss) private var dismiss
    @StateObject private var bridge: DouyinBridge

    init(receipt: DYForwardReceipt) {
        self.receipt = receipt
        #if DEBUG
        _bridge = StateObject(wrappedValue: DYMessageFixture.enabled
            ? DouyinBridge(startURL: URL(string: "about:blank")!) : DouyinBridge())
        #else
        _bridge = StateObject(wrappedValue: DouyinBridge())
        #endif
    }

    var body: some View {
        DYMessagesScreen(bridge: bridge, onClose: { dismiss() }, onWeb: { _ in }, forwardedShare: receipt)
            .onAppear { DDPlayback.shared.pauseAll(reason: .cover) }
            .onDisappear { DDPlayback.shared.releaseCover() }
    }
}
