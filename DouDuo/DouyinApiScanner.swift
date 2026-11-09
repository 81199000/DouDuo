#if DEBUG
import Foundation

/// 扫抖音 web 前端 bundle 里的接口路径（DEBUG 诊断用，DOUDUO_APISCAN=1 触发）
@MainActor
enum DYApiScanner {
    static func run(_ bridge: DouyinBridge) async {
        func log(_ s: String) { DYLiveModel.log("DDAPISCAN " + s) }
        log("start")
        let js = #"""
        const paths = new Set();
        const srcs = new Set();
        document.querySelectorAll('script[src]').forEach(s => { if (s.src) srcs.add(s.src); });
        performance.getEntriesByType('resource').forEach(r => { if (/\.js(\?|$)/.test(r.name)) srcs.add(r.name); });
        const list = [...srcs].slice(0, 24);
        for (const u of list) {
          try {
            const r = await fetch(u, { credentials: 'include' });
            if (!r.ok) continue;
            const t = await r.text();
            const m = t.match(/\/aweme\/v1\/[a-zA-Z0-9_\/]+/g) || [];
            m.forEach(p => paths.add(p));
          } catch (e) {}
        }
        return JSON.stringify({ bundles: list.length, count: paths.size, paths: [...paths] });
        """#
        do {
            let d = try await bridge.call(js, args: [:])
            let s = String(data: d, encoding: .utf8) ?? "empty"
            log("result \(s.prefix(12000))")
        } catch {
            log("fail \(error.localizedDescription)")
        }
    }
}
#endif
