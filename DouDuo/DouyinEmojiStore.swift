import SwiftUI
import UIKit

/// 抖音表情包：displayName（"[微笑]"）→ UIImage。
/// 评论里出现 [微笑] 这种文本时，渲染成官方表情图，跟抖音一致。
@MainActor
final class DYEmojiStore: ObservableObject {
    static let shared = DYEmojiStore()
    @Published private(set) var images: [String: UIImage] = [:]
    private var started = false

    func load(bridge: DouyinBridge) async {
        guard !started else { return }
        started = true
        let list = await bridge.emojiList()
        guard !list.isEmpty else { started = false; return }
        await withTaskGroup(of: (String, UIImage?).self) { group in
            for e in list {
                guard let s = e.url, let u = URL(string: s) else { continue }
                group.addTask {
                    guard let (d, _) = try? await URLSession.shared.data(from: u),
                          let img = UIImage(data: d) else { return (e.displayName, nil) }
                    return (e.displayName, img)
                }
            }
            for await (name, img) in group {
                if let img { images[name] = img }
            }
        }
    }

    /// 把 "好[微笑]的" 拼成带表情图的 Text
    func rich(_ s: String) -> Text {
        var out = Text("")
        var buf = ""
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "[", let close = s[i...].firstIndex(of: "]"), s.distance(from: i, to: close) <= 14 {
                let name = String(s[i...close])
                if let img = images[name] {
                    if !buf.isEmpty { out = out + Text(buf); buf = "" }
                    out = out + Text(Image(uiImage: img)).baselineOffset(-2)
                    i = s.index(after: close)
                    continue
                }
            }
            buf.append(s[i])
            i = s.index(after: i)
        }
        if !buf.isEmpty { out = out + Text(buf) }
        return out
    }
}
