import SwiftUI

/// 写操作（评论 / 回复）被抖音判成未登录：本机 cookie 还在、浏览照常，但抖音不接受这份登录写入。
struct DYLoginExpired: LocalizedError {
    var errorDescription: String? { "登录已失效（能浏览但发不了评论），请重新登录" }
}

/// 登录失效时就地弹出 App 内登录页（老板 11-18）。
/// 先退出本机这份失效登录：不然登录页还认着旧 sessionid，网页可能直接跳走、判不出这次登录成功。
/// 退出不调抖音登出接口、账号仍留在「账号」列表里（见 DYAccountStore.signOut），关掉登录页不登也能切回去。
@MainActor
enum DYRelogin {
    static func start(_ present: @escaping () -> Void) {
        DYLiveModel.log("DDRELOGIN start (write rejected code=8)")
        Task {
            await DYAccountStore.shared.signOut()
            present()
        }
    }
}

struct DYReloginSheet: ViewModifier {
    @Binding var isPresented: Bool
    let bridge: DouyinBridge
    /// 登录页关掉后回调：true = 已经换上新的登录
    var onFinish: (Bool) -> Void

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented, onDismiss: {
            // 网页登录组件把新登录写进共享 cookie：签名页重载后才用得上
            bridge.reload()
            Task { @MainActor in
                let ok = await DYLoginState.hasSession()
                DYLiveModel.log("DDRELOGIN done session=\(ok)")
                onFinish(ok)
                // 新登录记进账号列表（跟「我的」页登录后一样），之后切换账号用的是这份新的
                if ok, let u = try? await bridge.selfProfile() { await DYAccountStore.shared.remember(u) }
            }
        }) {
            DYAppLoginScreen()
        }
    }
}

extension View {
    func dyReloginSheet(isPresented: Binding<Bool>, bridge: DouyinBridge, onFinish: @escaping (Bool) -> Void) -> some View {
        modifier(DYReloginSheet(isPresented: isPresented, bridge: bridge, onFinish: onFinish))
    }
}
