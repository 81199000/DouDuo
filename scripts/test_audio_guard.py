"""音频会话守卫：前台不让第三方（VLC）关会话，我们自己要关的地方必须包 allowDeactivate。
2026-11-20 真机：直播卡后面那条视频开播后被停住，根因是 VLC 停播时 setActive:NO。"""
import pathlib, re, sys
root = pathlib.Path(__file__).resolve().parent.parent / "DouDuo"
bad = []
for f in root.glob("*.swift"):
    if f.name == "DDAudioSessionGuard.swift": continue
    lines = f.read_text().splitlines()
    for i, l in enumerate(lines):
        if re.search(r"AVAudioSession\.sharedInstance\(\)\.setActive\(false", l):
            ctx = "\n".join(lines[max(0, i - 3):i + 1])
            if "allowDeactivate" not in ctx and "DOUDUO_AUDIOGUARD_TEST" not in "\n".join(lines[max(0, i - 15):i]):
                bad.append(f"{f.name}:{i+1}")
app = (root / "DouDuoApp.swift").read_text()
assert "DDAudioSessionGuard.install()" in app, "启动时要装守卫"
g = (root / "DDAudioSessionGuard.swift").read_text()
assert 'NSSelectorFromString("setActive:withOptions:error:")' in g and 'NSSelectorFromString("setActive:error:")' in g
assert bad == [], "自己关会话没包 allowDeactivate（前台会被守卫拦掉）: " + ", ".join(bad)
print("ok audio guard")
