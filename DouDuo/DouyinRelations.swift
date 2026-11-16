// 关注 / 粉丝列表：网页接口 following/list、follower/list（要 uid + sec_uid，uid 从 profile/self 的 user.uid 取）。
// 「我的」页头部的关注/粉丝数字点进来 → 本列表页（头像+昵称+签名，下滑翻页），点人 → 现有 DYAuthorScreen。
import SwiftUI

// MARK: - 数据

enum DYRelationKind: String {
    case following, followers
    var title: String { self == .following ? "关注" : "粉丝" }
}

struct DYRelationUser: Identifiable, Decodable, Equatable {
    let uid: String
    let secUid: String
    let name: String
    let avatar: String?
    let signature: String
    var id: String { uid.isEmpty ? secUid : uid }
}

private struct DYRelationPage: Decodable {
    let status: Int
    let items: [DYRelationUser]
    let hasMore: Bool
    let code: Int?
    let msg: String?
    var maxTime: Int = 0
    var minTime: Int = 0
    var total: Int = 0
}

/// 关注/粉丝列表的翻页游标：offset 给「综合排序」，时间游标给「最近/最早」。
struct DYRelationCursor: Equatable {
    var offset = 0
    var maxTime = 0
    var minTime = 0
    /// 游标完全没前进 = 服务端在回同一页，必须停，否则无限请求
    func stalled(by next: DYRelationCursor) -> Bool {
        next.offset == offset && next.maxTime == maxTime && next.minTime == minTime
    }
}

/// 「我的」页点关注/粉丝数字后打开的目标
struct DYRelationsTarget: Identifiable {
    let id = UUID()
    let kind: DYRelationKind
    let user: DYUser
}

// MARK: - 接口

extension DouyinBridge {
    /// 关注 / 粉丝列表（每页 20）
    ///
    /// 翻页游标不能自己编：抖音这两个接口在 source_type=2 时会忽略 offset，只认时间游标。
    /// 实测口径（F2 官方文档 + 网页版请求）：
    /// - 关注：source_type=4（综合排序）时 offset 有效；返回的 max_time/min_time 也可继续用
    /// - 粉丝：source_type=1（最近粉丝）时靠 max_time 翻页，offset 无效
    /// 所以这里用「服务端回的游标」优先，offset 只作为没有游标时的兜底。
    func relationList(_ kind: DYRelationKind, uid: String, secUid: String, cursor: DYRelationCursor) async throws -> (items: [DYRelationUser], next: DYRelationCursor, hasMore: Bool, total: Int) {
        let js = kind == .following ? Self.relationFollowingJS : Self.relationFollowerJS
        let d = try await call(js, args: ["uid": uid, "sec": secUid,
                                          "offset": String(cursor.offset),
                                          "maxTime": String(cursor.maxTime),
                                          "minTime": String(cursor.minTime)])
        let p = try JSONDecoder().decode(DYRelationPage.self, from: d)
        if p.code == 8 || (p.msg ?? "").contains("未登录") { throw DYError.bad("抖音未登录：右上「我的」→ 登录") }
        guard p.status == 200 else { throw DYError.blocked("HTTP \(p.status)") }
        // 翻页游标按接口实测口径（模拟器真机探针，2026-11）：
        // - 粉丝：服务端把 offset 当只读回显（第二页起就归 0），只有 max_time 递减有效 → 用 max_time 翻
        // - 关注：max_time/min_time 恒为 0，服务端只认 offset → 用自己累加的 offset 翻
        var next = cursor
        next.offset = cursor.offset + p.items.count
        if kind == .followers, p.maxTime > 0 { next.maxTime = p.maxTime }
        return (p.items, next, p.hasMore, p.total)
    }

    // MARK: JS（requestJS 里有 req / base / parse / first / q）

