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

    /// 阶段打点：长帧发生时，把这帧前后 150ms 内做过什么事打出来，定位主线程被谁占住
    private static var marks: [(t: CFTimeInterval, s: String)] = []
    static func mark(_ text: String) {
        let now = CACurrentMediaTime()
        marks.append((now, text))
        if marks.count > 200 { marks.removeFirst(100) }
    }

    fileprivate static func frame(_ ts: CFTimeInterval) {
        if lastFrame > 0 {
            let gap = ts - lastFrame
            maxGap = max(maxGap, gap)
            if gap > 0.034 {
                drops += 1
                let from = ts - gap - 0.02
                let near = marks.filter { $0.t >= from && $0.t <= ts }.map { "\(Int(($0.t - from) * 1000)):\($0.s)" }
                DYLiveModel.log("DDLONGFRAME gap=\(Int(gap * 1000))ms marks=\(near.joined(separator: " | "))")
            }
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
    /// 不看缓存标记，直接再激活一次（便宜）。VLC 停播时会把音频会话关掉（setActive:NO），
    /// 这里的 active 标记却还是 true → 下一条短视频 play 后一直停着（2026-11-20 真机：
    /// 推荐里刷过直播卡后，下一条缓冲满了 rate=0 不动）。
    static func forceActive() {
        active = false
        ensureActive()
    }
    /// 被打断 / 切后台后要重新激活
    static func invalidate() { active = false }
    /// VLC（推荐里的直播卡）停播是异步的，停完会把整个 App 的音频会话关掉——这时下一条短视频
    /// 往往已经开播了，会被系统直接暂停（2026-11-20 真机：直播后面那条「开始播放然后卡住」）。
    /// 直播卡停播后连续几次发这个通知，当前短视频若被意外停住就重新激活会话接着播。
    static let lostNotification = Notification.Name("DDAudioSessionMaybeLost")
    private static var lostAt = Date.distantPast
    /// 直播卡刚停（4 秒内）：这段时间里短视频被停住，基本都是 VLC 关会话导致的
    static var recentlyLost: Bool { Date().timeIntervalSince(lostAt) < 4 }
    /// 当前音频输出（扬声器 / 蓝牙耳机 …），排查「直播后滑走卡一下」时对照用
    static var routeName: String {
        AVAudioSession.sharedInstance().currentRoute.outputs.map { "\($0.portType.rawValue)" }.joined(separator: "+")
    }
    static func noteVLCStopping() {
        DYLiveModel.log("DDROUTE 直播卡停播 输出=\(routeName)")
        lostAt = Date()
        invalidate()
        for delay in [0.15, 0.3, 0.45, 0.6, 0.8, 1.0, 1.3, 1.6, 2.0, 2.5, 3.0, 3.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                invalidate()
                NotificationCenter.default.post(name: lostNotification, object: nil)
            }
        }
    }
}


import MachO
/// 内存/播放器数打点：判断「同时暖 N 个播放器」到底吃多少内存
enum DYMemoryProbe {
    static var footprintMB: Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<Int32>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard r == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1024 / 1024
    }
}
