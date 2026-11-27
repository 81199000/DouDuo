import CoreGraphics
import Foundation
import Testing

@Suite("视频铺满宽度")
struct DYVideoFitTests {
    @Test(arguments: [16.0 / 9, 4.0 / 3, 2.39, 1.0, 9.0 / 16, 3.0 / 4], [
        CGSize(width: 466, height: 678),
        CGSize(width: 669, height: 951),
        CGSize(width: 951, height: 669),
        CGSize(width: 475, height: 669)
    ])
    func commentPlacementFitsAndAlignsVideoAbovePanel(_ aspect: Double, window: CGSize) {
        let viewport = CGRect(x: 6, y: 12, width: window.width - 12, height: window.height - 24)
        let target = CGRect(x: 16, y: 0, width: window.width - 32, height: window.height / 3)
        let fitted = DYVideoFit.contentSize(container: viewport.size, videoAspect: aspect, fillWidth: false)
        let placement = DYVideoFit.commentPlacement(viewport: viewport, fitted: fitted, target: target)
        let width = fitted.width * placement.scale
        let height = fitted.height * placement.scale
        let center = CGPoint(x: viewport.midX + placement.offset.width, y: viewport.midY + placement.offset.height)

        #expect(abs(width / height - aspect) < 0.001)
        #expect(width <= target.width + 0.001)
        #expect(abs(center.y - height / 2 - target.minY) < 0.001)
        #expect(center.y + height / 2 <= target.maxY + 0.001)
        #expect(abs(center.x - target.midX) < 0.001)

        let restored = DYVideoFit.commentPlacement(viewport: viewport, fitted: fitted, target: nil)
        #expect(restored.scale == 1)
        #expect(restored.offset == .zero)
    }

    @Test(arguments: [
        PinchCase(magnitude: 0.80, committed: false),
        PinchCase(magnitude: 0.93, committed: false),
        PinchCase(magnitude: 0.94, committed: nil),
        PinchCase(magnitude: 1.00, committed: nil),
        PinchCase(magnitude: 1.06, committed: nil),
        PinchCase(magnitude: 1.07, committed: true),
        PinchCase(magnitude: 1.40, committed: true),
    ])
    func pinchCommitsOnlyOutsideDeadZone(_ pinch: PinchCase) {
        #expect(DYVideoFit.pinchCommit(magnitude: pinch.magnitude) == pinch.committed)
    }

    @Test func finishedPinchInNotifiesFitAndPersists() {
        let isolated = isolatedDefaults()
        defer { isolated.defaults.removePersistentDomain(forName: isolated.name) }
        DYVideoFit.setFillWidth(true, in: isolated.defaults)
        var notified: [Bool] = []
        DYVideoFit.applyPinchEnd(magnitude: 0.8, endedNormally: true) { fill in
            notified.append(fill)
            DYVideoFit.setFillWidth(fill, in: isolated.defaults)
        }
        #expect(notified == [false])
        #expect(DYVideoFit.storedFillWidth(in: isolated.defaults) == false)
    }

    @Test func finishedPinchOutNotifiesFillAndPersists() {
        let isolated = isolatedDefaults()
        defer { isolated.defaults.removePersistentDomain(forName: isolated.name) }
        DYVideoFit.setFillWidth(false, in: isolated.defaults)
        DYVideoFit.applyPinchEnd(magnitude: 1.2, endedNormally: true) { fill in
            DYVideoFit.setFillWidth(fill, in: isolated.defaults)
        }
        #expect(DYVideoFit.storedFillWidth(in: isolated.defaults) == true)
    }

    @Test func cancelledOrDeadZonePinchDoesNotNotify() {
        var notified: [Bool] = []
        DYVideoFit.applyPinchEnd(magnitude: 0.8, endedNormally: false) { notified.append($0) }
        DYVideoFit.applyPinchEnd(magnitude: 1.0, endedNormally: true) { notified.append($0) }
        #expect(notified.isEmpty)
    }

    @Test func missingCallbackLeavesStoredPreferenceUntouched() {
        let isolated = isolatedDefaults()
        defer { isolated.defaults.removePersistentDomain(forName: isolated.name) }
        #expect(DYVideoFit.storedFillWidth(in: isolated.defaults) == true)
        DYVideoFit.applyPinchEnd(magnitude: 0.8, endedNormally: true, notify: nil)
        #expect(DYVideoFit.storedFillWidth(in: isolated.defaults) == true)
    }

    @Test func missingPreferenceDefaultsToFill() {
        let isolated = isolatedDefaults()
        defer { isolated.defaults.removePersistentDomain(forName: isolated.name) }
        #expect(DYVideoFit.defaultFillWidth == true)
        #expect(DYVideoFit.storedFillWidth(in: isolated.defaults) == true)
        #expect(DYVideoFit.preferenceKey == "douyin_autofit_v1")
    }

    @Test(arguments: [
        DYVideoFit.Surface.classicMore,
        DYVideoFit.Surface.classicOptions,
    ])
    func playbackSurfacesShowFillWidth(_ surface: DYVideoFit.Surface) {
        #expect(DYVideoFit.showsLabeledControl(on: surface))
        #expect(DYVideoFit.title == "铺满宽度")
        #expect(DYVideoFit.moreIdentifier == "douyin.quick.fit")
    }

