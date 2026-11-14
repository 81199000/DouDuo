import SwiftUI
import QuartzCore

/// 主线程开销探针：默认不启动，只有 `-DDPERF 1` 启动参数（或用 UserDefaults 打开）时才开始记录，
/// 所以正式包里带着也几乎零开销，需要时可以现场测量。
/// 目的：老板报「经典模式滑动卡、极简丝滑」时，用数字确认是 body 求值贵还是掉帧，
/// 而不是靠猜。日志前缀 `DDPERF`，写在 Documents/ddlog.txt。
@MainActor
final class DDPerf {
    static let shared = DDPerf()

    private var totals: [String: (ms: Double, n: Int)] = [:]
    private var frames = 0
    private var hitches = 0
    private var worstFrame: Double = 0
    private var lastFrame: CFTimeInterval = 0
    private var link: CADisplayLink?
    private var reportTask: Task<Void, Never>?
    private var started = false

    /// 包住一个视图的 body 求值并计时
    static func timed<V: View>(_ name: String, @ViewBuilder _ build: () -> V) -> V {
        let t0 = CACurrentMediaTime()
        let view = build()
        shared.add(name, (CACurrentMediaTime() - t0) * 1000)
        return view
    }

    func add(_ name: String, _ ms: Double) {
        var t = totals[name] ?? (0, 0)
        t.ms += ms; t.n += 1
        totals[name] = t
    }

    /// 从启动起就跑，每 5 秒输出一次；窗口关闭时按最后一次输出。
    func start() {
        guard !started else { return }
        started = true
        let l = CADisplayLink(target: TargetBox.shared, selector: #selector(TargetBox.tick))
        l.add(to: .main, forMode: .common)
        link = l
        reportTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                self?.flush()
            }
        }
        DDProbeLog.write("DDPERF start maxfps=\(UIScreen.main.maximumFramesPerSecond)")
    }

    func tick(_ ts: CFTimeInterval) {
        defer { lastFrame = ts }
        guard lastFrame > 0 else { return }
        let ms = (ts - lastFrame) * 1000
        frames += 1
        if ms > worstFrame { worstFrame = ms }
        // 一帧超过 24ms 记一次卡顿（60Hz 下约 1.5 帧）
        if ms > 24 { hitches += 1 }
    }

    private func flush() {
        guard frames > 0 || !totals.isEmpty else { return }
        let fps = Double(frames) / 5.0
        let parts = totals.sorted { $0.key < $1.key }
            .map { "\($0.key):\(String(format: "%.2f", $0.value.ms / Double(max($0.value.n, 1))))ms×\($0.value.n)" }
            .joined(separator: " ")
        DDProbeLog.write("DDPERF fps=\(String(format: "%.1f", fps)) hitch=\(hitches)/\(frames) worst=\(String(format: "%.0f", worstFrame))ms \(parts)")
        frames = 0; hitches = 0; worstFrame = 0
        totals.removeAll()
    }
}

private final class TargetBox {
    static let shared = TargetBox()
    @objc func tick(_ link: CADisplayLink) {
        MainActor.assumeIsolated { DDPerf.shared.tick(link.timestamp) }
    }
}

/// 探针自己的日志（Release 里没有 ddWrite）。写 Documents/ddlog.txt，和调试日志同一份文件。
enum DDProbeLog {
    static func write(_ s: String) {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = dir.appendingPathComponent("ddlog.txt")
        let line = "\(Date()) \(s)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
