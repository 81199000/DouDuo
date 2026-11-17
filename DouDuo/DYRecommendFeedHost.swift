import SwiftUI
import AVFoundation

/// 推荐流的共用操作（默认 / 简洁 / 极简 / 经典四种界面同一份）。
///
/// 维护规矩：推荐流「数据怎么动」只写在这里——刷新、连播、不感兴趣、话题屏蔽、存档会话、上报观看、
/// 点赞收藏等。两个推荐页（`DYUpstreamFeedScreen`、`DYClassicFeedScreen`）只负责「长什么样」，
/// 不要在它们里面再各写一份同名函数；需要按界面区分的，见 docs/ui-modes.md 的「必须分开」清单。
@MainActor
protocol DYRecommendFeedHost: View {
    var bridge: DouyinBridge { get }
    var feed: DYFeedModel { get }
    var preloader: DYPreloader { get }
    var tab: DYTab { get nonmutating set }
    var currentID: String? { get nonmutating set }
    var scrollID: String? { get nonmutating set }
    var resume: [String: Double] { get nonmutating set }
    var userScrolling: Bool { get nonmutating set }
    var scrollEndTask: Task<Void, Never>? { get nonmutating set }
    var initialized: Bool { get nonmutating set }
    var refreshing: Bool { get nonmutating set }
    var lastFeedPull: Date { get nonmutating set }
    var showComments: Bool { get nonmutating set }
    var noticeUnread: Int { get nonmutating set }
    var searchSession: DYSearchSession? { get nonmutating set }
}

@MainActor
extension DYRecommendFeedHost {
    /// 用户点了频道（关注 / 推荐 / 直播）。四种界面的频道入口都走这里：
    /// 默认的顶栏、简洁 / 极简的模块菜单、经典的顶部频道栏。
    /// 点**已选中的「推荐」= 刷新推荐**；其它情况交给各界面自己的 `switchTab`（经典有跟手切换动画）。
    /// 滑动切换、程序切换（调试 / 回到推荐）不走这里，不会误刷新。
    func tapChannel(_ target: DYTab, switchTab: (DYTab) -> Void) {
        if target == .recommend, tab == .recommend {
            DYLiveModel.log("DDREFRESH tap selected recommend")
            #if DEBUG
            DYRefreshProbe.shared.count += 1
            #endif
            Task { await refreshRecommendations() }
        } else {
            switchTab(target)
        }
    }

    var currentIndex: Int? { currentID.flatMap { id in feed.items.firstIndex { $0.id == id } } }
    var current: DYAweme? { currentIndex.map { feed.items[$0] } }

    /// 自动连播翻页带滑动动画（议题 #21-4）；分页代理没接上时退回直接切
    func advance(from: String, to: String) {
        if !DYPagerAdvance.request(from: from, to: to) { withAnimation { currentID = to } }
    }

    func applyHashtagFilter() async {
        let previousID = currentID
        currentID = feed.applyHashtagFilter(currentID: currentID)
        if previousID != currentID {
            scrollEndTask?.cancel()
            userScrolling = false
            showComments = false
            scrollID = currentID
            preloader.clear()
        }
        saveSession()
        guard initialized else { return }
        while feed.loading {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
        }
        guard !Task.isCancelled else { return }
        if feed.items.isEmpty { await feed.loadMore(bridge) }
        guard !Task.isCancelled else { return }
        if currentID == nil { currentID = feed.items.first?.id; scrollID = currentID }
        focusCurrent()
        saveSession()
    }

    /// 不感兴趣：立刻从列表拿掉并切到下一条，后台告诉抖音（失败只提示，不把视频塞回来）
    func dislike(_ id: String) {
        guard let i = feed.items.firstIndex(where: { $0.id == id }) else { return }
        let next = i + 1 < feed.items.count ? feed.items[i + 1].id : (i > 0 ? feed.items[i - 1].id : nil)
        scrollEndTask?.cancel(); userScrolling = false
        showComments = false
        if currentID == id { currentID = next; scrollID = next }
        feed.items.remove(at: i)
        resume[id] = nil
        saveSession()
        showToast("将减少此类推荐")
        Task {
            await DYVideoCache.shared.markWatched(id)
            do {
                switch try await bridge.dislike(id) {
                case .ok: break
                case .notLoggedIn: showToast("抖音未登录，「不感兴趣」没同步到账号")
                case .failed(let why): showToast("「不感兴趣」同步失败：\(why)")
                }
            } catch {
                showToast("「不感兴趣」同步失败：\(error.localizedDescription)")
            }
        }
        if next == nil { Task { await feed.loadMore(bridge); currentID = feed.items.first?.id; scrollID = currentID } }
    }