    private static let relationMap = #"""
    const rmap = x => x ? ({ uid: String(x.uid || ''), secUid: x.sec_uid || '', name: x.nickname || '',
      avatar: first(x.avatar_larger) || first(x.avatar_thumb), signature: x.signature || '' }) : null;
    """#

    static let relationFollowingJS = relationMap + #"""
    const r = await req('GET', '/aweme/v1/web/user/following/list/?' + q({ user_id: uid, sec_user_id: sec, offset: offset, min_time: String(minTime || 0), max_time: String(maxTime || 0), count: '20', source_type: '4', gps_access: '0', address_book_access: '0', is_top: '1' }));
    const d = parse(r.t) || {};
    return JSON.stringify({ status: r.s, code: d.status_code ?? null, msg: d.status_msg || (r.s === 200 ? null : (r.t || '').slice(0, 80)),
      items: (d.followings || []).map(rmap).filter(Boolean), hasMore: !!d.has_more,
      maxTime: Number(d.max_time || 0), minTime: Number(d.min_time || 0), total: Number(d.total || 0) });
    """#

    static let relationFollowerJS = relationMap + #"""
    const r = await req('GET', '/aweme/v1/web/user/follower/list/?' + q({ user_id: uid, sec_user_id: sec, offset: offset, min_time: String(minTime || 0), max_time: String(maxTime || 0), count: '20', source_type: '3', gps_access: '0', address_book_access: '0' }));
    const d = parse(r.t) || {};
    return JSON.stringify({ status: r.s, code: d.status_code ?? null, msg: d.status_msg || (r.s === 200 ? null : (r.t || '').slice(0, 80)),
      items: (d.followers || []).map(rmap).filter(Boolean), hasMore: !!d.has_more,
      maxTime: Number(d.max_time || 0), minTime: Number(d.min_time || 0), total: Number(d.total || 0) });
    """#
}

// MARK: - 分页模型（游标翻页，和 DYPagedModel 的 cursor 版分开）

@MainActor
final class DYRelationModel: ObservableObject {
    @Published var items: [DYRelationUser] = []
    @Published var loading = false
    @Published var error: String?
    @Published var hasMore = true
    /// 抖音给的列表总数（用来判断「到底了」和排查「只显示 20 个」）
    @Published var total = 0
    private var cursor = DYRelationCursor()
    private let fetch: (DYRelationCursor) async throws -> (items: [DYRelationUser], next: DYRelationCursor, hasMore: Bool, total: Int)

    init(fetch: @escaping (DYRelationCursor) async throws -> (items: [DYRelationUser], next: DYRelationCursor, hasMore: Bool, total: Int)) {
        self.fetch = fetch
    }

    func reset() { items = []; cursor = DYRelationCursor(); hasMore = true; error = nil; total = 0 }

    @discardableResult
    func loadMore() async -> [DYRelationUser] {
        guard !loading, hasMore else { return [] }
        loading = true
        defer { loading = false }
        do {
            let asked = cursor
            let r = try await fetch(asked)
            let seen = Set(items.map(\.id))
            let fresh = r.items.filter { !seen.contains($0.id) }
            items.append(contentsOf: fresh)
            if r.total > 0 { total = r.total }
            // 停止条件：服务端说没有了 / 这一页空 / 游标没前进（防无限回同一页）
            // 注意 offset 是客户端累加的，只看它必然前进；真正的判据是「这一页没有新数据」或时间游标没动。
            let timeStalled = asked.maxTime > 0 && r.next.maxTime == asked.maxTime
            hasMore = r.hasMore && !r.items.isEmpty && !timeStalled && !fresh.isEmpty
            DYLiveModel.log("DDREL page n=\(r.items.count) fresh=\(fresh.count) total=\(r.total) more=\(hasMore) next=\(r.next.offset)/\(r.next.maxTime)")
            cursor = r.next
            error = nil
            return fresh
        } catch {
            self.error = error.localizedDescription
            hasMore = false
            return []
        }
    }
}

// MARK: - 列表页

struct DYRelationsScreen: View {
    let bridge: DouyinBridge
    let kind: DYRelationKind
    let uid: String
    let secUid: String
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: DYRelationModel
    @State private var open: DYRelationUser?

    init(bridge: DouyinBridge, kind: DYRelationKind, uid: String, secUid: String) {
        self.bridge = bridge; self.kind = kind; self.uid = uid; self.secUid = secUid
        _model = StateObject(wrappedValue: DYRelationModel { cur in
            try await bridge.relationList(kind, uid: uid, secUid: secUid, cursor: cur)
        })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left").font(.headline.weight(.semibold)).foregroundStyle(Color.primary)
                        .frame(width: 40, height: 40)
                }
                .accessibilityIdentifier("douyin.relations.back")
                // 有总数时显示「已加载 / 总数」，否则显示已加载条数
                Text(model.total > model.items.count ? "\(kind.title)（\(model.items.count)/\(model.total)）"
                                                     : "\(kind.title)（\(model.items.count)）")
                    .font(.headline).foregroundStyle(Color.primary).shadow(radius: 3)
                Spacer()
            }
            .padding(.leading, 22).padding(.top, 10)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.items) { u in
                        Button { open = u } label: { row(u) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("douyin.relations.row")
                            .onAppear {
                                // 滑到最后一行就拉下一页
                                if u.id == model.items.last?.id { Task { await model.loadMore() } }
                            }
                    }
                    if model.loading {
                        ProgressView().tint(.primary).padding(.vertical, 20)
                    } else if let e = model.error {
                        Text(e).font(.footnote).foregroundStyle(Color.primary.opacity(0.7)).padding(.vertical, 20)
                    } else if !model.hasMore, !model.items.isEmpty {
                        Text("到底了").font(.caption).foregroundStyle(Color.primary.opacity(0.5)).padding(.vertical, 20)
                    } else if model.items.isEmpty {
                        Text(kind == .following ? "还没有关注任何人" : "还没有粉丝").font(.footnote)
                            .foregroundStyle(Color.primary.opacity(0.7)).frame(maxWidth: .infinity).padding(.top, 40)
                    }
                }
            }
        }
        .background(Color.ddBackground.ignoresSafeArea())
        .dyEdgeBack { dismiss() }
        .task { await model.loadMore() }
        .fullScreenCover(item: $open) { u in
            NavigationStack {
                DYAuthorScreen(bridge: bridge,
                               author: DYAweme.Author(name: u.name, avatar: u.avatar,
                                                      secUid: u.secUid.isEmpty ? nil : u.secUid,
                                                      uid: u.uid.isEmpty ? nil : u.uid),
                               onWeb: { _ in })
            }
        }
    }

    private func row(_ u: DYRelationUser) -> some View {
        HStack(spacing: 12) {
            CachedAsyncImage(url: u.avatar.flatMap(URL.init(string:))) { img in img.resizable().scaledToFill() }
                placeholder: { Color.primary.opacity(0.1) }
                .frame(width: 48, height: 48).clipShape(Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(u.name).font(.subheadline.weight(.semibold)).foregroundStyle(Color.primary)
                if !u.signature.isEmpty {
                    Text(u.signature).font(.caption).foregroundStyle(Color.primary.opacity(0.6)).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}
