import SwiftUI
import UIKit

/// Short-video paging only. Standard leaves SwiftUI's delegate and animation untouched.
enum DYPagingSpeed: String, CaseIterable, Identifiable {
    static let key = "douyin_paging_speed_v1"
    case standard, fast, faster
    var id: String { rawValue }
    var title: String {
        switch self { case .standard: "标准（系统）"; case .fast: "快速"; case .faster: "更快" }
    }
    var duration: TimeInterval? {
        switch self { case .standard: nil; case .fast: 0.18; case .faster: 0.10 }
    }
    static func resolved(_ raw: String) -> Self { Self(rawValue: raw) ?? .standard }
}

/// Attach inside the ScrollView, on its content stack, so it cannot affect nested comment/image scrolls.
struct DYPagingSpeedBridge: UIViewRepresentable {
    let ids: [String]
    @Binding var currentID: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 维护者定稿：固定「更快」（0.10s），不提供菜单。系统开了「减少动态效果」时仍走系统分页。
    static let fixedSpeed: DYPagingSpeed = .faster
    func makeUIView(context: Context) -> DYPagingSpeedHost { DYPagingSpeedHost() }
    func updateUIView(_ view: DYPagingSpeedHost, context: Context) {
        let listChanged = view.ids != ids
        view.ids = ids
        view.currentID = currentID
        if listChanged { view.listChanged() }
        view.didSettle = { id in
            guard ids.contains(id), currentID != id else { return }
            currentID = id
        }
        view.duration = reduceMotion ? nil : Self.fixedSpeed.duration
        view.attachWhenReady()
    }
    static func dismantleUIView(_ view: DYPagingSpeedHost, coordinator: ()) { view.detach() }
}

/// 自动连播翻页：播完后像手滑一样把下一条推上来（议题 #21-4：以前是直接切换，没有滑动动画）。
/// 由正挂着的分页代理执行收尾动画，停稳后照常走 didSettle 切当前条起播（「停住才播」不变）。
@MainActor
enum DYPagerAdvance {
    private static var delegates: [WeakDelegate] = []
    private struct WeakDelegate { weak var value: DYPagingDelegate? }
    fileprivate static func register(_ d: DYPagingDelegate) {
        delegates.removeAll { $0.value == nil || $0.value === d }
        delegates.append(WeakDelegate(value: d))
    }
    /// 返回 false = 没有分页代理接手（系统「减少动态效果」等），调用方自己直接切
    static func request(from: String, to: String) -> Bool {
        // App 在后台（后台播放 / 锁屏听）时屏幕不刷新，滑动动画靠 CADisplayLink 驱动、一帧都不走，
        // 动画「接手」了却永远停不下来 → 后台自动连播卡在播完的那条（议题 #52-3）。后台直接切，不放动画。
        if UIApplication.shared.applicationState != .active {
            DYLiveModel.log("DDAUTONEXT background → direct \(from.suffix(4))→\(to.suffix(4))")
            return false
        }
        delegates.removeAll { $0.value == nil }
        for d in delegates.reversed() {
            if let d = d.value, d.animateAdvance(from: from, to: to) { return true }
        }
        return false
    }
}

