import XCTest

/// 聊天页右侧栏多一颗「更多」时，返回键不能被状态栏（时间/信号）挡住。
final class DYMessageRailProbeTests: XCTestCase {
    func testChatBackButtonClearsStatusBar() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        addTeardownBlock { app.terminate() }
        app.launchEnvironment = ["DOUDUO_MESSAGE_LAYOUT": "1", "DOUDUO_MESSAGE_FIXTURE": "1"]
        app.launchArguments = ["-douyin_chrome_mode_v1", "rail", "-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO"]
        app.launch()

        let rows = app.buttons.matching(identifier: "douyin.conversation.row")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 30), "会话列表没出来")
        rows.firstMatch.tap()
        let back = app.buttons["douyin.messages.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 10), "聊天页没有返回键")
        Thread.sleep(forTimeInterval: 2)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "chat-rail"; shot.lifetime = .keepAlways; add(shot)
        print("RAILTEST back=\(back.frame) hittable=\(back.isHittable)")
        XCTAssertTrue(back.isHittable, "返回键被挡住、点不到")
        back.tap()
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10), "点返回没回到列表")
    }
}
