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
    /// updateApplicationContext：手机把「可看视频链接清单」推给手表。系统会替手表保存最后一份，
    /// 所以手机 App 没在运行时，手表照样能用上次的清单播放
    static let list = "list"
}

enum DDWatchCmd {
    static let videos = "videos"      // 请 iPhone 再推几条视频文件过来 → reply[count]
    static let like = "like"          // 点赞/取消赞（iPhone 代发）→ reply[ok]
    static let status = "status"      // 登录态 → reply[json]=DDWatchStatus
}

struct DDWatchStatus: Codable, Equatable {
    var loggedIn: Bool = false
    var updated: Double = 0
}

/// 一条可播视频：只存链接，手表用自己的 WiFi 直接拉流，不占存储。
/// url 是抖音的 /aweme/v1/play/ 签名直链（302 到 CDN；实测不需要 cookie，也不需要特殊请求头）
struct DDWatchVideoMeta: Codable, Identifiable, Equatable {
    var id: String
    var desc: String
    var author: String
    var duration: Double
    var liked: Bool
    var width: Double
    var height: Double
    var url: String = ""
    /// 手机取到这条链接的时间（Unix 秒），用来判断链接是否可能过期
    var fetched: Double = 0
}

struct DDWatchList: Codable, Equatable {
    var videos: [DDWatchVideoMeta] = []
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
