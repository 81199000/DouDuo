import Foundation

/// Anonymous metadata lookup; never opens the media URLs in a response.
actor DYPublicationRegionClient {
    static let shared = DYPublicationRegionClient()
    static let maximumBytes = 2_000_000
    static let maximumEntries = 512
    private let session: URLSession
    private let fileURL: URL?
    private let now: @Sendable () -> Date
    private var entries: [String: Entry] = [:]
    private var pending: [String: Task<Result, Never>] = [:]
    private var warming: Task<Void, Never>?
    private var warmIDs: [String] = []
    private nonisolated let snapshot = Snapshot()

    // A read-only mirror of the actor cache avoids awaiting an actor after a page's first frame.
    // The actor remains the sole writer; readers never perform disk or network work.
    private final class Snapshot: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: (result: Result, retryAt: Date)] = [:]
        func replace(_ values: [String: (result: Result, retryAt: Date)]) {
            lock.lock(); self.values = values; lock.unlock()
        }
        func read(_ id: String, now: Date) -> Result? {
            lock.lock(); defer { lock.unlock() }
            guard let entry = values[id], entry.retryAt > now else { return nil }
            return entry.result
        }
    }

    struct Result: Equatable, Sendable {
        let city: String?
        let country: String?
        let validResponse: Bool
    }
    private struct Entry: Codable {
        let id: String
        let city: String?
        let country: String?
        let validResponse: Bool
        let checkedAt: Date
        let retryAt: Date
        var result: Result { .init(city: city, country: country, validResponse: validResponse) }
    }

    init(session: URLSession = DYPublicationRegionClient.makeSession(),
         fileURL: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("publication-regions-v1.json"),
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.session = session; self.fileURL = fileURL; self.now = now
        if let fileURL, let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size <= Self.maximumBytes, let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            for entry in saved.suffix(Self.maximumEntries) where Self.validID(entry.id) {
                entries[entry.id] = entry
            }
        }
        snapshot.replace(entries.mapValues { ($0.result, $0.retryAt) })
    }

    nonisolated func cached(_ id: String) -> Result? { snapshot.read(id, now: now()) }

    /// One short, replaceable look-ahead chain; quick paging drops stale queued IDs.
    func prefetch(_ ids: [String]) {
        let ids = Array(ids.filter(Self.validID).prefix(2))
        guard ids != warmIDs || ids.contains(where: { cached($0) == nil }) else { return }
        warming?.cancel(); warmIDs = ids
        warming = Task(priority: .utility) { [weak self] in
            for id in ids {
                guard !Task.isCancelled, let self else { return }
                _ = await self.lookup(id)
            }
        }
    }

    func lookup(_ id: String) async -> Result {
        let empty = Result(city: nil, country: nil, validResponse: false)
        guard Self.validID(id), !Task.isCancelled else { return empty }
        if let entry = entries[id], entry.retryAt > now() { return entry.result }
        if let task = pending[id] { return await task.value }
        // At most two metadata requests across paging, popovers and work players.
        while pending.count >= 2 {
            guard let task = pending.values.first else { break }
            _ = await task.value
            guard !Task.isCancelled else { return empty }
            await Task.yield() // Let the owner commit/cache the completed request.
        }
        // Recheck after yielding: another caller may have filled this exact ID.
        if let entry = entries[id], entry.retryAt > now() { return entry.result }
        if let task = pending[id] { return await task.value }
        let session = session
        let task = Task { await Self.fetch(id, session: session) }
        pending[id] = task
        let result = await task.value
        pending[id] = nil
        let date = now()
        let known = DYPublicationRegion.name(for: result.city, country: result.country) != nil
        entries[id] = Entry(id: id, city: result.city, country: result.country, validResponse: result.validResponse, checkedAt: date,
                            retryAt: date.addingTimeInterval(known ? 7 * 86400 : result.validResponse ? 300 : 60))
        if entries.count > Self.maximumEntries,
           let oldest = entries.values.min(by: { $0.checkedAt < $1.checkedAt }) { entries[oldest.id] = nil }
        snapshot.replace(entries.mapValues { ($0.result, $0.retryAt) })
        if let fileURL, let data = try? JSONEncoder().encode(entries.values.sorted { $0.checkedAt < $1.checkedAt }) {
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: fileURL, options: .atomic)
        }
        return result
    }

    nonisolated static func validID(_ id: String) -> Bool {
        (1...20).contains(id.utf8.count) && id.utf8.allSatisfy { (48...57).contains($0) }
    }
    nonisolated static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 10; configuration.timeoutIntervalForResource = 15
        return URLSession(configuration: configuration, delegate: DYPublicationRegionRedirect(), delegateQueue: nil)
    }
    nonisolated static func request(_ id: String) -> URLRequest? {
        guard validID(id) else { return nil }
        var parts = URLComponents(string: "https://aweme.snssdk.com/aweme/v1/feed/")!
        parts.queryItems = [URLQueryItem(name: "aweme_id", value: id)]
        guard let url = parts.url else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("com.ss.android.ugc.aweme/260201 (Linux; U; Android 12; zh_CN; Pixel 4; Build/SP1A.210812.016; Cronet/TTNetVersion)", forHTTPHeaderField: "User-Agent")
        return request
    }
    nonisolated private static func fetch(_ id: String, session: URLSession) async -> Result {
        let empty = Result(city: nil, country: nil, validResponse: false)
        guard let request = request(id) else { return empty }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  http.url?.scheme == "https", http.url?.host == "aweme.snssdk.com",
                  response.expectedContentLength <= maximumBytes else { return empty }
            var data = Data()
            data.reserveCapacity(min(maximumBytes, max(0, Int(response.expectedContentLength))))
            for try await byte in bytes {
                guard data.count < maximumBytes, !Task.isCancelled else { return empty }
                data.append(byte)
            }
            return decode(data, matching: id)
        } catch { return empty }
    }
    nonisolated static func decode(_ data: Data, matching id: String) -> Result {
        let empty = Result(city: nil, country: nil, validResponse: false)
        guard validID(id), data.count <= maximumBytes,
              let root = try? JSONDecoder().decode(Response.self, from: data), root.status_code == 0,
              let work = root.aweme_list?.first(where: { $0.aweme_id == id }) else { return empty }
        let city = work.city.flatMap { code in
            (1...12).contains(code.utf8.count) && code.utf8.allSatisfy({ (48...57).contains($0) }) ? code : nil
        }
        // A malformed country must not become a missing country and accept a domestic code.
        let country = work.region.map { value in value.utf8.count <= 2 ? value : "?" }
        return .init(city: city, country: country, validResponse: true)
    }
    private struct Response: Decodable { let status_code: Int?; let aweme_list: [Work]? }
    private struct Work: Decodable {
        let aweme_id: String?; let city: String?; let region: String?
        enum CodingKeys: String, CodingKey { case aweme_id, city, region }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            func text(_ key: CodingKeys) -> String? {
                (try? container.decode(String.self, forKey: key))
                    ?? (try? container.decode(Int64.self, forKey: key)).map(String.init)
            }
            aweme_id = text(.aweme_id); city = text(.city)
            region = text(.region) ?? (container.contains(.region) && (try? container.decodeNil(forKey: .region)) == false ? "?" : nil)
        }
    }
}

private final class DYPublicationRegionRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme == "https" && request.url?.host == "aweme.snssdk.com" ? request : nil)
    }
}
