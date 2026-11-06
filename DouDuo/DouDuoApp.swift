import SwiftUI
import UIKit
import AVFoundation

/// 后台/失焦立刻停声：用 AppDelegate 回调，比 SwiftUI 的 scenePhase 稳
/// （实测 Scene 上的 onChange 在部分切后台路径下不触发，声音就漏出去了）
final class DouDuoAppDelegate: NSObject, UIApplicationDelegate {
    func applicationWillResignActive(_ application: UIApplication) {
        DDPlayback.shared.pauseAll()
    }
    func applicationDidEnterBackground(_ application: UIApplication) {
        DDPlayback.shared.pauseAll()
    }
    func applicationDidBecomeActive(_ application: UIApplication) {
        // 只有「之前真被切过后台」才恢复，避免启动时抢跑播放
        DDPlayback.shared.resumeAll()
    }

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        #if DEBUG
        // 自动测试用：DOUDUO_ACTTEST=<aweme_id> → 起播后直接打点赞/收藏接口，结果写 ddlog
        if let aid = ProcessInfo.processInfo.environment["DOUDUO_ACTTEST"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 14) {
                Task { @MainActor in
                    let bridge = actTestBridge
                    do {
                        let ok = try await bridge.digg(aid, like: true)
                        LocalVideoLaunch.log("DDACTTEST digg ok=\(ok)")
                        let ok2 = try await bridge.digg(aid, like: false)
                        LocalVideoLaunch.log("DDACTTEST undigg ok=\(ok2)")
                    } catch { LocalVideoLaunch.log("DDACTTEST digg error \(error)") }
                    do {
                        let f = try await bridge.favorite(aid, add: true)
                        LocalVideoLaunch.log("DDACTTEST fav ok=\(f)")
                    } catch { LocalVideoLaunch.log("DDACTTEST fav error \(error)") }
                }
            }
        }
        // 自动测试用：DOUDUO_LIVETEST=1 → 对比不同 Referer 下是否能拿到视频轨
        if ProcessInfo.processInfo.environment["DOUDUO_LIVETEST"] == "1" {
            Task { @MainActor in
                let rooms = (try? await actTestBridge.fetchLive(reset: true)) ?? []
                LocalVideoLaunch.log("DDLIVE rooms=\(rooms.count)")
                for (i, r) in rooms.prefix(4).enumerated() {
                    guard let u = r.bestHLS else { continue }
                    for ref in ["https://live.douyin.com/", "https://live.douyin.com/\(r.webRid)", "https://www.douyin.com/"] {
                        var h = DYMedia.headers
                        h["Referer"] = ref
                        let asset = AVURLAsset(url: u, options: ["AVURLAssetHTTPHeaderFieldsKey": h])
                        let item = AVPlayerItem(asset: asset)
                        let p = AVPlayer(playerItem: item)
                        p.play()
                        try? await Task.sleep(nanoseconds: 7_000_000_000)
                        if i == 0, ref.hasSuffix(".com/") { LocalVideoLaunch.log("DDLIVEURL \(u.absoluteString)") }
                        LocalVideoLaunch.log("DDLIVE #\(i) ref=\(ref.suffix(12)) st=\(item.status.rawValue) size=\(item.presentationSize) n=\(item.tracks.count) types=\(item.tracks.compactMap { $0.assetTrack?.mediaType.rawValue }.joined(separator: ",")) t=\(String(format: "%.1f", p.currentTime().seconds))")
                        p.pause()
                    }
                }
                LocalVideoLaunch.log("DDLIVE done")
            }
        }
        // 自动测试用：DOUDUO_BGTEST=1 → 起播 20 秒后模拟一次「进后台」，验证停声链路
        if ProcessInfo.processInfo.environment["DOUDUO_BGTEST"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
                LocalVideoLaunch.log("DDBG bgtest pauseAll")
                DDPlayback.shared.pauseAll()
            }
        }
        #endif
        return true
    }
}

