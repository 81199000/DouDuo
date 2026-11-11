// DouDuo 三姿态：外屏 / 半折叠 / 内屏平放。
// iOS 27.1 用 ArrangementView.overlay（书本：视频 leading、评论 trailing；桌面：视频在上、评论在下）。
// 更低版本回退容器宽度 wide>=700，不读方向、不读 UIScreen。
import SwiftUI

enum DYDuoMetrics {
    /// Align full-bleed video chrome to the runtime trailing system column.
    /// Compact chrome and layouts without a trailing column remain unchanged.
    static func actionRailHorizontalOffset(isRegular: Bool, trailingInset: CGFloat,
                                          columnWidth: CGFloat, outerPadding: CGFloat,
                                          opticalLeadingInset: CGFloat = 0) -> CGFloat {
        guard isRegular, trailingInset > 0 else { return 0 }
        return outerPadding + columnWidth / 2 - trailingInset / 2 - opticalLeadingInset
    }

    /// iOS 17–27.0 的宽屏回退，和改版前同一条线。
    static let legacyWideMin: CGFloat = 700

    /// 折痕是否处于激活状态（半折叠）。iOS 27.1 以下恒为 false。
    static func foldIsActive(_ proxy: GeometryProxy) -> Bool {
        #if DEBUG
        // 演示/截图用：模拟器没有物理折痕，用环境变量强制进入半折叠布局
        if ProcessInfo.processInfo.environment["DOUDUO_FOLD"] == "1" { return true }
        #endif
        if #available(iOS 27.1, *) {
            return proxy.reservedRegions(kind: .division).contains { $0.isActive }
        }
        return false
    }

    /// 顶栏左移量：合屏时前摄挖孔压在右上，整排往左让出它的宽度，避免「推荐/直播」被啃掉。
    /// 只认靠上且靠右的 occlusion；下方/居中的（如外屏下缘）不动顶栏。
    static func topBarLeftShift(_ proxy: GeometryProxy) -> CGFloat {
        guard #available(iOS 27.1, *) else { return 0 }
        let w = proxy.size.width
        var shift: CGFloat = 0
        for r in proxy.reservedRegions(kind: .occlusion) where r.isActive {
            let f = r.frame
            guard f.height > 1, f.width > 1 else { continue }
            // 顶部 140pt 内、且位于右半边 → 认定为前摄
            if f.minY < 140, f.minX > w * 0.5 {
                shift = max(shift, f.width)
            }
        }
        return min(shift, 56)
    }
}

// MARK: - 折痕 / 摄像头：整组小幅平移，不大挪

private struct DYNudgePref: PreferenceKey {
    static var defaultValue: CGSize { .zero }
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

/// 自定义按钮栏避开 active 的 occlusion（外屏摄像头）和 division（折痕）。
/// 测量放在未平移的布局框上，平移只作用于内容，避免来回抖。
struct DYRailReservedNudge: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            DYRailReservedNudgeBox { content }
        } else {
            content
        }
    }
}

@available(iOS 27.1, *)
private struct DYRailReservedNudgeBox<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @State private var nudge: CGSize = .zero

    var body: some View {
        content()
            .offset(nudge)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: DYNudgePref.self, value: DYReservedNudge.offset(in: proxy))
                }
            }
            .onPreferenceChange(DYNudgePref.self) { new in
                if hypot(new.width - nudge.width, new.height - nudge.height) > 0.5 { nudge = new }
            }
    }
}

@available(iOS 27.1, *)
enum DYReservedNudge {
    /// 在视图自己的坐标里，把和遮挡区相交的部分挪到最近的一侧。摄像头优先向下，符合外屏「小幅下移」。
    static func offset(in proxy: GeometryProxy) -> CGSize {
        let local = CGRect(origin: .zero, size: proxy.size)
        guard local.width > 1, local.height > 1 else { return .zero }
        var box = local
        var acc = CGSize.zero
        for region in proxy.reservedRegions(kind: .occlusion) where region.isActive && region.frame.intersects(box) {
            let d = clear(box, region.frame, preferDown: true)
            acc.width += d.width
            acc.height += d.height
            box = box.offsetBy(dx: d.width, dy: d.height)
        }
        for region in proxy.reservedRegions(kind: .division) where region.isActive && region.frame.intersects(box) {
            let d = clear(box, region.frame, preferDown: false)
            acc.width += d.width
            acc.height += d.height
            box = box.offsetBy(dx: d.width, dy: d.height)
        }
        return acc
    }

