// 原生直连抖音网页接口：Swift 自己算 a_bogus，用 App 共享的 WebKit 登录 cookie，不经过隐藏网页。
// 只承载「读」类接口与私信；评论写操作仍由网页安全 SDK 发（登录时绑定的票据密钥只在网页里）。
import Foundation
import WebKit

enum DYNative {
    /// 总开关：DouDuo N（对比包）默认开，正式包默认关。设置里可切。
    static let enabledKey = "douduo_native_api_v1"
    static var enabled: Bool {
        if let v = UserDefaults.standard.object(forKey: enabledKey) as? Bool { return v }
        return (Bundle.main.bundleIdentifier ?? "").hasSuffix(".native")
    }

    /// 只走原生（不回落网页）：DouDuo N 默认开，方便看清哪个接口原生不通。正式包默认关。
    static let nativeOnlyKey = "douduo_native_only_v1"
    static var nativeOnly: Bool {
        if let v = UserDefaults.standard.object(forKey: nativeOnlyKey) as? Bool { return v }
        return (Bundle.main.bundleIdentifier ?? "").hasSuffix(".native")
    }

    /// 原生写接口（发评论/点赞/收藏/关注…）：默认关。2026-11-27 真机实测原生发评论回 code 8 后登录被作废；
    /// 在模拟器里对齐网页真实请求前不许开。
    static let writeKey = "douduo_native_write_v1"
    /// DouDuo N 默认开（签名已改为网页同款 HMAC，模拟器小号实测发评论/赞/收藏不掉登录）；正式包默认关
    static var writeEnabled: Bool {
        if let v = UserDefaults.standard.object(forKey: writeKey) as? Bool { return v }
        return (Bundle.main.bundleIdentifier ?? "").hasSuffix(".native")
    }

    /// 原生发私信：默认关。2026-11-27 真机两次实测——imapi 直发一出去服务端立刻作废登录
    /// （之后所有请求回 "unexepcted session length"）。缺网页 IM 的身份令牌/票据签名，查清前不许开。
    static let imSendKey = "douduo_native_im_send_v1"
    static var imSendEnabled: Bool { UserDefaults.standard.bool(forKey: imSendKey) }

    /// 发请求与签名必须是同一个 UA，而且要和「登录时」的网页一致（Mac Safari）：
    /// 登录票据绑定在那个设备环境上，换成别的 UA 发写请求，服务端会当成异常设备作废登录。
    ///
    /// 两套设备环境不能混用（2026-11-27 真机：原生扫码登录 = Windows Chrome 环境，评论却按 Mac Safari 发，
    /// 第一条成功，第二条要求身份验证，第三条 403，随后抖音作废登录）：
    /// - 网页登录的会话 → Mac Safari（跟后台网页一致）
    /// - 原生扫码登录的会话 → Windows Chrome 131（跟登录时 passport 的环境指纹一致）
    @MainActor static var userAgent: String { DYNativeTicket.hasTicket ? DYPassport.userAgent : DouyinWeb.userAgent }
    static let host = "https://www.douyin.com"

    @MainActor static var baseParams: [(String, String)] { DYNativeTicket.hasTicket ? chromeParams : safariParams }

    /// 原生扫码登录会话的公共参数（照 Amor5207/douyin-tv 的 base()：Windows / Chrome 131 / Blink）
    static let chromeParams: [(String, String)] = [
        ("device_platform", "webapp"), ("aid", "6383"), ("channel", "channel_pc_web"), ("pc_client_type", "1"),
        ("version_code", "190500"), ("version_name", "19.5.0"), ("cookie_enabled", "true"),
        ("screen_width", "1536"), ("screen_height", "864"), ("browser_language", "zh-CN"),
        ("browser_platform", "Win32"), ("browser_name", "Chrome"), ("browser_version", "131.0.0.0"),
        ("browser_online", "true"), ("engine_name", "Blink"), ("engine_version", "131.0.0.0"),
        ("os_name", "Windows"), ("os_version", "10"), ("cpu_core_num", "16"), ("device_memory", "8"),
        ("platform", "PC"), ("downlink", "10"), ("effective_type", "4g"), ("round_trip_time", "50"),
    ]

