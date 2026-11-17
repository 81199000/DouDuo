import Foundation

/// 认抖音视频链接（纯函数，单元测试直接编这个文件）
enum DYShareLink {
    enum Target: Equatable {
        /// 已经知道作品 ID（长链接 / 分享页 / modal_id）
        case video(String)
        /// 短链，要先跟随跳转才能拿到 ID
        case short(URL)
    }

    /// 从任意文字（抖音口令、长链接、短链）里找出第一条抖音视频链接
    static func target(in text: String) -> Target? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let ns = text as NSString
        for match in detector.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let url = match.url else { continue }
            if let t = target(for: url) { return t }
        }
        return nil
    }

    static func target(for url: URL) -> Target? {
        guard let host = url.host?.lowercased() else { return nil }
        if host == "v.douyin.com" || host == "iesdouyin.com" && url.path.count <= 12 {
            return url.path.count > 1 ? .short(url) : nil
        }
        guard host == "douyin.com" || host.hasSuffix(".douyin.com") || host.hasSuffix("iesdouyin.com") else { return nil }
        if let id = videoID(in: url) { return .video(id) }
        return nil
    }

    /// www.douyin.com/video/<id>、/note/<id>、iesdouyin.com/share/video/<id>/、?modal_id=<id>
    static func videoID(in url: URL) -> String? {
        let parts = url.pathComponents.filter { $0 != "/" }
        for (i, p) in parts.enumerated() where (p == "video" || p == "note") && i + 1 < parts.count {
            let id = parts[i + 1]
            if isID(id) { return id }
        }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        for key in ["modal_id", "aweme_id", "vid"] {
            if let v = query.first(where: { $0.name == key })?.value, isID(v) { return v }
        }
        return nil
    }

    private static func isID(_ s: String) -> Bool {
        s.count >= 15 && s.count <= 22 && s.allSatisfy(\.isNumber)
    }

}
