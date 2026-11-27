// 原生私信：直连抖音网页 IM 后端 imapi.douyin.com（protobuf over HTTPS，只用登录 cookie 鉴权，不需要请求签名）。
// 信封与命令号参照 xianyulolo8/douyin-spark（MIT）的 douyin_im.py / spark.py；字段号经本机只读实测核对。
// 只做：拉会话列表、读某会话最近消息、发文字消息。发送结果严格核对回执，拿不准时报「未确认」，绝不自动重发。
import Foundation
import UIKit
import WebKit

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
    /// 以下字段来自 ConversationInfoV2（core_info=50 / setting_info=51）与 init 同步里的最后一条消息
    var avatar: String = ""         // 群头像（core_info.icon）
    var badge: Int = 0              // 未读角标（10 badge_count）
    var readBadge: Int = 0          // 已读到的角标（setting_info.read_badge_count）
    var pinned = false              // setting_info.stick_on_top
    var muted = false               // setting_info.mute
    var peerUID: UInt64 = 0         // 单聊对方 uid（会话 id 0:1:a:b 里不是自己的那个）
    var peerSec: String = ""        // 单聊对方 sec_uid（最后一条消息若由对方发出，取 sec_sender）
    var last: DYIMMessage?          // 最后一条消息
    var participants: [(uid: UInt64, sec: String)] = []
    var mode = 0                         // core_info.mode（16）：非 0 = 陌生人关系会话
    var coreExt: [String: String] = [:]  // core_info.ext（11）
    var settingExt: [String: String] = [:] // setting_info.ext（9）
    var onlySystem = true                // 随 init 下发的消息全是系统提示（或没有消息）

    /// 官方私信页主列表的过滤（照网页 IM 的 sortedConversationIdList）：
    /// 折叠会话进「折叠箱」、不是本 App 可见的不显示、「陌生人待回复」且只有系统提示的不显示
    var hiddenInMainList: Bool {
        if settingExt["a:s_is_folded"] == "1" { return true }
        if let apps = coreExt["a:visible_app_id"], !apps.isEmpty,
           !apps.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }).contains("6383") { return true }
        if type == 1, mode != 0, onlySystem { return true }
        return false
    }
    static func == (a: DYIMConversation, b: DYIMConversation) -> Bool {
        a.id == b.id && a.ticket == b.ticket && a.badge == b.badge && a.readBadge == b.readBadge && a.pinned == b.pinned
            && a.muted == b.muted && a.last == b.last && a.name == b.name && a.avatar == b.avatar
    }
    var unread: Int { max(0, badge - readBadge) }
}

struct DYIMMessage: Equatable, Identifiable {
    let serverID: UInt64
    let type: Int           // 7 = 普通消息（content 里 aweType 区分文字/视频卡等）
    let sender: UInt64
    let createdMS: UInt64
    let content: String     // JSON 原文
    var secSender: String = ""
    var index: UInt64 = 0           // index_in_conversation（翻页游标）
    var status: Int = 0             // 12 status
    var clientID: String = ""       // ext s:client_message_id
    var ext: [String: String] = [:]
    /// 系统提示（SYSTEM=1 / SYSTEM_COMPAT=1006 / 服务端下发）：如「对方回复或关注你之前，只能发送一条文字消息」
    var isSystem: Bool { type == 1 || type == 1006 || ext["a:is_server"] == "true" }
    /// 同官方 Message.visible：服务端禁用(status=1)、特殊消息(≥50000)不显示；s:visible / s:invisible 名单按自己 uid 判断
    func visible(to me: UInt64) -> Bool {
        if status == 1 || type >= 50000 { return false }
        guard me > 0 else { return true }
        let mine = String(me)
        if let v = ext["s:visible"], !v.isEmpty { return v.split(separator: ",").contains { $0 == mine } }
        if let v = ext["s:invisible"], !v.isEmpty { return !v.split(separator: ",").contains { $0 == mine } }
        return true
    }
    var id: String { serverID > 0 ? String(serverID) : clientID }
    var json: [String: Any] {
        guard let d = content.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return o
    }
    var text: String? { json["text"] as? String }