    /// 网页登录会话的公共参数：与网页签名页脚本里的 base 完全一致（Mac / Safari 26 / WebKit）
    static let safariParams: [(String, String)] = [
        ("device_platform", "webapp"), ("aid", "6383"), ("channel", "channel_pc_web"), ("pc_client_type", "1"),
        ("pc_libra_divert", "Mac"), ("update_version_code", "170400"), ("support_h265", "1"), ("support_dash", "0"),
        ("version_code", "170400"), ("version_name", "17.4.0"), ("cookie_enabled", "true"),
        ("screen_width", "1440"), ("screen_height", "900"), ("browser_language", "zh-CN"),
        ("browser_platform", "MacIntel"), ("browser_name", "Safari"), ("browser_version", "26.0"),
        ("browser_online", "true"), ("engine_name", "WebKit"), ("engine_version", "605.1.15"),
        ("os_name", "Mac OS"), ("os_version", "10.15.7"), ("cpu_core_num", "8"), ("device_memory", "8"),
        ("platform", "PC"), ("downlink", "10"), ("effective_type", "4g"), ("round_trip_time", "50"),
    ]

    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.timeoutIntervalForRequest = 12
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.*")
    static func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s }
    static func query(_ pairs: [(String, String)]) -> String { pairs.map { "\(enc($0.0))=\(enc($0.1))" }.joined(separator: "&") }

    struct Response { let status: Int; let data: Data; let ms: Int }
    /// 最近一次写请求是否被人机验证（bdturing）拦下
    @MainActor static var lastBdturing = false
    /// 最近一次写请求的回应头里是否带了身份验证要求（风控：短时间评论太多等）
    @MainActor static var lastVerify = false
    /// 最近一次写请求回应头 x-tt-verify-passport-decision 的原值（只在内存里转给官方验证组件，不进日志）
    @MainActor static var lastVerifyDecision: String?
    /// 最近一次被人机验证（滑块）拦下的原生读接口路径与时间（空包 + x-vc-bdturing-parameters）
    @MainActor static var lastReadCaptcha: (path: String, at: Date)?
    @MainActor static func readWasCaptcha(_ pathPrefix: String, within: TimeInterval = 15) -> Bool {
        guard let c = lastReadCaptcha else { return false }
        return c.path.hasPrefix(pathPrefix) && Date().timeIntervalSince(c.at) < within
    }

    enum Failure: LocalizedError {
        case noLogin, noTicket, http(Int), empty
        var errorDescription: String? {
            switch self {
            case .noLogin: "未登录"
            case .noTicket: "登录票据未就绪"
            case .http(let s): "HTTP \(s)"
            case .empty: "抖音返回空响应"
            }
        }
    }
}

/// 从 App 共享的 WebKit cookie 里取抖音登录态（与网页、签名页同一份）
@MainActor
enum DYNativeCookies {
    private static var cached: (at: Date, header: String, map: [String: String])?

    static func invalidate() { cached = nil }

    static func load(maxAge: TimeInterval = 20) async -> (header: String, map: [String: String]) {
        // 原生登录过的会话：cookie 在 App 自己的罐里（登录流程拿到的那份）
        if DYNativeTicket.hasTicket, !(DYCookieJar.shared.value("sessionid") ?? "").isEmpty {
            return (DYCookieJar.shared.header, DYCookieJar.shared.cookies)
        }
        if let c = cached, Date().timeIntervalSince(c.at) < maxAge { return (c.header, c.map) }
        let all = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        var map: [String: String] = [:]
        // www 与 .douyin.com 同名时以 .douyin.com 为准（登录态写在根域）
        for c in all where c.domain == "www.douyin.com" { map[c.name] = c.value }
        for c in all where c.domain == ".douyin.com" || c.domain == "douyin.com" { map[c.name] = c.value }
        let header = map.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "; ")
        cached = (Date(), header, map)
        return (header, map)
    }

    static func loggedIn() async -> Bool {
        let m = await load().map
        return !(m["sessionid"] ?? m["sessionid_ss"] ?? "").isEmpty
    }
}

