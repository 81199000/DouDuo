#!/usr/bin/env python3
"""长视频快进卡：拖进度的预览小图跟播放器共用同一资源，手指扫过的位置都去联网下
抢掉松手后真正要播那段的带宽。改为预览只读本地已有（ddstream://…?peek=1），松手取消未出的预览。"""
import pathlib, subprocess, sys, tempfile
R = pathlib.Path(__file__).resolve().parent.parent / "DouDuo"
s = (R / "DYStreamCache.swift").read_text()
p = (R / "ShortVideoPlayer.swift").read_text()
fails = []
def check(ok, msg):
    print(("PASS " if ok else "FAIL ") + msg)
    if not ok: fails.append(msg)

check("AVAssetImageGenerator(asset: DYStream.peekAsset(for: asset))" in p, "预览小图走只读资源")
check("AVAssetImageGenerator(asset: asset)" not in p, "不再拿播放器同一资源出预览")
lo = s[s.index("    func resourceLoader(_ loader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource"):][:700]
check("if DYStream.isPeek(url) { servePeek(req, entry: e); return true }" in lo, "资源加载按 peek 分流")
pk = s[s.index("    private func servePeek("):s.index("    private func serve(_ req")]
check("download(" not in pk and "ensureInfo(" not in pk and "windows" not in pk, "预览不联网、不开跳读窗口")
check(pk.count("finishLoading(with: URLError(.resourceUnavailable))") == 2, "缺数据立刻拒（不挂住）")
fs = p[p.index("    private func finishSeek() {"):][:600]
i_cancel = fs.find("imgGen?.cancelAllCGImageGeneration()"); i_seek = fs.find("seekTo(target)")
check(i_cancel != -1 and i_cancel < i_seek, "松手先取消未出的预览再跳")
check(p.count("finishSeek()") >= 3, "两种松手路径都走 finishSeek")
check('"DDSEEKNET' in p and "DDSeekProbe.drain()" in p, "快进日志：松手到在播耗时 + 预览命中/落空")

# 真跑：peek 规则对已缓存/未缓存位置的反应（只读 DYStreamPlan.contiguous，与 servePeek 同一判断）
plan = (R / "DYStreamPlan.swift").read_text()
harness = plan + """
let MB = Int64(1 << 20)
let ranges: [Range<Int64>] = [0..<(20 * MB), (50 * MB)..<(52 * MB)]
func peek(_ off: Int64, _ len: Int64) -> Bool {   // servePeek 的判定：从 off 起连续够 len 才给
    var cur = off; let end = off + len
    while cur < end { let n = DYStreamPlan.contiguous(from: cur, in: ranges); if n <= 0 { return false }; cur += min(n, end - cur) }
    return true
}
precondition(peek(5 * MB, MB), "已缓存段给")
precondition(!peek(30 * MB, MB), "没缓存段拒")
precondition(!peek(19 * MB + MB / 2, MB), "跨出缓存边界拒")
precondition(peek(50 * MB, MB), "跳着缓存的段也给")
print("PASS peek rule")
"""
with tempfile.TemporaryDirectory() as d:
    f = pathlib.Path(d) / "P.swift"; f.write_text(harness)
    out = subprocess.run(["swift", str(f)], text=True, capture_output=True, timeout=180)
print(out.stdout.strip())
if out.returncode != 0: print(out.stderr[-600:])
check(out.returncode == 0, "peek 规则真跑")
sys.exit(1 if fails else 0)