    func focusCurrent() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["DOUDUO_HASHTAG_FIXTURE"] == "1" { return }
        #endif
        guard !refreshing, let i = currentIndex else { return }
        preloader.update(feed.items, current: i)
        // 不再预解首帧：界面已不用首帧图顶替（老板要纯黑直出），省 CPU 和解码
        let curID = feed.items[i].id
        let ahead = Array(feed.items.dropFirst(i + 1))
        let regionIDs = ahead.prefix(2).filter {
            DYPublicationRegion.name(for: $0.publicationCityCode, country: $0.publicationCountry) == nil
        }.map(\.id)
        Task(priority: .utility) { await DYPublicationRegionClient.shared.prefetch(regionIDs) }
        let currentItem = feed.items[i]
        Task {
            await DYVideoCache.shared.markWatched(curID)
            await DYVideoCache.shared.focus(current: currentItem, ahead: ahead)
        }
        // 后面不足「缓存条数」就继续拉推荐（至少保证 6 条，节流 4 秒一次）
        let want = max(6, min(DYVideoCache.limit, 60))
        if feed.items.count - i - 1 < want, Date().timeIntervalSince(lastFeedPull) > 4 {
            lastFeedPull = Date()
            Task {
                await feed.loadMore(bridge)
                if let j = currentIndex {
                    preloader.update(feed.items, current: j)
                    await DYVideoCache.shared.focus(current: feed.items[j], ahead: Array(feed.items.dropFirst(j + 1)))
                    if feed.items.count - j - 1 < want { focusCurrent() }
                }
            }
        }
    }

    func openSearch() {
        DYSearchSession.transition { showComments = false; searchSession = DYSearchSession() }
    }

    /// 自动连播：播完滑到下一条；快到底时先补一页
    func playNext(after id: String) {
        guard let i = feed.items.firstIndex(where: { $0.id == id }) else { return }
        if i + 1 < feed.items.count {
            advance(from: id, to: feed.items[i + 1].id)
        } else {
            Task {
                await feed.loadMore(bridge)
                if let j = feed.items.firstIndex(where: { $0.id == id }), j + 1 < feed.items.count {
                    advance(from: id, to: feed.items[j + 1].id)
                }
            }
        }
    }

    func refreshNoticeUnread() async {
        guard let groups = try? await bridge.noticeCounts() else { return }
        noticeUnread = DYMessagesScreen.badge(groups)
    }

    /// 先拉到新一批再替换，失败不清空当前画面；与预取互斥，避免旧请求覆盖刷新结果。
    @MainActor func refreshRecommendations() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false; focusCurrent() }
        showToast("正在刷新推荐…")
        guard let replacement = try? await feed.prepareRefresh(bridge) else { return }
        guard !replacement.items.isEmpty else {
            showToast(replacement.error ?? "暂时没有新的推荐，已保留当前视频")
            DYLiveModel.log("DDREFRESH failed kept=\(currentID ?? "-")")
            return
        }
        showComments = false
        scrollEndTask?.cancel(); userScrolling = false
        preloader.clear()
        feed.replaceRecommendations(with: replacement)
        resume = [:]
        currentID = feed.items.first?.id
        scrollID = currentID
        lastFeedPull = Date()
        saveSession()
        showToast("推荐已刷新")
        DYLiveModel.log("DDREFRESH ok n=\(feed.items.count) first=\(currentID ?? "-")")
    }

    /// 当前条之后按新的方向/比例重排；不够就接着拉
    func remixUpcoming() {
        guard tab == .recommend || !feed.items.isEmpty else { return }
        feed.remix(after: currentIndex)
        DYLiveModel.log("DDMIX remix wide=\(feed.screenWide) upcoming=\(feed.items.count - (currentIndex ?? -1) - 1)")
        if currentID == nil { currentID = feed.items.first?.id; scrollID = currentID }
        lastFeedPull = .distantPast
        focusCurrent()
    }

    /// 换条时：上一条看完没有（≥95%，网页版同口径）+ 新一条起播 1.5 秒后上报
    func reportWatch(old: String?, new: String?) {
        guard let new, let item = feed.items.first(where: { $0.id == new }) else { return }
        var seen = false
        if let old, let prev = feed.items.first(where: { $0.id == old }), prev.duration > 0,
           DDNowPlaying.id == old { seen = DDNowPlaying.time / prev.duration >= 0.95 }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard currentID == new else { return }
            await bridge.reportWatch(item, preID: old, preSeen: seen)
        }
    }

    func saveSession() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["DOUDUO_HASHTAG_FIXTURE"] == "1" { return }
        #endif
        guard let id = currentID, feed.items.contains(where: { $0.id == id }) else { return }
        var positions = resume
        if DDNowPlaying.id == id, DDNowPlaying.time.isFinite {
            positions[id] = max(0, DDNowPlaying.time)
        }
        feed.noteCurrent(id, positions: positions)   // 切换界面模式后另一套根视图接手（main f76e636）
        DYFeedSession(items: feed.items, currentID: id, positions: positions).save()
    }

    func showToast(_ s: String) { feed.showToast(s) }

    /// 收藏 / 取消收藏（同步到抖音账号的「收藏」）
    func toggleCollect(_ id: String) { feed.toggleCollect(id, bridge: bridge) }

    /// 点赞：先本地乐观更新，再调抖音网页接口，按服务端返回决定成败
    /// （不用 cookie 判断登录态：sessionid 是 HttpOnly，document.cookie 读不到，会误判成未登录）
    func toggleLike(_ id: String, force: Bool?) { feed.toggleLike(id, force: force, bridge: bridge) }
}

#if DEBUG
/// UI 测试锚点：点已选中「推荐」触发刷新的次数（离线数据刷不出新视频，靠它确认确实刷了）。
@MainActor
final class DYRefreshProbe: ObservableObject {
    static let shared = DYRefreshProbe()
    @Published var count = 0
}

/// 挂在推荐页上，把刷新次数暴露给 UI 测试（`douyin.refreshCount`）。
struct DYRefreshProbeAnchor: View {
    @ObservedObject private var probe = DYRefreshProbe.shared
    var body: some View {
        Text("\(probe.count)").font(.caption2).opacity(0.01)
            .accessibilityIdentifier("douyin.refreshCount")
            .allowsHitTesting(false)
    }
}
#endif
