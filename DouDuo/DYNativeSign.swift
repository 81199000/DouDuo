// 抖音网页接口 a_bogus 签名（纯 Swift，不依赖 WebView）。
// 算法移植自 Amor5207/douyin-tv（GPL-3.0）的 Abogus.java / Sm3.java，对应网页安全 SDK bdms 1.0.1.20。
// 只依赖 Foundation，便于单元测试与 macOS 命令行对拍。
import Foundation

/// SM3 256 位哈希，与抖音网页签名器逐字节一致。
enum DYSm3 {
    private static let iv: [UInt32] = [
        0x7380166f, 0x4914b2b9, 0x172442d7, 0xda8a0600,
        0xa96f30bc, 0x163138aa, 0xe38dee4d, 0xb0fb0e4e,
    ]

    @inline(__always) private static func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 {
        let s = n & 31
        return s == 0 ? x : (x << s) | (x >> (32 - s))
    }

    static func hash(_ data: [UInt8]) -> [UInt8] {
        var reg = iv
        let bitLen = UInt64(data.count) * 8
        let total = ((data.count + 8) / 64 + 1) * 64
        var buf = [UInt8](repeating: 0, count: total)
        buf.replaceSubrange(0..<data.count, with: data)
        buf[data.count] = 0x80
        for i in 0..<8 { buf[total - 8 + i] = UInt8(truncatingIfNeeded: bitLen >> (56 - 8 * UInt64(i))) }
        var w = [UInt32](repeating: 0, count: 68)
        var w1 = [UInt32](repeating: 0, count: 64)
        var off = 0
        while off < total {
            for i in 0..<16 {
                let p = off + i * 4
                w[i] = UInt32(buf[p]) << 24 | UInt32(buf[p + 1]) << 16 | UInt32(buf[p + 2]) << 8 | UInt32(buf[p + 3])
            }
            for i in 16..<68 {
                var a = w[i - 16] ^ w[i - 9] ^ rotl(w[i - 3], 15)
                a = a ^ rotl(a, 15) ^ rotl(a, 23)
                w[i] = a ^ rotl(w[i - 13], 7) ^ w[i - 6]
            }
            for i in 0..<64 { w1[i] = w[i] ^ w[i + 4] }
            var a = reg[0], b = reg[1], c = reg[2], d = reg[3]
            var e = reg[4], f = reg[5], g = reg[6], h = reg[7]
            for j in 0..<64 {
                let t: UInt32 = j < 16 ? 0x79cc4519 : 0x7a879d8a
                let ss1 = rotl(rotl(a, 12) &+ e &+ rotl(t, UInt32(j)), 7)
                let ss2 = ss1 ^ rotl(a, 12)
                let ff = j < 16 ? (a ^ b ^ c) : ((a & b) | (a & c) | (b & c))
                let gg = j < 16 ? (e ^ f ^ g) : ((e & f) | (~e & g))
                let tt1 = ff &+ d &+ ss2 &+ w1[j]
                let tt2 = gg &+ h &+ ss1 &+ w[j]
                d = c; c = rotl(b, 9); b = a; a = tt1
                h = g; g = rotl(f, 19); f = e
                e = tt2 ^ rotl(tt2, 9) ^ rotl(tt2, 17)
            }
            reg[0] ^= a; reg[1] ^= b; reg[2] ^= c; reg[3] ^= d
            reg[4] ^= e; reg[5] ^= f; reg[6] ^= g; reg[7] ^= h
            off += 64
        }
        var out = [UInt8](repeating: 0, count: 32)
        for i in 0..<8 {
            let v = reg[i]
            out[i * 4] = UInt8(truncatingIfNeeded: v >> 24)
            out[i * 4 + 1] = UInt8(truncatingIfNeeded: v >> 16)
            out[i * 4 + 2] = UInt8(truncatingIfNeeded: v >> 8)
            out[i * 4 + 3] = UInt8(truncatingIfNeeded: v)
        }
        return out
    }

    static func twice(_ data: [UInt8]) -> [UInt8] { hash(hash(data)) }
}

/// a_bogus 生成器。`userAgent` 必须与实际发请求的 UA 一致，服务端会核对。
enum DYABogus {
    static let s3 = Array("ckdp1h4ZKsUB80/Mfvw36XIgR25+WQAlEi7NLboqYTOPuzmFjJnryx9HVGDaStCe".utf8)
    static let s4 = Array("Dkdpgh2ZmsQB80/MfvV36XI1R45-WUAlEixNLwoqYTOPuzKFjJnry79HbGcaStCe".utf8)
    static let salt = "dhzx"
    static let aid = 6383
    static let pageID = 41079
    static let sdkVersion = "1.0.1.20"
    /// 屏幕/窗口指纹串（与签名时声明的环境一致）
    /// 屏幕/窗口指纹串。⚠️ 签名器是定长 96 字节缓冲（50 + env + 尾部时间戳 + 校验），env 只能用原版这个长度，
    /// 换成更长的串会越界崩溃。实测配 Mac Safari UA 服务端照样认。
    static let env = "1536|747|1536|864|1536|834|1536|864|Win32"

