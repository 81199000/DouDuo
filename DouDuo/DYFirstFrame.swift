import AVFoundation
import UIKit

/// 「下一条视频」的第一帧：直接从视频流解一张图当封面用。
/// 抖音网页接口给的 cover 是 440x330 的 4:3 缩略图，竖屏视频套上去又糊又放大；自己解首帧，
/// 比例和真画面完全一致，出画面时不会「先放大再纠正」。
/// 只解码不建播放器，代价小，可以提前给后面几条并行准备。
@MainActor
enum DYFirstFrame {
    private static let mem = NSCache<NSString, UIImage>()
    private static var pending: Set<String> = []
    /// 解码队列：并发 2，避免抢当前视频的带宽
    private static let queue = DispatchQueue(label: "douduo.firstframe", qos: .utility, attributes: .concurrent)

    static func cached(_ id: String) -> UIImage? { mem.object(forKey: id as NSString) }

    /// 当前页及其后若干条准备首帧（已在内存/在解的跳过）
    static func prefetch(_ items: [DYAweme], from index: Int, ahead: Int = 3) {
        guard items.indices.contains(index) else { return }
        let window = items[index...].prefix(ahead + 1)
        for a in window {
            guard a.images.isEmpty, let s = a.play, let remote = URL(string: s) else { continue }
            if cached(a.id) != nil || pending.contains(a.id) { continue }
            pending.insert(a.id)
            let url = DYVideoCache.localURL(a.id) ?? remote
            let id = a.id
            queue.async {
                let generated = decode(url)
                DispatchQueue.main.async {
                    pending.remove(id)
                    if let generated { mem.setObject(generated, forKey: id as NSString) }
                }
            }
        }
    }

    private static func decode(_ url: URL) -> UIImage? {
        let asset = url.isFileURL ? AVURLAsset(url: url) : DYMedia.asset(url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 720, height: 1280)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 1.0, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 1.0, preferredTimescale: 600)
        if let cg = try? gen.copyCGImage(at: .zero, actualTime: nil) {
            return UIImage(cgImage: cg)
        }
        return nil
    }
}
