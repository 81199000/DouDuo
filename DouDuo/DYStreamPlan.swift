import Foundation

/// 边下边播的纯计算部分（不碰网络 / 播放器，脚本测试直接编译跑）：
/// - 已缓存区间的合并与查询
/// - 「现在最多允许下载到哪个字节」：当前播放的条 = 播放位置 + 前瞻秒数；预加载的条 = 只要开头几秒
/// - MP4 顶层盒子解析：找出 mdat（画面数据）从哪开始，用来把「秒」换算成「字节」
enum DYStreamPlan {
    /// 当前播放的条：比播放位置多下几秒（流量 / 不卡 的平衡点）
    static let lookaheadWiFi: Double = 30
    static let lookaheadCellular: Double = 18
    /// 预加载（还没划到）的条只要开头几秒：划过去能秒开，没划到就不浪费
    static let headSecondsWiFi: Double = 6
    static let headSecondsCellular: Double = 4
    /// 拖进度条 / 文件尾部的 moov：请求落在允许范围外，先给这么多秒的窗口，播放位置跟上后由前瞻接管
    static let jumpWindowSeconds: Double = 8
    /// 不知道文件多大时，第一次只取这么多（够读到 ftyp + moov 头）
    static let probeBytes: Int64 = 512 * 1024
    /// 单次网络请求最多取多少；太大取消不及时，太小握手多
    static let chunkBytes: Int64 = 1 * 1024 * 1024
    /// 请求起点比允许范围还远这么多，才算「跳着读」（拖进度条 / 读尾部 moov）
    static let jumpSlack: Int64 = 512 * 1024
    /// 一次网络请求至少攒够这么多才发（文件尾除外）：播放位置每 0.25 秒推进一点，
    /// 不攒的话会变成几百个 8KB 的小请求，每个都要 0.2–0.4 秒握手 → 播放一直卡（2026-11-20 真机实测）
    static let minFetchBytes: Int64 = 512 * 1024
    /// 预热条在画面数据起点之后至少备这么多（长视频 moov 有 500KB+，以前只够 moov，画面一点没有 →
    /// 划过去还要现下，起播 2–3 秒；模拟器实测）
    static let minimumMediaBytes: Int64 = 768 * 1024
    /// 起码的头部数据（防止码率估算偏小时连首帧都不够）

    static let minimumHeadBytes: Int64 = 384 * 1024

    // MARK: 区间

    /// 合并后的有序不重叠区间 [lower, upper)
    static func insert(_ r: Range<Int64>, into ranges: [Range<Int64>]) -> [Range<Int64>] {
        guard !r.isEmpty else { return ranges }
        var out: [Range<Int64>] = []
        var cur = r
        for x in ranges {
            if x.upperBound < cur.lowerBound || x.lowerBound > cur.upperBound {
                out.append(x)
            } else {
                cur = min(x.lowerBound, cur.lowerBound)..<max(x.upperBound, cur.upperBound)
            }
        }
        out.append(cur)
        return out.sorted { $0.lowerBound < $1.lowerBound }
    }

    /// 从 offset 起本地连续有多少字节
    static func contiguous(from offset: Int64, in ranges: [Range<Int64>]) -> Int64 {
        for r in ranges where r.contains(offset) { return r.upperBound - offset }
        return 0
    }

    /// offset 之后第一个已缓存区间的起点（没有返回 nil）——网络只取到这里为止，后面本地有
    static func nextCachedStart(after offset: Int64, in ranges: [Range<Int64>]) -> Int64? {
        ranges.first { $0.lowerBound > offset }?.lowerBound
    }

    static func covered(_ ranges: [Range<Int64>]) -> Int64 {
        ranges.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
    }

    static func isComplete(_ ranges: [Range<Int64>], total: Int64) -> Bool {
        total > 0 && ranges.count == 1 && ranges[0].lowerBound == 0 && ranges[0].upperBound >= total
    }

    // MARK: 允许下载到哪

