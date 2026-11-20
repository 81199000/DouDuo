// 启动时检查有没有新版本。
// 读发行版页 releases/latest 的跳转，最终 URL 就是 .../releases/tag/vX.Y.Z，从中取版本号（不走 API，免限流）。
// 2026-11-20：GitHub 旧号 81199000 被封、新号 WuWeiDuo 的仓库暂为私有。更新统一指向自家 oneduo.app：
// 版本号先读 dl.oneduo.app 上的软件源（Cloudflare R2，发版时同步，不限流），读不到再看 Gitee 的 releases/latest 跳转；
// 「去更新」打开 oneduo.app（用一键签装新版，登录态保留）。
import Foundation
import UIKit

struct DDUpdate: Equatable {
    let version: String        // 例如 1.3.1（不带 v）
    let tag: String            // v1.3.1
    var pageURL: URL { DDUpdateChecker.updatePage }
}

enum DDUpdateChecker {
    static let repo = "WuWeiDuo/DouDuo"
    /// 国内镜像（公开），更新检查和下载页以它为准
    static let giteeRepo = "remon8/douduo"
    /// 用户点过「关闭 / 去更新」的版本，记下来就不再提示这个版本
    static let dismissedKey = "douduo_dismissed_update_v1"
    /// 自家分发：软件源（R2）与更新页
    static let sourceURL = URL(string: "https://dl.oneduo.app/douduo/douduo.json")!
    static let updatePage = URL(string: "https://oneduo.app/")!
    /// 「关于」跳转的开源仓库
    static var repoURL: URL { URL(string: "https://gitee.com/\(giteeRepo)")! }

    static var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }

    static var dismissedVersion: String {
        get { UserDefaults.standard.string(forKey: dismissedKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: dismissedKey) }
    }

    /// 有更新返回新版信息，没有/查不到返回 nil
    static func latest() async -> DDUpdate? {
        #if DEBUG
        // 调试：DOUDUO_FAKEUPDATE=1 假装远端有 9.9.9，用来看弹窗长什么样
        if ProcessInfo.processInfo.environment["DOUDUO_FAKEUPDATE"] == "1" {
            return DDUpdate(version: "9.9.9", tag: "v9.9.9")
        }
        #endif
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 12
        cfg.httpShouldSetCookies = false
        let session = URLSession(configuration: cfg)
        // 1. 自家软件源：apps[0].version 就是最新版
        var src = URLRequest(url: sourceURL, timeoutInterval: 12)
        src.setValue("DouDuo-iOS", forHTTPHeaderField: "User-Agent")
        src.cachePolicy = .reloadIgnoringLocalCacheData
        if let (data, resp) = try? await session.data(for: src),
           (resp as? HTTPURLResponse)?.statusCode == 200,
           let update = parseSource(data) {
            return update
        }
        // 2. 兜底：Gitee 发行版 releases/latest 跳转
        for page in ["https://gitee.com/\(giteeRepo)/releases/latest"] {
            guard let url = URL(string: page) else { continue }
            var req = URLRequest(url: url, timeoutInterval: 12)
            req.setValue("DouDuo-iOS", forHTTPHeaderField: "User-Agent")
            guard let (_, resp) = try? await session.data(for: req),
                  let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  let final = http.url,
                  let update = parse(final) else { continue }
            return update
        }
        return nil
    }

    /// 软件源 JSON（全能签格式）→ 最新版本
    static func parseSource(_ data: Data) -> DDUpdate? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let apps = obj["apps"] as? [[String: Any]],
              let ver = apps.first?["version"] as? String,
              ver.first?.isNumber == true else { return nil }
        return DDUpdate(version: ver, tag: "v" + ver)
    }

    /// 跟随跳转后的地址形如 /releases/tag/v1.3.1 → 版本信息；没发过 release 会停在 /releases，返回 nil
    static func parse(_ final: URL) -> DDUpdate? {
        let comps = final.pathComponents
        guard let idx = comps.firstIndex(of: "tag"), idx + 1 < comps.count else { return nil }
        let tag = comps[idx + 1]
        let ver = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard !ver.isEmpty, ver.first?.isNumber == true else { return nil }
        return DDUpdate(version: ver, tag: tag)
    }

    /// 远端版本比本机新？
    static func isNewer(_ remote: String, than local: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        let a = parts(remote), b = parts(local)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// 启动时调用：有新版本且这个版本没被关掉过，就返回它
    static func check() async -> DDUpdate? {
        guard let remote = await latest() else { return nil }
        guard isNewer(remote.version, than: currentVersion) else { return nil }
        guard dismissedVersion != remote.version else { return nil }
        return remote
    }

    static func dismiss(_ update: DDUpdate) { dismissedVersion = update.version }

    @MainActor
    static func open(_ update: DDUpdate) {
        UIApplication.shared.open(update.pageURL)
    }
}
