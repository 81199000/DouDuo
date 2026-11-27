// 原生扫码登录流程（DouDuo N）：策略 → 取二维码 → 轮询扫码结果 → 跟跳转 → 进首页把会话坐实。
// 移植自 Amor5207/douyin-tv（GPL-3.0）DouyinApi 的 passport 登录部分；小号实测可登录、可发评论不掉线。
import Foundation

@MainActor
final class DYNativeLogin: ObservableObject {
    static let shared = DYNativeLogin()

    enum Phase: Equatable {
        case idle, loading, waiting(token: String), scanned, done, failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var qrImage: Data?
    @Published private(set) var expiresAt: Date?

    private var traceID = ""
    private var portrait = ""
    private var polling = false
    private var pollTask: Task<Void, Never>?
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.timeoutIntervalForRequest = 15
        return URLSession(configuration: c)
    }()

    var loggedIn: Bool {
        !(DYCookieJar.shared.value("sessionid") ?? DYCookieJar.shared.value("sessionid_ss") ?? "").isEmpty
    }

    private func startSession() {
        var b = [UInt8](repeating: 0, count: 4)
        _ = SecRandomCopyBytes(kSecRandomDefault, 4, &b)
        traceID = b.map { String(format: "%02x", $0) }.joined()
        portrait = UUID().uuidString.lowercased() + ".login"
        DYCookieJar.shared.set("biz_trace_id", traceID)
    }

    // MARK: HTTP

    private struct Resp { let status: Int; let text: String; let location: String?; var url: String = ""; var error: String = "" }

    private func send(_ method: String, _ url: URL, headers: [String: String], body: String? = nil,
                      followRedirect: Bool, useCookies: Bool = true) async -> Resp {
        var r = URLRequest(url: url)
        r.httpMethod = method
        if let body { r.httpBody = Data(body.utf8) }
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        if useCookies, !DYCookieJar.shared.cookies.isEmpty { r.setValue(DYCookieJar.shared.header, forHTTPHeaderField: "Cookie") }
        var delegateSession = session
        if !followRedirect { delegateSession = noRedirectSession }
        do {
            let (d, resp) = try await delegateSession.data(for: r)
            guard let h = resp as? HTTPURLResponse else { return Resp(status: -2, text: "", location: nil, error: "no-http") }
            DYCookieJar.shared.absorb(h)
            if let ms = h.value(forHTTPHeaderField: "X-Ms-Token"), !ms.isEmpty {
                DYCookieJar.shared.set("msToken", ms)
                DYCookieJar.shared.set("__dd_ms_captured", "1")
            }
            DYNativeTicket.capture(h)
            return Resp(status: h.statusCode, text: String(decoding: d, as: UTF8.self),
                        location: h.value(forHTTPHeaderField: "Location"), url: h.url?.absoluteString ?? "")
        } catch {
            return Resp(status: -1, text: "", location: nil, error: String(describing: error))
        }
    }

