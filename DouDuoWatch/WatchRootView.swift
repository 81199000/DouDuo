import SwiftUI

struct WatchRootView: View {
    @EnvironmentObject var model: WatchModel

    var body: some View {
        Group {
            if model.activated && !model.status.loggedIn && model.status.updated > 0 {
                NotLoggedInView()
            } else {
                VideoPagerView()
            }
        }
        .task { await model.refreshStatus() }
    }
}

/// 表上当前装的版本：版本号 + 表端程序构建时间，用来确认表端有没有跟着手机更新
enum WatchBuild {
    static let stamp: String = {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let d = (try? Bundle.main.executableURL?.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil
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
