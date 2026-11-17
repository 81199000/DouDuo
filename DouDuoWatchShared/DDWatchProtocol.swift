// iPhone ⇄ Apple Watch 通信协议（两个 target 共用）。
// 原则：手表不登录、不联网请求抖音，所有数据都由 iPhone 上的 DouDuo（持有登录态）代取后推给手表。
// 传输一律用 JSON Data 包在 ["json": Data] 里，避免 WatchConnectivity 对 plist 类型的限制。
import Foundation

enum DDWatchKey {
    static let cmd = "cmd"
    static let json = "json"
    static let id = "id"
    static let on = "on"
    /// updateApplicationContext 里放登录状态/未读数，手表不必连通 iPhone 也能显示
    static let status = "status"
}

enum DDWatchCmd {
    static let inbox = "inbox"        // 取消息（通知 + 私信）→ reply[json]=DDWatchInbox
    static let videos = "videos"      // 请 iPhone 再推几条视频文件过来 → reply[count]
    static let like = "like"          // 点赞/取消赞（iPhone 代发）→ reply[ok]
    static let status = "status"      // 登录态/未读数 → reply[json]=DDWatchStatus
    /// iPhone → 手表：视频分块（手表在前台且连通时用；比 transferFile 即时，且收到每块都有回执）
    static let chunk = "chunk"
}

enum DDWatchChunk {
    static let size = 48 * 1024
}

struct DDWatchStatus: Codable, Equatable {
    var loggedIn: Bool = false
    var comment = 0, digg = 0, fans = 0, system = 0, chat = 0
    var updated: Double = 0
    var unreadTotal: Int { comment + digg + fans + system + chat }
}

struct DDWatchNotice: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var action: String
    var detail: String
    var time: Double
    var unread: Bool
}

struct DDWatchChat: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var preview: String
    var time: String
    var badge: Int
}

struct DDWatchInbox: Codable, Equatable {
    var status = DDWatchStatus()
    var notices: [DDWatchNotice] = []
    var chats: [DDWatchChat] = []
    /// false = 这次没能向抖音刷新，给的是 iPhone 上的缓存
    var fresh = false
}

/// 随视频文件一起发的元数据
struct DDWatchVideoMeta: Codable, Identifiable, Equatable {
    var id: String
    var desc: String
    var author: String
    var duration: Double
    var liked: Bool
    var width: Double
    var height: Double
}

enum DDWatchCodec {
    static func pack<T: Encodable>(_ v: T) -> [String: Any] {
        [DDWatchKey.json: (try? JSONEncoder().encode(v)) ?? Data()]
    }
    static func unpack<T: Decodable>(_ type: T.Type, from dict: [String: Any]) -> T? {
        guard let d = dict[DDWatchKey.json] as? Data else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }
}