extension DYNative {
    /// 已签名 GET。`extra` 追加在公共参数后面；身份参数（msToken / uifid / verifyFp）从 cookie 补。
    @MainActor
    static func get(_ path: String, _ extra: [(String, String)], referer: String, needsLogin: Bool = false) async throws -> Response {
        let ck = await DYNativeCookies.load()
        if needsLogin, (ck.map["sessionid"] ?? "").isEmpty { throw Failure.noLogin }
        var pairs = baseParams + extra
        if let ms = ck.map["msToken"], !ms.isEmpty { pairs.append(("msToken", ms)) }
        let uifid = ck.map["UIFID"] ?? ck.map["UIFID_TEMP"] ?? ""
        if !uifid.isEmpty { pairs.append(("uifid", uifid)) }
        if let fp = ck.map["s_v_web_id"], !fp.isEmpty { pairs.append(("verifyFp", fp)); pairs.append(("fp", fp)) }
        let qs = query(pairs)
        let url = URL(string: host + path + "?" + qs + "&a_bogus=" + enc(DYABogus.sign(query: qs, userAgent: userAgent)))!
        var r = URLRequest(url: url)
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        r.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        r.setValue(referer, forHTTPHeaderField: "Referer")
        r.setValue(host, forHTTPHeaderField: "Origin")
        if !uifid.isEmpty { r.setValue(uifid, forHTTPHeaderField: "uifid") }
        r.setValue("1", forHTTPHeaderField: "x-tt-argus")
        if !DYDtrait.session.isEmpty { r.setValue(DYDtrait.session, forHTTPHeaderField: "x-tt-session-dtrait") }
        if !ck.header.isEmpty { r.setValue(ck.header, forHTTPHeaderField: "Cookie") }
        let t0 = Date()
        let (d, resp) = try await session.data(for: r)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        return Response(status: status, data: d, ms: Int(Date().timeIntervalSince(t0) * 1000))
    }

