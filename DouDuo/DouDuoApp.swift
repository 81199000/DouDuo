import SwiftUI

@main
struct DouDuoApp: App {
    var body: some Scene {
        WindowGroup {
            if let target = LocalVideoLaunch.target {
                LocalVideoPlaybackView(url: target.url, fillWidth: target.fill)
            } else {
                DouyinFeedScreen()
                    .preferredColorScheme(.dark)
            }
        }
    }
}

#if DEBUG
/// 用法：启动环境变量 DOUDUO_LOCALVIDEO=<Documents 里的文件名或绝对路径> [DOUDUO_LOCALFIT=0]
/// 直接把本地视频丢进播放页，用来核对「自动铺满宽度」的裁切效果。
enum LocalVideoLaunch {
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
