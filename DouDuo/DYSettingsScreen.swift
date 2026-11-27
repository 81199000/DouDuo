import SwiftUI

/// 完整设置页：「更多 → 设置」点进来。行样式与 GuoDuo 一致：左侧彩色圆角图标块 + 标题 / 小字说明 + 右侧控件。
/// 当前视频相关的操作（转发 / 不感兴趣 / 下载 / 倍速 / 静音 / 听书 / 自动连播 / 发弹幕）和铺满宽度都在播放页菜单，这里不重复。
struct DYSettingsScreen: View {
    /// 清缓存后让宿主把当前视频重新挂回播放器
    var onCacheCleared: () -> Void = {}
    var offlineCandidateSource: ((Int) async throws -> [DYAweme])?
    var offlineInteractionBridge: DouyinBridge?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @AppStorage(DDAppearance.key) private var appearance = DDAppearance.dark.rawValue
    @AppStorage(DDChromeMode.key) private var chromeMode = DDChromeMode.classic.rawValue
    @AppStorage(DYVideoAmbient.key) private var ambientLevel = DYVideoAmbient.defaultLevel
    @AppStorage(DYAutoPiP.storageKey) private var autoPiP = false
    @AppStorage(DYLaunchMute.key) private var launchMuted = false
    @AppStorage(DYHashtagFilter.storageKey) private var blockedHashtags = ""
    @AppStorage(DYFeedExtras.liveKey) private var feedLive = true
    @AppStorage(DYFeedExtras.adKey) private var feedAds = true
    @AppStorage(DYFeedExtras.productKey) private var feedProduct = true
    @AppStorage("douyin_danmaku_v1") private var danmakuEnabled = true
    @AppStorage(DYDanmakuPolicy.densityKey) private var density = DYDanmakuPolicy.Density.standard.rawValue
    @State private var cacheBytes: Int64?

    private var accent: Color { theme.accent.color(for: scheme) }
    private var ambientOn: Binding<Bool> {
        Binding(get: { ambientLevel > 0 }, set: { ambientLevel = $0 ? DYVideoAmbient.onLevel : 0 })
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    DDSettingRow(icon: "circle.lefthalf.filled", tint: .indigo, title: "外观") {
                        Picker("外观", selection: $appearance) {
                            ForEach(DDAppearance.allCases) { mode in
                                Text(mode.title).tag(mode.rawValue)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 210)
                        .accessibilityIdentifier("settings.appearance")
                    }
                    DDSettingRow(icon: "rectangle.3.group.fill", tint: accent, title: "界面模式") {
                        Picker("界面模式", selection: $chromeMode) {
                            ForEach(DDChromeMode.availableCases) { m in
                                Label(m.title, systemImage: m.symbol).tag(m.rawValue)
                            }
                        }
                        .labelsHidden()
                        .accessibilityIdentifier("settings.chrome")
                    }
                } header: { Text("界面") }

                Section {
                    DDSettingRow(icon: "sun.max.fill", tint: .orange, title: "环境光", subtitle: "视频没铺满时四周跟随画面颜色") {
                        Toggle("环境光", isOn: ambientOn).labelsHidden().tint(accent)
                            .accessibilityIdentifier("settings.ambient")
                    }
                    DDSettingRow(icon: "speaker.slash.fill", tint: .gray, title: "打开时默认静音", subtitle: "不打断正在放的音乐") {
                        Toggle("打开时默认静音", isOn: $launchMuted).labelsHidden().tint(accent)
                            .accessibilityIdentifier("settings.launch.muted")
                    }
                    DDSettingRow(icon: "text.bubble.fill", tint: .blue, title: "弹幕") {
                        Toggle("显示弹幕", isOn: $danmakuEnabled).labelsHidden().tint(accent)
                            .accessibilityIdentifier("douyin.danmaku.enabled")
                    }
                    DDSettingRow(icon: "line.3.horizontal.decrease", tint: .cyan, title: "弹幕密度") {
                        Picker("弹幕密度", selection: $density) {
                            ForEach(DYDanmakuPolicy.Density.allCases) { Text($0.title).tag($0.rawValue) }
                        }
                        .labelsHidden()
                        .disabled(!danmakuEnabled)
                        .accessibilityIdentifier("douyin.danmaku.density")
                    }
                    DDSettingRow(icon: "pip.enter", tint: .indigo, title: "离开应用时自动画中画") {
                        Toggle("离开应用时自动画中画", isOn: $autoPiP).labelsHidden().tint(accent)
                            .accessibilityIdentifier("settings.autoPip")
                    }
                } header: { Text("播放") } footer: {
                    Text("倍速、静音、听书、自动连播、铺满宽度、发弹幕在播放页菜单里。")
                }

                Section {
                    NavigationLink {
                        DYHashtagFilterScreen(currentTags: [], embedded: true)
                    } label: {
                        DDSettingRow(icon: "eye.slash.fill", tint: .red, title: "按关键词屏蔽视频") {
                            let n = DYHashtagFilter(rawValue: blockedHashtags).tags.count
                            Text(n == 0 ? "未设置" : "已屏蔽 \(n) 个").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("douyin.hashtags.manage")
                    DDSettingRow(icon: "dot.radiowaves.left.and.right", tint: .pink, title: "推荐里插入直播间") {
                        Toggle("推荐里插入直播间", isOn: $feedLive).labelsHidden().tint(accent)
                            .accessibilityIdentifier("settings.feed.live")
                    }
                    DDSettingRow(icon: "megaphone.fill", tint: .yellow, title: "推荐里显示广告") {
                        Toggle("推荐里显示广告", isOn: $feedAds).labelsHidden().tint(accent)
                            .accessibilityIdentifier("settings.feed.ads")
                    }
                    DDSettingRow(icon: "cart.fill", tint: .orange, title: "显示视频商品", subtitle: "带货视频上的小黄车") {
                        Toggle("显示视频商品（小黄车）", isOn: $feedProduct).labelsHidden().tint(accent)
                            .accessibilityIdentifier("settings.feed.product")
                    }
                } header: { Text("推荐") }

                Section {
                    NavigationLink {
                        DYOfflineDownloadScreen(candidateSource: offlineCandidateSource, interactionBridge: offlineInteractionBridge)
                    } label: {
                        DDSettingRow(icon: "tray.and.arrow.down.fill", tint: .teal, title: "离线视频") { EmptyView() }
                    }
                    .accessibilityIdentifier("settings.cache.offline")
                    NavigationLink {
                        DYStorageScreen(onCleared: onCacheCleared)
                    } label: {
                        DDSettingRow(icon: "externaldrive.fill", tint: .green, title: "储存空间", subtitle: "视频缓存、离线视频") {
                            if let cacheBytes {
                                Text(ByteCountFormatter.string(fromByteCount: cacheBytes, countStyle: .file))
                                    .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                            } else {
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                    .accessibilityIdentifier("settings.storage")
                } header: { Text("存储") }

                Section {
                    NavigationLink {
                        DDAboutScreen()
                    } label: {
                        DDSettingRow(icon: "info.circle.fill", tint: .gray, title: "关于 DouDuo") {
                            Text("v\(DDUpdateChecker.currentVersion)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("douyin.about.entry")
                } header: { Text("关于") }
            }
            .scrollContentBackground(.hidden)
            .background(Color.ddBackground)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }.accessibilityIdentifier("settings.done")
                }
            }
            .task { await loadCacheSize() }
        }
    }

    /// 只算缓存（视频 + 离线 + 图片 + 网页数据），不含 App 本体
    private func loadCacheSize() async {
        guard let u = try? await DYStorageFiles.shared.scan() else { return }
        cacheBytes = [.video, .offline, .images, .web].reduce(Int64(0)) { $0 + (u.categories[$1] ?? 0) }
    }
}

/// 设置行：左彩色圆角图标块 + 标题 / 小字说明 + 右侧控件（与 GuoDuo 设置同款）
struct DDSettingRow<Trailing: View>: View {
    let icon: String
    let tint: Color
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 29, height: 29)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body).foregroundStyle(.primary)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.vertical, 2)
    }
}

