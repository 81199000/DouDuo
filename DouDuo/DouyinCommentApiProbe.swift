#if DEBUG
import Foundation

@MainActor
enum DYCommentApiProbe {
    static func run(_ bridge: DouyinBridge) async {
        func log(_ s: String) { DYLiveModel.log("DDCPROBE " + s) }
        let js = """
        try {
          const r = await req('GET', '/aweme/v1/web/im/resource/list/aggregation/?count=1');
          const d = parse(r.t) || {};
          const ed = d.emoticon_data || {};
          const st = ed.stickers || [];
          const first = st[0] || null;
          const inner = first && first.sticker_info ? first.sticker_info : null;
          const innerList = inner && (inner.sticker_list || inner.stickers) ? (inner.sticker_list || inner.stickers) : null;
          return JSON.stringify({
            total: st.length, hasMore: ed.has_more, source: ed.source,
            firstKeys: first ? Object.keys(first) : [],
            first: first,
            innerKeys: inner ? Object.keys(inner) : [],
            innerCount: innerList ? innerList.length : 0,
            innerFirst: innerList ? innerList[0] : null,
            customPages: (d.custom_sticker_page_list && d.custom_sticker_page_list.resources || []).slice(0,2)
          }).slice(0, 3200);
        } catch(e) { return JSON.stringify({ err: String(e) }); }
        """
        let d = (try? await bridge.call(js, args: [:], attempts: 1)) ?? Data()
        log("stickerShape " + (String(data: d, encoding: .utf8) ?? "nil"))
    }
}
#endif
