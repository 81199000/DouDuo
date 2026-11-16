#if DEBUG
import Foundation
import UIKit

/// 网页端还没接的接口，在登录态的签名页里实测一遍（方案见 docs/web-api-gap-plan.md）。
/// 用法：启动环境变量 DOUDUO_WEBAPI=1，结果在 Documents/ddlog.txt 里找 DDGAP 开头的行。
/// 只发读请求；只记 HTTP 状态、status_code、字段名和列表长度，不记正文、cookie、凭证。
/// 参数名都照网页 bundle 里的调用写（2026-11-17 抓取）。
@MainActor
enum DYWebApiProbe {
    private struct Case {
        let name: String
        var method = "GET"
        let path: String
        /// 值里的 {aweme} {sec} {uid} {music} {mix} {ch} {tag} {hotword} {sentence} {collects} 会换成种子
        let params: [String: String]
        var body: [String: String] = [:]
        /// 想知道长度的列表字段
        var lists: [String] = []
        /// 从回包里再取一个种子给后面的用例用：(种子名, 取值路径，| 分隔的备选)
        var capture: (String, String)? = nil
    }

    private static let cases: [Case] = [
        Case(name: "social/count", path: "/aweme/v1/web/social/count/", params: [:]),
        Case(name: "aweme/related", path: "/aweme/v1/web/aweme/related/",
             params: ["aweme_id": "{aweme}", "count": "6", "filterGids": "", "refresh_index": "1"], lists: ["aweme_list"]),
        Case(name: "related/recommend", path: "/aweme/v1/web/related/recommend/",
             params: ["related_aweme_id": "{aweme}", "related_rt": "1"], lists: ["aweme_list"]),
        Case(name: "multi/aweme/detail", method: "POST", path: "/aweme/v1/web/multi/aweme/detail/", params: [:],
             body: ["aweme_ids": "[{aweme}]", "request_source": "200", "origin_type": "pc_web"], lists: ["aweme_details"]),
        Case(name: "mix/list", path: "/aweme/v1/web/mix/list/",
             params: ["sec_user_id": "{sec}", "req_from": "channel_pc_web", "cursor": "0", "count": "12"],
             lists: ["mix_infos"], capture: ("mix", "mix_infos.0.mix_id")),
        Case(name: "mix/detail", path: "/aweme/v1/web/mix/detail/", params: ["mix_id": "{mix}", "req_from": "channel_pc_web"]),
        Case(name: "mix/aweme", path: "/aweme/v1/web/mix/aweme/",
             params: ["mix_id": "{mix}", "cursor": "0", "count": "12"], lists: ["aweme_list"]),
        Case(name: "music/detail", path: "/aweme/v1/web/music/detail/", params: ["music_id": "{music}", "scene": "1"]),
        Case(name: "music/aweme", path: "/aweme/v1/web/music/aweme/",
             params: ["music_id": "{music}", "cursor": "0", "count": "10"], lists: ["aweme_list"]),
        Case(name: "challenge/detail", path: "/aweme/v1/web/challenge/detail/", params: ["ch_id": "{ch}", "query_type": "0"]),
        Case(name: "challenge/aweme", path: "/aweme/v1/web/challenge/aweme/",
             params: ["ch_id": "{ch}", "hashtag_name": "{tag}", "query_type": "0", "sort_type": "1", "offset": "0", "cursor": "0", "count": "10"],
             lists: ["aweme_list"]),
        Case(name: "hot/search/video/list", path: "/aweme/v1/web/hot/search/video/list/",
             params: ["hotword": "{hotword}", "sentence_id": "{sentence}", "offest": "0", "count": "6", "entry_name": "pc_web"],
             lists: ["aweme_list", "data"]),
        Case(name: "collects/list", path: "/aweme/v1/web/collects/list/", params: ["cursor": "0", "count": "12"],
             lists: ["collects_list"], capture: ("collects", "collects_list.0.collects_id_str|collects_list.0.collects_id")),
        Case(name: "collects/video/list", path: "/aweme/v1/web/collects/video/list/",
             params: ["collects_id": "{collects}", "cursor": "0", "count": "12"], lists: ["aweme_list"]),
        Case(name: "familiar/feed", path: "/aweme/v1/web/familiar/feed/",
             params: ["level": "1", "cursor": "0", "pull_type": "0", "refresh_type": "0", "address_book_access": "2", "gps_access": "2"],
             lists: ["data", "aweme_list"]),
        Case(name: "user/recommend", path: "/aweme/v1/web/user/recommend/",
             params: ["uid": "{uid}", "cursor": "0", "count": "10", "address_book_access": "2", "gps_access": "2", "recommend_type": "36"],
             lists: ["user_list"]),
        Case(name: "view/user/visited/list", method: "POST", path: "/aweme/v1/web/view/user/visited/list/", params: [:],
             body: ["cursor": "0", "count": "20"], lists: ["visited_user_list", "user_list"]),
        Case(name: "danmaku/conf/get", path: "/aweme/v1/web/danmaku/conf/get/", params: ["conf_end_type": "4", "hardware_concurrency": "8"]),
        // 评论发图的凭证：只看字段名齐不齐，值不记
        Case(name: "comment/upload/auth", path: "/aweme/v1/web/comment/upload/auth/", params: ["content_type": "0"]),
    ]

