import SwiftUI

/// 完整设置页：「更多 → 设置」点进来。所有全局偏好集中在这里，菜单里不再层层嵌套。
/// 当前视频相关的操作（转发 / 不感兴趣 / 下载 / 倍速 / 静音 / 听书 / 自动连播 / 发弹幕）和铺满宽度都在表层菜单，这里不重复。
struct DYSettingsScreen: View {
    @AppStorage(DYCommentKeyboard.autoFocusKey) private var replyAutoKeyboard = true
    /// 打开「网页版 / 登录」：由宿主页面负责弹出网页并在关闭后重载签名页
    var onOpenWeb: () -> Void
    /// 刷新推荐：先收起设置页再刷，刷完 toast 由宿主页面显示
    var onRefresh: () -> Void = {}
    /// 清缓存后让宿主把当前视频重新挂回播放器
    var onCacheCleared: () -> Void = {}
    var offlineCandidateSource: ((Int) async throws -> [DYAweme])?
    var offlineInteractionBridge: DouyinBridge?

    @Environment(\.dismiss) private var dismiss
    // 界面
    @AppStorage(DDAppearance.key) private var appearance = DDAppearance.dark.rawValue
    @AppStorage(DDChromeMode.key) private var chromeMode = DDChromeMode.classic.rawValue
    // 播放
    @AppStorage(DYVideoAmbient.key) private var ambientLevel = DYVideoAmbient.defaultLevel
    @AppStorage(DYAutoPiP.storageKey) private var autoPiP = false
    // 内容
    @AppStorage("douyin_wide_landscape_v1") private var landscapeOnly = false
    @AppStorage("douyin_portrait_mix_v1") private var portraitMix = false
    @AppStorage(DYSeenHistory.enabledKey) private var hideSeen = true
    @AppStorage(DYLaunchMute.key) private var launchMuted = false
    @State private var seenCount = 0
    @State private var confirmClearSeen = false
    @AppStorage(DYHashtagFilter.storageKey) private var blockedHashtags = ""
    @AppStorage(DYFeedExtras.liveKey) private var feedLive = true
    @AppStorage(DYFeedExtras.adKey) private var feedAds = true
    @AppStorage(DYFeedExtras.productKey) private var feedProduct = true
    // 弹幕
    @AppStorage("douyin_danmaku_v1") private var danmakuEnabled = true
    @AppStorage(DYDanmakuPolicy.densityKey) private var density = DYDanmakuPolicy.Density.standard.rawValue
    @AppStorage(DYDanmakuPolicy.deduplicateKey) private var deduplicate = true
    // 缓存
    @AppStorage(DYVideoCache.countKey) private var cacheCount = DYVideoCache.defaultCount
    @AppStorage(DYStream.enabledKey) private var streamCache = true
    @AppStorage(DYStream.saverKey) private var dataSaver = true
    @AppStorage(DYStream.wifiSaverKey) private var wifiSaver = false
    @State private var info: DYSettingInfo?
    @AppStorage(DYDMNotificationSettings.notifyKey) private var dmNotifications = false
    @AppStorage(DYDMNotificationSettings.detailKey) private var dmDetail = false
    @State private var showNotes = false
    @AppStorage(DYWebComposer.enabledKey) private var commentViaWebUI = false

    private static let cacheChoices: [(Int, String)] = [(1, "1 条"), (5, "5 条"), (10, "10 条")]

