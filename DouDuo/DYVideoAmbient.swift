import SwiftUI
import AVFoundation
import CoreImage
import UIKit

/// 视频环境光：从正在播的 AVPlayerItem 取帧（AVPlayerItemVideoOutput），缩成 48px 宽、模糊后铺满背景再压暗。
/// 主色保持黑，颜色跟着画面实时变（TikTok 式）。替代原来的「模糊封面」静态背景。
/// 试过放弃的两条路（2026-11 Duo 真机实测）：
/// - 同一个 AVPlayer 再挂第二个 AVPlayerLayer：第二层一直不出帧（isReadyForDisplay=false）。
/// - 系统 UIBackgroundExtensionView：是把画面边缘镜像拉伸出去，出竖条色带，不是环境光。
enum DYVideoAmbient {
    static let key = "douyin_ambient_dim_v1"
    /// 存的值只区分开关：0 = 关（退回模糊封面），其余 = 开
    static let onLevel = 70
    static let defaultLevel = onLevel
    /// 开着时统一按「暗」压暗
    static let dim: Double = Double(onLevel) / 100
}

struct DYAmbientBackdrop: UIViewRepresentable {
    @Environment(\.dyHingeClosed) private var hingeClosed
    let player: AVPlayer
    var active: Bool
    var dim: Double
    var fillWidth: Bool
    func makeUIView(context: Context) -> DYAmbientFrameView { DYAmbientFrameView(player: player) }
    func updateUIView(_ v: DYAmbientFrameView, context: Context) {
        v.player = player
        v.dim = dim
        v.fillWidth = fillWidth
        v.hingeClosed = hingeClosed
        v.active = active
    }
}

final class DYAmbientFrameView: UIView {
    var player: AVPlayer
    /// 只有当前页取帧；预加载页、滑走的页停掉，不白耗电
    var active = false { didSet { if active != oldValue { updateLink() } } }
    var dim: Double = 0.45 { didSet { dimView.backgroundColor = UIColor.black.withAlphaComponent(dim) } }
    var fillWidth = true { didSet { if fillWidth != oldValue { setNeedsLayout() } } }
    var hingeClosed = false { didSet { if hingeClosed != oldValue { setNeedsLayout() } } }
    private let imageView = UIImageView()
    private let dimView = UIView()
    private let mirrors = (0..<2).map { _ in DYAmbientMirror() }
    private let spread = CAGradientLayer()
    private var videoAspect: CGFloat = 0
    private var lastFrame: CIImage?
    private var shown = false
    private let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    private weak var attachedItem: AVPlayerItem?
    private var link: CADisplayLink?
    private static let ci = CIContext(options: [.cacheIntermediates: false])
    private static let queue = DispatchQueue(label: "douduo.ambient", qos: .utility)
    /// 上一帧还没处理完就不取新帧（不堆积）
    private var working = false

    init(player: AVPlayer) {
        self.player = player
        super.init(frame: .zero)
        // 出第一帧之前透明，下面的模糊封面先顶着
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
        for m in mirrors { m.alpha = 0; addSubview(m) }
        imageView.layer.mask = spread
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { link?.invalidate(); attachedItem?.remove(output) }

    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = bounds
        dimView.frame = bounds
        layoutMirrors()
    }

    private var videoRect: CGRect? {
        guard videoAspect > 0, bounds.width > 1, bounds.height > 1 else { return nil }
        let fitted = DYVideoFit.contentSize(container: bounds.size, videoAspect: Double(videoAspect), fillWidth: fillWidth)
        let dx = DYDuoMetrics.closedPortraitVideoOffset(viewport: bounds.size, videoAspect: Double(videoAspect), fills: fillWidth,
                                                        isDuo: DYDuoMetrics.isDuoHardware, isClosed: hingeClosed)
        return CGRect(x: (bounds.width - fitted.width) / 2 + dx, y: (bounds.height - fitted.height) / 2,
                      width: fitted.width, height: fitted.height)
    }

    private func layoutSpread(_ v: CGRect, horizontal: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spread.frame = imageView.bounds
        let full = UIColor.white.cgColor, none = UIColor(white: 1, alpha: 0).cgColor
        if horizontal {
            spread.startPoint = CGPoint(x: 0, y: 0.5); spread.endPoint = CGPoint(x: 1, y: 0.5)
            let a = v.minX / max(bounds.width, 1), b = v.maxX / max(bounds.width, 1)
            spread.locations = [0, NSNumber(value: Double(a)), NSNumber(value: Double(b)), 1]
        } else {
            spread.startPoint = CGPoint(x: 0.5, y: 0); spread.endPoint = CGPoint(x: 0.5, y: 1)
            let a = v.minY / max(bounds.height, 1), b = v.maxY / max(bounds.height, 1)
            spread.locations = [0, NSNumber(value: Double(a)), NSNumber(value: Double(b)), 1]
        }
        spread.colors = [none, full, full, none]
        CATransaction.commit()
    }

