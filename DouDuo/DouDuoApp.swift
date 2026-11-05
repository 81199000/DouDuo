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
        // 自动测试用：DOUDUO_LIVETEST=1 → 静默试播前 6 个直播间，逐条写日志（模拟器里跑，不碰手机）
        if ProcessInfo.processInfo.environment["DOUDUO_LIVETEST"] == "1" {
            Task { @MainActor in
                let rooms = (try? await actTestBridge.fetchLive(reset: true)) ?? []
                LocalVideoLaunch.log("DDLIVE rooms=\(rooms.count)")
                for (i, r) in rooms.prefix(6).enumerated() {
                    guard let u = r.bestHLS else { continue }
                    LocalVideoLaunch.log("DDLIVE #\(i) \(r.title) quality=\(r.hls.keys.sorted().joined(separator: "/")) url=\(u.absoluteString.prefix(80))")
                    let p = AVPlayer()
                    let withHeaders = AVPlayerItem(asset: DYMedia.liveAsset(u))
                    p.replaceCurrentItem(with: withHeaders)
                    p.play()
                    try? await Task.sleep(nanoseconds: 6_000_000_000)
                    LocalVideoLaunch.log("DDLIVE #\(i) headers status=\(withHeaders.status.rawValue) t=\(String(format: "%.1f", p.currentTime().seconds)) err=\(String(describing: withHeaders.error).prefix(100))")
                    if withHeaders.status != .readyToPlay {
                        // 换常用画质再试；有些房间 HD1 挂了但 SD1 正常
                        for key in ["FULL_HD1", "SD1", "SD2"] {
                            guard let s2 = r.hls[key], let u2 = URL(string: s2) else { continue }
                            let p2 = AVPlayer(); let it2 = AVPlayerItem(asset: DYMedia.liveAsset(u2)); p2.replaceCurrentItem(with: it2); p2.play()
                            try? await Task.sleep(nanoseconds: 4_000_000_000)
                            LocalVideoLaunch.log("DDLIVE #\(i) \(key) status=\(it2.status.rawValue) t=\(String(format: "%.1f", p2.currentTime().seconds))")
                            if it2.status == .readyToPlay { break }
                        }
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
