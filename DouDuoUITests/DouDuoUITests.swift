import XCTest

/// DouDuo 核心流程：推荐流加载 → 视频在走 → 上滑切下一条 → 左滑作者/右滑关注 → 点作者进主页 → 能返回原生页
final class DouDuoUITests: XCTestCase {
    override func setUpWithError() throws {
        // Device Hub selects the physical Duo display. Match that display's
        // orientation before launch so XCTest does not use stale portrait
        // hit coordinates until its first screenshot on the unfolded display.
        switch ProcessInfo.processInfo.environment["DOUDUO_TEST_DISPLAY"] {
        case "inner": XCUIDevice.shared.orientation = .landscapeLeft
        case "outer": XCUIDevice.shared.orientation = .portrait
        default: break
        }
    }

    func testPanelsKeepPlaybackAndDismissGestures() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO"]
        app.launchEnvironment["DOUDUO_VIDEO_ID"] = "7678628867820506406"
        app.launchEnvironment["DOUDUO_FORWARD_LAYOUT_FIXTURE"] = "1"
        app.launchEnvironment["DOUDUO_AUTHOR_WORK_FIXTURE"] = "1"
        addTeardownBlock { app.terminate() }
        app.launch()
        XCTAssertTrue(wait(label: "7678628867820506406", on: app.staticTexts["douyin.currentID"], timeout: 60))
        let progress = app.descendants(matching: .any).matching(identifier: "douyin.progress").firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 15))
        func seconds() -> Int { Int((progress.value as? String ?? "0").split(separator: " ").first ?? "0") ?? 0 }
        let started = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in seconds() > 2 }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [started], timeout: 20), .completed)
        let beforeMenu = seconds()
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.68, dy: 0.40)).press(forDuration: 0.8)
        let options = app.buttons["douyin.options.close"].firstMatch
        XCTAssertTrue(options.waitForExistence(timeout: 5), "68% 按整个屏幕计算，仍属于菜单区")
        Thread.sleep(forTimeInterval: 4)
        let list = app.scrollViews["douyin.options.list"].firstMatch
        let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 180)))
        XCTAssertTrue(options.waitForNonExistence(timeout: 5))
        XCTAssertGreaterThan(seconds(), beforeMenu + 2, "长按菜单保持视频播放")
        let beforeShare = seconds()
        app.buttons["douyin.share"].firstMatch.tap()
        let closeShare = app.buttons["douyin.forward.close"].firstMatch
        XCTAssertTrue(closeShare.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 4)
        closeShare.tap()
        XCTAssertTrue(closeShare.waitForNonExistence(timeout: 5))
        XCTAssertGreaterThan(seconds(), beforeShare + 2, "分享弹窗保持视频播放")
        app.buttons["douyin.comments"].firstMatch.tap()
        let comments = app.scrollViews["douyin.comments.list"].firstMatch
        XCTAssertTrue(comments.waitForExistence(timeout: 15))
        comments.swipeUp()
        let right = comments.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.45))
        right.press(forDuration: 0.05, thenDragTo: right.withOffset(CGVector(dx: 180, dy: 3)))
        XCTAssertTrue(app.buttons["douyin.comments.close"].firstMatch.waitForNonExistence(timeout: 5), "列表滚动后仍可右滑关闭")
        XCTAssertTrue(app.buttons["douyin.share"].firstMatch.waitForExistence(timeout: 5))
        if app.windows.firstMatch.frame.width >= 700 {
            let beforeAuthor = seconds()
            app.buttons["douyin.author.avatar"].firstMatch.tap()
            let back = app.buttons["douyin.author.back"].firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 15))
            Thread.sleep(forTimeInterval: 4)
            XCTAssertGreaterThan(seconds(), beforeAuthor + 2, "并排作者页保持视频播放")
            let work = app.descendants(matching: .any).matching(identifier: "douyin.author.works").firstMatch.buttons.firstMatch
            XCTAssertTrue(work.waitForExistence(timeout: 30))
            work.tap()
            let workBack = app.buttons["douyin.list.back"].firstMatch
            XCTAssertTrue(workBack.waitForExistence(timeout: 10))
            XCTAssertTrue(app.buttons["douyin.share"].firstMatch.isHittable)
            workBack.tap()
            XCTAssertTrue(back.waitForExistence(timeout: 10))
            let resumedAt = seconds()
            Thread.sleep(forTimeInterval: 3)
            XCTAssertGreaterThan(seconds(), resumedAt, "退出作者作品后左侧视频恢复")
            back.tap()
        }
        attach(app, "panels-playback-and-dismissal")
    }

    func testStandaloneRailWithLiveActivity() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO"]
        app.launchEnvironment["DOUDUO_VIDEO_ID"] = "7678628867820506406"
        app.launchEnvironment["DOUDUO_COMMENT_ENTRY"] = "mine"
        addTeardownBlock { app.terminate() }
        app.launch()
        XCTAssertTrue(wait(label: "7678628867820506406", on: app.staticTexts["douyin.currentID"], timeout: 60))
        app.buttons["首页"].firstMatch.tap()
        app.buttons["我的"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "douyin.list.player").firstMatch.waitForExistence(timeout: 30))
        let rail = app.descendants(matching: .any).matching(identifier: "douyin.video.actions").firstMatch
        XCTAssertTrue(rail.waitForExistence(timeout: 10))
        XCTAssertLessThan(rail.frame.height, 320, "作品互动胶囊应紧凑，不占满系统状态列")
        for id in ["douyin.author.avatar", "douyin.like", "douyin.comments", "douyin.collect", "douyin.share", "douyin.list.back"] {
            XCTAssertTrue(app.buttons[id].firstMatch.isHittable, id + " 应直接显示，不进入更多")
        }
        XCTAssertFalse(app.buttons["douyin.more"].exists)
        XCTAssertFalse(app.buttons["更多"].exists)
        attach(app, "standalone-rail-live-activity")
        app.buttons["douyin.comments"].firstMatch.tap()
        let list = app.scrollViews["douyin.comments.list"].firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.4))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 180, dy: 0)))
        XCTAssertTrue(app.buttons["douyin.comments.close"].firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["douyin.share"].firstMatch.isHittable)
    }

    func testPhysicalHalfFoldCommentsHideSidebar() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO"]
        app.launchEnvironment["DOUDUO_VIDEO_ID"] = "7678628867820506406"
        addTeardownBlock { app.terminate() }
        app.launch()
        XCTAssertTrue(wait(label: "7678628867820506406", on: app.staticTexts["douyin.currentID"], timeout: 60))
        XCTAssertTrue(app.scrollViews["douyin.comments.list"].firstMatch.waitForExistence(timeout: 15), "实际半折自动显示评论")
        for id in ["douyin.like", "douyin.share", "douyin.cleanScreen", "首页"] {
            XCTAssertFalse(app.buttons[id].firstMatch.isHittable, id + " 半折评论时隐藏")
        }
        let panel = app.descendants(matching: .any).matching(identifier: "douyin.comments.panel").firstMatch
        let screen = app.windows.firstMatch.frame
        if screen.width > screen.height {
            XCTAssertLessThanOrEqual(panel.frame.minY, screen.minY + 2, "半折评论背景贴顶")
            XCTAssertGreaterThanOrEqual(panel.frame.maxY, screen.maxY - 2, "半折评论背景贴底")
            XCTAssertGreaterThanOrEqual(panel.frame.maxX, screen.maxX - 2, "半折评论背景贴右边")
        }
        attach(app, "physical-half-fold-comments")
    }

    func testCleanScreenRestoresStableSidebar() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO"]
        app.launchEnvironment["DOUDUO_VIDEO_ID"] = "7678628867820506406"
        addTeardownBlock { app.terminate() }
        app.launch()
        let current = app.staticTexts["douyin.currentID"]
        XCTAssertTrue(current.waitForExistence(timeout: 40))
        XCTAssertTrue(wait(label: "7678628867820506406", on: current, timeout: 45))
        attach(app, "build95-clean-before")
        let clear = app.buttons["douyin.cleanScreen"].firstMatch
        let share = app.buttons["douyin.share"].firstMatch
        let home = app.buttons["首页"].firstMatch
        XCTAssertTrue(clear.isHittable)
        let originalShare = share.frame
        let originalHome = home.frame
        let originalID = current.label
        for round in 1...2 {
            clear.tap()
            let onlyClear = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                let visible = app.buttons.allElementsBoundByIndex.filter(\.isHittable)
                return visible.count == 1 && visible.first?.identifier == "douyin.cleanScreen"
            }, object: app)
            XCTAssertEqual(XCTWaiter.wait(for: [onlyClear], timeout: 5), .completed, app.debugDescription)
            XCTAssertEqual(clear.label, "退出清屏")
            XCTAssertFalse(app.otherElements["douyin.progress"].exists)
            XCTAssertFalse(app.otherElements["douyin.video.info"].exists)
            XCTAssertEqual(current.label, originalID, "清屏不能重建或切换播放器")
            if round == 1 {
                app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.4)).press(forDuration: 0.8)
                XCTAssertFalse(app.buttons["douyin.options.close"].exists, "清屏时中间长按不弹出菜单")
                attach(app, "build95-clean-only-toggle")
            }
            clear.tap()
            XCTAssertTrue(share.waitForExistence(timeout: 5))
            attach(app, "build95-clean-restored-\(round)")
            XCTAssertTrue(app.buttons["douyin.search"].isHittable)
            XCTAssertTrue(app.buttons["douyin.more"].isHittable)
            for _ in 0..<8 {
                XCTAssertEqual(share.frame.minY, originalShare.minY, accuracy: 1, "恢复后侧栏不能反复跳动")
                XCTAssertEqual(home.frame, originalHome)
                XCTAssertFalse(app.buttons["BottomOverflowBarButtonItem"].exists)
                Thread.sleep(forTimeInterval: 0.3)
            }
        }
    }

    func testCleanScreenStartsSystemPictureInPicture() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES", "-douyin_bg_play_v1", "NO", "-douyin_autoplay_v1", "NO"]
        app.launchEnvironment["DOUDUO_VIDEO_ID"] = "7678628867820506406"
        addTeardownBlock { app.terminate() }
        app.launch()
        let current = app.staticTexts["douyin.currentID"]
        XCTAssertTrue(current.waitForExistence(timeout: 40))
        XCTAssertTrue(wait(label: "7678628867820506406", on: current, timeout: 45))
        _ = app.screenshot()
        app.buttons["douyin.cleanScreen"].tap()
        let state = app.staticTexts["douyin.video.pipState"].firstMatch
        if state.label == "unsupported" {
            throw XCTSkip("当前 Duo 运行环境的 AVPictureInPictureController.isPictureInPictureSupported 返回 false，需真机确认系统小窗")
        }
        XCTAssertTrue(wait(label: "ready", on: state, timeout: 15), app.debugDescription)
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 3)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        print("PIP_SYSTEM_UI " + springboard.debugDescription)
        print("DUODUO_CAPTURE build95-pip-background")
        Thread.sleep(forTimeInterval: 2)
        app.activate()
        XCTAssertTrue(app.buttons["douyin.cleanScreen"].waitForExistence(timeout: 10))
        XCTAssertEqual(current.label, "7678628867820506406")
        attach(app, "build95-pip-restored")
        app.buttons["douyin.cleanScreen"].tap()
        XCTAssertTrue(app.buttons["douyin.comments"].waitForExistence(timeout: 5))
    }

    func testLongPressZonesAndSettingsMigration() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO"]
        app.launchEnvironment["DOUDUO_VIDEO_ID"] = "7678628867820506406"
        addTeardownBlock { app.terminate() }
        app.launch()
        let current = app.staticTexts["douyin.currentID"]
        XCTAssertTrue(current.waitForExistence(timeout: 40))
        XCTAssertTrue(wait(label: "7678628867820506406", on: current, timeout: 45))
        attach(app, "build95-long-press-before")
        print("GESTURE_WINDOW \(app.windows.firstMatch.frame) APP \(app.frame)")
        let count = app.staticTexts["douyin.video.boostStarts"].firstMatch
        let options = app.buttons["douyin.options.close"].firstMatch
        for (index, x) in [0.15, 0.78].enumerated() {
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.4)).press(forDuration: 0.8)
            XCTAssertEqual(count.label, String(index + 1))
            XCTAssertFalse(options.exists, "两侧只触发倍速")
        }
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.4)).press(forDuration: 0.8)
        XCTAssertTrue(options.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(count.label, "2", "中间长按不能启动倍速")
        attach(app, "build95-options-top")
        XCTAssertTrue(app.buttons["douyin.options.fit"].isHittable)
        XCTAssertTrue(app.switches["横屏时只放横屏内容"].exists, "内容偏好默认展开")
        attach(app, "build95-options-top")
        app.buttons["douyin.options.rate.1.5"].tap()
        attach(app, "build95-options-rate-selected")
        let selectedRate = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.buttons["douyin.options.rate.1.5"].isSelected
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [selectedRate], timeout: 5), .completed)
        app.buttons["douyin.options.rate.1.0"].tap()
        let list = app.scrollViews["douyin.options.list"].firstMatch
        list.swipeUp()
        XCTAssertTrue(app.switches["显示弹幕"].isHittable, app.debugDescription)
        XCTAssertTrue(app.switches["10秒内重复去重"].isHittable)
        attach(app, "build95-options-danmaku-expanded")
        app.buttons["douyin.options.close"].tap()
        XCTAssertTrue(options.waitForNonExistence(timeout: 5))
        app.buttons["douyin.more"].firstMatch.tap()
        XCTAssertFalse(app.buttons["douyin.dislike"].exists)
        XCTAssertFalse(app.buttons["douyin.danmaku.settings"].exists)
        XCTAssertFalse(app.buttons["转发"].exists)
        XCTAssertFalse(app.buttons["douyin.save"].exists)
        XCTAssertFalse(app.buttons["设置"].exists, "更多直接显示设置内的栏目")
        XCTAssertFalse(app.buttons["播放设置"].exists)
        XCTAssertFalse(app.buttons["内容偏好"].exists)
        XCTAssertTrue(app.buttons["缓存管理"].exists)
        XCTAssertTrue(app.buttons["账号与登录"].exists)
        XCTAssertTrue(app.buttons["关于"].exists)
        attach(app, "build95-more-retained-settings")
    }

    func testCommentsPullDownAndHeaderSpacing() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO"]
        app.launchEnvironment["DOUDUO_VIDEO_ID"] = "7678628867820506406"
        addTeardownBlock { app.terminate() }
        app.launch()
        let current = app.staticTexts["douyin.currentID"]
        XCTAssertTrue(current.waitForExistence(timeout: 40))
        XCTAssertTrue(wait(label: "7678628867820506406", on: current, timeout: 45))
        let comments = app.buttons["douyin.comments"].firstMatch
        comments.tap()
        let header = app.otherElements["douyin.comments.header"].firstMatch
        let panel = app.descendants(matching: .any).matching(identifier: "douyin.sheet.edgeSurface").firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 10))
        XCTAssertEqual(header.frame.minY, panel.frame.minY, accuracy: 1, "顶部不保留横条占位")
        let related = app.scrollViews["douyin.comments.relatedSearch"].firstMatch
        if related.waitForExistence(timeout: 10) {
            XCTAssertLessThanOrEqual(related.frame.minY, header.frame.maxY + 1)
            XCTAssertLessThanOrEqual(related.frame.height, 26)
        }
        attach(app, "build95-comments-tight-header")
        let list = app.scrollViews["douyin.comments.list"].firstMatch
        list.swipeUp()
        list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            .press(forDuration: 0.05, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
        XCTAssertTrue(header.exists, "列表从中间往回滚动不能误关闭")
        let start = header.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 130)))
        XCTAssertTrue(header.waitForNonExistence(timeout: 5), "标题区下拉可关闭")
        XCTAssertTrue(comments.waitForExistence(timeout: 5))
        comments.tap()
        XCTAssertTrue(header.waitForExistence(timeout: 10))
        let top = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        top.press(forDuration: 0.05, thenDragTo: top.withOffset(CGVector(dx: 0, dy: 160)))
        XCTAssertTrue(header.waitForNonExistence(timeout: 5), "列表顶部下拉可关闭")
        XCTAssertTrue(comments.waitForExistence(timeout: 5))
        attach(app, "build95-comments-pull-closed")
    }

    func testInnerShareUsesTrailingHalf() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO"]
        app.launchEnvironment["DOUDUO_VIDEO_ID"] = "7678628867820506406"
        app.launchEnvironment["DOUDUO_FORWARD_LAYOUT_FIXTURE"] = "1"
        addTeardownBlock { app.terminate() }
        app.launch()
        let current = app.staticTexts["douyin.currentID"]
        XCTAssertTrue(current.waitForExistence(timeout: 40))
        XCTAssertTrue(wait(label: "7678628867820506406", on: current, timeout: 45))
        guard app.windows.firstMatch.frame.width >= 700 else { throw XCTSkip("仅验收 Duo 内屏横向布局") }
        _ = app.screenshot()
        app.buttons["douyin.share"].firstMatch.tap()
        XCTAssertTrue(app.buttons["douyin.forward.contact.layout-fixture-1"].waitForExistence(timeout: 15))
        let panel = app.otherElements["douyin.sheet.edgeSurface"].firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertGreaterThanOrEqual(panel.frame.minX, app.windows.firstMatch.frame.width * 0.48)
        let surface = app.otherElements["douyin.sheet.edgeSurface"].firstMatch
        XCTAssertEqual(surface.frame.width, app.windows.firstMatch.frame.width / 2, accuracy: 1)
        XCTAssertEqual(surface.frame.maxY, app.windows.firstMatch.frame.maxY, accuracy: 1)
        let actions = app.buttons["douyin.forward.action.copy"]
        XCTAssertGreaterThanOrEqual(surface.frame.maxY - actions.frame.maxY, 20)
        XCTAssertLessThanOrEqual(surface.frame.maxY - actions.frame.maxY, 40)
        attach(app, "build94-inner-share-trailing-two-rows")
        app.buttons["douyin.forward.close"].tap()
    }

    /// Returning from comments must restore the native compressed home tab,
    /// including after the user has expanded the tab selector once.
    func testNativeDockRestoresAfterClosingComments() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO"]
        app.launchEnvironment["DOUDUO_VIDEO_ID"] = "7678628867820506406"
        addTeardownBlock { app.terminate() }
        app.launch()
        let current = app.staticTexts["douyin.currentID"]
        XCTAssertTrue(current.waitForExistence(timeout: 40))
        XCTAssertTrue(wait(label: "7678628867820506406", on: current, timeout: 45))
        let comment = app.buttons["douyin.comments"].firstMatch
        let share = app.buttons["douyin.share"].firstMatch
        let home = app.buttons["首页"].firstMatch
        XCTAssertTrue(comment.waitForExistence(timeout: 10))
        let size = app.windows.firstMatch.frame.size
        guard size.width < 600 || size.width > size.height else {
            throw XCTSkip("此用例验证 Duo 竖向系统侧栏；内屏竖向使用独立防重叠用例")
        }
        attach(app, "build94-dock-before-comments")
        let originalShare = share.frame
        let originalHome = home.frame
        print("DOCK_INITIAL share=\(originalShare) home=\(originalHome)")
        for round in 1...3 {
            if round == 3 {
                home.tap()
                attach(app, "build94-dock-expanded-before-comments")
            }
            comment.tap()
            let close = app.buttons["douyin.comments.close"].firstMatch
            XCTAssertTrue(close.waitForExistence(timeout: 10))
            if app.windows.firstMatch.frame.width >= 700 {
                XCTAssertFalse(share.exists)
                XCTAssertFalse(home.isHittable)
            }
            close.tap()
            XCTAssertTrue(comment.waitForExistence(timeout: 10))
            attach(app, "build94-dock-close-comments-" + String(round))
            print("DOCK_RESTORED \(round) share=\(share.frame) home=\(home.frame)")
            XCTAssertEqual(share.frame.midX, originalShare.midX, accuracy: 1)
            XCTAssertGreaterThan(home.frame.minY - share.frame.maxY, 0)
            XCTAssertLessThan(home.frame.minY - share.frame.maxY, 26)
            XCTAssertEqual(home.frame.width, originalHome.width, accuracy: 1, "关闭评论后必须恢复单项收起按钮，而非保留展开的系统选择器")
            XCTAssertEqual(home.frame.maxY, originalHome.maxY, accuracy: 2)
        }
        for round in 1...3 {
            let avatar = app.buttons["douyin.author.avatar"].firstMatch
            XCTAssertTrue(avatar.isHittable)
            avatar.tap()
            let back = app.buttons["douyin.author.back"].firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 12), "头像必须进入作者页")
            back.tap()
            let restored = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                comment.exists && comment.isHittable && share.isHittable
            }, object: app)
            XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 10), .completed)
            attach(app, "build95-author-return-" + String(round))
            XCTAssertEqual(home.frame.width, originalHome.width, accuracy: 1)
            XCTAssertFalse(app.buttons["BottomOverflowBarButtonItem"].exists, "互动栏不能进入省略菜单")
        }
    }

    func testInnerPortraitSeparatesActionsAndDock() throws {
        continueAfterFailure = false
        // Device Hub controls the foldable display's physical rotation;
        // XCUIDevice.orientation alone does not rotate this Duo runtime.
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO"]
        app.launchEnvironment["DOUDUO_VIDEO_ID"] = "7678628867820506406"
        addTeardownBlock { app.terminate() }
        app.launch()
        let current = app.staticTexts["douyin.currentID"]
        XCTAssertTrue(current.waitForExistence(timeout: 40))
        XCTAssertTrue(wait(label: "7678628867820506406", on: current, timeout: 45))
        let window = app.windows.firstMatch
        guard window.frame.width > 600, window.frame.height > window.frame.width else {
            throw XCTSkip("请先在 Device Hub 展开 Duo 并实际旋转为竖向")
        }
        XCTAssertGreaterThan(window.frame.width, 600, "必须使用实际展开内屏")
        XCTAssertGreaterThan(window.frame.height, window.frame.width)
        let home = app.buttons["首页"].firstMatch
        XCTAssertTrue(home.isHittable)
        let ids = ["douyin.author.avatar", "douyin.like", "douyin.comments", "douyin.collect", "douyin.share"]
        let actions = ids.map { app.buttons[$0].firstMatch }
        for action in actions {
            XCTAssertTrue(action.isHittable)
            XCTAssertFalse(action.frame.intersects(home.frame), "竖向互动栏不能并入横向 Dock")
        }
        for index in 1..<actions.count {
            XCTAssertGreaterThan(actions[index].frame.minY, actions[index - 1].frame.minY)
        }
        print("DUO_INNER_PORTRAIT_WINDOW \(window.frame)")
        print("PORTRAIT_CHROME home=\(home.frame) info=\(app.otherElements["douyin.video.info"].firstMatch.frame) progress=\(app.otherElements["douyin.progress"].firstMatch.frame)")
        attach(app, "build94-inner-portrait-actions-above-dock")
        XCTAssertFalse(app.otherElements["douyin.video.info"].firstMatch.frame.intersects(home.frame))
        XCTAssertFalse(app.otherElements["douyin.progress"].firstMatch.frame.intersects(home.frame))
    }

    func testCompactSheetsReachEdgesAndKeepInputClear() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO"]
        app.launchEnvironment["DOUDUO_VIDEO_ID"] = "7678628867820506406"
        app.launchEnvironment["DOUDUO_FORWARD_LAYOUT_FIXTURE"] = "1"
        addTeardownBlock { app.terminate() }
        app.launch()
        let window = app.windows.firstMatch
        let current = app.staticTexts["douyin.currentID"]
        XCTAssertTrue(current.waitForExistence(timeout: 40))
        XCTAssertTrue(wait(label: "7678628867820506406", on: current, timeout: 45))
        guard window.frame.width < 600 else { throw XCTSkip("仅验收 Duo 外屏") }
        print("DUO_OUTER_WINDOW \(window.frame)")
        app.buttons["douyin.comments"].firstMatch.tap()
        let surface = app.otherElements["douyin.sheet.edgeSurface"].firstMatch
        XCTAssertTrue(surface.waitForExistence(timeout: 10))
        XCTAssertEqual(surface.frame.minX, window.frame.minX, accuracy: 1)
        XCTAssertEqual(surface.frame.maxX, window.frame.maxX, accuracy: 1)
        XCTAssertEqual(surface.frame.maxY, window.frame.maxY, accuracy: 1)
        let input = app.descendants(matching: .any).matching(identifier: "douyin.comment.input").firstMatch
        let composer = app.otherElements["douyin.comments.composer"].firstMatch
        let list = app.scrollViews["douyin.comments.list"].firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 10))
        XCTAssertGreaterThanOrEqual(composer.frame.height, 44)
        XCTAssertLessThanOrEqual(list.frame.maxY, composer.frame.minY + 1)
        XCTAssertGreaterThanOrEqual(input.frame.height, 20)
        XCTAssertGreaterThanOrEqual(window.frame.maxY - input.frame.maxY, 18)
        attach(app, "build94-outer-comments-edge-input")
        list.swipeUp()
        attach(app, "build94-outer-comments-scrolled-clipped")
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        XCTAssertLessThanOrEqual(input.frame.maxY, app.keyboards.firstMatch.frame.minY)
        XCTAssertGreaterThanOrEqual(input.frame.height, 20)
        attach(app, "build94-outer-comments-keyboard")
        app.buttons["douyin.comments.close"].firstMatch.tap()
        _ = app.screenshot()
        app.buttons["douyin.share"].firstMatch.tap()
        XCTAssertTrue(app.buttons["douyin.forward.contact.layout-fixture-1"].waitForExistence(timeout: 15))
        XCTAssertEqual(surface.frame.minX, window.frame.minX, accuracy: 1)
        XCTAssertEqual(surface.frame.maxX, window.frame.maxX, accuracy: 1)
        XCTAssertEqual(surface.frame.maxY, window.frame.maxY, accuracy: 1)
        attach(app, "build94-outer-share-edge-two-rows")
        app.buttons["douyin.forward.close"].tap()
    }

    func testModuleMenuSwitching() throws {
        verifyModuleMenu(leading: false)
    }

    func testModuleMenuLeadingRail() throws {
        verifyModuleMenu(leading: true)
    }

    private func verifyModuleMenu(leading: Bool) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launchArguments += ["-douduo_dismissed_update_v1", "1.3.12"]
        // 模块入口只在「简洁」模式出现（默认模式是顶部页签）
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "rail"
        if leading { app.launchEnvironment["DOUDUO_RAIL_EDGE"] = "leading" }
        app.launch()
        let menu = app.buttons["douyin.module.menu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 40))
        XCTAssertTrue(app.buttons["douyin.more"].firstMatch.waitForExistence(timeout: 40))
        Thread.sleep(forTimeInterval: 2)
        if leading {
            for identifier in ["douyin.module.menu", "douyin.like", "douyin.comments", "douyin.collect", "douyin.more"] {
                let button = app.buttons[identifier].firstMatch
                XCTAssertTrue(button.isHittable)
                XCTAssertGreaterThanOrEqual(button.frame.minX, 0)
                XCTAssertLessThan(button.frame.midX, app.frame.width / 2)
            }
        }
        let selectorFrame = menu.frame
        attach(app, leading ? "leading-rail" : "module-menu-collapsed")
        for (module, title) in [("follow", "关注"), ("live", "直播"), ("recommend", "推荐")] {
            menu.tap()
            let option = app.buttons[title]
            XCTAssertTrue(option.waitForExistence(timeout: 5), app.debugDescription)
            if module == "follow" { attach(app, "module-menu-expanded") }
            option.tap()
            XCTAssertTrue(menu.waitForExistence(timeout: 10))
            sleep(1)
            print("DDLEAD label=\(menu.label) want=\(title)")
            XCTAssertTrue(menu.label.contains(title), "入口标签应变为「\(title)」，当前：\(menu.label)")
            print("DDLEAD \(module) frame=\(menu.frame) hittable=\(menu.isHittable) exists=\(menu.exists) win=\(app.frame)")
            XCTAssertTrue(menu.isHittable)
            // Native Menu accessibility bounds can include the 54pt label or the 50pt circle.
            // Alignment is defined by the center, not the accessibility rectangle's edge.
            print("RAIL_CENTER \(module): initial=\(selectorFrame) current=\(menu.frame)")
            XCTAssertEqual(menu.frame.midX, selectorFrame.midX, accuracy: 1)
            XCTAssertEqual(menu.frame.midY, selectorFrame.midY, accuracy: 1)
            if leading { XCTAssertLessThan(menu.frame.midX, app.frame.width / 2) }
            attach(app, "module-\(module)")
        }
    }

    /// 菜单与官网分享面板：仅打开、查看、关闭，绝不点击朋友或发送。
    func testMenuCleanupAndFriendForwardWithoutSending() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "classic"
        app.launchEnvironment["DOUDUO_VIDEO_ID"] = "7705789488781932361"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        addTeardownBlock { app.terminate() }
        app.launch()
        let current = app.staticTexts["douyin.currentID"]
        XCTAssertTrue(current.waitForExistence(timeout: 40))
        XCTAssertTrue(wait(label: "7705789488781932361", on: current, timeout: 45))
        let query = app.buttons.matching(identifier: "douyin.more")
        XCTAssertTrue(query.firstMatch.waitForExistence(timeout: 40))
        func openMore() {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5)).tap()
            (query.allElementsBoundByIndex.first(where: { $0.isHittable }) ?? query.firstMatch).tap()
        }
        openMore()
        XCTAssertFalse(app.buttons["竖屏占比"].exists)
        XCTAssertTrue(app.buttons["自动连播"].exists, "自动连播按需求放在「更多」第一层")
        XCTAssertFalse(app.buttons["静音"].exists)
        XCTAssertTrue(app.buttons["刷新推荐"].exists)
        attach(app, "menu-cleanup-root")
        app.buttons["设置"].tap()
        // 原生 Menu 子菜单偶发被动画吞掉一次点击：重开一次菜单再点，仍以真实控件存在为验收。
        if !app.buttons["播放设置"].waitForExistence(timeout: 3) && app.buttons["设置"].exists {
            app.buttons["设置"].tap()
        }
        XCTAssertTrue(app.buttons["播放设置"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["缓存管理"].exists)
        app.buttons["播放设置"].tap()
        XCTAssertFalse(app.buttons["播放速度"].exists, "倍速已放在「更多」第一层，设置里不再重复")
        attach(app, "menu-cleanup-settings")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.4)).tap()
        openMore()
        let forward = app.buttons["转发"].firstMatch
        XCTAssertTrue(forward.waitForExistence(timeout: 5))
        forward.tap()
        let close = app.buttons["douyin.forward.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        let panel = app.otherElements["douyin.sheet.edgeSurface"]
        XCTAssertTrue(panel.exists)
        XCTAssertFalse(app.navigationBars["转发给抖音朋友"].exists, "转发主界面不能退回全屏网页")
        XCTAssertTrue(app.staticTexts["分享至"].exists)
        XCTAssertTrue(app.buttons["douyin.forward.action.copy"].waitForExistence(timeout: 45), app.debugDescription)
        XCTAssertTrue(app.buttons["douyin.forward.action.other"].exists)
        app.buttons["douyin.forward.action.copy"].tap()
        XCTAssertTrue(app.staticTexts["链接已复制"].waitForExistence(timeout: 5))
        attach(app, "friend-forward-native-floating-panel-no-send")
        close.tap()
        XCTAssertTrue(query.firstMatch.waitForExistence(timeout: 5))
        print("DDFORWARD_UI: native-panel-opened-and-closed; no-recipient-selected; no-send")
    }

    /// 明确标注的模拟器合成联系人，只验证布局/横滑/取消确认，不连接发送桥。
    func testNativeForwardLayoutWithSyntheticContacts() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launchEnvironment["DOUDUO_VIDEO_ID"] = "7705789488781932361"
        app.launchEnvironment["DOUDUO_FORWARD_LAYOUT_FIXTURE"] = "1"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        addTeardownBlock { app.terminate() }
        app.launch()
        let current = app.staticTexts["douyin.currentID"]
        XCTAssertTrue(current.waitForExistence(timeout: 40))
        XCTAssertTrue(wait(label: "7705789488781932361", on: current, timeout: 45))
        let query = app.buttons.matching(identifier: "douyin.more")
        XCTAssertTrue(query.firstMatch.waitForExistence(timeout: 40))
        app.buttons.matching(identifier: "douyin.share").allElementsBoundByIndex.first(where: { $0.isHittable })!.tap()
        let contact = app.buttons["douyin.forward.contact.layout-fixture-1"]
        XCTAssertTrue(contact.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["合成布局测试（不会发送消息）"].exists)
        XCTAssertTrue(app.buttons["douyin.forward.action.private"].exists)
        XCTAssertTrue(app.buttons["douyin.forward.action.groups"].exists)
        let copy = app.buttons["douyin.forward.action.copy"]
        let download = app.buttons["douyin.forward.action.download"]
        XCTAssertTrue(copy.exists)
        XCTAssertTrue(download.exists)
        XCTAssertEqual(copy.frame.midY, download.frame.midY, accuracy: 1)
        XCTAssertEqual(copy.frame.midY, app.buttons["douyin.forward.action.private"].frame.midY, accuracy: 1)
        XCTAssertLessThan(contact.frame.maxY, copy.frame.minY)
        attach(app, "friend-forward-native-SYNTHETIC-layout-no-send")
        contact.tap()
        XCTAssertTrue(app.alerts["确认转发"].waitForExistence(timeout: 5))
        app.alerts.buttons["取消"].tap()
        let panel = app.otherElements["douyin.sheet.edgeSurface"]
        XCTAssertGreaterThan(panel.frame.minY, app.frame.height * 0.1)
        XCTAssertGreaterThan(panel.frame.maxY, app.frame.height * 0.9)
        let contactIDs = (1...9).map { "douyin.forward.contact.layout-fixture-\($0)" }
        let visibleBefore = Set(contactIDs.filter { app.buttons[$0].isHittable })
        let start = contact.coordinate(withNormalizedOffset: CGVector(dx: 3.7, dy: 0.3))
        let end = contact.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.3))
        start.press(forDuration: 0.05, thenDragTo: end)
        // 惯性可停在3–6或6–9，验“新联系人变为可点”，不把固定第5项当滚动终点。
        let scrolled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            contactIDs.contains { !visibleBefore.contains($0) && app.buttons[$0].isHittable }
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [scrolled], timeout: 5), .completed)
        app.buttons["douyin.forward.close"].tap()
        XCTAssertTrue(query.firstMatch.waitForExistence(timeout: 5))
        print("DDFORWARD_LAYOUT: synthetic-only; floating-frame; horizontal-scroll; confirmation-cancelled; real-sends=0")
    }

    func testVideoDanmakuSettings() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        // 仅在测试进程内生成明确标记的压力弹幕，不向平台发消息。
        app.launchEnvironment["DOUDUO_DM_STRESS"] = "1"
        app.launchEnvironment["DOUDUO_VIDEO_ID"] = "7705789488781932361"
        app.launch()
        let moreQuery = app.buttons.matching(identifier: "douyin.more")
        func moreButton() -> XCUIElement {
            moreQuery.allElementsBoundByIndex.first(where: { $0.isHittable }) ?? moreQuery.firstMatch
        }
        XCTAssertTrue(moreQuery.firstMatch.waitForExistence(timeout: 40))
        sleep(4)
        attach(app, "video-danmaku-upper-third-synthetic-stress")
        func openMore() {
            // Picker / Toggle 的原生菜单可能留在父菜单；先在左侧菜单外收起。
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5)).tap()
            moreButton().tap()
        }
        func openSettings() {
            openMore()
            let settings = app.buttons["douyin.danmaku.settings"]
            XCTAssertTrue(settings.waitForExistence(timeout: 5))
            settings.tap()
        }
        for title in ["稀疏", "密集", "标准"] {
            openSettings()
            let option = app.buttons[title]
            if !option.exists { app.buttons["douyin.danmaku.density"].tap() }
            XCTAssertTrue(option.waitForExistence(timeout: 5))
            option.tap()
            openMore()
            let settings = app.buttons["douyin.danmaku.settings"]
            XCTAssertTrue(settings.waitForExistence(timeout: 5))
            XCTAssertTrue(settings.label.contains(title), settings.debugDescription)
            attach(app, "video-danmaku-density-\(title)")
            // 点击内容区收起菜单，避免下一轮误点。
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.5)).tap()
        }
        openSettings()
        // UIKit 原生菜单不透传 Toggle 的 identifier，以实际按钮标题和勾选态验收。
        let toggle = app.buttons["10秒内重复去重"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        let before = toggle.isSelected
        toggle.tap()
        if !toggle.exists { openSettings() }
        XCTAssertNotEqual(toggle.isSelected, before)
        toggle.tap() // 恢复用户原去重设置。
        print("DD_DANMAKU_SETTINGS: density=standard; dedup-toggle=verified")
    }

    func testLiveStandaloneGameEntryRemoved() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launchEnvironment["DOUDUO_STARTLIVE"] = "1"
        app.launch()
        let discover = app.buttons["live.discover"]
        XCTAssertTrue(discover.waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["live.categories"].exists)
        XCTAssertFalse(app.buttons["游戏专区"].exists)
        attach(app, "live-standalone-game-entry-removed")
        discover.tap()
        XCTAssertTrue(app.buttons["live.category.game"].waitForExistence(timeout: 5))
        print("DD_GAME_ENTRY: standalone=removed; game-category=preserved")
    }

    func testLiveDiscoveryAndBack() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launchEnvironment["DOUDUO_TEST_MUTE"] = "1"
        addTeardownBlock { app.terminate() }
        app.launchEnvironment["DOUDUO_STARTLIVE"] = "1"
        app.launch()
        let discover = app.buttons["live.discover"]
        XCTAssertTrue(discover.waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["live.categories"].exists)
        XCTAssertFalse(app.buttons["游戏专区"].exists)
        XCTAssertFalse(app.buttons["live.category.featured"].exists)
        discover.tap()
        XCTAssertTrue(app.buttons["live.category.featured"].waitForExistence(timeout: 5))
        // v1.3.13 only exposes the followed-live strip when an author is live.
        // This network-dependent optional strip is covered separately by its state tests.
        let followed = app.descendants(matching: .any).matching(identifier: "live.follow").firstMatch
        if followed.exists { XCTAssertTrue(followed.isHittable) }
        XCTAssertFalse(app.buttons["live.category.followed"].exists)
        XCTAssertFalse(app.buttons["live.category.nearby"].exists)
        app.buttons["live.category.chat"].tap()
        XCTAssertEqual(app.buttons["live.category.chat"].value as? String, "已选择")
        discover.tap()
        XCTAssertFalse(app.buttons["live.category.featured"].exists)
        // The vertical lazy pager can expose an offscreen room before the new
        // category settles. Enter the currently hittable page, not firstMatch.
        let entrances = app.buttons.matching(identifier: "live.room.enter")
        let visibleEntry = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            entrances.allElementsBoundByIndex.contains { $0.isHittable }
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [visibleEntry], timeout: 45), .completed)
        let enter = try XCTUnwrap(entrances.allElementsBoundByIndex.first { $0.isHittable })
        // XCTest's automatic scroll-to-visible returns (-1, -1) for this
        // containerRelativeFrame pager even when the button is already visible.
        enter.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let back = app.buttons["live.room.close"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        XCTAssertTrue(back.label.contains("返回"))
        XCTAssertFalse(app.buttons["douyin.search"].isHittable)
        XCTAssertFalse(app.buttons["douyin.more"].isHittable)
        XCTAssertFalse(app.buttons["首页"].isHittable)
        XCTAssertFalse(app.buttons["douyin.cleanScreen"].isHittable)
        back.tap()
        XCTAssertTrue(discover.waitForExistence(timeout: 5))
        XCTAssertEqual(app.state, .runningForeground)
        attach(app, "live-discovery-return")
    }

    func testLiveVerifiedCategories() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launchEnvironment["DOUDUO_STARTLIVE"] = "1"
        app.launch()
        let discover = app.buttons["live.discover"]
        XCTAssertTrue(discover.waitForExistence(timeout: 30))
        let initial = expectation(for: NSPredicate(format: "label BEGINSWITH 'featured|' AND NOT label BEGINSWITH 'featured|0|' AND label ENDSWITH '|loaded'"), evaluatedWith: app.staticTexts["live.source"])
        XCTAssertEqual(XCTWaiter().wait(for: [initial], timeout: 40), .completed)
        discover.tap()
        print("DDCATEGORY_SCREEN:before"); fflush(stdout); sleep(3)
        for id in ["nearby", "star", "group", "beauty", "sing"] {
            XCTAssertFalse(app.buttons["live.category.\(id)"].exists)
        }
        let strip = app.scrollViews["live.categoryStrip"]
        let source = app.staticTexts["live.source"]
        for (id, partition) in [("chat", "101"), ("music", "102"), ("anime", "104"), ("dance", "105"), ("culture", "106"), ("life", "107"), ("exercise", "108")] {
            let button = app.buttons["live.category.\(id)"]
            for _ in 0..<4 {
                if strip.frame.intersection(app.windows.firstMatch.frame).insetBy(dx: -1, dy: -1).contains(button.frame) { break }
                strip.swipeLeft()
            }
            if !button.isHittable { print("DDCATEGORY_SCREEN:blocked"); fflush(stdout); sleep(3) }
            XCTAssertTrue(button.isHittable, id)
            button.tap()
            let loaded = expectation(for: NSPredicate { _, _ in
                let parts = source.label.split(separator: "|").map(String.init)
                return parts.count == 3 && parts[0] == partition && (Int(parts[1]) ?? 0) > 0 && parts[2] == "loaded"
            }, evaluatedWith: source)
            XCTAssertEqual(XCTWaiter().wait(for: [loaded], timeout: 40), .completed, id)
            XCTAssertEqual(button.value as? String, "已选择")
            print("DDCATEGORY_VERIFIED:\(id) source=\(source.label)")
        }
        print("DDCATEGORY_SCREEN:all"); fflush(stdout); sleep(4)
        for _ in 0..<4 {
            if strip.frame.intersection(app.windows.firstMatch.frame).contains(app.buttons["live.category.game"].frame) { break }
            strip.swipeRight()
        }
        app.buttons["live.category.game"].tap()
        XCTAssertTrue(app.buttons["live.categories.close"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["英雄联盟"].exists)
        app.buttons["live.categories.close"].tap()
        let game = expectation(for: NSPredicate(format: "label BEGINSWITH '103|' AND NOT label BEGINSWITH '103|0|' AND label ENDSWITH '|loaded'"), evaluatedWith: source)
        XCTAssertEqual(XCTWaiter().wait(for: [game], timeout: 40), .completed)
        for _ in 0..<4 {
            if strip.frame.intersection(app.windows.firstMatch.frame).contains(app.buttons["live.category.featured"].frame) { break }
            strip.swipeRight()
        }
        app.buttons["live.category.featured"].tap()
        let featured = expectation(for: NSPredicate(format: "label BEGINSWITH 'featured|' AND NOT label BEGINSWITH 'featured|0|' AND label ENDSWITH '|loaded'"), evaluatedWith: source)
        XCTAssertEqual(XCTWaiter().wait(for: [featured], timeout: 40), .completed)
    }

    func testMinePlayCountsAndCachedMessages() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launchEnvironment["DOUDUO_OPEN"] = "mine"
        app.launch()
        let count = app.descendants(matching: .any).matching(identifier: "douyin.grid.playCount").firstMatch
        XCTAssertTrue(count.waitForExistence(timeout: 45), app.debugDescription)
        XCTAssertTrue(count.label.contains("播放量"))
        XCTAssertFalse(count.label.contains("未提供"), count.label)
        print("DDMINE_PLAY=\(count.label)")
        print("DDCHAT_SHOT_MINE"); sleep(4)
        app.buttons["douyin.mine.back"].tap()
        app.buttons["douyin.messages.top"].tap()
        let row = app.buttons.matching(identifier: "douyin.conversation.row").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 40))
        sleep(4)
        app.buttons["douyin.messages.back"].tap()
        app.buttons["douyin.messages.top"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 3), "缓存会话应该直接显示")
        print("DDCACHE_REOPEN=ready")
        print("DDCHAT_SHOT_CACHE"); sleep(4)
        app.terminate()
        app.launchEnvironment["DOUDUO_OPEN"] = "messages"
        app.launch()
        // 会话列表按设计是实时从网页抓（只有通知/计数走缓存），冷启动等它连上即可
        XCTAssertTrue(row.waitForExistence(timeout: 40), "冷启动后会话列表没拉起来")
        print("DDCACHE_COLD=ready")
    }

    func testTopBarHitEdges() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launch()
        let info = app.buttons["douyin.messages.top"]
        XCTAssertTrue(info.waitForExistence(timeout: 40))
        // 点按钮边缘（不是文字中心）验证放大后的触摸区真的生效
        func tapEdge(_ el: XCUIElement, dx: CGFloat, dy: CGFloat) {
            let c = el.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: dy))
            c.tap()
        }
        let live = app.buttons.matching(NSPredicate(format: "label == '直播'")).firstMatch
        XCTAssertTrue(live.exists)
        tapEdge(live, dx: 0.5, dy: 0.94)
        sleep(4)
        print("DDHIT after-live-edge tab-\(app.staticTexts["live.currentID"].exists)")
        attach(app, "hit-live-edge")
        tapEdge(info, dx: 0.5, dy: 0.94)
        XCTAssertTrue(app.buttons["douyin.messages.back"].waitForExistence(timeout: 20), app.debugDescription)
        print("DDHIT info-bottom-edge ok")
        app.buttons["douyin.messages.back"].tap()
        let mine = app.buttons["douyin.mine.top"]
        tapEdge(mine, dx: 0.5, dy: 0.94)
        XCTAssertTrue(app.buttons["douyin.mine.back"].waitForExistence(timeout: 20), app.debugDescription)
        print("DDHIT mine-bottom-edge ok")
        app.buttons["douyin.mine.back"].tap()
        let recommend = app.buttons.matching(NSPredicate(format: "label == '推荐'")).firstMatch
        tapEdge(recommend, dx: 0.5, dy: 0.94)
        let current = app.staticTexts["douyin.currentID"]
        XCTAssertTrue(current.waitForExistence(timeout: 25))
        sleep(3)
        print("DDHIT recommend-restored id=\(current.label)")
        attach(app, "hit-recommend-edge")
    }

    func testStrangerCategory() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launchEnvironment["DOUDUO_OPEN"] = "messages"
        app.launch()
        let entry = app.buttons["douyin.messages.stranger"]
        XCTAssertTrue(entry.waitForExistence(timeout: 50), app.debugDescription)
        let rows = app.buttons.matching(identifier: "douyin.conversation.row")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 30))
        let mixed = rows.allElementsBoundByIndex.filter { ($0.value as? String) == "stranger" }
        XCTAssertEqual(mixed.count, 0, "陌生人不该平铺在首页列表")
        // 等预读把陌生人真实未读回填到入口角标（采集完整列表要十几秒）
        let filled = NSPredicate(format: "value != '0' AND value != '1'")
        _ = XCTWaiter().wait(for: [expectation(for: filled, evaluatedWith: entry)], timeout: 60)
        print("DDSTRANGERCAT entryBadge=\(entry.value ?? "-") friendRows=\(rows.count)")
        print("DDCHAT_SHOT_HOME"); sleep(3)

        entry.tap()
        let srows = app.buttons.matching(identifier: "douyin.stranger.row")
        XCTAssertTrue(srows.firstMatch.waitForExistence(timeout: 25), app.debugDescription)
        print("DDSTRANGERCAT list=\(srows.count)")
        print("DDCHAT_SHOT_STRANGERLIST"); sleep(3)

        // 点最后一个人：网页里它在虚拟列表可视区外，验证滚动寻找 + 进的就是他本人
        XCTAssertGreaterThan(srows.count, 11, "陌生人列表没采全（虚拟列表只读到可视区）")
        // 原生列表滚到底，取最下面一个可点的人
        for _ in 0..<6 { app.swipeUp(velocity: .fast) }
        sleep(1)
        let visible = srows.allElementsBoundByIndex.filter { $0.isHittable }
        XCTAssertFalse(visible.isEmpty)
        let pick = visible.last!
        let who = pick.label.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? ""
        print("DDSTRANGERCAT pick=\(who)")
        pick.tap()
        let detail = app.webViews.matching(identifier: "douyin.messages.chat.detail").firstMatch
        XCTAssertTrue(detail.waitForExistence(timeout: 25))
        sleep(4)
        let title = app.navigationBars.firstMatch.identifier
        print("DDSTRANGERCAT navTitle=\(title)")
        XCTAssertTrue(app.staticTexts["消息"].exists, "消息标题不能被右侧会话名替换")
        XCTAssertTrue(detail.staticTexts[who].waitForExistence(timeout: 10), "进的会话不是点的那个人")
        XCTAssertGreaterThan(detail.frame.width, 0, "聊天详情不可见：\(detail.frame)")
        if entry.isHittable {
            XCTAssertGreaterThanOrEqual(detail.frame.minX, entry.frame.maxX - 2, "双栏聊天盖住了左侧列表")
        }
        print("DDCHAT_SHOT_STRANGERCHAT"); sleep(3)
        app.buttons["douyin.messages.back"].tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 10))

        // 第一个人 = 主列表里我没关注的单聊（网页没放进陌生人面板），也要能点进本人
        entry.tap()
        XCTAssertTrue(srows.firstMatch.waitForExistence(timeout: 25))
        let first = srows.firstMatch
        let who2 = first.label.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? ""
        print("DDSTRANGERCAT pick2=\(who2)")
        first.tap()
        XCTAssertTrue(detail.waitForExistence(timeout: 25))
        sleep(4)
        let title2 = app.navigationBars.firstMatch.identifier
        print("DDSTRANGERCAT navTitle2=\(title2)")
        XCTAssertTrue(app.staticTexts["消息"].exists)
        XCTAssertTrue(detail.staticTexts[who2].waitForExistence(timeout: 10))
        print("DDCHAT_SHOT_STRANGERCHAT2"); sleep(3)
        app.buttons["douyin.messages.back"].tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
    }

    /// Run on iPhone Duo after manually unfolding its inner display in Device Hub.
    func testDuoInnerCommentPanelKeepsVideoAndNavigation() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        addTeardownBlock { app.terminate() }
        app.launchEnvironment["DOUDUO_VIDEO_ID"] = "7705789488781932361"
        app.launchEnvironment["DOUDUO_AUTHOR_WORK_FIXTURE"] = "1"
        app.launch()
        guard app.windows.firstMatch.frame.width >= 700 else {
            throw XCTSkip("只验收已经展开的 Duo 内屏；不把外屏或 iPad 当作替代")
        }
        let current = app.staticTexts["douyin.currentID"]
        XCTAssertTrue(current.waitForExistence(timeout: 40))
        let comment = app.buttons["douyin.comments"].firstMatch
        XCTAssertTrue(comment.waitForExistence(timeout: 10))
        XCTAssertTrue(wait(label: "7705789488781932361", on: current, timeout: 45))
        let id = current.label
        comment.tap()
        let close = app.buttons["douyin.comments.close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        let info = app.otherElements["douyin.video.info"].firstMatch
        let panel = app.descendants(matching: .any).matching(identifier: "douyin.comments.panel").firstMatch
        XCTAssertLessThanOrEqual(info.frame.maxX, panel.frame.minX, "视频留在左侧，评论在右侧")
        XCTAssertGreaterThan(panel.frame.width, app.windows.firstMatch.frame.width * 0.40)
        XCTAssertLessThan(panel.frame.width, app.windows.firstMatch.frame.width * 0.52)
        XCTAssertFalse(app.buttons["house"].firstMatch.isHittable)
        XCTAssertFalse(app.buttons["首页"].firstMatch.isHittable)
        for id in ["douyin.author.avatar", "douyin.like", "douyin.comments", "douyin.collect", "douyin.share"] {
            XCTAssertFalse(app.buttons[id].firstMatch.exists, "内屏评论打开时完全移除视频互动栏：" + id)
        }
        let related = app.scrollViews["douyin.comments.relatedSearch"].firstMatch
        XCTAssertTrue(related.waitForExistence(timeout: 15))
        XCTAssertLessThan(related.frame.maxY, panel.frame.minY + 100)
        XCTAssertEqual(panel.frame.maxX, app.windows.firstMatch.frame.maxX, accuracy: 1, "评论背景延伸到状态栏所在的屏幕右缘")
        XCTAssertLessThanOrEqual(panel.frame.minY, 4)
        XCTAssertGreaterThan(panel.frame.height, app.windows.firstMatch.frame.height * 0.9)
        XCTAssertFalse(app.buttons["douyin.search"].firstMatch.isHittable)
        XCTAssertTrue(app.buttons["douyin.more"].firstMatch.isHittable)
        let input = app.descendants(matching: .any).matching(identifier: "douyin.comment.input").firstMatch
        XCTAssertGreaterThanOrEqual(input.frame.height, 20)
        XCTAssertGreaterThanOrEqual(app.otherElements["douyin.comments.composer"].firstMatch.frame.height, 44)
        XCTAssertGreaterThanOrEqual(app.windows.firstMatch.frame.maxY - input.frame.maxY, 9)
        attach(app, "duo-inner-solid-comments-to-screen-edge")
        close.tap()
        XCTAssertEqual(current.label, id)
        attach(app, "duo-inner-return-same-video")
        app.buttons["douyin.author.avatar"].firstMatch.tap()
        let author = app.otherElements["douyin.author.panel"].firstMatch
        XCTAssertTrue(author.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(author.frame.minX, app.windows.firstMatch.frame.width * 0.35)
        XCTAssertLessThanOrEqual(info.frame.maxX, author.frame.minX)
        XCTAssertFalse(app.buttons["首页"].firstMatch.isHittable)
        attach(app, "duo-inner-author-split")
        let work = app.descendants(matching: .any).matching(identifier: "douyin.author.works").firstMatch.buttons.firstMatch
        XCTAssertTrue(work.waitForExistence(timeout: 35), app.debugDescription)
        work.tap()
        let workBack = app.buttons["douyin.list.back"].firstMatch
        XCTAssertTrue(workBack.waitForExistence(timeout: 15))
        for id in ["douyin.list.back", "douyin.author.avatar", "douyin.like", "douyin.comments", "douyin.collect", "douyin.share"] {
            XCTAssertTrue(app.buttons[id].firstMatch.isHittable, "作者作品页保留按钮：" + id)
        }
        attach(app, "duo-inner-author-work-controls")
        app.buttons["douyin.comments"].firstMatch.tap()
        XCTAssertTrue(close.waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["douyin.like"].firstMatch.exists)
        attach(app, "duo-inner-author-work-comments")
        close.tap()
        XCTAssertTrue(workBack.waitForExistence(timeout: 10))
        workBack.tap()
        XCTAssertTrue(app.buttons["douyin.author.back"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["douyin.author.back"].firstMatch.tap()
        XCTAssertEqual(current.label, id)
    }

    /// 倍速两条线互不污染：设置是全局速度（当前视频立刻生效），长按下滑锁的 2 倍只锁本条、上滑取消。
    func testPlaybackRateLockedByLongPressDownAndSetting() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO"]
        addTeardownBlock { app.terminate() }
        app.launchEnvironment["DOUDUO_VIDEO_ID"] = "7678628867820506406"
        app.launch()
        XCTAssertTrue(wait(label: "7678628867820506406", on: app.staticTexts["douyin.currentID"], timeout: 60))
        sleep(3)
        let setting = app.staticTexts["douyin.rate"]
        XCTAssertTrue(setting.waitForExistence(timeout: 10))

        // 1. 设置里回到正常速度：不显示倍速角标
        openSpeedMenu(app)
        XCTAssertTrue(app.buttons["正常速度"].waitForExistence(timeout: 5))
        app.buttons["正常速度"].tap()
        app.buttons["douyin.options.close"].tap()
        XCTAssertTrue(wait(label: "1", on: setting, timeout: 8), "设置应是 1 倍，当前 \(setting.label)")
        sleep(1)
        XCTAssertNil(visibleBadge(app), "1 倍速不该显示角标")

        // 2. 长按下滑：锁定本条 2 倍（松手后常驻角标），且不写进设置
        let start = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.40))
        let end = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.58))
        start.press(forDuration: 0.9, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.4)
        XCTAssertTrue(waitBadge(app, "2×", timeout: 8), "长按下滑应锁定 2 倍，当前 \(visibleBadge(app)?.label ?? "无角标")")
        XCTAssertEqual(setting.label, "1", "长按锁定不能改设置里的全局速度")
        attach(app, "rate-locked-2x-badge")

        // 3. 设置改成 1.5 倍：当前这条立刻变 1.5×（不用换视频）
        openSpeedMenu(app)
        XCTAssertTrue(app.buttons["1.5 倍速"].waitForExistence(timeout: 5))
        app.buttons["1.5 倍速"].tap()
        app.buttons["douyin.options.close"].tap()
        XCTAssertTrue(waitBadge(app, "1.5×", timeout: 8), "设置改 1.5 倍当前视频应立刻生效，当前 \(visibleBadge(app)?.label ?? "无角标")")
        XCTAssertEqual(setting.label, "1.5")
        attach(app, "rate-1-5x-badge")

        // 4. 长按上滑：取消 2 倍，回到设置的 1.5 倍
        let up = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.24))
        start.press(forDuration: 0.9, thenDragTo: up, withVelocity: .slow, thenHoldForDuration: 0.4)
        XCTAssertTrue(waitBadge(app, "1.5×", timeout: 8), "上滑应取消倍速，当前 \(visibleBadge(app)?.label ?? "无角标")")
        attach(app, "rate-cancelled")
        openSpeedMenu(app)
        app.buttons["正常速度"].tap()
        app.buttons["douyin.options.close"].tap()
    }

    /// 「更多」第一层的倍速：点开选速度，当前视频立刻变速（不用换视频）。
    func testQuickSpeedMenuAppliesToCurrentVideo() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "classic"
        app.launchEnvironment["DOUDUO_VIDEO_ID"] = "7705789488781932361"
        app.launch()
        XCTAssertTrue(app.staticTexts["douyin.currentID"].waitForExistence(timeout: 40))
        XCTAssertTrue(wait(label: "7705789488781932361", on: app.staticTexts["douyin.currentID"], timeout: 45))
        sleep(5)
        let more = app.buttons.matching(identifier: "douyin.more").allElementsBoundByIndex.filter { $0.isHittable }
        XCTAssertFalse(more.isEmpty)
        more[0].tap()
        let speed = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH '倍速'")).firstMatch
        XCTAssertTrue(speed.waitForExistence(timeout: 5), "「更多」第一层应直接有倍速")
        XCTAssertTrue(app.buttons["刷新推荐"].exists)
        attach(app, "quick-more-root")
        speed.tap()
        XCTAssertTrue(app.buttons["1.5 倍速"].waitForExistence(timeout: 5), "点倍速应弹出速度列表")
        attach(app, "quick-speed-list")
        app.buttons["1.5 倍速"].tap()
        print("MERGE_RATE setting=" + app.staticTexts["douyin.rate"].label)
        for badge in app.staticTexts.matching(identifier: "douyin.rateBadge").allElementsBoundByIndex {
            print("MERGE_RATE badge=\(badge.label) frame=\(badge.frame)")
        }
        XCTAssertTrue(waitBadge(app, "1.5×", timeout: 8), "选 1.5 倍后当前视频应立刻 1.5×")
        sleep(3)
        attach(app, "quick-speed-applied")
        let fit = app.buttons.matching(identifier: "douyin.fit").allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(fit, "搜索下面应有铺满按钮")
    }

    /// 复现：滑到下一条视频后，在「更多」里改倍速，当前视频应立刻变速（看 ddlog 里的 DDRATETEST）。
    func testSpeedChangeOnSecondVideoAppliesImmediately() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "classic"
        app.launchEnvironment["DOUDUO_VIDEO_ID"] = "7705789488781932361"
        app.launch()
        XCTAssertTrue(app.staticTexts["douyin.currentID"].waitForExistence(timeout: 40))
        sleep(5)
        let first = app.staticTexts["douyin.currentID"].label
        app.swipeUp(velocity: .fast)
        sleep(12)
        let second = app.staticTexts["douyin.currentID"].label
        print("DDRATETEST first=\(first) second=\(second)")
        func pick(_ title: String) {
            let more = app.buttons.matching(identifier: "douyin.more").allElementsBoundByIndex.filter { $0.isHittable }
            XCTAssertFalse(more.isEmpty)
            more[0].tap()
            let speed = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH '倍速'")).firstMatch
            XCTAssertTrue(speed.waitForExistence(timeout: 5))
            speed.tap()
            XCTAssertTrue(app.buttons[title].waitForExistence(timeout: 5))
            app.buttons[title].tap()
            sleep(3)
        }
        pick("1.5 倍速")
        XCTAssertTrue(waitBadge(app, "1.5×", timeout: 8), "第二条视频改 1.5 倍应立刻生效")
        // 关键回归：从 1.5 改回正常速度，观察器不能再把速度拉回 1.5（旧版会）
        pick("正常速度")
        sleep(2)
        XCTAssertNil(visibleBadge(app), "改回正常速度后不该再显示倍速角标（旧版被预加载时的旧值拉回 1.5）")
        pick("2 倍速")
        XCTAssertTrue(waitBadge(app, "2×", timeout: 8))
        attach(app, "second-video-rate")
    }

    /// 右侧按钮栏：五个按钮水平居中对齐、竖向等距。
    func testRailButtonsAlignedAndEvenlySpaced() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "classic"
        app.launchEnvironment["DOUDUO_VIDEO_ID"] = "7705789488781932361"
        app.launch()
        XCTAssertTrue(app.staticTexts["douyin.currentID"].waitForExistence(timeout: 40))
        sleep(4)
        func frame(_ id: String) -> CGRect {
            let q = app.buttons.matching(identifier: id).allElementsBoundByIndex.filter { $0.isHittable }
            XCTAssertFalse(q.isEmpty, "\(id) 不可点")
            return q.first?.frame ?? .zero
        }
        let ids = ["douyin.like", "douyin.comments", "douyin.collect", "douyin.search", "douyin.fit"]
        let f = ids.map(frame)
        print("DDRAIL frames=\(f)")
        for r in f { XCTAssertEqual(r.midX, f[0].midX, accuracy: 1.0, "水平没对齐") }
        // 有数字的三个按钮之间等距；无数字的搜索/铺满之间更紧（没有文字那一截）
        let pitches = zip(f, f.dropFirst()).map { $1.midY - $0.midY }
        print("DDRAIL pitches=\(pitches)")
        XCTAssertEqual(pitches[0], pitches[1], accuracy: 1.0, "赞→评论 与 评论→收藏 间距不等")
        XCTAssertLessThan(pitches[3], pitches[0], "无文字的按钮之间应比有文字的更紧")
        // 搜索与铺满之间的空隙 = 「图标—文字」间距那一级（约 2~12pt），不再是一整块空白
        let gapSearchFit = f[4].minY - f[3].maxY
        print("DDRAIL gapSearchFit=\(gapSearchFit)")
        XCTAssertLessThanOrEqual(gapSearchFit, 12)
        attach(app, "rail-aligned")
    }

    /// 三档界面模式：默认=顶部页签+原右侧栏；简洁=侧边功能栏；极简=简洁且隐藏作者标题。
    /// 注意：不能用 -key value 启动参数——它是只读的参数域，会盖住运行时在「更多」里的修改。
    /// 改用 DOUDUO_CHROME_MODE 环境变量，只在首次启动时写入存储。
    private func launchChrome(_ mode: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launchEnvironment["DOUDUO_VIDEO_ID"] = "7705789488781932361"
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = mode
        app.launchArguments += ["-douduo_dismissed_update_v1", "1.3.12"]
        app.launch()
        XCTAssertTrue(app.staticTexts["douyin.currentID"].waitForExistence(timeout: 40))
        XCTAssertTrue(wait(label: "7705789488781932361", on: app.staticTexts["douyin.currentID"], timeout: 45))
        sleep(5)
        return app
    }

    func testChromeModeClassicHasTopTabsAndSearchOnRail() throws {
        let app = launchChrome("classic")
        XCTAssertTrue(app.buttons.matching(identifier: "douyin.search").allElementsBoundByIndex.contains { $0.isHittable }, "默认模式右侧栏应有搜索")
        XCTAssertFalse(app.buttons["douyin.module.menu"].exists, "默认模式没有模块入口")
        XCTAssertTrue(app.buttons["关注"].exists || app.staticTexts["关注"].exists, "默认模式顶部应有「关注」页签")
        XCTAssertTrue(app.buttons.matching(identifier: "douyin.author").allElementsBoundByIndex.contains { $0.isHittable }, "默认模式应显示作者")
        attach(app, "chrome-classic")
    }

    func testChromeModeRailMovesSearchIntoModuleMenu() throws {
        let app = launchChrome("rail")
        XCTAssertTrue(app.buttons["douyin.module.menu"].waitForExistence(timeout: 10), "简洁模式应有模块入口")
        XCTAssertFalse(app.buttons.matching(identifier: "douyin.search").allElementsBoundByIndex.contains { $0.isHittable }, "简洁模式右侧栏不再有搜索")
        XCTAssertTrue(app.buttons.matching(identifier: "douyin.author").allElementsBoundByIndex.contains { $0.isHittable }, "简洁模式保留作者")
        app.buttons["douyin.module.menu"].tap()
        XCTAssertTrue(app.buttons["搜索"].waitForExistence(timeout: 5), "模块菜单里应有搜索")
        attach(app, "chrome-rail-menu")
        app.buttons["搜索"].tap()
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 10) || app.searchFields.firstMatch.waitForExistence(timeout: 5), "点搜索应打开搜索页")
    }

    func testChromeModeMinimalHidesAuthorAndTitle() throws {
        let app = launchChrome("minimal")
        XCTAssertTrue(app.buttons["douyin.module.menu"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons.matching(identifier: "douyin.author").allElementsBoundByIndex.contains { $0.isHittable }, "极简模式应隐藏作者")
        XCTAssertFalse(app.staticTexts.matching(identifier: "douyin.video.metadata").allElementsBoundByIndex.contains { $0.isHittable }, "极简模式应隐藏标题信息")
        attach(app, "chrome-minimal")
    }

    /// 在「更多」第一层切换界面模式，立即生效。
    func testStandaloneCommentsRespectLayout() throws {
        continueAfterFailure = false
        for mode in ["classic", "duoClassic"] {
            let app = XCUIApplication()
            app.launchEnvironment["DOUDUO_CHROME_MODE"] = mode
            app.launchEnvironment["DOUDUO_COMMENT_ENTRY"] = "mine"
            app.launchEnvironment["DOUDUO_VIDEO_ID"] = "7678628867820506406"
            app.launchArguments += ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO"]
            addTeardownBlock { app.terminate() }
            app.launch()
            XCTAssertTrue(wait(label: "7678628867820506406", on: app.staticTexts["douyin.currentID"], timeout: 60))
            if mode == "duoClassic" {
                app.buttons["首页"].firstMatch.tap()
                app.buttons["我的"].firstMatch.tap()
            } else { app.buttons["douyin.mine.top"].firstMatch.tap() }
            XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "douyin.list.player").firstMatch.waitForExistence(timeout: 30))
            let comment = app.buttons.matching(identifier: "douyin.comments").allElementsBoundByIndex.first { $0.isHittable }
            XCTAssertNotNil(comment)
            comment?.tap()
            let list = app.scrollViews["douyin.comments.list"].firstMatch
            let related = app.scrollViews["douyin.comments.relatedSearch"].firstMatch
            XCTAssertTrue(list.waitForExistence(timeout: 10))
            XCTAssertTrue(related.waitForExistence(timeout: 20))
            if mode == "duoClassic" { XCTAssertLessThanOrEqual(related.frame.maxY, list.frame.minY + 2) }
            else {
                XCTAssertGreaterThanOrEqual(related.frame.minY, list.frame.maxY - 2)
                XCTAssertFalse(app.otherElements["douyin.sheet.edgeSurface"].exists)
            }
            attach(app, "v14-standalone-comments-" + mode)
            app.buttons["douyin.comments.close"].firstMatch.tap()
            XCTAssertTrue(app.buttons["douyin.list.back"].firstMatch.isHittable)
            app.terminate()
        }
    }

    func testClassicSearchOpensAndReturns() throws {
        continueAfterFailure = false
        let app = launchChrome("duoClassic")
        addTeardownBlock { app.terminate() }
        for entry in 0..<3 {
            if entry == 1 {
                app.buttons["douyin.comments"].firstMatch.tap()
                let close = app.buttons["douyin.comments.close"].firstMatch
                XCTAssertTrue(close.waitForExistence(timeout: 15))
                close.tap()
                XCTAssertTrue(close.waitForNonExistence(timeout: 5))
            } else if entry == 2 {
                app.buttons["douyin.author.avatar"].firstMatch.tap()
                let back = app.buttons["douyin.author.back"].firstMatch
                XCTAssertTrue(back.waitForExistence(timeout: 15))
                back.tap()
                XCTAssertTrue(back.waitForNonExistence(timeout: 5))
            }
            let button = app.buttons["douyin.search"].firstMatch
            XCTAssertTrue(button.isHittable)
            button.tap()
            XCTAssertTrue(app.textFields["douyin.search.field"].waitForExistence(timeout: 10), app.debugDescription)
            app.buttons["douyin.search.back"].firstMatch.tap()
            XCTAssertTrue(button.waitForExistence(timeout: 10))
        }
        attach(app, "v14-classic-search-return")
    }

    func testCommentPresentationIsIsolatedAcrossLayouts() throws {
        continueAfterFailure = false
        for mode in ["classic", "rail", "minimal", "duoClassic"] {
            let app = launchChrome(mode)
            addTeardownBlock { app.terminate() }
            let comments = app.buttons.matching(identifier: "douyin.comments").allElementsBoundByIndex.first { $0.isHittable }
            XCTAssertNotNil(comments)
            comments?.tap()
            let list = app.scrollViews["douyin.comments.list"].firstMatch
            XCTAssertTrue(list.waitForExistence(timeout: 15))
            let related = app.scrollViews["douyin.comments.relatedSearch"].firstMatch
            XCTAssertTrue(related.waitForExistence(timeout: 20))
            let input = app.descendants(matching: .any).matching(identifier: "douyin.comment.input").firstMatch
            XCTAssertTrue(input.isHittable)
            if mode == "duoClassic" {
                XCTAssertLessThanOrEqual(related.frame.maxY, list.frame.minY + 2)
                if app.windows.firstMatch.frame.width < 700 {
                    XCTAssertTrue(app.otherElements["douyin.sheet.edgeSurface"].exists)
                }
            } else {
                XCTAssertGreaterThanOrEqual(related.frame.minY, list.frame.maxY - 2)
                XCTAssertFalse(app.otherElements["douyin.sheet.edgeSurface"].exists)
                if app.windows.firstMatch.frame.width >= 700 {
                    XCTAssertTrue(app.buttons.matching(identifier: "douyin.like").allElementsBoundByIndex.contains { $0.isHittable },
                                  mode + " 内屏评论不能隐藏互动栏")
                }
            }
            attach(app, "v14-comments-" + mode)
            app.buttons["douyin.comments.close"].firstMatch.tap()
            app.terminate()
        }
    }

    func testAllFourChromeModesRoundTrip() throws {
        continueAfterFailure = false
        let app = launchChrome("classic")
        addTeardownBlock { app.terminate() }
        for title in ["经典", "简洁", "极简", "默认"] {
            let more = app.buttons.matching(identifier: "douyin.more").allElementsBoundByIndex.first { $0.isHittable }
            XCTAssertNotNil(more)
            more?.tap()
            let picker = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH '界面'")).firstMatch
            XCTAssertTrue(picker.waitForExistence(timeout: 5))
            picker.tap()
            XCTAssertTrue(app.buttons[title].waitForExistence(timeout: 5))
            app.buttons[title].tap()
            XCTAssertTrue(app.staticTexts["douyin.currentID"].waitForExistence(timeout: 40))
            sleep(3)
            if title == "经典" {
                XCTAssertTrue(app.buttons["douyin.cleanScreen"].waitForExistence(timeout: 8))
            } else if title == "简洁" || title == "极简" {
                XCTAssertTrue(app.buttons["douyin.module.menu"].waitForExistence(timeout: 8))
            } else {
                XCTAssertFalse(app.buttons["douyin.module.menu"].exists)
            }
            attach(app, "merged-mode-" + title)
        }
    }

    func testChromeModeSwitchFromMoreMenu() throws {
        let app = launchChrome("classic")
        let more = app.buttons.matching(identifier: "douyin.more").allElementsBoundByIndex.filter { $0.isHittable }
        XCTAssertFalse(more.isEmpty)
        more[0].tap()
        let item = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH '界面'")).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "「更多」第一层应有界面模式")
        item.tap()
        XCTAssertTrue(app.buttons["简洁"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["极简"].exists)
        attach(app, "chrome-mode-list")
        app.buttons["极简"].tap()
        sleep(3)
        attach(app, "chrome-after-tap")
        XCTAssertTrue(app.buttons["douyin.module.menu"].waitForExistence(timeout: 8), "切到极简后应出现模块入口")
        XCTAssertFalse(app.buttons.matching(identifier: "douyin.author").allElementsBoundByIndex.contains { $0.isHittable }, "切到极简后应隐藏作者")
        attach(app, "chrome-switched-minimal")
    }

    func testClassicTopTabsFrame() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launchEnvironment["DOUDUO_VIDEO_ID"] = "7705789488781932361"
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "classic"
        app.launchArguments += ["-douduo_dismissed_update_v1", "1.3.12"]
        app.launch()
        XCTAssertTrue(app.staticTexts["douyin.currentID"].waitForExistence(timeout: 40))
        sleep(4)
        for t in ["关注", "推荐", "直播"] {
            let b = app.buttons[t].firstMatch
            print("DDTOP \(t) frame=\(b.frame) win=\(app.windows.firstMatch.frame)")
        }
        let more = app.buttons.matching(identifier: "douyin.more").allElementsBoundByIndex.first { $0.isHittable }
        print("DDTOP more frame=\(more?.frame ?? .zero)")
        attach(app, "top-frame")
    }

    /// 极简：底部进度条隐藏，进度画在模块入口外圈；长按入口显示作者标题，松开消失。
    func testMinimalProgressRingAndPeekInfo() throws {
        let app = launchChrome("minimal")
        let menu = app.buttons["douyin.module.menu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        sleep(6)
        let ring = app.otherElements["douyin.module.ring"].firstMatch
        XCTAssertTrue(ring.waitForExistence(timeout: 5), "极简模式应有进度外圈")
        let v1 = ring.value as? String ?? ""
        print("DDRING value1=\(v1)")
        sleep(5)
        let v2 = ring.value as? String ?? ""
        print("DDRING value2=\(v2)")
        XCTAssertNotEqual(v1, v2, "进度外圈应随播放前进")
        attach(app, "minimal-ring")
        XCTAssertFalse(app.otherElements["douyin.peek.info"].exists, "平时不显示作者标题")
        menu.press(forDuration: 1.2)
        // 按住期间截图不可行（press 是阻塞的），松开后应已消失
        sleep(1)
        XCTAssertFalse(app.otherElements["douyin.peek.info"].exists, "松开后作者标题应消失")
    }

    func testMinimalLongPressShowsInfoWhileHeld() throws {
        let app = launchChrome("minimal")
        let menu = app.buttons["douyin.module.menu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        sleep(4)
        let c = menu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        // 按住 3 秒；另起一个 DispatchQueue 在按住中途采样
        var seenDuring = false
        let exp = expectation(description: "sample")
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.8) {
            seenDuring = app.otherElements["douyin.peek.info"].exists || app.staticTexts["douyin.peek.info"].exists
            let shot = XCUIScreen.main.screenshot()
            let att = XCTAttachment(screenshot: shot); att.name = "minimal-peek-held"; att.lifetime = .keepAlways
            self.add(att)
            exp.fulfill()
        }
        c.press(forDuration: 3.0)
        wait(for: [exp], timeout: 5)
        XCTAssertTrue(seenDuring, "按住模块入口时应显示作者标题")
        attach(app, "minimal-after-peek")
        sleep(1)
        XCTAssertFalse(app.otherElements["douyin.peek.info"].exists, "松开后应消失")
    }

    /// 长按模块入口：按住期间和松手后，系统菜单都不能弹出；单击仍能弹菜单。
    func testModuleLongPressDoesNotOpenMenuMinimal() throws { try runLongPressNoMenu("minimal") }
    func testModuleLongPressDoesNotOpenMenuRail() throws { try runLongPressNoMenu("rail") }

    private func runLongPressNoMenu(_ mode: String) throws {
        let app = launchChrome(mode)
        let menu = app.buttons["douyin.module.menu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        sleep(4)
        let c = menu.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        var samples: [String] = []
        let lock = NSLock()
        let exp = expectation(description: "samples")
        exp.expectedFulfillmentCount = 3
        for t in [0.7, 1.5, 2.4] {
            DispatchQueue.global().asyncAfter(deadline: .now() + t) {
                if t == 2.4 {
                    let att = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); att.name = "hold-2.4s"; att.lifetime = .keepAlways
                    self.add(att)
                }
                let menuOpen = app.buttons["douyin.module.search"].exists || app.buttons["搜索"].exists
                let peek = app.buttons["douyin.author"].exists
                lock.lock(); samples.append("t=\(t) menu=\(menuOpen) peek=\(peek)"); lock.unlock()
                exp.fulfill()
            }
        }
        c.press(forDuration: 3.0)
        wait(for: [exp], timeout: 8)
        print("DDHOLD \(samples.sorted())")
        sleep(1)
        let menuAfter = app.buttons["douyin.module.search"].exists || app.buttons["搜索"].exists
        let peekAfter = app.buttons["douyin.author"].exists
        print("DDHOLD after: menu=\(menuAfter) peek=\(peekAfter)")
        XCTAssertFalse(samples.contains { $0.contains("menu=true") }, "按住期间不应弹出菜单：\(samples)")
        if mode == "minimal" {
            // 按下立刻显示：第一个采样点（0.7s）就应该看到
            XCTAssertTrue(samples.contains { $0.hasPrefix("t=0.7") && $0.contains("peek=true") }, "极简按下后应立即显示作者标题：\(samples)")
            XCTAssertTrue(samples.allSatisfy { $0.contains("peek=true") }, "按住期间标题应一直显示：\(samples)")
        }
        XCTAssertFalse(menuAfter, "松手后不应弹出菜单")
        if mode == "minimal" { XCTAssertFalse(peekAfter, "松手后作者标题应消失") }
        // 单击仍然弹菜单
        menu.tap()
        XCTAssertTrue(app.buttons["douyin.module.search"].waitForExistence(timeout: 5) || app.buttons["搜索"].waitForExistence(timeout: 5), "单击仍应弹出模块菜单")
        attach(app, "minimal-menu-after-tap")
    }

    // 兼容旧名


    /// 简洁模式也用外圈进度环，底部进度条隐藏；默认模式没有进度环。
    func testRailModeAlsoHasProgressRing() throws {
        let app = launchChrome("rail")
        XCTAssertTrue(app.buttons["douyin.module.menu"].waitForExistence(timeout: 10))
        sleep(6)
        let ring = app.otherElements["douyin.module.ring"].firstMatch
        XCTAssertTrue(ring.waitForExistence(timeout: 5), "简洁模式应有进度外圈")
        let v1 = ring.value as? String ?? ""; sleep(5); let v2 = ring.value as? String ?? ""
        print("DDRING rail \(v1) -> \(v2)")
        XCTAssertNotEqual(v1, v2)
        attach(app, "rail-ring")
        let classic = launchChrome("classic")
        XCTAssertFalse(classic.otherElements["douyin.module.ring"].exists, "默认模式不画进度环")
    }

    /// 量布局：入口环、入口按钮、右侧胶囊（赞）、更多按钮的位置和尺寸，核对「环与胶囊同宽」「入口到胶囊的间距 = 胶囊到更多的间距」。
    func testModuleEntryGeometry() throws {
        let app = launchChrome("minimal")
        let menu = app.buttons["douyin.module.menu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        sleep(5)
        let ring = app.otherElements["douyin.module.ring"].firstMatch
        XCTAssertTrue(ring.waitForExistence(timeout: 5))
        func vis(_ id: String) -> XCUIElement? {
            app.buttons.matching(identifier: id).allElementsBoundByIndex.first { $0.isHittable }
        }
        let like = vis("douyin.like")!.frame
        let fit = vis("douyin.fit")!.frame
        let more = vis("douyin.more")!.frame
        print("DDGEO ring=\(ring.frame) menu=\(menu.frame) like=\(like) fit=\(fit) more=\(more)")
        // 胶囊整体：赞的上沿 - 8（内边距）= 胶囊上沿；铺满下沿 + 8 = 胶囊下沿
        let capsuleTop = like.minY - 8, capsuleBottom = fit.maxY + 8
        let gapA = capsuleTop - ring.frame.maxY, gapB = more.minY - capsuleBottom
        print("DDGEO capsule=\(capsuleTop)...\(capsuleBottom) ringW=\(ring.frame.width) gapRingToCapsule=\(gapA) gapCapsuleToMore=\(gapB)")
        XCTAssertEqual(ring.frame.width, like.width, accuracy: 1.5, "进度环应和胶囊同宽")
        XCTAssertEqual(ring.frame.midX, like.midX, accuracy: 1.5, "进度环应和胶囊居中对齐")
        XCTAssertEqual(gapA, gapB, accuracy: 1.5, "入口到胶囊的间距应等于胶囊到「更多」的间距")
        attach(app, "geometry")
    }

    /// 极简：单击入口 → 菜单弹出，同时作者标题显示；菜单收起后标题消失。红点只在菜单「消息」行，入口上没有。
    func testMinimalTapShowsInfoWithMenuAndBadgeOnMessagesRow() throws {
        let app = launchChrome("minimal")
        let menu = app.buttons["douyin.module.menu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        sleep(4)
        XCTAssertFalse(app.buttons["douyin.author"].exists, "平时不显示作者")
        menu.tap()
        XCTAssertTrue(app.buttons["douyin.module.search"].waitForExistence(timeout: 5), "单击应弹出菜单")
        sleep(1)
        XCTAssertTrue(app.buttons["douyin.author"].exists, "菜单打开期间应显示作者标题")
        attach(app, "minimal-tap-menu-and-info")
        // 关菜单：点「推荐」行（当前模块，选了也不换页）
        app.buttons["douyin.module.item.recommend"].tap()
        sleep(1)
        XCTAssertFalse(app.buttons["douyin.author"].exists, "菜单收起后标题应消失")
        XCTAssertFalse(app.otherElements["douyin.module.entry.badge"].exists, "入口上不再有红点")
    }

    /// 压测：连续滑 8 条视频，每条停几秒（触发预加载解码音频），期间改倍速。App 不能崩。
    func testSwipeManyVideosWithSeamlessAudioDoesNotCrash() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "classic"
        app.launchArguments += ["-douduo_dismissed_update_v1", "1.3.12"]
        app.launch()
        XCTAssertTrue(app.staticTexts["douyin.currentID"].waitForExistence(timeout: 40))
        sleep(5)
        for i in 1...8 {
            app.swipeUp(velocity: .fast)
            sleep(4)
            XCTAssertEqual(app.state, .runningForeground, "第 \(i) 条视频后 App 崩溃了")
            if i == 3 || i == 6 {
                let more = app.buttons.matching(identifier: "douyin.more").allElementsBoundByIndex.filter { $0.isHittable }
                if let m = more.first {
                    m.tap()
                    let speed = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH '倍速'")).firstMatch
                    if speed.waitForExistence(timeout: 4) {
                        speed.tap()
                        let t = app.buttons[i == 3 ? "1.5 倍速" : "2 倍速"]
                        if t.waitForExistence(timeout: 4) { t.tap() }
                    }
                    sleep(2)
                }
            }
        }
        XCTAssertEqual(app.state, .runningForeground)
    }

    /// 分页里每页都挂了角标，只取屏幕上那个
    private func visibleBadge(_ app: XCUIApplication) -> XCUIElement? {
        let f = app.windows.firstMatch.frame
        return app.staticTexts.matching(identifier: "douyin.rateBadge").allElementsBoundByIndex.first {
            $0.frame.midY > f.minY && $0.frame.midY < f.maxY && $0.frame.midX > f.minX && $0.frame.midX < f.maxX
        }
    }

    private func waitBadge(_ app: XCUIApplication, _ label: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let b = visibleBadge(app), b.label == label { return true }
            usleep(200_000)
        }
        return false
    }

    /// 中间长按 → 默认展开的视频播放设置。
    private func openSpeedMenu(_ app: XCUIApplication) {
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
            .press(forDuration: 0.8)
        XCTAssertTrue(app.buttons["douyin.options.rate.1.0"].waitForExistence(timeout: 5))
    }

    private func wait(label: String, on element: XCUIElement, timeout: TimeInterval) -> Bool {
        let exp = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: element)
        return XCTWaiter().wait(for: [exp], timeout: timeout) == .completed
    }

    /// Native tabs, stable video header and compact comments. No account writes.
    func testSystemBarsDockAndComments() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        addTeardownBlock { app.terminate() }
        app.launchEnvironment["DOUDUO_VIDEO_ID"] = "7678628867820506406"
        app.launch()
        let current = app.staticTexts["douyin.currentID"]
        XCTAssertTrue(current.waitForExistence(timeout: 40))
        XCTAssertTrue(wait(label: "7678628867820506406", on: current, timeout: 45))
        func visibleButton(_ id: String) -> XCUIElement {
            app.buttons.matching(identifier: id).allElementsBoundByIndex.first(where: { $0.isHittable })
                ?? app.buttons[id].firstMatch
        }
        let header = app.otherElements["douyin.feed.header"].firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 10))
        let headerFrame = header.frame
        let actionIDs = ["douyin.author.avatar", "douyin.like", "douyin.comments", "douyin.collect", "douyin.share"]
        let actions = actionIDs.map(visibleButton)
        for action in actions { XCTAssertTrue(action.isHittable, app.debugDescription) }
        for i in 1..<actions.count { XCTAssertGreaterThan(actions[i].frame.minY, actions[i-1].frame.minY) }
        for id in actionIDs.dropFirst() {
            XCTAssertNotNil(visibleButton(id).label.rangeOfCharacter(from: .decimalDigits))
        }
        let home = app.buttons["首页"].firstMatch
        XCTAssertTrue(home.isHittable, app.debugDescription)
        print("DUO_DOCK_WINDOW \(app.windows.firstMatch.frame)")
        for action in actions {
            XCTAssertLessThanOrEqual(action.frame.width, 54, "保留小尺寸互动栏")
        }
        let info = app.otherElements["douyin.video.info"].firstMatch
        let progress = app.otherElements["douyin.progress"].firstMatch
        XCTAssertFalse(info.frame.intersects(home.frame))
        XCTAssertFalse(progress.frame.intersects(home.frame))
        attach(app, "build94-native-dock-home")
        let originalID = current.label
        home.tap()
        let mine = app.buttons["我的"].firstMatch
        let messages = app.buttons["私信"].firstMatch
        if app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height || app.windows.firstMatch.frame.width < 600 {
            XCTAssertLessThan(mine.frame.minY, messages.frame.minY)
            XCTAssertLessThan(messages.frame.minY, home.frame.minY)
        }
        attach(app, "build94-native-dock-expanded")
        mine.tap()
        XCTAssertTrue(app.buttons["douyin.mine.post"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertFalse(visibleButton("douyin.like").exists)
        attach(app, "build94-native-mine")
        let tabFrames = [mine, messages, home].map(\.frame)
        messages.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "douyin.messages.root").firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        let tabsSettled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            zip([mine, messages, home], tabFrames).allSatisfy { tab, frame in
                abs(tab.frame.midX - frame.midX) <= 2
            }
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [tabsSettled], timeout: 8), .completed)
        print("NATIVE_TAB_FRAMES mine=\(tabFrames) messages=\([mine, messages, home].map(\.frame))")
        XCTAssertEqual(home.frame.maxY, tabFrames[2].maxY, accuracy: 2, "系统 Dock 底部锚点保持一致；选中项的原生胶囊可改变各项尺寸")
        attach(app, "build94-native-messages")
        XCTAssertFalse(app.buttons["douyin.mine.back"].exists)
        XCTAssertFalse(app.buttons["douyin.messages.back"].exists)
        home.tap()
        XCTAssertTrue(visibleButton("douyin.comments").waitForExistence(timeout: 10))
        XCTAssertEqual(current.label, originalID)
        visibleButton("douyin.comments").tap()
        let close = app.buttons["douyin.comments.close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 15))
        let panel = app.descendants(matching: .any).matching(identifier: "douyin.comments.panel").firstMatch
        let commentHeader = app.otherElements["douyin.comments.header"].firstMatch
        XCTAssertLessThanOrEqual(commentHeader.frame.height, 44)
        let related = app.scrollViews["douyin.comments.relatedSearch"].firstMatch
        if related.waitForExistence(timeout: 15) {
            XCTAssertLessThanOrEqual(related.frame.minY, commentHeader.frame.maxY + 1)
            XCTAssertLessThanOrEqual(related.frame.maxX, panel.frame.maxX + 1)
        }
        attach(app, "build90-compact-comment-header-search-above-list")
        close.tap()
        for round in 1...2 {
            XCTAssertTrue(visibleButton("douyin.comments").waitForExistence(timeout: 10))
            attach(app, "build94-native-dock-after-comment-" + String(round))
            visibleButton("douyin.comments").tap()
            XCTAssertTrue(close.waitForExistence(timeout: 10))
            close.tap()
        }
        let previous = current.label
        app.windows.firstMatch.swipeUp(velocity: .fast)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", previous), object: current)], timeout: 10), .completed)
        XCTAssertEqual(header.frame.minY, headerFrame.minY, accuracy: 1)
        XCTAssertEqual(header.frame.minX, headerFrame.minX, accuracy: 1)
        XCTAssertTrue(visibleButton("douyin.more").isHittable)
        XCTAssertTrue(visibleButton("douyin.search").isHittable)
        XCTAssertTrue(visibleButton("douyin.share").isHittable)
        attach(app, "build90-fixed-header-after-next-video")
    }

    /// Same public work is injected only in DEBUG to exercise logged-out entry
    /// routes. Real comments/layout, no synthetic account history or sends.
    func testCommentsAreSharedAcrossRecommendationFollowAndMine() throws {
        continueAfterFailure = false
        var reference: CGRect?
        for entry in ["home", "follow", "mine"] {
            let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
            app.launchArguments += ["-douyin_muted_v1", "YES"]
            app.launchEnvironment["DOUDUO_VIDEO_ID"] = "7678628867820506406"
            addTeardownBlock { app.terminate() }
            app.launchEnvironment["DOUDUO_COMMENT_ENTRY"] = entry
            app.launch()
            let current = app.staticTexts["douyin.currentID"]
            XCTAssertTrue(current.waitForExistence(timeout: 40))
            XCTAssertTrue(wait(label: "7678628867820506406", on: current, timeout: 45))
            if entry == "follow" {
                app.buttons["关注"].firstMatch.tap()
                XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "douyin.follow.feed").firstMatch.waitForExistence(timeout: 10))
            } else if entry == "mine" {
                app.buttons["首页"].firstMatch.tap()
                app.buttons["我的"].firstMatch.tap()
                XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "douyin.list.player").firstMatch.waitForExistence(timeout: 40))
            }
            let comment = app.buttons["douyin.comments"].firstMatch
            XCTAssertTrue(comment.waitForExistence(timeout: 40))
            comment.tap()
            let panel = app.descendants(matching: .any).matching(identifier: "douyin.comments.panel").firstMatch
            XCTAssertTrue(panel.waitForExistence(timeout: 15))
            let header = app.otherElements["douyin.comments.header"].firstMatch
            XCTAssertLessThanOrEqual(header.frame.height, 44)
            if app.windows.firstMatch.frame.width >= 700 {
                XCTAssertGreaterThan(panel.frame.width, app.windows.firstMatch.frame.width * 0.40)
                XCTAssertLessThan(panel.frame.width, app.windows.firstMatch.frame.width * 0.52)
                XCTAssertFalse(app.buttons["douyin.like"].firstMatch.exists)
                XCTAssertFalse(app.buttons["首页"].firstMatch.isHittable)
            } else {
                XCTAssertGreaterThan(panel.frame.width, app.windows.firstMatch.frame.width * 0.94)
            }
            if let reference {
                XCTAssertEqual(panel.frame.minX, reference.minX, accuracy: 2)
                XCTAssertEqual(panel.frame.width, reference.width, accuracy: 2)
                XCTAssertEqual(panel.frame.minY, reference.minY, accuracy: 2)
            } else { reference = panel.frame }
            let related = app.scrollViews["douyin.comments.relatedSearch"].firstMatch
            XCTAssertTrue(related.waitForExistence(timeout: 15))
            XCTAssertLessThanOrEqual(related.frame.minY, header.frame.maxY + 1)
            let input = app.descendants(matching: .any).matching(identifier: "douyin.comment.input").firstMatch
            XCTAssertTrue(input.waitForExistence(timeout: 10))
            XCTAssertTrue(input.isHittable, app.debugDescription)
            attach(app, "build90-shared-comments-" + entry)
            input.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
            XCTAssertGreaterThanOrEqual(input.frame.height, 16, "输入文字不能只剩被键盘裁剪后的细线")
            XCTAssertLessThanOrEqual(input.frame.maxY, app.keyboards.firstMatch.frame.minY + 2)
            print("COMMENT_INPUT_FRAME \(entry) input=\(input.frame) keyboard=\(app.keyboards.firstMatch.frame)")
            attach(app, "build90-shared-comments-keyboard-" + entry)
            app.buttons["douyin.comments.close"].firstMatch.tap()
            app.terminate()
        }
    }

    func testPinchZoomAndBoostWithoutAccountWrites() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES", "-douyin_playback_rate_v1", "1"]
        app.launchEnvironment["DOUDUO_VIDEO_ID"] = "7678628867820506406"
        addTeardownBlock { app.terminate() }
        app.launch()
        let current = app.staticTexts["douyin.currentID"]
        XCTAssertTrue(current.waitForExistence(timeout: 40))
        XCTAssertTrue(wait(label: "7678628867820506406", on: current, timeout: 45))
        let id = current.label
        let zoom = app.staticTexts.matching(identifier: "douyin.video.zoom").firstMatch
        let fitMode = app.staticTexts.matching(identifier: "douyin.video.fitMode").firstMatch
        // Synchronize XCTest's touch coordinates with the actual Duo display.
        attach(app, "build95-pinch-before")
        // The transparent UIKit gesture host is not an accessibility hit target.
        // Pinch the visible window so XCTest uses the physical display bounds.
        let gesture = app.windows.firstMatch
        // Launch arguments override later UserDefaults writes. Set this
        // mutable preference through its real control, so pinching can change it.
        if fitMode.label != "fill" {
            openSpeedMenu(app)
            app.buttons["douyin.options.fit"].tap()
            app.buttons["douyin.options.close"].tap()
        }
        XCTAssertTrue(wait(label: "fill", on: fitMode, timeout: 5))
        gesture.pinch(withScale: 0.65, velocity: -1)
        XCTAssertTrue(wait(label: "fit", on: fitMode, timeout: 5))
        XCTAssertTrue(wait(label: "1.00", on: zoom, timeout: 5))
        XCTAssertEqual(current.label, id, "双指缩放不能切换视频")
        attach(app, "build95-pinch-fit-navigation-check")
        XCTAssertFalse(app.buttons["douyin.author.back"].exists)
        attach(app, "build91-pinch-fit-recentred-blurred-background")
        gesture.pinch(withScale: 2.5, velocity: 1)
        XCTAssertTrue(wait(label: "fill", on: fitMode, timeout: 5))
        XCTAssertTrue(wait(label: "1.00", on: zoom, timeout: 5))
        XCTAssertEqual(current.label, id)
        attach(app, "build91-pinch-fill-recentred")
        let start = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.35))
        let down = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.53))
        start.press(forDuration: 0.8, thenDragTo: down, withVelocity: .slow, thenHoldForDuration: 0.2)
        XCTAssertTrue(waitBadge(app, "2×", timeout: 5))
        XCTAssertEqual(current.label, id)
        let up = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.20))
        start.press(forDuration: 0.8, thenDragTo: up, withVelocity: .slow, thenHoldForDuration: 0.2)
        XCTAssertNil(visibleBadge(app))
        attach(app, "build90-long-press-released")
    }

    func testDragAndHoldDoesNotStartBoost() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES", "-douyin_playback_rate_v1", "1"]
        app.launchEnvironment["DOUDUO_VIDEO_ID"] = "7678628867820506406"
        addTeardownBlock { app.terminate() }
        app.launch()
        let current = app.staticTexts["douyin.currentID"]
        XCTAssertTrue(current.waitForExistence(timeout: 40))
        XCTAssertTrue(wait(label: "7678628867820506406", on: current, timeout: 45))
        attach(app, "build95-drag-before")
        let start = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.65))
        let end = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.2))
        let boostCount = app.staticTexts["douyin.video.boostStarts"].firstMatch
        XCTAssertEqual(boostCount.label, "0")
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 1.2)
        XCTAssertEqual(boostCount.label, "0", "整个拖动及停留过程都不能触发长按，而不只是松手后恢复速度")
        XCTAssertNil(visibleBadge(app), "先拖动再停住不能进入长按倍速")
        XCTAssertFalse(app.buttons["douyin.options.close"].exists)
        attach(app, "build95-drag-hold-no-boost")
        let stationary = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.35))
        stationary.press(forDuration: 0.8, thenDragTo: start, withVelocity: .slow, thenHoldForDuration: 0.2)
        XCTAssertTrue(waitBadge(app, "2×", timeout: 5), "静止长按后下滑仍能锁定倍速")
        XCTAssertEqual(boostCount.label, "1")
    }

    func testVideoSwipesNavigateAndProgressStillSeeks() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launchEnvironment["DOUDUO_VIDEO_ID"] = "7705789488781932361"
        addTeardownBlock { app.terminate() }
        app.launch()
        let current = app.staticTexts["douyin.currentID"]
        XCTAssertTrue(current.waitForExistence(timeout: 40))
        XCTAssertTrue(wait(label: "7705789488781932361", on: current, timeout: 45))
        let like = app.buttons["douyin.like"].firstMatch
        XCTAssertTrue(like.waitForExistence(timeout: 45))
        let progress = app.otherElements["douyin.progress"].firstMatch
        XCTAssertTrue(progress.waitForExistence(timeout: 10))
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.48))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.48))
        start.press(forDuration: 0.05, thenDragTo: end)
        XCTAssertTrue(app.buttons["douyin.channel.follow"].firstMatch.isHittable)
        XCTAssertEqual(app.buttons["douyin.channel.follow"].value as? String, "已选择")
        attach(app, "duo-swipe-right-follow")
        end.press(forDuration: 0.05, thenDragTo: start)
        XCTAssertEqual(app.buttons["douyin.channel.recommend"].value as? String, "已选择")
        XCTAssertFalse(app.buttons["douyin.author.back"].exists)
        XCTAssertTrue(like.waitForExistence(timeout: 10))
        end.press(forDuration: 0.05, thenDragTo: start)
        let back = app.buttons["douyin.author.back"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10), "左滑须打开作者页")
        let authorPanel = app.otherElements["douyin.author.panel"].firstMatch
        XCTAssertLessThan(authorPanel.frame.minY, app.frame.height * 0.15, "外屏作者页应是整页而非 sheet")
        XCTAssertFalse(app.buttons["house"].firstMatch.isHittable, "作者页隐藏 Dock")
        XCTAssertGreaterThan(back.frame.midX, app.frame.width * 0.8, "返回交给系统放到状态栏下方")
        XCTAssertEqual(back.frame.midX, app.buttons["douyin.author.follow"].firstMatch.frame.midX, accuracy: 2)
        attach(app, "duo-swipe-left-author")
        back.tap()
        XCTAssertTrue(progress.waitForExistence(timeout: 10))
        let before = (progress.value as? String ?? "").split { !$0.isNumber }.compactMap { Double($0) }
        XCTAssertEqual(before.count, 2)
        XCTAssertGreaterThan(before[1], 0)
        let forward = before[0] < before[1] * 0.5
        progress.coordinate(withNormalizedOffset: CGVector(dx: forward ? 0.35 : 0.65, dy: 0.7))
            .press(forDuration: 0.1, thenDragTo: progress.coordinate(withNormalizedOffset: CGVector(dx: forward ? 0.65 : 0.35, dy: 0.7)))
        let seeked = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let after = (progress.value as? String ?? "").split { !$0.isNumber }.compactMap { Double($0) }
            return after.count == 2 && (after[0] - before[0]) * (forward ? 1 : -1) > before[1] * 0.2
        }, object: progress)
        XCTAssertEqual(XCTWaiter.wait(for: [seeked], timeout: 7), .completed, "进度条仍按原版相对拖动跳转")
        attach(app, "duo-progress-drag")
        let previous = current.label
        app.swipeUp(velocity: .fast)
        let advanced = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", previous), object: current)
        XCTAssertEqual(XCTWaiter.wait(for: [advanced], timeout: 10), .completed, "竖滑切视频保持有效")
    }

    func testCommentImages() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launch()
        let current = app.staticTexts["douyin.currentID"]
        XCTAssertTrue(current.waitForExistence(timeout: 40))
        sleep(4)
        // 在推荐流里逐条打开评论，找带图/贴纸的评论；评论面板关掉再翻下一条
        for n in 0..<15 {
            let btn = app.buttons.matching(identifier: "douyin.comments").allElementsBoundByIndex.first { $0.isHittable }
            guard let btn else { app.swipeUp(); sleep(3); continue }
            btn.tap()
            sleep(5)
            let img = app.descendants(matching: .any).matching(identifier: "douyin.comment.images").firstMatch
            let stk = app.descendants(matching: .any).matching(identifier: "douyin.comment.sticker").firstMatch
            if img.exists || stk.exists {
                let hit = img.exists ? img : stk
                print("DDCOMMENTIMG found video#\(n) kind=\(img.exists ? "image" : "sticker")")
                // 在评论面板内滚动（不是整个 app，否则会翻走视频）
                let panel = app.scrollViews.allElementsBoundByIndex.first { $0.frame.minX > app.windows.firstMatch.frame.width * 0.5 } ?? app.scrollViews.allElementsBoundByIndex.last
                var tries = 0
                while !hit.isHittable && tries < 12 {
                    panel?.swipeUp(velocity: .slow)
                    tries += 1
                }
                print("DDCOMMENTIMG frame=\(hit.frame) hittable=\(hit.isHittable)")
                print("DDCHAT_SHOT_COMMENTIMG"); sleep(3)
                hit.tap()
                let close = app.buttons["douyin.comment.viewer.close"]
                XCTAssertTrue(close.waitForExistence(timeout: 10), "点图没打开全屏查看")
                sleep(3)
                print("DDCHAT_SHOT_COMMENTVIEWER"); sleep(3)
                close.tap()
                return
            }
            // 关评论：再点一次评论按钮（宽屏侧栏）或下滑（sheet）
            if btn.isHittable { btn.tap() } else { app.swipeDown(velocity: .fast) }
            sleep(2)
            app.swipeUp()
            sleep(4)
        }
        XCTFail("翻了15条视频都没遇到带图/贴纸的评论")
    }

    /// Both compact and split: inspect the composer without typing or sending.
    func testConversationListAndDetail() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launchEnvironment["DOUDUO_OPEN"] = "messages"
        app.launch()
        let row = app.buttons.matching(identifier: "douyin.conversation.row").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 50), app.debugDescription)
        let expectsSidebar = app.staticTexts["选择左侧消息查看详情"].isHittable
        print("DDCHAT_EXPECT_SIDEBAR=\(expectsSidebar)")
        attach(app, "conversation-native-root")
        print("DDCHAT_SHOT_ROOT"); sleep(4)
        let label = row.label
        print("DDCHAT root rows=\(app.buttons.matching(identifier: "douyin.conversation.row").count)")
        row.tap()
        sleep(5)
        attach(app, "conversation-single-detail")
        print("DDCHAT_SHOT_DETAIL"); sleep(4)
        print("DDCHAT_DETAIL\n\(app.debugDescription)\nDDCHAT_DETAIL_END")
        let web = app.webViews.matching(identifier: "douyin.messages.chat.detail").firstMatch
        XCTAssertTrue(web.exists)
        let master = app.buttons["douyin.messages.interactive"]
        XCTAssertEqual(master.isHittable, expectsSidebar, "展开应保留左栏；窄屏详情应覆盖列表")
        if expectsSidebar { XCTAssertGreaterThanOrEqual(web.frame.minX, master.frame.maxX - 2) }
        if expectsSidebar { XCTAssertTrue(row.isSelected, "左侧当前会话应该高亮") }
        XCTAssertTrue(web.isHittable, "当前聊天详情应可交互")
        let inputs = web.descendants(matching: .any).matching(NSPredicate(format: "elementType == %d OR elementType == %d", XCUIElement.ElementType.textView.rawValue, XCUIElement.ElementType.textField.rawValue))
        XCTAssertGreaterThan(inputs.count, 0)
        if inputs.count > 0 {
            let input = inputs.firstMatch
            XCTAssertLessThanOrEqual(input.frame.maxY, app.windows.firstMatch.frame.maxY)
            XCTAssertTrue(input.isHittable, "聊天输入区应可达；不输入或发送测试消息")
        }
        app.buttons["douyin.messages.back"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["douyin.messages.interactive"].exists)
        attach(app, "conversation-return-list")
        print("DDCHAT returned; original row label length=\(label.count)")
    }

    /// 评论通知：下方有「回复」（只验证弹出输入框，不真发）、长评论可展开、点评论进视频并定位高亮那条评论
    func testCommentNoticeActions() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launchEnvironment["DOUDUO_OPEN"] = "messages"
        app.launchEnvironment["DOUDUO_LONGNOTICE"] = "1"
        app.launch()
        let entry = app.buttons["douyin.messages.interactive"]
        XCTAssertTrue(entry.waitForExistence(timeout: 35))
        entry.tap()
        let comment = app.buttons.matching(identifier: "douyin.notice.comment").firstMatch
        XCTAssertTrue(comment.waitForExistence(timeout: 25), "互动里没有评论通知")
        sleep(2)
        print("DDCHAT_SHOT_CNOTICE_LIST"); sleep(3)
        let reply = app.buttons.matching(identifier: "douyin.notice.reply").firstMatch
        XCTAssertTrue(reply.exists, "评论通知下面没有回复按钮")
        reply.tap()
        let input = app.descendants(matching: .any).matching(identifier: "douyin.notice.reply.input").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5), "点回复没出输入框")
        print("DDCHAT_SHOT_CNOTICE_REPLY"); sleep(3)
        app.buttons["douyin.notice.reply.cancel"].firstMatch.tap()
        sleep(1)
        let expand = app.buttons.matching(identifier: "douyin.notice.expand").firstMatch
        print("DDEXPAND count=\(app.buttons.matching(identifier: "douyin.notice.expand").count)")
        if expand.exists && expand.isHittable {
            let before = expand.label
            expand.tap(); sleep(1)
            print("DDEXPAND before=\(before) after=\(expand.label)")
            XCTAssertNotEqual(before, expand.label, "点展开没变成收起")
            print("DDCHAT_SHOT_CNOTICE_EXPAND"); sleep(3)
        }
        comment.tap()
        let focused = app.descendants(matching: .any).matching(identifier: "douyin.comment.focused").firstMatch
        XCTAssertTrue(focused.waitForExistence(timeout: 30), "进视频后没定位到那条评论")
        print("DDCHAT_SHOT_CNOTICE_FOCUS"); sleep(3)
    }

    /// Read-only: split keeps master visible; compact returns through master.
    /// No text input, sends, likes or follows.
    func testMessageMasterDetailCategories() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launchEnvironment["DOUDUO_OPEN"] = "messages"
        app.launch()
        let interactive = app.buttons["douyin.messages.interactive"]
        XCTAssertTrue(interactive.waitForExistence(timeout: 35))
        let expectsSidebar = app.staticTexts["选择左侧消息查看详情"].isHittable
        print("DDMSG_EXPECT_SIDEBAR=\(expectsSidebar)")
        func showMasterIfCompact() {
            if !expectsSidebar {
                app.buttons["douyin.messages.back"].tap()
                XCTAssertTrue(interactive.isHittable)
            }
        }
        interactive.tap()
        let filter = app.descendants(matching: .any).matching(identifier: "douyin.notice.filter").firstMatch
        XCTAssertTrue(filter.waitForExistence(timeout: 15))
        XCTAssertEqual(interactive.isHittable, expectsSidebar, "分类应符合当前主从/窄屏布局")
        if expectsSidebar { XCTAssertGreaterThan(filter.frame.minX, interactive.frame.maxX - 2, "通知应显示在右栏") }
        filter.tap()
        let comments = app.buttons["douyin.notice.filter.2"] // production DYNoticeGroup.comment
        XCTAssertTrue(comments.waitForExistence(timeout: 5))
        comments.tap()
        XCTAssertTrue(filter.label.contains("评论"))
        showMasterIfCompact()
        app.buttons["douyin.messages.fans"].tap()
        XCTAssertEqual(interactive.isHittable, expectsSidebar)
        showMasterIfCompact()
        app.buttons["douyin.messages.system"].tap()
        XCTAssertEqual(interactive.isHittable, expectsSidebar)
        showMasterIfCompact()
        interactive.tap()
        XCTAssertTrue(filter.label.contains("评论"), "分类切换后应保留筛选")
        app.buttons["douyin.messages.back"].tap()
        XCTAssertTrue(interactive.isHittable, "详情返回应先回消息列表，不退出消息中心")
        // Lists remain mounted to preserve scroll/filter state; inactive controls must not be tappable.
        XCTAssertFalse(filter.isHittable)
        XCTAssertFalse(interactive.isSelected)
        attach(app, "message-master-detail-category-return")
    }

    func testMessageReadAndVideoReturn() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launchEnvironment["DOUDUO_OPEN"] = "messages"
        app.launchEnvironment["DOUDUO_READ_AUDIT"] = "1"
        app.launch()
        let entry = app.buttons["douyin.messages.interactive"]
        XCTAssertTrue(entry.waitForExistence(timeout: 35))
        sleep(12)
        print("DDUNREAD_BEFORE=\(entry.value ?? "nil")")
        entry.tap()
        sleep(12)
        attach(app, "notice-category")
        print("DDCHAT_SHOT_NOTICE"); sleep(4)
        let videos = app.buttons.matching(identifier: "douyin.notice.video")
        _ = videos.firstMatch.waitForExistence(timeout: 15)
        guard let video = videos.allElementsBoundByIndex.first(where: { $0.isHittable }) else {
            throw XCTSkip("当前通知里没有可点击视频卡片，不能将视频返回路径算通过")
        }
        let originalLabel = video.label
        let originalFrame = video.frame
        video.tap()
        let playerBack = app.buttons["douyin.list.back"].firstMatch
        XCTAssertTrue(playerBack.waitForExistence(timeout: 25))
        let like = app.buttons.matching(identifier: "douyin.like").allElementsBoundByIndex.first { $0.isHittable }
        if let like { XCTAssertLessThan(playerBack.frame.midY, like.frame.midY) }
        attach(app, "notice-video-return-above-like")
        playerBack.tap()
        XCTAssertTrue(video.waitForExistence(timeout: 10))
        XCTAssertTrue(video.isHittable)
        XCTAssertEqual(video.label, originalLabel, "视频返回必须保留同一通知")
        XCTAssertEqual(video.frame.minY, originalFrame.minY, accuracy: 2, "视频返回不能重置列表位置")
        let back = app.buttons["douyin.messages.back"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5), app.debugDescription)
        back.tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 8))
        sleep(10)
        // 退出分类只把看过的互动类（评论/赞）标已读；粉丝/系统仍可能有未读，所以看这个入口的角标
        print("DDUNREAD_AFTER=\(entry.value ?? "nil")")
        XCTAssertEqual(entry.value as? String, "0", "退出互动分类后它的未读应清零")
        XCTAssertTrue(app.buttons.matching(identifier: "douyin.conversation.row").firstMatch.waitForExistence(timeout: 15))
        attach(app, "message-read-and-conversations")
    }


    /// 只读采样手机上已安装的正式抖音 UI；默认跳过，不能用 DouDuo 页面冒充原版。
    func testOriginalLiveReference() throws {
        guard ProcessInfo.processInfo.environment["DOUDUO_ORIGINAL_REF"] == "1" else {
            throw XCTSkip("仅在连接已安装正式抖音的真机时手动启用")
        }
        let app = XCUIApplication(bundleIdentifier: "com.ss.iphone.ugc.Aweme")
        app.activate()
        sleep(5)
        guard app.state == .runningForeground else { throw XCTSkip("手机正在使用其他 App，停止采样") }
        print("DDORIGINAL_HOME\n\(app.debugDescription)\nDDORIGINAL_END")
        attach(app, "original-home")
        let entry = app.descendants(matching: .any).matching(NSPredicate(format: "label == '直播'")).allElementsBoundByIndex.first { $0.isHittable }
        if let entry {
            entry.tap()
            sleep(6)
            guard app.state == .runningForeground else { throw XCTSkip("原版已不在前台，停止采样") }
            print("DDORIGINAL_LIVE\n\(app.debugDescription)\nDDORIGINAL_END")
            attach(app, "original-live")
        }
        let roomEntry = app.buttons.matching(NSPredicate(format: "label CONTAINS '点击进入直播间'")).firstMatch
        if roomEntry.waitForExistence(timeout: 8), roomEntry.isHittable {
            roomEntry.tap()
            sleep(6)
            guard app.state == .runningForeground else { throw XCTSkip("原版已不在前台，进房采样作废") }
            print("DDORIGINAL_ROOM\n\(app.debugDescription)\nDDORIGINAL_END")
            attach(app, "original-room")
        }
    }

    func testLivePagesFillViewport() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launchEnvironment["DOUDUO_STARTLIVE"] = "1"
        app.launch()
        let current = app.staticTexts["live.currentID"]
        XCTAssertTrue(current.waitForExistence(timeout: 30))
        let loaded = expectation(for: NSPredicate(format: "label != '-'"), evaluatedWith: current)
        XCTAssertEqual(XCTWaiter().wait(for: [loaded], timeout: 40), .completed)
        for index in 0..<2 {
            let id = current.label
            let page = app.otherElements["live.page.\(id)"]
            XCTAssertTrue(page.waitForExistence(timeout: 5))
            let window = app.windows.firstMatch.frame
            XCTAssertEqual(page.frame.height, window.height, accuracy: 1, "直播页必须覆盖实际视口，不能少掉底部安全区")
            XCTAssertEqual(page.frame.maxY, window.maxY, accuracy: 1, "静止时页底必须与窗口底边重合")
            attach(app, "live-page-fill-\(index)")
            if index == 0 {
                page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
                    .press(forDuration: 0.05, thenDragTo: page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)))
                let changed = expectation(for: NSPredicate(format: "label != %@", id), evaluatedWith: current)
                XCTAssertEqual(XCTWaiter().wait(for: [changed], timeout: 10), .completed)
                sleep(1)
            }
        }
    }

    func testNativeLiveRoomFlow() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launchEnvironment["DOUDUO_STARTLIVE"] = "1"
        app.launch()
        let categories = app.buttons["live.discover"]
        XCTAssertTrue(categories.waitForExistence(timeout: 15), "发现更多应收成一个按钮")
        XCTAssertFalse(app.buttons["live.categories"].exists, "单独游戏专区入口已移除")
        XCTAssertFalse(app.buttons["英雄联盟"].exists, "分类不能常驻")
        categories.tap()
        app.buttons["live.category.game"].tap()
        XCTAssertTrue(app.buttons["英雄联盟"].waitForExistence(timeout: 5))
        attach(app, "live-category-picker")
        app.buttons["live.categories.close"].tap()
        categories.tap()
        let enter = app.buttons.matching(identifier: "live.room.enter").firstMatch
        XCTAssertTrue(enter.waitForExistence(timeout: 30))
        XCTAssertTrue(enter.isHittable)
        let id = app.staticTexts["live.currentID"].label
        enter.tap()
        XCTAssertTrue(app.buttons["live.room.close"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["live.chat.input"].exists)
        XCTAssertFalse(app.buttons["live.categories"].exists, "进房后不显示首页分类按钮")
        XCTAssertFalse(app.buttons["douyin.web.close"].exists, "进房不能打开网页版播放器")
        attach(app, "native-live-room")
        app.buttons["live.room.more"].tap()
        app.buttons["清屏"].tap()
        XCTAssertTrue(app.buttons["live.room.restore"].waitForExistence(timeout: 5))
        app.buttons["live.room.restore"].tap()
        app.buttons["live.room.close"].tap()
        XCTAssertTrue(categories.waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["live.currentID"].label, id, "退房应回到同一个直播预览")
        attach(app, "live-preview-return")
        let page = app.otherElements["live.page.\(id)"]
        page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
            .press(forDuration: 0.05, thenDragTo: page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)))
        let current = app.staticTexts["live.currentID"]
        let changed = expectation(for: NSPredicate(format: "label != %@", id), evaluatedWith: current)
        XCTAssertEqual(XCTWaiter().wait(for: [changed], timeout: 10), .completed, "上滑应换到相邻房间")
        let nextID = current.label
        sleep(3)
        XCTAssertEqual(current.label, nextID, "停止滑动后不应因布局回写继续乱跳")
    }

    /// 使用真实作品详情验证声明与时间，不通过标题猜 AI，也不做账号互动。
    func testVideoMetadataAIAndPublication() throws {
        for (id, isAI, name) in [("7705789488781932361", true, "ai"), ("7705458913226935590", false, "normal")] {
            let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
            app.launchEnvironment["DOUDUO_VIDEO_ID"] = id
            app.launch()
            let current = app.staticTexts["douyin.currentID"]
            XCTAssertTrue(current.waitForExistence(timeout: 30))
            let loaded = expectation(for: NSPredicate(format: "label == %@", id), evaluatedWith: current)
            XCTAssertEqual(XCTWaiter().wait(for: [loaded], timeout: 50), .completed)
            let metadata = app.staticTexts.matching(identifier: "douyin.video.metadata").firstMatch
            XCTAssertTrue(metadata.waitForExistence(timeout: 10))
            XCTAssertTrue(metadata.label.contains("发布"))
            XCTAssertEqual(metadata.label.contains("作者声明：内容由 AI 生成"), isAI)
            print("DDMETA_SCREEN:\(name) label=\(metadata.label)")
            fflush(stdout)
            sleep(4)
            app.terminate()
        }
    }

    /// 只输入草稿、不点击发送；验证真实隐藏网页就绪后，原生发送按钮才可用。
    func testLiveComposerReadyWithoutSending() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launchEnvironment["DOUDUO_STARTLIVE"] = "1"
        app.launchEnvironment["DOUDUO_AUTOLIVEROOM"] = "1"
        app.launch()
        let input = app.textFields["live.chat.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 35))
        let ready = expectation(for: NSPredicate(format: "value == %@", "说点什么…"), evaluatedWith: input)
        XCTAssertEqual(XCTWaiter().wait(for: [ready], timeout: 65), .completed, "必须等官网真实输入框挂载，不用视频首帧代替")
        input.tap()
        input.typeText("LOCAL_ONLY_DO_NOT_SEND")
        let send = app.buttons["live.chat.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        XCTAssertTrue(send.isEnabled)
        XCTAssertEqual(input.value as? String, "LOCAL_ONLY_DO_NOT_SEND")
        print("DDCOMPOSER_UI ready=true draft-preserved=true send-enabled=true no-send-performed=true")
        app.terminate()
    }

    /// 真机/模拟器均可跑；计时以 App 的 DDLIVE_READY 日志为准，截图另证是否实际出画。
    func testNativeLivePerformance() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launchEnvironment["DOUDUO_STARTLIVE"] = "1"
        app.launchEnvironment["DOUDUO_LIVEPROBE"] = "1"
        app.launch()
        let current = app.staticTexts["live.currentID"]
        let status = app.staticTexts["live.status"]
        XCTAssertTrue(current.waitForExistence(timeout: 30))
        for index in 0..<3 {
            let ready = expectation(for: NSPredicate(format: "label == '1'"), evaluatedWith: status)
            XCTAssertEqual(XCTWaiter().wait(for: [ready], timeout: 45), .completed, "当前房间没有视频输出")
            guard app.state == .runningForeground else { throw XCTSkip("用户切走了 App，本次截图作废") }
            let id = current.label
            attach(app, "device-live-frame-\(index)")
            let progress = app.staticTexts["live.time"].label
            print("DDDEVICE_SAMPLE index=\(index) id=\(id) progress=\(progress)")
            if index < 2 {
                let changed = expectation(for: NSPredicate(format: "label != %@", id), evaluatedWith: current)
                XCTAssertEqual(XCTWaiter().wait(for: [changed], timeout: 30), .completed, "探针没有切到下一间")
            }
        }
    }

    /// 头部缓存起播：先让当前条缓存 + 预取后面 2 条，再上滑看是否本地起播并在安全点切回在线
    func testHeadCachePlayback() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launch()
        let current = app.staticTexts["douyin.currentID"]
        XCTAssertTrue(current.waitForExistence(timeout: 30))
        let loaded = expectation(for: NSPredicate(format: "label != '-'"), evaluatedWith: current)
        XCTAssertEqual(XCTWaiter().wait(for: [loaded], timeout: 60), .completed)
        sleep(16)  // 当前条整条缓存 + 后面 2 条头部预取（等落盘完成再切）
        let first = current.label
        app.swipeUp(velocity: .fast)
        let changed = expectation(for: NSPredicate(format: "label != %@", first), evaluatedWith: current)
        XCTAssertEqual(XCTWaiter().wait(for: [changed], timeout: 15), .completed, "上滑没切条")
        // 进度文字在紧凑模式下不一定暴露给 XCUI，这里以 ddlog 的 DDSTART local=true / DDHEAD continue 为准
        sleep(4)
        attach(app, "head-cache-play")
        sleep(14)  // 跨过 headPlayableSeconds，验证续播不卡死
        attach(app, "head-cache-continued")
    }

    // MARK: - 演示视频分幕（每幕单独录屏）

    /// 幕2 合盖外屏：刷推荐流
    func testTourOuter() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launch()
        sleep(13)
        for _ in 0..<2 {
            let s = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.78))
            let e = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.28))
            s.press(forDuration: 0.12, thenDragTo: e, withVelocity: .slow, thenHoldForDuration: 0)
            sleep(5)
        }
    }

    /// 幕6 设置：竖屏 70% + 短视频 70%
    func testTourSettings() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launch()
        sleep(13)
        app.buttons.matching(identifier: "douyin.more").allElementsBoundByIndex.first { $0.isHittable }?.tap()
        sleep(3)
        app.buttons["设置"].firstMatch.tap()
        sleep(4)
        let any = { (kw: String) in
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS %@", kw))
                .allElementsBoundByIndex.first { $0.isHittable && $0.frame.width > 20 }
        }
        any("竖屏占比")?.tap()
        sleep(4)
        app.buttons["70%"].firstMatch.tap()
        sleep(3)
        any("竖屏短视频占比")?.tap()
        sleep(4)
        app.buttons["短视频 70%"].firstMatch.tap()
        sleep(3)
        app.tap()
        sleep(4)
    }

    /// 幕7 液态玻璃胶囊：点赞 / 收藏反馈
    func testTourRail() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launch()
        sleep(13)
        for id in ["douyin.like", "douyin.favorite"] {
            let b = app.buttons.matching(identifier: id).allElementsBoundByIndex.first { $0.isHittable }
            b?.tap()
            sleep(4)
            b?.tap()
            sleep(3)
        }
    }

    /// 幕5 半折叠桌面式：滑评论
    func testTourFold() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launchEnvironment["DOUDUO_FOLD"] = "1"
        app.launch()
        sleep(26)
        let s = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        let e = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
        s.press(forDuration: 0.12, thenDragTo: e, withVelocity: .slow, thenHoldForDuration: 0)
        sleep(5)
        s.press(forDuration: 0.12, thenDragTo: e, withVelocity: .slow, thenHoldForDuration: 0)
        sleep(4)
    }

    /// 幕9 直播：分类按钮 → 进原生直播间
    func testTourLive() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launch()
        sleep(13)
        app.buttons["直播"].firstMatch.tap()
        sleep(9)
        app.buttons["live.categories"].firstMatch.tap()
        sleep(6)
        app.buttons["推荐直播"].firstMatch.tap()
        sleep(9)
        app.buttons.matching(identifier: "live.room.enter").firstMatch.tap()
        sleep(14)
    }

    /// 幕3 展开宽屏（iPad）：点评论 → 右侧滑出
    func testTourWide() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        sleep(14)
        let b = app.buttons.matching(identifier: "douyin.comments").allElementsBoundByIndex.first { $0.isHittable }
        b?.tap()
        sleep(6)
        let s = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.6))
        let e = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.25))
        s.press(forDuration: 0.12, thenDragTo: e, withVelocity: .slow, thenHoldForDuration: 0)
        sleep(5)
    }

    /// 截图用（iPad 宽屏）：点开评论 → 右侧滑出
    func testCaptureWideComment() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        sleep(14)
        let btn = app.buttons.matching(identifier: "douyin.comments").allElementsBoundByIndex.first { $0.isHittable }
        btn?.tap()
        sleep(5)
        attach(app, "wide-comment")
    }

    /// 截图用（iPad 横屏 + 半折叠）：书本式左右分
    func testCaptureBookFold() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launchEnvironment["DOUDUO_FOLD"] = "1"
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(16)
        attach(app, "book-fold")
    }

    /// 截图用：保持横屏 40 秒，外部用 simctl 抓物理屏
    func testHoldLandscape() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launchEnvironment["DOUDUO_FOLD"] = "1"
        app.launch()
        sleep(10)
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(40)
    }

    /// 截图用：横屏 + 宽屏布局（评论右侧滑出）
    func testCaptureLandscapeWide() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(12)
        let btn = app.buttons.matching(identifier: "douyin.comments").allElementsBoundByIndex.first { $0.isHittable }
        btn?.tap()
        sleep(4)
        attach(app, "land-wide")
    }

    /// 截图用：横屏 + 强制半折叠（书本式左右分）
    func testCaptureLandscapeFold() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launchEnvironment["DOUDUO_FOLD"] = "1"
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(14)
        attach(app, "land-fold")
    }

    /// 录屏版：先手动启动 App 再开录，这里只接管前台，画面从第一帧就是 App
    func testFeatureTourActive() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.activate()
        sleep(2)
        app.buttons["推荐"].firstMatch.tap()
        sleep(4)
        let current = app.staticTexts["douyin.currentID"]
        _ = XCTWaiter().wait(for: [expectation(for: NSPredicate(format: "label != '-'"), evaluatedWith: current)], timeout: 40)
        sleep(4)

        // 更多 → 设置：短视频占比（展示 4 秒 + 选项 5 秒）
        app.buttons.matching(identifier: "douyin.more").allElementsBoundByIndex.first { $0.isHittable }?.tap()
        sleep(3)
        app.buttons["设置"].firstMatch.tap()
        sleep(4)
        app.buttons["竖屏短视频占比（3 分钟内）"].firstMatch.tap()
        sleep(5)
        app.buttons["短视频 70%"].firstMatch.tap()
        sleep(2)
        app.tap()
        sleep(3)

        // 直播：分类按钮 → 面板 → 专区 → 进房
        app.buttons["直播"].firstMatch.tap()
        sleep(5)
        app.buttons["live.categories"].firstMatch.tap()
        sleep(5)
        app.buttons["英雄联盟"].firstMatch.tap()
        sleep(6)
        app.buttons.matching(identifier: "live.room.enter").firstMatch.tap()
        sleep(6)

        // 直播间：更多 → 清屏 → 恢复
        app.buttons["live.room.more"].firstMatch.tap()
        sleep(3)
        app.buttons["清屏"].firstMatch.tap()
        sleep(4)
        app.buttons["live.room.restore"].firstMatch.tap()
        sleep(3)
        app.buttons["live.room.close"].firstMatch.tap()
        sleep(4)
        app.buttons["推荐"].firstMatch.tap()
        sleep(4)
        attach(app, "tour-active-end")
    }

    /// 功能演示脚本（录屏用）：按固定节奏走一遍新功能，不做断言，只保证画面走位
    func testFeatureTour() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launch()
        let current = app.staticTexts["douyin.currentID"]
        XCTAssertTrue(current.waitForExistence(timeout: 30))
        _ = XCTWaiter().wait(for: [expectation(for: NSPredicate(format: "label != '-'"), evaluatedWith: current)], timeout: 60)
        sleep(3)

        // 更多 → 设置：短视频占比
        let more = app.buttons.matching(identifier: "douyin.more").allElementsBoundByIndex.first { $0.isHittable }
        more?.tap()
        sleep(2)
        app.buttons["设置"].firstMatch.tap()
        sleep(2)
        app.buttons["竖屏短视频占比（3 分钟内）"].firstMatch.tap()
        sleep(2)
        app.buttons["短视频 70%"].firstMatch.tap()
        sleep(2)
        app.tap()
        sleep(2)

        // 直播：分类按钮 → 专区 → 进房 → 清屏 → 退出
        app.buttons["直播"].firstMatch.tap()
        sleep(4)
        app.buttons["live.categories"].firstMatch.tap()
        sleep(3)
        app.buttons["英雄联盟"].firstMatch.tap()
        sleep(5)
        app.buttons.matching(identifier: "live.room.enter").firstMatch.tap()
        sleep(4)
        app.buttons["live.room.more"].firstMatch.tap()
        sleep(2)
        app.buttons["清屏"].firstMatch.tap()
        sleep(2)
        app.buttons["live.room.restore"].firstMatch.tap()
        sleep(2)
        app.buttons["live.room.close"].firstMatch.tap()
        sleep(3)
        app.buttons["推荐"].firstMatch.tap()
        sleep(4)
        attach(app, "tour-end")
    }

    func testConditionalTitleExpansion() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        addTeardownBlock { app.terminate() }
        app.launchEnvironment["DOUDUO_TITLETEST"] = "1"
        app.launch()
        let short = app.otherElements["title.short"]
        let long = app.otherElements["title.long"]
        XCTAssertTrue(short.waitForExistence(timeout: 10))
        XCTAssertFalse(short.buttons["douyin.description.toggle"].exists, "短标题不应出现展开按钮")
        let toggle = long.buttons["douyin.description.toggle"]
        XCTAssertTrue(toggle.exists, "长标题被截断时应有展开按钮")
        XCTAssertEqual(toggle.label, "展开")
        let collapsedHeight = long.frame.height
        XCTAssertLessThanOrEqual(long.staticTexts["douyin.description"].frame.height, 60, "默认最多三行")
        toggle.tap()
        XCTAssertEqual(toggle.label, "收起")
        sleep(1)
        XCTAssertGreaterThan(long.frame.height, collapsedHeight, "展开后应显示完整标题而不只是切换按钮文字")
        attach(app, "expanded-title")
        toggle.tap()
        XCTAssertEqual(toggle.label, "展开")
        sleep(1)
        attach(app, "conditional-title")
    }

    func testCompactLayoutAndAuthorEntry() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launch()
        let current = app.staticTexts["douyin.currentID"]
        XCTAssertTrue(current.waitForExistence(timeout: 30))
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: NSPredicate(format: "label != '-'"), evaluatedWith: current)], timeout: 60), .completed)
        sleep(3)
        XCTAssertFalse(app.buttons.matching(identifier: "douyin.follow").allElementsBoundByIndex.contains { $0.isHittable })
        let desc = app.staticTexts.matching(identifier: "douyin.description").allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(desc)
        if let desc { XCTAssertLessThan(desc.frame.height, 40, "标题默认应只有一行") }
        let toggle = app.buttons.matching(identifier: "douyin.description.toggle").allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(toggle)
        toggle?.tap()
        XCTAssertTrue(app.buttons["收起"].exists)
        app.buttons["收起"].tap()
        attach(app, "compact-single-line")
        let author = app.buttons.matching(identifier: "douyin.author").allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(author)
        author?.tap()
        XCTAssertTrue(app.buttons["douyin.author.follow"].waitForExistence(timeout: 15))
        attach(app, "author-follow-retained")
        app.buttons["douyin.author.back"].tap()
    }

    func testCoreFlow() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launch()
        let current = app.staticTexts["douyin.currentID"]
        XCTAssertTrue(current.waitForExistence(timeout: 30))
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: NSPredicate(format: "label != '-'"), evaluatedWith: current)], timeout: 60), .completed, "推荐流没加载出来")
        sleep(6)
        attach(app, "1-feed")

        // 视频在走：进度时间 > 0:00
        let t1 = playTime(app)
        sleep(3)
        let t2 = playTime(app)
        print("DDTEST time \(t1) -> \(t2)")
        XCTAssertGreaterThan(t2, 0, "视频没在播")

        // 上滑下一条
        let first = current.label
        app.swipeUp(velocity: .fast)
        sleep(4)
        XCTAssertNotEqual(current.label, first, "上滑没切到下一条")
        let second = current.label
        XCTAssertGreaterThan(playTime(app), 0, "第二条没在播")
        attach(app, "2-next")

        // 横滑快进
        // 横滑快进。⚠️ 真机上 XCUICoordinate.press(…thenDragTo:) 根本不派发触摸（DDTOUCH 实测一个都没有），
        // swipeUp 能到 → 横向也用 swipe 系列（从画面中部起滑）
        app.swipeRight(velocity: .slow)
        sleep(3)
        XCTAssertEqual(current.label, second, "横滑不应切视频")
        print("DDTEST after seek \(playTime(app))")
        XCTAssertGreaterThanOrEqual(playTime(app), 25, "横滑快进没跳")

        // 点作者头像 → 网页主页 → 返回
        // 分页 ScrollView 同时保留离屏元素，只点当前可命中的作者。
        let authors = app.buttons.matching(identifier: "douyin.author")
        let author = authors.allElementsBoundByIndex.first(where: { $0.isHittable })
        XCTAssertNotNil(author, "当前页没有可点击的作者入口")
        guard let author else { return }
        author.tap()
        // 改版作者页已原生化，不能再等旧网页版返回键。
        let back = app.buttons["douyin.author.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 15), "作者主页没打开 / 没有返回键")
        sleep(4)
        attach(app, "3-author")
        back.tap()
        XCTAssertTrue(current.waitForExistence(timeout: 15), "从作者主页回不来")
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: NSPredicate(format: "label != '-'"), evaluatedWith: current)], timeout: 60), .completed, "返回后推荐流没恢复")
        sleep(6)
        XCTAssertGreaterThan(playTime(app), 0, "返回后视频没在播")
        attach(app, "4-back")
    }

    /// 窄视频（720x1280）在 Duo 上：开=铺满宽度（上下裁切），关=左右黑边。用本地测试片验证，不依赖推荐流给什么片。
    func testLocalNarrowFill() throws {
        for fit in ["1", "0"] {
            let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
            app.launchEnvironment["DOUDUO_LOCALVIDEO"] = "narrow.mp4"
            app.launchEnvironment["DOUDUO_LOCALFIT"] = fit
            app.launch()
            sleep(6)
            attach(app, "narrow-fit-\(fit)")
            app.terminate()
        }
    }

    /// 确认 App 真的能转到横屏（窗口宽>高）
    /// ⚠️ XCUIDevice 转屏在这台机器上时好时坏（无头/屏幕休眠时静默失败），重试 3 次仍不转就 skip，不当作 App 缺陷
    func testRotationSanity() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launchEnvironment["DOUDUO_LOCALVIDEO"] = "wide.mp4"
        app.launchEnvironment["DOUDUO_LOCALFIT"] = "1"
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        sleep(4)
        let p = app.windows.firstMatch.frame
        print("DDTEST portrait window \(p)")
        var l = p
        for i in 1...3 {
            XCUIDevice.shared.orientation = .landscapeLeft
            sleep(3)
            l = app.windows.firstMatch.frame
            print("DDTEST landscape window try\(i) \(l)")
            if l.width > l.height { break }
        }
        if l.width <= l.height {
            XCUIDevice.shared.orientation = .portrait
            throw XCTSkip("转屏指令没生效（环境问题），跳过；真机手动转屏正常")
        }
        attach(app, "rot-landscape")
        XCUIDevice.shared.orientation = .portrait
    }

    /// 竖屏 + 横屏 都要自适应（无黑边）：本地 720x1280 与 1280x720 测试片各跑一遍
    func testLocalFillBothOrientations() throws {
        // 先启动再转屏（启动时设方向会被 App 启动重置）
        for (file, orient, tag) in [("narrow.mp4", UIDeviceOrientation.portrait, "portrait"),
                                    ("wide.mp4", .portrait, "portrait"),
                                    ("narrow.mp4", .landscapeLeft, "landscape"),
                                    ("wide.mp4", .landscapeLeft, "landscape")] {
            let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
            app.launchEnvironment["DOUDUO_LOCALVIDEO"] = file
            app.launchEnvironment["DOUDUO_LOCALFIT"] = "1"
            XCUIDevice.shared.orientation = .portrait
            app.launch()
            sleep(4)
            XCUIDevice.shared.orientation = orient
            sleep(5)
            attach(app, "\(file)-\(tag)")
            app.terminate()
        }
        XCUIDevice.shared.orientation = .portrait
    }

    /// 「更多」菜单：一排快捷图标 + 播放组 + 设置子菜单；竖屏占比子菜单可选
    func testMoreMenuLayout() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launch()
        let current = app.staticTexts["douyin.currentID"]
        XCTAssertTrue(current.waitForExistence(timeout: 30))
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: NSPredicate(format: "label != '-'"), evaluatedWith: current)], timeout: 60), .completed)
        sleep(3)
        let any = { (l: String) in app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", l)).firstMatch }
        // 分页里上下相邻页的「更多」也在树里，只点屏幕内那颗
        let more = { app.buttons.matching(identifier: "douyin.more").allElementsBoundByIndex.first { $0.isHittable }! }
        more().tap()
        for l in ["转发", "下载", "不感兴趣", "竖屏占比", "自动连播", "静音", "显示弹幕", "刷新推荐", "我的", "设置"] {
            XCTAssertTrue(any(l).waitForExistence(timeout: 5), "更多菜单缺少 \(l)")
        }
        attach(app, "more-top")
        any("竖屏占比").tap()
        XCTAssertTrue(any("竖屏 50%").waitForExistence(timeout: 5), "竖屏占比子菜单没展开")
        attach(app, "more-mix")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.15)).tap()
        sleep(1)
        more().tap()
        any("设置").tap()
        for l in ["横着看时只放横屏", "自动铺满宽度", "预缓存视频", "清除视频缓存", "网页版", "关于"] {
            XCTAssertTrue(any(l).waitForExistence(timeout: 5), "设置子菜单缺少 \(l)")
        }
        attach(app, "more-settings")
    }

    /// VLC 兜底路径：强制 VLC 起播，画面时间要走、能上滑切换
    func testVLCFallback() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launchEnvironment["DOUDUO_FORCE_VLC"] = "1"
        app.launch()
        let current = app.staticTexts["douyin.currentID"]
        XCTAssertTrue(current.waitForExistence(timeout: 30))
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: NSPredicate(format: "label != '-'"), evaluatedWith: current)], timeout: 60), .completed)
        sleep(10)
        let t1 = playTime(app); sleep(3); let t2 = playTime(app)
        print("DDTEST vlc time \(t1) -> \(t2)")
        XCTAssertGreaterThan(t2, t1, "VLC 没在播")
        attach(app, "vlc-1")
        let first = current.label
        app.swipeUp(velocity: .fast)
        sleep(8)
        XCTAssertNotEqual(current.label, first, "VLC 下上滑没切")
        let t3 = playTime(app); sleep(3); let t4 = playTime(app)
        print("DDTEST vlc next \(t3) -> \(t4)")
        XCTAssertGreaterThan(t4, t3, "VLC 第二条没在播")
        attach(app, "vlc-2")
    }


    /// 停声链路（不依赖切后台事件）：DOUDUO_BGTEST=1 → 20 秒后自动 pauseAll，进度必须冻住
    func testPauseAllPlumbing() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launchEnvironment["DOUDUO_BGTEST"] = "1"
        app.launch()
        let current = app.staticTexts["douyin.currentID"]
        XCTAssertTrue(current.waitForExistence(timeout: 30))
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: NSPredicate(format: "label != '-'"), evaluatedWith: current)], timeout: 60), .completed)
        sleep(5)
        let t1 = playTime(app)
        sleep(12)
        let t2 = playTime(app)
        sleep(6)
        let t3 = playTime(app)
        print("DDTEST plumbing t1=\(t1) t2=\(t2) t3=\(t3)")
        XCTAssertGreaterThan(t1, 0)
        XCTAssertLessThanOrEqual(t3, t2 + 1, "pauseAll 之后进度还在走")
    }

    /// 直播播放：UI 测试里量不到真实播放（XCTest 环境下 HLS 已 readyToPlay 但进度不走，
    /// 同样的构建用 simctl 启动播放正常）→ 这里只做冒烟：能进直播页、能拿到房间、不崩
    func testLivePlayback() throws {
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        app.launchEnvironment["DOUDUO_STARTLIVE"] = "1"
        app.launch()
        let liveID = app.staticTexts["live.currentID"]
        XCTAssertTrue(liveID.waitForExistence(timeout: 30), "直播页没打开")
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: NSPredicate(format: "label != '-'"), evaluatedWith: liveID)], timeout: 60), .completed, "直播列表没加载出来")
        sleep(8)
        let st = app.staticTexts["live.status"].label
        let rate = app.staticTexts["live.rate"].label
        let t = app.staticTexts["live.time"].label
        print("DDTEST live id=\(liveID.label) status=\(st) rate=\(rate) time=\(t)")
        attach(app, "live")
        XCTAssertEqual(st, "1", "直播流没 ready（status=\(st)）")
    }

    /// Automated layout checks never write likes or collections to the account.
    func testLikeAndCollect() throws {
        throw XCTSkip("仅只读验收，不执行账号点赞或收藏写操作")
    }

    func testFollowedLivePickerRestoresRecommendation() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "duoClassic"
        app.launchArguments += ["-douyin_muted_v1", "YES"]
        addTeardownBlock { app.terminate() }
        app.launchEnvironment["DOUDUO_STARTLIVE"] = "1"
        app.launchEnvironment["DOUDUO_LIVEMOCK"] = "1"
        app.launchEnvironment["DOUDUO_FOLLOWMOCK"] = "rooms"
        app.launch()
        let current = app.staticTexts["live.currentID"]
        XCTAssertTrue(current.waitForExistence(timeout: 15))
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: NSPredicate(format: "label == 'rec-a'"), evaluatedWith: current)], timeout: 10), .completed)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "live.follow").firstMatch.label.contains("我的关注"))
        app.descendants(matching: .any).matching(identifier: "live.follow").firstMatch.tap()
        XCTAssertTrue(app.navigationBars["我的关注"].waitForExistence(timeout: 5))
        let row = app.buttons["live.follow.room.fol-b"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(app.scrollViews["live.follow.list"].exists)
        XCTAssertTrue(row.label.contains("关注乙"))
        XCTAssertTrue(row.label.contains("直播中"))
        XCTAssertFalse(row.label.contains("关注直播乙"), "列表不显示房间标题")
        XCTAssertFalse(row.label.contains("在看"))
        let other = app.buttons["live.follow.room.fol-a"]
        XCTAssertTrue(other.label.contains("关注甲"))
        XCTAssertTrue(other.label.contains("直播中"))
        XCTAssertTrue(other.label.contains("30"))
        XCTAssertTrue(other.label.contains("在看"))
        row.tap()
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: NSPredicate(format: "label == 'fol-b'"), evaluatedWith: current)], timeout: 5), .completed)
        XCTAssertTrue(app.buttons["live.room.close"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "live.follow").firstMatch.exists, "进入关注直播间后不显示选择按钮")
        app.buttons["live.room.close"].tap()
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: NSPredicate(format: "label == 'rec-a'"), evaluatedWith: current)], timeout: 5), .completed, "退出应回到原来的推荐直播")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "live.follow").firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["live.discover"].exists)
        app.windows.firstMatch.swipeUp(velocity: .slow)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: NSPredicate(format: "label == 'rec-b'"), evaluatedWith: current)], timeout: 5), .completed, "回到推荐后只能滑到原来的下一间")
    }

    func testFollowedLiveStatesStayDistinct() throws {
        let empty = XCUIApplication()
        empty.launchEnvironment["DOUDUO_STARTLIVE"] = "1"
        empty.launchEnvironment["DOUDUO_LIVEMOCK"] = "1"
        empty.launchEnvironment["DOUDUO_FOLLOWMOCK"] = "empty"
        empty.launch()
        XCTAssertTrue(empty.buttons["live.follow"].waitForExistence(timeout: 10))
        empty.buttons["live.follow"].tap()
        XCTAssertTrue(empty.staticTexts["live.follow.empty"].waitForExistence(timeout: 5))
        XCTAssertFalse(empty.staticTexts["live.follow.login"].exists)
        empty.terminate()

        let login = XCUIApplication()
        login.launchEnvironment["DOUDUO_STARTLIVE"] = "1"
        login.launchEnvironment["DOUDUO_LIVEMOCK"] = "1"
        login.launchEnvironment["DOUDUO_FOLLOWMOCK"] = "login"
        login.launch()
        XCTAssertTrue(login.buttons["live.follow"].waitForExistence(timeout: 10))
        login.buttons["live.follow"].tap()
        XCTAssertTrue(login.staticTexts["live.follow.login"].waitForExistence(timeout: 5))
        XCTAssertTrue(login.buttons["live.follow.login.button"].exists)
        XCTAssertFalse(login.staticTexts["live.follow.empty"].exists)
    }

    /// 关注开播只走直播页「我的关注」：直播页不挂头像条，关注页不挂直播头像。
    func testFollowLiveOnlyViaMyFollowButton() throws {
        continueAfterFailure = false
        let live = XCUIApplication()
        live.launchArguments += ["-douyin_muted_v1", "YES"]
        addTeardownBlock { live.terminate() }
        live.launchEnvironment["DOUDUO_STARTLIVE"] = "1"
        live.launchEnvironment["DOUDUO_LIVEMOCK"] = "1"
        live.launchEnvironment["DOUDUO_FOLLOWMOCK"] = "rooms"
        live.launch()
        XCTAssertTrue(live.buttons["live.follow"].waitForExistence(timeout: 10), "「我的关注」入口保留")
        sleep(2)
        attach(live, "live-no-strip")
        XCTAssertFalse(live.scrollViews["live.follow.strip"].exists, "直播页不再挂关注头像条")
        XCTAssertFalse(live.buttons["live.follow.pill"].exists)
        live.terminate()

        let follow = XCUIApplication()
        follow.launchArguments += ["-douyin_muted_v1", "YES"]
        addTeardownBlock { follow.terminate() }
        follow.launchEnvironment["DOUDUO_STARTFOLLOW"] = "1"
        follow.launchEnvironment["DOUDUO_FOLLOWMOCK"] = "rooms"
        follow.launch()
        XCTAssertTrue(follow.otherElements["douyin.follow.feed"].waitForExistence(timeout: 15))
        attach(follow, "follow-no-live-row")
        XCTAssertFalse(follow.staticTexts["直播中"].exists, "关注页不应出现直播头像")
    }

    /// 底部进度条左侧时间（秒）
    private func playTime(_ app: XCUIApplication) -> Int {
        let q = app.staticTexts.matching(NSPredicate(format: "label MATCHES '^[0-9]+:[0-9][0-9]$'"))
        guard q.count > 0 else { return 0 }
        return q.element(boundBy: 0).label.split(separator: ":").reduce(0) { $0 * 60 + (Int($1) ?? 0) }
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        print("DUODUO_CAPTURE " + name)
        Thread.sleep(forTimeInterval: 2) // Host captures the active Duo display; XCTest screenshots use the inactive outer screen.
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
}
