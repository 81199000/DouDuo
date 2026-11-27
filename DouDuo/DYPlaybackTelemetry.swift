import AVFoundation

/// 正式包也写的播放诊断（进 Documents/ddlog.txt，走 DYLiveModel.log）：
/// - DDSTARTUP：划到这条后多久画面真正动起来，划到那一刻是否就绪 / 缓冲了几秒 / 是否本地文件
/// - DDSTALL：播放中卡住（timeControlStatus 进入 waiting）到恢复用了多久，以及当时缓冲余量
/// 每页一个实例，页面变为当前时 begin，离开时 end（end 会把未结束的卡顿也记下）。
@MainActor
final class DYPlaybackTelemetry {
    /// 非当前页建播放器/解首帧的延迟：错开滑动收尾动画那一帧
    static let setupDelay: TimeInterval = 0.35
    private weak var player: AVPlayer?
    private var id = ""
    private var duration: Double = 0
    private var obs: NSKeyValueObservation?
    private var startAt: Date?
    private var stallAt: Date?
    private var stallPos: Double = 0
    private var stalls = 0
    private var stallTotal: Double = 0

    func begin(_ p: AVPlayer, id: String, duration: Double) {
        end(reason: "switch")
        player = p; self.id = id; self.duration = duration
        stalls = 0; stallTotal = 0; stallAt = nil
        let it = p.currentItem
        let ready = it?.status == .readyToPlay
        let buf = Self.bufferedAhead(p)
        let local = (it?.asset as? AVURLAsset)?.url.isFileURL ?? false
        let t0 = Date(); startAt = t0
        let base = p.currentTime().seconds
        DYLiveModel.log("DDSWIPEIN \(id) dur=\(Int(duration)) ready=\(ready) buf=\(String(format: "%.1f", buf))s local=\(local)")
        // .initial：begin 时播放器可能已经在 playing（上一帧就 rate=1 了），只听 .new 会漏掉这次起播
        // 起播慢诊断：0.6 / 1.5 / 2.5 秒还没动，记下播放器在等什么、边下边播那边是什么状态
        for delay in [0.6, 1.5, 2.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak p] in
                guard let self, let p, self.player === p, self.startAt == t0 else { return }
                let it = p.currentItem
                let ranges = (it?.loadedTimeRanges ?? []).map { r -> String in
                    let v = r.timeRangeValue; return String(format: "%.1f-%.1f", v.start.seconds, CMTimeRangeGetEnd(v).seconds) }.joined(separator: ",")
                let why = p.reasonForWaitingToPlay.map { $0.rawValue.replacingOccurrences(of: "AVPlayerWaiting", with: "").replacingOccurrences(of: "Reason", with: "") } ?? "-"
                let stream = DYStreamStore.shared.debugLine(forVideo: id)
                DYLiveModel.log("DDWAIT \(id.suffix(6)) +\(delay)s tcs=\(p.timeControlStatus.rawValue) rate=\(p.rate) why=\(why) st=\(it?.status.rawValue ?? -1) keepUp=\(it?.isPlaybackLikelyToKeepUp ?? false) empty=\(it?.isPlaybackBufferEmpty ?? false) loaded=[\(ranges)] pos=\(String(format: "%.2f", p.currentTime().seconds)) muted=\(p.isMuted) | \(stream)")
            }
        }
        obs = p.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] pl, _ in
            let status = pl.timeControlStatus
            let pos = pl.currentTime().seconds
            Task { @MainActor in self?.onStatus(status, pos: pos, base: base, t0: t0) }
        }
    }

    private func onStatus(_ s: AVPlayer.TimeControlStatus, pos: Double, base: Double, t0: Date) {
        guard let p = player else { return }
        switch s {
        case .playing:
            DYSwipeProbe.playing()
            if startAt != nil { watchMove(base: base) }
            if let start = startAt {
                startAt = nil
                DYLiveModel.log("DDSTARTUP \(id) 起播=\(String(format: "%.2f", Date().timeIntervalSince(start)))s dur=\(Int(duration))")
            }
            if let at = stallAt {
                let d = Date().timeIntervalSince(at)
                stallAt = nil; stalls += 1; stallTotal += d
                if d >= 0.3 {
                    DYLiveModel.log("DDSTALL \(id) 卡=\(String(format: "%.2f", d))s at=\(String(format: "%.1f", stallPos))/\(Int(duration))s")
                }
            }
        case .waitingToPlayAtSpecifiedRate:
            // 起播前的等待算在 DDSTARTUP 里，不当卡顿
            guard startAt == nil, stallAt == nil else { return }
            if p.reasonForWaitingToPlay == .toMinimizeStalls || p.reasonForWaitingToPlay == .evaluatingBufferingRate {
                stallAt = Date(); stallPos = pos
            }
        default: break
        }
    }

    /// 画面真正往前走（currentTime 越过起点）才算「动起来」
    private func watchMove(base: Double) {
        guard let p = player else { return }
        var n = 0
        func poll() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.008) { [weak self] in
                guard let self, self.player === p else { return }
                if p.currentTime().seconds > base + 0.01 { DYSwipeProbe.moved(); return }
                n += 1; if n < 150 { poll() }
            }
        }
        poll()
    }

    func end(reason: String = "leave") {
        obs?.invalidate(); obs = nil
        if let at = stallAt {
            let d = Date().timeIntervalSince(at)
            stalls += 1; stallTotal += d
            DYLiveModel.log("DDSTALL \(id) 卡=\(String(format: "%.2f", d))s at=\(String(format: "%.1f", stallPos))/\(Int(duration))s 未恢复就\(reason == "switch" ? "切走" : "离开")")
        }
        if let start = startAt, !id.isEmpty {
            DYLiveModel.log("DDSTARTUP \(id) 未起播就离开 等=\(String(format: "%.2f", Date().timeIntervalSince(start)))s dur=\(Int(duration))")
        }
        startAt = nil; stallAt = nil; player = nil
    }

    static func bufferedAhead(_ p: AVPlayer) -> Double {
        guard let it = p.currentItem else { return 0 }
        let now = p.currentTime()
        for r in it.loadedTimeRanges.map(\.timeRangeValue) where r.containsTime(now) || CMTimeCompare(r.start, now) <= 0 {
            let end = CMTimeGetSeconds(CMTimeRangeGetEnd(r))
            if end > now.seconds { return end - now.seconds }
        }
        return 0
    }
}
