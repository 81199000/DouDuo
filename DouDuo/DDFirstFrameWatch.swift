import AVFoundation
import UIKit

/// 首帧看门狗：起播后用 CADisplayLink 轮询 AVPlayerItemVideoOutput 有没有真拿到像素帧。
///
/// 为什么不看 timeControlStatus：实测 `hev1` 标签的 HEVC，AVPlayer 报 readyToPlay、tcs=playing、
/// 时间轴照走（声音在出），可一帧像素都没解出来（presentationSize=0）——用户看到的就是干等黑屏。
/// 只有「拿到 pixel buffer」才算画面真出来了。
///
/// 输出必须在播放器还停着时挂上（起播中给 item 加 VideoOutput 会让管线重建、回弹一帧，见 DYAmbientFrameView），
/// 所以 attach 在 setup 里做，begin 在页面接管起播时做。
@MainActor
final class DDFirstFrameWatch {
    /// 接管后多久还没出像素帧就降级（先写常量，验证有效后再考虑放设置里）
    static let fallbackAfter: TimeInterval = 0.8
    /// 「播放器自认为在播」至少要持续这么久才判解码器不行（刚开始走的那一下还没轮到出帧）
    static let playingGrace: TimeInterval = 0.4
    /// 数据真的到位才怪解码器：前方缓冲不足这个数就是网络问题，交给原来的起播看门狗
    static let minBuffered: Double = 0.5
    /// 一直没结果就别轮询了
    static let giveUpAfter: TimeInterval = 20

    struct Context {
        let player: AVPlayer
        /// 仍是这一路在播（当前页、没被暂停、没换播放器 / 没换 VLC、没在拖进度）
        let eligible: () -> Bool
        /// 画面层报过 isReadyForDisplay = 解码器出过帧，不能判它解不动
        let layerShown: () -> Bool
        let log: (String) -> Void
        let fallback: (Int) -> Void
    }

    private let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
    private weak var attachedItem: AVPlayerItem?
    private var link: CADisplayLink?
    private var ctx: Context?
    private(set) var startedAt: Date?
    private var playingSince: Date?
    private var startPosition: Double = 0
    private var reportedLayerOnly = false

    /// 还停着的时候挂上（同一个 item 重复调用无副作用）
    func attach(_ item: AVPlayerItem?) {
        guard let item, attachedItem !== item else { return }
        detach()
        item.add(output)
        attachedItem = item
    }

    /// 拆播放器 / 还给预热池前摘掉，别让输出跟着 item 回池里越挂越多
    func detach() {
        stop()
        attachedItem?.remove(output)
        attachedItem = nil
    }

    func begin(_ c: Context) {
        stop()
        guard let item = c.player.currentItem else { return }
        attach(item)
        ctx = c
        startedAt = Date()
        playingSince = nil
        startPosition = c.player.currentTime().seconds
        reportedLayerOnly = false
        let l = CADisplayLink(target: DDFirstFrameTick(self), selector: #selector(DDFirstFrameTick.tick))
        l.add(to: .main, forMode: .common)
        link = l
    }

    func stop() {
        link?.invalidate(); link = nil
        ctx = nil
    }

    private func hasFrame(_ item: AVPlayerItem) -> Bool {
        let t = output.itemTime(forHostTime: CACurrentMediaTime())
        if output.hasNewPixelBuffer(forItemTime: t), output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) != nil { return true }
        let now = item.currentTime()
        return output.hasNewPixelBuffer(forItemTime: now) && output.copyPixelBuffer(forItemTime: now, itemTimeForDisplay: nil) != nil
    }

    fileprivate func tick() {
        guard let c = ctx, let t0 = startedAt else { stop(); return }
        let p = c.player
        let elapsed = Date().timeIntervalSince(t0)
        let ms = Int(elapsed * 1000)
        guard let item = p.currentItem, item === attachedItem, c.eligible() else {
            if elapsed > 0.3 { c.log("ms=\(ms) fallback=none why=left") }
            stop(); return
        }
        if hasFrame(item) {
            c.log("ms=\(ms) fallback=av")
            stop(); return
        }
        if elapsed > Self.giveUpAfter {
            c.log("ms=-1 fallback=none why=timeout st=\(item.status.rawValue) tcs=\(p.timeControlStatus.rawValue) layer=\(c.layerShown())")
            stop(); return
        }
        // 画面层出过帧但输出没拿到（输出挂晚了等）：不怪解码器，记一笔不降级
        if c.layerShown() {
            if elapsed > 3, !reportedLayerOnly { reportedLayerOnly = true; c.log("ms=-1 fallback=none why=layer-only") }
            return
        }
        guard UIApplication.shared.applicationState == .active else { return }
        // 只在「item 已 readyToPlay、数据也到了、播放器自认为在播（或时间轴在走）却没出像素」时判解码器不行
        guard item.status == .readyToPlay else { playingSince = nil; return }
        let pos = p.currentTime().seconds
        let moving = p.timeControlStatus == .playing || (pos.isFinite && pos > startPosition + 0.1)
        guard moving else { playingSince = nil; return }
        if playingSince == nil { playingSince = Date() }
        guard elapsed >= Self.fallbackAfter,
              let since = playingSince, Date().timeIntervalSince(since) >= Self.playingGrace,
              DYPlaybackTelemetry.bufferedAhead(p) >= Self.minBuffered || pos > startPosition + 0.3,
              item.tracks.contains(where: { $0.assetTrack?.mediaType == .video }) else { return }
        stop()
        c.fallback(ms)
    }
}

/// CADisplayLink 会强引用 target：用中间人弱引用看门狗，页面销毁时不被它吊着
private final class DDFirstFrameTick: NSObject {
    weak var watch: DDFirstFrameWatch?
    init(_ w: DDFirstFrameWatch) { watch = w }
    @MainActor @objc func tick() { watch?.tick() }
}
