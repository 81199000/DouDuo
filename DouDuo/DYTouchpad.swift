import SwiftUI
import UIKit

// 竖屏半折叠（桌面姿态）下半屏：评论 ⇄ 触控板。
// - 划到视频先是评论；评论区 4 秒没人碰（没在打字）就淡成触控板，之后一直保持，换视频也不闪回评论
// - 触控板：纯黑底 + 上方画面的桌面倒影（DYDeskLight，由评论区那层投过来）+ 四角取景框，弹幕从视频挪到这里飘
// - 单击：回到评论（再 4 秒没动又变回触控板）
// - 上下滑：下一条 / 上一条；左右拖：快进快退（预览在上方视频里）；长按：2 倍速，按住下滑锁定、上滑取消

/// 当前在播的那一条把操作交给触控板（播放器每次成为当前条时挂上，离开时摘下）
@MainActor
final class DYTouchpadLink {
    static let shared = DYTouchpadLink()
    struct Player {
        let owner: UUID
        var seekBegan: () -> Void
        var seekChanged: (CGFloat, CGFloat) -> Void
        var seekEnded: () -> Void
        var boost: (Bool) -> Void
        var lockBoost: () -> Void
        var unlockBoost: () -> Void
    }
    private(set) var player: Player?
    func attach(_ p: Player) { player = p }
    func detach(_ owner: UUID) { if player?.owner == owner { player = nil } }
}

/// 触控板上飘的弹幕：只有触控板在显示时，当前条才往这里推（播放器自己那层同时收起）
@MainActor
final class DYTouchpadDanmaku: ObservableObject {
    static let shared = DYTouchpadDanmaku()
    @Published private(set) var items: [DYDanmaku] = []
    @Published private(set) var clock = DYDanmakuClock()
    private var owner: UUID?
    func publish(owner o: UUID, items i: [DYDanmaku], clock c: DYDanmakuClock) {
        if owner != o || i.count != items.count || i.first?.id != items.first?.id || i.last?.id != items.last?.id { items = i }
        owner = o
        clock = c
    }
    func clear(_ o: UUID) {
        guard owner == o else { return }
        owner = nil; items = []
    }
}

/// 评论区正在写回复（选了回复对象或有草稿）：触控板先别出来
@MainActor
final class DYTouchpadHold {
    static let shared = DYTouchpadHold()
    var composing = false
}

/// 当前条把自己的右侧按钮栏交给触控板（视频页 isCurrent 时发；评论打开时视频上的按钮栏本来就收起）
struct DYTouchpadActions { let id: String; let view: AnyView }
struct DYTouchpadActionsKey: PreferenceKey {
    static var defaultValue: DYTouchpadActions? { nil }
    static func reduce(value: inout DYTouchpadActions?, nextValue: () -> DYTouchpadActions?) {
        if value == nil { value = nextValue() }
    }
}

extension EnvironmentValues {
    /// 半折叠下半屏正显示触控板：播放器不在画面上画弹幕，改推给触控板
    @Entry var dyTouchpadEngaged = false
}

struct DYTouchpadPane: View {
    var onTap: () -> Void
    /// +1 下一条 / -1 上一条；nil = 这一页不支持（关注页等）
    var onPage: ((Int) -> Void)?
    /// 底部小字提示（直播间：「轻点进入直播间」）
    var hint: String? = nil
    @ObservedObject private var dm = DYTouchpadDanmaku.shared
    @GestureState private var holding = false
    @State private var boostOn = false
    @State private var lockDone = false
    @State private var lastBoostEnd = Date.distantPast
    @State private var axis: Axis?
    @State private var seeking = false

