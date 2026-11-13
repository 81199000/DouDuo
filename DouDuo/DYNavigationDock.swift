import SwiftUI

/// Declaration order is also the system vertical tab bar's order.
enum DYMainTab: String, CaseIterable, Hashable {
    case mine = "我的", messages = "私信", home = "首页"
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
}

@available(iOS 27.1, *)
struct DYNativeVideoActions: View {
    @Environment(\.toolbarVerticalEdge) private var verticalEdge
    let actions: DYVideoToolbarActions?
    let isClean: Bool
    let onToggleClean: () -> Void
    @State private var anchorFrame: CGRect = .zero
    @State private var windowHeight: CGFloat = 0
    private var slotHeight: CGFloat {
        guard !anchorFrame.isEmpty else { return 262 }
        return max(262, (windowHeight - anchorFrame.maxY - 112).rounded(.down))
    }

    var body: some View {
        Color.clear.frame(width: 0, height: 0).allowsHitTesting(false)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: onToggleClean) {
                        Image(systemName: isClean ? "eye" : "eye.slash")
                            .font(.title3)
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                        .accessibilityLabel(isClean ? "退出清屏" : "清屏")
                        .accessibilityIdentifier("douyin.cleanScreen")
                        .background(DYToolbarFrameReader { frame, height in
                            withTransaction(Transaction(animation: nil)) {
                                anchorFrame = frame
                                windowHeight = height
                            }
                        })
                }
                .axisBehavior(.verticalPreferred)
                .visibilityPriority(.high)
                .hidden(actions == nil)

                // The stable clear-screen anchor is independent of this group's size.
                // A new item identity invalidates the native cached fitting size.
                ToolbarItem(id: "video-actions-\(Int(slotHeight))", placement: .bottomBar) {
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
                        .frame(height: slotHeight, alignment: .bottom)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("douyin.video.actions")
                    }
                }
                .sharedBackgroundVisibility(.hidden)
                .axisBehavior(.verticalPreferred)
                .visibilityPriority(.high)
                .hidden(actions == nil || verticalEdge == nil || isClean)
            }
            // Retain the last measured slot across navigation and sheets.
            // Resetting it would briefly expand the tabs on every return,
            // until the system lays out the anchor again.
    }
}

/// Standalone works have no tab selector. Keep Back separate from the compact
/// interaction capsule, so the system never turns the video actions into More.
@available(iOS 27.1, *)
struct DYStandaloneVideoActions: View {
    @Environment(\.toolbarVerticalEdge) private var verticalEdge
    let actions: DYVideoToolbarActions?
    let onBack: () -> Void

    var body: some View {
        Color.clear.frame(width: 0, height: 0).allowsHitTesting(false)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("返回", systemImage: "chevron.backward", action: onBack)
                        .labelStyle(.iconOnly).foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .accessibilityIdentifier("douyin.list.back")
                }
                .axisBehavior(.verticalPreferred)
                .visibilityPriority(.high)
                ToolbarItem(placement: .bottomBar) {
                    if let actions {
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
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("douyin.video.actions")
                    }
                }
                .sharedBackgroundVisibility(.hidden)
                .axisBehavior(.verticalPreferred)
                .visibilityPriority(.high)
                .hidden(actions == nil || verticalEdge == nil)
            }
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