@main
struct DouDuoApp: App {
    @UIApplicationDelegateAdaptor(DouDuoAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if let target = LocalVideoLaunch.target {
                LocalVideoPlaybackView(url: target.url, fillWidth: target.fill)
            } else {
                DouyinFeedScreen()
                    .preferredColorScheme(.dark)
            }
            #else
            DouyinFeedScreen()
                .preferredColorScheme(.dark)
            #endif
        }
        // 退到后台 / 锁屏 / 来电：立刻停掉所有播放器的声音（不做后台播放）
        .onChange(of: scenePhase) { _, phase in
            #if DEBUG
            LocalVideoLaunch.log("DDSCENE phase=\(String(describing: phase))")
            #endif
            switch phase {
            case .active: DDPlayback.shared.resumeAll()
            default: DDPlayback.shared.pauseAll()
            }
        }
    }
}

#if DEBUG
/// 给 DOUDUO_ACTTEST 用的、独立于界面的桥接实例
@MainActor
let actTestBridge = DouyinBridge()

/// 用法：启动环境变量 DOUDUO_LOCALVIDEO=<Documents 里的文件名或绝对路径> [DOUDUO_LOCALFIT=0]
/// 直接把本地视频丢进播放页，用来核对「自动铺满宽度」的裁切效果。
enum LocalVideoLaunch {
    static func log(_ s: String) {
        let u = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("ddlog.txt")
        let line = "\(Date()) \(s)\n"
        if let h = try? FileHandle(forWritingTo: u) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? Data(line.utf8).write(to: u) }
    }
    static var target: (url: URL, fill: Bool)? {
        let env = ProcessInfo.processInfo.environment
        guard let p = env["DOUDUO_LOCALVIDEO"] else { return nil }
        let url = p.hasPrefix("/") ? URL(fileURLWithPath: p)
            : FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(p)
        return (url, env["DOUDUO_LOCALFIT"] != "0")
    }
}

struct LocalVideoPlaybackView: View {
    let url: URL
    let fillWidth: Bool
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PlayerPage.external(id: "local", title: url.lastPathComponent, url: url, durationSec: 20,
                                isActive: true, topInset: 0, bottomInset: 0, resumePosition: nil,
                                compactChrome: true, onEnded: nil, onDoubleTap: nil,
                                onSavePosition: { _ in }, onClose: {}, fillWidth: fillWidth)
        }
        .preferredColorScheme(.dark)
    }
}
#endif

