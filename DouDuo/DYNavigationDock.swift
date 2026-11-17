import SwiftUI
import UIKit

/// Declaration order is also the system vertical tab bar's order.
enum DYMainTab: String, CaseIterable, Hashable {
    /// 当前大页的持久化键（重启恢复要和代码状态一致）
    static let storageKey = "duoduomain_tab_v1"
    case mine = "我的", messages = "消息", home = "首页"
}

/// Reject Home reselection at the native tab controller, before the system
/// can scroll the feed to the top. Keep SwiftUI's delegate for other events.
/// 单击已选中的「首页」什么都不做（不让系统把推荐流拉回首条）；**双击**（0.4 秒内连点两下）= 刷新视频。
struct DYHomeReselectionGuard: UIViewControllerRepresentable {
    var onDoubleTap: () -> Void = {}
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.onDoubleTap = onDoubleTap
        controller.install()
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.uninstall()
    }

    final class Controller: UIViewController, UITabBarControllerDelegate {
        private weak var installedOn: UITabBarController?
        var onDoubleTap: () -> Void = {}
        private var lastReselect: CFTimeInterval = 0
        static let doubleTapWindow: CFTimeInterval = 0.4
        private nonisolated(unsafe) weak var previousDelegate: (any UITabBarControllerDelegate)?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            install()
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            if parent == nil { uninstall() }
            else { install() }
        }

        func install() {
            guard let tabs = tabBarController else { return }
            if installedOn !== tabs { uninstall() }
            guard tabs.delegate !== self else { return }
            previousDelegate = tabs.delegate
            installedOn = tabs
            tabs.delegate = self
        }

        func uninstall() {
            if let installedOn, installedOn.delegate === self {
                installedOn.delegate = previousDelegate
            }
            installedOn = nil
            previousDelegate = nil
        }

        func tabBarController(_ controller: UITabBarController, shouldSelectTab tab: UITab) -> Bool {
            if tab === controller.selectedTab && tab.title == DYMainTab.home.rawValue { return rejectHomeReselection() }
            return previousDelegate?.tabBarController?(controller, shouldSelectTab: tab) ?? true
        }

        func tabBarController(_ controller: UITabBarController, shouldSelect viewController: UIViewController) -> Bool {
            if viewController === controller.selectedViewController &&
                viewController.tabBarItem.title == DYMainTab.home.rawValue { return rejectHomeReselection() }
            return previousDelegate?.tabBarController?(controller, shouldSelect: viewController) ?? true
        }

        private func rejectHomeReselection() -> Bool {
            let now = CACurrentMediaTime()
            if now - lastReselect <= Self.doubleTapWindow {
                lastReselect = 0
                DYLiveModel.log("DDDOCK Home double tap → refresh")
                onDoubleTap()
            } else {
                lastReselect = now
                DYLiveModel.log("DDDOCK ignored Home reselection")
            }
            return false
        }

        override nonisolated func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || previousDelegate?.responds(to: selector) == true
        }

        override nonisolated func forwardingTarget(for selector: Selector!) -> Any? {
            if let previousDelegate, previousDelegate.responds(to: selector) { return previousDelegate }
            return super.forwardingTarget(for: selector)
        }
    }
}

/// Let the system compress tabs before video actions when its shared vertical
/// column runs out of room. The expanded selector remains a native TabView.
struct DYSystemTabBar: ViewModifier {
    var hidden = false
    @AppStorage(DDChromeMode.key) private var mode = DDChromeMode.classic.rawValue
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 27.1, *), mode == DDChromeMode.duoClassic.rawValue {
            content.toolbarVisibility(hidden ? .hidden : .visible, for: .tabBar)
                .toolbarVerticalCompressionBehavior(.prefersToolbarItems)
                .toolbarBackgroundVisibility(.hidden, for: .bottomBar)
                .tabBarMinimizeBehavior(.never)
        } else { content }
    }
}

/// The current video supplies its existing controls and callbacks; moving
/// these views into the toolbar must not create another player or data model.
struct DYActiveVideoActionsKey: PreferenceKey {
    static var defaultValue: DYVideoToolbarActions? { nil }

    static func reduce(value: inout DYVideoToolbarActions?, nextValue: () -> DYVideoToolbarActions?) {
        if let next = nextValue() { value = next }
    }
}

