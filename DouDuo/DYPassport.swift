// 原生扫码登录（DouDuo N）：整套移植自 Amor5207/douyin-tv（GPL-3.0）的 passport 登录流程。
// 关键点：登录前 App 自己生成一把 EC 密钥（P-256）交给抖音绑定（bd-ticket-guard-client-data），
// 登录成功后写接口就用这把密钥签名（sign-type 0）。这条路 2026-11-27 真机/小号实测：发评论成功、不掉登录。
// 与「网页登录 + HMAC(ecdh_key) sign-type 1」并存：原生登录过的会话走这里，网页登录的会话仍走 DYTicketGuard。
import CryptoKit
import Foundation
import WebKit

// MARK: - 自己的 cookie 罐（原生请求用，登录后整份灌进网页）

@MainActor
final class DYCookieJar {
    static let shared = DYCookieJar()
    private static let key = "douduo_native_cookie_jar_v1"
    private(set) var cookies: [String: String]

    private init() {
        cookies = UserDefaults.standard.dictionary(forKey: Self.key) as? [String: String] ?? [:]
    }

    func value(_ name: String) -> String? { cookies[name] }
    func set(_ name: String, _ value: String) { cookies[name] = value; save() }
    func remove(_ name: String) { cookies.removeValue(forKey: name); save() }
    func clear() { cookies = [:]; UserDefaults.standard.removeObject(forKey: Self.key) }

    /// 作废原生登录留下的整套会话（cookie 罐 + 票据 + 绑定的 EC 密钥）。
    /// 网页登录 / 切换账号 / 退出时必须调：否则 DYNativeTicket.hasTicket 还是 true，
    /// 读接口拿罐里的旧 sessionid、写接口用旧密钥签名，跟网页里新登录的账号对不上（服务端会作废登录）。
    static func dropNativeSession(reason: String) {
        let had = DYNativeTicket.hasTicket || !shared.cookies.isEmpty
        shared.clear()
        DYNativeTicket.clear()
        DYNativeCookies.invalidate()
        DYTicketStore.invalidate()
        if had { DYLiveModel.log("DDNATIVE session dropped reason=\(reason)") }
    }
    private func save() { UserDefaults.standard.set(cookies, forKey: Self.key); UserDefaults.standard.synchronize() }

    var header: String {
        cookies.filter { !$0.key.hasPrefix("__dd_") }.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "; ")
    }

    /// 收 Set-Cookie。注意 URLSession 会把多条 Set-Cookie 用逗号合并成一个头，
    /// 不能手动按行拆（会只认第一条），必须交给 HTTPCookie 解析。
    func absorb(_ response: HTTPURLResponse) {
        guard let url = response.url else { return }
        var fields: [String: String] = [:]
        for (k, v) in response.allHeaderFields { fields["\(k)"] = "\(v)" }
        let list = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
        for c in list {
            if c.value.isEmpty || c.value == "deleted" || (c.expiresDate.map { $0 < Date() } ?? false) {
                cookies.removeValue(forKey: c.name)
            } else {
                cookies[c.name] = c.value
            }
        }
        if !list.isEmpty { save() }
    }

    func absorbCookie(_ line: String) {
        let parts = line.components(separatedBy: ";")
        guard let first = parts.first else { return }
        let kv = first.components(separatedBy: "=")
        guard kv.count >= 2 else { return }
        let name = kv[0].trimmingCharacters(in: .whitespaces)
        let value = kv.dropFirst().joined(separator: "=").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if value.isEmpty || value == "deleted" { cookies.removeValue(forKey: name) } else { cookies[name] = value }
        save()
    }

    /// 把原生登录拿到的整份 cookie 写进网页的共享存储，让网页和私信等仍能共用同一个登录
    func pushToWebKit() async {
        let store = WKWebsiteDataStore.default().httpCookieStore
        for (name, value) in cookies where !name.hasPrefix("__dd_") {
            let c = HTTPCookie(properties: [
                .name: name, .value: value, .domain: ".douyin.com", .path: "/",
                .expires: Date(timeIntervalSinceNow: 60 * 60 * 24 * 300),
                .secure: "TRUE",
            ])
            if let c { await store.setCookie(c) }
        }
        DYNativeCookies.invalidate()
        DYTicketStore.invalidate()
    }
}

// MARK: - 调试种子（只在 DEBUG 包；用于把跑通了的会话灌进模拟器做回归，不参与 Release）

