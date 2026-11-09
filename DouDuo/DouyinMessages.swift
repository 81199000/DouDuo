// 消息中心（对齐抖音消息页）：顶部朋友头像 → 互动/粉丝/系统/私信入口 → 点进分类二级页。
// 全部内容在同一个 ScrollView 里滚动，分类入口不固定在顶部。
// Duo：返回键在右侧；根页左缘右滑关闭，二级页走系统原生左缘返回（回上一层，不回视频）。
import SwiftUI
import UIKit

enum DYNoticeGroup: Int, CaseIterable, Identifiable {
    case all = 700
    case comment = 2
    case digg = 3
    case fans = 401
    case system = 961

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .all: "全部"
        case .comment: "评论"
        case .digg: "赞"
        case .fans: "粉丝"
        case .system: "系统"
        }
    }
}

/// 消息二级页
enum DYMsgRoute: Hashable {
    case interactive, fans, system

    var title: String {
        switch self {
        case .interactive: "互动消息"
        case .fans: "粉丝消息"
        case .system: "系统通知"
        }
    }

    /// 标题下拉可切的接口分组（互动页 = 全部/评论/赞）
    var filters: [DYNoticeGroup] {
        switch self {
        case .interactive: [.all, .comment, .digg]
        case .fans: [.fans]
        case .system: [.system]
        }
    }

    func filterTitle(_ g: DYNoticeGroup) -> String {
        guard self == .interactive else { return title }
        switch g {
        case .comment: return "评论"
        case .digg: return "赞"
        default: return "全部互动"
        }
    }
}

/// notice 列表里的 type（不是 group）：31 评论 / 41 赞 / 9009 推荐 / 33 关注
enum DYNoticeKind {
    static let follow = 33
    static func isInteractive(_ n: DYNotice) -> Bool {
        n.type != follow && (n.author != nil || (n.awemeID ?? "").isEmpty == false)
    }
}

// MARK: - 根页

struct DYMessagesScreen: View {
    let bridge: DouyinBridge
    let onClose: () -> Void
    let onWeb: (URL) -> Void

    @State private var path: [DYMsgRoute] = []
    /// 顶部头像栏 = 朋友（互相关注），来自 familiar/atlist，不是粉丝
    @State private var friends: [DYFriend] = []
    @State private var counts: [Int: Int] = [:]
    @State private var recent: [DYNotice] = []
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        NavigationStack(path: $path) {
            root
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: DYMsgRoute.self) { r in
                    DYNoticeListScreen(bridge: bridge, route: r, onWeb: onWeb)
                        .toolbar(.hidden, for: .navigationBar)
                }
        }
        .task { await loadRoot() }
        .onChange(of: path) { _, p in
            // 从二级页回来：刷新未读角标
            if p.isEmpty { Task { await loadRoot() } }
        }
    }

    private var root: some View {
        VStack(spacing: 0) {
            DYMsgHeader(onBack: onClose) {
                HStack(spacing: 8) {
                    Text("消息").font(.headline.weight(.bold))
                    if loading { ProgressView().tint(.white).scaleEffect(0.8) }
                }
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    friendStrip
                    entry(icon: "heart.fill", tint: Color(red: 0.95, green: 0.30, blue: 0.55),
                          title: "互动消息", subtitle: interactSummary,
                          badge: (counts[DYNoticeGroup.comment.rawValue] ?? 0) + (counts[DYNoticeGroup.digg.rawValue] ?? 0),
                          id: "douyin.messages.interactive") { path.append(.interactive) }
                    entry(icon: "person.fill", tint: Color(red: 0.25, green: 0.55, blue: 0.95),
                          title: "粉丝消息", subtitle: fansSummary,
                          badge: counts[DYNoticeGroup.fans.rawValue] ?? 0,
                          id: "douyin.messages.fans") { path.append(.fans) }
                    entry(icon: "bell.fill", tint: Color(red: 0.55, green: 0.55, blue: 0.60),
                          title: "系统通知", subtitle: (counts[DYNoticeGroup.system.rawValue] ?? 0) > 0 ? "有新通知" : "没有新通知",
                          badge: counts[DYNoticeGroup.system.rawValue] ?? 0,
                          id: "douyin.messages.system") { path.append(.system) }
                    entry(icon: "bubble.left.and.bubble.right.fill", tint: Color(red: 0.20, green: 0.75, blue: 0.55),
                          title: "私信", subtitle: "在网页版查看会话",
                          badge: 0, id: "douyin.messages.chat") {
                        if let u = URL(string: "https://www.douyin.com/chat") { onWeb(u) }
                    }
                    if let error, recent.isEmpty {
                        VStack(spacing: 10) {
                            Text(error).font(.footnote).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center)
                            Button("重试") { Task { await loadRoot() } }.buttonStyle(.bordered)
                        }
                        .padding(24)
                    }
                }
            }
            .refreshable { await loadRoot() }
        }
        .background(Color.black.ignoresSafeArea())
        .foregroundStyle(.white)
        .modifier(DYEdgeSwipeBack(action: onClose))
    }

    @ViewBuilder
    private var friendStrip: some View {
        if !friends.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(friends) { p in
                        Button { openFriend(p) } label: {
                            VStack(spacing: 6) {
                                CachedAsyncImage(url: p.avatar.flatMap(URL.init(string:))) { img in
                                    img.resizable().scaledToFill()
                                } placeholder: {
                                    Circle().fill(Color.white.opacity(0.1))
                                }
                                .frame(width: 58, height: 58)
                                .clipShape(Circle())
                                .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
                                Text(p.name)
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.85))
                                    .lineLimit(1)
                                    .frame(width: 64)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
    }

    private var interactSummary: String {
        guard let h = recent.first(where: DYNoticeKind.isInteractive) else { return "没有新互动" }
        let who = h.name.isEmpty ? "抖音用户" : h.name
        return "\(who) \(h.action)"
    }

    private var fansSummary: String {
        guard let h = recent.first(where: { $0.type == DYNoticeKind.follow }) else {
            return (counts[DYNoticeGroup.fans.rawValue] ?? 0) > 0 ? "有新的粉丝" : "没有新粉丝"
        }
        return "\(h.name) 关注了你"
    }

    private func entry(icon: String, tint: Color, title: String, subtitle: String, badge: Int,
                       id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(tint).frame(width: 50, height: 50)
                    Image(systemName: icon).font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.body.weight(.semibold)).foregroundStyle(.white)
                    Text(subtitle).font(.footnote).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                }
                Spacer(minLength: 8)
                if badge > 0 {
                    Text(badge > 99 ? "99+" : "\(badge)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.red))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    private func loadRoot() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        if let groups = try? await bridge.noticeCounts() {
            counts = Dictionary(groups.map { ($0.group, $0.count) }, uniquingKeysWith: { a, _ in a })
        }
        do {
            recent = try await bridge.notices(group: DYNoticeGroup.all.rawValue, maxTime: 0).items
            error = nil
        } catch {
            if recent.isEmpty { self.error = error.localizedDescription }
        }
        if friends.isEmpty {
            friends = (try? await bridge.followingUsers().items) ?? []
        }
    }

    /// 点朋友头像：打开他的主页（网页版）
    private func openFriend(_ f: DYFriend) {
        guard !f.secUid.isEmpty, let u = URL(string: "https://www.douyin.com/user/\(f.secUid)") else { return }
        onWeb(u)
    }
}

