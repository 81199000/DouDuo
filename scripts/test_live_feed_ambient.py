#!/usr/bin/env python3
"""推荐流里刷到的直播加环境光：直播走 VLC 没有 AVPlayerItem
用 VLC 截小图 → 同一套模糊铺背景；画面层缩到画面大小居中，留边不盖住环境光。"""
import pathlib, sys
R = pathlib.Path(__file__).resolve().parent.parent / "DouDuo"
a = (R / "DYLiveAmbient.swift").read_text()
page = (R / "DYFeedLivePage.swift").read_text()
warm = (R / "DYFeedLiveWarm.swift").read_text()
vid = (R / "DYVideoAmbient.swift").read_text()
fails = []
def check(ok, msg):
    print(("PASS " if ok else "FAIL ") + msg)
    if not ok: fails.append(msg)

check("@AppStorage(DYVideoAmbient.key) private var ambientLevel = DYVideoAmbient.defaultLevel" in page, "跟视频共用环境光设置")
body = page[page.index("    var body: some View {"):page.index("    private var enterButton")]
i_amb = body.find("DYLiveAmbientBackdrop("); i_vid = body.find("DYFeedLiveVideo(")
check(i_amb != -1 and i_amb < i_vid, "环境光垫在直播画面下面")
check("if isCurrent, ambientLevel > 0 {" in body, "设置为「关」或不是当前条不出")
check("dim: DYVideoAmbient.dim" in body, "压暗程度统一")
check("controller: warm?.controller ?? player" in body[i_amb:i_amb + 200], "预热那一路也有环境光")

check("saveVideoSnapshot(at: path, withWidth: Self.width, andHeight: 0)" in a, "用 VLC 截小图取色")
check("DDTryObjC({ mp.saveVideoSnapshot(" in a, "截图包在 ObjC @try 里：VLCKit 截不到图会抛 NSException，不接住整个 App 闪退")
check("mp.hasVideoOut" in a, "没有视频输出时不截")
tk = a[a.index("    private func tick() {"):a.index("    static func blurred(")]
check("Self.queue.async" in tk and tk.index("Self.queue.async") < tk.index("saveVideoSnapshot"), "截图不在主线程")
check("guard !working" in tk, "上一张没好不截下一张")
check("!covered" in tk, "铺满整屏时不截")
check("thermalState" in a and "ProcessInfo.ThermalState.serious" in a, "发热停")
for k in ["applyingGaussianBlur(sigma: 3)", "kCIInputSaturationKey: 0.85", "48 / max(src.extent.width, 1)"]:
    check(k in a and k in vid, f"处理跟视频环境光一致：{k}")
check('"DDLIVEAMBIENT first' in a and '"DDLIVEAMBIENT snapshot' in a, "出图 / 截不到写日志")

lv = warm[warm.index("struct DYFeedLiveVideo: View {"):warm.index("enum DYFeedLeaving")]
check("DYVideoFit.contentSize(container: g.size" in lv and ".frame(width: fitted.width, height: fitted.height)" in lv, "画面层缩到画面大小，留边露出环境光")
sys.exit(1 if fails else 0)
