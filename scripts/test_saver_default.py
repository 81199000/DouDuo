#!/usr/bin/env python3
"""边看边缓存固定开；蜂窝 / Wi-Fi 省流量固定开；预缓存固定 10 条。"""
import pathlib, re
root = pathlib.Path(__file__).resolve().parent.parent / "DouDuo"
s = (root / "DYStreamCache.swift").read_text()
assert "static let enabled = true" in s and "enabledKey" not in s, "边看边缓存固定开"
assert "static let saverOn = true" in s, "蜂窝省流量固定开"
assert "static let wifiSaverOn = true" in s, "Wi-Fi 省流量固定开"
assert "saverKey" not in s and "wifiSaverKey" not in s
c = (root / "DouyinVideoCache.swift").read_text()
assert "static let defaultCount = 10" in c and "static let limit = defaultCount" in c, "预缓存固定 10 条"
st = (root / "DYSettingsScreen.swift").read_text()
for gone in ("Wi-Fi 省流量", "蜂窝数据省流量", "预缓存数量", "countKey", "边看边缓存"):
    assert gone not in st, gone
u = (root / "UpdateChecker.swift").read_text()
assert 'giteeRepo = "remon8/douduo"' in u and 'static let repo = "81199000/DouDuo"' in u, "更新检查源与开源仓库地址不对"
print("ok saver default + update source")
