#!/usr/bin/env python3
"""倍速声音变小：引擎链路插 PeakLimiter 按倍速补增益；把补偿曲线编出来真跑。"""
import pathlib, subprocess, sys, tempfile
R = pathlib.Path(__file__).resolve().parent.parent / "DouDuo"
s = (R / "SeamlessAudioPlayer.swift").read_text()
fails = []
def check(ok, msg):
    print(("PASS " if ok else "FAIL ") + msg)
    if not ok: fails.append(msg)

check("kAudioUnitSubType_PeakLimiter" in s, "链路里有限幅器（补增益不削顶）")
check("engine.connect(timePitch, to: loudness" in s and "engine.connect(loudness, to: engine.mainMixerNode" in s, "TimePitch → 补响度 → 混音")
check("engine.connect(timePitch, to: engine.mainMixerNode" not in s, "不再绕过补响度直连")
check(s.count("applyLoudness(rate: rate)") == 2, "起播和改速都跟着补")
check("kLimiterParam_PreGain" in s, "补偿写在限幅器 PreGain")
check("hub.loudness.latency" in s, "声音时钟扣掉限幅器延迟（音画同步）")

lo = s[s.index("// BEGIN DDLoudness"):s.index("// END DDLoudness")]
harness = "import Foundation\n" + lo + """
func c(_ r: Float) -> Float { DDLoudness.compensationDB(rate: r) }
precondition(c(1) == 0 && c(0.5) == 0 && c(0.75) == 0, "1x 和减速不补")
precondition(abs(c(2) - 1.6) < 0.01, "2x 补 1.6 dB")
precondition(c(1.25) > 0.3 && c(1.25) < 0.8, "1.25x 约 0.5 dB")
precondition(abs(c(4) - 3.2) < 0.01, "4x（速率上限）补 3.2 dB")
precondition(c(1.5) < c(2) && c(2) < c(3), "越快补越多")
print("PASS loudness curve")
"""
with tempfile.TemporaryDirectory() as d:
    f = pathlib.Path(d) / "L.swift"; f.write_text(harness)
    out = subprocess.run(["swift", str(f)], text=True, capture_output=True, timeout=120)
print(out.stdout.strip())
if out.returncode != 0: print(out.stderr[-800:])
check(out.returncode == 0, "补偿曲线真跑")
sys.exit(1 if fails else 0)