    /// 已签名 POST 表单（写接口）：a_bogus 同时签 query 与表单，并带登录票据签名头。
    /// 票据读不到时抛错（不发），避免「缺票据 → 服务端 1101 作废登录」。
    @MainActor
    static func postForm(_ path: String, _ extra: [(String, String)], form: [(String, String)], referer: String,
                         ticketWeb: WKWebView?) async throws -> (Response, ticketResult: String?) {
        let ck = await DYNativeCookies.load()
        guard !(ck.map["sessionid"] ?? "").isEmpty else { throw Failure.noLogin }
        guard let tg = await DYSigning.headers(path: path, web: ticketWeb) else { throw Failure.noTicket }
        var pairs = baseParams + extra
        if let ms = ck.map["msToken"], !ms.isEmpty { pairs.append(("msToken", ms)) }
        let uifid = ck.map["UIFID"] ?? ck.map["UIFID_TEMP"] ?? ""
        if !uifid.isEmpty { pairs.append(("uifid", uifid)) }
        if let fp = ck.map["s_v_web_id"], !fp.isEmpty { pairs.append(("verifyFp", fp)); pairs.append(("fp", fp)) }
        if let wid = ck.map["webid"], !wid.isEmpty { pairs.append(("webid", wid)) }
        let qs = query(pairs)
        let body = query(form)
        let url = URL(string: host + path + "?" + qs + "&a_bogus=" + enc(DYABogus.sign(query: qs, form: body, userAgent: userAgent)))!
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.httpBody = Data(body.utf8)
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        r.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        r.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        r.setValue(referer, forHTTPHeaderField: "Referer")
        r.setValue(host, forHTTPHeaderField: "Origin")
        r.setValue("DOWNGRADE", forHTTPHeaderField: "x-secsdk-csrf-token")
        r.setValue("1", forHTTPHeaderField: "x-tt-argus")
        if !uifid.isEmpty { r.setValue(uifid, forHTTPHeaderField: "uifid") }
        for (k, v) in tg { r.setValue(v, forHTTPHeaderField: k) }
        if !DYDtrait.session.isEmpty { r.setValue(DYDtrait.session, forHTTPHeaderField: "x-tt-session-dtrait") }
        r.setValue(ck.header, forHTTPHeaderField: "Cookie")
        let t0 = Date()
        let (d, resp) = try await session.data(for: r)
        let h = resp as? HTTPURLResponse
        lastBdturing = h?.value(forHTTPHeaderField: "X-Vc-Bdturing-Parameters") != nil
        lastVerify = h?.value(forHTTPHeaderField: "x-vc-bdturing-parameters") != nil
            || (h?.allHeaderFields.keys.contains { "\($0)".lowercased().contains("verify") } ?? false)
        let decision = h?.value(forHTTPHeaderField: "x-tt-verify-passport-decision")?.trimmingCharacters(in: .whitespaces)
        lastVerifyDecision = (decision?.isEmpty == false) ? decision : nil
        return (Response(status: h?.statusCode ?? -1, data: d, ms: Int(Date().timeIntervalSince(t0) * 1000)),
                h?.value(forHTTPHeaderField: "Bd-Ticket-Guard-Result"))
    }
}

// MARK: - 评论（写）

private struct DYRawPublish: Decodable {
    let status_code: Int?
    let status_msg: String?
    let comment: DYRawComment?
}

/// 原生发评论的结果：调用方据此决定回落 / 提示 / 回查
enum DYNativePublishOutcome {
    /// 抖音明确收下，拿到正式评论
    case sent(DYComment)
    /// 没发出去（票据没读到、未登录、签名环境异常），可放心回落网页再发
    case notSent(String)
    /// 抖音明确拒绝（敏感词、频控等），不回落、不重发
    case rejected(Int, String?)
    /// 请求可能已到达抖音但结果不明：交给上层回查，不重发
    case unknown
    /// 200 空包 + 要求身份验证（风控）：上层回查确认没收下后，弹官方验证，通过再发一次
    case needsVerify(String)
}

extension DYNative {
    @MainActor
    static func publishComment(_ awemeID: String, text: String, replyID: String?, replyToReplyID: String?,
                               ticketWeb: WKWebView?, op: String) async -> DYNativePublishOutcome {
        var form: [(String, String)] = [("aweme_id", awemeID), ("text", text), ("text_extra", "[]"),
                                        ("comment_send_celltime", "0"), ("comment_video_celltime", "0")]
        if let replyID, !replyID.isEmpty, replyID != "0" {
            form.append(("reply_id", replyID))
            form.append(("reply_to_reply_id", (replyToReplyID?.isEmpty == false ? replyToReplyID! : "0")))
        }
        let extra: [(String, String)] = [("app_name", "aweme"), ("enter_from", "video_detail"), ("previous_page", "video_detail")]
        let result: (Response, ticketResult: String?)
        do {
            result = try await postForm("/aweme/v1/web/comment/publish", extra, form: form,
                                        referer: host + "/video/" + awemeID, ticketWeb: ticketWeb)
        } catch let f as Failure {
            DYLiveModel.log("DDSEND comment op=\(op) phase=native-not-sent why=\(f)")
            return .notSent(f.localizedDescription)
        } catch {
            // 请求可能已经发出（超时 / 断网发生在发送后）
            DYLiveModel.log("DDSEND comment op=\(op) phase=native-transport-unknown code=\((error as NSError).code)")
            return .unknown
        }
        let (r, tg) = result
        if r.data.isEmpty {
            DYLiveModel.log("DDSEND comment op=\(op) phase=native-empty hdrs=\(result.0.status) bdt=\(lastBdturing ? 1 : 0) verify=\(lastVerify ? 1 : 0) decision=\(lastVerifyDecision == nil ? 0 : 1)")
        }
        let p = try? JSONDecoder().decode(DYRawPublish.self, from: r.data)
        DYLiveModel.log("DDSEND comment op=\(op) phase=native-response http=\(r.status) code=\(p?.status_code.map(String.init) ?? "nil") tg=\(tg ?? "-") bytes=\(r.data.count) ms=\(r.ms)")
        if r.status == 200, p?.status_code == 0, let c = p?.comment?.model(topLevel: replyID == nil || replyID == "0"), !c.id.isEmpty {
            return .sent(c)
        }
        if let code = p?.status_code, code != 0 { return .rejected(code, p?.status_msg) }
        if r.data.isEmpty, let decision = lastVerifyDecision { return .needsVerify(decision) }
        return .unknown
    }
}