    /// 消息内容分类（抖音 aweType）：只解析界面要画的几类，其余按「未支持」显示提示
    enum Body: Equatable {
        case text(String)
        case sticker(url: URL?, width: Int, height: Int)
        /// 私信图片：服务端存的是 AES-256-GCM 加密文件，skey 为十六进制密钥（同官方 imageDecryptor）
        case image(url: URL?, width: Int, height: Int, skey: String)
        case video(itemID: String, cover: URL?, title: String, author: String, width: Int, height: Int)
        case recalled
        case system(String)
        case unsupported(Int)
    }
    var body: Body {
        let o = json
        let awe = (o["aweType"] as? NSNumber)?.intValue ?? 0
        func url(_ key: String) -> URL? {
            let d = o[key] as? [String: Any]
            return ((d?["url_list"] as? [String])?.first).flatMap(URL.init(string:))
        }
        func int(_ key: String) -> Int { (o[key] as? NSNumber)?.intValue ?? 0 }
        if isSystem {
            let t = (o["text"] as? String) ?? (o["tips"] as? String) ?? (o["hint_content"] as? String) ?? ""
            return .system(t.isEmpty ? "[系统消息]" : t)
        }
        if type == 7 || awe == 700 || awe == 0, let t = o["text"] as? String { return .text(t) }
        switch awe {
        case 500...599:
            return .sticker(url: url("url"), width: int("width"), height: int("height"))
        case 800, 801, 802, 803:
            let id = o["itemId"] as? String ?? (o["itemId"] as? NSNumber)?.stringValue ?? ""
            return .video(itemID: id, cover: url("cover_url") ?? url("content_thumb"),
                          title: o["content_title"] as? String ?? "", author: o["content_name"] as? String ?? "",
                          width: int("cover_width"), height: int("cover_height"))
        case 11054, 11055:
            // 团购 / 地点视频卡（LIFE_MSG_VIDEO_POI）：item_id + cover_url + description
            let cover = o["cover_url"] as? [String: Any]
            let id = o["item_id"] as? String ?? (o["item_id"] as? NSNumber)?.stringValue ?? ""
            return .video(itemID: id, cover: ((cover?["url_list"] as? [String])?.first).flatMap(URL.init(string:)),
                          title: o["description"] as? String ?? "", author: "",
                          width: (cover?["width"] as? NSNumber)?.intValue ?? 0, height: (cover?["height"] as? NSNumber)?.intValue ?? 0)
        case 2702, 2701, 2703:
            let r = o["resource_url"] as? [String: Any] ?? [:]
            let list = (r["origin_url_list"] as? [String]) ?? (r["large_url_list"] as? [String]) ?? (r["medium_url_list"] as? [String]) ?? (r["url_list"] as? [String]) ?? []
            let w = int("cover_width") > 0 ? int("cover_width") : (r["width"] as? NSNumber)?.intValue ?? 0
            let h = int("cover_height") > 0 ? int("cover_height") : (r["height"] as? NSNumber)?.intValue ?? 0
            return .image(url: list.first.flatMap(URL.init(string:)), width: w, height: h, skey: r["skey"] as? String ?? "")
        default:
            if type == 15, let hello = o["hello_text"] as? String { return .system("[打招呼] " + hello) }
            if let t = o["text"] as? String, !t.isEmpty { return .text(t) }
            if let tip = (o["tips"] as? String) ?? (o["hint_content"] as? String), !tip.isEmpty { return .system(tip) }
            return .unsupported(awe)
        }
    }
    /// 会话列表里的一行预览
    var preview: String {
        switch body {
        case .text(let t): t
        case .sticker: "[表情]"
        case .image: "[图片]"
        case .video(_, _, let title, _, _, _): title.isEmpty ? "[视频]" : "[视频] " + title
        case .recalled: "[已撤回]"
        case .system(let t): t
        case .unsupported: "[消息]"
        }
    }
}

/// 抖音用户（私信头像 / 昵称）
struct DYIMUser: Codable, Equatable {
    let uid: String
    let sec: String
    let name: String
    let avatar: String
    /// 我是否关注对方（0 未关注 / 1 已关注 / 2 互关…）、对方是否关注我；同官方私信页 usersInfoStore 的字段。nil = 接口没给
    var follow: Int? = nil
    var follower: Int? = nil
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