final class DYPagingSpeedHost: UIView {
    var duration: TimeInterval?
    var ids: [String] = []
    var currentID: String?
    var didSettle: (String) -> Void = { _ in }
    private var proxy: DYPagingDelegate?
    /// 手指抬起、已知落到哪一页：提前切当前页起播，不等收尾动画
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { detach() } else { attachWhenReady() }
    }
    func attachWhenReady() {
        DispatchQueue.main.async { [weak self] in self?.attach() }
    }
    private func attach() {
        guard window != nil else { return }
        var ancestor = superview
        while let view = ancestor, !(view is UIScrollView) { ancestor = view.superview }
        guard let scroll = ancestor as? UIScrollView else { return }
        if proxy?.scroll !== scroll || (proxy != nil && scroll.delegate !== proxy) { detach() }
        guard let duration else { detach(); return }
        if let proxy { proxy.duration = duration; return }
        // Never chain multiple owners or touch a horizontal/non-paging scroll view.
        guard scroll.isPagingEnabled, !(scroll.delegate is DYPagingDelegate) else { return }
        let next = DYPagingDelegate(scroll: scroll, duration: duration,
            ids: { [weak self] in self?.ids ?? [] },
            currentID: { [weak self] in self?.currentID },
            didSettle: { [weak self] id in self?.didSettle(id) },
            willSettle: { [weak self] id in self?.didSettle(id) })
        proxy = next
        scroll.delegate = next
        DYPagerAdvance.register(next)
        #if DEBUG
        ddWrite("DDPAGE attach duration=\(duration)")
        #endif
    }
    func reconcileAfterLayout() { proxy?.reconcileAfterLayout() }
    func listChanged() { proxy?.listChanged() }
    func detach() { proxy?.detach(); proxy = nil }
}

// MARK: - feed-paging-decision

/// 竖滑松手后落到哪一页（纯计算，脚本可测）。
/// 系统分页轻轻一碰就翻，所以自己定规则：慢拖要过 1/4 屏；快甩只看方向，但至少要真拖动一小段，防止点按带一下就翻。
enum DYFeedPagingDecision {
    /// 慢慢拖、松手时几乎不动：拖过这个比例的屏高才翻
    static let distanceFraction: CGFloat = 0.25
    /// 快甩速度（pt/ms，与 UIScrollView 松手速度同单位）。
    /// 以前是 0.6 且只看抬手瞬时速度：快速小幅度一甩达不到，画面跟手上去了松手却弹回。
    /// 0.35 ≈ Android ViewPager 的 400dp/s 甩动门槛。
    static let flickVelocity: CGFloat = 0.35
    /// 快甩至少拖动的距离（列表实际位移，不含系统起拖前的十来 pt 死区）
    static let flickMinDistance: CGFloat = 16
    /// 抬手前平均速度的统计窗口
    static let recentWindow: CFTimeInterval = 0.08

    /// - dragged: 这次手势的位移（pt，正 = 往下一条）
    /// - velocity: 松手速度（pt/ms，正 = 往下一条）
    /// - 返回 -1 上一条 / 0 原页 / 1 下一条
    static func step(dragged: CGFloat, velocity: CGFloat, pageHeight: CGFloat) -> Int {
        if abs(velocity) >= flickVelocity {
            // 快甩看方向：顺着拖动方向甩才翻；拖出去又往回甩 = 撤回，留在原页
            guard abs(dragged) >= flickMinDistance, (dragged > 0) == (velocity > 0) else { return 0 }
            return velocity > 0 ? 1 : -1
        }
        let threshold = pageHeight * distanceFraction
        if dragged >= threshold { return 1 }
        if dragged <= -threshold { return -1 }
        return 0
    }

    /// UIKit 给的是抬手那一刻的瞬时速度：抬手那一帧和上一帧位置相同就读成 0（模拟器实测手指一直在动、release=0.00），
    /// 快速短甩时手指离屏前也常先减速，读数偏低。
    /// 用抬手前 80ms 的平均速度兜底——同方向且更快时用它；抬手瞬间明确往回甩（反向且够快）则信瞬时速度。
    static func effectiveVelocity(release: CGFloat, recent: CGFloat?) -> CGFloat {
        guard let recent, abs(recent) > abs(release) else { return release }
        if release != 0, (recent > 0) != (release > 0), abs(release) >= flickVelocity { return release }
        return recent
    }