// MARK: - 评论（读）

/// 抖音评论接口原始结构里我们用到的那部分
private struct DYRawCommentPage: Decodable {
    let status_code: Int?
    let comments: [DYRawComment]?
    let cursor: Int?
    let has_more: Int?
    let total: Int?
}

fileprivate struct DYRawURL: Decodable { let url_list: [String]?; let width: Double?; let height: Double? }
fileprivate struct DYRawImage: Decodable { let origin_url: DYRawURL?; let medium_url: DYRawURL?; let thumb_url: DYRawURL?; let crop_url: DYRawURL? }
fileprivate struct DYRawSticker: Decodable { let static_url: DYRawURL?; let animate_url: DYRawURL?; let width: Double?; let height: Double? }
fileprivate struct DYRawUser: Decodable { let nickname: String?; let sec_uid: String?; let uid: DYFlexID?; let avatar_thumb: DYRawURL? }

/// 抖音的 id 有时是字符串、有时是数字；数字超出安全整数范围时视为无效（与网页脚本 ddStableID 口径一致）
fileprivate struct DYFlexID: Decodable {
    let value: String?
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { value = (s.isEmpty || s == "0") ? nil : s; return }
        if let n = try? c.decode(Int64.self) { value = (n > 0 && n <= 9_007_199_254_740_991) ? String(n) : nil; return }
        value = nil
    }
}

fileprivate struct DYRawComment: Decodable {
    let cid: DYFlexID?
    let text: String?
    let user: DYRawUser?
    let digg_count: Int?
    let create_time: Double?
    let reply_comment_total: Int?
    let ip_label: String?
    let user_digged: Int?
    let image_list: [DYRawImage]?
    let sticker: DYRawSticker?
    let reply_id: DYFlexID?
    let reply_to_reply_id: DYFlexID?
    let reply_comment: [DYRawComment]?

    private static func pick(_ o: DYRawURL?) -> (u: String, w: Double, h: Double)? {
        guard let u = o?.url_list?.first, !u.isEmpty else { return nil }
        return (u, o?.width ?? 0, o?.height ?? 0)
    }

    func model(topLevel: Bool) -> DYComment {
        let images: [DYCommentImage] = (image_list ?? []).compactMap { x in
            guard let m = Self.pick(x.medium_url) ?? Self.pick(x.thumb_url) ?? Self.pick(x.crop_url) ?? Self.pick(x.origin_url) else { return nil }
            let o = Self.pick(x.origin_url) ?? m
            return DYCommentImage(thumb: m.u, full: o.u, w: o.w > 0 ? o.w : m.w, h: o.h > 0 ? o.h : m.h)
        }
        var stk: DYCommentImage?
        if let s = sticker, let st = Self.pick(s.static_url) ?? Self.pick(s.animate_url) {
            let an = Self.pick(s.animate_url) ?? st
            stk = DYCommentImage(thumb: st.u, full: an.u, w: s.width ?? st.w, h: s.height ?? st.h)
        }
        return DYComment(id: cid?.value ?? "", text: text ?? "", name: user?.nickname ?? "",
                         avatar: user?.avatar_thumb?.url_list?.first, digg: digg_count ?? 0,
                         time: create_time ?? 0, replies: topLevel ? (reply_comment_total ?? 0) : 0, ip: ip_label,
                         sec: user?.sec_uid, userDigged: user_digged ?? 0, images: images, sticker: stk,
                         pinned: nil, parent: reply_id?.value, uid: user?.uid?.value, replyTo: reply_to_reply_id?.value)
    }
}

