import SwiftUI

/// Shared by recommendation, following and every works player. These are the
/// existing persisted preferences; moving their controls does not reset them.
@available(iOS 27.1, *)
struct DYVideoOptionsPanel: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @AppStorage("douyin_muted_v1") private var muted = false
    @AppStorage("douyin_autofit_v1") private var autoFit = true
    @AppStorage("douyin_playback_rate_v1") private var playbackRate = 1.0
    @AppStorage("douyin_bg_play_v1") private var backgroundPlay = false
    @AppStorage("douyin_autoplay_v1") private var autoNext = false
    @State private var listAtTop = true
    var onDislike: (() -> Void)?
    var onSendDanmaku: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text("视频设置").font(.subheadline.weight(.semibold))
                HStack {
                    Spacer()
                    Button("关闭设置", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly).frame(width: 44, height: 44).contentShape(Rectangle())
                        .accessibilityIdentifier("douyin.options.close")
                }
            }
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
            .modifier(DYPanelDismissGesture(onClose: { dismiss() }))
            ScrollView {
                VStack(spacing: 12) {
                    HStack(spacing: 0) {
                        shortcut("铺满宽度", icon: "arrow.up.left.and.arrow.down.right",
                                 selected: autoFit, id: "douyin.options.fit") { autoFit.toggle() }
                        shortcut("静音", icon: muted ? "speaker.slash" : "speaker.wave.2",
                                 selected: muted, id: "douyin.options.muted") { muted.toggle() }
                        shortcut("听书模式", icon: "headphones",
                                 selected: backgroundPlay, id: "douyin.options.bgplay") { backgroundPlay.toggle() }
                        shortcut("自动连播", icon: "play.square.stack",
                                 selected: autoNext, id: "douyin.options.autonext") { autoNext.toggle() }
                        if let onDislike {
                            shortcut("不感兴趣", icon: "hand.thumbsdown", selected: false,
                                     id: "douyin.dislike") {
                                dismiss()
                                onDislike()
                            }
                        }
                    }
                    .padding(.vertical, 12)

                    VStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("倍速", systemImage: "speedometer")
                                .font(.subheadline.weight(.semibold))
                            HStack(spacing: 6) {
                                ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                                    Button {
                                        playbackRate = rate
                                    } label: {
                                        Text(rate.formatted(.number.precision(.fractionLength(0...2))))
                                            .font(.subheadline.weight(abs(playbackRate - rate) < 0.01 ? .semibold : .regular))
                                            .foregroundStyle(.primary)
                                            .frame(maxWidth: .infinity, minHeight: 44)
                                            .background(.black.opacity(abs(playbackRate - rate) < 0.01 ? 0.30 : 0.12), in: .capsule)
                                            .contentShape(Rectangle())
                                    }
                                    .accessibilityLabel(rate == 1 ? "正常速度" : "\(rate.formatted()) 倍速")
                                    .accessibilityAddTraits(abs(playbackRate - rate) < 0.01 ? .isSelected : [])
                                    .accessibilityIdentifier("douyin.options.rate.\(rate)")
                                }
                            }
                        }
                        .padding(16)
                        if let onSendDanmaku {
                            Divider().padding(.leading, 16)
                            Button("发弹幕", systemImage: "text.bubble") {
                                dismiss()
                                onSendDanmaku()
                            }
                            .padding(.horizontal, 16)
                            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                            .accessibilityIdentifier("douyin.danmaku.open")
                        }
                    }
                    .optionGroup()

                    Text("自动连播、环境光、推荐筛选、弹幕、界面等在「更多 → 设置」里")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }
                .padding(.horizontal, 16).padding(.top, 4)
                .padding(.bottom, max(16, DYDuoMetrics.windowBottomInset + 4))
            }
            .scrollBounceBehavior(.basedOnSize)
            .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top <= 1 } action: { _, atTop in listAtTop = atTop }
            .modifier(DYPanelDismissGesture(isAtTop: listAtTop, onClose: { dismiss() }))
            .accessibilityIdentifier("douyin.options.list")
        }
        .font(.subheadline)
        .foregroundStyle(.primary)
        .tint(theme.accent.color(for: scheme))
        .buttonStyle(.plain)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("douyin.options.panel")
    }

    private func shortcut(_ title: String, icon: String, selected: Bool,
                          id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.title3)
                Text(title).font(.caption).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(.black.opacity(selected ? 0.30 : 0.12), in: RoundedRectangle(cornerRadius: 18))
            .padding(.horizontal, 3)
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier(id)
        .accessibilityValue(selected ? "开启" : "关闭")
    }

}

private extension View {
    func optionGroup() -> some View {
        background(.black.opacity(0.10), in: RoundedRectangle(cornerRadius: 24))
    }
}