    private func layoutMirrors() {
        guard let v = videoRect else {
            for m in mirrors { m.isHidden = true }
            spread.frame = imageView.bounds; spread.colors = [UIColor.white.cgColor, UIColor.white.cgColor]
            return
        }
        let horizontal = v.minX > 2 || bounds.maxX - v.maxX > 2
        let vertical = v.minY > 2 || bounds.maxY - v.maxY > 2
        let sideways = horizontal && !(vertical && (bounds.height - v.height) > (bounds.width - v.width))
        layoutSpread(v, horizontal: sideways)
        if sideways {
            mirrors[0].place(.left, video: v, gap: CGRect(x: 0, y: v.minY, width: v.minX, height: v.height))
            mirrors[1].place(.right, video: v, gap: CGRect(x: v.maxX, y: v.minY, width: bounds.maxX - v.maxX, height: v.height))
        } else if vertical {
            mirrors[0].place(.top, video: v, gap: CGRect(x: v.minX, y: 0, width: v.width, height: v.minY))
            mirrors[1].place(.bottom, video: v, gap: CGRect(x: v.minX, y: v.maxY, width: v.width, height: bounds.maxY - v.maxY))
        } else {
            for m in mirrors { m.isHidden = true }
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        attachEarly()
        updateLink()
    }

    /// 取帧输出必须在视频「还停着」的时候挂上：给正在起播的 AVPlayerItem 加 VideoOutput 会让播放管线重建，
    /// 画面和声音一起顿一下、往回弹一帧。
    /// 页面一挂载（预热播放器已经接上）就挂，切过去起播时不再动管线。
    private func attachEarly() {
        guard window != nil, let item = player.currentItem, attachedItem !== item else { return }
        attachedItem?.remove(output)
        item.add(output)
        attachedItem = item
    }

    private func updateLink() {
        // 发热（serious 及以上）时停掉环境光取帧：背景留在最后一帧，不再每秒做图像处理（抖音同款发热降载）
        let hot = ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
        let primeOnly = !active && window != nil && !shown && !hot
        if (active || primeOnly) && window != nil && !hot && !DDPerfExperiment.off("AMBIENT") {
            guard link == nil else { return }
            let l = CADisplayLink(target: DYAmbientTick(self), selector: #selector(DYAmbientTick.tick))
            // 环境光不用 60 帧，12 帧左右看着就是连续的
            // 实测这一项占主线程约 1 成（每帧缩图 + 高斯模糊 + 生成图片都在主线程）；背景光变化慢，6 帧足够
            l.preferredFrameRateRange = CAFrameRateRange(minimum: 4, maximum: 8, preferred: 6)
            l.add(to: .main, forMode: .common)
            link = l
        } else {
            link?.invalidate(); link = nil
            // 不再在失活时摘掉输出：摘/挂都会动播放管线，留着直到页面销毁（deinit 里摘）
            if window == nil { attachedItem?.remove(output); attachedItem = nil }
            else { attachEarly() }
        }
    }

    /// 铺满模式下画面盖住整页，没有地方露背景，不取帧
    private var covered: Bool {
        guard let s = player.currentItem?.presentationSize, s.width > 1, s.height > 1,
              bounds.width > 1, bounds.height > 1 else { return false }
        return DYVideoFit.presentation(fillWidth: fillWidth, videoAspect: s.width / s.height,
                                       screenAspect: bounds.width / bounds.height) == .aspectFill
    }

    fileprivate func tick() {
        // 画面铺满时背景看不见，但桌面姿态的评论区还在等投光，照样取帧
        guard !covered || DYDeskLightHub.wanted, let item = player.currentItem else { return }
        // 秒开高清接管、头部缓存接在线流都会换 item，跟着换
        if attachedItem !== item {
            attachedItem?.remove(output)
            item.add(output)
            attachedItem = item
        }
        let t = player.rate == 0 ? item.currentTime() : output.itemTime(forHostTime: CACurrentMediaTime())
        guard !working, active || !shown, output.hasNewPixelBuffer(forItemTime: t) || (!shown && player.rate == 0),
              let pb = output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) else { return }
        // 缩图 + 模糊 + 生成图片放到后台队列（真机：环境光占主线程约 1 成），主线程只换图
        working = true
        let desk = DYDeskLightHub.wanted
        let previous = lastFrame
        Self.queue.async { [weak self] in
            let src = CIImage(cvPixelBuffer: pb)
            let scale = 64 / max(src.extent.width, 1)
            var small = src.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            small = small.transformed(by: CGAffineTransform(translationX: -small.extent.minX, y: -small.extent.minY))
            if let previous, previous.extent.size == small.extent.size {
                small = small.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: small, kCIInputImageKey: previous, kCIInputTimeKey: 0.35])
                    .cropped(to: small.extent)
            }
            let smoothed = Self.ci.createCGImage(small, from: small.extent).map { CIImage(cgImage: $0) }
            let base = smoothed ?? small
            let glow = base.clampedToExtent().applyingGaussianBlur(sigma: 4).cropped(to: base.extent)
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.8])
            let mirror = base.clampedToExtent().applyingGaussianBlur(sigma: 3.2).cropped(to: base.extent)
                .applyingFilter("CIGammaAdjust", parameters: ["inputPower": 1.3])
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.05])
            let cg = Self.ci.createCGImage(glow, from: base.extent)
            let mg = Self.ci.createCGImage(mirror, from: base.extent)
            let proj = desk ? DYDeskProjection.render(src, ci: Self.ci) : nil
            let aspect = src.extent.width / max(src.extent.height, 1)
            DispatchQueue.main.async {
                guard let self else { return }
                self.working = false
                self.lastFrame = smoothed
                if abs(aspect - self.videoAspect) > 0.01 { self.videoAspect = aspect; self.setNeedsLayout() }
                if let cg { self.swap(self.imageView, UIImage(cgImage: cg)) }
                if let mg { for m in self.mirrors { m.show(UIImage(cgImage: mg), animated: self.shown) } }
                if let proj { DYDeskLightHub.publish(proj.image, glow: proj.glow, aspect: aspect) }
                if !self.shown, cg != nil {
                    self.shown = true
                    let reveal = {
                        self.imageView.alpha = 0.4; self.dimView.alpha = 1
                        for m in self.mirrors { m.alpha = 1 }
                    }
                    if self.active {
                        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseOut, .allowUserInteraction], animations: reveal)
                    } else {
                        reveal()
                        self.updateLink()
                    }
                    DYLiveModel.log("DDAMBIENT ready active=\(self.active) rate=\(self.player.rate)")
                }
            }
        }
    }

    private func swap(_ view: UIImageView, _ image: UIImage) {
        if shown {
            let t = CATransition()
            t.type = .fade
            t.duration = 0.3
            view.layer.add(t, forKey: "ambient")
        }
        view.image = image
    }
}

