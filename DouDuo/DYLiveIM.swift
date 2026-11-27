import Foundation
#if canImport(Compression)
import Compression
#endif

/// 直播间弹幕的数据层：直播间网页自己连 WebSocket / 拉 im/fetch（签名跟着官方走），
/// 我们在网页里只截下它收到的原始字节（见 DYLiveChat.imHookJS），在这里解 gzip + protobuf，
/// 按消息类型原生显示：文字弹幕、表情、礼物（带礼物图）、进场、点赞、关注 / 分享、下播。
/// 以前是每秒抓一次页面渲染出来的文字：只有文字、还要等页面渲染。
///
/// 只依赖 Foundation，便于脚本单测（scripts/test_live_im.py）。

// MARK: - 无 schema 的 protobuf 读取

enum DYLivePB {
    typealias Fields = [Int: [Value]]
    enum Value {
        case int(UInt64)
        case bytes(Data)
        var int: UInt64? { if case .int(let v) = self { return v }; return nil }
        var data: Data? { if case .bytes(let d) = self { return d }; return nil }
    }

    static func decode(_ d: Data) -> Fields? {
        let b = [UInt8](d)
        var out: Fields = [:]
        var i = 0
        func varint() -> UInt64? {
            var shift: UInt64 = 0, v: UInt64 = 0
            while i < b.count, shift <= 63 {
                let x = b[i]; i += 1
                v |= UInt64(x & 0x7f) << shift
                if x & 0x80 == 0 { return v }
                shift += 7
            }
            return nil
        }
        while i < b.count {
            guard let key = varint() else { return nil }
            let n = Int(key >> 3), wire = key & 7
            guard n > 0 else { return nil }
            switch wire {
            case 0: guard let v = varint() else { return nil }; out[n, default: []].append(.int(v))
            case 1: guard i + 8 <= b.count else { return nil }; out[n, default: []].append(.bytes(Data(b[i..<i + 8]))); i += 8
            case 2:
                guard let len = varint(), len <= UInt64(b.count - i) else { return nil }
                out[n, default: []].append(.bytes(Data(b[i..<i + Int(len)]))); i += Int(len)
            case 5: guard i + 4 <= b.count else { return nil }; out[n, default: []].append(.bytes(Data(b[i..<i + 4]))); i += 4
            default: return nil
            }
        }
        return out
    }

    /// 只描述结构（字段号:类型/长度），不含内容，供日志定位字段
    static func shape(_ d: Data, depth: Int = 0) -> String {
        guard let f = decode(d) else { return "?\(d.count)" }
        return f.keys.sorted().map { k in
            let v = f[k]!.first!
            if let x = v.int { return "\(k)=\(x < 100_000 ? String(x) : "big")\(f[k]!.count > 1 ? "×\(f[k]!.count)" : "")" }
            let data = v.data ?? Data()
            if depth < 1, data.count > 1, decode(data) != nil, String(data: data, encoding: .utf8) == nil {
                return "\(k):{\(shape(data, depth: depth + 1))}"
            }
            return "\(k):b\(data.count)\(f[k]!.count > 1 ? "×\(f[k]!.count)" : "")"
        }.joined(separator: ",")
    }
}

extension DYLivePB.Fields {
    func int(_ n: Int) -> UInt64 { self[n]?.first?.int ?? 0 }
    func data(_ n: Int) -> Data? { self[n]?.first?.data }
    func string(_ n: Int) -> String { data(n).flatMap { String(data: $0, encoding: .utf8) } ?? "" }
    func sub(_ n: Int) -> DYLivePB.Fields? { data(n).flatMap(DYLivePB.decode) }
    func subs(_ n: Int) -> [DYLivePB.Fields] { (self[n] ?? []).compactMap { $0.data.flatMap(DYLivePB.decode) } }
}

// MARK: - gzip

enum DYGzip {
    static func isGzip(_ d: Data) -> Bool { d.count > 18 && d[d.startIndex] == 0x1f && d[d.startIndex + 1] == 0x8b }

