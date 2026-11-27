// 原生扫码登录流程：策略 → 取二维码 → 轮询扫码结果 → 跟跳转 → 进首页把会话坐实。
// 移植自 Amor5207/douyin-tv（GPL-3.0）DouyinApi 的 passport 登录部分
import Foundation

@MainActor
final class DYNativeLogin: ObservableObject {
    static let shared = DYNativeLogin()

    enum Phase: Equatable {
        case idle, loading, waiting(token: String), scanned, mfa, done, failed(String)
    }

    // 扫码确认后抖音要求短信二次验证（account_flow=verify / error_code 2046）时的状态
    @Published private(set) var mfaHint = ""
    @Published private(set) var mfaError = ""
    @Published private(set) var mfaBusy = false
    @Published private(set) var mfaCooldown = 0
    private var mfaData: [String: Any]?
    private var mfaAttempted = false
    private var verifyTicket: String?
    private var currentToken = ""

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
        smsPrepared = false
        pollTask?.cancel()
        phase = .loading
        qrImage = nil
        DYCookieJar.shared.clear()
        DYNativeTicket.clear()
        mfaData = nil; mfaAttempted = false; verifyTicket = nil; mfaError = ""; mfaHint = ""
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
        expiresAt = Date().addingTimeInterval(55)
        phase = .waiting(token: token)
        startPolling(token: token)
    }

    private func startPolling(token: String) {
        currentToken = token
        polling = true
        pollTask = Task { @MainActor in
            var misses = 0
            while polling, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled || !polling { return }
                if case .scanned = phase {
                    // 已经扫过（等手机确认），别在确认前把码换掉——换了等于把这次扫码作废；
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
                if let step { DDLog("DDNLOGIN poll status=\(step.status) code=\(step.errorCode) redirect=\(step.redirect == nil ? "-" : "yes")") }
                if case .scanned = phase {} else if let step, step.errorCode == 4031 {
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
                // 扫码确认后要求短信二次验证：先于跳转判断（这个响应里可能带别的链接）
                if step.needsVerify {
                    phase = .scanned
                    if Self.smsWay(step.data) == nil {
                        DDLog("DDNLOGIN verify-no-sms ways=\(Self.wayNames(step.data))")
                        continue   // 只能在手机上验证，继续等
                    }
                    if verifyTicket != nil {
                        // 上一次的验证票据被拒，允许重新输验证码
                        verifyTicket = nil
                        mfaAttempted = false
                    }
                    if !mfaAttempted { beginMfa(step.data); return }
                    continue
                }
                if let redirect = step.redirect, !redirect.isEmpty {
                    phase = .scanned
                    polling = false
                    let ok = await completeLogin(redirect: redirect)
                    DDLog("DDNLOGIN complete ok=\(ok) sessionid=\(DYCookieJar.shared.value("sessionid") == nil ? "none" : "set") ticket=\(DYNativeTicket.hasTicket)")
                    guard ok else { phase = .failed("登录未完成，请重试"); return }
                    await DYCookieJar.shared.pushToWebKit()
                    phase = .done
                    return
                }
                let status = step.status.lowercased()
                if status == "2" || status == "scan" || status == "scanned" {
                    phase = .scanned
                }
            }
        }
    }

    struct PollResult {
        var redirect: String?
        var status = ""
        var errorCode = 0
        var data: [String: Any] = [:]
        var needsVerify: Bool { errorCode == 2046 || (data["account_flow"] as? String) == "verify" }
    }

    /// 关键：**不跟随跳转**。扫码确认后服务端回 302 + Location，如果交给 URLSession 自动跟随，
    /// 它会把 POST 改成 GET 重新发且丢掉我们手写的 Cookie，服务端就回「系统繁忙」——
    /// 所以跟 Amor 的 Java 版一样：自己抓 Location，再手动一步步跟（completeLogin）。
    private func poll(token: String) async -> PollResult? {
        let path = "/passport/web/check_qrconnect/"
        var body: [(String, String)] = [("need_logo", "false"), ("is_frontier", "false"), ("token", token),
                                        ("is_new_login", "1"), ("next", DYPassport.host), ("need_short_url", "true")]
        if let vt = verifyTicket, !vt.isEmpty {
            body += [("verify_ticket", vt), ("std_verify_way", "mobile_sms_verify")]
        }
        let qs = DYPassport.signedQuery(DYPassport.base(.status, traceID: traceID,
                                                        verifyFp: DYCookieJar.shared.value("s_v_web_id")), body: body)
        let h = DYPassport.headers(path: path, post: true, traceID: traceID, portrait: portrait,
                                   dtrait: DYDtrait.session)
        let form = body.map { "\($0.0)=\(DYPassport.encComponent($0.1))" }.joined(separator: "&")
        let r = await send("POST", URL(string: DYPassport.host + path + "?" + qs)!, headers: h, body: form,
                           followRedirect: false)
        DDLog("DDNLOGIN poll http=\(r.status) loc=\(r.location == nil ? "-" : "yes") err=\(r.error.isEmpty ? "-" : r.error) vt=\(verifyTicket == nil ? 0 : 1) body=\(Self.redact(String(r.text.prefix(150))))")

        if !(DYCookieJar.shared.value("sessionid") ?? "").isEmpty { return PollResult(redirect: DYPassport.host + "/", status: "3") }
        if let loc = r.location, !loc.isEmpty { return PollResult(redirect: loc, status: "3") }
        guard let d = r.text.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        var data = (o["data"] as? [String: Any]) ?? o
        for k in ["redirect_url", "redirect_uri", "login_url", "status", "error_code", "description"] where data[k] == nil {
            if let v = o[k] { data[k] = v }
        }
        var res = PollResult(data: data)
        res.errorCode = (data["error_code"] as? Int) ?? Int("\(data["error_code"] ?? "0")") ?? 0
        res.status = (data["status"] as? String) ?? (data["status"].map { "\($0)" } ?? "")
        if res.needsVerify {
            DDLog("DDNLOGIN verify-required keys=\(data.keys.sorted().joined(separator: ",")) ways=\(Self.wayNames(data))")
            return res
        }
        // 跟 Java 版一致：只认这三个键、且必须是 https:// 或站内路径
        for k in ["redirect_url", "redirect_uri", "login_url"] {
            if let v = data[k] as? String {
                if v.hasPrefix("//") { res.redirect = "https:" + v; break }
                if v.hasPrefix("https://") || v.hasPrefix("/") { res.redirect = v; break }
            }
        }
        if res.status.isEmpty, let err = data["description"] as? String, !err.isEmpty {
            DDLog("DDNLOGIN poll-no-status code=\(res.errorCode) desc=\(err)")
        }
        return res
    }

    // MARK: 短信二次验证（照 Amor5207/douyin-tv 的 sendMfaCode / validateMfaCode）

    private static func smsWay(_ data: [String: Any]) -> [String: Any]? {
        (data["verify_ways"] as? [[String: Any]])?.first { ($0["verify_way"] as? String) == "mobile_sms_verify" }
    }

    private static func wayNames(_ data: [String: Any]) -> String {
        ((data["verify_ways"] as? [[String: Any]]) ?? []).compactMap { $0["verify_way"] as? String }.joined(separator: "|")
    }

    /// 日志里不留手机号、验证票据原文
    static func redact(_ s: String) -> String {
        var out = s
        for pat in [#"1[3-9]\d{9}"#, #"("(verify_ticket|encrypt_uid|ticket|mobile)":")[^"]+"#] {
            if let re = try? NSRegularExpression(pattern: pat) {
                let tmpl = pat.hasPrefix("(") ? "$1<redacted>" : "<phone>"
                out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: tmpl)
            }
        }
        return out
    }

    private static func maskMobile(_ m: String) -> String {
        m.count == 11 ? String(m.prefix(3)) + "****" + String(m.suffix(4)) : m
    }

    private static func xor5Hex(_ s: String) -> String {
        Data(s.utf8).map { String(format: "%02x", $0 ^ 0x05) }.joined()
    }

    private func mfaForm(code: String?) -> [(String, String)] {
        guard let data = mfaData else { return [] }
        var f: [(String, String)] = [("encrypt_uid", "\(data["encrypt_uid"] ?? "")"),
                                     ("verify_ticket", "\(data["verify_ticket"] ?? "")")]
        if let common = data["common_params"] as? [String: Any] {
            for (k, v) in common.sorted(by: { $0.key < $1.key }) {
                let sv: String
                if let str = v as? String { sv = str }
                else if JSONSerialization.isValidJSONObject(v), let j = try? JSONSerialization.data(withJSONObject: v) {
                    sv = String(decoding: j, as: UTF8.self)
                } else { sv = "\(v)" }
                if let i = f.firstIndex(where: { $0.0 == k }) { f[i].1 = sv } else { f.append((k, sv)) }
            }
        }
        var act = "22"
        if let v = Self.smsWay(data)?["act_type"] {
            let sv = "\(v)"
            if !sv.isEmpty { act = sv }
        }
        f += [("type", Self.xor5Hex(act)), ("aid", "6383"), ("std_verify_way", "mobile_sms_verify"),
              ("new_authn_sdk_version", "1.0.0.413"), ("mix_mode", "1")]
        if let code, !code.isEmpty { f.append(("code", Self.xor5Hex(code))) }
        return f
    }

    private func mfaRequest(_ path: String, form: [(String, String)]) async -> (ok: Bool, data: [String: Any], desc: String) {
        let q: [(String, String)] = [("passport_jssdk_version", "5.1.2"), ("passport_jssdk_type", "lite"),
                                     ("is_from_ttaccountsdk", "1"), ("aid", "6383"), ("language", "zh"),
                                     ("account_app_language", "zh-CN"), ("new_authn_sdk_version", "1.0.0.413")]
        let body = form.map { "\($0.0)=\(DYPassport.encComponent($0.1))" }.joined(separator: "&")
        let r = await send("POST", URL(string: DYPassport.host + path + "?" + DYPassport.query(q))!,
                           headers: ["Accept": "application/json, text/javascript", "Origin": DYPassport.host,
                                     "Referer": DYPassport.host + "/", "Content-Type": "application/x-www-form-urlencoded",
                                     "User-Agent": DYPassport.userAgent, "Accept-Language": "zh-CN,zh;q=0.9",
                                     "Accept-Encoding": "identity"],
                           body: body, followRedirect: true)
        DDLog("DDNLOGIN mfa \(path) http=\(r.status) body=\(Self.redact(String(r.text.prefix(160))))")
        guard let d = r.text.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            return (false, [:], "验证服务无响应")
        }
        let data = (o["data"] as? [String: Any]) ?? [:]
        let err = (data["error_code"] as? Int) ?? (o["error_code"] as? Int) ?? 0
        if err != 0 {
            let desc = (data["description"] as? String) ?? (o["description"] as? String) ?? ""
            return (false, data, desc.isEmpty ? "验证服务返回错误（\(err)）" : desc)
        }
        return (true, data, "")
    }

    private func beginMfa(_ data: [String: Any]) {
        mfaData = data
        mfaAttempted = true
        polling = false
        pollTask?.cancel()
        let mobile = Self.maskMobile("\(Self.smsWay(data)?["mobile"] ?? "")")
        mfaHint = mobile.isEmpty ? "抖音要求短信验证，正在发送验证码…" : "正在向 \(mobile) 发送验证码…"
        mfaError = ""
        phase = .mfa
        Task { await sendMfaCode() }
    }

    func sendMfaCode() async {
        guard mfaData != nil, !mfaBusy, mfaCooldown == 0 else { return }
        mfaBusy = true
        let r = await mfaRequest("/passport/web/send_code/", form: mfaForm(code: nil))
        mfaBusy = false
        let mobile = Self.maskMobile("\(Self.smsWay(mfaData ?? [:])?["mobile"] ?? "")")
        if r.ok {
            mfaHint = mobile.isEmpty ? "短信验证码已发送，请查收" : "验证码已发送至 \(mobile)"
            mfaError = ""
            startCooldown()
        } else {
            mfaHint = "没能发送验证码"
            mfaError = r.desc
        }
    }

    private func startCooldown() {
        mfaCooldown = 60
        Task { @MainActor in
            while mfaCooldown > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                mfaCooldown -= 1
            }
        }
    }

    func submitMfaCode(_ code: String) async {
        let code = code.filter(\.isNumber)
        guard mfaData != nil, !mfaBusy else { return }
        guard code.count >= 4 else { mfaError = "请输入短信验证码"; return }
        mfaBusy = true
        mfaError = ""
        let r = await mfaRequest("/passport/web/validate_code/", form: mfaForm(code: code))
        mfaBusy = false
        let ticket = (r.data["ticket"] as? String) ?? ((r.data["data"] as? [String: Any])?["ticket"] as? String) ?? ""
        guard r.ok, !ticket.isEmpty else {
            mfaError = r.ok ? "验证成功但没拿到登录票据" : r.desc
            return
        }
        DDLog("DDNLOGIN mfa validated, resume polling")
        verifyTicket = ticket
        mfaData = nil
        phase = .scanned
        expiresAt = Date().addingTimeInterval(60)
        startPolling(token: currentToken)
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

    // MARK: 手机号验证码登录（跟扫码同一套：App 自己的密钥在 sms_login 这一步交给抖音绑定）
    //
    // - send_code：query 同 passport 公共参数（无 ts，末尾 is_new_login=1）+ msToken + a_bogus；
    //   表单 is6Digits=1 / mix_mode=1 / mobile=xor5("+86 1xxxxxxxxxx") / type=xor5("24") / fixed_mix_mode=1
    // - sms_login：表单 service=https://www.douyin.com / mix_mode=1 / mobile / code=xor5(验证码) / fixed_mix_mode=1；
    //   头里带 bd-ticket-guard-ree-public-key（sign-type 0）——公钥就是在这里绑定的
    // 官方这两个请求都不带 x-tt-passport-aid-sign / x-secsdk-csrf-token，这里也不带。

    @Published private(set) var smsBusy = false
    @Published private(set) var smsError = ""
    @Published private(set) var smsHint = ""
    @Published private(set) var smsCooldown = 0
    private var smsPrepared = false

    /// 进手机号登录：停掉扫码轮询，准备一份干净的会话（cookie 罐 + 新密钥）
    func prepareSms() async {
        guard !smsPrepared else { return }
        polling = false
        pollTask?.cancel(); pollTask = nil
        DDLog("DDNLOGIN sms prepare")
        DYCookieJar.shared.clear()
        DYNativeTicket.clear()
        await bootstrap()
        startSession()
        DYNativeTicket.prepareLogin()
        await strategy()
        smsPrepared = true
    }

    private func smsHeaders(_ path: String, bindKey: Bool) -> [String: String] {
        var h = DYPassport.headers(path: path, post: true, traceID: traceID, portrait: portrait, dtrait: DYDtrait.session)
        h.removeValue(forKey: "x-tt-passport-aid-sign")
        h.removeValue(forKey: "x-secsdk-csrf-token")
        if bindKey { for (k, v) in DYNativeTicket.loginHeaders { h[k] = v } }
        return h
    }

    private func smsPost(_ path: String, form: [(String, String)], bindKey: Bool) async -> (data: [String: Any], code: Int, desc: String, http: Int) {
        let qs = DYPassport.smsQuery(DYPassport.base(.sms, traceID: traceID, verifyFp: DYCookieJar.shared.value("s_v_web_id")), body: form)
        let body = form.map { "\($0.0)=\(DYPassport.encComponent($0.1))" }.joined(separator: "&")
        let r = await send("POST", URL(string: DYPassport.host + path + "?" + qs)!, headers: smsHeaders(path, bindKey: bindKey),
                           body: body, followRedirect: false)
        DDLog("DDNLOGIN sms \(path) http=\(r.status) err=\(r.error.isEmpty ? "-" : r.error) body=\(Self.redact(String(r.text.prefix(200))))")
        guard let d = r.text.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            return ([:], -1, r.status == 200 ? "抖音返回了无法识别的内容" : "网络异常（\(r.status)）", r.status)
        }
        let data = (o["data"] as? [String: Any]) ?? [:]
        let code = (data["error_code"] as? Int) ?? (o["error_code"] as? Int) ?? Int("\(data["error_code"] ?? "0")") ?? 0
        let desc = (data["description"] as? String) ?? (o["description"] as? String) ?? ""
        return (data, (o["message"] as? String) == "error" && code == 0 ? -2 : code, desc, r.status)
    }

    private static func smsMobile(_ phone: String) -> String { "+86 " + phone.filter(\.isNumber) }

    func sendSmsCode(phone: String) async {
        let phone = phone.filter(\.isNumber)
        guard phone.count == 11, !smsBusy, smsCooldown == 0 else { return }
        smsBusy = true; smsError = ""
        await prepareSms()
        let form: [(String, String)] = [("is6Digits", "1"), ("mix_mode", "1"), ("mobile", Self.xor5Hex(Self.smsMobile(phone))),
                                        ("type", Self.xor5Hex("24")), ("fixed_mix_mode", "1")]
        let r = await smsPost("/passport/web/send_code/", form: form, bindKey: false)
        smsBusy = false
        if r.code == 0, r.http == 200 {
            smsHint = "验证码已发送至 \(Self.maskMobile(phone))"
            let retry = (r.data["retry_time"] as? Int) ?? 60
            startSmsCooldown(retry)
        } else {
            smsError = r.desc.isEmpty ? "验证码没发出去（\(r.code)）" : r.desc
            DDLog("DDNLOGIN sms send-fail code=\(r.code) keys=\(r.data.keys.sorted().joined(separator: ","))")
        }
    }

    private func startSmsCooldown(_ s: Int) {
        smsCooldown = max(1, s)
        Task { @MainActor in
            while smsCooldown > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                smsCooldown -= 1
            }
        }
    }

    func smsLogin(phone: String, code: String) async {
        let phone = phone.filter(\.isNumber), code = code.filter(\.isNumber)
        guard phone.count == 11, code.count >= 4, !smsBusy else { return }
        guard smsPrepared else { smsError = "请先获取验证码"; return }
        smsBusy = true; smsError = ""
        let form: [(String, String)] = [("service", DYPassport.host), ("mix_mode", "1"), ("mobile", Self.xor5Hex(Self.smsMobile(phone))),
                                        ("code", Self.xor5Hex(code)), ("fixed_mix_mode", "1")]
        let r = await smsPost("/passport/web/sms_login/", form: form, bindKey: true)
        guard r.code == 0, r.http == 200 || loggedIn else {
            smsBusy = false
            let verify = r.code == 2046 || (r.data["account_flow"] as? String) == "verify"
            smsError = verify ? "抖音要求额外的安全验证，这一步原生还不支持，请改用「原生扫码」登录"
                : (r.desc.isEmpty ? "登录失败（\(r.code)）" : r.desc)
            DDLog("DDNLOGIN sms login-fail code=\(r.code) verify=\(verify) keys=\(r.data.keys.sorted().joined(separator: ","))")
            return
        }
        let redirect = (r.data["redirect_url"] as? String) ?? ""
        let ok = await completeLogin(redirect: redirect.hasPrefix("http") || redirect.hasPrefix("/") ? redirect : "")
        DDLog("DDNLOGIN sms complete ok=\(ok) sessionid=\(DYCookieJar.shared.value("sessionid") == nil ? "none" : "set") ticket=\(DYNativeTicket.hasTicket)")
        smsBusy = false
        guard ok else { smsError = "登录未完成，请重试"; return }
        smsPrepared = false
        await DYCookieJar.shared.pushToWebKit()
        phase = .done
    }

    /// 登录页重新打开：上次停在「登录成功 / 失败」的状态清掉，从头开始
    func reset() {
        polling = false
        pollTask?.cancel()
        pollTask = nil
        switch phase {
        case .done, .failed: phase = .idle; qrImage = nil
        default: break
        }
        smsError = ""; smsHint = ""
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