@MainActor
enum DYDebugSeed {
    /// Documents/ddseed.json：{"cookies":{...},"ec_priv":"...","ticket":"...","ts_sign":"..."}
    static func applyIfPresent() {
        #if DEBUG
        let fm = FileManager.default
        let url = fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("ddseed.json")
        guard let d = try? Data(contentsOf: url),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
        if let jar = o["cookies"] as? [String: String] {
            for (k, v) in jar { DYCookieJar.shared.set(k, v) }
        }
        if let priv = o["ec_priv"] as? String { UserDefaults.standard.set(priv, forKey: "douduo_native_ec_key_v1") }
        if let tk = o["ticket"] as? String, let ts = o["ts_sign"] as? String,
           let data = try? JSONSerialization.data(withJSONObject: ["ticket": tk, "tsSign": ts]) {
            UserDefaults.standard.set(data, forKey: "douduo_native_ticket_v1")
        }
        try? fm.removeItem(at: url)
        DYLiveModel.log("DDSEED applied jar=\(DYCookieJar.shared.cookies.count) ticket=\(DYNativeTicket.hasTicket)")
        #endif
    }
}

// MARK: - passport 请求签名

enum DYPassport {
    static let appKey = "163e7ce78d58971a41f5b969996d85c2"
    static let host = "https://www.douyin.com"
    /// 必须和 account_sdk_source_info 的环境指纹配套（那份指纹是 Windows Chrome），
    /// 用 Mac Safari 的 UA 去配 Windows 指纹会被判环境异常（error_code 4031，扫码后一直不返回已确认）。
    static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

