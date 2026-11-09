// 消息中心。分组未读 + 列表翻页。点评论/赞/推荐打开视频，点关注打开作者。私信只给网页版。
import SwiftUI

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

struct DYMessagesScreen: View {
    let bridge: DouyinBridge
    let onClose: () -> Void
    let onWeb: (URL) -> Void

    @Environment(\.horizontalSizeClass) private var hSize
    @State private var group: DYNoticeGroup = .all
    /// 顶栏头像 = 朋友（互相关注），来自 familiar/atlist
    @State private var friends: [DYFriend] = []
    @State private var counts: [Int: Int] = [:]
    @State private var items: [DYNotice] = []
    @State private var maxTime = 0
    @State private var hasMore = true
    @State private var loading = false
    @State private var error: String?
    @State private var author: DYAweme.Author?
    @State private var player: DYMessagePlay?
    @State private var opening = false
    @State private var loadGen = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            if group == .all { avatarStrip }
            tabs
            if group == .all { aggregation }
            Divider()
            list
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            Button {
                if let u = URL(string: "https://www.douyin.com/chat") { onWeb(u) }
            } label: {
                Label("私信（网页版）", systemImage: "bubble.left.and.bubble.right")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("douyin.messages.chat")
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(Color.black.ignoresSafeArea())
        .foregroundStyle(.white)
        .task(id: group) { await reload(reset: true) }
        .task {
            if friends.isEmpty {
                friends = (try? await bridge.followingUsers().items) ?? []
            }
        }
        .sheet(item: $author) { a in
            DYAuthorScreen(bridge: bridge, author: a, onWeb: onWeb)
                .presentationDetents([.medium, .large])
                .presentationBackground(.black)
        }
        .fullScreenCover(item: $player) { p in
            DYListPlayer(bridge: bridge, title: p.item.desc.isEmpty ? "视频" : p.item.desc, items: [p.item], start: 0, onAuthor: { author = $0.author })
        }
    }

    /// 顶部头像栏 = 朋友（互相关注的人），来自 familiar/atlist，不是粉丝
    private var recentPeople: [DYFriend] { friends }

