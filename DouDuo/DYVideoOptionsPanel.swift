import SwiftUI

/// Shared by recommendation, following and every works player. These are the
/// existing persisted preferences; moving their controls does not reset them.
@available(iOS 27.1, *)
struct DYVideoOptionsPanel: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @AppStorage("douyin_muted_v1") private var muted = false
    @AppStorage(DYVideoFit.preferenceKey) private var autoFit = true
    @AppStorage("douyin_playback_rate_v1") private var playbackRate = 1.0
    @AppStorage("douyin_bg_play_v1") private var backgroundPlay = false
    @AppStorage("douyin_autoplay_v1") private var autoNext = false
    @State private var listAtTop = true
    @State private var headerHeight: CGFloat = 44
    var onDislike: (() -> Void)?
    var onSendDanmaku: (() -> Void)?
    var onWatchLater: (() -> Void)?
    /// 收藏类动作（放进收藏夹 / 收藏合集 / 收藏音乐 / 复制短链）；经典模式的「更多」走这个面板
    var library: (item: DYAweme, bridge: DouyinBridge, onToast: ((String) -> Void)?)? = nil
    @State private var pickingFolder = false

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
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
            .contentShape(Rectangle())
            .modifier(DYPanelDismissGesture(onClose: { dismiss() }))
            ScrollView {
                VStack(spacing: 12) {
                    HStack(spacing: 0) {
                        if DYVideoFit.showsLabeledControl(on: .classicOptions) {
                            shortcut(DYVideoFit.title, icon: "arrow.up.left.and.arrow.down.right",
                                     selected: autoFit, id: "douyin.options.fit") { autoFit.toggle() }
                        }
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
                        if let onWatchLater {
                            Divider().padding(.leading, 16)
                            Button("稍后再看", systemImage: "clock") {
                                dismiss()
                                onWatchLater()
                            }
                            .padding(.horizontal, 16)
                            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                            .accessibilityIdentifier("douyin.watchlater.add")
                        }
                        if let library {
                            libraryRow("放进收藏夹", "folder.badge.plus", id: "douyin.more.folder") { pickingFolder = true }
                            if let mix = library.item.mixID, !mix.isEmpty {
                                libraryRow("收藏合集", "rectangle.stack.badge.plus", id: "douyin.more.mix") {
                                    Task { await libraryRun("已收藏合集") { try await library.bridge.collectMix(mix, on: true) } }
                                }
                            }
                            if let mid = library.item.musicID, !mid.isEmpty {
                                libraryRow("收藏音乐", "music.note", id: "douyin.more.music") {
                                    Task { await libraryRun("已收藏音乐") { try await library.bridge.collectMusic(mid, on: true) } }
                                }
                            }
                            libraryRow("复制短链", "link.badge.plus", id: "douyin.more.shortlink") {
                                Task {
                                    do {
                                        UIPasteboard.general.string = try await library.bridge.shortLink(for: library.item.webURL)
                                        library.onToast?("短链已复制")
                                    } catch { library.onToast?("短链生成失败：" + error.localizedDescription) }
                                }
                            }
                        }
                    }
                    .optionGroup()
                }
                .padding(.horizontal, 16).padding(.top, 4)
                .padding(.bottom, max(16, DYDuoMetrics.windowBottomInset + 4))
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: DYBottomPanelContentHeightKey.self,
                                               value: headerHeight + geometry.size.height)
                    }
                }
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
        .sheet(isPresented: $pickingFolder) {
            if let library {
                DYCollectsFolderPicker(bridge: library.bridge, ids: [library.item.id]) { library.onToast?($0) }
            }
        }
    }

    private func libraryRow(_ title: String, _ icon: String, id: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            Divider().padding(.leading, 16)
            Button(title, systemImage: icon, action: action)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                .accessibilityIdentifier(id)
        }
    }

    private func libraryRun(_ ok: String, _ op: () async throws -> DYActionResult) async {
        do {
            switch try await op() {
            case .ok: library?.onToast?(ok)
            case .notLoggedIn: library?.onToast?("抖音未登录")
            case .failed(let why): library?.onToast?("没成功：" + why)
            }
        } catch { library?.onToast?("没成功：" + error.localizedDescription) }
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
