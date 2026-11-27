// 私信会话列表 / 聊天记录走 imapi 原生读取（只读，不发消息）；发送仍经隐藏的私信网页输入框。
// 原生会话直接产出 DYConversationRow，信息页列表、置顶、未读、陌生人判定照旧使用。
import Foundation
import SwiftUI

enum DYNativeChat {
    static var enabled: Bool {
        if let v = UserDefaults.standard.object(forKey: "douduo_native_chat_ui_v1") as? Bool { return v }
        return DYNative.enabled
    }
}

@MainActor
enum DYNativeConversationSync {
    private static var lastFull = Date.distantPast
    private static var inflight: Task<DYConversationSync.Outcome, Never>?

    /// 拉会话 → 补头像昵称 → 合并进缓存（与网页读取同一份 snapshot）。
    /// minInterval：两次完整同步的最短间隔（列表轮询用）。
    static func read(account: String, bridge: DouyinBridge, minInterval: TimeInterval = 4) async -> DYConversationSync.Outcome {
        let cache = DYMessageCache.shared
        guard !account.isEmpty else { return .init() }
        if let inflight { return await inflight.value }
        if Date().timeIntervalSince(lastFull) < minInterval {
            return .init(rows: cache.snapshot.conversations)
        }
        let task = Task { @MainActor () -> DYConversationSync.Outcome in
            await run(account: account, bridge: bridge)
        }
        inflight = task
        let out = await task.value
        inflight = nil
        return out
    }

    private static func run(account: String, bridge: DouyinBridge) async -> DYConversationSync.Outcome {
        let cache = DYMessageCache.shared
        let t0 = Date()
        let all: [DYIMConversation]
        do { all = try await DYNativeIM.shared.loadConversations(maxPages: 10) } catch {
            DYLiveModel.log("DDNATIVECHAT list fail \(error.localizedDescription)")
            if case DYIMError.noLogin = error { return .init(status: "私信需要登录，请使用网页版 / 登录") }
            return .init(rows: cache.snapshot.conversations, status: cache.snapshot.conversations.isEmpty ? "私信加载失败，请稍后重试" : nil)
        }
        lastFull = Date()
        guard cache.accountScope == account else { return .init() }
        let list = all.filter { !$0.hiddenInMainList }
        DYLiveModel.log("DDNATIVECHAT filter total=\(all.count) shown=\(list.count) pending=\(all.filter { $0.type == 1 && $0.mode != 0 && $0.onlySystem }.count) folded=\(all.filter { $0.settingExt["a:s_is_folded"] == "1" }.count) strangerMode=\(all.filter { $0.mode != 0 }.count)")
        let people = list.flatMap { c -> [(uid: UInt64, sec: String)] in
            c.type == 1 ? [(c.peerUID, c.peerSec)] : []
        }
        let users = await DYNativeIM.shared.users(people, bridge: bridge)
        let tUsers = Date()
        let existing = cache.snapshot.conversations
        let old = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let rows = list.map { c -> DYConversationRow in
            let id = "conversation:" + c.id
            let u = users[String(c.peerUID)]
            let prev = old[id]
            let name = c.type == 1 ? (u?.name ?? prev?.name ?? "") : (c.name.isEmpty ? (prev?.name ?? "群聊") : c.name)
            let avatar = c.type == 1 ? (u?.avatar ?? prev?.avatar) : (c.avatar.isEmpty ? prev?.avatar : c.avatar)
            let lastSec = c.last.map { Double($0.createdMS) / 1000 }
            var row = DYConversationRow(
                id: id, name: name.isEmpty ? "抖音用户" : name, avatar: avatar,
                preview: previewText(c), time: lastSec.map(timeLabel) ?? "",
                badge: c.unread > 0 ? (c.unread > 99 ? "99+" : String(c.unread)) : "",
                index: prev?.index ?? "", stranger: false, kind: c.type,
                sec: c.type == 1 ? (c.peerSec.isEmpty ? (u?.sec ?? prev?.sec) : c.peerSec) : nil)
            row.observedAt = prev?.observedAt ?? Date().timeIntervalSince1970
            row.streak = prev?.streak
            row.isPinned = c.pinned
            row.lastMessageTime = lastSec
            row.lastMessageID = c.last.map(\.id)
            return row
        }
        // 网页才有的陌生人聚合项保留（原生只同步好友 / 普通会话收件箱）
        let strangers = existing.filter(\.stranger)
        let merged = (rows + strangers).sorted(by: DYConversationRow.byTimeDesc)
        var out = DYConversationSync.Outcome()
        cache.reconcileHiddenConversations(merged)
        if merged != existing {
            cache.snapshot.conversations = merged
            cache.save()
            out.changed = true
        }
        out.rows = merged
        if merged.isEmpty { out.status = "还没有私信" }
        // 关注关系：im/user/info 已带回来就直接用；没带回来的才走旧的网页查询
        var pairs: [String: (follow: Int, follower: Int?)] = [:]
        for c in list where c.type == 1 {
            if let u = users[String(c.peerUID)], let f = u.follow, !u.sec.isEmpty { pairs[u.sec] = (f, u.follower) }
        }
        cache.applyFollow(pairs)
        let unresolved = merged.compactMap { $0.kind == 1 ? $0.sec : nil }.filter { pairs[$0] == nil }
        if !unresolved.isEmpty { await cache.resolveFollow(unresolved) }
        DYLiveModel.log("DDNATIVECHAT list n=\(rows.count) users=\(users.count) ms=\(Int(tUsers.timeIntervalSince(t0) * 1000)) changed=\(out.changed)")
        return out
    }

    private static func previewText(_ c: DYIMConversation) -> String {
        guard let last = c.last else { return "" }
        let mine = last.sender == DYNativeIM.shared.selfUID && c.type == 2 ? "我: " : ""
        return mine + last.preview
    }

    /// 与网页列表相同的口径：今天 HH:mm、昨天、本周星期几、更早 M/d、跨年 yyyy/M/d
    static func timeLabel(_ seconds: Double) -> String {
        let d = Date(timeIntervalSince1970: seconds), cal = Calendar.current, now = Date()
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        if cal.isDateInToday(d) { f.dateFormat = "HH:mm"; return f.string(from: d) }
        if cal.isDateInYesterday(d) { return "昨天" }
        if let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: now)).day, days < 7 {
            f.dateFormat = "EEEE"; return f.string(from: d)
        }
        f.dateFormat = cal.component(.year, from: d) == cal.component(.year, from: now) ? "M/d" : "yyyy/M/d"
        return f.string(from: d)
    }
}