struct DYVideoToolbarActions {
    let avatarImage: UIImage?
    let authorName: String
    let onAuthor: () -> Void
    let follow: AnyView?
    let like: AnyView
    let comments: AnyView
    let collect: AnyView
    let share: AnyView
    /// 当前视频的长按加速；图集没有播放器，为 nil。
    var boost: DYBoostControl? = nil
}

@available(iOS 27.1, *)
struct DYNativeVideoActions: View {
    @Environment(\.toolbarVerticalEdge) private var verticalEdge
    @Environment(\.dyStacksLandscapeComments) private var stacksLandscapeComments
    @Environment(\.dyHingeClosed) private var hingeClosed
    let actions: DYVideoToolbarActions?
    let isClean: Bool
    let onToggleClean: () -> Void
    var onBack: (() -> Void)? = nil
    var inlineTopInset: CGFloat? = nil
    @State private var anchorFrame: CGRect = .zero
    @State private var windowHeight: CGFloat = 0

    // Start with the capsule's natural size. A Live Activity can push the
    // primary controls down far enough that the usual empty spacing no longer fits.
    private var railHeight: CGFloat { 262 }
    private var availableBelowControls: CGFloat { max(0, windowHeight - anchorFrame.maxY) }
    private var standaloneBottomClearance: CGFloat {
        guard onBack != nil, !anchorFrame.isEmpty else { return 0 }
        return min(60, max(0, availableBelowControls - railHeight - 70))
    }
    private var showsInlineCleanControl: Bool {
        onBack == nil && verticalEdge == nil
            && (!DYDuoMetrics.isDuoHardware || (stacksLandscapeComments && !hingeClosed))
    }
    private var slotHeight: CGFloat {
        let minimum = railHeight + standaloneBottomClearance
        guard !anchorFrame.isEmpty else { return minimum }
        let preferred = (availableBelowControls - 112 + standaloneBottomClearance).rounded(.down)
        let dockClearance: CGFloat = onBack == nil ? 90 : 66
        return max(minimum, min(preferred, availableBelowControls - dockClearance))
    }

    private var cleanButton: some View {
        Button(action: { if actions?.boost?.blocksTap != true { onToggleClean() } }) {
            Image(systemName: isClean ? "eye" : "eye.slash")
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(isClean ? "退出清屏" : "清屏")
        .accessibilityIdentifier("douyin.cleanScreen")
        .modifier(DYHoldBoostArea(control: actions?.boost))
    }

    private func backButton(_ onBack: @escaping () -> Void) -> some View {
        Button("返回", systemImage: "chevron.backward", action: { if actions?.boost?.blocksTap != true { onBack() } })
            .labelStyle(.iconOnly)
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .accessibilityIdentifier("douyin.list.back")
            .modifier(DYHoldBoostArea(control: actions?.boost))
    }

    private func standaloneControls(_ onBack: @escaping () -> Void) -> some View {
        VStack(spacing: 4) {
            backButton(onBack)
            if actions != nil { cleanButton }
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if verticalEdge == nil, let onBack {
                standaloneControls(onBack)
                    .buttonStyle(.plain)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.leading, 8)
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if showsInlineCleanControl, actions != nil {
                cleanButton
                    .buttonStyle(.plain)
                    .glassEffect(.regular, in: .circle)
                    .padding(.trailing, 17)
                    .padding(.top, DYDuoMetrics.isDuoHardware ? 8 : max(inlineTopInset ?? DYDuoMetrics.windowSafeTop, 8) + 52)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .ignoresSafeArea(.container, edges: DYDuoMetrics.isDuoHardware ? [] : .top)
            } else {
                Color.clear.frame(width: 0, height: 0).allowsHitTesting(false)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Group {
                    if let onBack { standaloneControls(onBack) }
                    else { cleanButton }
                }
                .background(DYToolbarFrameReader { frame, height in
                    withTransaction(Transaction(animation: nil)) {
                        anchorFrame = frame
                        windowHeight = height
                    }
                })
            }
            .axisBehavior(.verticalPreferred)
            .visibilityPriority(.high)
            .hidden(onBack == nil ? actions == nil || showsInlineCleanControl : verticalEdge == nil)

            // The stable controls anchor is independent of this group's size.
            // A new item identity invalidates the native cached fitting size.
            ToolbarItem(id: "video-actions-\(Int(slotHeight))-\(Int(standaloneBottomClearance))", placement: .bottomBar) {
                if verticalEdge != nil, let actions {
                    VStack(spacing: 4) {
                        DYAuthorAvatarControl(image: actions.avatarImage, name: actions.authorName,
                                              onAuthor: actions.onAuthor, follow: actions.follow)
                        actions.like
                        actions.comments
                        actions.collect
                        actions.share
                    }
                    .padding(.vertical, 5)
                    .glassEffect(.regular, in: .capsule)
                    .environment(\.colorScheme, .dark)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("douyin.video.actions")
                    .padding(.bottom, standaloneBottomClearance)
                    .frame(height: slotHeight, alignment: .bottom)
                    .modifier(DYHoldBoostArea(control: actions.boost))
                }
            }
            .sharedBackgroundVisibility(.hidden)
            .axisBehavior(.verticalPreferred)
            .visibilityPriority(.high)
            .hidden(actions == nil || verticalEdge == nil || isClean)
        }
        // Retain the last measured slot across navigation and sheets.
    }
}

/// Keep the same avatar footprint before and after following, so changing
/// relationship state cannot resize the native toolbar or its collapsed tabs.
struct DYAuthorAvatarControl: View {
    let image: UIImage?
    let name: String
    let onAuthor: () -> Void
    let follow: AnyView?

