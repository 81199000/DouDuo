import QuartzCore
import Foundation

/// 正式包也写：一次竖滑从「手指抬起」到「画面真正动起来」各段耗时，以及这段时间主线程掉帧情况。
/// DDSWIPET lift→active / active→rate / rate→playing / playing→move（毫秒），maxGap = 最长一帧间隔（>34ms 肉眼可见顿挫）。
@MainActor
enum DYSwipeProbe {
    private static var liftAt: CFTimeInterval = 0
    private static var activeAt: CFTimeInterval = 0
    private static var rateAt: CFTimeInterval = 0
    private static var playingAt: CFTimeInterval = 0
    private static var id = ""
    private static var link: CADisplayLink?
    private static var lastFrame: CFTimeInterval = 0
    private static var maxGap: CFTimeInterval = 0
    private static var drops = 0
    private static let target = Tick()

    static func lift() {
        liftAt = CACurrentMediaTime(); activeAt = 0; rateAt = 0; playingAt = 0
        maxGap = 0; drops = 0; lastFrame = 0
        link?.invalidate()
        let l = CADisplayLink(target: target, selector: #selector(Tick.tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
        // 1.2 秒后收尾（没走完的也记下，方便看卡在哪段）
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { finish(moved: nil) }
    }
    static func active(_ vid: String) { id = vid; if activeAt == 0 { activeAt = CACurrentMediaTime() } }
    static func rate() { if rateAt == 0 { rateAt = CACurrentMediaTime() } }
    static func playing() { if playingAt == 0 { playingAt = CACurrentMediaTime() } }
    static func moved() { finish(moved: CACurrentMediaTime()) }

    fileprivate static func frame(_ ts: CFTimeInterval) {
        if lastFrame > 0 {
            let gap = ts - lastFrame
            maxGap = max(maxGap, gap)
            if gap > 0.034 { drops += 1 }
        }
        lastFrame = ts
    }

    private static func finish(moved: CFTimeInterval?) {
        guard link != nil, liftAt > 0 else { return }
        link?.invalidate(); link = nil
        func ms(_ a: CFTimeInterval, _ b: CFTimeInterval) -> String { a > 0 && b > 0 ? String(Int((b - a) * 1000)) : "-" }
        let m = moved ?? 0
        DYLiveModel.log("DDSWIPET \(id) lift→active=\(ms(liftAt, activeAt)) active→rate=\(ms(activeAt, rateAt)) rate→playing=\(ms(rateAt, playingAt)) playing→move=\(ms(playingAt, m)) total=\(ms(liftAt, m))ms maxGap=\(Int(maxGap * 1000))ms drops=\(drops)")
        liftAt = 0
    }

    private final class Tick: NSObject {
        @objc func tick(_ l: CADisplayLink) { MainActor.assumeIsolated { DYSwipeProbe.frame(l.timestamp) } }
    }
}

import AVFoundation
/// 音频会话只激活一次：每次滑动都同步调 setCategory/setActive(true) 会在主线程阻塞几到几十毫秒
@MainActor
enum DDAudioSessionGate {
    private static var active = false
    static func ensureActive() {
        let s = AVAudioSession.sharedInstance()
        if active, s.category == .playback { return }
        try? s.setCategory(.playback)
        try? s.setActive(true)
        active = true
    }
    /// 被打断 / 切后台后要重新激活
    static func invalidate() { active = false }
}
