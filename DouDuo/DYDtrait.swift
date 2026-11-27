// x-tt-session-dtrait：网页安全 SDK 给受保护接口加的会话特征头。
// 结构同 Amor5207/douyin-tv（GPL-3.0）Dtrait.java：随机 AES-128 密钥+IV 用固定 RSA 公钥加密，固定特征串用 AES-CBC 加密，
// 输出 "d0_<rsa>_<aes>"。一个会话生成一次即可。
import CommonCrypto
import Foundation
import Security

enum DYDtrait {
    private static let modulusHex =
        "e3e76fbd8eee33ea2973e9cb1bf0ee992785a3b6957089b52cefa6508ad6a6b4733f46b51a9110e2ab4ef4c45ffe5c04231dfcfb8059e17386cdebd5b6e52f7c839413b013b505bb14a25fe4f9d22c223afe4d2f9751422d44959843faa8f26b223678cd7a2a8b7cae359fb5a1d6d103ffc61e07204b2cb268bab3c239295865e8b8c626bd8b12a6993f7efd8458006cb4f37159ae0438109a75350f917350efa34110ff71cdf252db4c220efd684bfbcabeb494a567099dace4901bea41b6c0a956d015317f0cf8a4a69bba653ea51885ef24a0ab79e1621c0daa2bab52d7c4965475bd011cf5fa98c1d5ea88218b68856a53d81e34382e0ef2d55e0409db89"
    private static let payload =
        #"[["str_14",3419490229],["str_15",2525084665],["str_16",785994595],["str_19",2910269993],["str_29",3870149837],["str_27",2802661099],["str_28",1068634537],["str_30",140181531],["str_31",4255047500],["str_32",3927047830],["str_3",3757789876],["str_2",2861649864],["str_11",2990008912],["str_12",4273337803],["str_33",4255047500],["str_34",3530670207]]"#

    nonisolated(unsafe) private static var cached: String?
    static var session: String {
        if let c = cached { return c }
        let v = build() ?? ""
        if !v.isEmpty { cached = v }
        return v
    }

    private static func hexBytes(_ s: String) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(s.count / 2)
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return out
    }

    /// PKCS#1 RSAPublicKey DER：SEQUENCE { INTEGER n, INTEGER e }
    private static func rsaPublicKeyDER() -> Data {
        func len(_ n: Int) -> [UInt8] {
            if n < 0x80 { return [UInt8(n)] }
            var b = [UInt8](); var x = n
            while x > 0 { b.insert(UInt8(x & 0xff), at: 0); x >>= 8 }
            return [0x80 | UInt8(b.count)] + b
        }
        var n = hexBytes(modulusHex)
        if n[0] & 0x80 != 0 { n.insert(0, at: 0) }
        let intN: [UInt8] = [0x02] + len(n.count) + n
        let intE: [UInt8] = [0x02, 0x03, 0x01, 0x00, 0x01]
        let body = intN + intE
        return Data([0x30] + len(body.count) + body)
    }

    static func build() -> String? {
        var key = [UInt8](repeating: 0, count: 16), iv = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, 16, &key) == errSecSuccess,
              SecRandomCopyBytes(kSecRandomDefault, 16, &iv) == errSecSuccess else { return nil }
        let attrs: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                                    kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
                                    kSecAttrKeySizeInBits as String: 2048]
        guard let pub = SecKeyCreateWithData(rsaPublicKeyDER() as CFData, attrs as CFDictionary, nil),
              let wrapped = SecKeyCreateEncryptedData(pub, .rsaEncryptionPKCS1, Data(key + iv) as CFData, nil) as Data? else { return nil }
        let plain = Array(payload.utf8)
        var out = [UInt8](repeating: 0, count: plain.count + kCCBlockSizeAES128)
        var moved = 0
        let st = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                         key, key.count, iv, plain, plain.count, &out, out.count, &moved)
        guard st == kCCSuccess else { return nil }
        return "d0_" + wrapped.base64EncodedString() + "_" + Data(out.prefix(moved)).base64EncodedString()
    }
}
