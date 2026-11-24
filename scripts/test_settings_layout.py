#!/usr/bin/env python3
"""设置页 11-24 重排：两个省流量开关、每项 ⓘ 说明、高级设置归拢、横竖屏筛选默认关。"""
import re, sys, pathlib
R = pathlib.Path(__file__).resolve().parent.parent / "DouDuo"
s = (R / "DYSettingsScreen.swift").read_text()
feed = (R / "DouyinFeedView.swift").read_text()
fails = []
def check(ok, msg):
    print(("PASS " if ok else "FAIL ") + msg)
    if not ok: fails.append(msg)

check('Toggle("Wi-Fi 省流量", isOn: $wifiSaver)' in s and 'Toggle("蜂窝数据省流量", isOn: $dataSaver)' in s, "两个省流量开关")
check("private var wifiSaver = false" in s and "private var dataSaver = true" in s, "Wi-Fi 默认关、蜂窝默认开")
check("private var landscapeOnly = false" in s and "private var portraitMix = false" in s, "设置页横竖屏筛选默认关")
check('"douyin_wide_landscape_v1") var landscapeWhenWide = false' in feed and '"douyin_portrait_mix_v1") var portraitMix = false' in feed, "推荐模型横竖屏筛选默认关")
adv = s[s.index("private var advanced: some View"):s.index("private func row<C: View>")]
main = s[:s.index("private var advanced: some View")]
for t in ('"横屏时只放横屏内容"', '"竖屏时固定 70% 竖屏视频"', '"10 秒内重复弹幕去重"', '"离开应用时自动画中画"',
          '"点回复时自动弹出键盘"', '"用网页评论框发送"', 'Toggle("边看边缓存"', '"清空看过记录"'):
    check(t in adv and t not in main, f"{t} 在高级设置里")
# 每个开关 / 选择都包了 row(...)，ⓘ 说明齐全
cases = re.findall(r"row\(\.(\w+)\)", s)
enum = s[s.index("enum DYSettingInfo"):s.index("struct DYSettingInfoSheet")]
declared = set(re.findall(r"\bcase ([a-zA-Z, ]+)\n", enum)[0].replace(" ", "").split(",") + re.findall(r"\bcase ([a-zA-Z, ]+)\n", enum)[1].replace(" ", "").split(",") + re.findall(r"\bcase ([a-zA-Z, ]+)\n", enum)[2].replace(" ", "").split(","))
check(set(cases) == declared, f"每个 ⓘ 都有说明且都用上了 {sorted(set(cases) ^ declared)}")
toggles = len(re.findall(r'Toggle\("', s)); pickers = len(re.findall(r'Picker\("', s)) - 1  # 外观分段不带 ⓘ
check(len(cases) >= toggles + pickers, f"开关 {toggles} + 选择 {pickers} 都带 ⓘ（row {len(cases)}）")
check(".sheet(item: $info)" in s, "点 ⓘ 弹说明")
sys.exit(1 if fails else 0)