    /// UTC 当天 12:00 的秒级时间戳
    static var dayTs: String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        var c = cal.dateComponents([.year, .month, .day], from: Date())
        c.hour = 12; c.minute = 0; c.second = 0
        let d = cal.date(from: c) ?? Date()
        return String(Int(d.timeIntervalSince1970))
    }

    static func sha256Hex(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// hex(utf8(s) XOR 0x05)
    static func x5(_ s: String) -> String {
        Data(s.utf8).map { String(format: "%02x", $0 ^ 0x05) }.joined()
    }

    /// encodeURIComponent 口径（空格 %20，保留 !*'()）
    static func encComponent(_ s: String) -> String {
        var out = ""
        for b in s.utf8 {
            let c = Int(b)
            let plain = (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57)
                || c == 45 || c == 95 || c == 46 || c == 33 || c == 126 || c == 42 || c == 39 || c == 40 || c == 41
            if plain { out.append(Character(UnicodeScalar(b))) } else { out += String(format: "%%%02X", c) }
        }
        return out
    }

    static func query(_ pairs: [(String, String)]) -> String {
        pairs.map { "\($0.0)=\(encComponent($0.1))" }.joined(separator: "&")
    }

    static func pNo(pTs: String, pCa: String) -> String {
        sha256Hex("p_bd=1.0.1.19-fix.01&p_ca=\(pCa)&p_ts=\(pTs)&p_ver=1.1.4-beta.5&p_zt=3.3.34-beta.10&passport_jssdk_version=3.4.13")
    }

    /// account_sdk_source_info：源码里 XOR 混淆的固定串（还原自 Amor5207/douyin-tv），
    /// 里面的 timeOrigin 每次请求按当前时间重算。自己瞎拼这套环境指纹会被判 4031 风控。
    static func accountSDKInfo() -> String {
        let origin = String(format: "%.1f", Double(Int(Date().timeIntervalSince1970 * 1000)) - 1250.3)
        guard let key = sdkInfoTemplate.range(of: #""timeOrigin":"#) else { return sdkInfoTemplate }
        let tail = sdkInfoTemplate[key.upperBound...]
        let rest = tail.firstIndex(of: ",").map { tail[$0...] } ?? ""
        return String(sdkInfoTemplate[..<key.upperBound]) + origin + rest
    }

    private static let sdkInfoTemplate = #"{"hardwareConcurrency":12,"webdriver":false,"chromedriver":false,"shelldriver":false,"plugins":5,"innerHeight":770,"innerWidth":1272,"outerHeight":0,"outerWidth":0,"webgl":{"vendor":"Google Inc. (Microsoft)","renderer":"ANGLE (Microsoft, Microsoft Basic Render Driver (0x0000008C) Direct3D11 vs_5_0 ps_5_0, D3D11)"},"automation":{"s":"00000000","c":"0001","p":"0000000","s1":"00000000","c1":"0000","p1":"0"},"performance":{"timeOrigin":1794654461688.7,"usedJSHeapSize":149136654,"navigationTiming":{"decodedBodySize":919703,"entryType":"navigation","initiatorType":"navigation","name":"https://www.douyin.com/","renderBlockingStatus":"non-blocking","serverTiming":"cdn-cache,edge,origin,inner,tt_agw","guleStart":843.5,"guleDuration":12.5}},"browser":{"t":"2859744564971","bit_protocol":"false","bit_helper":false}}"#

    enum Step { case strategy, qr, status, sms }

    static func base(_ step: Step, traceID: String, verifyFp: String?) -> [(String, String)] {
        var p: [(String, String)] = [
            ("passport_jssdk_version", "3.4.13"), ("passport_jssdk_type", "normal"), ("is_from_ttaccountsdk", "1"),
            ("aid", "6383"), ("language", "zh"), ("account_app_language", "zh-CN"), ("ts", dayTs),
        ]
        if step == .qr {
            p += [("next", host), ("need_short_url", "true"), ("need_logo", "false"), ("is_new_login", "1")]
        }
        // 手机号 send_code / sms_login（2026-11-28 真机抓官方登录页）：query 不带 ts、末尾带 is_new_login=1
        if step == .sms, let i = p.firstIndex(where: { $0.0 == "ts" }) { p.remove(at: i) }
        if step != .strategy {
            p += [("is_from_iesaccountsaas", "1"), ("p_ui", "2.4.15"), ("p_ca", "4.0.26"),
                  ("p_ca_real", "1.0.0.1013")]
            if let fp = verifyFp { p += [("fp", fp), ("verifyFp", fp)] }
        }
        p += [("account_sdk_source", "web"), ("account_sdk_source_info", x5(accountSDKInfo())),
              ("p_js_v", "3.4.13"), ("p_js_t", "pro"), ("p_zt", "3.3.34-beta.10"), ("p_ver", "1.1.4-beta.5"),
              ("p_ver_real", "0"), ("request_host", "https%3A%2F%2Fwww.douyin.com"), ("p_bd", "1.0.1.19-fix.01")]
        let pTs = String(Int(Date().timeIntervalSince1970 * 1000))
        p += [("p_ts", pTs), ("p_no", pNo(pTs: pTs, pCa: "4.0.26")), ("biz_trace_id", traceID)]
        p.append(step == .sms ? ("is_new_login", "1") : ("device_platform", "web_app"))
        return p
    }

    /// 加 sign / qs（前 10 个键 + body + app_key 做 sha256）；返回拼好的 query
    @MainActor
    static func signedQuery(_ base: [(String, String)], body: [(String, String)]) -> String {
        var params = base
        let sorted = params.map { $0.0 }.sorted()
        let first = Array(sorted.prefix(10))
        var raw = first.map { k in "\(k)=\(params.first { $0.0 == k }!.1)" }.joined(separator: "&")
        raw += "&" + body.map { "\($0.0)=\($0.1)" }.joined(separator: "&") + "&app_key=" + appKey
        params.append(("sign", sha256Hex(raw)))
        params.append(("qs", x5(first.joined(separator: ","))))
        if DYCookieJar.shared.value("__dd_ms_captured") == "1",
           let ms = DYCookieJar.shared.value("msToken"), !ms.isEmpty { params.append(("msToken", ms)) }
        // passport 接口同样要 a_bogus（缺了它扫码轮询会一直返回 error_code 4031「存在安全风险」）
        let rawQuery = query(params)
        let form = body.map { "\($0.0)=\(encComponent($0.1))" }.joined(separator: "&")
        let bogus = DYABogus.sign(query: rawQuery, form: form, userAgent: userAgent)
        return rawQuery + "&a_bogus=" + encComponent(bogus)
    }

    /// 手机号 send_code / sms_login 的 query：官方登录页这两个请求**没有 sign / qs**（扫码轮询才有），
    /// 只有 passport 公共参数 + msToken + a_bogus（a_bogus 连表单一起签）
    @MainActor
    static func smsQuery(_ base: [(String, String)], body: [(String, String)]) -> String {
        var params = base
        // 跟扫码同口径：msToken 只在服务端真下发过（X-Ms-Token）才带，自造的随机值不带
        if DYCookieJar.shared.value("__dd_ms_captured") == "1",
           let ms = DYCookieJar.shared.value("msToken"), !ms.isEmpty { params.append(("msToken", ms)) }
        let rawQuery = query(params)
        let form = body.map { "\($0.0)=\(encComponent($0.1))" }.joined(separator: "&")
        return rawQuery + "&a_bogus=" + encComponent(DYABogus.sign(query: rawQuery, form: form, userAgent: userAgent))
    }

    /// x-tt-passport-aid-sign = HMAC-SHA256(HKDF-SHA256(HMAC-SHA256(ts, appKey)), "aid=6383&path=…&ts=…")
    static func aidSign(_ path: String) -> String {
        let ts = dayTs
        let prk = hmac(key: Data(appKey.utf8), data: Data(ts.utf8))
        let okm = hkdf(prk: prk, length: 32)
        return hmac(key: okm, data: Data("aid=6383&path=\(path)&ts=\(ts)".utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    static func hmac(key: Data, data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    static func hkdf(prk: Data, length: Int) -> Data {
        var out = Data(), block = Data(), counter: UInt8 = 1
        while out.count < length {
            block = hmac(key: prk, data: block + Data([counter]))
            out += block
            counter += 1
        }
        return out.prefix(length)
    }

    @MainActor
    static func headers(path: String, post: Bool, traceID: String, portrait: String, dtrait: String?) -> [String: String] {
        var h: [String: String] = [
            "Accept": "application/json, text/javascript", "Accept-Language": "zh-CN,zh;q=0.9",
            "Accept-Encoding": "identity", "Origin": host, "Referer": host + "/",
            "User-Agent": userAgent, "web-sdk-version": "1", "x-tt-passport-aid-sign": aidSign(path),
            "x-tt-passport-trace-id": traceID, "x-tt-passport-verify-portrait": portrait,
        ]
        if let dt = dtrait { h["x-tt-session-dtrait"] = dt }
        if let csrf = DYCookieJar.shared.value("passport_csrf_token") ?? DYCookieJar.shared.value("passport_csrf_token_default"),
           !csrf.isEmpty { h["x-tt-passport-csrf-token"] = csrf }
        if post {
            h["Content-Type"] = "application/x-www-form-urlencoded"
            h["x-secsdk-csrf-token"] = "DOWNGRADE"
        }
        return h
    }
}

// MARK: - 自己的票据（原生登录后写接口用 ECDSA sign-type 0）

@MainActor
enum DYNativeTicket {
    private static let keyTag = "douduo_native_ec_key_v1"
    private static let ticketTag = "douduo_native_ticket_v1"

    struct Ticket: Codable {
        var ticket: String
        var tsSign: String
        var serverCert: String?
        var clientCert: String?
        var session: String?
    }

    private static var cachedKey: P256.Signing.PrivateKey?

    /// 本机自己生成的 P-256 密钥（登录时交给抖音绑定；PKCS#8 base64 存本地）
    static func key() -> P256.Signing.PrivateKey? {
        if let k = cachedKey { return k }
        if let b64 = UserDefaults.standard.string(forKey: keyTag), let d = Data(base64Encoded: b64),
           let k = try? P256.Signing.PrivateKey(derRepresentation: d) {
            cachedKey = k
            return k
        }
        let k = P256.Signing.PrivateKey()
        UserDefaults.standard.set(k.derRepresentation.base64EncodedString(), forKey: keyTag)
        UserDefaults.standard.synchronize()
        cachedKey = k
        return k
    }

    static var publicPoint: String { key()?.publicKey.x963Representation.base64EncodedString() ?? "" }

    /// 手机号 sms_login 请求头里带的那组（官方登录页就是在这一步把公钥交给抖音绑定的；sign-type 0 = 还没有票据可签）
    static var loginHeaders: [String: String] {
        ["bd-ticket-guard-ree-public-key": publicPoint, "bd-ticket-guard-version": "2",
         "bd-ticket-guard-web-version": "2", "bd-ticket-guard-web-sign-type": "0"]
    }

    /// 登录前：把公钥交给抖音绑定（cookie bd-ticket-guard-client-data），并要求网页域版本
    static func prepareLogin() {
        let data: [String: Any] = ["bd-ticket-guard-version": 2, "bd-ticket-guard-iteration-version": 1,
                                   "bd-ticket-guard-ree-public-key": publicPoint, "bd-ticket-guard-web-version": 2]
        guard let d = try? JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]) else { return }
        let b64 = d.base64EncodedString()
        let enc = b64.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? b64
        DYCookieJar.shared.set("bd_ticket_guard_client_data", enc)
        DYCookieJar.shared.set("bd_ticket_guard_client_web_domain", "2")
    }

    /// 抖音回给我们的服务端票据（响应头或 cookie）
    static func capture(_ response: HTTPURLResponse) {
        var raw = response.value(forHTTPHeaderField: "bd-ticket-guard-server-data")
        if raw == nil || raw?.isEmpty == true { raw = DYCookieJar.shared.value("bd_ticket_guard_server_data") }
        guard let raw, let t = parse(raw) else { return }
        save(Ticket(ticket: t.0, tsSign: t.1))
    }

    private static func parse(_ raw: String) -> (String, String)? {
        let decoded = raw.replacingOccurrences(of: "+", with: "%2B").removingPercentEncoding ?? raw
        guard let d = Data(base64Encoded: decoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/"))
            ?? Data(base64Encoded: decoded),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let ticket = o["ticket"] as? String, !ticket.isEmpty,
              let ts = o["ts_sign"] as? String, !ts.isEmpty else { return nil }
        return (ticket, ts)
    }

    private static func save(_ t: Ticket) {
        if let d = try? JSONEncoder().encode(t) { UserDefaults.standard.set(d, forKey: ticketTag); UserDefaults.standard.synchronize() }
    }

    static var saved: Ticket? {
        let raw = UserDefaults.standard.object(forKey: ticketTag)
        // 正常存的是 Data；早期调试种子/外部写入可能留下 JSON 字符串，两种都认，认出后统一改存 Data
        let d: Data? = (raw as? Data) ?? (raw as? String).flatMap { $0.data(using: .utf8) }
        if let d, let t = try? JSONDecoder().decode(Ticket.self, from: d) {
            if raw is String { save(t); DYLiveModel.log("DDNATIVE ticket migrated string→data") }
            return t
        }
        if raw != nil { DYLiveModel.log("DDNATIVE ticket unreadable type=\(String(describing: type(of: raw!)))") }
        // 兜底：重装/更新后偏好设置偶尔没及时读到，但 cookie 罐里还留着抖音回的票据，从罐里恢复（密钥也必须还在）
        guard UserDefaults.standard.string(forKey: keyTag) != nil,
              let raw = DYCookieJar.shared.value("bd_ticket_guard_server_data"), let p = parse(raw) else { return nil }
        let t = Ticket(ticket: p.0, tsSign: p.1)
        save(t)
        DYLiveModel.log("DDNATIVE ticket restored-from-jar")
        return t
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: ticketTag)
        UserDefaults.standard.removeObject(forKey: keyTag)
        cachedKey = nil
    }

    static var hasTicket: Bool { saved != nil }

    /// 票据/密钥不可用时的原因（只用于日志，不含密钥内容）
    static var debugWhy: String {
        guard let t = saved else { return "no-ticket" }
        guard let k = key() else { return "no-key" }
        return t.ticket.isEmpty ? "empty-ticket" : "ok:\(k.publicKey.x963Representation.count)"
    }

    /// path 的写签名头（sign-type 0：用登录时绑定的私钥签 ticket+path+timestamp，DER 格式）
    static func headers(path: String, now: Int = Int(Date().timeIntervalSince1970)) -> [String: String]? {
        guard let t = saved, let k = key() else { return nil }
        let payload = "ticket=\(t.ticket)&path=\(path)&timestamp=\(now)"
        guard let sig = try? k.signature(for: Data(payload.utf8)).derRepresentation.base64EncodedString() else { return nil }
        let client = #"{"ts_sign":"\#(t.tsSign)","req_content":"ticket,path,timestamp","req_sign":"\#(sig)","timestamp":\#(now)}"#
        return [
            "bd-ticket-guard-ree-public-key": publicPoint,
            "bd-ticket-guard-version": "2",
            "bd-ticket-guard-iteration-version": "1",
            "bd-ticket-guard-web-version": t.tsSign.hasPrefix("ts.1") ? "1" : "2",
            "bd-ticket-guard-web-sign-type": "0",
            "bd-ticket-guard-client-data": Data(client.utf8).base64EncodedString(),
        ]
    }
}
