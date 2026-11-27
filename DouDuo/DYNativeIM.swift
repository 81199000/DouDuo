// 原生私信：直连抖音网页 IM 后端 imapi.douyin.com（protobuf over HTTPS，只用登录 cookie 鉴权，不需要请求签名）。
// 信封与命令号参照 xianyulolo8/douyin-spark（MIT）的 douyin_im.py / spark.py；字段号经本机只读实测核对。
// 只做：拉会话列表、读某会话最近消息、发文字消息。发送结果严格核对回执，拿不准时报「未确认」，绝不自动重发。
import Foundation

// MARK: - 无 schema 的 protobuf 编解码

enum DYPB {
    typealias Fields = [Int: [Value]]
    enum Value {
        case int(UInt64)
        case bytes(Data)
        var int: UInt64? { if case .int(let v) = self { return v }; return nil }
        var data: Data? { if case .bytes(let d) = self { return d }; return nil }
        var string: String? { data.flatMap { String(data: $0, encoding: .utf8) } }
    }

    static func varint(_ v: UInt64) -> Data {
        var v = v, out = Data()
        repeat {
            var b = UInt8(v & 0x7f); v >>= 7
            if v != 0 { b |= 0x80 }
            out.append(b)
        } while v != 0
        return out
    }
    static func field(_ n: Int, _ v: UInt64) -> Data { varint(UInt64(n << 3)) + varint(v) }
    static func field(_ n: Int, _ d: Data) -> Data { varint(UInt64(n << 3 | 2)) + varint(UInt64(d.count)) + d }
    static func field(_ n: Int, _ s: String) -> Data { field(n, Data(s.utf8)) }

    static func decode(_ d: Data) -> Fields? {
        let b = [UInt8](d)
        var out: Fields = [:]
        var i = 0
        func readVarint() -> UInt64? {
            var shift: UInt64 = 0, v: UInt64 = 0
            while i < b.count, shift <= 63 {
                let x = b[i]; i += 1
                v |= UInt64(x & 0x7f) << shift
                if x & 0x80 == 0 { return v }
                shift += 7
            }
            return nil
        }
        parse: while i < b.count {
            guard let key = readVarint() else { break }
            let n = Int(key >> 3), wire = key & 7
            guard n > 0 else { break }
            switch wire {
            case 0: guard let v = readVarint() else { break parse }; out[n, default: []].append(.int(v))
            case 1: guard i + 8 <= b.count else { break parse }; out[n, default: []].append(.bytes(Data(b[i..<i + 8]))); i += 8
            case 2:
                guard let len = readVarint(), i + Int(len) <= b.count else { break parse }
                out[n, default: []].append(.bytes(Data(b[i..<i + Int(len)]))); i += Int(len)
            case 5: guard i + 4 <= b.count else { break parse }; out[n, default: []].append(.bytes(Data(b[i..<i + 4]))); i += 4
            default: break parse
            }
        }
        return out.isEmpty && !b.isEmpty ? nil : out
    }

    /// 只描述结构（字段号:线型），不含任何内容，供日志定位
    static func shape(_ d: Data) -> String {
        guard let f = decode(d) else { return "undecodable(\(d.count))" }
        return f.keys.sorted().map { k in
            let v = f[k]!.first!
            if case .int(let x) = v { return "\(k)=\(x < 100000 ? String(x) : "big")" }
            return "\(k):b\(v.data?.count ?? 0)"
        }.joined(separator: ",")
    }
}

extension DYPB.Fields {
    func int(_ n: Int) -> UInt64? { self[n]?.first?.int }
    func data(_ n: Int) -> Data? { self[n]?.first?.data }
    func string(_ n: Int) -> String? { self[n]?.first?.string }
    func sub(_ n: Int) -> DYPB.Fields? { data(n).flatMap(DYPB.decode) }
}

// MARK: - 数据