extension DYNative {
    /// 一级评论。返回 nil = 原生这次没拿到（交给网页兜底）；抛错只用于明确的业务拒绝。
    @MainActor
    static func comments(_ awemeID: String, cursor: Int, insert: String?) async -> (items: [DYComment], cursor: Int, hasMore: Bool, total: Int)? {
        var extra: [(String, String)] = [("aweme_id", awemeID), ("cursor", String(cursor)), ("count", "20"), ("item_type", "0"),
                                         ("whale_cut_token", ""), ("cut_version", "1"), ("rcFT", "")]
        if let insert, !insert.isEmpty { extra.append(("insert_ids", insert)) }
        do {
            let r = try await get("/aweme/v1/web/comment/list/", extra, referer: host + "/video/" + awemeID)
            guard r.status == 200, !r.data.isEmpty, let p = try? JSONDecoder().decode(DYRawCommentPage.self, from: r.data),
                  (p.status_code ?? 0) == 0 else {
                DYLiveModel.log("DDNATIVE comment fail http=\(r.status) bytes=\(r.data.count) ms=\(r.ms)")
                return nil
            }
            let ins = !(insert ?? "").isEmpty
            let items = (p.comments ?? []).map { c -> DYComment in
                var m = c.model(topLevel: true)
                if ins, let rc = c.reply_comment, !rc.isEmpty { m.pinned = rc.map { $0.model(topLevel: false) } }
                return m
            }
            DYLiveModel.log("DDNATIVE comment ok n=\(items.count) ms=\(r.ms)")
            return (items, p.cursor ?? 0, (p.has_more ?? 0) != 0, p.total ?? 0)
        } catch {
            DYLiveModel.log("DDNATIVE comment error \((error as NSError).code)")
            return nil
        }
    }

    /// 楼中楼回复。nil = 交给网页兜底。
    @MainActor
    static func replies(_ awemeID: String, commentID: String, cursor: Int) async -> (items: [DYComment], cursor: Int, hasMore: Bool)? {
        let extra: [(String, String)] = [("item_id", awemeID), ("comment_id", commentID), ("cut_version", "1"),
                                         ("cursor", String(cursor)), ("count", "10"), ("item_type", "0")]
        for path in ["/aweme/v2/web/comment/list/reply/", "/aweme/v1/web/comment/list/reply/"] {
            guard let r = try? await get(path, extra, referer: host + "/video/" + awemeID), r.status == 200, !r.data.isEmpty,
                  let p = try? JSONDecoder().decode(DYRawCommentPage.self, from: r.data), (p.status_code ?? 0) == 0,
                  p.comments != nil else { continue }
            let items = (p.comments ?? []).map { $0.model(topLevel: false) }
            DYLiveModel.log("DDNATIVE reply ok n=\(items.count) ms=\(r.ms)")
            return (items, p.cursor ?? 0, (p.has_more ?? 0) != 0)
        }
        DYLiveModel.log("DDNATIVE reply fail")
        return nil
    }
}
