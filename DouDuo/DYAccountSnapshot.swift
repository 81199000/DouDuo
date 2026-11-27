import Foundation

/// 一个账号除 cookie 以外的登录状态（cookie 仍按原来的格式单独存，见 DYAccountStore）。
///
/// 抖音的登录不只认 cookie，还绑着一把「设备密钥」（bd-ticket-guard）：写接口要用登录时绑定的那把密钥签名，
/// 对不上就失败，严重时服务端直接作废登录。以前切换账号只换回 cookie：
/// - 网页登录：密钥在网页 localStorage（security-sdk/…），切换时被整片清掉又不恢复 → 切回来的账号写操作失败 / 掉登录
/// - 原生扫码登录：cookie 罐 + 票据 + EC 私钥全局只有一份，切换不动它 → 原生请求一直是原来那个人；
///   再扫码加一个账号时上一个账号的密钥被删 → 永远切不回去
/// 所以每个账号要存一份完整快照，切换时整份换回去。
struct DYAccountLoginExtras: Codable, Equatable {
    /// 网页安全 SDK 的 localStorage（只留 security-sdk/ 开头的：EC 私钥、票据、ecdh_key 等）
    var webStorage: [String: String] = [:]
    /// 原生扫码登录：App 自己的 cookie 罐
    var nativeJar: [String: String]? = nil
    /// 原生扫码登录：抖音回的票据（DYNativeTicket 存的原样 JSON）
    var nativeTicket: Data? = nil
    /// 原生扫码登录：登录前自己生成并交给抖音绑定的 P-256 私钥（PKCS#8 base64）
    var nativeKey: String? = nil

    static let webStoragePrefix = "security-sdk/"

    /// 三样都在才算一份能用的原生登录
    var hasNativeLogin: Bool {
        !(nativeJar?["sessionid"] ?? "").isEmpty && !(nativeTicket ?? Data()).isEmpty && !(nativeKey ?? "").isEmpty
    }

    /// 网页读回来的 localStorage 只留安全 SDK 的键；值不是字符串的丢掉
    static func filterWebStorage(_ raw: [String: Any]) -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in raw where k.hasPrefix(webStoragePrefix) {
            if let s = v as? String { out[k] = s }
        }
        return out
    }

    /// 新读到的快照覆盖旧的；但这次没读到的部分（网页没开着、不是原生登录）沿用旧的，不能拿空的把好的冲掉
    func merging(newer: DYAccountLoginExtras) -> DYAccountLoginExtras {
        var out = self
        if !newer.webStorage.isEmpty { out.webStorage = newer.webStorage }
        if newer.hasNativeLogin {
            out.nativeJar = newer.nativeJar
            out.nativeTicket = newer.nativeTicket
            out.nativeKey = newer.nativeKey
        }
        return out
    }

    /// 日志用：只给条数和 8 位短哈希，不记任何原文
    var logSummary: String {
        let joined = webStorage.keys.sorted().map { "\($0)=\(webStorage[$0] ?? "")" }.joined(separator: "&")
        return "web=\(webStorage.count) wh=\(Self.h8(joined)) native=\(hasNativeLogin ? 1 : 0)"
    }

    static func h8(_ s: String) -> String {
        guard !s.isEmpty else { return "-" }
        var h: UInt32 = 0x811c9dc5
        for b in s.utf8 { h ^= UInt32(b); h = h &* 16777619 }
        return String(format: "%08x", h)
    }
}

/// 网页里读 / 写安全 SDK 那几条 localStorage 的脚本（callAsyncJavaScript 的函数体）
enum DYWebStorageScript {
    /// 读：返回 { key: value }
    static let read = """
    const out = {};
    for (const k of Object.keys(localStorage)) if (k.startsWith('security-sdk/')) out[k] = localStorage.getItem(k);
    return out;
    """
    /// 写：先删掉现有的 security-sdk/ 键（不能留上一个账号的），再写入参数 entries；返回写入后的条数
    static let write = """
    for (const k of Object.keys(localStorage)) if (k.startsWith('security-sdk/')) localStorage.removeItem(k);
    for (const [k, v] of Object.entries(entries || {})) if (k.startsWith('security-sdk/') && typeof v === 'string') localStorage.setItem(k, v);
    return Object.keys(localStorage).filter(k => k.startsWith('security-sdk/')).length;
    """
}

#if DEBUG || ACCOUNT_SNAPSHOT_MAIN
enum DYAccountSnapshotTests {
    static func run() -> [String] {
        var failures: [String] = []
        func check(_ c: Bool, _ m: String) { if !c { failures.append(m) } }

        let raw: [String: Any] = ["security-sdk/s_sdk_crypt_sdk": "a", "security-sdk/s_sdk_cert_key": "b",
                                  "other_page_cache": "x", "security-sdk/bad": 3]
        let web = DYAccountLoginExtras.filterWebStorage(raw)
        check(web == ["security-sdk/s_sdk_crypt_sdk": "a", "security-sdk/s_sdk_cert_key": "b"], "只留 security-sdk/ 的字符串值")

        let native = DYAccountLoginExtras(webStorage: [:], nativeJar: ["sessionid": "s1", "ttwid": "t"],
                                          nativeTicket: Data("{\"ticket\":\"t\"}".utf8), nativeKey: "k")
        check(native.hasNativeLogin, "三样齐全才算原生登录")
        var partial = native; partial.nativeKey = nil
        check(!partial.hasNativeLogin, "缺私钥不算")
        var noSession = native; noSession.nativeJar = ["ttwid": "t"]
        check(!noSession.hasNativeLogin, "cookie 罐里没有 sessionid 不算")

        let old = DYAccountLoginExtras(webStorage: web, nativeJar: native.nativeJar, nativeTicket: native.nativeTicket, nativeKey: "k")
        let emptyRead = DYAccountLoginExtras()
        check(old.merging(newer: emptyRead) == old, "这次什么都没读到不能冲掉旧快照")
        let newerWeb = DYAccountLoginExtras(webStorage: ["security-sdk/s_sdk_crypt_sdk": "z"])
        let m1 = old.merging(newer: newerWeb)
        check(m1.webStorage == newerWeb.webStorage && m1.hasNativeLogin, "只读到网页部分时原生部分沿用")
        var newerNative = native; newerNative.nativeKey = "k2"
        let m2 = old.merging(newer: newerNative)
        check(m2.nativeKey == "k2" && m2.webStorage == web, "只读到原生部分时网页部分沿用")

        let coded = try? JSONDecoder().decode(DYAccountLoginExtras.self, from: JSONEncoder().encode(old))
        check(coded == old, "能存能读回")
        check(!old.logSummary.contains("a") || old.logSummary.hasPrefix("web=2"), "日志只有条数和哈希")
        check(!old.logSummary.contains("s1") && !old.logSummary.contains("crypt"), "日志不含原文和键名")
        check(DYAccountLoginExtras.h8("") == "-" && DYAccountLoginExtras.h8("abc").count == 8, "短哈希")

        check(DYWebStorageScript.read.contains("security-sdk/") && DYWebStorageScript.write.contains("removeItem"), "写之前先清掉上一个账号的键")
        return failures
    }
}
#endif

#if ACCOUNT_SNAPSHOT_MAIN
@main
struct DYAccountSnapshotMain {
    static func main() {
        let failures = DYAccountSnapshotTests.run()
        if failures.isEmpty { print("DYAccountSnapshotTests passed") }
        else { for f in failures { print("FAIL \(f)") }; exit(1) }
    }
}
#endif