struct DYIMConversation: Equatable {
    let id: String          // 与网页 React 里的 conversation.id 一致（DYConversationRow.id = "conversation:" + id）
    let shortID: UInt64
    let type: Int           // 1 单聊 / 2 群聊
    let ticket: String      // 发消息要带的会话票据
    let name: String
}

struct DYIMMessage: Equatable {
    let serverID: UInt64
    let type: Int           // 7 = 普通消息（content 里 aweType 区分文字/视频卡等）
    let sender: UInt64
    let createdMS: UInt64
    let content: String     // JSON 原文
    var text: String? {
        guard let d = content.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return o["text"] as? String
    }
}

enum DYIMError: LocalizedError {
    case noLogin, badResponse(String), rejected(String), unconfirmed
    var errorDescription: String? {
        switch self {
        case .noLogin: "未登录抖音"
        case .badResponse(let s): "私信接口返回异常（\(s)）"
        case .rejected(let s): "抖音没有接受这条消息（\(s)）"
        case .unconfirmed: "发送结果未确认，请先查看聊天记录"
        }
    }
}

// MARK: - 客户端

@MainActor
final class DYNativeIM {
    static let shared = DYNativeIM()
    static let host = "https://imapi.douyin.com"
    enum Cmd: Int { case send = 100, messages = 301, info = 610, initSync = 2043 }
    static let paths: [Cmd: String] = [.send: "/v1/message/send", .messages: "/v1/message/get_by_conversation",
                                       .info: "/v2/conversation/get_info_list", .initSync: "/v1/message/get_message_by_init"]

    private var seq = UInt64(10000 + Int(Date().timeIntervalSince1970) % 50000)
    private(set) var selfUID: UInt64 = 0
    /// 会话缓存（id → 会话），拿票据用
    private(set) var conversations: [String: DYIMConversation] = [:]
    #if DEBUG
    var debugLastInitItem: Data?
    #endif

