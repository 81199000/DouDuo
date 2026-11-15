#if DEBUG
import SwiftUI
import WebKit

struct DDAppearanceStateProbe: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        if ProcessInfo.processInfo.environment["DOUDUO_APPEARANCE_TEST"] == "1" {
            Text(scheme == .dark ? "dark" : "light")
                .font(.caption2).opacity(0.01).allowsHitTesting(false)
                .accessibilityIdentifier("appearance.resolved")
        }
    }
}

struct DDAppearanceWebProbe: View {
    @Environment(\.colorScheme) private var scheme
    @AppStorage(DDAppearance.key) private var appearance = DDAppearance.dark.rawValue
    @StateObject private var model = DouyinWebModel()
    @State private var report = ""

    var body: some View {
        VStack(spacing: 16) {
            Picker("外观", selection: $appearance) {
                ForEach(DDAppearance.allCases) { Text($0.title).tag($0.rawValue) }
            }.pickerStyle(.segmented).padding(.horizontal)
            DouyinWebContainer(model: model, zoom: 1, start: ProcessInfo.processInfo.environment["DOUDUO_APPEARANCE_WEB_LIVE"] == "1" ? DouyinWeb.home : URL(string: "https://www.douyin.com/appearance-test")!)
            Text(report).font(.caption2).lineLimit(1).frame(height: 14).accessibilityIdentifier("appearance.web.report")
        }
        .background(Color.ddBackground)
        .task(id: scheme) {
            while !Task.isCancelled {
                if let web = model.web,
                   let json = try? await web.evaluateJavaScript(Self.snapshot) as? String {
                    report = json
                    if ProcessInfo.processInfo.environment["DOUDUO_WEB_DIAGNOSTICS"] == "1",
                       let diagnostic = try? await web.evaluateJavaScript(Self.diagnostics) as? String {
                        let path = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                            .appendingPathComponent("appearance-web-diagnostics.json")
                        try? diagnostic.write(to: path, atomically: true, encoding: .utf8)
                    }
                }
                do { try await Task.sleep(for: .milliseconds(250)) }
                catch { return }
            }
        }
    }

    static let html = #"""
    <!doctype html><html data-theme="dark"><head><meta name="viewport" content="width=device-width,initial-scale=1">
    <style>
    body {font:24px system-ui;margin:0;padding:24px;box-sizing:border-box}
    body {background:#202426;color:#e4e6e8}
    .chatDark,.chatLight {padding:24px;border-radius:16px;background:#282b30;color:inherit}
    .messageTextContent {padding:20px;border-radius:16px;background:#30343b}
    textarea {font:24px system-ui;width:90%;margin-top:24px;background:var(--dd-page-panel,#33363c);color:inherit}
    </style></head><body><h1>网页主题验证</h1><div class="chatDark"><p class="messageTextContent">这条消息的正文和背景应同步切换。</p>
    <textarea aria-label="网页草稿">保留这段未发送的文字</textarea></div>
    <video id="media" style="background:rgb(20,30,40);filter:none"></video>
    <script>window.probeToken=String(Math.random());window.probeScroll=0;</script></body></html>
    """#

    private static let diagnostics = #"""
    (() => {
      const nodes = [...document.querySelectorAll('body,body *')].filter(e => {
        const r=e.getBoundingClientRect(), s=getComputedStyle(e);
        return r.width>150 && r.height>40 && r.top<innerHeight && r.bottom>0 && s.backgroundColor!=='rgba(0, 0, 0, 0)';
      }).slice(0,45);
      const describe = e => {const s=getComputedStyle(e),r=e.getBoundingClientRect();return {tag:e.tagName,id:e.id,class:e.className,
        attributes:[...e.attributes].filter(a=>/theme|mode/i.test(a.name)).map(a=>[a.name,a.value]),
        background:s.backgroundColor,color:s.color,width:r.width,height:r.height,
        variables:[...s].filter(k=>k.startsWith('--')&&/bg|text|background|theme/i.test(k)).map(k=>[k,s.getPropertyValue(k)])};};
      return JSON.stringify({url:location.href,root:describe(document.documentElement),nodes:nodes.map(describe),sheets:[...document.styleSheets].map(s=>s.href)});
    })()
    """#

    private static let snapshot = #"""
    (() => {
      const root = document.documentElement, body = document.body;
      const text = document.querySelector('.messageTextContent') || body;
      document.querySelectorAll('video,audio').forEach(v => { v.muted = true; v.pause(); });
      window.probeToken ||= String(Math.random());
      return JSON.stringify({mode:root.dataset.ddAppearance, appPalette:!!document.getElementById("dd-appearance"), background:getComputedStyle(body).backgroundColor,
        shellBackground:getComputedStyle(document.querySelector("#dark,#light,.chatDark,.chatLight") || body).backgroundColor,
        foreground:text && getComputedStyle(text).color, draft:document.querySelector('textarea')?.value,
        token:window.probeToken, url:location.href, rootClass:root.className, bodyClass:body.className,
        surfaces:[...document.querySelectorAll('main,header,nav,[class*=RightPanel],[class*=messageText]')].slice(0,12).map(e=>({class:e.className,bg:getComputedStyle(e).backgroundColor,fg:getComputedStyle(e).color})), mediaFilter:document.getElementById('media') ? getComputedStyle(document.getElementById('media')).filter : 'none'});
    })()
    """#
}
#endif
