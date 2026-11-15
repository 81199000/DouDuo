#!/usr/bin/env python3
"""Compile the production probe gate and reject malformed or cross-origin events."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "DouDuo/DYDMProbe.swift").read_text()
scheme = (root / "DouDuo.xcodeproj/xcshareddata/xcschemes/DouDuo.xcscheme").read_text()
if "DOUDUO_DM_SHAPE" in scheme or "DOUDUO_DM_DIRECT_CHAT" in scheme:
    raise SystemExit("shape and direct-chat gates must stay out of the shared scheme")
if "isShapeBody(body), !DYDMProbe.shapeEnabled" not in source or "acceptShape: DYDMProbe.shapeEnabled" not in source:
    raise SystemExit("shape reports must be ignored unless the environment gate is on")
if "isRouteBody(body), !DYDMProbe.directEnabled" not in source or "acceptRoute: DYDMProbe.directEnabled" not in source:
    raise SystemExit("route reports must be ignored unless the environment gate is on")
if "DDDM route accept=1" not in source or "route.id" in "\n".join(line for line in source.splitlines() if "DYLiveModel.log" in line):
    raise SystemExit("route diagnostics must not include the conversation id")
start = source.index("// BEGIN DYDMProbeGate\n")
end = source.index("// END DYDMProbeGate\n", start)
gate = source[start:end].replace("// BEGIN DYDMProbeGate\n", "").replace("// END DYDMProbeGate\n", "")
logs = [line for line in source.splitlines() if "DYLiveModel.log(" in line]
forbidden = ("cookie", "token", "sessionid", "nickname", "preview", "sec_uid", "wss://", "http://", "https://")
for line in logs:
    lowered = line.lower()
    for word in forbidden:
        if word in lowered:
            raise SystemExit(f"probe log contains {word}: {line}")

live = subprocess.check_output(["node", "--input-type=module", "-e", r'''
import fs from "node:fs";
import vm from "node:vm";
const src = fs.readFileSync("DouDuo/DYDMProbe.swift", "utf8");
const start = src.indexOf("static let collectJS = #\"\"\"");
const end = src.indexOf("\"\"\"#", start);
const collectJS = src.slice(src.indexOf("\n", start) + 1, end);
let message = { serverId: "m1", isFromMe: false };
function row() {
  const element = { closest: () => null, __reactFiber$test: { memoizedProps: { conversation: { id: "a", lastVisibleMessage: message } }, return: null } };
  element.querySelector = () => null;
  return element;
}
const context = {
  document: { hidden: false, readyState: "complete",
    querySelector: s => s.includes("ConversationListwrapper") ? {} : null,
    querySelectorAll: () => [row()] },
  Date, Map, Object, JSON, Math, String, Number, Array
};
context.window = context; context.globalThis = context;
vm.createContext(context); vm.runInContext(collectJS, context);
context.__ddDM = { obs: 2, suppressed: 0 };
context.__ddDMGen = 3; context.__ddDMEpoch = 2;
const baseline = context.__ddDMCollect("obs");
message = { serverId: "m2", isFromMe: false };
const incoming = context.__ddDMCollect("poll");
const diag = context.__ddDMPendingDiag || "";
if (baseline.includes("null") || incoming.includes("null") || diag.includes("null")) process.exit(2);
if (diag.includes("m1") || diag.includes("m2")) process.exit(3);
if (context.__ddDMPendingShape) process.exit(4);
if (context.__ddDMPendingRoute) process.exit(5);
process.stdout.write(baseline + "\n" + incoming + "\n" + diag + "\n");
'''], text=True, cwd=Path(__file__).resolve().parents[1])
baseline_body, incoming_body, diag_body = [line for line in live.splitlines() if line.startswith("{")]

def swift_raw(text):
    if '"#' in text:
        raise SystemExit("payload cannot be embedded")
    return '#"' + text + '"#'

program = "import Foundation\n" + gate + f'''
let productionBaseline = {swift_raw(baseline_body)}
let productionIncoming = {swift_raw(incoming_body)}
let productionDiag = {swift_raw(diag_body)}
''' + r'''

func body(_ fields: [String: Any]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: fields)
    return String(data: data, encoding: .utf8)!
}

func base() -> [String: Any] {
    ["type": "dm-probe", "v": 1, "src": "obs", "seq": 1, "gen": 3, "epoch": 2,
     "baseline": 0, "incoming": 1, "outgoing": 0, "reorder": 0, "badge": 0, "rebuild": 0,
     "activity": 0, "visible": 4, "hidden": 0, "ready": 1, "obs": 7, "lag": 12]
}

func input(_ text: String, scheme: String? = "https", host: String? = "www.douyin.com", port: Int = 443,
           generation: Int = 3, epoch: Int = 2, lastSeq: Int = 0, recent: Int = 0, origin: Bool = true,
           shape: Bool = false, route: Bool = false) -> DYDMProbeGate.Input {
    DYDMProbeGate.Input(body: text, scheme: scheme, host: host, port: port, generation: generation,
                        epoch: epoch, lastSeq: lastSeq, recentCount: recent, requireOrigin: origin,
                        acceptShape: shape, acceptRoute: route)
}

func expectDrop(_ text: String, _ reason: String, _ mutate: (inout DYDMProbeGate.Input) -> Void = { _ in }) {
    var item = input(text)
    mutate(&item)
    guard case .drop(let got) = DYDMProbeGate.verdict(item), got == reason else {
        fatalError("expected drop \(reason)")
    }
}

let video = body(["type": "video", "id": "123"])
guard case .forward = DYDMProbeGate.verdict(input(video)) else { fatalError("video must forward") }
let miss = body(["type": "video-miss", "html": "shared-video-payload-unavailable"])
guard case .forward = DYDMProbeGate.verdict(input(miss)) else { fatalError("video-miss must forward") }

let good = body(base())
guard case .event(let event) = DYDMProbeGate.verdict(input(good)) else { fatalError("trusted event rejected") }
precondition(event.incoming == 1 && event.seq == 1 && event.baseline == 0)

guard case .event(let baseline) = DYDMProbeGate.verdict(input(productionBaseline)) else { fatalError("production baseline rejected") }
precondition(baseline.baseline == 1 && baseline.seq > 0 && baseline.incoming == 0)
guard case .event(let produced) = DYDMProbeGate.verdict(input(productionIncoming, lastSeq: baseline.seq)) else { fatalError("production incoming rejected") }
precondition(produced.incoming == 1 && produced.seq > baseline.seq && produced.baseline == 0)
guard case .event = DYDMProbeGate.verdict(input(productionIncoming, lastSeq: 0)) else { fatalError("epoch reset must still accept a later seq") }
let broken = productionBaseline.replacingOccurrences(of: "\"seq\":\(baseline.seq)", with: "\"seq\":null")
expectDrop(broken, "schema-seq")
guard case .diagnostic(let info) = DYDMProbeGate.verdict(input(productionDiag)) else { fatalError("production diagnostic rejected") }
precondition(info.eventSeq == produced.seq && info.changes.count == 1)
precondition(info.changes[0].relation == "unlinked-change" && info.changes[0].direction == "incoming")
guard case .forward = DYDMProbeGate.verdict(input(video)) else { fatalError("diagnostic handling changed video forwarding") }

expectDrop(good, "origin") { $0.host = "evil.example" }
expectDrop(good, "origin") { $0.scheme = "http" }
expectDrop(good, "origin") { $0.port = 8443 }
expectDrop(good, "duplicate") { $0.lastSeq = 1 }
expectDrop(good, "gen") { $0.generation = 4 }
expectDrop(good, "epoch") { $0.epoch = 1 }
expectDrop(good, "rate") { $0.recentCount = 4 }
var extra = base(); extra["name"] = "hidden"
expectDrop(body(extra), "schema")
var hydrated = base(); hydrated["baseline"] = 1
expectDrop(body(hydrated), "schema")
expectDrop("{\"type\":\"dm-probe\"" + String(repeating: " ", count: 600), "size")
let hugeVideo = "{\"type\":\"video\",\"id\":\"" + String(repeating: "1", count: 700) + "\"}"
guard case .forward = DYDMProbeGate.verdict(input(hugeVideo)) else { fatalError("oversized non-probe must forward") }
precondition(DYDMProbeGate.trustedHosts == Set(["www.douyin.com"]))
precondition(DYDMProbeGate.maxBytes == 512)

func shapeBody(_ mutate: (inout [String: Any]) -> Void = { _ in }) -> String {
    var fields: [String: Any] = ["type": "dm-probe-shape", "v": 1, "eventSeq": 2, "gen": 3, "epoch": 2,
        "msg": 1, "id": 1, "dir": 1, "alias": 0, "multi": 0, "same": 1, "hold": 0,
        "content": 3, "parsed": 0, "text": 0, "inner": 3, "ptext": 0, "awe": 0, "kind": 0, "status": 0, "recall": 0]
    mutate(&fields)
    return body(fields)
}
guard case .forward = DYDMProbeGate.verdict(input(shapeBody())) else { fatalError("shape must stay off unless accepted") }
guard case .shape(let shape) = DYDMProbeGate.verdict(input(shapeBody(), shape: true)) else { fatalError("shape codes rejected") }
precondition(shape.message == 1 && shape.identifier == 1 && shape.sameObject == 1 && shape.content == 3 && shape.inner == 3)
expectDrop(shapeBody { $0["gen"] = 9 }, "gen") { $0.acceptShape = true }
expectDrop(shapeBody { $0["epoch"] = 9 }, "epoch") { $0.acceptShape = true }
expectDrop(shapeBody { $0["content"] = "hidden-body" }, "schema") { $0.acceptShape = true }
expectDrop(shapeBody { $0["note"] = "hidden-body" }, "schema") { $0.acceptShape = true }
expectDrop("{\"type\":\"dm-probe-shape\"" + String(repeating: " ", count: 600), "size") { $0.acceptShape = true }
guard case .forward = DYDMProbeGate.verdict(input("{\"type\":\"dm-probe-shape\"" + String(repeating: " ", count: 600))) else { fatalError("disabled shape must not be logged as a drop") }
guard case .forward = DYDMProbeGate.verdict(input(video)) else { fatalError("shape handling changed video forwarding") }
var routed = base(); routed["direct"] = 1
guard case .event(let marked) = DYDMProbeGate.verdict(input(body(routed), lastSeq: 0)) else { fatalError("direct flag rejected") }
precondition(marked.directReady && marked.aliasOnly == false && marked.incoming == 1)
func routeBody(_ mutate: (inout [String: Any]) -> Void = { _ in }) -> String {
    var fields: [String: Any] = ["type": "dm-probe-route", "v": 1, "eventSeq": 2, "gen": 3, "epoch": 2, "id": "conv-1"]
    mutate(&fields)
    return body(fields)
}
guard case .forward = DYDMProbeGate.verdict(input(routeBody())) else { fatalError("route must stay off unless accepted") }
guard case .route(let route) = DYDMProbeGate.verdict(input(routeBody(), route: true)) else { fatalError("route rejected") }
precondition(route.eventSeq == 2 && route.id == "conv-1")
expectDrop(routeBody { $0["id"] = "bad id" }, "schema") { $0.acceptRoute = true }
expectDrop(routeBody { $0["gen"] = 9 }, "gen") { $0.acceptRoute = true }
expectDrop(routeBody { $0["epoch"] = 9 }, "epoch") { $0.acceptRoute = true }
print("PASS production DM probe gate: origin, schema, size, rate, generation, epoch, duplicate, video passthrough, shape codes, route")
'''

with tempfile.TemporaryDirectory(prefix="dm-probe-gate-", dir=os.environ["TMPDIR"]) as directory:
    path = Path(directory)
    (path / "Gate.swift").write_text(program)
    subprocess.run(["swiftc", str(path / "Gate.swift"), "-o", str(path / "gate")], check=True)
    subprocess.run([str(path / "gate")], check=True, timeout=15)