// MARK: - 二级页（互动 / 粉丝 / 系统）

struct DYNoticeListScreen: View {
    let bridge: DouyinBridge
    let route: DYMsgRoute
    let onWeb: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var group: DYNoticeGroup
    @State private var items: [DYNotice] = []
    @State private var maxTime = 0
    @State private var hasMore = true
    @State private var loading = false
    @State private var error: String?
    @State private var author: DYAweme.Author?
    @State private var player: DYMessagePlay?
    @State private var opening = false
    @State private var loadGen = 0

    init(bridge: DouyinBridge, route: DYMsgRoute, onWeb: @escaping (URL) -> Void) {
        self.bridge = bridge
        self.route = route
        self.onWeb = onWeb
        _group = State(initialValue: route.filters[0])
    }

    var body: some View {
        VStack(spacing: 0) {
            DYMsgHeader(onBack: { dismiss() }) {
                HStack(spacing: 8) {
                    titleView
                    if opening { ProgressView().tint(.white).scaleEffect(0.8) }
                }
            }
            list.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.black.ignoresSafeArea())
        .foregroundStyle(.white)
        .task(id: group) { await reload(reset: true) }
        .sheet(item: $author) { a in
            DYAuthorScreen(bridge: bridge, author: a, onWeb: onWeb)
                .presentationDetents([.medium, .large])
                .presentationBackground(.black)
        }
        .fullScreenCover(item: $player) { p in
            DYListPlayer(bridge: bridge, title: p.item.desc.isEmpty ? "视频" : p.item.desc, items: [p.item], start: 0, onAuthor: { author = $0.author })
        }
    }