#if DEBUG
/// 接口探针：DOUDUO_APITEST=1，用界面里那个挂在窗口上的签名页跑
@MainActor enum DDApiProbe {
    static func run(_ b: DouyinBridge) async {
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                let pre = #"""
                const sum = (name, r) => {
                  const d = parse(r.t) || {};
                  const lists = Object.keys(d).filter(k => Array.isArray(d[k])).map(k => k + ':' + d[k].length).join(',');
                  return name + ' http=' + r.s + ' code=' + d.status_code + ' msg=' + (d.status_msg || '') + ' lists=[' + lists + '] more=' + d.has_more + ' cur=' + (d.cursor ?? d.max_cursor) + ' keys=' + Object.keys(d).slice(0, 14).join('|') + (Object.keys(d).length ? '' : ' raw=' + (r.t || '').slice(0, 80));
                };
                const q = s => new URLSearchParams(Object.assign({}, base, s)).toString();
                """#
                // 先拿一条有评论的推荐视频
                let pick = await b.probe(pre + #"""
                const fr = await req('POST', '/aweme/v2/web/module/feed/?' + q({ module_id: '3003101', count: '10', refresh_index: '3', pull_type: '2', refer_type: '10' }), '');
                const list = (parse(fr.t) || {}).aweme_list || [];
                const a = list.find(a => a && a.statistics && a.statistics.comment_count > 50) || list[0] || {};
                return [a.aweme_id, (a.video && a.video.duration) || 60000, (a.author && a.author.sec_uid) || ''].join(' ');
                """#)
                LocalVideoLaunch.log("DDAPI pick=\(pick)")
                let parts = pick.split(separator: " ").map(String.init)
                guard parts.count >= 3 else { return }
                let aid = parts[0], dur = parts[1], sec = parts[2]
                let extra = "const ck = k => ((document.cookie.match(new RegExp('(?:^|; )' + k + '=([^;]*)')) || [])[1] || ''); const ex = { webid: ck('webid') || ck('UIFID_TEMP').slice(0, 19), msToken: localStorage.getItem('xmst') || ck('msToken'), verifyFp: ck('s_v_web_id'), fp: ck('s_v_web_id') }; const fx = async (u) => { try { const r = await Promise.race([fetch(u, { credentials: 'include', headers: { accept: 'application/json' } }), new Promise((_, no) => setTimeout(() => no('to'), 12000))]); return { s: r.status, t: await r.text() } } catch (e) { return { s: -9, t: String(e) } } };"
                let rp = "const cm = parse((await req('GET', '/aweme/v1/web/comment/list/?' + q({ aweme_id: '\(aid)', cursor: '0', count: '20', item_type: '0' }))).t) || {}; const c0 = (cm.comments || []).find(c => c.reply_comment_total > 0); const cid = c0 ? String(c0.cid) : '0';"
                let tests: [(String, String)] = [
                    ("search-item", "const r = await req('GET', '/aweme/v1/web/search/item/?' + q({ search_channel: 'aweme_video_web', keyword: '猫', search_source: 'normal_search', query_correct_type: '1', is_filter_search: '0', from_group_id: '', offset: '0', count: '16', need_filter_settings: '1', list_type: 'single' })); const d = parse(r.t) || {}; const x = (d.data || [])[0] || {}; return sum('search-item', r) + ' x0=' + Object.keys(x).join('|') + ' al=' + (d.aweme_list||[]).length + ' a0=' + Object.keys((d.aweme_list||[])[0]||{}).slice(0,8).join('|');"),
                    ("search-general", "const r = await req('GET', '/aweme/v1/web/general/search/single/?' + q({ search_channel: 'aweme_general', keyword: '猫', search_source: 'normal_search', query_correct_type: '1', is_filter_search: '0', from_group_id: '', offset: '0', count: '16', need_filter_settings: '1', list_type: 'single' })); const d = parse(r.t) || {}; const t = (d.data || []).map(x => x.type + ':' + (!!x.aweme_info)).join(','); return sum('search-general', r) + ' types=' + t;"),
                    ("reply-fetch2", "const cm = parse((await req('GET', '/aweme/v1/web/comment/list/?' + q({ aweme_id: '\(aid)', cursor: '0', count: '20', item_type: '0' }))).t) || {}; const c0 = (cm.comments || []).find(c => c.reply_comment_total > 0); if (!c0) return 'none'; const u = '/aweme/v1/web/comment/list/reply/?' + q({ item_id: '\(aid)', comment_id: String(c0.cid), cut_version: '1', cursor: '0', count: '3', item_type: '0' }); const r = await Promise.race([fetch(u, { credentials: 'include' }).then(async x => ({ s: x.status, t: await x.text(), h: x.headers.get('content-length') + '/' + x.headers.get('x-tt-logid') })), new Promise(ok => setTimeout(() => ok({ s: -3, t: '', h: '' }), 12000))]); return 'reply-fetch2 http=' + r.s + ' len=' + r.t.length + ' h=' + r.h + ' head=' + r.t.slice(0, 120);"),
                ]
                for (name, body) in tests {
                    LocalVideoLaunch.log("DDAPI start \(name)")
                    let r = await withTaskGroup(of: String.self) { g -> String in
                        g.addTask { await b.probe(pre + body) }
                        g.addTask { try? await Task.sleep(nanoseconds: 30_000_000_000); return "TIMEOUT" }
                        let first = await g.next() ?? "?"
                        g.cancelAll()
                        return first
                    }
                    LocalVideoLaunch.log("DDAPI \(name): " + r.prefix(900))
                }
                LocalVideoLaunch.log("DDAPI done")
            
    }
}
#endif
