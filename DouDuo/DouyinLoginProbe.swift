#if DEBUG
import Foundation

/// 查 App 内 WebView 的真实登录态（DOUDUO_LOGINPROBE=1 触发）
@MainActor
enum DYLoginProbe {
    static func run(_ bridge: DouyinBridge) async {
        func log(_ s: String) { DYLiveModel.log("DDLPROBE " + s) }

        let js = """
        const out = {};
        try { out.href = location.href; } catch(e) {}
        try { out.cookieLen = (document.cookie || '').length; } catch(e) { out.cookieLen = -1; }
        try { out.ckNames = (document.cookie || '').split(';').map(s => s.split('=')[0].trim()).filter(Boolean).join(','); } catch(e) {}
        try { out.lsKeys = Object.keys(localStorage).slice(0, 40).join(','); } catch(e) {}
        try {
          const r = await req('GET', '/aweme/v1/web/user/profile/self/?' + q({}));
          out.self = { s: r.s, t: (r.t || '').slice(0, 600) };
        } catch(e) { out.self = String(e); }
        try {
          const r2 = await req('GET', '/aweme/v1/web/im/user/active/status/?' + q({}));
          out.active = { s: r2.s, t: (r2.t || '').slice(0, 400) };
        } catch(e) { out.active = String(e); }
        try {
          const r3 = await req('GET', '/aweme/v1/web/get/user/settings/?' + q({}));
          out.settings = { s: r3.s, t: (r3.t || '').slice(0, 400) };
        } catch(e) { out.settings = String(e); }
        return JSON.stringify(out);
        """
        let d = (try? await bridge.call(js, args: [:], attempts: 1)) ?? Data()
        let s = String(data: d, encoding: .utf8) ?? "nil"
        for chunk in stride(from: 0, to: s.count, by: 1500) {
            let start = s.index(s.startIndex, offsetBy: chunk)
            let end = s.index(start, offsetBy: min(1500, s.count - chunk))
            log("[\(chunk)] " + String(s[start..<end]))
        }
    }
}
#endif
