import SwiftUI

/// 推荐页评论排布：四种界面同一份（老板 2026-11-17 定，见 docs/ui-modes.md）。
///
/// 原样搬自经典推荐页（DYClassicFeedScreen.flatArrangement），一套布局通吃所有状态，且**不换容器**
/// （换容器会重建播放器 → 黑屏 / 重播）：
/// - Duo 外屏 / 内屏竖拿：横屏视频移到顶部，评论在下（DYInlineCommentOverlay）
/// - 平放 / 外屏：够宽时评论从右侧滑出（视频缩窄），窄屏走贴边底部面板（dyBottomSheet）
/// - 半折叠：视频缩到一多半，另一半常驻评论（宽>高→左右分；高>宽→上下分）
/// - 横屏右划 / 下拉关闭：评论面板自带（DYPanelDismissGesture）
///
/// 维护规矩：评论「怎么摆」只改这里。各界面只负责菜单（评论盖住视频时自己把菜单收起）。
struct DYCommentStage<Feed: View, Author: View>: View {
    let geo: GeometryProxy
    let bridge: DouyinBridge
    /// 当前评论对象（推荐 / 关注 / 简介）
    let aweme: DYAweme?
    @Binding var showComments: Bool
    let showSearch: Bool
    let isLive: Bool
    /// 外屏 / 内屏竖拿时把横屏视频叠在评论上方（系统铰链：DYHingeStateRoot）
    let stacksLandscapeComments: Bool
    /// 外屏叠放评论时状态栏让位（经典口径）
    let hidesCommentStatus: Bool
    let horizontalCommentStatus: Bool
    /// 经典简介面板：评论面板顶部显示作者 / 全文
    var showsCaption = false
    /// 右侧作者页（经典内屏）；其它界面传 nil
    var authorPane: (id: String?, workOpen: Bool, supportsSidePanel: Bool)? = nil
    /// 半折叠触控板上下滑翻页（+1 下一条 / -1 上一条）；nil = 不支持
    var onPage: ((Int) -> Void)? = nil
    /// 当前条是推荐流里的直播间：没有评论可显示，下半屏直接是触控板，单击 = 进直播间（老板 11-24）
    var onLiveTap: (() -> Void)? = nil
    @ViewBuilder var feed: () -> Feed
    @ViewBuilder var author: () -> Author
    /// 布局结果回报给外层（菜单让位、顶栏宽度等）
    var onLayout: (_ resident: Bool, _ bookFold: Bool) -> Void = { _, _ in }

    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    /// 半折叠下半屏：评论 4 秒没人碰 → 触控板（老板 11-24，见 DYTouchpad.swift）
    @State private var padShown = false
    @State private var padTimer: Task<Void, Never>?
    @State private var keyboardUp = false
    /// 最后一次碰评论区的时刻（不存「按着」开关，见 DYTouchSniffer）
    @State private var lastTouch = Date.distantPast
    static var padDelay: Double { 4 }

