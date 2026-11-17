import SwiftUI

struct WatchRootView: View {
    @EnvironmentObject var model: WatchModel
    @State private var showInbox = false

    var body: some View {
        Group {
            if model.activated && !model.status.loggedIn && model.status.updated > 0 {
                NotLoggedInView()
            } else {
                // 视频页独占竖向翻页手势（上下滑 / 数码表冠）。不再和横向分页嵌套，否则两层手势互相抢、竖滑切不了视频。
                NavigationStack {
                    VideoPagerView()
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button { showInbox = true } label: {
                                    Image(systemName: model.status.unreadTotal > 0 ? "bell.badge.fill" : "bell")
                                }
                            }
                        }
                        .navigationDestination(isPresented: $showInbox) { InboxView() }
                }
            }
        }
        .task { await model.refreshStatus() }
    }
}

/// 表上当前装的版本：Info.plist 里的版本号 + 可执行文件时间，用来确认表端有没有跟着手机更新
enum WatchBuild {
    static let stamp: String = {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let exe = Bundle.main.executableURL
        let d = (try? exe?.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"
        return "\(v)(\(b)) \(d.map { f.string(from: $0) } ?? "")"
    }()
}

/// 手表上没有登录入口：登录只能在 iPhone 的 DouDuo 里做
struct NotLoggedInView: View {
    @EnvironmentObject var model: WatchModel
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "iphone.and.arrow.forward").font(.system(size: 30))
            Text("请在 iPhone 上登录 DouDuo").font(.footnote).multilineTextAlignment(.center)
            Button("刷新") { Task { await model.refreshStatus() } }
        }
        .padding()
    }
}