/// 关于：版本、本版更新内容、开源仓库
struct DDAboutScreen: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.openURL) private var openURL
    @State private var showNotes = false

    var body: some View {
        List {
            Section {
                VStack(spacing: 8) {
                    Image(systemName: "play.rectangle.on.rectangle.fill")
                        .font(.system(size: 34, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 72, height: 72)
                        .background(theme.accent.color(for: scheme).gradient, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    Text("DouDuo").font(.title2.weight(.bold))
                    Text("版本 \(DDAppVersion.display)")
                        .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
                        .accessibilityIdentifier("douyin.about.version")
                }
                .frame(maxWidth: .infinity).padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }
            Section {
                Button { showNotes = true } label: {
                    DDSettingRow(icon: "sparkles", tint: .purple, title: "本版更新内容") { link }
                }
                .accessibilityIdentifier("douyin.about.notes")
                Button { openURL(DDUpdateChecker.repoURL) } label: {
                    DDSettingRow(icon: "chevron.left.forwardslash.chevron.right", tint: Color(white: 0.32), title: "DouDuo 开源仓库",
                                 subtitle: DDUpdateChecker.repo) { link }
                }
                .accessibilityIdentifier("douyin.about")
            } header: { Text("版本") }
        }
        .scrollContentBackground(.hidden)
        .background(Color.ddBackground)
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showNotes) {
            DDReleaseNotesSheet(mode: .whatsNew(DDUpdateChecker.currentVersion))
        }
    }

    private var link: some View {
        Image(systemName: "arrow.up.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
    }
}

/// 「更多」菜单里的设置入口：点一下打开完整设置页（不再是层层子菜单）。
struct DYSettingsButton: View {
    @Environment(\.dyOpenSettings) private var open
    var body: some View {
        if let open {
            Button("设置", systemImage: "gearshape") { open() }
                .accessibilityIdentifier("douyin.settings")
        }
    }
}

extension EnvironmentValues {
    @Entry var dyOpenSettings: (() -> Void)? = nil
}