    /// 信封（cb_req.proto Request）。字段与参考实现 catbus normalRequest 对齐：
    /// 1 cmd / 2 seq / 3 sdk / 5 refer=3 / 7 build / 8 body / 9 device_id / 11 platform / 14 version_code /
    /// 15 headers(map) / 18 auth_type=4 / 21 biz / 22 access。发送时 headers 里加 identity_security_*。
    private func envelope(_ cmd: Cmd, _ payload: Data, identity: (token: String, deviceID: String)? = nil) -> Data {
        seq += 1
        let ua = DYNative.userAgent
        let chrome = DYNativeTicket.hasTicket
        var meta: [(String, String)] = [
            ("session_aid", "6383"), ("session_did", "0"), ("app_name", "douyin_pc"), ("priority_region", "cn"),
            ("user_agent", ua), ("cookie_enabled", "true"), ("browser_language", "zh-CN"),
            ("browser_platform", chrome ? "Win32" : "MacIntel"), ("browser_name", "Mozilla"),
            ("browser_version", String(ua.dropFirst("Mozilla/".count))), ("browser_online", "true"),
            ("screen_width", chrome ? "1920" : "1440"), ("screen_height", chrome ? "1080" : "900"),
            ("referer", "https://www.douyin.com/"), ("timezone_name", "Asia/Shanghai"), ("deviceId", "0"), ("is-retry", "0"),
        ]
        if let identity {
            if !identity.token.isEmpty { meta.append(("identity_security_token", #"{"token":"\#(identity.token)"}"#)) }
            if !identity.deviceID.isEmpty { meta.append(("identity_security_device_id", identity.deviceID)) }
            meta.append(("identity_security_aid", ""))
        }
        var d = DYPB.field(1, UInt64(cmd.rawValue)) + DYPB.field(2, seq) + DYPB.field(3, "0.1.8")
        d += DYPB.field(5, 3) + DYPB.field(7, "0d50935:feat/pc-im-groupB")
        d += DYPB.field(8, DYPB.field(cmd.rawValue, payload)) + DYPB.field(9, "0") + DYPB.field(11, "douyin_pc")
        d += DYPB.field(14, "360000")
        for (k, v) in meta { d += DYPB.field(15, DYPB.field(1, k) + DYPB.field(2, v)) }
        d += DYPB.field(18, 4) + DYPB.field(21, "douyin_web") + DYPB.field(22, "web_sdk")
        return d
    }

    /// 私信发送前要取的短时身份安全令牌（scene=web_im），缓存 240 秒。参照 Amor5207/douyin-tv imIdentity 与 catbus identityToken。
    private var identityCache: (token: String, deviceID: String, at: Date)?
    func identityToken(force: Bool = false) async throws -> (token: String, deviceID: String) {
        if !force, let c = identityCache, Date().timeIntervalSince(c.at) < 240 { return (c.token, c.deviceID) }
        let path = "/passport/safe/get_identity_security_token/"
        let ck = await DYNativeCookies.load()
        guard !(ck.map["sessionid"] ?? "").isEmpty else { throw DYIMError.noLogin }
        let trace = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8))
        var pairs: [(String, String)] = [
            ("passport_jssdk_version", "4.2.3"), ("passport_jssdk_type", "lite"), ("is_from_ttaccountsdk", "1"), ("aid", "6383"),
            ("language", "zh"), ("scene", "web_im"), ("auto_retry_req", "0"), ("skip_verify", "false"),
            ("identity_token_force_get_tag", "0"), ("biz_trace_id", trace), ("id_token_version", "1.2.10"),
        ]
        if let ms = ck.map["msToken"], !ms.isEmpty { pairs.append(("msToken", ms)) }
        let qs = DYNative.query(pairs)
        let url = URL(string: DYNative.host + path + "?" + qs + "&a_bogus=" + DYNative.enc(DYABogus.sign(query: qs, userAgent: DYNative.userAgent)))!
        var r = URLRequest(url: url)
        var h = DYPassport.headers(path: path, post: false, traceID: trace, portrait: "", dtrait: DYDtrait.session.isEmpty ? nil : DYDtrait.session)
        h["Referer"] = DYNative.host + "/chat?isPopup=1"
        h["x-tt-argus"] = "1"
        h["User-Agent"] = DYNative.userAgent
        h.removeValue(forKey: "x-tt-passport-verify-portrait")
        let uifid = ck.map["UIFID"] ?? ck.map["UIFID_TEMP"] ?? ""
        if !uifid.isEmpty { h["uifid"] = uifid }
        if let tg = DYNativeTicket.headers(path: path) { for (k, v) in tg { h[k] = v } }
        for (k, v) in h { r.setValue(v, forHTTPHeaderField: k) }
        r.setValue(ck.header, forHTTPHeaderField: "Cookie")
        let (data, resp) = try await DYNative.session.data(for: r)
        let http = (resp as? HTTPURLResponse)?.statusCode ?? -1
        let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let dd = o?["data"] as? [String: Any]
        let token = dd?["identity_security_token"] as? String ?? ""
        let did = dd.flatMap { $0["device_id"].map { "\($0)" } } ?? ""
        DYLiveModel.log("DDNATIVEIM identity http=\(http) msg=\(o?["message"] as? String ?? "-") err=\(dd?["error_code"].map { "\($0)" } ?? "-") token=\(token.count) did=\(did.count)")
        guard !token.isEmpty else { throw DYIMError.rejected("身份令牌未下发") }
        identityCache = (token, did, Date())
        return (token, did)
    }

    /// 发一条命令。网络错误原样抛出（调用方据此区分「肯定没发」和「可能发了」）。
    private func call(_ cmd: Cmd, _ payload: Data, identity: (token: String, deviceID: String)? = nil) async throws -> DYPB.Fields {
        let ck = await DYNativeCookies.load()
        guard !(ck.map["sessionid"] ?? "").isEmpty else { throw DYIMError.noLogin }
        let path = Self.paths[cmd]!
        var urlString = Self.host + path
        if cmd == .send {
            // 发送：query 带 msToken + a_bogus + verifyFp/fp（同参考实现）
            var pairs: [(String, String)] = []
            if let ms = ck.map["msToken"], !ms.isEmpty { pairs.append(("msToken", ms)) }
            let qs = DYNative.query(pairs)
            var full = qs + (qs.isEmpty ? "" : "&") + "a_bogus=" + DYNative.enc(DYABogus.sign(query: qs, userAgent: DYNative.userAgent))
            if let fp = ck.map["s_v_web_id"], !fp.isEmpty { full += "&verifyFp=" + DYNative.enc(fp) + "&fp=" + DYNative.enc(fp) }
            urlString += "?" + full
        }
        var r = URLRequest(url: URL(string: urlString)!)
        r.httpMethod = "POST"
        r.httpBody = envelope(cmd, payload, identity: identity)
        for (k, v) in ["Accept": "application/x-protobuf", "Content-Type": "application/x-protobuf",
                       "Origin": "https://www.douyin.com", "Referer": "https://www.douyin.com/",
                       "User-Agent": DYNative.userAgent, "Cookie": ck.header] { r.setValue(v, forHTTPHeaderField: k) }
        if cmd == .send {
            // 发送必须带登录票据签名 + 会话指纹 + uifid（Amor imSignedHeaders）；拿不到票据就不发
            guard let tg = DYNativeTicket.headers(path: path) else { throw DYIMError.rejected("缺少登录票据") }
            for (k, v) in tg { r.setValue(v, forHTTPHeaderField: k) }
            if !DYDtrait.session.isEmpty { r.setValue(DYDtrait.session, forHTTPHeaderField: "x-tt-session-dtrait") }
            r.setValue("1", forHTTPHeaderField: "x-tt-argus")
            let uifid = ck.map["UIFID"] ?? ck.map["UIFID_TEMP"] ?? ""
            if !uifid.isEmpty { r.setValue(uifid, forHTTPHeaderField: "uifid") }
            r.setValue("DOWNGRADE", forHTTPHeaderField: "x-secsdk-csrf-token")
        }
        let t0 = Date()
        let (data, resp) = try await DYNative.session.data(for: r)
        let http = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard http == 200, let top = DYPB.decode(data) else {
            DYLiveModel.log("DDNATIVEIM cmd=\(cmd.rawValue) http=\(http) undecodable bytes=\(data.count) ctype=\((resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? "-")")
            throw DYIMError.badResponse("HTTP \(http)")
        }
        let status = top.int(3) ?? 0
        let msg = top.string(4) ?? ""
        let safeMsg = String(msg.prefix(60)).filter { $0.isASCII }
        if cmd == .send { DYLiveModel.log("DDNATIVEIM send-top shape=\(DYPB.shape(data))") }
        DYLiveModel.log("DDNATIVEIM cmd=\(cmd.rawValue) status=\(status) msg=\(safeMsg) ms=\(Int(Date().timeIntervalSince(t0) * 1000))")
        if status != 0 {
            // 服务器明确答复了错误 = 这次没发出去
            if msg.lowercased().contains("session") { throw DYIMError.noLogin }
            throw DYIMError.rejected("\(status) \(safeMsg)")
        }
        if let uid = top.int(13), uid > 0 { selfUID = uid }
        guard let inner = top.sub(6)?.sub(cmd.rawValue) else { return [:] }
        return inner
    }

    private static func conversation(_ raw: Data) -> DYIMConversation? {
        guard let f = DYPB.decode(raw), let id = f.string(1), !id.isEmpty else { return nil }
        return DYIMConversation(id: id, shortID: f.int(2) ?? 0, type: Int(f.int(3) ?? 0),
                                ticket: f.string(4) ?? "", name: f.sub(50)?.string(5) ?? "")
    }

    /// 全部会话（分页同步，最多 maxPages 页）
    func loadConversations(maxPages: Int = 20) async throws -> [DYIMConversation] {
        var out: [DYIMConversation] = [], seen = Set<String>()
        var cursor: UInt64 = 0
        for page in 0..<maxPages {
            let payload = (cursor > 0 ? DYPB.field(1, cursor) : Data()) + DYPB.field(2, UInt64(page))
            let body = try await call(.initSync, payload)
            for item in body[1] ?? [] {
                #if DEBUG
                if debugLastInitItem == nil { debugLastInitItem = item.data }
                #endif
                guard let head = item.data.flatMap(DYPB.decode)?.data(1), let c = Self.conversation(head),
                      seen.insert(c.id).inserted else { continue }
                out.append(c)
            }
            let more = body.int(2) ?? 0
            cursor = body.int(3) ?? 0
            if more == 0 || cursor == 0 { break }
        }
        for c in out { conversations[c.id] = c }
        return out
    }

    /// 取一个会话（缓存没有就刷一遍列表）
    func conversation(_ id: String) async throws -> DYIMConversation? {
        if let c = conversations[id] { return c }
        _ = try await loadConversations()
        return conversations[id]
    }

    /// 某会话最近 limit 条消息（新→旧）
    func recentMessages(_ c: DYIMConversation, limit: Int = 30) async throws -> [DYIMMessage] {
        let payload = DYPB.field(1, c.id) + DYPB.field(2, UInt64(c.type)) + DYPB.field(3, c.shortID)
            + DYPB.field(4, 0) + DYPB.field(5, 0) + DYPB.field(6, UInt64(limit))
        let body = try await call(.messages, payload)
        return (body[1] ?? []).compactMap { v in
            guard let f = v.data.flatMap(DYPB.decode) else { return nil }
            return DYIMMessage(serverID: f.int(3) ?? 0, type: Int(f.int(6) ?? 0), sender: f.int(7) ?? 0,
                               createdMS: f.int(10) ?? 0, content: f.string(8) ?? "")
        }
    }

    /// 刷新单个会话（拿最新发送票据）
    private func refresh(_ c: DYIMConversation) async throws -> DYIMConversation {
        let body = try await call(.info, DYPB.field(1, DYPB.field(1, c.id) + DYPB.field(2, c.shortID) + DYPB.field(3, UInt64(c.type))))
        guard let raw = body.data(1), let fresh = Self.conversation(raw), fresh.id == c.id, !fresh.ticket.isEmpty else {
            throw DYIMError.badResponse("会话信息")
        }
        conversations[c.id] = fresh
        return fresh
    }

    /// 发文字。返回服务端消息 id。
    /// - 明确被拒 → .rejected（可重发）
    /// - 请求已发出但回执不完整 / 网络在发送中断 → .unconfirmed（不许自动重发）
    func sendText(_ text: String, to conversationID: String) async throws -> UInt64 {
        guard var c = try await conversation(conversationID) else { throw DYIMError.badResponse("找不到会话") }
        // 每次发送前都刷新会话拿最新发送票据（缓存票据会过期，过期时服务端回 status=1）
        do { c = try await refresh(c) } catch {
            DYLiveModel.log("DDNATIVEIM refresh fail \(error)")
            throw DYIMError.rejected("会话信息刷新失败")
        }
        // 身份安全令牌：拿不到就不发（缺它直发会被当异常会话、作废登录）
        let identity: (token: String, deviceID: String)
        do { identity = try await identityToken() } catch {
            DYLiveModel.log("DDNATIVEIM identity fail \(error)")
            throw DYIMError.rejected("身份令牌获取失败")
        }
        let clientID = UUID().uuidString.lowercased()
        let sentAt = UInt64(Date().timeIntervalSince1970 * 1000)
        let stime = String(format: "%.1f", Date().timeIntervalSince1970 * 1000)
        let content = try JSONSerialization.data(withJSONObject: ["aweType": 700, "type": 0, "richTextInfos": [] as [Any], "text": text],
                                                 options: [.sortedKeys, .withoutEscapingSlashes])
        func ext(_ k: String, _ v: String) -> Data { DYPB.field(5, DYPB.field(1, k) + DYPB.field(2, v)) }
        var msg = DYPB.field(1, c.id) + DYPB.field(2, UInt64(c.type)) + DYPB.field(3, c.shortID) + DYPB.field(4, content)
        msg += ext("a:chat_bubble", #"{"bubble_id":"-1","bubble_source":"0"}"#) + ext("s:mentioned_users", "")
        msg += ext("s:client_message_id", clientID) + ext("s:stime", stime)
        msg += DYPB.field(6, 7) + DYPB.field(7, c.ticket) + DYPB.field(8, clientID)
        let body: DYPB.Fields
        do {
            body = try await call(.send, msg, identity: identity)
        } catch let e as DYIMError {
            DYLiveModel.log("DDNATIVEIM send fail \(e)")
            if case .badResponse = e {
                if let found = await readBack(c, text: text, since: sentAt) {
                    DYLiveModel.log("DDNATIVEIM send confirmed-by-readback after=badResponse")
                    return found
                }
                throw DYIMError.unconfirmed
            }
            throw e
        } catch {
            // 网络在发送过程中断：服务器可能已经收到
            DYLiveModel.log("DDNATIVEIM send net-error \((error as NSError).code)")
            if let found = await readBack(c, text: text, since: sentAt) { return found }
            throw DYIMError.unconfirmed
        }
        DYLiveModel.log("DDNATIVEIM send-ack shape=\(body.keys.sorted().map(String.init).joined(separator: ","))")
        let serverID = body.int(1) ?? 0
        let echoed = body.string(4) ?? ""
        let status = body.int(3) ?? 0, extra = body.int(5) ?? 0
        DYLiveModel.log("DDNATIVEIM send server=\(serverID > 0) echo=\(echoed == clientID) status=\(status)/\(extra)")
        if status != 0 || extra != 0 { throw DYIMError.rejected("\(status)/\(extra)") }
        if serverID > 0, echoed == clientID { return serverID }
        // 回执不完整：回读聊天记录确认（找我自己在发送之后发的、正文一致的那条）
        if let found = await readBack(c, text: text, since: sentAt) {
            DYLiveModel.log("DDNATIVEIM send confirmed-by-readback")
            return found
        }
        throw DYIMError.unconfirmed
    }

    /// 发送后回读：最多 3 次、间隔 0.8 秒
    private func readBack(_ c: DYIMConversation, text: String, since: UInt64) async -> UInt64? {
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 800_000_000) }
            guard let rows = try? await recentMessages(c, limit: 10) else { continue }
            if let m = rows.first(where: { $0.sender == selfUID && selfUID > 0 && $0.createdMS + 2000 >= since && $0.text == text }) {
                return m.serverID
            }
        }
        return nil
    }
}