    var body: some View {
        ZStack(alignment: .top) {
            Button(action: onAuthor) {
                Group {
                    if let image { Image(uiImage: image).renderingMode(.original) }
                    else { Image(systemName: "person.crop.circle").font(.title) }
                }
                .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("作者，" + name)
            .accessibilityIdentifier("douyin.author.avatar")
            if let follow {
                follow.frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .frame(width: 44, height: 52)
    }
}

/// Measure our own toolbar host in window coordinates. SwiftUI's `.global`
/// space inside a toolbar is local to its separate hosting view.
private struct DYToolbarFrameReader: UIViewRepresentable {
    let onChange: (CGRect, CGFloat) -> Void
    func makeUIView(context: Context) -> FrameView {
        let view = FrameView()
        view.isUserInteractionEnabled = false
        view.onChange = onChange
        return view
    }
    func updateUIView(_ view: FrameView, context: Context) {
        view.onChange = onChange
    }

    final class FrameView: UIView {
        var onChange: ((CGRect, CGFloat) -> Void)?
        private var lastFrame: CGRect = .zero
        private var lastHeight: CGFloat = 0
        private var candidateFrame: CGRect = .zero
        private var displayLink: CADisplayLink?
        private lazy var observer = FrameObserver(view: self)

        override func didMoveToWindow() {
            super.didMoveToWindow()
            displayLink?.invalidate()
            displayLink = nil
            guard window != nil else { return }
            let link = CADisplayLink(target: observer, selector: #selector(FrameObserver.sample))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 5, maximum: 10, preferred: 5)
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        deinit { displayLink?.invalidate() }

        // A native toolbar can move its host without laying out our child.
        // Sample only this view's public window rectangle and publish changes
        // after it settles, not the intermediate frames of navigation animation.
        fileprivate func reportFrame() {
            guard let window else { return }
            let frame = convert(bounds, to: window)
            guard !frame.isEmpty, frame.minY >= 0, frame.maxY < window.bounds.height else { return }
            guard frame == candidateFrame else { candidateFrame = frame; return }
            let height = window.bounds.height
            guard frame != lastFrame || height != lastHeight else { return }
            lastFrame = frame
            lastHeight = height
            DispatchQueue.main.async { [weak self] in self?.onChange?(frame, height) }
        }
    }

    private final class FrameObserver {
        weak var view: FrameView?
        init(view: FrameView) { self.view = view }
        @objc func sample() { view?.reportFrame() }
    }
}

/// Shared author status mark. Classic hides followed badges at its call site.
struct DYAuthorFollowMark: View {
    @Environment(\.appTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    let followed: Bool
    var busy = false
    var diameter: CGFloat = 14
    var symbolSize: CGFloat = 8
    var body: some View {
        ZStack {
            Circle().fill(followed ? theme.status.success.color(for: scheme) : theme.status.danger.color(for: scheme))
            if !busy { Image(systemName: followed ? "checkmark" : "plus")
                .font(.system(size: symbolSize, weight: .heavy)).foregroundStyle(.white) }
        }
        .frame(width: diameter, height: diameter)
        .overlay(Circle().stroke(.black.opacity(0.35), lineWidth: 0.5))
        // Flatten the solid badge before the native toolbar applies its glass
        // foreground treatment. The red fill must remain opaque over video.
        .drawingGroup()
        .overlay {
            if busy { ProgressView().controlSize(.mini).tint(.white) }
        }
    }
}
