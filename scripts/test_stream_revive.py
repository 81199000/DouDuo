#!/usr/bin/env python3
"""回前台卡十几秒
挂起时边下边播的连接被冻住，回来还占着「正在下这段」，播放器干等到 20 秒超时。
回前台作废旧连接 → 从已喂到的位置用新连接续拉。这里起本地慢速服务器真跑 DYChunkStream。"""
import http.server, pathlib, socketserver, subprocess, sys, tempfile, threading, time
R = pathlib.Path(__file__).resolve().parent.parent / "DouDuo"
s = (R / "DYStreamCache.swift").read_text()
fails = []
def check(ok, msg):
    print(("PASS " if ok else "FAIL ") + msg)
    if not ok: fails.append(msg)

check("willEnterForegroundNotification" in s and "reviveAfterForeground()" in s, "回前台触发作废")
rv = s[s.index("    private func reviveAfterForeground() {"):][:900]
check("_session = DYStreamLoader.makeSession()" in rv and "abortForRevive()" in rv, "换新会话 + 作废旧连接")
check("DYStreamPlan.reviveAfterBackground" in rv, "短暂离开（下拉控制中心）不动")
check("track(chunks)" in s and "untrack(cid)" in s, "正在收数据的连接都登记了")
sv = s[s.index("    private func serve("):s.index("    private func ensureInfo(")]
rb = sv[sv.index("catch where DYChunkStream.isRevive(error)"):][:300] if "catch where DYChunkStream.isRevive(error)" in sv else ""
check("cursor = fed\n                    continue" in rb, "供数据从已喂到的位置续拉（不重复喂）")
dl = s[s.index("    private func download("):s.index("/// 用 dataTask + delegate")]
check("if DYChunkStream.isRevive(error) { throw error }" in dl, "下载层不原地重下（防重复字节）")
pm = s[s.index("    func pump(_ e: DYStreamEntry) {"):s.index("    func fillWhole(")]
check("if !DYChunkStream.isRevive(error)" in pm, "补货作废后不多等 1 秒")

DATA = bytes(range(256)) * 4096
hits = {"n": 0}
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args): pass
    def do_GET(self):
        hits["n"] += 1; me = hits["n"]
        a, b = (int(x) for x in self.headers["Range"].split("=")[1].split("-"))
        body = DATA[a:b + 1]
        self.send_response(206); self.send_header("Content-Range", f"bytes {a}-{b}/{len(DATA)}")
        self.send_header("Content-Length", str(len(body))); self.end_headers()
        try:
            if me == 1:   # 冻住的连接：发 64KB 后不动
                self.wfile.write(body[:65536]); self.wfile.flush(); time.sleep(30); return
            self.wfile.write(body)
        except Exception: pass
socketserver.ThreadingTCPServer.allow_reuse_address = True
srv = socketserver.ThreadingTCPServer(("127.0.0.1", 0), H); srv.daemon_threads = True
port = srv.server_address[1]
threading.Thread(target=srv.serve_forever, daemon=True).start()

chunk = "import Foundation\n" + s[s.index("final class DYChunkStream"):]
main = r'''import Foundation
let c = URLSessionConfiguration.default; c.timeoutIntervalForRequest = 20
var r = URLRequest(url: URL(string: "http://127.0.0.1:PORT/v")!); r.setValue("bytes=0-1048575", forHTTPHeaderField: "Range")
func run() async {
    let t0 = Date()
    let a = DYChunkStream(session: URLSession(configuration: c), request: r)
    _ = try! await a.response()
    var got = 0, bytes = Data()
    Task { try? await Task.sleep(for: .seconds(1)); a.abortForRevive() }
    do { for try await d in a.data { got += d.count; bytes.append(d) }; fatalError("冻住的连接不该正常结束") }
    catch { precondition(DYChunkStream.isRevive(error), "作废要以 revive 结束，不是 \(error)") }
    let waited = Date().timeIntervalSince(t0)
    precondition(waited < 3, "作废后要立刻结束，实际 \(waited)s")
    var r2 = r; r2.setValue("bytes=\(got)-1048575", forHTTPHeaderField: "Range")
    let b = DYChunkStream(session: URLSession(configuration: c), request: r2)
    _ = try! await b.response()
    do { for try await d in b.data { bytes.append(d) } } catch { fatalError("新连接出错 \(error)") }
    let want = Data((0..<1048576).map { UInt8($0 % 256) })
    precondition(bytes == want, "续拉后字节要和原文件一致（\(bytes.count) 字节）")
    let x = DYChunkStream(session: URLSession(configuration: c), request: r2)
    _ = try? await x.response(); x.cancel()
    do { for try await _ in x.data {} } catch {
        precondition(error is CancellationError && !DYChunkStream.isRevive(error), "普通取消仍是 CancellationError")
    }
    print(String(format: "PASS 冻住的连接 %.1fs 作废、新连接续拉 1024KB 无缺无重", waited))
    exit(0)
}
Task { await run() }
RunLoop.main.run()
'''.replace("PORT", str(port))
with tempfile.TemporaryDirectory() as d:
    d = pathlib.Path(d)
    (d / "chunk.swift").write_text(chunk); (d / "main.swift").write_text(main)
    b = subprocess.run(["swiftc", "-O", str(d / "chunk.swift"), str(d / "main.swift"), "-o", str(d / "rv")], text=True, capture_output=True, timeout=300)
    if b.returncode != 0: print(b.stderr[-800:])
    out = subprocess.run([str(d / "rv")], text=True, capture_output=True, timeout=60) if b.returncode == 0 else b
print(out.stdout.strip())
if out.returncode != 0: print(out.stderr[-800:])
check(out.returncode == 0, "本地慢速服务器真跑")
sys.exit(1 if fails else 0)
