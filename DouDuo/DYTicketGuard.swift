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
              let key = try? P256.Signing.PrivateKey(pemRepresentation: pem) else { return nil }
        return DYTicketBundle(ticket: ticket, tsSign: ts, privatePEM: pem,
                              publicPoint: key.publicKey.x963Representation.base64EncodedString())
    }

    /// 某个接口 path 的票据签名头。
    static func headers(_ b: DYTicketBundle, path: String, now: Int = Int(Date().timeIntervalSince1970)) -> [String: String]? {
        guard let key = try? P256.Signing.PrivateKey(pemRepresentation: b.privatePEM) else { return nil }
        let payload = "ticket=\(b.ticket)&path=\(path)&timestamp=\(now)"
        guard let sig = try? key.signature(for: Data(payload.utf8)).derRepresentation.base64EncodedString() else { return nil }
        let client: [String: Any] = ["ts_sign": b.tsSign, "req_content": "ticket,path,timestamp", "req_sign": sig, "timestamp": now]
        guard let cd = try? JSONSerialization.data(withJSONObject: client, options: [.sortedKeys]) else { return nil }
        return [
            "bd-ticket-guard-ree-public-key": b.publicPoint,
            "bd-ticket-guard-version": "2",
            "bd-ticket-guard-iteration-version": "1",
            "bd-ticket-guard-web-version": b.tsSign.hasPrefix("ts.1") ? "1" : "2",
            "bd-ticket-guard-web-sign-type": "0",
            "bd-ticket-guard-client-data": cd.base64EncodedString(),
        ]
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
        guard let web, web.url?.host == "www.douyin.com" else { return cached?.bundle }
        let js = "[localStorage.getItem('security-sdk/s_sdk_sign_data_key/web_protect'), localStorage.getItem('security-sdk/s_sdk_crypt_sdk')]"
        let r = try? await web.evaluateJavaScript(js) as? [Any]
        let wp = r?.first as? String
        let cs = (r?.count ?? 0) > 1 ? r?[1] as? String : nil
        let b = DYTicketGuard.bundle(webProtect: wp, cryptSDK: cs)
        cached = (Date(), b)
        DYLiveModel.log("DDNATIVE ticket loaded=\(b != nil)")
        return b
    }
}