    /// 解 gzip（RFC 1952）：跳过头部，剩下的原始 deflate 交给系统 Compression（COMPRESSION_ZLIB 就是原始 deflate）
    static func inflate(_ d: Data) -> Data? {
        let b = [UInt8](d)
        guard b.count > 18, b[0] == 0x1f, b[1] == 0x8b, b[2] == 8 else { return nil }
        let flags = b[3]
        var i = 10
        if flags & 0x04 != 0 { guard i + 2 <= b.count else { return nil }; i += 2 + Int(b[i]) | Int(b[i + 1]) << 8 }
        if flags & 0x08 != 0 { while i < b.count, b[i] != 0 { i += 1 }; i += 1 }
        if flags & 0x10 != 0 { while i < b.count, b[i] != 0 { i += 1 }; i += 1 }
        if flags & 0x02 != 0 { i += 2 }
        guard i < b.count - 8 else { return nil }
        let isize = Int(b[b.count - 4]) | Int(b[b.count - 3]) << 8 | Int(b[b.count - 2]) << 16 | Int(b[b.count - 1]) << 24
        let deflated = Array(b[i..<(b.count - 8)])
        #if canImport(Compression)
        var capacity = max(isize, deflated.count * 4, 1024)
        for _ in 0..<4 {
            var out = [UInt8](repeating: 0, count: capacity)
            let n = compression_decode_buffer(&out, capacity, deflated, deflated.count, nil, COMPRESSION_ZLIB)
            if n > 0, n < capacity || n == isize { return Data(out[0..<n]) }
            capacity *= 4
        }
        #endif
        return nil
    }
}

// MARK: - 消息

/// 用户名前的小徽章（等级 / 粉丝团 / 管理等，官方下发的就是图片）。aspect = 宽 / 高
struct DYLiveBadge: Equatable, Hashable {
    var url: String
    var aspect: Double
}

/// 直播间头部要的状态：本场点赞、在线人数、前三名观众头像。只更新收到的那几项。
struct DYLiveRoomStats: Equatable {
    var likeTotal: Int? = nil
    var online: Int? = nil
    var topViewers: [String]? = nil

    var isEmpty: Bool { likeTotal == nil && online == nil && topViewers == nil }

    mutating func apply(_ u: DYLiveRoomStats) {
        if let v = u.likeTotal { likeTotal = max(v, likeTotal ?? 0) }   // 点赞只增不减（乱序的旧帧不能把数字拉回去）
        if let v = u.online { online = v }
        if let v = u.topViewers { topViewers = v }
    }

    /// 官方写法：一万以下原数，以上「1.2万」
    static func short(_ n: Int) -> String {
        guard n >= 10_000 else { return String(n) }
        let w = Double(n) / 10_000
        let s = w >= 100 ? String(format: "%.0f", w) : String(format: "%.1f", w)
        return (s.hasSuffix(".0") ? String(s.dropLast(2)) : s) + "万"
    }
}

/// 一条直播间消息（界面用）
struct DYLiveIMEvent: Equatable, Identifiable {
    enum Kind: String, Equatable { case chat, emoji, gift, member, like, social, ended }
    var id: String              // 服务端 msgId；礼物连击合并时用「人+礼物+组」做键
    var kind: Kind
    var user: String
    var text: String            // 弹幕原文（含 [表情] 代码）/ 系统消息文案
    var image: String? = nil    // 礼物图 / 大表情图
    var giftName: String = ""
    var count: Int = 0          // 礼物个数（连击累计）
    var badges: [DYLiveBadge] = []
}

enum DYLiveIM {
    /// 一帧网页收到的数据 → 消息列表。
    /// - ws：WebSocket 帧（PushFrame），payload 一般 gzip
    /// - fetch：im/fetch 回包（Response），可能 gzip
    static func events(fromFrame raw: Data, kind: String) -> (events: [DYLiveIMEvent], methods: [String], stats: DYLiveRoomStats) {
        var body = raw
        if kind == "ws" {
            guard let frame = DYLivePB.decode(raw), let payload = frame.data(8) else { return ([], [], .init()) }
            // payloadType（field 7）不是 msg 的（心跳 / ack）跳过
            let type = frame.string(7)
            if !type.isEmpty, type != "msg" { return ([], [], .init()) }
            body = payload
        }
        if DYGzip.isGzip(body) { guard let unzipped = DYGzip.inflate(body) else { return ([], [], .init()) }; body = unzipped }
        guard let response = DYLivePB.decode(body) else { return ([], [], .init()) }
        var out: [DYLiveIMEvent] = [], methods: [String] = [], stats = DYLiveRoomStats()
        for m in response.subs(1) {
            let method = m.string(1)
            methods.append(method)
            guard let payload = m.data(2), let p = DYLivePB.decode(payload) else { continue }
            if let e = event(method: method, msgID: m.int(3), p) { out.append(e) }
            if let u = roomStats(method: method, p) { stats.apply(u) }
        }
        return (out, methods, stats)
    }

