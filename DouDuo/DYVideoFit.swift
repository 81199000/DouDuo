import CoreGraphics
import Foundation

/// 铺满宽度。默认仍然打开：视频和屏幕同向时 Aspect Fill，异向时保持 Aspect Fit。
/// 播放容器始终铺满屏幕；关掉铺满后，内容缩小，四周露出已有的环境光。
enum DYVideoFit {
    static let preferenceKey = "douyin_autofit_v1"
    static let title = "铺满宽度"
    static let moreIdentifier = "douyin.quick.fit"
    /// 与原来的 @AppStorage 默认值一致。本热修不改默认缩放策略。
    static let defaultFillWidth = true
    /// 松手后临时捏合缩放必须回到 1，模式只由 fillWidth 决定。
    static let releasedScale: CGFloat = 1
    static let pinchFitBelow: CGFloat = 0.94
    static let pinchFillAbove: CGFloat = 1.06

    enum Surface: Equatable {
        /// 默认 / 简洁 / 极简，以及从作者、搜索、消息点开的列表播放器。
        case upstreamMore
        /// 经典模式顶栏「更多」。
        case classicMore
        /// 经典模式长按打开的视频设置。
        case classicOptions
        /// 全局设置页不重复放播放页开关。
        case settings
    }

    enum Presentation: Equatable {
        case aspectFill
        case aspectFit
    }

    static func showsLabeledControl(on surface: Surface) -> Bool {
        switch surface {
        case .upstreamMore, .classicMore, .classicOptions: true
        case .settings: false
        }
    }

    /// `duoClassic` 走顶栏更多；其余界面模式走播放页更多。
    static func moreSurface(for chromeMode: String) -> Surface {
        chromeMode == "duoClassic" ? .classicMore : .upstreamMore
    }

    static func storedFillWidth(in defaults: UserDefaults) -> Bool {
        guard defaults.object(forKey: preferenceKey) != nil else { return defaultFillWidth }
        return defaults.bool(forKey: preferenceKey)
    }

    static func setFillWidth(_ fill: Bool, in defaults: UserDefaults) {
        defaults.set(fill, forKey: preferenceKey)
    }

    /// 捏合收拢提交完整画面，捏开展开提交铺满。死区内返回 nil，不改偏好。
    static func pinchCommit(magnitude: CGFloat) -> Bool? {
        if magnitude < pinchFitBelow { return false }
        if magnitude > pinchFillAbove { return true }
        return nil
    }

    /// 只有正常结束的捏合才通知页面。取消或失败不写偏好。
    static func applyPinchEnd(magnitude: CGFloat, endedNormally: Bool, notify: ((Bool) -> Void)?) {
        guard endedNormally, let fill = pinchCommit(magnitude: magnitude) else { return }
        notify?(fill)
    }

    static func sameOrientation(videoAspect: Double, screenAspect: Double) -> Bool {
        (videoAspect < 1) == (screenAspect < 1)
    }

    static func presentation(fillWidth: Bool, videoAspect: Double, screenAspect: Double) -> Presentation {
        (fillWidth && sameOrientation(videoAspect: videoAspect, screenAspect: screenAspect)) ? .aspectFill : .aspectFit
    }

    /// 全屏容器不变。Fit 时返回居中内容尺寸，短边留给环境光。
    static func contentSize(container: CGSize, videoAspect: Double, fillWidth: Bool) -> CGSize {
        guard container.width > 1, container.height > 1 else { return container }
        let screenAspect = container.width / container.height
        let aspect = videoAspect > 0 ? videoAspect : screenAspect
        guard presentation(fillWidth: fillWidth, videoAspect: aspect, screenAspect: screenAspect) == .aspectFit else {
            return container
        }
        if aspect > screenAspect {
            return CGSize(width: container.width, height: container.width / aspect)
        }
        return CGSize(width: container.height * aspect, height: container.height)
    }

    /// VLC 先按等比 fit 画，再只在需要铺满时放大。Fit 的倍数是 1。
    static func vlcScale(fillWidth: Bool, videoAspect: Double, screenAspect: Double) -> CGFloat {
        guard videoAspect > 0, screenAspect > 0 else { return 1 }
        guard presentation(fillWidth: fillWidth, videoAspect: videoAspect, screenAspect: screenAspect) == .aspectFill else { return 1 }
        return CGFloat(max(screenAspect / videoAspect, videoAspect / screenAspect))
    }
}
