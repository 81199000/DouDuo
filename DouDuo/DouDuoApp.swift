import SwiftUI
import UIKit

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