    var body: some View {
        GeometryReader { g in
            ZStack {
                Color.black
                if !dm.items.isEmpty {
                    DYTouchpadDanmakuLayer(items: dm.items, clock: dm.clock)
                        .accessibilityElement()
                        .accessibilityIdentifier("douyin.touchpad.danmaku")
                        .accessibilityValue("\(dm.items.count)")
                }
                DYCornerBrackets()
                    .padding(.horizontal, 20).padding(.vertical, 18)
                    .allowsHitTesting(false)
                if let hint {
                    Text(hint).font(.footnote).foregroundStyle(Color.white.opacity(0.45))
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 34)
                        .allowsHitTesting(false)
                        .accessibilityIdentifier("douyin.touchpad.hint")
                }
                pad(g.size)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("douyin.touchpad")
    }

    private var link: DYTouchpadLink { .shared }

    private func pad(_ size: CGSize) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 10)
                .onChanged { v in
                    guard !holding, !boostOn else { return }
                    if axis == nil {
                        axis = abs(v.translation.width) > abs(v.translation.height) ? .horizontal : .vertical
                    }
                    guard axis == .horizontal else { return }
                    if !seeking { seeking = true; link.player?.seekBegan(); UIImpactFeedbackGenerator(style: .light).impactOccurred() }
                    link.player?.seekChanged(v.translation.width, max(size.width, 1))
                }
                .onEnded { v in
                    defer { axis = nil }
                    // 长按加速 / 锁定里的滑动，松手不当成快进或翻页
                    if boostOn || holding || Date().timeIntervalSince(lastBoostEnd) < 0.5 { return }
                    if axis == .vertical {
                        // 跟视频区竖滑同手感：位移 60pt 或甩出去（预测 180pt）就翻
                        let dy = v.translation.height, p = v.predictedEndTranslation.height
                        if dy < -60 || p < -180 { page(1) } else if dy > 60 || p > 180 { page(-1) }
                        return
                    }
                    if seeking { seeking = false; link.player?.seekEnded() }
                })
            .simultaneousGesture(LongPressGesture(minimumDuration: DYBoostTiming.holdSeconds)
                .sequenced(before: DragGesture(minimumDistance: 0))
                .updating($holding) { value, state, _ in
                    if case .second(true, _) = value { state = true }
                }
                .onChanged { value in
                    guard case .second(true, let drag?) = value, boostOn, !lockDone else { return }
                    let dy = drag.translation.height
                    guard abs(dy) > 50 else { return }
                    lockDone = true
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    if dy > 0 { link.player?.lockBoost() } else { link.player?.unlockBoost() }
                })
            .onChange(of: holding) { _, on in
                if on {
                    guard !seeking else { return }
                    boostOn = true; lockDone = false
                    link.player?.boost(true)
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                } else if boostOn {
                    boostOn = false
                    lastBoostEnd = Date()
                    link.player?.boost(false)
                }
            }
            .simultaneousGesture(TapGesture().onEnded {
                // 长按松手后系统会补一个单击，吞掉
                if boostOn || Date().timeIntervalSince(lastBoostEnd) < 0.8 || seeking { return }
                onTap()
            })
            .accessibilityIdentifier("douyin.touchpad.pad")
    }

    private func page(_ step: Int) {
        guard let onPage else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onPage(step)
    }
}

/// 触控板弹幕：整块下半屏都是弹幕区，轨道按高度算（稀疏 3 / 标准 5 / 密集 8 条），同 GuoDuo 操作台
private struct DYTouchpadDanmakuLayer: View {
    let items: [DYDanmaku]
    let clock: DYDanmakuClock
    private let deduplicate = DYDanmakuPolicy.deduplicate
    @AppStorage(DYDanmakuPolicy.densityKey) private var densityRaw = DYDanmakuPolicy.Density.standard.rawValue
    var body: some View {
        GeometryReader { g in
            let density = DYDanmakuPolicy.Density(rawValue: densityRaw) ?? .standard
            let top: CGFloat = 16
            let height = max(0, g.size.height - 40 - top)
            let cap = [3, 5, 8][min(max(density.rawValue, 0), 2)]
            let lanes = min(cap, Int(height / DYDanmakuStyle.laneHeight))
            DYDanmakuLiveSurface(items: items, clock: clock, regionTop: top, regionHeight: height,
                                 lanes: lanes, density: .dense, deduplicate: deduplicate)
                .frame(width: g.size.width, height: g.size.height)
        }
        .allowsHitTesting(false)
    }
}

