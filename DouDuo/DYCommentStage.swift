import SwiftUI

/// 推荐页评论排布：四种界面同一份（老板 2026-11-17 定，见 docs/ui-modes.md）。
///
/// 推荐流与评论布局共用同一个视频容器。评论面板独立挂载，避免开合时重建播放器。
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
    @ViewBuilder var feed: () -> Feed
    @ViewBuilder var author: () -> Author
    /// 布局结果回报给外层（菜单让位、顶栏宽度等）
    var onLayout: (_ resident: Bool, _ bookFold: Bool) -> Void = { _, _ in }

    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme

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
        // 让视频容器保持同一个身份，侧栏的出现和消失只发生在覆盖层。
        return feed()
            .environment(\.dyVideoHasSidePane, layout.showsSidePane)
            .frame(width: layout.videoSize.width, height: layout.videoSize.height, alignment: .topLeading)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .overlay(alignment: .topLeading) {
                if layout.showsPane {
                    pane(layout, showsAuthor: showsAuthorPane, authorOpen: authorOpen)
                }
            }
        .onChange(of: layout.resident, initial: true) { _, resident in
            onLayout(resident, layout.resident && layout.sideBySide)
        }
        .onChange(of: layout.resident && layout.sideBySide, initial: true) { _, bookFold in
            onLayout(layout.resident, bookFold)
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

    private func pane(_ layout: DYCommentPaneMetrics, showsAuthor: Bool, authorOpen: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            if showsAuthor {
                author()
                    .padding(.trailing, layout.trailingInset)
            } else if let aweme {
                DYCommentPanel(bridge: bridge, aweme: aweme,
                               onClose: layout.resident && !showsCaption ? nil : { showComments = false },
                               fillsPane: true,
                               trailingInset: horizontalCommentStatus ? geo.safeAreaInsets.trailing : layout.trailingInset,
                               horizontalStatus: horizontalCommentStatus)
                    .id(aweme.id)
            }
        }
        .padding(.top, !DYDuoMetrics.isDuoHardware && layout.sideBySide ? DYDuoMetrics.windowSafeTop : 0)
        .frame(width: layout.paneSize.width, height: layout.paneSize.height)
        .clipped()
        .dyDeskLight(layout.resident && !layout.sideBySide && !authorOpen)
        .overlay(alignment: .leading) {
            if layout.sideBySide { Color(uiColor: .separator).frame(width: 0.5) }
        }
        .padding(.leading, layout.paneOrigin.x)
        .padding(.top, layout.paneOrigin.y)
    }
}

extension DYCommentStage where Author == EmptyView {
    init(geo: GeometryProxy, bridge: DouyinBridge, aweme: DYAweme?, showComments: Binding<Bool>,
         showSearch: Bool, isLive: Bool, stacksLandscapeComments: Bool,
         hidesCommentStatus: Bool, horizontalCommentStatus: Bool,
         @ViewBuilder feed: @escaping () -> Feed,
         onLayout: @escaping (_ resident: Bool, _ bookFold: Bool) -> Void = { _, _ in }) {
        self.init(geo: geo, bridge: bridge, aweme: aweme, showComments: showComments, showSearch: showSearch,
                  isLive: isLive, stacksLandscapeComments: stacksLandscapeComments,
                  hidesCommentStatus: hidesCommentStatus, horizontalCommentStatus: horizontalCommentStatus,
                  feed: feed, author: { EmptyView() }, onLayout: onLayout)
    }
}

extension EnvironmentValues {
    /// 评论打开（默认 / 简洁 / 极简）：视频页上的按钮和信息收起
    @Entry var dyCommentsOpen = false
    /// 并排面板出现时，视频环境光只延伸到自己所在的一栏。
    @Entry var dyVideoHasSidePane = false
}
