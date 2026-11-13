import SwiftUI
import UIKit

@main struct ProbeApp: App {
    var body: some Scene { WindowGroup { Probe() } }
}
struct Probe: View {
    init() { if let mode = ProcessInfo.processInfo.environment["PROBE_MODE"] { UserDefaults.standard.set(mode, forKey: DYPagingSpeed.key) } }
    @State private var current: String? = "0"
    @State private var seeks=0
    @State private var presses=0
    @State private var ids=(0..<10).map(String.init)
    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(ids, id: \.self) { id in
                    let n = Int(id) ?? 0
                    ZStack { (n % 2 == 0 ? Color.blue : Color.orange); Text("Page \(n)").font(.largeTitle) }
                        .containerRelativeFrame([.horizontal, .vertical])
                        .id(String(n))
                }
            }.scrollTargetLayout().background(DYPagingSpeedBridge(ids:ids, currentID:$current)).background(Inspector())
        }
        .scrollTargetBehavior(.paging).scrollPosition(id: $current)
        .ignoresSafeArea()
        .overlay(alignment:.bottom) { HStack { ForEach(DYPagingSpeed.allCases) { speed in Button(speed.rawValue) { UserDefaults.standard.set(speed.rawValue,forKey:DYPagingSpeed.key) } } }.padding(.bottom,40) }
        .overlay(alignment:.topTrailing) { VStack { Text("seek=\(seeks),press=\(presses)").accessibilityIdentifier("gestures");DYPagingSpeedPicker();Button("reorder") { ids.reverse() } }.padding(.top,100) }
        .overlay(alignment:.topLeading) { Text("ID=\(current ?? "-1")").accessibilityIdentifier("current-id").padding(.top,70) }
    }
}
struct Inspector: UIViewRepresentable {
    func makeUIView(context: Context) -> InspectView { InspectView() }
    func updateUIView(_ view: InspectView, context: Context) {}
}
final class InspectView: UIView {
    weak var scroll: UIScrollView?
    var link: CADisplayLink?
    var previousBusy = false
    var lastOffset: CGFloat = 0
    var stillFrames=0
    var releaseTime: CFTimeInterval?
    var sawDragging = false
    var mode: String { ProcessInfo.processInfo.environment["PROBE_MODE"] ?? "standard" }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { link?.invalidate();link=nil;return }
        DispatchQueue.main.async { [weak self] in self?.attach() }
    }
    func attach() {
        var parent = superview
        while let p = parent, !(p is UIScrollView) { parent=p.superview }
        guard let s=parent as? UIScrollView, s.accessibilityIdentifier != "probe-scroll" else { return }
        scroll=s;s.accessibilityIdentifier="probe-scroll"
        s.panGestureRecognizer.addTarget(self, action:#selector(pan(_:)))


        print("PROBE attach mode=\(mode) paging=\(s.isPagingEnabled) rate=\(s.decelerationRate.rawValue)")
        link=CADisplayLink(target:self,selector:#selector(tick));link?.add(to:.main,forMode:.common)
    }
    @objc func pan(_ g: UIPanGestureRecognizer) {
        if g.state == .ended { releaseTime=CACurrentMediaTime();stillFrames=0;lastOffset=scroll?.contentOffset.y ?? 0 }
    }
    @objc func tick() {
        guard let s=scroll, let time=releaseTime else{return}
        if abs(s.contentOffset.y-lastOffset)<0.1 { stillFrames += 1 } else { stillFrames=0 }
        lastOffset=s.contentOffset.y
        let elapsed=CACurrentMediaTime()-time
        if elapsed>0.15 && stillFrames>=4 {
            s.accessibilityValue="mode=\(mode) duration=\(elapsed) offset=\(s.contentOffset.y) paging=\(s.isPagingEnabled) rate=\(s.decelerationRate.rawValue)"
            releaseTime=nil
        }
    }
}

