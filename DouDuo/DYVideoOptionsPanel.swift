import SwiftUI

/// Shared by recommendation, following and every works player. These are the
/// existing persisted preferences; moving their controls does not reset them.
@available(iOS 27.1, *)
struct DYVideoOptionsPanel: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @AppStorage("douyin_autoplay_v1") private var autoNext = false
    @AppStorage("douyin_muted_v1") private var muted = false
    @AppStorage("douyin_autofit_v1") private var autoFit = true
    @AppStorage("douyin_playback_rate_v1") private var playbackRate = 1.0
    @AppStorage("douyin_bg_play_v1") private var backgroundPlay = false
    @AppStorage("douyin_wide_landscape_v1") private var landscapeOnly = true
    @AppStorage("douyin_short_ratio_portrait_v1") private var portraitRatio = 70
    @AppStorage("douyin_short_ratio_landscape_v1") private var landscapeRatio = 70
    @AppStorage("douyin_danmaku_v1") private var danmakuEnabled = true
    @AppStorage(DYDanmakuPolicy.densityKey) private var density = DYDanmakuPolicy.Density.standard.rawValue
    @AppStorage(DYDanmakuPolicy.deduplicateKey) private var deduplicate = true
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
                        shortcut("自动连播", icon: "play.square.stack",
                                 selected: autoNext, id: "douyin.options.autoplay") { autoNext.toggle() }
                        if let onDislike {
                            shortcut("不感兴趣", icon: "heart.slash", selected: false,
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
                        Divider().padding(.leading, 16)
                        Toggle(isOn: $backgroundPlay) {
                            Label("后台播放（听书）", systemImage: "headphones")
                        }
                        .padding(.horizontal, 16).frame(minHeight: 52)
                    }
                    .optionGroup()

                    VStack(alignment: .leading, spacing: 0) {
                        Label("内容偏好", systemImage: "slider.horizontal.3")
                            .font(.subheadline.weight(.semibold)).frame(minHeight: 44)
                        Divider()
                        VStack(spacing: 4) {
                            Toggle("横屏时只放横屏内容", isOn: $landscapeOnly)
                                .accessibilityIdentifier("douyin.landscape.only")
                                .frame(minHeight: 48)
                            ratioPicker("竖屏短视频占比", selection: $portraitRatio, id: "douyin.short.portrait")
                            ratioPicker("横屏短视频占比", selection: $landscapeRatio, id: "douyin.short.landscape")
                            Text("短视频指 3 分钟以内的视频")
                                .font(.caption).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.padding(.bottom, 12)
                    }
                    .padding(.horizontal, 16).optionGroup()

                    VStack(alignment: .leading, spacing: 0) {
                        Label("弹幕设置", systemImage: "text.bubble")
                            .font(.subheadline.weight(.semibold)).frame(minHeight: 44)
                        Divider()
                        VStack(spacing: 4) {
                            Toggle("显示弹幕", isOn: $danmakuEnabled)
                                .accessibilityIdentifier("douyin.danmaku.enabled").frame(minHeight: 48)
                            choiceRow("弹幕密度", values: DYDanmakuPolicy.Density.allCases.map(\.rawValue),
                                      selection: $density, id: "douyin.danmaku.density") {
                                (DYDanmakuPolicy.Density(rawValue: $0) ?? .standard).title
                            }
                            Toggle("10秒内重复去重", isOn: $deduplicate)
                                .accessibilityIdentifier("douyin.danmaku.deduplicate").frame(minHeight: 48)
                            if let onSendDanmaku {
                                Button("发弹幕", systemImage: "text.bubble") {
                                    dismiss()
                                    onSendDanmaku()
                                }
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .accessibilityIdentifier("douyin.danmaku.open")
                            }
                            Text("显示区域：屏幕上方 1/3").font(.caption).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.padding(.bottom, 12)
                    }
                    .padding(.horizontal, 16).optionGroup()
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

    private func ratioPicker(_ title: String, selection: Binding<Int>, id: String) -> some View {
        choiceRow(title, values: [-1, 30, 50, 70, 100], selection: selection, id: id) {
            $0 == -1 ? "不限" : "\($0)%"
        }
    }

    private func choiceRow(_ title: String, values: [Int], selection: Binding<Int>,
                           id: String, label: @escaping (Int) -> String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline)
            HStack(spacing: 6) {
                ForEach(values, id: \.self) { value in
                    Button { selection.wrappedValue = value } label: {
                        Text(label(value))
                            .font(.subheadline.weight(selection.wrappedValue == value ? .semibold : .regular))
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(.black.opacity(selection.wrappedValue == value ? 0.30 : 0.12), in: .capsule)
                            .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier(id + "." + String(value))
                    .accessibilityLabel(title + "，" + label(value))
                    .accessibilityAddTraits(selection.wrappedValue == value ? .isSelected : [])
                }
            }
        }.padding(.vertical, 6)
    }
}

private extension View {
    func optionGroup() -> some View {
        background(.black.opacity(0.10), in: RoundedRectangle(cornerRadius: 24))
    }
}
