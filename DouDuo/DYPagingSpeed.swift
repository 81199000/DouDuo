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
        if listChanged { view.reconcileAfterLayout() }
        view.didSettle = { id in
            guard ids.contains(id) else { return }
            currentID = id
        }
        view.duration = reduceMotion ? nil : Self.fixedSpeed.duration
        view.attachWhenReady()
    }
    static func dismantleUIView(_ view: DYPagingSpeedHost, coordinator: ()) { view.detach() }
}

final class DYPagingSpeedHost: UIView {
    var duration: TimeInterval?
    var ids: [String] = []
    var currentID: String?
    var didSettle: (String) -> Void = { _ in }
    private var proxy: DYPagingDelegate?
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
            didSettle: { [weak self] id in self?.didSettle(id) })
        proxy = next
        scroll.delegate = next
        #if DEBUG
        ddWrite("DDPAGE attach duration=\(duration)")
        #endif
    }
    func reconcileAfterLayout() { proxy?.reconcileAfterLayout() }
    func detach() { proxy?.detach(); proxy = nil }
}

private final class DYPagingDisplayTarget: NSObject {
    weak var owner: DYPagingDelegate?
    @objc func tick(_ link: CADisplayLink) { owner?.tick(link) }
}

/// Preserves SwiftUI's target selection and all optional delegate methods. Only settling changes.
private final class DYPagingDelegate: NSObject, UIScrollViewDelegate {
    weak var scroll: UIScrollView?
    private weak var original: UIScrollViewDelegate?
    var duration: TimeInterval
    private let ids: () -> [String]
    private let currentID: () -> String?
    private let didSettle: (String) -> Void
    private var targetID: String?
    private var target: CGPoint?
    private var start = CGPoint.zero
    private var startTime: CFTimeInterval = 0
    private var animationDuration: TimeInterval = 0
    private var link: CADisplayLink?
    private let displayTarget = DYPagingDisplayTarget()
    private var boundsObservation: NSKeyValueObservation?
    private var size = CGSize.zero

    init(scroll: UIScrollView, duration: TimeInterval, ids: @escaping () -> [String],
         currentID: @escaping () -> String?, didSettle: @escaping (String) -> Void) {
        self.ids = ids; self.currentID = currentID; self.didSettle = didSettle
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

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        stop()
        original?.scrollViewWillBeginDragging?(scrollView)
    }
    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                   targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        original?.scrollViewWillEndDragging?(scrollView, withVelocity: velocity,
                                            targetContentOffset: targetContentOffset)
        guard scrollView.isPagingEnabled, scrollView.bounds.height > 0,
              targetContentOffset.pointee.y.isFinite else { return }
        let index = Int(((targetContentOffset.pointee.y + scrollView.adjustedContentInset.top) / scrollView.bounds.height).rounded())
        let items = ids()
        guard items.indices.contains(index) else { return }
        targetID = items[index]
        target = targetContentOffset.pointee
        // Prevent system deceleration; CADisplayLink then moves to the system-selected page.
        targetContentOffset.pointee = scrollView.contentOffset
    }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        original?.scrollViewDidEndDragging?(scrollView, willDecelerate: decelerate)
        guard target != nil else { return }
        start = scrollView.contentOffset; startTime = CACurrentMediaTime(); animationDuration = duration
        let next = CADisplayLink(target: displayTarget, selector: #selector(DYPagingDisplayTarget.tick(_:)))
        link = next; next.add(to: .main, forMode: .common)
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
        let progress = 1 - pow(1 - fraction, 3)
        scroll.setContentOffset(CGPoint(x: start.x + (target.x - start.x) * progress,
                                      y: start.y + (target.y - start.y) * progress), animated: false)
        if fraction >= 1 {
            stop()
            // SwiftUI may suppress its final scrollPosition write when there is no native deceleration.
            #if DEBUG
            ddWrite("DDPAGE settle id=\(targetID) ms=\(Int((CACurrentMediaTime() - startTime) * 1000))")
            #endif
            didSettle(targetID)
        }
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
    private func stop() { link?.invalidate(); link = nil; target = nil; targetID = nil }
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
