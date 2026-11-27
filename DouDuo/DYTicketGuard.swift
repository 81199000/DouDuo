// 登录票据签名（bd-ticket-guard）：写接口和受保护接口要求「用登录时绑定的 EC 密钥」签 ticket+path+timestamp。
// 密钥是抖音网页在登录时生成、存在本 App 网页存储（localStorage）里的那一套，这里只读取、不生成新密钥，
// 所以原生请求和网页请求在服务端看来是同一个登录设备。签名格式同 Amor5207/douyin-tv（GPL-3.0）TicketGuard.java。
import CryptoKit
import Foundation
import WebKit

struct DYTicketBundle: Equatable {
    let ticket: String
    let tsSign: String
    let privatePEM: String
    /// 65 字节未压缩公钥点的 base64（bd-ticket-guard-ree-public-key）
    let publicPoint: String
    /// 网页 SDK 与服务端 ECDH 协商出的 32 字节对称密钥（base64）。网页写请求用它做 HMAC 签名（sign-type 1）
    let ecdhKey: String?
}

enum DYTicketGuard {
    /// 由 web_protect 与 crypt_sdk 两条 localStorage 记录拼出票据。任一缺失返回 nil。
    static func bundle(webProtect: String?, cryptSDK: String?) -> DYTicketBundle? {
        func inner(_ raw: String?) -> [String: Any]? {
            guard let raw, let d = raw.data(using: .utf8),
                  let outer = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
            if let s = outer["data"] as? String, let d2 = s.data(using: .utf8) {
                return try? JSONSerialization.jsonObject(with: d2) as? [String: Any]
            }
            return outer["data"] as? [String: Any] ?? outer
        }
        guard let wp = inner(webProtect), let ticket = wp["ticket"] as? String, !ticket.isEmpty,
              let ts = wp["ts_sign"] as? String, !ts.isEmpty else { return nil }
        let cs = inner(cryptSDK)
        guard let pem = (wp["private_key"] as? String) ?? (cs?["ec_privateKey"] as? String), !pem.isEmpty,
              let key = privateKey(pem) else { return nil }
        return DYTicketBundle(ticket: ticket, tsSign: ts, privatePEM: pem,
                              publicPoint: key.publicKey.x963Representation.base64EncodedString(),
                              ecdhKey: (wp["ecdh_key"] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }

    /// 网页存的 PEM 把整段 base64 写在一行（184 字符），CryptoKit 的 PEM 解析只认 64 字符换行，
    /// 所以自己剥头尾、解 base64 得到 PKCS#8 DER 再导入。
    static func privateKey(_ pem: String) -> P256.Signing.PrivateKey? {
        if let k = try? P256.Signing.PrivateKey(pemRepresentation: pem) { return k }
        let b64 = pem.replacingOccurrences(of: #"-----[^-]+-----"#, with: "", options: .regularExpression)
            .components(separatedBy: .whitespacesAndNewlines).joined()
        guard let der = Data(base64Encoded: b64) else { return nil }
        return try? P256.Signing.PrivateKey(derRepresentation: der)
    }

    /// 某个接口 path 的票据签名头。
    /// 与网页安全 SDK 完全一致
    ///   req_sign = base64(HMAC-SHA256(ecdh_key, "ticket=<t>&path=<p>&timestamp=<秒>"))，sign-type = 1，client-data 带 t_trust:1。
    /// ⚠️ 不能用 ECDSA 私钥签（sign-type 0）：服务端回 1002 并作废登录（真机实测两次）。
    static func headers(_ b: DYTicketBundle, path: String, now: Int = Int(Date().timeIntervalSince1970)) -> [String: String]? {
        guard let kb64 = b.ecdhKey, let kd = Data(base64Encoded: kb64), kd.count == 32 else { return nil }
        let payload = "ticket=\(b.ticket)&path=\(path)&timestamp=\(now)"
        let mac = HMAC<SHA256>.authenticationCode(for: Data(payload.utf8), using: SymmetricKey(data: kd))
        let sig = Data(mac).base64EncodedString()
        // 键顺序照网页：ts_sign, req_content, req_sign, timestamp, t_trust
        let client = "{\"ts_sign\":\"\(b.tsSign)\",\"req_content\":\"ticket,path,timestamp\",\"req_sign\":\"\(sig)\",\"timestamp\":\(now),\"t_trust\":1}"
        return [
            "bd-ticket-guard-ree-public-key": b.publicPoint,
            "bd-ticket-guard-version": "2",
            "bd-ticket-guard-web-version": b.tsSign.hasPrefix("ts.1") ? "1" : "2",
            "bd-ticket-guard-web-sign-type": "1",
            "bd-ticket-guard-client-data": Data(client.utf8).base64EncodedString(),
        ]
    }
}

/// 写接口签名头：原生登录过的会话用 ECDSA（sign-type 0，密钥是登录前 App 自己生成并绑定的），
/// 网页登录的会话用 HMAC(ecdh_key)（sign-type 1，密钥在网页存储里）。两套各自对应自己的登录，混用会被判异常。
@MainActor
enum DYSigning {
    static func headers(path: String, web: WKWebView?) async -> [String: String]? {
        if DYNativeTicket.hasTicket {
            if let h = DYNativeTicket.headers(path: path) {
                DYLiveModel.log("DDSIGN pick=native-ecdsa path=\(path)")
                return h
            }
            DYLiveModel.log("DDSIGN native-ticket-unusable reason=\(DYNativeTicket.debugWhy)")
        }
        guard let b = await DYTicketStore.load(from: web) else { return nil }
        if let h = DYTicketGuard.headers(b, path: path) {
            DYLiveModel.log("DDSIGN pick=web-hmac path=\(path)")
            return h
        }
        return nil
    }
}

/// 从本 App 的抖音网页存储里读票据（读一次缓存 60 秒；切账号时 invalidate）
@MainActor
enum DYTicketStore {
    private static var cached: (at: Date, bundle: DYTicketBundle?)?
    static func invalidate() { cached = nil }

    /// 通过任一已加载 www.douyin.com 的网页读取（签名页 / 聊天页都可以）
    static func load(from web: WKWebView?) async -> DYTicketBundle? {
        if let c = cached, Date().timeIntervalSince(c.at) < 60, c.bundle != nil { return c.bundle }
        guard let web, web.url?.host == "www.douyin.com" else {
            DYLiveModel.log("DDNATIVE ticket no-page host=\(web?.url?.host ?? "nil")")
            return cached?.bundle
        }
        let js = "[localStorage.getItem('security-sdk/s_sdk_sign_data_key/web_protect'), localStorage.getItem('security-sdk/s_sdk_crypt_sdk')]"
        let r = try? await web.evaluateJavaScript(js) as? [Any]
        let wp = r?.first as? String
        let cs = (r?.count ?? 0) > 1 ? r?[1] as? String : nil
        let b = DYTicketGuard.bundle(webProtect: wp, cryptSDK: cs)
        cached = (Date(), b)
        // 只记有无与长度，不记内容
        DYLiveModel.log("DDNATIVE ticket loaded=\(b != nil) wp=\(wp?.count ?? -1) cs=\(cs?.count ?? -1) host=\(web.url?.host ?? "-")")
        return b
    }
}