    /// 信封（cb_req.proto Request）。逐字段照官方私信网页抓包（2026-11-27 模拟器 DOUDUO_IMCAP 干跑）：
    /// 1 cmd / 2 seq / 3 "0.1.8" / 4 "" / 5 refer=3 / 6 0 / 7 build / 8 body / 9 "0" / 11 douyin_pc / 14 "360000" /
    /// 15 headers（发送时 identity_security_* 在最前）/ 18 auth_type=1 / 21 douyin_web / 22 web_sdk。
    /// 环境字段与私信网页本身一致（UA = 网页 UA、browser_platform = navigator.platform、屏幕 = 真实尺寸、referer 空）。
    private func envelope(_ cmd: Cmd, _ payload: Data, identity: (token: String, deviceID: String)? = nil) -> Data {
        seq += 1
        let ua = DouyinWeb.userAgent
        let screen = UIScreen.main.bounds.size
        var meta: [(String, String)] = []
        if let identity {
            meta.append(("identity_security_token", #"{"token":"\#(identity.token)"}"#))
            meta.append(("identity_security_device_id", identity.deviceID))
            meta.append(("identity_security_aid", ""))
        }
        meta += [
            ("session_aid", "6383"), ("session_did", "0"), ("app_name", "douyin_pc"), ("priority_region", "cn"),
            ("user_agent", ua), ("cookie_enabled", "true"), ("browser_language", "zh-CN"),
            ("browser_platform", UIDevice.current.userInterfaceIdiom == .pad ? "MacIntel" : "iPhone"), ("browser_name", "Mozilla"),
            ("browser_version", String(ua.dropFirst("Mozilla/".count))), ("browser_online", "true"),
            ("screen_width", String(Int(screen.width))), ("screen_height", String(Int(screen.height))),
            ("referer", ""), ("timezone_name", "Asia/Shanghai"), ("deviceId", "0"), ("is-retry", "0"),
        ]
        var d = DYPB.field(1, UInt64(cmd.rawValue)) + DYPB.field(2, seq) + DYPB.field(3, "0.1.8") + DYPB.field(4, "")
        d += DYPB.field(5, 3) + DYPB.field(6, 0) + DYPB.field(7, "0d50935:feat/pc-im-group")
        d += DYPB.field(8, DYPB.field(cmd.rawValue, payload)) + DYPB.field(9, "0") + DYPB.field(11, "douyin_pc")
        d += DYPB.field(14, "360000")
        for (k, v) in meta { d += DYPB.field(15, DYPB.field(1, k) + DYPB.field(2, v)) }
        d += DYPB.field(18, 1) + DYPB.field(21, "douyin_web") + DYPB.field(22, "web_sdk")
        return d
    }

    /// 私信网页（同一 WebKit 存储）里的票据：网页 SDK 与服务端协商的那套（HMAC sign-type 1）。
    /// 私信服务认的是这套设备身份；用原生扫码那把 ECDSA 密钥签会变成「同一会话两台设备」，几条后作废登录。
    private func webTicket() async -> DYTicketBundle? {
        #if DEBUG
        if let web = DouyinBridge.primary?.web {
            let js = """
            (() => { const out = [];
              for (let i = 0; i < localStorage.length; i++) { const k = localStorage.key(i); if (!/security|ticket|crypt|bd_|protect|ecdh/i.test(k) || /tea_sdk/.test(k)) continue;
                const v = localStorage.getItem(k) || ''; let inner = '';
                const page = location.pathname;
                try { const o = JSON.parse(v); const d = typeof o.data === 'string' ? JSON.parse(o.data) : (o.data || o);
                      inner = Object.keys(d || {}).map(x => x + ':' + String(d[x] ?? '').length).join(','); } catch (e) {}
                out.push(k + '=' + v.length + ' {' + inner + '}'); }
              return location.pathname + ' :: ' + out.join(' | '); })()
            """
            if let r = try? await web.evaluateJavaScript(js) as? String { DYLiveModel.log("DDNATIVEIM ls \(r.prefix(1200))") }
        }
        #endif
        return await DYTicketStore.load(from: DouyinBridge.primary?.web)
    }

    /// 私信网页发请求带的 cookie（WebKit 共享存储），与网页一致
    private func webCookies() async -> String {
        let all = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        var map: [String: String] = [:]
        for c in all where c.domain == "www.douyin.com" { map[c.name] = c.value }
        for c in all where c.domain == ".douyin.com" || c.domain == "douyin.com" { map[c.name] = c.value }
        return map.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "; ")
    }

    /// 私信发送前要取的短时身份安全令牌（scene=web_im），缓存 240 秒。请求头逐项照私信网页抓包。
    private var identityCache: (token: String, deviceID: String, at: Date)?
    func identityToken(force: Bool = false) async throws -> (token: String, deviceID: String) {
        if !force, let c = identityCache, Date().timeIntervalSince(c.at) < 240 { return (c.token, c.deviceID) }
        let path = "/passport/safe/get_identity_security_token/"
        guard let tb = await webTicket(), let tg = DYTicketGuard.headers(tb, path: path) else { throw DYIMError.rejected("网页票据未就绪") }
        let ck = await DYNativeCookies.load()
        guard !(ck.map["sessionid"] ?? "").isEmpty else { throw DYIMError.noLogin }
        let trace = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8))
        var pairs: [(String, String)] = [
            ("passport_jssdk_version", "4.2.3"), ("passport_jssdk_type", "lite"), ("is_from_ttaccountsdk", "1"), ("aid", "6383"),
            ("language", "zh"), ("scene", "web_im"), ("auto_retry_req", "0"), ("skip_verify", "false"),
            ("identity_token_force_get_tag", "0"), ("biz_trace_id", trace), ("id_token_version", "1.2.10"),
        ]
        if let ms = ck.map["msToken"], !ms.isEmpty { pairs.append(("msToken", ms)) }
        let ua = DouyinWeb.userAgent
        let qs = DYNative.query(pairs)
        let url = URL(string: DYNative.host + path + "?" + qs + "&a_bogus=" + DYNative.enc(DYABogus.sign(query: qs, userAgent: ua)))!
        var r = URLRequest(url: url)
        r.setValue(ua, forHTTPHeaderField: "User-Agent")
        r.setValue("application/json, text/javascript", forHTTPHeaderField: "Accept")
        r.setValue(DYNative.host + "/chat?isPopup=1", forHTTPHeaderField: "Referer")
        r.setValue(trace, forHTTPHeaderField: "x-tt-passport-trace-id")
        if let csrf = ck.map["passport_csrf_token"] ?? ck.map["passport_csrf_token_default"], !csrf.isEmpty {
            r.setValue(csrf, forHTTPHeaderField: "x-tt-passport-csrf-token")
        }
        if !DYDtrait.session.isEmpty { r.setValue(DYDtrait.session, forHTTPHeaderField: "x-tt-session-dtrait") }
        for (k, v) in tg { r.setValue(v, forHTTPHeaderField: k) }
        r.setValue(await webCookies(), forHTTPHeaderField: "Cookie")
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


