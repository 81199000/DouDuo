import SwiftUI
import UIKit

/// 桌面投光：竖屏半折叠（桌面姿态）时，上半屏视频像一块立着的屏幕，
/// 把画面的光投到下半屏评论区这张「桌面」上。
/// - 光源复用环境光取帧（DYAmbientFrameView，48px 宽、已模糊），不另挂播放器输出。
/// - 画面上下翻转后压扁、左右放宽：靠近折痕的是视频底边，最亮；离折痕越远越淡、越散。
/// - 直接把帧推给投光视图，不经过 SwiftUI 状态（12 帧/秒的值挂到视图树上会让整页反复重算）。
@MainActor
enum DYDeskLightHub {
    private static let sinks = NSHashTable<DYDeskLightView>.weakObjects()
    /// 有投光视图在屏幕上时，环境光即使被铺满的画面盖住也继续取帧
    static var wanted: Bool { sinks.allObjects.contains { $0.window != nil } }
    static func add(_ v: DYDeskLightView) { sinks.add(v) }
    static func remove(_ v: DYDeskLightView) { sinks.remove(v) }
    static func publish(_ image: CGImage) {
        for v in sinks.allObjects where v.window != nil { v.show(image) }
    }
}

struct DYDeskLight: UIViewRepresentable {
    func makeUIView(context: Context) -> DYDeskLightView { DYDeskLightView() }
    func updateUIView(_ v: DYDeskLightView, context: Context) {}
}

final class DYDeskLightView: UIView {
    private let imageView = UIImageView()
    private let falloff = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        clipsToBounds = true
        alpha = 0
        imageView.contentMode = .scaleToFill
        imageView.layer.magnificationFilter = .linear
        // 倒影：视频底边贴着折痕
        imageView.transform = CGAffineTransform(scaleX: 1, y: -1)
        addSubview(imageView)
        // 椭圆衰减：折痕正中最亮，往两侧和往下逐渐暗下去
        falloff.type = .radial
        falloff.startPoint = CGPoint(x: 0.5, y: 0)
        falloff.endPoint = CGPoint(x: 1.15, y: 0.95)
        falloff.colors = [UIColor(white: 1, alpha: 1).cgColor,
                          UIColor(white: 1, alpha: 0.55).cgColor,
                          UIColor(white: 1, alpha: 0.18).cgColor,
                          UIColor(white: 1, alpha: 0).cgColor]
        falloff.locations = [0, 0.3, 0.62, 1]
        layer.mask = falloff
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width, h = bounds.height
        // 透视：落在桌面上的光被压扁（约 0.75 高），并向两侧铺开（1.4 宽）
        imageView.bounds = CGRect(x: 0, y: 0, width: w * 1.4, height: h * 0.75)
        imageView.center = CGPoint(x: w / 2, y: h * 0.375)
        falloff.frame = bounds
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { DYDeskLightHub.add(self) } else { DYDeskLightHub.remove(self); alpha = 0 }
    }

    func show(_ image: CGImage) {
        imageView.image = UIImage(cgImage: image)
        if alpha == 0 { UIView.animate(withDuration: 0.35) { self.alpha = 1 } }
    }
}

extension View {
    /// 桌面姿态下给评论区加投光；其他姿态原样返回
    @ViewBuilder
    func dyDeskLight(_ on: Bool) -> some View {
        if on {
            overlay {
                DYDeskLight()
                    .blendMode(.screen)
                    .opacity(0.8)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .accessibilityIdentifier("douyin.comments.deskLight")
            }
        } else {
            self
        }
    }
}
