// 消息中心（对齐抖音消息页）：顶部朋友头像 → 互动/粉丝/系统/私信入口 → 点进分类二级页。
// 全部内容在同一个 ScrollView 里滚动，分类入口不固定在顶部。
// Duo：返回键走系统 toolbar（自动进右侧竖向侧栏）；根页左缘右滑关闭，二级页系统原生左缘返回上一层。
import SwiftUI
import WebKit
import CryptoKit

private struct DYCachedNoticePage: Codable {
    var items: [DYNotice] = []
    var maxTime = 0
    var hasMore = true
}

/// 消息按登录会话分区缓存；只保存会话的哈希，不保存 cookie/token。
@MainActor
private final class DYMessageCache {
    static let shared = DYMessageCache()
    struct Snapshot: Codable {
        var pages: [String: DYCachedNoticePage] = [:]
        var counts: [Int: Int] = [:]
        var friends: [DYFriend] = []
        var conversations: [DYConversationRow] = []
    }
    var snapshot = Snapshot()
    let chatModel = DouyinWebModel()
    private var retainedChatWeb: WKWebView?
    private var scope = ""
    private var refreshing = Set<Int>()
    private var file: URL? {
        guard !scope.isEmpty else { return nil }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("message-cache-v1", isDirectory: true).appendingPathComponent(scope + ".json")
    }
    func prepare() async {
        let cookies: [HTTPCookie] = await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
        let identity = cookies.filter { $0.domain.hasSuffix("douyin.com") && ["sessionid", "sessionid_ss", "uid_tt"].contains($0.name) }
            .sorted { $0.name < $1.name }.map { $0.name + "=" + $0.value }.joined(separator: "|")
        let next = SHA256.hash(data: Data((identity.isEmpty ? "guest" : identity).utf8)).map { String(format: "%02x", $0) }.joined()
        guard next != scope else { return }
        let changingAccount = !scope.isEmpty
        scope = next
        snapshot = Snapshot()
        if let file, let data = try? Data(contentsOf: file), let cached = try? JSONDecoder().decode(Snapshot.self, from: data) {
            snapshot = cached
        }
        if changingAccount {
            chatModel.web?.load(URLRequest(url: URL(string: "https://www.douyin.com/chat")!))
        }
    }
    func retainChat() { retainedChatWeb = chatModel.web }
    func save() {
        guard let file, let data = try? JSONEncoder().encode(snapshot) else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch { DYLiveModel.log("DDMSGCACHE save failed") }
    }
    func page(_ group: Int) -> DYCachedNoticePage? { snapshot.pages[String(group)] }
    func refresh(_ group: Int, bridge: DouyinBridge) async throws -> DYCachedNoticePage {
        if refreshing.contains(group) { return page(group) ?? DYCachedNoticePage() }
        refreshing.insert(group)
        defer { refreshing.remove(group) }
        let account = scope
        let old = page(group)
        let boundary = Int(old?.items.map(\.time).max() ?? 0)
        let known = Set(old?.items.map(\.id) ?? [])
        var incoming: [DYNotice] = []
        var cursor = 0
        var initialCursor = 0
        var initialMore = false
        for batch in 0..<12 {
            let fresh = try await bridge.notices(group: group, maxTime: cursor, minTime: boundary)
            guard scope == account else { throw CancellationError() }
            if batch == 0 { initialCursor = fresh.maxTime; initialMore = fresh.hasMore }
            incoming.append(contentsOf: fresh.items)
            if !fresh.hasMore || fresh.items.isEmpty || fresh.maxTime == cursor || fresh.items.contains(where: { known.contains($0.id) }) { break }
            // 没有缓存时只取首页，历史仍由用户下滑分页获取。
            if old == nil { break }
            cursor = fresh.maxTime
        }
        var byID = Dictionary((old?.items ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for notice in incoming { byID[notice.id] = notice }
        let merged = Array(byID.values.sorted { $0.time == $1.time ? $0.id > $1.id : $0.time > $1.time }.prefix(500))
        let result = DYCachedNoticePage(items: merged, maxTime: old?.maxTime ?? initialCursor, hasMore: old?.hasMore ?? initialMore)
        snapshot.pages[String(group)] = result
        save()
        DYLiveModel.log("DDMSGCACHE refresh group=\(group) min=\(boundary) new=\(incoming.filter { !known.contains($0.id) }.count) cached=\(merged.count)")
        return result
    }
    func store(_ page: DYCachedNoticePage, group: Int) { snapshot.pages[String(group)] = page; save() }
    func markReadAfterExit(_ groups: Set<Int>, bridge: DouyinBridge) async {
        for group in groups {
            do {
                _ = try await bridge.notices(group: group, maxTime: 0, markRead: true)
                for key in Array(snapshot.pages.keys) {
                    guard var page = snapshot.pages[key] else { continue }
                    for i in page.items.indices {
                        let type = page.items[i].type
                        if key == String(group) || (group == 2 && type == 31) || (group == 3 && type == 41) || (group == 401 && type == 33) {
                            page.items[i].hasRead = true
                        }
                    }
                    snapshot.pages[key] = page
                }
                DYLiveModel.log("DDNOTICE read-on-exit group=\(group)")
            } catch { DYLiveModel.log("DDNOTICE read-on-exit failed group=\(group)") }
        }
        if let values = try? await bridge.noticeCounts() {
            snapshot.counts = Dictionary(values.map { ($0.group, $0.count) }, uniquingKeysWith: { a, _ in a })
        }
        save()
    }
}

private struct DYConversationRow: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let avatar: String?
    let preview: String
    let time: String
    let badge: String
    let index: String
    let stranger: Bool
}

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
    @StateObject private var chatModel = DYMessageCache.shared.chatModel
    @State private var viewedGroups: [DYMsgRoute: Set<Int>] = [:]
    @State private var conversations: [DYConversationRow] = []
    @State private var selectedChat: DYConversationRow?
    @State private var chatStatus = "正在加载私信…"
    /// 顶部头像栏 = 朋友（互相关注），来自 familiar/atlist，不是粉丝
    @State private var friends: [DYFriend] = []
    @State private var counts: [Int: Int] = [:]
    @State private var recent: [DYNotice] = []
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        NavigationStack(path: $path) {
            messageContent
                .navigationTitle(selectedChat?.name ?? "消息")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    // Duo：返回/关闭走系统 cancellationAction，系统把它放进右侧竖向侧栏
                    ToolbarItem(placement: .cancellationAction) {
                        Button("返回", systemImage: "chevron.backward", action: backFromMessage)
                            .accessibilityIdentifier("douyin.messages.back")
                    }
                }
                .navigationDestination(for: DYMsgRoute.self) { r in
                    DYNoticeListScreen(bridge: bridge, route: r, onWeb: onWeb, onViewedGroup: { group in viewedGroups[r, default: []].insert(group) })
                }
        }
        .preferredColorScheme(.dark)
        .task { await loadRoot() }
        .task {
            while !Task.isCancelled {
                if selectedChat == nil { await readConversations() }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
        .onChange(of: path) { old, current in
            // 只有真正退出分类才标已读；打开视频/作者弹层不算退出分类。
            guard old.count > current.count, let route = old.last else { return }
            let seen = viewedGroups.removeValue(forKey: route) ?? []
            Task {
                await DYMessageCache.shared.markReadAfterExit(seen, bridge: bridge)
                counts = DYMessageCache.shared.snapshot.counts
                recent = DYMessageCache.shared.page(700)?.items ?? recent
            }
        }
        .onDisappear { DYMessageCache.shared.retainChat() }
    }

    /// 同一个网页实例持续连接；首页只读取会话行，点会话后才显示聊天面板。
    private var messageContent: some View {
        GeometryReader { geo in
          ZStack(alignment: .topLeading) {
            root
                .frame(width: geo.size.width, height: geo.size.height)
                .opacity(selectedChat == nil ? 1 : 0)
                .allowsHitTesting(selectedChat == nil)
                .accessibilityHidden(selectedChat != nil)
            DouyinWebContainer(model: chatModel, zoom: 1, start: URL(string: "https://www.douyin.com/chat")!, reuseExisting: true)
                .frame(width: selectedChat == nil ? 760 : geo.size.width,
                       height: selectedChat == nil ? 640 : geo.size.height)
                .opacity(selectedChat == nil ? 0.001 : 1)
                .allowsHitTesting(selectedChat != nil)
                .accessibilityHidden(selectedChat == nil)
                .accessibilityIdentifier("douyin.messages.chat.detail")
          }
          .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .clipped()
        .modifier(DYEdgeSwipeBack(action: backFromMessage))
    }

    private var conversationRows: some View {
        VStack(spacing: 0) {
            if conversations.isEmpty {
                Text(chatStatus).font(.footnote).foregroundStyle(.secondary).padding(20)
            }
            ForEach(conversations) { row in
                Button { Task { await openConversation(row) } } label: {
                    HStack(spacing: 12) {
                        CachedAsyncImage(url: row.avatar.flatMap(URL.init(string:))) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Image(systemName: "person.crop.circle.fill").resizable().scaledToFit()
                        }
                        .frame(width: 50, height: 50).clipShape(Circle())
                        VStack(alignment: .leading, spacing: 5) {
                            Text(row.name).font(.body.weight(.semibold)).lineLimit(1)
                            Text(row.preview).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 7) {
                            Text(row.time).font(.caption2).foregroundStyle(.secondary)
                            if !row.badge.isEmpty {
                                Text(row.badge).font(.caption2.weight(.bold))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Capsule().fill(Color.red))
                            }
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("douyin.conversation.row")
            }
            if !conversations.isEmpty {
                Button("加载更多会话") {
                    Task {
                        _ = try? await chatModel.web?.evaluateJavaScript(Self.scrollConversationsJS)
                        try? await Task.sleep(for: .milliseconds(500))
                        await readConversations()
                    }
                }
                .font(.footnote).padding(16)
            }
        }
    }

    private func readConversations() async {
        guard let web = chatModel.web else { return }
        do {
            guard let result = try await web.evaluateJavaScript(Self.conversationsJS) as? String,
                  let data = result.data(using: .utf8) else { return }
            let rows = try JSONDecoder().decode([DYConversationRow].self, from: data)
            if rows.isEmpty {
                let text = (try? await web.evaluateJavaScript("document.body.innerText")) as? String ?? ""
                chatStatus = text.contains("验证码登录") ? "私信需要登录，请使用网页版 / 登录" : "正在加载会话；如无记录可稍后重试"
            } else {
                let updated = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                let existing = Set(conversations.map(\.id))
                let merged = rows.filter { !existing.contains($0.id) } + conversations.map { updated[$0.id] ?? $0 }
                if merged != conversations {
                    conversations = merged
                    DYMessageCache.shared.snapshot.conversations = merged
                    DYMessageCache.shared.save()
                }
                DYMessageCache.shared.retainChat()
                chatStatus = ""
            }
        } catch {
            chatStatus = "私信加载失败，请稍后重试"
        }
    }

    private func openConversation(_ row: DYConversationRow) async {
        guard let web = chatModel.web,
              let data = try? JSONEncoder().encode([row.name, row.avatar ?? "", row.index, row.stranger ? "1" : "0"]),
              let args = String(data: data, encoding: .utf8) else { return }
        let script = """
        (() => {
          const [name, avatar, index, stranger] = \(args);
          const selector = stranger === '1' ? '[class*="conversationStrangerBoxwrapper"]' : '[data-e2e="conversation-item"]';
          const rows = [...document.querySelectorAll(selector)];
          const row = rows.find(e => (e.querySelector('[class="conversationConversationItemtitle"]')?.textContent?.trim() || e.innerText.split('\\n')[0].trim()) === name && (!avatar || e.querySelector('img')?.src === avatar));
          if (!row) return false;
          row.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, button: 0 }));
          let style = document.getElementById('dd-chat-only');
          if (!style) { style = document.createElement('style'); style.id = 'dd-chat-only'; document.head.append(style); }
          style.textContent = '[class*="componentsEntrywrapper"] > .semi-resizable-resizable {display:none!important} [class*="componentsRightPanelwrapper"] {width:100%!important;max-width:none!important;flex:1!important;min-width:0!important} [class*="componentsEntrywrapper"] {min-width:0!important;width:100%!important}';
          window.__wuweiMinWidth = 320;
          window.__wuweiFixViewport?.();
          window.dispatchEvent(new Event('resize'));
          return true;
        })()
        """
        if (try? await web.evaluateJavaScript(script)) as? Bool == true {
            selectedChat = row
        } else {
            chatStatus = "会话位置已变化，正在刷新，请再点一次"
            await readConversations()
        }
    }

    private func backFromMessage() {
        guard selectedChat != nil else { onClose(); return }
        selectedChat = nil
        Task {
            _ = try? await chatModel.web?.evaluateJavaScript("document.getElementById('dd-chat-only')?.remove(); window.__wuweiMinWidth=760; window.__wuweiFixViewport?.(); window.dispatchEvent(new Event('resize')); true")
            await readConversations()
        }
    }

    private static let conversationsJS = #"""
    (() => {
      const nodes = [...document.querySelectorAll('[data-e2e="conversation-item"], [class*="conversationStrangerBoxwrapper"]')];
      return JSON.stringify(nodes.map(e => {
        const txt = s => e.querySelector(s)?.textContent?.trim() || '';
        const name = txt('[class="conversationConversationItemtitle"]') || e.innerText.split('\n')[0].trim();
        const avatar = e.querySelector('img')?.src || null;
        const stranger = e.className.includes('StrangerBox');
        const preview = txt('[class*="ConversationItemHinttextBox"]') || txt('[class*="ConversationItemDescleft"]');
        const time = txt('[class*="timeStr"]');
        const badgeNode = e.querySelector('[class*="badge-count"], [class*="BadgeCount"], [class*="badge-dot"]');
        const badge = badgeNode ? (badgeNode.textContent.trim() || '•') : '';
        return { id: name + '|' + (avatar || '') + '|' + stranger, name, avatar, preview, time, badge, index: e.closest('[data-index]')?.dataset.index || '', stranger };
      }).filter(x => x.name));
    })()
    """#

    private static let scrollConversationsJS = #"""
    (() => {
      const root = document.querySelector('[class*="ConversationListwrapper"]');
      if (!root) return false;
      const list = [root, ...root.querySelectorAll('div')].find(e => e.scrollHeight > e.clientHeight + 10 && /auto|scroll/.test(getComputedStyle(e).overflowY));
      if (!list) return false;
      list.scrollTop += list.clientHeight * 0.8;
      list.dispatchEvent(new Event('scroll', { bubbles: true }));
      return true;
    })()
    """#

    private var root: some View {
        VStack(spacing: 0) {
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
                    conversationRows
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
            // 横向 ScrollView 默认会铺进安全区（Duo 侧栏下面），裁回内容框
            .scrollClipDisabled(false)
            .clipped()
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
        .accessibilityValue(String(badge))
    }

    private func loadRoot() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        let cache = DYMessageCache.shared
        await cache.prepare()
        // 先还原本地数据，不清空列表、不挡着等网络；随后只合并增量。
        counts = cache.snapshot.counts
        friends = cache.snapshot.friends
        recent = cache.page(700)?.items ?? []
        conversations = cache.snapshot.conversations
        DYLiveModel.log("DDMSGCACHE restore root=\(recent.count) chats=\(conversations.count)")
        if let groups = try? await bridge.noticeCounts() {
            counts = Dictionary(groups.map { ($0.group, $0.count) }, uniquingKeysWith: { a, _ in a })
            cache.snapshot.counts = counts
        }
        do {
            recent = try await cache.refresh(700, bridge: bridge).items
            error = nil
        } catch {
            if recent.isEmpty { self.error = error.localizedDescription }
        }
        if friends.isEmpty {
            friends = (try? await bridge.followingUsers().items) ?? []
            cache.snapshot.friends = friends
        }
        cache.save()
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
    let onViewedGroup: (Int) -> Void
    @ObservedObject private var emojiStore = DYEmojiStore.shared

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

    init(bridge: DouyinBridge, route: DYMsgRoute, onWeb: @escaping (URL) -> Void, onViewedGroup: @escaping (Int) -> Void) {
        self.bridge = bridge
        self.route = route
        self.onWeb = onWeb
        self.onViewedGroup = onViewedGroup
        let group = route.filters[0]
        _group = State(initialValue: group)
        let cached = DYMessageCache.shared.page(group.rawValue)
        _items = State(initialValue: cached?.items ?? [])
        _maxTime = State(initialValue: cached?.maxTime ?? 0)
        _hasMore = State(initialValue: cached?.hasMore ?? true)
    }

    var body: some View {
        list.frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay { if opening { ProgressView().tint(.white) } }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle(route.filterTitle(group))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarTitleMenu {
            // 互动页点标题切 全部互动 / 评论 / 赞（对齐抖音「全部消息 ▾」）
            if route.filters.count > 1 {
                ForEach(route.filters) { g in
                    Button { group = g } label: {
                        if g == group { Label(route.filterTitle(g), systemImage: "checkmark") }
                        else { Text(route.filterTitle(g)) }
                    }
                }
            }
        }
        .foregroundStyle(.white)
        .task(id: group) {
            await reload(reset: true)
            #if DEBUG
            if ProcessInfo.processInfo.environment["DOUDUO_READ_AUDIT"] == "1", let values = try? await bridge.noticeCounts() {
                DYLiveModel.log("DDREADAUDIT inside-category " + values.map { "\($0.group)=\($0.count)" }.joined(separator: ","))
            }
            #endif
        }
        .task { await emojiStore.load(bridge: bridge) }
        .sheet(item: $author) { a in
            DYAuthorScreen(bridge: bridge, author: a, onWeb: onWeb)
                .presentationDetents([.medium, .large])
                .presentationBackground(.black)
        }
        .fullScreenCover(item: $player) { p in
            DYListPlayer(bridge: bridge, title: p.item.desc.isEmpty ? "视频" : p.item.desc, items: [p.item], start: 0, onAuthor: { author = $0.author })
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
                            .accessibilityIdentifier(n.awemeID == nil ? "douyin.notice.author" : "douyin.notice.video")
                            .accessibilityValue(n.hasRead ? "已读" : "未读")
                            .onAppear {
                                if group != .all { onViewedGroup(group.rawValue) }
                                else if n.type == 31 { onViewedGroup(2) }
                                else if n.type == 41 || n.type == 9009 { onViewedGroup(3) }
                            }
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
                emojiStore.rich(n.detail.isEmpty ? n.action : "\(n.action) · \(n.detail)")
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
        let requestedGroup = group.rawValue
        let cache = DYMessageCache.shared
        loading = true
        defer { if gen == loadGen { loading = false } }
        if reset {
            let cached = cache.page(requestedGroup)
            items = cached?.items ?? []
            maxTime = cached?.maxTime ?? 0
            hasMore = cached?.hasMore ?? true
            error = nil
        }
        do {
            let page: DYCachedNoticePage
            if reset {
                page = try await cache.refresh(requestedGroup, bridge: bridge)
            } else {
                let next = try await bridge.notices(group: requestedGroup, maxTime: maxTime)
                let seen = Set(items.map(\.id))
                page = DYCachedNoticePage(items: items + next.items.filter { !seen.contains($0.id) },
                                          maxTime: next.maxTime,
                                          hasMore: next.hasMore && !next.items.isEmpty && next.maxTime != maxTime)
                cache.store(page, group: requestedGroup)
            }
            guard gen == loadGen else { return }
            items = page.items
            maxTime = page.maxTime
            hasMore = page.hasMore
            error = nil
            DYLiveModel.log("DDNOTICE group=\(requestedGroup) n=\(items.count) read=deferred-until-exit")
        } catch {
            guard gen == loadGen else { return }
            if items.isEmpty { self.error = error.localizedDescription }
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