    @Test func settingsDoesNotDuplicateThePlaybackControl() {
        #expect(DYVideoFit.showsLabeledControl(on: .settings) == false)
    }

    /// 默认/简洁/极简：右侧按钮栏收藏下已有铺满按钮，「更多」不重复
    @Test func railMoreMenuDoesNotDuplicateTheRailButton() {
        #expect(DYVideoFit.showsLabeledControl(on: .upstreamMore) == false)
    }

    /// 只有经典模式的「更多」放铺满开关；默认/简洁/极简靠右侧按钮栏收藏下那个
    @Test(arguments: ["classic", "rail", "minimal", "duoClassic"])
    func onlyClassicMoreMenuShowsFillWidth(chrome: String) {
        #expect(DYVideoFit.showsLabeledControl(on: DYVideoFit.moreSurface(for: chrome)) == (chrome == "duoClassic"))
    }

    @Test func widerPortraitCropsWhenFilledAndLetterboxesWhenFit() {
        let video = 9.0 / 16.0
        let container = CGSize(width: 820, height: 1000)
        let screen = container.width / container.height
        #expect(DYVideoFit.presentation(fillWidth: true, videoAspect: video, screenAspect: screen) == .aspectFill)
        #expect(DYVideoFit.presentation(fillWidth: false, videoAspect: video, screenAspect: screen) == .aspectFit)
        let filled = DYVideoFit.contentSize(container: container, videoAspect: video, fillWidth: true)
        #expect(filled == container)
        let fitted = DYVideoFit.contentSize(container: container, videoAspect: video, fillWidth: false)
        #expect(fitted.height == container.height)
        #expect(fitted.width < container.width)
        #expect(DYVideoFit.vlcScale(fillWidth: true, videoAspect: video, screenAspect: screen) > 1)
        #expect(DYVideoFit.vlcScale(fillWidth: false, videoAspect: video, screenAspect: screen) == 1)
        #expect(DYVideoFit.releasedScale == 1)
    }

    @Test func foldedPortraitAndPartialFoldKeepTheSamePolicy() {
        let video = 9.0 / 16.0
        let folded = CGSize(width: 390, height: 844)
        let partial = CGSize(width: 700, height: 1000)
        for container in [folded, partial] {
            let screen = container.width / container.height
            #expect(DYVideoFit.presentation(fillWidth: true, videoAspect: video, screenAspect: screen) == .aspectFill)
            #expect(DYVideoFit.contentSize(container: container, videoAspect: video, fillWidth: true) == container)
            let fitted = DYVideoFit.contentSize(container: container, videoAspect: video, fillWidth: false)
            #expect(fitted.width < container.width || fitted.height < container.height)
        }
    }

    @Test func oppositeOrientationStaysFitAndLandscapeFillStillCovers() {
        let portraitVideo = 9.0 / 16.0
        let landscapeScreen = 16.0 / 9.0
        #expect(DYVideoFit.presentation(fillWidth: true, videoAspect: portraitVideo, screenAspect: landscapeScreen) == .aspectFit)
        #expect(DYVideoFit.vlcScale(fillWidth: true, videoAspect: portraitVideo, screenAspect: landscapeScreen) == 1)
        let landscape = CGSize(width: 1200, height: 800)
        let fitted = DYVideoFit.contentSize(container: landscape, videoAspect: portraitVideo, fillWidth: true)
        #expect(fitted.width < landscape.width || fitted.height < landscape.height)

        let landscapeVideo = 16.0 / 9.0
        let screen = landscape.width / landscape.height
        #expect(DYVideoFit.presentation(fillWidth: true, videoAspect: landscapeVideo, screenAspect: screen) == .aspectFill)
        #expect(DYVideoFit.contentSize(container: landscape, videoAspect: landscapeVideo, fillWidth: true) == landscape)
        #expect(DYVideoFit.presentation(fillWidth: false, videoAspect: landscapeVideo, screenAspect: screen) == .aspectFit)
    }

    private func isolatedDefaults() -> (defaults: UserDefaults, name: String) {
        let name = "DYVideoFitTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }
}

struct PinchCase: Sendable {
    var magnitude: CGFloat
    var committed: Bool?

}

@Suite("推荐流横竖选片")
struct DYFeedOrientationTests {
    /// 横屏半折叠 = 竖屏规则
    @Test func halfFoldFlipsFeedOrientation() {
        #expect(!DYVideoFit.feedPlaysLandscape(window: CGSize(width: 466, height: 678), halfFolded: false))  // 外屏竖拿
        #expect(DYVideoFit.feedPlaysLandscape(window: CGSize(width: 951, height: 669), halfFolded: false))   // 内屏横拿展开
        #expect(!DYVideoFit.feedPlaysLandscape(window: CGSize(width: 669, height: 951), halfFolded: false))  // 内屏竖拿展开
        #expect(DYVideoFit.feedPlaysLandscape(window: CGSize(width: 669, height: 951), halfFolded: true))    // 竖拿半折 → 横屏
        #expect(!DYVideoFit.feedPlaysLandscape(window: CGSize(width: 951, height: 669), halfFolded: true))   // 横拿半折 → 竖屏
    }
}