    /// 互动页标题是下拉菜单（全部互动 / 评论 / 赞），对齐抖音「全部消息 ▾」
    @ViewBuilder
    private var titleView: some View {
        if route.filters.count > 1 {
            Menu {
                ForEach(route.filters) { g in
                    Button { group = g } label: {
                        if g == group { Label(route.filterTitle(g), systemImage: "checkmark") }
                        else { Text(route.filterTitle(g)) }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(route.filterTitle(group))
                    Image(systemName: "chevron.down").font(.caption.weight(.bold))
                }
                .font(.headline.weight(.bold))
                .foregroundStyle(.white)
            }
            .accessibilityIdentifier("douyin.messages.filter")
        } else {
            Text(route.title).font(.headline.weight(.bold))
        }
    }

    /// 互动「全部」走 700 分组，要剔掉关注和系统类
    private var visibleItems: [DYNotice] {
        guard route == .interactive, group == .all else { return items }
        return items.filter(DYNoticeKind.isInteractive)
    }

    @ViewBuilder
    private var list: some View {
        if let error, items.isEmpty {
            VStack(spacing: 12) {
                Text(error).font(.footnote).foregroundStyle(.white.opacity(0.75)).multilineTextAlignment(.center)
                Button("重试") { Task { await reload(reset: true) } }.buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else if items.isEmpty && loading {
            ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visibleItems.isEmpty && !hasMore {
            Text("暂无消息").font(.footnote).foregroundStyle(.white.opacity(0.5))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(visibleItems) { n in
                        Button { Task { await open(n) } } label: { row(n) }
                            .buttonStyle(.plain)
                        Divider().background(Color.white.opacity(0.08))
                    }
                    if hasMore {
                        ProgressView().tint(.white).padding()
                            .onAppear { Task { await reload(reset: false) } }
                    }
                }
            }
            .refreshable { await reload(reset: true) }
        }
    }

    private func row(_ n: DYNotice) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack(alignment: .topTrailing) {
                CachedAsyncImage(url: n.avatar.flatMap(URL.init(string:))) { img in
                    img.resizable().scaledToFill()
                } placeholder: {
                    Color.white.opacity(0.08)
                }
                .frame(width: 44, height: 44)
                .clipShape(Circle())
                if !n.hasRead {
                    Circle().fill(Color.red).frame(width: 8, height: 8).offset(x: 2, y: -2)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(n.name.isEmpty ? "抖音用户" : n.name)
                    .font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(n.detail.isEmpty ? n.action : "\(n.action) · \(n.detail)")
                    .font(.footnote).foregroundStyle(.white.opacity(0.75)).lineLimit(2)
                Text(DYFormat.time(n.time)).font(.caption2).foregroundStyle(.white.opacity(0.45))
            }
            Spacer(minLength: 8)
            if let c = n.cover, let u = URL(string: c) {
                CachedAsyncImage(url: u) { img in img.resizable().scaledToFill() } placeholder: { Color.white.opacity(0.06) }
                    .frame(width: 44, height: 58)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private func reload(reset: Bool) async {
        if !reset && (!hasMore || loading) { return }
        loadGen += 1
        let gen = loadGen
        loading = true
        defer { if gen == loadGen { loading = false } }
        if reset {
            items = []
            maxTime = 0
            hasMore = true
            error = nil
        }
        let pageTime = reset ? 0 : maxTime
        do {
            let page = try await bridge.notices(group: group.rawValue, maxTime: pageTime)
            guard gen == loadGen else { return }
            if reset { items = page.items } else {
                let seen = Set(items.map(\.id))
                items.append(contentsOf: page.items.filter { !seen.contains($0.id) })
            }
            maxTime = page.maxTime
            hasMore = page.hasMore && !page.items.isEmpty && page.maxTime != pageTime
            error = nil
            DYLiveModel.log("DDNOTICE group=\(group.rawValue) n=\(page.items.count) more=\(hasMore) max=\(page.maxTime)")
        } catch {
            guard gen == loadGen else { return }
            if items.isEmpty || reset { self.error = error.localizedDescription }
            hasMore = false
            DYLiveModel.log("DDNOTICE error \(error.localizedDescription)")
        }
    }

    private func open(_ n: DYNotice) async {
        if n.type == 33, let a = n.author {
            author = a
            return
        }
        guard let id = n.awemeID, !id.isEmpty, id != "0" else {
            if let a = n.author { author = a }
            return
        }
        guard !opening else { return }
        opening = true
        defer { opening = false }
        do {
            let item = try await bridge.awemeDetail(id)
            player = DYMessagePlay(item: item)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - 公共部件

/// 消息页顶栏：标题在左，返回键在右（Duo 侧栏标准，合屏/展开一致）
struct DYMsgHeader<Title: View>: View {
    let onBack: () -> Void
    @ViewBuilder let title: () -> Title

    var body: some View {
        HStack(spacing: 8) {
            title()
            Spacer(minLength: 8)
            Button(action: onBack) {
                Image(systemName: "chevron.backward")
                    .font(.headline.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("返回")
            .accessibilityIdentifier("douyin.messages.back")
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .frame(height: 50)
    }
}

/// 根页（fullScreenCover）没有导航栈可退，用左缘右滑关闭
struct DYEdgeSwipeBack: ViewModifier {
    let action: () -> Void
    func body(content: Content) -> some View {
        content.simultaneousGesture(
            DragGesture(minimumDistance: 16)
                .onEnded { v in
                    if v.startLocation.x < 30, v.translation.width > 70,
                       abs(v.translation.height) < abs(v.translation.width) {
                        action()
                    }
                }
        )
    }
}

/// 隐藏导航栏后系统会关掉左缘返回手势；这里把它接回来（只在有上一层时生效）
extension UINavigationController: UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1
    }
}

private struct DYMessagePlay: Identifiable {
    let id = UUID()
    let item: DYAweme
}

extension DYMessagesScreen {
    /// 顶栏红点用的未读合计。700 有数用 700，否则加总。
    static func badge(_ groups: [DYNoticeCount]) -> Int {
        if let all = groups.first(where: { $0.group == DYNoticeGroup.all.rawValue }) { return all.count }
        return groups.reduce(0) { $0 + $1.count }
    }
}
