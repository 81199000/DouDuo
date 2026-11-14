import SwiftUI
import AVFoundation
import CoreImage
import UIKit

/// 环境光试验（仅 DEBUG 启动参数打开，正式包不生效）：
///   DOUDUO_AMBIENT=ext   系统 UIBackgroundExtensionView（iOS 26）直接包住主画面层，内容区=视频实际显示区域
///   DOUDUO_AMBIENT=blur  从同一个 AVPlayerItem 取帧（AVPlayerItemVideoOutput），缩小模糊后铺满背景（TikTok 式）
/// 注：同一个 AVPlayer 再挂第二个 AVPlayerLayer 在真机上不出帧（isReadyForDisplay 一直 false），所以不走那条路。
enum DYAmbientProbe {
    enum Mode: String { case ext, blur }
    static let mode: Mode? = {
        #if DEBUG
        ProcessInfo.processInfo.environment["DOUDUO_AMBIENT"].flatMap(Mode.init(rawValue:))
        #else
        nil
        #endif
    }()
}

// MARK: - ext：系统背景延伸包住主画面

struct DYExtendedVideoSurface: UIViewRepresentable {
    let player: AVPlayer
    var onReady: (() -> Void)? = nil
    func makeUIView(context: Context) -> DYExtendedVideoHost { DYExtendedVideoHost(player: player, onReady: onReady) }
    func updateUIView(_ v: DYExtendedVideoHost, context: Context) { v.setPlayer(player) }
}

final class DYExtendedVideoHost: UIView {
    private let ext = UIBackgroundExtensionView()
    private let surface: PlayerUIView
    private var sizeObs: NSKeyValueObservation?

    init(player: AVPlayer, onReady: (() -> Void)?) {
        surface = PlayerUIView(player: player)
        super.init(frame: .zero)
        backgroundColor = .black
        surface.fillWidth = false
        surface.onReady = onReady
        ext.automaticallyPlacesContentView = false
        ext.contentView = surface
        addSubview(ext)
        watch()
    }
    required init?(coder: NSCoder) { fatalError() }

    func setPlayer(_ p: AVPlayer) {
        guard surface.playerLayer.player !== p else { return }
        surface.playerLayer.player = p; watch(); setNeedsLayout()
    }
    private func watch() {
        sizeObs = surface.playerLayer.player?.currentItem?.observe(\.presentationSize, options: [.initial, .new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.setNeedsLayout() }
        }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        ext.frame = bounds
        if let s = surface.playerLayer.player?.currentItem?.presentationSize, s.width > 1, s.height > 1, bounds.width > 1 {
            surface.frame = AVMakeRect(aspectRatio: s, insideRect: bounds)
        } else {
            surface.frame = bounds
        }
    }
}

// MARK: - blur：取帧做实时环境光

struct DYAmbientBackdrop: UIViewRepresentable {
    let player: AVPlayer
    func makeUIView(context: Context) -> DYAmbientFrameView { DYAmbientFrameView(player: player) }
    func updateUIView(_ v: DYAmbientFrameView, context: Context) { v.player = player }
}

final class DYAmbientFrameView: UIView {
    var player: AVPlayer
    private let imageView = UIImageView()
    private let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    private weak var attachedItem: AVPlayerItem?
    private var link: CADisplayLink?
    private let ci = CIContext(options: [.cacheIntermediates: false])
    #if DEBUG
    private var frames = 0
    #endif

    init(player: AVPlayer) {
        self.player = player
        super.init(frame: .zero)
        backgroundColor = .black
        clipsToBounds = true
        imageView.contentMode = .scaleAspectFill
        imageView.layer.magnificationFilter = .linear
        addSubview(imageView)
        // 主色保持黑：环境光只给到约 55% 亮度
        dim.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        addSubview(dim)
    }
    private let dim = UIView()
    override func layoutSubviews() {
        super.layoutSubviews()
        imageView.frame = bounds
        dim.frame = bounds
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { link?.invalidate(); attachedItem?.remove(output) }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        link?.invalidate(); link = nil
        guard window != nil else { return }
        let l = CADisplayLink(target: DYWeakTarget(self), selector: #selector(DYWeakTarget.tick))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 15, preferred: 12)
        l.add(to: .main, forMode: .common)
        link = l
    }

    fileprivate func tick() {
        guard let item = player.currentItem else { return }
        if attachedItem !== item {
            attachedItem?.remove(output)
            item.add(output)
            attachedItem = item
        }
        let t = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: t),
              let pb = output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil) else { return }
        let src = CIImage(cvPixelBuffer: pb)
        let scale = 48 / max(src.extent.width, 1)
        let small = src.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let blurred = small.clampedToExtent().applyingGaussianBlur(sigma: 3).cropped(to: small.extent)
        guard let cg = ci.createCGImage(blurred, from: small.extent) else { return }
        imageView.image = UIImage(cgImage: cg)
        #if DEBUG
        frames += 1
        if frames == 1 || frames % 60 == 0 {
            var p: [UInt8] = [0,0,0,0]
            if let ctx = CGContext(data: &p, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) { ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1)) }
            ddWrite("DDAMB blur frames=\(frames) src=\(src.extent.size) cg=\(cg.width)x\(cg.height) px=\(p) iv=\(imageView.frame) self=\(frame) win=\(window != nil) super=\(String(describing: superview.map { type(of: $0) }))")
        }
        #endif
    }
}

private final class DYWeakTarget: NSObject {
    weak var view: DYAmbientFrameView?
    init(_ v: DYAmbientFrameView) { view = v }
    @objc func tick() { view?.tick() }
}
