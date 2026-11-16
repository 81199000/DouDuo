import XCTest

/// 关注 / 粉丝列表翻页回归：验证列表能一路往下拉，越过首屏（17~20 条）拿到更多页。
/// 这两个接口的分页口径不同（粉丝靠 max_time、关注靠 offset），只看「首屏能显示」不够，
/// 必须真的滑到底触发第二次 loadMore，并确认条数增长。
final class DYRelationsPagingTests: XCTestCase {
    func testFollowersLoadsMoreThanFirstPage() throws { try verifyPaging(kind: "followers") }
    func testFollowingLoadsMoreThanFirstPage() throws { try verifyPaging(kind: "following") }

    private func verifyPaging(kind: String) throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        addTeardownBlock { app.terminate() }
        app.launchEnvironment = ["DOUDUO_RELATIONS_PROBE": kind]
        app.launchArguments = ["-douyin_muted_v1", "YES", "-douyin_autoplay_v1", "NO"]
        app.launch()

        let rows = app.buttons.matching(identifier: "douyin.relations.row")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 40), "列表首屏没加载出来")
        let firstPage = rows.count
        XCTAssertGreaterThan(firstPage, 0, "首屏为空")
        attach(app, "relations-\(kind)-first")

        // 反复上滑直到行数不再增长（最多 12 次），模拟用户一直往下翻
        var last = firstPage
        var grew = false
        for _ in 0..<12 {
            app.swipeUp(velocity: .fast)
            _ = rows.firstMatch.waitForExistence(timeout: 2)
            // 给下一页请求留时间（抖音接口约 0.3–1s）
            Thread.sleep(forTimeInterval: 1.5)
            let now = rows.count
            if now > last { grew = true; last = now }
        }
        attach(app, "relations-\(kind)-after")
        XCTAssertTrue(grew, "\(kind) 列表只停留在首屏 \(firstPage) 条，翻页没生效（这是老板报的「只能显示 20 个人」）")
        XCTAssertGreaterThan(last, firstPage, "\(kind) 翻页后条数没有增加")
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