    var body: some View {
        let authorOpen = authorPane?.id != nil
        let showsAuthorPane = (authorPane?.supportsSidePanel ?? false) && authorOpen
        let placement = showComments && !showSearch && !authorOpen && !isLive
            ? DYInlineCommentPlacement(geo, aweme: aweme, enabled: stacksLandscapeComments,
                                       showsCaption: showsCaption, usesCompactPanel: stacksLandscapeComments)
            : nil
        let layout = DYCommentPaneMetrics(geo, isPresented: !showSearch && (showsAuthorPane || (showComments && placement == nil)),
                                          allowsResident: !showSearch && !isLive,
                                          paneFraction: showsAuthorPane ? 0.5 : nil,
                                          keepsSideBySide: showsAuthorPane && (authorPane?.workOpen ?? false))
        let w = geo.size.width, h = geo.size.height
        // 只在竖屏半折叠（上视频下评论）且下半屏是评论时；书本式左右分、作者页、直播都不变
        let padLayout = layout.resident && layout.showsPane && !layout.sideBySide && !showsAuthorPane && !authorOpen
        // 刷到直播间（aweme == nil 且有 onLiveTap）：没有评论，直接是触控板，不能让下半屏黑着卡住
        let liveHere = aweme == nil && onLiveTap != nil
        let padActive = padLayout && ((padShown && aweme != nil) || liveHere)

        return ZStack(alignment: .topLeading) {
            feed()
                .environment(\.dyTouchpadEngaged, padActive)
                .frame(width: layout.videoSize.width, height: layout.videoSize.height, alignment: .topLeading)
                .environment(\.dyRestrictsPlaybackToPane, layout.showsPane && layout.sideBySide)
                // 侧栏评论时视频区要裁边：播放器的环境光底（DYAmbientBackdrop）会铺满整屏宽，盖住右侧评论栏
                //（内屏横屏评论纯黑的根因；dd405e6 拿掉这个裁边后 11-18 晚复发，老板 11-19 指出之前修过）。
                .modifier(DDClipIf(on: layout.showsPane && layout.sideBySide))
            if layout.showsPane {
                Group {
                    if showsAuthorPane {
                        author()
                            .padding(.trailing, layout.trailingInset)
                    } else if let cur = aweme {
                        DYCommentPanel(bridge: bridge, aweme: cur,
                                       onClose: layout.resident && !showsCaption ? nil : { showComments = false },
                                       fillsPane: true,
                                       trailingInset: horizontalCommentStatus ? geo.safeAreaInsets.trailing : layout.trailingInset,
                                       horizontalStatus: horizontalCommentStatus)
                            .id(cur.id)
                            .opacity(padActive ? 0 : 1)
                            .allowsHitTesting(!padActive)
                            .background(DYTouchSniffer { lastTouch = Date() })
                    }
                }
                .padding(.top, !DYDuoMetrics.isDuoHardware && layout.sideBySide ? DYDuoMetrics.windowSafeTop : 0)
                .frame(width: layout.paneSize.width, height: layout.paneSize.height)
                .clipped()
                // 触控板压在评论上面、倒影下面：桌面倒影照样投在黑底上（不重复挂第二层投光）
                .overlay {
                    if padActive {
                        DYTouchpadPane(onTap: {
                            if liveHere { DYLiveModel.log("DDTOUCHPAD tap → 进直播间"); onLiveTap?(); return }
                            withAnimation(.easeInOut(duration: 0.25)) { padShown = false }
                            lastTouch = Date()
                            armPad()
                        }, onPage: onPage, hint: liveHere ? "轻点进入直播间" : nil)
                        .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.35), value: padActive)
                .dyDeskLight(layout.resident && !layout.sideBySide && !authorOpen, videoHeight: layout.videoSize.height)
                .overlay(alignment: .leading) {
                    if layout.sideBySide { Color(uiColor: .separator).frame(width: 0.5) }
                }
                .padding(.leading, layout.paneOrigin.x)
                .padding(.top, layout.paneOrigin.y)
            }
        }
        .frame(width: w, height: h, alignment: .topLeading)
        .onChange(of: layout.resident, initial: true) { _, resident in
            onLayout(resident, layout.resident && layout.sideBySide)
        }
        .onChange(of: layout.resident && layout.sideBySide, initial: true) { _, bookFold in
            onLayout(layout.resident, bookFold)
        }
        // 进入半折叠先给评论，4 秒后变触控板；离开半折叠复位。换视频不复位（老板选 B：连着刷不闪评论）
        .onChange(of: padLayout, initial: true) { _, on in
            DYLiveModel.log("DDTOUCHPAD layout=\(on ? "半折叠上下分" : "其他")")
            padTimer?.cancel()
            padShown = false
            if on { armPad() }
        }
        // 从直播间划回视频：保持触控板（老板选 B，连着刷不闪评论）
        .onChange(of: liveHere) { _, live in
            if live, padLayout { padTimer?.cancel(); padShown = true }
        }
        // 点了视频上的评论按钮：回到评论
        .onChange(of: showComments) { _, on in
            if on, padShown { withAnimation(.easeInOut(duration: 0.25)) { padShown = false }; armPad() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardUp = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardUp = false
            lastTouch = Date()
        }
        .background((layout.resident ? Color.black : theme.media.strongScrim.color(for: scheme)).ignoresSafeArea())
        .animation(showSearch ? nil : .snappy, value: layout.resident)
        .animation(!showSearch && layout.sideBySide ? .snappy : nil, value: showComments)
        .animation(showSearch ? nil : .snappy, value: authorPane?.id)
        .modifier(DYInlineCommentOverlay(placement: placement, bridge: bridge, aweme: aweme,
                                         onClose: { showComments = false }))
        .dyBottomSheet(isPresented: Binding(
            get: { !showSearch && showComments && placement == nil && !layout.sideBySide && !layout.resident },
            set: { if placement == nil && !(authorPane?.supportsSidePanel ?? false) && !layout.resident { showComments = $0 } }
        ), kind: .comments, hidesStatusBar: hidesCommentStatus) {
            if let cur = aweme {
                DYCommentSheet(bridge: bridge, aweme: cur, onClose: { showComments = false })
            }
        }
    }
}

extension DYCommentStage {
    /// 重新计时：评论区 4 秒没人碰、没在打字 / 写回复 → 淡成触控板。每 0.5 秒看一次，不靠「按下 / 抬起」配对
    fileprivate func armPad() {
        padTimer?.cancel()
        let armed = Date()
        padTimer = Task { @MainActor in
            var lastReason = ""
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                if Task.isCancelled { return }
                let idle = Date().timeIntervalSince(max(armed, lastTouch))
                let reason = keyboardUp ? "键盘弹着" : DYTouchpadHold.shared.composing ? "正在回复" : idle < Self.padDelay ? "" : "ok"
                if reason == "ok" {
                    withAnimation(.easeInOut(duration: 0.35)) { padShown = true }
                    DYLiveModel.log("DDTOUCHPAD on（评论 \(Int(Self.padDelay)) 秒没动）")
                    return
                }
                if !reason.isEmpty, reason != lastReason { DYLiveModel.log("DDTOUCHPAD 先不切：\(reason)") }
                lastReason = reason
            }
        }
    }
}

