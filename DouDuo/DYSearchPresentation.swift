import SwiftUI

/// Owned by the video host so moving between displays keeps the query and results.
@Observable @MainActor
final class DYSearchSession: Identifiable {
    let id = UUID()
    let initialQuery: String
    var keyword = ""
    var suggestions: [DYSug] = []
    var hot: [DYHot] = []
    var model: DYPagedModel?
    var lastRun = ""
    var initialized = false
    // Keep the host suspended through the result player's dismissal animation.
    var presentsVideo = false
    /// 分类：当前选中的标签、细分词、各分类自己的分页（切分类不重拉已拉过的）
    var tab: DYSearchTab = .general
    var chip: String?
    var guide: [String] = []
    var generalUsers: [DYSearchUser] = []
    var users: DYSearchPager<DYSearchUser>?
    var lives: DYSearchPager<DYLiveRoom>?
    var videos: DYPagedModel?

    init(query: String = "") { initialQuery = query }

    static func transition(_ update: () -> Void) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction, update)
    }
}

struct DYSearchPresentation: ViewModifier {
    let bridge: DouyinBridge
    @Binding var session: DYSearchSession?
    @Binding var isSplit: Bool
    var onOpen: () -> Void = {}
    @State private var allowsSplit = false
    @State private var measuredSplit = false

    private var split: Bool { allowsSplit && session != nil }
    private var fullScreen: Binding<Bool> {
        Binding(get: { session != nil && !allowsSplit }, set: { visible in
            if !visible && !allowsSplit { session = nil }
        })
    }

    func body(content: Content) -> some View {
        // Keep the video in the same position in the view tree while resizing.
        GeometryReader { geometry in
            HStack(spacing: 0) {
                content
                    .frame(width: split ? geometry.size.width / 2 : geometry.size.width,
                           height: geometry.size.height)
                    .environment(\.dySearchHashtag, { openSearch("#" + $0) })
                    .environment(\.dyOpenSearch, openSearch)
                    .environment(\.dySearchPresented, session != nil)
                    .environment(\.dySearchCoversVideo, session != nil && (!split || session?.presentsVideo == true))
                    .accessibilityHidden(session != nil && !split)
                    .allowsHitTesting(session == nil || split)
                if split, let session {
                    search(session)
                        .environment(\.dySearchInSplitPane, true)
                        .frame(width: geometry.size.width / 2, height: geometry.size.height)
                        .accessibilityIdentifier("douyin.search.pane")
                }
            }
            .overlay(alignment: .leading) {
                if split {
                    Rectangle().fill(Color.ddSeparator).frame(width: 1)
                        .offset(x: geometry.size.width / 2 - 0.5)
                        .allowsHitTesting(false)
                        .accessibilityLabel("视频与搜索分界线")
                        .accessibilityIdentifier("douyin.search.divider")
                }
            }
        }
        // Both halves include their own chrome; system sidebars never shift the midpoint.
        // 只在左右分栏时忽略水平安全区。不分栏时必须把系统侧栏宽度传下去，
        // 否则推荐流按钮栏/模块按钮读到 0，不再对齐右侧信号栏（冷启动必现）。
        .ignoresSafeArea(.container, edges: split ? .horizontal : [])
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onGeometryChange(for: Bool.self) { geometry in
                        DYDuoMetrics.isDuoHardware && geometry.size.width > geometry.size.height
                            && geometry.size.width >= 700 && geometry.size.height >= 600
                    } action: { measuredSplit = $0 }
            }
            // The keyboard must not turn a portrait search into a landscape split.
            .ignoresSafeArea(.keyboard)
        }
        // Moving search between its pane and cover would otherwise dismiss a
        // result player presented by that search view.
        .onChange(of: measuredSplit, initial: true) { _, measured in
            if session?.presentsVideo != true { allowsSplit = measured }
        }
        .onChange(of: session?.presentsVideo == true) { _, playing in
            if !playing { allowsSplit = measuredSplit }
        }
        // Publish the available layout before opening search, so the video does
        // not briefly deactivate/reactivate and lose a user's paused state.
        .onChange(of: allowsSplit, initial: true) { _, value in isSplit = value }
        .fullScreenCover(isPresented: fullScreen) {
            if let session { search(session) }
        }
        #if DEBUG
        .overlay(alignment: .topLeading) { DYSearchPlaybackProbeView() }
        #endif
    }

    private func openSearch(_ query: String) {
        DYSearchSession.transition {
            onOpen()
            session = DYSearchSession(query: query)
        }
    }

    private func search(_ value: DYSearchSession) -> some View {
        DYRelatedSearchScreen(bridge: bridge, word: value.initialQuery,
                              session: value, onClose: { DYSearchSession.transition { session = nil } })
            .id(value.id)
    }
}

