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
        let a = app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.45))
        let b = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.45))
        a.press(forDuration: 0.05, thenDragTo: b, withVelocity: .slow, thenHoldForDuration: 0.6)
        sleep(3)
        XCTAssertEqual(current.label, second, "横滑不应切视频")
        print("DDTEST after seek \(playTime(app))")
        XCTAssertGreaterThanOrEqual(playTime(app), 30, "横滑快进没跳")

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