    /// 头部状态（2026-11-28 真实数据核对过字段号）：
    /// - WebcastLikeMessage 3 = 本场点赞总数
    /// - WebcastRoomStatsMessage 5 / WebcastRoomUserSeqMessage 3 = 在线人数
    /// - WebcastRoomRankMessage 2 = 前几名观众，每项 1 是用户（9 头像）
    static func roomStats(method: String, _ p: DYLivePB.Fields) -> DYLiveRoomStats? {
        switch method {
        case "WebcastLikeMessage":
            let total = p.int(3)
            return total > 0 ? DYLiveRoomStats(likeTotal: Int(total)) : nil
        case "WebcastRoomStatsMessage":
            let n = p.int(5)
            return n > 0 ? DYLiveRoomStats(online: Int(n)) : nil
        case "WebcastRoomUserSeqMessage":
            let n = p.int(3)
            return n > 0 ? DYLiveRoomStats(online: Int(n)) : nil
        case "WebcastRoomRankMessage":
            let avatars = p.subs(2).compactMap { imageURL($0.sub(1)?.sub(9)) }
            return DYLiveRoomStats(topViewers: Array(avatars.prefix(3)))
        default:
            return nil
        }
    }

    /// 用户的徽章（field 21，repeated Image；图里 3 高 4 宽）。最多 3 个，跟官方一样排在昵称前
    static func badges(_ user: DYLivePB.Fields?) -> [DYLiveBadge] {
        guard let user else { return [] }
        return Array(user.subs(21).compactMap { img -> DYLiveBadge? in
            guard let url = imageURL(img) else { return nil }
            let h = Double(img.int(3)), w = Double(img.int(4))
            return DYLiveBadge(url: url, aspect: h > 0 && w > 0 ? w / h : 1)
        }.prefix(3))
    }

    static func nickname(_ user: DYLivePB.Fields?) -> String { user?.string(3) ?? "" }

    /// Image：url_list 是 field 1（repeated string）
    static func imageURL(_ image: DYLivePB.Fields?) -> String? {
        guard let image else { return nil }
        for v in image[1] ?? [] { if let s = v.data.flatMap({ String(data: $0, encoding: .utf8) }), s.hasPrefix("http") { return s } }
        return nil
    }

    static func event(method: String, msgID: UInt64, _ p: DYLivePB.Fields) -> DYLiveIMEvent? {
        let id = String(msgID)
        switch method {
        case "WebcastChatMessage":
            let text = p.string(3)
            guard !text.isEmpty else { return nil }
            return DYLiveIMEvent(id: id, kind: .chat, user: nickname(p.sub(2)), text: text, badges: badges(p.sub(2)))
        case "WebcastEmojiChatMessage":
            // emojiContent（Text，field 4）里的图片片段；没有就用 defaultContent（field 5）
            let pieces = p.sub(4)?.subs(4) ?? []
            let url = pieces.lazy.compactMap { imageURL($0.sub(8)?.sub(1)) }.first
            return DYLiveIMEvent(id: id, kind: .emoji, user: nickname(p.sub(2)), text: p.string(5), image: url)
        case "WebcastGiftMessage":
            let gift = p.sub(15)
            let name = gift?.string(16) ?? ""
            let user = p.sub(7)
            let count = Int(max(p.int(29), p.int(5), p.int(6), 1))
            // 连击：同一个人、同一个礼物、同一组（groupId field 11）合成一条，个数往上加
            let key = "gift:\(user?.int(1) ?? 0):\(p.int(2)):\(p.int(11))"
            return DYLiveIMEvent(id: key, kind: .gift, user: nickname(user), text: "送出了 \(name.isEmpty ? "礼物" : name)",
                                 image: imageURL(gift?.sub(1)) ?? imageURL(gift?.sub(21)), giftName: name, count: count,
                                 badges: badges(user))
        case "WebcastMemberMessage":
            let user = nickname(p.sub(2))
            guard !user.isEmpty else { return nil }
            return DYLiveIMEvent(id: id, kind: .member, user: user, text: "来了")
        case "WebcastLikeMessage":
            let user = nickname(p.sub(5))
            guard !user.isEmpty else { return nil }
            return DYLiveIMEvent(id: id, kind: .like, user: user, text: "为主播点赞了", count: Int(p.int(2)))
        case "WebcastSocialMessage":
            let user = nickname(p.sub(2))
            guard !user.isEmpty else { return nil }
            let action = p.int(4)
            return DYLiveIMEvent(id: id, kind: .social, user: user, text: action == 1 ? "关注了主播" : "分享了直播间")
        case "WebcastControlMessage":
            return p.int(2) == 3 ? DYLiveIMEvent(id: id, kind: .ended, user: "", text: "直播已结束") : nil
        default:
            return nil
        }
    }

