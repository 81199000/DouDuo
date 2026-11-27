import Foundation
import WebKit

/// 「保存登录信息」默认替用户点「保存」。
///
/// 抖音网页登录成功后会弹「是否保存登录信息？（5）」，5 秒倒计时，不点就自动关掉 = 不保存。
/// 网页说明是「保存登录信息，下次登录免验证」，点「保存」后网页调 `/passport/user/web_record_status/set/`
/// 把这台设备记成可信设备（实现见抖音网页 client-entry 包 395911 模块）。
///
/// 做法：所有登录态相关的抖音网页（App 内登录页、隐藏签名页、网页版）一开页就挂这段脚本，
/// 弹框一出现就点它自己的「保存」按钮 —— 走的是网页原本的点击流程（签名、接口、本地记录都由网页自己完成），
/// 不自己拼接口。只点弹框里的「保存」，不碰设置里的开关（那个是来回切换，点错会关掉）。
enum DYTrustLogin {
    static let script = #"""
    (() => {
      if (window.__ddTrustAuto) return;
      window.__ddTrustAuto = true;
      window.__ddTrustClicked = 0;
      const pick = () => document.querySelector('.trust-login-dialog-button-confirm')
        || [...document.querySelectorAll('[class*="trust-login-menu"] button, [class*="trust-login-menu"] [class*="confirm"]')]
             .find(e => (e.innerText || '').trim() === '保存');
      const tryClick = () => {
        const b = pick();
        if (!b || b.__ddClicked) return;
        b.__ddClicked = true;
        b.click();
        window.__ddTrustClicked += 1;
      };
      const start = () => {
        tryClick();
        new MutationObserver(tryClick).observe(document.documentElement, { childList: true, subtree: true });
      };
      if (document.documentElement) start(); else document.addEventListener('DOMContentLoaded', start);
    })();
    """#

    static func install(in cfg: WKWebViewConfiguration) {
        cfg.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    }

    /// 登录页已登录成功后：等网页弹「保存登录信息」并被点掉（最多 seconds 秒），返回点了几次
    @MainActor
    static func waitClicked(in web: WKWebView, seconds: Double) async -> Int {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let n = (try? await web.evaluateJavaScript("window.__ddTrustClicked || 0")) as? Int ?? 0
            if n > 0 {
                // 给网页一点时间把「保存」的请求发完再关页面
                try? await Task.sleep(for: .milliseconds(1200))
                return n
            }
            try? await Task.sleep(for: .milliseconds(400))
        }
        return 0
    }
}