final class DYAmbientMirror: UIView {
    enum Side { case left, right, top, bottom }
    private let box = UIView()
    private let imageView = UIImageView()
    private let fade = CAGradientLayer()
    private var side: Side = .left
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        clipsToBounds = true
        imageView.contentMode = .scaleToFill
        imageView.layer.magnificationFilter = .linear
        box.addSubview(imageView)
        addSubview(box)
        layer.mask = fade
    }
    required init?(coder: NSCoder) { fatalError() }

    func place(_ side: Side, video: CGRect, gap: CGRect) {
        self.side = side
        isHidden = gap.width < 2 || gap.height < 2
        guard !isHidden else { return }
        frame = gap
        fade.frame = bounds
        let strong = UIColor(white: 1, alpha: 0.4).cgColor, mid = UIColor(white: 1, alpha: 0.12).cgColor, none = UIColor(white: 1, alpha: 0).cgColor
        switch side {
        case .left: fade.startPoint = CGPoint(x: 1, y: 0.5); fade.endPoint = CGPoint(x: 0, y: 0.5)
        case .right: fade.startPoint = CGPoint(x: 0, y: 0.5); fade.endPoint = CGPoint(x: 1, y: 0.5)
        case .top: fade.startPoint = CGPoint(x: 0.5, y: 1); fade.endPoint = CGPoint(x: 0.5, y: 0)
        case .bottom: fade.startPoint = CGPoint(x: 0.5, y: 0); fade.endPoint = CGPoint(x: 0.5, y: 1)
        }
        fade.colors = [strong, mid, none]
        fade.locations = [0, 0.4, 1]
        let w = video.width, h = video.height
        box.transform = .identity
        switch side {
        case .left:
            box.frame = CGRect(x: gap.width - w, y: 0, width: w, height: h)
            box.transform = CGAffineTransform(scaleX: -1, y: 1)
        case .right:
            box.frame = CGRect(x: 0, y: 0, width: w, height: h)
            box.transform = CGAffineTransform(scaleX: -1, y: 1)
        case .top:
            box.frame = CGRect(x: 0, y: gap.height - h, width: w, height: h)
            box.transform = CGAffineTransform(scaleX: 1, y: -1)
        case .bottom:
            box.frame = CGRect(x: 0, y: 0, width: w, height: h)
            box.transform = CGAffineTransform(scaleX: 1, y: -1)
        }
        imageView.frame = box.bounds
    }

    func show(_ image: UIImage, animated: Bool) {
        if animated {
            let t = CATransition()
            t.type = .fade
            t.duration = 0.3
            imageView.layer.add(t, forKey: "ambient")
        }
        imageView.image = image
    }
}

private final class DYAmbientTick: NSObject {
    weak var view: DYAmbientFrameView?
    init(_ v: DYAmbientFrameView) { view = v }
    @objc func tick() { view?.tick() }
}