    /// 不自动跟随跳转的会话（要自己抓 Location 里的登录重定向）
    private lazy var noRedirectSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.timeoutIntervalForRequest = 15
        return URLSession(configuration: c, delegate: NoRedirect(), delegateQueue: nil)
    }()

    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ s: URLSession, task: URLSessionTask, willPerformHTTPRedirection r: HTTPURLResponse,
                        newRequest: URLRequest) async -> URLRequest? { nil }
    }

    // MARK: 流程

    private func DDLog(_ s: String) { DYLiveModel.log(s) }

    func start() async {
        DDLog("DDNLOGIN start")
        pollTask?.cancel()
        phase = .loading
        qrImage = nil
        DYCookieJar.shared.clear()
        DYNativeTicket.clear()
        await bootstrap()
        startSession()
        DYNativeTicket.prepareLogin()
        await strategy()
        await fetchQr()
    }

    /// 登录前先像浏览器一样「进一次首页」：拿 __ac_nonce/ttwid/webid 等基础 cookie。
    /// 少了这些，扫码确认那一步服务端会回「系统繁忙」。
    private func bootstrap() async {
        let jar = DYCookieJar.shared
        let home = await send("GET", URL(string: DYPassport.host + "/")!,
                              headers: ["Accept": "text/html,application/xhtml+xml", "User-Agent": DYPassport.userAgent,
                                        "Accept-Language": "zh-CN,zh;q=0.9", "Accept-Encoding": "identity"],
                              followRedirect: true)
        // ttwid
        let ttBody = #"{"aid":10006,"service":"sso.douyin.com","needFid":false,"union":true,"unionHost":"https://ttwid.bytedance.com","migrate_info":null,"fid":""}"#
        let tt = await send("POST", URL(string: "https://ttwid.bytedance.com/ttwid/union/register/")!,
                            headers: ["Content-Type": "application/json", "Accept": "application/json, text/plain, */*",
                                      "User-Agent": DYPassport.userAgent], body: ttBody, followRedirect: true)
        if let d = tt.text.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let redirect = o["redirect_url"] as? String, redirect.hasPrefix("http"), let u = URL(string: redirect) {
            _ = await send("GET", u, headers: ["Accept": "application/json, text/plain, */*", "User-Agent": DYPassport.userAgent],
                           followRedirect: true)
        }
        if jar.value("msToken") == nil { jar.set("msToken", Self.rand(107)) }
        if jar.value("UIFID_TEMP") == nil { jar.set("UIFID_TEMP", Self.hex(80)) }
        if jar.value("s_v_web_id") == nil { jar.set("s_v_web_id", Self.verifyFp()) }
        if jar.value("webid") == nil {
            let body = #"{"app_id":6383,"url":"https://www.douyin.com/","user_agent":"\#(DYPassport.userAgent)","referer":"","user_unique_id":""}"#
            let w = await send("POST", URL(string: "https://mcs.zijieapi.com/webid")!,
                               headers: ["Content-Type": "application/json", "User-Agent": DYPassport.userAgent],
                               body: body, followRedirect: true, useCookies: false)
            if let d = w.text.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let id = o["web_id"] as? String, id.count >= 6 { jar.set("webid", id) }
        }
        DDLog("DDNLOGIN bootstrap home=\(home.status) ttwid=\(jar.value("ttwid") != nil) nonce=\(jar.value("__ac_nonce") != nil) webid=\(jar.value("webid") != nil) ms=\(jar.value("__dd_ms_captured") ?? "0") cookies=\(jar.cookies.count)")
    }

    static func rand(_ n: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
        return String((0..<n).map { _ in chars.randomElement()! })
    }

    static func hex(_ bytes: Int) -> String {
        (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    private func strategy() async {
        let path = "/passport/general/login_guiding_strategy/"
        let qs = DYPassport.signedQuery(DYPassport.base(.strategy, traceID: traceID, verifyFp: nil), body: [])
        var h = DYPassport.headers(path: path, post: false, traceID: traceID, portrait: portrait, dtrait: nil)
        h.removeValue(forKey: "web-sdk-version")
        h.removeValue(forKey: "x-tt-passport-verify-portrait")
        let r = await send("GET", URL(string: DYPassport.host + path + "?" + qs)!, headers: h, followRedirect: false)
        DDLog("DDNLOGIN strategy http=\(r.status) cookies=\(DYCookieJar.shared.cookies.count) body=\(String(r.text.prefix(90)))")
    }

    private func fetchQr() async {
        let fp = DYCookieJar.shared.value("s_v_web_id") ?? Self.verifyFp()
        DYCookieJar.shared.set("s_v_web_id", fp)
        let path = "/passport/web/get_qrcode/"
        let qs = DYPassport.signedQuery(DYPassport.base(.qr, traceID: traceID, verifyFp: fp), body: [])
        let h = DYPassport.headers(path: path, post: false, traceID: traceID, portrait: portrait,
                                   dtrait: DYDtrait.session)
        let r = await send("GET", URL(string: DYPassport.host + path + "?" + qs)!, headers: h, followRedirect: true)
        DDLog("DDNLOGIN get_qrcode http=\(r.status) cookies=\(DYCookieJar.shared.cookies.count) body=\(String(r.text.prefix(120)))")
        guard let d = r.text.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            phase = .failed("取二维码失败（网络）")
            return
        }
        let data = (o["data"] as? [String: Any]) ?? o
        guard let token = data["token"] as? String, !token.isEmpty, var qr = data["qrcode"] as? String else {
            DDLog("DDNLOGIN no-token keys=\(data.keys.sorted().prefix(8))")
            phase = .failed("取二维码失败：\((o["description"] as? String) ?? "无二维码")")
            return
        }
        if let comma = qr.range(of: "base64,") { qr = String(qr[comma.upperBound...]) }
        guard let img = Data(base64Encoded: qr) else {
            DDLog("DDNLOGIN qr-not-base64 len=\(qr.count) head=\(String(qr.prefix(20)))")
            phase = .failed("二维码解码失败")
            return
        }
        DDLog("DDNLOGIN qr ok token=\(token.prefix(6))… img=\(img.count)B")
        qrImage = img
        // 实测这个 token 只有约 66 秒寿命（之后轮询直接回 4031），所以 55 秒就换，别让老板扫到已死的码
        expiresAt = Date().addingTimeInterval(55)
        phase = .waiting(token: token)
        startPolling(token: token)
    }

    private func startPolling(token: String) {
        polling = true
        pollTask = Task { @MainActor in
            var misses = 0
            while polling, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled || !polling { return }
                if case .scanned = phase {
                    // 已经扫过（等手机确认），别在确认前把码换掉——换了等于把这次扫码作废；
                    // 但也不能无限等，90 秒还没登进去就让老板重扫
                    if let exp = expiresAt, Date().timeIntervalSince(exp) > 35 {
                        polling = false
                        DDLog("DDNLOGIN scanned-timeout")
                        phase = .failed("扫码后迟迟没有确认，请重新扫一次")
                        return
                    }
                } else if let exp = expiresAt, Date() > exp {
                    DDLog("DDNLOGIN qr-expired, refreshing")
                    await fetchQr()
                    return
                }
                let step = await poll(token: token)
                if let step { DDLog("DDNLOGIN poll status=\(step.1) redirect=\(step.0 == nil ? "-" : "yes")") }
                if case .scanned = phase {} else if let step, step.1 == "4031" {
                    // 码已被服务端判死，立刻换新码，不要拿死码继续轮询
                    DDLog("DDNLOGIN token-dead(4031) refreshing")
                    await fetchQr()
                    return
                }
                if loggedIn {
                    polling = false
                    DDLog("DDNLOGIN logged-in-by-cookie")
                    let ok = await completeLogin(redirect: "")
                    DDLog("DDNLOGIN complete ok=\(ok) sessionid=\(DYCookieJar.shared.value("sessionid") == nil ? "none" : "set") ticket=\(DYNativeTicket.hasTicket)")
                    if ok { await DYCookieJar.shared.pushToWebKit(); phase = .done }
                    return
                }
                guard let step else {
                    misses += 1
                    if misses > 90 { polling = false; phase = .failed("二维码已过期") }
                    continue
                }
                misses = 0
                if let redirect = step.0, !redirect.isEmpty {
                    phase = .scanned
                    polling = false
                    let ok = await completeLogin(redirect: redirect)
                    DDLog("DDNLOGIN complete ok=\(ok) sessionid=\(DYCookieJar.shared.value("sessionid") == nil ? "none" : "set") ticket=\(DYNativeTicket.hasTicket)")
                    guard ok else { phase = .failed("登录未完成，请重试"); return }
                    await DYCookieJar.shared.pushToWebKit()
                    phase = .done
                    return
                }
                let status = step.1
                if status == "2" || status.lowercased() == "scan" || status.lowercased() == "scanned" {
                    phase = .scanned
                }
                if loggedIn {
                    polling = false
                    _ = await completeLogin(redirect: "")
                    await DYCookieJar.shared.pushToWebKit()
                    phase = .done
                    return
                }
            }
        }
    }

    /// 返回 (重定向地址, 状态串)。
    /// 关键：**不跟随跳转**。扫码确认后服务端回 302 + Location，如果交给 URLSession 自动跟随，
    /// 它会把 POST 改成 GET 重新发且丢掉我们手写的 Cookie，服务端就回「系统繁忙」——
    /// 所以跟 Amor 的 Java 版一样：自己抓 Location，再手动一步步跟（completeLogin）。
    private func poll(token: String) async -> (String?, String)? {
        let path = "/passport/web/check_qrconnect/"
        let body: [(String, String)] = [("need_logo", "false"), ("is_frontier", "false"), ("token", token),
                                        ("is_new_login", "1"), ("next", DYPassport.host), ("need_short_url", "true")]
        let qs = DYPassport.signedQuery(DYPassport.base(.status, traceID: traceID,
                                                        verifyFp: DYCookieJar.shared.value("s_v_web_id")), body: body)
        let h = DYPassport.headers(path: path, post: true, traceID: traceID, portrait: portrait,
                                   dtrait: DYDtrait.session)
        let form = body.map { "\($0.0)=\(DYPassport.encComponent($0.1))" }.joined(separator: "&")
        let r = await send("POST", URL(string: DYPassport.host + path + "?" + qs)!, headers: h, body: form,
                           followRedirect: false)
        DDLog("DDNLOGIN poll http=\(r.status) loc=\(r.location.map { String($0.prefix(60)) } ?? "-") err=\(r.error.isEmpty ? "-" : r.error) body=\(String(r.text.prefix(150)))")

        if !(DYCookieJar.shared.value("sessionid") ?? "").isEmpty { return (DYPassport.host + "/", "3") }
        if let loc = r.location, !loc.isEmpty { return (loc, "3") }
        guard let d = r.text.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        let data = (o["data"] as? [String: Any]) ?? o
        if (data["error_code"] as? Int) == 4031 { return (nil, "4031") }
        for k in ["redirect_url", "redirect_uri", "login_url", "scan_url", "url"] {
            if let v = (data[k] as? String) ?? (o[k] as? String), !v.isEmpty { return (v, "3") }
        }
        let st = (data["status"] as? String) ?? (data["status"].map { "\($0)" } ?? "")
        if st.isEmpty, let err = (data["description"] as? String) ?? (o["description"] as? String) {
            DDLog("DDNLOGIN poll-no-status desc=\(err)")
        }
        return (nil, st)
    }

    /// 跟着登录重定向把会话坐实，再进一次首页让 msToken / 票据落定
    private func completeLogin(redirect: String) async -> Bool {
        var url = redirect.isEmpty ? URL(string: DYPassport.host + "/")! : URL(string: redirect, relativeTo: URL(string: DYPassport.host))!
        for _ in 0..<6 {
            guard url.host?.hasSuffix("douyin.com") == true else { break }
            let r = await send("GET", url, headers: ["Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                                                           "Referer": DYPassport.host + "/", "User-Agent": DYPassport.userAgent],
                                     followRedirect: false)
            DDLog("DDNLOGIN hop http=\(r.status) loc=\(r.location == nil ? "-" : "yes")")
            guard r.status >= 300, r.status < 400, let loc = r.location, !loc.isEmpty,
                  let next = URL(string: loc, relativeTo: url) else { break }
            url = next
        }
        // 首页一跳：拿 msToken / server_data
        _ = await send("GET", URL(string: DYPassport.host + "/")!,
                       headers: ["Accept": "text/html,application/xhtml+xml", "User-Agent": DYPassport.userAgent],
                       followRedirect: true)
        if !DYNativeTicket.hasTicket {
            // 有些会话的 server_data 只在 cookie 里；没有再补一次接口拿票据
            await fetchTicketCert()
        }
        return loggedIn
    }

    /// 取客户端证书顺带拿 server_cert（部分接口要）
    private func fetchTicketCert() async {
        let path = "/passport/ticket_guard/get_client_cert/"
        let body = "server_data=1&aid=6383"
        let h = ["Accept": "application/json", "Content-Type": "application/x-www-form-urlencoded",
                 "Referer": DYPassport.host + "/", "Origin": DYPassport.host,
                 "User-Agent": DYPassport.userAgent, "Cookie": DYCookieJar.shared.header]
        _ = await send("POST", URL(string: DYPassport.host + path + "?aid=6383&is_from_ttaccountsdk=1")!,
                       headers: h, body: body, followRedirect: true)
    }

    func cancel() {
        polling = false
        pollTask?.cancel()
        pollTask = nil
        if case .done = phase { return }
        phase = .idle
    }

    static func verifyFp() -> String {
        let chars = Array("0123456789abcdef")
        let rand = String((0..<32).map { _ in chars.randomElement()! })
        let hex8 = String((0..<8).map { _ in chars.randomElement()! })
        return "verify_\(rand)_\(hex8)"
    }
}