    struct Shape: Equatable {
        var total: Int64
        /// 画面数据起点（moov 在前时 = ftyp + moov 之后）；未知时按 0
        var mediaStart: Int64
        var duration: Double

        var bytesPerSecond: Double {
            let d = duration > 0.5 ? duration : 60
            return Double(max(total - mediaStart, 1)) / d
        }

        func offset(at seconds: Double) -> Int64 {
            let t = max(0, seconds)
            return min(total, mediaStart + Int64(bytesPerSecond * t))
        }
    }

    /// 播放位置驱动的上限：当前条 = 位置 + 前瞻；非当前条 = 开头 head 秒
    static func horizon(shape: Shape, playhead: Double?, current: Bool, cellular: Bool) -> Int64 {
        let head = cellular ? headSecondsCellular : headSecondsWiFi
        let ahead = cellular ? lookaheadCellular : lookaheadWiFi
        let seconds = current ? max(head, (playhead ?? 0) + ahead) : head
        let byTime = shape.offset(at: seconds)
        return min(shape.total, max(byTime, shape.mediaStart + max(minimumHeadBytes, minimumMediaBytes)))
    }

    /// 跳着读（拖进度 / 尾部 moov）给的临时窗口
    static func jumpWindow(from start: Int64, shape: Shape) -> Range<Int64> {
        let bytes = max(Int64(shape.bytesPerSecond * jumpWindowSeconds), 1024 * 1024)
        return start..<min(shape.total, start + bytes)
    }

    /// 某个字节位置能不能下：在播放上限内，或者落在某个跳读窗口里
    static func allowedEnd(for offset: Int64, horizon: Int64, windows: [Range<Int64>]) -> Int64 {
        var end = horizon
        for w in windows where w.lowerBound <= offset && offset < w.upperBound { end = max(end, w.upperBound) }
        return end
    }

    /// 下一段网络请求的范围：从 need 开始，到「下一个已缓存区间 / 允许上限 / 单次上限 / 文件尾」为止
    static func nextFetch(need: Int64, ranges: [Range<Int64>], total: Int64?, allowed: Int64) -> Range<Int64>? {
        guard let total else { return need == 0 ? 0..<probeBytes : nil }
        var start = need
        // 跳过本地已有的
        start += contiguous(from: start, in: ranges)
        guard start < total, start < allowed else { return nil }
        var end = min(total, allowed, start + chunkBytes)
        let next = nextCachedStart(after: start, in: ranges)
        if let next { end = min(end, next) }
        guard end > start else { return nil }
        // 攒批：不到 minFetchBytes 且后面还有（没碰到文件尾 / 已缓存区间）就先不发，等允许范围再长一点
        let hitsBoundary = end == total || end == next
        if end - start < minFetchBytes, !hitsBoundary, end == allowed { return nil }
        return start..<end
    }

    // MARK: MP4 顶层盒子

    /// 读顶层盒子头找画面数据起点。read(offset, count) 返回本地已有的数据（不够 8 字节返回 nil）。
    /// - moov 在前（抖音绝大多数）：返回 moov 结束的位置——不需要真的读到 mdat 头，开头一段数据就能算出来；
    /// - mdat 在前（moov 在文件尾）：返回 mdat 头之后，尾部 moov 由「跳读窗口」去取。
    static func mediaStart(total: Int64, read: (Int64, Int) -> Data?) -> Int64? {
        var offset: Int64 = 0
        for _ in 0..<16 {
            guard offset + 8 <= total, let h = read(offset, 16), h.count >= 8 else { return nil }
            var size = Int64(h.prefix(4).reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
            let type = String(decoding: h[h.startIndex + 4..<h.startIndex + 8], as: UTF8.self)
            var header: Int64 = 8
            if size == 1 {
                guard h.count >= 16 else { return nil }
                size = Int64(h[h.startIndex + 8..<h.startIndex + 16].reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
                header = 16
            } else if size == 0 {
                size = total - offset
            }
            guard size >= header else { return nil }
            if type == "moov" { return min(total, offset + size) }
            if type == "mdat" { return offset + header }
            offset += size
        }
        return nil
    }
}
