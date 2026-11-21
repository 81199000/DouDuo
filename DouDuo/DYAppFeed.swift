import Foundation

/// App 推荐流（抖音 App 的 feed 接口，匿名可用）。
///
/// 网页 `tab/feed` 是网页「推荐」那份，竖屏只占 1～3 成，和 App 里刷到的不是一批内容；
/// App 的 `aweme/v1/feed` 下发的就是 App 那一套（实测竖屏约 8 成），item 结构跟网页同源，
/// aweme_id 通用，播放地址同样走 `api-play.amemv.com` 重定向 → 播放/评论/点赞全按原路径走。
///
/// 只做只读请求：不带签名、不带设备注册；登录态 cookie 默认不带（见 `usesLoginCookie`）。
enum DYAppFeed {
    /// 推荐来源："app" = App 接口（失败退回网页 tab/feed）；"web" = 只听网页推荐
    static let sourceKey = "douyin_feed_source_v1"
    /// 实验开关：把网页登录态 cookie 一起带上，让 App 接口按账号下发（可能触发风控，默认关）
    static let cookieKey = "douyin_feed_app_cookie_v1"

    static var prefersApp: Bool {
        (UserDefaults.standard.string(forKey: sourceKey) ?? "app") != "web"
    }
    static var usesLoginCookie: Bool {
        UserDefaults.standard.bool(forKey: cookieKey)
    }

    /// Android App UA：接口按 UA 判端，换成 Safari/macOS 会当网页端处理
    private static let userAgent =
        "com.ss.android.ugc.aweme/310001 (Linux; U; Android 14; zh_CN; Pixel 7; Build/UQ1A; Cronet/TTNetVersion:1)"
    private static let endpoint = "https://aweme.snssdk.com/aweme/v1/feed/"

    private static let session: URLSession = {
        // 独立会话（不吃 App 的 URL 缓存、不带共享 cookie），每次现拉
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 12
        c.timeoutIntervalForResource = 20
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    /// 拉一页原始 JSON。调用方负责把 JSON 交给页面里的 mapA 映射成统一结构。
    static func fetch(pull: Int) async throws -> Data {
        var comps = URLComponents(string: endpoint)!
        comps.queryItems = [
            .init(name: "type", value: "0"),
            .init(name: "max_cursor", value: "0"),
            .init(name: "min_cursor", value: "0"),
            .init(name: "count", value: "10"),
            .init(name: "pull_type", value: String(pull)),
            .init(name: "aid", value: "1128"),
            .init(name: "app_name", value: "aweme"),
            .init(name: "version_code", value: "310000"),
            .init(name: "version_name", value: "31.0.0"),
            .init(name: "device_platform", value: "android"),
            .init(name: "channel", value: "googleplay"),
            .init(name: "os_version", value: "14"),
            .init(name: "device_type", value: "Pixel 7"),
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if usesLoginCookie, let cookie = await loginCookieHeader() {
            req.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw DYError.blocked("App 接口没有响应") }
        guard http.statusCode == 200 else { throw DYError.blocked("App 接口 HTTP \(http.statusCode)") }
        return data
    }

    /// 网页登录态的 sessionid（与网页版共用 cookie 存储）
    private static func loginCookieHeader() async -> String? {
        let cookies = await DYAccountStore.douyinCookies().filter { $0.name == "sessionid" || $0.name == "sessionid_ss" }
        guard !cookies.isEmpty else { return nil }
        return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }
}
