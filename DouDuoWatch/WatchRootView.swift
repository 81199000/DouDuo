import SwiftUI

struct WatchRootView: View {
    @EnvironmentObject var model: WatchModel
    #if DEBUG
    @State private var tab = UserDefaults.standard.string(forKey: "dd_debug_tab") == "inbox" ? 1 : 0
    #else
    @State private var tab = 0
    #endif
    var body: some View {
        Group {
            if model.activated && !model.status.loggedIn && model.status.updated > 0 {
                NotLoggedInView()
            } else {
                TabView(selection: $tab) {
                    VideoPagerView().tag(0)
                    InboxView().tag(1)
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
