import SwiftUI
import UIKit
import WebKit
import CryptoKit

/// 聊天画面快照缓存（像微信那样点进会话立刻看到上次的聊天记录）。
///
/// 私信是网页渲染的，同一个 WKWebView 每次进会话都要在后台切 DOM（真机约 0.5~0.9s），
/// 现在：离开会话/会话停稳时把聊天区截一张图，按「账号+会话+尺寸+深浅色」存内存和磁盘；
/// 下次点进去先把这张图铺上，网页切好后无缝换成真网页（同位置同尺寸，看不出切换）。
@MainActor
final class DYChatSnapshotCache {
    static let shared = DYChatSnapshotCache()

    struct Key: Hashable {
        let scope: String
        let chatID: String
        let width: Int
        let height: Int
        let dark: Bool
        var file: String {
            let raw = "\(scope)|\(chatID)|\(width)x\(height)|\(dark ? "d" : "l")"
            return SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined().prefix(32) + ".jpg"
        }
    }

    private let memory = NSCache<NSString, UIImage>()
    private let dir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("chat-snapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    private let io = DispatchQueue(label: "douduo.chat-snapshot.io", qos: .utility)

    private init() {
        memory.countLimit = 40
    }

    func key(scope: String, chatID: String, size: CGSize, dark: Bool) -> Key? {
        guard !scope.isEmpty, !chatID.isEmpty, size.width > 10, size.height > 10 else { return nil }
        return Key(scope: scope, chatID: chatID, width: Int(size.width.rounded()), height: Int(size.height.rounded()), dark: dark)
    }

    /// 只读内存 + 同步读一次磁盘（单张 JPEG 很小，读一次 < 5ms），点下会话那一帧就要用
    func image(for key: Key) -> UIImage? {
        if let hit = memory.object(forKey: key.file as NSString) { return hit }
        let url = dir.appendingPathComponent(key.file)
        guard let data = try? Data(contentsOf: url), let img = UIImage(data: data, scale: UIScreen.main.scale) else { return nil }
        memory.setObject(img, forKey: key.file as NSString)
        return img
    }

    /// 截网页当前画面（只在聊天画面已经停稳、可见时调用）
    func capture(_ web: WKWebView, key: Key) async {
        guard web.bounds.width > 10, web.bounds.height > 10 else { return }
        let t0 = Date()
        let config = WKSnapshotConfiguration()
        config.afterScreenUpdates = false
        let img: UIImage? = await withCheckedContinuation { cont in
            web.takeSnapshot(with: config) { image, _ in cont.resume(returning: image) }
        }
        guard let img else { return }
        memory.setObject(img, forKey: key.file as NSString)
        let url = dir.appendingPathComponent(key.file)
        let d = dir
        io.async {
            if let data = img.jpegData(compressionQuality: 0.82) { try? data.write(to: url, options: .atomic) }
            // 磁盘只留最近 80 张（约 10~20MB），老的删掉
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: [.contentModificationDateKey]),
                  files.count > 80 else { return }
            let dated = files.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            for (f, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(80) { try? fm.removeItem(at: f) }
        }
        DYLiveModel.log("DDCHAT_SNAP save id=\(key.chatID.suffix(6)) ms=\(Int(Date().timeIntervalSince(t0) * 1000))")
    }

    /// 储存空间页「清理缓存」
    func clear() async -> Bool {
        memory.removeAllObjects()
        let directory = dir
        return await withCheckedContinuation { continuation in
            io.async { continuation.resume(returning: DYStorageFiles.resetCacheDirectory(directory)) }
        }
    }

    /// 切账号/退出登录时清掉，别让上一个账号的聊天画面露出来
    func clearAll() {
        memory.removeAllObjects()
        let d = dir
        io.async {
            try? FileManager.default.removeItem(at: d)
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
    }
}
