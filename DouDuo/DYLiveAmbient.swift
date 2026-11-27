import SwiftUI
import CoreImage
import UIKit
import VLCKitSPM

/// 推荐流里刷到的直播：环境光。
/// 视频那套（DYAmbientFrameView）是从 AVPlayerItem 取帧；直播走 VLC，没有 AVPlayerItem，
/// 改用 VLC 自带截图：每 0.5 秒截一张 48px 宽的小图，同样模糊 + 降饱和 + 压暗铺满背景。
/// - 截图在后台串行队列做（libvlc 截图会等下一帧，不能放主线程）；上一张没好不截下一张
/// - 只有当前条、没铺满（竖屏直播铺满整屏时背景看不见）、不发热时才截
/// - 压暗程度 / 开关跟视频共用设置里的「环境光」
struct DYLiveAmbientBackdrop: UIViewRepresentable {
    let controller: VLCPlayerController
    var active: Bool
    var dim: Double
    var fillWidth: Bool
    func makeUIView(context: Context) -> DYLiveAmbientView { DYLiveAmbientView(controller: controller) }
    func updateUIView(_ v: DYLiveAmbientView, context: Context) {
        v.controller = controller
        v.dim = dim
        v.fillWidth = fillWidth
        v.active = active
    }
}

final class DYLiveAmbientView: UIView {
    weak var controller: VLCPlayerController?
    var active = false { didSet { if active != oldValue { updateTimer() } } }
    var dim: Double = 0.6 { didSet { dimView.backgroundColor = UIColor.black.withAlphaComponent(dim) } }
    var fillWidth = true
    private let imageView = UIImageView()
    private let dimView = UIView()
    private var timer: Timer?
    private var working = false
    private var misses = 0
    private var startedAt = CACurrentMediaTime()
    private let file = FileManager.default.temporaryDirectory.appendingPathComponent("dd-live-ambient-\(UUID().uuidString).png")
    private static let ci = CIContext(options: [.cacheIntermediates: false])
    private static let queue = DispatchQueue(label: "douduo.live.ambient", qos: .utility)
    /// 截图间隔：直播画面变化慢，背景光 2 帧/秒看着就是连续的（视频那边 6 帧，但它取帧几乎不花钱）
    static let interval: TimeInterval = 0.5
    static let width: Int32 = 48

    init(controller: VLCPlayerController) {
        self.controller = controller
        super.init(frame: .zero)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        clipsToBounds = true
        imageView.contentMode = .scaleAspectFill
        imageView.layer.magnificationFilter = .linear
        imageView.alpha = 0
        dimView.alpha = 0
        dimView.backgroundColor = UIColor.black.withAlphaComponent(dim)
        addSubview(imageView)
        addSubview(dimView)
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit {
        timer?.invalidate()
        let f = file
        Self.queue.async { try? FileManager.default.removeItem(at: f) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = bounds
        dimView.frame = bounds
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateTimer()
    }

    private func updateTimer() {
        let hot = ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
        if active, window != nil, !hot, !DDPerfExperiment.off("AMBIENT") {
            guard timer == nil else { return }
            startedAt = CACurrentMediaTime()
            let t = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in self?.tick() }
            t.tolerance = 0.1
            RunLoop.main.add(t, forMode: .common)
            timer = t
            tick()
        } else {
            timer?.invalidate(); timer = nil
        }
    }

    /// 竖屏直播铺满整屏：背景完全被盖住，不截
    private var covered: Bool {
        guard let vs = controller?.videoSize, vs.width > 1, vs.height > 1, bounds.width > 1, bounds.height > 1 else { return false }
        return DYVideoFit.presentation(fillWidth: fillWidth, videoAspect: vs.width / vs.height,
                                       screenAspect: bounds.width / bounds.height) == .aspectFill
    }

    private func tick() {
        guard !working, let c = controller, c.videoSize.width > 0, !covered, let mp = c.mediaPlayer, mp.hasVideoOut else { return }
        working = true
        let path = file.path, url = file
        Self.queue.async { [weak self] in
            try? FileManager.default.removeItem(at: url)
            let t0 = CACurrentMediaTime()
            // ⚠️ VLCKit 截不到图（视频输出刚拆掉 / 换流 / 停播中）时不是返回失败，而是直接 @throw NSException
            // （"Can't take a video snapshot: No video output"）。Swift 接不住，后台队列上未捕获 = 整个 App 闪退，
            // 刷到直播每 0.5 秒截一次，碰上就崩、重开再崩。交给 ObjC 接住，当一次没出图。
            var reason: NSString?
            let ok = DDTryObjC({ mp.saveVideoSnapshot(at: path, withWidth: Self.width, andHeight: 0) }, &reason)
            let cg = ok ? Self.blurred(UIImage(contentsOfFile: path)) : nil
            let ms = Int((CACurrentMediaTime() - t0) * 1000)
            DispatchQueue.main.async {
                guard let self else { return }
                self.working = false
                guard let cg else {
                    self.misses += 1
                    if !ok, self.misses <= 3 || self.misses % 20 == 0 {
                        DYLiveModel.log("DDLIVEAMBIENT snapshot 抛异常已接住 n=\(self.misses) \(reason ?? "-")")
                    }
                    if self.misses == 3 { DYLiveModel.log("DDLIVEAMBIENT snapshot 连续 3 次没出图 ms=\(ms)") }
                    return
                }
                self.imageView.image = UIImage(cgImage: cg)
                if self.imageView.alpha == 0 {
                    DYLiveModel.log("DDLIVEAMBIENT first after=\(Int((CACurrentMediaTime() - self.startedAt) * 1000))ms snap=\(ms)ms \(cg.width)x\(cg.height) misses=\(self.misses)")
                    UIView.animate(withDuration: 0.25) { self.imageView.alpha = 1; self.dimView.alpha = 1 }
                }
            }
        }
    }

    /// 与视频环境光同一套处理：小图 → 高斯模糊 σ3 → 饱和度 0.85
    static func blurred(_ img: UIImage?) -> CGImage? {
        guard let cg = img?.cgImage else { return nil }
        let src = CIImage(cgImage: cg)
        let scale = 48 / max(src.extent.width, 1)
        let small = src.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let out = small.clampedToExtent().applyingGaussianBlur(sigma: 3).cropped(to: small.extent)
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.85])
        return ci.createCGImage(out, from: small.extent)
    }
}
