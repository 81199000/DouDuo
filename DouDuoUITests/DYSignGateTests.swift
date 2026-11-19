import XCTest

/// 签名没完成前点发送：立刻提示「等待签名完成才可以发送评论」，不发、不出本地行、草稿还在；签名完成后提示消失
final class DYSignGateTests: XCTestCase {
    func testSendBlockedUntilSigningCompletes() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DOUDUO_CHROME_MODE"] = "rail"
        app.launchEnvironment["DOUDUO_HASHTAG_FIXTURE"] = "1"
        app.launchEnvironment["DOUDUO_SIGN_DELAY"] = "25"
        app.launchArguments += ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO",
                                "-douduo_dismissed_update_v1", "9.9.9", "-duoduomain_tab_v1", "首页"]
        app.launch()
        let cur = app.staticTexts["douyin.currentID"].firstMatch
        XCTAssertTrue(cur.waitForExistence(timeout: 20))
        let loaded = expectation(for: NSPredicate(format: "label == %@", "hashtag-cat"), evaluatedWith: cur)
        wait(for: [loaded], timeout: 20)
        let button = app.buttons.matching(identifier: "douyin.comments").allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(button, "找不到评论按钮")
        button?.tap()
        let input = app.descendants(matching: .any).matching(identifier: "douyin.comment.input").firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap()
        input.typeText("签名测试草稿")
        let send = app.descendants(matching: .any).matching(identifier: "douyin.comment.send").firstMatch
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        send.tap()
        let hint = app.staticTexts["douyin.comment.sendErr"].firstMatch
        XCTAssertTrue(hint.waitForExistence(timeout: 3), "点发送后应立刻提示")
        XCTAssertEqual(hint.label, "等待签名完成才可以发送评论")
        let draftValue = (input.value as? String) ?? ""
        print("PROBE draft-after-blocked=\(draftValue.contains("签名测试草稿") ? "kept" : "lost:" + draftValue)")
        XCTAssertTrue(draftValue.contains("签名测试草稿"), "草稿应保留")
        XCTAssertFalse(app.staticTexts["签名测试草稿"].exists, "不应出现本地评论行")
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "sign-gate-blocked"; shot.lifetime = .keepAlways; add(shot)
        // 签名完成后提示自动消失
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: hint)
        waitForExpectations(timeout: 40)
        print("PROBE hint-cleared-after-sign=1")
        app.terminate()
    }
}