extension DYCommentStage where Author == EmptyView {
    init(geo: GeometryProxy, bridge: DouyinBridge, aweme: DYAweme?, showComments: Binding<Bool>,
         showSearch: Bool, isLive: Bool, stacksLandscapeComments: Bool,
         hidesCommentStatus: Bool, horizontalCommentStatus: Bool,
         onPage: ((Int) -> Void)? = nil,
         onLiveTap: (() -> Void)? = nil,
         @ViewBuilder feed: @escaping () -> Feed,
         onLayout: @escaping (_ resident: Bool, _ bookFold: Bool) -> Void = { _, _ in }) {
        self.init(geo: geo, bridge: bridge, aweme: aweme, showComments: showComments, showSearch: showSearch,
                  isLive: isLive, stacksLandscapeComments: stacksLandscapeComments,
                  hidesCommentStatus: hidesCommentStatus, horizontalCommentStatus: horizontalCommentStatus,
                  onPage: onPage, onLiveTap: onLiveTap, feed: feed, author: { EmptyView() }, onLayout: onLayout)
    }
}

extension EnvironmentValues {
    /// 评论打开（默认 / 简洁 / 极简）：视频页上的按钮和信息收起
    @Entry var dyCommentsOpen = false
    /// 侧栏评论打开时限制画面和环境光的安全区扩展，保持播放器视图身份。
    @Entry var dyRestrictsPlaybackToPane = false
}

/// 侧栏评论时把视频区裁到自己的框内（环境光底铺满整屏会盖住右侧评论栏，dd405e6 拿掉后评论纯黑）。
///
/// 裁剪**一直挂着、视图类型不变**：以前写成 `if on { content.clipped() } else { content }`，两个分支是两种视图，
/// Duo 内屏横屏一开关评论 SwiftUI 就把整块视频连播放器拆掉重建 → 从头播（议题 #52-2 / 工单 B13）。
/// 关评论时裁剪框只往外放 200pt（盖住安全区就够）。**别放到几万点**：95ef04d 用 ±100000 的超大裁剪，
/// 真机评论区黑屏（渲染不了那么大的遮罩），已回滚。
struct DDClipIf: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        content.clipShape(DDPaneClipShape(on: on))
    }
}

/// 开评论时只裁左右（别盖住右侧评论栏），上下照样外扩：环境光要铺到屏幕最底边，
/// 否则底部手势条那一截露出页面底色（老板 11-21：先是白边，垫黑底后成黑边）。
private struct DDPaneClipShape: Shape {
    let on: Bool
    func path(in rect: CGRect) -> Path {
        Path(rect.insetBy(dx: on ? 0 : -200, dy: -200))
    }
}