    /// 在隐藏网页（www.douyin.com）里发一个 XHR：网页安全 SDK 会像官方页面一样自动补票据签名、a_bogus、msToken。
    /// 私信服务认的是网页 SDK 那套设备身份（其私钥在网页里不可导出），所以发送必须经由它签名。
    /// 返回 (HTTP 状态, 响应字节, SDK 加的请求头名)。
    private func pageXHR(_ url: String, method: String, body: Data?, accept: String, extra: [String: String] = [:]) async throws -> (Int, Data, [String]) {
        // 优先私信网页（/chat，官方发私信的那一页：IM SDK 已初始化、长连接在线），没有再退到签名页
        let candidates = [DouyinWeb.chatWeb, DouyinBridge.primary?.web].compactMap { $0 }
        guard let web = candidates.first(where: { $0.url?.host == "www.douyin.com" }) else { throw DYIMError.rejected("网页未就绪") }
        DYLiveModel.log("DDNATIVEIM page=\(web.url?.path ?? "-")")
        let js = """
        const bin = b => { if (!b) return null; const s = atob(b); const u = new Uint8Array(s.length); for (let i = 0; i < s.length; i++) u[i] = s.charCodeAt(i); return u; };
        const enc = buf => { if (!buf) return ''; const u = new Uint8Array(buf); let s = ''; for (let i = 0; i < u.length; i++) s += String.fromCharCode(u[i]); return btoa(s); };
        const x = new XMLHttpRequest(); const names = [];
        // extra 里给定的票据头是「最终值」：安全 SDK 之后再设同名头一律改回、client-data 丢弃（照官方 IM SDK 实际发出的形态）
        const forced = {}; for (const [k, v] of Object.entries(extra || {})) if (/^bd-ticket-guard-/.test(k)) forced[k] = v;
        const lock = Object.keys(forced).length > 0;
        const set = x.setRequestHeader;
        x.setRequestHeader = function (k, v) {
          const n = String(k).toLowerCase(); names.push(n);
          if (lock && n === 'bd-ticket-guard-client-data') return;
          if (lock && n in forced) { if (this.__ddSet && this.__ddSet[n]) return; (this.__ddSet = this.__ddSet || {})[n] = 1; return set.call(this, k, forced[n]); }
          return set.apply(this, arguments);
        };
        return await new Promise(ok => {
          x.open(method, url, true); x.withCredentials = true; x.responseType = 'arraybuffer';
          x.setRequestHeader('accept', accept);
          for (const [k, v] of Object.entries(extra || {})) x.setRequestHeader(k, v);
          if (body) x.setRequestHeader('content-type', 'application/x-protobuf');
          x.onloadend = () => ok(JSON.stringify({ s: x.status, b: enc(x.response), h: names }));
          x.timeout = 15000; x.ontimeout = () => ok(JSON.stringify({ s: -2, b: '', h: names }));
          x.send(bin(body));
        });
        """
        let r = try await web.callAsyncJavaScript(js, arguments: ["url": url, "method": method, "body": body?.base64EncodedString() as Any, "accept": accept, "extra": extra], contentWorld: .page)
        guard let str = r as? String, let d = str.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { throw DYIMError.badResponse("页面请求无返回") }
        let status = o["s"] as? Int ?? -1
        let bytes = Data(base64Encoded: o["b"] as? String ?? "") ?? Data()
        let names = o["h"] as? [String] ?? []
        return (status, bytes, names)
    }

    /// 官方私信网页在原生扫码登录的会话下实际发出的票据头（2026-11-27 23:03 模拟器真发成功抓包）：
    /// 公钥空、sign-type 0、没有 client-data——即「不带票据签名」。网页安全 SDK 若自行补签，用的是跟这次登录不匹配的网页密钥，
    /// 服务端判定异常直接作废登录。预先设好这几个头，SDK 看到已存在就不再补签。
    static let officialGuardHeaders: [String: String] = [
        "bd-ticket-guard-ree-public-key": "", "bd-ticket-guard-version": "2",
        "bd-ticket-guard-web-sign-type": "0", "bd-ticket-guard-web-version": "2",
    ]