    private var avatarStrip: some View {
        Group {
            if recentPeople.isEmpty {
                EmptyView()
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(recentPeople) { p in
                            Button { Task { await openFriend(p) } } label: {
                                VStack(spacing: 5) {
                                    CachedAsyncImage(url: p.avatar.flatMap(URL.init(string:))) { img in
                                        img.resizable().scaledToFill()
                                    } placeholder: {
                                        Circle().fill(Color.white.opacity(0.1))
                                    }
                                    .frame(width: 54, height: 54)
                                    .clipShape(Circle())
                                    .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
                                    Text(p.name)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.white.opacity(0.8))
                                        .lineLimit(1)
                                        .frame(width: 58)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
            }
        }
    }

    /// 「全部」页顶部的聚合入口：互动消息 / 粉丝消息 / 系统通知（对齐抖音那三张卡）
    private var aggregation: some View {
        VStack(spacing: 0) {
            aggRow(icon: "heart.fill", tint: Color(red: 0.95, green: 0.30, blue: 0.55),
                   title: "互动消息", subtitle: interactSummary,
                   badge: (counts[DYNoticeGroup.comment.rawValue] ?? 0) + (counts[DYNoticeGroup.digg.rawValue] ?? 0)) {
                group = .digg
            }
            aggRow(icon: "person.fill", tint: Color(red: 0.25, green: 0.55, blue: 0.95),
                   title: "粉丝消息", subtitle: fansSummary,
                   badge: counts[DYNoticeGroup.fans.rawValue] ?? 0) {
                group = .fans
            }
            aggRow(icon: "bell.badge.fill", tint: Color(red: 0.55, green: 0.55, blue: 0.60),
                   title: "系统通知", subtitle: (counts[DYNoticeGroup.system.rawValue] ?? 0) > 0 ? "有新通知" : "没有新通知",
                   badge: counts[DYNoticeGroup.system.rawValue] ?? 0) {
                group = .system
            }
        }
        .background(Color.white.opacity(0.04))
    }

    private var interactSummary: String {
        let hit = items.first { $0.type == 2 || $0.type == 3 }
        guard let h = hit else { return "没有新互动" }
        let c = (counts[DYNoticeGroup.comment.rawValue] ?? 0) + (counts[DYNoticeGroup.digg.rawValue] ?? 0)
        let who = h.detail.isEmpty ? h.action : "\(h.name) \(h.detail)"
        return c > 1 ? "\(who) 等\(c)条新消息" : who
    }

    private var fansSummary: String {
        guard let h = items.first(where: { $0.type == 401 }) else {
            return (counts[DYNoticeGroup.fans.rawValue] ?? 0) > 0 ? "有新的粉丝" : "没有新粉丝"
        }
        return "\(h.name) 关注了你"
    }

    private func aggRow(icon: String, tint: Color, title: String, subtitle: String, badge: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(tint).frame(width: 46, height: 46)
                    Image(systemName: icon).font(.system(size: 19, weight: .semibold)).foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
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
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.25))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Duo 标准：内屏(regular)/合屏时控件走垂直侧栏，返回键贴右侧；
    /// 外屏(compact) 保持左上，符合单手习惯。
    private var header: some View {
        HStack {
            if hSize != .regular {
                Button(action: goBack) {
                    Image(systemName: "chevron.left")
                        .font(.headline.weight(.semibold))
                        .frame(width: 40, height: 40)
                }
                .accessibilityIdentifier("douyin.messages.back")
            }
            Text(group == .all ? "消息" : group.title)
                .font(.headline.weight(.bold))
            Spacer()
            if opening { ProgressView().tint(.white) }
            if hSize == .regular {
                Button(action: goBack) {
                    Image(systemName: "chevron.left")
                        .font(.headline.weight(.semibold))
                        .frame(width: 40, height: 40)
                }
                .accessibilityIdentifier("douyin.messages.back")
            }
        }
        .padding(.horizontal, 8)
    }

    /// 分类内点返回 → 回「全部」上一层；已在全部 → 关闭消息页
    private func goBack() {
        if group != .all {
            group = .all
        } else {
            onClose()
        }
    }

    private var tabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(DYNoticeGroup.allCases) { g in
                    let on = g == group
                    let n = counts[g.rawValue] ?? 0
                    Button { group = g } label: {
                        HStack(spacing: 4) {
                            Text(g.title)
                            if n > 0 { Text(n > 99 ? "99+" : "\(n)").font(.caption2.weight(.bold)) }
                        }
                        .font(.subheadline.weight(on ? .bold : .medium))
                        .foregroundStyle(on ? .black : .white)
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background(Capsule().fill(on ? Color.white : Color.white.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("douyin.messages.tab.\(g.rawValue)")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
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

    /// 「全部」页把互动(2/3)/粉丝(401)/系统(961) 都归到上面的聚合卡里，列表不再重复
    private var visibleItems: [DYNotice] {
        guard group == .all else { return items }
        return items.filter { ![2, 3, 401, 961].contains($0.type) }
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
            async let countTask = bridge.noticeCounts()
            let page = try await bridge.notices(group: group.rawValue, maxTime: pageTime)
            guard gen == loadGen else { return }
            if let groups = try? await countTask {
                counts = Dictionary(uniqueKeysWithValues: groups.map { ($0.group, $0.count) })
            }
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

    /// 点朋友头像：打开他的主页（网页版，原生主页需要 sec_uid 走 author 通道）
    private func openFriend(_ f: DYFriend) async {
        guard !f.secUid.isEmpty, let u = URL(string: "https://www.douyin.com/user/\(f.secUid)") else { return }
        onWeb(u)
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
