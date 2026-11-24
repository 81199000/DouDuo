"""1.6.5 起「边看边缓存」「省流量模式」默认打开：没设置过的用户（含从旧版升级）取到 true，设置页开关默认值也一致。"""
import pathlib, re
root = pathlib.Path(__file__).resolve().parent.parent / "DouDuo"
s = (root / "DYStreamCache.swift").read_text()
assert re.search(r'static var enabled: Bool \{ UserDefaults\.standard\.object\(forKey: enabledKey\) as\? Bool \?\? true \}', s), "边看边缓存默认要开"
assert re.search(r'static var saverOn: Bool \{ UserDefaults\.standard\.object\(forKey: saverKey\) as\? Bool \?\? true \}', s), "省流量模式默认要开"
st = (root / "DYSettingsScreen.swift").read_text()
assert "@AppStorage(DYStream.enabledKey) private var streamCache = true" in st
assert "@AppStorage(DYStream.saverKey) private var dataSaver = true" in st, "蜂窝省流量默认开"
assert "@AppStorage(DYStream.wifiSaverKey) private var wifiSaver = false" in st, "Wi-Fi 省流量默认关"
assert "static var wifiSaverOn: Bool { UserDefaults.standard.object(forKey: wifiSaverKey) as? Bool ?? false }" in s, "Wi-Fi 省流量默认关"
u = (root / "UpdateChecker.swift").read_text()
assert 'giteeRepo = "remon8/douduo"' in u and 'static let repo = "81199000/DouDuo"' in u, "更新检查源与开源仓库地址不对"
print("ok saver default + update source")