    var body: some View {
        NavigationStack {
            Form {
                // 每项后面 ⓘ 点开看这项具体改了什么；极少动的收进「高级设置」。
                // 1 界面  2 播放与弹幕  3 推荐与内容  4 流量与缓存  5 账号  6 高级设置  7 关于
                Section {
                    Picker("外观", selection: $appearance) {
                        ForEach(DDAppearance.allCases) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("settings.appearance")
                    row(.chrome) {
                        Picker("界面模式", selection: $chromeMode) {
                            ForEach(DDChromeMode.availableCases) { m in
                                Label(m.title, systemImage: m.symbol).tag(m.rawValue)
                            }
                        }
                        .accessibilityIdentifier("settings.chrome")
                    }
                } header: {
                    Text("界面")
                }

                Section {
                    row(.ambient) {
                        Picker("环境光", selection: $ambientLevel) {
                            ForEach(DYVideoAmbient.levels, id: \.self) { Text(DYVideoAmbient.title($0)).tag($0) }
                        }
                        .accessibilityIdentifier("settings.ambient")
                    }
                    row(.launchMuted) {
                        Toggle("打开时默认静音", isOn: $launchMuted).accessibilityIdentifier("settings.launch.muted")
                    }
                    row(.danmaku) {
                        Toggle("显示弹幕", isOn: $danmakuEnabled).accessibilityIdentifier("douyin.danmaku.enabled")
                    }
                    row(.danmakuDensity) {
                        Picker("弹幕密度", selection: $density) {
                            ForEach(DYDanmakuPolicy.Density.allCases) { Text($0.title).tag($0.rawValue) }
                        }
                        .disabled(!danmakuEnabled)
                        .accessibilityIdentifier("douyin.danmaku.density")
                    }
                } header: {
                    Text("播放与弹幕")
                } footer: {
                    Text("倍速、静音、听书、自动连播、铺满宽度、发弹幕在播放页菜单里。")
                }

                Section {
                    Button {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { onRefresh() }
                    } label: {
                        Label("刷新推荐", systemImage: "arrow.clockwise")
                    }
                    .accessibilityIdentifier("settings.refresh")
                    row(.keywords) {
                        NavigationLink {
                            DYHashtagFilterScreen(currentTags: [], embedded: true)
                        } label: {
                            LabeledContent("按关键词屏蔽视频") {
                                let n = DYHashtagFilter(rawValue: blockedHashtags).tags.count
                                Text(n == 0 ? "未设置" : "已屏蔽 \(n) 个")
                            }
                        }
                        .accessibilityIdentifier("douyin.hashtags.manage")
                    }
                    row(.hideSeen) {
                        Toggle("不再推荐看过的视频", isOn: $hideSeen).accessibilityIdentifier("settings.hide.seen")
                    }
                    row(.feedLive) {
                        Toggle("推荐里插入直播间", isOn: $feedLive).accessibilityIdentifier("settings.feed.live")
                    }
                    row(.feedAds) {
                        Toggle("推荐里显示广告", isOn: $feedAds).accessibilityIdentifier("settings.feed.ads")
                    }
                    row(.feedProduct) {
                        Toggle("显示视频商品（小黄车）", isOn: $feedProduct).accessibilityIdentifier("settings.feed.product")
                    }
                } header: {
                    Text("推荐与内容")
                }

                Section {
                    row(.wifiSaver) {
                        Toggle("Wi-Fi 省流量", isOn: $wifiSaver)
                            .disabled(!streamCache)
                            .accessibilityIdentifier("settings.stream.wifiSaver")
                    }
                    row(.cellSaver) {
                        Toggle("蜂窝数据省流量", isOn: $dataSaver)
                            .disabled(!streamCache)
                            .accessibilityIdentifier("settings.stream.saver")
                    }
                    row(.cacheCount) {
                        Picker("预缓存数量", selection: $cacheCount) {
                            ForEach(Self.cacheChoices, id: \.0) { Text($0.1).tag($0.0) }
                        }
                        .accessibilityIdentifier("settings.cache.count")
                        // 旧版存的 0 / 20 / 50 / 100 不在新选项里（选择器会显示空白）：打开设置时归到最近一档
                        .onAppear { if cacheCount != DYVideoCache.limit { cacheCount = DYVideoCache.limit } }
                    }
                    NavigationLink {
                        DYOfflineDownloadScreen(candidateSource: offlineCandidateSource, interactionBridge: offlineInteractionBridge)
                    } label: {
                        Label("离线视频", systemImage: "tray.and.arrow.down")
                    }
                    .accessibilityIdentifier("settings.cache.offline")
                    NavigationLink {
                        DYStorageScreen(onCleared: onCacheCleared)
                    } label: {
                        Label("储存空间", systemImage: "internaldrive")
                    }
                    .accessibilityIdentifier("settings.storage")
                } header: {
                    Text("流量与缓存")
                } footer: {
                    Text(Self.trafficSummary(wifiSaver: wifiSaver, cellSaver: dataSaver, streaming: streamCache, count: cacheCount))
                }

                Section {
                    Button {
                        dismiss()
                        // 先收起设置页再弹网页，避免两层全屏叠在一起
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { onOpenWeb() }
                    } label: {
                        Label("网页版 / 登录", systemImage: "safari")
                    }
                    .accessibilityIdentifier("settings.web")
                    row(.dmNotify) {
                        Toggle("应用内私信通知", isOn: $dmNotifications)
                            .accessibilityIdentifier("settings.dm.notify")
                    }
                    row(.dmDetail) {
                        Toggle("通知里显示会话名称与头像", isOn: $dmDetail)
                            .disabled(!dmNotifications)
                            .accessibilityIdentifier("settings.dm.detail")
                    }
                } header: {
                    Text("账号与私信")
                }

                Section {
                    NavigationLink {
                        advanced
                    } label: {
                        Label("高级设置", systemImage: "slider.horizontal.3")
                    }
                    .accessibilityIdentifier("settings.advanced")
                } footer: {
                    Text("横竖屏筛选、弹幕去重、评论方式、画中画、看过记录、边看边缓存等不常调的都在这里。")
                }

                Section {
                    LabeledContent("当前版本", value: DDAppVersion.display)
                        .accessibilityIdentifier("douyin.about.version")
                    Button {
                        showNotes = true
                    } label: {
                        Label("本版更新内容", systemImage: "sparkles")
                    }
                    .accessibilityIdentifier("douyin.about.notes")
                    .sheet(isPresented: $showNotes) {
                        DDReleaseNotesSheet(mode: .whatsNew(DDUpdateChecker.currentVersion))
                    }
                    Button {
                        UIApplication.shared.open(DDUpdateChecker.repoURL)
                    } label: {
                        Label("开源仓库", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                    .accessibilityIdentifier("douyin.about")
                } header: {
                    Text("关于")
                }
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
            .sheet(item: $info) { DYSettingInfoSheet(info: $0) }
        }
    }

    /// 高级设置：极少调的开关
    private var advanced: some View {
        Form {
            Section {
                row(.landscapeOnly) {
                    Toggle("横屏时只放横屏内容", isOn: $landscapeOnly).accessibilityIdentifier("douyin.landscape.only")
                }
                row(.portraitMix) {
                    Toggle("竖屏时固定 70% 竖屏视频", isOn: $portraitMix).accessibilityIdentifier("settings.portrait.mix")
                }
            } header: {
                Text("推荐筛选")
            } footer: {
                Text("默认都关：横着、竖着看都按抖音推荐的原顺序播放。")
            }
            Section {
                row(.dedupe) {
                    Toggle("10 秒内重复弹幕去重", isOn: $deduplicate)
                        .disabled(!danmakuEnabled)
                        .accessibilityIdentifier("douyin.danmaku.deduplicate")
                }
                row(.autoPiP) {
                    Toggle("离开应用时自动画中画", isOn: $autoPiP)
                        .accessibilityIdentifier("settings.autoPip")
                }
            } header: {
                Text("播放")
            }
            Section {
                row(.replyKeyboard) {
                    Toggle("点回复时自动弹出键盘", isOn: $replyAutoKeyboard)
                        .accessibilityIdentifier("douyin.comment.autoKeyboard")
                }
                row(.webComment) {
                    Toggle("用网页评论框发送", isOn: $commentViaWebUI)
                        .accessibilityIdentifier("douyin.comment.webUI")
                }
            } header: {
                Text("评论")
            }
            Section {
                row(.streaming) {
                    Toggle("边看边缓存", isOn: $streamCache)
                        .accessibilityIdentifier("settings.stream.enabled")
                }
                Button(role: .destructive) { confirmClearSeen = true } label: {
                    LabeledContent("清空看过记录") { Text("\(seenCount) 条").foregroundStyle(.secondary) }
                }
                .disabled(seenCount == 0)
                .accessibilityIdentifier("settings.seen.clear")
                .onAppear { seenCount = DYSeenHistory.shared.count }
                .confirmationDialog("清空看过记录？清空后看过的视频可能会再被推荐。", isPresented: $confirmClearSeen, titleVisibility: .visible) {
                    Button("清空 \(seenCount) 条", role: .destructive) {
                        DYSeenHistory.shared.clear(); seenCount = 0
                    }
                }
            } header: {
                Text("缓存与记录")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.ddBackground)
        .navigationTitle("高级设置")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $info) { DYSettingInfoSheet(info: $0) }
    }

    /// 一行设置 + 右侧 ⓘ：点开看这项具体会改变什么
    private func row<C: View>(_ i: DYSettingInfo, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 10) {
            content()
            Button { info = i } label: {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("说明：\(i.title)")
            .accessibilityIdentifier("settings.info.\(i.rawValue)")
        }
    }

    /// 流量与缓存区底部：按当前两个开关 + 条数说清楚现在 Wi-Fi / 流量下各会怎么下
    static func trafficSummary(wifiSaver: Bool, cellSaver: Bool, streaming: Bool, count: Int) -> String {
        let n = DYVideoCache.normalized(count)
        guard streaming else { return "边看边缓存已关（高级设置）：Wi-Fi 和流量下都整条下载后面 \(n) 条。" }
        let wifi = wifiSaver ? "Wi-Fi：后面 \(n) 条只下开头几秒，不播不继续下。" : "Wi-Fi：后面 \(n) 条整条下好，划到即播。"
        let cell = cellSaver ? "流量：低一档清晰度，只备下一条的开头。" : "流量：高清，后面 2 条整条下好。"
        return "现在 —— " + wifi + "\n" + cell
    }
}

/// 每个设置项的 ⓘ 说明：开 / 关分别会怎样
enum DYSettingInfo: String, Identifiable {
    case chrome, ambient, launchMuted, danmaku, danmakuDensity, keywords, hideSeen, feedLive, feedAds, feedProduct
    case wifiSaver, cellSaver, cacheCount, dmNotify, dmDetail
    case landscapeOnly, portraitMix, dedupe, autoPiP, replyKeyboard, webComment, streaming
    var id: String { rawValue }

    var title: String {
        switch self {
        case .chrome: "界面模式"
        case .ambient: "环境光"
        case .launchMuted: "打开时默认静音"
        case .danmaku: "显示弹幕"
        case .danmakuDensity: "弹幕密度"
        case .keywords: "按关键词屏蔽视频"
        case .hideSeen: "不再推荐看过的视频"
        case .feedLive: "推荐里插入直播间"
        case .feedAds: "推荐里显示广告"
        case .feedProduct: "显示视频商品（小黄车）"
        case .wifiSaver: "Wi-Fi 省流量"
        case .cellSaver: "蜂窝数据省流量"
        case .cacheCount: "预缓存数量"
        case .dmNotify: "应用内私信通知"
        case .dmDetail: "通知里显示会话名称与头像"
        case .landscapeOnly: "横屏时只放横屏内容"
        case .portraitMix: "竖屏时固定 70% 竖屏视频"
        case .dedupe: "10 秒内重复弹幕去重"
        case .autoPiP: "离开应用时自动画中画"
        case .replyKeyboard: "点回复时自动弹出键盘"
        case .webComment: "用网页评论框发送"
        case .streaming: "边看边缓存"
        }
    }

    /// (开 / 选了会怎样, 关会怎样)；选择类只有一段说明
    var lines: [(String, String)] {
        switch self {
        case .chrome: [("说明", "四种播放页布局：默认、简洁、极简、经典。只改按钮和信息怎么摆，不影响推荐和播放。")]
        case .ambient: [("说明", "视频没铺满屏幕时，四周的空白跟着画面颜色变化。分关 / 亮 / 中 / 暗 / 很暗；选「关」就是纯黑边。")]
        case .launchMuted: [("开", "每次打开 DouDuo 都先静音，并提示「已静音播放」；不会打断你正在放的音乐。"), ("关", "打开就带声音播放。")]
        case .danmaku: [("开", "视频上方 1/3 区域显示弹幕。"), ("关", "不显示弹幕，发弹幕仍在播放页菜单里。")]
        case .danmakuDensity: [("说明", "稀疏：最多 2 行、每秒 1 条；标准：4 行、每秒 2 条；密集：6 行、每秒 4 条。")]
        case .keywords: [("说明", "标题或话题标签里含有这个词就不推，例如屏蔽「美食」也会挡住 #美食推荐。只作用于推荐页，搜索、关注、作者主页不受影响。")]
        case .hideSeen: [("开", "推荐页划到过的就算看过（按账号分开，记最近 5000 条），抖音再推时自动跳过。"), ("关", "抖音推什么就放什么，可能刷到看过的。清空记录在「高级设置」里。")]
        case .feedLive: [("开", "推荐里会穿插直播间，划到直接看直播。"), ("关", "推荐里不出现直播。")]
        case .feedAds: [("开", "和官方一样保留广告，简介下方标「广告」。"), ("关", "推荐里不再出现广告。")]
        case .feedProduct: [("开", "带货视频上显示商品胶囊。"), ("关", "不显示商品胶囊。")]
        case .wifiSaver: [("开", "连 Wi-Fi 时，后面几条只下开头几秒，够秒开就停；你不播就不继续下。省流量，但快划长视频偶尔要多等一下。"), ("关（默认）", "连 Wi-Fi 时，按「预缓存数量」把后面几条整条下好，划到即播最顺。")]
        case .cellSaver: [("开（默认）", "用流量时自动换低一档清晰度（多为 H.265，画质接近、体积约一半），只备下一条的开头，也不提前连直播。"), ("关", "用流量时也是高清，并把后面 2 条整条下好；流量用得多。")]
        case .cacheCount: [("说明", "提前备好后面几条：1 / 5 / 10 条。条数越多快划越顺，占内存和流量也越多。Wi-Fi 省流量关时这几条会整条下好；用流量时不看这个设置（省流量开备 1 条，关备 2 条）。")]
        case .dmNotify: [("开", "在 App 里收到新私信时，屏幕顶部弹一条提醒。"), ("关", "不弹提醒，私信照常在「消息」里。")]
        case .dmDetail: [("开", "提醒里显示对方的会话名称和头像。"), ("关", "提醒里不显示是谁发的，公共场合更隐私。")]
        case .landscapeOnly: [("开", "手机横着拿或展开大屏时，推荐只放横屏视频。"), ("关（默认）", "横着看也按抖音推荐原顺序播放，竖屏视频会带黑边。")]
        case .portraitMix: [("开", "竖着看时推荐里约七成是竖屏视频（抖音网页推荐本身竖屏只有一到三成）。"), ("关（默认）", "按抖音推荐原顺序播放。")]
        case .dedupe: [("开", "10 秒内内容相同的弹幕只显示一次。"), ("关", "重复弹幕照常刷屏。")]
        case .autoPiP: [("开", "离开 DouDuo 时，当前短视频尝试进入系统画中画（系统决定能否启动）。"), ("关（默认）", "离开就暂停；播放页菜单里开了「听书模式」时继续出声。")]
        case .replyKeyboard: [("开（默认）", "点一条评论回复它时，直接弹出键盘。"), ("关", "点评论只选中要回复的人，要再点输入框才弹键盘。")]
        case .webComment: [("开", "文字评论和回复填进抖音网页自己的评论框再点发送，和手动发一样，每条多等几秒；带图评论仍按原方式发。"), ("关（默认）", "直接调用接口发送，更快。")]
        case .streaming: [("开（默认）", "视频看到哪下到哪，划走就停；看完的自动存成完整文件，下次可离线播。两个省流量开关依赖它。"), ("关", "老办法：后面几条整条下载后再播，流量最多，省流量开关失效。一般不需要关。")]
        }
    }
}

struct DYSettingInfoSheet: View {
    let info: DYSettingInfo
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(info.lines.enumerated()), id: \.offset) { _, line in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(line.0).font(.subheadline.weight(.semibold))
                        Text(line.1).font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
            .navigationTitle(info.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("好") { dismiss() } } }
        }
        .presentationDetents([.medium])
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


/// 评论键盘相关的设置键
enum DYCommentKeyboard {
    static let autoFocusKey = "douyin_comment_reply_autokeyboard_v1"
}
