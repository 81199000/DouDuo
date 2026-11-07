// 启动时检查 GitHub 有没有新版本。
// 不走 api.github.com（匿名 60 次/小时，容易 403），直接读 releases/latest 的 302 跳转，
// 最终 URL 就是 .../releases/tag/vX.Y.Z，从中取版本号。
import Foundation
import UIKit

struct DDUpdate: Equatable {
    let version: String        // 例如 1.3.1（不带 v）
    let tag: String            // v1.3.1
    var pageURL: URL { URL(string: "https://github.com/\(DDUpdateChecker.repo)/releases/tag/\(tag)")! }
}

enum DDUpdateChecker {
    static let repo = "81199000/DouDuo"
    /// 用户点过「关闭 / 去更新」的版本，记下来就不再提示这个版本
    static let dismissedKey = "douduo_dismissed_update_v1"
    /// 「关于」跳转的开源仓库
    static var repoURL: URL { URL(string: "https://github.com/\(repo)")! }

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
        guard let url = URL(string: "https://github.com/\(repo)/releases/latest") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.setValue("DouDuo-iOS", forHTTPHeaderField: "User-Agent")
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 12
        cfg.httpShouldSetCookies = false
        let session = URLSession(configuration: cfg)
        guard let (_, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse,
              let final = http.url else { return nil }
        // 跟随后最终地址形如 /releases/tag/v1.3.1；没发过 release 会停在 /releases 或 404
        let comps = final.pathComponents
        guard let idx = comps.firstIndex(of: "tag"), idx + 1 < comps.count else { return nil }
        let tag = comps[idx + 1]
        let ver = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard !ver.isEmpty else { return nil }
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