    /// 进场 / 点赞不进聊天列表，只留最新一条当滚动提示
    static func split(_ events: [DYLiveIMEvent]) -> (list: [DYLiveIMEvent], ticker: DYLiveIMEvent?) {
        let passing: (DYLiveIMEvent) -> Bool = { $0.kind == .member || $0.kind == .like }
        return (events.filter { !passing($0) }, events.last(where: passing))
    }

    /// 并进已有列表：礼物连击更新同一条（个数取大的、挪到最后）；其它按 id 去重。只留最近 limit 条。
    static func merge(_ list: [DYLiveIMEvent], _ new: [DYLiveIMEvent], limit: Int = 60) -> [DYLiveIMEvent] {
        var out = list
        for e in new {
            if let i = out.firstIndex(where: { $0.id == e.id }) {
                guard e.kind == .gift else { continue }
                var g = out.remove(at: i)
                g.count = max(g.count, e.count)
                out.append(g)
            } else {
                out.append(e)
            }
        }
        return Array(out.suffix(limit))
    }
}

#if DEBUG || LIVE_IM_MAIN
enum DYLiveIMTests {
    // 极简 protobuf 编码（只给测试拼帧用）
    static func v(_ x: UInt64) -> Data { var x = x, o = Data(); repeat { var b = UInt8(x & 0x7f); x >>= 7; if x != 0 { b |= 0x80 }; o.append(b) } while x != 0; return o }
    static func f(_ n: Int, _ x: UInt64) -> Data { v(UInt64(n << 3)) + v(x) }
    static func f(_ n: Int, _ d: Data) -> Data { v(UInt64(n << 3 | 2)) + v(UInt64(d.count)) + d }
    static func f(_ n: Int, _ s: String) -> Data { f(n, Data(s.utf8)) }
    static func user(_ id: UInt64, _ nick: String, badge: String? = nil, avatar: String? = nil) -> Data {
        var d = f(1, id) + f(3, nick)
        if let avatar { d += f(9, f(1, avatar)) }
        if let badge { d += f(21, f(1, badge) + f(3, 16) + f(4, 32)) }
        return d
    }
    static func msg(_ method: String, _ id: UInt64, _ payload: Data) -> Data { f(1, f(1, method) + f(2, payload) + f(3, id)) }

    #if canImport(Compression)
    /// gzip 封装：原始 deflate（Compression 的 ZLIB）+ 10 字节头 + 8 字节尾（CRC 不校验，填 0）
    static func gzip(_ d: Data) -> Data {
        let src = [UInt8](d)
        var dst = [UInt8](repeating: 0, count: src.count + 1024)
        let n = compression_encode_buffer(&dst, dst.count, src, src.count, nil, COMPRESSION_ZLIB)
        var out = Data([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 3])
        out += Data(dst[0..<n])
        out += Data([0, 0, 0, 0])
        let size = UInt32(src.count)
        out += Data([UInt8(size & 0xff), UInt8(size >> 8 & 0xff), UInt8(size >> 16 & 0xff), UInt8(size >> 24 & 0xff)])
        return out
    }
    #endif