    private static func clear(_ box: CGRect, _ region: CGRect, preferDown: Bool) -> CGSize {
        let left = CGSize(width: region.minX - box.maxX, height: 0)
        let right = CGSize(width: region.maxX - box.minX, height: 0)
        let up = CGSize(width: 0, height: region.minY - box.maxY)
        let down = CGSize(width: 0, height: region.maxY - box.minY)
        let mag: (CGSize) -> CGFloat = { abs($0.width) + abs($0.height) }
        let best = [left, right, up, down].min { mag($0) < mag($1) } ?? .zero
        if preferDown, mag(down) <= mag(best) + 24 { return down }
        return best
    }
}

// MARK: - ArrangementView 主面板

/// zIndex > 0：平放 / 外屏，面板浮在视频上，维持「点了才出」。
/// zIndex == 0：半折叠，系统把 primary 分到 trailing / 底部，面板常驻。
@available(iOS 27.1, *)
struct DYDuoCommentPrimary: View {
    @Environment(\.overlayArrangementZIndex) private var zIndex
    @Environment(\.horizontalSizeClass) private var hSize
    let bridge: DouyinBridge
    let aweme: DYAweme?
    let showComments: Bool
    let onClose: () -> Void
    let onAuthor: () -> Void

    var body: some View {
        if zIndex == 0 {
            resident
        } else if hSize == .regular, showComments, let aweme {
            sidePanel(aweme)
        }
    }

    private var resident: some View {
        VStack(spacing: 0) {
            if let aweme {
                authorBar(aweme)
                DYCommentPanel(bridge: bridge, aweme: aweme, onClose: nil)
                    .id(aweme.id)
            } else {
                ContentUnavailableView("还没有视频", systemImage: "play.rectangle", description: Text("推荐流加载后，这里显示作者和评论"))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(GlassBackground())
        .modifier(DYRailReservedNudge())
    }

    private func authorBar(_ aweme: DYAweme) -> some View {
        Button(action: onAuthor) {
            HStack(spacing: 10) {
                CachedAsyncImage(url: aweme.author.avatar.flatMap(URL.init(string:))) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Color.primary.opacity(0.08)
                }
                .frame(width: 36, height: 36)
                .clipShape(Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(aweme.author.name.isEmpty ? "作者" : aweme.author.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.themeTextPrimary)
                    if !aweme.desc.isEmpty {
                        Text(aweme.desc).font(.caption).foregroundStyle(.themeTextSecondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("douyin.duo.author")
    }

    private func sidePanel(_ aweme: DYAweme) -> some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                Color.clear
                    .frame(maxWidth: .infinity)
                    .allowsHitTesting(false)
                DYCommentPanel(bridge: bridge, aweme: aweme, onClose: onClose)
                    .frame(width: min(380, geo.size.width * 0.36))
                    .id(aweme.id)
            }
        }
        .transition(.move(edge: .trailing))
    }
}

/// 外屏（非 regular）评论走系统 sheet，挂在 ArrangementView 外面，避免 sheet 被姿态容器吃掉。
struct DYOuterCommentSheet: ViewModifier {
    @Environment(\.horizontalSizeClass) private var hSize
    @Binding var showComments: Bool
    let aweme: DYAweme?
    let bridge: DouyinBridge

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(
            get: { showComments && hSize != .regular && aweme != nil },
            set: { showComments = $0 }
        )) {
            if let aweme {
                DYCommentPanel(bridge: bridge, aweme: aweme, onClose: { showComments = false })
                    // 竖屏锁死半屏：不给 .large，上滑不能把评论区撑满整屏
                    .presentationDetents([.fraction(0.62)])
                    .presentationDragIndicator(.visible)
            }
        }
    }
}
