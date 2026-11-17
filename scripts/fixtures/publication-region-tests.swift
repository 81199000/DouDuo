import Foundation

final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 2_000_000_000)
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: Double) { lock.lock(); defer { lock.unlock() }; value += seconds }
}
final class RegionProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var count = 0, active = 0, peak = 0
    static func snapshot() -> (Int, Int) { lock.lock(); defer { lock.unlock() }; return (count, peak) }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.count += 1; Self.active += 1; Self.peak = max(Self.peak, Self.active); Self.lock.unlock()
        let id = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first!.value!
        precondition(request.url!.host == "aweme.snssdk.com" && request.url!.scheme == "https")
        precondition(request.value(forHTTPHeaderField: "Cookie") == nil && request.value(forHTTPHeaderField: "Authorization") == nil)
        Thread.sleep(forTimeInterval: 0.02)
        var data = Data("{\"status_code\":0,\"aweme_list\":[{\"aweme_id\":\"\(id)\",\"city\":\"440300\",\"region\":\"CN\"}]}".utf8)
        var headers = ["Content-Type": "application/json"]
        if id == "3" { data = Data("{\"status_code\":0,\"aweme_list\":[{\"aweme_id\":\"999\",\"city\":\"440300\"}]}".utf8) }
        if id == "7" { data = Data("{\"status_code\":0,\"aweme_list\":[{\"aweme_id\":\"7\",\"city\":\"0\",\"region\":\"\"}]}".utf8) }
        if id == "8" { headers["Content-Length"] = "3000000" }
        if id == "9" { data = Data(repeating: 32, count: 2_000_001) }
        Self.lock.lock(); Self.active -= 1; Self.lock.unlock()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@main struct RegionTests {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message); print("PASS " + message)
    }
    static func main() async throws {
        let tableURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let names = try JSONDecoder().decode([String:String].self, from: Data(contentsOf: tableURL))
        check(DYPublicationRegion.name(for: "440300") == "广东·深圳市", "bundled resource loads")
        check(names.count > 3000, "bundled table has domestic coverage")
        for (code, expected) in [("440300", "广东·深圳市"), ("110101", "北京市"), ("710000", "台湾"), ("810000", "香港特别行政区")] {
            check(DYPublicationRegion.name(for: code, country: nil, names: names) == expected, "maps " + code)
        }
        for (code, country) in [("0", ""), ("000000", "CN"), ("2197820", "FJ"), ("1859171", "JP"), ("440300", "US"), ("４４０３００", "CN"), ("999999", "CN"), (" 440300", "CN")] {
            check(DYPublicationRegion.name(for: code, country: country, names: names) == nil, "rejects " + code + "/" + country)
        }
        check(DYPublicationRegion.metadata("刚刚发布 · AI 声明", place: nil, resolved: false) == "刚刚发布 · AI 声明", "pending metadata preserves upstream text")
        check(DYPublicationRegion.metadata(nil, place: nil, resolved: false) == nil, "pending missing metadata stays hidden")
        check(DYPublicationRegion.metadata("刚刚发布 · AI 声明", place: nil) == "刚刚发布 · AI 声明 · 发布地：未知", "preserves original time and declaration")
        check(DYPublicationRegion.metadata(nil, place: "广东·深圳市") == "发布地：广东·深圳市", "region without timestamp")
        check(DYPublicationRegion.metadata("刚刚发布", place: nil, resolved: false) == "刚刚发布", "pending lookup never flashes unknown")
        check(DYPublicationRegion.metadata(nil, place: nil, resolved: false) == nil, "pending lookup adds no empty row")
        check(DYPublicationRegion.metadata(nil, place: "广东·深圳市", resolved: false) == "发布地：广东·深圳市", "existing region appears immediately")
        let decode = DYPublicationRegionClient.decode
        func response(_ work: String, status: Int = 0) -> Data { Data("{\"status_code\":\(status),\"aweme_list\":[\(work)]}".utf8) }
        check(decode(response("{\"aweme_id\":123,\"city\":440300,\"region\":\"CN\"}"), "123").city == "440300", "numeric city and ID")
        check(!decode(response("{\"aweme_id\":\"124\",\"city\":\"440300\"}"), "123").validResponse, "never picks another work")
        check(!decode(response("{\"aweme_id\":\"123\"}", status: 1), "123").validResponse, "status failure")
        check(!decode(Data("<html>challenge</html>".utf8), "123").validResponse, "non JSON failure")
        check(!decode(Data(repeating: 32, count: 2_000_001), "123").validResponse, "oversized JSON rejected")
        let malformed = decode(response("{\"aweme_id\":\"123\",\"city\":\"440300\",\"region\":\"INVALID\"}"), "123")
        check(DYPublicationRegion.name(for: malformed.city, country: malformed.country, names: names) == nil, "malformed country fails closed")
        for id in ["", "1&other=2", "../123", "１２３", String(repeating: "1", count: 21)] {
            check(DYPublicationRegionClient.request(id) == nil, "invalid ID rejected: " + id)
        }
        let configuration = DYPublicationRegionClient.makeSession().configuration
        check(configuration.httpCookieStorage == nil && configuration.urlCredentialStorage == nil && configuration.urlCache == nil, "production session has no credentials or cache")
        check(!configuration.httpShouldSetCookies, "production session disables cookies")
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [RegionProtocol.self]
        let session = URLSession(configuration: config)
        let clock = Clock()
        let file = URL(fileURLWithPath: CommandLine.arguments[2])
        let client = DYPublicationRegionClient(session: session, fileURL: file, now: { clock.now() })
        let start = RegionProtocol.snapshot().0
        await withTaskGroup(of: DYPublicationRegionClient.Result.self) { group in
            for _ in 0..<12 { group.addTask { await client.lookup("1") } }
            for await result in group { check(result.city == "440300", "coalesced caller result") }
        }
        check(RegionProtocol.snapshot().0 == start + 1, "one request for twelve duplicate callers")
        _ = await client.lookup("1")
        check(RegionProtocol.snapshot().0 == start + 1, "memory cache hit")
        let restored = DYPublicationRegionClient(session: session, fileURL: file, now: { clock.now() })
        _ = await restored.lookup("1")
        check(RegionProtocol.snapshot().0 == start + 1, "disk cache hit")
        check(restored.cached("1")?.city == "440300", "disk snapshot is synchronous on first frame")
        check(client.cached("99999") == nil, "synchronous cache miss never guesses")
        await withTaskGroup(of: Void.self) { group in
            for id in 1000..<1012 { group.addTask { _ = await client.lookup(String(id)) } }
        }
        check(RegionProtocol.snapshot().1 <= 2, "at most two simultaneous requests and queue drains")
        let wrong = await client.lookup("3"); check(!wrong.validResponse, "transport wrong ID remains unknown")
        let beforeFailure = RegionProtocol.snapshot().0
        let cachedWrong = await client.lookup("3"); check(!cachedWrong.validResponse, "cached failure retains failure state")
        check(RegionProtocol.snapshot().0 == beforeFailure, "failure backoff hit")
        clock.advance(61); _ = await client.lookup("3")
        check(RegionProtocol.snapshot().0 == beforeFailure + 1, "failure retries after sixty seconds")
        _ = await client.lookup("7"); let unknownCount = RegionProtocol.snapshot().0
        clock.advance(299); _ = await client.lookup("7")
        check(RegionProtocol.snapshot().0 == unknownCount, "valid unknown backoff five minutes")
        clock.advance(2); _ = await client.lookup("7")
        check(RegionProtocol.snapshot().0 == unknownCount + 1, "valid unknown retries")
        let large = await client.lookup("8"); check(!large.validResponse, "transport oversized declared response rejected")
        let oversized = await client.lookup("9"); check(!oversized.validResponse, "streaming byte cap enforced without declared length")
        let beforeKnown = RegionProtocol.snapshot().0; clock.advance(3600); _ = await client.lookup("1")
        check(RegionProtocol.snapshot().0 == beforeKnown, "known region cached for longer than negative TTL")
        let cancel = Task { () -> DYPublicationRegionClient.Result in
            withUnsafeCurrentTask { $0?.cancel() }; return await client.lookup("9999")
        }
        let cancelled = await cancel.value; check(!cancelled.validResponse, "cancelled caller does not request")
        await client.prefetch(["710", "711", "712"])
        for _ in 0..<100 {
            if client.cached("710") != nil && client.cached("711") != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        check(client.cached("710")?.city == "440300" && client.cached("711")?.city == "440300", "two successors prepared before page activation")
        check(client.cached("712") == nil, "look-ahead limited to two works")
        let prewarmedCount = RegionProtocol.snapshot().0; _ = await client.lookup("710")
        check(RegionProtocol.snapshot().0 == prewarmedCount, "prepared successor does not repeat the request")
        await client.prefetch([])
        clock.advance(8 * 86400); check(client.cached("1") == nil, "expired synchronous snapshot hidden")
        let expiredCount = RegionProtocol.snapshot().0; _ = await client.lookup("1")
        check(RegionProtocol.snapshot().0 == expiredCount + 1, "known metadata expires within seven days")
        let corrupt = file.deletingLastPathComponent().appendingPathComponent("corrupt.json")
        try Data("broken".utf8).write(to: corrupt)
        let recovered = DYPublicationRegionClient(session: session, fileURL: corrupt)
        let result = await recovered.lookup("2"); check(result.city == "440300", "corrupt cache recovers")
        let seeded = file.deletingLastPathComponent().appendingPathComponent("bounded.json")
        let date = Date().timeIntervalSinceReferenceDate
        let rows = (1...520).map { ["id": String($0), "city": "0", "validResponse": true, "checkedAt": date, "retryAt": date + 300] as [String:Any] }
        try JSONSerialization.data(withJSONObject: rows).write(to: seeded)
        let bounded = DYPublicationRegionClient(session: session, fileURL: seeded)
        _ = await bounded.lookup("521")
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: seeded)) as! [Any]
        check(saved.count == 512, "persistent cache bounded to 512 entries")
        session.invalidateAndCancel()
        print("PASS publication region suite completed")
    }
}
