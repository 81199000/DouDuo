// DouDuo 手表端：只做「手机登录态的遥控屏」——看消息、播 iPhone 推过来的视频。
// 手表上没有登录入口，也不直连抖音；所有数据来自 iPhone（WatchConnectivity）。
import SwiftUI

@main
struct DouDuoWatchApp: App {
    @StateObject private var model = WatchModel.shared
    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environmentObject(model)
        }
    }
}
