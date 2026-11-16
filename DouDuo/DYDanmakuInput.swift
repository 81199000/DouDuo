import SwiftUI

/// 视频弹幕：拉取 + 发送 + 输入条（四种界面同一份）。
///
/// 维护规矩：弹幕的数据和输入条只写在这里。视频页（`DYUpstreamVideoPage`、`DYClassicVideoPage`）
/// 只决定输入条「摆在哪」（简洁/极简挂在系统侧栏 / 底部，经典挂在视频底部），不要再各写一份。
@MainActor
final class DYDanmakuModel: ObservableObject {
    @Published var items: [DYDanmaku] = []
    @Published var showInput = false
    @Published var draft = ""
    @Published var sending = false
    private var loaded = false

    /// 轮到这条时拉弹幕（一次拉整条视频的）。挂在 `.task(id: isCurrent)` 里调用。
    func load(_ item: DYAweme, isCurrent: Bool, bridge: DouyinBridge?) async {
        guard isCurrent, !loaded, item.images.isEmpty, let b = bridge else { return }
        loaded = true
        // 接口单次只能拿到约 30 秒的弹幕，长视频按 60 秒窗口边拉边显示
        for await chunk in b.danmakuStream(item.id, durationMs: Int(item.duration * 1000)) {
            items = DYDanmaku.merged(items, chunk)
        }
        // 中途滑走会取消任务：标记回 false，回来重新把剩下的窗口补齐
        if Task.isCancelled { loaded = false }
        let sorted = items.map(\.offset).sorted()
        let gapMax = zip(sorted, sorted.dropFirst()).map { $1 - $0 }.max() ?? 0
        DYLiveModel.log("DDDM id=\(item.id) n=\(items.count) dur=\(String(format: "%.1f", item.duration))s range=\(sorted.first.map { String(format: "%.1f", $0) } ?? "-")..\(sorted.last.map { String(format: "%.1f", $0) } ?? "-") gapMax=\(String(format: "%.1f", gapMax))s afterHalf=\(sorted.filter { $0 > item.duration / 2 }.count)")
    }

    /// 发送成功返回 true（调用方收起键盘）。
    func send(_ item: DYAweme, bridge: DouyinBridge?, onToast: ((String) -> Void)?) async -> Bool {
        let text = draft.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, !sending, let b = bridge else { return false }
        sending = true
        defer { sending = false }
        let at = DDNowPlaying.id == item.id ? DDNowPlaying.time : 0
        do {
            let id = try await b.postDanmaku(item.id, text: text, offset: at)
            // 自己发的立刻上屏（从当前时间点开始飘）
            items.append(DYDanmaku(id: id, text: text, offset: at + 0.3))
            items.sort { $0.offset < $1.offset }
            draft = ""
            showInput = false
            onToast?("弹幕已发送")
            return true
        } catch {
            onToast?("弹幕发送失败：\(error.localizedDescription)")
            return false
        }
    }
}

/// 弹幕输入条：输入框 + 发送 + 关闭。
struct DYDanmakuBar: View {
    @ObservedObject var model: DYDanmakuModel
    var focused: FocusState<Bool>.Binding
    let onSend: () -> Void
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 8) {
            TextField("", text: $model.draft, prompt: Text("发个弹幕见证当下").foregroundStyle(.white.opacity(0.5)))
                .foregroundStyle(.white)
                .focused(focused)
                .submitLabel(.send)
                .onSubmit(onSend)
                .padding(.horizontal, 14).frame(height: 40)
                .background(Capsule().fill(.black.opacity(0.6)))
                .accessibilityIdentifier("douyin.danmaku.input")
            Button(action: onSend) {
                if model.sending { ProgressView().tint(.white) }
                else { Text("发送").font(.subheadline.weight(.semibold)) }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14).frame(height: 40)
            .background(Capsule().fill(theme.accent.color(for: scheme)))
            .disabled(model.draft.trimmingCharacters(in: .whitespaces).isEmpty || model.sending)
            .accessibilityIdentifier("douyin.danmaku.send")
            Button { model.showInput = false; focused.wrappedValue = false } label: {
                Image(systemName: "xmark").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    .frame(width: 36, height: 40)
            }
            .accessibilityIdentifier("douyin.danmaku.close")
        }
        .padding(.horizontal, 12)
    }
}
