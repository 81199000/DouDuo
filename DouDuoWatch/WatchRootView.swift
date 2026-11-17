import SwiftUI

struct WatchRootView: View {
    @EnvironmentObject var model: WatchModel
    var body: some View {
        Group {
            if model.activated && !model.status.loggedIn && model.status.updated > 0 {
                NotLoggedInView()
            } else {
                TabView {
                    VideoPagerView()
                    InboxView()
                }
                .tabViewStyle(.page)
            }
        }
        .task { await model.refreshStatus() }
    }
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