    static func run(_ bridge: DouyinBridge) async {
        func log(_ s: String) { DYLiveModel.log("DDGAP " + s) }
        func text(_ d: Data?) -> String { d.flatMap { String(data: $0, encoding: .utf8) } ?? "nil" }

        // 刚启动那几秒签名页还没挂好，请求会直接断（http=-1）；等它就绪，种子没取到就隔几秒再取
        await bridge.ensureWriteReady()
        var seeds: [String: String] = [:]
        for round in 1...4 where seeds["aweme"] == nil {
            if let d = try? await bridge.call(seedJS, args: [:], attempts: 1),
               let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                for (k, v) in o { if let s = v as? String, !s.isEmpty { seeds[k] = s } }
            }
            if seeds["aweme"] == nil {
                log("seeds round=\(round) 没取到作品，3 秒后再试")
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        if let me = try? await bridge.selfProfile() { seeds["uid"] = me.uid }
        log("seeds have=" + seeds.keys.sorted().joined(separator: ","))

        for c in cases {
            func fill(_ dict: [String: String]) -> [String: String]? {
                var out: [String: String] = [:]
                for (k, v) in dict {
                    var value = v
                    for (name, seed) in seeds { value = value.replacingOccurrences(of: "{\(name)}", with: seed) }
                    if value.contains("{") { return nil }
                    out[k] = value
                }
                return out
            }
            guard let params = fill(c.params), let body = fill(c.body) else {
                log("\(c.name) skipped（缺种子）")
                continue
            }
            let json = { (o: Any) in String(data: (try? JSONSerialization.data(withJSONObject: o)) ?? Data("{}".utf8), encoding: .utf8) ?? "{}" }
            let args: [String: Any] = [
                "pMethod": c.method, "pPath": c.path, "pParams": json(params), "pForm": json(body),
                "pLists": json(c.lists), "pCap": c.capture?.1 ?? "",
            ]
            let d = try? await bridge.call(caseJS, args: args, attempts: 1)
            if let key = c.capture?.0, let d,
               let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let got = o["cap"] as? String, !got.isEmpty {
                seeds[key] = got
            }
            // cap 的值是内容 ID，不进日志
            var line = text(d)
            if let d, var o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                o["cap"] = ((o["cap"] as? String)?.isEmpty == false)
                line = json(o)
            }
            log("\(c.name) \(c.method) " + line)
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        log("done")
    }

    /// 评论发图前两步的实测：取凭证 → 传一张 64×64 的纯色小图到 ImageX。不发评论。
    /// 用法：DOUDUO_IMGUP=1。会在自己账号的图床里留一张没人引用的小图。
    static func uploadSmoke(_ bridge: DouyinBridge) async {
        func log(_ s: String) { DYLiveModel.log("DDGAP imgup " + s) }
        let size = CGSize(width: 64, height: 64)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        guard let data = image.jpegData(compressionQuality: 0.8) else { return log("没生成出测试图") }
        do {
            let r = try await bridge.uploadCommentImage(
                data, fileName: "probe.jpg", measured: DYImageXUploadResult(uri: "", width: 64, height: 64, format: "jpeg"))
            log("ok bytes=\(data.count) uri=\(r.uri.isEmpty ? "空" : "有(\(r.uri.count)字)") w=\(r.width) h=\(r.height) format=\(r.format)")
        } catch {
            log("failed " + error.localizedDescription)
        }
    }

    /// 从推荐流和热榜里捞几个真实 ID 当参数用
    private static let seedJS = #"""
    try {
      await sdkReady(6000);
      const P = Object.assign({}, base, { count: '10', refresh_index: '1', video_type_select: '1',
        aweme_pc_rec_raw_data: JSON.stringify({ is_client: false, ff_danmaku_status: 0, danmaku_switch_status: 0 }),
        globalwid: '', pull_type: '0', min_window: '0', free_right: '0', ug_source: '', creative_id: '' });
      const f = parse((await req('GET', '/aweme/v1/web/tab/feed/?' + new URLSearchParams(P).toString())).t) || {};
      const list = f.aweme_list || [];
      const out = {};
      const a0 = list.find(a => a && a.aweme_id);
      if (a0) { out.aweme = String(a0.aweme_id); out.sec = (a0.author && a0.author.sec_uid) || ''; }
      for (const a of list) {
        if (!out.music && a.music && (a.music.id_str || a.music.mid)) out.music = String(a.music.id_str || a.music.mid);
        if (!out.mix && a.mix_info && a.mix_info.mix_id) { out.mix = String(a.mix_info.mix_id); out.sec = (a.author && a.author.sec_uid) || out.sec; }
        if (!out.ch) {
          const t = (a.text_extra || []).find(t => t.hashtag_id && t.hashtag_name);
          if (t) { out.ch = String(t.hashtag_id); out.tag = t.hashtag_name; }
          const c = (a.cha_list || []).find(c => c.cid && c.cha_name);
          if (!out.ch && c) { out.ch = String(c.cid); out.tag = c.cha_name; }
        }
      }
      const h = parse((await req('GET', '/aweme/v1/web/hot/search/list/?' + q({ detail_list: '1', source: '6', board_type: '0', board_sub_type: '' }))).t) || {};
      const w = ((h.data && h.data.word_list) || []).find(w => w && w.word && w.sentence_id);
      if (w) { out.hotword = w.word; out.sentence = String(w.sentence_id); }
      return JSON.stringify(out);
    } catch (e) { return JSON.stringify({}); }
    """#

    private static let caseJS = #"""
    try {
      const wanted = JSON.parse(pLists);
      const body = pMethod === 'POST' ? new URLSearchParams(JSON.parse(pForm)).toString() : null;
      const r = await req(pMethod, pPath + '?' + q(JSON.parse(pParams)), body);
      const raw = r.t || '', d = parse(raw);
      const at = (o, p) => p.split('.').reduce((x, k) => (x == null ? x : x[k]), o);
      const names = o => (o && typeof o === 'object' && !Array.isArray(o)) ? Object.keys(o).filter(k => /^[A-Za-z0-9_]+$/.test(k)).slice(0, 40) : [];
      const lens = {}; let firstKeys = [];
      for (const k of wanted) {
        const v = d ? d[k] : null;
        lens[k] = Array.isArray(v) ? v.length : null;
        if (!firstKeys.length && Array.isArray(v) && v.length) firstKeys = names(v[0]);
      }
      let cap = '';
      if (pCap && d) for (const p of pCap.split('|')) { const v = at(d, p); if (v != null && v !== '') { cap = String(v); break; } }
      return JSON.stringify({ http: r.s, code: d ? (d.status_code ?? null) : null,
        kind: !raw.trim() ? 'empty' : d ? 'json' : /^\s*</.test(raw) ? 'html' : 'other', chars: raw.length,
        signed: /a_bogus=/.test(r.u || ''), keys: names(d), lens, first: firstKeys, cap,
        hasMore: d ? (d.has_more ?? null) : null });
    } catch (e) { return JSON.stringify({ err: String(e).slice(0, 120) }); }
    """#
}
#endif