/// 四角取景框（GuoDuo 同款）：告诉你这一整块都能摸
struct DYCornerBrackets: View {
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height, l: CGFloat = 26, r: CGFloat = 8
            Path { p in
                p.move(to: CGPoint(x: 0, y: l)); p.addLine(to: CGPoint(x: 0, y: r))
                p.addQuadCurve(to: CGPoint(x: r, y: 0), control: .zero); p.addLine(to: CGPoint(x: l, y: 0))
                p.move(to: CGPoint(x: w - l, y: 0)); p.addLine(to: CGPoint(x: w - r, y: 0))
                p.addQuadCurve(to: CGPoint(x: w, y: r), control: CGPoint(x: w, y: 0)); p.addLine(to: CGPoint(x: w, y: l))
                p.move(to: CGPoint(x: 0, y: h - l)); p.addLine(to: CGPoint(x: 0, y: h - r))
                p.addQuadCurve(to: CGPoint(x: r, y: h), control: CGPoint(x: 0, y: h)); p.addLine(to: CGPoint(x: l, y: h))
                p.move(to: CGPoint(x: w - l, y: h)); p.addLine(to: CGPoint(x: w - r, y: h))
                p.addQuadCurve(to: CGPoint(x: w, y: h - r), control: CGPoint(x: w, y: h)); p.addLine(to: CGPoint(x: w, y: h - l))
            }
            .stroke(Color.white.opacity(0.22), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
        .accessibilityIdentifier("douyin.touchpad.brackets")
    }
}

/// 只「听」触摸、不拦截：评论区里手指按下 / 移动就回调（记「最后一次碰」的时刻）。挂在 window 上按自身范围过滤。
/// ⚠️ 不能记「按着 / 抬起」这种开关状态：评论区换视频、折叠角度变化时会被重建，按着的那根手指的抬起事件就丢了，
/// 开关卡在「按着」→ 触控板再也不出来。
struct DYTouchSniffer: UIViewRepresentable {
    var onTouch: () -> Void
    func makeUIView(context: Context) -> SnifferView {
        let v = SnifferView(); v.isUserInteractionEnabled = false; v.onTouch = onTouch; return v
    }
    func updateUIView(_ v: SnifferView, context: Context) { v.onTouch = onTouch }

    final class SnifferView: UIView {
        var onTouch: () -> Void = {}
        private var recognizer: Recognizer?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let r = recognizer { r.view?.removeGestureRecognizer(r); recognizer = nil }
            guard let w = window else { return }
            let r = Recognizer(target: nil, action: nil)
            r.cancelsTouchesInView = false
            r.delaysTouchesBegan = false
            r.delaysTouchesEnded = false
            r.owner = self
            r.delegate = r
            w.addGestureRecognizer(r)
            recognizer = r
        }
    }

    /// 一直停在 possible、和谁都同时识别，所以不影响评论区滚动 / 点按；手指全抬起才 failed 复位
    final class Recognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
        weak var owner: SnifferView?
        private var lastPing: CFTimeInterval = 0
        private func ping(_ touches: Set<UITouch>) {
            guard let o = owner, o.window != nil, touches.contains(where: { o.bounds.contains($0.location(in: o)) }) else { return }
            let now = CACurrentMediaTime()
            guard now - lastPing > 0.25 else { return }   // 滑动时别每帧都回调
            lastPing = now; o.onTouch()
        }
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) { ping(touches) }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) { ping(touches) }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { ping(touches); finish(event) }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { finish(event) }
        private func finish(_ event: UIEvent) {
            let left = (event.allTouches ?? []).filter { $0.phase != .ended && $0.phase != .cancelled }
            if left.isEmpty { state = .failed }
        }
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
        func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool { false }
    }
}