    static func run() -> [String] {
        var failures: [String] = []
        func check(_ c: Bool, _ m: String) { if !c { failures.append(m) } }

        let img = f(1, "https://example.invalid/gift.png")
        let gift = f(7, user(9, "送礼的")) + f(2, 463) + f(5, 1) + f(6, 1) + f(11, 77) + f(15, f(1, img) + f(16, "小心心"))
        let chatPayload: Data = f(2, user(1, "甲", badge: "https://example.invalid/lv37.png")) + f(3, "主播好[比心]")
        let emojiPayload: Data = f(2, user(5, "戊")) + f(4, f(4, f(8, f(1, f(1, "https://example.invalid/e.png"))))) + f(5, "[大表情]")
        let rankA: Data = f(2, f(1, user(7, "a", avatar: "https://example.invalid/a.jpg")))
        let rankB: Data = f(2, f(1, user(8, "b", avatar: "https://example.invalid/b.jpg")))
        let parts: [Data] = [
            msg("WebcastChatMessage", 1, chatPayload),
            msg("WebcastGiftMessage", 2, gift),
            msg("WebcastMemberMessage", 3, f(2, user(2, "乙"))),
            msg("WebcastLikeMessage", 4, f(2, 3) + f(5, user(3, "丙"))),
            msg("WebcastSocialMessage", 5, f(2, user(4, "丁")) + f(4, 1)),
            msg("WebcastEmojiChatMessage", 6, emojiPayload),
            msg("WebcastControlMessage", 7, f(2, 3)),
            msg("WebcastRoomStatsMessage", 8, f(5, 100)),
            msg("WebcastLikeMessage", 9, f(2, 1) + f(3, 10473) + f(5, user(6, "己"))),
            msg("WebcastRoomRankMessage", 10, rankA + rankB),
            f(2, "cursor"),
        ]
        let response = parts.reduce(Data(), +)

        let (events, methods, stats) = DYLiveIM.events(fromFrame: response, kind: "fetch")
        check(methods.count == 10, "10 条消息都认出类型")
        check(events.map(\.kind) == [.chat, .gift, .member, .like, .social, .emoji, .ended, .like], "各类消息都解出来，不认识的跳过")
        check(events.first?.badges == [DYLiveBadge(url: "https://example.invalid/lv37.png", aspect: 2)], "弹幕带上用户徽章（宽高比）")
        check(stats.likeTotal == 10473, "本场点赞总数")
        check(stats.online == 100, "在线人数")
        check(stats.topViewers == ["https://example.invalid/a.jpg", "https://example.invalid/b.jpg"], "前几名观众头像")
        var acc = DYLiveRoomStats(likeTotal: 20000, online: 5)
        acc.apply(DYLiveRoomStats(likeTotal: 19000))
        check(acc.likeTotal == 20000 && acc.online == 5, "点赞只增不减、没收到的项不动")
        check(DYLiveRoomStats.short(5) == "5" && DYLiveRoomStats.short(55_000) == "5.5万" && DYLiveRoomStats.short(20_000) == "2万" && DYLiveRoomStats.short(1_234_567) == "123万", "人数写法")
        check(events.first?.user == "甲" && events.first?.text == "主播好[比心]", "弹幕：昵称 + 原文（表情代码保留给界面换图）")
        let g = events[1]
        check(g.user == "送礼的" && g.giftName == "小心心" && g.image == "https://example.invalid/gift.png", "礼物：送礼人、礼物名、礼物图")
        check(g.id == "gift:9:463:77", "礼物连击按 人+礼物+组 合并")
        check(events[3].count == 3 && events[3].user == "丙", "点赞人在 field 5")
        check(events[4].text == "关注了主播", "关注")
        check(events[5].image == "https://example.invalid/e.png", "大表情图")

        // WebSocket 帧：PushFrame（payloadType=msg、payload gzip）
        #if canImport(Compression)
        let frame = f(7, "msg") + f(8, gzip(response))
        let ws = DYLiveIM.events(fromFrame: frame, kind: "ws")
        check(ws.events.count == 8, "WebSocket 帧解 gzip 后同样解出")
        check(DYGzip.inflate(gzip(Data("hello".utf8))) == Data("hello".utf8), "gzip 往返")
        #endif
        check(DYLiveIM.events(fromFrame: f(7, "hb") + f(8, Data([1])), kind: "ws").events.isEmpty, "心跳帧跳过")
        check(DYLiveIM.events(fromFrame: Data([0xff, 0xff]), kind: "fetch").events.isEmpty, "坏数据不崩")

        // 合并：礼物连击更新同一条；同 id 不重复
        var more = g; more.count = 5
        let merged = DYLiveIM.merge(DYLiveIM.merge([], events), [more, events[0]])
        check(merged.filter { $0.kind == .gift }.count == 1 && merged.last?.count == 5, "连击合成一条、个数更新、挪到最后")
        check(merged.filter { $0.id == "1" }.count == 1, "同一条弹幕不重复")
        check(DYLiveIM.merge([], (0..<100).map { DYLiveIMEvent(id: "\($0)", kind: .chat, user: "", text: "x") }).count == 60, "只留最近 60 条")

        let (list, ticker) = DYLiveIM.split(events)
        check(!list.contains { $0.kind == .member || $0.kind == .like }, "进场 / 点赞不进聊天列表")
        check(ticker?.kind == .like && ticker?.user == "己", "滚动提示用最新一条进场 / 点赞")
        return failures
    }
}
#endif

#if LIVE_IM_MAIN
@main
struct DYLiveIMMain {
    static func main() {
        let failures = DYLiveIMTests.run()
        if failures.isEmpty { print("DYLiveIMTests passed") } else { for f in failures { print("FAIL \(f)") }; exit(1) }
    }
}
#endif
