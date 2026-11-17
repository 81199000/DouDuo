import XCTest

final class DYShareLinkTests: XCTestCase {
    func testLongVideoLink() {
        XCTAssertEqual(DYShareLink.target(in: "https://www.douyin.com/video/7705001843541851839"), .video("7705001843541851839"))
    }

    func testDouyinAppShareText() {
        let text = "8.97 复制打开抖音，看看【某某的作品】今天的风景 # 旅行 https://v.douyin.com/iRNBho6u/ CuF:/ 08/03 a@n.QX"
        XCTAssertEqual(DYShareLink.target(in: text), .short(URL(string: "https://v.douyin.com/iRNBho6u/")!))
    }

    func testIesShareRedirectTarget() {
        let url = URL(string: "https://www.iesdouyin.com/share/video/7298145681699622182/?region=CN&mid=1&from=web_code_link")!
        XCTAssertEqual(DYShareLink.videoID(in: url), "7298145681699622182")
    }

    func testModalID() {
        XCTAssertEqual(DYShareLink.target(in: "https://www.douyin.com/jingxuan?modal_id=7705001843541851839"), .video("7705001843541851839"))
    }

    func testNoteLink() {
        XCTAssertEqual(DYShareLink.target(in: "看这个 https://www.douyin.com/note/7705001843541851839 好看"), .video("7705001843541851839"))
    }

    func testIgnoresOtherLinks() {
        XCTAssertNil(DYShareLink.target(in: "https://www.douyin.com/user/MS4wLjABAAAA"))
        XCTAssertNil(DYShareLink.target(in: "https://example.com/video/7705001843541851839"))
        XCTAssertNil(DYShareLink.target(in: "没有链接的文字"))
    }

    func testShareTextRoundTrips() {
        let text = "今天的风景 # 旅行 https://www.douyin.com/video/7705001843541851839 复制此链接，打开抖音搜索，直接观看视频！"
        XCTAssertEqual(DYShareLink.target(in: text), .video("7705001843541851839"))
    }
}
