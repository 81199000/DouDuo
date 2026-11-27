import SwiftUI

/// 竖滑分页「提前挂载」窗口。
/// 以前分页器用 LazyVStack：下一条要等滑进屏幕才创建页面 → 建播放器、挂画面层、解第一帧都发生在滑动那一刻，
/// 期间只能先铺封面，看起来就是「每条先闪一下封面再播」，网络慢时还会卡住。
/// 现在当前条前 1 条、后 2 条始终挂着真页面（播放器暂停在第一帧、画面层已就绪），滑过去直接是真画面并立刻起播；
/// 窗口外只放轻量占位（黑底 + 近处的封面），页数再多也不建播放器。
enum DYPagerWindow {
    static let behind = 1
    /// 提前挂载几条 = 预缓存条数（上限 10），跟暖机数一致。
    static var ahead: Int { min(max(DYVideoCache.limit, 1), 10) }
    /// 占位里显示封面的范围（快速连滑越过挂载窗口时也不是纯黑）
    static let coverRange = 4

    static func mounts(_ index: Int, current: Int) -> Bool {
        index >= current - behind && index <= current + ahead
    }
    static func showsCover(_ index: Int, current: Int) -> Bool {
        abs(index - current) <= coverRange
    }
    static func currentIndex(_ items: [DYAweme], _ id: String?) -> Int {
        guard let id else { return 0 }
        return items.firstIndex { $0.id == id } ?? 0
    }
}

/// 窗口外的轻量占位：不建播放器、不挂手势。
struct DYPagerPlaceholder: View {
    let item: DYAweme
    let showsCover: Bool
    var body: some View {
        ZStack {
            Color.black
            if showsCover, let s = item.cover ?? item.images.first, let u = URL(string: s) {
                CachedAsyncImage(url: u) { img in img.resizable().scaledToFit() } placeholder: { Color.black }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 竖滑分页的页面列表（三个分页器共用）：当前页立即挂载；挂载窗口的整体平移推迟到滑动收尾、起播之后
/// （新挂一页 = 建播放器 + 解首帧，卸一页 = 销毁播放器，都在主线程，和起播挤在同一帧就会「卡一下」）。
struct DYPagerStack<Page: View>: View {
    let items: [DYAweme]
    let currentID: String?
    @ViewBuilder let page: (DYAweme) -> Page
    var pageAxes: Axis.Set = [.horizontal, .vertical]
    @State private var centerID: String?
    @State private var shiftToken = 0
    /// 拆旧页延后到动画结束之后（扩窗是即时的）
    static var shiftDelay: TimeInterval { 0.45 }

    var body: some View {
        // 惰性分页：每帧只重建可见的 1–2 页（之前非惰性版本每帧把已挂载页全部重建，实测主线程一帧掉到 35–45ms）
        LazyVStack(spacing: 0) {
            ForEach(items) { item in
                page(item)
                    .containerRelativeFrame(pageAxes)
                    .id(item.id)
            }
        }
    }
}