    /// 身份令牌（经网页 SDK 签名）
    func identityTokenViaPage(force: Bool = false) async throws -> (token: String, deviceID: String) {
        if !force, let c = identityCache, Date().timeIntervalSince(c.at) < 240 { return (c.token, c.deviceID) }
        let trace = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(8))
        let pairs: [(String, String)] = [
            ("passport_jssdk_version", "4.2.3"), ("passport_jssdk_type", "lite"), ("is_from_ttaccountsdk", "1"), ("aid", "6383"),
            ("language", "zh"), ("scene", "web_im"), ("auto_retry_req", "0"), ("skip_verify", "false"),
            ("identity_token_force_get_tag", "0"), ("biz_trace_id", trace), ("id_token_version", "1.2.10"),
        ]
        // passport 接口的 msToken / a_bogus / csrf / trace 头是 passport SDK 自己加的（不经 XHR 钩子），这里照官方补齐
        let ck = await DYNativeCookies.load()
        var q = pairs
        if let ms = ck.map["msToken"], !ms.isEmpty { q.append(("msToken", ms)) }
        let qs = DYNative.query(q)
        let full = qs + "&a_bogus=" + DYNative.enc(DYABogus.sign(query: qs, userAgent: DouyinWeb.userAgent))
        var extra = Self.officialGuardHeaders
        extra["x-tt-passport-trace-id"] = trace
        if let csrf = ck.map["passport_csrf_token"] ?? ck.map["passport_csrf_token_default"], !csrf.isEmpty { extra["x-tt-passport-csrf-token"] = csrf }
        let (http, data, names) = try await pageXHR(DYNative.host + "/passport/safe/get_identity_security_token/?" + full,
                                                   method: "GET", body: nil, accept: "application/json, text/javascript", extra: extra)
        let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let dd = o?["data"] as? [String: Any]
        let token = dd?["identity_security_token"] as? String ?? ""
        let did = dd.flatMap { $0["device_id"].map { "\($0)" } } ?? ""
        DYLiveModel.log("DDNATIVEIM identity via=page http=\(http) msg=\(o?["message"] as? String ?? "-") token=\(token.count) did=\(did.count) sdkHeaders=\(names.filter { $0.hasPrefix("bd-") || $0.hasPrefix("x-") }.joined(separator: ","))")
        guard !token.isEmpty else { throw DYIMError.rejected("身份令牌未下发") }
        identityCache = (token, did, Date())
        return (token, did)
    }

    /// 发送（经网页 SDK 签名）。返回解出的顶层字段；网络/页面失败原样抛出。
    private func sendViaPage(_ payload: Data, identity: (token: String, deviceID: String)) async throws -> DYPB.Fields {
        // verifyFp / fp / msToken / a_bogus 由网页安全 SDK 自己补（抓包确认），这里不加，免得重复
        let url = Self.host + Self.paths[.send]!
        let body = envelope(.send, payload, identity: identity)
        let t0 = Date()
        let (http, data, names) = try await pageXHR(url, method: "POST", body: body, accept: "application/x-protobuf", extra: Self.officialGuardHeaders)
        DYLiveModel.log("DDNATIVEIM send via=page http=\(http) bytes=\(data.count) ms=\(Int(Date().timeIntervalSince(t0) * 1000)) sdkHeaders=\(names.filter { $0.hasPrefix("bd-") || $0.hasPrefix("x-") }.joined(separator: ","))")
        if data.count <= 64 { DYLiveModel.log("DDNATIVEIM send-resp hex=\(data.map { String(format: "%02x", $0) }.joined()) shape=\(DYPB.shape(data))") }
        guard http == 200, let top = DYPB.decode(data) else { throw DYIMError.badResponse("HTTP \(http)") }
        let status = top.int(3) ?? 0
        let msg = String((top.string(4) ?? "").prefix(60)).filter { $0.isASCII }
        DYLiveModel.log("DDNATIVEIM cmd=100 via=page status=\(status) msg=\(msg)")
        if status != 0 {
            if msg.lowercased().contains("session") { throw DYIMError.noLogin }
            throw DYIMError.rejected("\(status) \(msg)")
        }
        if let uid = top.int(13), uid > 0 { selfUID = uid }
        return top.sub(6)?.sub(Cmd.send.rawValue) ?? [:]
    }

    /// 发一条命令。网络错误原样抛出（调用方据此区分「肯定没发」和「可能发了」）。
    private func call(_ cmd: Cmd, _ payload: Data, identity: (token: String, deviceID: String)? = nil) async throws -> DYPB.Fields {
        let ck = await DYNativeCookies.load()
        guard !(ck.map["sessionid"] ?? "").isEmpty else { throw DYIMError.noLogin }
        let path = Self.paths[cmd]!
        var urlString = Self.host + path
        var r: URLRequest
        if cmd == .send {
            // 发送：逐项照私信网页抓包。签名用网页那套票据（HMAC sign-type 1），拿不到就不发
            guard let tb = await webTicket(), let tg = DYTicketGuard.headers(tb, path: path) else { throw DYIMError.rejected("网页票据未就绪") }
            let ua = DouyinWeb.userAgent
            var pairs: [(String, String)] = []
            if let fp = ck.map["s_v_web_id"], !fp.isEmpty { pairs += [("verifyFp", fp), ("fp", fp)] }
            if let ms = ck.map["msToken"], !ms.isEmpty { pairs.append(("msToken", ms)) }
            let qs = DYNative.query(pairs)
            urlString += "?" + qs + (qs.isEmpty ? "" : "&") + "a_bogus=" + DYNative.enc(DYABogus.sign(query: qs, userAgent: ua))
            r = URLRequest(url: URL(string: urlString)!)
            r.setValue(ua, forHTTPHeaderField: "User-Agent")
            r.setValue("https://www.douyin.com", forHTTPHeaderField: "Origin")
            r.setValue("https://www.douyin.com/", forHTTPHeaderField: "Referer")
            r.setValue("application/x-protobuf", forHTTPHeaderField: "Accept")
            r.setValue("application/x-protobuf", forHTTPHeaderField: "Content-Type")
            if !DYDtrait.session.isEmpty { r.setValue(DYDtrait.session, forHTTPHeaderField: "x-tt-session-dtrait") }
            for (k, v) in tg { r.setValue(v, forHTTPHeaderField: k) }
            r.setValue(await webCookies(), forHTTPHeaderField: "Cookie")
            #if DEBUG
            DDIMNativeCapture.record(r, body: envelope(cmd, payload, identity: identity), seqUsed: false)
            seq -= 1
            #endif
        } else {
            r = URLRequest(url: URL(string: urlString)!)
            for (k, v) in ["Accept": "application/x-protobuf", "Content-Type": "application/x-protobuf",
                           "Origin": "https://www.douyin.com", "Referer": "https://www.douyin.com/",
                           "User-Agent": DYNative.userAgent, "Cookie": ck.header] { r.setValue(v, forHTTPHeaderField: k) }
        }
        r.httpMethod = "POST"
        r.httpBody = envelope(cmd, payload, identity: identity)
        #if DEBUG
        if cmd == .send, DDIMNativeCapture.dry {
            DYLiveModel.log("DDNATIVEIM send dry-run recorded, not sent")
            throw DYIMError.rejected("dry-run")
        }
        #endif
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
        let core = f.sub(50), setting = f.sub(51)
        var c = DYIMConversation(id: id, shortID: f.int(2) ?? 0, type: Int(f.int(3) ?? 0),
                                 ticket: f.string(4) ?? "", name: core?.string(5) ?? "")
        c.avatar = core?.string(7) ?? ""
        c.badge = Int(f.int(10) ?? 0)
        c.readBadge = Int(setting?.int(16) ?? 0)
        c.pinned = (setting?.int(7) ?? 0) != 0
        c.muted = (setting?.int(6) ?? 0) != 0
        c.mode = Int(core?.int(16) ?? 0)
        c.coreExt = Self.map(core?[11])
        c.settingExt = Self.map(setting?[9])
        // first_page_participants（6）= ParticipantsPage{1: [Participant{1 user_id, 5 sec_uid}]}
        if let page = f.sub(6) {
            c.participants = (page[1] ?? []).compactMap { v in
                guard let p = v.data.flatMap(DYPB.decode), let uid = p.int(1) else { return nil }
                return (uid, p.string(5) ?? "")
            }
        }
        return c
    }

    /// MessageBody（字段号取自官方网页 IM SDK 的 protobuf 定义）
    static func message(_ raw: Data) -> DYIMMessage? {
        guard let f = DYPB.decode(raw) else { return nil }
        var m = DYIMMessage(serverID: f.int(3) ?? 0, type: Int(f.int(6) ?? 0), sender: f.int(7) ?? 0,
                            createdMS: f.int(10) ?? 0, content: f.string(8) ?? "")
        m.secSender = f.string(14) ?? ""
        m.index = f.int(4) ?? 0
        m.status = Int(f.int(12) ?? 0)
        m.ext = Self.map(f[9])
        m.clientID = m.ext["s:client_message_id"] ?? ""
        return m
    }

    /// protobuf map<string,string>（每项是 {1: key, 2: value}）
    static func map(_ values: [DYPB.Value]?) -> [String: String] {
        var out: [String: String] = [:]
        for e in values ?? [] {
            guard let kv = e.data.flatMap(DYPB.decode), let k = kv.string(1) else { continue }
            out[k] = kv.string(2) ?? ""
        }
        return out
    }

    /// 单聊会话 id「0:1:<uidA>:<uidB>」里不是自己的那个 uid
    func peer(of conversationID: String) -> UInt64 {
        let parts = conversationID.split(separator: ":").compactMap { UInt64($0) }
        guard parts.count >= 4 else { return 0 }
        let a = parts[2], b = parts[3]
        return a == selfUID ? b : b == selfUID ? a : (selfUID == 0 ? 0 : a)
    }

    /// 全部会话（分页同步，最多 maxPages 页）
    func loadConversations(maxPages: Int = 20) async throws -> [DYIMConversation] {
        var out: [DYIMConversation] = [], seen = Set<String>()
        var cursor: UInt64 = 0
        for page in 0..<maxPages {
            // MessageByInitRequestBody：1 version / 2 page / 3 conv_limit / 4 msg_limit（同官方私信页）
            let payload = (cursor > 0 ? DYPB.field(1, cursor) : Data()) + DYPB.field(2, UInt64(page))
                + DYPB.field(3, 50) + DYPB.field(4, 5)
            let body = try await call(.initSync, payload)
            for item in body[1] ?? [] {
                #if DEBUG
                if debugLastInitItem == nil { debugLastInitItem = item.data }
                #endif
                let entry = item.data.flatMap(DYPB.decode)
                guard let head = entry?.data(1), var c = Self.conversation(head),
                      seen.insert(c.id).inserted else { continue }
                // 2 = 该会话随 init 下发的消息（可能多条、顺序不定）：取时间最新的一条
                let msgs = (entry?[2] ?? []).compactMap { $0.data.flatMap(Self.message) }
                let shown = msgs.filter { $0.visible(to: selfUID) }
                if let last = shown.max(by: { $0.createdMS < $1.createdMS }) { c.last = last }
                c.onlySystem = !shown.contains { !$0.isSystem }
                #if DEBUG
                DYLiveModel.log("DDNATIVEIM init conv=\(c.id.suffix(6)) msgs=\(msgs.count) shown=\(shown.count) mode=\(c.mode) sys=\(c.onlySystem)")
                #endif
                if c.type == 1 {
                    c.peerUID = peer(of: c.id)
                    if let p = c.participants.first(where: { $0.uid == c.peerUID }), !p.sec.isEmpty { c.peerSec = p.sec }
                    else if let last = c.last, last.sender == c.peerUID, !last.secSender.isEmpty { c.peerSec = last.secSender }
                }
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
        try await messagePage(c, before: 0, limit: limit).messages
    }

    /// 一页消息（新→旧）。before = 0 取最新一页；否则取 index_in_conversation 小于它的更早一页。
    /// MessagesInConversationRequestBody：1 conversation_id / 2 type / 3 short_id / 4 direction（0 旧）/ 5 anchor_index / 6 limit
    func messagePage(_ c: DYIMConversation, before: UInt64, limit: Int = 30) async throws -> (messages: [DYIMMessage], hasMore: Bool, next: UInt64) {
        let payload = DYPB.field(1, c.id) + DYPB.field(2, UInt64(c.type)) + DYPB.field(3, c.shortID)
            + DYPB.field(4, 0) + DYPB.field(5, before) + DYPB.field(6, UInt64(limit))
        let body = try await call(.messages, payload)
        let list = (body[1] ?? []).compactMap { $0.data.flatMap(Self.message) }
        let next = body.int(2) ?? (list.map(\.index).min() ?? 0)
        return (list, (body.int(3) ?? 0) != 0, next)
    }

    // MARK: 用户资料（头像 / 昵称）

    private var userCache: [String: DYIMUser] = [:]
    private var userCacheLoaded = false
    /// 本次启动已从接口拿到关注关系的 uid
    private var followFresh = Set<String>()
    private static var userCacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("im-users.json")
    }
    func cachedUser(uid: UInt64) -> DYIMUser? {
        loadUserCache()
        return userCache[String(uid)]
    }
    private func loadUserCache() {
        guard !userCacheLoaded else { return }
        userCacheLoaded = true
        if let d = try? Data(contentsOf: Self.userCacheURL), let list = try? JSONDecoder().decode([DYIMUser].self, from: d) {
            for u in list { userCache[u.uid] = u }
        }
    }
    private func saveUserCache() {
        if let d = try? JSONEncoder().encode(Array(userCache.values)) { try? d.write(to: Self.userCacheURL, options: .atomic) }
    }

    /// 批量补头像昵称：先查缓存（按 uid），缺的走网页版 im/user/info（同官方私信页：按 sec_uid 批量，原生签名直连）
    /// people: (uid, sec_uid)；返回 uid → 用户
    func users(_ people: [(uid: UInt64, sec: String)], bridge: DouyinBridge, refresh: Bool = false) async -> [String: DYIMUser] {
        loadUserCache()
        var secOf: [String: String] = [:]
        for p in people where p.uid > 0 && !p.sec.isEmpty { secOf[String(p.uid)] = p.sec }
        // 缺资料、或旧缓存里没有关注关系的都重查（关注关系每次启动重查一次）
        let missing = secOf.filter { refresh || userCache[$0.key]?.follow == nil || !followFresh.contains($0.key) }.map(\.value)
        var changed = false
        for chunk in stride(from: 0, to: missing.count, by: 20).map({ Array(missing[$0..<min($0 + 20, missing.count)]) }) {
            do {
                let got = try await bridge.imUserInfo(secs: chunk)
                for u in got {
                    let uid = u.uid.isEmpty ? secOf.first(where: { $0.value == u.sec })?.key ?? "" : u.uid
                    guard !uid.isEmpty else { continue }
                    userCache[uid] = DYIMUser(uid: uid, sec: u.sec, name: u.name, avatar: u.avatar, follow: u.follow, follower: u.follower)
                    if u.follow != nil { followFresh.insert(uid) }
                    changed = true
                }
                DYLiveModel.log("DDNATIVEIM users want=\(chunk.count) got=\(got.count) follow=\(got.filter { $0.follow != nil }.count) followed=\(got.filter { ($0.follow ?? 0) > 0 }.count)")
            } catch { DYLiveModel.log("DDNATIVEIM users fail \(error.localizedDescription)") }
        }
        if changed { saveUserCache() }
        var out: [String: DYIMUser] = [:]
        for p in people { if let u = userCache[String(p.uid)] { out[String(p.uid)] = u } }
        return out
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
        do { identity = try await identityTokenViaPage() } catch {
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
            body = try await sendViaPage(msg, identity: identity)
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
            if let bridge = DouyinBridge.primary {
                let users = await DYNativeIM.shared.users(list.map { ($0.peerUID, $0.peerSec) }, bridge: bridge)
                for c in list.prefix(5) {
                    let u = users[String(c.peerUID)]
                    DYLiveModel.log("DDIMREAD row type=\(c.type) peer=\(c.peerUID > 0) sec=\(!c.peerSec.isEmpty) name=\((u?.name ?? c.name).count) avatar=\(!(u?.avatar ?? c.avatar).isEmpty) preview=\(c.last?.preview.count ?? -1) last=\(c.last?.createdMS ?? 0) unread=\(c.unread) pinned=\(c.pinned) muted=\(c.muted)")
                }
            }
            for c in list.prefix(3) {
                let msgs = try await DYNativeIM.shared.recentMessages(c, limit: 20)
                let mine = msgs.filter { $0.sender == DYNativeIM.shared.selfUID }.count
                let texts = msgs.filter { $0.text != nil }.count
                let types = Set(msgs.map(\.type)).sorted().map(String.init).joined(separator: ",")
                DYLiveModel.log("DDIMREAD msgs conv=\(c.id.suffix(6)) type=\(c.type) n=\(msgs.count) mine=\(mine) text=\(texts) types=\(types)")
                let kinds = msgs.map { m -> String in
                    switch m.body { case .text: "t"; case .sticker: "s"; case .image: "i"; case .video: "v"; case .recalled: "r"; case .system: "y"; case .unsupported(let a): "u\(a)" }
                }.joined(separator: ",")
                let page2 = try? await DYNativeIM.shared.messagePage(c, before: msgs.map(\.index).min() ?? 0, limit: 20)
                DYLiveModel.log("DDIMREAD kinds=\(kinds) idx=\(msgs.map(\.index).min() ?? 0)..\(msgs.map(\.index).max() ?? 0) page2=\(page2?.messages.count ?? -1) more=\(page2?.hasMore ?? false)")
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


#if DEBUG
enum DDIMNativeCapture {
    static var dry: Bool { ProcessInfo.processInfo.environment["DOUDUO_IMSEND_DRY"] == "1" }
    static func record(_ r: URLRequest, body: Data, seqUsed: Bool) {
        var h: [String: String] = [:]
        for (k, v) in r.allHTTPHeaderFields ?? [:] where k.lowercased() != "cookie" { h[k.lowercased()] = v }
        let ck = (r.value(forHTTPHeaderField: "Cookie") ?? "").split(separator: ";").map { $0.split(separator: "=").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? "" }.sorted()
        let o: [String: Any] = ["kind": "native", "u": r.url?.absoluteString ?? "", "h": h, "body": body.base64EncodedString(), "cookies": ck]
        guard let d = try? JSONSerialization.data(withJSONObject: o), let s = String(data: d, encoding: .utf8) else { return }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("ddimcap.jsonl")
        let line = s + "\n"
        if let fh = try? FileHandle(forWritingTo: url) { fh.seekToEndOfFile(); fh.write(Data(line.utf8)); try? fh.close() }
        else { try? Data(line.utf8).write(to: url) }
    }
}
#endif


#if DEBUG
/// DOUDUO_CHATJS=<js 表达式>：私信网页加载后执行并记录结果（只用于找网页 IM SDK 入口）
@MainActor enum DDChatJSProbe {
    static func run(_ js: String) async {
        for _ in 0..<40 {
            if let w = DouyinWeb.chatWeb, w.url?.path.hasPrefix("/chat") == true, !w.isLoading { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        try? await Task.sleep(nanoseconds: 6_000_000_000)
        guard let w = DouyinWeb.chatWeb else { DYLiveModel.log("DDCHATJS no-web"); return }
        do {
            let r = try await w.callAsyncJavaScript(js, arguments: [:], contentWorld: .page)
            let out = String(describing: r ?? "nil")
            var i = out.startIndex
            var n = 0
            while i < out.endIndex, n < 30 {
                let j = out.index(i, offsetBy: 900, limitedBy: out.endIndex) ?? out.endIndex
                DYLiveModel.log("DDCHATJS[\(n)] \(out[i..<j])"); i = j; n += 1
            }
        } catch { DYLiveModel.log("DDCHATJS err \(error)") }
    }
}
#endif
