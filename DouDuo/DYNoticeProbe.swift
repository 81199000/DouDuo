#if DEBUG
import SwiftUI

/// 只读探针：在真实签名页里跑通知接口，把每组「首页 / 翻页」的原始响应字段打出来，
/// 用来定位「消息中心只能显示 10 条 / 20 条」到底是接口只回一页、还是 has_more 判定或分页参数不对。
/// 用法：DOUDUO_NOTICE_PROBE=1 启动，页面显示后把结果复制出来（同时写 DDNOTICE_PROBE 日志）。
struct DYNoticeProbe: View {
    @State private var text = "启动中…"
    private let bridge = DouyinBridge()

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(size: 10, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .onAppear { DYLiveModel.log("DDNOTICE_PROBE appear") }
        .task { await run() }
    }

    private func run() async {
        var lines: [String] = []
        func add(_ s: String) { lines.append(s); text = lines.joined(separator: "\n"); DYLiveModel.log("DDNOTICE_PROBE " + s) }
        // 1) 账号
        var uid = "", sec = ""
        if let u = try? await bridge.selfProfile() {
            uid = u.uid ?? ""; sec = u.secUid ?? ""
            add("SELF uid=\(uid) sec=\(String(sec.prefix(12))) name=\(u.name)")
        } else {
            add("SELF fail")
        }
        // 2) 每组通知：首页 + 用返回的 max_time 再翻两次
        for group in [31, 41, 401, 700] {
            var cursor = 0
            for page in 0..<3 {
                do {
                    let r = try await bridge.noticeProbe(group: group, maxTime: cursor, minTime: 0)
                    add("G\(group) p\(page) in_max=\(cursor) -> status=\(r.status) code=\(r.code ?? -1) n=\(r.count) hasMore=\(r.hasMore) out_max=\(r.maxTime) min=\(r.minTime) total=\(r.total) keys=[\(r.keys)]")
                    if !r.hasMore { add("G\(group) stop hasMore=false"); break }
                    if r.maxTime == cursor { add("G\(group) stop maxTime unchanged"); break }
                    cursor = r.maxTime
                } catch {
                    add("G\(group) p\(page) ERR \(error.localizedDescription)")
                    break
                }
            }
        }
        // 3) 关注/粉丝列表：按 max_time 时间游标翻页（接口把 offset 当只读回显，不可靠）
        for (kind, label) in [(DYRelationKind.following, "following"), (.followers, "followers")] {
            var maxTime = 0
            var offset = 0
            for page in 0..<3 {
                do {
                    let r = try await bridge.relationProbe(kind, uid: uid, secUid: sec, offset: offset, maxTime: maxTime)
                    add("REL \(label) p\(page) in_max=\(maxTime) in_off=\(offset) -> status=\(r.status) n=\(r.count) hasMore=\(r.hasMore) out_max=\(r.maxTime) out_min=\(r.minTime) out_off=\(r.cursor) total=\(r.total)")
                    if !r.hasMore { add("REL \(label) stop hasMore=false"); break }
                    if r.maxTime == maxTime { add("REL \(label) stop max_time unchanged"); break }
                    maxTime = r.maxTime
                    offset += r.count
                } catch {
                    add("REL \(label) p\(page) ERR \(error.localizedDescription)")
                    break
                }
            }
        }
        add("DONE")
    }
}

// MARK: - 探针用的原始字段读取（不改生产路径）

struct DYNoticeProbePage: Decodable {
    let status: Int
    let code: Int?
    let count: Int
    let hasMore: Bool
    let maxTime: Int
    let minTime: Int
    let total: Int
    let keys: String
}

struct DYRelationProbePage: Decodable {
    let status: Int
    let count: Int
    let hasMore: Bool
    let cursor: Int
    let total: Int
    let keys: String
    var maxTime: Int = 0
    var minTime: Int = 0
}

extension DouyinBridge {
    /// 通知接口原始响应（第一页 / 翻页都走这条），字段原样回传，不做业务映射。
    func noticeProbe(group: Int, maxTime: Int, minTime: Int) async throws -> DYNoticeProbePage {
        let js = #"""
        const r = await req('GET', '/aweme/v1/web/notice/?' + q({
          is_new_notice: '1', is_mark_read: '0', count: '10', notice_group: String(group),
          min_time: String(minTime || 0), max_time: String(maxTime || 0)
        }));
        const d = parse(r.t) || {};
        const arr = d.notice_list_v2 || d.notice_list || [];
        return JSON.stringify({
          status: r.s, code: d.status_code ?? null, count: arr.length,
          hasMore: !!d.has_more, maxTime: Number(d.max_time || 0), minTime: Number(d.min_time || 0),
          total: Number(d.total || 0), keys: Object.keys(d).join('|')
        });
        """#
        let d = try await call(js, args: ["group": String(group), "maxTime": String(maxTime), "minTime": String(minTime)], attempts: 1)
        return try JSONDecoder().decode(DYNoticeProbePage.self, from: d)
    }

    /// 关注/粉丝接口原始响应（只回数量与翻页游标）。
    func relationProbe(_ kind: DYRelationKind, uid: String, secUid: String, offset: Int, maxTime: Int = 0) async throws -> DYRelationProbePage {
        let path = kind == .following ? "/aweme/v1/web/user/following/list/?" : "/aweme/v1/web/user/follower/list/?"
        let listKey = kind == .following ? "followings" : "followers"
        let extra = kind == .following ? "is_top: '1', " : ""
        let js = #"""
        const r = await req('GET', '\#(path)' + q({ user_id: uid, sec_user_id: sec, offset: offset,
          min_time: '0', max_time: String(maxTime || 0), count: '20', source_type: '\#(kind == .following ? "4" : "1")', gps_access: '0', address_book_access: '0', \#(extra)}));
        const d = parse(r.t) || {};
        const arr = d.\#(listKey) || [];
        return JSON.stringify({
          status: r.s, count: arr.length, hasMore: !!d.has_more,
          cursor: Number(d.offset || 0), total: Number(d.total || 0), keys: Object.keys(d).join('|'),
          maxTime: Number(d.max_time || 0), minTime: Number(d.min_time || 0)
        });
        """#
        let d = try await call(js, args: ["uid": uid, "sec": secUid, "offset": String(offset), "maxTime": String(maxTime)], attempts: 1)
        return try JSONDecoder().decode(DYRelationProbePage.self, from: d)
    }
}
#endif