    /// 抬手前窗口内的平均速度（pt/ms）。samples 为拖动中记录的 (时间, contentOffset.y)，按时间递增，最后一个是抬手时刻。
    /// 拖动比窗口还短时从拖动开始算；手指停住超过窗口再抬起，窗口内没有位移，结果是 0。
    static func recentVelocity(_ samples: [(t: CFTimeInterval, y: CGFloat)],
                               window: CFTimeInterval = recentWindow) -> CGFloat? {
        guard let last = samples.last, samples.count >= 2 else { return nil }
        let base = samples.last(where: { $0.t <= last.t - window }) ?? samples[0]
        let dt = last.t - base.t
        guard dt >= 0.008 else { return nil }
        return (last.y - base.y) / CGFloat(dt * 1000)
    }
}

// MARK: - feed-paging-decision-end

private final class DYPagingDisplayTarget: NSObject {
    weak var owner: DYPagingDelegate?
    @objc func tick(_ link: CADisplayLink) { owner?.tick(link) }
}

/// Preserves SwiftUI's target selection and all optional delegate methods. Only settling changes.
final class DYPagingDelegate: NSObject, UIScrollViewDelegate {
    weak var scroll: UIScrollView?
    private weak var original: UIScrollViewDelegate?
    var duration: TimeInterval
    private let ids: () -> [String]
    private let currentID: () -> String?
    private let didSettle: (String) -> Void
    private let willSettle: (String) -> Void
    private var targetID: String?
    /// 这次拖动以哪一页为起点。快速连刷时上一次收尾动画还没停住就被新的拖动打断，
    /// currentID 还没切（停稳才切），仍是上一次起拖的那一条；按它算，列表已经快到下一条了，
    /// 这次快甩只会被判成「去下一条」= 落回上一次就要去的那一页，看起来像跟手上去又弹回。必须以上一次正要去的那一页为起点。
    private var dragBaseID: String?
    private var dragStartY: CGFloat?
    /// 拖动中的 (时间, contentOffset.y)，用于算抬手前的平均速度
    private var dragSamples: [(t: CFTimeInterval, y: CGFloat)] = []
    /// 收尾动画期间「应该在的位置」；SwiftUI 的 scrollPosition 在抬手切当前页时会把列表直接跳到终点，
    /// 下一帧动画又拉回中途 → 肉眼看到「往回跳一帧」。动画期间外部写入一律在同一帧内改回来。
    private var expected: CGPoint?
    /// 提前起播时收尾动画还要走多久：这段时间里别让 SwiftUI 的 scrollPosition 跟着当前条改（会和收尾动画抢位置 → DDJUMPFIX）
    @MainActor static var settleEndsAt: CFTimeInterval = 0
    /// 收尾动画剩最后这么久时就切当前条起播（老板 11-21 选 2A：停住那一刻画面正好动起来，不再停住后干等约 0.15s）
    /// ⚠️ 11-21 晚改回 0：切当前条那一帧主线程要忙 50–70ms（播放器换成当前、整页重算），
    /// 提前 0.1s 切 = 这一顿正好落在画面还在往上走的时候，老板看到「每条快到位都卡一下」（真机 244 次长帧里 117 次紧跟提前起播）。
    /// 停住再切，这一顿发生在画面静止时，肉眼看不出。
    static let earlyStart: TimeInterval = 0
    private var earlyFired = false
    private var writing = false
    private var jumpFixes = 0
    /// 每条被拦次数（同一条拦太多就放行，避免永久卡住）
    private var blockedCount: [String: Int] = [:]
    private var target: CGPoint?
    private var start = CGPoint.zero
    private var startTime: CFTimeInterval = 0
    private var animationDuration: TimeInterval = 0
    private var link: CADisplayLink?
    private let displayTarget = DYPagingDisplayTarget()
    private var boundsObservation: NSKeyValueObservation?
    private var size = CGSize.zero