    private static let tlist: [Int] = [
        34, 44, 56, 61, 73, 29, 70, 45, 35, 49,
        38, 66, 51, 68, 28, 48, 64, 47, 30, 71,
        26, 55, 31, 69, 59, 40, 62, 63, 27, 72,
        41, 74, 57, 52, 42, 39, 33, 67, 53, 43,
        65, 46, 36, 24, 60, 32, 79, 80, 84, 85,
    ]

    static func rc4(_ key: [UInt8], _ text: [UInt8]) -> [UInt8] {
        var s = [Int](repeating: 0, count: 256)
        var k = [Int](repeating: 0, count: 256)
        for i in 0..<256 { s[i] = 255 - i; k[i] = Int(key[i % key.count]) }
        var j = 0
        for i in 0..<256 {
            j = (j * s[i] + j + k[i]) % 256
            s.swapAt(i, j)
        }
        var out = [UInt8](repeating: 0, count: text.count)
        var i = 0
        j = 0
        for n in 0..<text.count {
            i = (i + 1) % 256
            j = (j + s[i]) % 256
            s.swapAt(i, j)
            out[n] = text[n] ^ UInt8(s[(s[i] + s[j]) % 256])
        }
        return out
    }

    static func base64(_ data: [UInt8], table: [UInt8]) -> String {
        var out = [UInt8]()
        out.reserveCapacity(data.count * 4 / 3 + 4)
        var i = 0
        while i < data.count {
            let c1 = Int(data[i]); i += 1
            let c2 = i < data.count ? Int(data[i]) : -1; if c2 >= 0 { i += 1 }
            let c3 = i < data.count ? Int(data[i]) : -1; if c3 >= 0 { i += 1 }
            var cc = c1 << 16
            if c2 >= 0 { cc |= c2 << 8 }
            if c3 >= 0 { cc |= c3 }
            out.append(table[(cc & 16515072) >> 18])
            out.append(table[(cc & 258048) >> 12])
            if c2 >= 0 { out.append(table[(cc & 4032) >> 6]) }
            if c3 >= 0 { out.append(table[cc & 63]) }
            if c2 < 0 { out.append(UInt8(ascii: "=")) }
            if c3 < 0 { out.append(UInt8(ascii: "=")) }
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func u88Transform(_ u88: [Int], _ x: [Int]) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(((u88.count + 2) / 3) * 4)
        var xi = 0, i = 0
        while i < u88.count {
            if i + 2 < u88.count {
                let r = x[xi] & 0xff; xi += 1
                out.append(UInt8(truncatingIfNeeded: (r & 145) | (u88[i] & 110)))
                out.append(UInt8(truncatingIfNeeded: (r & 66) | (u88[i + 1] & 189)))
                out.append(UInt8(truncatingIfNeeded: (r & 44) | (u88[i + 2] & 211)))
                out.append(UInt8(truncatingIfNeeded: (u88[i] & 145) | (u88[i + 1] & 66) | (u88[i + 2] & 44)))
            } else {
                out.append(UInt8(truncatingIfNeeded: u88[i]))
                if i + 1 < u88.count { out.append(UInt8(truncatingIfNeeded: u88[i + 1])) }
            }
            i += 3
        }
        return out
    }

    private static func buildU88(query: String, form: String, userAgent: String, now: Int64,
                                 enterPageTs: Int64, env: String, u86: [Int]) -> [Int] {
        let salted = query.hasSuffix(salt)
        let u18 = DYSm3.twice(Array((salted ? query : query + salt).utf8))
        let u19 = DYSm3.twice(Array((form + salt).utf8))
        let rc = rc4([0, 129, 14], Array(userAgent.trimmingCharacters(in: .whitespaces).utf8))
        let uaEncode = base64(rc, table: s3)
        let u21 = DYSm3.hash(Array(uaEncode.utf8))

        let u16 = 129
        let ink = now - 1
        var u = [Int](repeating: 0, count: 88)
        u[8] = pageID
        u[9] = aid
        u[12] = 3
        u[14] = Int(Int32(truncatingIfNeeded: now))
        u[16] = u16
        u[17] = 14
        u[22] = Int(Int32(truncatingIfNeeded: ink))
        u[24] = 41
        u[26] = Int(Int32(truncatingIfNeeded: (now - 1721836800000) / 1000 / 60 / 60 / 24 / 14))
        u[27] = 6
        u[28] = Int((now - enterPageTs + 3) & 255)
        u[29] = Int(now & 255)
        u[30] = Int((now >> 8) & 255)
        u[31] = Int((now >> 16) & 255)
        u[32] = Int((now >> 24) & 255)
        u[33] = Int((now >> 32) & 255)
        u[34] = Int((now >> 40) & 255)
        u[35] = u16 & 255
        u[36] = (u16 >> 8) & 255
        u[38] = 75
        u[39] = 0
        u[44] = u[17] & 255
        u[45] = (u[17] >> 8) & 255
        u[46] = (u[17] >> 16) & 255
        u[47] = (u[17] >> 24) & 255
        u[48] = Int(u18[9])
        u[49] = Int(u18[18])
        u[51] = 11
        u[52] = Int(u19[10])
        u[53] = Int(u19[19])
        u[55] = Int(u19[4])
        u[56] = Int(u21[11])
        u[57] = Int(u21[21])
        u[59] = 12
        u[60] = Int(ink & 255)
        u[61] = Int((ink >> 8) & 255)
        u[62] = Int((ink >> 16) & 255)
        u[63] = Int((ink >> 24) & 255)
        u[64] = Int((ink >> 32) & 255)
        u[65] = Int((ink >> 40) & 255)
        u[66] = u[12]
        u[67] = pageID & 255
        u[68] = (pageID >> 8) & 255
        u[69] = (pageID >> 16) & 255
        u[70] = (pageID >> 24) & 255
        u[71] = aid & 255
        u[72] = (aid >> 8) & 255
        u[73] = (aid >> 16) & 255
        u[74] = (aid >> 24) & 255

        let envCodes = env.unicodeScalars.map { Int($0.value) & 0xff }
        u[78] = envCodes.count
        u[79] = u[78] & 255
        u[80] = (u[78] >> 8) & 255
        let tail = "\((now + 3) & 255),"
        let tailCodes = tail.unicodeScalars.map { Int($0.value) & 0xff }
        u[83] = tailCodes.count
        u[84] = u[83] & 255
        u[85] = (u[83] >> 8) & 255

        var x = u86[0]
        for i in 1..<8 { x ^= u86[i] }
        for idx in [24, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 38, 39, 40, 41, 42, 43, 44, 45,
                    46, 47, 48, 49, 51, 52, 53, 55, 56, 57, 59, 60, 61, 62, 63, 64, 65, 66, 67, 68,
                    69, 70, 71, 72, 73, 74, 79, 80, 84, 85] { x ^= u[idx] }
        u[87] = x & 255

        var out = [Int]()
        out.reserveCapacity(96)
        for idx in tlist { out.append(u[idx]) }
        out += envCodes
        out += tailCodes
        out.append(u[87])
        // 网页签名器用定长 96 字节缓冲：尾部时间戳位数少时剩下的位置是 0，不能截短
        if out.count < 96 { out += [Int](repeating: 0, count: 96 - out.count) }
        return out
    }

    /// 确定性版本（测试对拍用）：随机数全部由调用方给出。
    static func generate(query: String, form: String, userAgent: String, now: Int64, enterPageTs: Int64,
                         env: String = env, u86: [Int], head: [Int], x: [Int]) -> String {
        let u88 = buildU88(query: query, form: form, userAgent: userAgent, now: now,
                           enterPageTs: enterPageTs, env: env, u86: u86)
        let body = u88Transform(u88, x)
        let plain = u86.map { UInt8(truncatingIfNeeded: $0) } + body
        let crypt = rc4([211], plain)
        let framed = head.map { UInt8(truncatingIfNeeded: $0) } + crypt
        return base64(framed, table: s4)
    }

    /// 给一段原始 query（不含 a_bogus）签名；form 为 POST 表单原文（GET 传空串）。
    static func sign(query: String, form: String = "", userAgent: String) -> String {
        var g = SystemRandomNumberGenerator()
        let u86 = (0..<8).map { _ in Int.random(in: 0...255, using: &g) }
        let head = [
            0x01 | (Int.random(in: 0...255, using: &g) & 0xaa),
            0x02 | (Int.random(in: 0...255, using: &g) & 0x55),
            0x50 | (Int.random(in: 0...255, using: &g) & 0x2a),
            0x02 | (Int.random(in: 0...255, using: &g) & 0x15),
        ]
        let x = (0..<32).map { _ in Int.random(in: 0...255, using: &g) }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        return generate(query: query, form: form, userAgent: userAgent, now: now, enterPageTs: now,
                        u86: u86, head: head, x: x)
    }
}