#if DEBUG
/// 私信发送探针：DOUDUO_IMSEND=<文字> → 发给唯一的单聊会话（老板确认：小号唯一好友 = 老板大号），
/// 发完立即检查登录、回读确认。只发一条，不重试。
@MainActor enum DDIMSendProbe {
    static func run(_ text: String) async {
        try? await Task.sleep(nanoseconds: 8_000_000_000)
        do {
            let list = try await DYNativeIM.shared.loadConversations(maxPages: 3)
            let singles = list.filter { $0.type == 1 }
            guard singles.count == 1, let c = singles.first else {
                DYLiveModel.log("DDIMSEND abort singles=\(singles.count)"); return
            }
            DYLiveModel.log("DDIMSEND start conv=\(c.id.suffix(6)) len=\(text.count)")
            let t0 = Date()
            do {
                let sid = try await DYNativeIM.shared.sendText(text, to: c.id)
                DYLiveModel.log("DDIMSEND ok server=\(sid > 0) ms=\(Int(Date().timeIntervalSince(t0) * 1000))")
            } catch {
                DYLiveModel.log("DDIMSEND fail \(error)")
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            let again = try? await DYNativeIM.shared.loadConversations(maxPages: 1)
            let msgs = try? await DYNativeIM.shared.recentMessages(c, limit: 5)
            let mine = msgs?.filter { $0.sender == DYNativeIM.shared.selfUID && $0.text == text }.count ?? -1
            let selfOK = (try? await DouyinBridge.primary?.selfSecUid()) != nil
            DYLiveModel.log("DDIMSEND after reread=\(again?.count ?? -1) found=\(mine) profileSelf=\(selfOK)")
        } catch {
            DYLiveModel.log("DDIMSEND list fail \(error)")
        }
    }
}

/// 私信只读探针：DOUDUO_IMREAD=1 → 拉会话列表 + 第一个会话最近消息，只记条数/字段形状，不记内容，不发任何消息
@MainActor enum DDIMReadProbe {
    static func run() async {
        try? await Task.sleep(nanoseconds: 6_000_000_000)
        let t0 = Date()
        do {
            let list = try await DYNativeIM.shared.loadConversations(maxPages: 3)
            let single = list.filter { $0.type == 1 }.count
            DYLiveModel.log("DDIMREAD convs n=\(list.count) single=\(single) ticket=\(list.filter { !$0.ticket.isEmpty }.count) named=\(list.filter { !$0.name.isEmpty }.count) self=\(DYNativeIM.shared.selfUID > 0) ms=\(Int(Date().timeIntervalSince(t0) * 1000))")
            // 会话条目结构（只记字段号 / 线型 / 长度）
            if let raw = DYNativeIM.shared.debugLastInitItem {
                DYLiveModel.log("DDIMREAD item shape=\(DYPB.shape(raw))")
                if let f = DYPB.decode(raw) {
                    for k in f.keys.sorted() { if let d = f[k]?.first?.data, d.count > 2 { DYLiveModel.log("DDIMREAD item.\(k) shape=\(DYPB.shape(d).prefix(400))") } }
                    if let head = f.data(1), let h = DYPB.decode(head) {
                        for k in h.keys.sorted() { if let d = h[k]?.first?.data, d.count > 2, DYPB.decode(d) != nil { DYLiveModel.log("DDIMREAD head.\(k) shape=\(DYPB.shape(d).prefix(300))") } }
                    }
                }
            }
            for c in list.prefix(3) {
                let msgs = try await DYNativeIM.shared.recentMessages(c, limit: 20)
                let mine = msgs.filter { $0.sender == DYNativeIM.shared.selfUID }.count
                let texts = msgs.filter { $0.text != nil }.count
                let types = Set(msgs.map(\.type)).sorted().map(String.init).joined(separator: ",")
                DYLiveModel.log("DDIMREAD msgs conv=\(c.id.suffix(6)) type=\(c.type) n=\(msgs.count) mine=\(mine) text=\(texts) types=\(types)")
            }
            // 身份令牌（只取，不发消息）
            do { let id = try await DYNativeIM.shared.identityToken(force: true); DYLiveModel.log("DDIMREAD identity token=\(id.token.count) did=\(id.deviceID.count)") }
            catch { DYLiveModel.log("DDIMREAD identity fail \(error)") }
            // 取完令牌再读一次，确认没被踢
            let again = try? await DYNativeIM.shared.loadConversations(maxPages: 1)
            let after = await DYNativeCookies.load()
            DYLiveModel.log("DDIMREAD done loggedIn=\(!(after.map["sessionid"] ?? "").isEmpty) reread=\(again?.count ?? -1)")
        } catch {
            DYLiveModel.log("DDIMREAD fail \(error)")
        }
    }
}
#endif