    init(scroll: UIScrollView, duration: TimeInterval, ids: @escaping () -> [String],
         currentID: @escaping () -> String?, didSettle: @escaping (String) -> Void,
         willSettle: @escaping (String) -> Void) {
        self.ids = ids; self.currentID = currentID; self.didSettle = didSettle; self.willSettle = willSettle
        self.scroll = scroll; self.original = scroll.delegate; self.duration = duration
        self.size = scroll.bounds.size
        super.init()
        displayTarget.owner = self
        scroll.panGestureRecognizer.addTarget(self, action: #selector(panChanged(_:)))
        boundsObservation = scroll.observe(\.bounds, options: [.new]) { [weak self] view, _ in
            guard let self, view.bounds.size != self.size else { return }
            self.size = view.bounds.size
            self.reconcileAfterLayout()
        }
    }
    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || original?.responds(to: selector) == true
    }
    override func forwardingTarget(for selector: Selector!) -> Any? { original }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        original?.scrollViewDidScroll?(scrollView)
        if scrollView.isDragging, link == nil { recordSample(scrollView) }
        guard link != nil, !writing, let e = expected, abs(scrollView.contentOffset.y - e.y) > 0.5 else { return }
        writing = true
        scrollView.setContentOffset(e, animated: false)
        writing = false
        jumpFixes += 1
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        // 先记住被打断的收尾要去哪一页，再停动画
        dragBaseID = targetID ?? currentID()
        stop()
        dragStartY = scrollView.contentOffset.y
        dragSamples.removeAll(keepingCapacity: true)
        recordSample(scrollView)
        original?.scrollViewWillBeginDragging?(scrollView)
    }
    private func recordSample(_ scrollView: UIScrollView) {
        dragSamples.append((CACurrentMediaTime(), scrollView.contentOffset.y))
        // 只用得到最近 80ms；留一点余量即可
        if dragSamples.count > 64 { dragSamples.removeFirst(dragSamples.count - 32) }
    }
    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                   targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        original?.scrollViewWillEndDragging?(scrollView, withVelocity: velocity,
                                            targetContentOffset: targetContentOffset)
        guard scrollView.isPagingEnabled, scrollView.bounds.height > 0,
              targetContentOffset.pointee.y.isFinite else { return }
        let items = ids()
        let h = scrollView.bounds.height
        let top = scrollView.adjustedContentInset.top
        let baseID = dragBaseID ?? currentID()
        let baseIndex = items.firstIndex(where: { $0 == baseID })
        let startY = dragStartY ?? scrollView.contentOffset.y
        let curIndex0 = baseIndex ?? Int(((startY + top) / h).rounded())
        // 翻页规则见 DYFeedPagingDecision：拖过 1/4 屏，或顺着方向快甩，才翻到下一条/上一条；否则弹回原位。
        // 位移按这次手势自己的行程算：正常停稳后起拖，它就等于离当前页的距离；
        // 打断上一次收尾时，以「上一次要去的页」为起点，这一甩再往前/后一页（连刷两下 = 走两条）。
        let dragged = scrollView.contentOffset.y - startY
        recordSample(scrollView)
        let recent = DYFeedPagingDecision.recentVelocity(dragSamples)
        let v = DYFeedPagingDecision.effectiveVelocity(release: velocity.y, recent: recent)
        let step = DYFeedPagingDecision.step(dragged: dragged, velocity: v, pageHeight: h)
        var index = curIndex0 + step
        index = min(max(index, 0), max(items.count - 1, 0))
        DYLiveModel.log(String(format: "DDSWIPEDECIDE step=%d dragged=%.0f/%.0f v=%.2f release=%.2f recent=%@",
                               step, dragged, h, v, velocity.y, recent.map { String(format: "%.2f", $0) } ?? "-"))
        targetContentOffset.pointee.y = CGFloat(index) * h - top
        guard items.indices.contains(index) else { return }
        // 老板要求：下一个视频还没加载好就别让它翻过去（跟抖音原版一样）
        // 只拦「往前翻」；往回翻是看过的，直接放行
        let curIndex = baseIndex ?? index
        if index > curIndex, !DYReadiness.isReady(items[index]) {
            let id = items[index]
            blockedCount[id, default: 0] += 1
            // 同一条拦了 3 次还没就绪，就放行（可能是地址失效/长视频加载慢；宁可黑一下也不能把人卡死）
            if blockedCount[id, default: 0] <= 3 {
                let curY = CGFloat(curIndex) * scrollView.bounds.height - scrollView.adjustedContentInset.top
                targetID = items[curIndex]
                target = CGPoint(x: scrollView.contentOffset.x, y: curY)
                targetContentOffset.pointee = scrollView.contentOffset
                DYLiveModel.log("DDBLOCK next=\(id.suffix(4)) 未就绪，弹回当前页 #\(blockedCount[id, default: 0])")
                return
            }
            DYLiveModel.log("DDFORCE next=\(id.suffix(4)) 拦了 3 次仍未就绪，放行")
        }
        targetID = items[index]
        target = targetContentOffset.pointee
        // Prevent system deceleration; CADisplayLink then moves to the system-selected page.
        targetContentOffset.pointee = scrollView.contentOffset
    }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        original?.scrollViewDidEndDragging?(scrollView, willDecelerate: decelerate)
        guard target != nil else { return }
        start = scrollView.contentOffset; startTime = CACurrentMediaTime()
        expected = start; jumpFixes = 0; earlyFired = false
        // 剩余距离越长越久（0.22–0.32s），不再固定 0.10s 一闪而过
        if let t = target {
            let remain = abs(t.y - scrollView.contentOffset.y) / max(scrollView.bounds.height, 1)
            // 停住才起播后，收尾时长就是起播等待：0.22–0.32s 实测 lift→active≈320ms，老板觉得「又慢了」。
            // 收到 0.16–0.22s：仍是推上来的减速，不是 0.10s 的闪
            animationDuration = 0.16 + 0.06 * Double(min(remain, 1))
        } else { animationDuration = duration }
        let next = CADisplayLink(target: displayTarget, selector: #selector(DYPagingDisplayTarget.tick(_:)))
        link = next; next.add(to: .main, forMode: .common)
        // 老板定（11-21 改 2A）：收尾动画剩最后 0.1s 时切当前条起播（tick 里 earlyStart），停住那一刻画面正好在动；
        // 不是抬手就起播（那样画面还在往上走就开播了）。
        if let id = targetID, id != currentID() {
            DYSwipeProbe.lift(); DYSwipeProbe.mark("lift(\(id.suffix(4)))")
            // 抬手那一刻就告诉当前页「要走了」：直播卡据此先静音，不等下一条停住（老板 11-24：停住前 0.3 秒就该没声）
            if let from = currentID() {
                NotificationCenter.default.post(name: DYFeedLeaving.name, object: nil, userInfo: ["from": from, "to": id])
            }
        } else {
            DYLiveModel.log("DDSWIPESKIP target=\(targetID?.suffix(4) ?? "-") cur=\(currentID()?.suffix(4) ?? "-")")
        }
    }
    @objc private func panChanged(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .cancelled || gesture.state == .failed {
            // A cancelled gesture must never commit the previous gesture's target.
            reconcileAfterLayout()
        }
    }
    func tick(_ displayLink: CADisplayLink) {
        guard let scroll, let capturedTarget = target, let targetID,
              let index = ids().firstIndex(of: targetID), scroll.delegate === self,
              !scroll.isDragging, scroll.window != nil else { stop(); return }
        // Re-resolve the stable item, never write an index captured from an older list.
        let target = CGPoint(x: capturedTarget.x,
                             y: CGFloat(index) * scroll.bounds.height - scroll.adjustedContentInset.top)
        let fraction = min(1, max(0, (CACurrentMediaTime() - startTime) / animationDuration))
        if Self.earlyStart > 0, !earlyFired, CACurrentMediaTime() - startTime >= animationDuration - Self.earlyStart {
            earlyFired = true
            Self.settleEndsAt = startTime + animationDuration
            DYLiveModel.log("DDSETTLE-EARLY \(targetID.suffix(6)) 剩 \(Int(Self.earlyStart * 1000))ms 起播")
            didSettle(targetID)
        }
        let progress = 1 - pow(1 - fraction, 3)
        let p = CGPoint(x: start.x + (target.x - start.x) * progress,
                        y: start.y + (target.y - start.y) * progress)
        expected = p
        writing = true
        scroll.setContentOffset(p, animated: false)
        writing = false
        if fraction >= 1 {
            if jumpFixes > 0 { DYLiveModel.log("DDJUMPFIX 收尾期间拦下外部跳位 \(jumpFixes) 次") }
            stop()
            // SwiftUI may suppress its final scrollPosition write when there is no native deceleration.
            #if DEBUG
            ddWrite("DDPAGE settle id=\(targetID) ms=\(Int((CACurrentMediaTime() - startTime) * 1000))")
            #endif
            DYLiveModel.log("DDSETTLE \(targetID.suffix(6)) 停住 \(Int((CACurrentMediaTime() - startTime) * 1000))ms")
            didSettle(targetID)
        }
    }
    /// 自动连播：从当前页滑到下一页（跟手滑收尾同一套 tick，结束时 didSettle 起播）。
    /// 只在这个分页器的当前条就是播完的那条、且不在拖动/收尾中时接手。
    @MainActor
    func animateAdvance(from: String, to: String) -> Bool {
        guard let scroll, scroll.delegate === self, scroll.window != nil, !scroll.isDragging,
              link == nil, currentID() == from, let index = ids().firstIndex(of: to) else { return false }
        let y = CGFloat(index) * scroll.bounds.height - scroll.adjustedContentInset.top
        targetID = to
        target = CGPoint(x: scroll.contentOffset.x, y: y)
        start = scroll.contentOffset; startTime = CACurrentMediaTime()
        expected = start; jumpFixes = 0; earlyFired = false
        // 比手滑收尾（0.16–0.22s）慢一点：没有手指带着，要看得出是「滑上来」而不是闪过去
        animationDuration = 0.34
        let next = CADisplayLink(target: displayTarget, selector: #selector(DYPagingDisplayTarget.tick(_:)))
        link = next; next.add(to: .main, forMode: .common)
        DYLiveModel.log("DDAUTONEXT slide \(from.suffix(4))→\(to.suffix(4))")
        return true
    }
    /// 列表内容变了（后台又拉回来一批推荐）。正在往下一条滑的收尾动画不能被它打断：
    /// 以前一律停掉动画、把列表拽回当前条，手已经滑上去了又被弹回来（真机日志里有 DDSWIPEDECIDE 之后没下文的）。
    /// 目标页还在列表里就继续滑——tick 每帧按 id 重新定位，列表变了也落得准。
    func listChanged() {
        if link != nil, let targetID, ids().contains(targetID) {
            DYLiveModel.log("DDLISTKEEP 收尾中列表更新，继续滑到 \(targetID.suffix(4))")
            return
        }
        reconcileAfterLayout()
    }
    func reconcileAfterLayout() {
        stop()
        DispatchQueue.main.async { [weak self] in
            guard let self, let scroll = self.scroll, scroll.delegate === self,
                  !scroll.isDragging, let id = self.currentID(),
                  let index = self.ids().firstIndex(of: id) else { return }
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x,
                y: CGFloat(index) * scroll.bounds.height - scroll.adjustedContentInset.top), animated: false)
        }
    }
    private func stop() { link?.invalidate(); link = nil; target = nil; targetID = nil; expected = nil }
    func detach() {
        stop()
        boundsObservation?.invalidate(); boundsObservation = nil
        guard let scroll else { return }
        scroll.panGestureRecognizer.removeTarget(self, action: #selector(panChanged(_:)))
        if scroll.delegate === self {
            scroll.delegate = original
            // Restore the currently bound page, not an unfinished gesture's old destination.
            if !scroll.isDragging, let id = currentID(), let index = ids().firstIndex(of: id) {
                scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x,
                    y: CGFloat(index) * scroll.bounds.height - scroll.adjustedContentInset.top), animated: false)
            }
        }
    }
    deinit { link?.invalidate() }
}