extension EnvironmentValues {
    @Entry var dySearchCoversVideo = false
    @Entry var dySearchPresented = false
    @Entry var dyOpenSearch: ((String) -> Void)? = nil
    /// 搜索在 Duo 内屏左右分栏的右半屏：左缘是分界线，不做边缘返回
    @Entry var dySearchInSplitPane = false
}

/// The system places this independent item in Duo's native vertical toolbar.
struct DYSearchBackToolbar: ViewModifier {
    let onBack: () -> Void

    func body(content: Content) -> some View {
        content.toolbar {
            if #available(iOS 27.1, *) {
                ToolbarItem(placement: .primaryAction) { back }
                    .axisBehavior(.verticalPreferred)
                    .visibilityPriority(.high)
            } else {
                ToolbarItem(placement: .cancellationAction) { back }
            }
        }
    }

    private var back: some View {
        Button("返回", systemImage: "chevron.backward", action: onBack)
            .labelStyle(.iconOnly)
            .foregroundStyle(.primary)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityIdentifier("douyin.search.back")
    }
}

struct DYHotSearchRow: View {
    let item: DYHot
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.colorScheme) private var scheme
    @ScaledMetric(relativeTo: .footnote) private var badgeSize: CGFloat = 24

    private var rank: Int { item.pos ?? 0 }
    private var accent: Color {
        switch rank {
        case 0: Color(red: 0.32, green: 0.53, blue: 1)
        case 1: Color(red: 1, green: 0.64, blue: 0.08)
        case 2: Color(red: 0.77, green: 0.78, blue: 0.84)
        case 3: Color(red: 0.87, green: 0.49, blue: 0.39)
        default: .secondary
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                if (1...3).contains(rank) {
                    Image(systemName: "hexagon.fill")
                        .resizable().scaledToFit()
                        .foregroundStyle(LinearGradient(colors: [accent.mix(with: .white, by: 0.4), accent],
                                                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    Text(rank, format: .number).font(.footnote.bold().italic()).foregroundStyle(.white)
                } else if rank <= 0 {
                    Image(systemName: "arrow.up.to.line").font(.footnote.bold()).foregroundStyle(accent)
                } else {
                    Text(rank, format: .number).font(.footnote.bold()).foregroundStyle(accent)
                }
            }
            .frame(width: badgeSize, height: badgeSize)
            .accessibilityHidden(true)
            Text(item.word).font(.footnote).foregroundStyle(.primary)
                .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if item.hot > 0 {
                Text(heat).font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(minHeight: 44)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(LinearGradient(colors: [rowTint, .ddSecondaryBackground],
                                     startPoint: .leading, endPoint: .trailing))
        }
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(rank > 0 ? "第\(rank)名" : "置顶")，\(item.word)")
        .accessibilityValue(item.hot > 0 ? "热度 \(heat)" : "")
    }

    private var rowTint: Color {
        if scheme == .light { return accent.opacity(0.08) }
        return rank <= 0 ? Color(red: 0.19, green: 0.25, blue: 0.36)
            : (rank <= 3 ? Color(red: 0.23, green: 0.21, blue: 0.21) : Color(white: 0.14))
    }

    private var heat: String {
        if item.hot >= 100_000_000 { return String(format: "%.1f亿", Double(item.hot) / 100_000_000) }
        if item.hot >= 10_000 { return String(format: "%.1f万", Double(item.hot) / 10_000) }
        return String(item.hot)
    }
}

// MARK: - 搜索分类（综合 / 视频 / 用户 / 直播）

/// 网页版能搜的分类。店铺 / 团购 / 商品 / 图文只有 App 接口，网页搜索接口不提供。
enum DYSearchTab: String, CaseIterable, Identifiable {
    case general = "综合", video = "视频", user = "用户", live = "直播"
    var id: String { rawValue }
}

struct DYSearchUser: Decodable, Identifiable, Hashable {
    let name: String
    let avatar: String?
    let secUid: String
    let uid: String
    let uniqueId: String
    let followers: Int
    let followersText: String
    let signature: String
    let verify: String
    let liveRoomID: String
    var id: String { secUid.isEmpty ? uid : secUid }
    var author: DYAweme.Author { .init(name: name, avatar: avatar, secUid: secUid.isEmpty ? nil : secUid, uid: uid.isEmpty ? nil : uid) }
}

/// 用户 / 直播两个分类的分页列表（视频类复用 DYPagedModel）
@MainActor
final class DYSearchPager<T: Identifiable>: ObservableObject {
    @Published var items: [T] = []
    @Published var loading = false
    @Published var error: String?
    @Published var hasMore = true
    private var cursor = "0"
    private let fetch: (String) async throws -> (items: [T], cursor: String, hasMore: Bool)
    init(fetch: @escaping (String) async throws -> (items: [T], cursor: String, hasMore: Bool)) { self.fetch = fetch }

    func loadMore() async {
        guard !loading, hasMore else { return }
        loading = true
        defer { loading = false }
        do {
            let r = try await fetch(cursor)
            let seen = Set(items.map { "\($0.id)" })
            items.append(contentsOf: r.items.filter { !seen.contains("\($0.id)") })
            hasMore = r.hasMore && !r.items.isEmpty && r.cursor != cursor
            cursor = r.cursor
            error = nil
        } catch {
            self.error = error.localizedDescription
            hasMore = false
        }
    }
}

struct DYSearchDiag: Decodable { let nil_: String?; let keys: String?; let len: Int?; let vc: Bool?
    enum CodingKeys: String, CodingKey { case nil_ = "nil", keys, len, vc }
    var text: String { "nil=\(nil_ ?? "-") len=\(len ?? -1) vc=\(vc == true ? 1 : 0) keys=\(keys ?? "-")" }
}
private struct DYSearchGeneralPage: Decodable {
    let status: Int; let code: Int?; let msg: String?; var diag: DYSearchDiag? = nil
    let items: [DYAweme]; let users: [DYSearchUser]; let guide: [String]
    let cursor: String; let hasMore: Bool
}
private struct DYSearchUserPage: Decodable { let status: Int; let code: Int?; let msg: String?; var diag: DYSearchDiag? = nil; let items: [DYSearchUser]; let cursor: String; let hasMore: Bool }
private struct DYSearchLivePage: Decodable { let status: Int; let code: Int?; let msg: String?; var diag: DYSearchDiag? = nil; let items: [DYLiveRoom]; let cursor: String; let hasMore: Bool }


/// 搜索请求节流：抖音对同一账号短时间内连发搜索会回 verify_check（要求验证、结果为空），
/// 实测几秒后自己恢复。这里把搜索请求排队、两次之间至少隔 1.2 秒，同一请求并发时只发一次；
/// 碰到 verify_check 按 3 秒、6 秒各等一次再试，不做任何验证绕过。
@MainActor
enum DYSearchGate {
    private static var nextSlot = Date.distantPast
    private static var inflight: [String: Task<Data, Error>] = [:]
    static let spacing: TimeInterval = 1.2

    static func isThrottled(_ d: Data) -> Bool {
        guard let s = String(data: d.prefix(4000), encoding: .utf8) else { return false }
        return s.contains("\"nil\":\"verify_check\"") || s.contains("DIAG nil=verify_check")
    }

    static func fetch(key: String, _ op: @escaping @MainActor () async throws -> Data) async throws -> Data {
        if let t = inflight[key] { return try await t.value }
        let t = Task { @MainActor () throws -> Data in
            var last = Data()
            for (attempt, backoff) in [0.0].enumerated() {
                let slot = max(Date(), nextSlot).addingTimeInterval(backoff)
                nextSlot = slot.addingTimeInterval(spacing)
                let wait = slot.timeIntervalSinceNow
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                last = try await op()
                if !isThrottled(last) {
                    if attempt > 0 { DYLiveModel.log("DDSEARCH throttle-recovered attempt=\(attempt)") }
                    return last
                }
                DYLiveModel.log("DDSEARCH throttled attempt=\(attempt) key=\(key.prefix(24))")
            }
            throw DYError.bad("抖音要求验证后才给这页结果，稍后再试")
        }
        inflight[key] = t
        defer { inflight[key] = nil }
        return try await t.value
    }
}

extension DouyinBridge {
    /// 搜索类接口抖音额外校验浏览器页面环境，这几段脚本只在隐藏网页里跑（DYNativeJS.isPageOnly）
    private static let searchUserMap = #"""
    const uumap = u => u ? ({ name: u.nickname || '', avatar: first(u.avatar_thumb) || first(u.avatar_medium) || first(u.avatar_larger),
      secUid: u.sec_uid || '', uid: u.uid ? String(u.uid) : '', uniqueId: u.unique_id || u.short_id || '',
      followers: u.follower_count || 0, followersText: u.follower_count_str || '', signature: u.signature || '',
      verify: u.custom_verify || u.enterprise_verify_reason || '', liveRoomID: u.room_id_str || (u.room_id ? String(u.room_id) : '') }) : null;
    // 翻页游标「offset|search_id」：第二页起必须带第一页的 search_id（= log_pb.impr_id），网页版翻页就是这么带的；
    // 不带会被当成爬虫回 verify_check，并连累同账号后续几次搜索（真机实测）
    const [off, sid] = String(cursor || '0').split('|');
    const sq = (channel, extra) => q(Object.assign({ search_channel: channel, keyword: kw, search_source: off === '0' ? 'normal_search' : 'normal_search',
      query_correct_type: '1', is_filter_search: '0', from_group_id: '', offset: off, count: off === '0' ? '20' : '10',
      need_filter_settings: off === '0' ? '1' : '0', list_type: 'single' }, sid ? { search_id: sid } : {}, extra || {}));
    const nextCur = d => String(d.cursor ?? 0) + '|' + (sid || (d.log_pb && d.log_pb.impr_id) || (d.extra && d.extra.logid) || '');
    const okA = a => a && (a.video || a.images) && !a.is_ads;
    const diag = (r, d) => ({ nil: (d.search_nil_info && (d.search_nil_info.search_nil_type || d.search_nil_info.search_nil_item)) || null,
      keys: Object.keys(d).slice(0, 10).join('|'), len: (r.t || '').length, vc: !!(r.h && /bdturing/i.test(String(r.h))) });
    """#

    static let searchGeneralJS = searchUserMap + #"""
    const r = await req('GET', '/aweme/v1/web/general/search/single/?' + sq('aweme_general'));
    const d = parse(r.t) || {};
    const data = Array.isArray(d.data) ? d.data : [];
    const items = data.filter(x => x && x.type === 1 && okA(x.aweme_info)).map(x => mapA(x.aweme_info));
    const users = data.filter(x => x && x.type === 4).flatMap(x => (x.user_list || []).map(u => uumap(u && u.user_info))).filter(Boolean);
    const guide = (d.guide_search_words || []).map(w => w && w.word).filter(w => typeof w === 'string' && w);
    return JSON.stringify({ status: r.s, code: d.status_code ?? null, msg: d.status_msg || null, diag: diag(r, d), items, users, guide, cursor: nextCur(d), hasMore: !!d.has_more });
    """#

    static let searchUserJS = searchUserMap + #"""
    const r = await req('GET', '/aweme/v1/web/discover/search/?' + sq('aweme_user_web'));
    const d = parse(r.t) || {};
    const items = (d.user_list || []).map(u => uumap(u && u.user_info)).filter(Boolean);
    return JSON.stringify({ status: r.s, code: d.status_code ?? null, msg: d.status_msg || null, diag: diag(r, d), items, cursor: nextCur(d), hasMore: !!d.has_more });
    """#

    static let searchLiveJS = searchUserMap + #"""
    const r = await req('GET', '/aweme/v1/web/live/search/?' + sq('aweme_live'));
    const d = parse(r.t) || {};
    const items = (d.data || []).map(x => x && x.lives).filter(Boolean).map(l => {
      const room = typeof l.rawdata === 'string' ? parse(l.rawdata) : l.rawdata;
      if (!room) return null;
      const su = room.stream_url || {}, o = room.owner || {};
      return { id: String(room.id_str || room.id || ''), webRid: String(o.web_rid || ''), title: room.title || '',
        owner: o.nickname || '', avatar: first(o.avatar_thumb), cover: first(room.cover), ownerSec: o.sec_uid || null,
        ownerUID: o.id_str || (o.id ? String(o.id) : null), ownerFollow: (o.follow_info && o.follow_info.follow_status) || 0,
        viewers: (room.stats && room.stats.user_count_str) || room.user_count_str || (room.user_count ? String(room.user_count) : ''),
        hls: su.hls_pull_url_map || {}, flv: compatibleLiveFLV(su), portrait: su.stream_orientation !== 2, def: su.default_resolution || null };
    }).filter(x => x && x.id && (Object.keys(x.hls).length || Object.keys(x.flv).length));
    return JSON.stringify({ status: r.s, code: d.status_code ?? null, msg: d.status_msg || null, diag: diag(r, d), items, cursor: nextCur(d), hasMore: !!d.has_more });
    """#

    private static func searchError(status: Int, code: Int?, msg: String?) -> Error? {
        if code == 8 || code == 2483 || (msg ?? "").contains("未登录") { return DYError.bad("抖音未登录：请在「我的」中登录后重试") }
        if status < 0 { return DYError.bad("搜索连接失败，请稍后重试") }
        if status != 200 { return DYError.blocked("HTTP \(status)") }
        if let code, code != 0 { return DYError.bad(msg.flatMap { $0.isEmpty ? nil : $0 } ?? "搜索暂不可用（\(code)）") }
        return nil
    }

    func searchGeneral(_ kw: String, offset: String) async throws -> (items: [DYAweme], users: [DYSearchUser], guide: [String], cursor: String, hasMore: Bool) {
        let t0 = Date()
        let d = try await DYSearchGate.fetch(key: "general|\(kw)|\(offset)") { [self] in try await self.call(Self.searchGeneralJS, args: ["kw": kw, "cursor": offset]) }
        let p = try JSONDecoder().decode(DYSearchGeneralPage.self, from: d)
        DYLiveModel.log("DDSEARCH tab=general off=\(offset.split(separator: "|").first ?? "") http=\(p.status) code=\(p.code.map(String.init) ?? "-") n=\(p.items.count) users=\(p.users.count) guide=\(p.guide.count) ms=\(Int(Date().timeIntervalSince(t0) * 1000)) \(p.diag?.text ?? "")")
        if let e = Self.searchError(status: p.status, code: p.code, msg: p.msg) { throw e }
        return (p.items, p.users, p.guide, p.cursor, p.hasMore)
    }

    func searchUsers(_ kw: String, offset: String) async throws -> (items: [DYSearchUser], cursor: String, hasMore: Bool) {
        let d = try await DYSearchGate.fetch(key: "user|\(kw)|\(offset)") { [self] in try await self.call(Self.searchUserJS, args: ["kw": kw, "cursor": offset]) }
        let p = try JSONDecoder().decode(DYSearchUserPage.self, from: d)
        DYLiveModel.log("DDSEARCH tab=user off=\(offset.split(separator: "|").first ?? "") http=\(p.status) code=\(p.code.map(String.init) ?? "-") n=\(p.items.count) \(p.diag?.text ?? "")")
        if let e = Self.searchError(status: p.status, code: p.code, msg: p.msg) { throw e }
        return (p.items, p.cursor, p.hasMore)
    }

    func searchLive(_ kw: String, offset: String) async throws -> (items: [DYLiveRoom], cursor: String, hasMore: Bool) {
        let d = try await DYSearchGate.fetch(key: "live|\(kw)|\(offset)") { [self] in try await self.call(Self.searchLiveJS, args: ["kw": kw, "cursor": offset]) }
        let p = try JSONDecoder().decode(DYSearchLivePage.self, from: d)
        DYLiveModel.log("DDSEARCH tab=live off=\(offset.split(separator: "|").first ?? "") http=\(p.status) code=\(p.code.map(String.init) ?? "-") n=\(p.items.count) \(p.diag?.text ?? "")")
        if let e = Self.searchError(status: p.status, code: p.code, msg: p.msg) { throw e }
        return (p.items, p.cursor, p.hasMore)
    }
}

extension EnvironmentValues {
    /// 搜索结果里点直播间：由推荐页宿主关掉搜索、切到直播频道进房。没有宿主（列表播放页）时不显示「直播」分类。
    @Entry var dyOpenLiveRoom: ((DYLiveRoom) -> Void)? = nil
}

/// 分类标签栏（同官方：文字 + 选中下划线）
struct DYSearchTabBar: View {
    let tabs: [DYSearchTab]
    @Binding var selected: DYSearchTab
    var body: some View {
        HStack(spacing: 26) {
            ForEach(tabs) { t in
                Button { selected = t } label: {
                    VStack(spacing: 5) {
                        Text(t.rawValue)
                            .font(.body.weight(t == selected ? .semibold : .regular))
                            .foregroundStyle(t == selected ? Color.primary : Color.primary.opacity(0.55))
                        Capsule().fill(t == selected ? Color.primary : Color.clear).frame(width: 14, height: 3)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("douyin.search.tab.\(t.rawValue)")
                .accessibilityAddTraits(t == selected ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
    }
}

/// 细分词（官方第二行灰色胶囊：全部 / 最新 / …）。点了就按「关键词 + 细分词」重搜。
struct DYSearchChips: View {
    let words: [String]
    @Binding var selected: String?
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("全部", on: selected == nil) { selected = nil }
                ForEach(words, id: \.self) { w in chip(w, on: selected == w) { selected = w } }
            }
            .padding(.horizontal, 16)
        }
    }
    private func chip(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.subheadline.weight(on ? .semibold : .regular))
                .foregroundStyle(Color.primary.opacity(on ? 1 : 0.7))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(on ? 0.16 : 0.07)))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("douyin.search.chip.\(title)")
    }
}

struct DYSearchUserRow: View {
    let user: DYSearchUser
    var body: some View {
        HStack(spacing: 12) {
            CachedAsyncImage(url: user.avatar.flatMap(URL.init(string:))) { $0.resizable().scaledToFill() }
                placeholder: { Color.primary.opacity(0.08) }
                .frame(width: 56, height: 56).clipShape(Circle())
                .overlay(alignment: .bottom) {
                    if !user.liveRoomID.isEmpty && user.liveRoomID != "0" {
                        Text("直播中").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Capsule().fill(Color.pink)).offset(y: 4)
                    }
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(user.name).font(.body.weight(.semibold)).foregroundStyle(Color.primary).lineLimit(1)
                if !user.verify.isEmpty {
                    Text(user.verify).font(.caption).foregroundStyle(Color.primary.opacity(0.6)).lineLimit(1)
                }
                Text(fansLine).font(.caption).foregroundStyle(Color.primary.opacity(0.55)).lineLimit(1)
                if !user.signature.isEmpty {
                    Text(user.signature).font(.caption).foregroundStyle(Color.primary.opacity(0.45)).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .contentShape(Rectangle())
    }
    private var fansLine: String {
        let fans = user.followersText.isEmpty ? DYSearchUserRow.count(user.followers) : user.followersText
        return user.uniqueId.isEmpty ? "粉丝 \(fans)" : "粉丝 \(fans)  ·  抖音号 \(user.uniqueId)"
    }
    static func count(_ n: Int) -> String {
        n >= 10_000 ? String(format: "%.1fw", Double(n) / 10_000) : "\(n)"
    }
}

/// 滑到底才翻页：最后一项在屏上 + 用户手指拖动过，两者同时成立才拉下一页；每拉一页要重新拖一次
struct DYLoadOnScrollBottom: ViewModifier {
    let lastVisible: Bool
    let load: () -> Void
    @State private var userScrolled = false
    func body(content: Content) -> some View {
        content
            .onScrollPhaseChange { _, phase in if phase == .interacting { userScrolled = true } }
            .onChange(of: lastVisible && userScrolled) { _, ready in
                guard ready else { return }
                userScrolled = false
                load()
            }
    }
}

struct DYSearchUserList: View {
    @ObservedObject var pager: DYSearchPager<DYSearchUser>
    let onOpen: (DYSearchUser) -> Void
    @State private var lastVisible = false
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(pager.items) { u in
                    Button { onOpen(u) } label: { DYSearchUserRow(user: u) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("douyin.search.user.\(u.id)")
                        .onAppear { if u.id == pager.items.last?.id { lastVisible = true } }
                        .onDisappear { if u.id == pager.items.last?.id { lastVisible = false } }
                }
                DYSearchFooter(loading: pager.loading, error: pager.error, empty: pager.items.isEmpty)
            }
        }
        .modifier(DYLoadOnScrollBottom(lastVisible: lastVisible) { Task { await pager.loadMore() } })
        .onChange(of: pager.items.count) { _, _ in lastVisible = false }
        .task { if pager.items.isEmpty { await pager.loadMore() } }
    }
}

struct DYSearchLiveList: View {
    @ObservedObject var pager: DYSearchPager<DYLiveRoom>
    let onOpen: (DYLiveRoom) -> Void
    @State private var lastVisible = false
    private let cols = [GridItem(.adaptive(minimum: 160), spacing: 6)]
    var body: some View {
        ScrollView {
            LazyVGrid(columns: cols, spacing: 6) {
                ForEach(pager.items) { room in
                    Button { onOpen(room) } label: { cell(room) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("douyin.search.live.\(room.id)")
                        .onAppear { if room.id == pager.items.last?.id { lastVisible = true } }
                        .onDisappear { if room.id == pager.items.last?.id { lastVisible = false } }
                }
            }
            .padding(.horizontal, 6)
            DYSearchFooter(loading: pager.loading, error: pager.error, empty: pager.items.isEmpty)
        }
        .modifier(DYLoadOnScrollBottom(lastVisible: lastVisible) { Task { await pager.loadMore() } })
        .onChange(of: pager.items.count) { _, _ in lastVisible = false }
        .task { if pager.items.isEmpty { await pager.loadMore() } }
    }
    private func cell(_ room: DYLiveRoom) -> some View {
        Color.black.aspectRatio(3/4, contentMode: .fit)
            .overlay { CachedAsyncImage(url: room.cover.flatMap(URL.init(string:))) { $0.resizable().scaledToFill() } placeholder: { Color.white.opacity(0.06) } }
            .clipped()
            .overlay(alignment: .topLeading) {
                Text("直播中").font(.caption2.weight(.bold)).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.pink)).padding(6)
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(room.title.isEmpty ? room.owner : room.title).font(.caption.weight(.semibold)).lineLimit(2)
                    Text(room.viewers.isEmpty ? room.owner : "\(room.owner) · \(room.viewers)人在看").font(.caption2).opacity(0.8).lineLimit(1)
                }
                .foregroundStyle(.white).padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom))
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct DYSearchFooter: View {
    let loading: Bool
    let error: String?
    let empty: Bool
    var body: some View {
        if let error {
            Text(error).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(24)
        } else if loading {
            ProgressView().tint(.primary).padding(24)
        } else if empty {
            Text("这里还没有内容").font(.footnote).foregroundStyle(.secondary).padding(40)
        }
    }
}
