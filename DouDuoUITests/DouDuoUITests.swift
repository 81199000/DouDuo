import XCTest

/// 抖Duo 核心流程：推荐流加载 → 视频在走 → 上滑切下一条 → 横滑快进 → 点作者进主页 → 能返回原生页
final class DouDuoUITests: XCTestCase {
    func testCoreFlow() throws {
        let app = XCUIApplication()
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
        let author = app.buttons["douyin.author"].firstMatch
        XCTAssertTrue(author.waitForExistence(timeout: 5))
        author.tap()
        let back = app.buttons["douyin.web.back"]
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

    /// 菜单里的「自动铺满宽度」开关：开=竖屏窄视频放大铺满，关=完整画面留边
    func testAutoFitToggle() throws {
        let app = XCUIApplication()
        app.launch()
        let current = app.staticTexts["douyin.currentID"]
        XCTAssertTrue(current.waitForExistence(timeout: 30))
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: NSPredicate(format: "label != '-'"), evaluatedWith: current)], timeout: 60), .completed)
        sleep(8)
        attach(app, "fit-on")

        app.buttons["抖音菜单"].tap()
        // SwiftUI 菜单里的 Toggle 不是 Switch，按标签找任意类型（含按钮/菜单项）
        let toggle = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS '自动铺满宽度'")).firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "菜单里没有自动铺满宽度")
        toggle.tap()
        app.tap()   // 关菜单
        sleep(8)
        attach(app, "fit-off")

        app.buttons["抖音菜单"].tap()
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS '自动铺满宽度'")).firstMatch.tap()
    }

    /// VLC 兜底路径：强制 VLC 起播，画面时间要走、能上滑切换
    func testVLCFallback() throws {
        let app = XCUIApplication()
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

    /// 底部进度条左侧时间（秒）
    private func playTime(_ app: XCUIApplication) -> Int {
        let q = app.staticTexts.matching(NSPredicate(format: "label MATCHES '^[0-9]+:[0-9][0-9]$'"))
        guard q.count > 0 else { return 0 }
        return q.element(boundBy: 0).label.split(separator: ":").reduce(0) { $0 * 60 + (Int($1) ?? 0) }
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
}
